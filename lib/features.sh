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
#   KEY   the fix changes how the feature works
# Every place that shows
# a finding - the fix list, the Apply dialog, a check's page, the report -
# then says which features are affected and whether this PC uses them
# ("in use here: Steam is installed"), so the person can decide whether to
# touch the setting. Fixes that affect a feature in use start unticked.
#
# A finding can be kept on purpose ("I use this"): from the next check on it
# is listed as kept, does not lower the score and offers no fix. The choices
# are in KEPT_FILE (root only), one finding per line:
#   CHECK_ID<TAB>KEY<TAB>DATE<TAB>FEATURES<TAB>SEVERITY
# KEY is the finding's title with numbers replaced by "#", so "3 day(s)"
# and "4 day(s)" are the same finding, followed by the evidence a check
# gave with finding_keep_key (the exact ports): keeping "port 22 can be
# reached" does not cover a port that opens later. A kept finding counts
# again when it gets more severe than when it was kept.

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
declare -gA _FEATURE_SEEN=()    # cache: KEY -> "1<TAB>evidence" or "0" or "?"

# finding_affects KEY|SENTENCE... — for the finding just added: the features
# its fix (or the manual steps) affect, and what changes for each. Unknown
# keys are ignored; each key once.
finding_affects() {
    local i=$(( ${#F_SEV[@]} - 1 )) a key
    (( i >= 0 )) || return 0
    for a in "$@"; do
        key="${a%%|*}"; key="${key%[+?!]}"
        [[ -n "$key" && -n "${FEATURE_NAME[$key]:-}" && "$a" == *"|"* ]] || continue
        [[ $'\n'"${F_AFFECT[i]:-}" =~ $'\n'"${key}"[+?!]?\| ]] && continue
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
        performance|anticheat|couch|game_server) [[ "$USE_GAMING" -eq 1 ]] && echo "gaming" ;;
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
_affect_key() { local k="${1%%|*}"; printf '%s' "${k%[+?!]}"; }
_affect_mark() { local k="${1%%|*}"; [[ "$k" == *[+?!] ]] && printf '%s' "${k: -1}"; return 0; }

# _affects_in_use I — finding I's fix stops a feature this PC uses.
_affects_in_use() {
    local a
    while IFS= read -r a; do
        [[ -n "$a" && "$(_affect_mark "$a")" == "!" ]] || continue
        [[ "$(feature_status "$(_affect_key "$a")")" == in* ]] && return 0
    done <<< "${F_AFFECT[$1]:-}"
    return 1
}

# affects_list I — finding I's affected features, those in use first, one
# per line: "KEY<TAB>NAME<TAB>STATUS<TAB>WHY<TAB>MARK<TAB>SENTENCE" (STATUS
# in, out or unknown; WHY "-" when there is none; MARK "!", "?", "+" or
# "-"). No field is empty: "read" with a tab IFS would merge empty ones.
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
        "!") echo "stops it" ;; "?") echo "you choose in the fix" ;; "+") echo "helps it" ;; *) echo "changes it" ;;
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
        elif (( n >= 47984 && n <= 48010 )); then key=sunshine
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
# _finding_key TITLE — the stable part of a finding's title.
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
    [[ ${#KEPT[@]} -gt 0 ]] || return 1
    local k
    k="${F_CHECK[$1]}"$'\t'"$(_kept_key "$1")"
    [[ -n "${KEPT[$k]:-}" ]] || return 1
    printf '%s' "${KEPT[$k]}"
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
        e=$(_kept_entry "$i") || continue
        d="${e%%$'\t'*}"; e="${e#*$'\t'}"; f="${e%%$'\t'*}"; v="${e#*$'\t'}"
        # Worse than when it was kept: it counts again.
        [[ -n "$v" ]] && (( $(_sev_rank "${F_SEV[$i]}") < $(_sev_rank "$v") )) && continue
        F_KEPT_SEV[i]="${F_SEV[$i]}"
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

# _keep_candidates — findings that can be kept: open problems whose fix
# affects a feature this PC uses, and the findings kept already. Prints
# "INDEX<TAB>on|off".
_keep_candidates() {
    local i
    for i in "${!F_SEV[@]}"; do
        if [[ "${F_STATE[$i]}" == "kept" ]]; then
            printf '%s\ton\n' "$i"
        elif [[ "${F_STATE[$i]}" == "open" && "${F_SEV[$i]}" != "info" && "${F_VERIFY[$i]}" != "gone" ]] \
             && _affects_in_use "$i"; then
            printf '%s\toff\n' "$i"
        fi
    done
}

# kept_offered — there is something to keep (or kept already).
kept_offered() { [[ -n "$(_keep_candidates)" ]]; }

# kept_count — how many findings are kept on purpose in this run.
kept_count() {
    local s n=0
    for s in "${F_STATE[@]}"; do [[ "$s" == "kept" ]] && n=$((n + 1)); done
    echo "$n"
}

# _kept_features I — the in-use features finding I affects, for the file.
_kept_features() {
    local key name st why mark s out=""
    while IFS=$'\t' read -r key name st why mark s; do
        [[ "$st" == in && "$mark" == "!" ]] && out+="${out:+, }${name}"
    done < <(affects_list "$1")
    printf '%s' "${out//$'\t'/ }"
}

# manage_kept — tick the findings to keep on purpose; untick to count them
# again. Saved for the next check. Kept entries of checks that did not run
# this time stay as they are.
manage_kept() {
    local -a items=() picked=() rows=()
    local i on row
    while IFS=$'\t' read -r i on; do
        [[ -n "$i" ]] || continue
        row="$(_sev_label "${F_KEPT_SEV[$i]:-${F_SEV[$i]}}") · ${F_TITLE[$i]//$'\n'/ }"
        [[ -n "$(_kept_features "$i")" ]] && row+="  —  for: $(_kept_features "$i")"
        items+=("$i" "$row" "$on")
    done < <(_keep_candidates)
    if [[ ${#items[@]} -eq 0 ]]; then
        ui_msg "Nothing to keep: no open problem here affects a feature this PC uses."
        return 0
    fi
    local out
    out=$(ui_checklist "<html><h3>Kept on purpose</h3><p>Tick the problems you accept because you use the feature they are there for (Steam Remote Play, Sunshine, SSH, ...). From the next check on, a kept problem is listed as kept, does not lower the score and is not offered as a fix.</p><p>Untick one to count it again.</p></html>" "${items[@]}") || return 0
    mapfile -t picked <<< "$out"
    local -A want=()
    for i in "${picked[@]}"; do [[ "$i" =~ ^[0-9]+$ ]] && want["$i"]=1; done

    # Keep what this run did not look at; replace what it did.
    local -A ran=()
    local c
    for c in "${CHECK_ORDER[@]}"; do
        [[ "${CHECK_STATUS[$c]:-}" == "pass" || "${CHECK_STATUS[$c]:-}" == "fail" ]] && ran["$c"]=1
    done
    local k v today
    today=$(date +%Y-%m-%d)
    for k in "${!KEPT[@]}"; do
        [[ -n "${ran[${k%%$'\t'*}]:-}" ]] && continue
        v="${KEPT[$k]}"
        rows+=("${k}"$'\t'"${v}")
    done
    for i in "${!want[@]}"; do
        k="${F_CHECK[$i]}"$'\t'"$(_kept_key "$i")"
        v="${KEPT[$k]:-${today}$'\t'$(_kept_features "$i")$'\t'${F_KEPT_SEV[$i]:-${F_SEV[$i]}}}"
        rows+=("${k}"$'\t'"${v}")
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
