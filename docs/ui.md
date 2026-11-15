# The Security Check window: notes for developers

This describes the Kirigami front end: how it talks to the rest of the tool, what a page is, and how to add or test one. The code is `ui/app.py`, `ui/qml/` and the first half of `lib/ui.sh`. Where this file and the code disagree, the code is right and this file needs a fix.

## Two sides

| | Root side | Front end |
|---|---|---|
| Code | `bazzite-sec-audit.sh`, `lib/*.sh`, `checks/*.sh` | `ui/app.py` (PySide6), `ui/qml/*.qml` (Kirigami) |
| Runs as | root | the desktop user (`_as_desktop_user`), never root |
| Does | checks, fixes, reports; decides what is shown next | shows one page, returns what the person chose |

The root side starts the front end once per run (`ui_front_start`: `python3 -I ui/app.py serve`) with two pipes: requests go in on its stdin, answers come back on its stdout. One window, `ui/qml/Shell.qml`, stays open for the whole run and shows the pages one after the other. Until the first request the front end is an idle process: Qt is not loaded and no window exists.

Trust goes one way. The desktop user's account is trusted less than root, so:

- The front end gets nothing of root's except the two pipes and a third for its stderr: not the run log, and not the run's lock (`_run_lock_close` closes it for every program started as another account, and for fixes). A root process (`_ui_log_reader`) copies that stderr into the run log, each line cut to size and marked `ui:`; the front end never holds the log file. In all, `_UI_LOG_MAX` bytes (256 KiB) per front-end process are read, NUL bytes included; then the pipe is closed and the front end's later messages are lost.
- The root side treats every answer as untrusted input. `_ui_front_ask` takes the answer line apart with one fixed pattern (no JSON parser in the shell) and accepts a line of at most `_UI_FRONT_LINE_MAX` characters. Each caller then validates the answer and keeps only values it offered: a tag from its own list, a button it sent, a known action.
- Pages treat text from the PC (host names, paths, finding titles, commands) as untrusted too: plain text, or escaped with `Util.esc()` where a label mixes it into rich text.

The front end has no logic of its own about security. A page shows what it is given and reports a choice.

## The protocol (`app.py serve`)

One JSON object per line on stdin. A line may hold several of the keys below; they are handled in this order: `quit`, `theme`, `progress`, `busy`, `mode`.

| Line | Effect | Answer |
|---|---|---|
| `{"id": ID, "mode": MODE, "data": {...}}` | Show page MODE with `data` as its input. MODE is `wizard`, `settings`, `dashboard`, `check`, `choose`, `confirm` or `dialog`. ID is 1 to 64 characters from `A-Z a-z 0-9 - _`. | one line, below |
| `{"busy": "LABEL"}` | Dim the last page and show a spinner with LABEL. `""` does not ask for the spinner: it puts the usual text ("Working…") back and closes the progress window if that is open. | none |
| `{"progress": "start", "heading": "..."}` | The scan begins: the main window hides, the small progress window (`Progress.qml`) and its tray icon show. | none |
| `{"progress": "set", "line": "PERCENT\tSLOW\tLABEL\tDETAIL"}` | One progress line. PERCENT is 0 to 100, or `-` for a step without a percentage; SLOW is `1` for a long step. | none |
| `{"progress": "stop"}` | Nothing changes yet: the progress window stays until the next page or busy label, so there is never a moment without a window. | none |
| `{"theme": "system"}` (or `light`, `dark`) | Switch the colours of the open window. | none |
| `{"quit": true}` | Leave. End of input does the same. | none |

Every page request gets exactly one answer line, in exactly this form:

    {"id":"ID","status":0,"answer":{...}}

| Status | Meaning | `answer` |
|---|---|---|
| 0 | the person answered | what the page passed to `finished()` |
| 1 | cancelled: Esc, a Cancel button, or the window's close button | `null` |
| 3 | the page could not be shown | `null` |

What fails, and what happens then:

- A line that is not JSON, is not an object, or is an object with none of the five keys is answered with `{"id":"","status":3,"answer":null}`.
- A page request without a usable id is answered the same way. With a usable id but an unknown mode, a mode that is not a string, or `data` that is not an object, the answer carries the request's id and status 3.
- A page file that does not load, or loads but is not a page (not an `Item`, or without `finished` and `cancelled`), is answered with the request's id and status 3. The window stays up.
- An exception while a line is handled is logged and answered with status 3.
- A second request while one waits: the first is answered with status 1, then the second is shown. The root side skips answer lines that carry another id.
- The front end exits when the root side goes away without saying so: its parent process changes, or the process named in `BSA_OWNER_PID` is gone (`_Owner`, checked every two seconds).

