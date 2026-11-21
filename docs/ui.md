# The Security Check window: notes for developers

This describes the Kirigami front end: how it talks to the rest of the tool, what a page is, and how to add or test one. The code is `ui/app.py`, `ui/qml/` and the first half of `lib/ui.sh`. Where this file and the code disagree, the code is right and this file needs a fix.

## Two sides

| | Root side | Front end |
|---|---|---|
| Code | `bazzite-sec-audit.sh`, `lib/*.sh`, `checks/*.sh` | `ui/app.py` (PySide6), `ui/qml/*.qml` (Kirigami) |
| Runs as | root | the desktop user (`_as_desktop_user`), never root |
| Does | checks, fixes, reports; decides what is shown next | shows one page, returns what the person chose |

The root side starts the front end once per run (`ui_front_start`: `python3 -I ui/app.py serve`) with two pipes: requests go in on its stdin, answers come back on its stdout. One window, `ui/qml/Shell.qml`, stays open for the whole run and shows the pages one after the other. Until the first line that is not empty arrives, the front end is an idle process: Qt is not loaded and no window exists. Any such line loads Qt, a `busy` or `theme` line as much as a page request; only `quit` as the first line does not.

Trust goes one way. The desktop user's account is trusted less than root, so:

- The front end gets nothing of root's except the two pipes and a third for its stderr: not the run log, and not the run's lock (`_run_lock_close` closes it for every program started as another account, and for fixes). A root process (`_ui_log_reader`) copies that stderr into the run log, each line cut to size and marked `ui:`; the front end never holds the log file. In all, `_UI_LOG_MAX` bytes (256 KiB) per front-end process are read, NUL bytes included; then the pipe is closed and the front end's later messages are lost. The reader holds neither of the two pipes, and it ends within a second of the front end's end even when a program the front end left behind keeps writing.
- The root side treats every answer as untrusted input. `_ui_front_ask` takes the answer line apart with one fixed pattern (no JSON parser in the shell) and accepts only a line shorter than `_UI_FRONT_LINE_MAX` bytes (64 KiB; the pages' answers are a few hundred bytes). That is the limit that counts: it is below the 128 KiB the kernel allows for one program argument, which is how a caller hands the answer to its checking script. Each caller then validates the answer and keeps only values it offered: a tag from its own list, a button it sent, a known action.
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

- A line that is not JSON (or is JSON nested deeper than the parser takes), is not an object, or is an object with none of the five keys is answered with `{"id":"","status":3,"answer":null}`.
- A page request without a usable id is answered the same way. With a usable id but an unknown mode, a mode that is not a string, or `data` that is not an object, the answer carries the request's id and status 3.
- A page file that does not load, or loads but is not a page (not an `Item`, or without `finished` and `cancelled`), is answered with the request's id and status 3. The window stays up.
- A page's answer that cannot be written as JSON (a date, not-a-number) is logged and sent as status 3 with `null`.
- An exception while a line is handled is logged and answered with status 3, with the request's id when the line had a usable one.
- An answer that cannot be written (the root side closed its end of the answer pipe) ends the front end.
- A second request while one waits: the first is answered with status 1, then the second is shown. The root side skips answer lines that carry another id.
- The front end exits when the root side goes away without saying so: its parent process changes, or the process named in `BSA_OWNER_PID` is gone (`_Owner`, checked every two seconds).

The rule behind all of these: the root side must never wait for ever. It waits for an answer without a time limit, because a person answers when they answer, so every request line must produce an answer line or the pipe must close.

`app.py serve` exits with status 0, or 3 when Qt or the window could not be loaded or the program itself failed with an exception (never 1, which a one-page process uses for "cancelled"). The root side does not read the status; it sees the answer pipe close.

### Stopping the front end

`ui_front_stop` sends `quit` (given up after a second when the request pipe is full and the front end takes nothing out of it), closes the pipes and watches the front end's processes end, which normally takes a fraction of a second and needs no signal. Only a front end that hangs is ended: TERM after two seconds, KILL a second later. Root ends processes for a less trusted account here, so it must never hit a process that is not the front end's. A process id alone does not say that (an id is free again once its process has ended, and the front end decides when that is), so the rules are: a process is named by its id and its start time together, and the helper's are recorded when it is started; the list of what belongs to the front end is made while root still holds the pipes, when the helper does not end by itself; every signal is sent only after the start time has been read again, directly before; the front end's own processes are signalled as the desktop user (through `runuser`), so the kernel refuses anything that is not that account's; and root itself signals only its own helper processes. Should the helper have ended before the front end (ended from outside), there is no process to make that list from; the list is then what a shell of the run last saw below the helper while it lived, under the same rules (`_ui_front_note` keeps it in the file `ui-front-seen` in the run's private folder, because the first pages are asked from `$(...)`; it is taken each time a shell uses the front end and once a second while one waits for an answer). Nothing in `ui_front_stop` waits without a limit: it runs in the EXIT trap, and the private folder and the run's lock are only given up after it. The comment above `ui_front_stop` in `lib/ui.sh` has the reasoning.

