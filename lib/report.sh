# shellcheck shell=bash
# Reports: Markdown and a self-contained HTML page, the terminal summary and
# the closing dialog.

REPORT_MD=""
REPORT_HTML=""
REPORT_FALLBACK=0     # 1: the report folder could not be written; only the root copy exists

# _finding_state_label I — where finding I stands after this run's fixes.
_finding_state_label() {
    local i="$1"
    if [[ "${F_STATE[$i]}" != "fixed" && "${F_VERIFY[$i]}" == "gone" ]]; then
        echo "Gone - no longer found after this run's fixes (checked again)"
        return 0
    fi
    case "${F_STATE[$i]}" in
        fixed)
            case "${F_VERIFY[$i]}" in
                verified) echo "Fixed during this run - checked again: gone" ;;
                still)    echo "Fix applied during this run, but the check still finds it${F_RECHECK[$i]:+: ${F_RECHECK[$i]}}" ;;
                reboot)   echo "Fixed during this run - takes effect after a reboot" ;;
                *)        echo "Fixed during this run (not checked again)" ;;
            esac ;;
        kept)    echo "Kept on purpose - does not lower the score" ;;
        skipped) echo "Fix offered, skipped" ;;
        failed)  echo "Fix attempted, failed" ;;
        *)
            if [[ "${F_VERIFY[$i]}" == "undone" ]]; then echo "Open (fixed during this run, then undone)"
            elif [[ -n "${F_FIX[$i]}" ]]; then echo "Open - can be fixed by this tool"
            else echo "Open"; fi ;;
    esac
}

# _score_line — the score, and the score after verified fixes when it changed.
_score_line() {
    if [[ "$SCORE_NOW" != "$SCORE" ]]; then
        printf '%s/100 (grade %s) when checked → %s/100 (grade %s) after the fixes that were checked again' \
            "$SCORE" "$GRADE" "$SCORE_NOW" "$GRADE_NOW"
    else
        printf '%s/100 (grade %s)' "$SCORE" "$GRADE"
    fi
}

# _open_counts — open findings by severity (verified fixes left out).
_open_counts() {
    printf '%s high · %s medium · %s low · %s info' \
        "$(_open_count high)" "$(_open_count medium)" "$(_open_count low)" "$(_open_count info)"
}

_status_label() {
    case "$1" in
        pass) echo "Passed" ;; fail) echo "Findings" ;; na) echo "Not applicable" ;;
        skipped) echo "Skipped" ;; error) echo "Did not complete" ;; *) echo "-" ;;
    esac
}

# _sorted_findings — finding indexes, most severe first.
_sorted_findings() {
    local i
    for i in "${!F_SEV[@]}"; do
        printf '%s\t%s\n' "$(_sev_rank "${F_SEV[$i]}")" "$i"
    done | sort -n -k1,1 -s | cut -f2
}

_profile_line() {
    printf '%s · %s · fixes: %s' "$(_usecase_summary)" "$(_depth_label)" \
        "$([[ $FIX_MODE == confirm ]] && echo "offered with confirmation" || echo "report only")"
}

