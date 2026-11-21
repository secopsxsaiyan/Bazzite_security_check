# shellcheck shell=bash
# Optional extras: the tool installed as an app (menu entry and command)
# and a weekly report-only timer. Both run one root-owned copy in
# INSTALL_DIR (on Bazzite /usr/local lives in /var and is writable).

readonly INSTALL_DIR="/usr/local/libexec/bazzite-sec-audit"
readonly UNIT_NAME="bazzite-sec-audit"
readonly APP_ID="bazzite-security-check"
readonly APP_DESKTOP="/usr/local/share/applications/${APP_ID}.desktop"
readonly APP_BIN="/usr/local/bin/bazzite-sec-audit"
readonly APP_ICON_DIR="/usr/local/share/icons/hicolor/scalable/apps"
readonly APP_ICON_22="/usr/local/share/icons/hicolor/22x22/apps"
# What a copy of the tool is made of (relative to its folder).
readonly _TOOL_PARTS=(lib checks ui release-signers)

_timer_installed() { [[ -f "/etc/systemd/system/${UNIT_NAME}.timer" ]]; }
_app_installed() { [[ -f "$APP_DESKTOP" ]]; }

# installed_copy_outdated [DIR] — the menu app or the weekly check runs a
# copy in DIR (default INSTALL_DIR) that differs from the tool running now
# (it was updated, e.g. with git pull).
installed_copy_outdated() {
    local dir="${1:-$INSTALL_DIR}" p
    { _timer_installed || _app_installed; } && [[ -d "$dir" && "$SCRIPT_DIR" != "$dir" ]] || return 1
    for p in "${_TOOL_PARTS[@]}" "$(basename "$SCRIPT_PATH")"; do
        [[ -e "$SCRIPT_DIR/$p" || -e "$dir/$p" ]] || continue
        diff -rq -- "$SCRIPT_DIR/$p" "$dir/$p" >/dev/null 2>&1 || return 0
    done
    return 1
}

# _install_copy — put a root-owned copy of the running tool in INSTALL_DIR
# (replacing an older one). Running it from there, the menu app and the
# weekly check never run as root a file that the desktop user can change.
_install_copy() {
    # SRC: the folder to install from (default: the running tool; the
    # updater passes a verified release).
    local src="${1:-$SCRIPT_DIR}" main p
    main="$(basename "$SCRIPT_PATH")"
    # Started from the installed copy itself: it is already in place.
    [[ "$src" == "$INSTALL_DIR" ]] && return 0
    local tmp
    local -a parts=("$src/$main")
    for p in "${_TOOL_PARTS[@]}"; do [[ -e "$src/$p" ]] && parts+=("$src/$p"); done
    # Normal permissions for a shared folder like /usr/local/libexec (this
    # tool otherwise runs with umask 077).
    ( umask 022; mkdir -p "$(dirname "$INSTALL_DIR")" )
    tmp=$(mktemp -d "${INSTALL_DIR}.new.XXXXXX") || { ui_error "Could not create ${INSTALL_DIR}"; return 1; }
    # Plain copies (no preserved SELinux labels: files from a home folder are
    # labelled user_home_t, which system services may not use).
    # -L: a link in the source folder is copied as the file it points to.
    # Kept as a link, a root run would go on running a file in a home
    # folder that anything running as that user can rewrite.
    if ! cp -RL --no-preserve=all "${parts[@]}" "$tmp/" \
       || [[ -n "$(find "$tmp" ! -type f ! -type d -print -quit 2>/dev/null)" ]]; then
        rm -rf -- "$tmp"
        ui_error "The tool's files could not be copied to ${INSTALL_DIR} (a broken link, or something that is neither a file nor a folder); nothing was installed."
        return 1
    fi
    if ! { chown -R root:root "$tmp" && chmod -R u=rwX,go=rX "$tmp" \
           && chmod 755 "$tmp/$main"; }; then
        rm -rf -- "$tmp"
        ui_error "Could not set the owner and permissions of the copy in ${INSTALL_DIR}; nothing was installed."
        return 1
    fi
    # Swap the copies so a failure keeps the old one working: the old copy
    # moves aside, the new one takes its place, and only then is the old
    # one deleted (or put back if the new one could not be moved in).
    local old=""
    if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
        old="${tmp}.old"
        if ! mv -T -- "$INSTALL_DIR" "$old"; then
            rm -rf -- "$tmp"
            ui_error "Could not replace ${INSTALL_DIR}; the installed copy was left as it was."
            return 1
        fi
    fi
    if ! mv -T -- "$tmp" "$INSTALL_DIR"; then
        [[ -n "$old" ]] && mv -T -- "$old" "$INSTALL_DIR"
        rm -rf -- "$tmp"
        ui_error "Could not put the new copy in ${INSTALL_DIR}; the installed copy was left as it was."
        return 1
    fi
    [[ -n "$old" ]] && rm -rf -- "$old"
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R "$INSTALL_DIR" 2>/dev/null || true
    fi
    return 0
}

