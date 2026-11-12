# shellcheck shell=bash
# Offering fixes: the person picks fixes from a list, then each one is shown
# with what it changes (now -> after), its side effects, the exact commands
# and how to undo it, and runs only after it is confirmed. Applied fixes are
# checked again, so the dashboard and report say whether they worked. Every
# applied fix leaves an undo step in $STATE_DIR/undo/<run>/ (see --undo).

CURRENT_FINDING=""
FIX_APPLIED=0; FIX_SKIPPED=0; FIX_FAILED=0
NEEDS_REBOOT=0
declare -ga REBOOT_REASONS=()
declare -gA REBOOT_OF=()        # finding -> the reboot reason its fix added
declare -ga SESSION_DONE=()     # findings reviewed in the current fix session
# A fix function whose outcome depends on choices the person made in it (the
# firewall services, which packages) sets these before apply_change.
CHANGE_AFTER=""
declare -ga CHANGE_WARN=()

# ====================== BACKUPS ======================
# _bk_path FILE — where this run keeps the backup of FILE for the fix under
# review (one folder per finding, so two fixes touching the same file each
# keep their own "before" copy and undo in the right order).
_bk_path() { printf '%s/backups/%s/f%s%s' "$STATE_DIR" "$RUN_ID" "${CURRENT_FINDING:-0}" "$1"; }

# _backup_cmd FILE [OWNER] — shell lines that back FILE up (or remember it
# did not exist), for use inside a fix script. With OWNER (for files in a
# user's home) FILE is read as that user, so a symlink planted in its place
# cannot make root copy a file the user may not read. The copy only takes
# its final name once complete: a failed read stops the fix and leaves no
# (empty or partial) backup that a rollback would write back.
_backup_cmd() {
    local f="$1" owner="${2:-}" b
    b=$(_bk_path "$f")
    printf 'mkdir -p %s\n' "$(_q "$(dirname -- "$b")")"
    if [[ -n "$owner" ]]; then
        printf 'if runuser -u %s -- test -e %s; then runuser -u %s -- cat -- %s > %s.tmp || exit 1; mv -f -- %s.tmp %s; else : > %s.absent; fi\n' \
            "$(_q "$owner")" "$(_q "$f")" "$(_q "$owner")" "$(_q "$f")" "$(_q "$b")" "$(_q "$b")" "$(_q "$b")" "$(_q "$b")"
    else
        printf 'if [ -e %s ]; then cp -a -- %s %s.tmp || exit 1; mv -f -- %s.tmp %s; else : > %s.absent; fi\n' \
            "$(_q "$f")" "$(_q "$f")" "$(_q "$b")" "$(_q "$b")" "$(_q "$b")" "$(_q "$b")"
    fi
}

# _restore_cmd FILE [OWNER] — shell lines that put FILE back as it was
# before. With OWNER the file is written as that user (root never writes
# into a folder the user controls).
_restore_cmd() {
    local f="$1" owner="${2:-}" b
    b=$(_bk_path "$f")
    if [[ -n "$owner" ]]; then
        printf 'if [ -e %s ]; then runuser -u %s -- tee -- %s < %s > /dev/null; elif [ -e %s.absent ]; then runuser -u %s -- rm -f -- %s; fi\n' \
            "$(_q "$b")" "$(_q "$owner")" "$(_q "$f")" "$(_q "$b")" "$(_q "$b")" "$(_q "$owner")" "$(_q "$f")"
    else
        printf 'if [ -e %s ]; then cp -a -- %s %s; elif [ -e %s.absent ]; then rm -f -- %s; fi\n' \
            "$(_q "$b")" "$(_q "$b")" "$(_q "$f")" "$(_q "$b")" "$(_q "$f")"
    fi
}

