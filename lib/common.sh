# shellcheck shell=bash
# Shared helpers: terminal output, findings, JSON/HTML escaping, the
# desktop-user session bridge and the facts every check can rely on.

# Bash 5.2 treats "&" in ${var//pattern/replacement} as the matched text;
# every replacement in this tool means a literal "&".
shopt -u patsub_replacement 2>/dev/null || true

# ====================== OUTPUT ======================
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'
    BOLD=$'\e[1m'; RESET=$'\e[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

# print_status OK|WARN|ERR|INFO MESSAGE — one line on the terminal, and in the run log.
print_status() {
    local type="$1" msg="$2" sym
    case "$type" in
        OK)   sym="${GREEN}[✓]${RESET}" ;;
        WARN) sym="${YELLOW}[!]${RESET}" ;;
        ERR)  sym="${RED}[✗]${RESET}" ;;
        *)    sym="${BLUE}[i]${RESET}" ;;
    esac
    [[ "${QUIET:-0}" -eq 1 && "$type" != "ERR" ]] || printf '%s %s\n' "$sym" "$msg"
    log "[$type] $msg"
}

# log TEXT — append to the run log (no-op until the log exists).
log() {
    [[ -n "${RUN_LOG:-}" ]] || return 0
    printf '%s %s\n' "$(date '+%H:%M:%S')" "$1" >> "$RUN_LOG" 2>/dev/null || true
}

# ====================== ESCAPING ======================
# _json_str TEXT — TEXT as a JSON string literal (with quotes).
_json_str() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    if [[ "$s" == *[[:cntrl:]]* ]]; then
        s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037\177')
    fi
    printf '"%s"' "$s"
}

# _html TEXT — TEXT escaped for HTML (and for KDE rich-text dialogs).
_html() {
    local s="$1"
    s=${s//&/"&amp;"}
    s=${s//</"&lt;"}
    s=${s//>/"&gt;"}
    s=${s//\"/"&quot;"}
    printf '%s' "$s"
}

# _reflow_html TEXT — TEXT escaped for HTML, with the source's hard line
# wraps joined into flowing lines. Real breaks are kept: blank lines, list
# items ("- ...") and lines after one ending in ":".
_reflow_html() {
    _html "$1" | awk '
        {
            line = $0
            if (NR == 1) { out = line; prev = line; next }
            if (line == "" || prev == "" || line ~ /^[ \t]*(- |• |[0-9]+\. )/ || prev ~ /^[ \t]*(- |• |[0-9]+\. )/ \
                || prev ~ /:$/ || line ~ /^ {2,}/) {
                out = out "<br>" line
            } else {
                out = out " " line
            }
            prev = line
        }
        END { printf "%s", out }'
}

# _q WORD — WORD quoted for use in a generated shell command.
_q() { printf '%q' "$1"; }

# _pyjson EXPR — evaluate a Python expression over the JSON document on
# stdin (bound to d). Lists print one item per line, booleans as
# true/false, None as nothing. Only constant expressions from this tool
# are passed in.
_pyjson() {
    python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
try:
    r = eval(sys.argv[1], {"d": d, "len": len, "str": str, "int": int, "any": any, "all": all, "sorted": sorted})
except Exception:
    sys.exit(4)
def out(v):
    if v is None: return
    if isinstance(v, bool): print("true" if v else "false"); return
    if isinstance(v, (list, tuple)):
        for x in v: out(x)
        return
    if isinstance(v, dict): print(json.dumps(v)); return
    print(v)
out(r)' "$1"
}

# ====================== FINDINGS ======================
# One entry per finding in each array:
#   F_NOW / F_AFTER  the setting as it is now, and as the fix (or the manual
#                    steps) leave it - one short line each (finding_change)
#   F_WARN           side effects to know before applying the fix, one per
#                    line as "short tag|full sentence"
#   F_STATE          open | fixed | skipped | failed
#   F_VERIFY         for applied fixes: verified | still | reboot | unchecked
#   F_RECHECK        what the check found when it ran again after the fix
declare -ga F_SEV=() F_CHECK=() F_TITLE=() F_DETAIL=() F_MANUAL=() F_FIX=() F_STATE=()
declare -ga F_NOW=() F_AFTER=() F_WARN=() F_VERIFY=() F_RECHECK=()
declare -gA CHECK_STATUS=() CHECK_FAILED=() CHECK_ERRORS=()
declare -gA CHECK_SKIPPED=() CHECK_NA=() CHECK_NOTE=()
CURRENT_CHECK=""

# Side effects that many fixes share ("short tag|what it means").
readonly W_REBOOT="needs a reboot|Takes effect only after you restart the PC. Until then the problem is still there."
readonly W_NOUNDO="no undo|This change cannot be undone automatically."
readonly W_DOWNLOAD="downloads|Downloads data while the fix runs; this can take several minutes."

_sev_points() {
    case "$1" in high) echo 10 ;; medium) echo 5 ;; low) echo 2 ;; *) echo 0 ;; esac
}

