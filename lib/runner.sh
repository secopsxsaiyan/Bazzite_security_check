# shellcheck shell=bash
# The list of checks, how each is run, scoring and the comparison with the
# last run.

# Standard checks, in run order: id|weight|title. The weight is the most a
# check's findings can take off the score.
declare -ga STANDARD_CHECKS=(
    "check_image_signature|15|System image signature"
    "check_system_updates|12|System updates"
    "check_layered_packages|4|Layered packages and overrides"
    "check_repos|5|Package repositories"
    "check_flatpak|8|Flatpak updates and remotes"
    "check_flatpak_sandbox|4|Flatpak app permissions"
    "check_firmware|3|Firmware updates"
    "check_secure_boot|5|Secure Boot"
    "check_disk_encryption|8|Disk encryption"
    "check_kernel_args|8|Kernel arguments and CPU mitigations"
    "check_anticheat_ready|4|Anti-cheat readiness (Easy Anti-Cheat Linux v2)"
    "check_selinux|12|SELinux"
    "check_sysctl|5|Kernel hardening settings"
    "check_firewall|15|Firewall"
    "check_listening_services|10|Services reachable from the network"
    "check_ssh_server|12|SSH server"
    "check_accounts|15|User accounts and passwords"
    "check_sudo|8|sudo rules"
    "check_autologin|6|Automatic login"
    "check_screen_lock|5|Screen locking"
    "check_home_permissions|6|Home folder permissions"
    "check_secrets|10|Keys and secrets in home folders"
    "check_containers|8|Docker and containers"
    "check_game_streaming|8|Game streaming (Sunshine)"
)

declare -ga DEEP_CHECKS=(
    "check_deep_suid|8|SUID/SGID files outside the image"
    "check_deep_world_writable|5|World-writable files"
    "check_deep_autostart|6|Autostart and persistence entries"
    "check_deep_etc_changes|1|Changes to /etc compared with the image"
    "check_deep_malware|15|Malware scan (ClamAV)"
)

declare -gA CHECK_WEIGHT=() CHECK_TITLE=()
declare -ga CHECK_ORDER=()
declare -ga RUN_ONLY=() SKIP_CHECKS=()
_CHECK_TOTAL=0

_load_check_table() {
    local entry id w t
    for entry in "${STANDARD_CHECKS[@]}" "${DEEP_CHECKS[@]}"; do
        IFS='|' read -r id w t <<< "$entry"
        CHECK_WEIGHT["$id"]="$w"
        CHECK_TITLE["$id"]="$t"
    done
}

_known_check() { [[ -n "${CHECK_TITLE[$1]:-}" ]]; }

# _requested CHECK — CHECK was named with --check.
_requested() {
    local c
    for c in "${RUN_ONLY[@]}"; do [[ "$c" == "$1" ]] && return 0; done
    return 1
}

_selected() {
    local fn="$1" c
    if [[ ${#RUN_ONLY[@]} -gt 0 ]]; then
        for c in "${RUN_ONLY[@]}"; do [[ "$c" == "$fn" ]] && break; done
        [[ "$c" == "$fn" ]] || return 1
    fi
    for c in "${SKIP_CHECKS[@]}"; do [[ "$c" == "$fn" ]] && return 1; done
    return 0
}

# _run_isolated FN — run a check; a command that fails unexpectedly inside
# it is counted (and logged) instead of stopping the audit.
_run_isolated() {
    local fn="$1"
    _ISOLATION_SUBSHELL=$BASH_SUBSHELL
    set -E
    trap '_on_check_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
    "$fn"
    trap - ERR
    set +E
    return 0
}

_on_check_error() {
    [[ "$BASH_SUBSHELL" -eq "${_ISOLATION_SUBSHELL:-0}" ]] || return 0
    local id="${CURRENT_CHECK:-unknown}"
    CHECK_ERRORS["$id"]=$(( ${CHECK_ERRORS[$id]:-0} + 1 ))
    log "${id}: unexpected failure (exit $1) at line $2: $3"
}

_run_check() {
    local fn="$1"
    CURRENT_CHECK="$fn"
    if ! declare -F "$fn" >/dev/null; then
        CHECK_SKIPPED["$fn"]="not implemented"
    else
        _run_isolated "$fn"
    fi
    CURRENT_CHECK=""
    [[ -t 2 && "${QUIET:-0}" -eq 0 ]] && printf '\r%-70s\r' '' >&2
    local errors="${CHECK_ERRORS[$fn]:-0}"
    if [[ -n "${CHECK_FAILED[$fn]:-}" ]]; then
        CHECK_STATUS["$fn"]="fail"
    elif [[ -n "${CHECK_NA[$fn]:-}" ]]; then
        CHECK_STATUS["$fn"]="na"
        record_finding "$fn" "not applicable" "na" "${CHECK_NA[$fn]}"
    elif [[ -n "${CHECK_SKIPPED[$fn]:-}" ]]; then
        CHECK_STATUS["$fn"]="skipped"
        record_finding "$fn" "not checked" "skipped" "${CHECK_SKIPPED[$fn]}"
    elif [[ "$errors" -gt 0 ]]; then
        # Never report a check that went wrong as passed.
        CHECK_STATUS["$fn"]="error"
        record_finding "$fn" "did not complete" "error" "${errors} unexpected error(s); see the run log"
    else
        CHECK_STATUS["$fn"]="pass"
        record_finding "$fn" "passed" "pass" ""
    fi
    case "${CHECK_STATUS[$fn]}" in
        pass)    print_status "OK" "${CHECK_TITLE[$fn]}" ;;
        fail)    print_status "WARN" "${CHECK_TITLE[$fn]}: $(_check_finding_count "$fn") finding(s)" ;;
        na)      print_status "INFO" "${CHECK_TITLE[$fn]}: not applicable" ;;
        skipped) print_status "INFO" "${CHECK_TITLE[$fn]}: skipped - ${CHECK_SKIPPED[$fn]}" ;;
        error)   print_status "WARN" "${CHECK_TITLE[$fn]}: did not complete (see log)" ;;
    esac
}