### Fallback to kdialog

`ui_app MODE JSON` in `lib/ui.sh` is the one function callers use. It returns 0 (answer on stdout), 1 (cancelled), 3 (the front end failed) or 4 (not available here: no KDE session, no PySide6, no Kirigami, or it failed earlier in this run), and nothing else: where one page is shown by a process of its own (below), every exit status of that process other than 0 and 1 becomes 3.

On status 3 (or any status other than 0 and 1), an answer line in another form, a closed pipe, or a front end that has gone while a program it started still holds the answer pipe (`_ui_front_ask` reads a second at a time and looks in between whether the front end is still up), `_ui_front_ask` logs the failure, stops the front end (`ui_front_stop`) and marks it as gone for the rest of the run (the file `ui-front-gone` in the run's private folder, because the caller is often a `$(...)` subshell). The caller then asks the same question with kdialog, or on the terminal when kdialog fails too. A caller also falls back when it rejects the answer. So a broken page costs the Kirigami look for the rest of that run, never the run itself.

The front end can also go away while nobody waits for an answer. When it ends, the helper subshell that ran it writes `ui-front-gone` and from then on reads the request pipe and throws the lines away, so a write to that pipe neither fails nor blocks. When the helper itself has ended (a signal that went to every process of the tool, which the main shell holds back while it records a fix), `_ui_front_up` sees that, writes the file, and nothing more is sent. A write that still meets a pipe without a reader must not end the root shell with SIGPIPE, which would skip the EXIT trap and leave the fix unrecorded: `_pipe_write` ignores the signal for that one write and reports the failure. The signal is not ignored for the whole run, because every program started from the tool would inherit that, and the checks rely on the default (`find | head`). For the same reason a tool that is started with SIGPIPE already ignored (the weekly check's systemd service, some launchers; a shell cannot reset that) starts itself again through `env --default-signal=PIPE`, at the end of `bazzite-sec-audit.sh`.

**Which button Enter presses in a dialog from the root side.** `ui_yesno` and `ui_choice3` send `primary` after the question's default answer: the No button for default `n`, the Yes button for default `y`. A question whose Yes changes the PC as administrator there and then (the plain Apply dialog, each undo step, roll back, install, remove, update) is marked `careful` or `warn`: with default `y` it gets `primary` -1, so no button is the main one and a stray Enter or Space does nothing. kdialog cannot be told its default button: Enter presses its Yes place in every question, the warning dialog included (since kdialog 19.12, which builds the message box without KMessageBox's `Dangerous` option). So unless Yes is the default (`y` and not marked), the No answer goes in kdialog's Yes place and the Yes answer in its No place, and the exit status is read back the other way round (`_kd_answer`, which also makes sure exit 1 came from kdialog itself and not from `runuser`). Esc or closing is exit 2, never Yes. Marked questions use kdialog's warning dialog for its icon. Such a question reads No before Yes, and kdialog's icons for its places (a tick, a stop sign) sit on the other answers.

### One page per process

`app.py MODE < input.json` shows that one page in a window of its own and prints the answer as one JSON value. Exit status 0 answered, 1 cancelled, 2 bad input, 3 cannot run here. `app.py progress` shows the progress window alone and reads progress lines until end of input or a line `QUIT`. The root side uses these only when it could not make the two pipes for `serve` (`_ui_app_page`, the `window` progress backend). `_ui_app_page` passes on 0 and 1 and turns every other status (2, a signal, an error of `runuser`) into 3, as it does an answer of `_UI_FRONT_LINE_MAX` bytes or more (no more than that is read); `ui_app` then writes `ui-front-gone` as well, so that the front end is not tried again. An installed 1.5.0 also calls them while it updates itself to a newer version, so they must stay.

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
        readonly property Item scrollArea: …  // optional: the Flickable that PageUp, PageDown, Home, End and the arrows scroll
    }