The rule behind all of these: the root side must never wait for ever. It waits for an answer without a time limit, because a person answers when they answer, so every request line must produce an answer line or the pipe must close.

`app.py serve` exits with status 0, or 3 when Qt or the window could not be loaded. The root side does not read the status; it sees the answer pipe close.

### Stopping the front end

`ui_front_stop` sends `quit`, closes the pipes and watches the front end's processes end, which normally takes a fraction of a second and needs no signal. Only a front end that hangs is ended: TERM after two seconds, KILL a second later. Root ends processes for a less trusted account here, so it must never hit a process that is not the front end's. A process id alone does not say that (an id is free again once its process has ended, and the front end decides when that is), so the rules are: a process is named by its id and its start time together, and the helper's are recorded when it is started; the list of what belongs to the front end is made while root still holds the pipes, when the helper cannot have ended; every signal is sent only after the start time has been read again, directly before; the front end's own processes are signalled as the desktop user (through `runuser`), so the kernel refuses anything that is not that account's; and root itself signals only its own helper processes. The comment above `ui_front_stop` in `lib/ui.sh` has the reasoning.

### Fallback to kdialog

`ui_app MODE JSON` in `lib/ui.sh` is the one function callers use. It returns 0 (answer on stdout), 1 (cancelled), 3 (the front end failed) or 4 (not available here: no KDE session, no PySide6, no Kirigami, or it failed earlier in this run).

