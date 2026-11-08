# Optimization pass (2026-11-08)

Owner-authorized follow-up to the read-only repository review.

Scope:

1. Compact `STATUS.md` to current facts, open items, boundaries and inventory; remove the
   dated journal entries that Git already preserves, and correct the stale current-HEAD note.
2. Centralize the generated/temporary path prefixes and the Codex live-root rule in
   `scripts/repo-common.ps1`; keep every existing value and refusal behavior unchanged.
3. Make `Get-SkillDirectories` fail on enumeration errors instead of treating an unreadable
   source root as empty.
4. Remove duplicated approval-feedback usage detail from `README.md` and `docs/README.md`,
   leaving concise links to the canonical skill references.

Expected checks: `git diff --check`, `scan-secrets.ps1`, syntax gate, affected suites
(build-skills, deploy-skills, doctor, repository-policy, scan-secrets), then full
`run-tests.ps1` and `run-repository-validation.ps1` one at a time. This task does not include
a live skills Apply or config Apply.