# _remove_copy — remove INSTALL_DIR once neither the app nor the timer uses it.
_remove_copy() {
    _timer_installed || _app_installed || rm -rf -- "$INSTALL_DIR"
}

# _app_desktop_entry — the menu entry of the installed app. It starts the
# root-owned copy as the desktop user; the tool then asks for the
# administrator password (KDE's password dialog) before it checks anything.
_app_desktop_entry() {
    local exec_path
    exec_path="${INSTALL_DIR}/$(basename "$SCRIPT_PATH")"
    cat << EOF
[Desktop Entry]
Type=Application
Version=1.5
Name=Security Check
GenericName=Security check-up
Comment=Check this PC's security and fix issues with your confirmation (asks for the administrator password)
Exec=${exec_path} --gui
TryExec=${exec_path}
Icon=bazzite-security-check
Terminal=false
StartupNotify=true
Categories=System;Security;
Keywords=security;audit;firewall;privacy;hardening;bazzite;
Actions=undo;

[Desktop Action undo]
Name=Undo changes made by Security Check
Icon=edit-undo
Exec=${exec_path} --gui --undo
EOF
}

# _user_launcher — the per-user menu entry older versions added
# (--install-launcher); it has the same id, so it would hide the app's.
_user_launcher() {
    [[ -n "$DESKTOP_USER" ]] || return 1
    printf '%s/.local/share/applications/%s.desktop' "$(_home_of "$DESKTOP_USER")" "$APP_ID"
}

# _refresh_menu — tell the desktop about the new or removed menu entry.
_refresh_menu() {
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$(dirname "$APP_DESKTOP")" >/dev/null 2>&1
    command -v kbuildsycoca6 >/dev/null 2>&1 && _as_desktop_user kbuildsycoca6 >/dev/null 2>&1
    return 0
}

# _install_app_files [SRC] — without asking: the root-owned copy (from SRC,
# default the running tool), the menu entry, the icons and the command.
# Used by install_app and by the updater (with a verified release).
_install_app_files() {
    local src="${1:-$SCRIPT_DIR}" old_launcher="" exe icon
    _install_copy "$src" || return 1
    exe="${INSTALL_DIR}/$(basename "$SCRIPT_PATH")"
    if ! ( umask 022
           mkdir -p "$(dirname "$APP_DESKTOP")" "$(dirname "$APP_BIN")" "$APP_ICON_DIR" \
           && _app_desktop_entry > "${APP_DESKTOP}.tmp" && mv -f -- "${APP_DESKTOP}.tmp" "$APP_DESKTOP" \
           && chmod 644 "$APP_DESKTOP" && ln -sfn -- "$exe" "$APP_BIN" ) \
       || [[ ! -f "$APP_DESKTOP" || "$(readlink -- "$APP_BIN")" != "$exe" ]]; then
        rm -f -- "${APP_DESKTOP}.tmp"
        ui_error "Could not add the menu entry (${APP_DESKTOP}) or the command (${APP_BIN}); see the messages above."
        return 1
    fi
    # The app icon and its tray (symbolic) variants from the installed copy:
    # scalable, plus the 22 px tray glyph drawn on its own grid.
    for icon in "$INSTALL_DIR"/ui/icons/"${APP_ID}"*.svg; do
        [[ -f "$icon" ]] && install -m 644 -- "$icon" "$APP_ICON_DIR/"
    done
    if [[ -f "$INSTALL_DIR/ui/icons/22x22/${APP_ID}-symbolic.svg" ]]; then
        install -D -m 644 -- "$INSTALL_DIR/ui/icons/22x22/${APP_ID}-symbolic.svg" "$APP_ICON_22/${APP_ID}-symbolic.svg"
    fi
    command -v restorecon >/dev/null 2>&1 && restorecon -R "$APP_DESKTOP" "$APP_BIN" "$APP_ICON_DIR" 2>/dev/null
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
        && gtk-update-icon-cache -q -t "$(dirname "$(dirname "$APP_ICON_DIR")")" >/dev/null 2>&1
    # An older per-user entry would hide this one and run the tool from a
    # home folder; it is removed as its owner.
    old_launcher=$(_user_launcher) || old_launcher=""
    if [[ -n "$old_launcher" ]] && _as_desktop_user test -f "$old_launcher"; then
        _as_desktop_user rm -f -- "$old_launcher" || true
    fi
    _refresh_menu
    return 0
}

