#!/usr/bin/python3 -I
# Security Check - off-screen test of the real front end (ui/app.py and
# every file in ui/qml/). No display, no root, no kdialog: Qt draws into
# memory (QT_QPA_PLATFORM=offscreen).
#
#   python3 -I tests/ui-offscreen.py [--shots DIR] [--verbose] [SCENARIO...]
#   make test-ui
#
# Each scenario runs in a process of its own: ui/app.py is loaded as a
# module and its main() runs there with stdin and stdout replaced by two
# pipes, the same two the root side (lib/ui.sh) holds. The scenario sends
# request lines, presses keys in the window and reads the answer lines. It
# is driven from inside the front end's own event loop, through the
# module's test interface: PAGE_DIR (the folder the page files come from)
# and TEST_HOOK(app, shell, host).
#
# One "ok" or "FAIL" line per check, then a summary; the exit status is 1
# when a check failed. A QML warning (a binding loop, a type error, a
# missing component) fails the scenario it appears in. Every wait has a
# time limit, and a scenario that does not end is killed and reported: the
# test cannot hang.
#
# --shots DIR saves a picture of every page (for people; nothing is
# compared). --verbose also prints everything the front end wrote to stderr.
# Sample inputs: tests/ui/samples.json (made-up values).
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.dirname(HERE)
APP = os.path.join(REPO, "ui", "app.py")
SAMPLES_FILE = os.path.join(HERE, "ui", "samples.json")

SETTLE = 0.65           # the window ignores Enter and Esc for ~350 ms after a page appears
SCENARIO_LIMIT = 100    # seconds for one scenario, inside it
KILL_AFTER = 120        # seconds after which the parent kills a scenario

# The one form of an answer line, as lib/ui.sh takes it apart (no JSON parser there).
ANSWER_RE = re.compile(r'^\{"id":"([^"]*)","status":([0-9]+),"answer":(.*)\}$')

# What Qt itself says on stderr without a real display or desktop session.
# Nothing about QML is in this list.
NOISE = [re.compile(p) for p in (
    r"^\s*$",
    r"^This plugin does not support ",                  # the offscreen platform: raise(), size hints
    r"^kf\.iconthemes: Icon theme \"[^\"]*\" not found",   # no icon theme installed (a bare container)
    r"^qt\.svg: ",                                      # an icon of the desktop's icon theme
    r"^kf\.sonnet\.",                                  # no spell checker installed (text areas)
)]

# ---- stub pages -------------------------------------------------------------
# For what the real pages do not offer: a page with a text field, a combo
# box and a second button (which control gets Enter), and files that are
# not pages.
STUB_PAGE = """// Test stub: a page with a text field, a combo box and a second button.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: "Stub page " + (input.n || "")
    signal finished(var answer)
    signal cancelled()
    function primary() { finished({ "via": "primary", "text": field.text, "combo": combo.currentIndex }) }
    function dismiss() { cancelled() }
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        QQC2.Label { text: page.title }
        QQC2.TextField { id: field; objectName: "field"; Layout.fillWidth: true }
        QQC2.TextArea { objectName: "area"; Layout.fillWidth: true }
        QQC2.ComboBox { id: combo; objectName: "combo"; model: ["one", "two", "three"] }
        QQC2.Button { objectName: "other"; text: "Other"; onClicked: page.finished({ "via": "button" }) }
        Item { Layout.fillHeight: true }
    }
}
"""
STUBS_KEYS = {"Wizard.qml": STUB_PAGE}
STUBS_BROKEN = {
    "Wizard.qml": STUB_PAGE,
    # A syntax error.
    "Check.qml": "import QtQuick\nItem { this is not QML\n",
    # A component that does not exist (a shared component gone missing).
    "Confirm.qml": "import QtQuick\nItem {\n    required property var input\n    signal finished(var answer)\n"
                   "    signal cancelled()\n    NoSuchComponent { }\n}\n",
    # Loads, but is not a page: not an Item.
    "Choose.qml": "import QtQml\nQtObject { property var input; property string iconSource }\n",
    # Loads, but is not a page: no finished() and cancelled().
    "Dialog.qml": "import QtQuick\nItem { required property var input; property string iconSource: \"\" }\n",
}

# ---- one scenario, in its own process ----------------------------------------
fails = 0
checks = 0
replies = []        # the answer lines, as they came
NAME = ""
SHOTS = ""
out_fd = 1
req_w = -1
rep_r = -1
err_file = None
err_pos = 0
engine_warnings = []
allowed = []        # warnings a scenario expects (regular expressions)
app = shell = host = appmod = None
SAMPLES = {}
_buf = b""


def say(text):
    os.write(out_fd, (text + "\n").encode())


def check(ok, what):
    global fails, checks
    checks += 1
    if not ok:
        fails += 1
    say("%s [%s] %s" % ("ok  " if ok else "FAIL", NAME, what))
    return ok


def cut(text, n=110):
    text = str(text)
    return text if len(text) <= n else text[:n] + "…"


def pump():
    """Take the answer lines that have arrived."""
    global _buf
    while True:
        try:
            chunk = os.read(rep_r, 65536)
        except (BlockingIOError, OSError):
            return
        if not chunk:
            return
        _buf += chunk
        *lines, _buf = _buf.split(b"\n")
        replies.extend(line.decode("utf-8", "replace") for line in lines)


def send(obj):
    """One line to the front end: an object (as JSON), or the text as it is."""
    data = obj if isinstance(obj, bytes) else (obj if isinstance(obj, str) else json.dumps(obj)).encode()
    os.write(req_w, data + b"\n")


def ask(rid, mode, data):
    send({"id": rid, "mode": mode, "data": data})


