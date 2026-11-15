#!/usr/bin/python3 -I
# Security Check - the Kirigami front end: the seven pages of the tool
# (wizard, settings, dashboard, check, choose, confirm, dialog) in one
# window, and the scan's progress window with its tray icon.
#
# Runs as the desktop user, never as root. The root side of the tool starts
# it, tells it in JSON what to show, and reads the person's answers as
# JSON; the root side validates every value it takes from it. What this
# program writes to stderr, the root side reads through a pipe and copies
# (cut to size, marked "ui:") into its run log.
#
# Every page is shown in ONE window (qml/Shell.qml), which stays open for
# the whole run of the tool:
#
#   app.py serve     one JSON object per line on stdin, until EOF:
#       {"id": ID, "mode": MODE, "data": {...}}   show a page; answered by
#           one line on stdout, exactly in this form (the root side reads it
#           without a JSON parser):
#           {"id":"ID","status":0|1|3,"answer":...}
#           0 answered, 1 cancelled or closed, 3 the page could not be shown.
#       {"busy": "LABEL"}       nothing to answer: the last page stays, dimmed,
#                               with a spinner and LABEL. "" does not ask for
#                               the spinner: it only puts the spinner's usual
#                               text ("Working…") back and, if the progress
#                               window is open, closes it.
#       {"progress": "start", "heading": "..."}   the scan: the window makes
#       {"progress": "set", "line": "..."}        way for the small progress
#       {"progress": "stop"}                      window and its tray icon,
#                               which stay until the next page (a progress
#                               line is the one "app.py progress" takes)
#       {"theme": "system|light|dark"}            switch colours
#       {"quit": true}          leave (as EOF does)
#     Any other line (not JSON, not an object, an object with none of these
#     keys, a page request without a usable id), and any line whose handling
#     fails here, is answered by {"id":"","status":3,"answer":null} - with
#     the request's id instead of "" when it had a usable one.
#     Nothing is loaded and no window exists before the first line that is
#     not empty arrives; if that line is "quit", nothing ever is.
#     Exit status 0; 3 when Qt or the window could not be loaded (the root
#     side does not read it: it sees the answer pipe close).
#
# One page in a window of its own, and the progress window alone. The root
# side uses these when it could not make the two pipes for "serve"; and
# they are what an installed 1.5.0 root side calls while it updates itself
# to this version, so they must stay:
#
#   app.py wizard    < {"facts": ..., "detected": ..., "answers": ...}
#   app.py settings  < {"version": ..., "theme": ..., "repo": ...}
#   app.py dashboard < {"score": ..., "areas": [...], "checks": [...], ...}
#   app.py check     < {"title": ..., "notes": [...], "findings": [...]}
#   app.py choose    < {"title": ..., "intro": ..., "items": [{tag, label, ...}]}
#   app.py confirm   < {"title": ..., "now": ..., "commands": ..., ...}
#   app.py dialog    < {"kind": ..., "title": ..., "html": ..., "buttons": [...]}
#       The answer is one JSON value on stdout. Exit status 0: answered,
#       1: cancelled, 2: bad input, 3: this front end cannot run here (the
#       caller falls back to kdialog).
#   app.py progress  < {"heading": ...}, then progress lines until EOF or a
#                      line "QUIT": "PERCENT<TAB>SLOW<TAB>LABEL<TAB>DETAIL"
#                      (PERCENT "-" for no steps, SLOW 1 for a long step); a
#                      window and a tray icon show them. Exit status 0, or 3.
#
#   app.py theme-dir THEME   prints a config folder whose kdeglobals uses
#                            THEME's colours (for kdialog: XDG_CONFIG_HOME)
#
# In every mode it leaves when the root side has gone without saying so
# (see _Owner).
import json
import os
import select
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
SCHEMES = {"light": "BreezeLight", "dark": "BreezeDark"}
PAGES = {"wizard": "Wizard.qml", "settings": "Settings.qml", "dashboard": "Dashboard.qml",
         "check": "Check.qml", "choose": "Choose.qml", "confirm": "Confirm.qml", "dialog": "Dialog.qml"}
