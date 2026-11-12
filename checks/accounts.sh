# shellcheck shell=bash
# Accounts and access: passwords, sudo rules, automatic login and home
# folder permissions.

# ====================== ACCOUNTS ======================
check_accounts() {
    local u shadow f2
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        finding high "Account '${u}' has administrator rights (UID 0)" \
"Besides root, '${u}' has user ID 0 - it is root under another name. This is a
classic backdoor pattern unless you created it on purpose." \
"Check how it was created, then remove it: sudo userdel ${u}"
        finding_change "'${u}' has UID 0" "only root has UID 0 (manual)"
    done < <(getent passwd 2>/dev/null | awk -F: '$3 == 0 && $1 != "root" {print $1}' || true)

    shadow="$(_r /etc/shadow)"
    if [[ ! -r "$shadow" ]]; then
        mark_skip "cannot read /etc/shadow"
        return 0
    fi
    while IFS=: read -r u f2; do
        [[ -n "$u" ]] || continue
        if [[ -z "$f2" ]]; then
            if [[ "$u" == "$DESKTOP_USER" ]]; then
                finding high "Your account '${u}' has no password" \
"Anyone at the keyboard - or on the network, if a remote login service is on -
can log in as you, and sudo would not ask for anything. A password also
protects KDE Wallet and your saved browser logins." \
"passwd" \
                    fix_set_password "$u"
                finding_change "no password" "a password you type in (twice)" "$W_NOUNDO"
            elif _is_regular_user "$u" || [[ "$u" == "root" ]]; then
                finding high "Account '${u}' has no password" \
"'${u}' can be logged into without any password." \
"Give it a password (sudo passwd ${u}) or lock it (sudo passwd -l ${u})" \
                    fix_lock_account "$u"
                finding_change "'${u}': no password" "'${u}' locked (no password login)" \
                    "$([[ $u == root ]] && echo "emergency shell|Emergency mode can no longer open a root shell; boot an older deployment from the boot menu instead if an update breaks.")"
            else
                # A system or service account: nobody should log in as it.
                local sh sev=low
                sh=$(getent passwd "$u" 2>/dev/null | cut -d: -f7 || true)
                [[ -n "$sh" && ! "$sh" =~ (nologin|false)$ ]] && sev=high
                finding "$sev" "System account '${u}' has no password" \
"'${u}' has an empty password field$([[ $sev == high ]] && echo " and a login shell (${sh}), so it can be logged into without any password" || echo "; its shell (${sh:-none}) refuses logins, but an empty password is never needed for a service account")." \
"Lock it: sudo passwd -l ${u}" \
                    fix_lock_account "$u"
                finding_change "'${u}': no password" "'${u}' locked (no password login)"
            fi
        elif [[ "$u" == "root" && "$f2" == \$* ]]; then
            finding info "The root account has its own password" \
"Bazzite does not need a root password (administration goes through your
account and sudo/polkit). A root password is one more password that can be
guessed at a text console. Keeping it is fine if you use it for emergency mode." \
"sudo passwd -l root   (lock it; sudo keeps working)" \
                fix_lock_account root
            finding_change "root has its own password" "root password locked (sudo keeps working)" \
                "emergency shell|Emergency mode can no longer open a root shell; boot an older deployment from the boot menu instead if an update breaks."
        fi
    done < <(awk -F: '{print $1 ":" $2}' "$shadow" 2>/dev/null || true)

    local wheel
    wheel=$(getent group wheel 2>/dev/null | cut -d: -f4 || true)
    check_note "Administrators (wheel): ${wheel:-none}"
    return 0
}

# fix_set_password USER — set a password for USER (asked in a dialog).
fix_set_password() {
    local u="$1" pw
    ui_yesno "Set a password for '${u}' now?
You will be asked for it twice. It is passed to chpasswd directly and never written to a file or log." \
        "Set a password" "Skip" "y" || return 1
    pw=$(ui_newpassword "New password for ${u}") || return 1
    if printf '%s:%s\n' "$u" "$pw" | chpasswd 2>>"$RUN_LOG"; then
        unset pw
        print_status "OK" "Password set for ${u}"
        return 0
    fi
    unset pw
    ui_error "Setting the password failed - see ${RUN_LOG}"
    return 3
}

