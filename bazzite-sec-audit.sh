#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# bazzite-sec-audit.sh - security check-up for a Bazzite (KDE) home gaming
# and development desktop.
#
# A KDE wizard asks how the PC is used, the checks adapt to that and to what
# is installed, and a dashboard shows the result of every check. Fixes are
# picked from a list; each is shown with what it changes, its side effects
# and its exact commands, applied only after you confirm it, checked again
# afterwards, and can be undone (--undo).
#
# Start it as your normal user (it asks for administrator rights itself):
#   ./bazzite-sec-audit.sh
# =============================================================================
readonly SCRIPT_VERSION="1.2.0"

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
STATE_DIR="${AUDIT_STATE_DIR:-/var/lib/bazzite-sec-audit}"
AUDIT_ROOT="${AUDIT_ROOT:-}"      # file-read prefix, used by the tests
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_LOG=""
RUN_TMP=""                        # private scratch folder, removed on exit
FINDINGS_FILE=""
ACTION="audit"                    # audit | undo | install | uninstall | install-timer | remove-timer | settings | update | list
WIZARD="auto"                     # auto | force | never
DASHBOARD=1                       # 0: --no-dashboard
NOTIFY=0
QUIET=0
VERBOSE=0
CLI_USE=""
HAVE_PROFILE=0
HAD_PREVIOUS_RUN=0

# Every module is listed so `shellcheck -x` can follow it.
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/ui.sh
source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck source=lib/wizard.sh
source "${SCRIPT_DIR}/lib/wizard.sh"
# shellcheck source=lib/runner.sh
source "${SCRIPT_DIR}/lib/runner.sh"
# shellcheck source=lib/fixes.sh
source "${SCRIPT_DIR}/lib/fixes.sh"
# shellcheck source=lib/dashboard.sh
source "${SCRIPT_DIR}/lib/dashboard.sh"
# shellcheck source=lib/report.sh
source "${SCRIPT_DIR}/lib/report.sh"
# shellcheck source=lib/install.sh
source "${SCRIPT_DIR}/lib/install.sh"
# shellcheck source=lib/settings.sh
source "${SCRIPT_DIR}/lib/settings.sh"
# shellcheck source=lib/update.sh
source "${SCRIPT_DIR}/lib/update.sh"
# shellcheck source=checks/system.sh
source "${SCRIPT_DIR}/checks/system.sh"
# shellcheck source=checks/flatpak.sh
source "${SCRIPT_DIR}/checks/flatpak.sh"
# shellcheck source=checks/boot.sh
source "${SCRIPT_DIR}/checks/boot.sh"
# shellcheck source=checks/network.sh
source "${SCRIPT_DIR}/checks/network.sh"
# shellcheck source=checks/accounts.sh
source "${SCRIPT_DIR}/checks/accounts.sh"
# shellcheck source=checks/desktop.sh
source "${SCRIPT_DIR}/checks/desktop.sh"
# shellcheck source=checks/devgaming.sh
source "${SCRIPT_DIR}/checks/devgaming.sh"
# shellcheck source=checks/deep.sh
source "${SCRIPT_DIR}/checks/deep.sh"

