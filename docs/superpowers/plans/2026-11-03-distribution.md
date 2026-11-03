# Self-service installer implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement task-by-task.

**Goal:** Add preflight, useful diagnostics, link/QR recovery, encrypted backups and safe recovery/update controls to one Bash file.
**Architecture:** Keep the distributable script self-contained. Add Bash functions and embedded Python for parsing untrusted data; external OS utilities remain installed by apt. Each menu action continues in a fresh process.
**Tech Stack:** Bash, Python standard library, systemd, OpenSSL, qrencode.
**Spec:** ../specs/2026-11-03-distribution-design.md (approved in chat).

## Global constraints

- Only experimental; do not modify main, v1 or deploy to working VPS.
- One runtime file; no runtime modules, release numbering, changelog or clean-OS test pipeline.
- Never log secrets. No deactivation menu.
- Existing names, ports and profiles remain compatible.

## Review focus

- Hostile archive paths/symlinks and duplicate/conflicting profiles: restore must reject before writes.
- Wrong password or modified encrypted backup: reject without touching live profiles.
- Private repository/API failure or HTML response: self-update must not replace the script.
- Interrupted/failed core updates: restore old core and bound service restarts.
- No connection evidence: diagnosis must not claim a working tunnel from active alone.

### Task 1: preflight, operations journal and diagnosis
Files: openflux-setup.sh, tests/test_installer.py.
- [x] Write and run failing tests for diagnosis classes and sanitized journal.
- [x] Add preflight before mutations, deterministic service discovery and diagnosis classification.
- [x] Run syntax and isolated tests; record result.

### Task 2: link/QR and encrypted backup/restore
Files: openflux-setup.sh, tests/test_installer.py.
- [x] Write and run failing tests for archive traversal/conflicts and restoration without system writes.
- [x] Add repeat link display and local QR, encrypted archives with authentication, validated staged restore and optional start.
- [x] Run isolated tests including wrong-password/tampered backup; record result.

### Task 3: updates and documentation
Files: openflux-setup.sh, README.md, tests/test_installer.py.
- [x] Write and run failing tests for self-update validation and transaction interruption handling.
- [x] Add pre-update backup, bounded restart, manual rollback, SHA-pinned script update.
- [x] Rewrite README and menu descriptions; run all checks and independent review.
- [ ] Commit and publish only experimental; verify remote branch head and unchanged main/v1.