fix_lock_account() {
    local u="${1:-}"
    [[ -n "$u" ]] || return 1
    apply_change "passwd -l $(_q "$u")" "passwd -u $(_q "$u")"
}

# ====================== SUDO ======================
# _sudoers_files — the files sudo reads (sudoers.d names without '.' or '~').
_sudoers_files() {
    local f name
    [[ -f "$(_r /etc/sudoers)" ]] && printf '%s\n' "$(_r /etc/sudoers)"
    for f in "$(_r /etc/sudoers.d)"/*; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        [[ "$name" == *.* || "$name" == *"~" ]] && continue
        printf '%s\n' "$f"
    done | LC_ALL=C sort
}

check_sudo() {
    local f rel line rule no text img
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        rel="${f#"${AUDIT_ROOT:-}"}"
        img=0
        [[ -f "$(_r "/usr${rel}")" ]] && cmp -s "$f" "$(_r "/usr${rel}")" && img=1
        while IFS=: read -r no text; do
            [[ -n "$no" ]] || continue
            line="$(sed 's/^[[:space:]]*//' <<< "$text")"
            # The rule without a trailing comment, for the tests below.
            rule="$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<< "$line")"
            # Every command ("NOPASSWD: ALL", also followed by exclusions,
            # which are easy to get around), or a command that hands out a
            # root shell on its own.
            if [[ "$rule" =~ NOPASSWD:[[:space:]]*ALL([[:space:]]*,.*)?$ || "$rule" =~ !authenticate \
               || "$rule" =~ NOPASSWD:.*/(su|env|(ba|da|z|fi|k)?sh|python[0-9.]*|perl|ruby|vim?|nano|less|find|awk|sudoedit|systemd-run|pkexec)([[:space:],]|$) ]]; then
                if [[ $img -eq 1 ]]; then
                    finding info "The system image allows some commands without a password" \
"${rel}:${no}: ${line}  (shipped with the image)" ""
                else
                    finding medium "sudo works without a password" \
"${rel}, line ${no}: ${line}
Any program running as you - a game mod, a browser exploit, a malicious npm or
pip package - can become root silently, without the password prompt that would
otherwise warn you." \
"Edit with: sudo visudo -f ${rel}   and remove NOPASSWD: from line ${no}" \
                        fix_sudo_line "$rel" "$no" "$line"
                    if [[ "$line" == *NOPASSWD:* ]]; then
                        finding_change "${rel}:${no}: ${line}" "${rel}:${no}: ${line//NOPASSWD:/PASSWD:}" \
                            "asks for the password|Scripts and tools that run sudo without a password will start asking for it."
                    else
                        finding_change "${rel}:${no}: ${line}" "line ${no} commented out (sudo asks for the password)" \
                            "asks for the password|Scripts and tools that run sudo without a password will start asking for it."
                    fi
                fi
            elif [[ "$line" == *NOPASSWD:* ]]; then
                check_note "${rel}:${no}: specific commands allowed without a password: ${line}"
            fi
        done < <(grep -nE '^[[:space:]]*[^#[:space:]].*(NOPASSWD:|!authenticate)' "$f" 2>/dev/null || true)
    done < <(_sudoers_files)

    # polkit rules that approve everything for a group or user.
    for f in "$(_r /etc/polkit-1/rules.d)"/*.rules; do
        [[ -f "$f" ]] || continue
        if grep -q 'Result.YES' "$f" 2>/dev/null && ! grep -q 'action.id' "$f" 2>/dev/null; then
            finding medium "A polkit rule approves admin actions without asking" \
"${f#"${AUDIT_ROOT:-}"} returns YES without looking at which action is requested,
so system settings, software installs and more are approved silently." \
"Review it and limit it to specific action.id values, or remove it: sudo rm ${f#"${AUDIT_ROOT:-}"}"
            finding_change "${f##*/} approves every admin action" "limited to specific action.id values (manual)"
        fi
    done
    return 0
}

