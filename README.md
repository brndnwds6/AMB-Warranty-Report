# Warranty Wrangler — Setup & Usage Guide

This guide walks through everything needed to run `warranty_wrangler.zsh`, a script that pulls warranty and AppleCare+ coverage data from Apple Business Manager (ABM) or Apple School Manager (ASM) and produces CSV files ready for import into the Mass Update Tool (MUT).

---

## Prerequisites

- A Mac running macOS
- Administrator access to Apple Business Manager or Apple School Manager
- [`jq`](https://jqlang.org) installed — if you don't have it, install it with [Homebrew](https://brew.sh):
```
  brew install jq
```
- `openssl`, `curl`, and `xxd` — all included with macOS by default

---

## Step 1 — Create a Working Directory

Create a dedicated folder to store the script, your private key, and the generated CSV files. Keeping everything together makes the script easier to configure and run.

Open **Terminal** and run:

```zsh
mkdir ~/abm-warranty
```

You can name and place this folder wherever makes sense for your environment. Just note the full path — you'll need it shortly.

---

## Step 2 — Create an API Account

> **Note:** You must have the **Administrator** role to complete this step.

### Apple Business Manager

1. Sign in to [Apple Business Manager](https://business.apple.com).
2. Select your **name** at the bottom of the sidebar, then select **Preferences**.
3. Select **API** from the preferences panel.
4. Select **Get Started**, enter a name for the account (e.g., `Warranty Report`), then select **Create**.
5. Select **Generate Private Key**. A `.pem` file will automatically download to your browser's download location.
6. Select **Manage** on the newly created API account and note the following two values:
   - **Client ID** — looks like `BUSINESSAPI.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
   - **Key ID** — looks like `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

For full details, refer to Apple's official documentation:
[Create an API account in Apple Business Manager](https://support.apple.com/guide/apple-business-manager/create-an-api-account-axm33189f66a/web)

### Apple School Manager

The process is identical — sign in to [Apple School Manager](https://school.apple.com), navigate to **Preferences → API**, and follow the same steps. Your Client ID will be prefixed with `SCHOOLAPI.` instead of `BUSINESSAPI.`

> **Important:** The `.pem` file can only be downloaded once. If it is lost, you will need to revoke the key and generate a new one. Store it securely.

---

## Step 3 — Store the Private Key

Move the downloaded `.pem` file into the working directory you created in Step 1.

In Terminal:

```zsh
mv ~/Downloads/your-private-key.pem ~/abm-warranty/
```

Replace `your-private-key.pem` with the actual filename of the downloaded file.

---

## Step 4 — Place the Script in the Working Directory

Move or copy `warranty_wrangler.zsh` into the same working directory:

```zsh
mv ~/Downloads/warranty_wrangler.zsh ~/abm-warranty/
```

Then make it executable:

```zsh
chmod +x ~/abm-warranty/warranty_wrangler.zsh
```

---

## Step 5 — Configure the Script

Open the script in a text editor to fill in your credentials and paths. You can use:

- **Terminal** with a built-in editor:
```zsh
nano ~/abm-warranty/warranty_wrangler.zsh
```
- **Visual Studio Code:**
```zsh
code ~/abm-warranty/warranty_wrangler.zsh
```
- **CodeRunner** — open the file from the working directory

Find the configuration block near the top of the script:

```zsh
# ---------- Configuration (edit these) ---------------------------------------
ABM_PRIVATE_KEY_PATH="/path/to/private-key.pem"
ABM_CLIENT_ID="BUSINESSAPI.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
ABM_KEY_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
OUTPUT_DIR="."
COMPUTER_FILENAME="ComputerTemplate.csv"
MOBILE_FILENAME="MobileDeviceTemplate.csv"
FAILED_FILENAME="failed_coverage.csv"
ASM_MODE=false
RATE_LIMIT_DELAY=0.3
PAGE_FETCH_DELAY=2
CURL_CONNECT_TIMEOUT=15
CURL_MAX_TIME=60
```

Replace each placeholder with your actual values:

| Variable | What to enter |
|---|---|
| `ABM_PRIVATE_KEY_PATH` | Full path to your `.pem` file, e.g. `/Users/yourname/abm-warranty/private-key.pem` |
| `ABM_CLIENT_ID` | The Client ID from your ABM or ASM API account |
| `ABM_KEY_ID` | The Key ID from your ABM or ASM API account |
| `OUTPUT_DIR` | Path to the folder where CSVs should be saved, e.g. `/Users/yourname/abm-warranty` |
| `COMPUTER_FILENAME` | Name for the Mac CSV file (default: `ComputerTemplate.csv`) |
| `MOBILE_FILENAME` | Name for the mobile device CSV file (default: `MobileDeviceTemplate.csv`) |
| `ASM_MODE` | Set to `true` if using Apple School Manager, leave as `false` for Apple Business Manager |
| `RATE_LIMIT_DELAY` | Pause in seconds between per-device coverage API calls (default: `0.3`) |
| `PAGE_FETCH_DELAY` | Pause in seconds between page-level device list fetches (default: `2`) |
| `FAILED_FILENAME` | Name of the file listing devices whose coverage lookup failed (default: `failed_coverage.csv`) |
| `CURL_CONNECT_TIMEOUT` | Seconds to wait for a connection before giving up (default: `15`) |
| `CURL_MAX_TIME` | Maximum seconds for any single request (default: `60`) |

Save and close the file when done.

---

## Step 6 — Run the Script

### Running from Terminal

Navigate to your working directory and run the script:

```zsh
cd ~/abm-warranty
./warranty_wrangler.zsh
```

For Apple School Manager, pass the `--asm` flag:

```zsh
./warranty_wrangler.zsh --asm
```

All configurable options are also available as flags:

```zsh
./warranty_wrangler.zsh \
  --key /path/to/private-key.pem \
  --client-id BUSINESSAPI.xxxx \
  --key-id xxxx \
  --outdir /path/to/output \
  --computer-file MyMacs.csv \
  --mobile-file MyMobileDevices.csv \
  --delay 0.5 \
  --page-delay 3
```

#### Flag Reference

| Flag | Description | Default |
|---|---|---|
| `--key` | Path to the `.pem` private key file | Value in config block |
| `--client-id` | ABM/ASM API Client ID | Value in config block |
| `--key-id` | ABM/ASM API Key ID | Value in config block |
| `--outdir` | Directory to write CSV files to | `.` (current directory) |
| `--computer-file` | Filename for the Mac CSV | `ComputerTemplate.csv` |
| `--mobile-file` | Filename for the mobile device CSV | `MobileDeviceTemplate.csv` |
| `--asm` | Use Apple School Manager endpoints instead of ABM | Off (ABM mode) |
| `--delay` | Seconds to wait between per-device coverage API calls | `0.3` |
| `--page-delay` | Seconds to wait between page-level device list fetches | `2` |
| `--help`, `-h` | Print the script header documentation and exit | — |

> **Tip:** If you're hitting rate limits (HTTP 429 errors), try increasing `--page-delay` to `3` or `4`. If individual device coverage calls are also being throttled, increase `--delay` to `0.5` or higher.

### Running from CodeRunner

If you prefer to run the script directly in CodeRunner, configure everything in the configuration block at the top of the script rather than using flags. Set `ASM_MODE=true` to run against Apple School Manager, or leave it as `false` for Apple Business Manager. No flags are needed.

The script will print its progress as it runs, showing each page of devices fetched and a count of new vs. skipped devices per page.

---

## What the Script Does

### Two separate output files

The script separates devices into two CSV files:

- **ComputerTemplate.csv** — contains all Mac computers found in ABM or ASM
- **MobileDeviceTemplate.csv** — contains all other Apple devices: iPhones, iPads, Apple TVs, iPod touches, Apple Vision Pro, and any other non-Mac products

Each row is written to disk immediately as it is processed, so if the script is interrupted, any data already fetched is preserved.

### Fields populated

Both files include the following fields for each device (all other columns are left blank):

| Field | Source |
|---|---|
| Serial Number | Device serial number from ABM/ASM |
| PO Number | Order number from ABM/ASM device record |
| Vendor | Purchase source from ABM/ASM device record |
| Purchase Price | Not available in the API — always blank |
| PO Date | Order date from ABM/ASM (date only) |
| Warranty Expires | AppleCare+ expiration if active, otherwise Limited Warranty end date |
| AppleCare ID | AppleCare agreement number, if the device has AppleCare coverage |

### AppleCare+ support

The **Warranty Expires** field prioritizes the AppleCare+ expiration date when a device has active AppleCare+ coverage. If no active AppleCare+ coverage exists, it falls back to the standard Limited Warranty end date. This means the field always reflects the longest applicable coverage window for each device.

> **Note:** If you previously ran the script before AppleCare+ support was added, existing devices in your CSVs will still have the old Limited Warranty dates. To re-fetch corrected dates for those devices, delete or rename your existing CSV files and run the script again so all devices are treated as new.

### Coverage failures are retried, not silently recorded

If a device's coverage lookup fails, the script does **not** write a partial row. Writing one would put the serial into the CSV with a blank Warranty Expires, and incremental mode would then treat that device as already done and skip it on every future run — turning a momentary API hiccup into permanently missing warranty data. Instead the serial, product family, and HTTP status are appended to `failed_coverage.csv`, and the device is retried automatically on the next run.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Run completed; every device encountered was either written or already present |
| `1` | Setup/auth error, **or** the run finished with one or more devices in `failed_coverage.csv` |

A non-zero exit on a partial run makes the script safe to schedule with launchd, a Jamf policy, or CI — a run that skipped devices no longer reports success.

### Incremental updates

The script is designed to be run repeatedly as new devices are added to ABM or ASM. When run again:

- If the output CSV files already exist at the configured paths, the script reads the serial numbers already present in each file
- It then compares those against all devices currently in ABM/ASM
- Only **new devices** not already in the CSV are fetched and appended — existing rows are never modified
- If no new devices are found, the script exits with a clear message confirming that both files are already up to date

This means you can run the script on a regular schedule and the CSVs will grow over time to reflect your fleet without duplication.

### Rate-limiting and retries

The Apple API enforces rate limits on requests. The script handles this in several ways:

- **Page-level throttling** — a configurable delay (`PAGE_FETCH_DELAY`, default 2 seconds) is applied between each page of devices fetched from the API. When an entire page of devices is skipped (already in CSV), an additional delay is added since no per-device coverage calls provide natural spacing.
- **Per-device throttling** — a configurable delay (`RATE_LIMIT_DELAY`, default 0.3 seconds) is applied between each individual device coverage API call.
- **Automatic retries** — both page fetches and per-device coverage calls will retry up to 3 times on HTTP 429 (rate limited) responses, with increasing back-off. The `Retry-After` header is honored when the server provides one.
- **Early exit** — on incremental runs, if the number of known serials already matches the total device count reported by the API, the script exits immediately without fetching any pages.
- **Automatic token refresh** — the bearer token is valid for approximately 1 hour. Once it reaches ~50 minutes the script mints a fresh one and carries on, so a run is never cut short by token expiry. Expiry is checked both between pages and before each individual coverage call, since a single page can take long enough to outlive the token on its own.
- **Request timeouts** — every API call is bounded by `CURL_CONNECT_TIMEOUT` and `CURL_MAX_TIME`, so a stalled connection cannot hang the run indefinitely.

---

## Apple School Manager vs. Apple Business Manager

The script supports both platforms. The API endpoints and OAuth scope differ between ABM and ASM — the script handles this automatically based on the `--asm` flag or the `ASM_MODE` variable.

| | ABM | ASM |
|---|---|---|
| Client ID prefix | `BUSINESSAPI.` | `SCHOOLAPI.` |
| API base URL | `api-business.apple.com` | `api-school.apple.com` |
| OAuth scope | `business.api` | `school.api` |
| Flag / variable | default | `--asm` or `ASM_MODE=true` |

Both platforms use the same private key format, authentication flow, device data structure, and coverage endpoints — only the two values above differ.

---

## Using the CSVs with MUT

The generated CSV files are formatted to match MUT's default templates exactly — the column headers and order are identical to what MUT expects out of the box.

To import into Jamf Pro using MUT:

1. Open **MUT** and connect to your Jamf Pro server
2. For Mac warranty data, select **Computers** and import `ComputerTemplate.csv`
3. For mobile device and Apple TV warranty data, select **Mobile Devices** and import `MobileDeviceTemplate.csv`
4. MUT will match each row to the device by serial number and update only the fields that have values — blank columns in the CSV are ignored

> **Note:** MUT updates records by matching the serial number column. Devices in the CSV that do not exist in Jamf Pro will be skipped by MUT without causing errors.

---

## Customizing Output Filenames

If you want to use different filenames for the generated CSVs — for example, to include a date or distinguish between environments — you can pass them as flags when running the script:

```zsh
./warranty_wrangler.zsh \
  --computer-file "Macs_$(date +%Y-%m-%d).csv" \
  --mobile-file "Mobile_$(date +%Y-%m-%d).csv"
```

You can also change `COMPUTER_FILENAME` and `MOBILE_FILENAME` directly in the configuration block at the top of the script.

> **Note:** If you change the filename between runs, the script will not recognize the old file and will treat all devices as new. Use consistent filenames across runs to take advantage of the incremental update behavior.

---

## Troubleshooting

**"Private key not found"** — double-check that `ABM_PRIVATE_KEY_PATH` points to the exact location of your `.pem` file, including the filename and extension.

**"Token request failed"** — verify that your `ABM_CLIENT_ID` and `ABM_KEY_ID` match exactly what is shown in the API account management screen. Both values are case-sensitive. If using ASM, confirm that `ASM_MODE=true` is set or the `--asm` flag was passed — using a `SCHOOLAPI.` Client ID without ASM mode enabled will cause an auth failure.

**"jq not found"** — install jq with `brew install jq` and re-run the script.

**Frequent HTTP 429 (rate limited) errors** — increase the delay between requests by passing `--page-delay 4` and/or `--delay 0.5`. The default values (`PAGE_FETCH_DELAY=2`, `RATE_LIMIT_DELAY=0.3`) work well for most environments, but organizations with very large device counts or shared API rate limits may need higher values.

**Run takes longer than an hour** — this is handled automatically. The bearer token is valid for about 1 hour, and the script refreshes it in place once it reaches ~50 minutes, so long runs complete in a single pass. Earlier versions exited at ~58 minutes and had to be re-run.

**Devices listed in `failed_coverage.csv`** — these are devices whose AppleCare coverage lookup did not return successfully (a timeout, a 5xx, or an auth failure). They are deliberately **not** written to the CSVs, because a row with a blank Warranty Expires would be treated as complete by incremental mode and skipped on every later run. Simply run the script again — because they are absent from the CSVs, they are picked up and retried. The file is rewritten only on a run that has failures, so a leftover file from an earlier run is reported as stale in the summary.

**Warranty fields are blank in Jamf after MUT import** — confirm that the column headers in the CSV match the field names in Jamf Pro exactly. The script uses MUT's default column names, so no changes should be needed on a standard Jamf setup.

**Warranty Expires shows the 1-year date instead of AppleCare+** — this means the device either does not have AppleCare+ coverage, or the coverage entry in ABM/ASM does not have a status of `ACTIVE`. The script falls back to the Limited Warranty date in both cases.
