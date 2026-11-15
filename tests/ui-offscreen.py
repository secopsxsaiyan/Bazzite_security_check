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
# request lines, presses keys and clicks in the window and reads the answer
# lines. It
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

SETTLE = 0.65           # the window takes no keys and no clicks for ~350 ms after a page appears
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


def FOCUS_BY_TAB():
    from PySide6.QtCore import Qt
    return Qt.FocusReason.TabFocusReason


def key_event(press, k, text="", repeat=False):
    """One key event: a press or a release; REPEAT marks it as the
    keyboard's auto-repeat of a key that is held down."""
    from PySide6.QtCore import QCoreApplication, QEvent, Qt
    from PySide6.QtGui import QKeyEvent
    kind = QEvent.Type.KeyPress if press else QEvent.Type.KeyRelease
    QCoreApplication.sendEvent(shell, QKeyEvent(kind, k, Qt.KeyboardModifier.NoModifier, text, repeat))


def hold(k, text, seconds, until=None):
    """Keep a key held down for SECONDS, or until UNTIL() is true: the
    keyboard repeats it (a release and a press, both marked as repeats)."""
    end = time.monotonic() + seconds
    while time.monotonic() < end and not (until and until()):
        key_event(False, k, text, True)
        key_event(True, k, text, True)
        yield P(0.03)


def page_root():
    """The page that takes the input now: the dialog over a page, else the page."""
    return prop("dialogItem") or prop("pageItem")


def items_under(root):
    out, todo = [], [root] if root is not None else []
    while todo:
        item = todo.pop()
        out.append(item)
        todo.extend(reversed(item.childItems()))
    return out


def plain(value):
    """A value of a QML property as Python data."""
    return value.toVariant() if hasattr(value, "toVariant") else value


def is_main(item):
    """ITEM is a page's main button (PrimaryButton.qml)."""
    return item is not None and item.metaObject().className().startswith("PrimaryButton")


def controls(kind="QQuickAbstractButton", root=None):
    """The controls of the page that can be used now, in the order they are drawn."""
    return [i for i in items_under(root or page_root()) if i.inherits(kind) and i.isVisible() and i.isEnabled()]


def control(what, test, kind="QQuickAbstractButton"):
    """The first usable control that TEST accepts; a failed check when there is none."""
    for item in controls(kind):
        try:
            if test(item):
                return item
        except Exception:
            pass
    check(False, "%s: there is such a control on the page" % what)
    return None


def button(text):
    """The button whose label starts with TEXT."""
    return control("the button \"%s\"" % text, lambda i: (i.property("text") or "").startswith(text))


def main_button():
    return control("the main button", is_main)


def row(field, value):
    """The row (card, list entry) that shows the input's item whose FIELD is VALUE."""
    def test(i):
        data = plain(i.property("modelData"))
        return (data[field] if isinstance(field, int) else data.get(field)) == value
    return control("the row for %r" % (value,), test)


def scene_point(item):
    """The middle of ITEM in the window, None when it is not on screen
    there (outside the window, or scrolled out of a list)."""
    from PySide6.QtCore import QPointF, QRectF
    c = item.mapToScene(QPointF(item.width() / 2, item.height() / 2))
    if not (0 <= c.x() < shell.width() and 0 <= c.y() < shell.height()):
        return None
    up = item.parentItem()
    while up is not None:
        if up.clip() and not up.mapRectToScene(QRectF(0, 0, up.width(), up.height())).contains(c):
            return None
        up = up.parentItem()
    return c


def mouse_at(point, press=True, release=True):
    """The left mouse button, pressed and/or let go at POINT of the window."""
    from PySide6.QtCore import QCoreApplication, QEvent, QPointF, Qt
    from PySide6.QtGui import QMouseEvent
    where = QPointF(shell.mapToGlobal(point.toPoint()))
    left, none = Qt.MouseButton.LeftButton, Qt.MouseButton.NoButton
    if press:
        QCoreApplication.sendEvent(shell, QMouseEvent(QEvent.Type.MouseButtonPress, point, where, left, left,
                                                      Qt.KeyboardModifier.NoModifier))
    if release:
        QCoreApplication.sendEvent(shell, QMouseEvent(QEvent.Type.MouseButtonRelease, point, where, left, none,
                                                      Qt.KeyboardModifier.NoModifier))