# ---- what the Plasma window needs ----
# The one window (ui/app.py) runs on PySide6 and Kirigami (see _qml_ok).
# Bazzite's KDE image has Kirigami but not PySide6; without it the tool
# uses plain kdialog windows. Installing the app offers to add what is
# missing; the packages it added are listed in STATE_DIR so that removing
# the app can offer to take them away again.
readonly _FRONT_PKGS_FILE="front-end-packages"
# Set once the question was answered, so that a normal start asks once.
readonly _FRONT_OFFERED_FILE="front-end-offered"
# The only packages this ever adds or removes.
readonly -a _FRONT_PKGS_KNOWN=(python3-pyside6 kf6-kirigami)

# _front_end_missing — the packages the window needs that are not here, on
# a KDE Plasma desktop (nothing on another desktop: kdialog and the window
# are KDE's). PySide6 is tried with the desktop user's python3, as the
# window runs; with no desktop user, with root's. Only PySide6 itself not
# being found counts as missing (exit 3): a PySide6 that is there but does
# not load (a library missing), a probe that could not run or one that
# crashed says nothing, and nothing is offered for it.
readonly _PYSIDE_MISSING_PROBE="import sys
try:
    ${_PYSIDE_PROBE}
except ModuleNotFoundError as e:
    sys.exit(3 if (e.name or '').split('.')[0] == 'PySide6' else 4)
except ImportError:
    sys.exit(4)"
_front_end_missing() {
    [[ "$DESKTOP_ENV" == kde ]] || return 0
    local -a miss=()
    local rc=0
    if [[ -n "${DESKTOP_USER:-}" ]]; then
        _as_desktop_user python3 -I -c "$_PYSIDE_MISSING_PROBE" >/dev/null 2>&1 < /dev/null || rc=$?
    else
        python3 -I -c "$_PYSIDE_MISSING_PROBE" >/dev/null 2>&1 < /dev/null || rc=$?
    fi
    case $rc in
        0) ;;
        3) miss+=(python3-pyside6) ;;
        *) return 0 ;;   # unknown: offer nothing at all
    esac
    _kirigami_here || miss+=(kf6-kirigami)
    printf '%s' "${miss[*]}"
}

# _front_pkgs_recorded — the packages an earlier install added, one per
# line: only the known ones, from a regular file (not a link).
_front_pkgs_recorded() {
    local f="${STATE_DIR}/${_FRONT_PKGS_FILE}" p k
    [[ -f "$f" && ! -L "$f" ]] || return 0
    while IFS= read -r p; do
        for k in "${_FRONT_PKGS_KNOWN[@]}"; do
            [[ "$p" == "$k" ]] && printf '%s\n' "$p"
        done
    done < "$f"
    return 0
}

# _front_pkgs_record PACKAGE... — add PACKAGE to the list (no duplicates).
_front_pkgs_record() {
    local f="${STATE_DIR}/${_FRONT_PKGS_FILE}" tmp
    tmp=$(mktemp "${f}.XXXXXX") || return 1
    { _front_pkgs_recorded; printf '%s\n' "$@"; } | sort -u > "$tmp" && mv -f -- "$tmp" "$f"
}

# _front_offered — remember that the question was answered.
# (Only when someone was there to see it: an unattended --install or a
# dialog that failed is no answer.)
_front_offered() {
    ui_interactive || return 0
    { : > "${STATE_DIR}/${_FRONT_OFFERED_FILE}"; } 2>/dev/null || true
}

# _pkg_tool — how packages are added here: "rpm-ostree" (Bazzite and other
# Fedora Atomic images: layered, active after a restart), "dnf" (a system
# that is not image-based), or nothing (on an image without rpm-ostree, dnf
# would write to a read-only or throw-away /usr).
_pkg_tool() {
    if [[ "$IS_OSTREE" -eq 1 ]]; then
        _have rpm-ostree && echo rpm-ostree
    elif _have dnf; then
        echo dnf
    fi
    return 0
}

