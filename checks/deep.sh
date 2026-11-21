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
        if [[ "${p##*/}" =~ ^(passwd|sudo|su|pkexec|mount|umount|newgrp|chsh|chfn|gpasswd|fusermount3?|unix_chkpwd|ping|polkit-agent-helper-1|newuidmap|newgidmap|ssh-keysign)$ ]]; then
            list+=("$e" "$(ui_item "$p" "mode ${m}" high "A system tool that needs the bit (logins, sudo, mounting): taking it away breaks it for normal accounts.")" off)
        elif [[ "$p" =~ [Ss]team|vpn|VPN|sandbox|chrome|chromium|electron|bwrap ]]; then
            list+=("$e" "$(ui_item "$p" "mode ${m}" high "Looks like a sandbox, game or VPN helper that needs the bit: it will likely stop working.")" off)
        else
            list+=("$e" "$(ui_item "$p" "mode ${m}" medium "A program that needs the bit stops working until you undo this.")" off)
        fi
    done
    mapfile -t pick < <(ui_checklist "Remove the SUID/SGID bit from which files?" "${list[@]}") || return 1
    [[ ${#pick[@]} -gt 0 && -n "${pick[0]}" ]] || return 1
    local script="" undo="" u root=0
    local -a names=() byhand=()
    for e in "${pick[@]}"; do
        IFS='|' read -r m p <<< "$e"
        # As its owner for a normal account's file; as root only where no
        # other account can swap the file or a folder above it - also in
        # the undo, which runs as root later.
        u=$(_owner "$p")
        if _chmod_by_hand "$u" "$p"; then byhand+=("$p"); continue; fi
        _chmod_lines "$u" u-s,g-s "$m" "$p"
        script+="${_CL_FIX}"$'\n'
        undo+="${_CL_UNDO}"$'\n'
        [[ $_CL_ROOT -eq 1 ]] && root=1
        names+=("$p")
    done
    _deep_chmod_apply "no SUID/SGID bit" "$script" "$undo" "$root" "${#names[@]}" "${names[@]}" "${byhand[@]}"
}

# _deep_chmod_apply AFTER SCRIPT UNDO ROOT N NAME... BYHAND... — offer the
# chmod lines of a deep-check fix (AFTER, when given, heads the list of
# files in the "after" row). The first N of the names are changed;
# the rest are files the tool will not change as root (see _chmod_by_hand).
_deep_chmod_apply() {
    local after="$1" script="$2" undo="$3" root="$4" n="$5" note=""
    shift 5
    local -a names=("${@:1:n}") byhand=("${@:n+1}")
    if [[ ${#byhand[@]} -gt 0 ]]; then
        note="Not changed by this tool, because another account can change a folder above them (it could point the change at a different file): $(_join ', ' "${byhand[@]}"). Change these by hand if they should be changed."
    fi
    if [[ ${#names[@]} -eq 0 ]]; then
        [[ -n "$note" ]] && ui_msg "$note"
        return 1
    fi
    if [[ "$root" -eq 1 ]]; then
        # The changes first, the helper they use after them: the
        # confirmation shows the start of the script.
        script="changes() {"$'\n'"${script}}"$'\n'"${_ROOT_CHMOD_FN}"$'\n'"changes"$'\n'
        undo="changes() {"$'\n'"${undo}}"$'\n'"${_ROOT_CHMOD_FN}"$'\n'"changes"$'\n'
    fi
    [[ -n "$after" ]] && CHANGE_AFTER="${after}: $(_join ', ' "${names[@]}")"
    apply_change "${script%$'\n'}" "${undo%$'\n'}" "$note"
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
    local e u m p script="" undo="" root=0
    local -a names=() byhand=()
    for e in "$@"; do
        IFS='|' read -r u m p <<< "$e"
        # As in fix_strip_suid: as the owner, or as root only on a path
        # that no other account can swap - now and when it is undone.
        if _chmod_by_hand "$u" "$p"; then byhand+=("$p"); continue; fi
        _chmod_lines "$u" o-w "$m" "$p"
        script+="${_CL_FIX}"$'\n'
        undo+="${_CL_UNDO}"$'\n'
        [[ $_CL_ROOT -eq 1 ]] && root=1
        names+=("$p")
    done
    _deep_chmod_apply "" "$script" "$undo" "$root" "${#names[@]}" "${names[@]}" "${byhand[@]}"
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
readonly _CLAMUI_APP="io.github.linx_systems.ClamUI"
readonly _CLAMAV_SCAN_LIMIT=1800     # seconds for one account's folders
readonly _CLAMAV_DEFS_OLD=7          # days before the definitions count as old

# _clamav_db_dir — where freshclam keeps the virus definitions
# (DatabaseDirectory in /etc/freshclam.conf, else ClamAV's default).
_clamav_db_dir() {
    local d
    d=$(sed -n 's/^[[:space:]]*DatabaseDirectory[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$(_r /etc/freshclam.conf)" 2>/dev/null | tail -n 1)
    [[ "$d" == \"*\" ]] && d="${d:1:${#d}-2}"
    [[ "$d" == /* && "$d" != *$'\n'* ]] || d=/var/lib/clamav
    printf '%s' "${d%/}"
}

# _clamav_defs_age DIR — days since the daily definitions in DIR were last
# written. Status 1 with "none" (no definitions at all) or "partial" (the
# main or the daily set is missing: ClamAV needs both) instead.
_clamav_defs_age() {
    local dir f t newest=0 main=0 any=0
    dir=$(_r "$1")
    for f in "$dir/main.cvd" "$dir/main.cld"; do
        [[ -f "$f" && ! -L "$f" && -s "$f" ]] && { main=1; any=1; }
    done
    for f in "$dir/daily.cvd" "$dir/daily.cld"; do
        [[ -f "$f" && ! -L "$f" && -s "$f" ]] || continue
        any=1
        t=$(stat -c %Y -- "$f" 2>/dev/null) || continue
        (( t > newest )) && newest=$t
    done
    if (( main == 0 || newest == 0 )); then
        (( any )) && printf 'partial' || printf 'none'
        return 1
    fi
    t=$(( ( $(date +%s) - newest ) / 86400 ))
    (( t < 0 )) && t=0
    printf '%s' "$t"
}

# _clamav_pending PACKAGE... — those of PACKAGE that a system image ahead
# of the running one requests: layered, waiting for the restart. The
# rollback image (behind the running one) does not count.
_clamav_pending() {
    [[ -n "${RPMOSTREE_JSON:-}" ]] || return 0
    python3 -I -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(0)
deps = [x for x in (d.get("deployments") or []) if isinstance(x, dict)]
booted = next((i for i, x in enumerate(deps) if x.get("booted")), 0)
ahead = [x for i, x in enumerate(deps) if x.get("staged") or i < booted]
req = [x.get("requested-packages") for x in ahead]
req = [r for r in req if isinstance(r, list)]
print(" ".join(p for p in sys.argv[1:] if any(p in r for r in req)))' "$@" <<< "$RPMOSTREE_JSON" 2>/dev/null || true
}

# _clamav_official_dbs — the definitions freshclam takes from ClamAV's own
# mirrors: main, daily and bytecode, and safebrowsing or valhalla when an
# ExtraDatabase line asks for them; not those freshclam.conf leaves out
# (ExcludeDatabase, "Bytecode no"). The definitions fix updates only these
# (--update-db): freshclam refuses the whole update for a name it does not
# know there, and "custom" would fetch the extra sources again.
_clamav_official_dbs() {
    local x conf
    local -A out=()
    conf=$(_r /etc/freshclam.conf)
    for x in main daily bytecode; do out["$x"]=1; done
    while IFS= read -r x; do
        x="${x,,}"
        [[ "$x" == safebrowsing || "$x" == valhalla ]] && out["$x"]=1
    done < <(sed -n 's/^[[:space:]]*ExtraDatabase[[:space:]]\{1,\}\([^[:space:]]\{1,\}\)[[:space:]]*$/\1/p' "$conf" 2>/dev/null)
    while IFS= read -r x; do
        unset 'out[${x,,}]'
    done < <(sed -n 's/^[[:space:]]*ExcludeDatabase[[:space:]]\{1,\}\([A-Za-z0-9._-]\{1,\}\)[[:space:]]*$/\1/p' "$conf" 2>/dev/null)
    grep -qiE '^[[:space:]]*Bytecode[[:space:]]+(no|false|off)[[:space:]]*$' "$conf" 2>/dev/null && unset 'out[bytecode]'
    for x in main daily bytecode safebrowsing valhalla; do
        [[ -n "${out[$x]:-}" ]] && printf '%s\n' "$x"
    done
    return 0
}

# _freshclam_cmd — the freshclam command of the definitions fix.
_freshclam_cmd() {
    local d c="freshclam"
    while IFS= read -r d; do c+=" --update-db=${d}"; done < <(_clamav_official_dbs)
    printf '%s' "$c"
}

# _clamav_custom_urls — the extra signature sources freshclam.conf lists
# (DatabaseCustomURL), one per line, in the file's order (one pair of
# surrounding quotes removed, as freshclam does).
_clamav_custom_urls() {
    local u
    while IFS= read -r u; do
        [[ "$u" == \"*\" && ${#u} -gt 2 ]] && u="${u:1:${#u}-2}"
        printf '%s\n' "$u"
    done < <(sed -n 's/^[[:space:]]*DatabaseCustomURL[[:space:]]\{1,\}\([^[:space:]]\{1,\}\)[[:space:]]*$/\1/p' "$(_r /etc/freshclam.conf)" 2>/dev/null)
    return 0
}

# _clamav_custom_file URL — the name freshclam saves URL's database under:
# all after the last "/", a query or fragment included.
_clamav_custom_file() {
    printf '%s' "${1##*/}"
}

# _clamav_url_label URL — URL as the report shows it: the host and the
# file name only. A user name and password before the host, and the path
# between host and file (which can hold an access key), are left out.
_clamav_url_label() {
    local u="${1%%[?#]*}" rest host
    rest="${u#*://}"
    host="${rest%%/*}"
    host="${host##*@}"
    if [[ "$rest" == */*/* ]]; then
        printf '%s/…/%s' "$host" "${u##*/}"
    elif [[ "$rest" == */* ]]; then
        printf '%s/%s' "$host" "${u##*/}"
    else
        printf '%s' "$host"
    fi
}

# _clamav_fc_log — the recent messages of clamav-freshclam.service.
_clamav_fc_log() {
    journalctl -u clamav-freshclam.service --since "-3 days" -n 3000 --no-pager -q -o cat 2>/dev/null || true
}

# _clamav_custom_failed URL... — "URL<TAB>reason<TAB>gone" for each URL
# whose last download in freshclam's log failed (a later success clears
# it). gone is 1 when the source is not coming back: the server says the
# file is gone (404, 410), or it failed in two updates or more and never
# worked in the log (a refusal, 403, or something that is not a database);
# else a failure may be passing (a busy server). A rate limit (429) is
# always passing. A log line is about URL only when it ends with it,
# since one source's address can be the start of another's; a time stamp
# at the start of a line (LogTime: "Sat Nov 21 00:52:05 2026 -> x.ndb
# updated"; after the level in "WARNING: <time> -> ...") is skipped. The updates are told apart by
# freshclam's "update process started" line.
_clamav_custom_failed() {
    _clamav_fc_log | python3 -I -c '
import re, sys
urls = sys.argv[1:]
files = {u: u.rsplit("/", 1)[-1] for u in urls}
state, runs, worked, run, last = {}, {}, set(), 0, None
stamp = re.compile(r"^[A-Z][a-z]{2} [A-Z][a-z]{2} +\d+ \d\d:\d\d:\d\d \d{4} -> ")
for line in sys.stdin:
    line = stamp.sub("", line.strip(), count=1)
    if "update process started" in line:
        run += 1
        continue
    # A refusal or a rate limit is told on the line after the failed download.
    m = re.search(r"received error code (\d+)", line)
    if m and last:
        state[last] = "HTTP " + m.group(1)
        last = None
        continue
    last = None
    for u in urls:
        if line.endswith(" " + u):
            m = re.search(r"Unexpected response \((\d+)\)", line)
            if m:
                state[u] = "HTTP " + m.group(1)
            elif "file not found: " in line:
                state[u] = "HTTP 404"
            elif "Update failed for custom database URL" in line or "Can\x27t download" in line:
                if not state.get(u, "ok").startswith("HTTP"):
                    state[u] = "download failed"
                if "Can\x27t download" in line:
                    last = u
            elif "Unexpected error when attempting to update from custom database URL" in line:
                state[u] = "not a database"
            else:
                continue
            runs.setdefault(u, set()).add(run)
        elif files[u] and "custom database" in line and re.match(re.escape(files[u]) + r" (database )?(is up-to-date|updated)", line):
            state[u] = "ok"
            runs[u] = set()
            worked.add(u)
for u in urls:
    r = state.get(u, "ok")
    if r != "ok":
        gone = r in ("HTTP 404", "HTTP 410") or (r != "HTTP 429" and u not in worked and len(runs.get(u, ())) >= 2)
        print(u + "\t" + r + "\t" + ("1" if gone else "0"))' "$@" 2>/dev/null || true
}

# _clamav_custom_check DIR URL... — the extra sources. One that is not
# coming back is a finding whose fix turns it off; one that failed only
# lately is a note. Either way freshclam stopped there (unless it was only
# rate-limited, 429, after which it goes on), so the sources listed after
# the first such failure are no longer updated: both name them. A source
# that is only missing is a note too.
_clamav_custom_check() {
    local dir="$1" u r g n=0 labels="" after="" manual="" missing="" passing="" first="" firstgone=""
    shift
    local -a urls=("$@") gone=()
    local -A why=()
    while IFS=$'\t' read -r u r g; do
        [[ -n "$u" ]] || continue
        why["$u"]="$r"
        # Its file is there: it worked before, unless the server said it is gone.
        [[ "$g" == 1 && "$r" != "HTTP 404" && "$r" != "HTTP 410" && -f "$(_r "$dir")/$(_clamav_custom_file "$u")" ]] && g=0
        if [[ "$g" == 1 ]]; then gone+=("$u"); else passing+="${passing:+, }$(_clamav_url_label "$u") (${r})"; fi
        why["$u:g"]="$g"
    done < <(_clamav_custom_failed "${urls[@]}")
    for u in "${urls[@]}"; do
        # freshclam goes on after a rate limit (429), and stops at any other failure.
        if [[ -n "${why[$u]:-}" && "${why[$u]}" != "HTTP 429" ]]; then
            [[ -z "$first" ]] && firstgone="${why[$u:g]}"
            first=1
        elif [[ -n "${why[$u]:-}" ]]; then
            :
        elif [[ -n "$first" ]]; then
            after+="${after:+, }$(_clamav_url_label "$u")"
        elif [[ ! -f "$(_r "$dir")/$(_clamav_custom_file "$u")" ]]; then
            missing+="${missing:+, }$(_clamav_url_label "$u")"
        fi
    done
    [[ -n "$missing" ]] && check_note "Extra signature sources in freshclam.conf not in ${dir} yet: ${missing} (see: journalctl -u clamav-freshclam.service)"
    if [[ -n "$passing" ]]; then
        check_note "The last update could not download ${passing}; it may work next time.$([[ ${#gone[@]} -eq 0 && -n $after ]] && echo " freshclam stopped there, so these were not updated: ${after}." || true)"
    fi
    (( ${#gone[@]} > 0 )) || return 0
    manual="sudoedit /etc/freshclam.conf"$'\n'"# In it, put a # in front of:"
    for u in "${gone[@]}"; do
        n=$(( n + 1 ))
        labels+="${labels:+$'\n'}$(_clamav_url_label "$u") (${why[$u]})"
        manual+=$'\n'"#   DatabaseCustomURL $(_clamav_url_label "$u")"
    done
    manual+=$'\n'"sudo systemctl try-restart clamav-freshclam.service"
    finding low "freshclam cannot download ${n} extra signature source(s)" \
"freshclam.conf lists extra virus signature sources (DatabaseCustomURL). These
can no longer be downloaded:
${labels}$([[ -n $after ]] && printf '\nfreshclam stops at a source that fails, so these, listed after it, are no longer updated:\n%s' "$after" || true)
Each update of the definitions ends in an error while they stay listed." \
        "$manual" fix_clamav_custom_off "${gone[@]}"
    finding_change "${n} extra source(s) fail to download" "turned off in /etc/freshclam.conf$([[ -n $after && $firstgone == 1 && -z $passing ]] && echo "; the others are updated again" || true)"
    return 0
}

# fix_clamav_custom_off URL... — put a # in front of these extra sources
# in /etc/freshclam.conf (the file keeps its owner, mode and label), then
# let the running update service read it again. It fails, changing
# nothing, when none of the lines is there any more.
fix_clamav_custom_off() {
    local f=/etc/freshclam.conf u qurls="" script
    for u in "$@"; do qurls+=" $(_q "$u")"; done
    script="$(_backup_cmd "$f")
urls=\$(printf '%s\n'${qurls})
tmp=\$(mktemp $f.XXXXXX)
URLS=\"\$urls\" awk 'BEGIN { n = split(ENVIRON[\"URLS\"], u, \"\\n\"); for (i = 1; i <= n; i++) off[u[i]] = 1; done = 0 }
{ s = \$0; sub(/^[ \\t]+/, \"\", s)
  if (s ~ /^DatabaseCustomURL[ \\t]/) { v = s; sub(/^DatabaseCustomURL[ \\t]+/, \"\", v); sub(/[ \\t\\r]+\$/, \"\", v)
    if (v ~ /^\".*\"\$/ && length(v) > 2) v = substr(v, 2, length(v) - 2)
    if (v in off) { print \"# Turned off by Security Check (it could not be downloaded): \" \$0; done++; next } }
  print }
END { if (!done) exit 3 }' $f > \"\$tmp\" || { rc=\$?; rm -f -- \"\$tmp\"; exit \"\$rc\"; }
cat -- \"\$tmp\" > $f
rm -f -- \"\$tmp\"
systemctl try-restart clamav-freshclam.service || echo \"clamav-freshclam.service did not restart; it reads the file when it next starts.\""
    apply_change "$script" "$(_restore_cmd "$f")
systemctl try-restart clamav-freshclam.service || echo \"clamav-freshclam.service did not restart; it reads the file when it next starts.\"" \
        "Only these lines change; the other extra sources stay as they are. The commands show the full addresses, as they are in the file."
}

# _clamav_not_set_up CLAMUI HOST MISSING... — part of ClamAV is not
# installed: the scanner (clamscan, package clamav) or freshclam, which
# keeps its virus definitions up to date. With ClamUI that matters most:
# ClamUI is only a window over the system's ClamAV. On Bazzite the fix
# layers the packages; the definitions follow after the restart.
_clamav_not_set_up() {
    local clamui="$1" host="$2" sev title detail
    shift 2
    local -a missing=("$@")
    if [[ "$host" -eq 1 ]]; then
        sev=low
        title="ClamAV's virus definitions cannot be updated: freshclam is not installed"
        detail="clamscan is installed, but freshclam (package clamav-freshclam) is not, so the
virus definitions are never updated$([[ $clamui -eq 1 ]] && echo ", by ClamUI either" || true). The scan misses what is newer than them."
    elif [[ "$clamui" -eq 1 ]]; then
        sev=medium
        title="ClamUI is installed, but ClamAV is not set up on the system"
        detail="ClamUI is only the window: it scans with the system's ClamAV (clamscan) and
updates the virus definitions with the system's freshclam. Not installed:
${missing[*]}. So ClamUI cannot scan anything."
    else
        sev=info
        title="The malware scan needs ClamAV, which is not installed"
        detail="The deep check scans Downloads, the Desktop and the temporary folders with
ClamAV, which is not installed, so that part was left out. ClamTk from
Flathub brings its own ClamAV; ClamUI uses the system's (this fix)."
    fi
    if [[ "$IS_OSTREE" -eq 1 ]]; then
        finding "$sev" "$title" "$detail" "sudo rpm-ostree install ${missing[*]}
systemctl reboot
# Then run the check again: it offers to download the virus definitions." \
            fix_clamav_install "${missing[@]}"
        finding_change "not installed: ${missing[*]}" "layered on the system image: ${missing[*]} (after a restart)" "$W_DOWNLOAD" "$W_REBOOT"
    else
        finding "$sev" "$title" "$detail" "sudo dnf install ${missing[*]}
sudo freshclam"
    fi
    return 0
}

# fix_clamav_install PACKAGE... — layer ClamAV's packages on the system image.
fix_clamav_install() {
    local q="" p
    for p in "$@"; do q+=" $(_q "$p")"; done
    apply_change "rpm-ostree install${q}" "rpm-ostree uninstall${q}" \
"Layered packages stay through system updates and are updated with them. After the restart, run the check again: it offers to download the virus definitions and to keep them up to date." \
        "layer ClamAV on the system image"
}

# _freshclam_plan STATE — what fix_clamav_defs does with
# clamav-freshclam.service in this state (systemctl is-enabled): "on"
# (it starts with the system), "runtime" (on only until the restart; the
# fix turns it on for good), "masked", "masked-runtime", "none" (not
# installed) or "off".
_freshclam_plan() {
    case "$1" in
        enabled|static|indirect|alias|generated|transient) echo on ;;
        enabled-runtime) echo runtime ;;
        masked|masked-runtime) echo "$1" ;;
        missing|not-found|bad|"") echo none ;;
        *) echo off ;;
    esac
}

# _freshclam_after STATE — the commands that start (or turn on)
# clamav-freshclam.service after freshclam ran; nothing when it is not
# installed.
_freshclam_after() {
    local unit="clamav-freshclam.service"
    case "$(_freshclam_plan "$1")" in
        on)             printf 'systemctl start %s' "$unit" ;;
        masked)         printf 'systemctl unmask %s && systemctl enable --now %s' "$unit" "$unit" ;;
        masked-runtime) printf 'systemctl unmask --runtime %s && systemctl enable --now %s' "$unit" "$unit" ;;
        none)           ;;
        *)              printf 'systemctl enable --now %s' "$unit" ;;
    esac
}

# fix_clamav_defs SERVICE_STATE — download the virus definitions now and
# keep them up to date with clamav-freshclam.service. freshclam and the
# service take the same lock, so the service is stopped while freshclam
# runs. It is started (or turned on) afterwards even when the download
# failed: the fix then fails with freshclam's status, but the automatic
# updates are not left off. A failure to start it fails the fix too.
fix_clamav_defs() {
    local unit="clamav-freshclam.service" script="rc=0"$'\n' undo="" after
    after=$(_freshclam_after "$1")
    case "$(_freshclam_plan "$1")" in
        on)             undo="systemctl start ${unit}" ;;
        masked)         undo="systemctl disable --now ${unit}"$'\n'"systemctl mask ${unit}" ;;
        masked-runtime) undo="systemctl disable --now ${unit}"$'\n'"systemctl mask --runtime ${unit}" ;;
        runtime)        undo="systemctl disable ${unit}"$'\n'"systemctl enable --runtime ${unit}" ;;
        off)            undo="systemctl disable --now ${unit}" ;;
    esac
    [[ -n "$after" ]] && script+="systemctl stop ${unit} 2>/dev/null || true"$'\n'
    script+="$(_freshclam_cmd) || rc=\$?"
    [[ -n "$after" ]] && script+=$'\n'"{ ${after}; } || { s=\$?; [ \"\$rc\" -ne 0 ] || rc=\$s; }"
    script+=$'\n'"exit \"\$rc\""
    apply_change "$script" "$undo" \
        "$(case "$(_freshclam_plan "$1")" in
               on)   echo "Undo only starts the service again; the downloaded definitions stay." ;;
               none) ;;
               *)    echo "Undo puts the automatic updates back as they were; the downloaded definitions stay." ;;
           esac)"
}

# _clamav_defs_finding SEV TITLE DETAIL DIR NOW — a finding whose fix
# downloads the definitions (and turns on their automatic update); NOW is
# what the definitions in DIR are like at present. The manual steps are
# the fix's commands.
_clamav_defs_finding() {
    local sev="$1" title="$2" detail="$3" dir="$4" now="$5" svc after manual="" a
    svc=$(_unit_state clamav-freshclam.service)
    a=$(_freshclam_after "$svc")
    after="definitions downloaded now"
    case "$(_freshclam_plan "$svc")" in
        on|none) ;;
        *) after+=", then updated automatically (clamav-freshclam.service)" ;;
    esac
    [[ -n "$a" ]] && manual+="# The service holds the lock freshclam needs: stop it first."$'\n'"sudo systemctl stop clamav-freshclam.service"$'\n'
    manual+="sudo $(_freshclam_cmd)"
    [[ -n "$a" ]] && manual+=$'\n'"sudo ${a//&& /&& sudo }"
    finding "$sev" "$title" "$detail" "$manual" fix_clamav_defs "$svc"
    finding_change "${dir}: ${now}" "$after" "$W_DOWNLOAD"
}

check_deep_malware() {
    local -a scanner=() targets=() missing=()
    local clamui=0 host=0 db="" age="" svc
    _flatpak_installed "$_CLAMUI_APP" && clamui=1
    _have clamscan || missing+=(clamav)
    _have freshclam || missing+=(clamav-freshclam)
    if _have clamscan; then
        scanner=(clamscan); host=1
    elif _flatpak_installed com.gitlab.davem.ClamTk; then
        scanner=(flatpak run --command=clamscan com.gitlab.davem.ClamTk)
    fi
    # What is missing matters with ClamUI (which needs the system's
    # ClamAV), for the system's clamscan without freshclam, and when there
    # is no scanner at all. ClamTk alone brings both.
    # A package already layered in the image that waits for the restart is
    # not offered again; the note says so.
    local pending="" p
    local -a still=()
    if [[ ${#missing[@]} -gt 0 ]] && [[ $clamui -eq 1 || $host -eq 1 || ${#scanner[@]} -eq 0 ]]; then
        pending=$(_clamav_pending "${missing[@]}")
        for p in "${missing[@]}"; do
            [[ " ${pending} " == *" ${p} "* ]] || still+=("$p")
        done
        [[ -n "$pending" ]] && check_note "Layered, waiting for the restart: ${pending}"
        [[ ${#still[@]} -gt 0 ]] && _clamav_not_set_up "$clamui" "$host" "${still[@]}"
    fi
    if [[ ${#scanner[@]} -eq 0 && " ${pending} " == *" clamav "* ]]; then
        mark_skip "ClamAV is in the system update that waits for a restart; restart the PC, then run the check again"
        return 0
    fi
    if [[ ${#scanner[@]} -eq 0 ]]; then
        mark_skip "ClamAV is not installed$([[ $clamui -eq 0 ]] && echo " (ClamTk from Flathub brings its own; ClamUI needs the system's ClamAV)" || true)"
        return 0
    fi
    if [[ "$host" -eq 1 ]]; then
        db=$(_clamav_db_dir)
        svc=$(_unit_state clamav-freshclam.service)
        if ! age=$(_clamav_defs_age "$db"); then
            local what="no virus definitions"
            [[ "$age" == partial ]] && what="an incomplete set of virus definitions (main and daily are both needed)"
            if ! _have freshclam; then
                mark_skip "ClamAV has ${what} in ${db}, and freshclam, which downloads them, is not installed"
                return 0
            fi
            _clamav_defs_finding medium "$([[ $age == partial ]] && echo "ClamAV's virus definitions are incomplete" || echo "ClamAV has no virus definitions")" \
"ClamAV is installed, but ${db} holds ${what}, so it cannot
scan$([[ $clamui -eq 1 ]] && echo " - in ClamUI either" || true). The malware scan was left out." "$db" "$what"
            mark_skip "ClamAV has ${what} in ${db}"
            return 0
        fi
        check_note "Virus definitions: updated $([[ $age -eq 0 ]] && echo "today" || echo "${age} day(s) ago") (clamav-freshclam.service: ${svc})$([[ $clamui -eq 1 ]] && echo "; ClamUI uses this ClamAV" || true)"
        if _have freshclam; then
            local -a curls=()
            mapfile -t curls < <(_clamav_custom_urls)
            [[ ${#curls[@]} -gt 0 ]] && _clamav_custom_check "$db" "${curls[@]}"
        fi
        if (( age > _CLAMAV_DEFS_OLD )) && _have freshclam; then
            _clamav_defs_finding low "ClamAV's virus definitions are ${age} days old" \
"New malware is added to the definitions every day; with definitions ${age} days old
the scan misses what came since. They are not being updated$([[ $(_freshclam_plan "$svc") == on ]] && echo " although clamav-freshclam.service is on (see: journalctl -u clamav-freshclam.service)" || echo " automatically (clamav-freshclam.service is ${svc})")." \
                "$db" "last updated ${age} days ago"
        fi
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
    # the first account). It stays on the file system of each folder:
    # a drive, a network share or an app image mounted below one is left
    # out (an app's own mount in /tmp can be large).
    local out="" rc=0 part prc owner
    local -a opts=(-r -i --no-summary --cross-fs=no --max-filesize=200M --max-scansize=400M) dbopt=()
    # clamscan does not read freshclam.conf: it is told where freshclam
    # puts the definitions (the ones checked above).
    [[ "$host" -eq 1 && -n "$db" ]] && dbopt=("--database=${db}")
    if [[ "${scanner[0]}" == "flatpak" ]]; then
        out=$(_as_desktop_user timeout "$_CLAMAV_SCAN_LIMIT" "${scanner[@]}" "${opts[@]}" "${targets[@]}" 2>&1 < /dev/null) || rc=$?
    else
        for owner in "${!by_user[@]}"; do
            local -a mine=()
            mapfile -t mine <<< "${by_user[$owner]}"
            prc=0
            part=$(_as_user "$owner" timeout "$_CLAMAV_SCAN_LIMIT" "${scanner[@]}" "${opts[@]}" "${dbopt[@]}" "${mine[@]}" 2>&1 < /dev/null) || prc=$?
            out+="${part}"$'\n'
            # A stopped scan (124) is told apart from the rest.
            if (( prc == 124 )) || (( rc != 124 && prc > rc )); then rc=$prc; fi
        done
    fi
    local found first
    found=$(grep -E ' FOUND$' <<< "$out" || true)
    # ClamAV's own error lines start with "LibClamAV Error:" or "ERROR:";
    # a file it could not read is "PATH: ... ERROR" (exit 2).
    first=$(grep -m 1 -iE '^(LibClamAV Error|ERROR):' <<< "$out" | cut -c1-200 || true)
    if [[ -n "$found" ]]; then
        finding high "ClamAV found $(grep -c . <<< "$found") infected file(s)" \
"${found}" \
"Delete the files (or check them on virustotal.com if you think it is a false
alarm), then change passwords used on this PC if one of them was run."
        (( rc == 124 )) && check_note "The scan was stopped after $(( _CLAMAV_SCAN_LIMIT / 60 )) minutes, before it finished: other files may not have been scanned."
    elif (( rc == 124 )); then
        mark_skip "the scan was stopped after $(( _CLAMAV_SCAN_LIMIT / 60 )) minutes, before it finished (it scans $(_join ', ' "${targets[@]}"); many files there make it slow)"
    elif [[ $rc -ne 0 && $rc -ne 1 ]] && grep -qiE '^(LibClamAV Error|ERROR):.*(databas|cl_load|cli_load|cvd|cld|malformed|engine)' <<< "$out"; then
        if [[ "$host" -eq 1 ]] && _have freshclam; then
            _clamav_defs_finding medium "ClamAV cannot load its virus definitions" \
"The scan stopped because ClamAV could not load the definitions in ${db}
(${first:-exit ${rc}}). They may be damaged or half written; a fresh download
replaces them." "$db" "definitions that do not load"
        fi
        mark_skip "ClamAV could not load its virus definitions (${first:-exit ${rc}})$([[ $host -eq 0 ]] && echo "; open ClamTk once to download them" || true)$([[ $host -eq 1 ]] && ! _have freshclam && echo "; freshclam, which downloads them, is not installed" || true)"
    elif [[ $rc -ne 0 && $rc -ne 1 && $rc -ne 2 ]]; then
        mark_skip "the scan did not finish (exit ${rc}${first:+: ${first}})"
    else
        # Exit 2 without a database error: files the scanning account may
        # not read (other accounts' private files in /tmp) were left out.
        check_note "ClamAV scanned: $(_join ', ' "${targets[@]}") - nothing found$([[ $rc -eq 2 ]] && echo " (files the scanning account may not read were left out)" || true)"
    fi
    return 0
}
