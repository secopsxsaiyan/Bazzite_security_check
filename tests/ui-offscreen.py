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
# lines. It is driven from inside the front end's own event loop, through
# the module's test interface: PAGE_DIR (the folder the page files come
# from) and TEST_HOOK(app, shell, host).
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
# A page (and a dialog) with more content than fits, for the keys that
# scroll: the page names what scrolls (scrollArea). With "plain" in its
# input it names nothing (null); STUB_PAGE has no such property at all.
STUB_SCROLL = """// Test stub: a page or dialog that scrolls.
import QtQuick
import QtQuick.Controls as QQC2
Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: "Scroll stub"
    readonly property Item scrollArea: input.plain ? null : flick
    signal finished(var answer)
    signal cancelled()
    function primary() { finished({ "via": "primary" }) }
    function dismiss() { cancelled() }
    implicitWidth: 320
    implicitHeight: 240
    Flickable {
        id: flick
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: 4000
        Column {
            QQC2.Button { objectName: "top"; text: "Top" }
            QQC2.ComboBox { objectName: "combo"; model: ["one", "two", "three"] }
            Item { width: 1; height: 3800 }
        }
    }
}
"""
STUBS_KEYS = {"Wizard.qml": STUB_PAGE, "Check.qml": STUB_SCROLL, "Dialog.qml": STUB_SCROLL}
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
    "Settings.qml": "import QtQuick\nItem { required property var input; property string iconSource: \"\" }\n",
    # A page by every test the Shell makes, but the Shell fails while it
    # sets it up: a dialog whose maximumWidth cannot be set.
    "Dialog.qml": "import QtQuick\nItem {\n    objectName: \"cannot-be-set-up\"\n    required property var input\n"
                  "    property string iconSource: \"\"\n    signal finished(var answer)\n    signal cancelled()\n"
                  "    readonly property real maximumWidth: 100\n}\n",
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
    data = (obj if isinstance(obj, bytes) else (obj if isinstance(obj, str) else json.dumps(obj)).encode()) + b"\n"
    if len(data) <= pipe_room():
        os.write(req_w, data)
        return
    # A line longer than the pipe (a container may refuse to enlarge it):
    # this process also reads it, so a plain write would block for ever.
    # A thread writes it while the front end reads.
    import threading

    def write_all(fd=req_w, rest=data):
        while rest:
            rest = rest[os.write(fd, rest):]
    threading.Thread(target=write_all, daemon=True).start()


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


def MOD():
    from PySide6.QtCore import Qt
    return Qt.KeyboardModifier


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


def typed(k, mod=None, text="", press=True, release=True, repeat=False):
    """A key as the keyboard sends it: through Qt's own path for keyboard
    events, on which a press is first offered to the shortcuts (a button's
    Alt+letter) and only then goes to the control with the keyboard focus.
    key() and key_event() above hand the event to the window directly and
    never get near a shortcut. REPEAT marks the keyboard's auto-repeat."""
    from PySide6.QtCore import Qt
    from PySide6.QtTest import QTest
    mod = mod or Qt.KeyboardModifier.NoModifier
    # QTest runs the event loop after each event; the timer that drives
    # this scenario must not start its next step in there.
    timer = appmod.TEST_HOOK.keep[0]
    timer.stop()
    try:
        if press:
            QTest.simulateEvent(shell, True, k.value, mod, text, repeat)
        if release:
            QTest.simulateEvent(shell, False, k.value, mod, text, repeat)
    finally:
        timer.start(10)


def held(k, text, seconds, until=None, mod=None):
    """hold(), through Qt's path for keyboard events: see typed()."""
    end = time.monotonic() + seconds
    while time.monotonic() < end and not (until and until()):
        typed(k, mod, text, press=False, repeat=True)
        typed(k, mod, text, release=False, repeat=True)
        yield P(0.03)


def scroll_y(page=None):
    """How far the page that takes the input now (or PAGE) is scrolled, and
    how far it can be: (contentY, the largest contentY); None without a
    scrollArea."""
    area = (page or page_root()).property("scrollArea")
    if area is None:
        return None
    top = area.property("originY") - area.property("topMargin")
    return (area.property("contentY") - top,
            max(0.0, area.property("contentHeight") + area.property("bottomMargin") + area.property("topMargin") - area.height()))


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


def alt_keys():
    """The Alt key of every button of the page that has one: label -> letter."""
    from PySide6.QtQml import QQmlExpression, qmlContext
    keys = {}
    for b in controls():
        got_ = QQmlExpression(qmlContext(b), b, "Kirigami.MnemonicData.sequence.toString()").evaluate()
        seq = got_[0] if isinstance(got_, tuple) else got_
        if b.property("text") and seq:
            keys[b.property("text")] = str(seq).replace("Alt+", "")
    return keys


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


def enter_on(item):
    """The keyboard: the focus on ITEM, as Tab puts it there, then Enter.
    This is how the Confirm page is applied with Enter: there, Enter does
    nothing unless Apply itself has the keyboard focus."""
    from PySide6.QtCore import Qt
    if item is None:
        return False
    item.forceActiveFocus(Qt.FocusReason.TabFocusReason)
    key(Qt.Key.Key_Return, text="\r")
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


def on_and_on(rid, mode, data, act, steps, what):
    """at_once(), and then each of STEPS (functions) in turn, 150 ms apart:
    input that goes on and on as a page appears. Every step must start the
    settle pause again, so each one is taken only while the Shell says it
    is still settling. When it is not (this machine stalled for longer than
    the pause between two steps), all of it starts again with a new
    request, a few times: nothing is left out. Returns the id of the
    request that got ACT and every step, or that was answered on the way
    (the caller's check then fails); None, after a failed check, when no
    try got through."""
    tries = 4
    for attempt in range(tries):
        cur = yield from at_once("%s%d" % (rid, attempt), mode, data, act, what + " at once")
        if cur is None:
            return None
        done = 0
        for step in steps:
            yield P(0.15)
            if got(cur) or prop("settling") is not True:
                break
            step()
            done += 1
        if done == len(steps) or got(cur):
            return cur
        say("     note: %s on and on: the settle pause was over before step %d of %d (try %d)" % (what, done + 1, len(steps), attempt + 1))
        yield from settled(what)
    check(False, "%s on and on: the page was still settling before each of %d steps, 150 ms apart, in one of %d tries (if not: "
          "the Shell does not start the settle pause again with every key and click, or this machine stalls again and again)"
          % (what, len(steps), tries))
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
        # The one page where Enter is not the main button: no button has the
        # keyboard focus, and Enter applies only with the focus on Apply
        # (sc_controls has that). An answer with status 0 here would be an
        # Enter that applied a fix.
        ("confirm: Enter with the focus on no button applies nothing, Esc cancels", "confirm", S["confirm"],
         [Return, Return, Return, Escape], 1, None),
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
        if mode == "confirm":
            check(p is not None and p[1] == 1, "%s: Enter applied nothing, Esc cancelled it" % what)
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
    # Every size the window takes from here on (a Wayland compositor ends a
    # program whose window asks for a width or height of 0).
    # Off-screen the size itself is not seen to change, but the limits the
    # window is given are, and they come from the same values.
    sizes = [small]
    shell.minimumWidthChanged.connect(lambda *a: sizes.append((shell.minimumWidth(), shell.minimumHeight())))
    shell.minimumHeightChanged.connect(lambda *a: sizes.append((shell.minimumWidth(), shell.minimumHeight())))
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
    status = lambda: [s for s in spoken() if s[0] == "StatusBar"]
    yield W(lambda: status() == [("StatusBar", "Looking for an update…", "")],
            "busy: a screen reader is told one status, with the label as its name", 3.0)
    if status() != [("StatusBar", "Looking for an update…", "")]:
        say("     it is told: %s" % cut(status() or spoken(), 400))
    send({"busy": ""})
    yield W(lambda: prop("busyLabel") == "", "busy \"\": the usual label is back")
    check(prop("busyShown") is True and len(replies) == 1, "busy: still busy, and nothing was answered")

    # 3. the first page: the window grows, the spinner goes
    if (yield from show("s1", "confirm", S["confirm"], "first page")):
        big = (shell.width(), shell.height())
        check(prop("compact") is False and big[0] > small[0] and big[1] > small[1], "first page: the window grew to %dx%d" % big)
        check(prop("busyShown") is False, "first page: no longer busy")
        empty = [x for x in sizes if x[0] <= 0 or x[1] <= 0]
        check(not empty, "from the small window to the first page: the window was never told to have no width or height: %s" % empty[:3])
        # A label while a page waits for its answer is dropped.
        send({"busy": "Later"})
        yield P(0.3)
        check(prop("busyShown") is False and prop("pendingId") == "s1", "busy while a page is shown: the page stays usable")
        check(prop("busyLabel") == "", "busy while a page is shown: the label is not kept (it is %r)" % prop("busyLabel"))

    # 4. a dialog over the page
    if (yield from show("s2", "dialog", S["dialog-error"], "dialog over a page")):
        expect("s1", 1, "a second request while one is pending: the first is cancelled")
        check(prop("dialogItem") is not None and prop("pageItem") is not None and (shell.width(), shell.height()) == big,
              "dialog over a page: on top of it, same window size")
        shot("shell-dialog-over-page")
        told = [s for s in spoken() if s[0] == "Dialog"]
        check(told == [("Dialog", S["dialog-error"]["title"], "")],
              "dialog over a page: a screen reader is told one dialog, with the dialog's title as its name: %s" % cut(told))
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
    send({"busy": "Too early"})             # while the page waits: see 6.
    yield P(0.3)
    key(Return)
    yield from answered("s4", "two requests at once")
    expect("s4", 0, "two requests at once: the second is answered", lambda a: a == {"tags": ["a", "b"]})

    # 6. between two requests the page stays, under the spinner
    yield W(lambda: prop("busyShown") is True and shell.isVisible(), "after an answer: the window stays, busy")
    check(prop("busyLabel") == "", "after an answer: the spinner does not show a label that came while the page waited (it shows %r)"
          % prop("busyLabel"))

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
        click(main_button(), "Apply")
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
        # 10. a window that comes up (again) with a page in it: the settle
        # pause starts with the first picture of it, not before
        shell.hide()
        yield P(0.6)                        # longer than the pause
        shell.show()
        yield W(lambda: prop("settling") is True, "window shown with a page in it: the page settles again", 3.0)
        yield from settled("window shown with a page in it")

        # 11. the keys that scroll, on a real page in the smallest window
        shell.setWidth(shell.minimumWidth())
        shell.setHeight(shell.minimumHeight())
        yield W(lambda: scroll_y() is not None and scroll_y()[1] > 0, "smallest window: the Confirm page has more than fits (and names its scrollArea)")
        if scroll_y() is not None:
            typed(K().Key_End)
            yield P(0.1)
            check(scroll_y()[1] > 0 and abs(scroll_y()[0] - scroll_y()[1]) < 1.5, "End shows the end of the Confirm page (at %d of %d)" % scroll_y())
            typed(K().Key_PageUp)
            typed(K().Key_PageUp)
            typed(K().Key_PageUp)
            yield P(0.1)
            check(abs(scroll_y()[0]) < 1.5, "PageUp goes back to its top (at %d of %d)" % scroll_y())
        click(main_button(), "Apply")
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
        deep = card("Deep check-up")
        space(deep)
        yield P(0.1)
        check(deep is not None and deep.property("switchedOn") is True, "wizard: Space on \"Deep check-up\" ticks it")
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

    # Confirm: Enter applies only while Apply itself has the keyboard focus.
    def confirm_enter_elsewhere(rid):
        from PySide6.QtCore import Qt
        key(Return, text="\r")              # the focus on no control at all
        yield P(0.2)
        check(not got(rid), "confirm: Enter with the focus on no control applies nothing")
        block = control("the commands", lambda i: True, "QQuickTextEdit")
        if block is not None:
            block.forceActiveFocus(FOCUS_BY_TAB())
            key(Return, text="\r")
            yield P(0.2)
            check(not got(rid), "confirm: Enter with the focus on the commands applies nothing")
        page = prop("pageItem")
        if page is not None:
            from PySide6.QtCore import QMetaObject
            QMetaObject.invokeMethod(page, "primary")       # what the window calls for Enter
            yield P(0.2)
            check(not got(rid), "confirm: primary() without the focus on Apply applies nothing")
        # Shift+Tab from there goes back to Apply by way of Skip; from the
        # page as it comes up it is the first stop.
        for _ in range(12):
            if is_main(shell.activeFocusItem()):
                break
            typed(K().Key_Backtab, Qt.KeyboardModifier.ShiftModifier)
            yield P(0.03)
        check(is_main(shell.activeFocusItem()), "confirm: Shift+Tab reaches Apply (the focus is on: %s)" % focus_text())
        check(not got(rid), "confirm: moving the focus applies nothing")
        key(Return, text="\r")

    def confirm_backtab(rid):
        from PySide6.QtCore import Qt
        typed(K().Key_Backtab, Qt.KeyboardModifier.ShiftModifier)
        yield P(0.1)
        check(is_main(shell.activeFocusItem()), "confirm: Shift+Tab on the page as it comes up goes straight to Apply (the focus is on: %s)" % focus_text())
        typed(Return, text="\r")

    def enter_with(text):
        def steps(rid):
            enter_on(button(text))
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

    def press_keys(*keys):
        def steps(rid):
            yield from press(rid, keys)
        return steps

    def list_end_home(rid):
        tags = [i["tag"] for i in S["dialog-list"]["items"]]

        def picked():
            return [plain(r.property("modelData"))["tag"] for r in controls("QQuickRadioDelegate") if r.property("checked")]
        key(K().Key_End)
        yield P(0.1)
        at_end, on_end = picked(), shell.activeFocusItem().property("checked")
        key(K().Key_Home)
        yield P(0.1)
        check(len(tags) > 2 and at_end == [tags[-1]] and on_end is True and picked() == [tags[0]]
              and shell.activeFocusItem().property("checked") is True,
              "dialog, list: End picks the last row and Home the first, and the keyboard focus goes with them (%s, then %s)" % (at_end, picked()))
        key(K().Key_End)
        yield P(0.1)
        key(Return, text="\r")

    # Enter is the main button, and the main button is switched off: nothing.
    def choose_nothing(rid):
        for tag in ("a", "b"):              # the two that come ticked
            space(row("tag", tag))
            yield P(0.1)
        page = prop("pageItem")
        mains = [i for i in items_under(page) if is_main(i)]
        check(page.property("count") == 0 and len(mains) == 1 and not mains[0].isEnabled(),
              "choose, where one must be picked: with nothing ticked the main button is switched off")
        key(Return, text="\r")              # the focus is on a row: Enter is the page's main action
        yield P(0.3)
        check(not got(rid), "choose, where one must be picked: Enter with nothing ticked does not continue")
        key(K().Key_Escape)

    def check_nothing(rid):
        on = [b for b in controls("QQuickCheckBox") if not b.property("text") and b.property("checked")]
        if not check(len(on) == 1, "check: one finding comes ticked"):
            return
        space(on[0])                        # no longer; the focus stays on the tick box
        yield P(0.1)
        check(prop("pageItem").property("count") == 0, "check: Space unticks the finding")
        key(Return, text="\r")
        yield P(0.3)
        check(not got(rid), "check: Enter with nothing ticked sends no fix")
        key(K().Key_Escape)

    def wizard_no_folder(rid):
        page = prop("pageItem")
        key(Return, text="\r")              # "Start the check-up" on the Review step
        yield P(0.3)
        shown = [i.property("text") for i in items_under(page) if i.inherits("QQuickText") and i.isVisible()
                 and "Choose a report folder below" in (i.property("text") or "")]
        check(not got(rid) and page.property("step") == 2 and len(shown) == 1,
              "wizard without a report folder: \"Start the check-up\" answers nothing and goes to Options, where a message asks for the folder")
        yield from press(rid, [K().Key_Escape] * 4)

    def copy_commands(rid):
        from PySide6.QtGui import QGuiApplication
        board = QGuiApplication.clipboard()
        edit = control("the commands", lambda i: True, "QQuickTextEdit")
        copy = button("Copy")
        for how, use in (("clicked", click), ("pressed with Space", lambda b, what: space(b))):
            board.setText("something else")
            use(copy, "Copy")
            yield P(0.2)
            check(board.text() == S["confirm"]["commands"] and edit is not None and edit.property("selectedText") == "" and not got(rid),
                  "confirm: Copy, %s, puts the commands on the clipboard, leaves nothing selected and answers nothing: %r" % (how, cut(board.text(), 60)))
        click(button("Skip"), "Skip")

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
        ("confirm: Space with the focus on Apply", "confirm", S["confirm"], press_with("Apply", "space"), 0, lambda a: a == {"choice": "apply"}),
        ("confirm: Enter elsewhere does nothing, Enter with the focus on Apply applies", "confirm", S["confirm"], confirm_enter_elsewhere, 0,
         lambda a: a == {"choice": "apply"}),
        ("confirm: Shift+Tab, then Enter", "confirm", S["confirm"], confirm_backtab, 0, lambda a: a == {"choice": "apply"}),
        ("confirm: Enter with the focus on Skip skips", "confirm", S["confirm"], enter_with("Skip"), 0, lambda a: a == {"choice": "skip"}),
        ("dialog, question: the other button", "dialog", S["dialog"], press_with("Cancel", "mouse"), 0, lambda a: a == {"button": 0}),
        ("dialog, list: another row, clicked", "dialog", S["dialog-list"], list_other, 0, lambda a: a == {"button": 1, "tag": state["tag"]}),
        ("dialog, list: Down, then the other button", "dialog", S["dialog-list"], list_down_cancel, 0,
         lambda a: state["tag"] is not None and a == {"button": 0, "tag": state["tag"]}),
        ("dialog, list: End and Home, then Enter", "dialog", S["dialog-list"], list_end_home, 0,
         lambda a: a == {"button": 1, "tag": S["dialog-list"]["items"][-1]["tag"]}),
        ("choose, where one must be picked: nothing ticked, Enter, then Esc", "choose", dict(S["choose"], allow_none=False), choose_nothing, 1, None),
        ("check: nothing ticked, Enter, then Esc", "check", S["check"], check_nothing, 0, lambda a: a == {"action": "back"}),
        ("wizard without a report folder: Enter on Review, then Esc", "wizard",
         dict(S["wizard"], start_step=3, answers=dict(wiz, report_dir="")), wizard_no_folder, 1, None),
        # The root side rejects an answer with a key missing: the page fills them in.
        ("wizard: an answer has every key, also those the input left out", "wizard",
         dict(S["wizard"], start_step=3, answers={"report_dir": wiz["report_dir"]}), press_keys(Return), 0,
         lambda a: a == {"use": [], "fix": True, "deep": False, "report_dir": wiz["report_dir"], "action": "start"}),
        ("wizard: Settings, with answers the input left out", "wizard", dict(S["wizard"], answers={"report_dir": wiz["report_dir"]}),
         wizard_settings, 0, lambda a: a == {"use": [], "fix": True, "deep": False, "report_dir": wiz["report_dir"], "action": "settings"}),
        ("confirm: the Copy button", "confirm", S["confirm"], copy_commands, 0, lambda a: a == {"choice": "skip"}),
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


