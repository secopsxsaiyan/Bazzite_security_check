# shellcheck shell=bash
# System image and updates: signature checking, automatic updates, layered
# packages, repositories and firmware.

# ====================== IMAGE SIGNATURE ======================
check_image_signature() {
    if [[ "$IS_OSTREE" -ne 1 || -z "$RPMOSTREE_JSON" ]]; then
        mark_na "not an rpm-ostree / bootc system"
        return 0
    fi
    local ref clean target
    ref=$(_deploy 'b.get("container-image-reference", "")')
    if [[ -z "$ref" ]]; then
        mark_na "the system is not deployed from a container image"
        return 0
    fi
    check_note "Booted image: ${ref}"
    case "$ref" in
        ostree-image-signed:*)
            # "signed" means: checked against /etc/containers/policy.json.
            # A policy that accepts anything for this image checks nothing.
            if [[ "$(_image_policy "$ref")" == "anything" ]]; then
                finding medium "The signature policy accepts this system image unsigned" \
"This PC follows ${ref}, but /etc/containers/policy.json says
insecureAcceptAnything for it, so no signature is actually required." \
"Restore the image's policy: sudo cp /usr/etc/containers/policy.json /etc/containers/policy.json
(or add a sigstoreSigned entry with the publisher's key for this image)"
                finding_change "policy.json: insecureAcceptAnything for this image" "a signature is required (manual)"
            fi
            return 0 ;;
        ostree-remote-image:*|ostree-remote-registry:*)
            return 0 ;;
    esac
    clean="${ref#ostree-unverified-registry:}"
    clean="${clean#ostree-unverified-image:}"
    clean="${clean#docker://}"
    if [[ "$clean" == ghcr.io/ublue-os/* ]]; then
        target="ostree-image-signed:docker://${clean}"
        finding high "System updates are installed without checking their signature" \
"This PC follows ${ref}. The \"unverified\" transport downloads system images
without checking Universal Blue's signature, so a tampered image (for example
from a compromised mirror or network) would be installed silently. Official
images are signed; switching to the signed transport keeps the same image and
updates, it only adds the check." \
"rpm-ostree rebase ${target}
systemctl reboot
(Bazzite also has: ujust verify-image)" \
            fix_rebase "$target" "$ref" "switch to the signature-checked image"
        finding_change "image pulled without a signature check (${ref%%:*})" \
            "same image and updates, signature checked (ostree-image-signed)" \
            "$W_DOWNLOAD" "$W_REBOOT"
    else
        finding medium "Custom system image is not signature-checked" \
"This PC follows ${ref}, which is not an official Universal Blue image and is
pulled without signature verification." \
"If you build this image yourself, sign it with cosign, add its key to
/etc/containers/policy.json and rebase to ostree-image-signed:docker://${clean}"
        finding_change "custom image, signature not checked" "signed with your own cosign key (manual)"
    fi
    return 0
}

# _image_policy REF — "anything" when /etc/containers/policy.json accepts
# REF's image without a signature (the most specific docker scope that
# covers it, else the default, holds only insecureAcceptAnything).
_image_policy() {
    local f
    f="$(_r /etc/containers/policy.json)"
    [[ -f "$f" ]] || return 0
    python3 -I -c '
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
name = re.sub(r"^[a-z-]+:(docker://|registry:)?", "", sys.argv[2])
name = re.sub(r"(@sha256:[0-9a-f]+|:[^/:]+)$", "", name)
scopes = (d.get("transports") or {}).get("docker") or {}
req, scope = None, name
while scope:
    if scope in scopes:
        req = scopes[scope]
        break
    scope = scope.rpartition("/")[0]
if req is None:
    req = scopes.get("", d.get("default"))
if isinstance(req, list) and req and all(isinstance(r, dict) and r.get("type") == "insecureAcceptAnything" for r in req):
    print("anything")' "$f" "$1" 2>/dev/null || true
}

# fix_rebase TARGET OLD REASON — move to another image reference.
fix_rebase() {
    local target="$1" old="$2" reason="$3"
    apply_change "rpm-ostree rebase $(_q "$target")" \
                 "rpm-ostree rebase $(_q "$old")" \
                 "Your apps, files and settings are kept." \
                 "$reason"
}

# ====================== UPDATES ======================
readonly _UPDATE_TIMERS=(uupd.timer ublue-update.timer rpm-ostreed-automatic.timer)

check_system_updates() {
    if [[ "$IS_OSTREE" -ne 1 ]]; then
        mark_na "not an rpm-ostree / bootc system"
        return 0
    fi
    local t st enabled="" first_present="" first_state=""
    for t in "${_UPDATE_TIMERS[@]}"; do
        st=$(_unit_state "$t")
        [[ "$st" == "missing" ]] && continue
        [[ -z "$first_present" ]] && { first_present="$t"; first_state="$st"; }
        if [[ "$st" == "enabled" ]]; then
            enabled="$t"
            break
        fi
    done
    if [[ -n "$enabled" ]]; then
        check_note "Automatic updates: ${enabled} is enabled"
        if [[ "$enabled" == "rpm-ostreed-automatic.timer" ]]; then
            local pol
            pol=$(_ini_get "$(_r /etc/rpm-ostreed.conf)" Daemon AutomaticUpdatePolicy)
            if [[ -z "$pol" || "$pol" == "none" ]]; then
                finding medium "Automatic updates are enabled but set to do nothing" \
"rpm-ostreed-automatic.timer runs, but AutomaticUpdatePolicy in
/etc/rpm-ostreed.conf is '${pol:-none}', so no update is ever staged." \
"Set AutomaticUpdatePolicy=stage in the [Daemon] section of /etc/rpm-ostreed.conf"
                finding_change "AutomaticUpdatePolicy=${pol:-none}" "AutomaticUpdatePolicy=stage (manual)"
            fi
        fi
        _check_update_service_result "$enabled"
    elif [[ -n "$first_present" ]]; then
        finding medium "Automatic updates are turned off" \
"No update timer is enabled (${first_present} is ${first_state}). Bazzite normally
updates the system, Flatpaks, Homebrew and Distrobox containers in the
background with uupd and applies them at the next reboot. Without it, security
fixes only arrive when you remember to run ujust update." \
"sudo systemctl enable --now ${first_present}   (or run 'ujust update' regularly)" \
            fix_enable_unit "$first_present" "$first_state"
        finding_change "${first_present}: ${first_state}" "${first_present}: enabled and started" \
            "$([[ $first_state == masked ]] && echo "was masked|${first_present} was masked (blocked on purpose by someone or a tool); this unmasks it.")"
    else
        finding low "No automatic update service found" \
"None of ${_UPDATE_TIMERS[*]} is installed." \
"Run 'ujust update' (or rpm-ostree upgrade and flatpak update) regularly."
    fi

    [[ -n "$RPMOSTREE_JSON" ]] || return 0
    local staged booted_first ts age ref tag
    staged=$(_pyjson 'any(x.get("staged") for x in d.get("deployments", []))' <<< "$RPMOSTREE_JSON" 2>/dev/null || true)
    booted_first=$(_pyjson 'bool(d.get("deployments")) and bool(d["deployments"][0].get("booted") or d["deployments"][0].get("staged"))' <<< "$RPMOSTREE_JSON" 2>/dev/null || true)
    ts=$(_deploy 'b.get("timestamp", "")')
    ref=$(_deploy 'b.get("container-image-reference", "")')

    if [[ "$staged" == "true" ]]; then
        finding low "An update is downloaded and waits for a reboot" \
"A new system image is staged. Security fixes in it are not active until you
restart the PC." \
"Reboot when it suits you (Bazzite applies staged updates at the next boot)."
        finding_change "update staged, not active" "active after a reboot (manual)"
    elif [[ "$ts" =~ ^[0-9]+$ ]]; then
        age=$(( ( $(date +%s) - ts ) / 86400 ))
        check_note "Running system image built ${age} day(s) ago"
        if (( age > 30 )); then
            finding medium "The system image is ${age} days old" \
"The running image was built ${age} days ago. Bazzite publishes updates far more
often, so this PC is missing security fixes (kernel, Mesa, browser libraries,
...). Updates may be failing, or this PC is pinned to an old version." \
"ujust update      (then reboot)
journalctl -u uupd.service -n 50   (to see why automatic updates failed)"
            finding_change "image built ${age} days ago" "current image (ujust update, then reboot)"
        elif (( age > 14 )); then
            finding low "The system image is ${age} days old" \
"The running image was built ${age} days ago; a newer one is probably available." \
"ujust update      (then reboot)"
            finding_change "image built ${age} days ago" "current image (ujust update, then reboot)"
        fi
    fi

    if [[ "$booted_first" == "false" ]]; then
        finding low "An older system version is running (rollback)" \
"The PC was started from an older deployment instead of the newest one. That is
fine if you chose it on purpose in the boot menu (for example after a broken
update), but it lacks the newer security fixes." \
"Restart and pick the first boot entry, or make it permanent with: rpm-ostree rollback"
    fi

    # A tag that names a fixed build or Fedora release never moves forward.
    tag="${ref##*:}"
    if [[ -n "$ref" && "$tag" != "$ref" && "$tag" != */* ]]; then
        if [[ "$tag" =~ [0-9]{8} ]]; then
            local stable="${ref%:*}:${IMAGE_TAG:-stable}"
            [[ "$stable" == "$ref" ]] && stable="${ref%:*}:stable"
            finding medium "The system is pinned to a fixed build (${tag})" \