def parsed(line):
    """(id, status, answer) of an answer line; None if it has another form."""
    m = ANSWER_RE.match(line)
    if not m:
        return None
    try:
        return m.group(1), int(m.group(2)), json.loads(m.group(3))
    except ValueError:
        return None


def reply_for(rid):
    for line in replies:
        p = parsed(line)
        if p and p[0] == rid:
            return line, p
    return None, None


def got(rid):
    pump()
    return reply_for(rid)[0] is not None


def expect(rid, status, what, answer=None):
    """The answer to request RID has STATUS and (status 0) an answer that
    ANSWER, a function, accepts; any other status has the answer null."""
    line, p = reply_for(rid)
    if line is None:
        return check(False, "%s: no answer line for %s" % (what, rid))
    ok = p[1] == status and len([1 for r in replies if (parsed(r) or ("",))[0] == rid]) == 1
    if ok and status == 0 and answer is not None:
        try:
            ok = bool(answer(p[2]))
        except Exception:
            ok = False
    elif ok and status != 0:
        ok = p[2] is None
    return check(ok, "%s: %s" % (what, cut(line)))


def new_warnings():
    """What the front end has written to stderr (and the QML engine has
    reported) since the last call, without Qt's remarks about the missing
    display and the warnings this scenario expects."""
    global err_pos
    err_file.seek(err_pos)
    text = err_file.read().decode("utf-8", "replace")
    err_pos = err_file.tell()
    lines = text.splitlines()
    for w in engine_warnings:
        if not any(w in line for line in lines):
            lines.append(w)
    del engine_warnings[:]
    if os.environ.get("BSA_UI_TEST_VERBOSE"):
        for line in lines:
            say("     stderr: " + line)
    return [line for line in lines if not any(p.search(line) for p in NOISE + allowed)]


def no_warnings(what):
    w = new_warnings()
    return check(not w, "%s: no QML warnings%s" % (what, "" if not w else ": %d, first: %s" % (len(w), cut(" | ".join(w[:2]), 300))))


def key(k, repeat=False, text=""):
    """A key press and release in the window, as the person's keyboard sends them."""
    from PySide6.QtCore import QCoreApplication, QEvent, Qt
    from PySide6.QtGui import QKeyEvent
    for kind in (QEvent.Type.KeyPress, QEvent.Type.KeyRelease):
        QCoreApplication.sendEvent(shell, QKeyEvent(kind, k, Qt.KeyboardModifier.NoModifier, text, repeat))


def shot(name, win=None):
    if SHOTS:
        (win or shell).grabWindow().save(os.path.join(SHOTS, name + ".png"))


def prop(name):
    return shell.property(name) if shell is not None else None


def progress_window():
    from PySide6.QtGui import QGuiApplication
    for w in QGuiApplication.topLevelWindows():
        if w is not shell and w.property("percent") is not None:
            return w
    return None


def focus(name):
    from PySide6.QtCore import QMetaObject, QObject
    item = shell.findChild(QObject, name)
    if item is None:
        check(False, "the stub page has an item named %s" % name)
        return None
    QMetaObject.invokeMethod(item, "forceActiveFocus")
    return item


# What a scenario yields: W waits until COND() is true (the result is sent
# back: False after TIMEOUT seconds, which is also a failed check), P pauses.
def W(cond, what, timeout=6.0):
    return ("wait", cond, timeout, what)


def P(seconds):
    return ("pause", None, seconds, "")


def show(rid, mode, data, what):
    """Ask for a page and wait until it is the one on screen and takes keys."""
    ask(rid, mode, data)
    ok = yield W(lambda: got(rid) or (prop("pendingId") == rid and shell.isVisible()), what + ": shown")
    if ok and not got(rid):
        yield from settled(what)
    return ok and not got(rid)


def settled(what):
    """Wait until the page that has just appeared takes keys. The window's
    own clock for that (a QML Timer) runs with the frames it draws, which
    off-screen can be slower than the clock on the wall."""
    yield P(SETTLE)
    yield W(lambda: prop("settling") is not True, what + ": takes keys", 8.0)


def press(rid, keys, gap=0.15):
    """Press KEYS one after the other until the request is answered."""
    for k in keys:
        if got(rid):
            break
        key(k)
        yield P(gap)


def focus_text():
    """The control with the keyboard focus, for a failure message."""
    item = shell.activeFocusItem() if shell is not None else None
    if item is None:
        return "nothing"
    return "%s %r" % (item.metaObject().className(), item.property("text") or item.objectName() or "")


def answered(rid, what, timeout=4.0):
    ok = yield W(lambda: got(rid), what + ": answered", timeout)
    if not ok:
        say("     no answer to %s; pending: %r, settling: %r, keyboard focus: %s"
            % (rid, prop("pendingId"), prop("settling"), focus_text()))
    return ok


def K():
    from PySide6.QtCore import Qt
    return Qt.Key


