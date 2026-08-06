# New Windows Machine Onboarding Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** Safely connect a second or later Windows computer to this repository without losing local skills, overwriting the canonical source, exposing private data, or damaging Codex `.system`.

**Approach:** Clone first, identify the machine, verify a clean baseline, and back up live state before importing anything. Import local skills only into the machine-specific inbox, then build, scan, review merge risks, run sync in dry-run mode, and apply only after every gate is understood.

**Materials:** Git, PowerShell 7, access to the private GitHub repository, this repository's `STATUS.md` and `docs/README.md`, and the scripts under `scripts/`.

**Validation:** The repository must pass `scripts/scan-secrets.ps1`; sync dry-run must show an explainable add/update/prune plan and preserve Codex `.system`; final `git status` must contain only reviewed, intentional changes.

---

## Safety model

This is a controlled migration, not a blind bootstrap. During initial onboarding, **do not run `bootstrap.ps1` without `-SkipInitialSync`**: the default bootstrap path installs hooks and immediately enters the guarded sync flow. Complete the backup, import review, build, scan, and sync dry-run gates in this document first.

Use these repository roles consistently:

- `skills-source/`: the only canonical, hand-maintained skill source.
- `claude/skills/`, `codex/skills/`: generated output; never edit them directly.
- `imports/skills-inbox/<computername>/`: untrusted, machine-specific import staging.
- Live directories under the user profile: runtime state; never reverse-copy them over `skills-source/`.

### Unified command entry point

For routine repository operations, `scripts/agent-dotfiles.ps1` provides a thin entry point to the existing scripts. It forwards trailing arguments to the selected script and reports the target script path and exit result; it does not replace any underlying implementation.

The complete command surface is:

```text
doctor
build
scan
backup
sync
config status | pull | push
profile status | build | apply
skills inventory | analyze | dedupe | merge | normalize | promote
env list | status | build | activate | rollback
```

Read-only actions include `doctor`, `scan`, `config status`, `profile status`,
`skills inventory`, `skills analyze`, `skills dedupe`, `env list`, and `env
status`. `build`, `profile build`, and `env build` materialize disposable
generated/staging output; `backup` writes an external snapshot. None of these
actions writes arbitrary live-home state or changes `skills-source/` by
reverse-copy.

All live, canonical-source, and project-target writes start in dry-run mode.
For actions that expose a mode, choose exactly one of `-DryRun` or `-Apply`;
omitting the mode is rejected by the unified entry point rather than treated
as implicit apply. The entry point never adds `-Apply` automatically. `sync`
and `env rollback` require a reviewed plan path for apply. `env activate`
creates and binds its internal sync plan during apply before writing the
environment state.

`config pull` is a separate home-level config deployment path. It is not part
of `env activate` and must not be described as an environment component.

## 1. Verify prerequisites

Open PowerShell and run:

```powershell
git --version
$PSVersionTable.PSVersion
Get-Command pwsh -ErrorAction SilentlyContinue
Get-Command codex -ErrorAction SilentlyContinue
Get-Command claude -ErrorAction SilentlyContinue
```

Required conditions:

- Git is installed and `git --version` succeeds.
- PowerShell 7 or newer is installed and `pwsh` resolves. Repository scripts declare `#requires -Version 7.0`; Windows PowerShell 5.1 can run basic Git and file-inspection commands, but it is **not supported for these scripts**.
- If PowerShell 7 is missing, install it before continuing, for example:

  ```powershell
  winget install --id Microsoft.PowerShell --source winget
  ```

- The user can authenticate to the private GitHub repository through SSH or Git Credential Manager. Never embed a personal access token in a clone URL, script, or document.
- Codex and/or Claude Code is already installed, or its installation is planned before live sync. It is acceptable for one client command to be absent if that client is not yet being deployed, but record that limitation before continuing.

## 2. Clone at the chosen repository root

Use a repository root that is outside the live home roots. Keep the actual
machine path in a local variable; do not copy it into tracked docs or reports.

```powershell
$RepoUrl = Read-Host 'Paste the private repository SSH or HTTPS clone URL'
$RepoRoot = '<repo-root>'
git clone $RepoUrl $RepoRoot
Set-Location $RepoRoot
```

Use the same `$RepoRoot` variable in every later command. Never embed a
personal access token in a clone URL, script, or document.

Do not run the default `bootstrap.ps1` yet. If hooks must be installed before onboarding is complete, use only the non-syncing form after the initial checks:

```powershell
pwsh -NoProfile -File .\bootstrap.ps1 -SkipInitialSync
```

## 3. Record the local machine identity

Use `COMPUTERNAME` as the machine identifier. Normalize it to lowercase for a stable inbox path while retaining the original value in the onboarding notes or commit description.

```powershell
$ComputerName = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($ComputerName)) {
    throw 'COMPUTERNAME is empty; stop and resolve machine identity before importing.'
}
$MachineId = $ComputerName.ToLowerInvariant()
$InboxRoot = Join-Path $RepoRoot "imports\skills-inbox\$MachineId"

"COMPUTERNAME=$ComputerName"
"Machine inbox=$InboxRoot"
```

Expected staging layout:

```text
imports/skills-inbox/<computername>/
  claude/
    <skill-name>/SKILL.md
  codex/
    <skill-name>/SKILL.md
```

Do not put credentials, machine configuration dumps, or entire home directories under the inbox.

## 4. Run pre-onboarding checks

First confirm that the fresh clone is clean and synchronized:

```powershell
Set-Location $RepoRoot
git status --short --branch --untracked-files=all
git fetch --prune
git status --short --branch --untracked-files=all
```

The two-letter status area must be empty. Stop if tracked modifications or unexpected untracked files are present.

Run the repository's read-only health check. It reports environment, structure, required scripts, live/generated paths, `.system` protection, Git state, and a secret scan without changing files:

```powershell
$DoctorPath = Join-Path $RepoRoot 'scripts\doctor.ps1'
if (-not (Test-Path -LiteralPath $DoctorPath -PathType Leaf)) {
    throw 'scripts/doctor.ps1 is missing; stop onboarding.'
}
pwsh -NoProfile -File $DoctorPath -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw "doctor.ps1 failed with exit code $LASTEXITCODE" }
```

Warnings do not make doctor fail, but every warning must be understood before live sync. Use `-SkipSecretsScan` only when troubleshooting the scanner itself; the normal onboarding path must run doctor without that switch.

Verify and run the secret scanner against the clone before importing local material:

```powershell
$ScanScript = Join-Path $RepoRoot 'scripts\scan-secrets.ps1'
if (-not (Test-Path -LiteralPath $ScanScript -PathType Leaf)) {
    throw 'scripts/scan-secrets.ps1 is missing; stop onboarding.'
}
pwsh -NoProfile -File $ScanScript -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw "Baseline secret scan failed with exit code $LASTEXITCODE" }
```

## 5. Back up live skills before importing

Never skip this step, even when the machine appears new. Preview the backup,
then create it outside the repository. Keep only a safe reference to the
result in the onboarding record; do not copy backup contents into Git.

```powershell
$BackupScript = Join-Path $RepoRoot 'scripts\backup.ps1'
pwsh -NoProfile -File $BackupScript -RepoRoot $RepoRoot -HomeRoot $env:USERPROFILE -DryRun
if ($LASTEXITCODE -ne 0) { throw "Backup dry-run failed with exit code $LASTEXITCODE" }

pwsh -NoProfile -File $BackupScript -RepoRoot $RepoRoot -HomeRoot $env:USERPROFILE
if ($LASTEXITCODE -ne 0) { throw "Backup failed with exit code $LASTEXITCODE" }
```

`backup.ps1` owns the external backup format and scope. This onboarding guide
does not reproduce its contents. In particular, credentials, sessions,
caches, plugin state, and other machine-private data must stay outside the
repository even when a backup contains them for recovery purposes.

## 6. Import existing local skills into the machine inbox

The import operation reads live skill directories and writes only to `imports/skills-inbox/<computername>/`. It must not write to `skills-source/`, generated output, or any live directory.

The current `inventory-skills.ps1` probes `.agents/skills` for Codex, while current sync behavior prefers `.codex/skills`. The following explicit import block handles both locations and excludes Codex `.system`:

```powershell
if (Test-Path -LiteralPath $InboxRoot) {
    throw "Machine inbox already exists: $InboxRoot. Review or archive the previous import; do not overwrite it."
}

$ClaudeInbox = Join-Path $InboxRoot 'claude'
$CodexInbox = Join-Path $InboxRoot 'codex'
New-Item -ItemType Directory -Force -Path $ClaudeInbox, $CodexInbox | Out-Null

function Copy-SkillDirectoriesToInbox {
    param(
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $DestinationRoot,
        [string[]] $ExcludedNames = @()
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        Write-Host "Live source not found; skipped: $SourceRoot"
        return
    }

    foreach ($SkillDir in @(Get-ChildItem -LiteralPath $SourceRoot -Directory -Force)) {
        if ($SkillDir.Name -in $ExcludedNames) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $SkillDir.FullName 'SKILL.md'))) { continue }

        $Target = Join-Path $DestinationRoot $SkillDir.Name
        if (Test-Path -LiteralPath $Target) {
            throw "Import collision at $Target; stop and review instead of overwriting."
        }
        Copy-Item -LiteralPath $SkillDir.FullName -Destination $Target -Recurse
    }
}

$ClaudeLive = Join-Path $env:USERPROFILE '.claude\skills'
$CodexPreferred = Join-Path $env:USERPROFILE '.codex\skills'
$CodexFallback = Join-Path $env:USERPROFILE '.agents\skills'
$CodexLive = if (Test-Path -LiteralPath $CodexPreferred) { $CodexPreferred } else { $CodexFallback }

Copy-SkillDirectoriesToInbox -SourceRoot $ClaudeLive -DestinationRoot $ClaudeInbox
Copy-SkillDirectoriesToInbox -SourceRoot $CodexLive -DestinationRoot $CodexInbox -ExcludedNames @('.system')
```

For Claude plugin-provided skills, first list manifests without copying plugin caches or credentials:

```powershell
$ClaudePluginRoot = Join-Path $env:USERPROFILE '.claude\plugins'
if (Test-Path -LiteralPath $ClaudePluginRoot) {
    Get-ChildItem -LiteralPath $ClaudePluginRoot -Filter 'SKILL.md' -File -Recurse -Force |
        Select-Object -ExpandProperty FullName
}
```

Copy only reviewed skill directories containing `SKILL.md` into `$ClaudeInbox`. If a destination name already exists, stop and preserve both source locations in the external backup for merge review; never overwrite one copy with another.

Confirm the inbox contains only expected skills:

```powershell
Get-ChildItem -LiteralPath $InboxRoot -Directory -Recurse -Force |
    Select-Object FullName
```

## 7. Build generated output from the canonical source

Importing does not make inbox content canonical. The initial build verifies the current `skills-source/` baseline and recreates generated output:

```powershell
$BuildScript = Join-Path $RepoRoot 'scripts\build-skills.ps1'
pwsh -NoProfile -File $BuildScript -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw "Skill build failed with exit code $LASTEXITCODE" }
```

Confirm the command reports expected counts for at least:

- `Built Claude skills: <count>` and generated directories under `claude/skills/`.
- `Built Codex skills: <count>` and generated directories under `codex/skills/`.

The current build produces Claude and Codex generated output. Generated output is disposable and Git-ignored; do not edit it to resolve an import conflict.

## 8. Scan imported and generated material

Run the repository scanner again after import and build:

```powershell
pwsh -NoProfile -File $ScanScript -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw "Post-import secret scan failed with exit code $LASTEXITCODE" }
```

If a finding appears:

1. Stop the onboarding workflow before merge or sync.
2. Record the file, line, detector name, and why the value is believed to be real or false-positive in the current task review.
3. Remove real sensitive material from the inbox/source and rotate exposed credentials when necessary.
4. For a false-positive, prefer rewriting the example or using an environment-variable placeholder.
5. Do not add a whitelist, bypass the scanner, append `scan-ok`, or use a skip option without explicit human approval and a recorded reason.
6. Rerun the scan and require exit code 0.

## 9. Review duplicates, empty shells, and quarantine candidates

Generate the repository's analysis and dedupe reports:

```powershell
pwsh -NoProfile -File .\scripts\analyze-skills.ps1 -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw "Skill analysis failed with exit code $LASTEXITCODE" }

pwsh -NoProfile -File .\scripts\dedupe-skills.ps1 -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw "Dedupe analysis failed with exit code $LASTEXITCODE" }

pwsh -NoProfile -File .\scripts\auto-merge-skills.ps1 -RepoRoot $RepoRoot -DryRun
if ($LASTEXITCODE -ne 0) { throw "Auto-merge dry-run failed with exit code $LASTEXITCODE" }

Get-Content -LiteralPath .\imports\skills-reports\skills-analysis.md
Get-Content -LiteralPath .\imports\skills-reports\dedupe-report.md
Get-Content -LiteralPath .\imports\skills-reports\auto-merge-report.md
```

These commands write reports under ignored `imports/skills-reports/`; do not commit the reports.

Check for empty or malformed inbox entries:

```powershell
$InboxSkillDirs = @(
    Get-ChildItem -LiteralPath $ClaudeInbox, $CodexInbox -Directory -ErrorAction SilentlyContinue
)
$EmptyShells = @($InboxSkillDirs | Where-Object {
    $Manifest = Join-Path $_.FullName 'SKILL.md'
    -not (Test-Path -LiteralPath $Manifest -PathType Leaf) -or
    (Get-Item -LiteralPath $Manifest -ErrorAction SilentlyContinue).Length -eq 0
})
$EmptyShells | Select-Object FullName
```

Review gates:

- **Same-name skill:** compare content and tree hashes in the analysis report. Do not let one machine silently replace another version.
- **Empty-shell skill:** missing or empty `SKILL.md` blocks promotion and sync apply until repaired or quarantined.
- **Quarantine candidate:** any reported secret signal, binary/large-file signal, unresolved platform conflict, or unexplained absolute machine path must remain outside canonical source.
- **Unknown live skill:** record every unknown directory from the sync dry-run in the next section. Unknown directories are not automatically deleted, but each must be understood.

If an imported skill must be retained but is not yet represented correctly in `skills-source/`, stop before sync apply. Promote or merge it only through a reviewed source change. For one approved skill, preview the exact target first:

```powershell
$SkillPath = Read-Host 'Enter the reviewed inbox skill directory path'
$TargetType = Read-Host 'Enter exactly one target: shared, claude-only, or codex-only'
pwsh -NoProfile -File .\scripts\promote-skill.ps1 -RepoRoot $RepoRoot -InputSkillPath $SkillPath -TargetType $TargetType -DryRun
```

Only after reviewing that preview may an authorized maintainer rerun it with `-Apply`. Any source promotion requires a fresh build and secret scan before proceeding. Never run `auto-merge-skills.ps1 -Apply` as an unreviewed shortcut.

## 10. Run sync in dry-run mode

Dry-run is mandatory:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 sync `
  -RepoRoot $RepoRoot -HomeRoot $env:USERPROFILE -DryRun `
  -PlanPath (Join-Path $env:TEMP 'ai-agent-dotfiles-sync-plan.json')
if ($LASTEXITCODE -ne 0) { throw "Sync dry-run failed with exit code $LASTEXITCODE" }
```

Review every platform summary:

- `+` / add: expected canonical skills missing from live.
- `~` / update: skills present in both generated and live trees; this is a planned managed refresh, not proof that content differs.
- `-` / prune: only stale names from the platform's managed manifest. Any surprising prune blocks apply.
- `unknown`: not in generated output or the managed manifest. It will be reported and preserved, but must be identified before apply.
- Codex `.system`: output must explicitly show it as preserved/untouched when present. If `.system` is planned for deletion or is not protected, stop immediately.

Also review the skill dry-run section for each platform. Record the add/update/prune/unknown counts and the `.system` result in the machine's onboarding task record. Apply is blocked until all changes are explainable.

Record the add/update/prune/unknown counts and the `.system` result in the machine's onboarding task record. Apply is blocked until all changes are explainable.

## 11. Apply sync only after approval

Apply only when all of these are true:

- Backup completed and its external location was recorded.
- Imported skills are either intentionally merged/promoted or intentionally excluded.
- Build and secret scan pass.
- Same-name, empty-shell, quarantine, unknown, and prune findings are resolved or explicitly accepted.
- Dry-run shows Codex `.system` preserved.

Then run:

```powershell
$plan = Join-Path $env:TEMP 'ai-agent-dotfiles-sync-plan.json'
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 sync -RepoRoot $RepoRoot -HomeRoot $env:USERPROFILE -DryRun -PlanPath $plan
# 人工审查计划后，应用同一份计划
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 sync -RepoRoot $RepoRoot -HomeRoot $env:USERPROFILE -Apply -PlanPath $plan
if ($LASTEXITCODE -ne 0) { throw "Sync apply failed with exit code $LASTEXITCODE; use the reported backup for recovery." }

pwsh -NoProfile -File .\scripts\scan-secrets.ps1 -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw "Post-apply secret scan failed with exit code $LASTEXITCODE" }

git status --short --branch --untracked-files=all
```

`sync.ps1 -Apply -PlanPath <plan>` rechecks the source, manifest, and live fingerprints before its own build, secret scan, and mandatory backup; drift rejects the apply. The explicit post-apply scan and Git status are still required as final evidence.

## 12. Reproduce and verify a named environment

If the repository defines a named Harness Environment, build its disposable
staging output before activation:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 env build '<env-name>'
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 env status
```

