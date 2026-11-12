#!/usr/bin/python3 -I
# Security Check - the Kirigami front end (wizard, settings, tray icon).
#
# Runs as the desktop user, never as root. The root side of the tool starts
# it with a JSON description of what to show on stdin, and reads the
# person's answers as one JSON object on stdout; the root side validates
# every value it takes from it. Exit status 0: answered, 1: cancelled,
# 3: this front end cannot run here (the caller falls back to kdialog).
#
#   app.py wizard    < {"facts": ..., "detected": ..., "answers": ...}
#   app.py settings  < {"version": ..., "theme": ..., "repo": ...}
#   app.py dashboard < {"score": ..., "areas": [...], "checks": [...], ...}
#   app.py check     < {"title": ..., "notes": [...], "findings": [...]}
#   app.py choose    < {"title": ..., "intro": ..., "items": [{tag, label, ...}]}
#   app.py confirm   < {"title": ..., "now": ..., "commands": ..., ...}
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
QML = {"wizard": "Wizard.qml", "settings": "Settings.qml", "dashboard": "Dashboard.qml", "progress": "Progress.qml",
       "check": "Check.qml", "choose": "Choose.qml", "confirm": "Confirm.qml"}


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


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "theme-dir" and sys.argv[2] in SCHEMES:
        return _theme_dir(sys.argv[2])
    if len(sys.argv) != 2 or sys.argv[1] not in QML:
        print("usage: app.py %s|theme-dir light|dark" % "|".join(QML), file=sys.stderr)
        return 2
    mode = sys.argv[1]
    try:
        data = json.loads(_first_line() or "{}")
    except ValueError:
        return 2
    if not isinstance(data, dict):
        return 2
    theme = os.environ.get("BSA_THEME", "system")
    scheme = _scheme_path(theme)
    os.environ.setdefault("QT_QUICK_CONTROLS_STYLE", "org.kde.desktop")
    try:
        from PySide6.QtCore import QObject, QUrl, Signal, Slot, Property
        from PySide6.QtGui import QIcon
        from PySide6.QtWidgets import QApplication
    except ImportError:
        return 3

    app = QApplication(sys.argv)
    if scheme:
        # KDE's colour code (and so Kirigami) reads the scheme from this
        # application property, as KColorSchemeManager sets it.
        app.setProperty("KDE_COLOR_SCHEME_PATH", scheme)
        app.setPalette(_palette(scheme))
    app.setApplicationName("bazzite-security-check")
    app.setApplicationDisplayName("Security Check")
    app.setDesktopFileName("bazzite-security-check")
    icon = QIcon.fromTheme("bazzite-security-check")
    if icon.isNull():
        icon = QIcon(os.path.join(HERE, "icons", "bazzite-security-check.svg"))
    app.setWindowIcon(icon)

    from PySide6.QtQml import QQmlApplicationEngine

    class Bridge(QObject):
        """What QML sees: the input, and finish()/cancel() to answer."""
        def __init__(self):
            super().__init__()
            self._result = None

        @Property("QVariant", constant=True)
        def input(self):
            return data

        @Property(str, constant=True)
        def iconSource(self):
            return QUrl.fromLocalFile(os.path.join(HERE, "icons", "bazzite-security-check.svg")).toString()

        @Slot("QVariant")
        def finish(self, answers):
            self._result = answers.toVariant() if hasattr(answers, "toVariant") else answers
            app.quit()

        @Slot()
        def cancel(self):
            self._result = None
            app.quit()

    bridge = Bridge()
    engine = QQmlApplicationEngine()
    engine.rootContext().setContextProperty("bridge", bridge)
    qml = QML[mode]
    engine.load(QUrl.fromLocalFile(os.path.join(HERE, "qml", qml)))
    if not engine.rootObjects():
        return 3
    if mode == "progress":
        return _progress(app, engine.rootObjects()[0])
    app.exec()
    if bridge._result is None:
        return 1
    sys.stdout.write(json.dumps(bridge._result) + "\n")
    return 0


_STDIN_REST = b""


def _first_line():
    """The first line of stdin, read without Python's buffering (the
    progress lines after it are read from the same descriptor)."""
    global _STDIN_REST
    buf = b""
    while b"\n" not in buf:
        chunk = os.read(0, 4096)
        if not chunk:
            break
        buf += chunk
    line, _, _STDIN_REST = buf.partition(b"\n")
    return line.decode("utf-8", "replace")


def _progress(app, win):
    """Progress lines on stdin update the window and a tray icon (the
    one-colour icon, which Plasma recolours for the panel). EOF ends it."""
    from PySide6.QtCore import QSocketNotifier
    from PySide6.QtGui import QIcon
    from PySide6.QtWidgets import QMenu, QSystemTrayIcon
    icon = QIcon.fromTheme("bazzite-security-check-symbolic")
    if icon.isNull():
        icon = QIcon()
        icon.addFile(os.path.join(HERE, "icons", "bazzite-security-check-symbolic.svg"))
        icon.addFile(os.path.join(HERE, "icons", "22x22", "bazzite-security-check-symbolic.svg"))
    tray = None
    if QSystemTrayIcon.isSystemTrayAvailable():
        tray = QSystemTrayIcon(icon)
        menu = QMenu()
        status = menu.addAction("Security Check is starting…")
        status.setEnabled(False)
        menu.addSeparator()
        menu.addAction("Show progress", lambda: (win.show(), win.raise_(), win.requestActivate()))
        tray.setContextMenu(menu)
        # A left click shows the window; a right click only opens the menu.
        tray.activated.connect(lambda reason: (win.show(), win.raise_(), win.requestActivate())
                               if reason == QSystemTrayIcon.ActivationReason.Trigger else None)
        tray.setToolTip("Security Check")
        tray.show()
        win.setProperty("canHide", True)

    def apply(line):
        if line == "QUIT":
            app.quit()
            return
        f = line.split("\t")
        while len(f) < 4:
            f.append("")
        pct, slow, label, detail = f[0], f[1] == "1", f[2][:160], f[3][:300]
        win.setProperty("percent", int(pct) if pct.isdigit() and int(pct) <= 100 else -1)
        win.setProperty("slow", slow)
        win.setProperty("label", label or "Working…")
        win.setProperty("detail", detail)
        if tray:
            tip = "Security Check: " + ("%s%% - " % pct if pct.isdigit() else "") + (label or "working")
            status.setText(tip.replace("&", "&&"))
            tray.setToolTip(tip)

    pending = [_STDIN_REST]

    def read():
        chunk = os.read(0, 4096)
        if not chunk:
            app.quit()
            return
        pending[0] += chunk
        *lines, pending[0] = pending[0].split(b"\n")
        for line in lines:
            apply(line.decode("utf-8", "replace"))

    if _STDIN_REST:
        *lines, pending[0] = _STDIN_REST.split(b"\n")
        for line in lines:
            apply(line.decode("utf-8", "replace"))
    notifier = QSocketNotifier(0, QSocketNotifier.Read)
    notifier.activated.connect(read)
    app.setQuitOnLastWindowClosed(False)
    app.exec()
    return 0


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
