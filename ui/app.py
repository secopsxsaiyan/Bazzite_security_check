#!/usr/bin/python3 -I
# Security Check - the Kirigami front end (wizard, settings, tray icon).
#
# Runs as the desktop user, never as root. The root side of the tool starts
# it with a JSON description of what to show on stdin, and reads the
# person's answers as one JSON object on stdout; the root side validates
# every value it takes from it. Exit status 0: answered, 1: cancelled,
# 3: this front end cannot run here (the caller falls back to kdialog).
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
#           A line that is not a request gets {"id":"","status":3,...}.
#       {"busy": "LABEL"}       nothing to answer: the last page stays, dimmed,
#                               with a spinner and LABEL ("" for "Working…")
#       {"progress": "start", "heading": "..."}   the scan: the window makes
#       {"progress": "set", "line": "..."}        way for the small progress
#       {"progress": "stop"}                      window and its tray icon,
#                               which stay until the next page (a progress
#                               line is the one "app.py progress" takes)
#       {"theme": "system|light|dark"}            switch colours
#       {"quit": true}          leave (as EOF does)
#     Nothing is loaded and no window exists before the first line arrives.
#
# The same window for one page (also what the root side uses when the
# long-lived front end is not running):
#
#   app.py wizard    < {"facts": ..., "detected": ..., "answers": ...}
#   app.py settings  < {"version": ..., "theme": ..., "repo": ...}
#   app.py dashboard < {"score": ..., "areas": [...], "checks": [...], ...}
#   app.py check     < {"title": ..., "notes": [...], "findings": [...]}
#   app.py choose    < {"title": ..., "intro": ..., "items": [{tag, label, ...}]}
#   app.py confirm   < {"title": ..., "now": ..., "commands": ..., ...}
#   app.py dialog    < {"kind": ..., "title": ..., "html": ..., "buttons": [...]}
#   app.py progress  < {"heading": ...}, then progress lines until EOF:
#                      "PERCENT<TAB>SLOW<TAB>LABEL<TAB>DETAIL" (PERCENT "-"
#                      for no steps, SLOW 1 for a long step); a window and a
#                      tray icon show them
#   app.py theme-dir THEME   prints a config folder whose kdeglobals uses
#                            THEME's colours (for kdialog: XDG_CONFIG_HOME)
import json
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
SCHEMES = {"light": "BreezeLight", "dark": "BreezeDark"}
PAGES = {"wizard": "Wizard.qml", "settings": "Settings.qml", "dashboard": "Dashboard.qml",
         "check": "Check.qml", "choose": "Choose.qml", "confirm": "Confirm.qml", "dialog": "Dialog.qml"}
MODES = tuple(PAGES) + ("progress", "serve")
# For the tests only: a folder to take the page files from, and a function
# called with (app, shell window, front end) once the window exists.
PAGE_DIR = os.environ.get("BSA_UI_PAGES") or os.path.join(HERE, "qml")
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
    for line in open(path, encoding="utf-8"):
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

    def first(self):
        """The first line (waits for it); None when there is none. Lines
        that came with it are kept in .pending."""
        while not self.eof:
            lines = self.more()
            if lines:
                self.pending = lines[1:]
                return lines[0]
        rest, self.buf = self.buf, b""
        return rest.decode("utf-8", "replace") if rest else None


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "theme-dir" and sys.argv[2] in SCHEMES:
        return _theme_dir(sys.argv[2])
    if len(sys.argv) != 2 or sys.argv[1] not in MODES:
        print("usage: app.py %s|theme-dir light|dark" % "|".join(MODES), file=sys.stderr)
        return 2
    mode = sys.argv[1]
    # The two pipes to the root side are moved away from stdin and stdout:
    # a program this one starts (a KDE helper) must not get a copy, or the
    # root side would still wait for an answer after a crash here; and
    # nothing a library prints can end up among the answers.
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
    first = reader.first()
    if mode == "serve":
        return 0 if first is None else _gui(mode, first, reader, wfd)
    try:
        data = json.loads(first or "{}")
    except ValueError:
        return 2
    if not isinstance(data, dict):
        return 2
    return _gui(mode, data, reader, wfd)