_sev_rank() {
    case "$1" in high) echo 0 ;; medium) echo 1 ;; low) echo 2 ;; *) echo 3 ;; esac
}

_sev_label() {
    case "$1" in high) echo "HIGH" ;; medium) echo "MEDIUM" ;; low) echo "LOW" ;; *) echo "INFO" ;; esac
}

# Colours for KDE dialogs (Breeze's palette; readable on light and dark).
readonly C_HIGH="#da4453" C_MEDIUM="#f67400" C_LOW="#1d99f3" C_INFO="#7f8c8d" C_OK="#27ae60"

_sev_color() {
    case "$1" in high) echo "$C_HIGH" ;; medium) echo "$C_MEDIUM" ;; low) echo "$C_LOW" ;; ok) echo "$C_OK" ;; *) echo "$C_INFO" ;; esac
}

# _badge SEVERITY — the severity as a coloured label for rich text.
_badge() { printf '<font color="%s"><b>%s</b></font>' "$(_sev_color "$1")" "$(_sev_label "$1")"; }

# finding SEVERITY TITLE DETAIL MANUAL [FIX_FUNCTION ARGS...]
#   SEVERITY  high | medium | low | info (info never lowers the score)
#   DETAIL    what was found and why it matters
#   MANUAL    how to fix it by hand (shown in the report either way)
#   FIX_...   a function that offers to fix it, with confirmation
finding() {
    local sev="$1" title="$2" detail="$3" manual="$4" fix="" id="${CURRENT_CHECK:-unknown}"
    shift 4
    if [[ $# -gt 0 ]]; then
        fix=$(printf '%q ' "$@")
        fix="${fix% }"
    fi
    F_SEV+=("$sev")
    F_CHECK+=("$id")
    F_TITLE+=("$title")
    F_DETAIL+=("$detail")
    F_MANUAL+=("$manual")
    F_FIX+=("$fix")
    F_STATE+=("open")
    F_NOW+=(""); F_AFTER+=(""); F_WARN+=(""); F_VERIFY+=(""); F_RECHECK+=("")
    [[ "$sev" != "info" ]] && CHECK_FAILED["$id"]=1
    record_finding "$id" "$title" "$sev" "$detail"
    if [[ "${VERBOSE:-0}" -eq 1 ]]; then
        print_status "WARN" "[$(_sev_label "$sev")] ${title}"
    fi
    return 0
}

# finding_change NOW AFTER [WARNING...] — for the finding just added: the
# setting as it is now and as the fix (or the manual steps) would leave it,
# one short line each, read from the system rather than assumed. WARNINGs
# are side effects to know before applying, each "short tag|full sentence"
# (see W_REBOOT and friends). Shown in the fix list, the fix dialog, the
# dashboard and the report.
finding_change() {
    local i=$(( ${#F_SEV[@]} - 1 )) w
    (( i >= 0 )) || return 0
    F_NOW[i]="${1//$'\n'/ }"
    F_AFTER[i]="${2//$'\n'/ }"
    shift 2
    for w in "$@"; do
        [[ -n "$w" ]] && F_WARN[i]+="${F_WARN[i]:+$'\n'}${w//$'\n'/ }"
    done
    return 0
}

# _warn_tag WARNING / _warn_text WARNING — the short and the long part.
_warn_tag() { printf '%s' "${1%%|*}"; }
_warn_text() { printf '%s' "${1#*|}"; }

# check_note TEXT — context for a check (shown in the report even when it passes).
check_note() {
    local id="${CURRENT_CHECK:-unknown}"
    CHECK_NOTE["$id"]+="${CHECK_NOTE[$id]:+$'\n'}$1"
}

# mark_na REASON — this check does not apply to this PC.
mark_na() {
    [[ -n "$CURRENT_CHECK" ]] && CHECK_NA["$CURRENT_CHECK"]="$1"
    [[ "${VERBOSE:-0}" -eq 1 ]] && print_status "INFO" "${CURRENT_CHECK}: not applicable ($1)"
    return 0
}

# mark_skip REASON — this check could not be performed (tool missing, offline, ...).
mark_skip() {
    [[ -n "$CURRENT_CHECK" ]] && CHECK_SKIPPED["$CURRENT_CHECK"]="$1"
    print_status "INFO" "${CURRENT_CHECK}: skipped ($1)"
    return 0
}

# _ctx PORTABLE_SEV HOME_SEV — pick a severity by how the PC is used: a
# laptop or handheld that leaves the house gets the stricter one.
_ctx() {
    if [[ "${USE_PORTABLE:-0}" -eq 1 ]]; then echo "$1"; else echo "$2"; fi
}

# record_finding CHECK TITLE STATUS EVIDENCE — one JSON line per result.
record_finding() {
    [[ -n "${FINDINGS_FILE:-}" ]] || return 0
    printf '{"check_id": %s, "title": %s, "status": %s, "evidence": %s, "time": %s}\n' \
        "$(_json_str "$1")" "$(_json_str "$2")" "$(_json_str "$3")" "$(_json_str "$4")" \
        "$(_json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" >> "$FINDINGS_FILE" 2>/dev/null || true
}

# ====================== FILE HELPERS ======================
# _r PATH — PATH under AUDIT_ROOT (empty in real runs; tests point it at fixtures).
_r() { printf '%s%s' "${AUDIT_ROOT:-}" "$1"; }

# _ini_parse SECTION KEY — last value of KEY in [SECTION] of the INI text
# on stdin.
_ini_parse() {
    awk -v sec="$1" -v key="$2" '
        /^[ \t]*[#;]/ { next }
        /^[ \t]*\[/ { s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); insec = (s == sec); next }
        insec {
            line = $0
            i = index(line, "=")
            if (i == 0) next
            k = substr(line, 1, i - 1); v = substr(line, i + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (k == key) val = v
        }
        END { if (val != "") print val }' 2>/dev/null || true
}

# _ini_get FILE SECTION KEY — the same for a system file.
_ini_get() {
    [[ -f "$1" ]] || return 0
    _ini_parse "$2" "$3" < "$1"
}

# _user_cat USER FILE — FILE from USER's home, read as USER. Root never
# opens a path an account controls: a link planted there would make root
# read (and report on) a file that account may not see.
_user_cat() {
    _as_user "$1" cat -- "$2" 2>/dev/null < /dev/null || true
}

# _root_cat FILE — a file root owns that sits in a home folder (a deploy key
# copied in with sudo), read as root: only when it is a regular file owned
# by root, opened without following a link planted in its place.
_root_cat() {
    python3 -I -c '
import os, stat, sys
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    st = os.fstat(fd)
    if stat.S_ISREG(st.st_mode) and st.st_uid == 0:
        sys.stdout.buffer.write(os.read(fd, 65536))
except OSError:
    pass' "$1" 2>/dev/null || true
}

# _user_ini_get USER FILE SECTION KEY — _ini_get for a file in USER's home.
_user_ini_get() {
    _user_cat "$1" "$2" | _ini_parse "$3" "$4"
}

# _is_admin_user USER — USER may administer this PC (wheel or sudo group).
_is_admin_user() {
    id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qxE 'wheel|sudo'
}

# _mode PATH — octal permission bits of PATH (empty when it does not exist).
_mode() { stat -c '%a' -- "$1" 2>/dev/null || true; }

# _owner PATH — owner name of PATH.
_owner() { stat -c '%U' -- "$1" 2>/dev/null || true; }

# _join SEP ITEMS... — ITEMS joined by SEP.
_join() {
    local sep="$1" out="" x
    shift
    for x in "$@"; do out+="${out:+$sep}$x"; done
    printf '%s' "$out"
}

# _have CMD — CMD is installed.
_have() { command -v "$1" >/dev/null 2>&1; }

# _unit_state UNIT — "enabled", "disabled", "masked", ... or "missing".
_unit_state() {
    local s
    s=$(systemctl is-enabled "$1" 2>/dev/null) || true
    [[ -n "$s" ]] || s="missing"
    printf '%s' "$s"
}

_unit_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# ====================== DESKTOP USER ======================
# The audit runs as root, but dialogs, user services and per-user files
# belong to the person at the desktop. AUDIT_DESKTOP_USER is passed on by
# the launcher before it asks for administrator rights.
DESKTOP_USER=""
DESKTOP_UID=""
DESKTOP_HOME=""
declare -ga REGULAR_USERS=()

_uid_min() {
    local v
    v=$(awk '$1 == "UID_MIN" {print $2; exit}' "$(_r /etc/login.defs)" 2>/dev/null || true)
    [[ "$v" =~ ^[0-9]+$ ]] || v=1000
    echo "$v"
}

# _list_regular_users — people's accounts: UID_MIN..59999, a login shell and a home.
_list_regular_users() {
    local min
    min=$(_uid_min)
    getent passwd 2>/dev/null | awk -F: -v min="$min" '
        $3 >= min && $3 < 60000 && $7 !~ /(nologin|false)$/ { print $1 }' || true
}

_home_of() { getent passwd "$1" 2>/dev/null | cut -d: -f6 || true; }

_is_regular_user() {
    local u="$1" x
    for x in "${REGULAR_USERS[@]}"; do [[ "$x" == "$u" ]] && return 0; done
    return 1
}

detect_desktop_user() {
    mapfile -t REGULAR_USERS < <(_list_regular_users)
    local cand="" s
    for cand in "${AUDIT_DESKTOP_USER:-}" "${SUDO_USER:-}" \
                "$( [[ -n "${PKEXEC_UID:-}" ]] && id -nu "$PKEXEC_UID" 2>/dev/null )"; do
        if [[ -n "$cand" && "$cand" != "root" ]] && _is_regular_user "$cand"; then
            DESKTOP_USER="$cand"
            break
        fi
    done
    # Fallback (the weekly check): the owner of the active graphical
    # session - when that is an administrator. The report names sudo rules
    # and other accounts' files, so it is not handed to whoever happens to
    # be logged in.
    if [[ -z "$DESKTOP_USER" ]] && _have loginctl; then
        while read -r s; do
            [[ -n "$s" ]] || continue
            if [[ "$(loginctl show-session "$s" -p Active --value 2>/dev/null)" == "yes" ]] \
               && [[ "$(loginctl show-session "$s" -p Type --value 2>/dev/null)" =~ ^(wayland|x11)$ ]]; then
                cand=$(loginctl show-session "$s" -p Name --value 2>/dev/null || true)
                if [[ -n "$cand" ]] && _is_regular_user "$cand" && _is_admin_user "$cand"; then
                    DESKTOP_USER="$cand"
                    break
                fi
            fi
        done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
    fi
    if [[ -n "$DESKTOP_USER" ]]; then
        DESKTOP_UID=$(id -u "$DESKTOP_USER")
        DESKTOP_HOME=$(_home_of "$DESKTOP_USER")
    fi
}

# _user_env USER — fill _UENV with a clean environment for USER's desktop session.
_user_env() {
    local u="$1" uid home rt wl="" x11="${AUDIT_GUI_DISPLAY:-}" xa="${AUDIT_GUI_XAUTHORITY:-}" f
    uid=$(id -u "$u" 2>/dev/null) || return 1
    home=$(_home_of "$u")
    rt="/run/user/${uid}"
    # AUDIT_TEST_PATH lets the test suite put its stub commands first.
    _UENV=(PATH="${AUDIT_TEST_PATH:+${AUDIT_TEST_PATH}:}/usr/local/bin:/usr/bin:/bin" HOME="$home" USER="$u" LOGNAME="$u"
           LANG="${LANG:-C.UTF-8}" XDG_RUNTIME_DIR="$rt"
           DBUS_SESSION_BUS_ADDRESS="unix:path=${rt}/bus")
    if [[ "$u" == "$DESKTOP_USER" ]]; then
        wl="${AUDIT_GUI_WAYLAND:-}"
        if [[ -z "$wl" ]]; then
            for f in "$rt"/wayland-[0-9]; do
                [[ -S "$f" ]] && { wl="${f##*/}"; break; }
            done
        fi
        [[ -z "$x11" && -S /tmp/.X11-unix/X0 ]] && x11=":0"
        if [[ -z "$xa" ]]; then
            for f in "$rt"/xauth_*; do [[ -f "$f" ]] && { xa="$f"; break; }; done
        fi
        [[ -n "$wl" ]] && _UENV+=(WAYLAND_DISPLAY="$wl")
        [[ -n "$x11" ]] && _UENV+=(DISPLAY="$x11")
        [[ -n "$xa" ]] && _UENV+=(XAUTHORITY="$xa")
        if [[ -n "$wl" ]]; then _UENV+=(XDG_SESSION_TYPE=wayland); else _UENV+=(XDG_SESSION_TYPE=x11); fi
    fi
}

# _no_tty CMD... — run CMD in a session of its own, without this terminal as
# its controlling terminal: a program running as another account must not
# be able to type into the administrator's terminal (TIOCSTI).
_no_tty() {
    if _have setsid; then setsid --wait "$@"; else "$@"; fi
}

# _as_user USER CMD... — run CMD as USER in USER's session environment.
_as_user() {
    local u="$1"
    shift
    local -a _UENV=()
    _user_env "$u" || return 1
    if [[ "$(id -u)" -eq "$(id -u "$u")" ]]; then
        env -i "${_UENV[@]}" "$@"
    else
        _no_tty runuser -u "$u" -- env -i "${_UENV[@]}" "$@"
    fi
}

_as_desktop_user() {
    [[ -n "$DESKTOP_USER" ]] || return 1
    _as_user "$DESKTOP_USER" "$@"
}

# _user_unit_state USER UNIT — enabled/disabled/... of a systemd --user unit.
_user_unit_state() {
    local u="$1" unit="$2" s="" home
    s=$(systemctl --user -M "${u}@" is-enabled "$unit" 2>/dev/null) || true
    if [[ -z "$s" ]]; then
        # User manager not running (not logged in): look at the unit links.
        home=$(_home_of "$u")
        if compgen -G "${home}/.config/systemd/user/*.wants/${unit}" >/dev/null 2>&1 \
           || compgen -G "${home}/.config/systemd/user/*.wants/${unit}.service" >/dev/null 2>&1; then
            s="enabled"
        else
            s="unknown"
        fi
    fi
    printf '%s' "$s"
}

_user_unit_active() {
    systemctl --user -M "${1}@" is-active --quiet "$2" 2>/dev/null
}

# ====================== FACTS ======================
# Gathered once; checks and the wizard adapt to them.
OS_ID=""; OS_PRETTY=""; IS_BAZZITE=0; IS_OSTREE=0; IS_DECK=0
IMAGE_NAME=""; IMAGE_VENDOR=""; IMAGE_TAG=""; IMAGE_VERSION=""; BASE_IMAGE_NAME=""
DESKTOP_ENV="other"; CHASSIS="unknown"; IS_PORTABLE_HW=0
DISK_ENCRYPTED="unknown"   # yes | no | unknown
RPMOSTREE_JSON=""
VIRT=""

_detect_chassis() {
    local c="" t="" vendor=""
    if _have hostnamectl; then
        c=$(hostnamectl chassis 2>/dev/null || true)
    fi
    if [[ -z "$c" ]]; then
        t=$(cat "$(_r /sys/class/dmi/id/chassis_type)" 2>/dev/null || true)
        case "$t" in
            8|9|10|14) c="laptop" ;;
            30|31|32)  c="tablet" ;;
            3|4|5|6|7|13|15|16|35|36) c="desktop" ;;
        esac
    fi
    vendor=$(cat "$(_r /sys/class/dmi/id/sys_vendor)" 2>/dev/null || true)
    [[ "$vendor" == "Valve" ]] && c="handset"
    printf '%s' "${c:-unknown}"
}

# _root_source_encrypted — "yes" when the filesystem holding /var/home sits
# on a LUKS (crypt) device, "no" when it does not, "unknown" otherwise.
_root_source_encrypted() {
    local target src
    for target in /var/home /home /var /; do
        [[ -e "$target" ]] && break
    done
    src=$(findmnt -n -o SOURCE -T "$target" 2>/dev/null | head -n1 || true)
    src="${src%%\[*}"
    if [[ -z "$src" || "$src" != /dev/* ]]; then
        echo "unknown"
        return 0
    fi
    if lsblk -s -n -o TYPE -- "$src" 2>/dev/null | grep -qx 'crypt'; then
        echo "yes"
    elif lsblk -s -n -o TYPE -- "$src" >/dev/null 2>&1; then
        echo "no"
    else
        echo "unknown"
    fi
}

gather_facts() {
    local osr info
    osr="$(_r /etc/os-release)"
    [[ -f "$osr" ]] || osr="$(_r /usr/lib/os-release)"
    OS_ID=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2}' "$osr" 2>/dev/null || true)
    OS_PRETTY=$(awk -F= '$1 == "PRETTY_NAME" {gsub(/"/, "", $2); print $2}' "$osr" 2>/dev/null || true)
    [[ -e "$(_r /run/ostree-booted)" ]] && IS_OSTREE=1

    info="$(_r /usr/share/ublue-os/image-info.json)"
    if [[ -f "$info" ]]; then
        IMAGE_NAME=$(_pyjson 'd.get("image-name", "")' < "$info" 2>/dev/null || true)
        IMAGE_VENDOR=$(_pyjson 'd.get("image-vendor", "")' < "$info" 2>/dev/null || true)
        IMAGE_TAG=$(_pyjson 'd.get("image-tag", "")' < "$info" 2>/dev/null || true)
        IMAGE_VERSION=$(_pyjson 'd.get("version-pretty") or d.get("version", "")' < "$info" 2>/dev/null || true)
        BASE_IMAGE_NAME=$(_pyjson 'd.get("base-image-name", "")' < "$info" 2>/dev/null || true)
    fi
    [[ "$OS_ID" == "bazzite" || "$IMAGE_NAME" == bazzite* ]] && IS_BAZZITE=1
    [[ "$IMAGE_NAME" == *deck* ]] && IS_DECK=1

    if [[ "$BASE_IMAGE_NAME" == kinoite* ]] || _have plasmashell; then
        DESKTOP_ENV="kde"
    elif [[ "$BASE_IMAGE_NAME" == silverblue* ]] || _have gnome-shell; then
        DESKTOP_ENV="gnome"
    fi

    CHASSIS=$(_detect_chassis)
    case "$CHASSIS" in laptop|convertible|tablet|handset|watch) IS_PORTABLE_HW=1 ;; esac

    if _have systemd-detect-virt; then
        VIRT=$(systemd-detect-virt 2>/dev/null || true)
        [[ "$VIRT" == "none" ]] && VIRT=""
    fi

    DISK_ENCRYPTED=$(_root_source_encrypted)

    if [[ "$IS_OSTREE" -eq 1 ]] && _have rpm-ostree; then
        RPMOSTREE_JSON=$(timeout 60 rpm-ostree status --json 2>/dev/null || true)
    fi
}

# _deploy EXPR — evaluate EXPR over the booted deployment (bound to b) and
# the whole status (d). Empty when rpm-ostree status is unavailable.
_deploy() {
    [[ -n "$RPMOSTREE_JSON" ]] || return 0
    _pyjson "(lambda b: ($1))(next((x for x in d.get(\"deployments\", []) if x.get(\"booted\")), {}))" \
        <<< "$RPMOSTREE_JSON" 2>/dev/null || true
}