def click(item, what="a control"):
    """A mouse click in the middle of ITEM. An item in a list is scrolled
    into view first, as the Tab key does it."""
    from PySide6.QtCore import Qt
    if item is None:
        return False
    if scene_point(item) is None:
        item.forceActiveFocus(Qt.FocusReason.TabFocusReason)
    point = scene_point(item)
    if point is None:
        return check(False, "%s can be clicked: it is on screen" % what)
    mouse_at(point)
    return True


def space(item):
    """The keyboard: the focus on ITEM, as Tab puts it there, then Space."""
    from PySide6.QtCore import Qt
    if item is None:
        return False
    item.forceActiveFocus(Qt.FocusReason.TabFocusReason)
    key(Qt.Key.Key_Space, text=" ")
    return True


def stderr_text():
    """Everything the front end has written to stderr so far (the file
    itself: not what the QML engine reported to this test)."""
    err_file.seek(0)
    return err_file.read().decode("utf-8", "replace")


def at_once(rid, mode, data, act, what):
    """Ask for a page and call ACT() the moment it appears, inside the
    Shell's settle pause. ACT is only called while the Shell says it is
    still settling: when this machine stalled for longer than the pause,
    the page is asked for again (a few times). Returns the id of the
    request ACT was called for, None (a failed check) if that never
    worked out."""
    for attempt in range(5):
        cur = "%s-%d" % (rid, attempt)
        ask(cur, mode, data)
        ok = yield W(lambda: got(cur) or prop("pendingId") == cur, "%s: page shown" % what)
        if ok and not got(cur) and prop("settling") is True and act() is not False:
            return cur
        say("     note: %s: the settle pause was over before the test could act (try %d)" % (what, attempt + 1))
        yield from settled(what)
    check(False, "%s: the test could act within the settle pause in one of 5 tries" % what)
    return None


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


