# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.6.0] - 2026-11-21

### Added

- An off-screen test of the real windows, `make test-ui`
  (`tests/ui-offscreen.py`): it shows every page in the real front end,
  answers it with the keyboard and the mouse, through every button, row and
  tick box, and checks each answer line; a QML warning fails it. CI runs it
  as the new "UI test" job, in a Fedora container.
- `docs/ui.md` describes the front end for developers: the protocol between
  the root side and the window, what a page is, and how to add one.
- Installing the app (`--install`) offers to add what Security Check's
  window needs when it is missing: `python3-pyside6` (Bazzite's KDE images
  have Kirigami but not PySide6) and, if needed, Kirigami, with the Qt
  libraries they need. On Bazzite and other Fedora Atomic images they are
  layered with rpm-ostree and used after the next restart; on Fedora they
  come from dnf. The question is a change to the PC: Enter answers "Not
  now", and with nobody to answer (or a dialog that fails) nothing is added.
  An app installed or updated by an older version asks once when a check-up
  starts with KDE dialogs (not in a report-only run; again after a failed
  install). `--uninstall` offers to remove what was added (default: keep
  it); with dnf, not when other installed programs need it. When removing
  them fails, the app stays installed unless "Remove anyway" is chosen,
  and `--uninstall` then ends with status 1. The check-up's fix that
  removes layered packages marks these two as high risk on KDE and says that
  without them Security Check goes back to plain KDE dialogs (only for a
  package that is really layered: a request for one the image already has
  changes nothing when removed).
- `tests/ui-offscreen.py --shots DIR readme` renders the README's
  screenshots from the sample data, in the dark theme; they show the
  current window, and a fix to confirm with its commands is new.

### Changed

- The deep check's malware scan helps set ClamAV up instead of only
  skipping. When ClamUI is installed but the system's ClamAV is not (ClamUI
  scans with it), when freshclam is missing, or when there are no or only
  old virus definitions, the check says so and offers a fix: on Bazzite it
  layers ClamAV with rpm-ostree, and it downloads the definitions and turns
  on their automatic update (clamav-freshclam.service). A scan stopped by
  the time limit now says that, instead of blaming the virus database, and
  the scan no longer follows other drives or app images mounted inside the
  scanned folders.
- Extra virus signature sources in freshclam.conf (DatabaseCustomURL): when
  freshclam's log shows that one can no longer be downloaded, the deep check
  says so, names the sources freshclam then never reaches (it stops at a
  source that fails, unless it is only rate-limited), and offers to put a #
  in front of the failing ones. The report shows only the host and file name
  of a source, as its address can hold an access key. Downloading the
  definitions as a fix updates only ClamAV's own sets, so a broken extra
  source does not make it fail.
- The malware scan no longer says "nothing found" when ClamAV did not
  really scan. When clamscan stops with an error of its own (an option it
  does not take, no memory), when libclamav has no temporary folder to work
  in, when the scanner did not start or did not finish (no summary from
  clamscan), or when not one file could be read, the scan is reported as
  skipped, with ClamAV's message. When clamscan reports infected files
  without listing them, that is a finding. After a scan that did finish,
  the report says how many files were scanned and how many could not be
  read or scanned, from clamscan's summary, instead of a general "files
  were left out".
- Security Check now has one window for the whole run. The setup wizard, the
  dashboard, a check's page, the lists of fixes, the "Apply this fix?" page
  and Settings are pages of that window, and questions, messages and errors
  appear over the current page. Before, every page was a new window and the
  app went away between them. While the tool works between two pages (a fix
  being applied, a download) the last page stays, dimmed, with a spinner and
  what is being done. Only the scan's progress bar is still a small window of
  its own, with its tray icon.
- Every page was reworked to one layout: a header, the content, and a bar at
  the bottom with one main button that stands out. Every control can be
  reached with the keyboard and has a name for screen readers. The wizard
  has four steps (the report folder moved into Options), the check and
  "Apply this fix?" pages show what a fix affects in the same way, and texts
  are marked for translation (no translations ship yet).