# ---- the scenarios -----------------------------------------------------------
def sc_pages():
    """Every real page, with its sample input and with {}: it loads without
    a warning, and the keyboard answers it."""
    Return, Escape = K().Key_Return, K().Key_Escape
    S = SAMPLES
    wizard_keys = {"use", "fix", "deep", "report_dir", "action"}
    cases = [
        # name, mode, input, keys, status, what the answer must be
        ("wizard: Enter on every step starts the check-up", "wizard", S["wizard"], [Return] * 4, 0,
         lambda a: set(a) == wizard_keys and a["action"] == "start" and a["use"] == ["gaming", "streaming"]
         and a["fix"] is True and a["deep"] is False and a["report_dir"] == S["wizard"]["answers"]["report_dir"]),
        ("wizard: Esc on the first step cancels", "wizard", S["wizard"], [Escape], 1, None),
        ("wizard: opened on the Review step, Enter starts", "wizard", dict(S["wizard"], start_step=3), [Return], 0,
         lambda a: set(a) == wizard_keys and a["action"] == "start"),
        ("dashboard: Enter goes on to the fixes", "dashboard", S["dashboard"], [Return], 0, lambda a: a == {"action": "fix"}),
        # Esc on a check comes back here: a second Esc must not end the run.
        ("dashboard: Esc does nothing, the close button cancels", "dashboard", S["dashboard"], [Escape, Escape], "close", None),
        ("dashboard, nothing to fix: Enter finishes", "dashboard", dict(S["dashboard"], nfix=0), [Return], 0,
         lambda a: a == {"action": "finish"}),
        ("check: Enter fixes what is ticked", "check", S["check"], [Return], 0, lambda a: a == {"action": "fix", "ids": ["13"]}),
        ("check: Esc goes back", "check", S["check"], [Escape], 0, lambda a: a == {"action": "back"}),
        ("choose: Enter answers the ticked tags", "choose", S["choose"], [Return], 0, lambda a: a == {"tags": ["a", "b"]}),
        ("choose: Esc cancels", "choose", S["choose"], [Escape], 1, None),
        ("confirm: Enter applies", "confirm", S["confirm"], [Return], 0, lambda a: a == {"choice": "apply"}),
        ("confirm: Esc cancels", "confirm", S["confirm"], [Escape], 1, None),
        ("settings: Enter saves", "settings", S["settings"], [Return], 0,
         lambda a: set(a) == {"action", "theme", "update_check"} and a["action"] == "save" and a["theme"] == "system"),
        ("settings: Esc cancels", "settings", S["settings"], [Escape], 1, None),
        ("dialog, question: Enter is the last button", "dialog", S["dialog"], [Return], 0, lambda a: a == {"button": 1}),
        ("dialog, question: Esc cancels", "dialog", S["dialog"], [Escape], 1, None),
        ("dialog, message: Enter is OK", "dialog", S["dialog-message"], [Return], 0, lambda a: a == {"button": 0}),
        ("dialog, error: Enter is OK", "dialog", S["dialog-error"], [Return], 0, lambda a: a == {"button": 0}),
        ("dialog, list: Enter answers a button and a tag", "dialog", S["dialog-list"], [Return], 0,
         lambda a: set(a) == {"button", "tag"} and a["button"] == 1 and a["tag"] in ("fix", "report", "undo")),
        ("dialog, list: Esc cancels", "dialog", S["dialog-list"], [Escape], 1, None),
    ]
    for n, (what, mode, data, keys, status, answer) in enumerate(cases):
        rid = "p%d" % n
        if (yield from show(rid, mode, data, what)):
            check(bool(shell.title()), "%s: window title %r" % (mode, shell.title()))
            shot("%02d-%s" % (n, mode))
            yield from press(rid, keys)
            if status == "close":
                yield P(0.3)
                check(not got(rid) and prop("pendingId") == rid, "%s: still waiting after the keys" % mode)
                shell.close()
        yield from answered(rid, what)
        expect(rid, 1 if status == "close" else status, what, answer)
        no_warnings(what)

    # Back through the wizard's steps with Esc, then out.
    rid = "p-back"
    if (yield from show(rid, "wizard", S["wizard"], "wizard: Esc goes back a step")):
        key(Return)
        yield P(0.15)
        key(Return)
        yield P(0.15)
        page = prop("pageItem")
        check(page is not None and page.property("step") == 2, "wizard: two Enters reach the third step")
        key(Escape)
        yield P(0.15)
        check(page is not None and page.property("step") == 1 and not got(rid), "wizard: Esc goes back one step, without an answer")
        yield from press(rid, [Escape] * 3)
    yield from answered(rid, "wizard: Esc on the first step")
    expect(rid, 1, "wizard: Esc back to the first step, then cancelled")

    # With no input at all, a page still loads, warns about nothing, and
    # can be left: Enter may answer it (0), Esc always ends it (0 or 1).
    for mode in ("wizard", "dashboard", "check", "choose", "confirm", "settings", "dialog"):
        rid, what = "e-" + mode, "%s with {}" % mode
        if (yield from show(rid, mode, {}, what)):
            shot("empty-" + mode)
            yield from press(rid, [Return] * 5 + [Escape] * 6)
        yield from answered(rid, what)
        line, p = reply_for(rid)
        check(p is not None and p[1] in (0, 1) and (p[2] is None) == (p[1] == 1) and (p[1] == 1 or isinstance(p[2], dict)),
              "%s: answered or cancelled: %s" % (what, cut(line)))
        no_warnings(what)
    check(shell.isVisible(), "the window is still there after every page")
    send({"quit": True})


