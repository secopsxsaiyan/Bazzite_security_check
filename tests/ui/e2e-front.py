#!/usr/bin/python3
# The real front end (ui/app.py) with a hand at the keyboard, for
# tests/ui-e2e.sh: once a page takes keys, it presses the key named in
# E2E_KEY ("enter" or "esc") through Qt's own key path.
import importlib.util
import os
import sys

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ui", "app.py")
spec = importlib.util.spec_from_file_location("bsa_ui_app", APP)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def hook(app, shell, host):
    from PySide6.QtCore import QTimer, Qt
    from PySide6.QtTest import QTest

    def tick():
        if shell is not None and shell.property("pendingId") and not shell.property("settling"):
            QTest.keyClick(shell, Qt.Key_Escape if os.environ.get("E2E_KEY") == "esc" else Qt.Key_Return)
    timer = QTimer()
    timer.timeout.connect(tick)
    timer.start(150)
    hook.keep = timer


mod.TEST_HOOK = hook
sys.argv = ["app.py"] + sys.argv[1:]
sys.exit(mod.main())