# _pkg_run TOOL install|uninstall PACKAGE... — add or remove PACKAGE, with a
# busy indicator; what the package tool prints goes to the run log (its last
# lines are shown on failure).
_pkg_run() {
    local tool="$1" verb="$2" out rc=0
    shift 2
    local -a cmd
    case "$tool:$verb" in
        # (No "--" for rpm-ostree: its option parser then finds no package
        # at all. The names come only from _FRONT_PKGS_KNOWN, none starts
        # with "-".)
        rpm-ostree:install)   cmd=(rpm-ostree install --idempotent "$@") ;;
        rpm-ostree:uninstall) cmd=(rpm-ostree uninstall --idempotent "$@") ;;
        dnf:install)          cmd=(dnf install -y -- "$@") ;;
        dnf:uninstall)        cmd=(dnf remove -y -- "$@") ;;
        *) return 2 ;;
    esac
    ui_busy_start "$([[ $verb == install ]] && echo Installing || echo Removing) $*…"
    out=$("${cmd[@]}" 2>&1 < /dev/null) || rc=$?
    ui_busy_stop
    log "${cmd[*]}: exit ${rc}"
    printf '%s\n' "$out" | tail -n 40 | sed 's/^/  pkg: /' >> "${RUN_LOG:-/dev/null}" 2>/dev/null || true
    if (( rc != 0 )); then
        ui_error "$(printf '%s did not finish (exit %s):\n\n%s' "${cmd[*]}" "$rc" "$(printf '%s\n' "$out" | tail -n 8)")"
        return 1
    fi
    return 0
}

# install_front_end — offer to add what the Plasma window needs (see above).
# _FRONT_RESULT tells how it went: "none" (nothing missing), "added" (in
# use from the next start), "restart" (layered, or already waiting: active
# after the restart), "declined", "failed", "manual" (no package tool known
# here) or "broken" (installed, or layered in the running image, yet the
# window still cannot run). _FRONT_MISSING: the packages that were missing. The question
# defaults to "Not now": a lost dialog or nobody to ask adds nothing.
_FRONT_RESULT=""; _FRONT_MISSING=""; _FRONT_BROKEN=""
install_front_end() {
    local miss tool p left="" it=it they=It is=is need=needs
    miss=$(_front_end_missing)
    _FRONT_MISSING="$miss"; _FRONT_RESULT=none; _FRONT_BROKEN=""
    [[ -n "$miss" ]] || return 0
    tool=$(_pkg_tool)
    if [[ -z "$tool" ]]; then
        _FRONT_RESULT=manual
        _front_offered
        return 1
    fi
    # Each missing package is one of: layered in the running image yet
    # missing (broken: a restart would not help), waiting in the next image
    # (comes with the restart), installed yet missing (broken: installing
    # it again does nothing), or not there (offered).
    local broken="" waiting=""
    for p in $miss; do
        if [[ -n "$(_layered_booted "$p")" ]]; then
            broken+="${broken:+ }$p"
        elif [[ "$tool" == rpm-ostree && -n "$(_layered_pending "$p")" ]]; then
            waiting+="${waiting:+ }$p"
        elif LC_ALL=C rpm -q --quiet -- "$p" 2>/dev/null; then
            broken+="${broken:+ }$p"
        else
            left+="${left:+ }$p"
        fi
    done
    _FRONT_BROKEN="$broken"
    if [[ -z "$left" ]]; then
        if [[ -n "$waiting" ]]; then
            _FRONT_RESULT=restart; _FRONT_MISSING="$waiting"
        else
            _FRONT_RESULT=broken; _FRONT_MISSING="$broken"; _FRONT_BROKEN=""
        fi
        _front_offered
        [[ "$_FRONT_RESULT" == restart ]]
        return
    fi
    miss="$left"
    [[ "$miss" == *" "* ]] && { it=them; they=They; is=are; need=need; }
    _FRONT_MISSING="$miss"
    # Nobody to ask: nothing is added, and the next start with someone
    # there asks.
    if ! ui_interactive; then
        _FRONT_RESULT=declined
        return 1
    fi
    if ! ui_yesno "Security Check's window (one window for the setup, the results and the fixes) needs ${miss// /, }, which ${is} not installed. Without ${it}, the tool uses plain KDE dialogs.

$([[ $tool == rpm-ostree ]] && echo "Install ${it} now? ${they} and the Qt libraries ${they,,} ${need} (about 20 packages) are added to the system image with rpm-ostree as layered packages, updated with the system, and used after the next restart. If a system update ever fails because of them, remove the app or run: rpm-ostree uninstall ${miss}" || echo "Install ${it} now with dnf, with the Qt libraries ${they,,} ${need}?")

Removing the app later offers to remove ${it} again." "Install" "Not now" "n" careful; then
        _FRONT_RESULT=declined
        # Remembered only when someone could still answer (the dialog did
        # not fail on the way).
        ui_interactive && _front_offered
        return 1
    fi
    # shellcheck disable=SC2086 # package names, one word each
    if ! _pkg_run "$tool" install $miss; then
        # Not remembered as answered: the next start asks again (another
        # rpm-ostree transaction may have been running).
        _FRONT_RESULT=failed
        return 1
    fi
    _front_offered
    # shellcheck disable=SC2086
    _front_pkgs_record $miss \
        || ui_error "${miss// /, } could not be written to the list of what the install added (${STATE_DIR}/${_FRONT_PKGS_FILE}): removing the app will not offer to remove ${it}."
    [[ -n "$waiting" ]] && miss+=" $waiting"
    _FRONT_MISSING="$miss"
    if [[ "$tool" == rpm-ostree ]]; then _FRONT_RESULT=restart; else _FRONT_RESULT=added; fi
    return 0
}