usage() {
    cat << EOF
bazzite-sec-audit ${SCRIPT_VERSION} - security check-up for a Bazzite gaming & development desktop

Usage: $(basename "$0") [OPTIONS]
Start it as your normal user; it asks for administrator rights (pkexec or sudo).

What to check
  --deep              Also sweep for SUID files, autostart entries, /etc changes
                      and scan Downloads with ClamAV when available
  --standard          Standard depth (default)
  --use LIST          How the PC is used, comma-separated (skips the wizard):
                      gaming, streaming, dev, ssh, sharing, portable - or "none"
  --check LIST        Run only these checks (see --list-checks)
  --skip LIST         Skip these checks

Fixes
  --fix               Offer fixes: pick them from a list, each needs your OK (default)
  --report-only       Change nothing
  --undo              Undo changes made by an earlier run, one confirmation each

Interface
  --gui / --no-gui    KDE dialogs / terminal only (default: KDE dialogs if available)
  --wizard            Always show the setup wizard
  --no-wizard         Use the remembered (or detected) answers
  --no-dashboard      Skip the dashboard: go straight to the fix list, then finish
  --report-dir DIR    Where to save the HTML and Markdown report
  --quiet, --verbose

Extras
  --install           Install as an app: "Security Check" in the application menu
                      and the bazzite-sec-audit command; it asks for the
                      administrator password when started. Run again to update.
  --uninstall         Remove the app (reports and undo steps are kept)
  --settings          Theme of the windows, update check
  --update            Install the latest release from GitHub (its signature
                      and checksums are verified first)
  --install-timer     Weekly background check, report only, with a notification
  --remove-timer      Remove the weekly check
  --list-checks       List check ids
  --version, --help

Nothing is ever changed without your confirmation. Reports are saved in
~/Documents/bazzite-security-check by default; history, undo steps and logs
are kept in ${STATE_DIR} (root only).
EOF
}