def sc_shell():
    """What the window does around the pages: a dialog alone and over a
    page, the busy label, the scan's progress window, the theme, the close
    button, and two requests at once."""
    Return, Escape, Tab = K().Key_Return, K().Key_Escape, K().Key_Tab
    S = SAMPLES
    # 1. a dialog is the first request (sent before the front end started)
    ok = yield W(lambda: got("d1") or (prop("pendingId") == "d1" and shell.isVisible()), "dialog first: shown")
    yield from settled("dialog first")
    small = (shell.width(), shell.height())
    check(prop("compact") is True and prop("dialogItem") is None, "dialog first: a small window of its own (%dx%d)" % small)
    check(shell.title() == S["dialog"]["title"], "dialog first: window title %r" % shell.title())
    shot("shell-dialog-first")
    key(Return)
    yield from answered("d1", "dialog first")
    expect("d1", 0, "dialog first: Enter answers", lambda a: a == {"button": 1})
    check(shell.isVisible(), "the window stays after the answer")

    # 2. the busy label
    send({"busy": "Looking for an update…"})
    yield W(lambda: prop("busyShown") is True and prop("busyLabel") == "Looking for an update…", "busy: label shown")
    shot("shell-busy")
    send({"busy": ""})
    yield W(lambda: prop("busyLabel") == "", "busy \"\": the usual label is back")
    check(prop("busyShown") is True and len(replies) == 1, "busy: still busy, and nothing was answered")

    # 3. the first page: the window grows, the spinner goes
    if (yield from show("s1", "confirm", S["confirm"], "first page")):
        big = (shell.width(), shell.height())
        check(prop("compact") is False and big[0] > small[0] and big[1] > small[1], "first page: the window grew to %dx%d" % big)
        check(prop("busyShown") is False, "first page: no longer busy")
        # A label while a page waits for its answer is kept for later.
        send({"busy": "Later"})
        yield P(0.3)
        check(prop("busyShown") is False and prop("pendingId") == "s1", "busy while a page is shown: the page stays usable")

    # 4. a dialog over the page
    if (yield from show("s2", "dialog", S["dialog-error"], "dialog over a page")):
        expect("s1", 1, "a second request while one is pending: the first is cancelled")
        check(prop("dialogItem") is not None and prop("pageItem") is not None and (shell.width(), shell.height()) == big,
              "dialog over a page: on top of it, same window size")
        shot("shell-dialog-over-page")
        slot, inside = prop("dialogSlot"), True
        for _ in range(6):
            key(Tab)
            yield P(0.03)
            item = shell.activeFocusItem()
            while item is not None and item is not slot:
                item = item.parentItem()
            inside = inside and item is not None
        check(inside, "dialog over a page: Tab stays inside the dialog")
        key(Escape)
    yield from answered("s2", "dialog over a page")
    expect("s2", 1, "dialog over a page: Esc cancels it")
    yield W(lambda: prop("dialogItem") is None and prop("pageItem") is not None, "dialog over a page: gone, the page is still there")

    # 5. two requests at once: the first is answered "cancelled", the second shown
    ask("s3", "confirm", S["confirm"])
    ask("s4", "choose", S["choose"])
    yield W(lambda: got("s3") and prop("pendingId") == "s4", "two requests at once: the second is shown")
    expect("s3", 1, "two requests at once: the first is cancelled")
    yield from settled("two requests at once")
    key(Return)
    yield from answered("s4", "two requests at once")
    expect("s4", 0, "two requests at once: the second is answered", lambda a: a == {"tags": ["a", "b"]})

    # 6. between two requests the page stays, under the spinner
    yield W(lambda: prop("busyShown") is True and shell.isVisible(), "after an answer: the window stays, busy")

    # 7. the scan: the window makes way for the progress window
    n_before = len(replies)
    send({"progress": "start", "heading": "Checking your PC"})
    yield W(lambda: progress_window() is not None and progress_window().isVisible() and not shell.isVisible(),
            "progress start: the progress window shows, the main window is hidden")
    pw = progress_window()
    if pw is not None:
        check(pw.property("heading") == "Checking your PC", "progress start: heading %r" % pw.property("heading"))
        send({"progress": "set", "line": "45\t0\tFirewall\t"})
        yield W(lambda: pw.property("percent") == 45 and pw.property("label") == "Firewall", "progress set: percent and label")
        send({"progress": "set", "line": "-\t1\tMalware scan\tThis can take several minutes."})
        yield W(lambda: pw.property("percent") == -1 and pw.property("slow") is True
                and pw.property("detail") == "This can take several minutes.", "progress set: a long step without a percentage")
        shot("shell-progress", pw)
        send({"progress": "set", "line": "100\t0\tDone\t"})
        send({"progress": "stop"})
        yield W(lambda: pw.property("percent") == 100, "progress stop: the last line is shown")
        yield P(0.3)
        check(pw.isVisible() and len(replies) == n_before, "progress stop: the window stays until the next page; nothing was answered")
        if (yield from show("s5", "check", S["check"], "page after the scan")):
            check(shell.isVisible() and not pw.isVisible(), "page after the scan: the main window is back, the progress window gone")
            key(Escape)
        yield from answered("s5", "page after the scan")
        expect("s5", 0, "page after the scan: Esc goes back", lambda a: a == {"action": "back"})
        # A second scan uses the same window; a busy label ends it.
        send({"progress": "start", "heading": "Checking again"})
        yield W(lambda: pw.isVisible() and not shell.isVisible(), "second scan: the progress window again")
        send({"busy": "Applying a fix…"})
        yield W(lambda: shell.isVisible() and not pw.isVisible() and prop("busyShown") is True
                and prop("busyLabel") == "Applying a fix…", "busy after a scan: the main window is back with the label")

    # 8. the theme
    from PySide6.QtGui import QPalette
    colours = {}
    if (yield from show("s6", "confirm", S["confirm"], "theme")):
        for theme in ("light", "dark", "system"):
            send({"theme": theme})
            path = appmod._scheme_path(theme) or ""
            yield W(lambda: (app.property("KDE_COLOR_SCHEME_PATH") or "") == path, "theme %s: colour scheme %r" % (theme, path or "the system's"))
            yield P(0.2)
            colours[theme] = app.palette().color(QPalette.ColorRole.Window).name()
            shot("shell-theme-" + theme)
        if appmod._scheme_path("light") and appmod._scheme_path("dark"):
            check(colours["light"] != colours["dark"], "theme: light %s and dark %s differ" % (colours["light"], colours["dark"]))
        else:
            say("     note: no Breeze colour schemes installed here: only the message itself was tested")
        send({"theme": "no-such-theme"})
        send({"theme": 7})
        yield P(0.3)
        key(Return)
    yield from answered("s6", "theme")
    expect("s6", 0, "theme: the page still answers after the switches", lambda a: a == {"choice": "apply"})

    # 9. the window's close button
    if (yield from show("s7", "settings", S["settings"], "close button")):
        shell.close()
    yield from answered("s7", "close button")
    expect("s7", 1, "close button: the request is answered \"cancelled\"")
    yield P(0.3)
    check(shell.isVisible(), "close button: the window itself stays (the tool decides what comes next)")
    yield W(lambda: prop("busyShown") is True, "close button: then busy")
    n = len(replies)
    shell.close()
    yield P(0.3)
    check(not shell.isVisible() and len(replies) == n, "close button with nothing to answer: the window hides, no answer line")
    if (yield from show("s8", "confirm", S["confirm"], "page after the window was closed")):
        key(Return)
    yield from answered("s8", "page after the window was closed")
    expect("s8", 0, "page after the window was closed: shown and answered", lambda a: a == {"choice": "apply"})
    no_warnings("the whole scenario")
    send({"quit": True})