# _front_result_text — one line for the end of an install or a start, by
# _FRONT_RESULT (nothing for "none"), and what is installed yet broken.
_front_result_text() {
    if [[ -n "$_FRONT_BROKEN" && ( "$_FRONT_RESULT" == restart || "$_FRONT_RESULT" == added ) ]]; then
        # Not a promise of the window: something it needs is still broken.
        printf '%s %s added%s.' "${_FRONT_MISSING// /, }" "$([[ $_FRONT_MISSING == *" "* ]] && echo are || echo is)" \
            "$([[ $_FRONT_RESULT == restart ]] && echo " to the system image (used after the next restart)" || true)"
    else
        _front_result_line
    fi
    if [[ -n "$_FRONT_BROKEN" && "$_FRONT_RESULT" != broken ]]; then
        local r="$_FRONT_RESULT" m="$_FRONT_MISSING"
        _FRONT_RESULT=broken; _FRONT_MISSING="$_FRONT_BROKEN"
        printf ' The window still needs more: '
        _front_result_line
        _FRONT_RESULT="$r"; _FRONT_MISSING="$m"
    fi
    return 0
}
_front_result_line() {
    local what="${_FRONT_MISSING// /, }" is=is it=it check
    [[ "$_FRONT_MISSING" == *" "* ]] && { is=are; it=them; }
    if [[ "$_FRONT_MISSING" == *pyside6* ]]; then
        check="python3 -c 'import PySide6.QtQml'"
    else
        check="ls /usr/lib64/qt6/qml/org/kde/kirigami"
    fi
    case "$_FRONT_RESULT" in
        restart)  printf "Restart the PC to use Security Check's window: %s %s added to the system image and used after the restart. Until then it uses plain KDE dialogs." "$what" "$is" ;;
        added)    printf "Security Check's window is used from the next start." ;;
        declined) printf 'Without %s, Security Check uses plain KDE dialogs. Install the app again (--install) to add %s.' "$what" "$it" ;;
        failed)   printf 'Without %s, Security Check uses plain KDE dialogs. The next start offers %s again, or install the app again (--install).' "$what" "$it" ;;
        manual)   printf "Without %s, Security Check uses plain KDE dialogs. Install %s with your system's package manager." "$what" "$it" ;;
        broken)   printf "%s %s installed, yet Security Check's window cannot use %s, so it uses plain KDE dialogs. Check with: %s" "$what" "$is" "$it" "$check" ;;
    esac
    return 0
}

# offer_front_end_once — at the start of a check-up of the installed app
# with KDE dialogs: when the window cannot run, offer once what it needs
# (an app installed or updated by an older version was never asked). Not
# in a report-only run, which changes nothing. Installing the app again
# asks again.
offer_front_end_once() {
    [[ "$UI_MODE" == kde && "$FIX_MODE" != report ]] && _app_installed && ui_interactive || return 0
    [[ -e "${STATE_DIR}/${_FRONT_OFFERED_FILE}" ]] && return 0
    [[ -n "$(_front_end_missing)" ]] || return 0
    install_front_end || true
    [[ "$_FRONT_RESULT" == none ]] || ui_msg "$(_front_result_text)"
    return 0
}