def spoken(root=None):
    """What assistive tools are told about the window (the page, and the
    dialog over it): (role, name, description) of every object that is not
    hidden."""
    from PySide6.QtGui import QAccessible
    out = []

    def walk(obj, depth):
        if obj is None or depth > 80 or obj.state().invisible:
            return
        out.append((str(obj.role()).split(".")[-1], obj.text(QAccessible.Text.Name) or "", obj.text(QAccessible.Text.Description) or ""))
        for n in range(obj.childCount()):
            walk(obj.child(n), depth + 1)
    walk(QAccessible.queryAccessibleInterface(root or shell), 0)
    return out


def said_twice(root=None):
    """Controls and texts with something inside them that has a name of its
    own, which a screen reader would say after theirs: (the name, the name
    inside it) of each."""
    from PySide6.QtGui import QAccessible
    whole = ("Button", "CheckBox", "RadioButton", "StaticText", "ListItem")
    out = []

    def walk(obj, depth, above):
        if obj is None or depth > 80 or obj.state().invisible:
            return
        role, name = str(obj.role()).split(".")[-1], obj.text(QAccessible.Text.Name) or ""
        if above is not None and name:
            out.append((above, name))
        for n in range(obj.childCount()):
            walk(obj.child(n), depth + 1, above if above is not None else name if role in whole and name else None)
    walk(QAccessible.queryAccessibleInterface(root or shell), 0, None)
    return out


def util_js():
    """ui/qml/util.js, to call from here: an object with the text "a" and
    the list "b", and what the functions make of them as properties."""
    from PySide6.QtCore import QUrl
    from PySide6.QtQml import QQmlComponent
    source = b"""import QtQml
import "util.js" as Util
QtObject {
    property string a
    property var b: []
    readonly property string esc: Util.esc(a)
    readonly property string tip: Util.tip(a)
    readonly property string mnemonic: Util.mnemonic(a)
    readonly property string plain: Util.plain(a)
    readonly property string fill: Util.fill(a, b)
    readonly property string reflow: Util.reflow(a)
}
"""
    component = QQmlComponent(appmod.TEST_HOOK.keep[1])
    component.setData(source, QUrl.fromLocalFile(os.path.join(REPO, "ui", "qml", "util-test.qml")))
    obj = component.create()
    util_js.keep = (component, obj)
    return obj


def rings():
    """The focus rings (FocusRing.qml) that are shown now."""
    return [i for i in items_under(page_root()) if i.metaObject().className().startswith("FocusRing") and i.isVisible()]


def tab_stops(limit=80):
    """The controls Tab stops at, once around the page."""
    seen = []
    for _ in range(limit):
        key(K().Key_Tab)
        item = shell.activeFocusItem()
        if item in seen:
            break
        seen.append(item)
    return seen


