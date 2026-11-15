# Contributing

Thanks for helping improve Bazzite Security Check.

## Scope

This project is focused on Bazzite desktop and related Fedora Atomic images. Contributions should keep the tool aligned with the repository's security goals, documented assumptions, and non-destructive workflow.

## Before you begin

- Read the project overview in `README.md`.
- Keep fixes narrow and explainable.
- Prefer safe defaults and explicit confirmation flows.
- Do not introduce changes that break the tool's "nothing changes without your confirmation" model.

## Development workflow

1. Create a branch for your change.
2. Keep the change small and testable.
3. Run:
   - `make lint`
   - `make test` only in a disposable VM/container, because the smoke test creates a throwaway user and needs root.
   - `make test-ui` if you changed the GUI (see below).
4. If you add or change reporting output, check that it remains readable and safe to share.

## Tests

New functionality comes with tests. A change that adds a check, a fix, an option or a window, or that changes what one of them does, adds or updates tests in `tests/smoke.sh` (and, for the GUI, `tests/ui-offscreen.py`) in the same pull request. A bug fix adds a test that fails without the fix. Pull requests without them are not merged, unless the change cannot be tested there (documentation, CI configuration), and then the pull request says so.

## Working on the GUI

The windows are `ui/app.py` (PySide6) and the pages in `ui/qml/` (Kirigami). [`docs/ui.md`](docs/ui.md) describes how the root side and the window talk, what a page must provide, and how to add one or try one without root. A change to a page, to `ui/app.py` or to the window runs `make test-ui`, which needs no root and no display, and adds or updates checks in `tests/ui-offscreen.py`: a control that answers a page gets a case in the `controls` scenario, with the answer the root side accepts.

## Issue reports

Use the issue templates when filing bug reports. Please include:

- exact Bazzite image and version
- whether the bug happened in GUI or terminal mode
- the command used
- what you expected vs. what happened
- any relevant logs or redacted report excerpts

## Security reports

Do not open a public issue for a vulnerability. Follow `SECURITY.md` instead.
