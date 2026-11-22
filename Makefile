.PHONY: lint test test-ui shellcheck.sarif

SHELLCHECK_ARGS := -x -S warning -e SC2034 bazzite-sec-audit.sh lib/*.sh checks/*.sh tests/smoke.sh tests/ui-e2e.sh tests/ui/readme-confirm.sh

# ShellCheck every script (modules are followed from the entry script).
lint:
	shellcheck $(SHELLCHECK_ARGS)
	python3 -c "import ast, sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]" ui/app.py tests/ui-offscreen.py tests/ui/e2e-front.py

# The same findings as SARIF, for GitHub code scanning. ShellCheck exits
# non-zero when it finds something; the file is still written then, and
# `make lint` is what fails the build.
shellcheck.sarif:
	shellcheck -f json1 $(SHELLCHECK_ARGS) | .github/scripts/shellcheck-sarif.py > $@

# Simulated Bazzite PC with stubbed tools. Needs root and creates a test
# user: run it only in a throwaway container or VM.
#
# The suite runs with SIGPIPE as it finds it: at its default from a
# terminal, ignored on a CI runner. The tool is started both ways too (a
# systemd service has it ignored), and bash cannot change it afterwards, so
# both must pass. For the state you are not in:
#   env --ignore-signal=PIPE make test    env --default-signal=PIPE make test
test:
	sudo tests/smoke.sh

# The real front end (ui/app.py and every page in ui/qml/) off-screen:
# every page is shown and answered with the keyboard. Needs no root and no
# display, but PySide6 with Qt Quick, Kirigami and qqc2-desktop-style, which
# a Bazzite or Fedora KDE PC has. Not part of `make test`. A scenario by
# name, pictures of the pages: make test-ui UI_TEST_ARGS="--shots /tmp/shots pages"
test-ui:
	python3 -I tests/ui-offscreen.py $(UI_TEST_ARGS)
	bash tests/ui-e2e.sh
