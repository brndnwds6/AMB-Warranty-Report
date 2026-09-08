#!/bin/zsh

# ==============================================================================
# Script Name:  warranty_wrangler.zsh
# Author:       Brandon Woods
# Date:         February 23, 2026
# Version:      1.4.0
#
# Changelog:
#   1.1.0 — February 25, 2026
#           Added AppleCare+ support. Warranty Expires now reflects the
#           AppleCare+ expiration date when active coverage exists, falling
#           back to the Limited Warranty date for devices without AppleCare.
#           Credit: fpatafta (Jamf Nation Community)
#
#   1.2.0 — February 26, 2026
#           Added Apple School Manager (ASM) support via --asm flag. Switches
#           API base URL and OAuth scope automatically.
#           Credit: MultiSiggloo (Jamf Nation Community)
#
#   1.2.1 — March 26, 2026
#           Fixed rate limiting error (HTTP 429 / "Failed to fetch device
#           list") occurring on reruns when all devices are already in the CSV.
#           Page fetches now include a brief delay between requests and will
#           retry up to 3 times with increasing back-off on 429 responses.
#           HTTP status is now captured and printed on failure for easier
#           diagnosis. Credit: BR_TCTX, Steve_Xu (Jamf Nation Community)
#
#   1.3.0 — March 31, 2026
#           Improved rate-limiting resilience:
#           - Separate PAGE_FETCH_DELAY (default 2s) between page fetches so
#             skipped pages no longer hammer the API.
#           - Adaptive extra delay when an entire page has no new devices.
#           - Coverage API calls now retry up to 3x on HTTP 429 instead of
#             silently failing.
#           - Retry-After header honored on 429 responses when available.
#           - Early exit when known serial count >= ABM org total.
#           - Bearer token expiry warning after ~50 minutes of runtime.
#           - Added --page-delay CLI flag.
#           - Default RATE_LIMIT_DELAY increased from 0.2s to 0.3s.
#           - Enabled PIPE_FAIL for more reliable error detection.
#
#   1.4.0 — September 8, 2026
#           Reliability and failure-handling fixes:
#           - A flag given no value now errors out instead of spinning the
#             argument parser in an infinite loop.
#           - The bearer token is refreshed automatically as it nears its
#             1-hour expiry, and expiry is now checked before every coverage
#             call rather than only at page boundaries. Long runs no longer
#             abort partway through.
#           - Devices whose coverage lookup fails are no longer written to the
#             CSV with a blank warranty date (which incremental mode then
#             skipped on every later run). They are recorded in the failed
#             coverage file and retried on the next run.
#           - All curl calls now carry connect and total timeouts.
#           - Exits non-zero when any device could not be fetched.
#           - --help no longer depends on hardcoded line numbers.
# ==============================================================================
#
# Pulls device and AppleCare / warranty coverage data from Apple Business
# Manager (ABM) or Apple School Manager (ASM) and writes two MUT-compatible CSV files:
#
#   ComputerTemplate.csv     — Mac devices (productFamily = "Mac")
#   MobileDeviceTemplate.csv — iPhone, iPad, Apple TV, iPod, Vision Pro, etc.
#
# Incremental mode:
#   If the output CSV files already exist at the configured paths, the script
#   loads the serials already present and skips them — only newly added ABM
#   devices are fetched and appended. If no new devices are found the script
#   exits and tells you so.
#
# Populated fields (all others left blank):
#   Both templates:
#     Serial Number    — device serial / ID from ABM
#     PO Number        — orderNumber from ABM device record
#     Vendor           — purchaseSourceType from ABM device record
#     Purchase Price   — not available in ABM API (always blank)
#     PO Date          — orderDateTime from ABM device record (date only)
#     Warranty Expires — Limited Warranty endDateTime (date only)
#     AppleCare ID     — AppleCare agreement number (blank if none)
#
# Each device row is written to disk immediately after its coverage is fetched.
#
# Prerequisites:
#   - ABM API account with Client ID, Key ID, and .pem private key
#   - jq  (brew install jq)
#   - openssl + xxd (built-in on macOS)
#
# Usage:
#   ./warranty_wrangler.zsh
#   ./warranty_wrangler.zsh --key /path/to/key.pem \
#                              --client-id BUSINESSAPI.xxxx \
#                              --key-id xxxx \
#                              --outdir /path/to/output/folder \
#                              --computer-file MyMacs.csv \
#                              --mobile-file MyMobileDevices.csv
#   ./warranty_wrangler.zsh --asm \
#                              --client-id SCHOOLAPI.xxxx \
#                              --key-id xxxx
# ==============================================================================