The Shell creates the page, fills its area with it, and connects the two signals. Only the first `finished` or `cancelled` counts; a second click on a page that has answered does nothing.

Rules pages follow:

1. No window, no window size, no `onClosing`. The page fills its parent and works from 34 x 28 grid units up to a large screen. Only `Dialog.qml` has an implicit size, because the Shell sizes a dialog by its content.
2. Layout: `PageHeader` on top, scrollable content, `FooterBar` at the bottom. Exactly one `PrimaryButton`, rightmost in the footer; every other button is a plain `QQC2.Button`. The order `[Cancel] [Main action]` is deliberate, on every page and in every dialog: the main action is the rightmost button, as with Back and Next in the wizard and with Apply in System Settings. `Dialog.qml` is the exception to "exactly one": it shows the buttons the root side sends, in that order, and fills the one `primary` names (the last one when `primary` is not sent). That can be the leftmost (`primary` 0) or none at all (`primary` -1: no button is filled, none has the focus, Enter does nothing), which the root side uses where no button should be the default.
3. `primary()` does what the main button does. The one exception is `Confirm.qml`, where it applies the fix only while the Apply button itself has the keyboard focus, and does nothing otherwise. `dismiss()` goes back or emits `cancelled()`, and may do nothing: on the dashboard Esc does nothing, because that is where Esc on a check comes back to and a second Esc must not end the run.
4. A page must load with `input` equal to `{}` without a warning. Read fields as `input.x || default`.
5. Every control is reachable with Tab and usable with Space. A custom clickable item gets `activeFocusOnTab`, a `FocusRing`, key handling, and `Accessible.name` and `Accessible.role`. A tick box gets a `FocusRing` too: the desktop style shows no keyboard focus on one. A list of rows or chips is one stop for Tab, at its current item, and the arrow keys, Home and End move inside it (the rows of Choose, a dialog's list, the area chips and the checks of the dashboard). A control that gets the keyboard focus is scrolled into view (`Util.reveal`): all of it when it fits, and its top when it is taller than the room there is (a finding's card starts with its tick box and title). A control drawn from several labels (a card, a row, a chip, the main button) says them once, as its own `Accessible.name` and `Accessible.description`: the labels inside it get `Accessible.ignored: true`. What a screen reader is told is plain text: a label that shows rich text gets a plain `Accessible.name` (`Util.plain`), and a message in a box is a `Notice`, not a `Kirigami.InlineMessage`, which hands assistive tools its markup.
6. All visible strings go through `qsTr()`, with `.arg()` or `Util.fill()` instead of concatenation.
7. Colours and sizes come from `Kirigami.Theme` and `Kirigami.Units`. The state colours of a theme (`positiveTextColor`, `neutralTextColor`, `negativeTextColor`, `linkColor`, `disabledTextColor`) are for icons, fills and frames, not for text: as text they are below 4.5:1 on the page, in the light theme most of all. Text is in `textColor`; where a state should colour the text itself, use `Util.ink()`, and for a fill under `highlightedTextColor` use `Util.deep()`. A state is never shown by colour alone: an icon or the words say it too. What marks a control for the eye (the focus ring, the tick of a finished step) needs 3:1 against what is around it: the focus colour and the positive colour of Breeze do not have that on a light page, so `FocusRing` uses `Util.ink()` of the focus colour and the step's circle `Util.deep()`. A person may use a larger font than the grid units were made for: what holds text and is sized in grid units takes the larger of that size and what its text needs (the score ring, the circle of a step), and nothing relies on a text fitting a fixed room (the hint of `FooterBar` moves above the buttons when it does not fit next to them). No imports beyond those already used in `ui/qml/`: the pages must run on a stock Bazzite KDE image.
8. Never name a function `escape`: QML rejects it.
9. Keep the answer's keys and types stable. The root side validates them, and an installed older root side may talk to a newer page during an update.
10. No page has a text field that can be edited today. One that gets one must not answer when Space is typed in it or a line is added to it: a key held down in such a field types as in any text field, and the Shell's guard against held keys leaves it alone there (see "Settling"). Do not answer from a text area at all; a one-line field may take Enter as "done" (`onAccepted`), and a held Enter is still refused there.

