# Fourth optimization pass (2026-10-13)

Owner-approved optimization pass from the 2026-10-13 repository review, committed in themed
steps; grok reviews the diff before the task closes.

Scope:

1. tests: fix the syntax-gate suite's inverted inner timeout (120 s child limit inside a 90 s
   suite budget).
2. scripts: one shared policy module (`repo-common.ps1`) for the protected Reasonix paths, the
   binary-extension list and the drive/UNC path patterns, currently duplicated across
   scan-secrets, check-powershell-syntax, doctor, run-repository-validation, config-push and
   harness-profile-common. The lists themselves do not change.
3. scripts: de-duplicate the config-pull/config-push plan pipeline and the scan-secrets
   subprocess gate (shared `Invoke-SecretScanGate`/`Invoke-RepoScript`).
4. tests: failure-path coverage for pinned-tool and build-skills; suite timeout rebalance.
5. docs: align the environment schema documentation with the code; drop the dead engine-era
   `Profile` field from `harness-source/envs/*.psd1`.

Out of scope this pass (candidate follow-ups): CI workflow tweaks (duplicate gitleaks verify
step, 45-minute timeout, concurrency cancel), deploy-skills repeated tree walks, dry-run API
unification, error-output conventions.