setopt PIPE_FAIL

# ---------- Configuration (edit these) ---------------------------------------
ABM_PRIVATE_KEY_PATH="/path/to/private-key.pem"
ABM_CLIENT_ID="BUSINESSAPI.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
ABM_KEY_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
OUTPUT_DIR="."
COMPUTER_FILENAME="ComputerTemplate.csv"
MOBILE_FILENAME="MobileDeviceTemplate.csv"

# Devices whose AppleCare coverage lookup fails are listed here so they can be
# reviewed. They are deliberately left out of the CSVs so the next run retries.
FAILED_FILENAME="failed_coverage.csv"

# API endpoints — overridden automatically when --asm flag is used
ABM_AUTH_URL="https://account.apple.com/auth/oauth2/token"
ABM_API_BASE="https://api-business.apple.com/v1"
ABM_SCOPE="business.api"
ASM_MODE=false

# Pause between per-device coverage API calls to avoid rate limiting (seconds)
RATE_LIMIT_DELAY=0.3

# Pause between page-level device-list fetches (seconds)
PAGE_FETCH_DELAY=2

# curl network timeouts (seconds). Without these a stalled connection hangs
# the run indefinitely with no output.
CURL_CONNECT_TIMEOUT=15
CURL_MAX_TIME=60

# ---------- Helper: require a value for a flag -------------------------------
# A flag given no value used to leave $# unchanged while 'shift 2' failed,
# spinning this loop forever. Validate up front instead.
requireFlagValue() {
    if [[ -z "$2" || "$2" == --* ]]; then
        echo "ERROR: $1 requires a value." >&2
        echo "       Run '$(basename "$0") --help' for usage." >&2
        exit 1
    fi
}

# ---------- Parse command-line flags -----------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)             requireFlagValue "$1" "$2"; ABM_PRIVATE_KEY_PATH="$2"; shift 2 ;;
        --client-id)       requireFlagValue "$1" "$2"; ABM_CLIENT_ID="$2";        shift 2 ;;
        --key-id)          requireFlagValue "$1" "$2"; ABM_KEY_ID="$2";           shift 2 ;;
        --outdir)          requireFlagValue "$1" "$2"; OUTPUT_DIR="$2";           shift 2 ;;
        --computer-file)   requireFlagValue "$1" "$2"; COMPUTER_FILENAME="$2";    shift 2 ;;
        --mobile-file)     requireFlagValue "$1" "$2"; MOBILE_FILENAME="$2";      shift 2 ;;
        --delay)           requireFlagValue "$1" "$2"; RATE_LIMIT_DELAY="$2";     shift 2 ;;
        --page-delay)      requireFlagValue "$1" "$2"; PAGE_FETCH_DELAY="$2";     shift 2 ;;
        --asm)             ASM_MODE=true;                                         shift 1 ;;
        --help|-h)
            # Print the header comment block, stopping at the first line that
            # is not a comment, so this does not need manual line-number upkeep.
            awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1 ;;
    esac
done

# Ensure filenames end in .csv
[[ "$COMPUTER_FILENAME" != *.csv ]] && COMPUTER_FILENAME="${COMPUTER_FILENAME}.csv"
[[ "$MOBILE_FILENAME"   != *.csv ]] && MOBILE_FILENAME="${MOBILE_FILENAME}.csv"

# Override API base and scope for Apple School Manager
if [[ "$ASM_MODE" == true ]]; then
    ABM_API_BASE="https://api-school.apple.com/v1"
    ABM_SCOPE="school.api"
    echo "-> Mode: Apple School Manager (ASM)"
else
    echo "-> Mode: Apple Business Manager (ABM)"
fi

COMPUTER_CSV="${OUTPUT_DIR}/${COMPUTER_FILENAME}"
MOBILE_CSV="${OUTPUT_DIR}/${MOBILE_FILENAME}"
FAILED_CSV="${OUTPUT_DIR}/${FAILED_FILENAME}"

# Written lazily on the first coverage failure so a clean run leaves no file.
failedFileInitialized=false

