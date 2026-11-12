# shellcheck shell=bash
# User interface: KDE dialogs (kdialog, shown in the desktop user's session)
# with a terminal fallback. Every function works in three modes:
#   kde   kdialog windows on the user's Plasma desktop
#   tty   questions on the terminal
#   none  no one to ask (systemd timer): questions get their safe default,
#         which never changes anything.

UI_MODE="none"
UI_PREF="${UI_PREF:-auto}"     # auto | gui | tty (from --gui / --no-gui)
UI_TITLE="Bazzite Security Check"
_PROGRESS_REF=""
_QML_OK=""             # "", "yes" or "no": can the Kirigami front end run?
_UI_THEME_DIR=""       # config folder that gives kdialog the chosen theme

# _desktop_display_ok — the desktop user has a Wayland or X11 display we can reach.
_desktop_display_ok() {
    [[ -n "$DESKTOP_UID" ]] || return 1
    local f
    if [[ -n "${AUDIT_GUI_WAYLAND:-}" && -S "/run/user/${DESKTOP_UID}/${AUDIT_GUI_WAYLAND}" ]]; then
        return 0
    fi
    for f in /run/user/"${DESKTOP_UID}"/wayland-[0-9]; do
        [[ -S "$f" ]] && return 0
    done
    [[ -n "${AUDIT_GUI_DISPLAY:-}" || -S /tmp/.X11-unix/X0 ]]
}

_tty_ok() { [[ -t 0 ]] && [[ -r /dev/tty ]]; }

ui_init() {
    UI_MODE="none"
    if [[ "$UI_PREF" != "tty" ]] && _have kdialog && _desktop_display_ok; then
        UI_MODE="kde"
    elif [[ "$UI_PREF" != "gui" ]] && _tty_ok; then
        UI_MODE="tty"
    elif [[ "$UI_PREF" == "gui" ]] && _tty_ok; then
        print_status "WARN" "No KDE session or kdialog found - using the terminal instead"
        UI_MODE="tty"
    fi
    log "UI mode: ${UI_MODE}"
}

ui_interactive() { [[ "$UI_MODE" != "none" ]]; }

# _ui_fallback — kdialog cannot be used: continue on the terminal, or with
# safe defaults when there is none.
_ui_fallback() {
    if _tty_ok; then UI_MODE="tty"; else UI_MODE="none"; fi
}

# _ui_icon — the app icon: its name once installed, else a stock one.
_ui_icon() {
    if [[ -f "/usr/local/share/icons/hicolor/scalable/apps/bazzite-security-check.svg" ]]; then
        echo bazzite-security-check
    else
        echo security-high
    fi
}

# _ui_app_cmd — the Kirigami front end, run as the desktop user (never as
# root) with the chosen theme.
_ui_app_cmd() {
    _as_desktop_user env BSA_THEME="${UI_THEME:-system}" python3 -I "$SCRIPT_DIR/ui/app.py" "$@"
}

# _qml_ok — the Kirigami front end can run here: KDE dialogs are in use,
# and PySide6 and Kirigami are installed (checked once).
_qml_ok() {
    if [[ -z "$_QML_OK" ]]; then
        _QML_OK=no
        if [[ "$UI_MODE" == "kde" && -f "$SCRIPT_DIR/ui/app.py" ]] \
           && compgen -G "/usr/lib*/qt6/qml/org/kde/kirigami" >/dev/null \
           && _as_desktop_user python3 -I -c 'import PySide6.QtQml, PySide6.QtWidgets' >/dev/null 2>&1; then
            _QML_OK=yes
        fi
    fi
    [[ "$_QML_OK" == yes ]]
}

# ui_app MODE JSON — show the Kirigami front end (wizard or settings) with
# JSON as its input; prints its answer. Status 0 answered, 1 cancelled,
# 3 it could not run, 4 not available here. The caller validates the answer.
ui_app() {
    _qml_ok || return 4
    local out rc=0
    out=$(_ui_app_cmd "$1" <<< "$2" 2>>"${RUN_LOG:-/dev/null}") || rc=$?
    [[ $rc -eq 3 ]] && _QML_OK=no
    printf '%s' "$out"
    return "$rc"
}