def sc_a11y():
    """What a person who does not use the mouse, or does not see the
    window, gets: names without markup, a focus ring on every control the
    style shows none on, one Tab stop per list, a scrolling area the window
    can scroll with the keyboard, and buttons that fit in a dialog."""
    from PySide6.QtCore import QMetaObject, Qt
    from PySide6.QtGui import QAccessible
    Tab, Right, Down, End, Home = K().Key_Tab, K().Key_Right, K().Key_Down, K().Key_End, K().Key_Home
    S = SAMPLES
    QAccessible.setActive(True)
    # A page that starts with the focus on a row, not on a plain button
    # (nothing ticked, and something must be): the row shows its ring from
    # the start, so Space never ticks a row not shown as focused.
    unticked = dict(S["choose"], allow_none=False, items=[dict(i, on=False) for i in S["choose"]["items"]])
    if (yield from show("f1", "choose", unticked, "choose with nothing ticked")):
        first = shell.activeFocusItem()
        check(first is not None and first.property("checkable") is True and first.property("visualFocus") is True and len(rings()) == 1,
              "choose with nothing ticked: the row that starts with the focus shows its ring (%d shown)" % len(rings()))
        key(K().Key_Escape)
    yield from answered("f1", "choose with nothing ticked")
    markup = re.compile(r"<[A-Za-z!/]|&(amp|lt|gt|nbsp|quot);")
    undone = dict(S["confirm"], undo=False)
    notes = dict(S["dashboard"], reboot_reasons="A service was switched off", report_note="The folder could not be written",
                 prev=True, gone=1, new_titles="A new finding")
    # Text from the PC that looks like markup is shown, and spoken, as it is.
    tagged = dict(notes, reboot_reasons="A <b>bold</b> & plain reason")
    no_folder = dict(S["wizard"], start_step=2, answers=dict(S["wizard"]["answers"], report_dir=""))
    pages = [
        # name, mode, input, has a scrolling area, the least number of messages in a box (Notice.qml)
        ("wizard", "wizard", S["wizard"], True, 1),
        ("wizard, Your PC", "wizard", dict(S["wizard"], start_step=1), True, 0),
        ("wizard, Options without a folder", "wizard", no_folder, True, 1),
        ("wizard, Review", "wizard", dict(S["wizard"], start_step=3), True, 0),
        ("settings", "settings", S["settings"], True, 0),
        ("dashboard", "dashboard", notes, True, 3),
        ("check", "check", S["check"], True, 0),
        ("choose", "choose", S["choose"], True, 0),
        ("confirm", "confirm", S["confirm"], True, 1),
        ("confirm, no undo", "confirm", undone, True, 1),
        ("dialog, question", "dialog", S["dialog"], True, 0),
        ("dialog, error", "dialog", S["dialog-error"], True, 0),
        ("dialog, list", "dialog", S["dialog-list"], True, 0),
    ]
    for n, (what, mode, data, scrolls, boxes) in enumerate(pages):
        if not (yield from show("y%d" % n, mode, data, what)):
            continue
        said = spoken()
        if n == 0 and not check(len(said) > 3, "the accessible objects of a page can be read here (%d)" % len(said)):
            break
        bad = [(role, name or desc) for role, name, desc in said if markup.search(name) or markup.search(desc)]
        check(not bad, "%s: no markup in what a screen reader is told (%d objects)%s" % (what, len(said), "" if not bad else ": " + cut(bad[:2], 240)))
        alerts = [name for role, name, desc in said if role == "AlertMessage"]
        check(len(alerts) >= boxes and all(alerts), "%s: %d message boxes, each with its text as the name: %s" % (what, len(alerts), cut(alerts, 160)))
        if mode == "dialog" and data.get("html"):
            want = re.sub(r"\s+", " ", re.sub(r"<[^>]*>", " ", data["html"])).strip()
            got_names = [re.sub(r"\s+", " ", name).strip() for role, name, desc in said]
            check(any(g and g.replace(" ", "") == want.replace(" ", "") for g in got_names), "%s: the text is spoken without its tags: %r" % (what, cut(want, 60)))
        area = page_root().property("scrollArea")
        check((area is not None and area.inherits("QQuickFlickable")) == scrolls, "%s: scrollArea is the page's scrolling area" % what)
        twice = said_twice()
        check(not twice, "%s: no control or text is said a second time by a label inside it%s" % (what, "" if not twice else ": " + cut(twice[:3], 240)))
        no_warnings(what)

    if (yield from show("y-d", "dashboard", tagged, "dashboard, texts from the PC")):
        names = [name for role, name, desc in spoken() if role == "AlertMessage"]
        shown = [i.property("text") for i in items_under(page_root()) if i.inherits("QQuickText") and "plain reason" in (i.property("text") or "")]
        check(any(n.endswith("A <b>bold</b> & plain reason") for n in names) and len(shown) == 1
              and shown[0].endswith("A &lt;b&gt;bold&lt;/b&gt; &amp; plain reason"),
              "dashboard: a reason from the PC with tags in it is spoken as it is and shown as text, not as markup: %r" % shown)

    # ---- the report folder's description (wizard, Options)
    for rid, data, chosen in (("y-f0", no_folder, False), ("y-f1", dict(S["wizard"], start_step=2), True)):
        if (yield from show(rid, "wizard", data, "wizard, Options")):
            field = [(name, desc) for role, name, desc in spoken() if role == "EditableText"]
            ok = len(field) == 1 and field[0][0] == "Report folder" and (("No folder chosen" in field[0][1]) != chosen) and field[0][1] != ""
            check(ok, "wizard: the report folder's description %s: %r" % ("is not \"No folder chosen\" while one is chosen" if chosen
                                                                           else "says that none is chosen", field))
    # Why Settings cannot be used is on the page in words, not only in a tool tip.
    if (yield from show("y-s", "wizard", dict(S["wizard"], answers=dict(S["wizard"]["answers"], report_dir="")), "wizard without a folder")):
        why = [i.property("text") for i in items_under(page_root()) if i.inherits("QQuickText") and i.isVisible()
               and "report folder first" in (i.property("text") or "")]
        b = [i for i in items_under(page_root()) if i.inherits("QQuickAbstractButton") and i.property("text") == "Settings"]
        check(len(why) == 1 and len(b) == 1 and not b[0].isEnabled(), "wizard: why Settings is switched off is written on the page: %r" % why)

    # ---- a focus ring where the style draws none
    def ringed(what, item, around=None):
        if item is None:
            return check(False, "%s: there is such a control" % what)
        QMetaObject.invokeMethod(shell, "unfocus")      # the keyboard focus on no control
        before = len(rings())
        item.forceActiveFocus(FOCUS_BY_TAB())
        now = rings()
        target = [r for r in now if r.property("target") is item]
        ok = before == 0 and len(now) == 1 and len(target) == 1
        if ok and around is not None:
            ok = target[0].parentItem() is around
        return check(ok, "%s: a focus ring shows while it has the keyboard focus (%d before, %d now)" % (what, before, len(now)))

    if (yield from show("y-c", "check", S["check"], "check, focus")):
        boxes = controls("QQuickCheckBox")
        ticks = [b for b in boxes if not b.property("text")]
        ringed("check: Select all", next((b for b in boxes if b.property("text")), None))
        if check(len(ticks) > 0, "check: a tick box per finding that can be fixed"):
            card = ticks[0].parentItem()
            while card is not None and card.property("canFix") is None:
                card = card.parentItem()
            ringed("check: the tick box of a finding (the ring is around its card)", ticks[0], card)
        hows = [n for r, n, d in spoken() if n.startswith("How to fix it yourself")]
        check(len(hows) == len(set(hows)) and len(hows) >= 2, "check: each \"How to fix it yourself\" button has a name of its own (%d)" % len(hows))
    if (yield from show("y-t", "settings", S["settings"], "settings, focus")):
        ringed("settings: the tick box", next(iter(controls("QQuickCheckBox")), None))
        link = [i for i in items_under(page_root()) if i.metaObject().className().startswith("UrlButton") and i.isVisible()]
        ringed("settings: the link to the project page", link[0] if link else None)
        # A control that gets the focus comes into view.
        area = page_root().property("scrollArea")
        shell.setHeight(shell.minimumHeight())
        yield P(0.3)
        if link and check(scroll_y() is not None and scroll_y()[1] > 0, "settings in a small window: the page scrolls"):
            QMetaObject.invokeMethod(shell, "unfocus")
            area.setProperty("contentY", 0)
            link[0].forceActiveFocus(FOCUS_BY_TAB())
            yield P(0.2)
            check(scene_point(link[0]) is not None and scroll_y()[0] > 0, "settings: the link comes into view when Tab reaches it")

    # ---- the dashboard: the area chips are one Tab stop, the checks another
    if (yield from show("y-r", "dashboard", S["dashboard"], "dashboard, Tab stops")):
        n_areas, n_checks = len(S["dashboard"]["areas"]), len(S["dashboard"]["checks"])
        stops = tab_stops()
        chips = [i for i in stops if i.property("modelData") is not None and not i.inherits("QQuickItemDelegate")]
        rows_ = [i for i in stops if i.inherits("QQuickItemDelegate")]
        check(len(chips) == 1 and len(rows_) == 1 and len(stops) < 12,
              "dashboard: %d areas and %d checks are two Tab stops (%d chips, %d rows, %d stops in all)" % (n_areas, n_checks, len(chips), len(rows_), len(stops)))
        if chips and rows_:
            chips[0].forceActiveFocus(FOCUS_BY_TAB())
            key(Right)
            second = shell.activeFocusItem()
            check(second is not chips[0] and plain(second.property("modelData")) == S["dashboard"]["areas"][1], "dashboard: Right goes to the next area chip")
            key(End)
            check(plain(shell.activeFocusItem().property("modelData")) == S["dashboard"]["areas"][-1], "dashboard: End goes to the last area chip")
            rows_[0].forceActiveFocus(FOCUS_BY_TAB())
            key(Down)
            below = shell.activeFocusItem()
            check(below is not rows_[0] and below.inherits("QQuickItemDelegate"), "dashboard: Down goes to the next check")
            key(End)
            last = shell.activeFocusItem()
            yield P(0.2)
            check(last.inherits("QQuickItemDelegate") and last.property("number") == n_checks - 1 and scene_point(last) is not None,
                  "dashboard: End goes to the last check, which comes into view")
            key(Home)
            check(shell.activeFocusItem() is rows_[0], "dashboard: Home goes back to the first check")
            key(Down)
            again = tab_stops()
            check([i for i in again if i.inherits("QQuickItemDelegate")] == [below], "dashboard: Tab comes back to the check the arrows left")
            # Enter on a chip jumps to its area, and the focus goes to its first check.
            enter_on(second)
            yield P(0.2)
            landed = shell.activeFocusItem()
            check(not got("y-r") and landed.inherits("QQuickItemDelegate")
                  and plain(landed.property("modelData")).get("area") == S["dashboard"]["areas"][1]["name"],
                  "dashboard: Enter on an area chip goes to the first check of that area, and answers nothing")

    # ---- Choose: the rows are one Tab stop, and each is a check box with a name
    if (yield from show("y-o", "choose", S["choose"], "choose, Tab stops")):
        items = S["choose"]["items"]
        stops = tab_stops()
        rows_ = [i for i in stops if i.property("modelData") is not None]
        check(len(rows_) == 1 and len(items) > 2 and len(stops) < 8,
              "choose: %d rows are one Tab stop (%d rows among %d stops)" % (len(items), len(rows_), len(stops)))
        if rows_:
            rows_[0].forceActiveFocus(FOCUS_BY_TAB())
            key(Down)
            below = shell.activeFocusItem()
            key(End)
            last = shell.activeFocusItem()
            key(Home)
            check(plain(below.property("modelData")) == items[1] and plain(last.property("modelData")) == items[-1]
                  and shell.activeFocusItem() is rows_[0], "choose: Down, End and Home move between the rows")
            key(Down)
            check([i for i in tab_stops() if i.property("modelData") is not None] == [below], "choose: Tab comes back to the row the arrows left")
        risks = {"low": "Low risk", "medium": "Medium risk", "high": "High risk"}
        want = [("CheckBox", "%s, %s" % (i["label"], risks[i["risk"]]) if i["risk"] else i["label"],
                 ". ".join(t for t in (i.get("detail"), i.get("warn")) if t)) for i in items]
        boxes = [o for o in spoken() if o[0] == "CheckBox"]
        check(boxes == want, "choose: each row is a check box named after its item and its risk, with the detail and the warning as its description: %s"
              % cut(boxes, 200))
    # ---- Confirm: the command block and its Copy button are Tab stops; the severity is said
    if (yield from show("y-k", "confirm", S["confirm"], "confirm, Tab stops")):
        stops = tab_stops()
        check(len([i for i in stops if i.inherits("QQuickTextEdit")]) == 1 and len([i for i in stops if i.property("text") == "Copy"]) == 1,
              "confirm: the command block and its Copy button are Tab stops (%d stops)" % len(stops))
        said = spoken()
        check(("StaticText", "High severity", "") in said and S["confirm"]["sev"] == "high",
              "confirm: the chip with the severity is a text named \"High severity\": %s" % cut([o for o in said if "everity" in o[1]], 200))

    # ---- text from the PC in a tool tip and in the label of the main button
    odd = "/home/player/<b>bold</b> & co/reports"
    if (yield from show("y-p", "wizard", dict(S["wizard"], start_step=2, answers=dict(S["wizard"]["answers"], report_dir=odd)), "wizard, an odd folder")):
        field = control("the report folder", lambda i: True, "QQuickTextField")
        tips = [o.property("text") for o in field.children() if o.metaObject().className().startswith("QQuickToolTipAttached")] if field is not None else []
        check(field is not None and field.property("text") == odd and tips == ["<span>/home/player/&lt;b&gt;bold&lt;/b&gt; &amp; co/reports</span>"],
              "wizard: a folder name with tags in it is shown as it is, and escaped in the tool tip: %r" % tips)
    util = util_js()
    if check(util is not None, "ui/qml/util.js can be called from the test"):
        for name, text, values, want in (
                ("esc", "a <b> & </b>", [], "a &lt;b&gt; &amp; &lt;/b&gt;"),
                ("tip", "/home/<i>x</i> & y\nz", [], "<span>/home/&lt;i&gt;x&lt;/i&gt; &amp; y<br>z</span>"),
                ("mnemonic", "&Fix <b>it</b> && more", [], "<u>F</u>ix &lt;b&gt;it&lt;/b&gt; &amp; more"),
                ("mnemonic", "Fix &<b>it</b> &more", [], "Fix <u>&lt;</u>b&gt;it&lt;/b&gt; more"),
                ("plain", "<p>One<br>two &amp; <b>three</b></p>", [], "One two & three"),
                ("fill", "%1 and %2", ["%2", "b"], "%2 and b"),
                ("reflow", "a\nb\n\n- c\nd", [], "a b\n\n- c\nd")):
            util.setProperty("a", text)
            util.setProperty("b", values)
            check(util.property(name) == want, "util.js: %s(%r) is %r" % (name, text, util.property(name)))

    # ---- the main button shows its Alt key, as the other buttons do
    if (yield from show("y-m", "choose", dict(S["choose"], ok="Remove <i>these</i>"), "main button, Alt")):
        main = main_button()
        label = next((i for i in items_under(main) if i.inherits("QQuickText")), None) if main is not None else None
        if label is not None:
            typed(K().Key_Alt, Qt.KeyboardModifier.AltModifier, release=False)
            yield P(0.2)
            held_text = label.property("text")
            typed(K().Key_Alt, press=False)
            yield P(0.2)
            check("<u>" in held_text and "<u>" not in label.property("text") and not got("y-m"),
                  "the main button underlines its Alt key while Alt is held: %r, then %r" % (held_text, label.property("text")))
            check("&lt;i&gt;these&lt;/i&gt;" in held_text and "<i>" not in held_text and label.property("text").startswith("Remove <i>these</i>"),
                  "the main button: tags in a label from the PC are text, with Alt held and without")

    # ---- a dialog whose buttons do not fit next to each other
    labels = ["Keep everything as it is on this PC now", "Undo only the change to the firewall", "Undo every change made in this run"]
    long_ = {"kind": "question", "title": S["dialog"]["title"], "html": S["dialog"]["html"], "buttons": [{"label": t} for t in labels]}
    shell.setWidth(shell.minimumWidth())
    yield P(0.3)
    if (yield from show("y-l", "dialog", long_, "dialog, three long buttons")):
        from PySide6.QtCore import QPointF
        dialog = page_root()
        out = []
        shown = [b for b in controls() if b.property("text") in labels]
        for b in shown:
            left = b.mapToItem(dialog, QPointF(0, 0)).x()
            if left < 0 or left + b.width() > dialog.width() + 0.5:
                out.append(b.property("text"))
        check(len(shown) == 3 and not out, "dialog: three long buttons stay inside the dialog (%d wide)%s" % (dialog.width(), "" if not out else ": not %r" % out))
        key(K().Key_Return, text="\r")
        yield from answered("y-l", "dialog, three long buttons")
        expect("y-l", 0, "dialog, three long buttons: Enter is still the last one", lambda a: a == {"button": 2})
    no_warnings("the whole scenario")
    send({"quit": True})