### Shared components

All in `ui/qml/`, used by their bare name.

| Component | What it is |
|---|---|
| `PageHeader` | The band at the top: icon, optional small line, title, subtitle; items placed inside go in a row under the subtitle. |
| `FooterBar` | The bar at the bottom: `leading` buttons on the left, a short hint (two lines at most; on a line of its own above the buttons when it has no room between them), the page's buttons on the right. |
| `PrimaryButton` | The one main button of a page, filled with a deep shade of the highlight colour; `destructive: true` for a dangerous action. |
| `StatusChip` | A small rounded label: `sev` for a finding's severity, `risk` for the risk of a change, or your own text and tint. The tint colours the fill and the frame, the words are in the text colour; `quiet` leaves the fill out. |
| `Notice` | A message in a tinted box with an icon: `kind` (info, positive, warning, error), a `title` in bold and a `text`, both plain text. |
| `Section` | A titled block of content. |
| `NowAfter` | A setting now and after the fix, one above the other. |
| `AffectsList` | What a fix affects on Bazzite: one row per feature. |
| `WarningsBox` | The "before you apply" side effects of a fix. |
| `CodeBlock` | Commands or other fixed-width text: read-only, selectable, with a Copy button. With the keyboard focus in it the text shows its cursor, and the page scrolls along with the cursor. |
| `ExpandableText` | A check's description: its first lines, and a button for the rest when it is longer. |
| `FocusRing` | The keyboard focus ring for controls drawn in this folder. |
| `util.js` | Helpers (`import "util.js" as Util`): `esc`, `tip`, `plain`, `mnemonic`, `fill`, `reflow`, `reveal`, `within`, `ink`, `deep`, and the names, icons and colours of states, severities and risks. |

## What the Shell does

`Shell.qml` is a `Kirigami.ApplicationWindow` with a `host` object from `app.py`: signals `request`, `busy` and `park`, and the slot `reply(id, status, answer)`.

**Pages and dialogs.** A request replaces the current page; the new one fades in over the old. A `dialog` request is shown as a card over the current page, which is dimmed and takes no input while the dialog is up. When no page has been shown yet, the dialog is the whole content of a small window sized by the dialog (`compact`), and the window grows to its normal size when the first full page arrives.

**Settling.** For `settleTime` (350 ms) after a page or dialog appears, the window takes no keys and no clicks. An Enter or a double click meant for the page before must not answer the next one, which may be "Apply this fix?". This includes the buttons' own shortcuts (every button has one, Alt and a letter of its label): Qt looks a key up as a shortcut before the Shell's key handlers are asked, so while a page settles the Shell accepts every key when it is announced (`Keys.onShortcutOverride`), which keeps it from being a shortcut. The time starts again with every key event and with every press and release of a mouse button, so a key that is still held (or repeating) when the page appears cannot answer it however long it is held, and neither can pressing or clicking on and on: the page takes input once the keyboard and the mouse have been quiet for `settleTime`. A mouse button held since the page before needs no care: letting go of it clicks nothing, because the new page never saw it go down. The pause counts from the first picture of the page: a window that was hidden starts it again with the first frame it draws.

