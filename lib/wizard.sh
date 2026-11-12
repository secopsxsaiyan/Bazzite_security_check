# shellcheck shell=bash
# How the PC is used (detected, remembered, asked) and the setup wizard.

USE_GAMING=1; USE_STREAMING=0; USE_DEV=0; USE_SSH=0; USE_SHARING=0; USE_PORTABLE=0
DEEP=0
FIX_MODE="confirm"           # confirm | report
REPORT_DIR=""
_SET_USE=0; _SET_DEEP=0; _SET_FIX=0; _SET_REPORT_DIR=0
declare -gA DETECTED=()      # why a use case was pre-selected

# ====================== DETECTION ======================
_sunshine_enabled() {
    local u="$1" unit
    for unit in app-dev.lizardbyte.app.Sunshine.service homebrew.sunshine.service sunshine.service; do
        [[ "$(_user_unit_state "$u" "$unit")" == "enabled" ]] && return 0
        _user_unit_active "$u" "$unit" && return 0
    done
    return 1
}

_flatpak_installed() {
    flatpak info "$1" >/dev/null 2>&1 && return 0
    [[ -n "$DESKTOP_USER" ]] && _as_desktop_user flatpak info --user "$1" >/dev/null 2>&1
}

detect_usecases() {
    DETECTED=()
    if _have steam || _have bazzite-steam || _flatpak_installed com.valvesoftware.Steam \
       || _flatpak_installed net.lutris.Lutris || _flatpak_installed com.heroicgameslauncher.hgl; then
        DETECTED[gaming]="Steam or a game launcher is installed"
    fi
    if [[ -n "$DESKTOP_USER" ]] && _sunshine_enabled "$DESKTOP_USER"; then
        DETECTED[streaming]="Sunshine is set to start"
    fi
    if _have docker || [[ -S /run/docker.sock ]]; then
        DETECTED[dev]="Docker is installed"
    elif _have code || _flatpak_installed com.visualstudio.code || _flatpak_installed com.vscodium.codium \
         || compgen -G "${DESKTOP_HOME:-/nonexistent}/.local/share/JetBrains/*" >/dev/null 2>&1; then
        DETECTED[dev]="a code editor or IDE is installed"
    elif [[ -n "$DESKTOP_HOME" ]] && compgen -G "${DESKTOP_HOME}/.local/share/containers/storage/overlay-containers/*" >/dev/null 2>&1; then
        DETECTED[dev]="you have Podman/Distrobox containers"
    fi
    local s
    for s in sshd.service sshd.socket; do
        if [[ "$(_unit_state "$s")" == "enabled" ]] || _unit_active "$s"; then
            DETECTED[ssh]="the SSH server is turned on"
            break
        fi
    done
    for s in smb.service syncthing.service nfs-server.service; do
        if _unit_active "$s"; then DETECTED[sharing]="${s%.service} is running"; break; fi
    done
    if [[ -z "${DETECTED[sharing]:-}" && -n "$DESKTOP_USER" ]] \
       && _user_unit_active "$DESKTOP_USER" syncthing.service; then
        DETECTED[sharing]="Syncthing is running"
    fi
    if [[ "$IS_PORTABLE_HW" -eq 1 ]]; then
        DETECTED[portable]="this PC reports itself as a ${CHASSIS}"
    fi

    [[ -n "${DETECTED[gaming]:-}" ]] && USE_GAMING=1
    [[ -n "${DETECTED[streaming]:-}" ]] && USE_STREAMING=1
    [[ -n "${DETECTED[dev]:-}" ]] && USE_DEV=1
    [[ -n "${DETECTED[ssh]:-}" ]] && USE_SSH=1
    [[ -n "${DETECTED[sharing]:-}" ]] && USE_SHARING=1
    [[ -n "${DETECTED[portable]:-}" ]] && USE_PORTABLE=1
    return 0
}

# ====================== SAVED ANSWERS ======================
_profile_file() { printf '%s/profile.conf' "$STATE_DIR"; }