`env.lock.json` in the staging output is a verifiable lock. It records the
environment definition hash, repository/manifest evidence, skill source and
staged tree hashes, profile evidence, and hashes for built files. It is not a
portable container for credentials or machine state. `env status` validates
the lock and reports, for the active environment, lock validity, definition
drift, live parity, Codex `.system` status, and backup reference.

Activation remains an explicit, reviewable operation:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 env activate '<env-name>' -DryRun
# Review the manifest-scoped plan, especially prune actions.
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 env activate '<env-name>' -Apply
```

The apply path binds an internal sync dry-run plan before changing live
managed skills and writes environment state only after a successful apply.
`config pull` is not part of this process; home-level config synchronization
must be reviewed and run separately.

If an activation must be reverted, use the plan-bound rollback workflow in
[`RESTORE.md`](RESTORE.md). Rollback restores only the current Claude/Codex
manifest-managed skills and environment state. It never touches unknown live
directories, Codex `.system`, credentials, sessions, caches, Codex
`config.toml`.

## 13. Review and commit the onboarding result

Use one separate commit per onboarded machine. Before staging:

```powershell
git status --short --untracked-files=all
git diff --stat
git diff --check
pwsh -NoProfile -File .\scripts\scan-secrets.ps1 -RepoRoot $RepoRoot
```

Review `STATUS.md` and add a concise machine verification entry containing only non-sensitive evidence. Stage explicit reviewed files; do not use `git add .`, and do not stage `imports/`, generated output, backups, live home files, caches, or machine-private configuration.

```powershell
git add --patch
git status --short
git diff --cached --check
git commit -m "onboarding($MachineId): reconcile managed skills"
```

Suggested commit format:

```text
onboarding(<computername>): reconcile managed skills
```

If onboarding produces no tracked canonical, manifest, status, or documentation change, do not create an empty commit merely to mark the event.

## 14. Prohibited actions

- Do not commit API keys, access tokens, passwords, cookies, credentials, or authentication state.
- Do not commit SSH private keys or `.ssh` contents.
- Do not commit VPS node configuration, proxy/subscription data, device identity, approval state, or session data.
- Do not commit machine-specific absolute-path caches, local databases, logs, npm installs, launchers, or runtime history.
- Do not commit backup directories. Current repository policy keeps all backups outside Git; a future policy change would require explicit review before this rule changes.
- Do not commit `imports/`, quarantine originals, generated output, or live home files.
- Do not edit, move, overwrite, prune, or delete `~/.codex/skills/.system`.
- Do not use `robocopy /MIR` or any whole-directory mirror against live skill roots.
- Do not reverse-copy live skills over `skills-source/`.
- Do not edit `claude/skills/`, `codex/skills/` to resolve source problems.
- Do not run `sync.ps1 -Apply` before a reviewed dry-run.
- Do not run `env activate -Apply` or `env rollback -Apply` without the required
  explicit mode and plan-binding checks.
- Do not weaken or bypass `scripts/scan-secrets.ps1` to make onboarding appear successful.

## Completion checklist

- [ ] Prerequisites verified with Git and PowerShell 7.
- [ ] Repository cloned and clean before local import.
- [ ] `COMPUTERNAME` recorded and machine inbox path confirmed.
- [ ] `scripts/doctor.ps1` completed with exit code 0 and all warnings were reviewed.
- [ ] Baseline secret scan passed.
- [ ] Live Codex and Claude/Claude Code skill/plugin state backed up outside the repository.
- [ ] Local skills imported only into the machine inbox; `.system` excluded.
- [ ] Canonical build completed for Claude and Codex.
- [ ] Post-import secret scan passed.
- [ ] Duplicate, empty-shell, quarantine, and unknown-live findings reviewed.
- [ ] Sync dry-run reviewed, including `+`, `~`, `-`, unknown, and `.system` preservation.
- [ ] Sync apply completed only after approval, followed by scan and Git status.
- [ ] If a named environment is used, `env.lock.json` validates and `env status` evidence was reviewed for lock validity, definition drift, live parity, `.system`, and backup reference.
- [ ] `config pull` remains a separately reviewed operation and is not treated as part of `env activate`.
- [ ] Any rollback uses only current manifest-managed Claude/Codex skills and environment state; unknown, `.system`, credentials, sessions, caches, and `config.toml` remain untouched.
- [ ] Reviewed tracked changes committed separately for this machine, or no empty commit created when nothing changed.