The same holds later: when a key that can answer a page (Space, Enter, Esc, or anything with Alt) repeats while a page waits, the page stops taking input until the key has been up for `settleTime` (`hold()`), and the keyboard focus then returns to the control it was on, with its focus ring if it had one. That is what stops a key held since the page before whose first repeat comes later than `settleTime`. What is guaranteed: a key held down never answers the page after the one it was pressed on. On the page it was pressed on it counts once: Enter and Esc with the press, and Space held on a focused button presses that button once, when the keyboard starts to repeat (the button takes the first repeat as the end of the press). A page that has answered takes nothing more, neither keys nor clicks.

**Alt keys.** Every button gets a shortcut from Kirigami (`MnemonicData`): Alt and a letter of its label, chosen among the buttons that are switched on at that moment. A letter that becomes free later is not given out again. A new page is made while the old one is still there, so the Shell makes it switched off and switches it on when what it replaces is switched off: a page that follows one with the same buttons ("Apply this fix?" after "Apply this fix?") gives them the same keys. A button that is on a page only sometimes would move the letters of the others: the "Show all details" button of `ExpandableText` has no Alt key for that reason (`Kirigami.MnemonicData.enabled: false`). The style draws the underline of a plain button; the main button draws its own, and on a page that appears while Alt is held it asks the window (`altDown`), because Kirigami tells a button only of the next press of Alt.

One kind of held key is left alone, because it only types (`typing()`): Space in a text field that can be edited, and Enter in a text area that can be edited, where it starts a new line. They repeat as in any text field and answer nothing. Everything else is refused while it repeats in a text field too: Esc, anything with Alt, Enter in a one-line field, and every key in a field that is read-only.

**Focus.** While a page settles, the keyboard focus stays with the window. Then it goes to the item `initialFocus()` returns, or to wherever the page's own `focus: true` says; with neither, no control has it and Tab goes to the first one. `Confirm.qml` is the page that does this on purpose (`initialFocus()` returns `null`): Space presses the focused button, and with the focus on Apply the Space meant for "Skip" on the fix before would apply the next one. Enter does not apply from anywhere on that page either: its `primary()` does nothing unless Apply itself has the keyboard focus, so a fix is applied by a click on Apply, by its Alt key, or by Enter or Space after a deliberate move to the button (Tab goes through the page to it, Shift+Tab goes straight to it; the hint in the bar at the bottom names Tab and Enter). Esc cancels as everywhere. Each page is a focus scope. Tab stays inside a dialog while one is shown.

**Enter and Esc.** They reach the Shell only when the focused control did not use them (an open combo box takes both). Esc calls `dismiss()`. Enter calls `primary()`, with two exceptions: in a text field or text area it does nothing here, and on a focused button that cannot be ticked (`checkable` is false) it presses that button. Everything that can be ticked leaves Enter to `primary()`: a tick box, a radio row of a dialog's list, a row of the Choose page, an option card of the wizard. Those rows and cards are real checkable buttons (`AbstractButton` with `checkable: true`), so Space ticks the one with the focus and a screen reader announces a check box. On a closed combo box Enter is `primary()` as well. With Ctrl, Shift, Alt or Meta held, Enter and Esc do nothing here; the Enter key of the number block is Enter.

**Scrolling.** PageUp, PageDown, Home, End and the Up and Down arrows scroll the page when the focused control did not use them (a combo box and a list row keep their arrows, a text field its Home and End), so text without a control in it can be read with the keyboard too. The page says what scrolls with `scrollArea`, its Flickable; a page without one is not scrolled. PageUp and PageDown move by nine tenths of what is visible, the arrows by three grid units, Home and End go to the ends, and nothing moves past them. While a dialog is over a page, the dialog's `scrollArea` is the one that scrolls.

