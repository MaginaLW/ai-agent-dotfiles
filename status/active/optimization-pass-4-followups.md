# Fourth optimization pass: leftover follow-ups (2026-10-14)

Owner-approved completion of the five items left open by the fourth optimization pass:

1. CI workflow: drop the duplicate gitleaks verify step (the validation script re-verifies),
   tighten the 45-minute timeout, add concurrency cancel, and harden the pinned-tool download
   (timeout + retry).
2. deploy-skills: walk each target tree once instead of three to four times.
3. Dry-run API: converge on default-dry-run + `-Apply`; promote-skill loses its redundant
   `-DryRun` switch and the CLI wrapper strips uniformly.
4. Error output: fatal script errors go to stderr consistently.
5. scan-secrets: restructure the 131-line top-level try block into named passes.

Push and the confirming CI run still need the owner's authorization at the end.
