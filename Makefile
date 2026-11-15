.PHONY: lint test shellcheck.sarif

SHELLCHECK_ARGS := -x -S warning -e SC2034 bazzite-sec-audit.sh lib/*.sh checks/*.sh tests/smoke.sh

# ShellCheck every script (modules are followed from the entry script).
lint:
	shellcheck $(SHELLCHECK_ARGS)
	python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])" ui/app.py

# The same findings as SARIF, for GitHub code scanning. ShellCheck exits
# non-zero when it finds something; the file is still written then, and
# `make lint` is what fails the build.
shellcheck.sarif:
	shellcheck -f json1 $(SHELLCHECK_ARGS) | .github/scripts/shellcheck-sarif.py > $@

# Simulated Bazzite PC with stubbed tools. Needs root and creates a test
# user: run it only in a throwaway container or VM.
test:
	sudo tests/smoke.sh