def sc_guard():
    """What arrives as a page appears was meant for the page before and
    must not answer the new one: a key, a button's Alt+letter shortcut or a
    click in the first moment (and pressed on and on after it), and a key
    or mouse button that is held down (or repeats) across the change of
    page - however long it is held. A held key answers the page it was
    pressed on once; a page that has answered takes nothing more."""
    Return, Escape, Space, Tab = K().Key_Return, K().Key_Escape, K().Key_Space, K().Key_Tab
    data, choose = SAMPLES["confirm"], SAMPLES["choose"]
    missing = " (the guard in ui/qml/Shell.qml is missing or does not cover this)"

    def no_answer(rid, what):
        return check(not got(rid), what + (missing if got(rid) else ""))

    def tab_to(item):
        """The keyboard focus on ITEM as Tab puts it there, with the focus
        ring (also when the page gave ITEM the focus without one)."""
        item.setFocus(False)
        item.forceActiveFocus(FOCUS_BY_TAB())

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

    # 1. A key or a click in the first moment. The Choose page is one that
    # Enter answers whatever has the keyboard focus. Each key twice: as the
    # keyboard sends it, and as a program hands it to the window.
    for base, k, name in (("g1", Return, "Enter"), ("g2", Escape, "Esc"), ("g3", Space, "Space")):
        text = {Return: "\r", Space: " "}.get(k, "")
        for how, send_key in (("the keyboard", lambda press=True, release=True: typed(k, text=text, press=press, release=release)),
                              ("a program", lambda press=True, release=True: [key_event(p, k, text) for p in (True, False)
                                                                                 if (press if p else release)])):
            what = "%s from %s" % (name, how)
            # On and on: every key event, a press as much as a release,
            # starts the wait again. Four presses, four releases, then the
            # key once more.
            steps = [lambda n=n, send_key=send_key: send_key(press=n < 4 or n == 8, release=n >= 4) for n in range(9)]
            rid = yield from on_and_on(base + how[-1], "choose", choose, send_key, steps, what)
            if rid is None:
                continue
            yield P(0.2)
            no_answer(rid, "%s, pressed the moment a page appears, with a key event every 150 ms after it, does not answer it" % what)
            yield from settled(what)
            if not got(rid):
                key(Return if k == Space else k)
                yield from answered(rid, "%s after the pause" % name)
                expect(rid, 1 if k == Escape else 0, "a key pressed after the pause answers")
    # Clicking on and on: every click starts the wait again.
    skip = lambda: click(button("Skip"), "Skip")
    rid = yield from on_and_on("g4", "confirm", data, skip, [skip] * 5, "a click")
    if rid is not None:
        yield P(0.2)
        no_answer(rid, "a click in the moment a page appears, and a click every 150 ms after it, are dropped")
        yield from settled("a click at once")
        if not got(rid):
            click(button("Skip"), "Skip")
            yield from answered(rid, "a click after the pause")
            expect(rid, 0, "a click after the pause answers", lambda a: a == {"choice": "skip"})

    # 2. Every button has a shortcut, Alt and a letter of its label, and
    # Qt looks a key up as a shortcut before the window's own key handlers
    # are asked. Which letter a button gets is Kirigami's choice: all of
    # them are pressed.
    alt = MOD().AltModifier
    letters = [(c, getattr(K(), "Key_" + c)) for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"]

    def every_letter():
        for c, k in letters:
            typed(k, alt, c.lower())

    def every_letter_held(rid):
        """Alt and each letter in turn as a held key (a repeat), 150 ms
        apart: a shortcut holds its button down for a moment before it
        clicks, and two at once get in each other's way. A repeat is
        refused on its own, settle pause or not, so a machine that stalls
        between two of them changes nothing."""
        for c, k in letters:
            if got(rid):
                break
            typed(k, alt, c.lower(), repeat=True)
            yield P(0.15)

    def one_letter(rid, what):
        """Alt and one letter after the other, until a button answers."""
        used = None
        for c, k in letters:
            if got(rid):
                break
            typed(k, alt, c.lower())
            used = (c, k)
            yield P(0.25)       # a shortcut holds its button down for a moment, then clicks
        yield from answered(rid, what)
        check(got(rid), "%s: Alt+%s presses a button (the test's keys do reach the shortcuts)" % (what, used[0] if used else "?"))

    # Then Alt and each letter in turn, 150 ms apart: a shortcut holds its
    # button down for a moment before it clicks, and two at once get in
    # each other's way.
    rid = yield from on_and_on("g7", "confirm", data, every_letter,
                               [lambda c=c, k=k: typed(k, alt, c.lower()) for c, k in letters], "Alt+letter")
    if rid is not None:
        yield P(0.3)
        no_answer(rid, "Alt and a letter (a button's shortcut), pressed the moment a page appears and on and on after it, does not answer it")
        yield from settled("Alt+letter at once")
        yield from one_letter(rid, "Alt+letter after the pause")
    # Held down since the page before: the keyboard's first repeat can come
    # later than the settle pause after the new page appeared. The first
    # repeat is the one that counts, so it is the letter of the Skip button
    # of this very page: the desktop style marks it in the label it draws
    # ("S&kip"). Then all the letters.
    if (yield from show("g8", "confirm", data, "held Alt+letter")):
        skip = button("Skip")
        drawn = skip.property("background") if skip is not None else None
        marked = re.findall(r"&([A-Za-z])", (drawn.property("text") if drawn is not None else "") or "")
        if check(len(marked) == 1, "the Skip button shows its shortcut (Alt+%s)" % "".join(marked).upper()):
            c = marked[0].upper()
            typed(getattr(K(), "Key_" + c), alt, c.lower(), repeat=True)
            yield P(0.15)
        yield from every_letter_held("g8")
        yield P(0.3)
        no_answer("g8", "Alt and a letter held down (repeating) does not answer a page")
        yield from settled("after the held Alt+letter")
        yield from one_letter("g8", "Alt+letter let go and pressed again")
    # A button has the same Alt key on every page, also on a page that
    # follows one with the same buttons (the old page is still there, and
    # holds its letters, when the new one is made). And the main button,
    # which draws its own label, shows its key on a page that appears while
    # Alt is held, as the other buttons do.
    if (yield from show("g9", "confirm", data, "Alt keys, first page")):
        first = alt_keys()
        check(len(first) >= 3 and len(set(first.values())) == len(first) and all(t in first for t in ("Stop reviewing", "Skip", "Apply")),
              "every button of the page has an Alt key of its own: %r" % first)
        c = first.get("Skip", "S")
        k = getattr(K(), "Key_" + c)
        typed(K().Key_Alt, alt, release=False)
        typed(k, alt, c.lower(), release=False)
        yield from answered("g9", "Alt+%s, the Skip button" % c)
        ask("g10", "confirm", data)
        shown = yield W(lambda: prop("pendingId") == "g10", "Alt keys, the page after: shown")
        if not shown:
            typed(k, alt, c.lower(), press=False)
            typed(K().Key_Alt, press=False)
        else:
            yield from held(k, c.lower(), 0.5, mod=alt)
            apply_ = main_button()
            check(apply_ is not None and apply_.property("showsKey") is True,
                  "the main button of a page that appears while Alt is held shows its Alt key")
            check(alt_keys() == first, "a page that follows one with the same buttons has the same Alt keys, from the moment it appears: %r, before %r" % (alt_keys(), first))
            typed(k, alt, c.lower(), press=False)
            typed(K().Key_Alt, press=False)
            check(apply_ is not None and apply_.property("showsKey") is False, "and no longer when Alt is let go")
            yield from settled("Alt keys, the page after")
            check(alt_keys() == first, "a page that follows one with the same buttons has the same Alt keys: %r, before %r" % (alt_keys(), first))
            no_answer("g10", "the key held since the page before did not answer it")
            key(Escape)
            yield from answered("g10", "Alt keys, the page after: Esc")
        # A text too long for its lines brings a "Show all details" button:
        # it takes no letter from the buttons that are on every page.
        if (yield from show("g11", "confirm", dict(data, detail="A long line of text about this fix. " * 60), "Alt keys, a long text")):
            more = button("Show all details")
            keys = alt_keys()
            check(more is not None and "Show all details" not in keys and dict(keys) == first,
                  "a page with a \"Show all details\" button has the same Alt keys: %r, before %r" % (keys, first))
            key(Escape)
            yield from answered("g11", "Alt keys, a long text: Esc")
    # The same for what replaces a dialog: a dialog after a dialog, and a
    # page after a dialog, with the labels of that page on the dialog's
    # buttons.
    same = {"kind": "question", "title": "Go on?", "html": "Skip or apply?", "buttons": [{"label": "Skip"}, {"label": "Apply"}]}
    if (yield from show("g12", "choose", choose, "Alt keys, a page under a dialog")):
        if (yield from show("g13", "dialog", same, "Alt keys, a dialog")):
            one = alt_keys()
            check(len(one) == 2 and len(set(one.values())) == 2, "both buttons of a dialog have an Alt key of their own: %r" % one)
            if (yield from show("g14", "dialog", same, "Alt keys, a dialog after a dialog")):
                check(alt_keys() == one, "a dialog that replaces one with the same buttons has the same Alt keys: %r, before %r" % (alt_keys(), one))
                if (yield from show("g15", "confirm", data, "Alt keys, a page after a dialog")):
                    check(alt_keys() == first, "a page that replaces a dialog with its buttons' labels has its usual Alt keys: %r, usually %r" % (alt_keys(), first))
                    key(Escape)
                    yield from answered("g15", "Alt keys, a page after a dialog: Esc")

    # 3. Auto-repeat alone, handed to the window by a program (the press
    # itself was never seen here).
    for rid, k, name in (("g5", Return, "Enter"), ("g6", Escape, "Esc")):
        if not (yield from show(rid, "choose", choose, "auto-repeat %s" % name)):
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

    # 4. A key pressed on one page and held down, as the keyboard sends it:
    # still down (and repeating) when the next page appears and long after
    # its settle pause. It answers the page it was pressed on, once (Enter
    # and Esc with the press, Space on the focused button when the keyboard
    # starts to repeat), and never the next one. Choose, then Confirm, as in
    # a review of fixes; after Enter another Choose, a page Enter answers.
    for k, name, text, nxt in ((Space, "Space", " ", "confirm"), (Return, "Enter", "\r", "choose"), (Escape, "Esc", "", "confirm")):
        c, f = "gc-" + name, "gf-" + name
        if not (yield from show(c, "choose", choose, "held %s: the page before" % name)):
            continue
        first = main_button()
        if first is None:
            continue
        tab_to(first)
        typed(k, text=text, release=False)
        yield from held(k, text, 1.0, lambda: got(c))
        yield from held(k, text, 0.25)      # more repeats, on the page that has answered
        if not check(got(c), "%s held down: the page it was pressed on is answered" % name):
            typed(k, text=text, press=False)
            continue
        ask(f, nxt, SAMPLES[nxt])           # the next page comes while the key is down
        yield from held(k, text, 6.0, lambda: got(f) or prop("pendingId") == f)
        if not check(prop("pendingId") == f or got(f), "held %s: the next page is shown" % name):
            typed(k, text=text, press=False)
            continue
        yield from held(k, text, 1.5)       # four times the settle pause
        no_answer(f, "%s held down since the page before does not answer the new page, however long" % name)
        typed(k, text=text, press=False)
        yield P(0.2)
        no_answer(f, "letting go of %s does not answer it either" % name)
        expect(c, 1 if k == Escape else 0, "%s held down answered the page it was pressed on once" % name,
               lambda a: a == CHOOSE_ENTER)
        yield from settled("after the held " + name)
        if got(f):
            continue
        # Pressed again on purpose, the key works.
        if k == Space:
            typed(Space, text=" ")
            yield P(0.3)
            no_answer(f, "Space with the focus on no button answers nothing")
            for _ in range(12):
                if is_main(shell.activeFocusItem()):
                    break
                typed(Tab)
                yield P(0.03)
            check(is_main(shell.activeFocusItem()), "Tab reaches Apply (the focus is on: %s)" % focus_text())
            typed(Space, text=" ")
        else:
            typed(k, text=text)
        yield from answered(f, "%s pressed again" % name)
        if k == Escape:
            expect(f, 1, "Esc let go and pressed again cancels")
        else:
            expect(f, 0, "%s let go and pressed again answers" % name, lambda a: a == ({"choice": "apply"} if k == Space else CHOOSE_ENTER))

    # 5. Space starts to repeat on a button with the keyboard focus (held
    # since the page before: the press was not seen here). The page takes
    # no input until the key is up, then the focus is back on that button.
    # As the keyboard sends it where only the press repeats, and as a
    # program hands it to the window (release and press, never announced).
    for how in ("the keyboard", "a program"):
        rid = "gh" + how[-1]
        if not (yield from show(rid, "choose", choose, "Space repeats on a button")):
            continue
        b = main_button()
        if b is None:
            continue
        tab_to(b)
        yield P(0.05)
        for _ in range(3):
            if how == "a program":
                key_event(False, Space, " ", True)
                key_event(True, Space, " ", True)
            else:
                typed(Space, text=" ", release=False, repeat=True)
            yield P(0.03)
        if how == "a program":
            key_event(False, Space, " ")
        else:
            typed(Space, text=" ", press=False)
        yield P(0.3)
        no_answer(rid, "Space repeating on the focused button (from %s) and then let go does not press it" % how)
        yield from settled("after Space repeated")
        check(shell.activeFocusItem() == b and b.property("visualFocus") is True,
              "after that, the keyboard focus is back on the button, with its ring (it is on: %s)" % focus_text())
        if not got(rid):
            typed(Space, text=" ")
            yield from answered(rid, "Space pressed once")
            expect(rid, 0, "Space pressed once on the button presses it", lambda a: a == CHOOSE_ENTER)

    # 6. A page that has answered takes nothing more: not a second press of
    # its button with Space, not a click.
    if (yield from show("ga", "choose", choose, "a page that has answered")):
        b = main_button()
        point = scene_point(b) if b is not None else None
        if check(point is not None, "the main button is on screen"):
            tab_to(b)
            typed(Space, text=" ")
            check(prop("pendingId") == "", "Space on the main button answers the page")
            typed(Space, text=" ")
            mouse_at(point, release=False)
            check(b.property("pressed") is False or prop("busyShown") is True,
                  "a mouse button pressed on the button of a page that has answered does not press it")
            mouse_at(point, press=False)
    yield from answered("ga", "a page that has answered")
    yield P(0.3)
    expect("ga", 0, "Space again and a click on a page that has answered: still the one answer", lambda a: a == CHOOSE_ENTER)

    # 7. The mouse button held down on the page before and let go on the new one.
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

    # Enter and Esc with Ctrl, Shift, Alt or Meta are other keys; the Enter
    # of the number block is Enter. Keys that scroll do nothing on a page
    # that names nothing to scroll.
    mods = MOD()
    if (yield from show("k4", "wizard", {"n": 4}, "stub page 4")):
        for name, mod in (("Ctrl", mods.ControlModifier), ("Shift", mods.ShiftModifier), ("Alt", mods.AltModifier),
                          ("Meta", mods.MetaModifier)):
            typed(Return, mod, "\r")
            typed(Escape, mod)
            yield P(0.2)
            check(not got("k4"), "%s+Enter and %s+Esc do not answer the page" % (name, name))
        for k in (K().Key_PageDown, K().Key_End, K().Key_Down, K().Key_Up, K().Key_Home, K().Key_PageUp):
            typed(k)
        yield P(0.2)
        check(not got("k4"), "the keys that scroll do nothing on a page without a scrollArea")
        typed(K().Key_Enter, mods.KeypadModifier, "\r")
    yield from answered("k4", "Enter of the number block")
    expect("k4", 0, "the Enter key of the number block is the page's primary()", lambda a: a.get("via") == "primary")

    yield from keys_scroll()
    no_warnings("the whole scenario")
    send({"quit": True})


def keys_scroll():
    """PageUp, PageDown, Home, End and the arrow keys scroll what the page
    names as its scrollArea, between its two ends; a dialog over the page
    is scrolled instead of the page; a control that uses a key itself
    keeps it (stub pages)."""
    Key = K()

    def moves(page, what, k, test, how):
        before = scroll_y(page)
        typed(k)
        yield P(0.05)
        now = scroll_y(page)
        try:
            ok = bool(test(before[0], now[0], now[1]))
        except Exception:
            ok = False
        check(ok, "%s: %s (from %d to %d of %d)" % (what, how, before[0], now[0], now[1]))

    def all_keys(page, what, view):
        near = lambda a, b: abs(a - b) < 1.5
        yield from moves(page, what, Key.Key_PageDown, lambda a, b, m: near(b - a, view * 0.9), "PageDown goes down by most of what is seen")
        yield from moves(page, what, Key.Key_Down, lambda a, b, m: 0 < b - a < view / 2, "Down goes down a little")
        yield from moves(page, what, Key.Key_Up, lambda a, b, m: 0 < a - b < view / 2, "Up goes up as much")
        yield from moves(page, what, Key.Key_PageUp, lambda a, b, m: near(b, 0), "PageUp goes back up")
        yield from moves(page, what, Key.Key_PageUp, lambda a, b, m: near(b, 0), "PageUp at the top stays there")
        yield from moves(page, what, Key.Key_Up, lambda a, b, m: near(b, 0), "Up at the top stays there")
        yield from moves(page, what, Key.Key_End, lambda a, b, m: m > view and near(b, m), "End goes to the end")
        yield from moves(page, what, Key.Key_PageDown, lambda a, b, m: near(b, m), "PageDown at the end stays there")
        yield from moves(page, what, Key.Key_Down, lambda a, b, m: near(b, m), "Down at the end stays there")
        yield from moves(page, what, Key.Key_Up, lambda a, b, m: 0 < a - b < view / 2, "Up leaves the end")
        yield from moves(page, what, Key.Key_Home, lambda a, b, m: near(b, 0), "Home goes to the top")

    if not (yield from show("k5", "check", {}, "scroll stub")):
        return
    page = prop("pageItem")
    yield from all_keys(page, "a page", page.height())
    # A closed combo box takes Down for itself: the page stays.
    combo = focus("combo")
    yield P(0.05)
    yield from moves(page, "a page", Key.Key_Down, lambda a, b, m: b == a, "Down on a combo box does not scroll")
    check(combo is not None and combo.property("currentIndex") == 1, "Down on a combo box goes to its next entry")
    yield from moves(page, "a page", Key.Key_PageDown, lambda a, b, m: b > a, "PageDown on a combo box scrolls")
    at = scroll_y(page)[0]

    # A dialog over the page: the dialog is what scrolls.
    if (yield from show("k6", "dialog", {}, "scroll stub dialog")):
        expect("k5", 1, "the page under the dialog was answered \"cancelled\"")
        dialog = prop("dialogItem")
        if check(dialog is not None and dialog is not page, "the dialog is over the page"):
            yield from all_keys(dialog, "a dialog over a page", dialog.height())
            typed(Key.Key_End)
            yield P(0.05)
            check(scroll_y(page)[0] == at, "a dialog over a page: the page under it did not move")
        typed(Key.Key_Escape)
    yield from answered("k6", "scroll stub dialog")
    # A dialog that names nothing to scroll: the page under it stays.
    if (yield from show("k7", "dialog", {"plain": True}, "plain stub dialog")):
        for k in (Key.Key_PageUp, Key.Key_Home, Key.Key_Up):
            typed(k)
        yield P(0.05)
        check(got("k7") is False and scroll_y(page)[0] == at, "a dialog with a scrollArea of null: the keys that scroll do nothing")
        typed(Key.Key_Escape)
    yield from answered("k7", "plain stub dialog")


# What Enter answers on the Choose page with its sample: the ticked rows.
# (The scenarios about ui/app.py use this page where they only need "a page
# that is shown and answered".)
CHOOSE_ENTER = {"tags": ["a", "b"]}

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
# JSON that Python's parser gives up on with a RecursionError, which is not
# a ValueError as for every other line that is not JSON: lists nested deeper
# than it takes.
DEEP = 200000
DEEP_LINE = '{"id":"m10","mode":"confirm","data":' + "[" * DEEP + "]" * DEEP + "}"
BAD_LINES.append(("JSON nested %d deep" % DEEP, DEEP_LINE, [""]))


def pipe_room():
    """How many bytes the request pipe of this test takes in one write."""
    try:
        import fcntl
        return fcntl.fcntl(req_w, fcntl.F_GETPIPE_SZ)
    except (ImportError, AttributeError, OSError):
        return 65536


def deep_line_fits():
    """DEEP_LINE is what it is meant to be here (a check: a test that cannot
    do its work fails, it is not skipped)."""
    try:
        json.loads(DEEP_LINE)
        error = "none"
    except Exception as e:
        error = type(e).__name__
    ok = check(error == "RecursionError", "JSON nested %d deep is a RecursionError for this Python's parser (it is: %s; "
               "if not, DEEP in the test must grow)" % (DEEP, error))
    return ok


def sc_malformed():
    """Lines that are not requests: each gets exactly one answer line with
    status 3 (the root side then stops using the front end), never silence."""
    Return = K().Key_Return
    # What the front end itself logs about a bad line is not a QML warning.
    allowed.append(re.compile(r"^(?!.*(qml|QML|Binding loop)).*$"))
    for n, (what, line, ids) in enumerate(BAD_LINES):
        before = len(replies) if n else 0       # the first one was sent before the front end started
        if line is DEEP_LINE and not deep_line_fits():
            continue
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
    if (yield from show("m9", "choose", SAMPLES["choose"], "a page after the bad lines")):
        key(Return)
    yield from answered("m9", "a page after the bad lines")
    expect("m9", 0, "a page after the bad lines is shown and answered", lambda a: a == CHOOSE_ENTER)
    no_warnings("the whole scenario")
    send({"quit": True})


def sc_broken():
    """Page files that do not load, or are not pages: status 3, and the
    window goes on."""
    Return = K().Key_Return
    allowed.extend(re.compile(p) for p in (
        r"Security Check: ", r"Check\.qml", r"Confirm\.qml", r"Choose\.qml", r"Dialog\.qml", r"Settings\.qml",
        r"NoSuchComponent", r"^\s+\^|^\s+this is not QML|^\s+NoSuch"))
    # The Shell refuses a file in three places: it does not load, it is not
    # a page, or setting it up fails (the catch in showRequest()). Each
    # says so in its own words, which is how the test tells them apart.
    for rid, mode, what, why in (("b1", "check", "a page file with a syntax error", "cannot load "),
                                 ("b2", "confirm", "a page that uses a component that does not exist", "cannot load "),
                                 ("b3", "choose", "a file that is not an Item", "Choose.qml is not a page"),
                                 ("b4", "settings", "an Item without finished() and cancelled()", "Settings.qml is not a page"),
                                 ("b6", "dialog", "a dialog the Shell fails to set up", "cannot show ")):
        seen = len(stderr_text())
        ask(rid, mode, {"title": "t"})
        yield from answered(rid, what, 5.0)
        expect(rid, 3, what + ": status 3")
        said = [line for line in stderr_text()[seen:].splitlines() if "Security Check: " in line]
        check(len(said) == 1 and why in said[0], "%s: the Shell says why (\"%s…\"): %s" % (what, why, cut(" | ".join(said))))
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
    # The same dialog over a page. Nothing of either is left in the window,
    # unseen: not the one that was to be the whole content, not this one.
    if (yield from show("b7", "wizard", {"n": 7}, "a page for the dialog")):
        ask("b8", "dialog", {"title": "t"})
        yield from answered("b8", "a dialog over a page that the Shell fails to set up", 5.0)
        expect("b8", 3, "a dialog over a page that the Shell fails to set up: status 3")
        expect("b7", 1, "the page under it was answered \"cancelled\" first")
        check(prop("dialogItem") is None and prop("dialogSlot") is None, "no dialog is over the page")
        yield P(0.3)
        left = [i for i in items_under(shell.contentItem()) if i.objectName() == "cannot-be-set-up"]
        check(not left, "nothing of the dialogs that could not be set up is left in the window (%d found)" % len(left))
    if (yield from show("b9", "wizard", {"n": 9}, "the next page")):
        click(button("Other"), "the page's second button")
    yield from answered("b9", "a click on the next page")
    expect("b9", 0, "the next page takes a click on its button", lambda a: a == {"via": "button"})
    w = new_warnings()
    check(not w, "only the expected warnings to the end%s" % ("" if not w else ": " + cut(" | ".join(w[:2]), 300)))
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
    if (yield from show("e0", "choose", SAMPLES["choose"], "a page first")):
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
    if (yield from show("e2", "choose", SAMPLES["choose"], "the next request")):
        key(Return)
    yield from answered("e2", "the next request")
    expect("e2", 0, "the front end still serves the next request", lambda a: a == CHOOSE_ENTER)
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
        # Nothing but the answer may be printed on the real stdout.
        print_noise()
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


# ---- ui/app.py itself: what no page and no key press shows ---------------------
NOISE_LINE = "a library printed this on stdout"
# A page whose answer is not JSON, for "odd-answer" and "oneshot-odd".
STUB_ODD = """// Test stub: a page that answers with what its input asks for.
import QtQuick
Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: "Odd answer"
    signal finished(var answer)
    signal cancelled()
    function primary() {
        var w = input.what
        finished(w === "date" ? { "when": new Date(0) } : w === "nan" ? { "n": 0 / 0 }
                 : w === "inf" ? { "n": 1 / 0 } : { "ok": true })
    }
    function dismiss() { cancelled() }
}
"""
STUBS_ODD = {"Wizard.qml": STUB_ODD}


def print_noise():
    """What a library does when it prints on stdout: a line on descriptor 1
    of the front end's process (which is this one)."""
    allowed.append(re.compile("^" + re.escape(NOISE_LINE) + "$"))
    os.write(1, (NOISE_LINE + "\n").encode())


def sc_serve_edge():
    """What ui/app.py does with its own descriptors, with an empty busy
    label and with progress lines that are not what they should be."""
    Return = K().Key_Return
    # 1. the first line was {"busy": ""}: it asks for nothing to be shown
    yield P(0.4)
    check(not shell.isVisible() and prop("busyShown") is not True and not replies,
          "busy \"\" as the first line: no window, no spinner, no answer line")
    # 2. stdout is not the answer pipe, stdin is not the request pipe
    print_noise()
    yield P(0.2)
    pump()
    check(not replies, "a line printed on stdout is not among the answers: %s" % cut(replies))
    check(NOISE_LINE in stderr_text(), "it went to stderr (the run log) instead")
    try:
        nothing = os.read(0, 16)
    except OSError as e:
        nothing = repr(e)
    check(nothing == b"", "stdin is no longer the request pipe: reading it gives %r" % (nothing,))
    # 3. a window the person closed: busy "" leaves it closed, a label brings it back
    if (yield from show("v1", "choose", SAMPLES["choose"], "a page")):
        key(Return)
    yield from answered("v1", "a page")
    yield W(lambda: prop("busyShown") is True, "after the answer: busy")
    shell.close()
    yield W(lambda: not shell.isVisible(), "the close button with nothing to answer: the window hides")
    n = len(replies)
    send({"busy": ""})
    yield P(0.4)
    check(not shell.isVisible() and len(replies) == n, "busy \"\" does not bring a closed window back")
    send({"busy": "Applying a fix…"})
    yield W(lambda: shell.isVisible() and prop("busyLabel") == "Applying a fix…", "a busy label does bring it back")
    # A label that is not a string says nothing.
    send({"busy": 7})
    send({"busy": None})
    yield P(0.3)
    check(prop("busyLabel") == "Applying a fix…" and len(replies) == n, "a busy label that is not a string changes nothing")
    # 4. progress lines
    send({"progress": "start", "heading": "Checking your PC"})
    yield W(lambda: progress_window() is not None and progress_window().isVisible() and not shell.isVisible(), "progress start: the progress window")
    pw = progress_window()
    if pw is not None:
        for n_line, (pct, want) in enumerate((("100", 100), ("101", -1), ("150", -1), ("1000", -1), ("007", 7), ("0", 0),
                                              ("-5", -1), ("5.5", -1), ("٣", -1), ("", -1), ("0100", -1), ("9" * 5000, -1))):
            label = "Step %d" % n_line
            send({"progress": "set", "line": "%s\t0\t%s\t" % (pct, label)})
            ok = yield W(lambda: pw.property("label") == label, "progress line with percent %s: shown" % cut(pct, 12), 3.0)
            if ok:
                check(pw.property("percent") == want, "progress line with percent %s: the window shows %r (%r expected)"
                      % (cut(pct, 12), pw.property("percent"), want))
        check(len(replies) == n, "none of these progress lines was answered (status 3 would end the front end's use): %s" % cut(replies[n:]))
        send({"progress": "set", "line": 5})
        send({"progress": "set"})
        send({"progress": "no-such-step"})
        send({"progress": "set", "line": "50\t0\t" + "x" * 500 + "\t" + "y" * 500})
        yield W(lambda: pw.property("percent") == 50, "a progress line with long texts: shown")
        check(len(pw.property("label")) == 160 and len(pw.property("detail")) == 300,
              "a progress line with long texts: label cut to %d, detail to %d characters" % (len(pw.property("label")), len(pw.property("detail"))))
        # 5. busy "" while the progress window shows closes it; the main window is back
        n = len(replies)
        send({"busy": ""})
        yield W(lambda: not pw.isVisible() and shell.isVisible(), "busy \"\" after a scan: the progress window closes, the main window is back")
        check(prop("busyLabel") == "" and len(replies) == n, "busy \"\" after a scan: the usual label, no answer line")
    no_warnings("the whole scenario")
    send({"quit": True})


def prepare_no_progress():
    """Progress.qml cannot be loaded (say, a file missing from the installed
    copy). It is never taken from PAGE_DIR, so the test stands in the way of
    the one function that loads it."""
    load = appmod._Ui.load
    appmod._Ui.load = lambda self, name, properties: None if name == "Progress.qml" else load(self, name, properties)


def sc_no_progress_window():
    """The scan when the progress window cannot be made: the main window's
    spinner shows the progress labels, and nothing fails."""
    Return = K().Key_Return
    send({"progress": "start", "heading": "Checking your PC"})
    yield P(0.4)
    check(progress_window() is None and not replies, "progress start without a progress window: none, and no answer line")
    send({"progress": "set", "line": "45\t0\tFirewall\t"})
    yield W(lambda: shell.isVisible() and prop("busyShown") is True and prop("busyLabel") == "Firewall",
            "progress set without a progress window: the main window's spinner says \"Firewall\"")
    send({"progress": "set", "line": "-\t1\tMalware scan\tThis can take several minutes."})
    yield W(lambda: prop("busyLabel") == "Malware scan", "the next progress line: the spinner says \"Malware scan\"")
    send({"progress": "stop"})
    if (yield from show("n1", "choose", SAMPLES["choose"], "a page after the scan")):
        check(prop("busyShown") is False, "a page after the scan: no longer busy")
        key(Return)
    yield from answered("n1", "a page after the scan")
    expect("n1", 0, "a page after the scan is shown and answered", lambda a: a == CHOOSE_ENTER)
    check(len(replies) == 1, "nothing else was answered: %s" % cut(replies))
    no_warnings("the whole scenario")
    send({"quit": True})


def sc_odd_answer():
    """A page whose answer cannot be written as JSON: status 3 (the root
    side falls back), never silence and never a line that is not JSON."""
    Return = K().Key_Return
    allowed.append(re.compile(r"^app\.py: the answer of "))
    for rid, what, name in (("o1", "date", "a date"), ("o2", "nan", "not-a-number"), ("o3", "inf", "infinity")):
        if (yield from show(rid, "wizard", {"what": what}, "an answer with " + name)):
            key(Return)
        yield from answered(rid, "an answer with " + name)
        expect(rid, 3, "an answer with %s: status 3" % name)
    check("app.py: the answer of o1 is not JSON" in stderr_text(), "the reason is written to stderr")
    if (yield from show("o4", "wizard", {}, "the next page")):
        key(Return)
    yield from answered("o4", "the next page")
    expect("o4", 0, "the next page is shown and answered", lambda a: a == {"ok": True})
    no_warnings("the whole scenario")
    send({"quit": True})


def sc_oneshot_odd():
    allowed.append(re.compile(r"^app\.py: the answer of "))
    yield W(lambda: shell.isVisible() and prop("pendingId") != "", "the page is shown")
    yield from settled("app.py wizard")
    key(K().Key_Return)


def first_lines(*lines):
    """Several lines for the front end in ONE write, made before it starts:
    it reads them together with the first one."""
    def text():
        out = "\n".join(json.dumps(line() if callable(line) else line) for line in lines)
        if len(out) >= 4096:
            raise RuntimeError("these lines are too long to arrive in one read")
        return out
    return text


def sc_first_lines():
    """Lines that arrive in the same read as the first one are handled too,
    in their order: a busy label and two requests, written at once."""
    Return = K().Key_Return
    yield W(lambda: got("f1") and prop("pendingId") == "f2" and shell.isVisible(),
            "three lines written at once before the front end started: the last request is shown")
    expect("f1", 1, "the request before it was answered \"cancelled\"")
    yield from settled("the last request")
    key(Return)
    yield from answered("f2", "the last request")
    expect("f2", 0, "the last request is answered", lambda a: a == CHOOSE_ENTER)
    check(len(replies) == 2, "two answer lines for the two requests: %s" % cut(replies))
    no_warnings("the whole scenario")
    send({"quit": True})


def sc_deep_first():
    """The first line is JSON nested too deep for the parser: one answer
    with status 3, and the front end goes on."""
    Return = K().Key_Return
    # What the front end itself logs about a bad line is not a QML warning.
    allowed.append(re.compile(r"^(?!.*(qml|QML|Binding loop)).*$"))
    if deep_line_fits():
        yield W(lambda: (pump(), len(replies) > 0)[1], "JSON nested too deep as the first line: answered", 5.0)
        check(replies == ['{"id":"","status":3,"answer":null}'], "JSON nested too deep as the first line: one answer line, status 3: %s"
              % cut(" | ".join(replies)))
    if (yield from show("p1", "choose", SAMPLES["choose"], "a page after it")):
        key(Return)
    yield from answered("p1", "a page after it")
    expect("p1", 0, "a page after it is shown and answered", lambda a: a == CHOOSE_ENTER)
    no_warnings("the whole scenario")
    send({"quit": True})


def sc_answer_closed():
    """The root side no longer reads the answers (that pipe is closed at
    its end) while the request pipe stays open: an answer cannot be
    written, and the front end leaves instead of going on unheard."""
    global rep_r
    yield W(lambda: prop("pendingId") == "x1" and shell.isVisible(), "page shown")
    yield from settled("page shown")
    os.close(rep_r)
    rep_r = -1
    key(K().Key_Escape)
    check(prop("pendingId") == "", "Esc answers the page, with nobody to read the answer")


def after_answer_closed(rc):
    check(rc == 0 and not replies, "an answer that cannot be written: app.py serve ended by itself, with status %r (0 expected)" % (rc,))
    no_warnings("the answer pipe closed")


def after_crash(rc):
    """ui/app.py as a program of its own, started without a stdin: main()
    fails at its first step. (The other scenarios call main() and never
    get to the lines below it.)"""
    status, out, err = "not run", b"", ""
    try:
        p = subprocess.run(["/bin/sh", "-c", 'exec "$0" -I "$1" serve <&-', sys.executable, APP],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        status, out, err = p.returncode, p.stdout, p.stderr.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired) as e:
        status = repr(e)
    check(status == 3 and out == b"", "app.py that fails with an exception ends with status %r (3: \"cannot run here\"; 1 would be "
          "\"cancelled\"), nothing printed" % (status,))
    check("Traceback (most recent call last)" in err and "OSError" in err, "the exception is written to stderr: %s" % cut(err.strip().splitlines()[-1:]))


# A page with text fields: two that can be edited (the one-line field takes
# Enter as "done") and one that cannot. It asks for the keyboard focus on
# the field its input names.
STUB_TYPING = """// Test stub: a page with text fields.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
Item {
    id: page
    required property var input
    property string iconSource: ""
    readonly property string title: "Typing stub"
    signal finished(var answer)
    signal cancelled()
    function primary() { finished({ "via": "primary" }) }
    function dismiss() { cancelled() }
    function initialFocus() { return input.start === "field" ? field : input.start === "area" ? area : null }
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        QQC2.TextField { id: field; objectName: "field"; Layout.fillWidth: true; onAccepted: page.finished({ "via": "field" }) }
        QQC2.TextArea { id: area; objectName: "area"; Layout.fillWidth: true }
        QQC2.TextArea { objectName: "fixed"; Layout.fillWidth: true; readOnly: true; text: "fixed" }
        QQC2.Button { objectName: "other"; text: "Other"; onClicked: page.finished({ "via": "button" }) }
        Item { Layout.fillHeight: true }
    }
}
"""
STUBS_TYPING = {"Wizard.qml": STUB_TYPING}


def sc_typing():
    """A key held down in a text field that can be edited types, as in any
    text field: the guard against held keys (Shell.qml: hold()) leaves it
    alone, and it answers nothing. Every key that does not type there is
    still refused while it repeats."""
    Key, alt = K(), MOD().AltModifier
    Return, Escape, Space, A = Key.Key_Return, Key.Key_Escape, Key.Key_Space, Key.Key_A

    def named(name):
        for item in items_under(page_root()):
            if item.objectName() == name:
                return item
        check(False, "the stub page has an item named %s" % name)
        return None

    def quiet(rid, item, what):
        """The page is as it was: not answered, taking input, the focus still in ITEM."""
        return check(not got(rid) and prop("settling") is False and shell.activeFocusItem() == item,
                     "%s: no answer, the page still takes input and the focus stays in the field (answered: %r, settling: %r, focus: %s)"
                     % (what, got(rid), prop("settling"), focus_text()))

    # 1. Space and Enter held down where they type. As the keyboard sends
    # the events, and as a program hands them to the window.
    for how in ("the keyboard", "a program"):
        rid = "t1" + how[-1]
        if not (yield from show(rid, "wizard", {}, "typing (%s)" % how)):
            continue
        if how == "the keyboard":
            down = lambda k, text: typed(k, text=text, release=False)
            up = lambda k, text: typed(k, text=text, press=False)
            repeats = held
        else:
            down = lambda k, text: key_event(True, k, text)
            up = lambda k, text: key_event(False, k, text)
            repeats = hold
        for name, k, text, word in (("field", Space, " ", "Space"), ("area", Space, " ", "Space"), ("area", Return, "\r", "Enter")):
            item = named(name)
            if item is None:
                continue
            item.setProperty("text", "")
            item.forceActiveFocus()
            yield P(0.05)
            down(A, "a")
            up(A, "a")
            down(k, text)
            yield from repeats(k, text, 0.6)
            now = item.property("text")
            what = "%s held down in a text %s (from %s)" % (word, name, how)
            quiet(rid, item, what)
            up(k, text)
            yield P(0.1)
            check(re.fullmatch("a[ \n]{4,}", now) is not None and set(now[1:]) == {" " if k == Space else "\n"},
                  "%s types with every repeat: the field holds %r" % (what, cut(now, 40)))
            quiet(rid, item, what + ", let go")
        # 2. What does not type is refused while it repeats, in a text
        # field as anywhere else (the press itself was not seen here: held
        # since the page before).
        for name, k, mod, text, word in (("fixed", Space, None, " ", "Space in a text area that is read-only"),
                                         ("field", Return, None, "\r", "Enter in a one-line field (which takes Enter as \"done\")"),
                                         ("field", Escape, None, "", "Esc in a one-line field"),
                                         ("area", Escape, None, "", "Esc in a text area"),
                                         ("area", Key.Key_O, alt, "o", "Alt+O (the shortcut of a button) in a text area"),
                                         ("area", Space, alt, " ", "Alt+Space in a text area")):
            item = named(name)
            if item is None or got(rid) or (mod is not None and how != "the keyboard"):
                continue                    # a shortcut is the keyboard's alone
            item.forceActiveFocus()
            yield P(0.05)
            before = item.property("text")
            for _ in range(3):
                if how == "the keyboard":
                    typed(k, mod, text, release=False, repeat=True)
                else:
                    key_event(False, k, text, True)
                    key_event(True, k, text, True)
                yield P(0.03)
            check(not got(rid) and prop("settling") is True and item.property("text") == before,
                  "%s, repeating (from %s): refused, the page takes no input until the key is up (answered: %r, settling: %r)"
                  % (word, how, got(rid), prop("settling")))
            yield from settled("after " + word)
            check(shell.activeFocusItem() == item, "after that the keyboard focus is back in the field (it is on: %s)" % focus_text())
        # Pressed once, Enter is the one-line field's own.
        if not got(rid):
            field = named("field")
            field.forceActiveFocus()
            yield P(0.05)
            down(Return, "\r")
            up(Return, "\r")
        yield from answered(rid, "Enter pressed once in the one-line field")
        expect(rid, 0, "Enter pressed once in the one-line field is the field's", lambda a: a == {"via": "field"})

    # 3. A key held since the page before, on a page that puts the
    # keyboard focus in a text field by itself: Space only types there,
    # Esc and Enter answer nothing.
    for start, k, text, word in (("area", Space, " ", "Space"), ("field", Return, "\r", "Enter"), ("area", Escape, "", "Esc")):
        rid = "t3" + word
        if not (yield from show(rid, "wizard", {"start": start}, "a page that starts in a text field")):
            continue
        item = named(start)
        check(shell.activeFocusItem() == item, "the page starts with the keyboard focus in its text %s (it is on: %s)" % (start, focus_text()))
        for _ in range(3):
            typed(k, text=text, release=False, repeat=True)
            yield P(0.03)
        yield P(0.2)
        check(not got(rid), "%s held since the page before, repeating in the text %s the page starts in, does not answer it" % (word, start))
        if k == Space:
            check(item.property("text") == "   ", "it types there: the field holds %r" % cut(item.property("text"), 40))
        typed(k, text=text, press=False)
        yield from settled("after " + word)
        if not got(rid):
            typed(Escape)
        yield from answered(rid, "Esc pressed once")
        expect(rid, 1, "Esc pressed once cancels")
    no_warnings("the whole scenario")
    send({"quit": True})


def sc_parent_gone():
    """The process that started the front end (runuser) is gone: the kernel
    hands the front end to another parent. Nothing else tells it here: no
    BSA_OWNER_PID, no "quit", no end of input."""
    global owner_killed
    yield W(lambda: prop("pendingId") == "x1" and shell.isVisible(), "page shown")
    yield from settled("page shown")
    real = os.getppid()
    if not check(appmod._Owner().pid is None and real > 1, "only the parent process is watched (no BSA_OWNER_PID), parent %d" % real):
        return send({"quit": True})
    # This test cannot end its own parent, so it makes the question "who is
    # my parent?" give the answer it gives after that: another process.
    os.getppid = lambda: 1
    owner_killed = time.monotonic()


def after_parent_gone(rc):
    took = time.monotonic() - owner_killed if owner_killed else -1
    check(rc == 0 and 0 <= took < 6, "the parent process changed: app.py serve ended with status %r, %.1f s later "
          "(checked every %.0f s)" % (rc, took, appmod.OWNER_CHECK_MS / 1000))
    line, p = reply_for("x1")
    check(line is None or (p[1] == 1 and p[2] is None), "the waiting request got no answer line, or \"cancelled\": %s" % cut(line))
    no_warnings("parent gone")


def sc_variants():
    """The inputs that change what Enter means: a dashboard in a report-only
    run, and dialogs whose main button is not the last one (a warning's
    main button is the safe answer)."""
    Return, Escape, Space = K().Key_Return, K().Key_Escape, K().Key_Space
    S = SAMPLES

    def texts():
        return [str(i.property("text") or "") for i in items_under(page_root()) if i.isVisible()]

    # 1. the dashboard of a run that changes nothing
    data = S["dashboard-report-only"]
    if (yield from show("r1", "dashboard", data, "dashboard, report only")):
        check(data["nfix"] > 0 and data["report_only"] is True, "the sample has fixes on offer and says \"report only\"")
        check(any("Report only" in t for t in texts()), "dashboard, report only: the page says that nothing will be changed")
        check(any("/var/lib/bazzite-sec-audit/reports" in t for t in texts()), "dashboard, report only: the note about the report is shown")
        shot("variants-dashboard-report-only")
        no_warnings("dashboard, report only")
        key(Return)
    yield from answered("r1", "dashboard, report only")
    expect("r1", 0, "dashboard, report only: Enter finishes, it does not go on to the fixes", lambda a: a == {"action": "finish"})
    if (yield from show("r2", "dashboard", dict(data, report_only=False), "the same dashboard, fixes allowed")):
        check(not any("Report only" in t for t in texts()), "the same dashboard, fixes allowed: no \"report only\" message")
        key(Return)
    yield from answered("r2", "the same dashboard, fixes allowed")
    expect("r2", 0, "the same dashboard, fixes allowed: Enter goes on to the fixes", lambda a: a == {"action": "fix"})

    # 2. dialogs: which button is the main one, has the focus and gets Enter
    cases = (
        # what, sample, the main button's number (None: there is none)
        ("a warning, main button 0 (\"No\")", "dialog-warning", 0),
        ("two buttons, main button 1", "dialog", 1),
        ("three buttons, main button 1 (the middle one)", "dialog-three", 1),
        ("main button -1 (none)", "dialog-no-main", None),
        ("no \"primary\" in the input", "dialog-no-primary", len(S["dialog-no-primary"]["buttons"]) - 1),
        ("one button", "dialog-message", 0),
        ("a list to pick from", "dialog-list", 1),
    )
    check(S["dialog-warning"]["primary"] == 0 and S["dialog"]["primary"] == 1 and S["dialog-three"]["primary"] == 1
          and S["dialog-no-main"]["primary"] == -1 and "primary" not in S["dialog-no-primary"],
          "the samples have \"primary\" 0, 1, -1 and none")
    for n, (what, sample, main) in enumerate(cases):
        data, rid = S[sample], "p%d" % n
        labels = [b["label"] for b in data["buttons"]]
        tag = {"tag": data["items"][0]["tag"]} if data["items"] else {}
        if (yield from show(rid, "dialog", data, what)):
            drawn = [b.property("text") for b in controls() if b.property("text") in labels]
            mains = [b.property("text") for b in controls() if is_main(b)]
            check(drawn == labels, "%s: the buttons are %r, left to right" % (what, drawn))
            check(mains == ([labels[main]] if main is not None else []), "%s: the filled main button is %r" % (what, mains))
            f = shell.activeFocusItem()
            if data["items"]:
                check(f is not None and f.property("checked") is True, "%s: the keyboard focus is on the picked row" % what)
            elif main is not None:
                check(is_main(f) and f.property("text") == labels[main], "%s: the keyboard focus is on the main button (%s)" % (what, focus_text()))
            else:
                check(f is None or f.property("text") not in labels, "%s: the keyboard focus is on no button (%s)" % (what, focus_text()))
            no_warnings(what)
            key(Return)
            if main is None:
                yield P(0.5)
                check(not got(rid), "%s: Enter answers nothing" % what)
                key(Escape)
        yield from answered(rid, what)
        if main is None:
            expect(rid, 1, "%s: Esc still cancels" % what)
        else:
            expect(rid, 0, "%s: Enter means button %d" % (what, main), lambda a: a == dict(tag, button=main))
    # Space, on the dialog as it comes up: the button that has the focus.
    for rid, what, sample, want in (("q1", "a warning", "dialog-warning", 0), ("q2", "no main button", "dialog-no-main", None)):
        if (yield from show(rid, "dialog", S[sample], what + ", Space")):
            key(Space, text=" ")
            if want is None:
                yield P(0.5)
                check(not got(rid), "%s: Space on the dialog as it comes up answers nothing" % what)
                click(button(S[sample]["buttons"][1]["label"]), "the second button")
        yield from answered(rid, what + ", Space")
        expect(rid, 0, "%s: %s" % (what, "Space means button 0, the safe one" if want is not None else "a click on the second button answers"),
               lambda a: a == {"button": 1 if want is None else want})
    # A number that is no button's: no main button, Enter answers nothing.
    for rid, value in (("u1", 2), ("u2", 99), ("u3", -7)):
        what = "\"primary\" %d with two buttons" % value
        if (yield from show(rid, "dialog", dict(S["dialog-warning"], primary=value), what)):
            check(not [b for b in controls() if is_main(b)], "%s: no main button" % what)
            key(Return)
            yield P(0.4)
            check(not got(rid), "%s: Enter answers nothing" % what)
            key(Escape)
        yield from answered(rid, what)
        expect(rid, 1, "%s: Esc cancels" % what)
    no_warnings("the whole scenario")
    send({"quit": True})


# ---- what stays in view, what can be seen, what fits -------------------------
def scene_rect(item):
    """ITEM as a rectangle in its window."""
    from PySide6.QtCore import QRectF
    return item.mapRectToScene(QRectF(0, 0, item.width(), item.height()))


def shown_rect(item):
    """The part of ITEM (an item of the main window) that shows there: cut
    to the window and to every item above it that clips. None when nothing
    of it shows."""
    from PySide6.QtCore import QRectF
    r = scene_rect(item).intersected(QRectF(0, 0, shell.width(), shell.height()))
    up = item.parentItem()
    while up is not None:
        if up.clip():
            r = r.intersected(scene_rect(up))
        up = up.parentItem()
    return r if r.width() >= 1 and r.height() >= 1 else None


def top_in_view(item):
    """ITEM shows from its top left corner on."""
    full, part = scene_rect(item), shown_rect(item)
    return part is not None and abs(part.top() - full.top()) < 1 and abs(part.left() - full.left()) < 1


def named(item):
    """A control and where it is in the window, for a failure message."""
    r = scene_rect(item)
    return "%s %r from y %d to %d" % (item.metaObject().className().split("_")[0], cut(item.property("text") or "", 30), r.top(), r.bottom())


def unfold():
    """Open what a page keeps folded, so that what is in it is a Tab stop too."""
    for label in ("Show all details", "How to fix it yourself", "Show details"):
        for b in [i for i in controls() if (i.property("text") or "") == label]:
            space(b)


def smallest_window():
    """The window as small as it goes."""
    shell.setWidth(shell.minimumWidth())
    shell.setHeight(shell.minimumHeight())
    yield P(0.3)
    return "%d x %d" % (shell.width(), shell.height())


def sc_reveal():
    """A control that gets the keyboard focus is in view, from its top edge
    on: Tab and Shift+Tab through every stop of every page and the arrow
    keys through its lists in the smallest window, Tab again in a larger
    one. The cursor of a command block shows, and the page follows it."""
    from PySide6.QtCore import QMetaObject, Qt
    Tab, Backtab, Down, Up = K().Key_Tab, K().Key_Backtab, K().Key_Down, K().Key_Up
    S = SAMPLES
    many_lines = "".join("line %d of the details\n" % n for n in range(1, 41))
    pages = [
        ("wizard, Welcome", "wizard", S["wizard"]),
        ("wizard, Your PC", "wizard", dict(S["wizard"], start_step=1)),
        ("wizard, Options", "wizard", dict(S["wizard"], start_step=2)),
        ("wizard, Review", "wizard", dict(S["wizard"], start_step=3)),
        ("settings", "settings", S["settings"]),
        ("dashboard", "dashboard", S["dashboard"]),
        ("check", "check", S["check"]),
        ("choose", "choose", S["choose"]),
        ("confirm", "confirm", S["confirm"]),
        ("dialog, list", "dialog", S["dialog-list"]),
        ("dialog, error with its details", "dialog", dict(S["dialog-error"], details=many_lines)),
    ]

    def walk(back):
        """Once around the page: (the stops, those that were not in view)."""
        QMetaObject.invokeMethod(shell, "unfocus")
        seen, bad = [], []
        for _ in range(90):
            if back:
                typed(Backtab, Qt.KeyboardModifier.ShiftModifier)
            else:
                key(Tab)
            yield P(0.02)
            item = shell.activeFocusItem()
            if item is None or item in seen:
                break
            seen.append(item)
            if not top_in_view(item):
                bad.append(named(item))
        return seen, bad

    def along(start, k):
        """From a row of a list with an arrow key, as far as it goes."""
        start.forceActiveFocus(FOCUS_BY_TAB())
        bad = []
        for _ in range(60):
            before = shell.activeFocusItem()
            key(k)
            yield P(0.02)
            item = shell.activeFocusItem()
            if item is before or item is None:
                break
            if not top_in_view(item):
                bad.append(named(item))
        return bad

    def not_in_view(bad):
        return "" if not bad else " - not: " + cut("; ".join(bad), 300)

    for small in (True, False):
        size = None
        for n, (what, mode, data) in enumerate(pages):
            if not (yield from show("v%d-%d" % (small, n), mode, data, what)):
                continue
            if size is None:
                if small:
                    size = yield from smallest_window()
                else:
                    shell.setWidth(max(900, shell.minimumWidth()))
                    shell.setHeight(max(720, shell.minimumHeight()))
                    yield P(0.3)
                    size = "%d x %d" % (shell.width(), shell.height())
            unfold()
            yield P(0.2)
            seen, bad = yield from walk(False)
            check(len(seen) >= 2 and not bad, "%s, %s: each of the %d Tab stops is in view when it gets the keyboard focus%s"
                  % (what, size, len(seen), not_in_view(bad)))
            if small:
                back, bad = yield from walk(True)
                check(len(back) >= 2 and not bad, "%s, %s: and each of the %d that Shift+Tab stops at%s" % (what, size, len(back), not_in_view(bad)))
                rows_ = [i for i in seen if i.property("modelData") is not None and i.property("index") is not None]
                bad = []
                for item in rows_:
                    bad += yield from along(item, Down)
                    bad += yield from along(item, Up)
                if rows_:
                    check(not bad, "%s, %s: each row the arrow keys go to is in view%s" % (what, size, not_in_view(bad)))
            no_warnings(what)

    # ---- the cursor of a command block
    commands = "".join("command-%d --with an-option\n" % n for n in range(1, 61))
    if (yield from show("v-c", "confirm", dict(S["confirm"], commands=commands), "confirm, many commands")):
        yield from smallest_window()
        edit = control("the command block", lambda i: True, "QQuickTextEdit")
        if edit is not None:
            QMetaObject.invokeMethod(shell, "unfocus")
            yield P(0.1)
            hidden = edit.property("cursorVisible")
            edit.forceActiveFocus(FOCUS_BY_TAB())
            yield P(0.2)
            check(hidden is False and edit.property("cursorVisible") is True,
                  "confirm: the command block shows its cursor while it has the keyboard focus, and only then")
            area = page_root().property("scrollArea")
            start, y0, lost = edit.property("cursorPosition"), scroll_y()[0], 0
            for _ in range(45):
                key(Down)
                yield P(0.02)
                if not scene_rect(area).adjusted(0, -1, 0, 1).contains(edit.mapRectToScene(edit.property("cursorRectangle"))):
                    lost += 1
            check(edit.property("cursorPosition") > start and scroll_y()[0] > y0 and lost == 0,
                  "confirm: Down moves the cursor of the command block and the page scrolls along with it (the cursor was out of view %d of 45 times)" % lost)
    no_warnings("the whole scenario")
    send({"quit": True})


def luminance(c):
    def part(v):
        v /= 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * part(c[0]) + 0.7152 * part(c[1]) + 0.0722 * part(c[2])


def contrast(a, b):
    """The contrast of two colours (red, green, blue), as WCAG works it out: 1 to 21."""
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def colours(img, rect):
    """The colours of the pixels of RECT in a picture of the window, the most frequent first."""
    from collections import Counter
    count = Counter()
    for y in range(max(0, int(rect.top())), min(img.height(), int(rect.top() + rect.height() + 0.999))):
        for x in range(max(0, int(rect.left())), min(img.width(), int(rect.left() + rect.width() + 0.999))):
            p = img.pixel(x, y)
            count[((p >> 16) & 255, (p >> 8) & 255, p & 255)] += 1
    return [c for c, n in count.most_common()]


def hex_colour(c):
    return "#%02x%02x%02x" % tuple(c)


def ring_contrast(img, ring, deep=0):
    """How a focus ring that shows stands out, from the pixels along its top
    edge: (its contrast against the line of pixels outside it, against the
    line inside it, its colour, the colour outside, the colour inside).
    DEEP: the line that many pixels further in (past the gap and the frame
    of a card, on its fill). None when its top edge is not in view."""
    from PySide6.QtCore import QRectF
    full, part = scene_rect(ring), shown_rect(ring)
    line = int(ring.property("line"))
    bend = float(ring.property("radius") or 0) + 4        # the corners are round
    if part is None or abs(part.top() - full.top()) >= 1 or full.top() < 1 or full.width() < bend * 2 + 8:
        return None
    top, x, w = round(full.top()), full.left() + bend, full.width() - bend * 2
    own = colours(img, QRectF(x, top, w, line))[0]
    outside = colours(img, QRectF(x, top - 1, w, 1))[0]
    inside = colours(img, QRectF(x, top + line + deep, w, 1))[0]
    return contrast(own, outside), contrast(own, inside), own, outside, inside


def sc_contrast():
    """What must be seen, measured from pictures of the window, in the
    colours as they come here and, where the Breeze colour schemes are
    installed, in the light and in the dark theme: a focus ring has 3:1
    against what is outside it and against what is inside it, the
    placeholder of the report folder 4.5:1, the tick of a finished step 3:1."""
    from PySide6.QtCore import QMetaObject
    from PySide6.QtGui import QIcon
    S = SAMPLES
    no_folder = dict(S["wizard"], start_step=2, answers=dict(S["wizard"]["answers"], report_dir=""))
    state = {"theme": "", "n": 0}

    def ringed(what, item, card=False):
        """CARD: the ring is around a card (or inside one): it must stand
        out from the card's fill too, three pixels further in."""
        if item is None:
            return check(False, "%s: there is such a control" % what)
        QMetaObject.invokeMethod(shell, "unfocus")
        item.forceActiveFocus(FOCUS_BY_TAB())
        yield P(0.25)
        img = shell.grabWindow()
        seen = [ring_contrast(img, r) for r in rings()]
        if len(seen) != 1 or seen[0] is None:
            return check(False, "%s, %s: one focus ring shows, and its top edge is in view (%d rings)" % (what, state["theme"], len(seen)))
        out, ins, own, c_out, c_in = seen[0]
        fill, c_fill = ring_contrast(img, rings()[0], 3)[1::3] if card else (99, None)
        return check(out >= 3 and ins >= 3 and fill >= 3,
                     "%s, %s: the focus ring %s has %.2f:1 against %s outside it and %.2f:1 against %s inside it%s (3:1 needed)"
                     % (what, state["theme"], hex_colour(own), out, hex_colour(c_out), ins, hex_colour(c_in),
                        "" if not card else ", and %.2f:1 against the card's %s" % (fill, hex_colour(c_fill))))

    def page(mode, data, what):
        state["n"] += 1
        return (yield from show("o%d" % state["n"], mode, data, what))

    for label, theme in (("in the colours as they come", None), ("light theme", "light"), ("dark theme", "dark")):
        state["theme"] = label
        if theme is not None:
            path = appmod._scheme_path(theme)
            if not path:
                say("     note: the Breeze colour scheme of the %s theme is not installed here: nothing measured in it" % theme)
                continue
            send({"theme": theme})
            yield W(lambda: (app.property("KDE_COLOR_SCHEME_PATH") or "") == path, "the %s theme is set" % theme)
            yield P(0.3)
        if (yield from page("confirm", S["confirm"], "confirm")):
            yield from ringed("confirm: the main button, on the page", main_button())
            yield from ringed("confirm: the command block (the ring is inside it)", control("the command block", lambda i: True, "QQuickTextEdit"), True)
            shot("contrast-%s-confirm" % (theme or "as-it-comes"))
        if (yield from page("check", S["check"], "check")):
            boxes = controls("QQuickCheckBox")
            ticks = [b for b in boxes if not b.property("text")]
            yield from ringed("check: Select all", next((b for b in boxes if b.property("text")), None))
            yield from ringed("check: a finding that is not ticked (the ring is around its card)", next((b for b in ticks if not b.property("checked")), None), True)
            yield from ringed("check: a finding that is ticked", next((b for b in ticks if b.property("checked")), None), True)
            shot("contrast-%s-check" % (theme or "as-it-comes"))
        if (yield from page("choose", S["choose"], "choose")):
            yield from ringed("choose: a row that is ticked", row("tag", "a"), True)
            yield from ringed("choose: a row that is not ticked", row("tag", "c"), True)
        if (yield from page("dashboard", S["dashboard"], "dashboard")):
            chips = [i for i in controls() if i.property("modelData") is not None and i.property("index") is not None and not i.inherits("QQuickItemDelegate")]
            yield from ringed("dashboard: an area chip", chips[0] if chips else None, True)
            yield from ringed("dashboard: a check (the ring is inside the row)",
                              next((i for i in controls("QQuickItemDelegate") if i.property("number") is not None), None))
        if (yield from page("wizard", dict(S["wizard"], start_step=1), "wizard, Your PC")):
            cards = [i for i in controls() if i.property("switchedOn") is not None and i.property("checkable")]
            yield from ringed("wizard: a card that is switched on", next((c for c in cards if c.property("switchedOn")), None), True)
            yield from ringed("wizard: a card that is switched off", next((c for c in cards if not c.property("switchedOn")), None), True)
            yield from ringed("wizard: a finished step (the ring is inside it, on the band at the top)",
                              next((i for i in controls() if i.property("done") is True), None))
        if (yield from page("settings", S["settings"], "settings")):
            yield from ringed("settings: the tick box", next(iter(controls("QQuickCheckBox")), None))
            link = [i for i in items_under(page_root()) if i.metaObject().className().startswith("UrlButton") and i.isVisible()]
            yield from ringed("settings: the link", link[0] if link else None)
        if (yield from page("dialog", S["dialog-list"], "a dialog over the page")):
            yield from ringed("dialog: the main button, on the dialog's card", main_button())
            key(K().Key_Escape)
            yield P(0.3)

        # The placeholder of the report folder, and the tick of a finished step.
        if (yield from page("wizard", no_folder, "wizard, Options without a folder")):
            field = control("the report folder", lambda i: True, "QQuickTextField")
            if field is not None:
                field.forceActiveFocus(FOCUS_BY_TAB())      # into view
                QMetaObject.invokeMethod(shell, "unfocus")
                yield P(0.3)
                img = shell.grabWindow()
                part = shown_rect(field)
                seen = colours(img, part.adjusted(6, 4, -6, -4)) if part is not None else []
                best = max([contrast(c, seen[0]) for c in seen] or [0])
                check(field.property("text") == "" and "No folder" in (field.property("placeholderText") or "") and best >= 4.5,
                      "wizard, %s: the placeholder %r has %.2f:1 on the field (4.5:1 needed; text %s on %s)"
                      % (label, field.property("placeholderText"), best,
                         hex_colour(max(seen, key=lambda c: contrast(c, seen[0]))) if seen else "?", hex_colour(seen[0]) if seen else "?"))
            done = [i for i in items_under(page_root()) if i.property("done") is True and i.isVisible()]
            discs = [i for i in items_under(done[0]) if i.inherits("QQuickRectangle") and i.width() > 8
                     and abs(i.width() - i.height()) < 0.5 and abs((i.property("radius") or 0) - i.width() / 2) < 0.5] if done else []
            if check(len(discs) == 1, "wizard, %s: a finished step has a filled circle" % label):
                img = shell.grabWindow()
                r = scene_rect(discs[0])
                k = r.width() * 0.18
                seen = colours(img, r.adjusted(k, k, -k, -k))
                icon = [i for i in discs[0].childItems() if i.isVisible() and i.property("source") is not None]
                tick = icon[0].property("color") if icon else None
                wanted = contrast((tick.red(), tick.green(), tick.blue()), seen[0]) if tick is not None else 0
                check(wanted >= 3, "wizard, %s: the colour of a finished step's tick has %.2f:1 on its circle %s (3:1 needed)" % (label, wanted, hex_colour(seen[0])))
                best = max(contrast(c, seen[0]) for c in seen)
                if icon and QIcon.hasThemeIcon("dialog-ok-apply"):
                    check(best >= 3, "wizard, %s: the tick as it is drawn has %.2f:1 on its circle" % (label, best))
                else:
                    say("     note: no icon theme here: the tick is not drawn, only its colour was measured")
            shot("contrast-%s-wizard" % (theme or "as-it-comes"))
        no_warnings(label)
    send({"quit": True})


def sc_layout(large):
    """What must fit in the smallest window. LARGE: with a font of 15 pt
    instead of 9 or 10, as for a person who needs large text (the pages are made
    after the font is set; the sizes Kirigami gives stay as they are, so
    what is sized in grid units must follow the text by itself)."""
    def script():
        from PySide6.QtGui import QFont
        S = SAMPLES
        tag = ", large text" if large else ""
        long_label = "After-the-fix-and-a-label-that-goes-on-without-a-space-in-it and then some more words"
        long_intro = " ".join(["Each app keeps working, but may ask for a file or folder when it needs one."] * 12)
        long_title = " ".join(["Choose the Flatpak permissions to remove"] * 8)
        long_detail = " ".join(["Looking at the open ports of this PC"] * 8)
        state = {"n": 0}

        def texts(root):
            return [i for i in items_under(root) if i.inherits("QQuickText") and i.isVisible() and (i.property("text") or "") != ""]

        def of_class(name, root=None):
            return [i for i in items_under(root or page_root()) if i.metaObject().className().startswith(name) and i.isVisible()]

        def page(mode, data, what):
            state["n"] += 1
            ok = yield from show("l%d" % state["n"], mode, data, what)
            if ok:
                yield from smallest_window()
            return ok

        def footer(what, wanted):
            """The bar at the bottom: the whole hint can be read, and the buttons are inside the window, next to each other."""
            bars = of_class("FooterBar")
            if not check(len(bars) == 1, "%s%s: one bar at the bottom" % (what, tag)):
                return
            hints = [t for t in texts(bars[0]) if wanted in t.property("text")]
            check(len(hints) == 1 and hints[0].property("truncated") is False and top_in_view(hints[0])
                  and scene_rect(hints[0]).bottom() <= shell.height(),
                  "%s%s: the hint in the bar at the bottom is there once, and all of it can be read: %s"
                  % (what, tag, cut([(t.property("text"), t.property("truncated")) for t in hints], 200)))
            rects = sorted((scene_rect(b).left(), scene_rect(b).right()) for b in controls(root=bars[0]))
            check(len(rects) >= 2 and rects[0][0] >= 0 and rects[-1][1] <= shell.width()
                  and all(a[1] <= b[0] + 0.5 for a, b in zip(rects, rects[1:])),
                  "%s%s: the buttons of the bar are inside the window, next to each other: %s" % (what, tag, [(round(a), round(b)) for a, b in rects]))

        if large:
            font = QFont(app.font())
            check(font.pointSizeF() <= 11, "the font as it comes has %.1f pt: 15 pt is large text" % font.pointSizeF())
            font.setPointSizeF(15)
            app.setFont(font)
            yield P(0.3)

        # ---- the dashboard: the score in its ring
        if (yield from page("dashboard", S["dashboard"], "dashboard")):
            rings_ = [i for i in items_under(page_root()) if i.inherits("QQuickCanvasItem")]
            if check(len(rings_) == 1, "dashboard%s: the ring of the score" % tag):
                box = rings_[0].parentItem()
                rects = [scene_rect(t) for t in texts(box)]
                mid, reach = scene_rect(box).center(), box.width() / 2 - rings_[0].property("line")
                far = max([((x - mid.x()) ** 2 + (y - mid.y()) ** 2) ** 0.5 for r in rects
                           for x in (r.left(), r.right()) for y in (r.top(), r.bottom())] or [0])
                check(len(rects) == 2 and rects[0].bottom() <= rects[1].top() + 0.5 and far <= reach + 0.5,
                      "dashboard%s: the score is above the grade and both are inside the ring (their farthest corner is %d from the middle, the ring's inner edge %d)"
                      % (tag, far, reach))
            footer("dashboard", "exact commands")
            shot("layout-dashboard" + ("-large" if large else ""))

        # ---- the wizard: the numbers of the steps in their circles
        for step in range(4):
            if (yield from page("wizard", dict(S["wizard"], start_step=step), "wizard, step %d" % (step + 1))):
                steps = [i for i in items_under(page_root()) if i.property("number") is not None and i.property("done") is not None and i.isVisible()]
                bad, numbers = [], 0
                for b in steps:
                    for t in [t for t in texts(b) if t.property("text") == str(b.property("number") + 1)]:
                        numbers += 1
                        if not scene_rect(t.parentItem()).adjusted(-0.5, -0.5, 0.5, 0.5).contains(scene_rect(t)):
                            bad.append(t.property("text"))
                check(len(steps) == 4 and numbers == 4 - step and not bad and scene_rect(steps[-1]).right() <= shell.width(),
                      "wizard, step %d%s: the numbers of the steps are inside their circles, and the steps inside the window%s"
                      % (step + 1, tag, "" if not bad else " - not: %s" % bad))
        no_folder = dict(S["wizard"], answers=dict(S["wizard"]["answers"], report_dir=""))
        if (yield from page("wizard", no_folder, "wizard without a folder")):
            footer("wizard without a folder", "report folder first")
            shot("layout-wizard" + ("-large" if large else ""))

        # ---- the hints of the other pages
        for mode, wanted in (("check", "exact commands"), ("choose", "Nothing changes yet"), ("confirm", "Nothing changes until")):
            if (yield from page(mode, S[mode], mode)):
                footer(mode, wanted)
                shot("layout-%s%s" % (mode, "-large" if large else ""))

        # ---- a finding: a long label for the setting after the fix, and none
        data = json.loads(json.dumps(S["check"]))
        data["findings"][0]["after_label"] = long_label
        del data["findings"][1]["after_label"]
        if (yield from page("check", data, "check, a long label")):
            grids = of_class("NowAfter")
            if check(len(grids) >= 2, "check%s: a setting now and after the fix, for two findings" % tag):
                g, ts = grids[0], texts(grids[0])
                label = [t for t in ts if t.property("text") == long_label]
                card = g.parentItem()
                while card is not None and card.property("canFix") is None:
                    card = card.parentItem()
                area = page_root().property("scrollArea")
                check(len(label) == 1 and label[0].property("lineCount") > 1 and label[0].width() <= g.width() * 0.4 + 1
                      and all(scene_rect(t).right() <= scene_rect(g).right() + 0.5 for t in ts)
                      and card is not None and scene_rect(g).right() <= scene_rect(card).right()
                      and area.property("contentWidth") <= area.width() + 0.5,
                      "check%s: a long label for the setting after the fix wraps in its column (%d of %d wide, %s lines) and the card keeps its width"
                      % (tag, label[0].width() if label else -1, g.width(), label[0].property("lineCount") if label else "?"))
                check("After the fix" in [t.property("text") for t in texts(grids[1])],
                      "check%s: a finding without a label for it says \"After the fix\"" % tag)
            shot("layout-check-long-label" + ("-large" if large else ""))

        # ---- the band at the top: a long title and a long line under it
        if (yield from page("choose", dict(S["choose"], title=long_title, intro=long_intro), "choose, long texts")):
            bands = of_class("PageHeader")
            title = [t for t in texts(bands[0]) if t.property("text") == long_title] if bands else []
            intro = [t for t in texts(bands[0]) if t.property("text") == long_intro] if bands else []
            area = page_root().property("scrollArea")
            check(len(title) == 1 and len(intro) == 1 and title[0].property("lineCount") <= 3 and intro[0].property("lineCount") <= 4
                  and intro[0].property("truncated") is True and area.height() >= shell.height() * 0.15,
                  "choose%s: a long title is cut after three lines and the line under it after four, and the list keeps room (%d of %d high)"
                  % (tag, area.height(), shell.height()))
            shot("layout-choose-long" + ("-large" if large else ""))
        no_warnings("the pages" + tag)

        # ---- the progress window: its Hide button, with a detail of two lines
        send({"progress": "start", "heading": "Checking your PC"})
        send({"progress": "set", "line": "40\t0\tFirewall\t" + long_detail})
        if (yield W(lambda: progress_window() is not None and progress_window().isVisible(), "the progress window shows")):
            win = progress_window()
            win.setProperty("canHide", True)        # as when the desktop has a tray
            yield P(0.5)
            hide = [i for i in items_under(win.contentItem()) if i.inherits("QQuickAbstractButton") and i.property("text") == "Hide" and i.isVisible()]
            detail = [t for t in texts(win.contentItem()) if t.property("text") == long_detail]
            r = scene_rect(hide[0]) if hide else None
            check(len(hide) == 1 and len(detail) == 1 and detail[0].property("lineCount") == 2 and r.top() >= 0 and r.bottom() <= win.height(),
                  "progress%s: with a detail of two lines the Hide button is inside the window (it ends at %s of %d)"
                  % (tag, round(r.bottom()) if r is not None else "?", win.height()))
            if SHOTS:
                win.grabWindow().save(os.path.join(SHOTS, "layout-progress%s.png" % ("-large" if large else "")))
            high = win.height()
            send({"progress": "set", "line": "60\t0\tAccounts\t"})
            yield P(0.4)
            check(win.height() == high and win.property("detail") == "", "progress%s: the window keeps its height when the detail goes (%d, then %d)" % (tag, high, win.height()))
        send({"busy": ""})
        yield P(0.3)
        no_warnings("the progress window" + tag)
        send({"quit": True})
    return script


# Where the root side builds the input of each page (file, function). The
# keys are read from the text of these functions: see root_keys().
BUILDERS = {
    "wizard": (("lib/wizard.sh", "_wizard_input"),),
    "settings": (("lib/settings.sh", "run_settings"),),
    "dashboard": (("lib/dashboard.sh", "_dashboard_input"),),
    "check": (("lib/dashboard.sh", "_check_input"), ("lib/features.sh", "affects_json"), ("lib/fixes.sh", "_warnings_json")),
    "choose": (("lib/ui.sh", "_choose_input"),),
    "confirm": (("lib/fixes.sh", "apply_change"), ("lib/features.sh", "affects_json"), ("lib/fixes.sh", "_warnings_json")),
    "dialog": (("lib/ui.sh", "_ui_dialog"),),
}
# Objects whose keys are data (a fact's name, a severity), not a fixed set.
OPEN_MAPS = {"wizard": ("facts", "detected"), "dashboard": ("open",)}
# Words the patterns of root_keys() find that are not keys of the input:
# the dashboard's line type "check", the dialog's default titles by kind.
NOT_KEYS = {"dashboard": ("check",), "dialog": ("error", "warning", "question")}


def root_keys(mode):
    """The keys the root side puts into the input of MODE, at any depth,
    read from the text of the shell functions that build it; None with a
    failed check when such a function is not where BUILDERS says."""
    keys = set()
    for path, name in BUILDERS[mode]:
        with open(os.path.join(REPO, path), encoding="utf-8") as f:
            m = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), f.read(), re.M | re.S)
        if not m:
            check(False, "%s: the function %s is in %s" % (mode, name, path))
            return None
        body = m.group(0)
        if mode == "settings":
            # _json KEY "$VALUE" ... on the line that calls ui_app
            line = [x for x in body.split("\n") if "ui_app settings" in x]
            keys.update(re.findall(r'\b([a-z_]+) "\$[A-Z_]+"', line[0] if line else ""))
            continue
        # "key": in a Python dictionary, \"key\": in JSON written by the shell
        keys.update(re.findall(r'\\?"([a-z_]+)\\?"\s*:', body))
        if mode == "dashboard":
            # printf 'key\t%s\n': one line per value, made into JSON at the end
            keys.update(re.findall(r"(?:'|\\n)([a-z_]+)\\t", body))
    return keys - set(NOT_KEYS.get(mode, ()))


