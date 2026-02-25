#!/bin/zsh

# ==============================================================================
# Script Name:  abm_warranty_report.zsh
# Author:       Brandon Woods
# Date:         February 23, 2026
#
# Changelog:
#   February 25, 2026 — Added AppleCare+ support. Warranty Expires now reflects
#                       the AppleCare+ expiration date when active coverage exists,
#                       falling back to the Limited Warranty date for devices
#                       without AppleCare. Credit: fpatafta (Jamf Nation Community)
# ==============================================================================
#
# Pulls device and AppleCare / warranty coverage data from Apple Business
# Manager and writes two MUT-compatible CSV files:
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
#   ./abm_warranty_report.zsh
#   ./abm_warranty_report.zsh --key /path/to/key.pem \
#                              --client-id BUSINESSAPI.xxxx \
#                              --key-id xxxx \
#                              --outdir /path/to/output/folder \
#                              --computer-file MyMacs.csv \
#                              --mobile-file MyMobileDevices.csv
# ==============================================================================

# ---------- Configuration (edit these) ---------------------------------------
ABM_PRIVATE_KEY_PATH="/path/to/private-key.pem"
ABM_CLIENT_ID="BUSINESSAPI.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
ABM_KEY_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
OUTPUT_DIR="."
COMPUTER_FILENAME="ComputerTemplate.csv"
MOBILE_FILENAME="MobileDeviceTemplate.csv"

# API endpoints
ABM_AUTH_URL="https://account.apple.com/auth/oauth2/token"
ABM_API_BASE="https://api-business.apple.com/v1"

# Pause between per-device coverage API calls to avoid rate limiting (seconds)
RATE_LIMIT_DELAY=0.2

# ---------- Parse command-line flags -----------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)             ABM_PRIVATE_KEY_PATH="$2"; shift 2 ;;
        --client-id)       ABM_CLIENT_ID="$2";         shift 2 ;;
        --key-id)          ABM_KEY_ID="$2";             shift 2 ;;
        --outdir)          OUTPUT_DIR="$2";             shift 2 ;;
        --computer-file)   COMPUTER_FILENAME="$2";      shift 2 ;;
        --mobile-file)     MOBILE_FILENAME="$2";        shift 2 ;;
        --delay)           RATE_LIMIT_DELAY="$2";       shift 2 ;;
        --help|-h)
            sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1 ;;
    esac
done

# Ensure filenames end in .csv
[[ "$COMPUTER_FILENAME" != *.csv ]] && COMPUTER_FILENAME="${COMPUTER_FILENAME}.csv"
[[ "$MOBILE_FILENAME"   != *.csv ]] && MOBILE_FILENAME="${MOBILE_FILENAME}.csv"

COMPUTER_CSV="${OUTPUT_DIR}/${COMPUTER_FILENAME}"
MOBILE_CSV="${OUTPUT_DIR}/${MOBILE_FILENAME}"

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

# ---------- Helper: base64url encode -----------------------------------------
base64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# ---------- Step 1: Build and sign the JWT client assertion -------------------
echo "-> Generating JWT client assertion..."

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

# ---------- Step 2: Exchange client assertion for bearer token ---------------
echo "-> Requesting bearer token..."

tokenResponse=$(curl -s -w "\n__STATUS__%{http_code}" -X POST \
    -H "Host: account.apple.com" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    "${ABM_AUTH_URL}?grant_type=client_credentials&client_id=${ABM_CLIENT_ID}&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=${clientAssertion}&scope=business.api")

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