_parse_list() {
    local flag="$1" value="$2" id
    local -n _dest="$3"
    local -a ids=()
    IFS=',' read -ra ids <<< "$value"
    _dest=()
    for id in "${ids[@]}"; do
        [[ -n "$id" ]] || continue
        [[ "$id" == check_* ]] || id="check_${id}"
        if ! _known_check "$id"; then
            echo "Unknown check for ${flag}: ${id#check_} (see --list-checks)" >&2
            exit 1
        fi
        _dest+=("$id")
    done
    # An empty list would quietly mean "every check".
    if [[ ${#_dest[@]} -eq 0 ]]; then
        echo "${flag} needs a list of checks (see --list-checks)" >&2
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --deep)          DEEP=1; _SET_DEEP=1 ;;
            --standard|--quick) DEEP=0; _SET_DEEP=1 ;;
            --use)
                shift
                [[ -n "${1:-}" ]] || { echo "--use needs a list" >&2; exit 1; }
                local u
                for u in ${1//,/ }; do
                    case "$u" in
                        gaming|streaming|dev|ssh|sharing|portable|none) ;;
                        *) echo "Unknown use for --use: $u" >&2; exit 1 ;;
                    esac
                done
                CLI_USE="$1"; _SET_USE=1 ;;
            --check)         shift; _parse_list --check "${1:-}" RUN_ONLY ;;
            --skip)          shift; _parse_list --skip "${1:-}" SKIP_CHECKS ;;
            --fix)           FIX_MODE="confirm"; _SET_FIX=1 ;;
            --report-only)   FIX_MODE="report"; _SET_FIX=1 ;;
            --undo)          ACTION="undo" ;;
            --gui)           UI_PREF="gui" ;;
            --no-gui)        UI_PREF="tty" ;;
            --wizard|--interactive) WIZARD="force" ;;
            --no-wizard)     WIZARD="never" ;;
            --no-dashboard)  DASHBOARD=0 ;;
            --report-dir|--output-dir)
                shift
                [[ "${1:-}" == /* ]] || { echo "--report-dir needs an absolute path" >&2; exit 1; }
                REPORT_DIR="$1"; _SET_REPORT_DIR=1 ;;
            --notify)        NOTIFY=1 ;;
            --quiet)         QUIET=1 ;;
            --verbose)       VERBOSE=1 ;;
            # --install-launcher was a per-user menu entry that ran the tool
            # from a home folder; the app install replaces it.
            --install|--install-launcher) ACTION="install" ;;
            --uninstall)     ACTION="uninstall" ;;
            --settings)      ACTION="settings" ;;
            --update)        ACTION="update" ;;
            --install-timer) ACTION="install-timer" ;;
            --remove-timer)  ACTION="remove-timer" ;;
            --list-checks)   ACTION="list" ;;
            --version)       echo "bazzite-sec-audit ${SCRIPT_VERSION}"; exit 0 ;;
            -h|--help)       usage; exit 0 ;;
            *)               echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
        esac
        shift
    done
}

_apply_cli_use() {
    [[ "$_SET_USE" -eq 1 ]] || return 0
    USE_GAMING=0; USE_STREAMING=0; USE_DEV=0; USE_SSH=0; USE_SHARING=0; USE_PORTABLE=0
    local u
    for u in ${CLI_USE//,/ }; do
        case "$u" in
            gaming) USE_GAMING=1 ;; streaming) USE_STREAMING=1 ;; dev) USE_DEV=1 ;;
            ssh) USE_SSH=1 ;; sharing) USE_SHARING=1 ;; portable) USE_PORTABLE=1 ;;
        esac
    done
}

# _user_dialog ARGS... — a kdialog in the person's own session, before
# administrator rights exist. Status 2 when no dialog can be shown.
_user_dialog() {
    [[ "$UI_PREF" != "tty" ]] && command -v kdialog >/dev/null 2>&1 \
        && [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]] || return 2
    local icon=security-high
    [[ -f /usr/local/share/icons/hicolor/scalable/apps/bazzite-security-check.svg ]] && icon=bazzite-security-check
    kdialog --title "Bazzite Security Check" --icon "$icon" "$@" 2>/dev/null
}

# _explain_pkexec — say why the password dialog comes and what it shows,
# before it appears. An information dialog, so "don't show again" stores
# only that (a yes/no dialog would also remember a Cancel and then quit
# silently on every later start); cancelling is done in the password dialog.
_explain_pkexec() {
    local what
    case "$ACTION" in
        undo) what="To undo changes it made earlier, Security Check needs administrator rights." ;;
        install-timer|remove-timer) what="To set up or remove the weekly check, Security Check needs administrator rights." ;;
        install|uninstall|update) what="To install, update or remove the Security Check app, administrator rights are needed: it is installed for the whole PC, owned by root." ;;
        settings) what="Security Check's settings are kept with its other files, which only an administrator may change." ;;
        *) what="Security Check needs administrator rights to read system settings: the firewall, accounts and passwords, SSH, sudo rules and more." ;;
    esac
    local promise="Nothing on this PC changes until you review a change and press <b>Apply</b>."
    case "$ACTION" in
        install|uninstall|update|settings|install-timer|remove-timer) promise="Nothing is installed or removed until you confirm it in the next window." ;;
    esac
    _user_dialog --dontagain "bazzite-sec-audit:explain-admin" --msgbox \
"<html><p>${what}</p><p>KDE asks for your password next (cancel there to stop). That dialog names <tt>/usr/bin/env</tt>: this is how the tool restarts itself as administrator while keeping your desktop session, so its windows still appear on your screen.</p><p>You are asked once. ${promise}</p></html>" || true
    return 0
}

# _elevate ARGS... — start again as root: sudo on a terminal, pkexec (the
# KDE password dialog) otherwise. The desktop session is passed along so
# the dialogs appear on the user's screen. Administrator rights are asked
# for once: the whole run (checks, and the fixes you confirm) runs as root,
# while dialogs and files in your home folder are handled as you.
_elevate() {
    local -a envs=(
        "AUDIT_DESKTOP_USER=$(id -un)"
        "AUDIT_GUI_WAYLAND=${WAYLAND_DISPLAY:-}"
        "AUDIT_GUI_DISPLAY=${DISPLAY:-}"
        "AUDIT_GUI_XAUTHORITY=${XAUTHORITY:-}"
        "LANG=${LANG:-C.UTF-8}"
    )
    # AUDIT_STATE_DIR and AUDIT_ROOT (for the tests) are not passed on: the
    # root run keeps its history and undo steps in root's own folder, never
    # in one named by the unprivileged environment.
    [[ -n "${NO_COLOR:-}" ]] && envs+=("NO_COLOR=1")
    if [[ -t 0 ]] && command -v sudo >/dev/null 2>&1; then
        echo "Administrator rights are needed to read the system settings (firewall, accounts, SSH, sudo rules, ...)."
        echo "sudo asks for your password once; nothing is changed until you confirm each change."
        exec sudo /usr/bin/env "${envs[@]}" "$SCRIPT_PATH" "$@"
    elif command -v pkexec >/dev/null 2>&1; then
        _explain_pkexec
        local rc=0 err
        # Started from the menu, nobody sees the root run's error messages:
        # keep them, to show in a dialog if it stops with an error.
        err=$(mktemp "${TMPDIR:-/tmp}/bazzite-sec-audit-err.XXXXXX" 2>/dev/null) || err=/dev/null
        pkexec /usr/bin/env "${envs[@]}" "$SCRIPT_PATH" "$@" 2> "$err" || rc=$?
        [[ "$err" == /dev/null ]] || cat -- "$err" >&2
        # 126: the password dialog was dismissed; 127: not authorised.
        if [[ $rc -eq 126 || $rc -eq 127 ]]; then
            _user_dialog --sorry "Administrator rights were not granted, so nothing was checked or changed." \
                || echo "Administrator rights were not granted; nothing was checked or changed." >&2
        elif [[ $rc -ne 0 && -s "$err" ]]; then
            _user_dialog --sorry "Security Check stopped: $(tail -n 3 -- "$err")" || true
        fi
        [[ "$err" == /dev/null ]] || rm -f -- "$err"
        exit "$rc"
    fi
    echo "This tool needs administrator rights, but neither sudo (on a terminal) nor pkexec is available." >&2
    exit 1
}

_init_state() {
    # A trailing slash would make the symlink test below look through a link.
    while [[ "$STATE_DIR" == ?*/ ]]; do STATE_DIR="${STATE_DIR%/}"; done
    mkdir -p "$STATE_DIR"
    # Undo steps in here run as root: the folder must be root's alone.
    if [[ -L "$STATE_DIR" || "$(stat -c %u -- "$STATE_DIR" 2>/dev/null)" != 0 ]]; then
        echo "The state folder ${STATE_DIR} is not a folder owned by root; refusing to use it." >&2
        exit 1
    fi
    chmod 700 "$STATE_DIR"
    mkdir -p "$STATE_DIR/history" "$STATE_DIR/logs" "$STATE_DIR/reports"
    # Lock first: a second run started in the same second has the same run
    # id, and must not empty the running one's log.
    exec 9> "$STATE_DIR/.lock"
    if ! flock -n 9; then
        echo "Another security check is already running." >&2
        exit 1
    fi
    RUN_LOG="$STATE_DIR/logs/run-${RUN_ID}.log"
    : > "$RUN_LOG"
    RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/bazzite-sec-audit.XXXXXX") || RUN_TMP=""
}