# ---------- Dependency checks -------------------------------------------------
for cmd in jq openssl curl xxd; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not found. Install with: brew install $cmd" >&2
        exit 1
    fi
done

if [[ ! -f "$ABM_PRIVATE_KEY_PATH" ]]; then
    echo "ERROR: Private key not found at: $ABM_PRIVATE_KEY_PATH" >&2
    exit 1
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "ERROR: Output directory does not exist: $OUTPUT_DIR" >&2
    exit 1
fi

# ---------- Detect existing CSVs and load known serials ----------------------
# knownComputerSerials and knownMobileSerials are associative arrays used as
# sets — key = serial number, value = 1. Lookup is O(1).
typeset -A knownComputerSerials
typeset -A knownMobileSerials

computerFileExists=false
mobileFileExists=false

if [[ -f "$COMPUTER_CSV" ]]; then
    computerFileExists=true
    # Read col 1 (serial), skip header row, strip surrounding quotes
    while IFS=, read -r serial rest; do
        serial="${serial//\"/}"
        [[ -n "$serial" && "$serial" != "Computer Serial" ]] && knownComputerSerials[$serial]=1
    done < "$COMPUTER_CSV"
    echo "-> Existing computer file detected: $COMPUTER_CSV"
    echo "   ${#knownComputerSerials} known serials loaded — will append new devices only"
else
    echo "-> No existing computer file found — will create: $COMPUTER_CSV"
fi

if [[ -f "$MOBILE_CSV" ]]; then
    mobileFileExists=true
    while IFS=, read -r serial rest; do
        serial="${serial//\"/}"
        [[ -n "$serial" && "$serial" != "Mobile Device Serial" ]] && knownMobileSerials[$serial]=1
    done < "$MOBILE_CSV"
    echo "-> Existing mobile file detected: $MOBILE_CSV"
    echo "   ${#knownMobileSerials} known serials loaded — will append new devices only"
else
    echo "-> No existing mobile file found — will create: $MOBILE_CSV"
fi

