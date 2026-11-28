# New Windows Machine Onboarding

Set up one Windows machine for the daily Codex, Antigravity, and Hermes workflow (skills, global agreements, plugins, and managed MCP servers).
The `work` environment selects ten skills from `codex/skills/` for Codex. Bootstrap builds `codex/skills/` from `skills-source/`.
Use PowerShell 7+. Start only after the owner names the machine.

## 1. Clone and bootstrap

Check that PowerShell 7 or later and Git are available in the terminal you will use.

```powershell
pwsh -v
git --version
```

If either command is missing, install that tool and reopen the terminal before cloning.

```powershell
$RepoRoot = '<repo-root>'
git clone <repo-url> $RepoRoot
Set-Location $RepoRoot
pwsh -NoProfile -File .\bootstrap.ps1
pwsh -NoProfile -File .\scripts\doctor.ps1 -RepoRoot $RepoRoot
```

Bootstrap installs and verifies the pinned gitleaks, builds the generated skills and prints the
combined deploy dry-run command. It never changes a live skills directory or config. Use a URL without
embedded credentials. Resolve any doctor FAIL or listed deployment blocker before continuing.

## 2. Review the dry run

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env deploy work -DryRun
```

Check the target skills directory and the changes in both stages. Review the config changes
and confirm that every planned `prune` is intended. Continue when both stages succeed.
`install` and `update` are selected Codex skills. `unknown` lines are unselected
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
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env deploy work -Apply
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

Preview the managed block in `~/.gemini/config/AGENTS.md`.

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 config pull -Platform Antigravity -DryRun
```

Check the target and the planned change to the managed block. Once the owner approves that change, apply it and read back the result.

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 config pull -Platform Antigravity -Apply
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 config status -Platform Antigravity
```

Before building the plugin, check that the Antigravity CLI is available.

```powershell
agy --version
```

If that command fails, make the CLI available on `PATH` before continuing. Build and preview the managed plugin.

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 antigravity build
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 antigravity status
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 antigravity deploy -DryRun
```

Check the plugin name, installed and candidate versions, package, and enablement effects. Once the owner approves that scope, apply it.

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 antigravity deploy -Apply
```

For a missing external marketplace plugin such as `unity`, select it explicitly with `-ExternalPlugin unity` in both the preview and the separately authorized Apply. If file locks interfere, close Antigravity Desktop before installation. See [the plugin guide](README.md#15-antigravity-插件) for ownership and post-install readback.

## 4b. Set up Hermes (`SOUL.md` and shared skills)

Ensure Hermes Agent is already installed on the machine under its default `%LOCALAPPDATA%\hermes` root and `default` profile (non-default `HERMES_HOME`, `HERMES_DATA_DIR_SUFFIX`, non-`default` `active_profile`, or reparse points fail closed as `blocked`; if Hermes is absent, `status` and `-DryRun` report `not-installed` cleanly).

Preview the managed block in `%LOCALAPPDATA%\hermes\SOUL.md`:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 config status -Platform Hermes
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 config pull -Platform Hermes -DryRun
```

If `%LOCALAPPDATA%\hermes\SOUL.md` already has local content without `<!-- BEGIN/END AI-AGENT-DOTFILES: hermes/SOUL.md -->` markers, wrap or append the markers manually while keeping existing persona text intact, then re-run `-DryRun`. Once the owner approves that change, apply it and read back:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 config pull -Platform Hermes -Apply
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 config status -Platform Hermes
```

Next, preview and apply the 8 collision-free shared skills declared in `harness-source/hermes/skills.psd1` into `%LOCALAPPDATA%\hermes\skills\ai-agent-dotfiles\` (only after explicit owner authorization; `deploy.ps1` and Codex standing `work` grant do not cover Hermes):

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 hermes status
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 hermes deploy -DryRun
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 hermes deploy -Apply
```

Verify with `hermes skills list` that the 8 `ai-agent-dotfiles` skills appear cleanly without ambiguity. See [docs/README.md §18](README.md#18-hermes-共享技能hermes-skills) for fail-closed collision rules and backup state.

## 5. Project managed MCP servers (`mcp-sync`)

Ensure required runtimes/CLIs for declared servers (for example `uv` / `uvx` for `blender`, and `codex` on `PATH` for Codex projection) are installed. Preview across Antigravity, Codex, and Hermes, then run `-Apply` only after explicit owner authorization (Codex standing `work` skill grant does not cover MCP Apply):

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 mcp status
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 mcp deploy -DryRun
```

Review the server, client, and changed fields for each planned entry. After the owner approves these entries, apply them and check their status.

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 mcp deploy -Apply
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 mcp status
```

`unchanged` confirms that the client configuration matches the registry. To check the Blender connection:

1. Open Blender with the **MCP for Blender** add-on enabled. Use its regular windowed mode. The add-on needs the UI event loop.
2. In the 3D Viewport sidebar, select **MCP for Blender → Connect to MCP server**. The default endpoint is `localhost:9800` (set the Blender add-on listener port to match the `BLENDER_PORT` declared in `harness-source/mcp/servers.psd1`).
3. From the MCP client you want to check, call `get_addon_status`. Confirm that it returns a Blender version and that the reported protocol version matches the expected version. A connection refusal at the configured endpoint calls for checking the running Blender instance and confirming that its add-on listener port matches `BLENDER_PORT` first.

See [docs/README.md §16](README.md#16-受管-mcp-分发mcp-sync) for per-client projection targets, unmanaged-entry preservation, and backup recovery.

## 6. Verify status and optional local dashboard

Run one read-only command to verify the recorded environment, configuration blocks, Antigravity plugins, Hermes shared skills, and managed MCP status:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 status
```

Optionally, launch the loopback-only Chinese web monitoring console via `start-dashboard.cmd` or the CLI wrapper:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 dashboard
```

## 7. Optional: remove skills an older setup left

If the skill dry run shows `unknown` directories that an older setup deployed and that are no
longer wanted, name them with `-Retire` in a skills-only dry run, review the `prune` lines, then
Apply with the owner's OK:

```powershell
pwsh -NoProfile -File .\scripts\deploy-skills.ps1 -Environment work -Retire <old-skill>
```

Confirm the `prune` line names the intended skill. After the owner approves its removal, use that same name in the Apply.

```powershell
pwsh -NoProfile -File .\scripts\deploy-skills.ps1 -Environment work -Retire <old-skill> -Apply
```

Record the result in [STATUS.md](../STATUS.md) without machine names or private paths.