def sc_controls():
    """Every control that produces an answer, other than Enter and Esc on
    the page as it comes up: clicked with the mouse or, with the keyboard
    focus on it, pressed with Space. The answers are what the root side
    accepts (_wizard_answer, _dashboard_answer, _check_answer,
    _confirm_answer, lib/settings.sh, the dialog and choose callers in
    lib/ui.sh)."""
    Return, Down = K().Key_Return, K().Key_Down
    S = SAMPLES
    wiz = S["wizard"]["answers"]
    fixable = [f["id"] for f in S["check"]["findings"] if f.get("fixable")]
    first_check = S["dashboard"]["checks"][0]["id"]
    state = {}

    def card(title):
        return control("the card \"%s\"" % title, lambda i: i.property("title") == title)

    # ---- the steps of each case: a generator that uses the page
    def wizard_settings(rid):
        click(button("Settings"), "Settings")
        yield P(0)

    def wizard_changed(rid):
        key(Return)                         # to "Your PC"
        yield P(0.15)
        page = prop("pageItem")
        off = control("a use that is not ticked", lambda i: i.property("switchedOn") is False and plain(i.property("modelData"))[0] not in wiz["use"])
        if off is None:
            return
        state["use"] = plain(off.property("modelData"))[0]
        space(off)                          # Space ticks the card that has the focus
        yield P(0.1)
        check(off.property("switchedOn") is True and off.property("checked") is True, "wizard: Space on a card ticks it")
        key(Return, text="\r")              # Enter on a card is the page's main action, not a tick
        yield P(0.15)
        check(page.property("step") == 2 and off.property("switchedOn") is True, "wizard: Enter on a card goes on, and leaves the tick alone")
        click(card("Offer fixes"), "Offer fixes")
        yield P(0.1)
        deep = card("Deep check")
        space(deep)
        yield P(0.1)
        check(deep is not None and deep.property("switchedOn") is True, "wizard: Space on \"Deep check\" ticks it")
        key(Return, text="\r")
        yield P(0.15)
        check(page.property("step") == 3, "wizard: Enter on a card of the Options step goes on to Review")
        key(Return, text="\r")

    def settings_changed(rid):
        combo = control("the theme box", lambda i: True, "QQuickComboBox")
        if combo is None:
            return
        combo.forceActiveFocus(FOCUS_BY_TAB())
        key(Down)                           # the next entry: Light
        yield P(0.1)
        click(button("Check for updates when"), "the tick box")
        yield P(0.1)
        key(Return, text="\r")              # Enter on a tick box is the page's main action

    def settings_update(rid):
        page = prop("pageItem")
        page.setProperty("latest", "99.0.0")        # as if "Check now" had found a newer release
        page.setProperty("checkState", "done")
        yield P(0.1)
        click(button("Install update"), "Install update")

    def press_with(text, how):
        def steps(rid):
            (click if how == "mouse" else space)(button(text))
            yield P(0)
        return steps

    def open_check(rid):
        click(row("id", first_check), "the row of a check")
        yield P(0)

    def check_all(rid):
        click(button("Select all"), "Select all")
        yield P(0.1)
        click(main_button(), "the main button")

    def check_one(rid):
        boxes = [b for b in controls("QQuickCheckBox") if not b.property("text")]
        off = [b for b in boxes if not b.property("checked")]
        if not check(len(boxes) == len(fixable) and off, "check: a tick box for each finding that can be fixed (%d)" % len(boxes)):
            return
        space(off[0])
        yield P(0.1)
        key(Return, text="\r")

    def choose_keys(rid):
        r = row("tag", "c")
        space(r)
        yield P(0.1)
        check(r is not None and r.property("checked") is True, "choose: Space on a row ticks it")
        key(Return, text="\r")              # Enter on a row continues, and does not untick it

    def choose_mouse(rid):
        click(row("tag", "a"), "a row")
        yield P(0.1)
        click(main_button(), "the main button")

    def choose_button(text):
        def steps(rid):
            click(button(text), text)
            yield P(0.1)
            click(main_button(), "the main button")
        return steps

    def list_other(rid):
        rows = controls("QQuickRadioDelegate")
        other = [r for r in rows if not r.property("checked")]
        if not check(len(rows) == len(S["dialog-list"]["items"]) and other, "dialog, list: a row for each item"):
            return
        state["tag"] = plain(other[-1].property("modelData"))["tag"]
        click(other[-1], "a row of the list")
        yield P(0.1)
        click(main_button(), "the main button")

    def list_down_cancel(rid):
        state["tag"] = None
        before = [plain(r.property("modelData"))["tag"] for r in controls("QQuickRadioDelegate") if r.property("checked")]
        key(Down)                           # the arrow keys pick the next row
        yield P(0.1)
        now = [plain(r.property("modelData"))["tag"] for r in controls("QQuickRadioDelegate") if r.property("checked")]
        if check(len(now) == 1 and now != before, "dialog, list: Down picks the next row (%s, then %s)" % (before, now)):
            state["tag"] = now[0]
        space(button("Cancel"))             # the other button: answered, not cancelled

    wizard_keys = {"use", "fix", "deep", "report_dir", "action"}
    cases = [
        # name, mode, input, steps, status, what the answer must be
        ("wizard: the Settings button", "wizard", S["wizard"], wizard_settings, 0,
         lambda a: set(a) == wizard_keys and a["action"] == "settings" and a["use"] == wiz["use"] and a["fix"] is True and a["deep"] is False),
        ("wizard: other choices on every step", "wizard", S["wizard"], wizard_changed, 0,
         lambda a: set(a) == wizard_keys and a["action"] == "start" and sorted(a["use"]) == sorted(wiz["use"] + [state["use"]])
         and a["fix"] is False and a["deep"] is True and a["report_dir"] == wiz["report_dir"]),
        ("wizard: Quit", "wizard", S["wizard"], press_with("Quit", "mouse"), 1, None),
        ("settings: another theme and the tick box", "settings", S["settings"], settings_changed, 0,
         lambda a: a == {"action": "save", "theme": "light", "update_check": False}),
        ("settings: Install update", "settings", S["settings"], settings_update, 0,
         lambda a: a == {"action": "update", "theme": "system", "update_check": True}),
        ("settings: Cancel", "settings", S["settings"], press_with("Cancel", "space"), 1, None),
        ("dashboard: Open the full report", "dashboard", S["dashboard"], press_with("Open the full report", "mouse"), 0, lambda a: a == {"action": "report"}),
        ("dashboard: Undo changes", "dashboard", S["dashboard"], press_with("Undo changes", "space"), 0, lambda a: a == {"action": "undo"}),
        ("dashboard: Kept on purpose", "dashboard", S["dashboard"], press_with("Kept on purpose", "mouse"), 0, lambda a: a == {"action": "keep"}),
        ("dashboard: Settings", "dashboard", S["dashboard"], press_with("Settings", "space"), 0, lambda a: a == {"action": "settings"}),
        ("dashboard: Finish", "dashboard", S["dashboard"], press_with("Finish", "mouse"), 0, lambda a: a == {"action": "finish"}),
        ("dashboard: a check is opened", "dashboard", S["dashboard"], open_check, 0, lambda a: a == {"action": "check", "check": first_check}),
        ("check: Back", "check", S["check"], press_with("Back", "mouse"), 0, lambda a: a == {"action": "back"}),
        ("check: Select all, then fix", "check", S["check"], check_all, 0, lambda a: a == {"action": "fix", "ids": fixable}),
        ("check: one more ticked, then fix", "check", S["check"], check_one, 0,
         lambda a: set(a) == {"action", "ids"} and a["action"] == "fix" and len(a["ids"]) == 2 and "13" in a["ids"] and set(a["ids"]) <= set(fixable)),
        ("choose: Space on a row, Enter", "choose", S["choose"], choose_keys, 0, lambda a: a == {"tags": ["a", "b", "c"]}),
        ("choose: a row clicked", "choose", S["choose"], choose_mouse, 0, lambda a: a == {"tags": ["b"]}),
        ("choose: Select all", "choose", S["choose"], choose_button("Select all"), 0, lambda a: a == {"tags": ["a", "b", "c", "d"]}),
        ("choose: Select none", "choose", S["choose"], choose_button("Select none"), 0, lambda a: a == {"tags": []}),
        ("choose: Low risk only", "choose", S["choose"], choose_button("Low risk only"), 0, lambda a: a == {"tags": ["a"]}),
        ("choose: Cancel", "choose", S["choose"], press_with("Cancel", "mouse"), 1, None),
        ("confirm: Skip", "confirm", S["confirm"], press_with("Skip", "mouse"), 0, lambda a: a == {"choice": "skip"}),
        ("confirm: Stop reviewing", "confirm", S["confirm"], press_with("Stop reviewing", "space"), 0, lambda a: a == {"choice": "stop"}),
        ("confirm: Apply, clicked", "confirm", S["confirm"], press_with("Apply", "mouse"), 0, lambda a: a == {"choice": "apply"}),
        ("dialog, question: the other button", "dialog", S["dialog"], press_with("Cancel", "mouse"), 0, lambda a: a == {"button": 0}),
        ("dialog, list: another row, clicked", "dialog", S["dialog-list"], list_other, 0, lambda a: a == {"button": 1, "tag": state["tag"]}),
        ("dialog, list: Down, then the other button", "dialog", S["dialog-list"], list_down_cancel, 0,
         lambda a: state["tag"] is not None and a == {"button": 0, "tag": state["tag"]}),
    ]
    for n, (what, mode, data, steps, status, answer) in enumerate(cases):
        rid = "c%d" % n
        if (yield from show(rid, mode, data, what)):
            yield from steps(rid)
        yield from answered(rid, what)
        expect(rid, status, what, answer)
        no_warnings(what)
    send({"quit": True})


