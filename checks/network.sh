# shellcheck shell=bash
# Network exposure: the firewall zone of each real network connection, the
# services that listen on the network, and the SSH server.

readonly AUDIT_ZONE="bazzite-desktop"

# ====================== INTERFACES ======================
# _virtual_iface NAME — bridges and links that belong to containers, VMs or
# Waydroid; their zones are managed by those tools.
_virtual_iface() {
    case "$1" in
        lo|docker*|br-*|veth*|virbr*|vnet*|podman*|cni*|flannel*|waydroid*|incusbr*|lxcbr*|lxdbr*|tap*|vmnet*|vboxnet*) return 0 ;;
    esac
    return 1
}

# _vpn_iface NAME — overlay networks (Tailscale, WireGuard, ZeroTier, OpenVPN).
_vpn_iface() {
    case "$1" in tailscale*|wg*|tun*|zt*|ts*) return 0 ;; esac
    return 1
}

# _lan_ifaces — interfaces with a global address that face a real network.
_lan_ifaces() {
    local ifc
    while read -r ifc; do
        [[ -n "$ifc" ]] || continue
        _virtual_iface "$ifc" && continue
        _vpn_iface "$ifc" && continue
        printf '%s\n' "$ifc"
    done < <(ip -o addr show scope global 2>/dev/null | awk '{print $2}' | sed 's/@.*//' | sort -u || true)
    return 0
}

# ====================== FIREWALLD ======================
_fw_running() { _have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; }

_fw_default_zone() { firewall-cmd --get-default-zone 2>/dev/null || true; }

# _fw_zone_of IFACE — the zone filtering IFACE (the default zone when the
# interface is not bound to one).
_fw_zone_of() {
    local z
    z=$(firewall-cmd --get-zone-of-interface="$1" 2>/dev/null) || z=""
    [[ -n "$z" ]] || z=$(_fw_default_zone)
    printf '%s' "$z"
}

declare -gA _FW_ZONE_ALL=()
# _fw_zone_field ZONE FIELD — one field of "firewall-cmd --list-all" (read
# from the cache when _fw_zone_load filled it).
_fw_zone_field() {
    local all
    if [[ -n "${_FW_ZONE_ALL[$1]+x}" ]]; then
        all="${_FW_ZONE_ALL[$1]}"
    else
        all=$(firewall-cmd --zone="$1" --list-all 2>/dev/null || true)
    fi
    awk -v f="$2" '{ line = $0; sub(/^[ \t]+/, "", line) } index(line, f ":") == 1 { sub(/^[^:]*:[ \t]*/, "", line); print line; exit }' <<< "$all" || true
}

# _fw_zone_load ZONE — read ZONE once into the caches (its --list-all and
# the ports it opens). Call it directly, not in $(...): a subshell's cache
# is lost when it ends.
_fw_zone_load() {
    [[ -n "${_FW_ZONE_ALL[$1]+x}" ]] || _FW_ZONE_ALL["$1"]=$(firewall-cmd --zone="$1" --list-all 2>/dev/null || true)
    _fw_zone_open "$1" > /dev/null
}

declare -gA _FW_SVC_PORTS=()
# _fw_service_ports SERVICE — "port/proto" (or "a-b/proto") entries of a service.
_fw_service_ports() {
    if [[ -z "${_FW_SVC_PORTS[$1]+x}" ]]; then
        _FW_SVC_PORTS["$1"]=$(firewall-cmd --info-service="$1" 2>/dev/null \
            | awk '{ line = $0; sub(/^[ \t]+/, "", line) } index(line, "ports:") == 1 { sub(/^ports:[ \t]*/, "", line); print line; exit }' || true)
    fi
    printf '%s' "${_FW_SVC_PORTS[$1]}"
}

declare -gA _FW_ZONE_OPEN=()
# _fw_zone_open ZONE — every port entry the zone opens (own ports, those of
# its services, and every port of a protocol it allows as a whole),
# space-separated; "ALL" when its target accepts everything.
_fw_zone_open() {
    local z="$1" target svc p out=""
    if [[ -z "${_FW_ZONE_OPEN[$z]+x}" ]]; then
        target=$(_fw_zone_field "$z" target)
        if [[ "$target" == "ACCEPT" ]]; then
            out="ALL"
        else
            out="$(_fw_zone_field "$z" ports)"
            for svc in $(_fw_zone_field "$z" services); do
                out+=" $(_fw_service_ports "$svc")"
            done
            # "protocols: tcp" lets in every TCP port.
            for p in $(_fw_zone_field "$z" protocols); do
                [[ "$p" =~ ^(tcp|udp|sctp|dccp)$ ]] && out+=" 1-65535/${p}"
            done
        fi
        _FW_ZONE_OPEN["$z"]="$out"
    fi
    printf '%s' "${_FW_ZONE_OPEN[$z]}"
}

