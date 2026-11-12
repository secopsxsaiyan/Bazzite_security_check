# shellcheck shell=bash
# What each finding's fix can affect, and settings kept on purpose.
#
# A check names the Bazzite features a finding (and its fix) touches with
# finding_affects, each as "KEY|what changes for it". KEY may end in a mark
# for how the fix touches the feature:
#   KEY!  the fix stops the feature (a fix like that starts unticked when
#         this PC uses the feature, and the finding can be kept on purpose)
#   KEY?  the fix asks what to keep for it
#   KEY+  the fix is what the feature needs
#   KEY~  the fix leaves it as it is (manual steps would change it)
#   KEY   the fix changes how the feature works
# Every place that shows a finding - the fix list, the Apply dialog, a
# check's page, the dashboard row, the report - then says which features are
# affected and whether this PC uses them ("in use here: ..."), so the person
# can decide whether to touch the setting. Only a fix marked "!" for a
# feature in use starts unticked.
#
# A finding can be kept on purpose ("I use this"): it is then listed as
# kept, does not lower the score and offers no fix. The choices
# are in KEPT_FILE (root only), one finding per line:
#   CHECK_ID<TAB>KEY<TAB>DATE<TAB>FEATURES<TAB>SEVERITY
# KEY is the finding's title with numbers replaced by "#", so "3 day(s)"
# and "4 day(s)" are the same finding, followed by the evidence a check
# gave with finding_keep_key (its ports): a kept entry covers the finding
# while every port it reports is among the kept ones - a kept port that is
# closed this run is still covered, a port that opens later is not. A kept finding counts
# again when it gets more severe than when it was kept. Lines without a
# severity (written before it was stored) never count again that way.

# Feature names, for the person.
declare -grA FEATURE_NAME=(
    [remote_play]="Steam Remote Play and LAN game transfers"
    [sunshine]="Sunshine game streaming (Moonlight)"
    [kdeconnect]="KDE Connect"
    [ssh]="SSH logins to this PC"
    [sharing]="File sharing (Samba, Syncthing, LocalSend)"
    [discovery]="Finding printers and devices (mDNS)"
    [local_names]="Finding this PC by name from Windows PCs"
    [game_server]="Game servers you host"
    [docker]="Docker"
    [containers]="Containers you run"
    [performance]="Game performance"
    [anticheat]="Games with Easy Anti-Cheat"
    [lockdown]="Hibernation and unsigned kernel modules"
    [couch]="Controller-only play and watching videos"
    [dev_tools]="Developer tools and scripts"
    [flatpak_apps]="Flatpak apps"
)

KEPT_FILE=""                    # set once STATE_DIR is ready (see kept_load)
declare -gA KEPT=()             # "CHECK<TAB>KEY" -> "DATE<TAB>FEATURES"
declare -ga F_AFFECT=()         # per finding: "KEY|sentence" lines
declare -ga F_KEYX=()           # per finding: evidence that is part of its kept key
declare -gA _FEATURE_SEEN=()    # cache: KEY -> "in<TAB>why", "out" or "unknown<TAB>hint"