MODES = tuple(PAGES) + ("progress", "serve")
KEYS = ("quit", "theme", "progress", "busy", "mode")    # what a "serve" line may hold
OWNER_CHECK_MS = 2000       # how often: is the root side still there? (_Owner)

# The test interface (tests/ui-offscreen.py); nothing else may set these,
# and there is no environment variable for them:
#   PAGE_DIR    the folder the seven page files (PAGES) are loaded from. A
#               test sets module.PAGE_DIR = "..." before it calls main().
#               Shell.qml and Progress.qml are NOT taken from it: they are
#               always loaded from the qml folder next to this file.
#   TEST_HOOK   called as TEST_HOOK(app, shell, host) once the QApplication
#               and the Shell root object exist, before the event loop runs
#               (shell is None in "progress" mode, which has no Shell).
#   main()      reads sys.argv and returns the exit status.
PAGE_DIR = os.path.join(HERE, "qml")
TEST_HOOK = None


def _scheme_path(theme):
    """The colour scheme file for a forced theme (None: follow the system)."""
    name = SCHEMES.get(theme)
    if not name:
        return None
    for d in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":") + ["/usr/share"]:
        p = os.path.join(d, "color-schemes", name + ".colors")
        if os.path.isfile(p):
            return p
    return None


def _scheme_groups(path):
    """The [Colors:*] groups of a .colors file: {group: [(key, value)]}."""
    groups, cur = {}, None
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("[") and line.endswith("]"):
                cur = line[1:-1] if line[1:-1].startswith("Colors:") else None
                if cur:
                    groups[cur] = []
            elif cur and "=" in line:
                k, _, v = line.partition("=")
                groups[cur].append((k.strip(), v.strip()))
    return groups


def _palette(path):
    """A QPalette from a KDE .colors file (what KColorScheme would build)."""
    from PySide6.QtGui import QColor, QPalette
    g = {k: dict(v) for k, v in _scheme_groups(path).items()}
    def c(group, key, fallback="128,128,128"):
        r, gg, b = (int(x) for x in g.get(group, {}).get(key, fallback).split(",")[:3])
        return QColor(r, gg, b)
    p = QPalette()
    roles = {
        QPalette.Window: c("Colors:Window", "BackgroundNormal"),
        QPalette.WindowText: c("Colors:Window", "ForegroundNormal"),
        QPalette.Base: c("Colors:View", "BackgroundNormal"),
        QPalette.AlternateBase: c("Colors:View", "BackgroundAlternate"),
        QPalette.Text: c("Colors:View", "ForegroundNormal"),
        QPalette.Button: c("Colors:Button", "BackgroundNormal"),
        QPalette.ButtonText: c("Colors:Button", "ForegroundNormal"),
        QPalette.Highlight: c("Colors:Selection", "BackgroundNormal"),
        QPalette.HighlightedText: c("Colors:Selection", "ForegroundNormal"),
        QPalette.ToolTipBase: c("Colors:Tooltip", "BackgroundNormal"),
        QPalette.ToolTipText: c("Colors:Tooltip", "ForegroundNormal"),
        QPalette.Link: c("Colors:View", "ForegroundLink"),
        QPalette.PlaceholderText: c("Colors:View", "ForegroundInactive"),
    }
    for role, col in roles.items():
        p.setColor(role, col)
    p.setColor(QPalette.Disabled, QPalette.Text, c("Colors:View", "ForegroundInactive"))
    p.setColor(QPalette.Disabled, QPalette.WindowText, c("Colors:Window", "ForegroundInactive"))
    p.setColor(QPalette.Disabled, QPalette.ButtonText, c("Colors:Button", "ForegroundInactive"))
    return p


