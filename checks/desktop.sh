# shellcheck shell=bash
# The desktop session and home folders: screen locking, SSH keys, tokens and
# other secrets developers leave lying around.

# ====================== SCREEN LOCK ======================
_kwriteconfig() {
    if _have kwriteconfig6; then echo kwriteconfig6
    elif _have kwriteconfig5; then echo kwriteconfig5
    fi
}

check_screen_lock() {
    if [[ "$DESKTOP_ENV" != "kde" ]]; then
        mark_na "not a KDE Plasma desktop"
        return 0
    fi
    local u h rc autolock timeout resume e key type new old unit
    local -a issues=() sets=() now=() after=()
    local checked=0
    for u in "${REGULAR_USERS[@]}"; do
        h=$(_home_of "$u")
        [[ -d "$h/.config" ]] || continue
        checked=$((checked + 1))
        rc="$h/.config/kscreenlockerrc"
        autolock=$(_user_ini_get "$u" "$rc" Daemon Autolock)
        timeout=$(_user_ini_get "$u" "$rc" Daemon Timeout)
        resume=$(_user_ini_get "$u" "$rc" Daemon LockOnResume)
        # Plasma's defaults: lock after 5 minutes, and on waking from sleep.
        check_note "${u}: $([[ ${autolock,,} == false ]] && echo "never locks by itself" || echo "locks after ${timeout:-5} min$([[ -z $timeout ]] && echo " (default)")"); $([[ ${resume,,} == false ]] && echo "does not lock on waking" || echo "locks on waking")"
        issues=(); sets=()
        if [[ "${autolock,,}" == "false" ]]; then
            issues+=("the screen never locks by itself")
            sets+=("Autolock|bool|true|${autolock}")
        elif [[ "$timeout" =~ ^[0-9]+$ ]] && (( timeout > 30 )); then
            issues+=("it locks only after ${timeout} minutes")
            sets+=("Timeout|int|10|${timeout}")
        fi
        if [[ "${resume,,}" == "false" ]]; then
            issues+=("it does not lock when waking from sleep")
            sets+=("LockOnResume|bool|true|${resume}")
        fi
        [[ ${#issues[@]} -gt 0 ]] || continue
        now=(); after=()
        for e in "${sets[@]}"; do
            IFS='|' read -r key type new old <<< "$e"
            unit=""
            [[ "$key" == "Timeout" ]] && unit=" min"
            now+=("${key}=${old:-default}${unit}")
            after+=("${key}=${new}${unit}")
        done
        finding "$(_ctx medium low)" "${u}'s screen does not lock reliably" \
"For ${u}: $(_join '; ' "${issues[@]}").
An unlocked desktop gives anyone who walks by your browser sessions, chats and
files. Games and videos in fullscreen keep the screen awake on their own, so
auto-lock does not interrupt them." \
"System Settings → Security & Privacy → Screen Locking:
lock automatically after 10 minutes, and after waking from sleep" \
            fix_screen_lock "$u" "${sets[@]}"
        finding_change "${u}: $(_join ', ' "${now[@]}")" "${u}: $(_join ', ' "${after[@]}")"
    done
    [[ $checked -gt 0 ]] || mark_na "no user has a Plasma configuration yet"
    return 0
}

# fix_screen_lock USER KEY|TYPE|NEW|OLD... — write kscreenlockerrc as USER.
fix_screen_lock() {
    local u="$1" kw script="" undo="" e key type new old uid
    shift
    kw=$(_kwriteconfig)
    [[ -n "$kw" ]] || { ui_error "kwriteconfig6 is not installed; change it in System Settings instead."; return 3; }
    uid=$(id -u "$u")
    for e in "$@"; do
        IFS='|' read -r key type new old <<< "$e"
        script+="runuser -u $(_q "$u") -- ${kw} --file kscreenlockerrc --group Daemon --key ${key} --type ${type} ${new}"$'\n'
        if [[ -n "$old" ]]; then
            undo+="runuser -u $(_q "$u") -- ${kw} --file kscreenlockerrc --group Daemon --key ${key} --type ${type} $(_q "$old")"$'\n'
        else
            undo+="runuser -u $(_q "$u") -- ${kw} --file kscreenlockerrc --group Daemon --key ${key} --delete"$'\n'
        fi
    done
    # Ask the running screen locker to re-read its settings (best effort).
    script+="runuser -u $(_q "$u") -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus busctl --user call org.freedesktop.ScreenSaver /ScreenSaver org.kde.screensaver configure >/dev/null 2>&1 || true"
    apply_change "$script" "${undo%$'\n'}" "If the change does not show up right away, it applies at the next login."
}

# ====================== SECRETS ======================
# Plain-text credential files: path (relative to home) | what | pattern that
# shows a secret is stored in it.
readonly -a _SECRET_FILES=(
    ".git-credentials|Git passwords/tokens|."
    ".config/gh/hosts.yml|GitHub CLI token|oauth_token:"
    ".aws/credentials|AWS access keys|aws_secret_access_key"
    ".npmrc|npm registry token|(_authToken|_password)"
    ".pypirc|PyPI password|password"
    ".docker/config.json|Docker registry login|\"auth\"[[:space:]]*:[[:space:]]*\"[^\"]"
    ".netrc|.netrc passwords|password"
    ".kube/config|Kubernetes credentials|(token:|client-key-data:)"
    ".config/rclone/rclone.conf|rclone cloud credentials|(pass|token)[[:space:]]*="
    ".cargo/credentials.toml|crates.io token|token"
)

_PRIVKEY_RE='^-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----'

# _other_readable PATH — readable by accounts other than the owner (o+r).
_other_readable() {
    local m
    m=$(_mode "$1")
    [[ "$m" =~ ^[0-7]+$ ]] && (( (8#$m & 8#004) != 0 ))
}

check_secrets() {
    local u h home_open f rel what pat m n
    local -a perm_items=() perm_lines=() plain=() nopass=()
    for u in "${REGULAR_USERS[@]}"; do
        h=$(_home_of "$u")
        [[ -d "$h" ]] || continue
        home_open=0
        m=$(_mode "$h")
        [[ "$m" =~ ^[0-7]+$ ]] && (( (8#$m & 8#001) != 0 )) && home_open=1

        # SSH private keys: permissions and passphrases.
        if [[ -d "$h/.ssh" && ! -L "$h/.ssh" ]]; then
            for f in "$h/.ssh"/*; do
                [[ -f "$f" && ! -L "$f" ]] || continue
                [[ "$f" == *.pub || "${f##*/}" == known_hosts* || "${f##*/}" == authorized_keys* || "${f##*/}" == config ]] && continue
                # Read as the account (see _user_cat). A key root owns
                # (copied in with sudo) is read by root, through _root_cat,
                # and its text never goes to a process of the account.
                local key_root=0
                [[ "$(stat -c %u -- "$f" 2>/dev/null)" == 0 ]] && key_root=1
                if [[ $key_root -eq 1 ]]; then
                    _root_cat "$f" | head -c 4096 | grep -qE "$_PRIVKEY_RE" || continue
                else
                    _as_user "$u" timeout 5 head -c 4096 -- "$f" 2>/dev/null < /dev/null | grep -qE "$_PRIVKEY_RE" || continue
                fi
                if _other_readable "$f"; then
                    perm_items+=("${u}|$(_mode "$f")|${f}")
                    perm_lines+=("${f} (mode $(_mode "$f"))")
                fi
                if _have ssh-keygen; then
                    local pub
                    # Piped: ssh-keygen refuses its owner a key file other
                    # accounts can read, which this check must still see.
                    if [[ $key_root -eq 1 ]]; then
                        pub=$(_root_cat "$f" | timeout 5 ssh-keygen -y -P "" -f /dev/stdin 2>/dev/null) || pub=""
                        [[ -n "$pub" && "$pub" != sk-* ]] && nopass+=("${f}")
                    elif pub=$(_as_user "$u" timeout 5 sh -c 'cat -- "$1" | ssh-keygen -y -P "" -f /dev/stdin' sh "$f" 2>/dev/null) \
                       && [[ "$pub" != sk-* ]]; then
                        nopass+=("${f}")
                    fi
                fi
            done
        fi

        # Credential files of developer tools.
        local entry
        for entry in "${_SECRET_FILES[@]}"; do
            IFS='|' read -r rel what pat <<< "$entry"
            f="$h/$rel"
            [[ -f "$f" && ! -L "$f" ]] || continue
            if _other_readable "$f"; then
                perm_items+=("${u}|$(_mode "$f")|${f}")
                perm_lines+=("${f} - ${what} (mode $(_mode "$f"))")
            fi
            if _as_user "$u" grep -qsE -- "$pat" "$f" 2>/dev/null < /dev/null; then
                [[ "$rel" == ".docker/config.json" ]] && _as_user "$u" grep -qs '"credsStore"' "$f" < /dev/null && continue
                plain+=("~${u}/${rel} (${what})")
            fi
        done

        # .env files with secrets that other accounts can read.
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            _as_user "$u" grep -qsiE '^(export[[:space:]]+)?[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*[[:space:]]*=[[:space:]]*[^[:space:]]' "$f" < /dev/null || continue
            perm_items+=("${u}|$(_mode "$f")|${f}")
            perm_lines+=("${f} - .env with secrets (mode $(_mode "$f"))")
        done < <(_as_user "$u" timeout 60 find "$h" -maxdepth 5 \
                    \( -name node_modules -o -name .git -o -name .cache -o -name .var -o -name .local \
                       -o -name .steam -o -name steamapps -o -name .wine -o -name .cargo -o -name .rustup \
                       -o -name .npm -o -name go -o -name Games -o -name .mozilla \) -prune \
                    -o -type f \( -name '.env' -o -name '.env.*' \) ! -name '*.example' ! -name '*.sample' \
                       ! -name '*.template' ! -path $'*\n*' -perm -o=r -print 2>/dev/null < /dev/null || true)

        if [[ ${#perm_items[@]} -gt 0 ]]; then
            n=${#perm_items[@]}
            local -A modes=()
            local item
            for item in "${perm_items[@]}"; do modes["$(cut -d'|' -f2 <<< "$item")"]=1; done
            finding "$([[ $home_open -eq 1 ]] && echo medium || echo low)" "${n} private key or credential file(s) of ${u} are readable by others" \
"$(printf -- '- %s\n' "${perm_lines[@]}")
$([[ $home_open -eq 1 ]] && echo "${u}'s home folder lets other accounts in, so they can read these files right now." || echo "${u}'s home folder is private, which hides them for now - but they should be private on their own too (backups, shared folders, a later permission change).")" \
"chmod 600 FILE   (for each file above, as ${u})" \
                fix_chmod_files "${perm_items[@]}"
            finding_change "${n} file(s) readable by other accounts (mode $(_join ', ' "${!modes[@]}"))" "mode 600: only ${u} can read them"
            unset modes
        fi
        perm_items=(); perm_lines=()
    done

    if [[ ${#nopass[@]} -gt 0 ]]; then
        finding "$(_ctx medium low)" "${#nopass[@]} SSH private key(s) have no passphrase" \
"$(printf -- '- %s\n' "${nopass[@]}")
Anything that can copy the file - malware running as you, a stolen backup or
drive - can use the key (GitHub pushes, servers, ...)." \
"ssh-keygen -p -f KEY   (adds a passphrase; KDE Wallet can remember it via ksshaskpass,
so you only type it once per login)"
        finding_change "${#nopass[@]} key(s) without a passphrase" "passphrase set (ssh-keygen -p - manual)"
    fi
    if [[ ${#plain[@]} -gt 0 ]]; then
        finding info "Developer tools store tokens in plain text" \
"$(printf -- '- %s\n' "${plain[@]}")
Malicious packages (npm, pip, game mods) look for exactly these files. Where a
tool can use the KDE Wallet / Secret Service instead, prefer that." \
"git:    git config --global credential.helper libsecret   (or use gh auth / SSH keys)
gh:     gh auth login  (stores the token in the keyring when available)
docker: set \"credsStore\": \"secretservice\" in ~/.docker/config.json
others: keep them, but rotate the tokens if you ever suspect malware"
    fi
    return 0
}

# fix_chmod_files OWNER|MODE|PATH... — chmod 600 as the file's owner (so a
# path swapped for a symlink cannot reach anyone else's files).
fix_chmod_files() {
    local e u m p script="" undo=""
    for e in "$@"; do
        IFS='|' read -r u m p <<< "$e"
        script+="[ -L $(_q "$p") ] || runuser -u $(_q "$u") -- chmod 600 -- $(_q "$p")"$'\n'
        undo+="[ -L $(_q "$p") ] || runuser -u $(_q "$u") -- chmod $(_q "$m") -- $(_q "$p")"$'\n'
    done
    apply_change "${script%$'\n'}" "${undo%$'\n'}"
}
