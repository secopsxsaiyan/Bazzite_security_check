# shellcheck shell=bash
# Boot chain and kernel: Secure Boot, disk encryption, kernel arguments,
# SELinux and a small set of kernel hardening settings that are safe for
# games and development tools.

# ====================== SECURE BOOT ======================
_secure_boot_state() {
    local out v
    if _have mokutil; then
        out=$(mokutil --sb-state 2>&1 || true)
        case "$out" in
            *"SecureBoot enabled"*)  echo "enabled"; return 0 ;;
            *"SecureBoot disabled"*) echo "disabled"; return 0 ;;
        esac
    fi
    v=$(od -An -t u1 -j4 -N1 "$(_r /sys/firmware/efi/efivars)"/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ' || true)
    case "$v" in 1) echo "enabled" ;; 0) echo "disabled" ;; *) echo "unknown" ;; esac
}

check_secure_boot() {
    if [[ ! -d "$(_r /sys/firmware/efi)" ]]; then
        mark_na "the PC boots in legacy BIOS mode (no UEFI)"
        return 0
    fi
    local st sev
    st=$(_secure_boot_state)
    case "$st" in
        enabled)
            check_note "Secure Boot is on" ;;
        disabled)
            sev=$(_ctx medium low)
            [[ -n "$VIRT" ]] && sev="info"
            finding "$sev" "Secure Boot is off" \
"Secure Boot makes the firmware refuse to start a boot loader or kernel that
was tampered with (boot-kits survive reinstalls of apps and are invisible to the
running system). Bazzite supports it with its own signing key. Some anti-cheat
systems (Easy Anti-Cheat Linux v2) also check for it." \
"1. ujust enroll-secure-boot-key  (enrolls Bazzite's key)
2. Reboot; in the blue MOK manager choose 'Enroll MOK' and type the
   one-time password shown by the command (on Bazzite: universalblue)
3. Turn on Secure Boot in your UEFI/BIOS setup
Anti-cheat readiness: ujust check-anticheat"
            finding_change "Secure Boot off" "Secure Boot on with Bazzite's key (manual, in the firmware setup)" ;;
        *)
            mark_skip "could not read the Secure Boot state" ;;
    esac
    return 0
}

# ====================== DISK ENCRYPTION ======================
check_disk_encryption() {
    case "$DISK_ENCRYPTED" in
        yes)
            check_note "Home folders are on an encrypted (LUKS) volume" ;;
        no)
            if [[ -n "$VIRT" ]]; then
                finding info "The disk is not encrypted (virtual machine)" \
"This VM's disk is not encrypted inside the guest; the host's disk encryption
protects it, if enabled." ""
                finding_change "guest disk not encrypted" "protected by the host's encryption"
                return 0
            fi
            finding "$(_ctx medium low)" "The disk is not encrypted" \
"Your home folder is stored unencrypted. Anyone who takes the $([[ $USE_PORTABLE -eq 1 ]] && echo "laptop or handheld" || echo "PC or its drive (theft, repair shop, selling it later)") can
read browser sessions, saved passwords, SSH keys, API tokens and documents
without knowing your password. Game libraries do not matter here - the home
folder does." \
"Encryption can only be turned on when installing:
1. Back up your home folder (Pika Backup, Déjà Dup or rsync)
2. Reinstall Bazzite and tick \"Encrypt my data\" in the installer
3. Optional: unlock with the TPM - ujust setup-luks-tpm-unlock"
            finding_change "home folders stored unencrypted" "encrypted with LUKS (needs a reinstall - manual)" ;;
        *)
            mark_skip "could not tell which device holds /var/home" ;;
    esac
    return 0
}

# ====================== KERNEL ARGUMENTS ======================
readonly _WEAK_KARGS=(mitigations=off nospectre_v1 nospectre_v2 nospectre_bhb nopti pti=off
    kpti=0 spectre_v2=off spectre_v2_user=off spectre_bhi=off spec_store_bypass_disable=off
    nospec_store_bypass_disable l1tf=off mds=off tsx_async_abort=off mmio_stale_data=off
    retbleed=off srbds=off gather_data_sampling=off reg_file_data_sampling=off
    spec_rstack_overflow=off)