# ====================== APPLY ======================
# _fix_warnings I UNDO REBOOT — the side effects of finding I's fix, one
# "tag|text" per line: those the check named, those the fix function added
# for the choices made in it, a reboot and a missing undo (each tag once).
_fix_warnings() {
    local i="$1" undo="$2" reboot="$3" w tag
    local -A seen=()
    local -a all=()
    [[ -n "${F_WARN[$i]:-}" ]] && mapfile -t all <<< "${F_WARN[$i]}"
    all+=("${CHANGE_WARN[@]}")
    [[ -n "$reboot" ]] && all+=("$W_REBOOT")
    [[ -z "$undo" ]] && all+=("$W_NOUNDO")
    for w in "${all[@]}"; do
        [[ -n "$w" ]] || continue
        tag=$(_warn_tag "$w")
        [[ -n "${seen[$tag]:-}" ]] && continue
        seen["$tag"]=1
        printf '%s\n' "$w"
    done
    return 0
}

# _now_after_html NOW AFTER [AFTER_LABEL] — the two-row "Now / After" table.
_now_after_html() {
    [[ -n "$1$2" ]] || return 0
    printf '<table cellpadding="3">'
    [[ -n "$1" ]] && printf '<tr><td><b>Now</b></td><td>%s</td></tr>' "$(_html "$1")"
    [[ -n "$2" ]] && printf '<tr><td><b>%s</b></td><td><font color="%s">%s</font></td></tr>' \
        "${3:-After}" "$C_OK" "$(_html "$2")"
    printf '</table>'
}

# _warnings_html WARNING... — a "Before you apply" list.
_warnings_html() {
    [[ $# -gt 0 ]] || return 0
    local w
    printf '<p><font color="%s"><b>⚠ Before you apply:</b></font></p><ul>' "$C_MEDIUM"
    for w in "$@"; do
        printf '<li><b>%s</b> - %s</li>' "$(_html "$(_warn_tag "$w")")" "$(_html "$(_warn_text "$w")")"
    done
    printf '</ul>'
}

# apply_change SCRIPT UNDO [NOTE] [REBOOT_REASON]
# Show the finding under review - what the setting is now and what it will
# be, its side effects, the commands SCRIPT runs and whether UNDO can
# reverse them - and run SCRIPT only when confirmed.
# Returns 0 applied, 1 skipped, 2 stop reviewing, 3 failed.
apply_change() {
    local script="$1" undo="$2" note="${3:-}" reboot="${4:-}"
    local i="$CURRENT_FINDING" sev title detail now after html rc
    local -a warns=()
    sev="${F_SEV[$i]}"
    title="${F_TITLE[$i]}"
    detail="${F_DETAIL[$i]}"
    now="${F_NOW[$i]:-}"
    after="${CHANGE_AFTER:-${F_AFTER[$i]:-}}"
    mapfile -t warns < <(_fix_warnings "$i" "$undo" "$reboot")
    [[ -n "${warns[0]:-}" ]] || warns=()
    CHANGE_AFTER=""; CHANGE_WARN=()

    html="<h3>$(_badge "$sev") &nbsp;$(_html "$title")</h3>"
    html+="$(_now_after_html "$now" "$after")"
    html+="<p>$(_rich "$detail")</p>"
    html+="$(affects_html "$i")"
    html+="$(_warnings_html "${warns[@]}")"
    html+="<p><b>Commands</b> (run as administrator - this tool already has administrator rights, so you are not asked for your password again):</p>$(_pre "$script" 30)"
    if [[ -n "$undo" ]]; then
        html+="<p><font color=\"${C_OK}\">✔</font> <b>Can be undone</b> later: dashboard → Undo, or run the tool with <tt>--undo</tt>.</p>"
    else
        html+="<p><font color=\"${C_HIGH}\">✖</font> <b>No automatic undo.</b></p>"
    fi
    [[ -n "$note" ]] && html+="<p><i>$(_rich "$note")</i></p>"

    ui_choice3 "$html" "" "Apply" "Skip" "Stop reviewing" \
        "$([[ ${#warns[@]} -gt 0 ]] && echo warn)"
    rc=$?
    case "$rc" in
        0) ;;
        1) log "Skipped fix: ${title}"; return 1 ;;
        *) return 2 ;;
    esac
    _run_change "$title" "$script" "$undo" "$reboot"
}

