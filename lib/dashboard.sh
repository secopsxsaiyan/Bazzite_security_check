# shellcheck shell=bash
# The dashboard: after the checks, one window with the score, the open
# problems, a status line for every area and a row for every check. Pick a
# check to see what it found and the settings it saw; pick an action to fix
# problems, open the report or undo changes. It stays open until Finish.

# _check_area CHECK — the area a check belongs to.
_check_area() {
    case "${1#check_}" in
        image_signature|system_updates|layered_packages|repos) echo "System" ;;
        flatpak|flatpak_sandbox) echo "Apps" ;;
        firmware|secure_boot|disk_encryption|kernel_args|selinux|sysctl) echo "Boot" ;;
        firewall|listening_services|ssh_server) echo "Network" ;;
        accounts|sudo|autologin) echo "Accounts" ;;
        screen_lock|home_permissions|secrets) echo "Desktop" ;;
        containers|game_streaming) echo "Dev & gaming" ;;
        deep_*) echo "Deep" ;;
        *) echo "Other" ;;
    esac
}

# Per-check caches for drawing the dashboard: the finding indexes of each
# check (fixed once the checks have run) and each check's state (refreshed
# for every redraw, since fixes change it).
declare -gA _CF=() _CSTATE=()
_CF_READY=0

# _dash_index — fill _CF in one pass over the findings, most severe first.
_dash_index() {
    local _r i
    _CF=()
    while IFS=$'\t' read -r _r i; do
        [[ -n "$i" ]] && _CF["${F_CHECK[$i]}"]+="${i}"$'\n'
    done < <(for i in "${!F_CHECK[@]}"; do printf '%s\t%s\n' "$(_sev_rank "${F_SEV[$i]}")" "$i"; done | sort -n -k1,1 -s)
    _CF_READY=1
}

# _check_findings CHECK — CHECK's finding indexes, most severe first.
_check_findings() {
    if [[ "$_CF_READY" -eq 1 ]]; then
        printf '%s' "${_CF[$1]:-}"
        return 0
    fi
    local i
    for i in "${!F_CHECK[@]}"; do
        [[ "${F_CHECK[$i]}" == "$1" ]] && printf '%s\t%s\n' "$(_sev_rank "${F_SEV[$i]}")" "$i"
    done | sort -n -k1,1 -s | cut -f2
}

# _check_state CHECK — one word for where CHECK stands now:
#   bad (high/medium open)  warn (low open)  reboot (fixed, needs a reboot)
#   fixed  note (only info)  ok  na  skipped  error
_check_state() {
    local id="$1" i bad=0 warn=0 note=0 reboot=0 fixed=0
    case "${CHECK_STATUS[$id]:-}" in
        na) echo na; return 0 ;;
        skipped) echo skipped; return 0 ;;
        error) echo error; return 0 ;;
    esac
    while IFS= read -r i; do
        [[ -n "$i" ]] || continue
        if [[ "${F_VERIFY[$i]}" == "gone" ]]; then fixed=1; continue; fi
        if [[ "${F_STATE[$i]}" == "fixed" && "${F_VERIFY[$i]}" != "still" ]]; then
            if [[ "${F_VERIFY[$i]}" == "reboot" ]]; then reboot=1; else fixed=1; fi
            continue
        fi
        case "${F_SEV[$i]}" in
            high|medium) bad=1 ;;
            low) warn=1 ;;
            *) note=1 ;;
        esac
    done < <(_check_findings "$id")
    if   (( bad ));    then echo bad
    elif (( warn ));   then echo warn
    elif (( reboot )); then echo reboot
    elif (( fixed ));  then echo fixed
    elif (( note ));   then echo note
    else echo ok; fi
}

_state_icon() {
    case "$1" in
        bad) echo "✖" ;; warn) echo "⚠" ;; reboot) echo "↻" ;; fixed|ok) echo "✔" ;;
        note) echo "ℹ" ;; na) echo "–" ;; *) echo "?" ;;
    esac
}