On status 3, an answer line in another form, or a closed pipe, `_ui_front_ask` logs the failure, stops the front end (`ui_front_stop`) and marks it as gone for the rest of the run (the file `ui-front-gone` in the run's private folder, because the caller is often a `$(...)` subshell). The caller then asks the same question with kdialog, or on the terminal when kdialog fails too. A caller also falls back when it rejects the answer. So a broken page costs the Kirigami look for the rest of that run, never the run itself.

### One page per process

`app.py MODE < input.json` shows that one page in a window of its own and prints the answer as one JSON value. Exit status 0 answered, 1 cancelled, 2 bad input, 3 cannot run here. `app.py progress` shows the progress window alone and reads progress lines until end of input or a line `QUIT`. The root side uses these only when it could not make the two pipes for `serve` (`_ui_app_page`, the `window` progress backend). An installed 1.5.0 also calls them while it updates itself to a newer version, so they must stay.

`app.py theme-dir light|dark` prints a config folder that gives kdialog the same forced theme.

## Pages

A page is a QML file in `ui/qml/` whose root is an `Item`:

    Item {
        id: page
        required property var input        // the "data" object of the request
        property string iconSource: ""     // file URL of the app icon
        readonly property string title: …  // short: the window's title bar
        signal finished(var answer)        // status 0 with this answer
        signal cancelled()                 // status 1
        function primary() { … }           // Enter
        function dismiss() { … }           // Esc
        function initialFocus() { … }      // optional: the item that gets the keyboard focus
    }

The Shell creates the page, fills its area with it, and connects the two signals. Only the first `finished` or `cancelled` counts; a second click on a page that has answered does nothing.

Rules pages follow:

1. No window, no window size, no `onClosing`. The page fills its parent and works from 34 x 28 grid units up to a large screen. Only `Dialog.qml` has an implicit size, because the Shell sizes a dialog by its content.
2. Layout: `PageHeader` on top, scrollable content, `FooterBar` at the bottom. Exactly one `PrimaryButton`, rightmost in the footer; every other button is a plain `QQC2.Button`.
3. `primary()` does what the main button does. `dismiss()` goes back or emits `cancelled()`, and may do nothing: on the dashboard Esc does nothing, because that is where Esc on a check comes back to and a second Esc must not end the run.
4. A page must load with `input` equal to `{}` without a warning. Read fields as `input.x || default`.
5. Every control is reachable with Tab and usable with Space. A custom clickable item gets `activeFocusOnTab`, a `FocusRing`, key handling, and `Accessible.name` and `Accessible.role`.
6. All visible strings go through `qsTr()`, with `.arg()` or `Util.fill()` instead of concatenation.
7. Colours and sizes come from `Kirigami.Theme` and `Kirigami.Units`. No imports beyond those already used in `ui/qml/`: the pages must run on a stock Bazzite KDE image.
8. Never name a function `escape`: QML rejects it.
9. Keep the answer's keys and types stable. The root side validates them, and an installed older root side may talk to a newer page during an update.

### Shared components

All in `ui/qml/`, used by their bare name.

| Component | What it is |
|---|---|
| `PageHeader` | The band at the top: icon, optional small line, title, subtitle; items placed inside go in a row under the subtitle. |
| `FooterBar` | The bar at the bottom: `leading` buttons on the left, a one-line hint, the page's buttons on the right. |
| `PrimaryButton` | The one main button of a page, filled with the highlight colour; `destructive: true` for a dangerous action. |
| `StatusChip` | A small rounded label: `sev` for a finding's severity, `risk` for the risk of a change, or your own text and tint. |
| `Section` | A titled block of content. |
| `NowAfter` | A setting now and after the fix, one above the other. |
| `AffectsList` | What a fix affects on Bazzite: one row per feature. |
| `WarningsBox` | The "before you apply" side effects of a fix. |
| `CodeBlock` | Commands or other fixed-width text: read-only, selectable, with a Copy button. |
| `ExpandableText` | A check's description: its first lines, and a button for the rest when it is longer. |
| `FocusRing` | The keyboard focus ring for controls drawn in this folder. |
| `util.js` | Helpers (`import "util.js" as Util`): `esc`, `fill`, `reflow`, `reveal`, and the names and colours of states, severities and risks. |

## What the Shell does

`Shell.qml` is a `Kirigami.ApplicationWindow` with a `host` object from `app.py`: signals `request`, `busy` and `park`, and the slot `reply(id, status, answer)`.

**Pages and dialogs.** A request replaces the current page; the new one fades in over the old. A `dialog` request is shown as a card over the current page, which is dimmed and takes no input while the dialog is up. When no page has been shown yet, the dialog is the whole content of a small window sized by the dialog (`compact`), and the window grows to its normal size when the first full page arrives.

**Settling.** For `settleTime` (350 ms) after a page or dialog appears, the window takes no keys and no clicks. An Enter or a double click meant for the page before must not answer the next one, which may be "Apply this fix?". The time starts again with every key event and for as long as a mouse button is down, so a key or button that is still held (or repeating) when the page appears cannot answer it however long it is held: the page takes input once everything has been let go for `settleTime`. The same holds later: when a key that can answer a page (Space, Enter, Esc) repeats while a page waits, the page stops taking input until the key has been up for `settleTime` (`hold()`), and the keyboard focus then returns to the control it was on. A held key never answers anything.

**Focus.** While a page settles, the keyboard focus stays with the window. Then it goes to the item `initialFocus()` returns, or to wherever the page's own `focus: true` says; with neither, no control has it and Tab goes to the first one. `Confirm.qml` is the page that does this on purpose (`initialFocus()` returns `null`): Space presses the focused button, and with the focus on Apply the Space meant for "Skip" on the fix before would apply the next one. There, Enter still applies and Esc cancels; Space or a click needs a deliberate move to the button. Each page is a focus scope. Tab stays inside a dialog while one is shown.

**Enter and Esc.** They reach the Shell only when the focused control did not use them (an open combo box takes both). Esc calls `dismiss()`. Enter calls `primary()`, with two exceptions: in a text field or text area it does nothing here, and on a focused button that cannot be ticked (`checkable` is false) it presses that button. Everything that can be ticked leaves Enter to `primary()`: a tick box, a radio row of a dialog's list, a row of the Choose page, an option card of the wizard. Those rows and cards are real checkable buttons (`AbstractButton` with `checkable: true`), so Space ticks the one with the focus and a screen reader announces a check box. On a closed combo box Enter is `primary()` as well.

**Busy.** After an answer the page stays. If the next request does not come within `Kirigami.Units.veryLongDuration`, the page is dimmed and a spinner shows; a `busy` line shows it at once, with its label. A `busy` line while a page waits for its answer does not cover that page.

**Progress.** `progress start` parks the main window (hidden) and shows `Progress.qml`, with a tray icon where the desktop has a tray. The next page request or busy label closes the progress window and brings the main window back. If the progress window cannot be loaded, the main window's spinner shows the progress labels instead.

**Close button.** It answers the waiting request with status 1 and the window stays; the root side decides what comes next. With nothing to answer, the window hides until the next page or the next busy line with a label, either of which brings it back. It never stops a fix that is running. Closing the progress window only hides or minimises it.

## Adding a page

1. Write `ui/qml/Name.qml` to the contract above. Start from the page closest to what you need; `Confirm.qml` is the shortest.
2. Add the mode to `PAGES` in `ui/app.py` and to the list of modes in its header comment.
3. On the root side, build the input as JSON (`_json_str` for every value), call `out=$(ui_app name "$json")`, and handle each status: 0, validate `out` with a small `python3 -I -c` script that keeps only what was offered, and fall back if it is rejected; 1, cancelled; anything else, fall back to the kdialog or terminal version of the same question. `apply_change` in `lib/fixes.sh` with `_confirm_answer` is a short example.
4. Add a sample input to `tests/ui/samples.json` (made-up values only) and cases to `tests/ui-offscreen.py`: in `sc_pages` the answer to Enter, the answer to Esc, and the mode in the list that is tried with `{}`; in `sc_controls` every other control that answers; in `sc_tab` the page.
5. Cover the root-side caller, its validation and its fallback in `tests/smoke.sh`.

## Trying a page without root

The front end never needs root. On a KDE desktop with PySide6 and Kirigami, show one page with a sample input and see the answer and the exit status:

    python3 -c 'import json; print(json.dumps(json.load(open("tests/ui/samples.json"))["confirm"]))' \
        | python3 -I ui/app.py confirm; echo "status $?"

`BSA_THEME=light` or `BSA_THEME=dark` in front forces a theme. To drive the long-lived window by hand, run `python3 -I ui/app.py serve` in a terminal and type request lines; the answers are printed there.

Without a display, save a picture of every page:

    python3 -I tests/ui-offscreen.py --shots /tmp/shots pages

## Tests

| Command | What it covers | Needs |
|---|---|---|
| `make lint` | ShellCheck on the scripts; `ui/app.py` and `tests/ui-offscreen.py` parse | shellcheck |
| `make test-ui` | The real front end, off-screen (`tests/ui-offscreen.py`) | PySide6 with Qt Quick, Kirigami, qqc2-desktop-style; no root, no display |
| `make test` | The root side against a fake front end and fake system tools (`tests/smoke.sh`): `lib/ui.sh`, answer validation, the kdialog fallback | root, a throwaway container or VM |

`tests/ui-offscreen.py` loads `ui/app.py` as a module and runs its `main()` with stdin and stdout replaced by pipes, one process per scenario. It sends request lines, presses keys and clicks in the window and checks every answer line against the pattern `lib/ui.sh` uses. Any QML warning fails the scenario it appears in, every wait has a time limit, and a scenario that does not end is killed and reported. It uses the test interface of `ui/app.py`: `PAGE_DIR` (the folder the page files come from, for stub pages), `TEST_HOOK(app, shell, host)` and `main()`. `Shell.qml` and `Progress.qml` are never taken from `PAGE_DIR`: they always come from `ui/qml/`.

| Scenario | Checks |
|---|---|
| `pages` | every page with its sample and with `{}`: loads without a warning, Enter and Esc give the expected answer |
| `shell` | a dialog first and over a page, busy, progress, theme, the close button, two requests at once |
| `controls` | every other control that answers (buttons, rows, tick boxes, the theme box), clicked or pressed with Space: the answer is one the root side accepts |
| `tab` | Tab reaches every button of the bar at the bottom of each page |
| `guard` | a key or click as a page appears, auto-repeat, and a key or mouse button held since the page before do not answer it; Confirm starts with the focus on no button |
| `keys` | which control gets Enter: text field, text area, button, combo box (stub page) |
| `malformed` | lines that are not requests: one answer with status 3 each, never silence |
| `exception` | an exception while a line is handled: one answer with status 3, and the next request is served |
| `broken-page` | page files that do not load or are not pages: status 3, the reason on stderr, the window goes on |
| `eof`, `quit`, `owner-gone` | the ways `serve` ends with a page on screen: status 0 |
| `eof-idle`, `quit-first`, `blank-quit` | `serve` ends before anything was shown: status 0, Qt never started |
| `progress-only`, `oneshot`, `oneshot-esc`, `oneshot-close`, `oneshot-broken`, `oneshot-bad` | `app.py progress` and one page per process |

Run some of them by name, with everything the front end wrote to stderr:

    python3 -I tests/ui-offscreen.py --verbose guard keys

CI runs `make test-ui` as the "UI test" job in a Fedora container, because Ubuntu does not package PySide6's Qt Quick modules or Kirigami. Two things to know when a check fails there but not at home: the container has no icon theme and no Breeze colour schemes, so icons are missing in pictures and the theme check only tests the message; and the window's 350 ms settle timer runs with the frames it draws, which off-screen can be slower than the clock, so the test waits for `settling` to end before it presses a key, and where it must act inside the pause it does so only while `settling` is still true (and asks for the page again when it was too late).