# _run_change TITLE SCRIPT UNDO [REBOOT_REASON]
_run_change() {
    local title="$1" script="$2" undo="$3" reboot="${4:-}" out rc=0 tmpfile
    log "Applying fix: ${title}"
    log "--- script ---"$'\n'"${script}"
    ui_busy_start "Applying: ${title}…"

    # The script file lives in this run's private folder. Without one there
    # is no safe place for it (a guessable name in /tmp could be someone
    # else's file), so the fix is not run at all.
    if [[ -z "${RUN_TMP:-}" || ! -d "$RUN_TMP" ]] \
       || ! tmpfile=$(mktemp "${RUN_TMP}/bazzite-fix.XXXXXX") \
       || ! printf '%s\n' 'set -euo pipefail' 'umask 022' "$script" > "$tmpfile"; then
        ui_busy_stop
        print_status "ERR" "Fix not run: ${title}"
        ui_error "Could not create a private temporary file for \"${title}\", so nothing was changed."
        return 3
    fi
    # umask 022: files the fix creates (drop-ins, Flatpak data) must stay
    # readable by the services and accounts that use them. _no_tty: programs
    # the fix runs as another account get no access to this terminal.
    out=$(_no_tty bash "$tmpfile" 2>&1 < /dev/null) || rc=$?
    rm -f -- "$tmpfile"
    ui_busy_stop
    log "--- output (exit ${rc}) ---"$'\n'"${out}"
    if [[ $rc -eq 0 ]]; then
        [[ -n "$undo" ]] && _undo_record "$title" "$undo"
        if [[ -n "$reboot" ]]; then
            NEEDS_REBOOT=1
            REBOOT_REASONS+=("$reboot")
            if [[ -n "$CURRENT_FINDING" ]]; then
                F_VERIFY[CURRENT_FINDING]="reboot"
                REBOOT_OF["$CURRENT_FINDING"]="$reboot"
            fi
        fi
        print_status "OK" "Applied: ${title}"
        return 0
    fi
    print_status "ERR" "Fix failed: ${title}"
    ui_error "The change \"${title}\" did not complete (exit ${rc}).

Output:
$(tail -n 15 <<< "$out")"
    if [[ -n "$undo" ]] && ui_yesno "Put back what this fix may already have changed?" "Roll back" "Leave it" "y"; then
        if _no_tty bash -c "$undo" >> "$RUN_LOG" 2>&1 < /dev/null; then
            print_status "OK" "Rolled back: ${title}"
        else
            ui_error "Rolling back \"${title}\" failed too - see the run log: ${RUN_LOG}"
        fi
    fi
    return 3
}

# ====================== CHOOSING AND REVIEWING ======================
# _fix_candidates — findings with a fix that is not applied yet (open, or
# skipped/failed earlier in this run), most severe first.
_fix_candidates() {
    local i fn
    for i in "${!F_FIX[@]}"; do
        [[ -n "${F_FIX[$i]}" && "${F_STATE[$i]}" != "fixed" && "${F_VERIFY[$i]}" != "gone" ]] || continue
        fn="${F_FIX[$i]%% *}"
        declare -F "$fn" >/dev/null || continue
        printf '%s\t%s\n' "$(_sev_rank "${F_SEV[$i]}")" "$i"
    done | sort -n -k1,1 -s | cut -f2
}

