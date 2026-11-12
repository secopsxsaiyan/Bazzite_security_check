# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.4.0] - 2026-11-12

### Changed

- A check's page is a Kirigami window in the wizard's style: what the
  check saw, and each finding as a card with the setting now and after the
  fix, what it affects on Bazzite, its side effects and the manual steps
  (long details fold out). Every finding that can be fixed has its own
  tick box, with Select all.
- Choosing what a fix changes (Flatpak apps, firewall ports and services,
  containers, layered packages, SUID files, the fix list) is a Kirigami
  window: each item has its own tick box, a risk (low, medium, high) and a
  warning in its own words, with Select all, Select none and Low risk only.
  A port that belongs to a feature this PC uses is high risk and starts
  unticked; unticking a service the PC uses in the firewall list warns.
- Confirming a fix is a Kirigami window too: now and after, what it
  affects, side effects, the exact commands and whether it can be undone.
- Every other dialog (messages, questions, errors, the fix summary, the
  undo and preset lists) is a Kirigami window in the same style; kdialog and
  the terminal stay as fallbacks.
- Layered packages show what each package is and are high risk when one of
  its services runs now (or for drivers, ClamAV, LACT, ...); firewall ports
  say what they are usually for (a dev web server, PostgreSQL, a game
  server, ...).
- Closing the confirm window skips that fix (it no longer ends the review).
- The fix list only offers "Low risk only" where a tick means a change; the
  firewall list (where a tick keeps something open) has no such button.
- The kdialog and terminal versions show each item's risk and warning in
  its line.

### Fixed

- "Open the full report" did nothing: the browser was started without the
  desktop session's variables (and without Flatpak apps on its path), so no
  browser was found. It now opens, and says where the report is if it
  cannot.

### Changed (report)

- The HTML report starts with "What to do next" (each open problem with the
  one thing to do: fix it in the app, or the first manual step), then the
  findings grouped as Needs attention, Worth a look, Notes and Fixed. Long
  lists fold, manual steps fold, and a bar links to each part.
- Dashboard: a cut-off "In use here" line shows in full as a tooltip; a
  check with only medium problems reads orange, not red.
- Kept list: names every feature of the kept entries, says when a problem
  came back because a new port opened, and no longer shows an empty date.

## [1.3.0] - 2026-11-12

### Added