**Busy.** After an answer the page stays. If the next request does not come within `Kirigami.Units.veryLongDuration`, the page is dimmed and a spinner shows; a `busy` line shows it at once, with its label. A `busy` line while a page waits for its answer does not cover that page, and its label is dropped: it is not shown after the answer either.

**Progress.** `progress start` parks the main window (hidden) and shows `Progress.qml`, with a tray icon where the desktop has a tray. The next page request or busy label closes the progress window and brings the main window back. If the progress window cannot be loaded, the main window's spinner shows the progress labels instead.

**Close button.** It answers the waiting request with status 1 and the window stays; the root side decides what comes next. With nothing to answer, the window hides until the next page or the next busy line with a label, either of which brings it back. It never stops a fix that is running. Closing the progress window only hides or minimises it.

## Adding a page

1. Write `ui/qml/Name.qml` to the contract above. Start from the page closest to what you need; `Confirm.qml` is the shortest.
2. Add the mode to `PAGES` in `ui/app.py` and to the list of modes in its header comment.
3. On the root side, build the input as JSON (`_json_str` for every value), call `out=$(ui_app name "$json")`, and handle each status: 0, validate `out` with a small `python3 -I -c` script that keeps only what was offered, and fall back if it is rejected; 1, cancelled; anything else, fall back to the kdialog or terminal version of the same question. `apply_change` in `lib/fixes.sh` with `_confirm_answer` is a short example.
4. Add a sample input to `tests/ui/samples.json` (made-up values only, with exactly the keys the root side sends; name the function that builds the input in `BUILDERS` in the test, and the `sample-keys` scenario compares the two) and cases to `tests/ui-offscreen.py`: in `sc_pages` the answer to Enter, the answer to Esc, and the mode in the list that is tried with `{}`; in `sc_controls` every other control that answers; in `sc_tab` the page.
5. Cover the root-side caller, its validation and its fallback in `tests/smoke.sh`.

## Trying a page without root

The front end never needs root. On a KDE desktop with PySide6 and Kirigami, show one page with a sample input and see the answer and the exit status:

    python3 -c 'import json; print(json.dumps(json.load(open("tests/ui/samples.json"))["confirm"]))' \
        | python3 -I ui/app.py confirm; echo "status $?"

`BSA_THEME=light` or `BSA_THEME=dark` in front forces a theme. To drive the long-lived window by hand, run `python3 -I ui/app.py serve` in a terminal and type request lines; the answers are printed there.

Without a display, save a picture of every page:

    python3 -I tests/ui-offscreen.py --shots /tmp/shots pages

The same scenarios run in real windows of the session, for a look at them on a real desktop, with `BSA_UI_TEST_PLATFORM=wayland` (or `xcb`) in front. The default is off-screen, and CI uses only that. Checks that need the real keyboard focus or the real clipboard can fail there while another window is in front.

## Tests

| Command | What it covers | Needs |
|---|---|---|
| `make lint` | ShellCheck on the scripts; `ui/app.py` and `tests/ui-offscreen.py` parse | shellcheck |
| `make test-ui` | The real front end, off-screen (`tests/ui-offscreen.py`), then the tool's own functions asking that front end for pages (`tests/ui-e2e.sh`) | PySide6 with Qt Quick, Kirigami, qqc2-desktop-style; no root, no display |
| `make test` | The root side against a fake front end and fake system tools (`tests/smoke.sh`): `lib/ui.sh`, answer validation, the kdialog fallback | root, a throwaway container or VM |

`tests/ui-e2e.sh` is the one place where the two halves meet: it sources the tool, starts the real front end with `ui_front_start` and asks it for questions and pages through `ui_app`, `ui_yesno` and `ui_radiolist`, with a key pressed for it. A change to the request or answer form on one side only fails there.