# _clip TEXT MAX — TEXT shortened to MAX characters.
_clip() {
    if (( ${#1} > $2 )); then printf '%s…' "${1:0:$(( $2 - 1 ))}"; else printf '%s' "$1"; fi
}

# _fix_row I — one line of the fix list: severity, title, now -> after and
# the tags of its side effects.
_fix_row() {
    local i="$1" row tags="" w
    row="$(_sev_label "${F_SEV[$i]}") · ${F_TITLE[$i]//$'\n'/ }"
    if [[ -n "${F_NOW[$i]}${F_AFTER[$i]}" ]]; then
        row+="  —  $(_clip "${F_NOW[$i]:-?}" 55) → $(_clip "${F_AFTER[$i]:-?}" 55)"
    fi
    while IFS= read -r w; do
        [[ -n "$w" ]] && tags+="${tags:+, }$(_warn_tag "$w")"
    done < <(_fix_warnings "$i" "x" "")
    [[ -n "$tags" ]] && row+="  ⚠ ${tags}"
    tags=$(affects_tags "$i")
    [[ -n "$tags" ]] && row+="  ★ stops ${tags} (in use here)"
    case "${F_STATE[$i]}" in
        skipped) row+="  (skipped earlier)" ;;
        failed)  row+="  (failed earlier)" ;;
    esac
    printf '%s' "$row"
}

# _choose_fixes — the fix list: print the findings the person ticks.
_choose_fixes() {
    local -a cand=() items=()
    local i on n_warn=0 n_use=0
    mapfile -t cand < <(_fix_candidates)
    [[ -n "${cand[0]:-}" ]] || return 1
    for i in "${cand[@]}"; do
        on=off
        [[ "${F_STATE[$i]}" == "open" && "${F_SEV[$i]}" =~ ^(high|medium)$ ]] && on=on
        # A fix that changes a feature this PC uses is the person's call.
        if _affects_in_use "$i"; then on=off; n_use=$((n_use + 1)); fi
        [[ -n "$(_fix_warnings "$i" "x" "")" ]] && n_warn=$((n_warn + 1))
        items+=("$i" "$(_fix_row "$i")" "$on")
    done
    ui_checklist "<html><h3>Choose what to fix</h3><p>${#cand[@]} problem(s) can be fixed from here. The high and medium ones are ticked$([[ $n_use -gt 0 ]] && echo ", except ${n_use} that would stop a feature this PC uses (marked ★)"). Each line shows the setting now → after the fix.</p><p>Nothing runs yet: every ticked fix is shown again with its exact commands and side effects, and runs only when you press <b>Apply</b> there.$([[ $n_warn -gt 0 ]] && echo " <font color=\"${C_MEDIUM}\">⚠</font> marks ${n_warn} fix(es) with side effects (a reboot, a restarted service, no undo, ...).")</p></html>" \
        "${items[@]}"
}

# review_fixes INDEX... — offer these findings' fixes, in this order. An
# INDEX that is not a plain number is ignored: bash evaluates array
# subscripts as arithmetic, which would run code hidden in one.
review_fixes() {
    local i rc
    for i in "$@"; do
        [[ "$i" =~ ^[0-9]+$ ]] || continue
        [[ -n "${F_FIX[$i]:-}" && "${F_STATE[$i]}" != "fixed" ]] || continue
        CURRENT_FINDING="$i"
        local -a fx=()
        # F_FIX is only ever written by finding(), which quotes every word
        # with printf %q: eval gives back exactly those words (a plain
        # "read" would split arguments that contain spaces).
        eval "fx=(${F_FIX[$i]})"
        if [[ ${#fx[@]} -eq 0 ]] || ! declare -F "${fx[0]}" >/dev/null; then
            continue
        fi
        SESSION_DONE+=("$i")
        F_VERIFY[i]=""
        CHANGE_AFTER=""; CHANGE_WARN=()
        rc=0
        "${fx[@]}" || rc=$?
        _ui_sync
        case "$rc" in
            0) F_STATE[i]="fixed" ;;
            1) F_STATE[i]="skipped" ;;
            2) F_STATE[i]="skipped"; break ;;
            *) F_STATE[i]="failed" ;;
        esac
    done
    CURRENT_FINDING=""
    _count_fixes
    return 0
}