_state_color() {
    case "$1" in
        bad) echo "$C_HIGH" ;; warn) echo "$C_MEDIUM" ;; reboot) echo "$C_LOW" ;;
        fixed|ok) echo "$C_OK" ;; *) echo "$C_INFO" ;;
    esac
}

# _check_row CHECK — the dashboard row: icon, title and what stands now.
_check_row() {
    local id="$1" st i sum="" fixable=0 still=0
    local -A n=()
    st="${_CSTATE[$id]:-$(_check_state "$id")}"
    while IFS= read -r i; do
        [[ -n "$i" ]] || continue
        [[ "${F_VERIFY[$i]}" == "gone" ]] && continue
        if [[ "${F_STATE[$i]}" == "fixed" ]]; then
            [[ "${F_VERIFY[$i]}" == "still" ]] || continue
            still=1
        elif [[ -n "${F_FIX[$i]}" && "$FIX_MODE" == "confirm" ]]; then
            fixable=1
        fi
        n["${F_SEV[$i]}"]=$(( ${n[${F_SEV[$i]}]:-0} + 1 ))
    done < <(_check_findings "$id")
    case "$st" in
        bad|warn)
            local s
            for s in high medium low; do
                [[ -n "${n[$s]:-}" ]] && sum+="${sum:+, }${n[$s]} ${s}"
            done
            [[ $fixable -eq 1 ]] && sum+=" · fix available"
            [[ $still -eq 1 ]] && sum+=" · fix applied, still found" ;;
        reboot)  sum="fixed - active after a reboot" ;;
        fixed)   sum="fixed in this run" ;;
        note)    sum="${n[info]:-1} note(s)" ;;
        ok)      sum="OK" ;;
        na)      sum="not applicable: $(_clip "${CHECK_NA[$id]:-}" 60)" ;;
        skipped) sum="not checked: $(_clip "${CHECK_SKIPPED[$id]:-}" 60)" ;;
        error)   sum="did not complete (see the run log)" ;;
    esac
    printf '%s  %s  —  %s' "$(_state_icon "$st")" "${CHECK_TITLE[$id]}" "$sum"
}

# _state_rank STATE — how bad a check state is (for an area's summary).
_state_rank() {
    case "$1" in bad) echo 5 ;; warn) echo 4 ;; reboot) echo 3 ;; error|skipped) echo 2 ;; note) echo 1 ;; *) echo 0 ;; esac
}

# _area_states — "AREA<TAB>STATE" per area, in check order: the worst
# state of its checks (notes and n/a count as ok).
_area_states() {
    local id a st
    local -a order=()
    local -A worst=()
    for id in "${CHECK_ORDER[@]}"; do
        a=$(_check_area "$id")
        [[ -n "${worst[$a]+x}" ]] || { order+=("$a"); worst["$a"]=ok; }
        st="${_CSTATE[$id]:-$(_check_state "$id")}"
        (( $(_state_rank "$st") > $(_state_rank "${worst[$a]}") )) && worst["$a"]="$st"
    done
    for a in "${order[@]}"; do
        st="${worst[$a]}"
        [[ "$st" == "note" || "$st" == "na" ]] && st=ok
        printf '%s\t%s\n' "$a" "$st"
    done
}

# _areas_html — one coloured status per area, the worst of its checks.
_areas_html() {
    local a st out=""
    while IFS=$'\t' read -r a st; do
        [[ -n "$a" ]] || continue
        out+="${out:+ &nbsp;·&nbsp; }$(_html "$a") <font color=\"$(_state_color "$st")\"><b>$(_state_icon "$st")</b></font>"
    done < <(_area_states)
    printf '%s' "$out"
}