# finding_affects KEY|SENTENCE... — for the finding just added: the features
# its fix (or the manual steps) affect, and what changes for each. Unknown
# keys are ignored; each key once.
finding_affects() {
    local i=$(( ${#F_SEV[@]} - 1 )) a key
    (( i >= 0 )) || return 0
    for a in "$@"; do
        key="${a%%|*}"; key="${key%[+?!~]}"
        [[ -n "$key" && -n "${FEATURE_NAME[$key]:-}" && "$a" == *"|"* ]] || continue
        [[ $'\n'"${F_AFFECT[i]:-}" =~ $'\n'"${key}"[+?!~]?\| ]] && continue
        F_AFFECT[i]+="${F_AFFECT[i]:+$'\n'}${a//$'\n'/ }"
    done
    return 0
}

# finding_keep_key EVIDENCE... — for the finding just added: what it is
# about (ports, ...). Kept on purpose then covers exactly this evidence.
finding_keep_key() {
    local i=$(( ${#F_SEV[@]} - 1 ))
    (( i >= 0 )) || return 0
    F_KEYX[i]=$(printf '%s\n' "$@" | tr -d '\t\r' | sed 's/  .*//' | grep -v '^$' | sort -u | paste -sd, -)
    return 0
}

# _steam_installed — Steam (native, Bazzite's, or the Flatpak) is installed.
_steam_installed() {
    _have steam || _have bazzite-steam || _flatpak_installed com.valvesoftware.Steam
}

# _feature_detect KEY — print why this PC uses feature KEY (status 0), or
# status 1 when it does not look set up, or status 2 when this cannot be
# told from here.
_feature_detect() {
    case "$1" in
        remote_play)
            # Steam is on every Bazzite image; that alone does not mean
            # Remote Play is used (the setup's game streaming answer does).
            _steam_installed && { echo "Steam is installed"; return 2; } ;;
        anticheat)
            _steam_installed && { echo "Steam is installed"; return 0; } ;;
        performance|couch)
            _steam_installed && { echo "Steam is installed"; return 0; }
            [[ -n "${DETECTED[gaming]:-}" ]] && { echo "${DETECTED[gaming]}"; return 0; } ;;
        sunshine)
            if [[ -n "$DESKTOP_USER" ]] && _sunshine_installed "$DESKTOP_USER"; then
                if _sunshine_enabled "$DESKTOP_USER"; then echo "Sunshine is installed and set to start"
                else echo "Sunshine is installed"; fi
                return 0
            fi ;;
        kdeconnect)
            { _have kdeconnectd || [[ -x /usr/libexec/kdeconnectd ]] || pgrep -x kdeconnectd >/dev/null 2>&1; } \
                && { echo "KDE Connect is installed"; return 0; } ;;
        ssh)
            # The server being on is not use; keys someone can log in with are.
            local h
            for h in /root /var/home/* /home/*; do
                [[ -s "$h/.ssh/authorized_keys" && ! -L "$h/.ssh/authorized_keys" ]] \
                    && { echo "${h##*/} has keys for SSH logins (authorized_keys)"; return 0; }
            done ;;
        sharing)
            [[ -n "${DETECTED[sharing]:-}" ]] && { echo "${DETECTED[sharing]}"; return 0; }
            _flatpak_installed org.localsend.localsend_app && { echo "LocalSend is installed"; return 0; } ;;
        discovery)
            _unit_active avahi-daemon.service && { echo "avahi-daemon is running"; return 0; } ;;
        docker)
            { _have docker || [[ -S /run/docker.sock ]]; } && { echo "Docker is installed"; return 0; } ;;
        containers)
            { _have docker || [[ -S /run/docker.sock ]]; } && { echo "Docker is installed"; return 0; }
            if [[ -n "${DESKTOP_HOME:-}" ]] && compgen -G "${DESKTOP_HOME}/.local/share/containers/storage/overlay-containers/*" >/dev/null 2>&1; then
                echo "you have Podman or Distrobox containers"; return 0
            fi ;;
        lockdown)
            grep -qw 'resume=[^ ]*' /proc/cmdline 2>/dev/null && { echo "hibernation is set up"; return 0; }
            { _have dkms || compgen -G '/etc/akmods/*' >/dev/null 2>&1; } && { echo "kernel modules are built on this PC (DKMS/akmods)"; return 0; } ;;
        dev_tools)
            [[ -n "${DETECTED[dev]:-}" ]] && { echo "${DETECTED[dev]}"; return 0; } ;;
        flatpak_apps)
            echo "the apps listed are installed"; return 0 ;;
        local_names|game_server)
            return 2 ;;
    esac
    return 1
}

# _feature_use KEY — the use case of the wizard that covers feature KEY.
_feature_use() {
    case "$1" in
        remote_play|sunshine) [[ "$USE_STREAMING" -eq 1 ]] && echo "game streaming" ;;
        ssh) [[ "$USE_SSH" -eq 1 ]] && echo "SSH" ;;
        sharing) [[ "$USE_SHARING" -eq 1 ]] && echo "file sharing" ;;
        docker|containers|dev_tools) [[ "$USE_DEV" -eq 1 ]] && echo "development" ;;
        # Not game_server: gaming is the default answer and says nothing
        # about hosting a server.
        performance|anticheat|couch) [[ "$USE_GAMING" -eq 1 ]] && echo "gaming" ;;
    esac
    return 0
}