- A question or message that comes before any page (for example from
  "Install", "Uninstall" or "Update" in the menu) shows as a small window of
  its own size, which grows into the main window when the first page comes.
  On the way it is never given a width or height of 0, which a Wayland
  desktop answers by closing the program.
- Closing the window answers the current page as "cancelled", as before. It
  never stops a fix that is being applied.
- Enter does the page's main action and Esc goes back or cancels on every
  page, except that Esc does nothing on the result page (going back from a
  check must not end the run) and that Enter alone never applies a fix (see
  below). Enter in a text field stays with that field,
  and Enter on a focused button presses that button. In a list of fixes
  and on the wizard's option cards, Space ticks the row or card and Enter
  goes on.
- A key or click meant for one page cannot answer the next. A page that has
  just appeared ignores keys, the buttons' Alt+letter shortcuts and clicks
  for a moment, and a key or mouse button that is still held down from the
  page before cannot answer it however long it is held: the page takes
  input once everything has been let go. A held-down key counts once, on
  the page it was pressed on.
- PageUp, PageDown, Home, End and the arrow keys scroll every page and
  dialog, so text that does not fit can be read without a mouse.
- The "Apply this fix?" page starts with the keyboard focus on no button,
  and Enter applies the fix only while the Apply button itself has the
  keyboard focus. A fix is applied by a click on Apply, by Alt+A, or by
  Enter or Space after moving to the button (Shift+Tab goes straight to
  it): an Enter or Space meant for the page before cannot apply a fix. Esc
  cancels as on every page.
- Easier to read and to use without a mouse. Coloured text (severity and
  risk labels, counts, the score, warnings, the value after a fix) is now
  dark enough to read in the light theme and the dark one; the colour stays
  in the fill, the frame and the icon. Tick boxes and the link in Settings
  show a ring when they have the keyboard focus. On the result page the
  area chips and the list of checks are one Tab stop each, and the arrow
  keys move inside them. The main button underlines its Alt key while Alt
  is held, and a button has the same Alt key on every "Apply this fix?"
  page. Screen readers get the messages in boxes and the text of a
  dialog as plain text. A dialog whose buttons do not fit next to each
  other stacks them. The control with the keyboard focus is always in view:
  a finding that is taller than the window shows its tick box and title,
  not its end. The focus ring, the placeholder of the report folder and the
  tick of a finished step are dark enough in the light theme. A card, row or
  button is read out once, not a second time label by label. Home and End
  work in a dialog's list, and a block of commands shows its cursor.
- Pages hold up with a larger font: the score ring and the step numbers grow
  with the text, a hint that has no room next to the buttons goes above
  them, and the progress window is high enough for its Hide button.
- Changing the theme in Settings switches the open window at once.
- CI uploads ShellCheck and Scorecard results to code scanning on pull
  requests, so the `Protect main` ruleset can pass without an administrator
  bypass. The ruleset and its thresholds are unchanged.

### Security

- Programs the tool starts as the desktop user (the windows, kdialog, the
  browser for the report) and the fixes it runs no longer get a copy of the
  run's lock. Such a program could release the lock while the run was going
  on, or keep it after the run, so that the next one stopped with "Another
  security check is already running".
- The run log is never handed to a program of another account. What the
  window and an undo step print is copied into the log by the tool itself,
  cut to size: at most 256 KiB from the window, and the end of an undo
  step's output (where the reason for a failure is) rather than all of it.
- When the tool closes its window it signals only processes it has checked
  to be the ones it started (by process id and start time), and the window's
  own processes are signalled as the desktop user, not as root. A process
  that merely got the same id later cannot be hit.
- The tool no longer waits for ever on a window that has gone: one that
  ended while a program it started still held one of its pipes or kept
  writing. It carries on with KDE dialogs. When the tool ends, also after
  Ctrl-C pressed twice, a window that hangs or is stopped does not hold it
  up: it always removes its private folder and gives up its lock.