# fix_sudo_line FILE LINE TEXT — make the rule ask for a password again
# (NOPASSWD: becomes PASSWD:, so the account keeps its sudo rights; a
# "!authenticate" Defaults line is commented out), validated by visudo.
fix_sudo_line() {
    local file="$1" no="$2" text="$3" edit script restore_cmd
    if [[ "$text" == *NOPASSWD:* ]]; then
        edit="${no}s/NOPASSWD:/PASSWD:/g"
    else
        edit="${no}s/^/# disabled by bazzite-sec-audit: /"
    fi
    restore_cmd=$(_restore_cmd "$file")
    script=$(cat <<EOF
$(_backup_cmd "$file")
sed -i '${edit}' -- $(_q "$file")
if ! visudo -c >/dev/null 2>&1; then
    $(printf '%s' "$restore_cmd" | tr '\n' ';')
    echo 'visudo rejected the change; restored' >&2
    exit 1
fi
EOF
)
    apply_change "$script" "$restore_cmd" "visudo checks the edited rules; if it rejects them, the file is put back as it was."
}

# ====================== AUTOMATIC LOGIN ======================
# _sddm_autologin — "file<TAB>user<TAB>session" of the effective SDDM
# autologin (later files win: /usr/lib conf.d, /etc conf.d, /etc/sddm.conf).
_sddm_autologin() {
    local -a files=()
    local f
    for f in "$(_r /usr/lib/sddm/sddm.conf.d)"/*.conf "$(_r /etc/sddm.conf.d)"/*.conf "$(_r /etc/sddm.conf)"; do
        [[ -f "$f" ]] && files+=("$f")
    done
    [[ ${#files[@]} -gt 0 ]] || return 0
    awk -v root="${AUDIT_ROOT:-}" '
        FNR == 1 { sec = "" }
        /^[ \t]*[#;]/ { next }
        /^[ \t]*\[/ { sec = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", sec); next }
        sec == "Autologin" {
            i = index($0, "="); if (i == 0) next
            k = substr($0, 1, i - 1); v = substr($0, i + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
            fn = FILENAME; if (root != "" && index(fn, root) == 1) fn = substr(fn, length(root) + 1)
            if (k == "User") { user = v; ufile = fn }
            if (k == "Session") session = v
        }
        END { if (user != "") print ufile "\t" user "\t" session }' "${files[@]}" 2>/dev/null || true
}

check_autologin() {
    local file="" user="" session="" sev
    if [[ "$DESKTOP_ENV" == "gnome" ]]; then
        local gdm en
        gdm="$(_r /etc/gdm/custom.conf)"
        en=$(_ini_get "$gdm" daemon AutomaticLoginEnable)
        if [[ "${en,,}" == "true" || "$en" == "1" ]]; then
            file="/etc/gdm/custom.conf"
            user=$(_ini_get "$gdm" daemon AutomaticLogin)
        fi
    else
        IFS=$'\t' read -r file user session < <(_sddm_autologin) || true
    fi
    if [[ -z "$user" ]]; then
        check_note "No automatic login"
        return 0
    fi
    check_note "Automatic login as ${user} (${file}${session:+, session ${session}})"

    if [[ "$session" == *gamescope* ]]; then
        finding info "Starts straight into Game Mode without a password" \
"This PC logs in as ${user} into Steam Game Mode, like a console. That is how
Bazzite's HTPC/handheld images are meant to work. Keep in mind that anyone with
the device can switch to Desktop Mode from there$([[ $DISK_ENCRYPTED == yes ]] || echo ", and the disk is not encrypted")." \
"If others can get hold of the device: turn off automatic login in Bazzite's
settings (Steam → Settings → System, or the Bazzite Portal) and set a screen lock."
        return 0
    fi

    if [[ "$DISK_ENCRYPTED" == "yes" ]]; then
        sev=$(_ctx low info)
    else
        sev=$(_ctx medium low)
    fi
    local fixable=1
    [[ "$file" == /usr/* ]] && fixable=2
    [[ "$IS_DECK" -eq 1 && "$file" == */zz-bazzite-autologin.conf ]] && fixable=0
    local detail
    detail="The desktop opens as '${user}' without asking for a password. Anyone who can