def sc_guard():
    """Enter and Esc that arrive as a page appears (typed for the page
    before) or from a held-down key must not answer the new page."""
    Return, Escape = K().Key_Return, K().Key_Escape
    data = SAMPLES["confirm"]
    missing = " (the key guard in ui/qml/Shell.qml is missing or does not cover this)"
    # A page that is answered normally first, so that the window is up.
    if (yield from show("g0", "confirm", data, "first page")):
        key(Escape)
    yield from answered("g0", "first page")
    for rid, k, name in (("g1", Return, "Enter"), ("g2", Escape, "Esc")):
        ask(rid, "confirm", data)
        yield W(lambda: prop("pendingId") == rid, "%s at once: page shown" % name)
        key(k)
        yield P(0.2)
        check(not got(rid), "%s pressed the moment a page appears does not answer it%s" % (name, missing if got(rid) else ""))
        yield from settled(name)
        if not got(rid):
            key(k)
            yield from answered(rid, "%s after the pause" % name)
            expect(rid, 0 if k == Return else 1, "%s pressed after the pause answers" % name)
    for rid, k, name in (("g3", Return, "Enter"), ("g4", Escape, "Esc")):
        if not (yield from show(rid, "confirm", data, "auto-repeat %s" % name)):
            continue
        for _ in range(5):
            key(k, repeat=True)
        yield P(0.3)
        check(not got(rid), "auto-repeat %s (a held-down key) does not answer a page%s" % (name, missing if got(rid) else ""))
        if not got(rid):
            key(k)
            yield from answered(rid, "%s pressed once" % name)
            expect(rid, 0 if k == Return else 1, "%s pressed once answers" % name)
    no_warnings("the whole scenario")
    send({"quit": True})


def sc_keys():
    """Which control gets Enter (stub page with a text field, a text area,
    a combo box and a second button)."""
    Return, Escape, A = K().Key_Return, K().Key_Escape, K().Key_A
    if (yield from show("k1", "wizard", {"n": 1}, "stub page")):
        check(shell.title() == "Stub page 1", "the window title follows the page: %r" % shell.title())
        focus("field")
        yield P(0.05)
        key(A, text="a")
        key(Return, text="\r")
        yield P(0.4)
        check(not got("k1"), "Enter in a one-line text field does not answer the page")
        focus("area")
        yield P(0.05)
        key(Return, text="\r")
        yield P(0.4)
        check(not got("k1"), "Enter in a text area does not answer the page")
        focus("other")
        yield P(0.05)
        key(Return, text="\r")
    yield from answered("k1", "Enter on a button")
    expect("k1", 0, "Enter on a focused button presses that button", lambda a: a == {"via": "button"})

    if (yield from show("k2", "wizard", {"n": 2}, "stub page 2")):
        focus("combo")
        yield P(0.05)
        key(Return, text="\r")
    yield from answered("k2", "Enter on a closed combo box")
    expect("k2", 0, "Enter on a closed combo box is the page's primary()", lambda a: a.get("via") == "primary")

    if (yield from show("k3", "wizard", {"n": 3}, "stub page 3")):
        focus("field")
        yield P(0.05)
        key(A, text="a")
        key(Escape)
    yield from answered("k3", "Esc in a text field")
    expect("k3", 1, "Esc in a text field is the page's dismiss()")
    no_warnings("the whole scenario")
    send({"quit": True})


