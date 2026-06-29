# Project Harness Profiles Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** Implement the first version of project-local harness profiles described in `docs/specs/2026-06-29-project-harness-profiles-design.md`.

**Approach:** Build the feature in conservative layers: source examples and schema fixtures first, then shared validation helpers, then read-only status, generated-output build, project-local apply, tests, and documentation. Keep all writes repo-local or fake-project-local; do not touch live home harness directories.

**Materials:** `docs/specs/2026-06-29-project-harness-profiles-design.md`, `docs/README.md`, `STATUS.md`, `AGENTS.md`, `CLAUDE.md`, `manifests/whitelist.psd1`, `scripts/config-status.ps1`, `scripts/config-pull.ps1`, `scripts/config-push.ps1`, `tests/config-sync.tests.ps1`.

**Validation:** Run the new harness-profile regression test, existing config-sync regression test, secret scan, whitespace check, and read-only/manual dry-run checks against a fake project.

---

### Task 1: Add Harness Source Skeleton And Example Components

**Artifacts / Locations:**
- Create: `harness-source/profiles/base.psd1`
- Create: `harness-source/profiles/coding.psd1`
- Create: `harness-source/components/rules/safe-file-edits/component.psd1`
- Create: `harness-source/components/rules/safe-file-edits/content.md`
- Create: `harness-source/components/rules/no-generated-output-edits/component.psd1`
- Create: `harness-source/components/rules/no-generated-output-edits/content.md`
- Create: `harness-source/components/claude-settings/project-guards/component.psd1`
- Create: `harness-source/components/claude-settings/project-guards/settings.json`
- Create: `harness-source/components/prompts/commit-summary/component.psd1`
- Create: `harness-source/components/prompts/commit-summary/content.md`
- Review: `docs/specs/2026-06-29-project-harness-profiles-design.md`

- [x] **Step 1: Gather schema requirements**

Read: `docs/specs/2026-06-29-project-harness-profiles-design.md`
Extract: required keys for profile and component `.psd1` files, allowed target platforms, allowed ownership modes, and first-version write scope.

- [x] **Step 2: Create minimal source fixtures**

Create the files listed above. Include:
- `SchemaVersion = 1` in every `.psd1`.
- Globally unique component `Id` values.
- `TargetPlatforms` using only `Claude` and `Codex` for the initial examples.
- `Outputs` using `ManagedBlock`, `StructuredMerge`, or `GeneratedOnly`.
- Content that contains no real credentials, tokens, machine-private paths, or home-specific values.

- [x] **Step 3: Verify the source fixtures**

Check:
```powershell
pwsh -NoProfile -File scripts/scan-secrets.ps1
```
Expected: exit code 0 with no blocking secrets. Keyword hints are acceptable only if non-blocking and not from real secret values.

- [x] **Step 4: Record the result**

Mark this task complete only after the new source tree has at least one profile that extends another profile and at least one component for each planned writer type: managed block, structured JSON merge, and generated-only review output.

### Task 2: Implement Shared Harness Profile Helpers

**Artifacts / Locations:**
- Create: `scripts/harness-profile-common.ps1`
- Review: `scripts/config-status.ps1`
- Review: `scripts/config-push.ps1`

- [x] **Step 1: Gather local script patterns**

Read: `scripts/config-status.ps1` and `scripts/config-push.ps1`.
Extract: PowerShell 7 strict-mode pattern, path parameter style, helper naming style, exclusion/path-scan patterns, JSON output approach, and dry-run reporting style.

- [x] **Step 2: Add shared helper functions**