switch the PC on gets your browser sessions, chats, saved logins and files.
$([[ $DISK_ENCRYPTED == yes ]] && echo "Your disk is encrypted, so at least a stolen drive is protected; the PC itself still opens up when switched on." || echo "The disk is not encrypted either, so anyone who can switch the PC on gets everything; the drive is exposed if it is taken.")
KDE Wallet cannot unlock itself with your login password when automatic login
is on, which often leads to wallets with an empty password."
    local manual="System Settings → Colors & Themes → Login Screen (SDDM) → Behavior → untick \"Automatically log in\"
(the setting is in ${file})"
    case "$fixable" in
        1) finding "$sev" "Automatic login is on" "$detail" "$manual" fix_autologin_off "$file" ;;
        2) finding "$sev" "Automatic login is on" "$detail" "$manual" fix_autologin_override ;;
        *) finding "$sev" "Automatic login is on" "$detail" \
"Bazzite manages this setting on this image (bazzite-autologin rewrites ${file} at boot);
change it with Bazzite's own setting instead." ;;
    esac
    finding_change "logs in as ${user} without a password (${file})" \
        "the login screen asks for the password$([[ $fixable -eq 2 ]] && echo " (override in /etc/sddm.conf.d)")" \
        "next login screen|Takes effect at the next login screen; your current session is not affected."
    return 0
}

# fix_autologin_off FILE — comment out the User= line in FILE.
fix_autologin_off() {
    local file="$1" key="User" script
    [[ "$file" == /etc/gdm/* ]] && key="AutomaticLoginEnable"
    script=$(cat <<EOF
$(_backup_cmd "$file")
sed -i 's/^[[:space:]]*${key}[[:space:]]*=/# disabled by bazzite-sec-audit: &/' -- $(_q "$file")
EOF
)
    apply_change "$script" "$(_restore_cmd "$file")"
}

# fix_autologin_override — the setting comes from /usr (read-only): override
# it with an empty user in /etc.
fix_autologin_override() {
    local f=/etc/sddm.conf.d/zz-bazzite-sec-audit.conf
    local script
    script=$(cat <<EOF
mkdir -p -- /etc/sddm.conf.d
$(_backup_cmd "$f")
printf '%s\n' '[Autologin]' 'User=' > $(_q "$f")
EOF
)
    apply_change "$script" "$(_restore_cmd "$f")" \
        "The setting comes from the read-only image, so it is overridden in /etc instead of edited."
}

# ====================== HOME FOLDERS ======================
check_home_permissions() {
    local u h m others
    others=$(( ${#REGULAR_USERS[@]} - 1 ))
    for u in "${REGULAR_USERS[@]}"; do
        h=$(_home_of "$u")
        [[ -d "$h" && ! -L "$h" ]] || continue
        m=$(_mode "$h")
        [[ "$m" =~ ^[0-7]+$ ]] || continue
        check_note "${h}: mode ${m}"
        if (( (8#$m & 8#007) != 0 )); then
            finding "$([[ $others -gt 0 ]] && echo medium || echo low)" "${u}'s home folder is open to other accounts" \
"${h} has mode ${m}: other accounts$([[ $others -gt 0 ]] && echo " (there are ${others} other user(s) on this PC)") and system
services can look inside, and read any file in it that is not locked down on its
own (SSH keys, browser profiles, .env files). Bazzite's default is 700." \
"sudo chmod o-rwx ${h}" \
                fix_home_mode "$u" "$h" "$m"
            finding_change "${h}: mode ${m}" "${h}: mode $(printf '%o' $(( 8#$m & ~8#007 )))" \
                "shared folders|If another account or a Samba share uses a folder inside it, that stops working."
        fi
    done
    return 0
}

fix_home_mode() {
    local u="$1" h="$2" m="$3"
    apply_change "[ -L $(_q "$h") ] || chmod o-rwx -- $(_q "$h")" \
        "[ -L $(_q "$h") ] || chmod $(_q "$m") -- $(_q "$h")"
}