BAD_LINES = [
    # what, the line, the id its answer must carry ("" or that id)
    ("not JSON", "this is not json", [""]),
    ("JSON cut short", '{"id":"m0","mode":"confirm","data":{', [""]),
    ("bytes that are not UTF-8", b'\xff\xfe{"id":\x80}', [""]),
    ("not an object: a list", "[1, 2]", [""]),
    ("not an object: a string", '"quit"', [""]),
    ("not an object: a number", "42", [""]),
    ("not an object: null", "null", [""]),
    ("an object with no known key", {"hello": 1}, [""]),
    ("an empty object", {}, [""]),
    ("a request without an id", {"mode": "confirm", "data": {}}, [""]),
    ("an id that is not a string", {"id": 7, "mode": "confirm", "data": {}}, [""]),
    ("an empty id", {"id": "", "mode": "confirm", "data": {}}, [""]),
    ("an id with a space and a quote", {"id": 'bad "id', "mode": "confirm", "data": {}}, [""]),
    ("an id of 65 characters", {"id": "a" * 65, "mode": "confirm", "data": {}}, [""]),
    ("an unknown mode", {"id": "m1", "mode": "nosuch", "data": {}}, ["m1"]),
    ("the mode \"serve\"", {"id": "m2", "mode": "serve", "data": {}}, ["m2"]),
    ("a mode that is a number", {"id": "m3", "mode": 5, "data": {}}, ["m3", ""]),
    ("a mode that is a list", {"id": "m4", "mode": ["dialog"], "data": {}}, ["m4", ""]),
    ("a mode that is an object", {"id": "m5", "mode": {"dialog": 1}, "data": {}}, ["m5", ""]),
    ("a mode that is null", {"id": "m6", "mode": None, "data": {}}, ["m6", ""]),
    ("input that is a list", {"id": "m7", "mode": "confirm", "data": [1]}, ["m7"]),
    ("no input", {"id": "m8", "mode": "confirm"}, ["m8"]),
]


def sc_malformed():
    """Lines that are not requests: each gets exactly one answer line with
    status 3 (the root side then stops using the front end), never silence."""
    Return = K().Key_Return
    # What the front end itself logs about a bad line is not a QML warning.
    allowed.append(re.compile(r"^(?!.*(qml|QML|Binding loop)).*$"))
    for n, (what, line, ids) in enumerate(BAD_LINES):
        before = len(replies) if n else 0       # the first one was sent before the front end started
        if n:
            send(line)
        ok = yield W(lambda: (pump(), len(replies) > before)[1], "%s: answered (silence makes the root side wait for ever)" % what, 3.0)
        if not ok:
            continue
        yield P(0.05)
        pump()
        p = parsed(replies[before])
        check(p is not None and p[0] in ids and p[1] == 3 and p[2] is None and len(replies) == before + 1,
              "%s: one answer line, status 3: %s" % (what, cut(" | ".join(replies[before:]))))
    check(not shell.isVisible(), "no window was opened for any of them")
    # The front end is still usable.
    if (yield from show("m9", "confirm", SAMPLES["confirm"], "a page after the bad lines")):
        key(Return)
    yield from answered("m9", "a page after the bad lines")
    expect("m9", 0, "a page after the bad lines is shown and answered", lambda a: a == {"choice": "apply"})
    no_warnings("the whole scenario")
    send({"quit": True})


def sc_broken():
    """Page files that do not load, or are not pages: status 3, and the
    window goes on."""
    Return = K().Key_Return
    allowed.extend(re.compile(p) for p in (
        r"Security Check: ", r"Check\.qml", r"Confirm\.qml", r"Choose\.qml", r"Dialog\.qml",
        r"NoSuchComponent", r"^\s+\^|^\s+this is not QML|^\s+NoSuch"))
    for rid, mode, what in (("b1", "check", "a page file with a syntax error"),
                            ("b2", "confirm", "a page that uses a component that does not exist"),
                            ("b3", "choose", "a file that is not an Item"),
                            ("b4", "dialog", "an Item without finished() and cancelled()")):
        ask(rid, mode, {"title": "t"})
        yield from answered(rid, what, 5.0)
        expect(rid, 3, what + ": status 3")
    check(prop("pendingId") == "", "nothing is left waiting for an answer")
    w = new_warnings()
    check(not w, "only the expected warnings%s" % ("" if not w else ": " + cut(" | ".join(w[:2]), 300)))
    if (yield from show("b5", "wizard", {"n": 5}, "a good page after the broken ones")):
        key(Return)
    yield from answered("b5", "a good page after the broken ones")
    expect("b5", 0, "a good page after the broken ones is shown and answered", lambda a: a.get("via") == "primary")
    send({"quit": True})


def sc_eof():
    """The root side goes away (its end of the pipe closes) while a page waits."""
    global req_w
    yield W(lambda: prop("pendingId") == "x1" and shell.isVisible(), "page shown")
    yield P(0.3)
    os.close(req_w)
    req_w = -1


def sc_quit():
    """{"quit":true} while a page waits."""
    yield W(lambda: prop("pendingId") == "x1" and shell.isVisible(), "page shown")
    yield P(0.3)
    send({"quit": True})


def sc_oneshot(how):
    def script():
        Return, Escape = K().Key_Return, K().Key_Escape
        yield W(lambda: shell.isVisible() and prop("pendingId") != "", "the dialog is shown")
        yield from settled("app.py dialog")
        check(prop("compact") is True, "app.py dialog: a small window (%dx%d)" % (shell.width(), shell.height()))
        shot("oneshot-dialog")
        no_warnings("app.py dialog")
        if how == "enter":
            key(Return)
        elif how == "esc":
            key(Escape)
        else:
            shell.close()
    return script


def sc_progress_only():
    """"app.py progress": the progress window alone (no main window)."""
    yield W(lambda: progress_window() is not None and progress_window().isVisible(), "app.py progress: the window shows")
    pw = progress_window()
    if pw is not None:
        check(shell is None and pw.property("heading") == "Checking your PC", "app.py progress: heading %r, no main window" % pw.property("heading"))
        send("45\t0\tFirewall\t")
        yield W(lambda: pw.property("percent") == 45 and pw.property("label") == "Firewall", "app.py progress: a progress line is shown")
        shot("progress-only", pw)
        pw.close()
        yield P(0.2)
        check(not pw.isVisible() or pw.visibility() == pw.Visibility.Minimized, "app.py progress: the close button only hides or minimises it")
        no_warnings("app.py progress")
    send("QUIT")


