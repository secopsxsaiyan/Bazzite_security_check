#!/usr/bin/env bash
# The two halves together: the tool's own functions (lib/ui.sh) ask the real
# front end (ui/app.py, off-screen) for pages and read its answers. smoke.sh
# tests the root side against a stand-in front end, and ui-offscreen.py
# tests the front end from Python; only here do the two meet, so a change
# to the request or answer form on one side alone fails here.
# No root: the front end runs as this user, with a key pressed for it.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/bsa-e2e.XXXXXX") || exit 2
# shellcheck source=../bazzite-sec-audit.sh
source "$HERE/../bazzite-sec-audit.sh"
set +e
RUN_LOG="$W/run.log"; : > "$RUN_LOG"
RUN_TMP=$(mktemp -d "$W/rt.XXXXXX")
UI_MODE=kde; _QML_OK=yes
_kd() { echo "kdialog asked: $*" >> "$W/kd"; return 1; }
_ui_app_cmd() { env QT_QPA_PLATFORM=offscreen E2E_KEY="${E2E_KEY:-enter}" python3 -I "$HERE/ui/e2e-front.py" "$@"; }
trap 'ui_front_stop; rm -rf "$W"' EXIT

pass=0; fail=0
is() {  # is WHAT GOT WANTED
    if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); echo "  ok   $1"
    else fail=$((fail + 1)); echo "  FAIL $1: got '$2', expected '$3'"; fi
}

ui_front_start
is "the window is started and its pipe is open" "$([[ -n "${_UI_FRONT_W:-}" ]] && _ui_front_up && echo up)" up

ui_yesno "Proceed with it?" "Yes" "No" "y"; is "a yes/no question, default yes: Enter is yes" "$?" 0
ui_yesno "Proceed with it?" "Yes" "No" "n"; is "a yes/no question, default no: Enter is no" "$?" 1
sel=$(ui_radiolist "Pick one" a "Alpha" off b "Beta" on); is "a pick-one list: Enter takes the marked entry" "$?:$sel" "0:b"
out=$(ui_app choose "$(_choose_input "<html><h3>Title</h3><p>Text</p>" t1 "One" on t2 "Two" off)")
is "a choose page: Enter answers the ticked tag" "$?:$(printf '%s' "$out" | tr -d ' ')" '0:{"tags":["t1"]}'
out=$(ui_app settings "$(_json version 1.0 repo x/y theme system update_check 1)")
is "a settings page: Enter saves" "$?" 0
ui_busy_start "Working on it"; ui_busy_stop; ui_theme_changed
is "busy and theme lines leave the window in use" "$(_ui_front_up && echo up)" up
is "no question went to kdialog" "$(cat "$W/kd" 2>/dev/null)" ""

out=$(ui_app nosuchmode '{}'); is "a page the front end does not know: status 3" "$?" 3
out=$(ui_app settings '{}'); is "and from then on the window is not used: status 4" "$?" 4

ui_front_stop
# (Read from /proc: the CI image has no pgrep.)
left=0
for f in /proc/[0-9]*/cmdline; do
    { tr '\0' ' ' < "$f" | grep -qF "$HERE/ui/e2e-front.py"; } 2>/dev/null && left=$((left + 1))
done
is "after the stop nothing of the front end is left" "$left" 0

echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