_not_checked_text() {
    cat << 'EOF'
This check is tuned for a home gaming and development desktop. It deliberately
does NOT ask for these server-hardening rules, because they cost more than they
protect on a personal machine (or would break games and tools):

- Password complexity/lockout rules, login banners, GRUB passwords, AIDE/auditd.
- noexec mounts on /tmp or /home (breaks Proton, Steam runtime and build tools).
- kernel.yama.ptrace_scope, kernel.dmesg_restrict, kernel.kptr_restrict (break
  debuggers, profilers and some game tools).
- Disabling user namespaces (Flatpak, Steam's pressure-vessel and Distrobox need them).
- vm.max_map_count, split-lock and other gaming tunables Bazzite sets on purpose.
- IP forwarding (containers and VMs need it) and IPv6.
EOF
}

write_reports() {
    local stamp base tmp_md tmp_html
    stamp="$RUN_ID"
    base="bazzite-security-${stamp}"
    mkdir -p "$STATE_DIR/reports"
    tmp_md="$STATE_DIR/reports/${base}.md"
    tmp_html="$STATE_DIR/reports/${base}.html"
    _write_markdown > "$tmp_md"
    _write_html > "$tmp_html"
    REPORT_MD="$tmp_md"
    REPORT_HTML="$tmp_html"

    # A copy the desktop user owns, in their report folder. It is written by
    # the user, not by root: the folder is theirs, so a symlink in its path
    # must not let root create files elsewhere.
    if [[ -n "$DESKTOP_USER" && -n "$REPORT_DIR" && "$REPORT_DIR" != "$STATE_DIR/reports" ]]; then
        if _as_desktop_user mkdir -p -- "$REPORT_DIR" 2>/dev/null \
           && _write_as_desktop_user "$REPORT_DIR/${base}.md" < "$tmp_md" \
           && _write_as_desktop_user "$REPORT_DIR/${base}.html" < "$tmp_html"; then
            REPORT_MD="$REPORT_DIR/${base}.md"
            REPORT_HTML="$REPORT_DIR/${base}.html"
        else
            [[ "$REPORT_FALLBACK" -eq 1 ]] || print_status "WARN" "Could not write to ${REPORT_DIR}; the report is in ${STATE_DIR}/reports"
            REPORT_FALLBACK=1
        fi
    fi
}

# _write_as_desktop_user DEST — write stdin to DEST (mode 600) as the desktop user.
_write_as_desktop_user() {
    _as_desktop_user sh -c 'umask 077; cat > "$1"' sh "$1"
}

_write_markdown() {
    local i sev w
    printf '# Bazzite Security Check - %s\n\n' "$(hostname 2>/dev/null)"
    printf '| | |\n|---|---|\n'
    printf '| Date | %s |\n' "$(date '+%Y-%m-%d %H:%M')"
    printf '| System | %s%s |\n' "${OS_PRETTY:-unknown}" "${IMAGE_NAME:+ (image ${IMAGE_NAME}:${IMAGE_TAG:-?}${IMAGE_VERSION:+, ${IMAGE_VERSION}})}"
    printf '| Hardware | %s%s%s |\n' "$CHASSIS" "${VIRT:+, virtual machine (${VIRT})}" \
        "$([[ $DISK_ENCRYPTED == yes ]] && echo ', encrypted disk')"
    printf '| Profile | %s |\n' "$(_profile_line)"
    printf '| **Score** | **%s** |\n' "$(_score_line)"
    printf '| Findings | %s high · %s medium · %s low · %s info |\n' \
        "$(_sev_count high)" "$(_sev_count medium)" "$(_sev_count low)" "$(_sev_count info)"
    if [[ "$(_open_counts)" != "$(_sev_count high) high · $(_sev_count medium) medium · $(_sev_count low) low · $(_sev_count info) info" ]]; then
        printf '| Still open | %s |\n' "$(_open_counts)"
    fi
    if [[ "$FIX_APPLIED$FIX_SKIPPED$FIX_FAILED" != "000" ]]; then
        printf '| Fixes | %s applied · %s skipped · %s failed |\n' "$FIX_APPLIED" "$FIX_SKIPPED" "$FIX_FAILED"
    fi
    printf '\n'
    if [[ "${HAD_PREVIOUS_RUN:-0}" -eq 1 ]]; then
        printf '## Since the last check\n\n'
        [[ ${#DELTA_GONE[@]} -gt 0 ]] && printf -- '- Resolved: %s\n' "${DELTA_GONE[@]}"
        [[ ${#DELTA_NEW[@]} -gt 0 ]] && printf -- '- New: %s\n' "${DELTA_NEW[@]}"
        [[ ${#DELTA_GONE[@]} -eq 0 && ${#DELTA_NEW[@]} -eq 0 ]] && printf -- '- No changes.\n'
        printf '\n'
    fi
    if [[ "$NEEDS_REBOOT" -eq 1 ]]; then
        printf '> **Reboot needed** to finish: %s\n\n' "$(_join '; ' "${REBOOT_REASONS[@]}")"
    fi

    printf '## Findings\n\n'
    if [[ ${#F_SEV[@]} -eq 0 ]]; then
        printf 'Nothing to report - well done.\n\n'
    fi
    while IFS= read -r i; do
        [[ -n "$i" ]] || continue
        sev=$(_sev_label "${F_SEV[$i]}")
        printf '### [%s] %s\n\n' "$sev" "${F_TITLE[$i]}"
        printf '*%s* · %s\n\n' "${CHECK_TITLE[${F_CHECK[$i]}]:-${F_CHECK[$i]}}" "$(_finding_state_label "$i")"
        [[ -n "${F_NOW[$i]}" ]] && printf -- '- **Now:** %s\n' "${F_NOW[$i]}"
        [[ -n "${F_AFTER[$i]}" ]] && printf -- '- **%s:** %s\n' "$([[ -n ${F_FIX[$i]} ]] && echo "After the fix" || echo "Goal")" "${F_AFTER[$i]}"
        [[ -n "${F_NOW[$i]}${F_AFTER[$i]}" ]] && printf '\n'
        printf '%s\n\n' "${F_DETAIL[$i]}"
        if [[ -n "${F_AFFECT[$i]:-}" ]] && _still_open "$i"; then
            printf '**What this affects on Bazzite:**\n\n'
            while IFS= read -r w; do
                [[ -n "$w" ]] && printf -- '- %s\n' "$w"
            done < <(affects_text "$i")
            printf '\n'
        fi
        if [[ -n "${F_FIX[$i]}" && "${F_STATE[$i]}" != "fixed" && -n "${F_WARN[$i]}" ]]; then
            printf '**Before applying the fix:**\n\n'
            while IFS= read -r w; do
                [[ -n "$w" ]] && printf -- '- %s: %s\n' "$(_warn_tag "$w")" "$(_warn_text "$w")"
            done <<< "${F_WARN[$i]}"
            printf '\n'
        fi
        if [[ -n "${F_MANUAL[$i]}" && "${F_STATE[$i]}" != "fixed" ]]; then
            printf '**How to fix it yourself:**\n\n```\n%s\n```\n\n' "${F_MANUAL[$i]}"
        fi
    done < <(_sorted_findings)

    printf '## All checks\n\n| Check | Result | Notes |\n|---|---|---|\n'
    local id note
    for id in "${CHECK_ORDER[@]}"; do
        note="${CHECK_NOTE[$id]:-}${CHECK_NA[$id]:-}${CHECK_SKIPPED[$id]:-}"
        note="${note//$'\n'/; }"
        note="${note//|/\\|}"
        printf '| %s | %s | %s |\n' "${CHECK_TITLE[$id]}" "$(_status_label "${CHECK_STATUS[$id]:-}")" "$note"
    done
    printf '\n## Not checked on purpose\n\n'
    _not_checked_text
    printf '\n## Undo and files\n\n'
    # undo-all.sh exists only once this run has applied a fix.
    if [[ -f "$(_undo_dir)/undo-all.sh" ]]; then
        printf -- '- Undo changes made by this tool: run it again with `--undo` (or `sudo %s`).\n' \
            "$(_undo_dir)/undo-all.sh"
    else
        printf -- '- Undo changes made by this tool: run it again with `--undo`.\n'
    fi
    printf -- '- Run log: `%s`\n' "$RUN_LOG"
    printf -- '- History (root only): `%s`\n\n' "$STATE_DIR"
    printf '_Generated by bazzite-sec-audit %s._\n' "$SCRIPT_VERSION"
}

# _report_group I — the report section of finding I: attention (high or
# medium open), look (low open), notes (info, kept) or fixed.
_report_group() {
    if ! _still_open "$1"; then echo fixed
    elif [[ "${F_STATE[$1]}" == kept || "${F_SEV[$1]}" == info ]]; then echo notes
    elif [[ "${F_SEV[$1]}" == low ]]; then echo look
    else echo attention; fi
}

# _report_todo I — the one thing to do about finding I.
_report_todo() {
    local i="$1" first
    if [[ -n "${F_FIX[$i]}" ]]; then
        printf 'Fix it in Security Check: dashboard → %s → %s (shown with its commands first; can be undone).' \
            "$(_check_area "${F_CHECK[$i]}")" "${CHECK_TITLE[${F_CHECK[$i]}]:-${F_CHECK[$i]}}"
    elif [[ -n "${F_MANUAL[$i]}" ]]; then
        first="${F_MANUAL[$i]%%$'\n'*}"
        printf 'By hand: %s' "$(_clip "$first" 160)"
    else
        printf 'Read the details below.'
    fi
}

# _report_card I — finding I as a card: what it is, now / after, what to
# do, what it affects, side effects; long details and the manual steps fold.
_report_card() {
    local i="$1" sev="${F_SEV[$1]}" cls w nlines head rest
    cls="$sev"; _still_open "$i" || cls+=" fixed"
    printf '<div class="f %s" id="f%s"><h3>%s</h3><div class="meta">%s · %s · %s</div>' \
        "$cls" "$i" "$(_html "${F_TITLE[$i]}")" "$(_sev_label "$sev")" \
        "$(_html "${CHECK_TITLE[${F_CHECK[$i]}]:-${F_CHECK[$i]}}")" "$(_html "$(_finding_state_label "$i")")"
    if [[ -n "${F_NOW[$i]}${F_AFTER[$i]}" ]]; then
        printf '<table class="na">'
        [[ -n "${F_NOW[$i]}" ]] && printf '<tr><th>Now</th><td>%s</td></tr>' "$(_html "${F_NOW[$i]}")"
        [[ -n "${F_AFTER[$i]}" ]] && printf '<tr><th>%s</th><td>%s</td></tr>' \
            "$([[ -n ${F_FIX[$i]} ]] && echo "After the fix" || echo "Goal")" "$(_html "${F_AFTER[$i]}")"
        printf '</table>'
    fi
    _still_open "$i" && printf '<div class="todo"><b>What to do</b>%s</div>' "$(_html "$(_report_todo "$i")")"
    # Long lists (files, apps) fold after the first lines.
    nlines=$(grep -c '' <<< "${F_DETAIL[$i]}")
    if (( nlines > 10 )); then
        head=$(head -n 6 <<< "${F_DETAIL[$i]}"); rest=$(tail -n +7 <<< "${F_DETAIL[$i]}")
        printf '<p>%s</p><details><summary>Show the other %s lines</summary><p>%s</p></details>' \
            "$(_reflow_html "$head")" "$(( nlines - 6 ))" "$(_reflow_html "$rest")"
    else
        printf '<p>%s</p>' "$(_reflow_html "${F_DETAIL[$i]}")"
    fi
    if [[ -n "${F_AFFECT[$i]:-}" ]] && _still_open "$i"; then
        printf '<div class="meta">What this affects on Bazzite:</div><ul class="affects">'
        while IFS= read -r w; do
            [[ -n "$w" ]] && printf '<li>%s</li>' "$(_html "$w")"
        done < <(affects_text "$i")
        printf '</ul>'
    fi
    if [[ -n "${F_FIX[$i]}" && "${F_STATE[$i]}" != "fixed" && -n "${F_WARN[$i]}" ]]; then
        printf '<div class="meta">Before applying the fix:</div><ul class="warn">'
        while IFS= read -r w; do
            [[ -n "$w" ]] && printf '<li><b>%s</b> - %s</li>' "$(_html "$(_warn_tag "$w")")" "$(_html "$(_warn_text "$w")")"
        done <<< "${F_WARN[$i]}"
        printf '</ul>'
    fi
    if [[ -n "${F_MANUAL[$i]}" && "${F_STATE[$i]}" != "fixed" ]]; then
        printf '<details><summary>How to fix it yourself</summary><pre>%s</pre></details>' "$(_html "${F_MANUAL[$i]}")"
    fi
    printf '</div>\n'
}

_write_html() {
    local i sev cls id note w
    cat << 'EOF'
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Bazzite Security Check</title>
<style>
:root{--bg:#f6f5fa;--card:#fff;--fg:#1d1b26;--muted:#5f5b6e;--line:#e2dfeb;--accent:#8a2be2;
--high:#c62828;--medium:#d97706;--low:#2563eb;--info:#6b7280;--ok:#15803d;--code:#f0eef6}
@media (prefers-color-scheme:dark){:root{--bg:#14121a;--card:#1e1b27;--fg:#ece9f5;--muted:#a8a3b8;
--line:#332e40;--accent:#b57bff;--high:#ef5350;--medium:#f59e0b;--low:#60a5fa;--info:#9ca3af;--ok:#4ade80;--code:#2a2636}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
font:15px/1.55 system-ui,-apple-system,"Noto Sans",sans-serif}
main{max-width:960px;margin:0 auto;padding:24px 16px 48px}
h1{font-size:1.6rem;margin:0 0 4px}h2{margin:32px 0 12px;font-size:1.2rem}
.sub{color:var(--muted);margin:0 0 20px}
.top{display:flex;gap:16px;flex-wrap:wrap;align-items:stretch}
.score{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px 22px;min-width:180px;text-align:center}
.score b{display:block;font-size:2.6rem;line-height:1.1;color:var(--accent)}
.facts{flex:1;min-width:260px;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 18px}
.facts div{display:flex;gap:10px;padding:3px 0}.facts div:not(.pills) span:first-child{color:var(--muted);min-width:90px;flex-shrink:0}
.pills{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}
.pill{border-radius:999px;padding:2px 10px;font-size:.85rem;color:#fff}
.p-high{background:var(--high)}.p-medium{background:var(--medium)}.p-low{background:var(--low)}.p-info{background:var(--info)}
.f{background:var(--card);border:1px solid var(--line);border-left:5px solid var(--info);border-radius:10px;padding:12px 16px;margin:10px 0}
.f.high{border-left-color:var(--high)}.f.medium{border-left-color:var(--medium)}.f.low{border-left-color:var(--low)}
.f h3{margin:0 0 4px;font-size:1.02rem}.meta{color:var(--muted);font-size:.85rem;margin-bottom:6px}
.f.fixed{opacity:.75}.f.fixed h3::after{content:" ✓ fixed";color:var(--ok);font-size:.85rem}
p{margin:6px 0;overflow-wrap:anywhere}
pre{background:var(--code);border-radius:8px;padding:10px 12px;font-size:.85rem;margin:6px 0;
white-space:pre-wrap;overflow-wrap:anywhere}
td{overflow-wrap:anywhere}.note p{white-space:pre-wrap}
table{width:100%;border-collapse:collapse;background:var(--card);border-radius:10px;overflow:hidden;font-size:.9rem}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
.s-pass{color:var(--ok)}.s-fail{color:var(--high)}.s-na,.s-skipped{color:var(--muted)}.s-error{color:var(--medium)}
.note{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 16px}
.reboot{border-color:var(--medium)}
table.na{background:none;margin:6px 0;width:auto}table.na th{color:var(--muted);font-weight:normal;padding:2px 12px 2px 0;border:0}
table.na td{padding:2px 0;border:0}
ul.warn{margin:4px 0 6px;padding-left:20px}ul.warn li::marker{content:"⚠  ";color:var(--medium)}
@media (max-width:600px){th:nth-child(3),td:nth-child(3){display:none}}
nav{display:flex;gap:14px;flex-wrap:wrap;margin:14px 0 0;font-size:.9rem}nav a{color:var(--accent);text-decoration:none}
.next{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:6px 0;margin:0}
.next li{list-style:none;display:flex;gap:12px;align-items:flex-start;padding:10px 18px;border-bottom:1px solid var(--line)}
.next li:last-child{border-bottom:0}.next a{color:var(--fg);font-weight:600;text-decoration:none}.next a:hover{text-decoration:underline}
.next .do{color:var(--muted);font-size:.9rem;display:block;font-weight:normal}
.tag{border-radius:6px;padding:1px 7px;font-size:.75rem;font-weight:700;color:#fff;flex-shrink:0;margin-top:3px}
.t-high{background:var(--high)}.t-medium{background:var(--medium)}.t-low{background:var(--low)}.t-info{background:var(--info)}
.areas{display:flex;gap:8px;flex-wrap:wrap;margin:14px 0 0}
.area{border:1px solid var(--line);border-radius:999px;padding:3px 12px;font-size:.85rem;background:var(--card)}
.area.bad{border-color:var(--high);color:var(--high)}.area.warn{border-color:var(--low);color:var(--low)}
.area.ok{border-color:var(--ok);color:var(--ok)}
.todo{border-radius:8px;padding:8px 12px;margin:8px 0;background:var(--code)}
.todo b{display:block;font-size:.85rem;color:var(--accent);margin-bottom:2px}
details{margin:6px 0}summary{cursor:pointer;color:var(--accent);font-size:.9rem}
.empty{color:var(--muted)}
</style></head><body><main>
EOF
    printf '<h1>Bazzite Security Check</h1><p class="sub">%s · %s</p>\n' \
        "$(_html "$(hostname 2>/dev/null)")" "$(date '+%Y-%m-%d %H:%M')"
    printf '<div class="top"><div class="score"><b>%s</b>out of 100 · grade %s%s</div><div class="facts">\n' \
        "$SCORE_NOW" "$GRADE_NOW" "$([[ $SCORE_NOW != "$SCORE" ]] && printf '<br><small>%s when checked; fixes checked again count</small>' "$SCORE")"
    printf '<div><span>System</span><span>%s</span></div>\n' \
        "$(_html "${OS_PRETTY:-unknown}${IMAGE_NAME:+ (${IMAGE_NAME}:${IMAGE_TAG:-?})}")"
    printf '<div><span>Version</span><span>%s</span></div>\n' "$(_html "${IMAGE_VERSION:--}")"
    printf '<div><span>Profile</span><span>%s</span></div>\n' "$(_html "$(_profile_line)")"
    if [[ "$FIX_APPLIED$FIX_SKIPPED$FIX_FAILED" != "000" ]]; then
        printf '<div><span>Fixes</span><span>%s applied · %s skipped · %s failed</span></div>\n' \
            "$FIX_APPLIED" "$FIX_SKIPPED" "$FIX_FAILED"
    fi
    printf '<div class="pills"><span class="pill p-high">%s high</span><span class="pill p-medium">%s medium</span>' \
        "$(_open_count high)" "$(_open_count medium)"
    printf '<span class="pill p-low">%s low</span><span class="pill p-info">%s info</span>%s</div></div></div>\n' \
        "$(_open_count low)" "$(_open_count info)" "$([[ $SCORE_NOW != "$SCORE" ]] && echo ' <span class="sub">open now</span>')"

    if [[ "$NEEDS_REBOOT" -eq 1 ]]; then
        printf '<h2>Reboot needed</h2><div class="note reboot">%s</div>\n' \
            "$(_html "$(_join '; ' "${REBOOT_REASONS[@]}")")"
    fi
    if [[ "${HAD_PREVIOUS_RUN:-0}" -eq 1 ]]; then
        printf '<h2>Since the last check</h2><div class="note">'
        [[ ${#DELTA_GONE[@]} -gt 0 ]] && printf '✔ Resolved: %s<br>' "$(_html "$(_join '; ' "${DELTA_GONE[@]}")")"
        [[ ${#DELTA_NEW[@]} -gt 0 ]] && printf '⚠ New: %s<br>' "$(_html "$(_join '; ' "${DELTA_NEW[@]}")")"
        [[ ${#DELTA_GONE[@]} -eq 0 && ${#DELTA_NEW[@]} -eq 0 ]] && printf 'No changes.'
        printf '</div>\n'
    fi

    # Areas at a glance and a short way through the page.
    printf '<div class="areas">'
    local area ast
    while IFS=$'\t' read -r area ast; do
        [[ -n "$area" ]] && printf '<span class="area %s">%s %s</span>' "$ast" "$(_state_icon "$ast")" "$(_html "$area")"
    done < <(_area_states)
    printf '</div>\n<nav><a href="#next">What to do next</a><a href="#attention">Needs attention</a><a href="#look">Worth a look</a><a href="#notes">Notes</a><a href="#checks">All checks</a><a href="#undo">Undo</a></nav>\n'

    # What to do next: the open problems, most severe first, each with the
    # one thing to do about it.
    printf '<h2 id="next">What to do next</h2>\n'
    local n=0 todo
    while IFS= read -r i; do
        [[ -n "$i" ]] && _still_open "$i" && [[ "${F_SEV[$i]}" =~ ^(high|medium|low)$ ]] || continue
        (( n == 0 )) && printf '<ol class="next">'
        n=$((n + 1))
        printf '<li><span class="tag t-%s">%s</span><span><a href="#f%s">%s</a><span class="do">%s</span></span></li>' \
            "${F_SEV[$i]}" "$(_sev_label "${F_SEV[$i]}")" "$i" "$(_html "${F_TITLE[$i]}")" "$(_html "$(_report_todo "$i")")"
        (( n >= 10 )) && break
    done < <(_sorted_findings)
    if (( n == 0 )); then printf '<div class="note">Nothing needs doing - well done.</div>\n'; else printf '</ol>\n'; fi

    # The findings, by how urgent they are.
    local group gid gtitle any
    for group in attention look notes fixed; do
        case "$group" in
            attention) gtitle="Needs attention" ;;
            look)      gtitle="Worth a look" ;;
            notes)     gtitle="Notes and problems kept on purpose" ;;
            fixed)     gtitle="Fixed in this run" ;;
        esac
        any=0
        while IFS= read -r i; do
            [[ -n "$i" ]] || continue
            [[ "$(_report_group "$i")" == "$group" ]] || continue
            (( any )) || printf '<h2 id="%s">%s</h2>\n' "$group" "$gtitle"
            any=1
            _report_card "$i"
        done < <(_sorted_findings)
        (( any )) || [[ "$group" == fixed ]] || printf '<h2 id="%s">%s</h2><div class="note empty">None.</div>\n' "$group" "$gtitle"
    done

    printf '<h2 id="checks">All checks</h2><table><tr><th>Check</th><th>Result</th><th>Notes</th></tr>\n'
    for id in "${CHECK_ORDER[@]}"; do
        note="${CHECK_NOTE[$id]:-}${CHECK_NA[$id]:-}${CHECK_SKIPPED[$id]:-}"
        printf '<tr><td>%s</td><td class="s-%s">%s</td><td>%s</td></tr>\n' \
            "$(_html "${CHECK_TITLE[$id]}")" "${CHECK_STATUS[$id]:-na}" \
            "$(_status_label "${CHECK_STATUS[$id]:-}")" "$(_rich "$note")"
    done
    printf '</table>\n<h2>Not checked on purpose</h2><div class="note"><p>%s</p></div>\n' \
        "$(_html "$(_not_checked_text)")"
    local undo_all=""
    [[ -f "$(_undo_dir)/undo-all.sh" ]] && undo_all=", or <code>sudo $(_html "$(_undo_dir)/undo-all.sh")</code>"
    printf '<h2 id="undo">Undo</h2><div class="note">Run the tool again with <code>--undo</code> to reverse changes it made%s.<br>Run log: <code>%s</code></div>\n' \
        "$undo_all" "$(_html "$RUN_LOG")"
    printf '<p class="sub">Generated by bazzite-sec-audit %s</p></main></body></html>\n' "$SCRIPT_VERSION"
}

# _term_color SCORE — green, yellow or red for the terminal summary.
_term_color() {
    if (( $1 >= 80 )); then printf '%s' "$GREEN"; elif (( $1 >= 60 )); then printf '%s' "$YELLOW"; else printf '%s' "$RED"; fi
}

print_summary() {
    printf '\n%s══════════════════════════════════════════════════════%s\n' "$BOLD" "$RESET"
    printf '  Score: %s%s%s/100 (grade %s)   %s high · %s medium · %s low · %s info\n' \
        "$(_term_color "$SCORE")$BOLD" "$SCORE" "$RESET" "$GRADE" \
        "$(_sev_count high)" "$(_sev_count medium)" "$(_sev_count low)" "$(_sev_count info)"
    if [[ "$SCORE_NOW" != "$SCORE" ]]; then
        printf '  After the fixes that were checked again: %s%s%s/100 (grade %s); still open: %s\n' \
            "$(_term_color "$SCORE_NOW")$BOLD" "$SCORE_NOW" "$RESET" "$GRADE_NOW" "$(_open_counts)"
    fi
    if [[ "$FIX_APPLIED$FIX_SKIPPED$FIX_FAILED" != "000" ]]; then
        printf '  Fixes: %s applied · %s skipped · %s failed\n' "$FIX_APPLIED" "$FIX_SKIPPED" "$FIX_FAILED"
    fi
    if [[ "${HAD_PREVIOUS_RUN:-0}" -eq 1 ]]; then
        [[ ${#DELTA_GONE[@]} -gt 0 ]] && printf '  %s✔ Resolved since last check:%s %s\n' "$GREEN" "$RESET" "$(_join '; ' "${DELTA_GONE[@]}")"
        [[ ${#DELTA_NEW[@]} -gt 0 ]] && printf '  %s⚠ New since last check:%s %s\n' "$YELLOW" "$RESET" "$(_join '; ' "${DELTA_NEW[@]}")"
    fi
    [[ "$NEEDS_REBOOT" -eq 1 ]] && printf '  %sReboot needed:%s %s\n' "$YELLOW" "$RESET" "$(_join '; ' "${REBOOT_REASONS[@]}")"
    printf '  Report: %s\n          %s\n' "$REPORT_HTML" "$REPORT_MD"
    printf '%s══════════════════════════════════════════════════════%s\n' "$BOLD" "$RESET"
}

# final_dialog — closing summary when the dashboard was skipped
# (--no-dashboard); offers to open the HTML report.
final_dialog() {
    [[ "$UI_MODE" == "kde" ]] || return 0
    local text
    text="Score: $(_score_line)
Still open: $(_open_counts)"
    if [[ "$FIX_APPLIED$FIX_SKIPPED$FIX_FAILED" != "000" ]]; then
        text+=$'\n'"Fixes: ${FIX_APPLIED} applied, ${FIX_SKIPPED} skipped, ${FIX_FAILED} failed"
        [[ "$FIX_APPLIED" -gt 0 ]] && text+=$'\n'"Changed your mind? Run the tool with --undo."
    fi
    [[ "$NEEDS_REBOOT" -eq 1 ]] && text+=$'\n\n'"Reboot to finish: $(_join '; ' "${REBOOT_REASONS[@]}")"
    if [[ "$REPORT_FALLBACK" -eq 1 ]]; then
        text+=$'\n\n'"The report could not be saved in ${REPORT_DIR} (${DESKTOP_USER} cannot write there), so it is only in ${STATE_DIR}/reports, which only root can read. Run the tool with --wizard to choose another folder."
        ui_msg "$text"
        return 0
    fi
    text+=$'\n\n'"Report: ${REPORT_HTML}"
    if ui_yesno "$text" "Open the report" "Close" "y"; then
        _open_report
    fi
}