"This PC follows the tag '${tag}', which names one specific build: it will never
receive another update. Pinning is useful for a short time to skip a broken
release, but not as a permanent setting." \
"rpm-ostree rebase ${stable}" \
                fix_rebase "$stable" "$ref" "move back to the updating '${stable##*:}' channel"
            finding_change "tag '${tag}' (one fixed build, never updates)" "tag '${stable##*:}' (receives updates)" \
                "$W_DOWNLOAD" "$W_REBOOT"
        elif [[ "$tag" =~ ^(([a-z]+)-)?([0-9]{2})$ ]]; then
            # "42", or "stable-42": that channel, but only on Fedora 42.
            local fedora="${BASH_REMATCH[3]}" channel="${BASH_REMATCH[2]:-stable}"
            finding low "The system is pinned to Fedora ${fedora}" \
"This PC follows the tag '${tag}', so it stays on Fedora ${fedora}. Updates stop when
that release reaches its end of life." \
"When you are ready: rpm-ostree rebase ${ref%:*}:${channel}"
            finding_change "tag '${tag}' (stays on Fedora ${fedora})" "tag '${channel}' (manual, when you are ready)"
        fi
    fi
    return 0
}

# _check_update_service_result TIMER — report when the last run of the
# timer's service failed.
_check_update_service_result() {
    local svc="${1%.timer}.service" result started
    started=$(systemctl show -p ExecMainStartTimestamp --value "$svc" 2>/dev/null || true)
    [[ -n "$started" && "$started" != "n/a" ]] || return 0
    result=$(systemctl show -p Result --value "$svc" 2>/dev/null || true)
    if [[ -n "$result" && "$result" != "success" ]]; then
        finding low "The last automatic update did not finish" \
"${svc} last ran ${started} and ended with '${result}'. Updates may be stuck." \
"journalctl -u ${svc} -n 80     (shows why)
ujust update                    (runs it by hand)"
    fi
    return 0
}

