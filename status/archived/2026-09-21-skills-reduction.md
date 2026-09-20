# Skills reduction — 2026-09-21

The owner approved the inventory's reduction recommendations. This change keeps
specialist capabilities while reducing the everyday environment's repeated process
instructions. The separate Smallpdf plugin removal returned an `uninstalled`
receipt; it is not a repository-managed skill deployment.

## Changes

- `work` now selects only `systematic-debugging` on Claude, Codex, and Reasonix:
  1/1/1 instead of 2/4/2. Generic review, planning, and brainstorming remain in the
  canonical library for deliberate selection; AGENTS continues to govern ordinary
  planning, delegation, review, and verification.
- All 15 canonical skills and platform manifests are retained. `full`, `minimal`,
  the task overlay, specialist writing/security tools, and browser components are
  not removed or reconfigured.
- Brainstorming is scoped to unresolved design decisions and no longer inserts
  repeated approval gates into already-authorized routine work.
- Systematic debugging uses self-contained regression-test guidance instead of
  a missing Superpowers dependency and points to the existing verification skill.
- The usage guide distinguishes conditional interlocked behavior from the current
  unaccepted release candidate and links to the authoritative current-state entry.

## Validation

- Both changed skills passed the Skill Creator frontmatter validator using UTF-8.
- `build-skills.ps1` passed: Claude 7, Codex 15, Reasonix 7; tracked manifests unchanged.
- `scan-secrets.ps1` passed with pinned gitleaks and no blocking findings.
- `check-powershell-syntax.ps1` passed for 179 files.
- `build-harness-env.ps1` passed for work, minimal, and full; status reports all
  three definitions and locks valid. The materialized work output contains only
  systematic-debugging on all three platforms. No environment is activated.
- Internal-host sandbox `sync.ps1 -DryRun` passed with schema 3, operation initial,
  environment full, 29 additions and no updates or pruning. Build and scan had
  already passed and were not repeated inside that producer. This validates the
  required isolated plan path, not a deployment plan for the actual machine.
- Relative file links in README and STATUS passed; `git diff --check` passed.
- Independent review found no actionable issue in the final source/config/docs diff.
- Targeted `harness-env.tests.ps1`: **308 passed, 3 failed**, exit 1. Two assertions
  (lines 468 and 893) always expect `safety-protocol-upgrade-required`; the public
  rollback assertion expects sandbox-only host resolution. The audit baseline
  `67bfdc6` already carries `ReleaseState=released`, which changes these paths.
  These cases use fixture environments, not the modified work definition. Policy,
  activation/rollback code, and the test are unchanged. The corresponding no-plan
  or unchanged-state assertions passed. The failed workspace was retained outside
  the repository for inspection; this is not a green regression or release gate.
- Full regression and remote CI were not run for this source/config/docs cleanup.

## Boundaries

No managed live skills were installed, removed, or synchronized. No protected
`.system` content, personal skill, credentials, MCP registration, or global
configuration was edited by repository scripts. Smallpdf was removed through the
supported plugin uninstaller, not by deleting cache files.

The candidate's release lab and remaining Task 8 acceptance steps are not part of
this cleanup. Local checks do not establish production acceptance or remote CI.

## Follow-up: policy-independent environment regression

The owner subsequently requested a fix for the three failed assertions. The
environment suite now exercises both `interlocked` and `released` policies in
temporary script copies rather than assuming the checkout remains interlocked.
Only each fixture's policy and two OS home-location adapters are substituted; the
production policy, public entrypoints, plan validation, host resolver, and
authority checks are unchanged.

The missing-plan case checks the interlock diagnostic or `activation-plan-not-found`
and proves identity was not resolved. The reviewed-plan case retains real static
plan validation, then checks the interlock or `live-plan-authority-missing` against
an empty isolated home. Rollback checks both DryRun and Apply under both policies,
including the precise host/authority diagnostic and whether identity was called.
Home files and directories, repository content, plans, and existing authority
state are checked for unintended changes. No fixed diagnostic was replaced with
an arbitrary nonzero-exit assertion.

The home adapter keeps the current token SID for Windows security semantics but
resolves every home/AppData path inside the disposable fixture. Public-path child
processes clear inherited internal sandbox variables to test the intended branch.
This does not establish real-machine release acceptance.

During validation, a fixture-toolchain Git initialization omission caused canonical
path validation to return `manual-recovery-required`. The inner exception was
diagnosed and the fixture corrected; the expected authority diagnostic was not
weakened to accept that incidental error.

Final validation: `pwsh -NoProfile -File tests/harness-env.tests.ps1` completed
with **339 passed, 0 failed**, exit 0, on the final test implementation. PowerShell
syntax validation passed for 179 files; pinned secret scan and whitespace checks
passed; independent review found no actionable issue. This supersedes the three
failures from the earlier cleanup run for this suite. The full repository suite
collection and remote CI were not run for this test-only correction. No production
script or policy was changed, and no real deployment or release lab was run.