# _count_fixes — FIX_APPLIED/SKIPPED/FAILED from the findings' states.
_count_fixes() {
    local s
    FIX_APPLIED=0; FIX_SKIPPED=0; FIX_FAILED=0
    for s in "${F_STATE[@]}"; do
        case "$s" in
            fixed)   FIX_APPLIED=$((FIX_APPLIED + 1)) ;;
            skipped) FIX_SKIPPED=$((FIX_SKIPPED + 1)) ;;
            failed)  FIX_FAILED=$((FIX_FAILED + 1)) ;;
        esac
    done
}

# run_fix_session [INDEX...] — pick fixes from the list (or review the
# given findings), apply the confirmed ones, check them again, and update
# the score and the reports.
run_fix_session() {
    local -a order=()
    SESSION_DONE=()
    if [[ $# -gt 0 ]]; then
        order=("$@")
    else
        # ui_checklist only returns findings the list offered.
        mapfile -t order < <(_choose_fixes)
        _ui_sync
        [[ ${#order[@]} -gt 0 ]] || return 0
    fi
    review_fixes "${order[@]}"
    [[ ${#SESSION_DONE[@]} -gt 0 ]] || return 0
    verify_fixes
    update_score_now
    write_reports
    _session_summary
}

# ====================== CHECKING FIXES AGAIN ======================
# _recheck CHECK — run CHECK again (in a subshell, so nothing of this run
# changes) and print "status<TAB>…" first (ok, or incomplete when it could
# not finish), then "delta-key<TAB>title" for each finding it makes now.
_recheck() {
    local id="$1"
    (
        FINDINGS_FILE=""; VERBOSE=0; QUIET=1
        F_SEV=(); F_CHECK=(); F_TITLE=(); F_DETAIL=(); F_MANUAL=(); F_FIX=(); F_STATE=()
        F_NOW=(); F_AFTER=(); F_WARN=(); F_VERIFY=(); F_RECHECK=(); F_AFFECT=(); F_KEYX=(); F_KEPT_SEV=(); F_KEPT_FROM=()
        CHECK_NOTE=(); CHECK_NA=(); CHECK_SKIPPED=(); CHECK_FAILED=(); CHECK_ERRORS=()
        _FW_ZONE_ALL=(); _FW_ZONE_OPEN=(); _FW_SVC_PORTS=()
        CURRENT_CHECK="$id"
        _run_isolated "$id" > /dev/null 2>&1
        if [[ -n "${CHECK_SKIPPED[$id]:-}" || "${CHECK_ERRORS[$id]:-0}" -gt 0 ]]; then
            printf 'status\tincomplete\n'
        else
            printf 'status\tok\n'
        fi
        local i
        for i in "${!F_TITLE[@]}"; do
            printf '%s\t%s\n' "$(_delta_key "$id" "${F_TITLE[$i]//$'\t'/ }")" "${F_TITLE[$i]//$'\n'/ }"
        done
    )
}

# Checks whose result depends on what another check's fix changes: they
# run again too, so their findings are not shown from before the fix.
declare -gA _CHECK_DEPENDENTS=(
    [check_firewall]="check_listening_services check_game_streaming check_containers"
)

# verify_fixes — check the fixes applied in this session again. Each one
# ends up verified (the finding is gone), still (the check still finds it),
# reboot (takes effect after a reboot) or unchecked (deep checks, which
# take too long, or a check that could not finish). Other findings of the
# checks run again that are no longer found are marked gone.
verify_fixes() {
    local i id key line status d
    local -A checks=()
    for i in "${SESSION_DONE[@]}"; do
        [[ "${F_STATE[$i]}" == "fixed" ]] || continue
        [[ "${F_VERIFY[$i]}" == "reboot" ]] && continue
        case "${F_CHECK[$i]}" in check_deep_*) F_VERIFY[i]="unchecked"; continue ;; esac
        checks["${F_CHECK[$i]}"]=1
        for d in ${_CHECK_DEPENDENTS[${F_CHECK[$i]}]:-}; do
            [[ "${CHECK_STATUS[$d]:-}" =~ ^(pass|fail)$ ]] && checks["$d"]=1
        done
    done
    [[ ${#checks[@]} -gt 0 ]] || return 0
    ui_busy_start "Checking that the changes worked…"
    for id in "${!checks[@]}"; do
        local -A found=()
        status=""
        while IFS=$'\t' read -r key line; do
            [[ -n "$key" ]] || continue
            if [[ "$key" == "status" ]]; then status="$line"; else found["$key"]="$line"; fi
        done < <(_recheck "$id")
        for i in "${SESSION_DONE[@]}"; do
            [[ "${F_CHECK[$i]}" == "$id" && "${F_STATE[$i]}" == "fixed" && "${F_VERIFY[$i]}" != "reboot" ]] || continue
            key=$(_delta_key "$id" "${F_TITLE[$i]//$'\t'/ }")
            if [[ "$status" != "ok" ]]; then
                F_VERIFY[i]="unchecked"
            elif [[ -n "${found[$key]:-}" ]]; then
                F_VERIFY[i]="still"
                F_RECHECK[i]="${found[$key]}"
            else
                F_VERIFY[i]="verified"
                F_RECHECK[i]=""
            fi
            log "Re-check of ${id} after fixing \"${F_TITLE[$i]}\": ${F_VERIFY[$i]}"
        done
        # Findings of this check that were not fixed directly.
        if [[ "$status" == "ok" ]]; then
            for i in "${!F_CHECK[@]}"; do
                [[ "${F_CHECK[$i]}" == "$id" && "${F_STATE[$i]}" != "fixed" ]] || continue
                key=$(_delta_key "$id" "${F_TITLE[$i]//$'\t'/ }")
                if [[ -z "${found[$key]:-}" ]]; then
                    F_VERIFY[i]="gone"
                elif [[ "${F_VERIFY[$i]}" == "gone" ]]; then
                    F_VERIFY[i]=""
                fi
            done
        fi
        unset found
    done
    ui_busy_stop
}

# _verify_label I — what the re-check said about finding I's applied fix.
_verify_label() {
    case "${F_VERIFY[$1]}" in
        verified)  echo "checked again: fixed" ;;
        still)     echo "checked again: still found${F_RECHECK[$1]:+ (${F_RECHECK[$1]})}" ;;
        reboot)    echo "takes effect after a reboot" ;;
        *)         echo "applied (not checked again)" ;;
    esac
}

# _session_summary — what this fix session did, and the score now.
_session_summary() {
    local i html="" icon col applied=0 skipped=0 failed=0
    for i in "${SESSION_DONE[@]}"; do
        case "${F_STATE[$i]}" in
            fixed)
                applied=$((applied + 1))
                case "${F_VERIFY[$i]}" in
                    verified) icon="✔"; col="$C_OK" ;;
                    still)    icon="⚠"; col="$C_MEDIUM" ;;
                    *)        icon="↻"; col="$C_LOW" ;;
                esac
                html+="<li><font color=\"${col}\">${icon}</font> $(_html "${F_TITLE[$i]}") - <i>$(_html "$(_verify_label "$i")")</i></li>" ;;
            failed)
                failed=$((failed + 1))
                html+="<li><font color=\"${C_HIGH}\">✖</font> $(_html "${F_TITLE[$i]}") - <i>failed (see the run log)</i></li>" ;;
            *)
                skipped=$((skipped + 1))
                html+="<li><font color=\"${C_INFO}\">–</font> $(_html "${F_TITLE[$i]}") - <i>skipped</i></li>" ;;
        esac
    done
    local score="Score: ${SCORE_NOW}/100 (grade ${GRADE_NOW})"
    [[ "$SCORE_NOW" != "$SCORE" ]] && score="Score: ${SCORE} → <b>${SCORE_NOW}</b>/100 (grade ${GRADE_NOW}), counting fixes that were checked again"
    ui_page "<html><h3>Fixes: ${applied} applied · ${skipped} skipped · ${failed} failed</h3><ul>${html}</ul><p>${score}</p>$([[ $NEEDS_REBOOT -eq 1 ]] && echo "<p><font color=\"${C_MEDIUM}\"><b>Reboot to finish:</b></font> $(_html "$(_join '; ' "${REBOOT_REASONS[@]}")")</p>")<p>Changed your mind? Use <b>Undo</b> on the dashboard.</p></html>"
}

