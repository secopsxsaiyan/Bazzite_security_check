# shellcheck shell=bash
# Flatpak: pending updates, remotes without signature checks, and apps whose
# permissions reach outside their sandbox.

# _flatpak_user_installs — regular users that have their own Flatpak apps.
_flatpak_user_installs() {
    local u h
    for u in "${REGULAR_USERS[@]}"; do
        h=$(_home_of "$u")
        compgen -G "${h}/.local/share/flatpak/app/*" >/dev/null 2>&1 && printf '%s\n' "$u"
    done
    return 0
}

# _flatpak_unverified_remotes — remotes with gpg-verify=false in the OSTree
# repo config on stdin.
_flatpak_unverified_remotes() {
    awk '
        /^\[remote "/ { r = $0; sub(/^\[remote "/, "", r); sub(/"\][ \t]*$/, "", r); next }
        /^\[/ { r = ""; next }
        r != "" && /^[ \t]*gpg-verify[ \t]*=[ \t]*false/ { print r }' 2>/dev/null || true
}

_update_timer_enabled() {
    local t
    for t in "${_UPDATE_TIMERS[@]}"; do
        [[ "$(_unit_state "$t")" == "enabled" ]] && return 0
    done
    return 1
}

check_flatpak() {
    if ! _have flatpak; then
        mark_na "Flatpak is not installed"
        return 0
    fi
    local r u h
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        finding high "Flatpak remote '${r}' is not signature-checked" \
"The system-wide remote '${r}' has gpg-verify=false: apps and updates from it
are installed without checking who published them." \
"flatpak remote-modify --gpg-verify --gpg-import=KEYFILE ${r}
or remove it: flatpak remote-delete ${r}"
        finding_change "remote '${r}': gpg-verify=false" "gpg-verify=true with the publisher's key (manual)"
    done < <([[ -f "$(_r /var/lib/flatpak/repo/config)" ]] && _flatpak_unverified_remotes < "$(_r /var/lib/flatpak/repo/config)")
    for u in "${REGULAR_USERS[@]}"; do
        h=$(_home_of "$u")
        while IFS= read -r r; do
            [[ -n "$r" ]] || continue
            finding high "${u}'s Flatpak remote '${r}' is not signature-checked" \
"The per-user remote '${r}' of ${u} has gpg-verify=false." \
"As ${u}: flatpak remote-modify --user --gpg-verify --gpg-import=KEYFILE ${r}
or: flatpak remote-delete --user ${r}"
            finding_change "remote '${r}' (${u}): gpg-verify=false" "gpg-verify=true with the publisher's key (manual)"
        done < <(_user_cat "$u" "${h}/.local/share/flatpak/repo/config" | _flatpak_unverified_remotes)
    done

    # Pending updates (needs the network; skipped quietly when offline).
    local sys_n=0 out rc=0 total=0 any_ok=0
    local -a users=()
    out=$(timeout 60 flatpak remote-ls --updates --system --columns=application 2>/dev/null) || rc=$?
    if [[ $rc -eq 0 ]]; then
        any_ok=1
        sys_n=$(grep -c . <<< "$out" || true)
    fi
    total=$sys_n
    mapfile -t users < <(_flatpak_user_installs)
    local -a upd_users=()
    for u in "${users[@]}"; do
        rc=0
        out=$(_as_user "$u" timeout 60 flatpak remote-ls --updates --user --columns=application 2>/dev/null) || rc=$?
        [[ $rc -eq 0 ]] || continue
        any_ok=1
        local n
        n=$(grep -c . <<< "$out" || true)
        if [[ "$n" -gt 0 ]]; then
            total=$((total + n))
            upd_users+=("$u")
        fi
    done
    if [[ $any_ok -eq 0 ]]; then
        check_note "Could not check for Flatpak updates (offline?)"
    elif [[ $total -gt 0 ]]; then
        local sev="low" auto=""
        if _update_timer_enabled; then
            sev="info"
            auto=" Automatic updates are on, so they will be installed by the next background update."
        fi
        finding "$sev" "${total} Flatpak update(s) waiting" \
"${total} installed Flatpak apps or runtimes have updates (browsers, Discord,
game launchers and their runtimes get security fixes this way).${auto}" \
"flatpak update" \
            fix_flatpak_update "$sys_n" "${upd_users[@]}"
        finding_change "${total} update(s) waiting (system: ${sys_n}$([[ ${#upd_users[@]} -gt 0 ]] && echo "; per-user: $(_join ', ' "${upd_users[@]}")"))" \
            "all installed Flatpaks up to date" \
            "$W_DOWNLOAD" "$W_NOUNDO" \
            "restart apps|Apps that are running keep their old version until you restart them."
    fi
    return 0
}

# fix_flatpak_update SYSTEM_COUNT USER... — install pending Flatpak updates.
fix_flatpak_update() {
    local sys_n="$1" script="" u
    shift
    [[ "$sys_n" -gt 0 ]] && script+="flatpak update --system -y --noninteractive"$'\n'
    for u in "$@"; do
        script+="runuser -u $(_q "$u") -- flatpak update --user -y --noninteractive"$'\n'
    done
    [[ -n "$script" ]] || return 1
    apply_change "${script%$'\n'}" ""
}

# _flatpak_perm_flags PERMISSIONS OVERRIDES — the ways out of the sandbox
# that the effective permissions (metadata, minus overrides) allow, one per
# line:
#   escape   talks to org.freedesktop.Flatpak (flatpak-spawn --host)
#   bus      the whole session bus (reaches the same service, and more)
#   systemd  talks to systemd --user (can start programs on the host)
#   host     all files, including system folders
_flatpak_perm_flags() {
    awk '
        # Each entry keeps its own mode; a later "!entry" (an override)
        # removes it, a later entry replaces its mode.
        function parse(v, set,    n, a, i, f, mode) {
            n = split(v, a, ";")
            for (i = 1; i <= n; i++) {
                f = a[i]; mode = "rw"
                if (match(f, /:(rw|ro|create|reset)$/)) { mode = substr(f, RSTART + 1); sub(/:(rw|ro|create|reset)$/, "", f) }
                if (f == "") continue
                if (substr(f, 1, 1) == "!") { delete set[substr(f, 2)]; continue }
                set[f] = mode
            }
        }
        function talks(    v) {
            v = substr($0, index($0, "=") + 1)
            return (v == "talk" || v == "own")
        }
        /^\[/ { sec = $0; next }
        sec == "[Context]" && /^filesystems=/ { parse(substr($0, 13), fs) }
        sec == "[Context]" && /^sockets=/ { parse(substr($0, 9), sock) }
        sec == "[Session Bus Policy]" && /^org\.freedesktop\.Flatpak=/ { esc = talks() }
        sec == "[Session Bus Policy]" && /^org\.freedesktop\.systemd1=/ { sysd = talks() }
        END {
            if (esc) print "escape"
            if ("session-bus" in sock) print "bus"
            if (sysd) print "systemd"
            # host includes the home folder; host-os and host-etc (system
            # folders only) do not. ("/" is not a filesystem flatpak accepts.)
            if ("host" in fs) {
                print (fs["host"] != "ro" ? "host" : "hostro")
            } else if (("host-os" in fs) || ("host-etc" in fs)) {
                print "hostos"
            }
        }' "$@" 2>/dev/null || true
}

# _flatpak_flag_text FLAGS — what comma-separated FLAGS let an app do.
_flatpak_flag_text() {
    local -a t=()
    [[ ",$1," =~ ,(escape|bus|systemd), ]] && t+=("can run commands outside the sandbox")
    [[ ",$1," == *,host,* ]] && t+=("can read and change all files, including system folders")
    [[ ",$1," == *,hostro,* ]] && t+=("can read all files, including system folders")
    [[ ",$1," == *,hostos,* ]] && t+=("can read system folders")
    _join '; ' "${t[@]}"
}

# _flatpak_flag_short FLAGS — the same in two or three words, for lists.
_flatpak_flag_short() {
    local -a t=()
    [[ ",$1," =~ ,(escape|bus|systemd), ]] && t+=("host commands")
    [[ ",$1," == *,host,* ]] && t+=("all files")
    [[ ",$1," == *,hostro,* ]] && t+=("reading all files")
    [[ ",$1," == *,hostos,* ]] && t+=("system folders")
    _join ', ' "${t[@]}"
}

# _flatpak_restrict_args FLAGS — flatpak override options that remove FLAGS.
_flatpak_restrict_args() {
    local a=""
    [[ ",$1," == *,escape,* ]] && a+=" --no-talk-name=org.freedesktop.Flatpak"
    [[ ",$1," == *,bus,* ]] && a+=" --nosocket=session-bus"
    [[ ",$1," == *,systemd,* ]] && a+=" --no-talk-name=org.freedesktop.systemd1"
    # All files becomes the home folder: system folders go, the files
    # people open (and downloads, saves, projects) stay reachable.
    [[ ",$1," == *,host,* ]] && a+=" --nofilesystem=host --nofilesystem=host-os --nofilesystem=host-etc --filesystem=home"
    [[ ",$1," == *,hostro,* ]] && a+=" --nofilesystem=host --nofilesystem=host-os --nofilesystem=host-etc --filesystem=home:ro"
    # System folders only: removed, nothing added.
    [[ ",$1," == *,hostos,* ]] && a+=" --nofilesystem=host-os --nofilesystem=host-etc"
    printf '%s' "$a"
}

# _flatpak_break_risk APP FLAGS — how likely restricting APP breaks it:
# "high|why", "medium|why" or "low|why". Apps whose job needs the host
# (managing Flatpaks or containers, IDE terminals, VMs, whole-disk tools,
# game launchers) are high; tools that work with files anywhere (sync,
# transfer, emulators reading games from other drives) and apps this list
# does not know are medium; viewers, players, office apps and browsers,
# which keep the home folder, are low.
_flatpak_break_risk() {
    local app="$1" flags="$2"
    case "$app" in
        io.github.flattool.Warehouse|com.github.tchx84.Flatseal|io.github.flattool.Ignition)
            echo "high|manages other apps" ;;
        com.ranfdev.DistroShelf|io.github.dvlv.boxbuddyrs|io.github.dvlv.BoxBuddy|com.github.marhkb.Pods|io.podman_desktop.PodmanDesktop)
            echo "high|manages host containers" ;;
        com.vysp3r.ProtonPlus|net.davidotek.pupgui2)
            echo "high|writes to launchers' folders" ;;
        it.mijorus.gearlever)
            echo "high|runs AppImages on the host" ;;
        net.nokyan.Resources|io.missioncenter.MissionCenter)
            echo "high|monitors the host" ;;
        com.visualstudio.code|com.vscodium.codium|com.jetbrains.*|dev.zed.Zed|org.gnome.Builder|com.google.AndroidStudio)
            echo "high|terminal runs on the host" ;;
        org.gnome.Boxes|org.virt_manager.virt-manager|org.gnome.GnomeBoxes)
            echo "high|VM images outside home" ;;
        io.github.linx_systems.ClamUI|com.gitlab.davem.ClamTk)
            echo "high|scans the whole disk" ;;
        org.gnome.baobab|org.kde.filelight)
            echo "high|measures the whole disk" ;;
        com.usebottles.bottles|net.lutris.Lutris|com.heroicgameslauncher.hgl|com.valvesoftware.Steam)
            echo "high|starts games from other drives" ;;
        com.nextcloud.desktopclient.nextcloud|com.github.zocker_160.SyncThingy|org.kde.ktorrent|org.qbittorrent.qBittorrent|com.transmissionbt.Transmission|org.filezillaproject.Filezilla|com.gitbutler.gitbutler|io.github.Archeb.opentrace|org.kde.isoimagewriter)
            echo "medium|may use folders outside home" ;;
        org.blender.Blender|org.gimp.GIMP|org.kde.krita|org.inkscape.Inkscape|org.kde.kdenlive|com.obsproject.Studio|org.darktable.Darktable|org.audacityteam.Audacity)
            echo "medium|projects often live outside home" ;;
        org.DolphinEmu.dolphin-emu|org.libretro.RetroArch|org.ppsspp.PPSSPP|io.github.shiiion.primehack|net.kuribo64.melonDS|app.xemu.xemu|com.supermodel3.Supermodel|io.mgba.mGBA|org.scummvm.ScummVM|org.duckstation.DuckStation|net.pcsx2.PCSX2|net.rpcs3.RPCS3|org.ryujinx.Ryujinx|info.cemu.Cemu|org.flycast.Flycast|net.shadps4.shadPS4|org.azahar_emu.Azahar|io.github.ryubing.Ryujinx)
            echo "medium|games on other drives unreachable" ;;
        org.kde.gwenview|org.kde.okular|org.kde.haruna|org.videolan.VLC|io.mpv.Mpv|org.onlyoffice.desktopeditors|org.libreoffice.LibreOffice|net.giuspen.cherrytree|com.brave.Browser|com.google.Chrome|com.microsoft.Edge|org.mozilla.firefox|org.chromium.Chromium|app.grayjay.Grayjay)
            if [[ ",$flags," =~ ,(escape|bus|systemd), ]]; then
                echo "medium|host commands stop working"
            else
                echo "low|keeps your home folder"
            fi ;;
        *)
            if [[ ",$flags," =~ ,(escape|bus|systemd), ]]; then
                echo "medium|unknown app, runs host commands"
            else
                echo "medium|unknown app, test after"
            fi ;;
    esac
}

