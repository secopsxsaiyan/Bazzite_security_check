#!/usr/bin/env bash
# The inputs of the three pages the README's pictures show (tests/ui-offscreen.py,
# scenario readme), as one JSON object: {"wizard-readme", "dashboard-readme",
# "confirm-readme"} - the samples of those names in samples.json. The tool's own
# code makes them: detect_usecases and _wizard_input; run_all_checks,
# compute_score and _dashboard_input; the real check_screen_lock and
# fix_screen_lock up to the confirm window. Only the PC is made up, below: a
# Bazzite desktop with Steam and Sunshine, an account "alex", and checks that
# find what such a PC might (with the tool's own titles; the screen-lock check
# is the real one, reading alex's settings). Nothing is changed and no root is
# needed:
#   bash tests/ui/readme-samples.sh > /tmp/readme-samples.json
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
(
    # shellcheck source=../../bazzite-sec-audit.sh
    source "$HERE/../../bazzite-sec-audit.sh"
    _load_check_table
    RUN_ID="20261121-140500"; STATE_DIR="/var/lib/bazzite-sec-audit"; RUN_LOG=/dev/null; QUIET=1
    UI_MODE=kde; FIX_MODE=confirm; DEEP=0; REPORT_DIR="/home/alex/Documents/bazzite-security-check"

    # ---- the PC
    OS_PRETTY="Bazzite"; IMAGE_NAME="bazzite"; IMAGE_TAG="stable"; IMAGE_VERSION="Stable (F45.20261117.1)"
    CHASSIS="desktop"; IS_PORTABLE_HW=0; VIRT=""; DISK_ENCRYPTED="yes"; DESKTOP_ENV="kde"
    DESKTOP_USER="alex"; DESKTOP_HOME="/nonexistent"; REGULAR_USERS=(alex)
    LAST_RUN_ID="20261114-190500"; LAST_SCORE=61; LAST_GRADE="D"
    hostname() { echo living-room-pc; }
    _have() { case "$1" in steam) return 0 ;; docker|code|bazzite-steam) return 1 ;; esac; command -v "$1" >/dev/null 2>&1; }
    _flatpak_installed() { return 1; }
    _sunshine_enabled() { return 0; }
    _unit_state() { echo disabled; }
    _unit_active() { return 1; }
    _user_unit_active() { return 1; }
    _steam_installed() { return 0; }
    # alex's screen locker settings: never locks by itself, nor on waking.
    _home_of() { mkdir -p "$OUT/home/$1/.config"; echo "$OUT/home/$1"; }
    _user_ini_get() { case "$4" in Autolock|LockOnResume) echo false ;; esac; }
    _kwriteconfig() { echo kwriteconfig6; }
    id() { echo 1000; }
    _undo_available() { return 0; }    # the fixes of this run left undo steps

    # ---- the wizard
    detect_usecases
    # It also looks for Docker's socket, which no stub can hide: the made-up
    # PC has no Docker, whatever the machine running this has (a CI runner
    # does).
    if [[ "${DETECTED[dev]:-}" == "Docker is installed" ]]; then unset 'DETECTED[dev]'; USE_DEV=0; fi
    _wizard_input > "$OUT/wizard"

    # ---- the check-up: these checks find something, the others pass.
    for entry in "${STANDARD_CHECKS[@]}"; do
        id="${entry%%|*}"
        [[ "$id" == check_screen_lock ]] || eval "${id}() { :; }"
    done
    check_system_updates() { finding low "An update is downloaded and waits for a reboot" - -; }
    check_flatpak_sandbox() { finding low "2 Flatpak app(s) are not really sandboxed" - - fix_flatpak_restrict -; }
    check_kernel_args() { finding medium "CPU vulnerability protections are turned off" - - fix_kargs_delete mitigations=off; }
    check_firewall() { finding high "The firewall lets in far more than this PC needs" - - fix_firewall_zone -; }
    check_ssh_server() { finding medium "SSH accepts passwords" - - fix_ssh_dropin -; }
    check_sudo() { finding medium "sudo works without a password" - - fix_sudo_line -; }
    check_accounts() { finding info "The root account has its own password" - -; }
    check_firmware() { finding low "Firmware updates are available" - -; }
    check_game_streaming() {
        finding high "Sunshine's admin page accepts connections from the internet" - - fix_sunshine_setting -
        finding medium "Sunshine opens ports on your router (UPnP)" - - fix_sunshine_setting -
    }
    ui_progress_start() { :; }; ui_progress_set() { :; }; ui_progress_stop() { :; }
    run_all_checks
    compute_score
    # Fixed in this run: sudo and the CPU protections (active after a
    # reboot); the reboot reason is the one the real fix gives.
    reason=$(apply_change() { printf '%s' "$4"; return 1; }; fix_kargs_delete mitigations=off)
    for i in "${!F_TITLE[@]}"; do
        case "${F_TITLE[$i]}" in
            "sudo works without a password") F_STATE[i]=fixed; F_VERIFY[i]=verified ;;
            "CPU vulnerability protections are turned off") F_STATE[i]=fixed; F_VERIFY[i]=reboot ;;
        esac
    done
    NEEDS_REBOOT=1; REBOOT_REASONS=("$reason")
    # Since the last check-up: three problems are gone, one is new.
    HAD_PREVIOUS_RUN=1; DELTA_GONE=(1 2 3); DELTA_NEW=("Sunshine opens ports on your router (UPnP)")
    SCORE_NOW=$(_score now); GRADE_NOW=$(_grade "$SCORE_NOW")
    _CSTATE=(); _CF_READY=0
    _dashboard_input "$(_fix_candidates | grep -c . || true)" > "$OUT/dashboard"

    # ---- the fix: alex's screen lock, as the real check recorded it
    _qml_ok() { return 0; }
    ui_app() { printf '%s\n' "$2" > "$OUT/confirm"; return 1; }
    fx=()
    for i in "${!F_TITLE[@]}"; do
        [[ "${F_CHECK[$i]}" == check_screen_lock ]] || continue
        CURRENT_FINDING=$i
        eval "fx=(${F_FIX[$i]})"
        "${fx[@]}" || true
    done
) > "$OUT/log" 2>&1
for f in wizard dashboard confirm; do
    if [[ ! -s "$OUT/$f" ]]; then
        echo "readme-samples: no ${f} input was made; what the tool printed:" >&2
        tail -n 20 "$OUT/log" >&2
        exit 1
    fi
done
python3 -I -c 'import json, sys
d = sys.argv[1]
print(json.dumps({k + "-readme": json.load(open(d + "/" + k)) for k in ("wizard", "dashboard", "confirm")}, ensure_ascii=False, indent=1))' "$OUT"