# fix_enable_unit UNIT PREVIOUS_STATE — enable (and unmask) a system unit.
fix_enable_unit() {
    local unit="$1" prev="$2" script undo
    script=""
    [[ "$prev" == "masked" ]] && script+="systemctl unmask $(_q "$unit")"$'\n'
    script+="systemctl enable --now $(_q "$unit")"
    undo="systemctl disable --now $(_q "$unit")"
    [[ "$prev" == "masked" ]] && undo+=$'\n'"systemctl mask $(_q "$unit")"
    apply_change "$script" "$undo"
}

# ====================== LAYERED PACKAGES ======================
check_layered_packages() {
    if [[ "$IS_OSTREE" -ne 1 || -z "$RPMOSTREE_JSON" ]]; then
        mark_na "not an rpm-ostree / bootc system"
        return 0
    fi
    local -a layered=()
    local removals overrides
    mapfile -t layered < <(_deploy 'sorted(set(b.get("requested-packages", []) + b.get("requested-local-packages", [])))')
    removals=$(_deploy 'len(b.get("requested-base-removals", []) or [])')
    overrides=$(_deploy 'len(b.get("requested-base-local-replacements", []) or []) + len(b.get("base-remote-replacements", {}) or {})')
    [[ "$removals" =~ ^[0-9]+$ ]] || removals=0
    [[ "$overrides" =~ ^[0-9]+$ ]] || overrides=0

    if [[ ${#layered[@]} -gt 0 ]]; then
        check_note "Layered: $(_join ', ' "${layered[@]}")"
        finding low "${#layered[@]} package(s) layered on top of the system image" \
"Layered: $(_join ', ' "${layered[@]}").
Layered packages come from repositories the image does not vet, are only
updated when their repository has a matching build, and are the most common
reason a Bazzite update fails (which then also holds back security fixes).
Keep the ones you need; consider a Flatpak, Homebrew or Distrobox for the rest." \
"rpm-ostree uninstall PACKAGE ...   (then reboot)
Alternatives: flatpak install, brew install, or distrobox create" \
            fix_layered_remove "${layered[@]}"
        finding_change "layered: $(_join ', ' "${layered[@]}")" "the packages you tick are removed" \
            "$W_REBOOT" \
            "programs go away|Programs from removed packages are gone after the reboot. Install them as a Flatpak, with Homebrew or in a Distrobox if you still need them."
    fi
    if (( removals + overrides > 0 )); then
        finding medium "${removals} removed and ${overrides} replaced base package(s)" \
"Parts of the image are overridden. A replaced package stays at the version you
chose and misses the image's security updates for it; removed packages can
leave dependencies broken." \
"rpm-ostree status -v                 (shows the overrides)
rpm-ostree override reset PACKAGE    (or --all), then reboot"
        finding_change "${removals} removed, ${overrides} replaced" "the image's own packages (manual)"
    fi
    return 0
}

# fix_layered_remove PACKAGE... — let the user pick layered packages to remove.
fix_layered_remove() {
    local -a items=() pick=()
    local p
    local sum risk warn running u
    for p in "$@"; do
        # What it is (from the package), and whether a service of it runs now.
        sum=$(rpm -q --qf '%{SUMMARY}' "$p" 2>/dev/null | head -n1) || sum=""
        running=$(rpm -ql "$p" 2>/dev/null | grep -E '/systemd/system/[^/]+\.service$' | while read -r u; do
            _unit_active "${u##*/}" && printf '%s ' "${u##*/}"; done)
        risk=medium
        warn="Its programs are gone after the reboot; install them as a Flatpak, with Homebrew or in a Distrobox if you still need them."
        case "$p" in
            clamav*|clamd*) risk=high; warn="The deep check's ClamAV malware scan (and any scan you run) stops working after the reboot." ;;
            lact*) risk=high; warn="LACT controls your GPU's clocks, power limits and fan curve; what it applies stops after the reboot." ;;
            *akmod*|*kmod*|*nvidia*|mesa*|gamescope*|*firmware*|*driver*) risk=high; warn="A driver or graphics component: removing it can break graphics or gaming." ;;
            steam*|sunshine*|tailscale*|*virt*|qemu*|docker*|podman*) risk=high; warn="Removing it stops the service or app it provides (games, streaming, VPN, VMs or containers)." ;;
        esac
        [[ -n "$running" ]] && { risk=high; warn="Running now: ${running% }. ${warn}"; }
        items+=("$p" "$(ui_item "$p" "${sum:-layered on the system image}" "$risk" "$warn")" off)
    done
    mapfile -t pick < <(ui_checklist "Which layered packages do you want to remove?
Leave a package unticked to keep it. Removal takes effect after a reboot." "${items[@]}") || return 1
    [[ ${#pick[@]} -gt 0 && -n "${pick[0]}" ]] || return 1
    local q=""
    for p in "${pick[@]}"; do q+=" $(_q "$p")"; done
    CHANGE_AFTER="removed after the reboot: $(_join ', ' "${pick[@]}")"
    apply_change "rpm-ostree uninstall${q}" "rpm-ostree install${q}" "" \
        "remove layered package(s):${q}"
}

# ====================== REPOSITORIES ======================
# _repo_problems — "file<TAB>section<TAB>problem<TAB>has_key" for enabled
# repositories that skip GPG checks or use plain http (has_key: 1 when the
# section names a gpgkey=, so turning gpgcheck on keeps it working).
_repo_problems() {
    local f
    for f in "$(_r /etc/yum.repos.d)"/*.repo; do
        [[ -f "$f" ]] || continue
        awk -v file="${f#"${AUDIT_ROOT:-}"}" '
            function flush() {
                if (sec != "" && en != "0") {
                    if (gpg == "0") print file "\t" sec "\tgpgcheck=0\t" (key != "" ? 1 : 0)
                    if (url ~ /^http:\/\//) print file "\t" sec "\thttp\t" (key != "" ? 1 : 0)
                }
            }
            /^[ \t]*[#;]/ { next }
            /^[ \t]*\[/ { flush(); sec = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", sec); en = "1"; gpg = ""; url = ""; key = ""; next }
            {
                i = index($0, "="); if (i == 0) next
                k = substr($0, 1, i - 1); v = substr($0, i + 1)
                gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
                if (k == "enabled") en = v
                else if (k == "gpgcheck") gpg = v
                else if (k == "gpgkey") key = v
                else if ((k == "baseurl" || k == "metalink" || k == "mirrorlist") && url == "") url = v
            }
            END { flush() }' "$f" 2>/dev/null || true
    done
}

check_repos() {
    if [[ ! -d "$(_r /etc/yum.repos.d)" ]]; then
        mark_na "no /etc/yum.repos.d"
        return 0
    fi
    local nlayered=0 file sec prob has_key sev
    if [[ -n "$RPMOSTREE_JSON" ]]; then
        nlayered=$(_deploy 'len(b.get("requested-packages", []))')
        [[ "$nlayered" =~ ^[0-9]+$ ]] || nlayered=0
    fi
    while IFS=$'\t' read -r file sec prob has_key; do
        [[ -n "$file" ]] || continue
        if [[ "$prob" == "gpgcheck=0" ]]; then
            sev="low"; (( nlayered > 0 )) && sev="medium"
            finding "$sev" "Repository '${sec}' installs packages without a signature check" \
"${file} enables [${sec}] with gpgcheck=0. Packages layered from it are not
verified. $([[ $nlayered -gt 0 ]] && echo "This PC has layered packages, so this repository can be in use." || echo "It only matters when you layer packages (rpm-ostree install), which this PC does not do right now.")" \
"Set gpgcheck=1 in [${sec}] of ${file} (and add the repository's gpgkey=), or
disable it with enabled=0." \
                fix_repo_setting "$file" "$sec" "gpgcheck" "1"
            if [[ "$has_key" == 1 ]]; then
                finding_change "[${sec}] gpgcheck=0 (it names a gpgkey)" "[${sec}] gpgcheck=1"
            else
                finding_change "[${sec}] gpgcheck=0, no gpgkey= line" "[${sec}] gpgcheck=1" \
                    "repository stops working|[${sec}] names no signing key (gpgkey=), so installing or updating packages from it fails until you add its key or disable the repository."
            fi
        else
            finding low "Repository '${sec}' is fetched over plain http" \
"${file} uses an http:// address for [${sec}]. With gpgcheck the packages are
still verified, but the metadata can be tampered with on the way." \
"Change the address to https:// in ${file} if the server supports it."
            finding_change "[${sec}] fetched over http://" "https:// (manual, if the server supports it)"
        fi
    done < <(_repo_problems)
    return 0
}

# fix_repo_setting FILE SECTION KEY VALUE — set KEY=VALUE inside [SECTION]
# (whether the repository names a key is shown as a warning by the check).
fix_repo_setting() {
    local file="$1" sec="$2" key="$3" val="$4" esec script
    esec=$(printf '%s' "$sec" | sed 's/[][\.*^$/]/\\&/g')
    script="$(_backup_cmd "$file")"$'\n'
    # The section name comes from the repository file: quoted as one word,
    # so nothing in it can run as a command.
    script+="sed -i $(_q "/^\\[${esec}\\]/,/^\\[/ s/^[[:space:]]*${key}[[:space:]]*=.*/${key}=${val}/") -- $(_q "$file")"
    apply_change "$script" "$(_restore_cmd "$file")"
}

# ====================== FIRMWARE ======================
check_firmware() {
    if [[ -n "$VIRT" ]]; then
        mark_na "virtual machine (${VIRT})"
        return 0
    fi
    if ! _have fwupdmgr; then
        mark_skip "fwupd is not installed"
        return 0
    fi
    local out names
    out=$(timeout 45 fwupdmgr get-updates --json 2>/dev/null) || true
    if [[ -z "$out" ]]; then
        mark_skip "fwupd did not answer (offline or no supported devices)"
        return 0
    fi
    names=$(_pyjson '[x.get("Name", "?") for x in d.get("Devices", []) if x.get("Releases")]' <<< "$out" 2>/dev/null || true)
    if [[ -n "$names" ]]; then
        finding low "Firmware updates are available" \
"Updates are available for: $(paste -sd ',' <<< "$names" | sed 's/,/, /g')
Firmware updates (UEFI/BIOS, SSD, docks, peripherals) often close security holes
such as UEFI boot-kit or CPU microcode issues." \
"Open Discover → Updates, or run: fwupdmgr refresh && fwupdmgr update"
        finding_change "updates available: $(paste -sd ',' <<< "$names" | sed 's/,/, /g')" "installed from Discover (manual)"
    fi
    return 0
}