# feature_status KEY — "in<TAB>why" (this PC uses it), "out" (not set up
# here) or "unknown<TAB>hint" (cannot be told). Cached for the run.
feature_status() {
    local key="$1" why rc use
    if [[ -z "${_FEATURE_SEEN[$key]:-}" ]]; then
        why=$(_feature_detect "$key"); rc=$?
        use=$(_feature_use "$key")
        if [[ $rc -eq 0 ]]; then
            _FEATURE_SEEN["$key"]="in"$'\t'"${why}"
        elif [[ -n "$use" ]]; then
            _FEATURE_SEEN["$key"]="in"$'\t'"you chose ${use} in the setup"
        elif [[ $rc -eq 2 ]]; then
            _FEATURE_SEEN["$key"]="unknown"$'\t'"${why}"
        else
            _FEATURE_SEEN["$key"]="out"
        fi
    fi
    printf '%s' "${_FEATURE_SEEN[$key]}"
}

# _affect_key ENTRY / _affect_mark ENTRY — the feature key of a
# finding_affects entry, and its mark ("!", "?", "+" or empty).
_affect_key() { local k="${1%%|*}"; printf '%s' "${k%[+?!~]}"; }
_affect_mark() { local k="${1%%|*}"; [[ "$k" == *[+?!~] ]] && printf '%s' "${k: -1}"; return 0; }

# _affects_in_use I — finding I's fix stops a feature this PC uses.
_affects_in_use() {
    local a
    while IFS= read -r a; do
        [[ -n "$a" && "$(_affect_mark "$a")" == "!" ]] || continue
        [[ "$(feature_status "$(_affect_key "$a")")" == in* ]] && return 0
    done <<< "${F_AFFECT[$1]:-}"
    return 1
}

# _affects_maybe_in_use I — finding I's fix stops a feature this PC uses or
# may use (it cannot be told, as with Steam's Remote Play): such a problem
# can be kept on purpose, though its fix is not unticked.
_affects_maybe_in_use() {
    local a st
    while IFS= read -r a; do
        [[ -n "$a" && "$(_affect_mark "$a")" == "!" ]] || continue
        st=$(feature_status "$(_affect_key "$a")")
        [[ "$st" == in* || "$st" == unknown* ]] && return 0
    done <<< "${F_AFFECT[$1]:-}"
    return 1
}

# affects_list I — finding I's affected features, those in use first, one
# per line: "KEY<TAB>NAME<TAB>STATUS<TAB>WHY<TAB>MARK<TAB>SENTENCE" (STATUS
# in, out or unknown; WHY "-" when there is none; MARK "!", "?", "+", "~"
# or "-"). No field is empty: "read" with a tab IFS would merge empty ones.
affects_list() {
    local a key st why mark
    while IFS= read -r a; do
        [[ -n "$a" ]] || continue
        key=$(_affect_key "$a"); mark=$(_affect_mark "$a")
        st=$(feature_status "$key")
        why=""; [[ "$st" == *$'\t'* ]] && why="${st#*$'\t'}"; why="${why//$'\t'/ }"
        st="${st%%$'\t'*}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$([[ $st == in ]] && echo 0 || { [[ $st == unknown ]] && echo 1 || echo 2; })" \
            "$key" "${FEATURE_NAME[$key]}" "$st" "${why:--}" "${mark:--}" "${a#*|}"
    done <<< "${F_AFFECT[$1]:-}" | sort -n -k1,1 -s | cut -f2-
}

# _mark_text MARK — how the fix touches the feature, for the person.
_mark_text() {
    case "$1" in
        "!") echo "stops it" ;; "?") echo "you choose in the fix" ;; "+") echo "helps it" ;;
        "~") echo "left as it is" ;; *) echo "changes it" ;;
    esac
}

# _affect_status_text STATUS WHY — how the person reads a feature's status.
_affect_status_text() {
    case "$1" in
        in) echo "in use here: $2" ;;
        unknown) if [[ -n "$2" && "$2" != "-" ]]; then echo "$2 - whether you use it can't be told; you know best"
                 else echo "can't be told from here - you know best"; fi ;;
        *) echo "not set up on this PC" ;;
    esac
}