_configured_kargs() {
    local k=""
    [[ "$IS_OSTREE" -eq 1 ]] && _have rpm-ostree && k=$(timeout 30 rpm-ostree kargs 2>/dev/null || true)
    [[ -n "$k" ]] || k=$(cat "$(_r /proc/cmdline)" 2>/dev/null || true)
    printf '%s' "$k"
}

check_kernel_args() {
    local configured running a w img=""
    local -a found=() vuln=() args=()
    configured=$(_configured_kargs)
    running=$(cat "$(_r /proc/cmdline)" 2>/dev/null || true)
    read -ra args <<< "$configured $running"
    for a in "${args[@]}"; do
        for w in "${_WEAK_KARGS[@]}"; do
            if [[ "$a" == "$w" ]] && [[ " ${found[*]} " != *" $a "* ]]; then
                found+=("$a")
            fi
        done
    done
    [[ ${#found[@]} -gt 0 ]] || check_note "No kernel argument turns CPU vulnerability protections off"
    if [[ ${#found[@]} -gt 0 ]]; then
        if grep -qsE "$(_join '|' "${found[@]}")" "$(_r /usr/lib/bootc/kargs.d)"/*.toml 2>/dev/null; then
            img="These arguments come (at least partly) from the system image itself (/usr/lib/bootc/kargs.d), so an update may bring them back."
        fi
        finding medium "CPU vulnerability protections are turned off" \
"The kernel is started with: ${found[*]}
This switches off protections against Spectre/Meltdown-style CPU flaws, which
let one program (or JavaScript in a web page) read memory it should not see,
such as passwords and session cookies. On current CPUs the gaming benefit is
usually a few percent at most. ${img}" \
"rpm-ostree kargs$(printf ' --delete-if-present=%s' "${found[@]}")
systemctl reboot" \
            fix_kargs_delete "${found[@]}"
        finding_change "kernel started with: ${found[*]}" "those arguments removed (CPU protections on)" \
            "$W_REBOOT" \
            "slightly slower|Some games may run a few percent slower. You can undo this if one does." \
            "$([[ -n $img ]] && echo "may come back|These arguments come from the system image, so an update may add them again.")"
        finding_affects \
            "performance|Some games may run a few percent slower with the protections on. You can undo this if one does."
    fi

    local f v
    for f in "$(_r /sys/devices/system/cpu/vulnerabilities)"/*; do
        [[ -f "$f" ]] || continue
        v=$(cat "$f" 2>/dev/null || true)
        [[ "$v" == Vulnerable* ]] && vuln+=("${f##*/}: ${v}")
    done
    if [[ ${#vuln[@]} -gt 0 && ${#found[@]} -eq 0 ]]; then
        finding info "The CPU reports unmitigated vulnerabilities" \
"$(printf '%s\n' "${vuln[@]}")
Often this means the CPU microcode is outdated (fixed by a BIOS/UEFI update) or
that a protection is not available for this CPU." \
"Update your BIOS/UEFI from the board or laptop maker (or: fwupdmgr update)."
        finding_change "$(_join ', ' "${vuln[@]%%:*}") reported as vulnerable" "mitigated after a firmware/microcode update (manual)"
    fi
    return 0
}

# fix_kargs_delete ARG... — remove kernel arguments (applies after a reboot).
fix_kargs_delete() {
    local del="" add="" a
    for a in "$@"; do
        del+=" --delete-if-present=$(_q "$a")"
        add+=" --append-if-missing=$(_q "$a")"
    done
    apply_change "rpm-ostree kargs${del}" "rpm-ostree kargs${add}" "" \
        "turn CPU vulnerability protections back on"
}

# ====================== ANTI-CHEAT READINESS ======================
# Easy Anti-Cheat for Linux v2 (what "ujust check-anticheat" tests) also
# needs kernel lockdown in integrity mode and kexec turned off. Both are
# kernel arguments; the other requirements (Secure Boot, TPM, signed kernel
# and modules) are the image's and the Secure Boot check's business.
readonly _EAC_LOCKDOWN_KARG="lockdown=integrity"
readonly _EAC_KEXEC_KARG="sysctl.kernel.kexec_load_disabled=1"

# _lockdown_mode — the active kernel lockdown mode (none, integrity,
# confidentiality), empty when the kernel does not say.
_lockdown_mode() {
    sed -n 's/.*\[\([a-z]*\)\].*/\1/p' "$(_r /sys/kernel/security/lockdown)" 2>/dev/null | head -n1 || true
}

check_anticheat_ready() {
    if [[ "$USE_GAMING" -ne 1 ]]; then
        mark_na "only checked when the PC is used for gaming"
        return 0
    fi
    local mode kexec configured
    local -a need=() what=() pending=()
    mode=$(_lockdown_mode)
    kexec=$(cat "$(_r /proc/sys/kernel/kexec_load_disabled)" 2>/dev/null || true)
    configured=" $(_configured_kargs) "
    local sb no_sb=0
    sb=$(_secure_boot_state)
    if [[ -n "$mode" && "$mode" == none ]]; then
        if [[ "$configured" == *" lockdown=integrity "* || "$configured" == *" lockdown=confidentiality "* ]]; then
            pending+=("kernel lockdown")
        elif [[ "$sb" != enabled ]]; then
            # Without Secure Boot the kernel does not trust Machine Owner
            # Keys, so lockdown could stop MOK-signed drivers (NVIDIA and
            # other add-on modules) from loading - and EAC needs Secure Boot
            # anyway. Secure Boot comes first.
            no_sb=1; what+=("kernel lockdown is off, and Secure Boot is ${sb} (turn Secure Boot on first; see the Secure Boot check)")
        else
            need+=("$_EAC_LOCKDOWN_KARG"); what+=("kernel lockdown is off (mode 'none'; integrity needed)")
        fi
    elif [[ -n "$mode" ]]; then
        check_note "Kernel lockdown: ${mode}"
    fi
    if [[ "$kexec" == 0 ]]; then
        if [[ "$configured" == *" ${_EAC_KEXEC_KARG} "* ]]; then
            pending+=("kexec off")
        else
            need+=("$_EAC_KEXEC_KARG"); what+=("kexec is allowed (kernel.kexec_load_disabled = 0)")
        fi
    elif [[ "$kexec" == 1 ]]; then
        check_note "kexec is disabled"
    fi
    [[ ${#pending[@]} -gt 0 ]] && check_note "Set, takes effect after a reboot: $(_join ', ' "${pending[@]}")"
    [[ ${#need[@]} -gt 0 || $no_sb -eq 1 ]] || return 0
    local why="" manual="" n=$(( ${#need[@]} + no_sb ))
    [[ " ${need[*]} " == *" ${_EAC_LOCKDOWN_KARG} "* ]] && why+="Lockdown also hardens the PC: even root can no longer change the running kernel (raw memory access, unsigned modules). "
    [[ " ${need[*]} " == *" ${_EAC_KEXEC_KARG} "* ]] && why+="With kexec off, nothing can swap in another kernel without a real reboot."
    [[ $no_sb -eq 1 ]] && manual+="Turn Secure Boot on in the firmware (UEFI) settings and enroll Bazzite's key (ujust enroll-secure-boot-key); then run this check again."$'\n'
    [[ ${#need[@]} -gt 0 ]] && manual+="rpm-ostree kargs$(printf ' --append-if-missing=%s' "${need[@]}")"$'\n'"systemctl reboot"$'\n'
    manual+="Check afterwards with: ujust check-anticheat"
    local -a fixargs=()
    [[ ${#need[@]} -gt 0 ]] && fixargs=(fix_anticheat_kargs "${need[@]}")
    finding low "Games using Easy Anti-Cheat for Linux may refuse to start: ${n} kernel setting(s) missing" \
"Easy Anti-Cheat's Linux v2 readiness check (ujust check-anticheat) fails on:
$(printf -- '- %s\n' "${what[@]}")
${why}" \
"$manual" "${fixargs[@]}"
    if [[ ${#need[@]} -eq 0 ]]; then
        finding_change "$(_join '; ' "${what[@]}")" "Secure Boot on, then lockdown=integrity (manual)"
        finding_affects "anticheat+|This is what the steps are for: games whose Easy Anti-Cheat checks these settings can start."
        return 0
    fi
    finding_change "$(_join '; ' "${what[@]}")" "kernel started with: ${need[*]}$([[ $no_sb -eq 1 ]] && echo "; lockdown after Secure Boot is on (manual)")" \
        "$W_REBOOT" \
        "$([[ " ${need[*]} " == *" ${_EAC_LOCKDOWN_KARG} "* ]] && echo "lockdown limits|With lockdown, kernel modules not signed with an enrolled key no longer load, hibernation (suspend to disk) is turned off, and tools that write CPU registers or raw memory (undervolting and some overclocking or RGB tools) stop working. Sleep (suspend to RAM) keeps working.")" \
        "$([[ " ${need[*]} " == *" ${_EAC_KEXEC_KARG} "* ]] && echo "no kexec|kdump crash dumps and fast reboots with 'systemctl kexec' stop working.")"
    finding_affects "anticheat+|This is what the fix is for: games whose Easy Anti-Cheat checks these kernel settings can start."
    # Only the lockdown argument stops hibernation and unsigned modules.
    [[ " ${need[*]} " == *" ${_EAC_LOCKDOWN_KARG} "* ]] \
        && finding_affects "lockdown!|Kernel lockdown turns hibernation off and stops kernel modules that are not signed with an enrolled key from loading."
    return 0
}

# fix_anticheat_kargs ARG... — add the kernel arguments Easy Anti-Cheat
# needs (applies after a reboot).
fix_anticheat_kargs() {
    local add="" del="" a
    for a in "$@"; do
        [[ "$a" == "$_EAC_LOCKDOWN_KARG" || "$a" == "$_EAC_KEXEC_KARG" ]] || continue
        add+=" --append-if-missing=$(_q "$a")"
        del+=" --delete-if-present=$(_q "$a")"
    done
    [[ -n "$add" ]] || return 1
    local -a what=()
    [[ "$add" == *lockdown* ]] && what+=("turn on kernel lockdown")
    [[ "$add" == *kexec* ]] && what+=("turn kexec off")
    apply_change "rpm-ostree kargs${add}" "rpm-ostree kargs${del}" \
        "After the reboot, check with: ujust check-anticheat" \
        "$(_join ' and ' "${what[@]}") (Easy Anti-Cheat)"
}

# ====================== SELINUX ======================
# _avc_denials — SELinux denials logged since boot, each counted from one
# place: the journal's audit records (when journald collects them, it gets
# every one), else the larger of the kernel messages (without auditd, or
# from before it started) and auditd's own log.
_avc_denials() {
    local n k=0 a=0
    n=$(timeout 20 journalctl -b --no-pager -q _TRANSPORT=audit 2>/dev/null | grep -c 'avc:  denied' || true)
    if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
        k=$(timeout 20 journalctl -k -b --no-pager -q 2>/dev/null | grep -c 'avc:  denied' || true)
        if _have ausearch; then
            a=$(timeout 20 ausearch -m AVC,USER_AVC -ts boot 2>/dev/null | grep -c 'avc:  denied' || true)
        fi
        [[ "$k" =~ ^[0-9]+$ ]] || k=0
        [[ "$a" =~ ^[0-9]+$ ]] || a=0
        n=$(( k > a ? k : a ))
    fi
    printf '%s' "$n"
}

check_selinux() {
    if ! _have getenforce; then
        mark_skip "SELinux tools are not installed"
        return 0
    fi
    local mode cfg cmd denials
    mode=$(getenforce 2>/dev/null || true)
    cfg=$(awk -F= '$1 == "SELINUX" {print $2}' "$(_r /etc/selinux/config)" 2>/dev/null | tail -n1 || true)
    cmd=$(cat "$(_r /proc/cmdline)" 2>/dev/null || true)
    case "$mode" in
        Enforcing)
            check_note "SELinux is enforcing"
            if [[ -n "$cfg" && "$cfg" != "enforcing" ]]; then
                finding low "SELinux will not be enforcing after the next reboot" \
"SELinux is enforcing now, but /etc/selinux/config says SELINUX=${cfg}." \
"Set SELINUX=enforcing in /etc/selinux/config" \
                    fix_selinux_config
                finding_change "running: Enforcing; /etc/selinux/config: SELINUX=${cfg}" "SELINUX=enforcing in /etc/selinux/config"
            fi ;;
        Permissive)
            denials=$(_avc_denials)
            finding high "SELinux is not protecting the system (permissive)" \
"SELinux only logs what it would block. It is one of the main walls between a
compromised app (a browser, a game, a mod) and the rest of the system.
${denials:-0} access(es) were logged as 'would be denied' since boot.
$([[ "$cmd" == *enforcing=0* ]] && echo "The kernel is started with enforcing=0.")" \
"sudo setenforce 1
Set SELINUX=enforcing in /etc/selinux/config
$([[ "$cmd" == *enforcing=0* ]] && echo "rpm-ostree kargs --delete-if-present=enforcing=0")
If something breaks: journalctl -t setroubleshoot, or ask in the Bazzite help channels." \
                fix_selinux_enforce "$([[ "$cmd" == *enforcing=0* ]] && echo karg)" "$denials"
            finding_change "Permissive (only logs; config: SELINUX=${cfg:-?})" "Enforcing now, and SELINUX=enforcing for later boots" \
                "$([[ ${denials:-0} -gt 0 ]] && echo "${denials} would-be denials|${denials} action(s) were logged as 'would be denied' since boot. The programs behind them may stop working once SELinux enforces; undo the change if one does.")" \
                "$([[ "$cmd" == *enforcing=0* ]] && echo "kernel argument|enforcing=0 is also removed from the kernel command line; that part applies from the next boot.")" ;;
        Disabled)
            finding high "SELinux is disabled" \
"SELinux is turned off completely. Turning it back on needs a full relabel of
the file system at the next boot (takes a few minutes)." \
"Set SELINUX=enforcing in /etc/selinux/config
$([[ "$cmd" == *selinux=0* ]] && echo "rpm-ostree kargs --delete-if-present=selinux=0")
Then relabel: sudo fixfiles -F onboot && systemctl reboot"
            finding_change "Disabled" "Enforcing (needs a relabel and a reboot - manual)" ;;
        *)
            mark_skip "unknown SELinux mode '${mode}'" ;;
    esac
    return 0
}

fix_selinux_config() {
    local f=/etc/selinux/config
    apply_change "$(_backup_cmd "$f")
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' $f" "$(_restore_cmd "$f")"
}

# fix_selinux_enforce [karg] DENIALS — switch to enforcing now and for good.
fix_selinux_enforce() {
    local karg="$1" denials="${2:-0}" f=/etc/selinux/config script undo note=""
    script="setenforce 1
$(_backup_cmd "$f")
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' $f"
    undo="setenforce 0
$(_restore_cmd "$f")"
    if [[ "$karg" == "karg" ]]; then
        script+=$'\n'"rpm-ostree kargs --delete-if-present=enforcing=0"
        undo+=$'\n'"rpm-ostree kargs --append-if-missing=enforcing=0"
    fi
    if [[ "${denials:-0}" -gt 0 ]]; then
        note="If something stops working after this, undo it and look at: journalctl -b | grep 'avc:  denied'"
    fi
    apply_change "$script" "$undo" "$note"
}

# ====================== SYSCTL ======================
# Only protections that are on by default in Bazzite/Fedora: a finding means
# something weakened them. Gaming/debugging trade-offs are left alone (see the
# report's "not checked on purpose").
readonly _SYSCTL_DROPIN="/etc/sysctl.d/99-zz-bazzite-sec-audit.conf"
declare -gA _SYSCTL_WANT=(
    [kernel.randomize_va_space]="=2"
    [fs.protected_hardlinks]="=1"
    [fs.protected_symlinks]="=1"
    [fs.protected_regular]=">=1"
    [fs.protected_fifos]=">=1"
    [kernel.unprivileged_bpf_disabled]=">=1"
    [net.ipv4.tcp_syncookies]=">=1"
    [net.ipv4.conf.all.accept_source_route]="=0"
)
declare -gA _SYSCTL_FIXVAL=(
    [kernel.randomize_va_space]=2 [fs.protected_hardlinks]=1 [fs.protected_symlinks]=1
    [fs.protected_regular]=1 [fs.protected_fifos]=1 [kernel.unprivileged_bpf_disabled]=2
    [net.ipv4.tcp_syncookies]=1 [net.ipv4.conf.all.accept_source_route]=0
)

_sysctl_value() {
    local p="/proc/sys/${1//.//}"
    cat "$(_r "$p")" 2>/dev/null || sysctl -n "$1" 2>/dev/null || true
}

# _sysctl_source KEY — the configuration file that sets KEY last, if any.
# Files are read in the order systemd-sysctl uses: sorted by file name
# across the folders, a name in /etc hiding the same name in /run and /usr
# (a link to /dev/null masks it). On Fedora /etc/sysctl.conf is read through
# the 99-sysctl.conf link, so it counts at that place; one no link reads is
# read last by sysctl --system, so it comes last here.
_sysctl_source() {
    local key="$1" d f name last="" conf_read=0
    local -A by_name=()
    for d in /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d; do
        for f in "$(_r "$d")"/*.conf; do
            [[ -e "$f" || -L "$f" ]] || continue
            name="${f##*/}"
            [[ -n "${by_name[$name]:-}" ]] || by_name["$name"]="$f"
        done
    done
    for name in "${!by_name[@]}"; do
        [[ "${by_name[$name]}" -ef "$(_r /etc/sysctl.conf)" ]] && conf_read=1
    done
    while IFS= read -r f; do
        [[ -n "$f" && -f "$f" ]] || continue
        grep -qsE "^[[:space:]]*-?${key//./[./]}[[:space:]]*=" "$f" && last="${f#"${AUDIT_ROOT:-}"}"
    done < <(for name in "${!by_name[@]}"; do printf '%s\t%s\n' "$name" "${by_name[$name]}"; done \
                 | LC_ALL=C sort -t$'\t' -k1,1 | cut -f2-
             [[ $conf_read -eq 1 ]] || printf '%s\n' "$(_r /etc/sysctl.conf)")
    printf '%s' "$last"
}

check_sysctl() {
    local key want val min ok src
    local -a bad=() keys=() now=() after=() srcs=() seen=()
    for key in $(printf '%s\n' "${!_SYSCTL_WANT[@]}" | sort); do
        want="${_SYSCTL_WANT[$key]}"
        val=$(_sysctl_value "$key")
        [[ "$val" =~ ^-?[0-9]+$ ]] || continue
        seen+=("${key}=${val}")
        ok=1
        if [[ "$want" == ">="* ]]; then
            min="${want#>=}"
            (( val >= min )) || ok=0
        else
            [[ "$val" == "${want#=}" ]] || ok=0
        fi
        if [[ $ok -eq 0 ]]; then
            src=$(_sysctl_source "$key")
            bad+=("${key} = ${val} (should be ${want#=}${src:+; set in ${src}})")
            keys+=("$key")
            now+=("${key}=${val}")
            after+=("${key}=${_SYSCTL_FIXVAL[$key]}")
            [[ -n "$src" && " ${srcs[*]} " != *" ${src} "* ]] && srcs+=("$src")
        fi
    done
    [[ ${#seen[@]} -gt 0 ]] && check_note "Current values: $(_join ', ' "${seen[@]}")"
    if [[ ${#bad[@]} -gt 0 ]]; then
        finding low "${#bad[@]} kernel protection(s) weaker than the default" \
"$(printf '%s\n' "${bad[@]}")
These are on by default in Bazzite and cost nothing in games, so something
switched them off." \
"Put the default values in ${_SYSCTL_DROPIN} and run: sudo sysctl --system" \
            fix_sysctl "${keys[@]}"
        finding_change "$(_join ', ' "${now[@]}")" "$(_join ', ' "${after[@]}")" \
            "$([[ ${#srcs[@]} -gt 0 ]] && echo "overrides a file|This overrides what $(_join ', ' "${srcs[@]}") sets. If you changed that on purpose, skip this fix.")"
    fi
    return 0
}

fix_sysctl() {
    local key body="" existing=""
    existing=$(grep -vE "^[[:space:]]*($(_join '|' "${@//./[.]}"))[[:space:]]*=" "$(_r "$_SYSCTL_DROPIN")" 2>/dev/null || true)
    [[ -n "$existing" ]] || existing="# Written by bazzite-sec-audit: restores default kernel protections."
    body="$existing"
    for key in "$@"; do body+=$'\n'"${key} = ${_SYSCTL_FIXVAL[$key]}"; done
    # The file's earlier lines are kept: written as one quoted word, so
    # nothing in them can end up as a command.
    apply_change "$(_backup_cmd "$_SYSCTL_DROPIN")
printf '%s\n' $(_q "$body") > ${_SYSCTL_DROPIN}
sysctl -p ${_SYSCTL_DROPIN}" \
        "$(_restore_cmd "$_SYSCTL_DROPIN")
sysctl --system" \
        "${_SYSCTL_DROPIN} is read last, so its values win over the other sysctl files."
}