_check_finding_count() {
    local i n=0
    for i in "${!F_CHECK[@]}"; do
        [[ "${F_CHECK[$i]}" == "$1" ]] && n=$((n + 1))
    done
    echo "$n"
}

run_all_checks() {
    local entry id
    CHECK_ORDER=()
    for entry in "${STANDARD_CHECKS[@]}"; do
        id="${entry%%|*}"
        _selected "$id" && CHECK_ORDER+=("$id")
    done
    # Deep checks run in deep mode, or when asked for by name (--check).
    for entry in "${DEEP_CHECKS[@]}"; do
        id="${entry%%|*}"
        if [[ "$DEEP" -eq 1 ]] || _requested "$id"; then
            _selected "$id" && CHECK_ORDER+=("$id")
        fi
    done
    _CHECK_TOTAL=${#CHECK_ORDER[@]}
    print_status "INFO" "Running ${_CHECK_TOTAL} checks ($(_depth_label)) for: $(_usecase_summary)"
    ui_progress_start "Checking your PC…" "$_CHECK_TOTAL"
    local n=0
    for id in "${CHECK_ORDER[@]}"; do
        n=$((n + 1))
        # The malware scan takes minutes: the bar holds at 90% meanwhile.
        ui_progress_set "$n" "${CHECK_TITLE[$id]}" "$([[ $id == check_deep_malware ]] && echo slow)"
        _run_check "$id"
    done
    ui_progress_stop
}

# _depth_label — how deep this run checks: "deep check", "standard check",
# or "standard check + named deep checks" (deep checks given with --check).
_depth_label() {
    local id
    if [[ "$DEEP" -eq 1 ]]; then echo "deep check"; return 0; fi
    for id in "${CHECK_ORDER[@]}"; do
        if [[ "$id" == check_deep_* ]]; then echo "standard check + named deep checks"; return 0; fi
    done
    echo "standard check"
}

# ====================== SCORE ======================
SCORE=100; GRADE="A"            # when the checks ran
SCORE_NOW=100; GRADE_NOW="A"    # counting fixes of this run that were checked again

# _resolved I — a re-check in this run confirmed finding I is gone: its fix
# was verified, or another fix made it go away ("gone").
_resolved() {
    [[ "${F_VERIFY[$1]}" == "gone" ]] || [[ "${F_STATE[$1]}" == "fixed" && "${F_VERIFY[$1]}" == "verified" ]]
}

# _still_open I — finding I still needs attention: not gone, and not fixed
# in this run (a fix waiting for a reboot or not checked again counts as
# fixed, as on the dashboard rows; one the re-check still finds does not).
_still_open() {
    [[ "${F_VERIFY[$1]}" == "gone" ]] && return 1
    [[ "${F_STATE[$1]}" != "fixed" || "${F_VERIFY[$1]}" == "still" ]]
}

# _score found|now — the score from the findings (each check loses at most
# its weight). "now" leaves out findings whose fix was verified.
_score() {
    local mode="${1:-found}" id st w d i total=0 lost=0
    local -A pts=()
    for i in "${!F_SEV[@]}"; do
        [[ "$mode" == "now" ]] && _resolved "$i" && continue
        pts["${F_CHECK[$i]}"]=$(( ${pts[${F_CHECK[$i]}]:-0} + $(_sev_points "${F_SEV[$i]}") ))
    done
    for id in "${CHECK_ORDER[@]}"; do
        st="${CHECK_STATUS[$id]:-}"
        [[ "$st" == "pass" || "$st" == "fail" ]] || continue
        w="${CHECK_WEIGHT[$id]:-5}"
        d="${pts[$id]:-0}"
        (( d > w )) && d=$w
        total=$((total + w))
        lost=$((lost + d))
    done
    if (( total == 0 )); then echo 100; else echo $(( (100 * (total - lost) + total / 2) / total )); fi
}

_grade() {
    if   (( $1 >= 90 )); then echo A
    elif (( $1 >= 80 )); then echo B
    elif (( $1 >= 70 )); then echo C
    elif (( $1 >= 60 )); then echo D
    else echo F; fi
}

compute_score() {
    SCORE=$(_score found); GRADE=$(_grade "$SCORE")
    SCORE_NOW=$SCORE; GRADE_NOW=$GRADE
}

update_score_now() {
    SCORE_NOW=$(_score now); GRADE_NOW=$(_grade "$SCORE_NOW")
}

# _open_count SEV — findings of SEV that still need attention.
_open_count() {
    local i n=0
    for i in "${!F_SEV[@]}"; do
        [[ "${F_SEV[$i]}" == "$1" ]] || continue
        _still_open "$i" && n=$((n + 1))
    done
    echo "$n"
}

# _sev_count SEV — number of findings of SEV.
_sev_count() {
    local s n=0
    for s in "${F_SEV[@]}"; do [[ "$s" == "$1" ]] && n=$((n + 1)); done
    echo "$n"
}


# ====================== CHANGES SINCE LAST RUN ======================
declare -ga DELTA_NEW=() DELTA_GONE=()

# _delta_key CHECK TITLE — what identifies a finding across runs: numbers
# that stand alone in the title (counts, ages) are left out, so "The system
# image is 15 days old" and "... 16 days old" are the same finding, not one
# resolved and one new. Digits that are part of a name (account 'kid1',
# repository 'copr:foo2') are kept. Must match the Python side of compute_delta.
_delta_key() {
    local t="${2//$'\n'/ }" out="" run
    while [[ "$t" =~ ^([^0-9]*)([0-9]+)(.*)$ ]]; do
        out+="${BASH_REMATCH[1]}"
        run="${BASH_REMATCH[2]}"
        t="${BASH_REMATCH[3]}"
        if [[ "${out: -1}" == [A-Za-z_\'-] || "${t:0:1}" == [A-Za-z_\'-] ]]; then
            out+="$run"
        else
            out+="#"
        fi
    done
    printf '%s | %s' "$1" "${out}${t}"
}

# compute_delta — findings that are new or gone compared with earlier runs.
# Each check is compared with its last known result (the newest earlier run
# in which it ran), so a run limited with --check does not make older
# findings look new or fixed.
compute_delta() {
    DELTA_NEW=(); DELTA_GONE=()
    local -a prev=()
    mapfile -t prev < <(find "$STATE_DIR/history" -maxdepth 1 -name 'findings-*.jsonl' \
        ! -name "findings-${RUN_ID}.jsonl" 2>/dev/null | sort -r)
    [[ ${#prev[@]} -gt 0 && -n "${prev[0]}" ]] || return 0
    local -A old=() cur=()
    local key title
    while IFS=$'\t' read -r key title; do
        [[ -n "$key" ]] && old["$key"]="$title"
    done < <(python3 -I -c '
import json, re, sys
seen, out = set(), []
for path in sys.argv[1:]:            # newest first
    rows = []
    try:
        with open(path) as f:
            rows = [json.loads(l) for l in f if l.strip()]
    except Exception:
        continue
    checks = {r.get("check_id") for r in rows} - seen
    for r in rows:
        if r.get("check_id") in checks and r.get("status") in ("high", "medium", "low"):
            title = r["title"].replace("\n", " ").replace("\t", " ")
            # \x27 is a quote character (this program is in single quotes).
            key = re.sub(r"(?<![A-Za-z0-9_\x27-])[0-9]+(?![A-Za-z0-9_\x27-])", "#", title)
            out.append(r["check_id"] + " | " + key + "\t" + title)
    seen |= checks
print("\n".join(out))' "${prev[@]}" 2>/dev/null || true)
    HAD_PREVIOUS_RUN=1
    local i cid
    for i in "${!F_TITLE[@]}"; do
        [[ "${F_SEV[$i]}" == "info" ]] && continue
        key=$(_delta_key "${F_CHECK[$i]}" "${F_TITLE[$i]//$'\t'/ }")
        cur["$key"]=1
        cid="${F_CHECK[$i]}"
        # Only checks with an earlier result can have "new" findings.
        if [[ -z "${old[$key]:-}" ]] && _ran_before "$cid" "${prev[@]}"; then
            DELTA_NEW+=("${F_TITLE[$i]}")
        fi
    done
    for key in "${!old[@]}"; do
        cid="${key%% | *}"
        [[ "${CHECK_STATUS[$cid]:-}" == "pass" || "${CHECK_STATUS[$cid]:-}" == "fail" ]] || continue
        [[ -z "${cur[$key]:-}" ]] && DELTA_GONE+=("${old[$key]}")
    done
    return 0
}

# _ran_before CHECK FILE... — CHECK has a result in one of the history FILEs.
_ran_before() {
    local id="$1"
    shift
    grep -qsF "{\"check_id\": \"${id}\"" "$@"
}