# affects_tags I — short tags for the fix list: the features in use the
# fix stops ("Sunshine game streaming (Moonlight)").
affects_tags() {
    local key name st why mark s out=""
    while IFS=$'\t' read -r key name st why mark s; do
        [[ "$st" == in && "$mark" == "!" ]] && out+="${out:+, }${name}"
    done < <(affects_list "$1")
    printf '%s' "$out"
}

# affects_html I — "What this affects" for dialogs (rich text).
affects_html() {
    local key name st why mark s col h="" rest=""
    while IFS=$'\t' read -r key name st why mark s; do
        [[ -n "$key" ]] || continue
        if [[ "$st" == out ]]; then
            rest+="${rest:+, }$(_html "$name")"
            continue
        fi
        col="$C_INFO"; [[ "$st" == in && "$mark" == "!" ]] && col="$C_MEDIUM"
        h+="<li><b>$(_html "$name")</b> - $(_html "$(_mark_text "$mark")") <font color=\"${col}\">($(_html "$(_affect_status_text "$st" "$why")"))</font><br>$(_html "$s")</li>"
    done < <(affects_list "$1")
    [[ -n "$h$rest" ]] || return 0
    printf '<p><b>What this affects on Bazzite:</b></p><ul>%s%s</ul>' "$h" \
        "$([[ -n $rest ]] && printf '<li><i>Also touches, not set up on this PC: %s</i></li>' "$rest")"
}

# affects_text I — the same as plain lines "NAME (status): sentence".
affects_text() {
    local key name st why mark s
    while IFS=$'\t' read -r key name st why mark s; do
        [[ -n "$key" ]] && printf '%s - %s (%s): %s\n' "$name" "$(_mark_text "$mark")" "$(_affect_status_text "$st" "$why")" "$s"
    done < <(affects_list "$1")
}

# _ports_affects MARK SENTENCE PORT/PROTO... — finding_affects arguments for
# the features known ports belong to (each once), with MARK and SENTENCE.
_ports_affects() {
    local m="$1" s="$2" p n key
    local -A seen=()
    shift 2
    for p in "$@"; do
        p="${p%% *}"; n="${p%%/*}"; n="${n%%-*}"
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        key=""
        if   (( n >= 27031 && n <= 27040 )); then key=remote_play
        elif (( n >= 47984 && n <= 48010 && n != 47990 )); then key=sunshine   # 47990: admin page, not streaming
        elif (( n >= 1714 && n <= 1764 ));   then key=kdeconnect
        elif (( n == 22 ));                  then key=ssh
        elif (( n == 445 || n == 139 || n == 53317 || n == 22000 || n == 21027 )); then key=sharing
        elif (( n == 5353 ));                then key=discovery
        elif (( n == 25565 || n == 19132 || n == 2456 || n == 2457 || n == 7777 || n == 27015 || n == 27016 )); then key=game_server
        fi
        [[ -n "$key" && -z "${seen[$key]:-}" ]] || continue
        seen["$key"]=1
        printf '%s%s|%s\n' "$key" "$m" "$s"
    done
}

# ====================== KEPT ON PURPOSE ======================
# _finding_key TITLE — the stable part of a finding's title. Numbers become
# "#", so two findings of one check whose titles differ only in numbers
# share a key; checks that can report such findings separately give
# evidence with finding_keep_key (the ports) to tell them apart.
_finding_key() {
    local t="${1//$'\t'/ }"
    t="${t//$'\n'/ }"
    sed -E 's/[0-9]+/#/g' <<< "$t"
}

# kept_load — read the kept findings (once STATE_DIR exists).
kept_load() {
    KEPT=()
    KEPT_FILE="${STATE_DIR}/kept"
    [[ -f "$KEPT_FILE" && ! -L "$KEPT_FILE" ]] || return 0
    local c k d f v line
    # Fields may be empty; tab is whitespace to "read", which would merge
    # them, so split on a non-whitespace separator.
    while IFS= read -r line; do
        IFS=$'\x1f' read -r c k d f v <<< "${line//$'\t'/$'\x1f'}"
        [[ "$c" =~ ^check_[a-z0-9_]+$ && -n "$k" ]] || continue
        [[ "$v" =~ ^(high|medium|low)$ ]] || v=""
        KEPT["${c}"$'\t'"${k}"]="${d}"$'\t'"${f}"$'\t'"${v}"
    done < "$KEPT_FILE"
    return 0
}

