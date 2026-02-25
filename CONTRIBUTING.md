# Contributing to ABM Warranty Recon

Thank you for your interest in contributing! This project is a zsh-based tool for Mac administrators that pulls warranty and AppleCare coverage data from Apple Business Manager and formats it for use with the Mass Update Tool (MUT) in Jamf Pro.

Contributions of all kinds are welcome — bug fixes, improvements, documentation updates, and feature suggestions.

---

## Getting Started

1. **Fork the repository** by clicking the Fork button at the top right of the repo page
2. **Clone your fork** to your local machine:
   ```zsh
   git clone https://github.com/your-username/ABM-Warranty-Recon.git
   ```
3. **Create a new branch** for your change — do not work directly on `main`:
   ```zsh
   git checkout -b your-branch-name
   ```
4. Make your changes, test them against a real or simulated ABM environment, then commit:
   ```zsh
   git add .
   git commit -m "Brief description of what you changed"
   ```
5. Push your branch to your fork:
   ```zsh
   git push origin your-branch-name
   ```
6. Open a **Pull Request** against the `main` branch of this repository

---

## Reporting Bugs

If you run into a problem, please open an [Issue](https://github.com/brndnwds6/ABM-Warranty-Recon/issues) and include:

- macOS version
- What you ran and the full terminal output
- What you expected to happen vs. what actually happened
- Any relevant details about your ABM setup (number of devices, API account status, etc.)

Please **do not** include your Client ID, Key ID, private key, or any other credentials in issues or pull requests.

---

## Suggesting Features

Feature requests are welcome. Open an [Issue](https://github.com/brndnwds6/ABM-Warranty-Recon/issues) with a description of what you'd like to see and why it would be useful. If you're planning to build it yourself, mention that so work isn't duplicated.

---

## Code Guidelines

This project is a single zsh script. Please keep contributions consistent with the existing style:

- Use **camelCase** for variable names
- Include **comments** explaining non-obvious logic
- Keep error messages descriptive and actionable
- Test any changes against both the computer and mobile device code paths
- Do not hardcode credentials, paths, or environment-specific values — all configuration should remain in the config block at the top of the script
- If your change affects CSV column output, verify the column positions still align with MUT's default templates before submitting

---

## Pull Request Checklist

Before submitting a pull request, please confirm:

- [ ] Tested on macOS with a real or simulated ABM API response
- [ ] No credentials, private keys, or personal information included
- [ ] Code follows the existing style and variable naming conventions
- [ ] CSV output columns verified against MUT templates (if applicable)
- [ ] PR description explains what changed and why

---

## Questions

If you have a question that doesn't fit an issue, feel free to open a Discussion or reach out via the Issues tab.

---

*Maintained by [Brandon Woods](https://github.com/brndnwds6)*