# load_profile — answers from the last wizard run (only known keys and
# well-formed values are taken; the file is root's).
load_profile() {
    local f key val
    f=$(_profile_file)
    [[ -f "$f" && ! -L "$f" && "$(_owner "$f")" == "root" ]] || return 0
    while IFS='=' read -r key val; do
        case "$key" in
            USE_GAMING|USE_STREAMING|USE_DEV|USE_SSH|USE_SHARING|USE_PORTABLE)
                [[ "$_SET_USE" -eq 0 && "$val" =~ ^[01]$ ]] && printf -v "$key" '%s' "$val" ;;
            DEEP)
                [[ "$_SET_DEEP" -eq 0 && "$val" =~ ^[01]$ ]] && DEEP="$val" ;;
            FIX_MODE)
                [[ "$_SET_FIX" -eq 0 && "$val" =~ ^(confirm|report)$ ]] && FIX_MODE="$val" ;;
            REPORT_DIR)
                [[ "$_SET_REPORT_DIR" -eq 0 && "$val" == /* && "$val" != *$'\n'* ]] && REPORT_DIR="$val" ;;
        esac
    done < "$f"
    HAVE_PROFILE=1
}

save_profile() {
    local f
    f=$(_profile_file)
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    {
        printf 'USE_GAMING=%s\nUSE_STREAMING=%s\nUSE_DEV=%s\nUSE_SSH=%s\nUSE_SHARING=%s\nUSE_PORTABLE=%s\n' \
            "$USE_GAMING" "$USE_STREAMING" "$USE_DEV" "$USE_SSH" "$USE_SHARING" "$USE_PORTABLE"
        printf 'DEEP=%s\nFIX_MODE=%s\nREPORT_DIR=%s\n' "$DEEP" "$FIX_MODE" "$REPORT_DIR"
    } > "$f.tmp" && mv -f "$f.tmp" "$f"
}

# _default_report_dir — ~/Documents/bazzite-security-check for the desktop
# user (their localised Documents folder), else the state directory.
_default_report_dir() {
    local docs=""
    if [[ -n "$DESKTOP_USER" ]]; then
        docs=$(_as_desktop_user xdg-user-dir DOCUMENTS 2>/dev/null || true)
        [[ "$docs" == /* && -d "$docs" ]] || docs="$DESKTOP_HOME"
        printf '%s/bazzite-security-check' "$docs"
    else
        printf '%s/reports' "$STATE_DIR"
    fi
}

# _report_dir_usable DIR — the desktop user can create DIR and write to it
# (the report copy is written as that user). Without a desktop user, reports
# stay in the state folder anyway.
_report_dir_usable() {
    [[ -n "$DESKTOP_USER" ]] || return 0
    _as_desktop_user sh -c 'mkdir -p -- "$1" && test -w "$1"' sh "$1" 2>/dev/null
}

_onoff() { if [[ "$1" -eq 1 ]]; then echo on; else echo off; fi; }

_usecase_summary() {
    local -a u=()
    [[ "$USE_GAMING" -eq 1 ]] && u+=("gaming")
    [[ "$USE_STREAMING" -eq 1 ]] && u+=("game streaming")
    [[ "$USE_DEV" -eq 1 ]] && u+=("development")
    [[ "$USE_SSH" -eq 1 ]] && u+=("remote SSH")
    [[ "$USE_SHARING" -eq 1 ]] && u+=("LAN file sharing")
    [[ "$USE_PORTABLE" -eq 1 ]] && u+=("leaves the house")
    [[ ${#u[@]} -gt 0 ]] || u=("general desktop")
    _join ", " "${u[@]}"
}

# ====================== LAST FULL CHECK ======================
_last_run_file() { printf '%s/last-run.conf' "$STATE_DIR"; }

LAST_RUN_ID=""; LAST_SCORE=""; LAST_GRADE=""

# load_last_run — the date and score of the last full check (root's file;
# only well-formed values are taken).
load_last_run() {
    local f key val
    f=$(_last_run_file)
    [[ -f "$f" && ! -L "$f" && "$(_owner "$f")" == "root" ]] || return 0
    while IFS='=' read -r key val; do
        case "$key" in
            RUN_ID) [[ "$val" =~ ^[0-9]{8}-[0-9]{6}$ ]] && LAST_RUN_ID="$val" ;;
            SCORE)  [[ "$val" =~ ^[0-9]{1,3}$ ]] && LAST_SCORE="$val" ;;
            GRADE)  [[ "$val" =~ ^[A-F]$ ]] && LAST_GRADE="$val" ;;
        esac
    done < "$f"
    [[ -n "$LAST_RUN_ID" && -n "$LAST_SCORE" && -n "$LAST_GRADE" ]] || { LAST_RUN_ID=""; LAST_SCORE=""; LAST_GRADE=""; }
}

# save_last_run — remember this run's score, when it ran every standard
# check (a run limited with --check/--skip is not comparable).
save_last_run() {
    [[ ${#RUN_ONLY[@]} -eq 0 && ${#SKIP_CHECKS[@]} -eq 0 ]] || return 0
    local f
    f=$(_last_run_file)
    printf 'RUN_ID=%s\nSCORE=%s\nGRADE=%s\n' "$RUN_ID" "$SCORE_NOW" "$GRADE_NOW" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

# _run_date RUN_ID — "2026-11-04 05:31".
_run_date() { printf '%s-%s-%s %s:%s' "${1:0:4}" "${1:4:2}" "${1:6:2}" "${1:9:2}" "${1:11:2}"; }

# ====================== WIZARD ======================
_wcancel() { print_status "INFO" "Cancelled."; exit 0; }

# The wizard's pages, in the style of a Plasma setup assistant: a small
# bold "STEP 1 OF 4 · YOUR PC" line, a large title and a one-line subtitle,
# then the content. Only the default text colour carries words, so every
# page reads the same in Breeze Light and Breeze Dark.
_WIZ_STEPS=("Welcome" "Your PC" "Options" "Report" "Review")

# _wiz_page STEP TITLE SUBTITLE BODY — one page (STEP indexes _WIZ_STEPS).
_wiz_page() {
    local n="$1" eyebrow="WELCOME"
    (( n > 0 )) && eyebrow="STEP ${n} OF $(( ${#_WIZ_STEPS[@]} - 1 )) · ${_WIZ_STEPS[$n]^^}"
    printf '<html><p><small><b>%s</b></small></p><h2>%s</h2><p><i>%s</i></p>%s</html>' \
        "$eyebrow" "$2" "$3" "$4"
}

# _wiz_row LABEL VALUE — a row of a page's key/value table (VALUE is HTML).
_wiz_row() { printf '<tr><td><b>%s</b>&nbsp;&nbsp;</td><td>%s</td></tr>' "$1" "$2"; }

# _overview_html — the welcome page: what this PC is and what was found on
# it, before anything is checked.
_overview_html() {
    local disk det="" k last body
    case "$DISK_ENCRYPTED" in
        yes) disk="<font color=\"${C_OK}\">✔</font> encrypted (LUKS)" ;;
        no)  disk="<font color=\"${C_MEDIUM}\">⚠</font> not encrypted" ;;
        *)   disk="could not tell" ;;
    esac
    for k in gaming streaming dev ssh sharing portable; do
        [[ -n "${DETECTED[$k]:-}" ]] && det+="${det:+<br>}• $(_html "${DETECTED[$k]}")"
    done
    if [[ -n "$LAST_RUN_ID" ]]; then
        last="$(_run_date "$LAST_RUN_ID") · <b><font color=\"$(_grade_color "$LAST_GRADE")\">${LAST_SCORE}/100</font></b> (grade ${LAST_GRADE})"
    else
        last="none yet"
    fi
    body="<p>Checks updates, the firewall, network services, SSH, accounts, screen locking, secrets in your home folder, game streaming and more. Server rules that would get in your way are left out.</p>"
    body+="<p><font color=\"${C_OK}\">✔</font> <b>Nothing changes without your OK</b>, and every change can be undone later.</p>"
    body+="<table cellpadding=\"3\">"
    body+="$(_wiz_row "This PC" "$(_html "$(hostname 2>/dev/null)") · $(_html "${OS_PRETTY:-unknown OS}")")"
    [[ -n "$IMAGE_NAME" ]] && body+="$(_wiz_row "System image" "$(_html "${IMAGE_NAME}:${IMAGE_TAG:-?}${IMAGE_VERSION:+ (${IMAGE_VERSION})}")")"
    body+="$(_wiz_row "Hardware" "$(_html "${CHASSIS}${VIRT:+, virtual machine (${VIRT})}")")"
    body+="$(_wiz_row "Disk" "$disk")"
    body+="$(_wiz_row "Desktop" "$(_html "$( [[ $DESKTOP_ENV == kde ]] && echo "KDE Plasma" || echo "$DESKTOP_ENV")${DESKTOP_USER:+, user ${DESKTOP_USER}}")")"
    body+="$(_wiz_row "Found here" "${det:-nothing that changes the checks}")"
    body+="$(_wiz_row "Last full check" "$last")"
    body+="</table>"
    _wiz_page 0 "Security check-up" "For a home gaming and development PC · about a minute" "$body"
}

# _grade_color GRADE — the Breeze colour of a score grade.
_grade_color() {
    case "$1" in
        A|B) printf '%s' "$C_OK" ;;
        C)   printf '%s' "$C_LOW" ;;
        D)   printf '%s' "$C_MEDIUM" ;;
        *)   printf '%s' "$C_HIGH" ;;
    esac
}

# _hint KEY — " — detected: why" for a use case found on this PC.
_hint() {
    local h="${DETECTED[$1]:-}"
    [[ -n "$h" ]] && printf ' — detected: %s' "$h"
}

# _wiz_usecases — page 1: how the PC is used, pre-selected from what is installed.
_wiz_usecases() {
    local sel t
    sel=$(UI_CHOOSE_NOTE=0 UI_CHOOSE_LOWONLY=0 UI_CHOOSE_ALLOW_NONE=1 UI_CHOOSE_OK="Next" UI_CHOOSE_TITLE="How do you use this PC?" ui_checklist "$(_wiz_page 1 "How do you use this PC?" "Selected from what is installed. Click a row to change it." \
"<p>The check adapts to your answers: a service you use is reviewed, one you don't use is offered to be turned off, and a PC that leaves the house gets stricter ratings.</p>")" \
        gaming    "Gaming — Steam, Lutris, Heroic$(_hint gaming)"                              "$(_onoff "$USE_GAMING")" \
        streaming "Streaming games to other devices — Sunshine, Steam Remote Play$(_hint streaming)" "$(_onoff "$USE_STREAMING")" \
        dev       "Software development — containers, local dev servers$(_hint dev)"            "$(_onoff "$USE_DEV")" \
        ssh       "Logging in from other devices over SSH$(_hint ssh)"                           "$(_onoff "$USE_SSH")" \
        sharing   "Sharing files at home — Samba, Syncthing, KDE Connect$(_hint sharing)"       "$(_onoff "$USE_SHARING")" \
        portable  "A laptop or handheld that leaves the house$(_hint portable)"                 "$(_onoff "$USE_PORTABLE")") \
        || _wcancel
    USE_GAMING=0; USE_STREAMING=0; USE_DEV=0; USE_SSH=0; USE_SHARING=0; USE_PORTABLE=0
    while IFS= read -r t; do
        case "$t" in
            gaming) USE_GAMING=1 ;; streaming) USE_STREAMING=1 ;; dev) USE_DEV=1 ;;
            ssh) USE_SSH=1 ;; sharing) USE_SHARING=1 ;; portable) USE_PORTABLE=1 ;;
        esac
    done <<< "$sel"
}

# _wiz_options — page 2: fixes and depth.
_wiz_options() {
    local sel t
    sel=$(UI_CHOOSE_NOTE=0 UI_CHOOSE_LOWONLY=0 UI_CHOOSE_ALLOW_NONE=1 UI_CHOOSE_OK="Next" UI_CHOOSE_TITLE="Options" ui_checklist "$(_wiz_page 2 "Options" "Both can be changed next time." \
"<p><b>Offer fixes:</b> after the check you pick fixes from a list; each one is shown and confirmed before it runs. Deselect it for a report only.</p><p><b>Deep check:</b> also SUID files, autostart entries, /etc changes and a ClamAV scan of Downloads.</p>")" \
        fix  "Offer fixes (recommended)" \
             "$([[ $FIX_MODE == confirm ]] && echo on || echo off)" \
        deep "Deep check · several minutes" \
             "$(_onoff "$DEEP")") \
        || _wcancel
    FIX_MODE="report"; DEEP=0
    while IFS= read -r t; do
        case "$t" in fix) FIX_MODE="confirm" ;; deep) DEEP=1 ;; esac
    done <<< "$sel"
}

# _wiz_report — page 3: where the report goes.
_wiz_report() {
    local choice
    [[ -n "$REPORT_DIR" ]] || REPORT_DIR=$(_default_report_dir)
    if ! ui_yesno "$(_wiz_page 3 "Report" "An HTML and a Markdown report are saved after the check." \
"<p>Folder:</p><p>&nbsp;&nbsp;<b>$(_html "$REPORT_DIR")</b></p><p><i>Reports can contain host and user names; review one before sharing it.</i></p>")" \
        "Save here" "Choose another folder…" "y"; then
        choice=$(ui_dir "Report folder" "$REPORT_DIR") || choice=""
        if [[ "$choice" == /* ]]; then
            if _report_dir_usable "$choice"; then
                REPORT_DIR="$choice"
            else
                ui_error "${DESKTOP_USER} cannot write to ${choice}, so the report could not be saved there. Keeping ${REPORT_DIR}."
            fi
        fi
    fi
}

# _wiz_review_html — page 4: the answers, before anything runs.
_wiz_review_html() {
    local body="<table cellpadding=\"3\">"
    body+="$(_wiz_row "Use" "$(_html "$(_usecase_summary)")")"
    body+="$(_wiz_row "Depth" "$([[ $DEEP -eq 1 ]] && echo "Deep · several minutes" || echo "Standard · about a minute")")"
    body+="$(_wiz_row "Fixes" "$([[ $FIX_MODE == confirm ]] && echo "offered after the check - you pick them and confirm each one" || echo "none - report only")")"
    body+="$(_wiz_row "Report" "$(_html "$REPORT_DIR")")"
    body+="</table><p>Your answers are remembered for next time. Afterwards a dashboard shows the result of every check.</p>"
    _wiz_page 4 "Ready to check this PC" "Nothing has been checked or changed yet." "$body"
}

# _wizard_input — the Kirigami wizard's input: what this PC is, what was
# detected, and the current answers.
_wizard_input() {
    local k det=() use=()
    for k in gaming streaming dev ssh sharing portable; do
        [[ -n "${DETECTED[$k]:-}" ]] && det+=("$k" "${DETECTED[$k]}")
    done
    [[ "$USE_GAMING" -eq 1 ]] && use+=(gaming); [[ "$USE_STREAMING" -eq 1 ]] && use+=(streaming)
    [[ "$USE_DEV" -eq 1 ]] && use+=(dev); [[ "$USE_SSH" -eq 1 ]] && use+=(ssh)
    [[ "$USE_SHARING" -eq 1 ]] && use+=(sharing); [[ "$USE_PORTABLE" -eq 1 ]] && use+=(portable)
    local disk="${DISK_ENCRYPTED:-unknown}" last=""
    [[ -n "$LAST_RUN_ID" ]] && last="$(_run_date "$LAST_RUN_ID") · ${LAST_SCORE}/100 (grade ${LAST_GRADE})"
    python3 -I -c '
import json, sys
a = sys.argv[1:]
i = a.index("--det"); j = a.index("--use")
facts = dict(zip(a[0:i:2], a[1:i:2]))
det = dict(zip(a[i + 1:j:2], a[i + 2:j:2]))
print(json.dumps({"facts": facts, "detected": det,
                  "answers": {"use": a[j + 1:-3], "fix": a[-3] == "confirm", "deep": a[-2] == "1", "report_dir": a[-1]}}))' \
        os "${OS_PRETTY:-unknown}" image "${IMAGE_NAME:+${IMAGE_NAME}:${IMAGE_TAG:-?}${IMAGE_VERSION:+ (${IMAGE_VERSION})}}" \
        hardware "${CHASSIS}${VIRT:+, virtual machine (${VIRT})}" disk "$disk" last "$last" \
        --det "${det[@]}" --use "${use[@]}" "$FIX_MODE" "$DEEP" "$REPORT_DIR"
}

# _wizard_answer JSON — the wizard's answer, checked: prints shell-safe
# lines "use LIST", "fix 0|1", "deep 0|1", "action start|settings" and
# "dir PATH" (status 1 for anything else).
_wizard_answer() {
    python3 -I -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
known = {"gaming", "streaming", "dev", "ssh", "sharing", "portable"}
use, fix, deep, act, rd = d.get("use"), d.get("fix"), d.get("deep"), d.get("action"), d.get("report_dir")
if not (isinstance(use, list) and all(u in known for u in use) and isinstance(fix, bool)
        and isinstance(deep, bool) and act in ("start", "settings")
        and isinstance(rd, str) and rd.startswith("/") and "\n" not in rd and "\x00" not in rd and len(rd) < 4096):
    sys.exit(1)
print("use", ",".join(sorted(set(use))))
print("fix", int(fix)); print("deep", int(deep)); print("action", act)
print("dir", rd)' "$1"
}

# _wizard_app — the Kirigami wizard. Status 0 done, 1 cancelled, 3 or 4 it
# cannot run here (the kdialog wizard is used instead).
_wizard_app() {
    local out rc key val action=""
    while :; do
        [[ -n "$REPORT_DIR" ]] || REPORT_DIR=$(_default_report_dir)
        out=$(ui_app wizard "$(_wizard_input)")
        rc=$?
        # 3: the front end could not run here; do not try it again.
        [[ $rc -eq 3 ]] && _QML_OK=no
        [[ $rc -eq 0 ]] || return "$rc"
        # An answer that does not pass the checks: use the kdialog wizard.
        if ! out=$(_wizard_answer "$out"); then
            log "wizard: front-end answer rejected; using the kdialog wizard"
            _QML_OK=no
            return 3
        fi
        while read -r key val; do
            case "$key" in
                use)
                    USE_GAMING=0; USE_STREAMING=0; USE_DEV=0; USE_SSH=0; USE_SHARING=0; USE_PORTABLE=0
                    [[ ",$val," == *,gaming,* ]] && USE_GAMING=1; [[ ",$val," == *,streaming,* ]] && USE_STREAMING=1
                    [[ ",$val," == *,dev,* ]] && USE_DEV=1; [[ ",$val," == *,ssh,* ]] && USE_SSH=1
                    [[ ",$val," == *,sharing,* ]] && USE_SHARING=1; [[ ",$val," == *,portable,* ]] && USE_PORTABLE=1 ;;
                fix)    if [[ "$val" == 1 ]]; then FIX_MODE="confirm"; else FIX_MODE="report"; fi ;;
                deep)   DEEP="$val" ;;
                action) action="$val" ;;
                dir)
                    if [[ "$val" != "$REPORT_DIR" ]]; then
                        if _report_dir_usable "$val"; then REPORT_DIR="$val"
                        else ui_error "${DESKTOP_USER} cannot write to ${val}, so the report could not be saved there. Keeping ${REPORT_DIR}."; fi
                    fi ;;
            esac
        done <<< "$out"
        [[ "$action" == settings ]] || return 0
        # Settings from the welcome page: show them, then the wizard again.
        run_settings
    done
}

run_wizard() {
    local rc=0
    _wizard_app || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) _wcancel ;;
    esac
    ui_yesno "$(_overview_html)" "Get started" "Quit" "y" || _wcancel
    while :; do
        _wiz_usecases
        _wiz_options
        _wiz_report
        ui_choice3 "$(_wiz_review_html)" "" "Start the check" "Change answers…" "Quit" "" y
        rc=$?
        case "$rc" in
            0) return 0 ;;
            # Back to page 1 (with no one left to ask, start as answered).
            1) ui_interactive || return 0 ;;
            *) _wcancel ;;
        esac
    done
}