def after_serve(rc):
    check(rc == 0, "app.py serve ended with status %r (0 expected)" % (rc,))


def after_end(what, pending_status):
    def f(rc):
        check(rc == 0, "%s: app.py serve ended with status %r (0 expected)" % (what, rc))
        line, p = reply_for("x1")
        check(line is None or (p[1] == pending_status and p[2] is None),
              "%s: the waiting request got no answer line, or \"cancelled\": %s" % (what, cut(line)))
        no_warnings(what)
    return f


def after_oneshot(status, answer):
    def f(rc):
        check(rc == status, "app.py dialog ended with status %r (%d expected)" % (rc, status))
        got_answer = None
        try:
            got_answer = [json.loads(r) for r in replies]
        except ValueError:
            pass
        check(got_answer == ([answer] if status == 0 else []), "app.py dialog printed %s" % cut(replies))
    return f


def request(rid, mode, sample):
    return lambda: {"id": rid, "mode": mode, "data": SAMPLES[sample]}


# name: (argv, the first line (sent before main() starts; None: none, stdin
#        closed), stub pages or None, script, what to check when main() is back)
SCENARIOS = {
    "pages": (["serve"], lambda: {"busy": ""}, None, sc_pages, after_serve),
    "shell": (["serve"], request("d1", "dialog", "dialog"), None, sc_shell, after_serve),
    "guard": (["serve"], lambda: {"busy": ""}, None, sc_guard, after_serve),
    "keys": (["serve"], lambda: {"busy": ""}, STUBS_KEYS, sc_keys, after_serve),
    "malformed": (["serve"], lambda: BAD_LINES[0][1], None, sc_malformed, after_serve),
    "broken-page": (["serve"], lambda: {"busy": ""}, STUBS_BROKEN, sc_broken, after_serve),
    "eof": (["serve"], request("x1", "confirm", "confirm"), None, sc_eof, after_end("end of input while a page waits", 1)),
    "eof-idle": (["serve"], None, None, None, lambda rc: check(rc == 0 and not replies, "end of input before any request: status %r, nothing printed" % (rc,))),
    "quit": (["serve"], request("x1", "confirm", "confirm"), None, sc_quit, after_end("quit while a page waits", 1)),
    "quit-first": (["serve"], lambda: {"quit": True}, None, None, lambda rc: check(rc == 0 and not replies, "quit as the first line: status %r, nothing printed" % (rc,))),
    "progress-only": (["progress"], lambda: {"heading": "Checking your PC"}, None, sc_progress_only,
                      lambda rc: check(rc == 0 and not replies, "app.py progress ended with status %r, nothing printed" % (rc,))),
    "oneshot": (["dialog"], lambda: SAMPLES["dialog"], None, sc_oneshot("enter"), after_oneshot(0, {"button": 1})),
    "oneshot-esc": (["dialog"], lambda: SAMPLES["dialog"], None, sc_oneshot("esc"), after_oneshot(1, None)),
    "oneshot-close": (["dialog"], lambda: SAMPLES["dialog"], None, sc_oneshot("close"), after_oneshot(1, None)),
    "oneshot-bad": (["dialog"], lambda: "this is not json", None, None,
                    lambda rc: check(rc == 2 and not replies, "app.py dialog with input that is not JSON: status %r (2 expected), nothing printed" % (rc,))),
}


def run_scenario(name):
    global NAME, SHOTS, out_fd, req_w, rep_r, err_file, app, shell, host, appmod, SAMPLES
    NAME = name
    SHOTS = os.environ.get("BSA_UI_TEST_SHOTS", "")
    argv, first, stubs, script, after = SCENARIOS[name]
    with open(SAMPLES_FILE, encoding="utf-8") as f:
        SAMPLES = json.load(f)

    import importlib.util
    import PySide6.QtQuick  # noqa: F401  (so that the window comes back as a QQuickWindow)
    sys.dont_write_bytecode = True      # no ui/__pycache__ in the source tree
    spec = importlib.util.spec_from_file_location("bsa_ui_app", APP)
    appmod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(appmod)
    stub_dir = None
    if stubs:
        stub_dir = tempfile.mkdtemp(prefix="bsa-ui-stubs-")
        for fname, text in stubs.items():
            with open(os.path.join(stub_dir, fname), "w", encoding="utf-8") as f:
                f.write(text)
        appmod.PAGE_DIR = stub_dir

    # The front end's stdin and stdout become pipes whose other ends are
    # held here; its stderr goes to a file that is read for warnings.
    r, req_w = os.pipe()
    rep_r, w = os.pipe()
    out_fd = os.dup(1)
    err_file = tempfile.TemporaryFile()
    os.dup2(r, 0)
    os.dup2(w, 1)
    os.dup2(err_file.fileno(), 2)
    os.close(r)
    os.close(w)
    os.set_blocking(rep_r, False)

    def hook(a, s, h):
        global app, shell, host
        from PySide6.QtCore import QTimer
        from PySide6.QtQml import qmlEngine
        app, shell, host = a, s, h
        engine = qmlEngine(s) if s is not None else None
        if engine is not None:
            engine.warnings.connect(lambda ws: engine_warnings.extend(x.toString() for x in ws))
        gen = script() if script else iter(())
        state = {"cur": None, "until": 0.0, "done": False, "start": time.monotonic()}

        def give_up(why):
            check(False, why)
            timer.stop()
            a.quit()

        def step():
            pump()
            now = time.monotonic()
            if now - state["start"] > SCENARIO_LIMIT:
                return give_up("the scenario did not end within %d s" % SCENARIO_LIMIT)
            if state["done"]:
                if now > state["until"]:
                    give_up("the front end did not end within 10 s of the last step")
                return
            cur, result = state["cur"], None
            if cur is not None:
                if cur[0] == "pause":
                    if now < state["until"]:
                        return
                else:
                    try:
                        result = bool(cur[1]())
                    except Exception as e:
                        result = False
                        say("     error while waiting for %s: %r" % (cur[3], e))
                    if not result and now < state["until"]:
                        return
                    if not result:
                        check(False, "%s: not within %g s" % (cur[3], cur[2]))
            try:
                state["cur"] = gen.send(result) if cur is not None else next(gen)
                state["until"] = time.monotonic() + state["cur"][2]
            except StopIteration:
                state["done"], state["until"] = True, time.monotonic() + 10
            except Exception:
                import traceback
                say(traceback.format_exc().rstrip())
                give_up("error in the test script itself")

        timer = QTimer()
        timer.timeout.connect(step)
        timer.start(10)
        hook.keep = (timer, engine)

    appmod.TEST_HOOK = hook
    if first is None:
        os.close(req_w)
        req_w = -1
    else:
        send(first())
    sys.argv = ["app.py"] + argv
    rc = "an exception"
    try:
        rc = appmod.main()
    except BaseException:
        import traceback
        say(traceback.format_exc().rstrip())
    time.sleep(0.05)
    pump()
    for line in replies:
        if argv == ["serve"] and not ANSWER_RE.match(line):
            check(False, "an answer line in a form the root side cannot read: %s" % cut(line))
    after(rc)
    left = new_warnings()
    if left:
        check(False, "warnings at the end: %s" % cut(" | ".join(left[:3]), 400))
    if stub_dir:
        shutil.rmtree(stub_dir, ignore_errors=True)
    say("done [%s] %d checks, %d failed" % (name, checks, fails))
    # Not through Python's and Qt's shutdown: nothing there is under test.
    os._exit(1 if fails else 0)