def sc_tab():
    """Tab reaches every button of the bar at the bottom of each page (in
    a dialog: each of its buttons)."""
    Tab = K().Key_Tab
    S = SAMPLES
    for n, (mode, sample) in enumerate((("wizard", "wizard"), ("settings", "settings"), ("dashboard", "dashboard"), ("check", "check"),
                                        ("choose", "choose"), ("confirm", "confirm"), ("dialog", "dialog"), ("dialog", "dialog-list"))):
        what = "%s (%s)" % (mode, sample)
        if not (yield from show("t%d" % n, mode, S[sample], what)):
            continue
        if mode == "dialog":
            labels = [b["label"] for b in S[sample]["buttons"]]
            want = [b for b in controls() if b.property("text") in labels and not b.property("checkable")]
            check(len(want) == len(labels), "%s: %d buttons for %d in the request" % (what, len(want), len(labels)))
        else:
            bars = [i for i in items_under(page_root()) if i.metaObject().className().startswith("FooterBar")]
            want = controls(root=bars[0]) if len(bars) == 1 else []
            check(len(want) >= 2, "%s: the bar at the bottom has %d buttons" % (what, len(want)))
        seen = []
        for i in range(400):
            if all(b in seen for b in want):
                break
            key(Tab)
            seen.append(shell.activeFocusItem())
            if i % 10 == 9:
                yield P(0)
        left = [b.property("text") for b in want if b not in seen]
        check(not left, "%s: Tab reaches %s%s" % (what, ", ".join(repr(b.property("text")) for b in want),
                                                 "" if not left else " - but not %s (in %d presses)" % (", ".join(map(repr, left)), len(seen))))
        no_warnings(what)
    send({"quit": True})


