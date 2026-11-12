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
4. If you add or change reporting output, check that it remains readable and safe to share.

## Issue reports

Use the issue templates when filing bug reports. Please include:

- exact Bazzite image and version
- whether the bug happened in GUI or terminal mode
- the command used
- what you expected vs. what happened
- any relevant logs or redacted report excerpts

## Security reports

Do not open a public issue for a vulnerability. Follow `SECURITY.md` instead.
