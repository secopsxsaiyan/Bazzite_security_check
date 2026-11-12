# shellcheck shell=bash
# Deep mode: slower sweeps. /usr comes from the signed, read-only image, so
# these look at what can change on this PC: /etc, /var (which holds /home)
# and /opt.

# Paths that are big, belong to container/VM tools, or are caches.
_deep_prune_args() {
    local -n _o="$1"
    _o=( \( -path /var/lib/containers -o -path /var/lib/docker -o -path /var/lib/flatpak
            -o -path /var/lib/waydroid -o -path /var/lib/libvirt -o -path /var/lib/incus
            -o -path /var/cache -o -path /var/log -o -path /var/tmp -o -path /var/lib/ostree
            -o -path /var/home/linuxbrew -o -path '*/.local/share/containers' -o -path '*/.local/share/Steam'
            -o -path '*/.steam' -o -path '*/steamapps' -o -path '*/.var/app' -o -path '*/.cache'
            -o -path '*/node_modules' -o -path '*/.wine' -o -path '*/compatdata'
            -o -fstype nfs -o -fstype nfs4 -o -fstype cifs -o -fstype smb3 -o -fstype fuse.sshfs \) -prune -o )
}

# _deep_find OUT ODD FIND_ARGS... — up to 50 paths that find prints, into
# the array OUT. Paths are read NUL-separated: a line break in a file name
# must not turn one path into two (the second could name any file on the
# PC). Paths with control characters go to ODD instead, shell-quoted so
# they can be shown; no fix is offered for them.
_deep_find() {
    local -n _out="$1" _odd="$2"
    shift 2
    local -a _prune=() _all=()
    local _p
    _deep_prune_args _prune
    _out=(); _odd=()
    mapfile -d '' -t _all < <(timeout 600 find /etc /var /opt "${_prune[@]}" "$@" -print0 2>/dev/null | head -z -n 50 || true)
    for _p in "${_all[@]}"; do
        [[ -n "$_p" ]] || continue
        if [[ "$_p" == *[[:cntrl:]]* ]]; then _odd+=("$(printf '%q' "$_p")"); else _out+=("$_p"); fi
    done
}