def sc_guard():
    """What arrives as a page appears was meant for the page before and
    must not answer the new one: a key or a click in the first moment, and
    a key or mouse button that is held down (or repeats) across the change
    of page - however long it is held."""
    Return, Escape, Space, Tab = K().Key_Return, K().Key_Escape, K().Key_Space, K().Key_Tab
    data, choose = SAMPLES["confirm"], SAMPLES["choose"]
    missing = " (the guard in ui/qml/Shell.qml is missing or does not cover this)"

    def no_answer(rid, what):
        return check(not got(rid), what + (missing if got(rid) else ""))

    # A page that is answered normally first, so that the window is up.
    if (yield from show("g0", "confirm", data, "first page")):
        # The page that asks "apply this?" does not start with the keyboard
        # focus on Apply: Space, which presses a focused button, does nothing.
        check(not is_main(shell.activeFocusItem()), "confirm: the keyboard focus does not start on Apply (it is on: %s)" % focus_text())
        key(Space, text=" ")
        yield P(0.3)
        no_answer("g0", "confirm: Space on the page as it comes up answers nothing")
        key(Escape)
    yield from answered("g0", "first page")

    # 1. A key or a click in the first moment.
    for base, k, name in (("g1", Return, "Enter"), ("g2", Escape, "Esc"), ("g3", Space, "Space")):
        rid = yield from at_once(base, "confirm", data, lambda: key(k, text={Return: "\r", Space: " "}.get(k, "")), name + " at once")
        if rid is None:
            continue
        yield P(0.2)
        no_answer(rid, "%s pressed the moment a page appears does not answer it" % name)
        yield from settled(name)
        if not got(rid):
            key(Return if k == Space else k)
            yield from answered(rid, "%s after the pause" % name)
            expect(rid, 1 if k == Escape else 0, "a key pressed after the pause answers")
    rid = yield from at_once("g4", "confirm", data, lambda: click(button("Skip"), "Skip"), "a click at once")
    if rid is not None:
        yield P(0.2)
        no_answer(rid, "a click in the moment a page appears is dropped")
        yield from settled("a click at once")
        if not got(rid):
            click(button("Skip"), "Skip")
            yield from answered(rid, "a click after the pause")
            expect(rid, 0, "a click after the pause answers", lambda a: a == {"choice": "skip"})

    # 2. Auto-repeat alone (the press itself was never seen here).
    for rid, k, name in (("g5", Return, "Enter"), ("g6", Escape, "Esc")):
        if not (yield from show(rid, "confirm", data, "auto-repeat %s" % name)):
            continue
        for _ in range(5):
            key(k, repeat=True)
        yield P(0.3)
        no_answer(rid, "auto-repeat %s (a held-down key) does not answer a page" % name)
        yield from settled("after auto-repeat " + name)
        if not got(rid):
            key(k)
            yield from answered(rid, "%s pressed once" % name)
            expect(rid, 0 if k == Return else 1, "%s pressed once answers" % name)

    # 3. A key held down on the page before, still down (and repeating)
    # when the next page appears and long after its settle pause: Choose,
    # then Confirm, as in a review of fixes.
    for k, name, text in ((Space, "Space", " "), (Return, "Enter", "\r"), (Escape, "Esc", "")):
        c, f = "gc-" + name, "gf-" + name
        if not (yield from show(c, "choose", choose, "held %s: the page before" % name)):
            continue
        key_event(True, k, text)
        yield from hold(k, text, 0.25)
        ask(f, "confirm", data)             # the next page comes while the key is down
        yield from hold(k, text, 6.0, lambda: got(f) or prop("pendingId") == f)
        if not check(prop("pendingId") == f or got(f), "held %s: the next page is shown" % name):
            continue
        yield from hold(k, text, 1.5)       # four times the settle pause
        no_answer(f, "%s held down since the page before does not answer the new page, however long" % name)
        key_event(False, k, text)
        yield P(0.2)
        no_answer(f, "letting go of %s does not answer it either" % name)
        yield from settled("after the held " + name)
        if got(f):
            continue
        # Pressed again on purpose, the key works.
        if k == Space:
            key(Space, text=" ")
            yield P(0.3)
            no_answer(f, "Space with the focus on no button answers nothing")
            for _ in range(12):
                if is_main(shell.activeFocusItem()):
                    break
                key(Tab)
                yield P(0.03)
            check(is_main(shell.activeFocusItem()), "Tab reaches Apply (the focus is on: %s)" % focus_text())
            key(Space, text=" ")
        else:
            key(k, text=text)
        yield from answered(f, "%s pressed again" % name)
        if k == Escape:
            expect(f, 1, "Esc let go and pressed again cancels")
        else:
            expect(f, 0, "%s let go and pressed again applies" % name, lambda a: a == {"choice": "apply"})

    # 4. The mouse button held down on the page before and let go on the new one.
    if (yield from show("gm0", "choose", choose, "held mouse button: the page before")):
        point = scene_point(main_button())
        if check(point is not None, "the main button of the page before is on screen"):
            mouse_at(point, release=False)
            yield P(0.1)
            ask("gm1", "confirm", data)
            ok = yield W(lambda: got("gm1") or prop("pendingId") == "gm1", "held mouse button: the next page is shown")
            yield P(1.5)                    # four times the settle pause
            mouse_at(point, press=False)
            yield P(0.3)
            no_answer("gm1", "a mouse button held since the page before, let go over the new page's button, does not answer it")
            yield from settled("after the held mouse button")
            if ok and not got("gm1"):
                click(main_button(), "Apply")
                yield from answered("gm1", "a click on purpose")
                expect("gm1", 0, "a click on purpose applies", lambda a: a == {"choice": "apply"})
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
    # Why a page did not load must reach the run log, which is this
    # process's stderr. Qt writes there by itself only on a terminal; this
    # scenario runs without QT_FORCE_STDERR_LOGGING in its environment, so
    # it is ui/app.py that has to ask for it.
    err = stderr_text()
    check(re.search(r"Check\.qml:\d+", err) is not None and "NoSuchComponent" in err,
          "the reason a page file did not load is written to stderr (%d bytes there)" % len(err))
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