def _theme_dir(theme):
    """A folder under ~/.cache with a kdeglobals that is the person's own,
    with THEME's colours; kdialog started with XDG_CONFIG_HOME pointing at
    it shows that theme. Prints nothing for "system"."""
    scheme = _scheme_path(theme)
    if not scheme:
        return 0
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    d = os.path.join(cache, "bazzite-sec-audit", "theme-" + theme)
    os.makedirs(d, mode=0o700, exist_ok=True)
    own = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"), "kdeglobals")
    out, skip = [], False
    try:
        for line in open(own, encoding="utf-8"):
            if line.startswith("["):
                skip = line.strip()[1:-1].startswith("Colors:") or line.strip() == "[General]"
            if not skip:
                out.append(line.rstrip("\n"))
    except OSError:
        pass
    out += ["", "[General]", "ColorScheme=" + SCHEMES[theme]]
    for grp, kv in _scheme_groups(scheme).items():
        out += ["", "[%s]" % grp] + ["%s=%s" % (k, v) for k, v in kv]
    tmp = os.path.join(d, "kdeglobals.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    os.replace(tmp, os.path.join(d, "kdeglobals"))
    print(d)
    return 0


class _Owner:
    """Is the root side still there? Normally it says "quit" or closes the
    pipe. But its other child processes hold copies of the pipe, so when it
    is killed outright there may be no EOF for a long time. Two checks:
    - the parent of this process (runuser, which the root side starts in a
      session of its own and which waits for this process) has changed;
    - the tool's main shell, whose process id the root side passes in
      BSA_OWNER_PID, is no longer there (same id and same start time)."""

    def __init__(self):
        self.ppid = os.getppid()
        self.pid = self.start = None
        try:
            pid = int(os.environ.get("BSA_OWNER_PID", ""))
        except ValueError:
            pid = 0
        if pid > 1:
            self.pid, self.start = pid, self._start_time(pid)

    @staticmethod
    def _start_time(pid):
        """Field 22 of /proc/PID/stat; None when it cannot be read."""
        try:
            with open("/proc/%d/stat" % pid, "rb") as f:
                return f.read().rpartition(b")")[2].split()[19]
        except (OSError, IndexError):
            return None

    def gone(self):
        if self.ppid > 1 and os.getppid() != self.ppid:
            return True
        if self.pid is None:
            return False
        if self.start is not None:
            return self._start_time(self.pid) != self.start
        try:
            os.kill(self.pid, 0)
        except ProcessLookupError:
            return True
        except OSError:
            pass                    # not ours to signal: it is there
        return False


class _Lines:
    """Lines from a descriptor, read without Python's buffering."""

    def __init__(self, fd):
        self.fd, self.buf, self.eof, self.pending = fd, b"", False, []

    def more(self):
        """Read once; the complete lines that have arrived."""
        try:
            chunk = os.read(self.fd, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            self.eof = True
        self.buf += chunk
        *lines, self.buf = self.buf.split(b"\n")
        return [line.decode("utf-8", "replace") for line in lines]

    def first(self, owner, skip_blank=False):
        """The first line (waits for it, as long as OWNER is there); None
        when there is none. Lines that came with it are kept in .pending.
        With SKIP_BLANK, lines of white space do not count as the first."""
        while not self.eof:
            try:
                ready = select.select([self.fd], [], [], OWNER_CHECK_MS / 1000)[0]
            except (OSError, ValueError):
                ready = [self.fd]
            if not ready:
                if owner.gone():
                    return None
                continue
            lines = self.more()
            while skip_blank and lines and not lines[0].strip():
                del lines[0]
            if lines:
                self.pending = lines[1:]
                return lines[0]
        rest, self.buf = self.buf, b""
        if skip_blank and not rest.strip():
            return None
        return rest.decode("utf-8", "replace") if rest else None


def _say(text=None):
    """A line for the run log (stderr); without TEXT, the traceback of the
    exception being handled."""
    try:
        if text is None:
            import traceback
            traceback.print_exc()
        else:
            print(text, file=sys.stderr, flush=True)
    except Exception:
        pass                        # the root side stopped reading stderr


def _write_all(fd, data):
    while data:
        data = data[os.write(fd, data):]


def _qml_url(folder, name):
    from PySide6.QtCore import QUrl
    return QUrl.fromLocalFile(os.path.join(folder, name)).toString()


def _page_url(page):
    """Where the page file of PAGE (a key of PAGES) is."""
    return _qml_url(PAGE_DIR, PAGES[page])


def _heading(msg):
    """The heading for the progress window in a message ("" if none)."""
    heading = msg.get("heading")
    return heading if isinstance(heading, str) else ""


def _request_id(msg):
    """The id of a page request, "" if it has none that can be used."""
    rid = msg.get("id") if isinstance(msg, dict) else None
    if isinstance(rid, str) and 0 < len(rid) <= 64 \
       and all(c.isascii() and (c.isalnum() or c in "-_") for c in rid):
        return rid
    return ""


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "theme-dir" and sys.argv[2] in SCHEMES:
        return _theme_dir(sys.argv[2])
    if len(sys.argv) != 2 or sys.argv[1] not in MODES:
        print("usage: app.py %s|theme-dir light|dark" % "|".join(MODES), file=sys.stderr)
        return 2
    mode = sys.argv[1]
    owner = _Owner()
    # The two pipes to the root side are moved away from stdin and stdout:
    # a program this one starts (a KDE helper) must not get a copy, or the
    # root side would still wait for an answer after a crash here; and
    # nothing a library prints can end up among the answers (it goes to
    # stderr instead).
    rfd, wfd = os.dup(0), os.dup(1)
    null = os.open(os.devnull, os.O_RDONLY)
    os.dup2(null, 0)
    os.close(null)
    try:
        os.dup2(2, 1)
    except OSError:
        pass
    reader = _Lines(rfd)
    # Waits here: no Qt, no window, before the root side asks for one.
    if mode == "serve":
        # Empty lines say nothing (_Serve.line ignores them too): the first
        # line that does decides whether Qt is needed at all.
        line = reader.first(owner, skip_blank=True)
        if line is None or _is_quit(line):
            return 0                # nothing was ever shown: no Qt needed
        return _run(mode, reader, wfd, owner, line=line)
    try:
        data = json.loads(reader.first(owner) or "{}")
    except ValueError:
        return 2
    if not isinstance(data, dict):
        return 2
    return _run(mode, reader, wfd, owner, data=data)


def _is_quit(line):
    try:
        msg = json.loads(line)
    except ValueError:
        return False
    return isinstance(msg, dict) and bool(msg.get("quit"))


class _Ui:
    """The Qt application: its name, icon and colours, the QML engine, and
    (not in "progress" mode) the one window, Shell.qml, with its host."""

    def __init__(self, on_reply):
        from PySide6.QtGui import QIcon
        from PySide6.QtQml import QQmlApplicationEngine
        from PySide6.QtWidgets import QApplication
        app = self.app = QApplication(sys.argv[:1])
        if _scheme_path(os.environ.get("BSA_THEME", "system")):
            self.set_theme(os.environ["BSA_THEME"])
        app.setApplicationName("bazzite-security-check")
        app.setApplicationDisplayName("Security Check")
        app.setDesktopFileName("bazzite-security-check")
        icon = QIcon.fromTheme("bazzite-security-check")
        if icon.isNull():
            icon = QIcon(os.path.join(HERE, "icons", "bazzite-security-check.svg"))
        app.setWindowIcon(icon)
        # The window is hidden while the scan's progress shows, and closing it
        # only answers "cancelled": this process ends when the root side says so.
        app.setQuitOnLastWindowClosed(False)
        self.icon_url = _qml_url(os.path.join(HERE, "icons"), "bazzite-security-check.svg")
        self.engine = QQmlApplicationEngine()
        self.host = _make_host(on_reply)
        self.shell = None

    def set_theme(self, theme):
        from PySide6.QtGui import QPalette
        scheme = _scheme_path(theme)
        # KDE's colour code (and so Kirigami) reads the scheme from this
        # application property, as KColorSchemeManager sets it.
        self.app.setProperty("KDE_COLOR_SCHEME_PATH", scheme or "")
        self.app.setPalette(_palette(scheme) if scheme else QPalette())

    def load(self, name, properties):
        """The root object of qml/NAME (always the one next to this file),
        None if it cannot be loaded."""
        before = len(self.engine.rootObjects())
        self.engine.setInitialProperties(properties)
        self.engine.load(_qml_url(os.path.join(HERE, "qml"), name))
        roots = self.engine.rootObjects()
        return roots[-1] if len(roots) > before else None

    def load_shell(self):
        self.shell = self.load("Shell.qml", {"host": self.host, "iconSource": self.icon_url})
        return self.shell is not None

    def feed(self, reader, on_line, begin, owner):
        """Run the event loop: BEGIN() first, then ON_LINE(line) for every
        line READER gets (those that came with the first one too), until
        something calls app.quit(), the input ends or OWNER has gone.
        BEGIN returns False when no lines are to be read."""
        from PySide6.QtCore import QSocketNotifier, QTimer
        app = self.app

        def readable():
            for line in reader.more():
                on_line(line)
            if reader.eof:
                notifier.setEnabled(False)
                app.quit()

        def start():
            if begin() is False:
                return
            for line in reader.pending:
                on_line(line)
            if reader.eof:
                return app.quit()
            notifier.setEnabled(True)

        notifier = QSocketNotifier(reader.fd, QSocketNotifier.Read)
        notifier.setEnabled(False)
        notifier.activated.connect(readable)
        watch = QTimer()
        watch.timeout.connect(lambda: app.quit() if owner.gone() else None)
        watch.start(OWNER_CHECK_MS)
        # Inside the event loop, so that a "quit" in the first lines works.
        QTimer.singleShot(0, start)
        if TEST_HOOK:
            TEST_HOOK(app, self.shell, self.host)
        app.exec()


def _make_host(on_reply):
    """What Shell.qml sees: what to show, and reply() to answer, which
    calls ON_REPLY(id, status, answer)."""
    from PySide6.QtCore import QObject, Signal, Slot

    class Host(QObject):
        request = Signal(str, str, str, "QVariant")     # id, mode, page URL, input
        busy = Signal(str)                               # label ("" for the default)
        park = Signal(bool)                              # hidden while the progress window shows

        @Slot(str, int, "QVariant")
        def reply(self, rid, status, answer):
            if hasattr(answer, "toVariant"):
                answer = answer.toVariant()
            on_reply(rid, status, answer)

    return Host()


class _Progress:
    """The scan's progress window (qml/Progress.qml, made on first use) and
    its tray icon, and the progress lines they show."""

    def __init__(self, ui):
        self.ui = ui
        self.win = self.tray = self.menu = self.status = None
        self.open = False

    def start(self, heading):
        """Show the window with HEADING; False if it cannot be made."""
        if self.win is None:
            self.win = self.ui.load("Progress.qml", {"iconSource": self.ui.icon_url})
            if self.win is None:
                return False
            self._make_tray()
        if heading:
            self.win.setProperty("heading", heading[:160])
        if self.tray:
            self.tray.show()
        self.open = True
        self.show()
        return True

    def _make_tray(self):
        from PySide6.QtGui import QIcon
        from PySide6.QtWidgets import QMenu, QSystemTrayIcon
        if not QSystemTrayIcon.isSystemTrayAvailable():
            return
        # The one-colour icon, which Plasma recolours for the panel.
        sym = QIcon.fromTheme("bazzite-security-check-symbolic")
        if sym.isNull():
            sym = QIcon()
            sym.addFile(os.path.join(HERE, "icons", "bazzite-security-check-symbolic.svg"))
            sym.addFile(os.path.join(HERE, "icons", "22x22", "bazzite-security-check-symbolic.svg"))
        self.tray = QSystemTrayIcon(sym)
        self.menu = QMenu()         # kept: the tray icon does not own it
        self.status = self.menu.addAction("Security Check is starting…")
        self.status.setEnabled(False)
        self.menu.addSeparator()
        self.menu.addAction("Show progress", self.show)
        self.tray.setContextMenu(self.menu)
        # A left click shows the window; a right click only opens the menu.
        self.tray.activated.connect(
            lambda reason: self.show() if reason == QSystemTrayIcon.ActivationReason.Trigger else None)
        self.tray.setToolTip("Security Check")
        self.win.setProperty("canHide", True)

    def show(self):
        self.win.show()
        self.win.raise_()
        self.win.requestActivate()

    @staticmethod
    def parse(line):
        """(percent or -1, slow, label, detail) of a progress line."""
        f = line.split("\t") + ["", "", ""]
        pct = f[0]
        ok = pct.isascii() and pct.isdigit() and len(pct) <= 3 and int(pct) <= 100
        return (int(pct) if ok else -1), f[1] == "1", f[2][:160], f[3][:300]

    def line(self, line):
        """Show a progress line; False when the window is not open."""
        if not self.open:
            return False
        percent, slow, label, detail = self.parse(line)
        self.win.setProperty("percent", percent)
        self.win.setProperty("slow", slow)
        self.win.setProperty("label", label or "Working…")
        self.win.setProperty("detail", detail)
        if self.tray:
            tip = "Security Check: " + ("%d%% - " % percent if percent >= 0 else "") + (label or "working")
            self.status.setText(tip.replace("&", "&&"))
            self.tray.setToolTip(tip)
        return True

    def close(self):
        if self.open:
            self.open = False
            self.win.hide()
            if self.tray:
                self.tray.hide()


class _Serve:
    """"app.py serve": what each line from the root side does. A line can
    hold several of the keys; they are handled in the order of KEYS."""

    def __init__(self, wfd):
        self.wfd = wfd
        self.ui = _Ui(self.reply)
        self.progress = _Progress(self.ui)
        self.host = self.ui.host

    def send(self, rid, status, answer):
        """One answer line for the root side, always in this exact form."""
        # An answer that is not JSON (a page passed a date, a function, NaN)
        # is a page that failed: the root side falls back, it never waits.
        try:
            text = json.dumps(answer, allow_nan=False)
        except (TypeError, ValueError):
            _say("app.py: the answer of %s is not JSON" % (rid or "a page"))
            status, text = 3, "null"
        try:
            _write_all(self.wfd, ('{"id":%s,"status":%d,"answer":%s}\n' % (json.dumps(rid), status, text)).encode())
        except OSError:
            self.ui.app.quit()      # the root side has gone

    def reply(self, rid, status, answer):
        """The page's answer (Host.reply)."""
        self.send(rid, status if status in (0, 1) else 3, answer if status == 0 else None)

    def line(self, line):
        """One line from the root side. Whatever goes wrong with it, the
        root side gets an answer: it must never wait for ever."""
        if not line.strip():
            return
        try:
            msg = json.loads(line)
        except ValueError:
            msg = None
        if not isinstance(msg, dict) or not any(k in msg for k in KEYS):
            _say("app.py: a line that is not a request was refused")
            return self.send("", 3, None)
        try:
            for key in KEYS:
                if key in msg and getattr(self, "on_" + key)(msg) is False:
                    break
        except Exception:
            _say()
            self.send(_request_id(msg), 3, None)

    def on_quit(self, msg):
        if msg["quit"]:
            self.ui.app.quit()
            return False            # nothing else in this line counts

    def on_theme(self, msg):
        if isinstance(msg["theme"], str):
            self.ui.set_theme(msg["theme"])

    def on_progress(self, msg):
        what = msg["progress"]
        if what == "start":
            if self.progress.start(_heading(msg)):
                self.host.park.emit(True)
            else:
                self.host.busy.emit("")
        elif what == "set" and isinstance(msg.get("line"), str):
            if not self.progress.line(msg["line"]):
                # No progress window here: the main window's spinner says it.
                self.host.busy.emit(_Progress.parse(msg["line"])[2])
        # "stop": the progress window stays (at "Done") until the next
        # page or spinner is there, so there is never a moment with no
        # window at all.

    def on_busy(self, msg):
        label = msg["busy"]
        if not isinstance(label, str):
            return
        # The progress window, if it is what shows, makes way for the main
        # window. A label asks for the spinner now; "" only puts the usual
        # label back, and the Shell does not bring back a window the person
        # has closed for it.
        self.show_window()
        self.host.busy.emit(label[:200])

    def on_mode(self, msg):
        rid, page, data = _request_id(msg), msg["mode"], msg.get("data")
        if not rid:
            return self.send("", 3, None)
        if not isinstance(page, str) or page not in PAGES or not isinstance(data, dict):
            return self.send(rid, 3, None)
        self.show_window()
        self.host.request.emit(rid, page, _page_url(page), data)

    def show_window(self):
        """The main window instead of the progress window."""
        self.progress.close()
        self.host.park.emit(False)

    def run(self, first, reader, owner):
        if not self.ui.load_shell():
            return 3
        self.ui.feed(reader, self.line, lambda: self.line(first), owner)
        self.progress.close()
        return 0


class _OnePage:
    """"app.py MODE < json": that one page in the window, then leave."""

    def __init__(self, wfd):
        self.wfd, self.status, self.answer = wfd, None, None
        self.ui = _Ui(self.reply)

    def reply(self, _rid, status, answer):
        self.status, self.answer = status, answer
        self.ui.app.quit()

    def run(self, mode, data, reader, owner):
        if not self.ui.load_shell():
            return 3

        def begin():
            self.ui.host.request.emit("one", mode, _page_url(mode), data)
            return False            # the input was the one JSON line

        self.ui.feed(reader, lambda line: None, begin, owner)
        if self.status == 0:
            try:
                text = json.dumps(self.answer, allow_nan=False)
            except (TypeError, ValueError):
                _say("app.py: the answer of the page is not JSON")
                return 3
            _write_all(self.wfd, (text + "\n").encode())
            return 0
        return 3 if self.status == 3 else 1


class _ProgressOnly:
    """"app.py progress": the progress window alone, fed progress lines."""

    def __init__(self):
        self.ui = _Ui(lambda *reply: None)
        self.progress = _Progress(self.ui)
        self.status = 0

    def line(self, line):
        if line == "QUIT":
            self.ui.app.quit()
        else:
            self.progress.line(line)

    def run(self, data, reader, owner):
        def begin():
            if not self.progress.start(_heading(data)):
                self.status = 3
                self.ui.app.quit()
                return False

        self.ui.feed(reader, self.line, begin, owner)
        self.progress.close()
        return self.status


def _run(mode, reader, wfd, owner, line=None, data=None):
    """Start Qt and run MODE: "serve" with LINE, the first line that was
    read; any other mode with DATA, the JSON object that was read."""
    os.environ.setdefault("QT_QUICK_CONTROLS_STYLE", "org.kde.desktop")
    # Without this Qt keeps its warnings (a page that does not load) to
    # itself when stderr is not a terminal; the root side wants them.
    os.environ.setdefault("QT_FORCE_STDERR_LOGGING", "1")
    try:
        import PySide6.QtQml        # noqa: F401
        import PySide6.QtWidgets    # noqa: F401
    except ImportError:
        return 3
    if mode == "serve":
        return _Serve(wfd).run(line, reader, owner)
    if mode == "progress":
        return _ProgressOnly().run(data, reader, owner)
    return _OnePage(wfd).run(mode, data, reader, owner)


if __name__ == "__main__":
    # A crash is "cannot run here" (3), never "cancelled" (1): the caller
    # then falls back to the kdialog questions instead of quitting.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        _say()
        sys.exit(3)
