# New Windows Machine Onboarding

Set up one Windows machine for the daily Codex and Antigravity workflow (skills, global agreements, plugins, and managed MCP servers).
The `work` environment selects eight skills from `codex/skills/` for Codex. Bootstrap builds `codex/skills/` from `skills-source/`.
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

Check every line from both stages. `install` and `update` are the selected Codex skills;
the config stage only shows whether the Codex `AGENTS.md` managed block needs to be added or
updated. `unknown` lines are unselected
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

## 4. Set up Antigravity (`AGENTS.md` and plugins)

1. Preview and apply the Antigravity managed `AGENTS.md` block (`~/.gemini/config/AGENTS.md`) with explicit `-Platform Antigravity` and owner authorization:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 config pull -Platform Antigravity -DryRun
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 config pull -Platform Antigravity -Apply
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 config status -Platform Antigravity
```

2. Build, inspect, and deploy the managed `ai-agent-dotfiles` plugin (and optionally install missing declared `ExternalPlugins` such as `unity` via `-ExternalPlugin <name>` after reviewing the dry-run and securing owner authorization covering identity, version, and enablement; close the Antigravity Desktop App before installing external marketplace entries if file locks occur):

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 antigravity build
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 antigravity status
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 antigravity deploy -DryRun
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 antigravity deploy -Apply
```

See [docs/README.md §15](README.md#15-antigravity-插件) for ownership, `ExternalPlugins`, and post-install readback details.

## 5. Project managed MCP servers (`mcp-sync`)

Ensure required runtimes/CLIs for declared servers (for example `uv` / `uvx` for `blender`, and `codex` on `PATH` for Codex projection) are installed. Preview across Antigravity and Codex, then run `-Apply` only after explicit owner authorization (Codex standing `work` skill grant does not cover MCP Apply):

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 mcp status
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 mcp deploy -DryRun
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 mcp deploy -Apply
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 mcp status
```

`unchanged` confirms that the client configuration matches the registry. To check the Blender connection:

1. Open Blender with the **MCP for Blender** add-on enabled. Use its regular windowed mode. The add-on needs the UI event loop.
2. In the 3D Viewport sidebar, select **MCP for Blender → Connect to MCP server**. The default endpoint is `localhost:9800` (set the Blender add-on listener port to match the `BLENDER_PORT` declared in `harness-source/mcp/servers.psd1`).
3. From the MCP client you want to check, call `get_addon_status`. Confirm that it returns a Blender version and that the reported protocol version matches the expected version. A connection refusal at the configured endpoint calls for checking the running Blender instance and confirming that its add-on listener port matches `BLENDER_PORT` first.

See [docs/README.md §16](README.md#16-受管-mcp-分发mcp-sync) for per-client projection targets, unmanaged-entry preservation, and backup recovery.

## 6. Optional: remove skills an older setup left

If the skill dry run shows `unknown` directories that an older setup deployed and that are no
longer wanted, name them with `-Retire` in a skills-only dry run, review the `prune` lines, then
Apply with the owner's OK:

```powershell
pwsh -NoProfile -File .\scripts\deploy-skills.ps1 -Environment work -Retire <old-skill>
pwsh -NoProfile -File .\scripts\deploy-skills.ps1 -Environment work -Retire <old-skill> -Apply
```

Record the result in [STATUS.md](../STATUS.md) without machine names or private paths.