# _kept_key I — finding I's key in the kept file (without the check id).
_kept_key() {
    local k
    k=$(_finding_key "${F_TITLE[$1]}")
    [[ -n "${F_KEYX[$1]:-}" ]] && k+=" [${F_KEYX[$1]}]"
    printf '%s' "$k"
}

# _kept_entry I — "DATE<TAB>FEATURES<TAB>SEVERITY" when finding I is kept.
_kept_entry() {
    local k
    k=$(_kept_match "$1") || return 1
    printf '%s' "${KEPT[$k]}"
}

# _orig_sev I — finding I's own severity (before keeping made it a note).
_orig_sev() { printf '%s' "${F_KEPT_SEV[$1]:-${F_SEV[$1]}}"; }

# _sev_allows STORED SEV — a problem kept at STORED severity stays kept at
# SEV (not more severe; no STORED: always).
_sev_allows() { [[ -z "$1" ]] || (( $(_sev_rank "$2") >= $(_sev_rank "$1") )); }

# _kept_related I — the kept entries about finding I, one per line as
# "cover<TAB>KEY" (it covers every port the finding reports now) or
# "sub<TAB>KEY" (its ports are all among the finding's, so it is about the
# same problem but does not cover it). Without evidence: the exact key.
_kept_related() {
    [[ ${#KEPT[@]} -gt 0 ]] || return 0
    local base k list cur p cover sub
    base="${F_CHECK[$1]}"$'\t'"$(_finding_key "${F_TITLE[$1]}")"
    if [[ -z "${F_KEYX[$1]:-}" ]]; then
        [[ -n "${KEPT[$base]:-}" ]] && printf 'cover\t%s\n' "$base"
        return 0
    fi
    cur=",${F_KEYX[$1]},"
    for k in "${!KEPT[@]}"; do
        [[ "$k" == "$base ["*"]" ]] || continue
        list="${k#"$base ["}"; list=",${list%]},"
        cover=1; sub=1
        for p in ${F_KEYX[$1]//,/ }; do [[ "$list" == *",${p},"* ]] || { cover=0; break; }; done
        for p in ${list//,/ }; do [[ "$cur" == *",${p},"* ]] || { sub=0; break; }; done
        if (( cover )); then printf 'cover\t%s\n' "$k"
        elif (( sub )); then printf 'sub\t%s\n' "$k"; fi
    done
    return 0
}

# _kept_match I — a kept entry that covers finding I at its severity now
# (any of them: one that allows it is enough).
_kept_match() {
    local kind k v sev
    sev=$(_orig_sev "$1")
    while IFS=$'\t' read -r kind k; do
        [[ "$kind" == cover && -n "$k" ]] || continue
        v="${KEPT[$k]##*$'\t'}"
        _sev_allows "$v" "$sev" && { printf '%s' "$k"; return 0; }
    done < <(_kept_related "$1")
    return 1
}


# kept_apply — turn the findings kept on purpose into notes: they no longer
# lower the score, offer no fix and say since when they are kept. Run after
# the checks (and again after the kept list changes).
kept_apply() {
    local i e d f a
    # Detect the features the findings affect once, in this shell, so the
    # lists drawn later (often in subshells) reuse the result.
    for i in "${!F_AFFECT[@]}"; do
        while IFS= read -r a; do
            [[ -n "$a" ]] && feature_status "$(_affect_key "$a")" >/dev/null
        done <<< "${F_AFFECT[$i]}"
    done
    local v
    for i in "${!F_SEV[@]}"; do
        [[ "${F_STATE[$i]}" == "open" && "${F_SEV[$i]}" != "info" ]] || continue
        # Kept by an entry that allows its severity now (one kept at a
        # milder severity does not count; it is worse now).
        e=$(_kept_entry "$i") || continue
        d="${e%%$'\t'*}"; e="${e#*$'\t'}"; f="${e%%$'\t'*}"; v="${e#*$'\t'}"
        F_KEPT_SEV[i]="${F_SEV[$i]}"
        F_KEPT_FROM[i]="$v"
        F_SEV[i]="info"
        F_FIX[i]=""
        F_STATE[i]="kept"
        F_DETAIL[i]="Kept on purpose since ${d}${f:+ (for ${f})}: this does not lower the score. Change it under \"Kept on purpose\" on the dashboard."$'\n'"${F_DETAIL[$i]}"
    done
    _kept_recount
}

# _kept_recount — a check whose only findings are kept or info no longer
# counts as failed.
_kept_recount() {
    local id i bad
    for id in "${!CHECK_FAILED[@]}"; do
        bad=0
        for i in "${!F_CHECK[@]}"; do
            [[ "${F_CHECK[$i]}" == "$id" && "${F_SEV[$i]}" != "info" ]] && { bad=1; break; }
        done
        if (( ! bad )); then
            unset 'CHECK_FAILED[$id]'
            [[ "${CHECK_STATUS[$id]:-}" == "fail" ]] && CHECK_STATUS["$id"]="pass"
        fi
    done
    return 0
}

declare -ga F_KEPT_SEV=()       # the severity a kept finding had
declare -ga F_KEPT_FROM=()      # the severity it was kept at (from the file)

# _keep_candidates — findings that can be kept: open problems whose fix
# affects a feature this PC uses, and the findings kept already. Prints
# "INDEX<TAB>on|off".
_keep_candidates() {
    local i
    for i in "${!F_SEV[@]}"; do
        if [[ "${F_STATE[$i]}" == "kept" ]]; then
            # Ticked from the file, not the run: a problem unticked earlier
            # in this session stays unticked.
            if _kept_match "$i" >/dev/null; then printf '%s\ton\n' "$i"; else printf '%s\toff\n' "$i"; fi
        elif [[ "${F_STATE[$i]}" == "open" && "${F_SEV[$i]}" != "info" && "${F_VERIFY[$i]}" != "gone" ]] \
             && _affects_maybe_in_use "$i"; then
            printf '%s\toff\n' "$i"
        fi
    done
}

# kept_offered — there is something to keep (or kept already).
kept_offered() { [[ -n "$(_keep_candidates)" ]]; }

# kept_count — how many findings are kept on purpose (as the kept list
# would tick them: one unticked in this session no longer counts).
kept_count() {
    _keep_candidates | grep -c $'\ton$' || true
}

# _kept_features I — the features in use (or maybe in use) that finding I's
# fix stops, for the list and the file.
_kept_features() {
    local key name st why mark s out=""
    while IFS=$'\t' read -r key name st why mark s; do
        [[ ( "$st" == in || "$st" == unknown ) && "$mark" == "!" ]] && out+="${out:+, }${name}"
    done < <(affects_list "$1")
    printf '%s' "${out//$'\t'/ }"
}

# manage_kept — tick the findings to keep on purpose; untick to count them
# again. Saved for the next check. Kept entries of checks that did not run
# this time stay as they are.
manage_kept() {
    local -a items=() picked=() rows=() offered=()
    local i on row feats kind k was
    while IFS=$'\t' read -r i on; do
        [[ -n "$i" ]] || continue
        row="$(_sev_label "$(_orig_sev "$i")") · ${F_TITLE[$i]//$'\n'/ }"
        feats=$(_kept_features "$i")
        [[ -n "$feats" ]] && row+="  —  for: ${feats}"
        # Kept before at a milder level: say why it is unticked now.
        if [[ "$on" == off && "${F_STATE[$i]}" == open ]]; then
            while IFS=$'\t' read -r kind k; do
                [[ "$kind" == cover && -n "$k" ]] || continue
                was="${KEPT[$k]##*$'\t'}"
                [[ -n "$was" ]] && { row+="  (kept before at $(_sev_label "$was"), worse now - tick to keep it again)"; break; }
            done < <(_kept_related "$i")
        fi
        items+=("$i" "$row" "$on")
        offered+=("$i")
    done < <(_keep_candidates)
    if [[ ${#items[@]} -eq 0 ]]; then
        ui_msg "Nothing to keep: no open problem here has a fix that would stop a feature this PC uses (or may use)."
        return 0
    fi
    local out
    out=$(ui_checklist "<html><h3>Kept on purpose</h3><p>Tick the problems you accept because you use the feature they are there for (Steam Remote Play, Sunshine, SSH, ...). A kept problem is listed as kept, does not lower the score and is not offered as a fix - in this run's dashboard and report right away, and in later checks.</p><p>Untick one to count it again from the next check.</p></html>" "${items[@]}") || return 0
    mapfile -t picked <<< "$out"
    local -A want=()
    local -A is_offered=()
    for i in "${offered[@]}"; do is_offered["$i"]=1; done
    for i in "${picked[@]}"; do [[ "$i" =~ ^[0-9]+$ && -n "${is_offered[$i]:-}" ]] && want["$i"]=1; done

    # Every kept entry about an offered problem is replaced (all of them:
    # covering and narrower ones), so an untick cannot leave one behind
    # that still keeps it. Entries about anything else stay (a check that
    # did not run, ports not open right now).
    local -A drop=()
    local k v today kind
    for i in "${offered[@]}"; do
        while IFS=$'\t' read -r kind k; do [[ -n "$k" ]] && drop["$k"]=1; done < <(_kept_related "$i")
    done
    today=$(date +%Y-%m-%d)
    for k in "${!KEPT[@]}"; do
        [[ -n "${drop[$k]:-}" ]] && continue
        rows+=("${k}"$'\t'"${KEPT[$k]}")
    done
    # A ticked problem gets one entry: every port of the entries it
    # replaces and its own, the most severe level any of them accepted (or
    # its own), the earliest date.
    local ports sev date feats ek ed ef ev
    for i in "${!want[@]}"; do
        ports="${F_KEYX[$i]:-}"; sev=$(_orig_sev "$i"); date="$today"; feats=$(_kept_features "$i")
        [[ -n "${F_KEPT_FROM[$i]:-}" ]] && (( $(_sev_rank "${F_KEPT_FROM[$i]}") < $(_sev_rank "$sev") )) && sev="${F_KEPT_FROM[$i]}"
        while IFS=$'\t' read -r kind k; do
            [[ -n "$k" ]] || continue
            IFS=$'\x1f' read -r ed ef ev <<< "${KEPT[$k]//$'\t'/$'\x1f'}"
            [[ -n "$ed" && "$ed" < "$date" ]] && date="$ed"
            [[ -z "$feats" ]] && feats="$ef"
            [[ -n "$ev" ]] && (( $(_sev_rank "$ev") < $(_sev_rank "$sev") )) && sev="$ev"
            if [[ "$k" == *" ["*"]" ]]; then ek="${k##* [}"; ports+="${ports:+,}${ek%]}"; fi
        done < <(_kept_related "$i")
        k="${F_CHECK[$i]}"$'\t'"$(_finding_key "${F_TITLE[$i]}")"
        if [[ -n "${F_KEYX[$i]:-}" ]]; then
            ports=$(tr ',' '\n' <<< "$ports" | grep -v '^$' | sort -u | paste -sd, -)
            k+=" [${ports}]"
        fi
        rows+=("${k}"$'\t'"${date}"$'\t'"${feats}"$'\t'"${sev}")
    done
    _kept_save "${rows[@]}" || { ui_error "Could not save the kept problems in ${KEPT_FILE}."; return 0; }
    # Keeping takes effect now: the dashboard, score and reports update.
    # A problem unticked here counts again from the next check.
    kept_load
    kept_apply
    compute_score
    update_score_now
    _CF_READY=0
    write_reports
    ui_msg "Saved: ${#want[@]} problem(s) kept on purpose. The score and the report are updated. A problem you unticked counts again from the next check."
    log "kept on purpose: ${#want[@]} finding(s)"
}

# _kept_save LINE... — write the kept file (root only, replaced at once).
_kept_save() {
    [[ -n "$KEPT_FILE" ]] || return 1
    [[ -L "$KEPT_FILE" ]] && return 1
    local tmp="${KEPT_FILE}.tmp.$$" line
    ( umask 077
      for line in "$@"; do [[ -z "$line" ]] || printf '%s\n' "$line"; done > "$tmp" ) || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$KEPT_FILE"
}
