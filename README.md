# ABM Warranty Report — Setup & Usage Guide

This guide walks through everything needed to run `abm_warranty_report.zsh`, a script that pulls warranty and AppleCare coverage data from Apple Business Manager (ABM) and produces CSV files ready for import into the Mass Update Tool (MUT).

---

## Prerequisites

- A Mac running macOS
- Administrator access to Apple Business Manager
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

## Step 2 — Create an API Account in Apple Business Manager

> **Note:** You must have the **Administrator** role in ABM to complete this step.

1. Sign in to [Apple Business Manager](https://business.apple.com).
2. Select your **name** at the bottom of the sidebar, then select **Preferences**.
3. Select **API** from the preferences panel.
4. Select **Get Started**, enter a name for the account (e.g., `Warranty Report`), then select **Create**.
5. Select **Generate Private Key**. A `.pem` file will automatically download to your browser's download location.
6. Select **Manage** on the newly created API account and note the following two values — you will need them when configuring the script:
   - **Client ID** — looks like `BUSINESSAPI.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
   - **Key ID** — looks like `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

> **Important:** The `.pem` file can only be downloaded once. If it is lost, you will need to revoke the key and generate a new one. Store it securely.

For full details on this process, refer to Apple's official documentation:
[Create an API account in Apple Business Manager](https://support.apple.com/guide/apple-business-manager/create-an-api-account-axm33189f66a/web)

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

Move or copy `abm_warranty_report.zsh` into the same working directory:

```zsh
mv ~/Downloads/abm_warranty_report.zsh ~/abm-warranty/
```

Then make it executable:

```zsh
chmod +x ~/abm-warranty/abm_warranty_report.zsh
```

---

## Step 5 — Configure the Script

Open the script in a text editor to fill in your credentials and paths. You can use:

- **Terminal** with a built-in editor:
  ```zsh
  nano ~/abm-warranty/abm_warranty_report.zsh
  ```
- **Visual Studio Code:**
  ```zsh
  code ~/abm-warranty/abm_warranty_report.zsh
  ```
- **CodeRunner** (or any other editor of your choice) — open the file from the working directory

Find the configuration block near the top of the script — it looks like this:

```zsh
# ---------- Configuration (edit these) ---------------------------------------
ABM_PRIVATE_KEY_PATH="/path/to/private-key.pem"
ABM_CLIENT_ID="BUSINESSAPI.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
ABM_KEY_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
OUTPUT_DIR="."
COMPUTER_FILENAME="ComputerTemplate.csv"
MOBILE_FILENAME="MobileDeviceTemplate.csv"
```

Replace each placeholder with your actual values:

| Variable | What to enter |
|---|---|
| `ABM_PRIVATE_KEY_PATH` | Full path to your `.pem` file, e.g. `/Users/yourname/abm-warranty/private-key.pem` |
| `ABM_CLIENT_ID` | The Client ID from your ABM API account |
| `ABM_KEY_ID` | The Key ID from your ABM API account |
| `OUTPUT_DIR` | Path to the folder where CSVs should be saved, e.g. `/Users/yourname/abm-warranty` |
| `COMPUTER_FILENAME` | Name for the Mac CSV file (default: `ComputerTemplate.csv`) |
| `MOBILE_FILENAME` | Name for the mobile device CSV file (default: `MobileDeviceTemplate.csv`) |

Save and close the file when done.

---

## Step 6 — Run the Script

In Terminal, navigate to your working directory and run the script:

```zsh
cd ~/abm-warranty
./abm_warranty_report.zsh
```

The script will print its progress as it runs, showing each page of devices fetched and a count of new vs. skipped devices per page.

---

## What the Script Does

### Two separate output files

The script separates devices into two CSV files:

- **ComputerTemplate.csv** — contains all Mac computers found in ABM
- **MobileDeviceTemplate.csv** — contains all other Apple devices: iPhones, iPads, Apple TVs, iPod touches, Apple Vision Pro, and any other non-Mac products

Each row is written to disk immediately as it is processed, so if the script is interrupted, any data already fetched is preserved.

### Fields populated

Both files include the following fields for each device (all other columns are left blank):

| Field | Source |
|---|---|
| Serial Number | Device serial number from ABM |
| PO Number | Order number from ABM device record |
| Vendor | Purchase source from ABM device record |
| Purchase Price | Not available in the ABM API — always blank |
| PO Date | Order date from ABM (date only) |
| Warranty Expires | Limited Warranty end date from ABM |
| AppleCare ID | AppleCare agreement number, if the device has AppleCare coverage |

### Incremental updates

The script is designed to be run repeatedly as new devices are added to ABM. When run again:

- If the output CSV files already exist at the configured paths, the script reads the serial numbers already present in each file
- It then compares those against all devices currently in ABM
- Only **new devices** that are not already in the CSV are fetched and appended — existing rows are never modified
- If no new devices are found, the script exits with a clear message confirming that both files are already up to date

This means you can run the script on a regular schedule and the CSVs will grow over time to reflect your fleet without duplication.

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
./abm_warranty_report.zsh \
  --computer-file "Macs_$(date +%Y-%m-%d).csv" \
  --mobile-file "Mobile_$(date +%Y-%m-%d).csv"
```

You can also change `COMPUTER_FILENAME` and `MOBILE_FILENAME` directly in the configuration block at the top of the script.

> **Note:** If you change the filename between runs, the script will not recognize the old file and will treat all devices as new. Use consistent filenames across runs to take advantage of the incremental update behavior.

---

## Troubleshooting

**"Private key not found"** — double-check that `ABM_PRIVATE_KEY_PATH` points to the exact location of your `.pem` file, including the filename and extension.

**"Token request failed"** — verify that your `ABM_CLIENT_ID` and `ABM_KEY_ID` match exactly what is shown in the ABM API account management screen. Both values are case-sensitive.

**"jq not found"** — install jq with `brew install jq` and re-run the script.

**Warranty fields are blank in Jamf after MUT import** — confirm that the column headers in the CSV match the field names in Jamf Pro exactly. The script uses MUT's default column names, so no changes should be needed on a standard Jamf setup.