Create `scripts/harness-profile-common.ps1` with functions that support all three harness-profile scripts:
- import and validate `.psd1` data files
- resolve `RepoRoot` and `ProjectRoot`
- load project profile `.agent-harness/profile.psd1`
- resolve `Extends` from `harness-source/profiles/`
- enumerate component directories under `harness-source/components/`
- validate unique component IDs
- validate `Requires` and `Conflicts`
- validate `TargetPlatforms`
- deep-merge profile objects and stable-de-duplicate arrays
- normalize candidate source and target paths
- reject absolute paths, `..` escapes, UNC paths, URL references, and paths that resolve outside allowed roots
- detect machine-private paths using the same drive-letter and UNC classes as `config-push.ps1`
- compute SHA-256 file hashes
- build a structured plan object for status, build, and apply

- [x] **Step 3: Verify helper load behavior**

Check:
```powershell
pwsh -NoProfile -Command ". ./scripts/harness-profile-common.ps1; 'loaded'"
```
Expected: prints `loaded` and exits 0.

- [x] **Step 4: Record the result**

Mark this task complete only after helper functions load without side effects and do not write files when dot-sourced.

### Task 3: Implement Read-Only Status Script

**Artifacts / Locations:**
- Create: `scripts/status-harness-profile.ps1`
- Create: `tests/fixtures/harness-profile/project/.agent-harness/profile.psd1`
- Review: `scripts/config-status.ps1`

- [x] **Step 1: Gather status output requirements**

Read: `docs/specs/2026-06-29-project-harness-profiles-design.md`.
Extract: status report fields: profile location, resolved profiles, resolved components, component issues, target files, ownership modes, permission diffs, generated-output drift, and add/update/skip plan.

- [x] **Step 2: Implement status script**

Create `scripts/status-harness-profile.ps1` with parameters:
```powershell
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $ProjectRoot = (Get-Location).Path,
    [switch] $Json
)
```

Include:
- PowerShell 7 requirement.
- strict mode and stop-on-error behavior.
- read-only plan construction through `harness-profile-common.ps1`.
- human-readable output for normal use.
- JSON output for tests.
- clear failure messages for missing profile, invalid schema, duplicate IDs, missing components, unsupported platforms, conflicts, and unsafe paths.

- [x] **Step 3: Verify read-only behavior**

Check:
```powershell
$before = git status --short
pwsh -NoProfile -File scripts/status-harness-profile.ps1 -ProjectRoot tests/fixtures/harness-profile/project
$after = git status --short
if ($before -ne $after) { throw 'status script changed the working tree' }
```
Expected: status script exits 0 for the valid fixture and does not change `git status`.

- [x] **Step 4: Record the result**

Mark this task complete only after status can produce both human-readable and JSON output for the fixture project.

### Task 4: Implement Build Script For Generated Review Output

**Artifacts / Locations:**
- Create: `scripts/build-harness-profile.ps1`
- Modify: `tests/fixtures/harness-profile/project/.agent-harness/profile.psd1` if the fixture needs additional components
- Review: `scripts/build-skills.ps1`
- Review: `scripts/scan-secrets.ps1`

- [x] **Step 1: Gather generated-output requirements**

Read: `docs/specs/2026-06-29-project-harness-profiles-design.md`.
Extract: generated directory path, expected generated files, manifest fields, safety gates, and the rule that active harness files are not modified by build.

- [x] **Step 2: Implement build script**

Create `scripts/build-harness-profile.ps1` with parameters:
```powershell
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $ProjectRoot = (Get-Location).Path,
    [switch] $Clean
)
```

Include:
- validation through shared helpers
- optional clean of `.agent-harness/generated/` only after verifying the resolved path is inside the project
- generation of `manifest.json`
- generation of `plan.json`
- generated review files for managed blocks and structured settings output
- secret scan over the repository after generated files are written
- machine-private path scan over profile, components, and generated files
- no writes to `AGENTS.md`, `CLAUDE.md`, `.claude/settings.json`, home directories, or live skills directories

- [x] **Step 3: Verify build scope**

Check:
```powershell
pwsh -NoProfile -File scripts/build-harness-profile.ps1 -ProjectRoot tests/fixtures/harness-profile/project -Clean
Test-Path tests/fixtures/harness-profile/project/.agent-harness/generated/manifest.json
Test-Path tests/fixtures/harness-profile/project/AGENTS.md
```
Expected: `manifest.json` exists and `AGENTS.md` is not created by build.