def _gui(mode, first, reader, wfd):
    """mode "serve": pages as the root side asks for them (FIRST is its
    first line); "progress": the progress window alone, fed progress lines;
    else that one page with FIRST as its input."""
    os.environ.setdefault("QT_QUICK_CONTROLS_STYLE", "org.kde.desktop")
    try:
        from PySide6.QtCore import QObject, QSocketNotifier, QTimer, QUrl, Signal, Slot
        from PySide6.QtGui import QIcon, QPalette
        from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon
        from PySide6.QtQml import QQmlApplicationEngine
    except ImportError:
        return 3

    app = QApplication(sys.argv[:1])

    def set_theme(theme):
        scheme = _scheme_path(theme)
        # KDE's colour code (and so Kirigami) reads the scheme from this
        # application property, as KColorSchemeManager sets it.
        app.setProperty("KDE_COLOR_SCHEME_PATH", scheme or "")
        app.setPalette(_palette(scheme) if scheme else QPalette())

    if _scheme_path(os.environ.get("BSA_THEME", "system")):
        set_theme(os.environ["BSA_THEME"])
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
    icon_url = QUrl.fromLocalFile(os.path.join(HERE, "icons", "bazzite-security-check.svg")).toString()
    engine = QQmlApplicationEngine()
    result = {"status": None, "answer": None}

    def send(rid, status, answer):
        """One answer line for the root side, always in this exact form."""
        try:
            text = json.dumps(answer)
        except (TypeError, ValueError):
            status, text = 3, "null"
        line = ('{"id":%s,"status":%d,"answer":%s}\n' % (json.dumps(rid), status, text)).encode()
        try:
            while line:
                line = line[os.write(wfd, line):]
        except OSError:
            app.quit()      # the root side has gone

    class Host(QObject):
        """What Shell.qml sees: what to show, and reply() to answer."""
        request = Signal(str, str, str, "QVariant")     # id, mode, page URL, input
        busy = Signal(str)                               # label ("" for the default)
        park = Signal(bool)                              # hidden while the progress window shows

        @Slot(str, int, "QVariant")
        def reply(self, rid, status, answer):
            if hasattr(answer, "toVariant"):
                answer = answer.toVariant()
            if mode == "serve":
                send(rid, status if status in (0, 1) else 3, answer if status == 0 else None)
            else:
                result["status"], result["answer"] = status, answer
                app.quit()

    host = Host()
    shell = None
    if mode != "progress":
        engine.setInitialProperties({"host": host, "iconSource": icon_url})
        engine.load(QUrl.fromLocalFile(os.path.join(HERE, "qml", "Shell.qml")))
        if not engine.rootObjects():
            return 3
        shell = engine.rootObjects()[0]

    # ---- the scan's progress window and its tray icon ---------------------
    prog = {"win": None, "tray": None, "status": None, "open": False}

    def prog_show():
        win = prog["win"]
        win.show()
        win.raise_()
        win.requestActivate()

    def prog_start(heading):
        """Show the progress window (made on first use); False if it cannot."""
        if prog["win"] is None:
            before = len(engine.rootObjects())
            engine.setInitialProperties({"iconSource": icon_url})
            engine.load(QUrl.fromLocalFile(os.path.join(HERE, "qml", "Progress.qml")))
            if len(engine.rootObjects()) == before:
                return False
            prog["win"] = engine.rootObjects()[-1]
            # The one-colour icon, which Plasma recolours for the panel.
            sym = QIcon.fromTheme("bazzite-security-check-symbolic")
            if sym.isNull():
                sym = QIcon()
                sym.addFile(os.path.join(HERE, "icons", "bazzite-security-check-symbolic.svg"))
                sym.addFile(os.path.join(HERE, "icons", "22x22", "bazzite-security-check-symbolic.svg"))
            if QSystemTrayIcon.isSystemTrayAvailable():
                tray = prog["tray"] = QSystemTrayIcon(sym)
                menu = prog["menu"] = QMenu()
                prog["status"] = menu.addAction("Security Check is starting…")
                prog["status"].setEnabled(False)
                menu.addSeparator()
                menu.addAction("Show progress", prog_show)
                tray.setContextMenu(menu)
                # A left click shows the window; a right click only opens the menu.
                tray.activated.connect(lambda reason: prog_show()
                                       if reason == QSystemTrayIcon.ActivationReason.Trigger else None)
                tray.setToolTip("Security Check")
                prog["win"].setProperty("canHide", True)
        if heading:
            prog["win"].setProperty("heading", heading[:160])
        if prog["tray"]:
            prog["tray"].show()
        prog["open"] = True
        prog_show()
        return True

    def prog_line(line):
        f = line.split("\t")
        while len(f) < 4:
            f.append("")
        pct, slow, label, detail = f[0], f[1] == "1", f[2][:160], f[3][:300]
        if not prog["open"]:
            # No progress window here: the main window's spinner says it.
            host.busy.emit(label)
            return
        win = prog["win"]
        win.setProperty("percent", int(pct) if pct.isdigit() and int(pct) <= 100 else -1)
        win.setProperty("slow", slow)
        win.setProperty("label", label or "Working…")
        win.setProperty("detail", detail)
        if prog["tray"]:
            tip = "Security Check: " + ("%s%% - " % pct if pct.isdigit() else "") + (label or "working")
            prog["status"].setText(tip.replace("&", "&&"))
            prog["tray"].setToolTip(tip)

    def prog_close():
        if prog["open"]:
            prog["open"] = False
            prog["win"].hide()
            if prog["tray"]:
                prog["tray"].hide()

    # ---- what the root side sends ----------------------------------------
    def bad():
        send("", 3, None)

    def serve_line(line):
        if not line.strip():
            return
        try:
            msg = json.loads(line)
        except ValueError:
            return bad()
        if not isinstance(msg, dict):
            return bad()
        if msg.get("quit"):
            return app.quit()
        if isinstance(msg.get("theme"), str):
            set_theme(msg["theme"])
        if "progress" in msg:
            what = msg["progress"]
            if what == "start":
                heading = msg.get("heading")
                if prog_start(heading if isinstance(heading, str) else ""):
                    host.park.emit(True)
                else:
                    host.busy.emit("")
            elif what == "set" and isinstance(msg.get("line"), str):
                prog_line(msg["line"])
            # "stop": the progress window stays (at "Done") until the next
            # page or spinner is there, so there is never a moment with no
            # window at all.
        if isinstance(msg.get("busy"), str):
            # A label asks for the spinner now; "" only puts the usual
            # label back.
            if msg["busy"] or prog["open"]:
                prog_close()
                host.park.emit(False)
            host.busy.emit(msg["busy"][:200])
        if "mode" in msg:
            rid, page, data = msg.get("id"), msg.get("mode"), msg.get("data")
            if not isinstance(rid, str) or not rid or len(rid) > 64 \
               or not all(c.isascii() and (c.isalnum() or c in "-_") for c in rid):
                return bad()
            if page not in PAGES or not isinstance(data, dict):
                return send(rid, 3, None)
            prog_close()
            host.park.emit(False)
            host.request.emit(rid, page, QUrl.fromLocalFile(os.path.join(PAGE_DIR, PAGES[page])).toString(), data)

    def on_line(line):
        if mode == "serve":
            serve_line(line)
        elif line == "QUIT":
            app.quit()
        else:
            prog_line(line)

    def readable():
        for line in reader.more():
            on_line(line)
        if reader.eof:
            notifier.setEnabled(False)
            app.quit()

    def begin():
        if mode == "serve":
            on_line(first)
        elif mode == "progress":
            heading = first.get("heading")
            if not prog_start(heading if isinstance(heading, str) else ""):
                result["status"] = 3
                return app.quit()
        else:
            host.request.emit("one", mode, QUrl.fromLocalFile(os.path.join(PAGE_DIR, PAGES[mode])).toString(), first)
            return
        for line in reader.pending:
            on_line(line)
        if reader.eof:
            return app.quit()
        notifier.setEnabled(True)

    notifier = QSocketNotifier(reader.fd, QSocketNotifier.Read)
    notifier.setEnabled(False)
    notifier.activated.connect(readable)
    # Inside the event loop, so that a "quit" in the first lines works.
    QTimer.singleShot(0, begin)
    if TEST_HOOK:
        TEST_HOOK(app, shell, host)
    app.exec()
    prog_close()
    if mode == "serve":
        return 0
    if mode == "progress":
        return result["status"] or 0
    if result["status"] == 0:
        os.write(wfd, (json.dumps(result["answer"]) + "\n").encode())
        return 0
    return 3 if result["status"] == 3 else 1


if __name__ == "__main__":
    # A crash is "cannot run here" (3), never "cancelled" (1): the caller
    # then falls back to the kdialog questions instead of quitting.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(3)
