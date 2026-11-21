# shellcheck shell=bash
# User interface: windows on the desktop user's Plasma session (the
# Kirigami front end, ui/app.py; kdialog where that cannot run) with a
# terminal fallback. Every function works in three modes:
#   kde   windows on the user's Plasma desktop
#   tty   questions on the terminal
#   none  no one to ask (systemd timer): questions get their safe default,
#         which never changes anything.

UI_MODE="none"
UI_PREF="${UI_PREF:-auto}"     # auto | gui | tty (from --gui / --no-gui)
UI_TITLE="Bazzite Security Check"
_PROGRESS_REF=""
_QML_OK=""             # "", "yes" or "no": can the Kirigami front end run?
_UI_THEME_DIR=""       # config folder that gives kdialog the chosen theme

# _desktop_display_ok — the desktop user has a Wayland or X11 display we can reach.
_desktop_display_ok() {
    [[ -n "$DESKTOP_UID" ]] || return 1
    local f
    if [[ -n "${AUDIT_GUI_WAYLAND:-}" && -S "/run/user/${DESKTOP_UID}/${AUDIT_GUI_WAYLAND}" ]]; then
        return 0
    fi
    for f in /run/user/"${DESKTOP_UID}"/wayland-[0-9]; do
        [[ -S "$f" ]] && return 0
    done
    [[ -n "${AUDIT_GUI_DISPLAY:-}" || -S /tmp/.X11-unix/X0 ]]
}

_tty_ok() { [[ -t 0 ]] && [[ -r /dev/tty ]]; }

ui_init() {
    UI_MODE="none"
    if [[ "$UI_PREF" != "tty" ]] && _have kdialog && _desktop_display_ok; then
        UI_MODE="kde"
    elif [[ "$UI_PREF" != "gui" ]] && _tty_ok; then
        UI_MODE="tty"
    elif [[ "$UI_PREF" == "gui" ]] && _tty_ok; then
        print_status "WARN" "No KDE session or kdialog found - using the terminal instead"
        UI_MODE="tty"
    fi
    log "UI mode: ${UI_MODE}"
}

ui_interactive() { [[ "$UI_MODE" != "none" ]]; }

# _ui_fallback — kdialog cannot be used: continue on the terminal, or with
# safe defaults when there is none.
_ui_fallback() {
    if _tty_ok; then UI_MODE="tty"; else UI_MODE="none"; fi
}

# _ui_icon — the app icon: its name once installed, else a stock one.
_ui_icon() {
    if [[ -f "/usr/local/share/icons/hicolor/scalable/apps/bazzite-security-check.svg" ]]; then
        echo bazzite-security-check
    else
        echo security-high
    fi
}

# _ui_app_cmd — the Kirigami front end, run as the desktop user (never as
# root) with the chosen theme. BSA_OWNER_PID: the tool's main shell; the
# front end leaves when that process is no longer there.
_ui_app_cmd() {
    _as_desktop_user env BSA_THEME="${UI_THEME:-system}" BSA_OWNER_PID="$_UI_FRONT_OWNER" \
        python3 -I "$SCRIPT_DIR/ui/app.py" "$@"
}

# _qml_ok — the Kirigami front end can run here: KDE dialogs are in use,
# and PySide6 and Kirigami are installed (checked once), and the front end
# has not failed in this run. Once it is not to be used, its window is
# closed too: the kdialog windows take over.
_qml_ok() {
    if [[ -z "$_QML_OK" ]]; then
        _QML_OK=no
        if [[ "$UI_MODE" == "kde" && -f "$SCRIPT_DIR/ui/app.py" ]] \
           && compgen -G "/usr/lib*/qt6/qml/org/kde/kirigami" >/dev/null \
           && _as_desktop_user python3 -I -c 'import PySide6.QtQml, PySide6.QtWidgets' >/dev/null 2>&1; then
            _QML_OK=yes
        fi
    fi
    if [[ "$_QML_OK" == yes && -n "${RUN_TMP:-}" && -e "${RUN_TMP}/ui-front-gone" ]]; then
        _QML_OK=no
    fi
    # Started, but its helper has ended since (see _ui_front_up).
    if [[ "$_QML_OK" == yes && -n "$_UI_FRONT_W" ]] && ! _ui_front_up; then
        _QML_OK=no
    fi
    [[ "$_QML_OK" == yes ]] && return 0
    ui_front_stop
    return 1
}

# ====================== THE ONE WINDOW ======================
# Every Kirigami page is shown by one front-end process ("ui/app.py serve",
# run as the desktop user) in one window, which stays open for the whole
# run. This side writes one JSON line per request to its input and reads
# one JSON line per answer (the protocol is described in ui/app.py).
#
# It is started here, in the main shell, so that the two pipes are open in
# every $(...) subshell a page is asked from. Until the first request it is
# an idle process: no Qt, no window. What a subshell learns is lost when it
# ends, so "the front end has gone or failed" is a file in RUN_TMP,
# ui-front-gone (as for kdialog).
#
# The desktop user's account is trusted less than root, so the front end
# gets nothing of root's but the two pipes and a third one for its stderr:
# never the run log itself (see _ui_log_reader), and an answer line is only
# read up to _UI_FRONT_LINE_MAX bytes. Nor is it trusted to answer, to end
# or to stay: this side notices within a second when it has gone, whoever
# still holds its pipes (_ui_front_ask), and never waits for it without a
# limit when the tool itself ends (ui_front_stop).
_UI_FRONT_W=""         # file descriptor: requests to the front end
_UI_FRONT_R=""         # file descriptor: its answers
_UI_FRONT_PID=""       # the helper subshell that runs it (not python itself)
_UI_FRONT_START=""     # ... and its start time: the two together name it
_UI_FRONT_ANSWER=""
_UI_FRONT_OWNER="$BASHPID"     # the shell that may start it and holds the pipes
# An answer line must be shorter than this many bytes. The callers hand the
# answer to a checking script as one program argument, which the kernel
# limits to 128 KiB; this limit is well below that, so it is the one that
# counts. The answers of the pages are a few hundred bytes.
_UI_FRONT_LINE_MAX=65536
_UI_LOG_MAX=262144             # most stderr bytes logged per front-end process

# _ui_front_up — the front end was started and has not gone away: the file
# does not say so, and the helper that runs it is still there. The helper
# is what reads the request pipe to the end and writes the file when the
# front end ends. When it has ended itself (a signal that went to every
# process of this tool, while this shell held it back to finish recording
# a fix), nobody may be reading the pipe any more: the front end counts as
# gone from then on, and the file says so to every other shell.
_ui_front_up() {
    [[ -n "$_UI_FRONT_W" && ! -e "${RUN_TMP:-}/ui-front-gone" ]] || return 1
    if ! _proc_stat "$_UI_FRONT_PID" || [[ "$_PS_START" != "$_UI_FRONT_START" ]]; then
        log "The Security Check window's helper process has ended; using KDE dialogs from here on"
        _ui_front_gone_mark
        return 1
    fi
    _ui_front_note
    return 0
}

# _ui_front_gone_mark — write the file that says "the front end has gone
# or failed" to every shell of this run.
_ui_front_gone_mark() {
    if [[ -n "${RUN_TMP:-}" && -d "$RUN_TMP" ]]; then : > "$RUN_TMP/ui-front-gone"; fi
    return 0
}