- [x] **Step 4: Record the result**

Mark this task complete only after two consecutive build runs produce equivalent manifest component hashes and no active harness target files are modified.

### Task 5: Implement Apply Script For Project-Local Targets

**Artifacts / Locations:**
- Create: `scripts/apply-harness-profile.ps1`
- Modify: `tests/fixtures/harness-profile/project/AGENTS.md`
- Modify: `tests/fixtures/harness-profile/project/CLAUDE.md`
- Modify: `tests/fixtures/harness-profile/project/.claude/settings.json`
- Review: `scripts/config-pull.ps1`
- Review: `docs/specs/2026-06-29-project-harness-profiles-design.md`

- [x] **Step 1: Gather apply requirements**

Read: `scripts/config-pull.ps1` and the spec's apply, write-scope, merge, and backup sections.
Extract: dry-run default, add/update/skip plan, backup-before-overwrite behavior, file-by-file apply, no-prune posture, and failure reporting style.

- [x] **Step 2: Implement apply script**

Create `scripts/apply-harness-profile.ps1` with parameters:
```powershell
param(
    [switch] $Apply,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $ProjectRoot = (Get-Location).Path,
    [string] $BackupRoot = (Join-Path $ProjectRoot '.agent-harness/backups')
)
```

Include:
- dry-run output when `-Apply` is absent
- managed-block replacement for `AGENTS.md` and `CLAUDE.md`
- structured JSON merge for `.claude/settings.json`
- append-or-tighten-only validation for `permissions.deny`
- preservation of unmanaged JSON keys
- directory-file writes only under allowlisted directories
- backup manifest for overwritten files
- best-effort rollback for files changed before a write failure
- hard rejection of any target outside the first-version allowlist
- no writes to any home-level harness directory

- [x] **Step 3: Verify dry-run and apply**

Check:
```powershell
pwsh -NoProfile -File scripts/apply-harness-profile.ps1 -ProjectRoot tests/fixtures/harness-profile/project
pwsh -NoProfile -File scripts/apply-harness-profile.ps1 -ProjectRoot tests/fixtures/harness-profile/project -Apply
pwsh -NoProfile -File scripts/status-harness-profile.ps1 -ProjectRoot tests/fixtures/harness-profile/project
```
Expected: first command writes nothing, second command writes only allowlisted fixture project files, third command reports no pending changes for the fixture.

- [x] **Step 4: Record the result**

Mark this task complete only after a backup manifest is created for overwritten fixture files and no home-level files are touched.

### Task 6: Add Harness Profile Regression Tests

**Artifacts / Locations:**
- Create: `tests/harness-profile.tests.ps1`
- Create or modify: `tests/fixtures/harness-profile/`
- Review: `tests/config-sync.tests.ps1`

- [x] **Step 1: Gather existing test style**

Read: `tests/config-sync.tests.ps1`.
Extract: self-contained test runner style, temp workspace cleanup pattern, assertion helper pattern, and command invocation pattern.

- [x] **Step 2: Implement regression tests**

Create `tests/harness-profile.tests.ps1` covering:
- status is read-only
- build writes only `.agent-harness/generated/`
- apply dry-run writes nothing
- apply writes only allowlisted project paths
- repeated build is idempotent for component hashes and generated plan shape
- apply followed by status reports clean fixture state
- existing `AGENTS.md` without markers is not modified
- marker block replacement works
- `.claude/settings.json` preserves unmanaged keys
- `permissions.deny` cannot be removed
- duplicate component IDs fail
- `Requires` and `Conflicts` are enforced
- unsupported target platform is reported
- `..`, absolute, UNC, URL, and home-path references fail validation
- fake secret and machine-private path gates fail closed and do not leave unsafe generated output

- [x] **Step 3: Verify tests**

