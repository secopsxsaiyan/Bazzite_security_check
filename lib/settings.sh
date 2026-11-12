# shellcheck shell=bash
# Settings: the theme of Security Check's windows and whether to look for a
# new release at start. Kept in $STATE_DIR/settings.conf (root's); only
# known keys with valid values are read back.

readonly APP_REPO="secopsxsaiyan/Bazzite_security_check"
UI_THEME="system"      # system | light | dark
UPDATE_CHECK=0         # 1: look for a new release when an interactive run starts

_settings_file() { printf '%s/settings.conf' "$STATE_DIR"; }

load_settings() {
    local f key val
    f=$(_settings_file)
    [[ -f "$f" && ! -L "$f" && "$(_owner "$f")" == "root" ]] || return 0
    while IFS='=' read -r key val; do
        case "$key" in
            THEME)        [[ "$val" =~ ^(system|light|dark)$ ]] && UI_THEME="$val" ;;
            UPDATE_CHECK) [[ "$val" =~ ^[01]$ ]] && UPDATE_CHECK="$val" ;;
        esac
    done < "$f"
    return 0
}

save_settings() {
    local f
    f=$(_settings_file)
    printf 'THEME=%s\nUPDATE_CHECK=%s\n' "$UI_THEME" "$UPDATE_CHECK" > "$f.tmp" && mv -f -- "$f.tmp" "$f"
}

# _json KEY VALUE... — a JSON object of string values (for the front end).
_json() {
    python3 -I -c 'import json, sys; a = sys.argv[1:]; print(json.dumps(dict(zip(a[::2], a[1::2]))))' "$@"
}

# _settings_answer JSON — the settings window's answer, checked: prints
# "THEME UPDATE_CHECK ACTION" (status 1 for anything else).
_settings_answer() {
    python3 -I -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
t, c, a = d.get("theme"), d.get("update_check"), d.get("action")
if t not in ("system", "light", "dark") or not isinstance(c, bool) or a not in ("save", "update"):
    sys.exit(1)
print(t, int(c), a)' "$1"
}

# run_settings — show the settings, save them, and install an update when
# asked to. The Kirigami window when it can run, else kdialog questions.
run_settings() {
    local out rc theme check action
    out=$(ui_app settings "$(_json version "$SCRIPT_VERSION" repo "$APP_REPO" theme "$UI_THEME" update_check "$UPDATE_CHECK")")
    rc=$?
    [[ $rc -eq 3 ]] && _QML_OK=no
    if [[ $rc -eq 0 ]] && ! read -r theme check action < <(_settings_answer "$out"); then
        log "settings: front-end answer rejected; asking with kdialog"
        _QML_OK=no; rc=3
    fi
    if [[ $rc -eq 0 ]]; then
        :
    elif [[ $rc -eq 3 || $rc -eq 4 ]]; then
        # No Kirigami front end here (4: not tried).
        theme=$(ui_radiolist "Theme of Security Check's windows:" \
            system "Follow the system" "$([[ $UI_THEME == system ]] && echo on || echo off)" \
            light "Light" "$([[ $UI_THEME == light ]] && echo on || echo off)" \
            dark "Dark" "$([[ $UI_THEME == dark ]] && echo on || echo off)") || return 0
        check=0
        ui_yesno "Look for a new release of Security Check when it starts?" "Yes" "No" \
            "$([[ $UPDATE_CHECK -eq 1 ]] && echo y || echo n)" && check=1
        action=save
        ui_yesno "Check for an update now? (Security Check ${SCRIPT_VERSION})" "Check now" "Not now" "n" && action=update
    else
        return 0
    fi
    UI_THEME="$theme"; UPDATE_CHECK="$check"
    save_settings
    ui_theme_prepare
    log "settings: theme=${UI_THEME} update_check=${UPDATE_CHECK}"
    [[ "$action" == update ]] && { update_run; [[ $? -eq 10 ]] && exit 0; }
    return 0
}
