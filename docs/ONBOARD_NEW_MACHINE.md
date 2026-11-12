# New Windows Machine Onboarding

Set up one Windows machine for the daily Codex/ZCode environment and Codex managed config.
The work selection is Claude/Codex/ZCode 0/9/8. Keep the generated Claude skills as the ZCode
projection source; they need no Claude account, CLI or live directory. Legacy Claude config
requires an explicit config-pull.ps1 -Platform Claude invocation and matching authorization.
Use PowerShell 7+. Start only after the owner names the machine.

## 1. Clone and bootstrap

```powershell
$RepoRoot = '<repo-root>'
git clone <repo-url> $RepoRoot
Set-Location $RepoRoot
pwsh -NoProfile -File .\bootstrap.ps1
pwsh -NoProfile -File .\scripts\doctor.ps1 -RepoRoot $RepoRoot
```

Bootstrap installs and verifies the pinned gitleaks, builds the generated skills and prints the
combined deploy dry-run command. It never changes a live skills directory or config. Use a URL without
embedded credentials, and fix any doctor FAIL before going on.

## 2. Review the dry run

```powershell
pwsh -NoProfile -File .\scripts\deploy.ps1 -Environment work
```

Check every line from both stages. `install` and `update` are the selected Codex/ZCode skills;
the config stage only shows whether the Codex `AGENTS.md` managed block needs to be added or
updated. It does not recreate Claude live config. `unknown` lines are unselected
live directories absent from deploy state and `-Retire`; they may be local skills, come from
another tool or an older setup, or have been deployed here before state was lost. The current
plan leaves them untouched. Codex `.system` is never listed. To keep a local skill in the
repository instead, review it and add it to `skills-source/` first
([docs/README.md §6](README.md#6-新增-skill-的流程)).

Skill install/update entries also list added, changed and removed relative files. The plan shows
the recorded previous environment and the target environment; a recorded environment is not a
live-content check. Prunes distinguish deselection from explicit retirement. Review filenames
for private information before sharing the output.

## 3. Apply with the owner's OK

```powershell
pwsh -NoProfile -File .\scripts\deploy.ps1 -Environment work -Apply
```

Run it only after the owner authorizes this Apply for this machine. Old skill directories are
backed up first ([docs/README.md §8](README.md#8-备份与恢复)); config-pull backs up files it
overwrites. Run the dry run again: every selected skill should now be `unchanged`, and config
should report no pending changes.

Combined Apply runs both planners before live writes. `Preflight failed` leaves live skills,
config and deploy state untouched, although the skill build may regenerate repository output.
Preflight does not guarantee write access or prevent concurrent changes. A runtime config failure
can still leave skills completed; use the [recovery table](README.md#8-备份与恢复) before retrying.

## 4. Optional: remove skills an older setup left

If the skill dry run shows `unknown` directories that an older setup deployed and that are no
longer wanted, name them with `-Retire` in a skills-only dry run, review the `prune` lines, then
Apply with the owner's OK:

```powershell
pwsh -NoProfile -File .\scripts\deploy-skills.ps1 -Environment work -Retire <old-skill>
pwsh -NoProfile -File .\scripts\deploy-skills.ps1 -Environment work -Retire <old-skill> -Apply
```

Record the result in [STATUS.md](../STATUS.md) without machine names or private paths.