`tests/ui-offscreen.py` loads `ui/app.py` as a module and runs its `main()` with stdin and stdout replaced by pipes, one process per scenario. It sends request lines, presses keys and clicks in the window and checks every answer line against the pattern `lib/ui.sh` uses. Any QML warning fails the scenario it appears in, every wait has a time limit, and a scenario that does not end is killed and reported. It uses the test interface of `ui/app.py`: `PAGE_DIR` (the folder the page files come from, for stub pages), `TEST_HOOK(app, shell, host)` and `main()`. `Shell.qml` and `Progress.qml` are never taken from `PAGE_DIR`: they always come from `ui/qml/`. So the two scenarios that need `Progress.qml` to fail (`no-progress-window`, `progress-broken`) replace the function that loads it, `_Ui.load`, in the loaded module.

| Scenario | Checks |
|---|---|
| `pages` | every page with its sample and with `{}`: loads without a warning, Enter and Esc give the expected answer (on Confirm, Enter with the focus on no button applies nothing) |
| `shell` | a dialog first and over a page (the window is never told to have a width or height of 0, nor a size smaller than the small window, when it grows into the first page), busy (and a label that comes while a page waits), progress, theme, the close button, two requests at once, the settle pause of a window that comes up with a page in it, the scroll keys on a real page; what a screen reader is told about the busy card (a status, named by its label) and about a dialog over a page (a dialog, named by its title) |
| `controls` | every other control that answers (buttons, rows, tick boxes, the theme box), clicked or pressed with Space: the answer is one the root side accepts; on Confirm, Enter applies only with the focus on Apply; Enter with nothing ticked neither continues on Choose (where one must be picked) nor sends a fix on a check; the wizard without a report folder goes to Options instead of starting, and its answer has every key also when the input left some out; Home and End in a dialog's list; the Copy button |
| `tab` | Tab reaches every button of the bar at the bottom of each page |
| `a11y` | no markup in what a screen reader is told, and a message box's text is its name; every scrolling page has a `scrollArea`; a focus ring on tick boxes and on the link in Settings; the dashboard's area chips and checks are one Tab stop each, with the arrow keys inside; the report folder's description; the main button underlines its Alt key; long dialog buttons stay inside the dialog; no control is said a second time by a label inside it; the rows of Choose are one Tab stop and check boxes by role and name, the command block and its Copy button are Tab stops, a severity chip is a named text; text from the PC is escaped in a tool tip and in the main button's label; `util.js` (`esc`, `tip`, `mnemonic`, `plain`, `fill`, `reflow`) called directly |
| `guard` | a key, a button's Alt+letter shortcut or a click as a page appears (and on and on after it: each further key or click is sent only while `settling` is still true, and the page is asked for again when this machine was too slow, so no part is skipped), auto-repeat, and a key or mouse button held since the page before do not answer it; a held key answers the page it was pressed on once; after a held key the focus is back where it was; a page that has answered takes nothing more; Confirm starts with the focus on no button; a page or dialog that follows one with the same buttons has the same Alt keys, with or without a "Show all details" button on it, and the main button shows its key when the page appears while Alt is held, also while Alt repeats; the window forgets Alt (`altDown`) once another window takes over, and from then on the underline follows Kirigami's own Alt state. Keys are sent both through Qt's keyboard path (`QTest`, where shortcuts are looked up) and straight to the window |
| `keys` | which control gets Enter: text field, text area, button, combo box; Enter and Esc with a modifier; the keys that scroll, on a page, on a dialog over it and where nothing is named to scroll (stub pages) |
| `typing` | a key held down in a text field that can be edited types and answers nothing (Space; Enter in a text area); Esc, Alt+key, Enter in a one-line field and any key in a read-only field are still refused while they repeat (stub page) |
| `malformed` | lines that are not requests, one of them JSON nested too deep for the parser: one answer with status 3 each, never silence |
| `deep-first`, `oneshot-deep` | JSON nested too deep as the first line of `serve` (status 3, the next request is served) and as the input of one page (exit status 2) |
| `first-lines`, `first-lines-quit` | lines written together with the first one, before the front end starts, are handled in their order: a busy label and two requests; a request and `quit` |
| `exception` | an exception while a line is handled: one answer with status 3, and the next request is served |
| `answer-closed` | the answer pipe is closed at the root side's end: `serve` ends by itself when it cannot write an answer |
| `crash` | `app.py` run as a program that fails with an exception: exit status 3, not 1 |
| `broken-page` | page files that do not load, are not pages, or that the Shell fails to set up: status 3, the reason on stderr (each of the three in its own words), nothing of them left in the window, the window goes on |
| `eof`, `quit`, `owner-gone` | the ways `serve` ends with a page on screen: status 0 |
| `eof-idle`, `quit-first`, `blank-quit` | `serve` ends before anything was shown: status 0, Qt never started |
| `parent-gone` | the front end's parent process changes while a page waits: `serve` ends with status 0 |
| `serve-edge` | `app.py` itself: a line printed on stdout does not reach the answers, an empty busy label does not bring back a closed window and closes the progress window, a percentage that is not 0 to 100 is shown as "no percentage" |
| `no-progress-window` | `Progress.qml` cannot be loaded: the main window's spinner shows the progress labels |
| `odd-answer` | a page's answer that is not JSON (a date, not-a-number): status 3 |
| `variants` | the dashboard of a report-only run; dialogs with `primary` 0, 1, -1, none and out of range: which button is filled, has the focus and gets Enter and Space |
| `reveal` | the control with the keyboard focus is in view from its top edge on: Tab and Shift+Tab through every stop of every page and the arrow keys through its lists in the smallest window, Tab again at 900 x 720; the cursor of a command block shows while it has the focus, and the page follows it |
| `contrast` | measured from pictures of the window, in the colours as they come and (where the Breeze colour schemes are installed, so not in CI) in the light and the dark theme: every focus ring has 3:1 against what is outside it, against the gap inside it and against the fill of the card it is around; the placeholder of the report folder has 4.5:1; the tick of a finished step 3:1 |
| `layout`, `large-text` | what must fit in the smallest window, with the text as it comes and with a 15 pt font (the grid units stay as they are): the score and the grade inside the ring, the step numbers inside their circles, the whole hint of the bar at the bottom and its buttons inside the window, a long label for the setting after the fix, a long title and subtitle, the Hide button of the progress window with a detail of two lines |
| `sample-keys` | `tests/ui/samples.json` against the root side: the samples of a page use every key its builder (`BUILDERS` in the test) sends and no other |
| `progress-only`, `progress-broken`, `oneshot`, `oneshot-esc`, `oneshot-close`, `oneshot-broken`, `oneshot-bad`, `oneshot-list`, `oneshot-odd` | `app.py progress` and one page per process |