# ui_theme_prepare — make (once, and again after Settings) the folder that
# gives kdialog the chosen theme: a copy of the person's kdeglobals with
# that theme's colours, made by the desktop user in their own ~/.cache.
ui_theme_prepare() {
    _UI_THEME_DIR=""
    [[ "${UI_THEME:-system}" != system && "$UI_MODE" == kde && -n "$DESKTOP_USER" ]] || return 0
    local d home
    d=$(_as_desktop_user python3 -I "$SCRIPT_DIR/ui/app.py" theme-dir "$UI_THEME" 2>/dev/null) || d=""
    home=$(_home_of "$DESKTOP_USER")
    # Only a folder in that person's home is used.
    [[ -n "$home" && "$d" == "$home"/* && "$d" != *$'\n'* && "$d" != *..* ]] && _UI_THEME_DIR="$d"
    return 0
}

# _ui_theme_env — "XDG_CONFIG_HOME=DIR" for kdialog (nothing for "system").
_ui_theme_env() {
    [[ -n "$_UI_THEME_DIR" ]] && printf 'XDG_CONFIG_HOME=%s' "$_UI_THEME_DIR"
    return 0
}

# _kd ARGS... — run kdialog as the desktop user. When kdialog itself fails
# (no display, crash: exit status above 2) the UI drops to the terminal and
# 255 is returned so the caller can ask again there. A caller that runs _kd
# in $(...) must call _ui_fallback itself on 255: the subshell's switch is
# lost when it ends. The failure is also remembered in RUN_TMP, which every
# later call sees, so a broken kdialog is not started again and again.
_kd() {
    local rc=0 flag="${RUN_TMP:+${RUN_TMP}/kdialog-failed}"
    if [[ -n "$flag" && -e "$flag" ]]; then
        _ui_fallback
        return 255
    fi
    local theme
    theme=$(_ui_theme_env)
    _as_desktop_user env ${theme:+"$theme"} kdialog --title "$UI_TITLE" --icon "$(_ui_icon)" "$@" 2>/dev/null || rc=$?
    if (( rc > 2 )); then
        log "kdialog failed (exit ${rc}); falling back"
        if [[ -n "$flag" ]]; then : > "$flag"; fi
        _ui_fallback
        return 255
    fi
    return "$rc"
}

# _rich TEXT — plain text as KDE rich text (escaped, line breaks kept).
_rich() { _reflow_html "$1"; }

# _ui_offered STEP ANSWER ITEM... — the lines of ANSWER that are tags of the
# ITEMs (each STEP words long, the tag first). kdialog runs as the desktop
# user, so root only takes an answer that is one of the choices it offered:
# never a path, a command or a finding that was not on the list.
_ui_offered() {
    local step="$1" answer="$2" line i
    shift 2
    local -a items=("$@")
    local -A tag=()
    for (( i = 0; i < ${#items[@]}; i += step )); do
        [[ -n "${items[$i]}" ]] && tag["${items[$i]}"]=1
    done
    while IFS= read -r line; do
        [[ -n "$line" && -n "${tag[$line]+x}" ]] && printf '%s\n' "$line"
    done <<< "$answer"
    return 0
}

# _ui_sync — a kdialog that failed inside $(...) only switched the UI off
# KDE in that subshell; make the switch here too.
_ui_sync() {
    if [[ "$UI_MODE" == "kde" && -n "${RUN_TMP:-}" && -e "${RUN_TMP}/kdialog-failed" ]]; then
        _ui_fallback
    fi
    return 0
}

# Dialog texts are plain text, or rich text when they start with "<html>"
# (built with _html, _rich and _pre). _ui_html gives the KDE version,
# _ui_plain the terminal version of either.
_ui_html() {
    if [[ "$1" == "<html>"* ]]; then printf '%s' "$1"; else printf '<html>%s</html>' "$(_rich "$1")"; fi
}

_ui_plain() {
    if [[ "$1" == "<html>"* ]]; then _html2text "$1"; else printf '%s' "$1"; fi
}

# _html2text HTML — the terminal version of a rich-text dialog: tags become
# line breaks and indents, <pre> blocks are indented, entities decoded.
_html2text() {
    python3 -I -c '
import html, re, sys
s = sys.argv[1]
s = re.sub(r"(?is)<pre[^>]*>(.*?)</pre>",
           lambda m: "\n" + "\n".join("    " + l for l in m.group(1).split("\n")) + "\n", s)
s = re.sub(r"(?i)<br\s*/?>", "\n", s)
s = re.sub(r"(?i)<hr[^>]*>", "\n" + "-" * 64 + "\n", s)
s = re.sub(r"(?i)<li[^>]*>", "\n  - ", s)
s = re.sub(r"(?i)<h[1-6][^>]*>", "\n", s)
s = re.sub(r"(?i)</(p|div|h[1-6]|tr|table|ul|ol)>", "\n", s)
s = re.sub(r"(?i)</t[dh]>", "  ", s)
s = re.sub(r"<[^>]+>", "", s)
s = html.unescape(s).replace("\u00a0", " ")
out, blank = [], 0
for line in s.split("\n"):
    line = line.rstrip()
    blank = blank + 1 if not line.strip() else 0
    if blank <= 1:
        out.append(line)
print("\n".join(out).strip("\n"))' "$1"
}

# _pre TEXT [MAXLINES] — TEXT as a monospace block, shortened to MAXLINES.
_pre() {
    local text="$1" max="${2:-40}" n
    n=$(printf '%s\n' "$text" | wc -l)
    if (( n > max )); then
        text="$(printf '%s\n' "$text" | head -n "$max")"$'\n'"… ($((n - max)) more lines - see the run log)"
    fi
    # Long lines are wrapped for display (marked ↵) so a dialog never grows
    # wider than the screen; the run log keeps the exact commands.
    text=$(printf '%s\n' "$text" | awk -v w=90 '
        # Break at the last space before the limit (so "name=value" and
        # paths stay whole); a single word longer than the line is cut.
        { line = $0
          while (length(line) > w) {
              cut = 0
              for (i = w; i > 24; i--) if (substr(line, i, 1) == " ") { cut = i; break }
              if (cut == 0) for (i = w; i > 24; i--) if (substr(line, i, 1) == "/") { cut = i; break }
              if (cut == 0) cut = w
              print substr(line, 1, cut) "↵"
              line = "    " substr(line, cut + 1)
          }
          print line }')
    printf '<pre style="font-size:small">%s</pre>' "$(_html "$text")"
}

_tty_read() {
    local prompt="$1" __v=""
    read -r -p "$prompt" __v < /dev/tty || __v=""
    printf '%s' "$__v"
}

# ui_msg TEXT — an information dialog.
ui_msg() {
    if [[ "$UI_MODE" == "kde" ]]; then
        _kd --msgbox "$(_ui_html "$1")" && return 0
        [[ $? -ne 255 ]] && return 0
    fi
    [[ "$UI_MODE" == "tty" ]] && printf '\n%s\n' "$(_ui_plain "$1")" > /dev/tty
    return 0
}

# ui_page TEXT — like ui_msg, but on a terminal it waits for Enter, so the
# page is read before the next screen scrolls it away.
ui_page() {
    if [[ "$UI_MODE" == "tty" ]]; then
        printf '\n%s\n' "$(_ui_plain "$1")" > /dev/tty
        read -r -p "  Press Enter to go back " _ < /dev/tty || true
        return 0
    fi
    ui_msg "$1"
}

# ui_error TEXT [DETAILS] — an error dialog.
ui_error() {
    if [[ "$UI_MODE" == "kde" ]]; then
        if [[ -n "${2:-}" ]]; then
            _kd --detailederror "<html>$(_rich "$1")</html>" "$2" && return 0
        else
            _kd --error "<html>$(_rich "$1")</html>" && return 0
        fi
        [[ $? -ne 255 ]] && return 0
    fi
    print_status "ERR" "$1"
    [[ -n "${2:-}" ]] && printf '%s\n' "$2" >&2
    return 0
}

# ui_yesno TEXT [YES_LABEL] [NO_LABEL] [DEFAULT y|n] [warn] — 0 for yes.
# "warn" shows KDE's warning dialog (for questions with side effects).
ui_yesno() {
    local text="$1" yes="${2:-Yes}" no="${3:-No}" def="${4:-n}" kind="--yesno" a rc
    [[ "${5:-}" == "warn" ]] && kind="--warningyesno"
    if [[ "$UI_MODE" == "kde" ]]; then
        _kd --yes-label "$yes" --no-label "$no" \
            "$kind" "$(_ui_html "$text")"
        rc=$?
        [[ $rc -ne 255 ]] && return "$rc"
    fi
    if [[ "$UI_MODE" == "tty" ]]; then
        printf '\n%s\n' "$(_ui_plain "$text")" > /dev/tty
        a=$(_tty_read "  ${yes} / ${no}? [$([[ $def == y ]] && echo Y/n || echo y/N)] ")
        a="${a:-$def}"
        [[ "${a,,}" == y* ]] && return 0
        return 1
    fi
    [[ "$def" == "y" ]]
}

# ui_choice3 HTML_OR_TEXT TEXT_FOR_TTY YES NO CANCEL [warn] [y|n] — 0, 1 or 2
# (Yes/No/Cancel); "warn" shows KDE's warning dialog. An empty TEXT_FOR_TTY
# is made from the HTML (only when it is needed). On the terminal, Enter
# gives the last argument's answer (No unless "y" is given); with no one to
# ask, the answer is always No.
ui_choice3() {
    local html="$1" text="$2" yes="$3" no="$4" cancel="$5" kind="--yesnocancel" def="${7:-n}" a rc
    [[ "${6:-}" == "warn" ]] && kind="--warningyesnocancel"
    if [[ "$UI_MODE" == "kde" ]]; then
        _kd --yes-label "$yes" --no-label "$no" --cancel-label "$cancel" \
            "$kind" "<html>${html#<html>}"
        rc=$?
        [[ $rc -ne 255 ]] && return "$rc"
    fi
    if [[ "$UI_MODE" == "tty" ]]; then
        [[ -n "$text" ]] || text=$(_html2text "<html>${html#<html>}")
        printf '\n%s\n' "$text" > /dev/tty
        while :; do
            a=$(_tty_read "  [y] ${yes}   [n] ${no}   [s] ${cancel}  (default ${def}): ")
            a="${a:-$def}"
            case "${a,,}" in
                y|yes) return 0 ;;
                n|no) return 1 ;;
                s|stop|q|c) return 2 ;;
            esac
        done
    fi
    return 1
}