# _dashboard_html — the header above the list: score, PC, open problems.
_dashboard_html() {
    local h col s chips="" fixed=0 verified=0 reboot=0 i
    if (( SCORE_NOW >= 80 )); then col="$C_OK"; elif (( SCORE_NOW >= 60 )); then col="$C_MEDIUM"; else col="$C_HIGH"; fi
    for s in high medium low info; do
        chips+="<font color=\"$(_sev_color "$s")\">●</font> $(_open_count "$s") ${s} &nbsp; "
    done
    for i in "${!F_STATE[@]}"; do
        [[ "${F_STATE[$i]}" == "fixed" ]] || continue
        fixed=$((fixed + 1))
        case "${F_VERIFY[$i]}" in verified) verified=$((verified + 1)) ;; reboot) reboot=$((reboot + 1)) ;; esac
    done
    local info was=""
    info="<b>$(_html "$(hostname 2>/dev/null)")</b> · $(_html "${OS_PRETTY:-unknown OS}")"
    [[ -n "$IMAGE_NAME" ]] && info+=" · image $(_html "${IMAGE_NAME}:${IMAGE_TAG:-?}")"
    info+="<br>$(_html "$(_usecase_summary)") · $(_html "$(_depth_label)")"
    info+="<br><b>Open:</b> ${chips}"
    if (( fixed > 0 )); then
        info+="<br><b>Fixed in this run:</b> ${fixed} (${verified} checked again and gone"
        [[ $reboot -gt 0 ]] && info+=", ${reboot} after a reboot"
        info+=")"
    fi
    [[ "$SCORE_NOW" != "$SCORE" ]] && was="${SCORE} when checked"
    if [[ "$UI_MODE" == "kde" ]]; then
        h="<html><table width=\"100%\" cellpadding=\"6\"><tr>"
        h+="<td align=\"center\" valign=\"middle\" width=\"150\"><span style=\"font-size:28pt; font-weight:600; color:${col}\">${SCORE_NOW}</span><br>of 100 · grade ${GRADE_NOW}"
        [[ -n "$was" ]] && h+="<br><small>${was}</small>"
        h+="</td><td valign=\"middle\">${info}</td></tr></table>"
    else
        h="<html><h3>Bazzite Security Check</h3><p><b>Score: ${SCORE_NOW}/100 (grade ${GRADE_NOW})</b>${was:+ - ${was}}</p><p>${info}</p>"
    fi
    h+="<p>$(_areas_html)</p>"
    if [[ "$NEEDS_REBOOT" -eq 1 ]]; then
        h+="<p><font color=\"${C_MEDIUM}\"><b>↻ Reboot to finish:</b></font> $(_html "$(_join '; ' "${REBOOT_REASONS[@]}")")</p>"
    fi
    if [[ "${HAD_PREVIOUS_RUN:-0}" -eq 1 ]]; then
        if [[ ${#DELTA_NEW[@]} -gt 0 || ${#DELTA_GONE[@]} -gt 0 ]]; then
            h+="<p><b>Since the last check:</b> ${#DELTA_GONE[@]} resolved, ${#DELTA_NEW[@]} new"
            [[ ${#DELTA_NEW[@]} -gt 0 ]] && h+=" ($(_html "$(_clip "$(_join '; ' "${DELTA_NEW[@]}")" 160)"))"
            h+="</p>"
        else
            h+="<p><b>Since the last check:</b> no changes.</p>"
        fi
    fi
    if [[ "$FIX_MODE" != "confirm" ]]; then
        h+="<p><i>Report only: nothing on this PC will be changed in this run.</i></p>"
    fi
    if [[ "$REPORT_FALLBACK" -eq 1 ]]; then
        h+="<p><font color=\"${C_MEDIUM}\">⚠</font> The report could not be saved in $(_html "$REPORT_DIR") (${DESKTOP_USER} cannot write there); it is in $(_html "$STATE_DIR/reports"), which only root can read. Run the tool with --wizard to choose another folder.</p>"
    elif [[ "$UI_MODE" != "kde" ]]; then
        h+="<p>Report: $(_html "$REPORT_HTML")</p>"
    fi
    h+="<p>Pick a check to see what it found and the settings it saw, or an action.</p></html>"
    printf '%s' "$h"
}

# _finding_html I — one finding on a check's page.
_finding_html() {
    local i="$1" h state
    local -a warns=()
    h="<p>$(_badge "${F_SEV[$i]}") &nbsp;<b>$(_html "${F_TITLE[$i]}")</b>"
    state=$(_finding_state_label "$i")
    h+="<br><i>$(_html "$state")</i></p>"
    h+="$(_now_after_html "${F_NOW[$i]}" "${F_AFTER[$i]}" "$([[ -n ${F_FIX[$i]} ]] && echo "After the fix" || echo "Goal")")"
    h+="<p>$(_rich "${F_DETAIL[$i]}")</p>"
    if _still_open "$i"; then
        if [[ -n "${F_FIX[$i]}" ]]; then
            mapfile -t warns < <(_fix_warnings "$i" "x" "")
            [[ -n "${warns[0]:-}" ]] || warns=()
            h+="$(_warnings_html "${warns[@]}")"
        fi
        if [[ -n "${F_MANUAL[$i]}" ]]; then
            h+="<p><b>How to fix it yourself:</b></p>$(_pre "${F_MANUAL[$i]}" 20)"
        fi
    fi
    printf '%s' "$h"
}

# show_check CHECK — a check's page: its result, the settings it saw and
# each finding; offers the fixes that are still open.
show_check() {
    local id="$1" st html i
    local -a fixable=() fidx=()
    st=$(_check_state "$id")
    mapfile -t fidx < <(_check_findings "$id")
    [[ -n "${fidx[0]:-}" ]] || fidx=()
    html="<html><h3><font color=\"$(_state_color "$st")\">$(_state_icon "$st")</font> $(_html "${CHECK_TITLE[$id]}")</h3>"
    html+="<p><i>$(_html "$(_check_area "$id")") · $(_html "$(_check_row "$id" | sed 's/^.*  —  //')")</i></p>"
    if [[ -n "${CHECK_NOTE[$id]:-}${CHECK_NA[$id]:-}${CHECK_SKIPPED[$id]:-}" ]]; then
        html+="<p><b>What the check saw:</b></p><ul>"
        while IFS= read -r i; do
            [[ -n "$i" ]] && html+="<li>$(_html "$i")</li>"
        done <<< "${CHECK_NOTE[$id]:-}${CHECK_NA[$id]:+$'\n'Not applicable: ${CHECK_NA[$id]}}${CHECK_SKIPPED[$id]:+$'\n'Not checked: ${CHECK_SKIPPED[$id]}}"
        html+="</ul>"
    fi
    [[ ${#fidx[@]} -gt 0 ]] || html+="<p>Nothing to report.</p>"
    for i in "${fidx[@]}"; do
        html+="<hr>$(_finding_html "$i")"
        if [[ "$FIX_MODE" == "confirm" && -n "${F_FIX[$i]}" && "${F_STATE[$i]}" != "fixed" && "${F_VERIFY[$i]}" != "gone" ]]; then
            declare -F "${F_FIX[$i]%% *}" >/dev/null && fixable+=("$i")
        fi
    done
    html+="</html>"
    if [[ ${#fixable[@]} -gt 0 ]]; then
        if ui_yesno "$html" "Fix…" "Back" "n"; then
            run_fix_session "${fixable[@]}"
        fi
    else
        ui_page "$html"
    fi
    _ui_sync
}

# _open_report — open the HTML report in the desktop user's browser.
_open_report() {
    if [[ "$REPORT_FALLBACK" -eq 1 || -z "$DESKTOP_USER" ]]; then
        ui_msg "The report is in ${REPORT_HTML}, which only root can read."
        return 0
    fi
    _as_desktop_user setsid -f xdg-open "$REPORT_HTML" >/dev/null 2>&1 || true
}

# run_dashboard — show the dashboard until Finish.
# _one_line TEXT — TEXT without tabs or line breaks (one field of a line).
_one_line() { local t="${1//$'\t'/ }"; t="${t//$'\r'/ }"; printf '%s' "${t//$'\n'/ }"; }

# _dashboard_input NFIX — the Kirigami dashboard's input (JSON): the score,
# the PC, open problems, area states, notices, actions and every check
# with its state and summary.
_dashboard_input() {
    local nfix="$1" id st row s i fixed=0 verified=0 reboot=0
    for i in "${!F_STATE[@]}"; do
        [[ "${F_STATE[$i]}" == "fixed" ]] || continue
        fixed=$((fixed + 1))
        case "${F_VERIFY[$i]}" in verified) verified=$((verified + 1)) ;; reboot) reboot=$((reboot + 1)) ;; esac
    done
    {
        printf 'score\t%s\nscore_was\t%s\ngrade\t%s\n' "$SCORE_NOW" "$SCORE" "$GRADE_NOW"
        printf 'host\t%s\nos\t%s\n' "$(_one_line "$(hostname 2>/dev/null)")" "$(_one_line "${OS_PRETTY:-unknown OS}")"
        [[ -n "$IMAGE_NAME" ]] && printf 'image\t%s\n' "$(_one_line "${IMAGE_NAME}:${IMAGE_TAG:-?}")"
        printf 'use\t%s\ndepth\t%s\n' "$(_one_line "$(_usecase_summary)")" "$(_one_line "$(_depth_label)")"
        for s in high medium low info; do printf 'open_%s\t%s\n' "$s" "$(_open_count "$s")"; done
        printf 'fixed\t%s\nverified\t%s\nfixed_reboot\t%s\n' "$fixed" "$verified" "$reboot"
        [[ "$NEEDS_REBOOT" -eq 1 ]] && printf 'reboot_reasons\t%s\n' "$(_one_line "$(_join '; ' "${REBOOT_REASONS[@]}")")"
        if [[ "${HAD_PREVIOUS_RUN:-0}" -eq 1 ]]; then
            printf 'prev\t1\ngone\t%s\nnew\t%s\n' "${#DELTA_GONE[@]}" "${#DELTA_NEW[@]}"
            [[ ${#DELTA_NEW[@]} -gt 0 ]] && printf 'new_titles\t%s\n' "$(_one_line "$(_clip "$(_join '; ' "${DELTA_NEW[@]}")" 200)")"
        fi
        [[ "$FIX_MODE" != "confirm" ]] && printf 'report_only\t1\n'
        [[ "$REPORT_FALLBACK" -eq 1 ]] && printf 'report_note\t%s\n' "$(_one_line "The report could not be saved in ${REPORT_DIR} (${DESKTOP_USER} cannot write there); it is in ${STATE_DIR}/reports.")"
        printf 'nfix\t%s\nundo\t%s\n' "$nfix" "$(_undo_available && echo 1 || echo 0)"
        while IFS=$'\t' read -r s st; do [[ -n "$s" ]] && printf 'area\t%s\t%s\n' "$(_one_line "$s")" "$st"; done < <(_area_states)
        for id in "${CHECK_ORDER[@]}"; do
            st="${_CSTATE[$id]:-$(_check_state "$id")}"
            row=$(_check_row "$id")
            printf 'check\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(_one_line "${CHECK_TITLE[$id]}")" "$(_one_line "$(_check_area "$id")")" "$st" "$(_one_line "${row#*  —  }")"
        done
    } | python3 -I -c '
import json, sys
d = {"areas": [], "checks": [], "open": {}}
ints = {"score", "score_was", "fixed", "verified", "fixed_reboot", "gone", "new", "nfix"}
for line in sys.stdin.read().split("\n"):
    f = line.split("\t")
    if not f[0]:
        continue
    if f[0] == "area" and len(f) >= 3:
        d["areas"].append({"name": f[1], "state": f[2]})
    elif f[0] == "check" and len(f) >= 6:
        d["checks"].append({"id": f[1], "title": f[2], "area": f[3], "state": f[4], "summary": "\t".join(f[5:])})
    elif f[0].startswith("open_") and len(f) >= 2:
        d["open"][f[0][5:]] = int(f[1]) if f[1].isdigit() else 0
    elif len(f) >= 2:
        v = "\t".join(f[1:])
        if f[0] in ints:
            v = int(v) if v.isdigit() else 0
        elif f[0] in ("prev", "report_only", "undo"):
            v = v == "1"
        d[f[0]] = v
print(json.dumps(d))'
}

# _dashboard_answer JSON — the dashboard's answer, checked: prints the
# action ("fix", "report", "undo", "settings", "finish" or "check:ID" for a
# known check); status 1 for anything else.
_dashboard_answer() {
    local a
    a=$(python3 -I -c '
import json, re, sys
try:
    d = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
a = d.get("action") if isinstance(d, dict) else None
if a in ("fix", "report", "undo", "settings", "finish"):
    print(a)
elif a == "check" and isinstance(d.get("check"), str) and re.fullmatch(r"check_[a-z0-9_]+", d["check"]):
    print("check:" + d["check"])
else:
    sys.exit(1)' "$1") || return 1
    [[ "$a" != check:* ]] || _known_check "${a#check:}" || return 1
    printf '%s\n' "$a"
}

# _dashboard_offered ACTION NFIX — ACTION was on offer: fixing only when
# fixes are offered in this run and there is one, undoing only when there
# are undo steps. (The kdialog list only returns what it offered.)
_dashboard_offered() {
    case "$1" in
        fix)  [[ "$FIX_MODE" == "confirm" && "${2:-0}" -gt 0 ]] ;;
        undo) _undo_available ;;
        report) [[ "$UI_MODE" == "kde" ]] ;;
        *) return 0 ;;
    esac
}

# _dashboard_app_choice NFIX — show the Kirigami dashboard; prints the
# checked action. Status 3 or 4: it cannot run here (use kdialog).
_dashboard_app_choice() {
    local out rc
    out=$(ui_app dashboard "$(_dashboard_input "$1")")
    rc=$?
    [[ $rc -eq 3 ]] && _QML_OK=no
    case "$rc" in
        0)
            local a
            if ! a=$(_dashboard_answer "$out") || ! _dashboard_offered "$a" "$1"; then
                log "dashboard: front-end answer rejected (${a:-invalid})"; _QML_OK=no; return 3
            fi
            printf '%s\n' "$a" ;;
        1) echo finish ;;
        *) return "$rc" ;;
    esac
}

run_dashboard() {
    local choice id nfix
    local -a items=()
    _dash_index
    while ui_interactive; do
        _ui_sync
        items=()
        _CSTATE=()
        for id in "${CHECK_ORDER[@]}"; do _CSTATE["$id"]=$(_check_state "$id"); done
        nfix=$(_fix_candidates | grep -c . || true)
        if [[ "$FIX_MODE" == "confirm" && "$nfix" -gt 0 ]]; then
            items+=(fix "▶  Review and fix problems  —  ${nfix} can be fixed here")
        fi
        [[ "$UI_MODE" == "kde" ]] && items+=(report "≡  Open the full report")
        _undo_available && items+=(undo "↺  Undo changes made by this tool…")
        items+=(settings "⚙  Settings: theme and updates…")
        for id in "${CHECK_ORDER[@]}"; do
            items+=("check:${id}" "$(_check_row "$id")")
        done
        # The Kirigami dashboard when it can run, else the kdialog list.
        if choice=$(_dashboard_app_choice "$([[ $FIX_MODE == confirm ]] && echo "$nfix" || echo 0)"); then
            [[ "$choice" == finish ]] && break
        else
            _QML_OK=no
            choice=$(ui_menu "$(_dashboard_html)" "Open" "Finish" "${items[@]}") || break
        fi
        _CSTATE=()
        case "$choice" in
            # Each action only when it was offered (the kdialog list and the
            # Kirigami answer both pass through here).
            fix)     _dashboard_offered fix "$nfix" && run_fix_session ;;
            report)  _dashboard_offered report && _open_report ;;
            undo)    _dashboard_offered undo && { run_undo; _sync_undone; write_reports; } ;;
            settings) run_settings ;;
            check:*) _known_check "${choice#check:}" && show_check "${choice#check:}" ;;
        esac
    done
    _CSTATE=()
    _ui_sync
    return 0
}
