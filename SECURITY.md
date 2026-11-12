# Security Policy

## Supported versions

The project currently supports Bazzite and related Fedora Atomic desktop images, and the tool is intended for personal desktop use rather than server hardening.

We do not provide security support guarantees for unpublished or unsupported snapshots, or for modifications outside the repository's documented Bazzite-compatible workflows.

## Reporting a vulnerability

Please do not open a public GitHub issue for security-sensitive problems. Instead, report them privately.

Use one of these routes:

- Create a private security advisory in the GitHub repository security tab, if available for the repository.
- Or email the maintainer directly using the email address attached to the GitHub account for this repository.

Include:

- a short description of the issue
- affected version or commit
- affected operating system / image details
- reproduction steps or proof of concept
- impact assessment and suggested remediation

We will acknowledge valid reports within 5 business days and work toward a resolution as quickly as possible.

## Responsible disclosure

Please allow time for a fix to be developed and shipped before posting any public details. Security fixes should be coordinated responsibly to avoid exposing users to unnecessary risk.

## Safe use guidance

This tool reads system configuration, account metadata, firewall state, and other security-sensitive data. It also applies root-level changes only after explicit confirmation. If you discover a bug that could cause unintended system changes, unsafe access, or report disclosure, follow the private reporting process above.