Check:
```powershell
pwsh -NoProfile -File tests/harness-profile.tests.ps1
```
Expected: exit code 0 and every assertion passes.

- [x] **Step 4: Record the result**

Mark this task complete only after the test script cleans its temp workspace on success and keeps it for inspection on failure.

### Task 7: Update Documentation And Agent Scope Triggers

**Artifacts / Locations:**
- Modify: `docs/README.md`
- Modify: `AGENTS.md`
- Modify: `CLAUDE.md`
- Modify: `STATUS.md`
- Review: `docs/specs/2026-06-29-project-harness-profiles-design.md`

- [x] **Step 1: Gather documentation update points**

Read: `docs/README.md`, `AGENTS.md`, `CLAUDE.md`, and `STATUS.md`.
Extract: existing scope trigger style, hard-rule style, status update style, and the current config-sync section.

- [x] **Step 2: Update docs**

Modify:
- `docs/README.md`: add a section for project harness profiles, first-version commands, safety rules, and non-goals.
- `AGENTS.md`: add harness profile paths and scripts to the scope trigger.
- `CLAUDE.md`: mirror the `AGENTS.md` scope-trigger update.
- `STATUS.md`: record that project harness profile design has moved to implementation planning and whether implementation has been completed in this task.

Include:
- profile is source, generated output is disposable
- apply is dry-run by default
- first version does not touch home-level harness directories
- first version does not install project-local skills
- generated output should remain uncommitted

- [x] **Step 3: Verify documentation**

Check:
```powershell
rg -n "harness-profile|project harness|agent-harness|harness-source" docs/README.md AGENTS.md CLAUDE.md STATUS.md
```
Expected: each modified document has the intended references and no stale statement claims project harness profiles are already a global home switcher.

- [x] **Step 4: Record the result**

Mark this task complete only after docs describe the implemented scripts and their dry-run/apply behavior accurately.

### Task 8: Run Final Validation And Review Diff

**Artifacts / Locations:**
- Review: full repository diff
- Review: generated or ignored files under `tmp/` and fixture directories

- [x] **Step 1: Run validation commands**

Run:
```powershell
pwsh -NoProfile -File tests/harness-profile.tests.ps1
pwsh -NoProfile -File tests/config-sync.tests.ps1
pwsh -NoProfile -File scripts/scan-secrets.ps1
git diff --check
git status --short --ignored
```

Expected:
- new harness-profile tests pass
- existing config-sync tests pass
- secret scan reports no blocking secrets
- whitespace check passes
- generated harness output appears only under ignored temp or fixture-generated locations

- [x] **Step 2: Inspect changed paths**

Check:
```powershell
git diff --stat
git diff --name-only
```

Expected changed tracked paths are limited to:
- `harness-source/`
- `scripts/harness-profile-common.ps1`
- `scripts/status-harness-profile.ps1`
- `scripts/build-harness-profile.ps1`
- `scripts/apply-harness-profile.ps1`
- `tests/harness-profile.tests.ps1`
- `tests/fixtures/harness-profile/`
- `docs/README.md`
- `docs/specs/2026-06-29-project-harness-profiles-design.md`
- `docs/superpowers/plans/2026-06-29-project-harness-profiles.md`
- `AGENTS.md`
- `CLAUDE.md`
- `STATUS.md`

Expected changed tracked paths do not include:
- `claude/skills/`
- `codex/skills/`
- `openclaw/skills/`
- files under `%USERPROFILE%`
- live home harness directories
- generated project output outside ignored temp or fixture paths

- [x] **Step 3: Self-review against the spec**

Compare the diff with `docs/specs/2026-06-29-project-harness-profiles-design.md`.
Expected: every first-version acceptance criterion is either implemented or explicitly deferred in documentation with no claim that it is complete.

- [x] **Step 4: Record the result**

Update this plan's checklist as tasks are completed. In the final handoff, report validation commands, pass/fail status, changed path categories, and any residual risks.
