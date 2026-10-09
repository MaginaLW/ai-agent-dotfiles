# New Windows Machine Onboarding

Set up one Windows machine so its Claude, Codex and Reasonix live skill directories match an
environment from this repository. Use PowerShell 7+. Start only after the owner names the machine.

## 1. Clone and bootstrap

```powershell
$RepoRoot = '<repo-root>'
git clone <repo-url> $RepoRoot
Set-Location $RepoRoot
pwsh -NoProfile -File .\bootstrap.ps1
pwsh -NoProfile -File .\scripts\doctor.ps1 -RepoRoot $RepoRoot
```

Bootstrap installs and verifies the pinned gitleaks, builds the generated skills and prints the
deploy-skills dry-run command. It never changes a live skills directory. Use a URL without
embedded credentials, and fix any doctor FAIL before going on.

## 2. Review the dry run

```powershell
pwsh -NoProfile -File .\scripts\deploy-skills.ps1 -Environment work
```

Check every line. `install` and `update` are the selected skills. `unknown` lines are live
directories this tool never deployed (local skills, other tools, or an older setup); they stay
untouched. Codex `.system` is never listed. To keep a local skill in the repository instead,
import it first ([MERGE_POLICY.md](MERGE_POLICY.md)).

## 3. Apply with the owner's OK

```powershell
pwsh -NoProfile -File .\scripts\deploy-skills.ps1 -Environment work -Apply
```

Run it only after the owner authorizes this Apply for this machine. Old directories it replaces
are backed up first ([docs/README.md §9](README.md#9-备份与恢复)). Run the dry run again: every
selected skill should now be `unchanged`.

## 4. Optional: remove skills an older setup left

If the dry run shows `unknown` directories that an older setup deployed and that are no longer
wanted, name them with `-Retire` in a dry run, review the `prune` lines, then Apply with the
owner's OK:

```powershell
pwsh -NoProfile -File .\scripts\deploy-skills.ps1 -Environment work -Retire <old-skill>
pwsh -NoProfile -File .\scripts\deploy-skills.ps1 -Environment work -Retire <old-skill> -Apply
```

Record the result in [STATUS.md](../STATUS.md) without machine names or private paths.
