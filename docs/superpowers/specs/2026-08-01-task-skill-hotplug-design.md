# Task-Level Skill Hot-Plug Design

**Status:** Approved by user; implementation complete

**Goal:** Keep each task on a small `work` baseline while allowing an agent to add a known repository-managed skill during the task, with the requested task skill set shareable across computers using the project.

## Scope and decisions

The feature is task-scoped, project-shared, and platform-aware.

- `harness-source/envs/work.psd1` remains the tracked baseline environment. It is not rewritten every time a task needs a skill.
- The task's additional skills live in a tracked project file: `.agent-harness/task-skills.psd1`.
- The file is branch/worktree scoped. A task that must be shared across computers commits the file; another computer receives it through the normal project checkout/pull flow.
- Machine-private `state/current-env.json` records what was actually activated on that computer. It is an attestation, not the shared task request.
- The default platform is Codex for the current agent workflow. The interface also accepts an explicit Claude platform so the same mechanism can support both platforms without ambiguous cross-installation.
- Unknown, quarantined, unmanaged, or secret-scanning-failing skills are never auto-installed.

The initial overlay shape is:

```powershell
@{
    SchemaVersion = 1
    BaseEnv = 'work'
    Skills = @{
        Claude = @()
        Codex = @()
    }
}
```

One overlay is active per checkout/worktree. Parallel tasks use separate branches or worktrees, avoiding a global mutable task list.

## User and agent interface

The unified CLI gains a task-skill group:

```powershell
pwsh -File scripts/agent-dotfiles.ps1 env task status
pwsh -File scripts/agent-dotfiles.ps1 env task ensure-skill <name> -Platform Codex -DryRun
pwsh -File scripts/agent-dotfiles.ps1 env task ensure-skill <name> -Platform Codex -Apply
pwsh -File scripts/agent-dotfiles.ps1 env task sync -DryRun
pwsh -File scripts/agent-dotfiles.ps1 env task sync -Apply
pwsh -File scripts/agent-dotfiles.ps1 env task close -DryRun
pwsh -File scripts/agent-dotfiles.ps1 env task close -Apply
```

`ensure-skill` is the agent-facing operation. The project instructions will tell an agent that, when a requested skill is absent from the current catalog, it should call this operation with the exact skill name rather than editing a live directory or inventing a replacement.

`status` reports the base environment, overlay entries, effective skill set, overlay hash, and whether the live environment matches. `sync` applies the current shared overlay after review. `close` removes the task overlay and requires an explicit prune review because closing a task can remove its managed skills from live.

## Hot-plug data flow

1. The agent asks for a skill by exact name.
2. `ensure-skill` verifies that the name exists in the repository source, generated output, and the selected platform manifest; it rejects path-like names and quarantined/import-only content.
3. Dry-run builds an effective `work + task overlay` staging tree without changing the tracked overlay or live home. The plan must show an addition for the requested skill and no unrelated prune.
4. Apply writes the overlay, runs the existing build and secret-scan gates, creates the normal mandatory backup, and deploys through the existing `sync.ps1` transactional path.
5. The environment lock records the overlay hash and effective skill provenance. `current-env.json` records the same effective lock hash on success.
6. The agent can read the newly installed `SKILL.md` on the next turn. If the Codex application has already cached the task's initial skill catalog, a new task/thread may still be required; the repository can hot-plug files and state but cannot force an undocumented application-level catalog reload.

Only additions are eligible for automatic task-time synchronization. Removal and task close always remain explicit because they can prune managed live skill directories.

## Cross-computer behavior

The implementation, validation rules, CLI, and agent instructions are tracked in this repository. The overlay file is also tracked when the task needs to share its skill set.

After another computer checks out or pulls a commit containing `.agent-harness/task-skills.psd1`:

- the existing Git hook detects the task overlay path;
- the task-aware sync path runs build, secret scan, and a bound dry-run;
- an addition-only overlay can be applied automatically under the existing backup/parity gates;
- any removal, stale lock, unknown skill, or prune is reported and waits for explicit `env task sync -Apply` review.

No computer receives another computer's live home files directly. It reconstructs the same effective environment from the shared source and overlay, which keeps the process auditable and reproducible.

## Safety and invariants

- `skills-source/` remains the only hand-maintained skill source of truth.
- Generated output is rebuilt; generated directories and live skill roots are never edited directly.
- All live writes go through `sync.ps1`; no second copy/delete implementation is introduced.
- Build, secret scan, external fingerprint-bound dry-run, mandatory backup, and managed-scope parity remain required.
- Codex `.system`, unknown live directories, credentials, sessions, caches, and configuration files remain untouched.
- The overlay can reference only a platform manifest entry with a valid source and generated output.
- The feature never auto-commits. Sharing across computers requires the normal user-reviewed Git commit and pull flow.
- A failed apply must leave both the overlay and live state recoverable; the plan and backup are retained for diagnosis.

## Alternatives considered

### Expand `work.psd1` permanently

This is simple but makes one task's requirement global to every task and every computer. It does not provide task isolation or a clean close operation.

### Watch Codex logs for missing-skill errors

This could appear fully automatic, but it depends on private application log formats, can misread quoted skill names, and cannot reliably know whether a request is authorized. It is not the control plane.

### Project-shared task overlay (selected)

This keeps the baseline small, makes the task requirement reviewable in Git, allows every computer to reconstruct the same effective environment, and reuses the repository's existing gates. The main limitation is that application-level skill catalog refresh remains outside the repository's control.

## Validation and acceptance criteria

The implementation is complete only when all of the following pass:

- a missing but managed Codex skill is rejected by the current catalog, then added by `ensure-skill` with a dry-run showing exactly one addition;
- apply creates a mandatory backup, writes the overlay, installs the skill, preserves `.system`, and passes live parity;
- a second computer or fake home reconstructs the same effective skill set from the tracked overlay;
- unknown, quarantined, unmanaged, malformed, and secret-failing requests fail before any live write;
- task close shows the exact prune set and requires explicit apply;
- overlay changes invalidate stale locks and are recovered by rebuild;
- Git hook handling is addition-only automatic and does not silently prune on checkout or pull;
- existing sync, harness-env, profile, import, plugin, MCP, doctor, and unified CLI regression suites remain green.

## Review questions

This design assumes one shared overlay per branch/worktree and automatic synchronization only for addition-only changes. Before implementation, confirm those two semantics; changing either affects the state model and Git-hook behavior.