_cleanup() {
    [[ -n "$RUN_TMP" && -d "$RUN_TMP" ]] && rm -rf -- "$RUN_TMP"
    return 0
}

# _prune_history — keep the 30 newest of each kind of history file.
_prune_history() {
    local pattern dir
    for pattern in "history/findings-*.jsonl" "logs/run-*.log" "reports/bazzite-security-*.md" "reports/bazzite-security-*.html"; do
        dir="$STATE_DIR/${pattern%/*}"
        find "$dir" -maxdepth 1 -type f -name "${pattern##*/}" -printf '%f\n' 2>/dev/null \
            | sort -r | tail -n +31 | while IFS= read -r f; do rm -f -- "$dir/$f"; done
    done
    return 0
}

main() {
    set -uo pipefail
    umask 077
    _load_check_table
    parse_args "$@"

    case "$ACTION" in
        list)
            local e
            for e in "${STANDARD_CHECKS[@]}" "${DEEP_CHECKS[@]}"; do
                IFS='|' read -r _id _w _t <<< "$e"
                printf '%-28s %s%s\n' "${_id#check_}" "$_t" "$([[ $_id == check_deep_* ]] && echo ' (--deep)')"
            done
            exit 0 ;;
    esac

    if [[ $EUID -ne 0 ]]; then
        _elevate "$@"
    fi

    trap '_PROGRESS_STEPS=0; ui_progress_stop; echo; print_status "WARN" "Interrupted."; exit 130' INT TERM
    trap _cleanup EXIT
    _init_state
    # Test hooks change what is read and where state is kept; never silently.
    if [[ -n "${AUDIT_ROOT:-}${AUDIT_STATE_DIR:-}${AUDIT_TEST_PATH:-}" ]]; then
        echo "Note: test settings are active (AUDIT_ROOT, AUDIT_STATE_DIR or AUDIT_TEST_PATH); results do not describe this PC." >&2
        log "test settings active: AUDIT_ROOT=${AUDIT_ROOT:-} AUDIT_STATE_DIR=${AUDIT_STATE_DIR:-} AUDIT_TEST_PATH=${AUDIT_TEST_PATH:-}"
    fi
    detect_desktop_user
    load_settings
    ui_init
    ui_theme_prepare
    gather_facts
    log "bazzite-sec-audit ${SCRIPT_VERSION}; user=${DESKTOP_USER:-none}; ui=${UI_MODE}; os=${OS_PRETTY}; bazzite=${IS_BAZZITE}; image=${IMAGE_NAME:-?}"

    if [[ "$IS_OSTREE" -ne 1 && "$ACTION" == "audit" ]]; then
        # Without a terminal or desktop nobody can answer the question
        # below: say why nothing was checked instead of quitting silently.
        if ! ui_interactive; then
            echo "This PC does not look like Bazzite or another Fedora Atomic system (${OS_PRETTY:-unknown}); nothing was checked. Start it from a terminal or the desktop to continue anyway." >&2
            exit 1
        fi
        if ! ui_yesno "This PC does not look like Bazzite or another Fedora Atomic system (${OS_PRETTY:-unknown}).