echo "  OK Bearer token obtained (valid ~1 hour)"

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

    if [[ -n "$nextCursor" ]]; then
        pageUrl="${ABM_API_BASE}/orgDevices?cursor=${nextCursor}"
    else
        pageUrl="${ABM_API_BASE}/orgDevices"
    fi

    pageResponse=$(curl -sf \
        -H "Authorization: Bearer ${accessToken}" \
        "$pageUrl")

    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to fetch device list (page $pageCount)" >&2
        exit 1
    fi

    pageDeviceCount=$(echo "$pageResponse" | jq '.data | length')
    echo "  Page $pageCount: $pageDeviceCount devices"

    while IFS= read -r serial \
       && IFS= read -r productFamily \
       && IFS= read -r orderNumber \
       && IFS= read -r purchaseSourceType \
       && IFS= read -r orderDateTime; do

        totalDevices=$(( totalDevices + 1 ))

        # Skip devices already present in the existing CSV
        if [[ "$productFamily" == "Mac" ]]; then
            if (( ${+knownComputerSerials[$serial]} )); then
                skippedCount=$(( skippedCount + 1 ))
                continue
            fi
            targetCSV="$COMPUTER_CSV"
            newComputerCount=$(( newComputerCount + 1 ))
        else
            if (( ${+knownMobileSerials[$serial]} )); then
                skippedCount=$(( skippedCount + 1 ))
                continue
            fi
            targetCSV="$MOBILE_CSV"
            newMobileCount=$(( newMobileCount + 1 ))
        fi

        # Normalize null jq values to empty string
        [[ "$orderNumber"        == "null" ]] && orderNumber=""
        [[ "$purchaseSourceType" == "null" ]] && purchaseSourceType=""
        [[ "$orderDateTime"      == "null" ]] && orderDateTime=""

        # Trim time portion from ISO 8601 timestamp — keep date only
        poDate="${orderDateTime%%T*}"

        echo "  New device: $serial ($productFamily)"

        # Fetch AppleCare coverage for this device
        coverageResponse=$(curl -sf \
            -H "Authorization: Bearer ${accessToken}" \
            "${ABM_API_BASE}/orgDevices/${serial}/appleCareCoverage")

        if [[ $? -ne 0 ]]; then
            # Coverage unavailable — write serial and PO fields, leave warranty blank
            if [[ "$productFamily" == "Mac" ]]; then
                printf '"%s",,,,,,,,,,,,,"%s","%s",,"%s",,,,,\n' \
                    "$serial" "$orderNumber" "$purchaseSourceType" "$poDate" >> "$targetCSV"
            else
                printf '"%s",,,,,,,,,,,,"%s","%s",,"%s",,,,,,\n' \
                    "$serial" "$orderNumber" "$purchaseSourceType" "$poDate" >> "$targetCSV"
            fi
            errorCount=$(( errorCount + 1 ))
            sleep "$RATE_LIMIT_DELAY"
            continue
        fi

        # Warranty Expires — prefer active AppleCare+ expiration date when available,
        # fall back to Limited Warranty end date if no active AppleCare coverage exists.
        # Credit: fpatafta (Jamf Nation Community, February 25, 2026)
        warrantyExpires=$(echo "$coverageResponse" | jq -r '
            [ .data[] | select(.attributes.description != "Limited Warranty" and .attributes.status == "ACTIVE") ]
            | first
            | .attributes.endDateTime // ""')

        if [[ -z "$warrantyExpires" || "$warrantyExpires" == "null" ]]; then
            warrantyExpires=$(echo "$coverageResponse" | jq -r '
                [ .data[] | select(.attributes.description == "Limited Warranty") ]
                | first
                | .attributes.endDateTime // ""')
        fi
        warrantyExpires="${warrantyExpires%%T*}"

        # AppleCare agreement number -> AppleCare ID (prefer ACTIVE entry)
        applecareID=$(echo "$coverageResponse" | jq -r '
            [ .data[] | select(.attributes.description != "Limited Warranty") ]
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
        else
            # Mobile: 22 cols
            # Col: 1=Serial  13=PO#  14=Vendor  15=Price(blank)  16=PODate  17=WarrantyExpires  20=AppleCareID
            printf '"%s",,,,,,,,,,,,"%s","%s",,"%s","%s",,,"%s",,\n' \
                "$serial" \
                "$orderNumber" "$purchaseSourceType" \
                "$poDate" "$warrantyExpires" \
                "$applecareID" >> "$targetCSV"
        fi

        sleep "$RATE_LIMIT_DELAY"

    done < <(echo "$pageResponse" | jq -r '.data[] | (
        .id,
        (.attributes.productFamily // "Unknown"),
        (.attributes.orderNumber // "null"),
        (.attributes.purchaseSourceType // "null"),
        (.attributes.orderDateTime // "null")
    )')

    echo "  Page $pageCount complete — New: $newComputerCount computers, $newMobileCount mobile | Skipped: $skippedCount | Errors: $errorCount"

    nextCursor=$(echo "$pageResponse" | jq -r '.meta.paging.nextCursor // empty')
    [[ -z "$nextCursor" ]] && break
done

# ---------- Summary -----------------------------------------------------------
newDevicesTotal=$(( newComputerCount + newMobileCount ))

echo ""
echo "============================================"
echo " ABM Warranty Report Complete"
echo "============================================"
echo " Total devices in ABM : $totalDevices"
echo " Already in CSV       : $skippedCount (skipped)"
echo " New computers added  : $newComputerCount -> $(basename "$COMPUTER_CSV")"
echo " New mobile added     : $newMobileCount -> $(basename "$MOBILE_CSV")"
echo " Coverage errors      : $errorCount"
echo "============================================"

if [[ $newDevicesTotal -eq 0 ]]; then
    echo ""
    echo " No new devices were found in ABM."
    echo " Both CSV files are already up to date."
    echo "============================================"
fi