def sc_exception():
    """An exception while a line is handled (here: a colour scheme that
    cannot be read): one answer line with status 3, never silence, and the
    front end goes on."""
    Return = K().Key_Return
    # The traceback the front end logs is not a QML warning.
    allowed.append(re.compile(r"^(?!.*(qml|QML|Binding loop)).*$"))
    if (yield from show("e0", "confirm", SAMPLES["confirm"], "a page first")):
        key(Return)
    yield from answered("e0", "a page first")
    scheme = appmod._scheme_path("light") or ""
    if not check(scheme.startswith(os.environ.get("BSA_UI_TEST_HOME", "\0")), "the colour scheme that cannot be read is the one found: %r" % scheme):
        return send({"quit": True})
    n = len(replies)
    send({"theme": "light"})
    yield W(lambda: (pump(), len(replies) > n)[1], "an exception while a line is handled: answered (silence makes the root side wait for ever)", 3.0)
    yield P(0.3)
    pump()
    check(replies[n:] == ['{"id":"","status":3,"answer":null}'], "an exception while a line is handled: exactly one line, status 3, no id: %s" % cut(" | ".join(replies[n:])))
    check("Traceback (most recent call last)" in stderr_text(), "the exception is written to stderr")
    # With a page request in the same line, the answer carries its id.
    send({"theme": "light", "id": "e1", "mode": "confirm", "data": {}})
    yield from answered("e1", "an exception in a line with a page request")
    expect("e1", 3, "an exception in a line with a page request: status 3 with the request's id")
    if (yield from show("e2", "confirm", SAMPLES["confirm"], "the next request")):
        key(Return)
    yield from answered("e2", "the next request")
    expect("e2", 0, "the front end still serves the next request", lambda a: a == {"choice": "apply"})
    send({"quit": True})


