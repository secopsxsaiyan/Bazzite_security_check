#!/usr/bin/env bash
# Prints the input of the confirm window for the real screen-lock fix: the
# sample "confirm-readme" in samples.json, which the README's picture of a
# fix shows (tests/ui-offscreen.py, scenario readme). The finding is
# recorded with what check_screen_lock in checks/desktop.sh gives for an
# account "alex" whose screen never locks by itself nor on waking (Steam
# installed), and the real fix_screen_lock runs up to the window, which only
# saves its input here. Nothing is changed and no root is needed:
#   bash tests/ui/readme-confirm.sh > /tmp/confirm-readme.json
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
(
    # shellcheck source=../../bazzite-sec-audit.sh
    source "$HERE/../../bazzite-sec-audit.sh"
    _load_check_table
    RUN_ID="20261121-140500"; STATE_DIR="/var/lib/bazzite-sec-audit"; RUN_LOG=/dev/null; UI_MODE=kde
    CURRENT_CHECK=check_screen_lock; DESKTOP_ENV=kde; USE_PORTABLE=0; USE_GAMING=0
    _steam_installed() { return 0; }
    _kwriteconfig() { echo kwriteconfig6; }
    id() { echo 1000; }
    _qml_ok() { return 0; }
    ui_app() { printf '%s\n' "$2" > "$OUT"; return 1; }
    # As check_screen_lock records it (Autolock and LockOnResume false).
    finding "$(_ctx medium low)" "alex's screen does not lock reliably" \
"For alex: the screen never locks by itself; it does not lock when waking from sleep.
An unlocked desktop gives anyone who walks by your browser sessions, chats and
files. Games and videos in fullscreen keep the screen awake on their own, so
auto-lock does not interrupt them." \
"System Settings → Security & Privacy → Screen Locking:
lock automatically after 10 minutes, and after waking from sleep" \
        fix_screen_lock alex "Autolock|bool|true|false" "LockOnResume|bool|true|false"
    finding_change "alex: Autolock=false, LockOnResume=false" "alex: Autolock=true, LockOnResume=true"
    finding_affects \
        "couch|The screen can lock while you play with only a controller or watch a video, if that app does not keep the screen awake."
    CURRENT_FINDING=0
    fix_screen_lock alex "Autolock|bool|true|false" "LockOnResume|bool|true|false" || true
) > /dev/null 2>&1
[[ -s "$OUT" ]] || { echo "readme-confirm: the fix did not reach the confirm window" >&2; exit 1; }
cat "$OUT"