# _ports_cover OPEN PORT PROTO — true when PORT/PROTO falls in OPEN.
_ports_cover() {
    local open="$1" port="$2" proto="$3" e range p lo hi
    [[ "$open" == "ALL" ]] && return 0
    for e in $open; do
        range="${e%/*}"; p="${e##*/}"
        [[ "$p" == "$proto" ]] || continue
        lo="${range%-*}"; hi="${range#*-}"
        [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || continue
        (( port >= lo && port <= hi )) && return 0
    done
    return 1
}

# _wide_ranges OPEN — port ranges of 1000 or more ports in OPEN.
_wide_ranges() {
    local e range lo hi
    for e in $1; do
        range="${e%/*}"
        [[ "$range" == *-* ]] || continue
        lo="${range%-*}"; hi="${range#*-}"
        [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || continue
        (( hi - lo + 1 >= 1000 )) && printf '%s ' "$e"
    done
    return 0
}

check_firewall() {
    if ! _have firewall-cmd; then
        if _have nft && nft list ruleset 2>/dev/null | grep -qE 'hook input .*policy drop'; then
            check_note "firewalld is not installed, but an nftables input policy drops traffic"
            return 0
        fi
        finding high "No firewall is installed" \
"firewalld (Bazzite's firewall) is missing and no other firewall rules were found." \
"rpm-ostree install firewalld && systemctl reboot"
        finding_change "no firewall" "firewalld installed and running (manual, needs a reboot)"
        return 0
    fi
    if ! _fw_running; then
        if _have nft && nft list ruleset 2>/dev/null | grep -qE 'hook input .*policy drop'; then
            check_note "firewalld is stopped, but an nftables input policy drops traffic"
            return 0
        fi
        finding high "The firewall is turned off" \
"firewalld is not running, so every service that listens on the network - dev
servers, databases, game servers, file shares - can be reached by anyone on the
same network (other people's devices on public Wi-Fi, a compromised smart TV at
home, ...)." \
"sudo systemctl enable --now firewalld" \
            fix_enable_unit firewalld.service "$(_unit_state firewalld.service)"
        local cfg_zone
        cfg_zone=$(awk -F= '$1 == "DefaultZone" {gsub(/[ \t]/, "", $2); print $2}' "$(_r /etc/firewalld/firewalld.conf)" 2>/dev/null | tail -n1 || true)
        finding_change "firewalld stopped ($(_unit_state firewalld.service))" \
            "firewalld running and enabled, default zone ${cfg_zone:-as configured}" \
            "blocks unlisted services|From now on, incoming connections the zone${cfg_zone:+ '${cfg_zone}'} does not allow are blocked."
        return 0
    fi

    local def ifc z prob
    local -A seen=() used=()
    local -a bad_zones=() bad_ifaces=() desc=()
    def=$(_fw_default_zone)
    check_note "firewalld is running; default zone: ${def}"
    while IFS= read -r ifc; do
        [[ -n "$ifc" ]] || continue
        z=$(_fw_zone_of "$ifc")
        [[ -n "$z" ]] || continue
        check_note "${ifc}: zone ${z}"
        used["$z"]=1
        _fw_zone_load "$z"
        if prob=$(_fw_zone_problem "$z"); then
            bad_ifaces+=("$ifc")
            if [[ -z "${seen[$z]:-}" ]]; then
                seen["$z"]=1
                bad_zones+=("$z")
                desc+=("zone '${z}' ${prob}")
            fi
        fi
    done < <(_lan_ifaces)
    # New connections (the next Wi-Fi you join) get the default zone, even
    # when no connection uses it right now - for example on an offline laptop.
    local unused_default=0
    [[ -n "$def" ]] && _fw_zone_load "$def"
    if [[ -n "$def" && -z "${used[$def]:-}" ]] && prob=$(_fw_zone_problem "$def"); then
        unused_default=1
        bad_zones+=("$def")
        desc+=("the default zone '${def}', which new connections get, ${prob}")
    fi

    if [[ ${#bad_zones[@]} -eq 0 ]]; then
        return 0
    fi
    local sev where
    if [[ ${#bad_ifaces[@]} -eq 0 ]]; then
        # Only the default zone, which no connection uses right now.
        sev=$(_ctx medium low)
        [[ "${desc[*]}" == *"accepts all incoming"* ]] && sev=$(_ctx high medium)
        where="no connection uses it right now, but the next network you join will"
    else
        if [[ "${desc[*]}" == *"accepts all incoming"* ]]; then sev="high"; else sev=$(_ctx high medium); fi
        where="on: ${bad_ifaces[*]}"
        [[ $unused_default -eq 1 ]] && where+="; the default zone applies to networks you join later"
    fi
    finding "$sev" "The firewall lets in far more than this PC needs" \
"$(_join '; ' "${desc[@]}") (${where}).
Fedora's desktop zone opens every port above 1024 for convenience. That means
any dev server, database, game server or tool that listens on the network is
reachable by every other device on the same network - including public Wi-Fi.
A zone that opens only what you use (Steam, KDE Connect, Sunshine, ...) keeps
everything working without that exposure." \
"Create a zone with only the services you use and make it the default:
firewall-cmd --permanent --new-zone=${AUDIT_ZONE}
firewall-cmd --permanent --zone=${AUDIT_ZONE} --add-service=mdns  (and others you need)
firewall-cmd --reload && firewall-cmd --set-default-zone=${AUDIT_ZONE}
Or use the Firewall settings app (firewall-config)." \
        fix_firewall_zone "$def" "${bad_zones[*]}" "${bad_ifaces[@]}"
    finding_change "$(_join '; ' "${desc[@]}")" "zone '${AUDIT_ZONE}' that allows only what you tick" \
        "blocks the rest|Anything you leave unticked can no longer be reached from other devices. This PC can still connect out, and games and browsing are not affected."
    return 0
}

# _fw_zone_problem ZONE — print why ZONE lets in too much (status 1 if it does not).
_fw_zone_problem() {
    local wide
    if [[ "$(_fw_zone_field "$1" target)" == "ACCEPT" ]]; then
        echo "accepts all incoming connections"
        return 0
    fi
    wide=$(_wide_ranges "$(_fw_zone_open "$1")")
    [[ -n "$wide" ]] || return 1
    echo "opens ${wide% }"
}

# _fw_zone_extras ZONE — settings of ZONE that the zone built by
# fix_firewall_zone does not copy (it only keeps services and ports), one
# short description per line. Rich rules and forwarded ports follow their
# header on lines of their own, indented with a tab.
_fw_zone_extras() {
    _fw_zone_load "$1"
    awk '
        /^\t/ { if ($0 ~ /[^ \t]/) { if (cur == "rich") nrich++; else if (cur == "fwd") nfwd++ }; next }
        {
            cur = ""; line = $0; sub(/^[ \t]+/, "", line)
            i = index(line, ":"); if (i == 0) next
            k = substr(line, 1, i - 1); v = substr(line, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (k == "rich rules")         { cur = "rich"; if (v != "") nrich++ }
            else if (k == "forward-ports") { cur = "fwd"; if (v != "") nfwd++ }
            else if (k == "masquerade" && v == "yes") print "masquerading (NAT)"
            else if (k == "source-ports" && v != "") print "source ports " v
            else if (k == "protocols" && v != "") print "allowed protocols " v
        }
        END {
            if (nfwd) print nfwd " port forwarding rule(s)"
            if (nrich) print nrich " rich rule(s)"
        }' <<< "${_FW_ZONE_ALL[$1]:-}" 2>/dev/null || true
}

# _fw_item_ports TAG — the ports a checklist item of fix_firewall_zone opens
# (when firewalld has no predefined service for it).
_fw_item_ports() {
    case "$1" in
        kdeconnect) echo "1714-1764/tcp 1714-1764/udp" ;;
        steam)      echo "27031-27036/udp 27036-27037/tcp 27040/tcp" ;;
        # 47990 (the admin web page) stays closed: pairing is done on this PC.
        sunshine)   echo "47984/tcp 47989/tcp 48010/tcp 47998-48000/udp 48002/udp 48010/udp" ;;
        localsend)  echo "53317/tcp 53317/udp" ;;
    esac
}

# _fw_has_service NAME — firewalld knows the predefined service NAME.
_fw_has_service() { firewall-cmd --get-services 2>/dev/null | tr ' ' '\n' | grep -qx "$1"; }

# fix_firewall_zone OLD_DEFAULT "BAD_ZONES" IFACE... — build a zone from what
# is installed (the user ticks what to keep) and move the connections to it.
fix_firewall_zone() {
    local old_def="$1" zones_str="$2"
    shift 2
    local -a ifaces=("$@") items=() pick=()
    local -A short=([dhcpv6-client]="DHCPv6" [mdns]="mDNS" [kdeconnect]="KDE Connect" [steam]="Steam Remote Play"
                    [sunshine]="Sunshine streaming" [ssh]="SSH" [samba]="Samba" [syncthing]="Syncthing" [localsend]="LocalSend")
    local kdc=0 steam=0 sun=0 sshd_on=0 smb=0 sync=0 lsend=0

    { _have kdeconnectd || [[ -x /usr/libexec/kdeconnectd ]] || pgrep -x kdeconnectd >/dev/null 2>&1; } && kdc=1
    { _have steam || _have bazzite-steam; } && steam=1
    [[ -n "$DESKTOP_USER" ]] && _sunshine_installed "$DESKTOP_USER" && sun=1
    { _unit_active sshd.service || [[ "$(_unit_state sshd.service)" == "enabled" ]] || _unit_active sshd.socket; } && sshd_on=1
    _unit_active smb.service && smb=1
    { _have syncthing || _flatpak_installed com.github.zocker_160.SyncThingy; } && sync=1
    _flatpak_installed org.localsend.localsend_app && lsend=1

    items+=(dhcpv6-client "Automatic IPv6 address setup (DHCPv6) - recommended" on)
    items+=(mdns "Finding printers, Chromecasts and other devices (mDNS) - recommended" on)
    [[ $kdc -eq 1 ]] && items+=(kdeconnect "KDE Connect (phone integration, ports 1714-1764)" on)
    [[ $steam -eq 1 ]] && items+=(steam "Steam Remote Play host and LAN game transfers (27031-27040)" "$(_onoff "$((USE_STREAMING || USE_GAMING))")")
    [[ $sun -eq 1 ]] && items+=(sunshine "Sunshine game streaming to Moonlight (47984-48010, admin page stays local)" "$(_onoff "$USE_STREAMING")")
    [[ $sshd_on -eq 1 ]] && items+=(ssh "SSH logins to this PC (port 22)" "$(_onoff "$USE_SSH")")
    [[ $smb -eq 1 ]] && items+=(samba "Windows file sharing from this PC (Samba)" "$(_onoff "$USE_SHARING")")
    [[ $sync -eq 1 ]] && items+=(syncthing "Syncthing file sync (22000, 21027)" "$(_onoff "$USE_SHARING")")
    [[ $lsend -eq 1 ]] && items+=(localsend "LocalSend file transfers (53317)" on)

    # What the current zone(s) let in on purpose - their own services and
    # narrow port ranges (Fedora's samba-client, a game server port you
    # added) - stays ticked, so what works today keeps working. Ports an
    # item above already opens are not listed twice.
    local proto port proc z open key svc i p
    local -A done_ports=() have=([ssh]=1)
    for (( i = 0; i < ${#items[@]}; i += 3 )); do
        case "${items[$i]}" in steam) have[steam-streaming]=1 ;; *) have["${items[$i]}"]=1 ;; esac
        for p in $(_fw_item_ports "${items[$i]}"); do done_ports["$p"]=1; done
    done
    for z in $zones_str; do
        _fw_zone_load "$z"
        for svc in $(_fw_zone_field "$z" services); do
            [[ -n "${have[$svc]:-}" ]] && continue
            have["$svc"]=1
            items+=("svc:${svc}" "Keep '${svc}' (allowed now by the zone '${z}')" on)
            short["svc:${svc}"]="$svc"
        done
        for key in $(_fw_zone_field "$z" ports); do
            [[ -n "${done_ports[$key]:-}" || -n "$(_wide_ranges "$key")" ]] && continue
            done_ports["$key"]=1
            short["port:${key}"]="$key"
            if [[ "$key" == "47990/tcp" ]]; then
                # Sunshine's admin page: pairing and settings work from this PC.
                items+=("port:${key}" "Keep ${key} open (Sunshine's admin page - allowed now by the zone '${z}', best kept closed)" off)
            else
                items+=("port:${key}" "Keep ${key} open (allowed now by the zone '${z}')" on)
            fi
        done
    done

    # Other services listening right now that the current zone lets in.
    while IFS=$'\t' read -r proto port proc; do
        [[ -n "$port" ]] || continue
        key="${port}/${proto}"
        [[ -n "${done_ports[$key]:-}" ]] && continue
        done_ports["$key"]=1
        _listener_known "$proc" "$port" "$proto" >/dev/null && continue
        for z in $zones_str; do
            open=$(_fw_zone_open "$z")
            if _ports_cover "$open" "$port" "$proto"; then
                items+=("port:${key}" "Keep ${key} open for ${proc} (listening now - only if other devices must reach it)" off)
                short["port:${key}"]="${key} (${proc})"
                break
            fi
        done
    done < <(_listeners | awk -F'\t' '{print $1 "\t" $3 "\t" $4}')

    local chosen
    chosen=$(ui_checklist "Choose what other devices on your network may reach on this PC.
Everything not ticked is blocked for incoming connections (this PC can still
connect out to anything, and games and browsing are not affected).
Pre-selected from what is installed and how you said you use the PC." "${items[@]}") || return 1
    mapfile -t pick <<< "$chosen"

    local -a add=() kept=() dropped=() missing=()
    local t n_add
    local -A picked=()
    # ui_checklist only returns tags it offered, and only the offered items
    # below are looked up.
    for t in "${pick[@]}"; do [[ -n "$t" ]] && picked["$t"]=1; done
    for (( i = 0; i < ${#items[@]}; i += 3 )); do
        t="${items[$i]}"
        if [[ -z "${picked[$t]:-}" ]]; then dropped+=("${short[$t]:-$t}"); continue; fi
        n_add=${#add[@]}
        case "$t" in
            kdeconnect)
                if _fw_has_service kdeconnect; then add+=("--add-service=kdeconnect")
                else for p in $(_fw_item_ports kdeconnect); do add+=("--add-port=${p}"); done; fi ;;
            steam)
                if _fw_has_service steam-streaming; then add+=("--add-service=steam-streaming" "--add-port=27040/tcp")
                else for p in $(_fw_item_ports steam); do add+=("--add-port=${p}"); done; fi ;;
            sunshine|localsend) for p in $(_fw_item_ports "$t"); do add+=("--add-port=${p}"); done ;;
            port:*) add+=("--add-port=${t#port:}") ;;
            svc:*) add+=("--add-service=${t#svc:}") ;;
            *) if _fw_has_service "$t"; then add+=("--add-service=${t}"); fi ;;
        esac
        # firewalld may have no predefined service for a ticked item.
        if (( ${#add[@]} > n_add )); then kept+=("${short[$t]:-$t}"); else missing+=("${short[$t]:-$t}"); fi
    done

    local script="" undo="" ifc uuid czone zone_exists=0
    firewall-cmd --permanent --get-zones 2>/dev/null | tr ' ' '\n' | grep -qx "$AUDIT_ZONE" && zone_exists=1
    [[ $zone_exists -eq 1 ]] && script+="firewall-cmd --permanent --delete-zone=${AUDIT_ZONE}"$'\n'
    script+="firewall-cmd --permanent --new-zone=${AUDIT_ZONE}"$'\n'
    script+="firewall-cmd --permanent --zone=${AUDIT_ZONE} --set-description='Home gaming/dev desktop: only what you chose in bazzite-sec-audit'"$'\n'
    if [[ ${#add[@]} -gt 0 ]]; then
        script+="firewall-cmd --permanent --zone=${AUDIT_ZONE}$(printf ' %q' "${add[@]}")"$'\n'
    fi
    script+="firewall-cmd --reload"$'\n'
    if [[ " $zones_str " == *" $old_def "* ]]; then
        script+="firewall-cmd --set-default-zone=${AUDIT_ZONE}"$'\n'
        undo+="firewall-cmd --set-default-zone=$(_q "$old_def")"$'\n'
    fi
    # Connections pinned to one of the old zones move explicitly.
    for ifc in "${ifaces[@]}"; do
        _have nmcli || break
        uuid=$(nmcli -g GENERAL.CON-UUID device show "$ifc" 2>/dev/null || true)
        [[ -n "$uuid" ]] || continue
        czone=$(nmcli -g connection.zone connection show "$uuid" 2>/dev/null || true)
        if [[ -n "$czone" && " $zones_str " == *" $czone "* ]]; then
            script+="nmcli connection modify $(_q "$uuid") connection.zone ${AUDIT_ZONE}"$'\n'
            script+="firewall-cmd --zone=${AUDIT_ZONE} --change-interface=$(_q "$ifc")"$'\n'
            undo+="nmcli connection modify $(_q "$uuid") connection.zone $(_q "$czone")"$'\n'
            undo+="firewall-cmd --zone=$(_q "$czone") --change-interface=$(_q "$ifc")"$'\n'
        fi
    done
    undo+="firewall-cmd --permanent --delete-zone=${AUDIT_ZONE} || true"$'\n'
    undo+="firewall-cmd --reload"
    local allows="nothing (all incoming connections blocked)" newdef=""
    [[ ${#kept[@]} -gt 0 ]] && allows=$(_join ', ' "${kept[@]}")
    [[ " $zones_str " == *" $old_def "* ]] && newdef=" (new default)"
    CHANGE_AFTER="zone '${AUDIT_ZONE}'${newdef} allows: ${allows}"
    if [[ ${#dropped[@]} -gt 0 ]]; then
        CHANGE_WARN+=("no longer reachable|No longer reachable from other devices: $(_join ', ' "${dropped[@]}").")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        CHANGE_WARN+=("not available|firewalld has no predefined service for: $(_join ', ' "${missing[@]}"). They stay blocked; open their ports in the Firewall app if you need them.")
    fi
    [[ $zone_exists -eq 1 ]] && CHANGE_WARN+=("replaces zone|A zone named '${AUDIT_ZONE}' exists from an earlier run; it is deleted and rebuilt from what you ticked.")
    # The new zone keeps services and ports only; say what else goes.
    local -a extras=()
    local x
    for z in $zones_str; do
        [[ "$z" == "$AUDIT_ZONE" ]] && continue
        while IFS= read -r x; do
            [[ -n "$x" ]] && extras+=("${x} (zone '${z}')")
        done < <(_fw_zone_extras "$z")
    done
    if [[ ${#extras[@]} -gt 0 ]]; then
        CHANGE_WARN+=("not carried over|The new zone only has the services and ports you ticked. These settings of the old zone are not copied: $(_join '; ' "${extras[@]}"). Add them to the zone '${AUDIT_ZONE}' in the Firewall app (firewall-config) if you still need them.")
    fi
    apply_change "${script%$'\n'}" "$undo" \
        "You can change the allowed services later in the Firewall app (firewall-config) under the zone '${AUDIT_ZONE}', or undo this with --undo."
}

# ====================== LISTENING SERVICES ======================
# _listeners — "proto<TAB>address<TAB>port<TAB>process<TAB>pid" for every
# socket listening on a non-loopback address (DHCP client ports excluded).
_listeners() {
    _have ss || return 0
    ss -H -tulpn 2>/dev/null | awk '
        {
            proto = substr($1, 1, 3); addr = $5
            port = addr; sub(/^.*:/, "", port)
            host = addr; sub(/:[^:]*$/, "", host); gsub(/[\[\]]/, "", host)
            if (port !~ /^[0-9]+$/) next
            if (host ~ /%lo$/ || host ~ /^127\./ || host == "::1" || host ~ /^::ffff:127\./) next
            if (proto == "udp" && (port == 68 || port == 546)) next
            proc = "?"; pid = ""
            if (match($0, /users:\(\("[^"]*",pid=[0-9]+/)) {
                s = substr($0, RSTART + 9, RLENGTH - 9)
                proc = s; sub(/".*/, "", proc)
                pid = s; sub(/.*pid=/, "", pid)
            }
            gsub(/[^A-Za-z0-9._@:+-]/, "?", proc)
            print proto "\t" host "\t" port "\t" proc "\t" pid
        }' | sort -u -t$'\t' -k1,1 -k3,3n || true
}

# _listener_known PROCESS PORT [PROTO] — print a friendly name for expected
# desktop services (status 1 for anything else).
_listener_known() {
    local p="$1" port="$2" proto="${3:-}"
    # Browsers, Electron apps (Discord, VS Code, Spotify) and Chromecast
    # support listen for mDNS answers; the mdns firewall service covers it.
    if [[ "$proto" == "udp" && "$port" == "5353" ]]; then
        echo "mDNS device discovery"
        return 0
    fi
    case "$p" in
        steam|steamwebhelper)          echo "Steam" ;;
        kdeconnectd|kdeconnect*)       echo "KDE Connect" ;;
        sunshine|Sunshine)             echo "Sunshine (see the game streaming check)" ;;
        avahi-daemon)                  echo "mDNS device discovery" ;;
        cupsd|cups-browsed)            echo "Printing" ;;
        systemd-resolve)               echo "Name resolution (LLMNR)" ;;
        sshd|sshd-session)             echo "SSH (see the SSH check)" ;;
        NetworkManager|dhclient|dhcpcd) echo "Network setup (DHCP)" ;;
        chronyd)                       echo "Time sync" ;;
        dnsmasq)                       echo "VM network DNS/DHCP" ;;
        docker-proxy|rootlessport|pasta|pasta.avx2|conmon|slirp4netns) echo "Container port (see the containers check)" ;;
        tailscaled|zerotier-one)       echo "VPN" ;;
        localsend*|LocalSend*)         echo "LocalSend" ;;
        spotify)                       echo "Spotify device discovery" ;;
        smbd|nmbd|samba-dcerpcd|wsdd|wsdd2) [[ "$USE_SHARING" -eq 1 ]] && echo "File sharing (Samba)" || return 1 ;;
        syncthing)                     [[ "$USE_SHARING" -eq 1 ]] && echo "Syncthing" || return 1 ;;
        systemd)
            case "$port" in 22) echo "SSH (socket-activated)" ;; *) return 1 ;; esac ;;
        *) return 1 ;;
    esac
    return 0
}

# _addr_iface ADDRESS — the interface that holds ADDRESS (empty for wildcards).
_addr_iface() {
    case "$1" in 0.0.0.0|::|\*|"") return 0 ;; esac
    ip -o addr show 2>/dev/null | awk -v a="$1" '{ split($4, x, "/"); if (x[1] == a) { print $2; exit } }' || true
}

# _reachable PROTO ADDRESS PORT — true when the firewall lets other devices
# reach this socket on at least one real network interface.
_reachable() {
    local proto="$1" addr="$2" port="$3" ifc z
    _fw_running || return 0
    ifc=$(_addr_iface "${addr%%%*}")
    if [[ -n "$ifc" ]]; then
        _virtual_iface "$ifc" && return 1
        z=$(_fw_zone_of "$ifc")
        _ports_cover "$(_fw_zone_open "$z")" "$port" "$proto"
        return $?
    fi
    while IFS= read -r ifc; do
        [[ -n "$ifc" ]] || continue
        z=$(_fw_zone_of "$ifc")
        _ports_cover "$(_fw_zone_open "$z")" "$port" "$proto" && return 0
    done < <(_lan_ifaces)
    return 1
}

# _listener_zones ADDRESS — the firewall zones that filter traffic to a
# socket on ADDRESS: the zone of the interface holding it, or of every real
# network interface for a wildcard address.
_listener_zones() {
    local ifc z
    local -A seen=()
    ifc=$(_addr_iface "${1%%%*}")
    if [[ -n "$ifc" ]]; then
        _virtual_iface "$ifc" && return 0
        _fw_zone_of "$ifc"; echo
        return 0
    fi
    while IFS= read -r ifc; do
        [[ -n "$ifc" ]] || continue
        z=$(_fw_zone_of "$ifc")
        [[ -n "$z" && -z "${seen[$z]:-}" ]] || continue
        seen["$z"]=1
        printf '%s\n' "$z"
    done < <(_lan_ifaces)
    return 0
}

# _fw_port_entry ENTRY — ENTRY is a single port or a narrow range
# ("8001/tcp", "6000-6010/udp") that a zone can open on its own.
_fw_port_entry() {
    [[ "$1" =~ ^[0-9]+(-[0-9]+)?/(tcp|udp|sctp|dccp)$ ]] && [[ -z "$(_wide_ranges "$1")" ]]
}

# _fw_rich_accepts ZONE PORT PROTO — an accept rich rule of ZONE lets
# PORT/PROTO in (from some or all sources). A rule that names no port and
# no service accepts every port; it counts as covering.
_fw_rich_accepts() {
    local z="$1" port="$2" proto="$3" rule rp rproto svc
    while IFS= read -r rule; do
        [[ "$rule" == *accept* ]] || continue
        if [[ "$rule" =~ port\ port=\"([0-9-]+)\"\ protocol=\"([a-z]+)\" ]]; then
            rp="${BASH_REMATCH[1]}"; rproto="${BASH_REMATCH[2]}"
            _ports_cover "${rp}/${rproto}" "$port" "$proto" && return 0
        elif [[ "$rule" =~ service\ name=\"([A-Za-z0-9_.-]+)\" ]]; then
            svc="${BASH_REMATCH[1]}"
            _ports_cover "$(_fw_service_ports "$svc")" "$port" "$proto" && return 0
        else
            return 0
        fi
    done < <(awk '
        { line = $0; sub(/^[ \t]+/, "", line) }
        /^\t/ { if (in_rich && line != "") print line; next }
        { in_rich = (index(line, "rich rules:") == 1)
          if (in_rich) { v = line; sub(/^rich rules:[ \t]*/, "", v); if (v != "") print v } }' \
        <<< "${_FW_ZONE_ALL[$z]:-}" 2>/dev/null || true)
    return 1
}

# _fw_open_besides ZONE PORT PROTO [ENTRY...] — ZONE still lets PORT/PROTO
# in without the port ENTRYs: through another port entry, a service, a
# whole protocol, an accept-all target or an accept rich rule.
_fw_open_besides() {
    local z="$1" port="$2" proto="$3" e svc p
    shift 3
    local -A skip=()
    for e in "$@"; do skip["$e"]=1; done
    [[ "$(_fw_zone_field "$z" target)" == "ACCEPT" ]] && return 0
    for p in $(_fw_zone_field "$z" protocols); do [[ "$p" == "$proto" ]] && return 0; done
    for svc in $(_fw_zone_field "$z" services); do
        _ports_cover "$(_fw_service_ports "$svc")" "$port" "$proto" && return 0
    done
    for e in $(_fw_zone_field "$z" ports); do
        [[ -n "${skip[$e]:-}" ]] && continue
        _ports_cover "$e" "$port" "$proto" && return 0
    done
    _fw_rich_accepts "$z" "$port" "$proto"
}

# _closable_entries PROTO ADDRESS PORT — the "zone|port/proto" entries that
# let other devices reach this socket. Status 1 when removing them would
# not block it (see _fw_open_besides; wide ranges are the firewall zone
# finding's to fix).
_closable_entries() {
    local proto="$1" addr="$2" port="$3" z e
    local -a out=() mine=()
    _fw_running || return 1
    while IFS= read -r z; do
        [[ -n "$z" ]] || continue
        _fw_zone_load "$z"
        _ports_cover "$(_fw_zone_open "$z")" "$port" "$proto" || _fw_rich_accepts "$z" "$port" "$proto" || continue
        mine=()
        for e in $(_fw_zone_field "$z" ports); do
            _ports_cover "$e" "$port" "$proto" || continue
            _fw_port_entry "$e" || return 1
            mine+=("$e")
        done
        [[ ${#mine[@]} -gt 0 ]] || return 1
        _fw_open_besides "$z" "$port" "$proto" "${mine[@]}" && return 1
        for e in "${mine[@]}"; do out+=("${z}|${e}"); done
    done < <(_listener_zones "$addr")
    [[ ${#out[@]} -gt 0 ]] || return 1
    printf '%s\n' "${out[@]}"
}

# _stale_port_entries — "zone|port/proto" entries the zones of real network
# connections open on their own while nothing listens on them, and whose
# removal would close the port. Ports of apps the firewall zone fix knows
# (Steam, Sunshine, ...) are left out: they only listen while the app runs.
_stale_port_entries() {
    _fw_running || return 0
    local ifc z e item p used proto lport lo eproto
    local -A zseen=() listening=()
    local app_ports="47990/tcp"
    for item in kdeconnect steam sunshine localsend; do
        app_ports+=" $(_fw_item_ports "$item")"
    done
    while IFS=$'\t' read -r proto _ lport _; do
        [[ -n "$lport" ]] && listening["${lport}/${proto}"]=1
    done < <(_listeners)
    while IFS= read -r ifc; do
        [[ -n "$ifc" ]] || continue
        z=$(_fw_zone_of "$ifc")
        [[ -n "$z" && -z "${zseen[$z]:-}" ]] || continue
        zseen["$z"]=1
        _fw_zone_load "$z"
        for e in $(_fw_zone_field "$z" ports); do
            _fw_port_entry "$e" || continue
            [[ "$e" =~ ^([0-9]+)(-[0-9]+)?/([a-z]+)$ ]] || continue
            lo="${BASH_REMATCH[1]}"; eproto="${BASH_REMATCH[3]}"
            [[ "$eproto" == tcp || "$eproto" == udp ]] || continue
            _ports_cover "$app_ports" "$lo" "$eproto" && continue
            used=0
            for p in "${!listening[@]}"; do
                _ports_cover "$e" "${p%/*}" "${p#*/}" && { used=1; break; }
            done
            [[ $used -eq 1 ]] && continue
            # Still open some other way: closing this entry changes nothing.
            _fw_open_besides "$z" "$lo" "$eproto" "$e" && continue
            printf '%s|%s\n' "$z" "$e"
        done
    done < <(_lan_ifaces)
    return 0
}

check_listening_services() {
    if ! _have ss; then
        mark_skip "ss (iproute) is not installed"
        return 0
    fi
    local proto addr port proc pid label entries
    local -a exposed=() blocked=() known=() close=() manual=()
    local llmnr=0
    local -A seen=() close_seen=()
    while IFS=$'\t' read -r proto addr port proc pid; do
        [[ -n "$port" ]] || continue
        [[ -n "${seen[${proto}${port}${proc}]:-}" ]] && continue
        seen["${proto}${port}${proc}"]=1
        if [[ "$proc" == "systemd-resolve" && "$port" == "5355" ]]; then
            llmnr=1
            continue
        fi
        if label=$(_listener_known "$proc" "$port" "$proto"); then
            known+=("${port}/${proto} ${label}")
            continue
        fi
        if _reachable "$proto" "$addr" "$port"; then
            exposed+=("${port}/${proto}  ${proc}${pid:+ (pid ${pid})}  on ${addr}")
            # The fix can close the firewall when the zone opens this port
            # by itself; otherwise the person changes the program (manual).
            if entries=$(_closable_entries "$proto" "$addr" "$port"); then
                local ent
                while IFS= read -r ent; do
                    [[ -n "$ent" && -z "${close_seen[$ent]:-}" ]] || continue
                    close_seen["$ent"]=1
                    close+=("${ent}|${proc}")
                done <<< "$entries"
            else
                manual+=("${port}/${proto}")
            fi
        else
            blocked+=("${port}/${proto}  ${proc}")
        fi
    done < <(_listeners)

    [[ ${#known[@]} -gt 0 ]] && check_note "Expected: $(_join ', ' "${known[@]}")"
    if [[ ${#exposed[@]} -gt 0 ]]; then
        local -a eports=() fixargs=()
        local e after warn=""
        for e in "${exposed[@]}"; do eports+=("${e%%  *}"); done
        if [[ ${#close[@]} -gt 0 ]]; then
            fixargs=(fix_close_ports "${close[@]}")
            warn="other devices lose access|Other devices on your network can no longer connect to the ports you close. Programs on this PC (and containers using host networking) still can."
        fi
        finding "$(_ctx high medium)" "${#exposed[@]} service(s) can be reached from your network" \
"These programs listen on the network and the firewall lets other devices reach them:
$(printf -- '- %s\n' "${exposed[@]}")
Dev servers, databases and debug ports often have no password because they
expect to be used from this PC only." \
"For each one: make it listen on 127.0.0.1 only (e.g. 'npm run dev -- --host 127.0.0.1',
'python -m http.server --bind 127.0.0.1', 'docker run -p 127.0.0.1:5432:5432 ...',
'ports: [\"127.0.0.1:5432:5432\"]' in a compose file), stop it if you don't need it,
or close the port in the firewall: firewall-cmd --permanent --zone=ZONE --remove-port=PORT/tcp
then firewall-cmd --reload (see also the firewall finding)." \
            "${fixargs[@]}"
        if [[ ${#close[@]} -gt 0 && ${#manual[@]} -eq 0 ]]; then
            after="blocked by the firewall; programs on this PC still reach them"
        elif [[ ${#close[@]} -gt 0 ]]; then
            after="firewall closes the ports it opens by itself; $(_join ', ' "${manual[@]}"): listen on 127.0.0.1 only (manual)"
        else
            after="listening on 127.0.0.1 only, or blocked by the firewall (manual)"
        fi
        finding_change "reachable: $(_join ', ' "${eports[@]}")" "$after" "$warn"
    fi
    if [[ ${#blocked[@]} -gt 0 ]]; then
        check_note "Listening but blocked by the firewall: $(_join ', ' "${blocked[@]}")"
    fi

    # Ports opened by hand stay open after the program that needed them is
    # gone; the next program on that port is reachable at once.
    local -a stale=() stale_desc=()
    local s
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        stale+=("${s}|nothing listening now")
        stale_desc+=("${s#*|} (zone '${s%%|*}')")
    done < <(_stale_port_entries)
    if [[ ${#stale[@]} -gt 0 ]]; then
        finding "$(_ctx low info)" "The firewall opens ${#stale[@]} port(s) that nothing uses" \
"These ports are open in the firewall, but no program listens on them now:
$(printf -- '- %s\n' "${stale_desc[@]}")
Whatever starts on one of them later - a dev server, a database - is reachable
from your network at once, without anyone deciding it should be." \
"firewall-cmd --permanent --zone=ZONE --remove-port=PORT/PROTO
firewall-cmd --reload" \
            fix_close_ports "${stale[@]}"
        finding_change "open: $(_join ', ' "${stale_desc[@]}")" "closed (open them again in the Firewall app when you need them)" \
            "other devices lose access|A program you start on one of these ports later is only reachable from this PC until you open the port again."
    fi

    if [[ $llmnr -eq 1 ]]; then
        finding "$(_ctx low info)" "LLMNR name resolution answers on the network" \
"systemd-resolved answers LLMNR queries (port 5355). On untrusted networks,
LLMNR can be abused to trick programs into sending login attempts to an
attacker. mDNS (.local names) keeps working without it." \
"Create /etc/systemd/resolved.conf.d/90-bazzite-sec-audit.conf with:
[Resolve]
LLMNR=no
then: sudo systemctl restart systemd-resolved" \
            fix_llmnr
        finding_change "LLMNR on (systemd-resolved answers on 5355)" "LLMNR=no (mDNS .local names keep working)" \
            "DNS restarts|systemd-resolved restarts; name lookups pause for a moment."
    fi
    return 0
}

# fix_close_ports "ZONE|PORT/PROTO|WHAT"... — remove ports a firewall zone
# opens by itself, now and permanently (the person unticks any to keep).
# No reload: that would also drop other runtime-only changes.
fix_close_ports() {
    local -a items=() pick=()
    local a z e what
    local -A by_tag=()
    for a in "$@"; do
        IFS='|' read -r z e what <<< "$a"
        [[ "$z" =~ ^[A-Za-z0-9_-]+$ ]] && _fw_port_entry "$e" || continue
        items+=("${z}|${e}" "${e} in zone '${z}' (${what})" on)
        by_tag["${z}|${e}"]="$z"
    done
    [[ ${#items[@]} -gt 0 ]] || return 1
    local chosen t
    chosen=$(ui_checklist "Choose the ports to close in the firewall.
Other devices on your network can then no longer connect to them; programs
on this PC still can. Untick a port another device really needs." "${items[@]}") || return 1
    mapfile -t pick <<< "$chosen"

    local script="" undo="" perm rt qz qe
    local -a closed=()
    for t in "${pick[@]}"; do
        [[ -n "$t" && -n "${by_tag[$t]:-}" ]] || continue
        z="${t%%|*}"; e="${t#*|}"
        qz=$(_q "$z"); qe=$(_q "$e")
        perm=0; rt=0
        firewall-cmd --permanent --zone="$z" --query-port="$e" >/dev/null 2>&1 && perm=1
        firewall-cmd --zone="$z" --query-port="$e" >/dev/null 2>&1 && rt=1
        if [[ $rt -eq 1 ]]; then
            script+="firewall-cmd --zone=${qz} --remove-port=${qe}"$'\n'
            undo+="firewall-cmd --zone=${qz} --add-port=${qe}"$'\n'
        fi
        if [[ $perm -eq 1 ]]; then
            script+="firewall-cmd --permanent --zone=${qz} --remove-port=${qe}"$'\n'
            undo+="firewall-cmd --permanent --zone=${qz} --add-port=${qe}"$'\n'
        fi
        [[ $rt -eq 1 || $perm -eq 1 ]] && closed+=("${e} (zone '${z}')")
    done
    [[ ${#closed[@]} -gt 0 ]] || return 1
    CHANGE_AFTER="closed: $(_join ', ' "${closed[@]}")"
    apply_change "${script%$'\n'}" "${undo%$'\n'}" \
        "Open a port again in the Firewall app (firewall-config), or undo this with --undo."
}

fix_llmnr() {
    local f=/etc/systemd/resolved.conf.d/90-bazzite-sec-audit.conf
    apply_change "mkdir -p /etc/systemd/resolved.conf.d
$(_backup_cmd "$f")
printf '[Resolve]\nLLMNR=no\n' > $f
systemctl try-restart systemd-resolved" \
        "$(_restore_cmd "$f")
systemctl try-restart systemd-resolved"
}

# ====================== SSH SERVER ======================
readonly _SSH_DROPIN="/etc/ssh/sshd_config.d/10-bazzite-sec-audit.conf"

_users_with_keys() {
    local u h
    for u in "${REGULAR_USERS[@]}"; do
        h=$(_home_of "$u")
        [[ -s "${h}/.ssh/authorized_keys" ]] && printf '%s\n' "$u"
    done
    return 0
}

check_ssh_server() {
    local -a on=()
    local u
    for u in sshd.service sshd.socket; do
        if [[ "$(_unit_state "$u")" == "enabled" ]] || _unit_active "$u"; then
            on+=("$u")
        fi
    done
    if [[ ${#on[@]} -eq 0 ]]; then
        check_note "The SSH server is off (Bazzite's default)"
        return 0
    fi
    if [[ "$USE_SSH" -ne 1 ]]; then
        finding medium "The SSH server is on, but you don't log in remotely" \
"${on[*]} is enabled or running. You said you don't log in to this PC over SSH,
so it is an open door with no benefit: anyone who learns or guesses a password
of an account on this PC could log in from the network." \
"sudo systemctl disable --now ${on[*]}
(Bazzite: ujust toggle-ssh)" \
            fix_disable_units "${on[@]}"
        local sessions
        sessions=$(_ssh_sessions)
        finding_change "${on[*]}: $(_unit_state "${on[0]}"), $(_unit_active "${on[0]}" && echo running || echo stopped)" \
            "SSH server disabled and stopped" \
            "ends SSH logins|Logging in to this PC over SSH stops working. Sessions that are already open stay connected." \
            "$([[ "$sessions" -gt 0 ]] && echo "${sessions} open SSH connection(s)|${sessions} SSH connection(s) to this PC are open right now. They stay up, but cannot reconnect after this.")"
        return 0
    fi

    local conf root pw kbd empty fails keyusers
    conf=$(sshd -T 2>/dev/null || true)
    if [[ -z "$conf" ]]; then
        mark_skip "sshd -T could not read the effective SSH configuration"
        return 0
    fi
    root=$(awk '$1 == "permitrootlogin" {print $2; exit}' <<< "$conf")
    pw=$(awk '$1 == "passwordauthentication" {print $2; exit}' <<< "$conf")
    kbd=$(awk '$1 == "kbdinteractiveauthentication" {print $2; exit}' <<< "$conf")
    empty=$(awk '$1 == "permitemptypasswords" {print $2; exit}' <<< "$conf")
    fails=$(timeout 20 journalctl -t sshd -t sshd-session --since "-7d" --no-pager -q 2>/dev/null \
        | grep -cE 'Failed password|Invalid user' || true)
    check_note "SSH: root login ${root:-?}, passwords ${pw:-?}; ${fails:-0} failed logins in 7 days"

    if [[ "$empty" == "yes" ]]; then
        finding high "SSH accepts accounts with an empty password" \
"PermitEmptyPasswords is yes." "Set 'PermitEmptyPasswords no' in ${_SSH_DROPIN}" \
            fix_ssh_dropin "PermitEmptyPasswords no"
        finding_change "PermitEmptyPasswords yes" "PermitEmptyPasswords no" \
            "SSH reloads|sshd reloads its settings; open sessions stay connected."
    fi
    if [[ "$root" == "yes" ]]; then
        finding high "SSH allows root to log in with a password" \
"PermitRootLogin is yes. Log in as your own user and use sudo instead." \
"Set 'PermitRootLogin no' in ${_SSH_DROPIN}" \
            fix_ssh_dropin "PermitRootLogin no"
        finding_change "PermitRootLogin yes" "PermitRootLogin no (log in as yourself, then sudo)" \
            "SSH reloads|sshd reloads its settings; open sessions stay connected."
    fi
    if [[ "$pw" == "yes" || "$kbd" == "yes" ]]; then
        keyusers=$(_users_with_keys | paste -sd, - || true)
        local detail="SSH accepts passwords, so it can be brute-forced${fails:+ (${fails} failed attempts in the last 7 days)}. Keys are both safer and more convenient."
        if [[ -n "$keyusers" ]]; then
            local -a nokey=()
            for u in "${REGULAR_USERS[@]}"; do
                [[ ",${keyusers}," == *",${u},"* ]] || nokey+=("$u")
            done
            finding medium "SSH accepts passwords" \
"${detail}
These accounts already have SSH keys set up: ${keyusers}.$([[ ${#nokey[@]} -gt 0 ]] && printf '\nNo key yet (they could no longer log in over SSH after this fix): %s.' "$(_join ', ' "${nokey[@]}")")" \
"Set 'PasswordAuthentication no' and 'KbdInteractiveAuthentication no' in ${_SSH_DROPIN}" \
                fix_ssh_dropin "PasswordAuthentication no" "KbdInteractiveAuthentication no"
            finding_change "PasswordAuthentication ${pw:-?}, KbdInteractiveAuthentication ${kbd:-?}" \
                "both no: SSH keys only (keys set up for: ${keyusers})" \
                "$([[ ${#nokey[@]} -gt 0 ]] && echo "locks out $(_join ', ' "${nokey[@]}")|$(_join ', ' "${nokey[@]}") have no SSH key yet and can no longer log in over SSH after this.")" \
                "SSH reloads|sshd reloads its settings; open sessions stay connected."
        else
            finding medium "SSH accepts passwords" \
"${detail}
No account has ~/.ssh/authorized_keys yet, so password logins are left on to
avoid locking you out - set up a key first." \
"On the computer you connect from:  ssh-keygen -t ed25519 && ssh-copy-id ${DESKTOP_USER:-YOUR_USER}@$(hostname 2>/dev/null)
Then set 'PasswordAuthentication no' in ${_SSH_DROPIN} and run this check again."
            finding_change "PasswordAuthentication ${pw:-?}, no account has an SSH key" "keys only, once a key is set up (manual)"
        fi
    fi
    return 0
}

# _ssh_sessions — number of established connections to the SSH server, on
# the ports it is configured for (sshd -T; 22 when it cannot tell).
_ssh_sessions() {
    _have ss || { echo 0; return 0; }
    local ports
    ports=$(sshd -T 2>/dev/null | awk '$1 == "port" && $2 ~ /^[0-9]+$/ { printf "%s ", $2 }' || true)
    ss -Htn 2>/dev/null | awk -v ports="${ports:-22}" '
        BEGIN { n = split(ports, p, " "); for (i = 1; i <= n; i++) want[p[i]] = 1 }
        $1 == "ESTAB" { port = $4; sub(/^.*:/, "", port); if (port in want) c++ }
        END { print c + 0 }' || echo 0
}

# fix_disable_units UNIT... — stop and disable system units.
fix_disable_units() {
    local q="" u
    for u in "$@"; do q+=" $(_q "$u")"; done
    apply_change "systemctl disable --now${q}" "systemctl enable --now${q}"
}

# fix_ssh_dropin "Directive value"... — set directives in this tool's sshd
# drop-in (read before Fedora's 50-redhat.conf, so it wins), validated with
# sshd -t before reloading.
fix_ssh_dropin() {
    local script line key
    script="$(_backup_cmd "$_SSH_DROPIN")"$'\n'"touch ${_SSH_DROPIN} && chmod 600 ${_SSH_DROPIN}"$'\n'
    for line in "$@"; do
        key="${line%% *}"
        script+="sed -i '/^${key}[[:space:]]/Id' ${_SSH_DROPIN}"$'\n'
        script+="echo '${line}' >> ${_SSH_DROPIN}"$'\n'
    done
    local restore
    restore="$(_restore_cmd "$_SSH_DROPIN" | tr '\n' ';')"
    script+="sshd -t || { ${restore} echo 'sshd -t rejected the change; restored' >&2; exit 1; }"$'\n'
    # An earlier file in sshd_config.d can set the same directive first, and
    # then this drop-in changes nothing: check what sshd will really use.
    script+="eff=\$(sshd -T 2>/dev/null) || eff=''"$'\n'
    script+="[ -n \"\$eff\" ] || { ${restore} echo 'could not read the effective SSH configuration (sshd -T failed); restored' >&2; exit 1; }"$'\n'
    for line in "$@"; do
        script+="grep -qixF -- '${line,,}' <<< \"\$eff\" || { ${restore} echo 'another file in /etc/ssh/sshd_config.d sets ${line%% *} first; restored' >&2; exit 1; }"$'\n'
    done
    script+="systemctl try-reload-or-restart sshd.service"
    apply_change "$script" "$(_restore_cmd "$_SSH_DROPIN")
systemctl try-reload-or-restart sshd.service" \
        "sshd -t checks the new settings and sshd -T confirms that they take effect; otherwise the file is put back as it was."
}
