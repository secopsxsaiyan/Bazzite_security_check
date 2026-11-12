# Bazzite Security Check

**A security check-up for a Bazzite home gaming and development desktop.**

A KDE wizard asks how you use the PC. The checks then adapt to that and to what is actually installed, and a dashboard shows the result of every check. You pick fixes from a checklist; each one shows the setting now and after the fix, its side effects and its exact commands, runs only after you confirm it, is checked again afterwards, and can be undone later.

It is a desktop-friendly counterpart to [ubuntu-sec-audit](https://github.com/secopsxsaiyan/ubuntu-sec-audit), which audits servers against NIST/CIS. This tool leaves out server rules that cost more than they protect on a personal machine, and it never applies a change in bulk.

## Privacy and report sharing

Reports can contain hostnames, usernames, filesystem paths, service names, firewall rules, and other sensitive local details. Before you post a report or attach it to an issue, review it and redact anything you do not want to share publicly.

- Do not attach raw reports to public issues unless they are redacted.
- If you are reporting a bug, include only the smallest relevant excerpt.
- See [SECURITY.md](SECURITY.md) for private vulnerability reporting.

## Quick start

```bash
git clone https://github.com/secopsxsaiyan/Bazzite_security_check.git ~/bazzite-sec-audit
~/bazzite-sec-audit/bazzite-sec-audit.sh
```

### Install it as an app

```bash
~/bazzite-sec-audit/bazzite-sec-audit.sh --install
```

This adds **Security Check** to the application menu (System) and the
`bazzite-sec-audit` command for every user on the PC. When you start it, KDE
asks for your administrator password, then the check-up runs as usual. The app
runs a copy owned by root in `/usr/local/libexec/bazzite-sec-audit`, so nothing
running as you can change what later runs as administrator. To update it,
install updates from Settings → Updates (or `--update`): a new release is
installed only after its signature and checksums are verified. `--uninstall`
removes the app; reports, history and undo steps are kept.

The setup wizard and Settings use a Kirigami (Plasma) window when PySide6 and
Kirigami are installed, as on Bazzite's KDE images; Settings chooses the theme
of Security Check's windows (follow the system, light or dark).

For a background check once a week (report only, with a notification), add
`--install-timer`.