- Every finding and fix names the Bazzite features it affects (Steam Remote
  Play, Sunshine, KDE Connect, SSH, file sharing, game servers, Docker and
  containers, anti-cheat, hibernation, game performance, Flatpak apps, ...),
  how the fix touches each one (stops it, changes it, you choose in the
  fix, or helps it) and whether this PC uses it ("in use here: Steam is
  installed"). Shown in the fix list, the Apply dialog, each check's page,
  the dashboard rows and the report. Suggested by a user who wanted that
  context before touching a setting kept for Steam Remote Play.
- A fix that would stop a feature this PC uses starts unticked in the fix
  list.
- Kept on purpose: the dashboard lists the problems whose fix would stop a
  feature you use; a kept problem no longer lowers the score and is not
  offered as a fix from the next check on. Untick it to count it again.
  The list is in `/var/lib/bazzite-sec-audit/kept` (root only).

## [1.2.0] - 2026-11-12

### Changed

- The project moved to
  [secopsxsaiyan/Bazzite_security_check](https://github.com/secopsxsaiyan/Bazzite_security_check).
  Releases are published there and signed with a new release key
  (`release-signers`). Copies of 1.1.0 trust the earlier key and look for
  updates in the old repository, so install 1.2.0 once by hand (see the
  README); later updates then come through Settings → Updates.
- The dashboard after the checks is a Kirigami window in the wizard's
  style: a score ring with the grade, the PC and open findings by
  severity, a coloured pill per area, notices (reboot needed, fixed in this
  run, since the last check, report only), action buttons (review and fix,
  open the report, undo, settings) and the checks grouped by area with
  their state and summary. Its answer is validated before use; the kdialog
  list stays as the fallback.
- While checks run (and while a fix is applied), a Kirigami progress window
  matching the wizard replaces the kdialog progress bar, with the app icon
  in the system tray. Closing or hiding it lets the work go on; the tray
  icon shows the progress.
- The progress bar counts finished checks and goes up to 90% while checks
  run, so it never reads 100% while one is still running. The malware scan
  (ClamAV) holds at 90% with a spinner and a note that it can take several
  minutes; 100% comes when everything is done.

## [1.1.0] - 2026-11-11

### Added

- A modern Kirigami front end (PySide6 + Kirigami, both part of Bazzite's
  KDE images) for the setup wizard and the new Settings window: a step
  indicator, cards with switches for how the PC is used (with a "Detected"
  badge), a review page, and Back/Next navigation. It runs as the desktop
  user; the administrator side only accepts answers it can validate. Where
  PySide6 or Kirigami are missing, the kdialog wizard is used as before.
- Settings (wizard welcome page, dashboard, or `--settings`): the theme of
  Security Check's windows (follow the system, light or dark - also applied
  to the kdialog dialogs), and an optional update check at start.
- Updates from GitHub releases (Settings → Updates, or `--update`): the
  release archive is installed as the app only when the SSH signature over
  its SHA256SUMS verifies against the release key that ships with the tool
  (`release-signers`) and the archive matches its checksum. A release
  workflow publishes each `vX.Y.Z` tag with the archive, SHA256SUMS and the
  signature.
- An app icon, used in the application menu, the window title bar and a
  system tray icon that shows the progress while a check runs.

- When the PC is used for gaming, a new check (Anti-cheat readiness) looks
  for the two kernel settings Easy Anti-Cheat for Linux v2 needs that
  Bazzite leaves off: kernel lockdown in integrity mode and kexec disabled
  (what `ujust check-anticheat` reports as FAIL). The fix adds
  `sysctl.kernel.kexec_load_disabled=1`, and `lockdown=integrity` only when
  Secure Boot is on (otherwise it asks for Secure Boot first, since without
  it MOK-signed drivers could stop loading), to the kernel arguments (after
  a reboot) and warns what lockdown blocks:
  unsigned modules, hibernation, and tools that write CPU registers or raw
  memory. Arguments already set are reported as waiting for a reboot.
- `--install` installs the tool as an app: "Security Check" in every user's
  application menu (with an Undo action) and the `bazzite-sec-audit`
  command. Both run a root-owned copy in `/usr/local/libexec`, and ask for
  the administrator password when started. Run `--install` again after an
  update; `--uninstall` removes it. `--install-launcher` now does the same:
  its per-user entry ran the tool as root from a home folder, and an older
  entry is removed because it would hide the app's.
- The "services reachable from your network" finding has a fix when the
  firewall zone opens those ports by itself: it closes them (now and
  permanently, without a reload), and the undo opens them again.
- A new info finding lists ports a firewall zone opens while nothing listens
  on them, with the same fix.

### Changed

- Containers reachable from the network (Docker and rootful Podman) can now
  be fixed by the tool, one checklist item per container. Compose services
  (Docker Compose and podman-compose, including its podman-compose@ units
  and relative file names) get `127.0.0.1:` added to their port lines in
  every compose file of the project, edited as the files' owner, and are
  recreated with the owner's HOME and the project's env file by a compose
  program installed for the whole system (Docker with a root-only
  `DOCKER_CONFIG`). A plain `podman run` container is stopped and kept as
  `NAME-before-fix` (restart policy off) while a new one runs with the same
  options. Every picked container is checked before anything changes and
  every recreate is checked afterwards (running, no all-interface port).
  The undo only touches what the fix got to: the kept container is put back
  only when it is the original (same ID), and a compose service is
  recreated only when the fix reached its `up`. Cases the tool cannot repeat safely stay manual with
  the reason: anonymous volumes, `--rm`, pods, `-P`, a bare `-p PORT`, port
  ranges, combined flags, no `--name`, relative paths, env files and `-e`
  without a value, `~` or shell variables in the compose file, ports in
  other compose forms (including IPv6), and systemd/Quadlet containers.
- The Flatpak sandbox fix grades every app by how likely the change breaks
  it (low, medium or high, with the reason), lists low-risk apps first, and
  starts from a choice: low-risk apps only (recommended), all, or none.
  "All files" (`host`) becomes the home folder in the same mode, so
  viewers, players and office apps keep opening your files; `host-os` and
  `host-etc` (system folders only) are removed without adding home. A system
  app the desktop user also overrides (Flatseal) is restricted in that user
  override too, since it wins over the system one.
- Commands shown before a fix wrap long lines at spaces (marked ↵), so the dialog
  stays on screen instead of growing wider than it and hiding its text.
- `/etc` changes compared with the image are split by area, one finding
  each with a risk grade (high: sudo, login/PAM, polkit, SSH server, boot
  and kernel modules, services and timers, program loader and shell
  startup, software sources, device rules; medium: network/DNS/firewall,
  kernel/audit/crypto; low: everything else), high risk first, one file
  per line ("added: /etc/...").
- The setup wizard looks and flows like a Plasma setup assistant. Each page
  starts with a small "STEP 1 OF 4 · YOUR PC" line, a large title and a
  one-line subtitle, in the default text colour so it reads the same in Breeze
  Light and Dark. Option labels are short enough not to be cut off, and the
  review page has **Change answers…**, which goes back to step 1. The last
  score is shown in its grade's colour. On a terminal, Enter on the review
  page still starts the check.

### Fixed

- The manual LLMNR instructions name the drop-in file the fix writes
  (`90-bazzite-sec-audit.conf`).
- Removing the weekly check keeps the installed copy while the app uses it,
  and the other way round.
- Fixes get their arguments exactly as the check gave them again. Arguments
  with spaces were split, so the sudo fix commented a rule out instead of
  changing `NOPASSWD:` to `PASSWD:`, and several other fixes failed.
- Fix scripts run with umask 022, so the files they create (the LLMNR
  drop-in, Flatpak overrides and updates) are readable by the services and
  accounts that use them.
- A fix is not run when no private temporary folder is available, instead of
  using a guessable file name in `/tmp`.
- The error dialog, the fix list's text and the fix summary are as they were
  before (line breaks, escaping, the undo hint).
- A password typed on the terminal keeps its leading and trailing spaces.

### Security

- Files in home folders (screen lock settings, SSH keys, credential files,
  `.env` files, autostart entries, Sunshine and Flatpak settings) are read as
  the account that owns the home, never as root.
- ClamAV runs as the account whose folders it scans, not as root.
- Programs run as another account no longer share the administrator's
  terminal.
- Paths found by the deep sweeps are read NUL-separated; a line break in a
  file name cannot make another path appear in a finding or a fix.
- Repository section names, file names and existing sysctl lines are quoted
  in generated fix scripts.
- `--install-timer` copies files, not links, to the root-owned folder.
- The weekly check hands its report only to an administrator's session.
- A note is printed when the test settings (`AUDIT_ROOT`, ...) are active.

### Added

- sudo rules that allow every command with exclusions, or a shell-capable
  command (`env`, `bash`, `python`, ...), without a password are findings.
- System accounts with an empty password are findings.
- A signed image whose `policy.json` entry accepts anything is a finding.

## [1.0.0] - 2026-11-04

First release.

### Added

- A KDE wizard (or terminal prompts with `--no-gui`) that asks how the PC is
  used, pre-selected from what is installed, and remembers the answers.
- 23 standard checks across the system image, apps, boot and kernel,
  network, accounts, desktop, and dev and gaming tools, plus 5 deep sweeps
  (`--deep`): SUID/SGID files, world-writable files, autostart entries,
  `/etc` changes compared with the image, and a ClamAV scan.
- A dashboard with the score, a status per area and per check, and the
  settings each check saw.
- A fix checklist, most severe first. Each fix shows the setting now and
  after, its side effects and its exact commands, runs only after
  **Apply**, is checked again afterwards, and records an undo step.
- `--undo`, and a per-run `undo-all.sh`, to reverse applied fixes newest
  first.
- HTML and Markdown reports in the user's Documents folder, with what
  changed since the last check.
- `--install-launcher` for a menu entry, and `--install-timer` for a weekly
  report-only check with a desktop notification.
- `make lint` (ShellCheck) and `make test` (a simulated Bazzite PC with
  stubbed tools), run by GitHub Actions on every push and pull request.

### Security

- Root never writes reports, restores backups or runs an undo step through
  a symlink in a user's folder. Changes to `sshd` and `sudoers` are
  validated and rolled back if they fail.

[Unreleased]: https://github.com/secopsxsaiyan/Bazzite_security_check/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/secopsxsaiyan/Bazzite_security_check/releases/tag/v1.4.0
[1.3.0]: https://github.com/secopsxsaiyan/Bazzite_security_check/releases/tag/v1.3.0
[1.2.0]: https://github.com/secopsxsaiyan/Bazzite_security_check/releases/tag/v1.2.0
[1.1.0]: https://github.com/secopsxsaiyan/bazzite-sec-audit/releases/tag/v1.1.0
[1.0.0]: https://github.com/secopsxsaiyan/bazzite-sec-audit/releases/tag/v1.0.0