# ---------- Shared curl options ----------------------------------------------
# Applied to every request so a stalled connection cannot hang the run.
curlTimeoutOpts=( --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" )

# ---------- Helper: base64url encode -----------------------------------------
base64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# ---------- Temp file for response headers (cleaned up on exit) --------------
headerTmpFile=$(mktemp)
trap "rm -f '$headerTmpFile'" EXIT INT TERM

# ---------- Steps 1 & 2: Build a signed JWT and exchange it for a token ------
# Wrapped in a function so it can be called again mid-run. Sets accessToken
# and tokenObtainedAt.
generateBearerToken() {
    echo "-> Generating JWT client assertion..."

    # Declared before assignment so $? reflects the command substitution
    # rather than the 'local' builtin, which always succeeds.
    local nowTimestamp expTimestamp jti headerJson jwtHeader payloadJson
    local jwtPayload signingInput asn1Out rHex sHex signature clientAssertion
    local tokenResponse httpStatus tokenBody

    nowTimestamp=$(date -u +%s)
    expTimestamp=$(( nowTimestamp + 15552000 ))   # 180 days
    jti=$(uuidgen | tr '[:upper:]' '[:lower:]')

    headerJson=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$ABM_KEY_ID")
    jwtHeader=$(printf '%s' "$headerJson" | base64url)

    payloadJson=$(printf '{"sub":"%s","aud":"https://account.apple.com/auth/oauth2/v2/token","iat":%d,"exp":%d,"jti":"%s","iss":"%s"}' \
        "$ABM_CLIENT_ID" "$nowTimestamp" "$expTimestamp" "$jti" "$ABM_CLIENT_ID")
    jwtPayload=$(printf '%s' "$payloadJson" | base64url)

    signingInput="${jwtHeader}.${jwtPayload}"

    asn1Out=$(printf '%s' "$signingInput" \
        | openssl dgst -sha256 -sign "$ABM_PRIVATE_KEY_PATH" 2>/dev/null \
        | openssl asn1parse -inform DER 2>&1)

    if [[ $? -ne 0 ]]; then
        echo "ERROR: openssl signing failed. Verify your .pem contains a valid EC private key." >&2
        echo "$asn1Out" >&2
        exit 1
    fi

    rHex=$(echo "$asn1Out" | awk '/INTEGER/{gsub(/.*INTEGER[[:space:]]+:/,"",$0); gsub(/ /,"",$0); if(++n==1) print}')
    sHex=$(echo "$asn1Out" | awk '/INTEGER/{gsub(/.*INTEGER[[:space:]]+:/,"",$0); gsub(/ /,"",$0); if(++n==2) print}')

    if [[ -z "$rHex" || -z "$sHex" ]]; then
        echo "ERROR: Failed to extract r/s from ASN.1 signature." >&2
        echo "$asn1Out" >&2
        exit 1
    fi

    rHex=$(printf '%s' "$rHex" | sed 's/^00//')
    sHex=$(printf '%s' "$sHex" | sed 's/^00//')
    while [[ ${#rHex} -lt 64 ]]; do rHex="00${rHex}"; done
    while [[ ${#sHex} -lt 64 ]]; do sHex="00${sHex}"; done

    signature=$(printf '%s%s' "$rHex" "$sHex" | xxd -r -p | base64url)
    clientAssertion="${signingInput}.${signature}"
    echo "  OK Client assertion generated"

    echo "-> Requesting bearer token..."

    tokenResponse=$(curl -s "${curlTimeoutOpts[@]}" -w "\n__STATUS__%{http_code}" -X POST \
        -H "Host: account.apple.com" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        "${ABM_AUTH_URL}?grant_type=client_credentials&client_id=${ABM_CLIENT_ID}&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=${clientAssertion}&scope=${ABM_SCOPE}")

    httpStatus=$(echo "$tokenResponse" | grep '__STATUS__' | sed 's/__STATUS__//')
    tokenBody=$(echo "$tokenResponse" | grep -v '__STATUS__')

    if [[ "$httpStatus" != "200" ]]; then
        echo "ERROR: Token request failed (HTTP $httpStatus):" >&2
        echo "$tokenBody" >&2
        exit 1
    fi

    accessToken=$(echo "$tokenBody" | jq -r '.access_token // empty')
    if [[ -z "$accessToken" ]]; then
        echo "ERROR: No access_token in response:" >&2
        echo "$tokenBody" >&2
        exit 1
    fi

    tokenObtainedAt=$(date -u +%s)
    echo "  OK Bearer token obtained (valid ~1 hour)"
}

# ---------- Helper: refresh the bearer token before it expires ---------------
# Apple bearer tokens last ~1 hour. Previously the script aborted at ~58 min,
# so any org too large to finish inside one token lifetime could never complete
# in a single run. A fresh assertion can be minted at any time, so refresh
# instead of giving up. Called at each page boundary and before every coverage
# call, since a page of devices can take a long time on its own.
ensureFreshToken() {
    local tokenAge=$(( $(date -u +%s) - tokenObtainedAt ))
    if [[ $tokenAge -ge 3000 ]]; then
        echo "  Bearer token is $(( tokenAge / 60 )) min old — refreshing before it expires"
        generateBearerToken
    fi
}

# ---------- Helper: record a device whose coverage lookup failed -------------
# These devices are intentionally NOT written to the CSVs. A row there would
# carry a blank Warranty Expires, and incremental mode would treat the serial
# as done and skip it on every future run, making a transient failure
# permanent. Leaving them out means the next run retries them.
recordCoverageFailure() {
    if [[ "$failedFileInitialized" == false ]]; then
        printf '%s\n' "Serial,Product Family,HTTP Status" > "$FAILED_CSV"
        failedFileInitialized=true
    fi
    printf '"%s","%s","%s"\n' "$1" "$2" "${3:-no response}" >> "$FAILED_CSV"
}

generateBearerToken

# ---------- Step 3: Initialize output files -----------------------------------
# Write header only if the file does not already exist
echo "-> Initializing output files..."

if [[ "$computerFileExists" == false ]]; then
    printf '%s\n' "Computer Serial,Display Name,Asset Tag,Barcode 1,Barcode 2,Username,Real Name,Email Address,Position,Phone Number,Department,Building,Room,PO Number,Vendor,Purchase Price,PO Date,Warranty Expires,Is Leased,Lease Expires,AppleCare ID,Site (ID or Name)" > "$COMPUTER_CSV"
    echo "  Created: $COMPUTER_CSV"
else
    echo "  Appending to: $COMPUTER_CSV"
fi

if [[ "$mobileFileExists" == false ]]; then
    printf '%s\n' "Mobile Device Serial,Display Name,Enforce Name,Asset Tag,Username,Real Name,Email Address,Position,Phone Number,Department,Building,Room,PO Number,Vendor,Purchase Price,PO Date,Warranty Expires,Is Leased,Lease Expires,AppleCare ID,Airplay Password (tvOS Only),Site (ID or Name)" > "$MOBILE_CSV"
    echo "  Created: $MOBILE_CSV"
else
    echo "  Appending to: $MOBILE_CSV"
fi

# ---------- Step 4: Enumerate devices and fetch coverage page by page --------
echo "-> Fetching devices from ABM..."

totalDevices=0
newComputerCount=0
newMobileCount=0
skippedCount=0
errorCount=0
nextCursor=""
pageCount=0

while true; do
    pageCount=$(( pageCount + 1 ))

    # --- Refresh the bearer token if it is nearing expiry ---------------------
    ensureFreshToken

    if [[ -n "$nextCursor" ]]; then
        pageUrl="${ABM_API_BASE}/orgDevices?cursor=${nextCursor}"
    else
        pageUrl="${ABM_API_BASE}/orgDevices"
    fi

    # Fetch device page — capture HTTP status separately so failures are diagnosable.
    # Retries up to 3 times on rate limiting (HTTP 429) with increasing back-off.
    # Honors Retry-After header when available.
    pageResponse=""
    pageHttpStatus=""
    retryCount=0
    while true; do
        pageRaw=$(curl -s "${curlTimeoutOpts[@]}" -D "$headerTmpFile" -w "\n__STATUS__%{http_code}" \
            -H "Authorization: Bearer ${accessToken}" \
            "$pageUrl")
        pageHttpStatus=$(echo "$pageRaw" | grep '__STATUS__' | sed 's/__STATUS__//')
        pageResponse=$(echo "$pageRaw" | grep -v '__STATUS__')

        if [[ "$pageHttpStatus" == "200" ]]; then
            break
        elif [[ "$pageHttpStatus" == "429" && $retryCount -lt 3 ]]; then
            retryCount=$(( retryCount + 1 ))
            retryAfter=$(grep -i '^Retry-After:' "$headerTmpFile" 2>/dev/null | awk '{print $2}' | tr -d '\r')
            if [[ -n "$retryAfter" && "$retryAfter" =~ ^[0-9]+$ ]]; then
                backoff=$retryAfter
            else
                backoff=$(( retryCount * 10 ))
            fi
            echo "  Rate limited (HTTP 429) on page $pageCount — waiting ${backoff}s before retry $retryCount/3..." >&2
            sleep "$backoff"
        else
            echo "ERROR: Failed to fetch device list (page $pageCount) — HTTP $pageHttpStatus" >&2
            echo "$pageResponse" >&2
            exit 1
        fi
    done

    # Pause between page fetches to avoid rate limiting, even when all
    # devices are being skipped and no coverage calls are being made.
    sleep "$PAGE_FETCH_DELAY"

    pageDeviceCount=$(echo "$pageResponse" | jq '.data | length')
    echo "  Page $pageCount: $pageDeviceCount devices"

    # --- Early exit: if first page shows all devices are already known --------
    if [[ $pageCount -eq 1 ]]; then
        totalInOrg=$(echo "$pageResponse" | jq -r '.meta.paging.total // 0')
        knownTotal=$(( ${#knownComputerSerials} + ${#knownMobileSerials} ))
        if [[ $totalInOrg -gt 0 && $knownTotal -ge $totalInOrg ]]; then
            echo "  All $totalInOrg devices already in CSV — nothing to do."
            totalDevices=$totalInOrg
            skippedCount=$totalInOrg
            break
        fi
    fi

    # Track how many new devices are found on this page
    pageNewCount=0

    while IFS= read -r serial \
       && IFS= read -r productFamily \
       && IFS= read -r orderNumber \
       && IFS= read -r purchaseSourceType \
       && IFS= read -r orderDateTime; do

        totalDevices=$(( totalDevices + 1 ))

        # Skip devices already present in the existing CSV. The new-device
        # counters are incremented only once a row is actually written, so a
        # coverage failure is not reported as an added device.
        if [[ "$productFamily" == "Mac" ]]; then
            if (( ${+knownComputerSerials[$serial]} )); then
                skippedCount=$(( skippedCount + 1 ))
                continue
            fi
            targetCSV="$COMPUTER_CSV"
        else
            if (( ${+knownMobileSerials[$serial]} )); then
                skippedCount=$(( skippedCount + 1 ))
                continue
            fi
            targetCSV="$MOBILE_CSV"
        fi

        pageNewCount=$(( pageNewCount + 1 ))

        # Normalize null jq values to empty string
        [[ "$orderNumber"        == "null" ]] && orderNumber=""
        [[ "$purchaseSourceType" == "null" ]] && purchaseSourceType=""
        [[ "$orderDateTime"      == "null" ]] && orderDateTime=""

        # Trim time portion from ISO 8601 timestamp — keep date only
        poDate="${orderDateTime%%T*}"

        echo "  New device: $serial ($productFamily)"

        # A page can take long enough on its own to outlive the token, so
        # check expiry here as well as at the page boundary. Without this the
        # remaining devices on a page would all 401 and be silently recorded
        # as having no coverage.
        ensureFreshToken

        # Fetch AppleCare coverage — retries up to 3 times on HTTP 429
        coverageResponse=""
        coverageStatus=""
        coverageRetry=0
        while true; do
            coverageRaw=$(curl -s "${curlTimeoutOpts[@]}" -D "$headerTmpFile" -w "\n__STATUS__%{http_code}" \
                -H "Authorization: Bearer ${accessToken}" \
                "${ABM_API_BASE}/orgDevices/${serial}/appleCareCoverage")
            coverageStatus=$(echo "$coverageRaw" | grep '__STATUS__' | sed 's/__STATUS__//')
            coverageResponse=$(echo "$coverageRaw" | grep -v '__STATUS__')

            if [[ "$coverageStatus" == "200" ]]; then
                break
            elif [[ "$coverageStatus" == "429" && $coverageRetry -lt 3 ]]; then
                coverageRetry=$(( coverageRetry + 1 ))
                retryAfter=$(grep -i '^Retry-After:' "$headerTmpFile" 2>/dev/null | awk '{print $2}' | tr -d '\r')
                if [[ -n "$retryAfter" && "$retryAfter" =~ ^[0-9]+$ ]]; then
                    backoff=$retryAfter
                else
                    backoff=$(( coverageRetry * 10 ))
                fi
                echo "    Rate limited on coverage for $serial — waiting ${backoff}s (retry $coverageRetry/3)..." >&2
                sleep "$backoff"
            else
                coverageResponse=""
                break
            fi
        done

        if [[ -z "$coverageResponse" || "$coverageStatus" != "200" ]]; then
            # Coverage unavailable. Record the serial and move on WITHOUT
            # writing a row — see recordCoverageFailure for why.
            echo "    Coverage unavailable for $serial (HTTP ${coverageStatus:-no response}) — deferred to next run" >&2
            recordCoverageFailure "$serial" "$productFamily" "$coverageStatus"
            errorCount=$(( errorCount + 1 ))
            sleep "$RATE_LIMIT_DELAY"
            continue
        fi

        # Warranty Expires — prefer active AppleCare+ expiration date when available,
        # fall back to Limited Warranty end date if no active AppleCare coverage exists.
        # Credit: fpatafta (Jamf Nation Community, February 25, 2026)
        warrantyExpires=$(echo "$coverageResponse" | jq -r '
            [ .data // [] | .[] | select(.attributes.description != "Limited Warranty" and .attributes.status == "ACTIVE") ]
            | first
            | .attributes.endDateTime // ""')

        if [[ -z "$warrantyExpires" || "$warrantyExpires" == "null" ]]; then
            warrantyExpires=$(echo "$coverageResponse" | jq -r '
                [ .data // [] | .[] | select(.attributes.description == "Limited Warranty") ]
                | first
                | .attributes.endDateTime // ""')
        fi
        warrantyExpires="${warrantyExpires%%T*}"

        # AppleCare agreement number -> AppleCare ID (prefer ACTIVE entry)
        applecareID=$(echo "$coverageResponse" | jq -r '
            [ .data // [] | .[] | select(.attributes.description != "Limited Warranty") ]
            | sort_by(.attributes.status == "ACTIVE" | not)
            | first
            | .attributes.agreementNumber // ""')

        # Write row immediately — Purchase Price always blank (not in ABM API)
        if [[ "$productFamily" == "Mac" ]]; then
            # Computer: 22 cols
            # Col: 1=Serial  14=PO#  15=Vendor  16=Price(blank)  17=PODate  18=WarrantyExpires  21=AppleCareID
            printf '"%s",,,,,,,,,,,,,"%s","%s",,"%s","%s",,,"%s",\n' \
                "$serial" \
                "$orderNumber" "$purchaseSourceType" \
                "$poDate" "$warrantyExpires" \
                "$applecareID" >> "$targetCSV"
            newComputerCount=$(( newComputerCount + 1 ))
        else
            # Mobile: 22 cols
            # Col: 1=Serial  13=PO#  14=Vendor  15=Price(blank)  16=PODate  17=WarrantyExpires  20=AppleCareID
            printf '"%s",,,,,,,,,,,,"%s","%s",,"%s","%s",,,"%s",,\n' \
                "$serial" \
                "$orderNumber" "$purchaseSourceType" \
                "$poDate" "$warrantyExpires" \
                "$applecareID" >> "$targetCSV"
            newMobileCount=$(( newMobileCount + 1 ))
        fi

        sleep "$RATE_LIMIT_DELAY"

    done < <(echo "$pageResponse" | jq -r '.data[] | (
        .id,
        (.attributes.productFamily // "Unknown"),
        (.attributes.orderNumber // "null"),
        (.attributes.purchaseSourceType // "null"),
        (.attributes.orderDateTime // "null")
    )')

    # Adaptive delay: if no new devices were processed on this page, add extra
    # pause since no per-device coverage calls provided natural throttling.
    if [[ $pageNewCount -eq 0 && $pageDeviceCount -gt 0 ]]; then
        echo "  (All devices on page $pageCount already known — throttling)"
        sleep "$PAGE_FETCH_DELAY"
    fi

    echo "  Page $pageCount complete — New: $newComputerCount computers, $newMobileCount mobile | Skipped: $skippedCount | Errors: $errorCount"

    nextCursor=$(echo "$pageResponse" | jq -r '.meta.paging.nextCursor // empty')
    [[ -z "$nextCursor" ]] && break
done

# ---------- Summary -----------------------------------------------------------
newDevicesTotal=$(( newComputerCount + newMobileCount ))

echo ""
echo "============================================"
if [[ "$ASM_MODE" == true ]]; then
    echo " ASM Warranty Recon Complete"
else
    echo " ABM Warranty Recon Complete"
fi
echo "============================================"
echo " Total devices in ABM : $totalDevices"
echo " Already in CSV       : $skippedCount (skipped)"
echo " New computers added  : $newComputerCount -> $(basename "$COMPUTER_CSV")"
echo " New mobile added     : $newMobileCount -> $(basename "$MOBILE_CSV")"
if [[ $errorCount -gt 0 ]]; then
    echo " Coverage failures    : $errorCount (deferred to next run)"
else
    echo " Coverage failures    : 0"
fi
echo "============================================"

if [[ $newDevicesTotal -eq 0 && $errorCount -eq 0 ]]; then
    echo ""
    if [[ "$ASM_MODE" == true ]]; then
        echo " No new devices were found in ASM."
    else
        echo " No new devices were found in ABM."
    fi
    echo " Both CSV files are already up to date."
    echo "============================================"
fi

# Exit non-zero when any device could not be fetched, so scheduled runs
# (launchd, Jamf policy, CI) can detect a partial result instead of seeing
# a success for a run that skipped devices.
if [[ $errorCount -gt 0 ]]; then
    echo ""
    echo " $errorCount device(s) had no retrievable coverage and were NOT written"
    echo " to the CSVs. They are listed in: $(basename "$FAILED_CSV")"
    echo " Re-run the script to retry them."
    echo "============================================"
    exit 1
elif [[ -f "$FAILED_CSV" ]]; then
    # The file is only rewritten on a run that has failures, so one left over
    # from an earlier run would otherwise look current.
    echo ""
    echo " Note: $(basename "$FAILED_CSV") is left over from an earlier run —"
    echo " no devices failed this time, so it is safe to delete."
    echo "============================================"
fi

exit 0