check_flatpak_sandbox() {
    if ! _have flatpak; then
        mark_na "Flatpak is not installed"
        return 0
    fi
    local app inst flags u tdir tmp1 tmp2
    local -a lines=() items=()
    tdir=$(mktemp -d "${RUN_TMP:-${TMPDIR:-/tmp}}/flatpak.XXXXXX") || { mark_skip "could not create a temporary folder"; return 0; }
    tmp1="$tdir/perms"; tmp2="$tdir/overrides"
    # System apps, then each user's own apps.
    {
        flatpak list --system --app --columns=application 2>/dev/null | sed 's/^/system\t/' || true
        for u in $(_flatpak_user_installs); do
            _as_user "$u" flatpak list --user --app --columns=application 2>/dev/null | sed "s/^/${u}\t/" || true
        done
    } > "$tdir/list"
    while IFS=$'\t' read -r inst app; do
        [[ -n "$app" && "$app" != "Application ID" ]] || continue
        if [[ "$inst" == "system" ]]; then
            flatpak info --system --show-permissions "$app" > "$tmp1" 2>/dev/null || continue
            flatpak override --system --show "$app" > "$tmp2" 2>/dev/null || : > "$tmp2"
            # The desktop user's own overrides (Flatseal) apply on top.
            [[ -n "$DESKTOP_USER" ]] && _as_desktop_user flatpak override --user --show "$app" >> "$tmp2" 2>/dev/null
        else
            _as_user "$inst" flatpak info --user --show-permissions "$app" > "$tmp1" 2>/dev/null || continue
            _as_user "$inst" flatpak override --user --show "$app" > "$tmp2" 2>/dev/null || : > "$tmp2"
        fi
        flags=$(_flatpak_perm_flags "$tmp1" "$tmp2" | paste -sd, - || true)
        [[ -n "$flags" ]] || continue
        lines+=("${app}$([[ $inst != system ]] && echo " (${inst})"): $(_flatpak_flag_text "$flags")")
        items+=("${inst}|${app}|${flags}")
    done < "$tdir/list"
    rm -rf -- "$tdir"

    if [[ ${#items[@]} -gt 0 ]]; then
        finding low "${#items[@]} Flatpak app(s) are not really sandboxed" \
"These apps have permissions that bypass the Flatpak sandbox:
$(printf -- '- %s\n' "${lines[@]}")
That is normal for some tools (IDEs that open a host terminal, some launchers),
but it means a bug or malicious update in them has the same reach as a native
program. Restrict the ones that don't need it." \
"Review with Flatseal, or per app:
flatpak override --nofilesystem=host --filesystem=home --no-talk-name=org.freedesktop.Flatpak APP_ID
(and --nosocket=session-bus / --no-talk-name=org.freedesktop.systemd1 where listed)" \
            fix_flatpak_restrict "${items[@]}"
        finding_change "${#items[@]} app(s) can leave the sandbox" "the apps you pick keep your home folder but lose system folders and host commands" \
            "apps may break|An app that really needs the permission (an IDE terminal that must reach the host, a launcher that starts host programs) stops working until you undo the change or allow it again in Flatseal."
        finding_affects \
            "flatpak_apps?|The apps you pick lose access to system folders and host commands. A launcher, emulator or IDE that needs them may stop working until you undo the change or allow it in Flatseal."
    fi
    return 0
}

# fix_flatpak_restrict INST|APP|FLAGS... — restrict the apps the person
# picks. Each app is graded by how likely the change breaks it; the list is
# pre-selected with the low-risk ones, all of them, or none.
fix_flatpak_restrict() {
    local -a list=() pick=() order=()
    local e inst app flags risk why grade label preset w nlow=0
    local -A risk_of=() why_of=()
    for e in "$@"; do
        IFS='|' read -r inst app flags <<< "$e"
        [[ "$app" =~ ^[A-Za-z0-9._-]+$ ]] || continue
        IFS='|' read -r risk why <<< "$(_flatpak_break_risk "$app" "$flags")"
        risk_of["$e"]="$risk"; why_of["$e"]="$why"
        [[ "$risk" == low ]] && nlow=$((nlow + 1))
    done
    # Least likely to break first.
    for grade in low medium high; do
        for e in "$@"; do [[ "${risk_of[$e]:-}" == "$grade" ]] && order+=("$e"); done
    done
    [[ ${#order[@]} -gt 0 ]] || return 1
    # The Kirigami chooser has Select all / none / low risk only itself.
    preset=low
    _qml_ok || preset=$(ui_radiolist "<html><p>${#order[@]} apps can be restricted. Each is graded by how likely the change breaks it:</p>
<p><b>low</b> - keeps your home folder; files elsewhere open through the file chooser<br>
<b>medium</b> - may lose folders or host commands it uses<br>
<b>high</b> - its job needs the host; it will probably stop working</p>
<p>Which apps should be selected to start with? You can change each one next.</p></html>" \
        low "Low-risk apps only (${nlow}) - recommended" on \
        all "All ${#order[@]} apps" off \
        none "None - I will pick them myself" off) || return 1
    for e in "${order[@]}"; do
        IFS='|' read -r inst app flags <<< "$e"
        risk="${risk_of[$e]}"
        case "$risk" in
            low)
                if [[ ",$flags," == *,host,* ]]; then
                    w="Keeps your home folder; files elsewhere open through the file chooser."
                elif [[ ",$flags," == *,hostro,* ]]; then
                    w="Keeps reading your home folder; files elsewhere open through the file chooser."
                elif [[ ",$flags," == *,hostos,* ]]; then
                    w="Loses only system folders (/usr, /etc); its access to your files does not change."
                else
                    w="Loses only host commands and system services it should not need."
                fi ;;
            medium) w="May lose folders or host commands it uses (${why_of[$e]}). Undo it or allow them again in Flatseal if it does." ;;
            *)      w="Its job needs the host (${why_of[$e]}): it will probably stop working after this." ;;
        esac
        label=$(ui_item "${app}$([[ $inst != system ]] && echo " (${inst})")" "${why_of[$e]} · removes: $(_flatpak_flag_short "$flags")" "$risk" "$w")
        case "$preset" in
            all) list+=("$e" "$label" on) ;;
            none) list+=("$e" "$label" off) ;;
            *) list+=("$e" "$label" "$([[ $risk == low ]] && echo on || echo off)") ;;
        esac
    done
    mapfile -t pick < <(UI_CHOOSE_TITLE="Which apps should lose these permissions?" ui_checklist "<html><p>Which apps should lose these permissions?</p>
<p><b>All files</b> becomes your home folder; <b>host commands</b> are removed.<br>
Selected apps are restricted. Undo later, or change single apps in Flatseal.</p></html>" "${list[@]}") || return 1
    [[ ${#pick[@]} -gt 0 && -n "${pick[0]}" ]] || return 1
    local -a high=()
    for e in "${pick[@]}"; do
        [[ "${risk_of[$e]:-}" == high ]] && { IFS='|' read -r inst app flags <<< "$e"; high+=("$app"); }
    done
    [[ ${#high[@]} -gt 0 ]] && CHANGE_WARN+=("likely to break|These apps need the host for their job and will probably stop working: $(_join ', ' "${high[@]}"). Undo the change if they do.")
    local script="" undo="" scope ofile args home owner
    local -a names=()
    for e in "${pick[@]}"; do
        IFS='|' read -r inst app flags <<< "$e"
        args=$(_flatpak_restrict_args "$flags")
        if [[ "$inst" == "system" ]]; then
            ofile="/var/lib/flatpak/overrides/${app}"
            scope="flatpak override --system"
            owner=""
        else
            home=$(_home_of "$inst")
            ofile="${home}/.local/share/flatpak/overrides/${app}"
            scope="runuser -u $(_q "$inst") -- flatpak override --user"
            owner="$inst"
        fi
        script+="$(_backup_cmd "$ofile" "$owner")"$'\n'"${scope}${args} $(_q "$app")"$'\n'
        undo+="$(_restore_cmd "$ofile" "$owner")"$'\n'
        # A system app the desktop user also overrides (Flatseal): user
        # overrides win, so the same restriction goes there too.
        if [[ "$inst" == "system" && -n "$DESKTOP_USER" ]]; then
            local uof
            uof="$(_home_of "$DESKTOP_USER")/.local/share/flatpak/overrides/${app}"
            if _as_desktop_user test -f "$uof"; then
                script+="$(_backup_cmd "$uof" "$DESKTOP_USER")"$'\n'"runuser -u $(_q "$DESKTOP_USER") -- flatpak override --user${args} $(_q "$app")"$'\n'
                undo+="$(_restore_cmd "$uof" "$DESKTOP_USER")"$'\n'
            fi
        fi
        if [[ "$inst" == "system" ]]; then names+=("$app"); else names+=("${app} (${inst})"); fi
    done
    CHANGE_AFTER="restricted: $(_join ', ' "${names[@]}")"
    apply_change "${script%$'\n'}" "${undo%$'\n'}" "Restart the apps for this to take effect."
}