# ui_radiolist TEXT TAG LABEL on|off ... — print the chosen TAG (1 if cancelled).
ui_radiolist() {
    local text="$1" out rc i n a def=""
    shift
    if [[ "$UI_MODE" == "kde" ]]; then
        out=$(_kd --radiolist "$(_ui_html "$text")" "$@")
        rc=$?
        if [[ $rc -ne 255 ]]; then
            out=$(_ui_offered 3 "$out" "$@" | head -n1)
            [[ $rc -eq 0 && -n "$out" ]] || return 1
            printf '%s\n' "$out"
            return 0
        fi
        _ui_fallback
    fi
    local -a tags=() labels=()
    while [[ $# -ge 3 ]]; do
        tags+=("$1"); labels+=("$2")
        [[ "$3" == "on" ]] && def="$1"
        shift 3
    done
    [[ -n "$def" ]] || def="${tags[0]}"
    if [[ "$UI_MODE" == "tty" ]]; then
        printf '\n%s\n' "$(_ui_plain "$text")" > /dev/tty
        n=${#tags[@]}
        for (( i = 0; i < n; i++ )); do
            printf '  [%d] %s%s\n' $((i + 1)) "${labels[$i]}" \
                "$([[ ${tags[$i]} == "$def" ]] && echo '  (default)')" > /dev/tty
        done
        while :; do
            a=$(_tty_read "  Choose 1-${n}: ")
            [[ -z "$a" ]] && { printf '%s\n' "$def"; return 0; }
            if [[ "$a" =~ ^[0-9]+$ ]] && (( a >= 1 && a <= n )); then
                printf '%s\n' "${tags[$((a - 1))]}"
                return 0
            fi
        done
    fi
    printf '%s\n' "$def"
}

# ui_checklist TEXT TAG LABEL on|off ... — print the chosen TAGs, one per
# line (status 1 if cancelled).
ui_checklist() {
    local text="$1" out rc i n a t geo=()
    shift
    # Long lists (the fix list, the firewall services) get a bigger window.
    (( $# / 3 > 6 )) && geo=(--geometry 900x620)
    if [[ "$UI_MODE" == "kde" ]]; then
        out=$(_kd "${geo[@]}" --separate-output --checklist "$(_ui_html "$text")" "$@")
        rc=$?
        if [[ $rc -ne 255 ]]; then
            [[ $rc -eq 0 ]] || return 1
            _ui_offered 3 "$out" "$@"
            return 0
        fi
        _ui_fallback
    fi
    local -a tags=() labels=() on=()
    while [[ $# -ge 3 ]]; do
        tags+=("$1"); labels+=("$2"); on+=("$([[ $3 == on ]] && echo 1 || echo 0)")
        shift 3
    done
    n=${#tags[@]}
    if [[ "$UI_MODE" == "tty" ]]; then
        while :; do
            printf '\n%s\n' "$(_ui_plain "$text")" > /dev/tty
            for (( i = 0; i < n; i++ )); do
                printf '  [%s] %d. %s\n' "$([[ ${on[$i]} == 1 ]] && echo x || echo ' ')" \
                    $((i + 1)) "${labels[$i]}" > /dev/tty
            done
            a=$(_tty_read "  Numbers to toggle (e.g. \"2 4\"), Enter to accept: ")
            [[ -z "$a" ]] && break
            for t in $a; do
                if [[ "$t" =~ ^[0-9]+$ ]] && (( t >= 1 && t <= n )); then
                    on[t - 1]=$(( 1 - on[t - 1] ))
                fi
            done
        done
    fi
    for (( i = 0; i < n; i++ )); do
        [[ "${on[$i]}" == 1 ]] && printf '%s\n' "${tags[$i]}"
    done
    return 0
}

# ui_menu HTML OK_LABEL CANCEL_LABEL TAG LABEL ... — a list to pick one
# entry from (the dashboard). Prints the chosen TAG; status 1 when closed
# with CANCEL_LABEL (or nobody can answer).
ui_menu() {
    local html="$1" ok="$2" cancel="$3" out rc i n a
    shift 3
    if [[ "$UI_MODE" == "kde" ]]; then
        out=$(_kd --geometry 900x700 --ok-label "$ok" --cancel-label "$cancel" --menu "$(_ui_html "$html")" "$@")
        rc=$?
        if [[ $rc -ne 255 ]]; then
            out=$(_ui_offered 2 "$out" "$@" | head -n1)
            [[ $rc -eq 0 && -n "$out" ]] || return 1
            printf '%s\n' "$out"
            return 0
        fi
        _ui_fallback
    fi
    [[ "$UI_MODE" == "tty" ]] || return 1
    local -a tags=() labels=()
    while [[ $# -ge 2 ]]; do tags+=("$1"); labels+=("$2"); shift 2; done
    n=${#tags[@]}
    {
        printf '\n%s\n\n' "$(_ui_plain "$html")"
        for (( i = 0; i < n; i++ )); do printf '  %2d) %s\n' $((i + 1)) "${labels[$i]}"; done
        printf '   q) %s\n' "$cancel"
    } > /dev/tty
    while :; do
        read -r -p "  Choose 1-${n}, or q: " a < /dev/tty || return 1
        case "$a" in q|Q) return 1 ;; esac
        if [[ "$a" =~ ^[0-9]+$ ]] && (( a >= 1 && a <= n )); then
            printf '%s\n' "${tags[$((a - 1))]}"
            return 0
        fi
    done
}

# ui_newpassword TEXT — ask twice for a new password; print it (1 if cancelled).
ui_newpassword() {
    local text="$1" out rc p1 p2
    if [[ "$UI_MODE" == "kde" ]]; then
        out=$(_kd --newpassword "$text")
        rc=$?
        if [[ $rc -ne 255 ]]; then
            [[ $rc -eq 0 && -n "$out" ]] || return 1
            printf '%s' "$out"
            return 0
        fi
        _ui_fallback
    fi
    [[ "$UI_MODE" == "tty" ]] || return 1
    printf '\n%s\n' "$text" > /dev/tty
    IFS= read -r -s -p "  New password: " p1 < /dev/tty || return 1
    printf '\n' > /dev/tty
    IFS= read -r -s -p "  Repeat it: " p2 < /dev/tty || return 1
    printf '\n' > /dev/tty
    [[ -n "$p1" && "$p1" == "$p2" ]] || { printf '  Passwords are empty or differ.\n' > /dev/tty; return 1; }
    printf '%s' "$p1"
}

# ui_dir TEXT START — pick a folder (prints it; 1 if cancelled).
ui_dir() {
    local text="$1" start="$2" out rc
    if [[ "$UI_MODE" == "kde" ]]; then
        out=$(_kd --getexistingdirectory "$start")
        rc=$?
        if [[ $rc -ne 255 ]]; then
            [[ $rc -eq 0 && -n "$out" ]] || return 1
            printf '%s\n' "$out"
            return 0
        fi
        _ui_fallback
    fi
    if [[ "$UI_MODE" == "tty" ]]; then
        out=$(_tty_read "$text [${start}]: ")
        printf '%s\n' "${out:-$start}"
        return 0
    fi
    printf '%s\n' "$start"
}

# ui_notify TEXT — a passive desktop notification (or a terminal line).
ui_notify() {
    if [[ "$UI_MODE" == "kde" ]]; then
        _as_desktop_user kdialog --title "$UI_TITLE" --icon "$(_ui_icon)" \
            --passivepopup "$1" 6 >/dev/null 2>&1 &
        return 0
    fi
    print_status "INFO" "$1"
}

# ====================== PROGRESS ======================
# A kdialog progress bar, driven over the user's D-Bus session (best effort:
# if it cannot be driven it is simply closed at the end).
# Progress while checks (or a fix) run: the Kirigami progress window with
# a tray icon when it can run, else a kdialog progress bar. _PROGRESS_FD is
# the Kirigami window's input; _PROGRESS_REF the kdialog bar.
_PROGRESS_FD=""
_PROGRESS_STEPS=0

# ui_progress_start TEXT STEPS — STEPS 0: no steps (a busy indicator).
ui_progress_start() {
    local text="$1" steps="$2"
    _PROGRESS_REF=""; _PROGRESS_STEPS="$steps"
    [[ "$UI_MODE" == "kde" ]] || return 0
    if _qml_ok; then
        # The reader keeps draining its input even if the window could not
        # be shown, so writing progress never fails.
        exec {_PROGRESS_FD}> >(_ui_app_cmd progress > /dev/null 2>&1; cat > /dev/null)
        _progress_line "$(_json heading "$([[ $steps -gt 0 ]] && echo "Checking your PC" || echo "$text")")"
        if [[ $steps -gt 0 ]]; then _progress_line "0	0	${text}	"; else _progress_line "-	0	Please wait…	"; fi
        return 0
    fi
    local theme ref
    theme=$(_ui_theme_env)
    ref=$(_as_desktop_user env ${theme:+"$theme"} kdialog --title "$UI_TITLE" --icon "$(_ui_icon)" \
        --progressbar "$text" "$([[ $steps -gt 0 ]] && echo 100 || echo 0)" 2>/dev/null) || return 0
    # "org.kde.kdialog-12345 /ProgressDialog"
    [[ "$ref" =~ ^(org\.kde\.kdialog-[0-9]+)[[:space:]]+(/[A-Za-z]+)$ ]] && _PROGRESS_REF="$ref"
}

_progress_line() {
    [[ -n "$_PROGRESS_FD" ]] || return 0
    printf '%s\n' "${1//$'\n'/ }" 2>/dev/null 1>&"$_PROGRESS_FD" || true
}

_progress_call() {
    local svc path
    read -r svc path <<< "$_PROGRESS_REF"
    _as_desktop_user busctl --user "$1" "$svc" "$path" org.kde.kdialog.ProgressDialog "${@:2}" \
        >/dev/null 2>&1
}

# ui_progress_set STEP LABEL [slow] — step STEP of the steps given to
# ui_progress_start has started. The bar shows the steps already done,
# scaled to 90%: it reaches 100% only when the last step has finished
# (ui_progress_stop), never while one still runs. "slow": a long step (the
# malware scan) - the bar holds at 90% with a spinner and a note.
ui_progress_set() {
    local value="$1" label="$2" slow="${3:-}" pct detail=""
    local total="${_PROGRESS_STEPS:-0}"
    (( total > 0 )) || total=1
    pct=$(( (value - 1) * 90 / total ))
    (( pct < 0 )) && pct=0
    if [[ "$slow" == slow ]]; then
        pct=90
        detail="This can take several minutes. The bar moves on when it is done."
    fi
    _progress_line "${pct}	$([[ $slow == slow ]] && echo 1 || echo 0)	${label//$'\t'/ }	${detail}"
    if [[ -n "$_PROGRESS_REF" ]]; then
        _progress_call set-property value i "$pct" || true
        _progress_call call setLabelText s "${label}${detail:+ - $detail}" || true
    fi
    if [[ -t 2 && "${QUIET:-0}" -eq 0 ]]; then
        printf '\r  [%2d/%-2d] %3d%% %-50.50s' "$value" "${_PROGRESS_STEPS:-0}" "$pct" "$label" >&2
    fi
}

# ui_busy_start TEXT / ui_busy_stop — a busy indicator while a fix runs
# (a kdialog progress bar without steps, or a line on the terminal).
ui_busy_start() {
    if [[ "$UI_MODE" == "kde" ]]; then
        ui_progress_start "$1" 0
    elif [[ "$UI_MODE" == "tty" ]]; then
        printf '  %s\n' "$1" > /dev/tty
    fi
    return 0
}

ui_busy_stop() { ui_progress_stop; }

# ui_progress_stop — every step has finished: 100%, then the window closes.
ui_progress_stop() {
    [[ -t 2 && "${QUIET:-0}" -eq 0 ]] && printf '\r%-80s\r' '' >&2
    if [[ -n "$_PROGRESS_FD" ]]; then
        [[ "${_PROGRESS_STEPS:-0}" -gt 0 ]] && _progress_line "100	0	Done	"
        # An explicit end: the window closes even if a child process still
        # holds a copy of the pipe.
        _progress_line "QUIT"
        exec {_PROGRESS_FD}>&-
        _PROGRESS_FD=""
    fi
    [[ -n "$_PROGRESS_REF" ]] || return 0
    _progress_call set-property value i 100 || true
    _progress_call call close || true
    _PROGRESS_REF=""
}