# remove_front_end — offer to remove the packages an install added. With
# dnf, only when nothing else installed needs them (dnf would remove that
# too); rpm-ostree only drops the layer request. Returns 1 when they could
# not be removed and the person chose to keep the app (to try again).
remove_front_end() {
    local -a pkgs=()
    local tool need p q them=it
    tool=$(_pkg_tool)
    [[ -n "$tool" ]] || return 0
    # Only those still there (removed by hand since: nothing to do). With
    # rpm-ostree, still requested in the running or the waiting image; when
    # its status is not known, all of them (removing is idempotent). With
    # dnf, all but those rpm says are not installed.
    while IFS= read -r p; do
        if [[ "$tool" == rpm-ostree ]]; then
            if ! _rpmostree_status_known || [[ -n "$(_layered_booted "$p")$(_layered_pending "$p")" ]]; then
                pkgs+=("$p")
            fi
        else
            q=$(LC_ALL=C rpm -q -- "$p" 2>&1) || true
            [[ "$q" == *"is not installed"* ]] || pkgs+=("$p")
        fi
    done < <(_front_pkgs_recorded)
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        rm -f -- "${STATE_DIR:?}/${_FRONT_PKGS_FILE:?}"
        return 0
    fi
    [[ ${#pkgs[@]} -gt 1 ]] && them=them
    ui_yesno "Installing the app also installed ${pkgs[*]} for its window. Remove ${them} too?

Other programs may use ${them} as well.$([[ $tool == rpm-ostree ]] && echo " The change is active after the next restart.")" \
        "Remove" "Keep" "n" careful || return 0
    if [[ "$tool" == dnf ]] && ! need=$(LC_ALL=C rpm -e --test -- "${pkgs[@]}" 2>&1); then
        if grep -q 'is needed by' <<< "$need"; then
            ui_msg "Other installed programs need ${pkgs[*]} now, so $([[ $them == them ]] && echo they stay || echo it stays):

$(grep 'is needed by' <<< "$need" | head -n 6)"
            rm -f -- "${STATE_DIR:?}/${_FRONT_PKGS_FILE:?}"
            return 0
        fi
        ui_error "Could not check whether other programs need ${pkgs[*]}:

$(printf '%s\n' "$need" | head -n 6)"
        _front_remove_failed "$tool" "${pkgs[@]}"
        return
    fi
    if ! _pkg_run "$tool" uninstall "${pkgs[@]}"; then
        _front_remove_failed "$tool" "${pkgs[@]}"
        return
    fi
    rm -f -- "${STATE_DIR:?}/${_FRONT_PKGS_FILE:?}"
}

# _front_remove_failed TOOL PACKAGE... — removing them did not work: keep
# the app (so removing it again can try again; the default), or remove it
# anyway and leave the packages, saying how to remove them by hand.
_front_remove_failed() {
    local tool="$1" cmd
    shift
    if [[ "$tool" == rpm-ostree ]]; then cmd="rpm-ostree uninstall $*"; else cmd="dnf remove $*"; fi
    if ui_yesno "$* could not be removed. Remove the Security Check app anyway? $([[ $# -gt 1 ]] && echo They stay || echo It stays) installed; remove $([[ $# -gt 1 ]] && echo them || echo it) later with: ${cmd}

If you keep the app, --uninstall can try again later." \
        "Remove anyway" "Keep the app" "n" careful; then
        rm -f -- "${STATE_DIR:?}/${_FRONT_PKGS_FILE:?}"
        return 0
    fi
    return 1
}

# install_app — install the tool as an app: a "Security Check" entry in
# every user's application menu and the bazzite-sec-audit command, both
# running the root-owned copy in INSTALL_DIR.
install_app() {
    local verb="Install" old_launcher=""
    _app_installed && verb="Update"
    ui_yesno "${verb} Security Check as an app?

It appears in the application menu as \"Security Check\" (System), and as
the command bazzite-sec-audit. When you start it, it asks for your
administrator password first, then runs the check-up as usual - so it is
easy to run regularly.

This copies the tool to ${INSTALL_DIR} (owned by root, so nothing
running as you can change what later runs as administrator) and adds
${APP_DESKTOP} and ${APP_BIN}.
Remove it any time with --uninstall." "${verb}" "Cancel" "y" careful || return 0

    _install_app_files "$SCRIPT_DIR" || return 1
    local extra=""
    _timer_installed && extra=$'

The weekly check uses the same copy, so it was updated too.'
    install_front_end || true
    [[ "$_FRONT_RESULT" == none ]] || extra+=$'\n\n'"$(_front_result_text)"
    ui_msg "Security Check is installed. Start it from the application menu (System → Security Check) or with the command bazzite-sec-audit.

Updates: Settings → Updates installs new releases (signature and checksums are verified first).${extra}"
}

uninstall_app() {
    if ! _app_installed; then
        ui_msg "Security Check is not installed as an app."
        return 0
    fi
    ui_yesno "Remove the Security Check app (menu entry and the bazzite-sec-audit command)?

Reports, history and undo steps are kept.$(_timer_installed && printf '\nThe weekly check stays set up (remove it with --remove-timer).')" \
        "Remove" "Cancel" "y" careful || return 0
    # What the install added for the window goes first: when that fails,
    # the app stays installed, so removing it again can try again.
    remove_front_end || return 1
    rm -f -- "$APP_DESKTOP" "$APP_ICON_DIR/${APP_ID}.svg" "$APP_ICON_DIR/${APP_ID}-symbolic.svg" "$APP_ICON_22/${APP_ID}-symbolic.svg"
    [[ -L "$APP_BIN" ]] && rm -f -- "$APP_BIN"
    _remove_copy
    _refresh_menu
    ui_msg "The Security Check app was removed. Past reports were kept."
}

# install_timer — weekly report-only check that notifies the desktop user
# about new findings.
install_timer() {
    ui_yesno "Set up a weekly security check?

It runs in the background once a week, changes nothing (report only),
saves the report in your report folder and shows a notification when it
finds something new.

This copies the tool to ${INSTALL_DIR} and adds
/etc/systemd/system/${UNIT_NAME}.service and .timer." "Set it up" "Cancel" "y" careful || return 0

    _install_copy || return 1

    cat > "/etc/systemd/system/${UNIT_NAME}.service" << EOF
[Unit]
Description=Weekly Bazzite security check (report only)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash ${INSTALL_DIR}/$(basename "$SCRIPT_PATH") --no-gui --no-wizard --report-only --notify --quiet
Nice=10
IOSchedulingClass=idle
EOF
    cat > "/etc/systemd/system/${UNIT_NAME}.timer" << EOF
[Unit]
Description=Weekly Bazzite security check

[Timer]
OnCalendar=weekly
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 "/etc/systemd/system/${UNIT_NAME}.service" "/etc/systemd/system/${UNIT_NAME}.timer"
    systemctl daemon-reload
    if systemctl enable --now "${UNIT_NAME}.timer"; then
        ui_msg "The weekly check is set up. Remove it any time with --remove-timer."
    else
        ui_error "Could not enable ${UNIT_NAME}.timer - see: systemctl status ${UNIT_NAME}.timer"
    fi
}

remove_timer() {
    if ! _timer_installed; then
        ui_msg "The weekly check is not set up."
        return 0
    fi
    ui_yesno "Remove the weekly security check (timer and service)?$(_app_installed || printf ' The copy in %s goes too.' "$INSTALL_DIR")" \
        "Remove" "Cancel" "y" careful || return 0
    systemctl disable --now "${UNIT_NAME}.timer" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${UNIT_NAME}.service" "/etc/systemd/system/${UNIT_NAME}.timer"
    systemctl daemon-reload
    _remove_copy
    ui_msg "The weekly check was removed. Past reports were kept."
}

# notify_desktop — tell the logged-in desktop user about a background run.
notify_desktop() {
    [[ -n "$DESKTOP_USER" ]] || return 0
    local high body
    high=$(_sev_count high)
    [[ ${#DELTA_NEW[@]} -gt 0 || "$high" -gt 0 ]] || return 0
    body="Score ${SCORE}/100. "
    [[ ${#DELTA_NEW[@]} -gt 0 ]] && body+="${#DELTA_NEW[@]} new finding(s). "
    [[ "$high" -gt 0 ]] && body+="${high} high-severity finding(s). "
    body+="Report: ${REPORT_HTML}"
    _as_desktop_user notify-send -a "Security Check" -i security-medium \
        "Weekly security check" "$body" >/dev/null 2>&1 || true
}