Many checks will not apply. Continue anyway?" "Continue" "Quit" "n"; then
            exit 0
        fi
    fi

    case "$ACTION" in
        undo)          run_undo; exit 0 ;;
        install)       install_app; exit 0 ;;
        settings)      run_settings; exit 0 ;;
        update)        update_run; exit 0 ;;
        uninstall)     uninstall_app; exit 0 ;;
        install-timer) install_timer; exit 0 ;;
        remove-timer)  remove_timer; exit 0 ;;
    esac

    # A newer release, when the person asked to be told (Settings).
    if [[ "$UPDATE_CHECK" -eq 1 ]] && ui_interactive; then
        update_run quiet
        [[ $? -eq 10 ]] && { print_status "INFO" "Start Security Check again to use the new version."; exit 0; }
    fi
    detect_usecases
    load_profile
    load_last_run
    _apply_cli_use

    if [[ "$WIZARD" == "force" ]] || { [[ "$WIZARD" == "auto" ]] && ui_interactive && [[ "$_SET_USE" -eq 0 ]]; }; then
        if ui_interactive; then
            run_wizard
            save_profile
        fi
    fi
    [[ -n "$REPORT_DIR" ]] || REPORT_DIR=$(_default_report_dir)
    ui_interactive || FIX_MODE="report"

    FINDINGS_FILE="$STATE_DIR/history/findings-${RUN_ID}.jsonl"
    : > "$FINDINGS_FILE"
    run_all_checks
    compute_score
    compute_delta
    write_reports

    if ui_interactive && [[ "$DASHBOARD" -eq 1 ]]; then
        run_dashboard
    elif ui_interactive; then
        [[ "$FIX_MODE" == "confirm" ]] && run_fix_session
    fi

    write_reports
    save_last_run
    _prune_history
    print_summary
    if installed_copy_outdated; then
        if _app_installed; then
            print_status "WARN" "The installed app (and weekly check) still run an older copy of this tool (${INSTALL_DIR}); run --install again to update it."
        else
            print_status "WARN" "The weekly check still runs an older copy of this tool (${INSTALL_DIR}); run --install-timer again to update it."
        fi
    fi
    [[ "$NOTIFY" -eq 1 ]] && notify_desktop
    [[ "$DASHBOARD" -eq 1 ]] || final_dialog
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