# _odd_names_text NAME... — a paragraph about paths with control characters.
_odd_names_text() {
    [[ $# -gt 0 ]] || return 0
    printf 'These have line breaks or other control characters in their name, which is itself suspicious; handle them by hand:\n'
    printf -- '- %s\n' "$@"
}

# ====================== SUID / SGID ======================
check_deep_suid() {
    local -a files=() odd=() items=() fix=()
    local f
    _deep_find files odd -type f -perm /6000
    [[ $(( ${#files[@]} + ${#odd[@]} )) -gt 0 ]] || return 0
    for f in "${files[@]}"; do
        items+=("$(_mode "$f")|${f}")
    done
    [[ ${#items[@]} -gt 0 ]] && fix=(fix_strip_suid "${items[@]}")
    finding medium "$(( ${#files[@]} + ${#odd[@]} )) SUID/SGID program(s) outside the system image" \
"Programs that run with their owner's rights (usually root) were found outside
the read-only, signed /usr:
$([[ ${#files[@]} -gt 0 ]] && printf -- '- %s\n' "${files[@]}")
$(_odd_names_text "${odd[@]}")
Bazzite ships none there. They may come from a game installer, an AppImage
extracted by hand or a tool you installed - or they can be a backdoor." \
"Check where each came from; if not needed: sudo chmod u-s,g-s FILE" \
        "${fix[@]}"
    finding_change "$(( ${#files[@]} + ${#odd[@]} )) SUID/SGID file(s) in /etc, /var or /opt" "the files you tick lose the SUID/SGID bit" \
        "programs may break|A program that needs the bit (some game helpers, sandboxes, VPN clients) stops working until you undo it."
    return 0
}

fix_strip_suid() {
    local -a list=() pick=()
    local e m p
    for e in "$@"; do
        IFS='|' read -r m p <<< "$e"
        if [[ "${p##*/}" =~ ^(passwd|sudo|su|pkexec|mount|umount|newgrp|chsh|chfn|gpasswd|fusermount3?|unix_chkpwd|ping)$ ]]; then
            list+=("$e" "$(ui_item "$p" "mode ${m}" high "A system tool that needs the bit (logins, sudo, mounting): taking it away breaks it for normal accounts.")" off)
        elif [[ "$p" =~ [Ss]team|vpn|VPN|sandbox|chrome|chromium|electron|bwrap ]]; then
            list+=("$e" "$(ui_item "$p" "mode ${m}" high "Looks like a sandbox, game or VPN helper that needs the bit: it will likely stop working.")" off)
        else
            list+=("$e" "$(ui_item "$p" "mode ${m}" medium "A program that needs the bit stops working until you undo this.")" off)
        fi
    done
    mapfile -t pick < <(ui_checklist "Remove the SUID/SGID bit from which files?" "${list[@]}") || return 1
    [[ ${#pick[@]} -gt 0 && -n "${pick[0]}" ]] || return 1
    local script="" undo=""
    local -a names=()
    for e in "${pick[@]}"; do
        IFS='|' read -r m p <<< "$e"
        script+="[ -L $(_q "$p") ] || chmod u-s,g-s -- $(_q "$p")"$'\n'
        # The undo runs as root later: a path swapped for a symlink since
        # must not pass the old mode on to the file it points to.
        undo+="[ -L $(_q "$p") ] || chmod $(_q "$m") -- $(_q "$p")"$'\n'
        names+=("$p")
    done
    CHANGE_AFTER="no SUID/SGID bit: $(_join ', ' "${names[@]}")"
    apply_change "${script%$'\n'}" "${undo%$'\n'}"
}

# ====================== WORLD-WRITABLE ======================
check_deep_world_writable() {
    local -a files=() dirs=() odd=() odd_dirs=()
    _deep_find files odd -type f -perm -0002
    _deep_find dirs odd_dirs -type d -perm -0002 ! -perm -1000
    dirs+=("${odd_dirs[@]}")
    if [[ $(( ${#files[@]} + ${#odd[@]} )) -gt 0 ]]; then
        local -a items=() fix=()
        local f
        for f in "${files[@]}"; do items+=("$(_owner "$f")|$(_mode "$f")|${f}"); done
        [[ ${#items[@]} -gt 0 ]] && fix=(fix_remove_world_write "${items[@]}")
        finding medium "$(( ${#files[@]} + ${#odd[@]} )) file(s) anyone can change" \
"Every account and service on this PC can modify:
$([[ ${#files[@]} -gt 0 ]] && printf -- '- %s\n' "${files[@]}")
$(_odd_names_text "${odd[@]}")
If one of them is a script or config that something runs, that is a way to take
over whatever runs it." \
"chmod o-w FILE   (for each file above)" \
            "${fix[@]}"
        finding_change "$(( ${#files[@]} + ${#odd[@]} )) file(s) writable by every account" "other accounts can no longer change them"
    fi
    if [[ ${#dirs[@]} -gt 0 ]]; then
        finding low "${#dirs[@]} folder(s) anyone can write to without protection" \
"These folders are world-writable without the sticky bit, so any account can
delete or replace files of other accounts in them:
$(printf -- '- %s\n' "${dirs[@]}")" \
"chmod o-w DIR  (or chmod +t DIR if it is meant to be shared, like /tmp)"
    fi
    return 0
}

fix_remove_world_write() {
    local e u m p script="" undo=""
    for e in "$@"; do
        IFS='|' read -r u m p <<< "$e"
        # The undo is guarded like the fix: as the owner, and never through
        # a path that was swapped for a symlink in the meantime.
        if [[ "$u" != "root" && "$u" != "UNKNOWN" && -n "$u" ]]; then
            script+="[ -L $(_q "$p") ] || runuser -u $(_q "$u") -- chmod o-w -- $(_q "$p")"$'\n'
            undo+="[ -L $(_q "$p") ] || runuser -u $(_q "$u") -- chmod $(_q "$m") -- $(_q "$p")"$'\n'
        else
            script+="[ -L $(_q "$p") ] || chmod o-w -- $(_q "$p")"$'\n'
            undo+="[ -L $(_q "$p") ] || chmod $(_q "$m") -- $(_q "$p")"$'\n'
        fi
    done
    apply_change "${script%$'\n'}" "${undo%$'\n'}"
}

# ====================== AUTOSTART / PERSISTENCE ======================
# Hidden folders that toolchains and launchers really install programs into.
readonly _KNOWN_DOT_DIRS="local config var steam cargo rustup nix-profile npm-global nvm bun deno volta pyenv rbenv asdf sdkman dotnet linuxbrew"

# _suspicious_exec CMD — commands that run from temporary or hidden places,
# or download and run code.
_suspicious_exec() {
    local c="$1" rest comp
    [[ "$c" =~ (^|[[:space:]\"\'])(/tmp/|/var/tmp/|/dev/shm/) ]] && return 0
    [[ "$c" =~ (curl|wget)[^|]*\|[[:space:]]*(ba|z)?sh ]] && return 0
    [[ "$c" =~ base64[[:space:]]+(-d|--decode) ]] && return 0
    # Every hidden folder in the command counts on its own, so a known one
    # elsewhere in it (~/.config/...) does not excuse ~/.local/share/.x/payload.
    rest="$c"
    while [[ "$rest" =~ /\.([A-Za-z0-9_-]+)/ ]]; do
        comp="${BASH_REMATCH[1]}"
        [[ " ${_KNOWN_DOT_DIRS} " == *" ${comp} "* ]] || return 0
        rest="${rest#*"/.${comp}"}"
    done
    return 1
}

check_deep_autostart() {
    local u h f exec_line entry
    local -a all=() bad=()
    for u in "${REGULAR_USERS[@]}"; do
        h=$(_home_of "$u")
        for f in "$h"/.config/autostart/*.desktop; do
            [[ -f "$f" ]] || continue
            # Files in a home folder are read as that account (see _user_cat).
            _user_cat "$u" "$f" | grep -qiE '^Hidden[[:space:]]*=[[:space:]]*true' && continue
            exec_line=$(_user_cat "$u" "$f" | sed -n 's/^Exec[[:space:]]*=[[:space:]]*//p' | head -n1)
            entry="${u}: autostart ${f##*/} → ${exec_line}"
            all+=("$entry")
            _suspicious_exec "$exec_line" && bad+=("$entry")
        done
        for f in "$h"/.config/plasma-workspace/env/* "$h"/.config/plasma-workspace/shutdown/*; do
            [[ -f "$f" ]] || continue
            entry="${u}: Plasma login/logout script ${f#"$h"/}"
            all+=("$entry")
            _suspicious_exec "$(_user_cat "$u" "$f")" && bad+=("$entry")
        done
        for f in "$h"/.config/systemd/user/*.wants/*; do
            [[ -e "$f" || -L "$f" ]] || continue
            exec_line=$(_user_cat "$u" "$f" | grep '^ExecStart' | head -n1 || true)
            entry="${u}: user service ${f##*/}${exec_line:+ → ${exec_line#ExecStart=}}"
            all+=("$entry")
            _suspicious_exec "$exec_line" && bad+=("$entry")
        done
        if [[ -s "/var/spool/cron/${u}" ]]; then
            all+=("${u}: crontab ($(grep -cvE '^[[:space:]]*(#|$)' "/var/spool/cron/${u}" || true) job(s))")
            while IFS= read -r exec_line; do
                _suspicious_exec "$exec_line" && bad+=("${u}: cron → ${exec_line}")
            done < <(grep -vE '^[[:space:]]*(#|$)' "/var/spool/cron/${u}" 2>/dev/null || true)
        fi
    done
    # System-wide additions that do not come from the image.
    local d
    for d in /etc/systemd/system /etc/xdg/autostart /etc/cron.d /etc/profile.d; do
        for f in "$d"/*; do
            [[ -f "$f" && ! -L "$f" ]] || continue
            [[ -e "/usr${f}" ]] && continue
            # This tool's own weekly check (--install-timer).
            [[ "$f" == "/etc/systemd/system/${UNIT_NAME}".* ]] && continue
            entry="system: ${f}"
            all+=("$entry")
            _suspicious_exec "$(grep -hsE '^(ExecStart|Exec)=' "$f" | head -n3 || true)" && bad+=("$entry")
        done
    done

    if [[ ${#bad[@]} -gt 0 ]]; then
        finding high "Autostart entries run code from suspicious places" \
"$(printf -- '- %s\n' "${bad[@]}")
Malware commonly persists like this: running from /tmp or a hidden folder, or
downloading a script and piping it into a shell." \
"Look at each entry; if you don't recognise it, disable it (System Settings →
Autostart, systemctl --user disable UNIT, crontab -e) and scan your files."
    fi
    if [[ ${#all[@]} -gt 0 ]]; then
        finding info "${#all[@]} autostart/persistence entr(y/ies) to review" \
"Programs that start automatically, outside the system image:
$(printf -- '- %s\n' "${all[@]}")
Steam (added by Bazzite), Discord and similar are normal here; anything you
don't recognise deserves a look." \
"System Settings → Autostart (user entries), systemctl list-unit-files --state=enabled"
    fi
    return 0
}

# ====================== /etc CHANGES ======================
check_deep_etc_changes() {
    if [[ "$IS_OSTREE" -ne 1 ]] || ! _have ostree; then
        mark_na "not an OSTree system"
        return 0
    fi
    local out
    local -a lines=()
    out=$(timeout 120 ostree admin config-diff 2>/dev/null || true)
    if [[ -z "$out" ]]; then
        check_note "No changes to /etc compared with the image (or ostree could not tell)"
        return 0
    fi
    # Changes every installation has.
    mapfile -t lines < <(grep -vE '[[:space:]](passwd|group|shadow|gshadow|subuid|subgid|machine-id|hostname|localtime|adjtime|locale\.conf|vconsole\.conf|resolv\.conf|\.pwd\.lock|\.updated|ld\.so\.cache|fstab|crypttab|kernel/cmdline|NetworkManager/system-connections/.*|ssh/ssh_host_.*|pki/.*|udev/hwdb\.bin|selinux/targeted/.*|lvm/.*|sysconfig/.*|systemd/system/.*\.wants/.*|sddm\.conf\.d/zz-bazzite-autologin\.conf|nvidia/.*|dconf/db/.*)$' <<< "$out" || true)
    [[ -n "${lines[0]:-}" ]] || lines=()
    check_note "$(grep -c . <<< "$out" || true) file(s) in /etc differ from the image; ${#lines[@]} listed below (changes every installation has, such as passwords and machine IDs, are left out)"
    [[ ${#lines[@]} -gt 0 ]] || return 0

    # Sort each change into an area; every area has a risk grade (what a
    # change there can do) and becomes its own finding, high risk first.
    local line path area kind
    local -A by_area=() count=()
    for line in "${lines[@]}"; do
        path="${line#?}"; path="${path#"${path%%[![:space:]]*}"}"
        area=$(_etc_area "$path")
        # One bullet per file (bullets keep their own line in dialogs).
        case "${line:0:1}" in A) kind="added" ;; D) kind="deleted" ;; *) kind="changed" ;; esac
        by_area["$area"]+="- ${kind}: /etc/${path}"$'\n'
        count["$area"]=$(( ${count[$area]:-0} + 1 ))
    done
    local entry id grade name why list n
    for entry in "${_ETC_AREAS[@]}"; do
        IFS='|' read -r id grade name why _ <<< "$entry"
        n="${count[$id]:-0}"
        [[ $n -gt 0 ]] || continue
        mapfile -t list <<< "${by_area[$id]%$'\n'}"
        finding info "${grade^} risk: ${n} change(s) to ${name}" \
"${why}
Changed on this PC, compared with the system image:
$(printf '%s\n' "${list[@]:0:40}")$([[ $n -gt 40 ]] && printf -- '- … and %d more\n' $(( n - 40 )))

$(case "$grade" in
    high) echo "Check that you (or software you trust) made each of these. An unexpected one here is how malware and intruders keep access." ;;
    medium) echo "Usually deliberate tuning; check the ones you do not recognise." ;;
    *) echo "Rarely a security concern; listed so nothing is hidden." ;;
  esac)" \
"Show one change:
  diff /usr/etc/FILE /etc/FILE
Show an added file:
  cat /etc/FILE
Find what owns an added file:
  rpm -qf /etc/FILE
Put back the image's version:
  sudo cp -a /usr/etc/FILE /etc/FILE
Remove an added file you do not want:
  sudo rm /etc/FILE"
    done
    return 0
}

# _ETC_AREAS — "id|grade|area name|why it matters|path pattern" (an
# extended regular expression matched against the path under /etc).
_ETC_AREAS=(
    "sudo|high|sudo rules|These decide who can become administrator, and whether a password is asked.|^(sudoers|sudo\.conf)"
    "auth|high|login, password and automatic login settings|These decide how logins and passwords are checked; a change can let anyone in.|^(pam\.d/|authselect/|login\.defs$|sddm\.conf|sddm\.conf\.d/|gdm/|plasmalogin\.conf\.d/|security/(pam|access|faillock|pwquality|opasswd|namespace|time\.conf|group\.conf|sepermit|console))"
    "polkit|high|administrator prompts (polkit)|Polkit rules decide which actions need the administrator password.|^polkit-1/"
    "sshd|high|the SSH server|The SSH server settings decide who can log in over the network.|^ssh/sshd_config"
    "boot|high|boot, kernel options and kernel modules|These run or change code before and while the system starts; a modprobe rule can run any program as root.|^(default/grub|grub\.d|dracut\.conf|kernel/|modprobe\.d|modules-load\.d)(/|$|\.)"
    "services|high|services, timers, scheduled jobs and startup scripts|These start programs as root at boot, on a schedule or on an event.|^(systemd/system(/|\.control)|systemd/user/|systemd/system-generators/|containers/systemd/|cron|anacrontab|xdg/autostart/|rc\.d/|rc\.local|binfmt\.d/|dbus-1/system\.d/|NetworkManager/dispatcher\.d/)"
    "loader|high|what every program or shell loads|These add code or settings to every program or login shell.|^(ld\.so\.preload|ld\.so\.conf|profile|profile\.d/|bashrc|environment|zshrc|zprofile)(/|$|\.)"
    "packages|high|software sources and image trust|These decide where software and system images come from and whether their signatures are checked.|^(yum\.repos\.d|containers/(policy\.json|registries)|pki/rpm-gpg|ostree/remotes\.d|dnf/)"
    "udev|high|device rules|udev rules can run programs as root when a device is plugged in.|^udev/rules\.d/"
    "network|medium|network, DNS and firewall settings|These decide where this PC's traffic goes and what can reach it.|^(hosts|ssh/ssh_config|NetworkManager/|firewalld/|nftables|systemd/(resolved|networkd|network/)|dnscrypt|wireguard/|nsswitch\.conf)"
    "kernel|medium|kernel, audit and crypto settings|These tune kernel protections, logging and allowed encryption.|^(sysctl|audit(/|$)|crypto-policies/|selinux/|tmpfiles\.d/|systemd/(system\.conf|logind|journald|coredump)|security/limits)"
    "other|low|other settings|Printing, firmware updates, power profiles, displays and similar.|"
)

# _etc_area PATH — the id of the first _ETC_AREAS entry whose pattern
# matches PATH ("other" when none does).
_etc_area() {
    local entry id pat
    for entry in "${_ETC_AREAS[@]}"; do
        IFS='|' read -r id _ _ _ pat <<< "$entry"
        [[ -n "$pat" ]] || continue
        [[ "$1" =~ $pat ]] && { printf '%s' "$id"; return 0; }
    done
    printf 'other'
}

# ====================== MALWARE SCAN ======================
check_deep_malware() {
    local -a scanner=() targets=()
    if _have clamscan; then
        scanner=(clamscan)
    elif _flatpak_installed com.gitlab.davem.ClamTk; then
        scanner=(flatpak run --command=clamscan com.gitlab.davem.ClamTk)
    else
        mark_skip "ClamAV is not installed (install ClamTk from Flathub to enable this scan)"
        return 0
    fi
    local u h d shared
    local -A by_user=()
    for u in "${REGULAR_USERS[@]}"; do
        h=$(_home_of "$u")
        d=$(_as_user "$u" xdg-user-dir DOWNLOAD 2>/dev/null < /dev/null || true)
        [[ "$d" == /* && "$d" != *$'\n'* && -d "$d" ]] || d="$h/Downloads"
        for d in "$d" "$h/Desktop" "$h/.local/bin" "$h/bin" "$h/.config/autostart"; do
            [[ -d "$d" ]] || continue
            targets+=("$d")
            by_user["$u"]+="${by_user[$u]:+$'\n'}${d}"
        done
    done
    shared="${DESKTOP_USER:-${REGULAR_USERS[0]:-}}"
    if [[ -n "$shared" ]]; then
        targets+=(/tmp /var/tmp)
        by_user["$shared"]+="${by_user[$shared]:+$'\n'}/tmp"$'\n'"/var/tmp"
    fi
    if [[ ${#targets[@]} -eq 0 ]]; then
        mark_skip "no account to run the scan as"
        return 0
    fi
    print_status "INFO" "Scanning $(_join ', ' "${targets[@]}") with ClamAV (can take a while)…"
    # The scanner never runs as root: it parses files that any account (or
    # a download) controls, and a folder name an account reports must not
    # send a root process anywhere. Each account's folders are scanned as
    # that account; the shared temporary folders as the desktop user (or
    # the first account).
    local out="" rc=0 part prc owner
    local -a opts=(-r -i --no-summary --max-filesize=200M --max-scansize=400M)
    if [[ "${scanner[0]}" == "flatpak" ]]; then
        out=$(_as_desktop_user timeout 1800 "${scanner[@]}" "${opts[@]}" "${targets[@]}" 2>&1 < /dev/null) || rc=$?
    else
        for owner in "${!by_user[@]}"; do
            local -a mine=()
            mapfile -t mine <<< "${by_user[$owner]}"
            prc=0
            part=$(_as_user "$owner" timeout 1800 "${scanner[@]}" "${opts[@]}" "${mine[@]}" 2>&1 < /dev/null) || prc=$?
            out+="${part}"$'\n'
            (( prc > rc )) && rc=$prc
        done
    fi
    local found
    found=$(grep -E ' FOUND$' <<< "$out" || true)
    if [[ -n "$found" ]]; then
        finding high "ClamAV found $(grep -c . <<< "$found") infected file(s)" \
"${found}" \
"Delete the files (or check them on virustotal.com if you think it is a false
alarm), then change passwords used on this PC if one of them was run."
    elif [[ $rc -ne 0 && $rc -ne 1 ]] && { [[ $rc -ne 2 ]] || grep -qiE 'database|cl_load|cli_load|engine' <<< "$out"; }; then
        mark_skip "the scan did not finish (exit ${rc}; the virus database may be missing - run freshclam or open ClamTk once)"
    else
        # Exit 2 without a database error: files the scanning account may
        # not read (other accounts' private files in /tmp) were left out.
        check_note "ClamAV scanned: $(_join ', ' "${targets[@]}") - nothing found$([[ $rc -eq 2 ]] && echo " (files the scanning account may not read were left out)")"
    fi
    return 0
}