# _ui_front_note — remember the front end's processes. ui_front_stop finds
# them from the helper down; should the helper end before the front end
# does, there is nothing to start from, and a front end that hangs would be
# left running. What was seen here last is then what gets ended. It is kept
# in a file of the private folder (ui-front-seen), not in a variable: the
# first pages are asked from $(...), and what such a shell sees must reach
# the main shell, which does the ending. This look is a cheap one
# (_proc_tree ... quick), so it is taken every time a shell of this run
# uses the front end, and once a second while it waits for an answer.
_ui_front_note() {
    [[ -n "${RUN_TMP:-}" && -d "$RUN_TMP" ]] || return 0
    local f="$RUN_TMP/ui-front-seen"
    local -a seen=() old=()
    mapfile -t seen < <(_proc_tree "$_UI_FRONT_PID" "$_UI_FRONT_START" quick)
    (( ${#seen[@]} )) || return 0
    { mapfile -t old < "$f"; } 2>/dev/null
    [[ "${seen[*]}" != "${old[*]}" ]] || return 0
    # In one step (a new file, renamed): no shell reads half a list.
    { printf '%s\n' "${seen[@]}" > "$f.$BASHPID" && mv -f -- "$f.$BASHPID" "$f"; } 2>/dev/null
    return 0
}

# _ui_front_seen — the list _ui_front_note kept, one "PID STARTTIME KIND"
# a line; only lines of that form.
_ui_front_seen() {
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[0-9]+\ [0-9]+\ (own|user|other)$ ]] && printf '%s\n' "$line"
    done 2>/dev/null < "${RUN_TMP:-}/ui-front-seen"
    return 0
}

# _ui_log_reader [STOPFILE] — copy the front end's stderr (this function's
# stdin, a pipe) to the run log, as root: each line cut to size, cleaned
# and marked "ui: " (see _log_foreign), so that the front end can neither
# touch the log file nor write lines that look like this tool's.
#
# At most _UI_LOG_MAX bytes are taken from the pipe, counted by "dd" and
# not by this shell: "read" drops NUL bytes without counting them, so a
# front end that writes nothing else (cat /dev/zero) would otherwise keep
# this reader busy for the rest of the run. (dd with bs=1 passes every
# byte on at once; "head -c" would keep the messages back until its
# buffer is full.) After that many bytes the pipe is closed (the front
# end's further writes fail, which it ignores). The reader ends when the
# pipe is closed and, because a program the front end started can keep the
# pipe open, also within a second of STOPFILE appearing or its folder
# going away: that is looked at when nothing came for a second, and once a
# second while lines keep coming (a program the front end left behind can
# write on and on). Always run in a process of its own (a process
# substitution) that holds nothing but this pipe: the reader closes its
# standard input, and whoever starts it gives it no copy of the window's
# two pipes, not even as its standard output. With one, the answer pipe
# would stay open for as long as the reader lives, and a shell waiting for
# an answer would not see the front end's end.
_ui_log_reader() {
    local stop="${1:-}" line rc total=0 LC_ALL=C in="" hpid hstart="" held=1 looked=$SECONDS
    # exec: the process to end is "dd" itself, a child of this shell.
    exec {in}< <(exec dd bs=1 count="$_UI_LOG_MAX" status=none 2>/dev/null)
    hpid=$!
    exec <&-
    _proc_stat "$hpid" && hstart=$_PS_START
    while :; do
        line=""; rc=0
        IFS= read -r -t 1 -n "$_LOG_FOREIGN_LINE" -u "$in" line || rc=$?
        if [[ -n "$line" || $rc -eq 0 ]]; then
            total=$(( total + ${#line} + 1 ))
            if (( total >= _UI_LOG_MAX )); then
                _log_foreign "ui: " "(the window wrote more than ${_UI_LOG_MAX} bytes of messages; the rest is not recorded)"
                break
            fi
            _log_foreign "ui: " "$line"
        fi
        if (( rc > 0 && rc <= 128 )); then held=0; break; fi    # the pipe was closed, or dd is done
        # Is anyone still there? (rc above 128: nothing came for a second.)
        if [[ -n "$stop" ]] && (( rc > 128 || SECONDS != looked )); then
            looked=$SECONDS
            if [[ -e "$stop" || ! -d "${stop%/*}" ]]; then break; fi
        fi
    done
    # "dd" still holds the pipe when this loop ended first. It is this
    # shell's own child and is ended only while it is still that process.
    exec {in}<&-
    if (( held )) && [[ -n "$hstart" ]]; then _kill_same TERM "$hpid" "$hstart"; fi
    return 0
}

# ui_front_start — start the front end (once; does nothing in a subshell,
# without a private folder for the pipes, or where it cannot run).
ui_front_start() {
    [[ -z "$_UI_FRONT_W" && "$BASHPID" == "$_UI_FRONT_OWNER" ]] || return 0
    [[ -n "${RUN_TMP:-}" && -d "$RUN_TMP" && ! -e "$RUN_TMP/ui-front-gone" ]] || return 0
    _qml_ok || return 0
    local d="$RUN_TMP/ui-front" hq="" hp="" w="" r="" cr="" cw="" efd=""
    if ! mkdir -- "$d" 2>/dev/null || ! mkfifo -- "$d/req" "$d/rep" 2>/dev/null; then
        rm -rf -- "$d"
        return 0
    fi
    # All four ends are opened here, before the helper exists. Opening one
    # end of a pipe waits until the other end is open; opening it for
    # reading and writing at once (hq, hp) never waits, and while those are
    # held no other open does. Were the opening shared with the helper, each
    # side waiting for the other, a helper that was ended before it got
    # there would leave this shell waiting for ever.
    if ! { exec {hq}<> "$d/req" {hp}<> "$d/rep"; } 2>/dev/null \
       || ! { exec {w}> "$d/req" {r}< "$d/rep" {cr}< "$d/req" {cw}> "$d/rep"; } 2>/dev/null; then
        for efd in "$hq" "$hp" "$w" "$r" "$cr" "$cw"; do
            [[ -z "$efd" ]] || exec {efd}>&-
        done
        rm -rf -- "$d"
        return 0
    fi
    exec {hq}>&- {hp}>&-
    rm -rf -- "$d"
    # The helper gets the front end's two ends (cr, cw) as its standard
    # input and output, and closes every other copy. When the front end
    # ends (or cannot start), the helper closes the answer pipe, so a
    # waiting ui_app sees the end at once; then the file says it has gone,
    # and what is still written to it is thrown away: while this helper
    # lives, writing to it never fails (without it, see _pipe_write). It
    # must not hold the run's lock (_run_lock_close).
    # The front end gets its stderr pipe as descriptor 2 and under no other
    # number, and the log reader gets nothing but that pipe.
    (
        exec {w}>&- {r}<&- {cr}<&- {cw}>&-
        _run_lock_close
        exec {efd}> >(exec > /dev/null 2>&1; _ui_log_reader "$RUN_TMP/ui-front-gone")
        _ui_app_cmd serve 2>&"$efd" {efd}>&-
        exec {efd}>&- >&-
        _ui_front_gone_mark 2>/dev/null
        exec cat > /dev/null
    ) <&"$cr" >&"$cw" &
    _UI_FRONT_PID=$!
    exec {cr}<&- {cw}>&-
    _UI_FRONT_W=$w; _UI_FRONT_R=$r
    # It has not ended by itself: it reads its input to the end, and this
    # shell holds the other end. Its start time tells it from any later
    # process with the same id (see ui_front_stop).
    _UI_FRONT_START=""
    _proc_stat "$_UI_FRONT_PID" && _UI_FRONT_START=$_PS_START
    disown "$_UI_FRONT_PID" 2>/dev/null || true
    _ui_front_note
    return 0
}

# _proc_stat PID — a process's parent and start time (fields 4 and 22 of
# its /proc stat line) in _PS_PPID and _PS_START; fails when it is not
# there. The start time tells a process from a later one with the same id.
_PS_PPID=""; _PS_START=""
_proc_stat() {
    local s=""
    { read -r -d '' s < "/proc/$1/stat"; } 2>/dev/null
    [[ -n "$s" ]] || return 1
    s=${s##*) }
    # shellcheck disable=SC2086
    set -- $s
    [[ $# -ge 20 && "$1" != Z ]] || return 1       # Z: ended, not yet collected
    _PS_PPID="$2"; _PS_START="${20}"
}

# _proc_uid PID — the account a process runs as, in _PS_UID; fails when
# the process is not there or its real and effective ids differ (a setuid
# program: nobody's to signal here).
_PS_UID=""
_proc_uid() {
    local k r e rest
    while read -r k r e rest; do
        [[ "$k" == Uid: ]] || continue
        [[ -n "$r" && "$r" == "$e" ]] || return 1
        _PS_UID=$r
        return 0
    done 2>/dev/null < "/proc/$1/status"
    return 1
}

# _kill_same SIGNAL PID STARTTIME — signal one of this tool's own
# processes, and only if PID is still the process that started at
# STARTTIME and still runs as this account: both are read here, directly
# before the signal, so a process that merely got the same id later is
# never signalled.
_kill_same() {
    if ! _proc_stat "$2" || [[ "$_PS_START" != "$3" ]]; then return 1; fi
    if ! _proc_uid "$2" || [[ "$_PS_UID" != "$EUID" ]]; then return 1; fi
    kill -s "$1" "$2" 2>/dev/null
}

# _proc_tree PID STARTTIME — the process PID that started at STARTTIME and
# every process below it, one "PID STARTTIME KIND" a line. KIND says who
# may signal it:
#   own    it runs as this account, and so does everything between it and
#          PID: this tool's helper, runuser, the log reader
#   user   it runs as the desktop user: the front end and what it started
#   other  anything else (a setuid program the front end started): left
#          alone
# Nothing is printed when PID is not that process any more. A second look
# at every process (parent first) drops what changed while /proc was read:
# a process is listed only if it and its parent were still the same ones
# afterwards, so a process that took over an id in between is never taken
# for a child of the tree.
#
# _proc_tree PID STARTTIME quick — the same list without reading all of
# /proc (a tenth of a second on a busy desktop): each process's children
# come from the kernel's own list of them (/proc/PID/task/*/children), and
# a child counts only if it names that process as its parent and the
# process is still the same one after its children were read. A kernel
# built without those lists gets the full reading. For a look that is
# taken often (_ui_front_note); ui_front_stop reads all of /proc.
_proc_tree() {
    local -A kids=() began=() who=()
    local -a todo=("$1")
    local f pid k c list quick="${3:-}"
    [[ -r "/proc/$1/task/$1/children" ]] || quick=""
    if [[ -z "$quick" ]]; then
        for f in /proc/[0-9]*; do
            pid=${f#/proc/}
            _proc_stat "$pid" || continue
            kids[$_PS_PPID]+=" $pid"; began[$pid]=$_PS_START
        done
    elif _proc_stat "$1"; then
        began[$1]=$_PS_START
    fi
    [[ "${began[$1]:-}" == "$2" ]] || return 0
    who[$1]=own
    while (( ${#todo[@]} )); do
        pid=${todo[0]}; todo=("${todo[@]:1}")
        [[ -n "${began[$pid]:-}" ]] || continue
        if ! _proc_stat "$pid" || [[ "$_PS_START" != "${began[$pid]}" ]]; then continue; fi
        if [[ -n "$quick" ]]; then
            for f in "/proc/$pid/task"/*/children; do
                list=""
                { read -r list < "$f"; } 2>/dev/null
                for c in $list; do
                    if [[ "$c" =~ ^[0-9]+$ ]] && _proc_stat "$c" && [[ "$_PS_PPID" == "$pid" ]]; then
                        kids[$pid]+=" $c"; began[$c]=$_PS_START
                    fi
                done
            done
            if ! _proc_stat "$pid" || [[ "$_PS_START" != "${began[$pid]}" ]]; then continue; fi
        fi
        k=other
        if _proc_uid "$pid"; then
            if [[ "$_PS_UID" == "$EUID" && "${who[$pid]}" == own ]]; then
                k=own
            elif [[ -n "${DESKTOP_UID:-}" && "$_PS_UID" == "$DESKTOP_UID" ]]; then
                k=user
            fi
        fi
        printf '%s %s %s\n' "$pid" "${began[$pid]}" "$k"
        for f in ${kids[$pid]:-}; do
            who[$f]=$k
            todo+=("$f")
        done
    done
    return 0
}

# _procs_left "PID STARTTIME KIND"... — those of them that still run.
_procs_left() {
    local p pid st
    for p in "$@"; do
        read -r pid st _ <<< "$p"
        _proc_stat "$pid" && [[ "$_PS_START" == "$st" ]] && printf '%s\n' "$p"
    done
    return 0
}

# What ends the front end's own processes, run as the desktop user (bash
# -c SCRIPT bash SIGNAL "PID STARTTIME"...): it reads each start time
# again and signals in the same breath.
# shellcheck disable=SC2016
_UI_FRONT_KILL_SCRIPT='sig=$1; shift
for p in "$@"; do
    pid=${p% *}; s=""
    { read -r -d "" s < "/proc/$pid/stat"; } 2>/dev/null
    s=${s##*) }
    read -r -a f <<< "$s"
    if [[ ${#f[@]} -ge 20 && "${f[19]}" == "${p#* }" ]]; then kill -s "$sig" "$pid" 2>/dev/null; fi
done
exit 0'

# _ui_front_signal SIGNAL "PID STARTTIME KIND"... — signal what is left of
# a front end (the rules are above ui_front_stop).
_ui_front_signal() {
    local sig="$1" p pid st k
    local -a users=()
    shift
    for p in "$@"; do
        read -r pid st k <<< "$p"
        case "$k" in
            user) users+=("$pid $st") ;;
            own)
                # Root's own, unless it has become the front end since the
                # list was made (runuser's child, before it changes account).
                if ! _kill_same "$sig" "$pid" "$st" \
                   && [[ "$EUID" != "${DESKTOP_UID:-}" ]] && _proc_uid "$pid" \
                   && [[ "$_PS_UID" == "${DESKTOP_UID:-}" ]]; then
                    users+=("$pid $st")
                fi
                ;;
        esac
    done
    if (( ${#users[@]} )); then
        _as_desktop_user bash -c "$_UI_FRONT_KILL_SCRIPT" bash "$sig" "${users[@]}" \
            > /dev/null 2>&1 < /dev/null || true
    fi
    return 0
}

# _ui_front_reap "PID STARTTIME KIND"... — the processes of a front end
# that was told to leave: wait two seconds for them to end by themselves
# (they do, normally at once), then end them (TERM, a second later KILL: a
# stopped process only reacts to that). When only this tool's own helpers
# are left after a moment, the wait is over: they have nothing to finish,
# and stay only because some program holds a copy of a pipe.
_ui_front_reap() {
    local -a left=("$@") still=()
    local sig p i pid st k mine
    for sig in "" TERM KILL; do
        [[ -z "$sig" ]] || _ui_front_signal "$sig" "${left[@]}"
        for (( i = 0; i < ( ${#sig} ? 50 : 100 ); i++ )); do
            still=(); mine=1
            for p in "${left[@]}"; do
                read -r pid st k <<< "$p"
                if _proc_stat "$pid" && [[ "$_PS_START" == "$st" ]]; then
                    still+=("$p")
                    [[ "$k" == own ]] || mine=0
                fi
            done
            left=("${still[@]}")
            (( ${#left[@]} )) || return 0
            if [[ -z "$sig" ]] && (( mine && i >= 10 )); then break; fi
            sleep 0.02
        done
    done
    return 0
}

# ui_front_stop — tell the front end to leave (its window closes), make
# sure that it and what belongs to it (the helper below, runuser, python,
# the log reader) really has ended, and do not use it again in this run.
# Called when the tool ends, and when the front end failed. In a subshell
# the pipes stay open for the main shell; the file tells it.
#
# Ending processes is done by root, on behalf of processes of a less
# trusted account, so it must never hit a process that is not ours. A
# process id alone does not say that: once a process has ended and been
# collected its id is free, and the front end decides when its own
# processes end. So:
#   1. A process is named by its id and its start time together. The
#      helper's are recorded when it is started.
#   2. The list of what belongs to the front end is made first, while this
#      shell still holds the pipes. The helper reads one of them to the
#      end, so until they are closed here it does not end by itself, and
#      the list starts from a process that is certainly the right one
#      (rule 6: when something else has ended it).
#   3. No signal without a check. Root signals only processes that run as
#      root with nothing of the desktop user's above them, and reads the
#      start time again directly before each signal (_kill_same).
#   4. The front end's processes run as the desktop user and are signalled
#      as the desktop user (_UI_FRONT_KILL_SCRIPT, through runuser), again
#      with the start time read directly before. The kernel then refuses
#      a signal to anything that is not that account's, so whatever
#      happens to ids in between, root's signal cannot reach a process of
#      root or of a third account. A setuid program the front end started
#      is nobody's here and is left alone.
#   5. Normally nothing is signalled at all: the processes end by
#      themselves within a fraction of a second and this only watches them
#      go. Signals are for a front end that hangs (TERM after two seconds,
#      KILL a second later), and for root's helpers when some program still
#      holds a copy of a pipe and nothing of the front end's is left.
#   6. When the helper has ended before the front end (rule 2 then has no
#      process to start from), the list is what was last seen below the
#      helper while it lived (_ui_front_note), less what has ended since.
#      Each of those was found by the same rules and is named by its id
#      and start time, so rules 3 and 4 hold for it unchanged.
#   7. Nothing here waits without a limit, whatever the front end does:
#      this runs when the tool ends, and what comes after it (the private
#      folder removed, the run's lock released) must always happen.
ui_front_stop() {
    [[ -n "$_UI_FRONT_W" ]] || return 0
    # Written whether or not the file says "gone": a front end that is
    # still there (its helper is not) must hear it, and otherwise the
    # helper throws the line away or nobody reads it. A front end that has
    # stopped reading, with the pipe full, gets no "quit" (rule 7): it is
    # ended below like any other that does not leave.
    _pipe_write_soon "$_UI_FRONT_W" '{"quit":true}' || true
    _ui_front_gone_mark
    [[ "$BASHPID" == "$_UI_FRONT_OWNER" ]] || return 0
    # The list, while the pipes are still open here (rule 2). The front end
    # is already leaving meanwhile, which is what keeps this short.
    local -a procs=()
    if [[ -n "$_UI_FRONT_PID" && -n "$_UI_FRONT_START" ]]; then
        mapfile -t procs < <(_proc_tree "$_UI_FRONT_PID" "$_UI_FRONT_START")
    fi
    if (( ! ${#procs[@]} )); then
        local -a seen=()
        mapfile -t seen < <(_ui_front_seen)
        (( ${#seen[@]} )) && mapfile -t procs < <(_procs_left "${seen[@]}")     # rule 6
    fi
    exec {_UI_FRONT_W}>&- {_UI_FRONT_R}<&-
    _UI_FRONT_W=""; _UI_FRONT_R=""
    (( ${#procs[@]} )) && _ui_front_reap "${procs[@]}"
    _UI_FRONT_PID=""; _UI_FRONT_START=""
    return 0
}

# _pipe_write FD LINE — one line to a pipe whose reader may have gone;
# fails then (1). A write to a pipe that nobody reads ends the writing
# process with SIGPIPE on the spot: for this shell that would mean no EXIT
# trap, the private folder left behind, and a fix that was just applied
# never recorded. So the signal is ignored, and only for this one write: an
# ignored signal stays ignored in every program started from here, and the
# checks and fixes count on the default (in "find | head", find is ended by
# it when head has read enough). Where the signal was already ignored when
# this shell started, the two "trap" lines change nothing (a shell cannot),
# and the write fails in the same way.
_pipe_write() {
    local rc=0
    trap '' PIPE
    printf '%s\n' "$2" 2>/dev/null 1>&"$1" || rc=1
    trap - PIPE
    return "$rc"
}

# _pipe_write_soon FD LINE — the same, for a pipe that may be full with
# nobody taking anything out of it (a front end that was stopped): a write
# would then wait for ever. So a process of its own writes the line, and
# when it has not ended after a second it is ended and the line given up
# (1; what it wrote of the line stays in the pipe). 0 does not say that
# the line arrived.
_pipe_write_soon() {
    local pid st="" i
    ( _pipe_write "$1" "$2" ) > /dev/null &
    pid=$!
    _proc_stat "$pid" && st=$_PS_START
    disown "$pid" 2>/dev/null || true
    for (( i = 0; i < 50; i++ )); do
        _proc_stat "$pid" || return 0
        sleep 0.02
    done
    [[ -z "$st" ]] || _kill_same KILL "$pid" "$st"
    return 1
}

# _ui_front_send LINE — one line to the front end (1: it is not there).
# This is the one place that makes it one line: a line break in LINE (JSON
# may have them between its parts) becomes a space.
_ui_front_send() {
    _ui_front_up || return 1
    _pipe_write "$_UI_FRONT_W" "${1//$'\n'/ }"
}

# _ui_front_ask MODE JSON — show a page and wait for the answer, which is
# left in _UI_FRONT_ANSWER. Status 0 answered, 1 cancelled, 3 the front end
# failed or went away (it is then not used again). The answer line has one
# fixed form, so it is taken apart here without a JSON parser; the caller
# validates what is in it. There is no time limit (a person answers when
# they answer), but a limit on the length of the line: a front end that
# sends _UI_FRONT_LINE_MAX bytes or more without a line end has failed.
# (Bytes, not characters: LC_ALL=C. The limit is there for memory and for
# the size of a program argument, and both count bytes.)
#
# The wait is for a front end that is there. The end of the answer pipe
# does not always tell that it has gone (a program it started can hold a
# copy), so the line is read a second at a time, and in between this looks
# whether the front end is still up (_ui_front_up, which also notes its
# processes; the first look comes sooner, when the front end has just had
# time to start). What a read took before its time was up is kept: the
# line is put together from the parts.
_ui_front_ask() {
    local id="${BASHPID}-${RANDOM}${RANDOM}" data="$2" line="" part rc pause=0.2 LC_ALL=C
    # The same pattern is in tests/ui-offscreen.py (ANSWER_RE), which holds
    # the real front end to it; tests/smoke.sh checks that the two agree.
    local re='^\{"id":"([^"]*)","status":([0-9]+),"answer":(.*)\}$'
    _UI_FRONT_ANSWER=""
    [[ -n "$data" ]] || data='{}'
    if _ui_front_send "{\"id\":\"${id}\",\"mode\":\"${1}\",\"data\":${data}}"; then
        while :; do
            part=""; rc=0
            IFS= read -r -t "$pause" -n "$_UI_FRONT_LINE_MAX" -u "$_UI_FRONT_R" part || rc=$?
            line+=$part
            # "read" stops at the limit: a line of that length is the start
            # of a longer one. Cut off like that it could still have the
            # form of an answer, so the pattern alone does not refuse it.
            (( ${#line} < _UI_FRONT_LINE_MAX )) || break
            if (( rc > 128 )); then
                pause=1
                _ui_front_up || break
                continue
            fi
            (( rc == 0 )) || break          # the pipe was closed
            [[ "$line" =~ $re ]] || break
            line=""
            if [[ "${BASH_REMATCH[1]}" != "$id" ]]; then
                # No id: the request could not be read. Another id: the
                # answer to an earlier request that was given up.
                [[ -n "${BASH_REMATCH[1]}" ]] || break
                continue
            fi
            # The front end is certainly running now: note its processes.
            case "${BASH_REMATCH[2]}" in
                0) _UI_FRONT_ANSWER="${BASH_REMATCH[3]}"; _ui_front_note; return 0 ;;
                1) _ui_front_note; return 1 ;;
            esac
            break
        done
    fi
    log "The Security Check window failed or went away (${1}); using KDE dialogs from here on"
    ui_front_stop
    return 3
}

# _ui_app_page MODE JSON — the fallback of ui_app: one front-end process
# for this one page ("app.py MODE"), in a window of its own. Used only
# where the long-lived front end could not be started for want of its two
# pipes (no private folder, mkfifo failed). Prints the answer; status 0
# answered, 1 cancelled, 3 anything else: "app.py MODE" has more ways to
# end than that (2 bad input, a signal, runuser's own errors), and none of
# them is an answer. Its stderr reaches the log as the long-lived one's
# does, and its answer has the same limit: "head" takes no more than
# _UI_FRONT_LINE_MAX bytes of what it prints, and that many is too long.
_ui_app_page() {
    local out rc=0 stop="" efd LC_ALL=C
    if [[ -n "${RUN_LOG:-}" && -n "${RUN_TMP:-}" && -d "$RUN_TMP" ]]; then
        stop="$RUN_TMP/ui-page-done.${BASHPID}.${RANDOM}"
        exec {efd}> >(exec > /dev/null 2>&1; _ui_log_reader "$stop")
    else
        # No private folder to tell the log reader "done" in: no log.
        exec {efd}> /dev/null
    fi
    out=$(set -o pipefail
          _ui_app_cmd "$1" <<< "$2" 2>&"$efd" {efd}>&- | head -c "$_UI_FRONT_LINE_MAX") || rc=$?
    exec {efd}>&-
    [[ -z "$stop" ]] || : > "$stop"
    if (( ${#out} >= _UI_FRONT_LINE_MAX )); then
        log "The Security Check window's answer was too long (${1})"
        rc=3; out=""
    fi
    case "$rc" in
        0) printf '%s' "$out" ;;
        1) ;;
        *) log "The Security Check window could not be shown (${1}, exit ${rc})"; rc=3 ;;
    esac
    return "$rc"
}

# ui_app MODE JSON — show a Kirigami page (wizard, settings, dashboard,
# check, choose, confirm or dialog) with JSON as its input; prints its
# answer. Status 0 answered, 1 cancelled, 3 it failed, 4 not available
# here (not tried); no other status. The caller validates the answer.
# Works inside $(...) too. The one place that chooses how: the long-lived
# front end's one window (_ui_front_ask) when that was started, else a
# window for this page alone (_ui_app_page).
ui_app() {
    _qml_ok || return 4
    local rc=0
    ui_front_start
    if [[ -n "$_UI_FRONT_W" ]]; then
        # Should it have gone since _qml_ok looked, this fails with 3.
        _ui_front_ask "$1" "$2" || rc=$?
        printf '%s' "$_UI_FRONT_ANSWER"
    else
        _ui_app_page "$1" "$2" || rc=$?
    fi
    if [[ $rc -eq 3 ]]; then
        # Not to be tried again in this run. The file says so to the shell
        # that called this in $(...), where the variable is lost.
        _QML_OK=no
        _ui_front_gone_mark
    fi
    return "$rc"
}

# ui_theme_prepare — make (once, and again after Settings) the folder that
# gives kdialog the chosen theme: a copy of the person's kdeglobals with
# that theme's colours, made by the desktop user in their own ~/.cache.
ui_theme_prepare() {
    _UI_THEME_DIR=""
    [[ "${UI_THEME:-system}" != system && "$UI_MODE" == kde && -n "$DESKTOP_USER" ]] || return 0
    local d home
    # (No more is read of what a program of that account prints than a
    # path can be long.)
    d=$(set -o pipefail
        _as_desktop_user python3 -I "$SCRIPT_DIR/ui/app.py" theme-dir "$UI_THEME" 2>/dev/null | head -c 4097) || d=""
    home=$(_home_of "$DESKTOP_USER")
    # Only a folder in that person's home is used.
    [[ -n "$home" && "$d" == "$home"/* && "$d" != *$'\n'* && "$d" != *..* ]] && _UI_THEME_DIR="$d"
    return 0
}

# ui_theme_changed — Settings changed the theme: the window that is open
# switches too.
ui_theme_changed() {
    ui_theme_prepare
    case "${UI_THEME:-system}" in
        system|light|dark) _ui_front_send "{\"theme\":\"${UI_THEME:-system}\"}" || true ;;
    esac
    return 0
}

# _ui_theme_env — "XDG_CONFIG_HOME=DIR" for kdialog (nothing for "system").
_ui_theme_env() {
    [[ -n "$_UI_THEME_DIR" ]] && printf 'XDG_CONFIG_HOME=%s' "$_UI_THEME_DIR"
    return 0
}

# _kd ARGS... — run kdialog as the desktop user. When kdialog itself fails
# (no display, crash: exit status above 2) the UI drops to the terminal and
# 255 is returned so the caller can ask again there. A caller that runs _kd
# in $(...) must call _ui_fallback itself on 255: the subshell's switch is
# lost when it ends. The failure is also remembered in RUN_TMP, which every
# later call sees, so a broken kdialog is not started again and again.
# kdialog is a program of the desktop user's account: no more is read of
# what it prints than an answer of the window may be long. (Its answers
# are a few tags, a folder or a password. One that was cut is checked like
# any other: see _ui_offered.)
_kd() {
    local rc=0 flag="${RUN_TMP:+${RUN_TMP}/kdialog-failed}"
    if [[ -n "$flag" && -e "$flag" ]]; then
        _ui_fallback
        return 255
    fi
    local theme
    theme=$(_ui_theme_env)
    _as_desktop_user env ${theme:+"$theme"} kdialog --title "$UI_TITLE" --icon "$(_ui_icon)" "$@" 2>/dev/null \
        | head -c "$_UI_FRONT_LINE_MAX"
    rc=${PIPESTATUS[0]}
    if (( rc > 2 )); then
        log "kdialog failed (exit ${rc}); falling back"
        if [[ -n "$flag" ]]; then : > "$flag"; fi
        _ui_fallback
        return 255
    fi
    return "$rc"
}

# _kd_answer ARGS... — _kd for a question whose labels ui_yesno or
# ui_choice3 swapped (see there): there exit 1 means "yes", so it may only
# come from kdialog itself. kdialog runs under "sh -c", which prints its
# exit status after it; without that line (no desktop user, runuser or env
# failing) or above 2, kdialog counts as failed: 255, as in _kd. (Qt exits
# 1 itself only when a lost Wayland connection cannot be restored with
# QT_WAYLAND_RECONNECT set; _user_env never passes that variable on.)
_kd_answer() {
    local out rc flag="${RUN_TMP:+${RUN_TMP}/kdialog-failed}"
    if [[ -n "$flag" && -e "$flag" ]]; then
        _ui_fallback
        return 255
    fi
    local theme
    theme=$(_ui_theme_env)
    # shellcheck disable=SC2016 # $@ and $? are for the inner shell
    out=$(_as_desktop_user env ${theme:+"$theme"} sh -c 'kdialog "$@"; echo "bsa-kdialog-exit:$?"' sh \
              --title "$UI_TITLE" --icon "$(_ui_icon)" "$@" 2>/dev/null < /dev/null | head -c 256)
    rc=$(sed -n 's/^bsa-kdialog-exit:\([0-9]\{1,3\}\)$/\1/p' <<< "$out" | tail -n 1)
    if [[ -z "$rc" ]] || (( rc > 2 )); then
        log "kdialog failed (exit ${rc:-unknown}); falling back"
        if [[ -n "$flag" ]]; then : > "$flag"; fi
        _ui_fallback
        return 255
    fi
    return "$rc"
}

# _rich TEXT — plain text as KDE rich text (escaped, line breaks kept).
_rich() { _reflow_html "$1"; }

# _ui_offered STEP ANSWER ITEM... — the lines of ANSWER that are tags of the
# ITEMs (each STEP words long, the tag first). kdialog runs as the desktop
# user, so root only takes an answer that is one of the choices it offered:
# never a path, a command or a finding that was not on the list.
_ui_offered() {
    local step="$1" answer="$2" line i
    shift 2
    local -a items=("$@")
    local -A tag=()
    for (( i = 0; i < ${#items[@]}; i += step )); do
        [[ -n "${items[$i]}" ]] && tag["${items[$i]}"]=1
    done
    while IFS= read -r line; do
        [[ -n "$line" && -n "${tag[$line]+x}" ]] && printf '%s\n' "$line"
    done <<< "$answer"
    return 0
}

# _ui_sync — a kdialog that failed inside $(...) only switched the UI off
# KDE in that subshell; make the switch here too.
_ui_sync() {
    if [[ "$UI_MODE" == "kde" && -n "${RUN_TMP:-}" && -e "${RUN_TMP}/kdialog-failed" ]]; then
        _ui_fallback
    fi
    return 0
}

# Dialog texts are plain text, or rich text when they start with "<html>"
# (built with _html, _rich and _pre). _ui_html gives the KDE version,
# _ui_plain the terminal version of either.
_ui_html() {
    if [[ "$1" == "<html>"* ]]; then printf '%s' "$1"; else printf '<html>%s</html>' "$(_rich "$1")"; fi
}

_ui_plain() {
    if [[ "$1" == "<html>"* ]]; then _html2text "$1"; else printf '%s' "$1"; fi
}

# _html2text HTML — the terminal version of a rich-text dialog: tags become
# line breaks and indents, <pre> blocks are indented, entities decoded.
_html2text() {
    python3 -I -c '
import html, re, sys
s = sys.argv[1]
s = re.sub(r"(?is)<pre[^>]*>(.*?)</pre>",
           lambda m: "\n" + "\n".join("    " + l for l in m.group(1).split("\n")) + "\n", s)
s = re.sub(r"(?i)<br\s*/?>", "\n", s)
s = re.sub(r"(?i)<hr[^>]*>", "\n" + "-" * 64 + "\n", s)
s = re.sub(r"(?i)<li[^>]*>", "\n  - ", s)
s = re.sub(r"(?i)<h[1-6][^>]*>", "\n", s)
s = re.sub(r"(?i)</(p|div|h[1-6]|tr|table|ul|ol)>", "\n", s)
s = re.sub(r"(?i)</t[dh]>", "  ", s)
s = re.sub(r"<[^>]+>", "", s)
s = html.unescape(s).replace("\u00a0", " ")
out, blank = [], 0
for line in s.split("\n"):
    line = line.rstrip()
    blank = blank + 1 if not line.strip() else 0
    if blank <= 1:
        out.append(line)
print("\n".join(out).strip("\n"))' "$1"
}

# _pre TEXT [MAXLINES] — TEXT as a monospace block, shortened to MAXLINES.
_pre() {
    local text="$1" max="${2:-40}" n
    n=$(printf '%s\n' "$text" | wc -l)
    if (( n > max )); then
        text="$(printf '%s\n' "$text" | head -n "$max")"$'\n'"… ($((n - max)) more lines - see the run log)"
    fi
    # Long lines are wrapped for display (marked ↵) so a dialog never grows
    # wider than the screen; the run log keeps the exact commands.
    text=$(printf '%s\n' "$text" | awk -v w=90 '
        # Break at the last space before the limit (so "name=value" and
        # paths stay whole); a single word longer than the line is cut.
        { line = $0
          while (length(line) > w) {
              cut = 0
              for (i = w; i > 24; i--) if (substr(line, i, 1) == " ") { cut = i; break }
              if (cut == 0) for (i = w; i > 24; i--) if (substr(line, i, 1) == "/") { cut = i; break }
              if (cut == 0) cut = w
              print substr(line, 1, cut) "↵"
              line = "    " substr(line, cut + 1)
          }
          print line }')
    printf '<pre style="font-size:small">%s</pre>' "$(_html "$text")"
}

_tty_read() {
    local prompt="$1" __v=""
    read -r -p "$prompt" __v < /dev/tty || __v=""
    printf '%s' "$__v"
}

# _ui_dialog KIND TEXT DETAILS BUTTON... [-- TAG LABEL on|off ...] — the
# Kirigami dialog (KIND info, warning, error or question; TEXT plain or
# rich; buttons left to right; after "--", items to pick one of). The
# button that is highlighted, has the focus and that Enter presses is the
# last one, or the one whose number (from 0) is in UI_DIALOG_PRIMARY; -1
# there means none (see ui_yesno for which it is). Prints the number of the button that was pressed, and the picked
# tag on a second line. Status 0 answered, 1 closed, 3 or 4 it cannot run
# here (as ui_app; 3 also for an answer that is not one of the buttons
# and tags given).
_ui_dialog() {
    _qml_ok || return 4
    local kind="$1" text="$2" details="$3" html title="" out rc
    shift 3
    local -a btn=()
    while [[ $# -gt 0 && "$1" != -- ]]; do btn+=("$1"); shift; done
    [[ "${1:-}" == -- ]] && shift
    # Plain text: a short first line (a question) is the title.
    if [[ "$text" != "<html>"* ]]; then
        local first="${text%%$'\n'*}"
        if (( ${#first} <= 90 )) && [[ "$text" == *$'\n'* || "$first" == *"?" ]]; then
            title="$first"; text="${text#"$first"}"; text="${text#$'\n'}"
        fi
    fi
    html=""; [[ -n "$text" ]] && html=$(_ui_html "$text")
    if [[ "$html" =~ \<h3\>(([^<]|\<font[^>]*\>|\</font\>|\<b\>|\</b\>)*)\</h3\> ]]; then
        title=$(_html2text "<html>${BASH_REMATCH[1]}")
        html="${html/"${BASH_REMATCH[0]}"/}"
    fi
    out=$(ui_app dialog "$(BSA_PRIMARY="${UI_DIALOG_PRIMARY:-}" python3 -I -c '
import json, sys
a = sys.argv[1:]
kind, title, html, details, nb = a[0], a[1], a[2], a[3], int(a[4])
buttons = [{"label": b} for b in a[5:5 + nb]]
rest = a[5 + nb:]
items = []
for i in range(0, len(rest) - 2, 3):
    p = (rest[i + 1].split("\x1f") + ["", "", ""])[:4]
    items.append({"tag": rest[i], "label": p[0], "detail": p[1],
                  "risk": p[2] if p[2] in ("low", "medium", "high") else "", "warn": p[3], "on": rest[i + 2] == "on"})
default = {"error": "Something went wrong", "warning": "Please check", "question": "Security Check"}.get(kind, "Security Check")
import os
p = os.environ.get("BSA_PRIMARY", "")
primary = int(p) if p.lstrip("-").isdigit() else len(buttons) - 1
print(json.dumps({"kind": kind, "title": title.strip() or default, "html": html, "details": details,
                  "buttons": buttons, "items": items, "primary": primary}))' "$kind" "$title" "$html" "$details" "${#btn[@]}" "${btn[@]}" "$@")")
    rc=$?
    [[ $rc -eq 0 ]] || return "$rc"
    # Only a button that was there, and only a tag that was offered.
    local -a tags=()
    local i
    for (( i = 1; i <= $#; i += 3 )); do tags+=("${!i}"); done
    python3 -I -c '
import json, sys
nb = int(sys.argv[2]); tags = sys.argv[3:]
try:
    d = json.loads(sys.argv[1])
except ValueError:
    sys.exit(3)
b = d.get("button") if isinstance(d, dict) else None
if not isinstance(b, int) or isinstance(b, bool) or not 0 <= b < nb:
    sys.exit(3)
print(b)
if tags:
    t = d.get("tag")
    if t not in tags:
        sys.exit(3)
    print(t)' "$out" "${#btn[@]}" "${tags[@]}" || { log "dialog: front-end answer rejected"; return 3; }
}

# ui_msg TEXT — an information dialog.
ui_msg() {
    # The Kirigami dialog when it can run (closing it is OK too).
    _ui_dialog info "$1" "" "OK" >/dev/null; [[ $? -le 1 ]] && return 0
    if [[ "$UI_MODE" == "kde" ]]; then
        _kd --msgbox "$(_ui_html "$1")" && return 0
        [[ $? -ne 255 ]] && return 0
    fi
    [[ "$UI_MODE" == "tty" ]] && printf '\n%s\n' "$(_ui_plain "$1")" > /dev/tty
    return 0
}

# ui_page TEXT — like ui_msg, but on a terminal it waits for Enter, so the
# page is read before the next screen scrolls it away.
ui_page() {
    if [[ "$UI_MODE" == "tty" ]]; then
        printf '\n%s\n' "$(_ui_plain "$1")" > /dev/tty
        read -r -p "  Press Enter to go back " _ < /dev/tty || true
        return 0
    fi
    ui_msg "$1"
}

# ui_error TEXT [DETAILS] — an error dialog.
ui_error() {
    _ui_dialog error "$1" "${2:-}" "OK" >/dev/null; [[ $? -le 1 ]] && return 0
    if [[ "$UI_MODE" == "kde" ]]; then
        if [[ -n "${2:-}" ]]; then
            _kd --detailederror "<html>$(_rich "$1")</html>" "$2" && return 0
        else
            _kd --error "<html>$(_rich "$1")</html>" && return 0
        fi
        [[ $? -ne 255 ]] && return 0
    fi
    print_status "ERR" "$1"
    [[ -n "${2:-}" ]] && printf '%s\n' "$2" >&2
    return 0
}

# ui_yesno TEXT [YES_LABEL] [NO_LABEL] [DEFAULT y|n] [warn|careful] — 0
# for yes. DEFAULT is the answer of Enter on the terminal and the answer
# when there is no one to ask, except for a marked question (careful or
# warn): there both are "no".
#
# Which button a stray Enter or Space presses in a window (the same rule
# in ui_choice3):
#   DEFAULT n            the NO button
#   DEFAULT y            the YES button
#   DEFAULT y, careful   none: for a question whose YES changes this PC as
#                        administrator there and then (apply, undo,
#                        install, remove). A key that was meant for the
#                        window before must not do that; YES is clicked,
#                        or reached with Tab.
#   warn                 as "careful", and shown as a warning (a question
#                        with side effects)
# kdialog cannot be told which button is the default: Enter presses the
# button in its YES place, in the plain question and in the warning alike
# (since kdialog 19.12). So unless YES is the default (DEFAULT y, not
# marked), the NO answer is put in kdialog's YES place and YES in its NO
# place, and the answer is read back the other way round. Esc or closing
# the window is neither (exit 2): always NO. "careful" and "warn" use the
# warning dialog. The cost: such a question reads NO before YES, and the
# icons kdialog gives its places (a tick for YES, a stop sign for NO) sit
# on the other answers; the labels say what each button does. (kdialog
# before 19.12 made the warning's default NO; Bazzite has never shipped
# one that old.)
ui_yesno() {
    local text="$1" yes="${2:-Yes}" no="${3:-No}" def="${4:-n}" how="${5:-}" kind="--yesno" primary=1 a rc
    [[ -z "$how" ]] || { kind="--warningyesno"; primary=-1; }
    [[ "$def" == y ]] || primary=0
    a=$(UI_DIALOG_PRIMARY="$primary" _ui_dialog "$([[ $how == warn ]] && echo warning || echo question)" "$text" "" "$no" "$yes")
    case $? in
        0) [[ "$a" == 1 ]] && return 0; return 1 ;;
        1) return 1 ;;
    esac
    if [[ "$UI_MODE" == "kde" ]]; then
        if [[ "$def" == y && -z "$how" ]]; then
            _kd --yes-label "$yes" --no-label "$no" "$kind" "$(_ui_html "$text")"
            rc=$?
            [[ $rc -ne 255 ]] && return "$rc"
        else
            _kd_answer --yes-label "$no" --no-label "$yes" "$kind" "$(_ui_html "$text")"
            rc=$?
            case $rc in
                1) return 0 ;;
                255) ;;
                *) return 1 ;;
            esac
        fi
    fi
    # A marked question changes the PC as administrator there and then: on
    # the terminal Enter is "no" too, and with nobody to ask (no terminal,
    # or a dialog that failed) the answer is "no", whatever DEFAULT is.
    [[ -n "$how" ]] && def=n
    if [[ "$UI_MODE" == "tty" ]]; then
        printf '\n%s\n' "$(_ui_plain "$text")" > /dev/tty
        a=$(_tty_read "  ${yes} / ${no}? [$([[ $def == y ]] && echo Y/n || echo y/N)] ")
        a="${a:-$def}"
        [[ "${a,,}" == y* ]] && return 0
        return 1
    fi
    [[ "$def" == "y" ]]
}

# ui_choice3 HTML_OR_TEXT TEXT_FOR_TTY YES NO CANCEL [warn|careful] [y|n] —
# 0, 1 or 2 (Yes/No/Cancel). An empty TEXT_FOR_TTY is made from the HTML
# (only when it is needed). On the terminal, Enter gives the last
# argument's answer (No unless "y" is given; always No for a marked
# question); with no one to ask, the answer is always No. "warn",
# "careful" and the button that Enter presses in a window: as in ui_yesno
# (in kdialog, NO is put in the YES place, and
# Esc or closing the window is CANCEL).
ui_choice3() {
    local html="$1" text="$2" yes="$3" no="$4" cancel="$5" how="${6:-}" kind="--yesnocancel" def="${7:-n}" primary=2 a rc
    [[ -z "$how" ]] || { kind="--warningyesnocancel"; primary=-1; }
    [[ "$def" == y ]] || primary=1
    a=$(UI_DIALOG_PRIMARY="$primary" _ui_dialog "$([[ $how == warn ]] && echo warning || echo question)" "$html" "" "$cancel" "$no" "$yes")
    case $? in
        0) case "$a" in 2) return 0 ;; 1) return 1 ;; *) return 2 ;; esac ;;
        1) return 2 ;;
    esac
    if [[ "$UI_MODE" == "kde" ]]; then
        if [[ "$def" == y && -z "$how" ]]; then
            _kd --yes-label "$yes" --no-label "$no" --cancel-label "$cancel" \
                "$kind" "<html>${html#<html>}"
            rc=$?
            [[ $rc -ne 255 ]] && return "$rc"
        else
            _kd_answer --yes-label "$no" --no-label "$yes" --cancel-label "$cancel" \
                "$kind" "<html>${html#<html>}"
            rc=$?
            case $rc in
                0) return 1 ;;
                1) return 0 ;;
                255) ;;
                *) return 2 ;;
            esac
        fi
    fi
    # A marked question: Enter on the terminal is "no" too (see ui_yesno).
    [[ -n "$how" ]] && def=n
    if [[ "$UI_MODE" == "tty" ]]; then
        [[ -n "$text" ]] || text=$(_html2text "<html>${html#<html>}")
        printf '\n%s\n' "$text" > /dev/tty
        while :; do
            a=$(_tty_read "  [y] ${yes}   [n] ${no}   [s] ${cancel}  (default ${def}): ")
            a="${a:-$def}"
            case "${a,,}" in
                y|yes) return 0 ;;
                n|no) return 1 ;;
                s|stop|q|c) return 2 ;;
            esac
        done
    fi
    return 1
}

# ui_radiolist TEXT TAG LABEL on|off ... — print the chosen TAG (1 if cancelled).
ui_radiolist() {
    local text="$1" out rc i n a def=""
    shift
    out=$(_ui_dialog question "$text" "" "Cancel" "OK" -- "$@")
    rc=$?
    if [[ $rc -eq 0 ]]; then
        [[ "${out%%$'\n'*}" == 1 ]] || return 1
        printf '%s\n' "${out#*$'\n'}"
        return 0
    fi
    [[ $rc -eq 1 ]] && return 1
    if [[ "$UI_MODE" == "kde" ]]; then
        out=$(_kd --radiolist "$(_ui_html "$text")" "$@")
        rc=$?
        if [[ $rc -ne 255 ]]; then
            out=$(_ui_offered 3 "$out" "$@" | head -n1)
            [[ $rc -eq 0 && -n "$out" ]] || return 1
            printf '%s\n' "$out"
            return 0
        fi
        _ui_fallback
    fi
    local -a tags=() labels=()
    while [[ $# -ge 3 ]]; do
        tags+=("$1"); labels+=("$2")
        [[ "$3" == "on" ]] && def="$1"
        shift 3
    done
    [[ -n "$def" ]] || def="${tags[0]}"
    if [[ "$UI_MODE" == "tty" ]]; then
        printf '\n%s\n' "$(_ui_plain "$text")" > /dev/tty
        n=${#tags[@]}
        for (( i = 0; i < n; i++ )); do
            printf '  [%d] %s%s\n' $((i + 1)) "${labels[$i]}" \
                "$([[ ${tags[$i]} == "$def" ]] && echo '  (default)')" > /dev/tty
        done
        while :; do
            a=$(_tty_read "  Choose 1-${n}: ")
            [[ -z "$a" ]] && { printf '%s\n' "$def"; return 0; }
            if [[ "$a" =~ ^[0-9]+$ ]] && (( a >= 1 && a <= n )); then
                printf '%s\n' "${tags[$((a - 1))]}"
                return 0
            fi
        done
    fi
    printf '%s\n' "$def"
}

# ui_item LABEL [DETAIL] [RISK] [WARNING] — the LABEL of a ui_checklist
# item with more to say about it: a second line, how likely the change is
# to break something (low, medium, high) and what could break. The Kirigami
# chooser shows each part; kdialog and the terminal show them in one line.
ui_item() {
    local IFS=$'\x1f'
    printf '%s' "${*//$'\n'/ }"
}

# _ui_item_part LABEL N — part N of an item label (0 label, 1 detail,
# 2 risk, 3 warning).
_ui_item_part() {
    local -a p=()
    IFS=$'\x1f' read -r -a p <<< "$1"
    printf '%s' "${p[$2]:-}"
}

# _ui_item_line LABEL — an item label in one line (kdialog, terminal).
_ui_item_line() {
    local l d r w
    l=$(_ui_item_part "$1" 0); d=$(_ui_item_part "$1" 1); r=$(_ui_item_part "$1" 2); w=$(_ui_item_part "$1" 3)
    # In one line only a risk worth a look is named.
    [[ "$r" == low ]] && r=""
    printf '%s%s%s%s' "$l" "${d:+  —  $d}" "${r:+  [$r risk]}" "${w:+  ⚠ $w}"
}

# _choose_input TEXT TAG LABEL on|off ... — the Kirigami chooser's input
# (JSON): a title, the text as plain text and each item's parts. Callers
# may set UI_CHOOSE_TITLE, UI_CHOOSE_OK (the button), UI_CHOOSE_ALLOW_NONE=1
# (continue with nothing ticked), UI_CHOOSE_NOTE=0 (no "nothing changes
# yet" line) and UI_CHOOSE_LOWONLY=0 (no "Low risk only": for lists where a
# tick keeps something, like the firewall's) for the call.
_choose_input() {
    local text="$1" title="${UI_CHOOSE_TITLE:-}"
    shift
    if [[ -z "$title" && "$text" =~ \<(h[23])\>([^<]*)\</h[23]\> ]]; then
        title="${BASH_REMATCH[2]}"
        text="${text/"${BASH_REMATCH[0]}"/}"
        title=$(_html2text "<html>${title}")
    fi
    text=$(_ui_plain "$text")
    if [[ -z "$title" ]]; then title="${text%%$'\n'*}"; text="${text#"$title"}"; fi
    python3 -I -c '
import json, re, sys
a = sys.argv[1:]
title, intro, ok, none, note, low = a[:6]
# The text as paragraphs that wrap in the window, without the title again.
intro = intro.strip()
if title.strip() and intro.startswith(title.strip()):
    intro = intro[len(title.strip()):].strip()
intro = "\n\n".join(" ".join(p.split()) for p in re.split(r"\n\s*\n", intro) if p.strip())
items = []
for i in range(6, len(a) - 2, 3):
    p = (a[i + 1].split("\x1f") + ["", "", ""])[:4]
    items.append({"tag": a[i], "label": p[0], "detail": p[1],
                  "risk": p[2] if p[2] in ("low", "medium", "high") else "",
                  "warn": p[3], "on": a[i + 2] == "on"})
print(json.dumps({"title": title.strip(), "intro": intro.strip(), "ok": ok or "Continue",
                  "allow_none": none == "1", "note_nothing_yet": note != "0", "low_only": low != "0", "items": items}))' \
        "$title" "$text" "${UI_CHOOSE_OK:-}" "${UI_CHOOSE_ALLOW_NONE:-0}" "${UI_CHOOSE_NOTE:-1}" "${UI_CHOOSE_LOWONLY:-1}" "$@"
}

# _choose_answer JSON — the tags in the chooser's answer, one per line
# (status 1 when it is not a list of tags). The caller keeps only tags it
# offered.
_choose_answer() {
    python3 -I -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
t = d.get("tags") if isinstance(d, dict) else None
if not isinstance(t, list) or not all(isinstance(x, str) and "\n" not in x for x in t):
    sys.exit(1)
for x in t:
    print(x)' "$1"
}

# ui_checklist TEXT TAG LABEL on|off ... — print the chosen TAGs, one per
# line (status 1 if cancelled). A LABEL made with ui_item adds a detail
# line, a risk and a warning for that item.
ui_checklist() {
    local text="$1" out rc i n a t geo=()
    shift
    # The Kirigami chooser: each item with its risk and warning, Select
    # all / none / low risk only.
    if _qml_ok; then
        out=$(ui_app choose "$(_choose_input "$text" "$@")")
        rc=$?
        case "$rc" in
            0) if out=$(_choose_answer "$out"); then _ui_offered 3 "$out" "$@"; return 0; fi
               log "choose: front-end answer rejected" ;;
            1) return 1 ;;
        esac
    fi
    # kdialog and the terminal show each item in one line.
    local -a flat=()
    while [[ $# -ge 3 ]]; do
        flat+=("$1" "$(_ui_item_line "$2")" "$3")
        shift 3
    done
    set -- "${flat[@]}"
    # Long lists (the fix list, the firewall services) get a bigger window.
    (( $# / 3 > 6 )) && geo=(--geometry 900x620)
    if [[ "$UI_MODE" == "kde" ]]; then
        out=$(_kd "${geo[@]}" --separate-output --checklist "$(_ui_html "$text")" "$@")
        rc=$?
        if [[ $rc -ne 255 ]]; then
            [[ $rc -eq 0 ]] || return 1
            _ui_offered 3 "$out" "$@"
            return 0
        fi
        _ui_fallback
    fi
    local -a tags=() labels=() on=()
    while [[ $# -ge 3 ]]; do
        tags+=("$1"); labels+=("$2"); on+=("$([[ $3 == on ]] && echo 1 || echo 0)")
        shift 3
    done
    n=${#tags[@]}
    if [[ "$UI_MODE" == "tty" ]]; then
        while :; do
            printf '\n%s\n' "$(_ui_plain "$text")" > /dev/tty
            for (( i = 0; i < n; i++ )); do
                printf '  [%s] %d. %s\n' "$([[ ${on[$i]} == 1 ]] && echo x || echo ' ')" \
                    $((i + 1)) "${labels[$i]}" > /dev/tty
            done
            a=$(_tty_read "  Numbers to toggle (e.g. \"2 4\"), Enter to accept: ")
            [[ -z "$a" ]] && break
            for t in $a; do
                if [[ "$t" =~ ^[0-9]+$ ]] && (( t >= 1 && t <= n )); then
                    on[t - 1]=$(( 1 - on[t - 1] ))
                fi
            done
        done
    fi
    for (( i = 0; i < n; i++ )); do
        [[ "${on[$i]}" == 1 ]] && printf '%s\n' "${tags[$i]}"
    done
    return 0
}

# ui_menu HTML OK_LABEL CANCEL_LABEL TAG LABEL ... — a list to pick one
# entry from (the dashboard). Prints the chosen TAG; status 1 when closed
# with CANCEL_LABEL (or nobody can answer).
ui_menu() {
    local html="$1" ok="$2" cancel="$3" out rc i n a
    shift 3
    if [[ "$UI_MODE" == "kde" ]]; then
        out=$(_kd --geometry 900x700 --ok-label "$ok" --cancel-label "$cancel" --menu "$(_ui_html "$html")" "$@")
        rc=$?
        if [[ $rc -ne 255 ]]; then
            out=$(_ui_offered 2 "$out" "$@" | head -n1)
            [[ $rc -eq 0 && -n "$out" ]] || return 1
            printf '%s\n' "$out"
            return 0
        fi
        _ui_fallback
    fi
    [[ "$UI_MODE" == "tty" ]] || return 1
    local -a tags=() labels=()
    while [[ $# -ge 2 ]]; do tags+=("$1"); labels+=("$2"); shift 2; done
    n=${#tags[@]}
    {
        printf '\n%s\n\n' "$(_ui_plain "$html")"
        for (( i = 0; i < n; i++ )); do printf '  %2d) %s\n' $((i + 1)) "${labels[$i]}"; done
        printf '   q) %s\n' "$cancel"
    } > /dev/tty
    while :; do
        read -r -p "  Choose 1-${n}, or q: " a < /dev/tty || return 1
        case "$a" in q|Q) return 1 ;; esac
        if [[ "$a" =~ ^[0-9]+$ ]] && (( a >= 1 && a <= n )); then
            printf '%s\n' "${tags[$((a - 1))]}"
            return 0
        fi
    done
}

# ui_newpassword TEXT — ask twice for a new password; print it (1 if cancelled).
ui_newpassword() {
    local text="$1" out rc p1 p2
    if [[ "$UI_MODE" == "kde" ]]; then
        out=$(_kd --newpassword "$text")
        rc=$?
        if [[ $rc -ne 255 ]]; then
            [[ $rc -eq 0 && -n "$out" ]] || return 1
            printf '%s' "$out"
            return 0
        fi
        _ui_fallback
    fi
    [[ "$UI_MODE" == "tty" ]] || return 1
    printf '\n%s\n' "$text" > /dev/tty
    IFS= read -r -s -p "  New password: " p1 < /dev/tty || return 1
    printf '\n' > /dev/tty
    IFS= read -r -s -p "  Repeat it: " p2 < /dev/tty || return 1
    printf '\n' > /dev/tty
    [[ -n "$p1" && "$p1" == "$p2" ]] || { printf '  Passwords are empty or differ.\n' > /dev/tty; return 1; }
    printf '%s' "$p1"
}

# ui_dir TEXT START — pick a folder (prints it; 1 if cancelled).
ui_dir() {
    local text="$1" start="$2" out rc
    if [[ "$UI_MODE" == "kde" ]]; then
        out=$(_kd --getexistingdirectory "$start")
        rc=$?
        if [[ $rc -ne 255 ]]; then
            [[ $rc -eq 0 && -n "$out" ]] || return 1
            printf '%s\n' "$out"
            return 0
        fi
        _ui_fallback
    fi
    if [[ "$UI_MODE" == "tty" ]]; then
        out=$(_tty_read "$text [${start}]: ")
        printf '%s\n' "${out:-$start}"
        return 0
    fi
    printf '%s\n' "$start"
}

# ui_notify TEXT — a passive desktop notification (or a terminal line).
ui_notify() {
    if [[ "$UI_MODE" == "kde" ]]; then
        _as_desktop_user kdialog --title "$UI_TITLE" --icon "$(_ui_icon)" \
            --passivepopup "$1" 6 >/dev/null 2>&1 &
        return 0
    fi
    print_status "INFO" "$1"
}

# ====================== PROGRESS ======================
# Progress while the checks run (with steps), and a busy indicator while a
# fix is applied or a file is fetched (without steps). There are three
# back ends; _progress_pick is the one place that chooses, and the one that
# is in use is in _PROGRESS_BACKEND:
#   front    the long-lived front end (ui_front_start). With steps: its
#            small progress window with a tray icon, while the main window
#            is hidden. Without: the main window's spinner with the text.
#            The normal case on a KDE desktop.
#   window   a front-end process of its own ("app.py progress"), fed
#            through _PROGRESS_FD: the Kirigami front end can run, but the
#            long-lived one is not running (it could not get its pipes).
#   kdialog  a kdialog progress bar (_PROGRESS_REF), driven over the user's
#            D-Bus session (best effort: if it cannot be driven it is
#            simply closed at the end): KDE dialogs without the Kirigami
#            front end, or after it failed.
#   ""       none: the terminal (a line that is rewritten) or nothing.
# Each back end is three functions: _progress_BACKEND_start TEXT STEPS,
# _progress_BACKEND_line LINE ("PERCENT<TAB>SLOW<TAB>LABEL<TAB>DETAIL", as
# ui/app.py describes it) and _progress_BACKEND_stop.
_PROGRESS_BACKEND=""
_PROGRESS_FD=""
_PROGRESS_STEPS=0

# _progress_pick — set _PROGRESS_BACKEND to the back end to use now.
_progress_pick() {
    _PROGRESS_BACKEND=""
    [[ "$UI_MODE" == "kde" ]] || return 0
    if ! _qml_ok; then
        _PROGRESS_BACKEND=kdialog
        return 0
    fi
    ui_front_start
    if _ui_front_up; then _PROGRESS_BACKEND=front; else _PROGRESS_BACKEND=window; fi
}

# ---- back end "front" ----
_PROGRESS_FRONT_STEPS=0     # 1: its progress window shows, 0: its spinner

_progress_front_start() {
    if [[ $2 -gt 0 ]]; then
        _PROGRESS_FRONT_STEPS=1
        _ui_front_send '{"progress":"start","heading":"Checking your PC"}' || true
        _progress_front_line "0	0	${1}	"
    else
        _PROGRESS_FRONT_STEPS=0
        _ui_front_send "{\"busy\":$(_json_str "$1")}" || true
    fi
}

_progress_front_line() {
    # The spinner has its text already.
    [[ "$_PROGRESS_FRONT_STEPS" -eq 1 ]] || return 0
    _ui_front_send "{\"progress\":\"set\",\"line\":$(_json_str "${1//$'\n'/ }")}" || true
}

_progress_front_stop() {
    if [[ "$_PROGRESS_FRONT_STEPS" -eq 1 ]]; then
        # The progress window stays, at "Done", until the next page or
        # spinner replaces it: there is never a moment without a window.
        [[ "${_PROGRESS_STEPS:-0}" -gt 0 ]] && _progress_front_line "100	0	Done	"
        _ui_front_send '{"progress":"stop"}' || true
    else
        # The spinner stays too, with its usual text, until the next page.
        _ui_front_send '{"busy":""}' || true
    fi
    _PROGRESS_FRONT_STEPS=0
}

# ---- back end "window" ----
_progress_window_start() {
    # The reader keeps draining its input even if the window could not
    # be shown, so writing progress never fails.
    exec {_PROGRESS_FD}> >(_ui_app_cmd progress > /dev/null 2>&1; cat > /dev/null)
    _progress_window_line "$(_json heading "$([[ $2 -gt 0 ]] && echo "Checking your PC" || echo "$1")")"
    if [[ $2 -gt 0 ]]; then _progress_window_line "0	0	${1}	"; else _progress_window_line "-	0	Please wait…	"; fi
}

_progress_window_line() {
    [[ -n "$_PROGRESS_FD" ]] || return 0
    # The reader can have been ended from outside: see _pipe_write.
    _pipe_write "$_PROGRESS_FD" "${1//$'\n'/ }" || true
}

_progress_window_stop() {
    [[ -n "$_PROGRESS_FD" ]] || return 0
    [[ "${_PROGRESS_STEPS:-0}" -gt 0 ]] && _progress_window_line "100	0	Done	"
    # An explicit end: the window closes even if a child process still
    # holds a copy of the pipe.
    _progress_window_line "QUIT"
    exec {_PROGRESS_FD}>&-
    _PROGRESS_FD=""
}

# ---- back end "kdialog" ----
_progress_kdialog_start() {
    local theme ref
    theme=$(_ui_theme_env)
    # (Of what it prints, no more is read than such a line can be long.)
    ref=$(set -o pipefail
          _as_desktop_user env ${theme:+"$theme"} kdialog --title "$UI_TITLE" --icon "$(_ui_icon)" \
              --progressbar "$1" "$([[ $2 -gt 0 ]] && echo 100 || echo 0)" 2>/dev/null | head -c 256) || return 0
    # "org.kde.kdialog-12345 /ProgressDialog"
    [[ "$ref" =~ ^(org\.kde\.kdialog-[0-9]+)[[:space:]]+(/[A-Za-z]+)$ ]] && _PROGRESS_REF="$ref"
    return 0
}

_progress_kdialog_call() {
    local svc path
    read -r svc path <<< "$_PROGRESS_REF"
    _as_desktop_user busctl --user "$1" "$svc" "$path" org.kde.kdialog.ProgressDialog "${@:2}" \
        >/dev/null 2>&1
}

_progress_kdialog_line() {
    [[ -n "$_PROGRESS_REF" ]] || return 0
    local pct="${1%%$'\t'*}" rest="${1#*$'\t'}" label detail
    rest=${rest#*$'\t'}; label=${rest%%$'\t'*}; detail=${rest#*$'\t'}
    _progress_kdialog_call set-property value i "$pct" || true
    _progress_kdialog_call call setLabelText s "${label}${detail:+ - $detail}" || true
}

_progress_kdialog_stop() {
    [[ -n "$_PROGRESS_REF" ]] || return 0
    _progress_kdialog_call set-property value i 100 || true
    _progress_kdialog_call call close || true
    _PROGRESS_REF=""
}

# ---- what the tool calls ----
# ui_progress_start TEXT STEPS — STEPS 0: no steps (a busy indicator).
ui_progress_start() {
    _PROGRESS_REF=""; _PROGRESS_STEPS="$2"
    _progress_pick
    [[ -z "$_PROGRESS_BACKEND" ]] || "_progress_${_PROGRESS_BACKEND}_start" "$1" "$2"
    return 0
}

# _progress_line LINE — a progress line to the back end in use.
_progress_line() {
    [[ -z "$_PROGRESS_BACKEND" ]] || "_progress_${_PROGRESS_BACKEND}_line" "$1"
    return 0
}

# ui_progress_set STEP LABEL [slow] — step STEP of the steps given to
# ui_progress_start has started. The bar shows the steps already done,
# scaled to 90%: it reaches 100% only when the last step has finished
# (ui_progress_stop), never while one still runs. "slow": a long step (the
# malware scan) - the bar holds at 90% with a spinner and a note.
ui_progress_set() {
    local value="$1" label="$2" slow="${3:-}" pct detail=""
    local total="${_PROGRESS_STEPS:-0}"
    (( total > 0 )) || total=1
    pct=$(( (value - 1) * 90 / total ))
    (( pct < 0 )) && pct=0
    if [[ "$slow" == slow ]]; then
        pct=90
        detail="This can take several minutes. The bar moves on when it is done."
    fi
    _progress_line "${pct}	$([[ $slow == slow ]] && echo 1 || echo 0)	${label//$'\t'/ }	${detail}"
    if [[ -t 2 && "${QUIET:-0}" -eq 0 ]]; then
        printf '\r  [%2d/%-2d] %3d%% %-50.50s' "$value" "${_PROGRESS_STEPS:-0}" "$pct" "$label" >&2
    fi
}

# ui_busy_start TEXT / ui_busy_stop — a busy indicator while a fix runs
# (the main window's spinner with TEXT, else a progress window or a kdialog
# progress bar without steps, or a line on the terminal).
ui_busy_start() {
    if [[ "$UI_MODE" == "kde" ]]; then
        ui_progress_start "$1" 0
    elif [[ "$UI_MODE" == "tty" ]]; then
        printf '  %s\n' "$1" > /dev/tty
    fi
    return 0
}

ui_busy_stop() { ui_progress_stop; }

# ui_progress_stop — every step has finished: 100% ("Done"). The front
# end's progress window then stays until the next page or spinner takes
# its place; a progress window of its own and a kdialog bar close.
ui_progress_stop() {
    [[ -t 2 && "${QUIET:-0}" -eq 0 ]] && printf '\r%-80s\r' '' >&2
    [[ -z "$_PROGRESS_BACKEND" ]] || "_progress_${_PROGRESS_BACKEND}_stop"
    _PROGRESS_BACKEND=""
    return 0
}
