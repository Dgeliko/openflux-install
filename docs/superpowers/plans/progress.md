# SDD ledger — plan: docs/superpowers/plans/2026-11-03-distribution.md
Pre-flight: helper functions for path validation/service discovery are shared across tasks; implement once before lifecycle actions.
Ruling: inline execution; use an isolated clone on experimental rather than changing the untracked main workspace. No working-server mutations.
Ruling: keep existing embedded Python blocks; the user requests one distributed Bash file, not removal of existing Python dependency.

Task 1: complete — preflight, safe journal and evidence-based diagnosis; isolated tests pass.
Task 2: complete — saved link/QR, authenticated encrypted backup, staged validated restore; wrong-password, tamper, archive traversal, symlink, conflict tests pass.
Task 3: implementation complete — backup-gated updates, bounded restart, manual rollback, SHA-pinned self-update and README.
Ruling: preserve existing embedded Python standard library usage inside one Bash file. No runtime modules or third-party Python packages.
Ruling: backup restore deliberately standardizes service templates and does not import arbitrary firewall rules or binaries; documented limits avoid executing archive-supplied units.
Review fix: explicit failure checks in backup_profiles because calls in || suppress Bash errexit. Regression observed failing, then passing.
Verification: bash -n; 12 unittest cases passed on local temporary fixtures. Not tested on fresh OS or deployed on working VPS.
Review: independent reviewer found no remaining critical/important issues after explicit temporary-directory guards and streamed archive limits. Injected partial restore failure preserved unrelated files. Final verification: 14 tests pass; bash -n and git diff --check pass.
Task 3: complete pending publication verification. No clean OS pipeline, release numbering, changelog, or live-server deployment added.