# ====================== UNDO ======================
# _undo_dir — this run's undo folder.
_undo_dir() { printf '%s/undo/%s' "$STATE_DIR" "$RUN_ID"; }

# _undo_record TITLE SCRIPT — keep the undo step of an applied fix.
_undo_record() {
    local dir n f
    dir=$(_undo_dir)
    mkdir -p "$dir" && chmod 700 "$dir"
    # Steps already undone (.done) keep their number.
    n=$(find "$dir" -maxdepth 1 -name '[0-9][0-9]-undo.*' 2>/dev/null | wc -l)
    f=$(printf '%s/%02d-undo.sh' "$dir" $((n + 1)))
    {
        printf '#!/usr/bin/env bash\n# TITLE: %s\n# Applied: %s\n# FINDING: %s\nset -uo pipefail\n' \
            "${1//$'\n'/ }" "$(date '+%Y-%m-%d %H:%M')" "${CURRENT_FINDING:-}"
        printf '%s\n' "$2"
    } > "$f"
    chmod 700 "$f"
    _write_undo_all "$dir"
}

# _write_undo_all DIR — a standalone script that runs DIR's undo steps,
# newest first, asking before each (for use from a terminal).
_write_undo_all() {
    local dir="$1"
    cat > "$dir/undo-all.sh" << 'EOF'
#!/usr/bin/env bash
# Undo the changes made by one run of bazzite-sec-audit, newest first.
# Run as root: sudo ./undo-all.sh   (add --yes to skip the questions)
set -uo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
yes=0; [[ "${1:-}" == "--yes" ]] && yes=1
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }
steps=("$dir"/[0-9][0-9]-undo.sh)
for (( i = ${#steps[@]} - 1; i >= 0; i-- )); do
    f="${steps[$i]}"
    [[ -f "$f" ]] || continue
    title=$(sed -n 's/^# TITLE: //p' "$f")
    if [[ $yes -eq 0 ]]; then
        read -r -p "Undo: ${title}? [y/N] " a || a=""
        [[ "${a,,}" == y* ]] || continue
    fi
    if bash "$f"; then mv -f "$f" "${f%.sh}.done"; echo "Undone: ${title}"; else echo "FAILED: ${title}" >&2; fi
done
EOF
    chmod 700 "$dir/undo-all.sh"
}

# _undo_body FILE — the commands of an undo step, without its header.
_undo_body() { sed '1,/^set -uo pipefail$/d' "$1"; }

# _undo_available — some run has undo steps that were not undone yet.
_undo_available() { compgen -G "$STATE_DIR/undo/*/[0-9][0-9]-undo.sh" >/dev/null; }

# _sync_undone — fixes of this run that were undone (from the dashboard)
# are open again. Each undone step counts once, so a fix applied again
# after an undo stays applied.
declare -gA _UNDO_SYNCED=()
_sync_undone() {
    local f i
    for f in "$(_undo_dir)"/[0-9][0-9]-undo.done; do
        [[ -f "$f" && -z "${_UNDO_SYNCED[$f]:-}" ]] || continue
        _UNDO_SYNCED["$f"]=1
        i=$(sed -n 's/^# FINDING: //p' "$f")
        [[ "$i" =~ ^[0-9]+$ && "${F_STATE[$i]:-}" == "fixed" ]] || continue
        F_STATE[i]="open"
        F_VERIFY[i]="undone"
        # What its re-check marked gone (here and in dependent checks) is back
        # as it was before the fix.
        local j c
        for c in "${F_CHECK[$i]}" ${_CHECK_DEPENDENTS[${F_CHECK[$i]}]:-}; do
            for j in "${!F_CHECK[@]}"; do
                [[ "${F_CHECK[$j]}" == "$c" && "${F_VERIFY[$j]}" == "gone" ]] && F_VERIFY[j]=""
            done
        done
        # Undone before a reboot: nothing is left to reboot for.
        if [[ -n "${REBOOT_OF[$i]:-}" ]]; then
            local -a keep=()
            local r dropped=0
            for r in "${REBOOT_REASONS[@]}"; do
                if [[ $dropped -eq 0 && "$r" == "${REBOOT_OF[$i]}" ]]; then dropped=1; else keep+=("$r"); fi
            done
            REBOOT_REASONS=("${keep[@]}")
            unset 'REBOOT_OF[$i]'
            [[ ${#REBOOT_REASONS[@]} -gt 0 ]] || NEEDS_REBOOT=0
        fi
    done
    _count_fixes
    update_score_now
}

# run_undo — pick an earlier run and undo its changes, one confirmation each.
run_undo() {
    local base="$STATE_DIR/undo" r count label choice f title
    local -a items=() runs=()
    local d i
    for d in "$base"/*/; do [[ -d "$d" ]] && runs+=("$(basename "$d")"); done
    for (( i = ${#runs[@]} - 1; i >= 0; i-- )); do
        r="${runs[$i]}"
        count=$(find "$base/$r" -maxdepth 1 -name '[0-9][0-9]-undo.sh' 2>/dev/null | wc -l)
        [[ "$count" -gt 0 ]] || continue
        label="${r:0:4}-${r:4:2}-${r:6:2} ${r:9:2}:${r:11:2} - ${count} change(s)"
        items+=("$r" "$label" "$([[ ${#items[@]} -eq 0 ]] && echo on || echo off)")
    done
    if [[ ${#items[@]} -eq 0 ]]; then
        ui_msg "There is nothing to undo: no changes made by this tool are on record."
        return 0
    fi
    # ui_radiolist only returns one of the runs offered, never a path.
    choice=$(ui_radiolist "Which run's changes do you want to undo?" "${items[@]}") || return 0
    [[ -d "$base/$choice" ]] || return 0
    # Undo restores files as they were before that run. A newer run may have
    # changed the same file since; undoing the older one first loses that.
    local newer=0
    for r in "${runs[@]}"; do
        [[ "$r" > "$choice" ]] || continue
        compgen -G "$base/$r/[0-9][0-9]-undo.sh" >/dev/null && newer=$((newer + 1))
    done
    if [[ $newer -gt 0 ]] && ! ui_yesno "${newer} newer run(s) also made changes that are still in place.
Undoing an older run first can overwrite them when both changed the same
file. Undo the newest run first unless you are sure.

Undo this older run anyway?" "Undo anyway" "Cancel" "n"; then
        return 0
    fi
    local undone=0 failed=0
    local -a steps=()
    for f in "$base/$choice"/[0-9][0-9]-undo.sh; do [[ -f "$f" ]] && steps+=("$f"); done
    for (( i = ${#steps[@]} - 1; i >= 0; i-- )); do
        f="${steps[$i]}"
        title=$(sed -n 's/^# TITLE: //p' "$f")
        ui_choice3 "<h3>Undo: $(_html "$title")</h3>$(_pre "$(_undo_body "$f")" 30)" \
            "Undo: ${title}"$'\n'"$(_undo_body "$f" | sed 's/^/    /')" \
            "Undo it" "Keep it" "Stop"
        case $? in
            0) ;;
            1) continue ;;
            *) break ;;
        esac
        if _no_tty bash "$f" >> "$RUN_LOG" 2>&1 < /dev/null; then
            mv -f -- "$f" "${f%.sh}.done"
            undone=$((undone + 1))
            print_status "OK" "Undone: ${title}"
        else
            failed=$((failed + 1))
            ui_error "Undoing \"${title}\" failed - see ${RUN_LOG}"
        fi
    done
    ui_msg "Undo finished: ${undone} change(s) undone$([[ $failed -gt 0 ]] && echo ", ${failed} failed").
Some changes (kernel arguments, image rebase) take effect after a reboot."
}
