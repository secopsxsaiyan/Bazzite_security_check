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
    _sunshine_installed() { return 0; }
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
    # _found CHECK TITLE records that finding as CHECK's code does: its
    # severity, fix and affected features are read from the finding call
    # with that title in checks/*.sh (an error when there is none).
    _found() {
        local -a spec=()
        mapfile -t spec < <(python3 -I - "$HERE/../../checks" "$1" "$2" <<'PY'
import glob, os, re, sys
d, check, title = sys.argv[1:]
for f in sorted(glob.glob(os.path.join(d, "*.sh"))):
    lines, fn = open(f, encoding="utf-8").read().split("\n"), None
    for i, l in enumerate(lines):
        m = re.match(r"^(check_\w+)\(\)", l)
        if m:
            fn = m.group(1)
        m = re.match(r'^\s*finding (high|medium|low|info) "([^"$]*)"', l)
        if not (m and fn == check and m.group(2) == title):
            continue
        fix, affects, j = "", [], i + 1
        while j < len(lines) and not re.match(r"^\s*(finding |fi$|elif |else$|done$)", lines[j]):
            if not fix and re.match(r"^\s*fix_\w+", lines[j]):
                fix = lines[j].split()[0]
            if re.match(r"^\s*finding_affects\b", lines[j]):
                k = j + 1
                while k < len(lines):
                    a = re.match(r'^\s*"([^"$]*)"( \\)?$', lines[k])
                    if not a:
                        sys.exit("%s: an affected feature that is not plain text" % title)
                    affects.append(a.group(1))
                    if not a.group(2):
                        break
                    k += 1
                break
            j += 1
        print(m.group(1)); print(fix)
        for a in affects:
            print(a)
        sys.exit(0)
sys.exit("%s: no finding with this title in %s" % (title, check))
PY
        ) || return 1
        [[ ${#spec[@]} -ge 2 ]] || { echo "readme-samples: ${2}: not found in ${1}" >&2; exit 1; }
        if [[ -n "${spec[1]}" ]]; then finding "${spec[0]}" "$2" - - "${spec[1]}" -; else finding "${spec[0]}" "$2" - -; fi
        [[ ${#spec[@]} -gt 2 ]] && finding_affects "${spec[@]:2}"
        return 0
    }
    for entry in "${STANDARD_CHECKS[@]}"; do
        id="${entry%%|*}"
        [[ "$id" == check_screen_lock ]] || eval "${id}() { :; }"
    done
    check_system_updates() { _found check_system_updates "An update is downloaded and waits for a reboot" || exit 1; }
    check_firmware() { _found check_firmware "Firmware updates are available" || exit 1; }
    check_selinux() { _found check_selinux "SELinux is not protecting the system (permissive)" || exit 1; }
    check_kernel_args() { _found check_kernel_args "CPU vulnerability protections are turned off" || exit 1; }
    check_accounts() { _found check_accounts "The root account has its own password" || exit 1; }
    check_sudo() {
        _found check_sudo "sudo works without a password" || exit 1
        _found check_sudo "A polkit rule approves admin actions without asking" || exit 1
    }
    check_game_streaming() {
        _found check_game_streaming "Sunshine's admin page accepts connections from the internet" || exit 1
        _found check_game_streaming "Sunshine opens ports on your router (UPnP)" || exit 1
        _found check_game_streaming "Sunshine's admin page is reachable from your network" || exit 1
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
    HAD_PREVIOUS_RUN=1; DELTA_GONE=(1 2 3); DELTA_NEW=()
    for i in "${!F_TITLE[@]}"; do
        [[ "${F_CHECK[$i]}" == check_game_streaming && "${F_SEV[$i]}" == medium ]] && DELTA_NEW+=("${F_TITLE[$i]}")
    done
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