owner_proc = None
owner_killed = 0.0


def prepare_owner():
    """A process that stands for the tool's main shell (BSA_OWNER_PID)."""
    global owner_proc
    owner_proc = subprocess.Popen(["sleep", "300"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.environ["BSA_OWNER_PID"] = str(owner_proc.pid)


def sc_owner_gone():
    """The root side is killed while a page is on screen and its other
    processes still hold the pipes: no "quit", no end of input."""
    global owner_killed
    yield W(lambda: prop("pendingId") == "x1" and shell.isVisible(), "page shown")
    yield from settled("page shown")
    check(appmod._Owner().pid == owner_proc.pid, "the front end watches the process in BSA_OWNER_PID")
    owner_proc.kill()
    owner_proc.wait()
    owner_killed = time.monotonic()


def after_owner_gone(rc):
    took = time.monotonic() - owner_killed if owner_killed else -1
    if owner_proc is not None and owner_proc.poll() is None:
        owner_proc.kill()
    check(rc == 0 and 0 <= took < 6, "the root side's main process is gone: app.py serve ended with status %r, %.1f s later "
          "(checked every %.0f s)" % (rc, took, appmod.OWNER_CHECK_MS / 1000))
    line, p = reply_for("x1")
    check(line is None or (p[1] == 1 and p[2] is None), "the waiting request got no answer line, or \"cancelled\": %s" % cut(line))
    no_warnings("owner gone")


def after_no_qt(what):
    """SERVE ended before anything was to be shown: status 0, nothing
    printed, and Qt was never started."""
    def f(rc):
        check(rc == 0 and not replies, "%s: status %r, nothing printed" % (what, rc))
        check(app is None and "PySide6.QtWidgets" not in sys.modules, "%s: no Qt application was made for it" % what)
    return f


def after_oneshot_broken(rc):
    allowed.extend(re.compile(p) for p in (r"Security Check: ", r"Check\.qml", r"^\s+\^|^\s+this is not QML"))
    check(rc == 3 and not replies, "app.py check with a page file that does not load: status %r (3 expected), nothing printed" % (rc,))
    check(re.search(r"Check\.qml:\d+", stderr_text()) is not None, "app.py check: the reason is written to stderr")


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
    "controls": (["serve"], lambda: {"busy": ""}, None, sc_controls, after_serve),
    "tab": (["serve"], lambda: {"busy": ""}, None, sc_tab, after_serve),
    "guard": (["serve"], lambda: {"busy": ""}, None, sc_guard, after_serve),
    "keys": (["serve"], lambda: {"busy": ""}, STUBS_KEYS, sc_keys, after_serve),
    "malformed": (["serve"], lambda: BAD_LINES[0][1], None, sc_malformed, after_serve),
    "broken-page": (["serve"], lambda: {"busy": ""}, STUBS_BROKEN, sc_broken, after_serve),
    "eof": (["serve"], request("x1", "confirm", "confirm"), None, sc_eof, after_end("end of input while a page waits", 1)),
    "eof-idle": (["serve"], None, None, None, after_no_qt("end of input before any request")),
    "exception": (["serve"], lambda: {"busy": ""}, None, sc_exception, after_serve),
    "owner-gone": (["serve"], request("x1", "confirm", "confirm"), None, sc_owner_gone, after_owner_gone),
    "quit": (["serve"], request("x1", "confirm", "confirm"), None, sc_quit, after_end("quit while a page waits", 1)),
    "quit-first": (["serve"], lambda: {"quit": True}, None, None, after_no_qt("quit as the first line")),
    "blank-quit": (["serve"], lambda: "\n   \n" + json.dumps({"quit": True}), None, None, after_no_qt("empty lines, then quit")),
    "progress-only": (["progress"], lambda: {"heading": "Checking your PC"}, None, sc_progress_only,
                      lambda rc: check(rc == 0 and not replies, "app.py progress ended with status %r, nothing printed" % (rc,))),
    "oneshot": (["dialog"], lambda: SAMPLES["dialog"], None, sc_oneshot("enter"), after_oneshot(0, {"button": 1})),
    "oneshot-esc": (["dialog"], lambda: SAMPLES["dialog"], None, sc_oneshot("esc"), after_oneshot(1, None)),
    "oneshot-close": (["dialog"], lambda: SAMPLES["dialog"], None, sc_oneshot("close"), after_oneshot(1, None)),
    "oneshot-broken": (["check"], lambda: SAMPLES["check"], STUBS_BROKEN, None, after_oneshot_broken),
    "oneshot-bad": (["dialog"], lambda: "this is not json", None, None,
                    lambda rc: check(rc == 2 and not replies, "app.py dialog with input that is not JSON: status %r (2 expected), nothing printed" % (rc,))),
}
# What a scenario needs done in its process before main() runs.
PREPARE = {"owner-gone": prepare_owner}
# Scenarios that run without QT_FORCE_STDERR_LOGGING: there ui/app.py must
# see to it that Qt's messages reach stderr.
NO_FORCED_STDERR = ("broken-page", "oneshot-broken")


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
    if name in PREPARE:
        PREPARE[name]()
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
    # For "exception": a colour scheme that is found first and cannot be read.
    os.makedirs(os.path.join(home, "share", "color-schemes"))
    with open(os.path.join(home, "share", "color-schemes", "BreezeLight.colors"), "w", encoding="utf-8") as f:
        f.write("[Colors:Window]\nBackgroundNormal=abc\n")
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
        "BSA_UI_TEST_HOME": home,
    })
    for var in ("BSA_THEME", "BSA_OWNER_PID", "QT_QUICK_CONTROLS_STYLE", "QT_LOGGING_RULES", "QML_IMPORT_TRACE", "QT_DEBUG_PLUGINS"):
        env.pop(var, None)
    total = failed = 0
    bad = []
    started = time.monotonic()
    try:
        for name in names or list(SCENARIOS):
            cmd = [sys.executable, "-I", os.path.realpath(__file__), "--scenario", name]
            env_now = dict(env)
            if name in NO_FORCED_STDERR:
                del env_now["QT_FORCE_STDERR_LOGGING"]
            if name == "exception":
                env_now["XDG_DATA_DIRS"] = os.path.join(home, "share") + ":" + env.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share")
            try:
                p = subprocess.run(cmd, env=env_now, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
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