def sample_keys(mode, value, out=None):
    """The keys of a sample input at any depth (not inside OPEN_MAPS)."""
    out = set() if out is None else out
    if isinstance(value, dict):
        for k, v in value.items():
            out.add(k)
            if k not in OPEN_MAPS.get(mode, ()):
                sample_keys(mode, v, out)
    elif isinstance(value, list):
        for v in value:
            sample_keys(mode, v, out)
    return out


def after_sample_keys(rc):
    """tests/ui/samples.json against the root side: the samples of a page,
    taken together, use every key the root side sends for it and no other.
    (Names only: a key under another parent is not noticed.)"""
    check(rc == 0 and app is None, "no window was needed for this")
    for mode in appmod.PAGES:
        names = [n for n in SAMPLES if n == mode or n.startswith(mode + "-")]
        used = set()
        for n in names:
            sample_keys(mode, SAMPLES[n], used)
        sent = root_keys(mode)
        if sent is None:
            continue
        check(len(sent) >= 4, "%s: the keys the root side sends were found in its code (%d)" % (mode, len(sent)))
        check(not sent - used, "%s: every key the root side sends is in a sample (%s)%s"
              % (mode, ", ".join(names), "" if not sent - used else "; missing: " + ", ".join(sorted(sent - used))))
        check(not used - sent, "%s: no sample has a key the root side never sends%s"
              % (mode, "" if not used - sent else ": " + ", ".join(sorted(used - sent))))
    check(not [n for n in SAMPLES if n.split("-")[0] not in appmod.PAGES], "every sample is named after a page")


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
    "a11y": (["serve"], lambda: {"busy": ""}, None, sc_a11y, after_serve),
    "guard": (["serve"], lambda: {"busy": ""}, None, sc_guard, after_serve),
    "keys": (["serve"], lambda: {"busy": ""}, STUBS_KEYS, sc_keys, after_serve),
    "typing": (["serve"], lambda: {"busy": ""}, STUBS_TYPING, sc_typing, after_serve),
    "malformed": (["serve"], lambda: BAD_LINES[0][1], None, sc_malformed, after_serve),
    # (A line that does not fit in the pipe would block this test for ever: deep_line_fits() then fails instead.)
    "deep-first": (["serve"], lambda: DEEP_LINE, None, sc_deep_first, after_serve),
    "first-lines": (["serve"], first_lines({"busy": "Starting…"}, request("f1", "confirm", "confirm"), request("f2", "choose", "choose")),
                    None, sc_first_lines, after_serve),
    "first-lines-quit": (["serve"], first_lines({"busy": "Starting…"}, request("x1", "confirm", "confirm"), {"quit": True}),
                         None, None, after_end("a request and quit, written together with the first line", 1)),
    "answer-closed": (["serve"], request("x1", "confirm", "confirm"), None, sc_answer_closed, after_answer_closed),
    "crash": (["serve"], None, None, None, after_crash),
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
    "oneshot-list": (["dialog"], lambda: "[1, 2]", None, None,
                     lambda rc: check(rc == 2 and not replies and app is None,
                                      "app.py dialog with input that is JSON but not an object: status %r (2 expected), nothing printed, no window" % (rc,))),
    "oneshot-deep": (["dialog"], lambda: DEEP_LINE, None, None,
                     lambda rc: check(deep_line_fits() and rc == 2 and not replies and app is None,
                                      "app.py dialog with input that is JSON nested too deep: status %r (2 expected), nothing printed, no window" % (rc,))),
    "oneshot-odd": (["wizard"], lambda: {"what": "date"}, STUBS_ODD, sc_oneshot_odd,
                    lambda rc: check(rc == 3 and not replies, "app.py with a page whose answer is not JSON: status %r (3 expected), nothing printed" % (rc,))),
    "serve-edge": (["serve"], lambda: {"busy": ""}, None, sc_serve_edge, after_serve),
    "no-progress-window": (["serve"], lambda: {"busy": ""}, None, sc_no_progress_window, after_serve),
    "progress-broken": (["progress"], lambda: {"heading": "Checking your PC"}, None, None,
                        lambda rc: check(rc == 3 and not replies, "app.py progress when the window cannot be made: status %r (3 expected), nothing printed" % (rc,))),
    "odd-answer": (["serve"], lambda: {"busy": ""}, STUBS_ODD, sc_odd_answer, after_serve),
    "parent-gone": (["serve"], request("x1", "confirm", "confirm"), None, sc_parent_gone, after_parent_gone),
    "variants": (["serve"], lambda: {"busy": ""}, None, sc_variants, after_serve),
    "reveal": (["serve"], lambda: {"busy": ""}, None, sc_reveal, after_serve),
    "contrast": (["serve"], lambda: {"busy": ""}, None, sc_contrast, after_serve),
    "layout": (["serve"], lambda: {"busy": ""}, None, sc_layout(False), after_serve),
    "large-text": (["serve"], lambda: {"busy": ""}, None, sc_layout(True), after_serve),
    "sample-keys": (["serve"], None, None, None, after_sample_keys),
}
# What a scenario needs done in its process before main() runs.
PREPARE = {"owner-gone": prepare_owner, "no-progress-window": prepare_no_progress, "progress-broken": prepare_no_progress}
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
    # Room for one very long request line: this process writes it and reads
    # it, so a write that does not fit in the pipe would block for ever.
    try:
        import fcntl
        fcntl.fcntl(req_w, fcntl.F_SETPIPE_SZ, 1 << 20)
    except (ImportError, AttributeError, OSError):
        pass                    # the default size: send() then writes a long line from a thread
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
        # BSA_UI_TEST_PLATFORM=wayland (or xcb) runs the same scenarios in
        # real windows of the session, for a look at them on a real desktop.
        "QT_QPA_PLATFORM": os.environ.get("BSA_UI_TEST_PLATFORM") or "offscreen",
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