- A stray Enter or Space can no longer start a change in a question window.
  Where "Yes" changes the PC there and then (applying a fix in the plain
  dialog, each undo step, "Undo anyway", rolling back a failed fix, install,
  remove, update), no button or the "No" button is the one Enter presses.
  kdialog presses its first button (its "Yes" place) on Enter in every
  question, warnings included, and cannot be told otherwise, so there the
  "No" answer (Skip, Keep it, Leave it, Cancel) is put in that place and
  the answer is read back the other way round; Esc or closing it is never
  "Yes". The plain questions whose default is "No" get the same. On the
  terminal Enter is "No" for these questions too, and when nobody can be
  asked (no terminal, or a dialog that failed) their answer is "No". So
  `--install`, `--uninstall`, `--install-timer`, `--remove-timer`,
  `--undo` and `--update` no longer run unattended: without a terminal or
  the desktop they say that nothing was changed and exit with status 1
  (also `--undo` with nothing to undo), and when their window stops
  working on the way they end with status 1 too. A fix that fails keeps
  its undo step for `--undo` from the moment it failed (also when the tool
  is interrupted at the rollback question) until a rollback works.
- What a fix prints is copied into the run log like an undo step's output:
  only the end of it, cut to size and marked `fix:`. What kdialog or a
  one-page window prints is read only up to the size of an answer.
- Started with SIGPIPE ignored (the weekly check's systemd service does
  that), the tool starts itself again with the signal at its default.
  Before, `find | head` in the deep checks went on through every folder in
  that case, up to its time limit. CI runs the smoke test in both states.

## [1.5.0] - 2026-11-14

### Added

- OpenSSF Scorecard workflow (weekly, on pushes to `main` and on demand) with a
  README badge. Every action is pinned to a commit.
- OpenSSF Best Practices badge for project 16708.
- Releases carry a build provenance attestation (`.intoto.jsonl`) for the
  source archive, which `gh attestation verify` can check.

### Security

- Deep check fixes for SUID/SGID and world-writable files change a mode as
  administrator only where root alone can change every folder above the
  file. Files of a normal account are changed as that account; a root-owned
  file in a folder another account can change is left to you and named.
  Before, an account that owned a folder above a file could swap it for a
  link, and the fix or its undo would set the mode on a file of its choosing.
- A fix that is interrupted (Ctrl-C, a closed terminal, the tool killed)
  still gets its undo step: the fix runs to its end either way, and the tool
  now waits for it. The same holds for an undo step being marked as done.
- Setting a password refuses an answer with a line break, which would have
  handed `chpasswd` a second account.
- The Markdown report shows file names, settings and command output as plain
  text: no HTML, links, images or code spans from them.
- Recreating a container from compose files that a normal account can
  change warns before you apply: those files decide what starts as
  administrator.
- Started from a folder that an account other than root owns, the tool says
  so when it asks for administrator rights and points to `--install`.

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

[Unreleased]: https://github.com/secopsxsaiyan/Bazzite_security_check/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/secopsxsaiyan/Bazzite_security_check/releases/tag/v1.6.0
[1.5.0]: https://github.com/secopsxsaiyan/Bazzite_security_check/releases/tag/v1.5.0
[1.4.0]: https://github.com/secopsxsaiyan/Bazzite_security_check/releases/tag/v1.4.0
[1.3.0]: https://github.com/secopsxsaiyan/Bazzite_security_check/releases/tag/v1.3.0
[1.2.0]: https://github.com/secopsxsaiyan/Bazzite_security_check/releases/tag/v1.2.0
[1.1.0]: https://github.com/secopsxsaiyan/bazzite-sec-audit/releases/tag/v1.1.0
[1.0.0]: https://github.com/secopsxsaiyan/bazzite-sec-audit/releases/tag/v1.0.0