Run some of them by name, with everything the front end wrote to stderr:

    python3 -I tests/ui-offscreen.py --verbose guard keys

CI runs `make test-ui` as the "UI test" job in a Fedora container, because Ubuntu does not package PySide6's Qt Quick modules or Kirigami. Three things to know when a check fails there but not at home. The Qt version differs: the CI image has Qt 6.10 (with Kirigami 6.30), a Bazzite desktop has Qt 6.11, and the two do not behave the same everywhere (on 6.10 a text field's placeholder becomes its accessible description, on 6.11 it does not). So run the CI image on your own machine before you push; this is the command, with `DIR` the folder of your copy (the image is the one named in `.github/workflows/ci.yml`; take it from there if it has changed):

    podman run --rm -v "$DIR":/src:ro,Z registry.fedoraproject.org/fedora@sha256:086bb30fc7dd0f84b266b9c93d14298f06e30d04421dcd6813629ea00542fa8a bash -c 'dnf install -y -q python3-pyside6 kf6-kirigami kf6-qqc2-desktop-style make git-core >/dev/null 2>&1; cp -r /src /w && cd /w && make test-ui'

The container has no icon theme and no Breeze colour schemes, so icons are missing in pictures and the theme check only tests the message. And the window's 350 ms settle timer runs with the frames it draws, which off-screen can be slower than the clock, so the test waits for `settling` to end before it presses a key, and where it must act inside the pause it does so only while `settling` is still true (and asks for the page again when it was too late).
