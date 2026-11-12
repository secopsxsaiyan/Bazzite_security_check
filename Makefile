.PHONY: lint test

# ShellCheck every script (modules are followed from the entry script).
lint:
	shellcheck -x -S warning -e SC2034 bazzite-sec-audit.sh lib/*.sh checks/*.sh tests/smoke.sh
	python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])" ui/app.py

# Simulated Bazzite PC with stubbed tools. Needs root and creates a test
# user: run it only in a throwaway container or VM.
test:
	sudo tests/smoke.sh