# ---- the parent: every scenario, one process each ------------------------------
def main():
    args = sys.argv[1:]
    if args[:1] == ["--scenario"] and len(args) == 2 and args[1] in SCENARIOS:
        return run_scenario(args[1])
    shots, verbose, names = "", False, []
    while args:
        a = args.pop(0)
        if a == "--shots" and args:
            shots = os.path.abspath(args.pop(0))
        elif a == "--verbose":
            verbose = True
        elif a in SCENARIOS:
            names.append(a)
        else:
            print("usage: ui-offscreen.py [--shots DIR] [--verbose] [%s]..." % "|".join(SCENARIOS), file=sys.stderr)
            return 2
    try:
        import PySide6.QtQuick  # noqa: F401
        import PySide6.QtWidgets  # noqa: F401
    except ImportError as e:
        print("FAIL PySide6 with Qt Quick is needed for this test: %s" % e)
        return 1
    if shots:
        os.makedirs(shots, exist_ok=True)
    home = tempfile.mkdtemp(prefix="bsa-ui-test-")
    env = dict(os.environ)
    env.update({
        "QT_QPA_PLATFORM": "offscreen",
        "QT_FORCE_STDERR_LOGGING": "1",
        # Qt's messages as they are, whatever the person has set.
        "QT_MESSAGE_PATTERN": "%{if-category}%{category}: %{endif}%{message}",
        "QML_DISABLE_DISK_CACHE": "1",
        # Nothing of the person's own settings, and nothing written to them.
        "XDG_CONFIG_HOME": os.path.join(home, "config"),
        "XDG_CACHE_HOME": os.path.join(home, "cache"),
        "BSA_UI_TEST_SHOTS": shots,
        "BSA_UI_TEST_VERBOSE": "1" if verbose else "",
    })
    for var in ("BSA_THEME", "QT_QUICK_CONTROLS_STYLE", "QT_LOGGING_RULES", "QML_IMPORT_TRACE", "QT_DEBUG_PLUGINS"):
        env.pop(var, None)
    total = failed = 0
    bad = []
    started = time.monotonic()
    try:
        for name in names or list(SCENARIOS):
            cmd = [sys.executable, "-I", os.path.realpath(__file__), "--scenario", name]
            try:
                p = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   timeout=KILL_AFTER)
                out, rc = p.stdout.decode("utf-8", "replace"), p.returncode
            except subprocess.TimeoutExpired as e:
                out, rc = (e.stdout or b"").decode("utf-8", "replace"), None
            lines = out.splitlines()
            n_ok = len([x for x in lines if x.startswith("ok  ")])
            n_fail = len([x for x in lines if x.startswith("FAIL")])
            ended = any(x.startswith("done [") for x in lines)
            for x in lines:
                if not x.startswith("done ["):
                    print(x)
            if rc is None:
                print("FAIL [%s] no result within %d s: killed (a hang)" % (name, KILL_AFTER))
                n_fail += 1
            elif not ended:
                print("FAIL [%s] the test process ended early with status %s (a crash)" % (name, rc))
                n_fail += 1
            elif (rc != 0) != (n_fail > 0):
                print("FAIL [%s] exit status %s does not fit %d failed checks" % (name, rc, n_fail))
                n_fail += 1
            total += n_ok + n_fail
            failed += n_fail
            if n_fail:
                bad.append(name)
            sys.stdout.flush()
    finally:
        shutil.rmtree(home, ignore_errors=True)
    print("%s: %d checks in %d scenarios, %d failed%s (%.0f s)" % (
        "FAILED" if failed else "ALL OK", total, len(names or SCENARIOS), failed,
        " (in: %s)" % ", ".join(bad) if bad else "", time.monotonic() - started))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
