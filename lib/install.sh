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
Remove it any time with --uninstall." "${verb}" "Cancel" "y" || return 0

    _install_app_files "$SCRIPT_DIR" || return 1
    local extra=""
    _timer_installed && extra=$'

The weekly check uses the same copy, so it was updated too.'
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
        "Remove" "Cancel" "y" || return 0
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
/etc/systemd/system/${UNIT_NAME}.service and .timer." "Set it up" "Cancel" "y" || return 0

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
        "Remove" "Cancel" "y" || return 0
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
