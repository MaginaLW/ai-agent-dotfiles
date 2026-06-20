# OpenClaw Skills and Plugins Sync Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** Bring OpenClaw skills and user-managed OpenClaw plugin choices into `ai-agent-dotfiles` without weakening the existing build, scan, backup, dry-run, and manifest-scoped sync guarantees.

**Approach:** Extend the current Claude/Codex skill pipeline in small, reviewable steps: first inventory OpenClaw state without copying secrets, then add OpenClaw-aware source/layout/manifest support, then add safe live sync, then add plugin convergence through the OpenClaw CLI. Treat OpenClaw bundled package content and machine-managed state as inputs for discovery only, not repo source.

**Materials:** `docs/README.md`, `STATUS.md`, `AGENTS.md`, `.gitignore`, `manifests/whitelist.psd1`, `scripts/build-skills.ps1`, `scripts/sync.ps1`, `scripts/backup.ps1`, `scripts/auto-sync-after-git.ps1`, `scripts/skills-common.ps1`, OpenClaw docs for skills and plugins, and local OpenClaw state under `%USERPROFILE%\.openclaw`.

**Validation:** `build-skills.ps1`, `scan-secrets.ps1`, `sync.ps1` dry-run, fake-home apply tests, OpenClaw plugin dry-run reports, and post-apply parity checks must all pass before any live OpenClaw changes are considered complete.

---

## Review Corrections

The original draft had the right direction but needed these corrections before implementation:

- Plugin sync is in scope. The repo should manage a reviewed declarative plugin list, not copy `~/.openclaw/plugins/installs.json`.
- The default repo-managed OpenClaw skill target should be `~/.openclaw/skills`, not `~/.openclaw/workspace/skills`. Workspace skills are higher-precedence, per-workspace user content and should be import candidates or explicit override targets only.
- `~/.openclaw/plugins/installs.json` is machine-managed OpenClaw state. It contains absolute paths, generated hashes, registry cache data, and package metadata; never commit it and never edit it directly.
- OpenClaw bundled skills and bundled plugins from the installed npm package are platform-managed. Inventory them for comparison, but do not reverse-import them by default.
- Do not hard-code the "13 OpenClaw-native skills" list. Generate an inventory report from the actual machine and review each candidate.
- A single global `manifests/managed-skills.txt` is too coarse for three platforms. Add target-scoped manifests and keep the existing union manifest only for compatibility/reporting.
- `.clawhub` preservation must copy real files to a temporary preservation directory or rely on the mandatory backup. Keeping `DirectoryInfo` objects for paths that are then deleted cannot restore anything.
- `identity/`, `credentials/`, `devices/`, `auth-profiles.json`, `exec-approvals.json`, `node.json`, launcher scripts, logs, sessions, caches, `~/.openclaw/npm`, and workspace memory/artifacts are not repo-managed.

## Target Model

### Skill Sources

Tracked source:

```text
skills-source/shared/<skill>/
skills-source/claude-only/<skill>/
skills-source/codex-only/<skill>/
skills-source/openclaw-only/<skill>/
```

Generated output:

```text
claude/skills/
codex/skills/
openclaw/skills/
```

Live targets:

```text
~/.claude/skills
~/.codex/skills
~/.openclaw/skills
```

OpenClaw workspace skills at `~/.openclaw/workspace/skills` are treated as import candidates and unknown live content unless the user passes an explicit future `-OpenClawLiveSkillsPath` override.

### Plugin Source

Tracked source:

```text
openclaw/plugins/managed-plugins.json
```

This file is a hand-reviewed declaration of desired plugin state:

```json
{
  "version": 1,
  "plugins": [
    {
      "id": "diffs",
      "source": "clawhub:diffs",
      "enabled": true,
      "allowUninstall": true
    },
    {
      "id": "browser",
      "bundled": true,
      "enabled": true,
      "allowUninstall": false
    }
  ]
}
```

Rules:

- `source` may use `clawhub:`, `npm:`, `git:`, or `npm-pack:` specs that OpenClaw supports. Marketplace installs use `source` plus a separate `marketplace` field and apply as `openclaw plugins install <source> --marketplace <marketplace>`.
- Local path installs are rejected unless represented as a repo-relative path under a tracked repo directory.
- `bundled: true` entries may only manage enablement; sync must never uninstall bundled plugins.
- No secrets, auth profiles, API keys, cookies, local absolute paths, generated manifest hashes, or package cache records are allowed.
- Plugin apply uses OpenClaw CLI commands such as `openclaw plugins install`, `openclaw plugins update`, `openclaw plugins enable`, `openclaw plugins disable`, and `openclaw plugins uninstall`. It must not hand-edit `installs.json`.

## Task 1: Inventory OpenClaw State Safely

**Artifacts / Locations:**
- Create: `scripts/inventory-openclaw.ps1`
- Create: `imports/skills-reports/openclaw-inventory.md`
- Create: `imports/skills-reports/openclaw-inventory.json`
- Review: `%USERPROFILE%\.openclaw`, OpenClaw CLI `plugins list --json`

- [ ] **Step 1: Add a read-only inventory script**

Create `scripts/inventory-openclaw.ps1` with `-RepoRoot` and `-HomeRoot` parameters. It must inspect only path names, directory names, file sizes, hashes, frontmatter metadata, plugin ids, plugin origins, plugin source specs, and enablement booleans.

Do not record file contents from `identity/`, `credentials/`, `devices/`, `auth-profiles.json`, `exec-approvals.json`, `node.json`, logs, sessions, caches, or `plugins/installs.json` package metadata beyond plugin id/source/origin/enabled.

- [ ] **Step 2: Inventory skill roots**

Read these roots if they exist:

```text
%USERPROFILE%\.openclaw\skills
%USERPROFILE%\.openclaw\workspace\skills
%USERPROFILE%\.openclaw\workspace\.agents\skills
%USERPROFILE%\.agents\skills
```

Record skill name, source root, whether `SKILL.md` exists, file count, total size, tree hash, `.clawhub` presence, likely platform features, and scan findings.

- [ ] **Step 3: Inventory plugins**

Run `openclaw plugins list --json` when the CLI is available. If the CLI is unavailable, read `%USERPROFILE%\.openclaw\plugins\installs.json` as a cold fallback and record only sanitized plugin facts.

Classify plugin records as:

```text
bundled
managed-install
linked-local
unknown-or-broken
```

Expected: bundled plugins are reported but not selected for repo management unless only enablement is desired.

- [ ] **Step 4: Verify inventory safety**

Run:

```powershell
pwsh -NoProfile -File scripts/scan-secrets.ps1
```

Expected: no blocking secret findings. Keyword hints are acceptable only if they point to explanatory docs, not captured secret values.

## Task 2: Update Repo Policy and Ignore Rules

**Artifacts / Locations:**
- Modify: `AGENTS.md`
- Modify: `CLAUDE.md`
- Modify: `docs/README.md`
- Modify: `STATUS.md`
- Modify: `.gitignore`
- Modify: `manifests/whitelist.psd1`

- [ ] **Step 1: Extend policy docs**

Add OpenClaw to the scope trigger and rules. The docs must say:

- `skills-source/openclaw-only/` is the only hand-maintained OpenClaw-only skill source.
- `openclaw/skills/` is generated output and must not be edited or committed.
- `openclaw/plugins/managed-plugins.json` is tracked desired plugin state.
- `~/.openclaw/plugins/installs.json` is machine-managed and must not be committed or edited directly.
- OpenClaw identity, credentials, devices, approval state, sessions, caches, npm installs, node launchers, and workspace memory are never repo-managed.

- [ ] **Step 2: Extend `.gitignore`**

Add:

```text
openclaw/skills/
openclaw/**/*.local.json
openclaw/state/
openclaw/sessions/
openclaw/logs/
openclaw/cache/
openclaw/npm/
```

Do not ignore `openclaw/plugins/managed-plugins.json`.

- [ ] **Step 3: Extend `manifests/whitelist.psd1`**

Add OpenClaw paths:

```powershell
OpenClaw = @{
    HomeRelativeRoot = '.openclaw'
    RepoRelativeRoot = 'openclaw'
    PushItems = @('plugins/managed-plugins.json')
    PullItems = @('plugins/managed-plugins.json')
    ExcludedItems = @('identity', 'credentials', 'devices', 'sessions', 'logs', 'cache', 'npm', 'plugins/installs.json', 'exec-approvals.json', 'node.json', 'auth-profiles.json')
}
```

Add `OpenClawOnlySource`, `GeneratedOpenClaw`, and target-scoped manifest paths under `Skills`.

- [ ] **Step 4: Verify docs and ignore rules**

Run:

```powershell
git status --short --ignored
```

Expected: `openclaw/skills/` is ignored after generation, while `openclaw/plugins/managed-plugins.json` remains trackable.

## Task 3: Add Target-Scoped Skill Manifests

**Artifacts / Locations:**
- Modify: `scripts/build-skills.ps1`
- Modify: `scripts/sync.ps1`
- Modify: `manifests/managed-skills.txt`
- Create: `manifests/managed-skills.claude.txt`
- Create: `manifests/managed-skills.codex.txt`
- Create: `manifests/managed-skills.openclaw.txt`

- [ ] **Step 1: Build platform-specific skill name sets**

In `build-skills.ps1`, compute:

```text
claude = shared + claude-only
codex = shared + codex-only
openclaw = shared + openclaw-only
union = claude + codex + openclaw
```

Write one sorted UTF-8 no-BOM manifest per target and keep `managed-skills.txt` as the sorted union.

- [ ] **Step 2: Strengthen conflict checks**

Fail build when the same skill name appears in `shared/` and any platform-only source. Also fail when the same skill appears in more than one platform-only source unless a reviewer explicitly moves it to `shared/`.

- [ ] **Step 3: Update sync to read the target manifest**

Change `Get-SyncPlan` callers so Claude reads `managed-skills.claude.txt`, Codex reads `managed-skills.codex.txt`, and OpenClaw reads `managed-skills.openclaw.txt`.

Expected: a Codex-only skill name in live OpenClaw is reported as unknown, not pruned.

- [ ] **Step 4: Verify manifests**

Run:

```powershell
pwsh -NoProfile -File scripts/build-skills.ps1
```

Expected output includes `Built Claude skills: N`, `Built Codex skills: N`, `Built OpenClaw skills: N`, and all four manifest files are updated.

## Task 4: Extend Skill Build Output for OpenClaw

**Artifacts / Locations:**
- Create: `skills-source/openclaw-only/.gitkeep`
- Create: `openclaw/.gitkeep`
- Modify: `scripts/build-skills.ps1`

- [ ] **Step 1: Add OpenClaw source and output roots**

Add:

```powershell
$openclawOnlySource = Join-RepoPath 'skills-source/openclaw-only'
$openclawTarget = Join-RepoPath 'openclaw/skills'
```

OpenClaw build output must include every `shared` skill and every `openclaw-only` skill.

- [ ] **Step 2: Preserve runtime exclusions**

Use the existing `Copy-SkillDirectory` helper so generated OpenClaw skills also strip:

```text
MERGE_NOTES.md
CREATION-LOG.md
*.magina-laptop.*
```

Do not add `.clawhub` to runtime exclusions. If a reviewed source skill contains `.clawhub`, generated OpenClaw output should contain it.

- [ ] **Step 3: Verify generated output is ignored**

Run:

```powershell
pwsh -NoProfile -File scripts/build-skills.ps1
git status --short --ignored
```

Expected: `openclaw/skills/` appears only as ignored generated output, not as tracked files.

## Task 5: Extend Backup for OpenClaw

**Artifacts / Locations:**
- Modify: `scripts/backup.ps1`

- [ ] **Step 1: Add `-HomeRoot`**

Add a `-HomeRoot` parameter defaulting to `$env:USERPROFILE`. Use it for Claude, Codex, and OpenClaw live path resolution so tests can run against `tests/fixtures/fake-home`.

- [ ] **Step 2: Back up OpenClaw managed roots**

Back up these paths when present:

```text
<HomeRoot>\.openclaw\skills
<HomeRoot>\.openclaw\workspace\skills
<HomeRoot>\.openclaw\plugins\installs.json
```

Use directory copies for skill roots and a file copy for `installs.json`. Missing paths should create `.MISSING.txt` markers, matching current backup behavior.

- [ ] **Step 3: Keep backup outside repo**

Reuse the existing backup-root safety check. The backup manifest must include OpenClaw source paths, target paths, existence booleans, skill counts, file counts, and whether plugin install state existed.

- [ ] **Step 4: Verify dry-run**

Run:

```powershell
pwsh -NoProfile -File scripts/backup.ps1 -DryRun
```

Expected: dry-run reports Claude, Codex, and OpenClaw backup plans and copies no files.

## Task 6: Extend Skill Sync for OpenClaw

**Artifacts / Locations:**
- Modify: `scripts/sync.ps1`

- [ ] **Step 1: Add `-HomeRoot` and OpenClaw path resolution**

Add `-HomeRoot` defaulting to `$env:USERPROFILE`. Resolve OpenClaw live skills by default as:

```text
<HomeRoot>\.openclaw\skills
```

Add an optional `-OpenClawLiveSkillsPath` override for a deliberate workspace deployment.

- [ ] **Step 2: Add OpenClaw plan computation**

Add:

```powershell
$openclawSource = Join-Path $RepoRoot 'openclaw\skills'
$openclawLive = Get-OpenClawLiveSkillsPath
$openclawPlan = Get-SyncPlan -Platform 'openclaw' -SourceRoot $openclawSource -LiveRoot $openclawLive -ManagedNames $openclawManagedNames
```

Report add, update, prune, unknown, and `.clawhub` counts.

- [ ] **Step 3: Preserve `.clawhub` safely during updates**

Implement OpenClaw updates with one of these safe mechanisms:

- Copy each live `.clawhub` directory to a temporary preservation directory before deleting the live skill, then restore it after copying generated source if generated source lacks that same `.clawhub` path.
- Or restore from the mandatory backup directory created earlier in the same apply run.

The implementation must verify every preservation and restore path is under the expected live skill root or temp root before copying.

- [ ] **Step 4: Define prune behavior**

Prune only a top-level OpenClaw skill directory whose name is in `managed-skills.openclaw.txt` and absent from `openclaw/skills/`.

Unknown OpenClaw live skills are reported and never deleted. Nested `.clawhub` directories are deleted only when their owning managed skill is intentionally pruned.

- [ ] **Step 5: Extend post-apply verification**

Verify:

```text
Claude live top-level dirs == claude/skills
Codex live top-level dirs == codex/skills, excluding .system
OpenClaw managed live top-level dirs == openclaw/skills, allowing unknown top-level dirs and preserved nested .clawhub
```

Expected: OpenClaw unknown skills remain in place and do not fail the apply.

## Task 7: Add Plugin Desired-State Sync

**Artifacts / Locations:**
- Create: `openclaw/plugins/managed-plugins.json`
- Create: `scripts/sync-openclaw-plugins.ps1`
- Modify: `scripts/sync.ps1`
- Modify: `scripts/auto-sync-after-git.ps1`

- [ ] **Step 1: Create the managed plugin schema**

Create `openclaw/plugins/managed-plugins.json` with:

```json
{
  "version": 1,
  "plugins": []
}
```

Add schema validation in `scripts/sync-openclaw-plugins.ps1`:

- `id` is required.
- `enabled` is required.
- Non-bundled entries require `source`.
- Bundled entries must not set `source` unless it is an OpenClaw-documented bundled id alias.
- Marketplace entries must set both `source` and `marketplace`.
- `allowUninstall` defaults to `false`.
- Absolute local paths are rejected.
- Fields outside the approved schema fail validation.

- [ ] **Step 2: Implement plugin dry-run**

Dry-run reads `managed-plugins.json` and live plugin inventory from `openclaw plugins list --json` when available, falling back to sanitized `installs.json` reads.

Report:

```text
would install
would update
would enable
would disable
would uninstall
unknown plugins ignored
bundled plugins preserved
```

Dry-run must not run plugin lifecycle mutators.

- [ ] **Step 3: Implement plugin apply through OpenClaw CLI**

Apply must run after backup and secret scan. Use:

```powershell
openclaw plugins install <source>
openclaw plugins install <source> --marketplace <marketplace>
openclaw plugins update <id-or-source>
openclaw plugins enable <id>
openclaw plugins disable <id>
openclaw plugins uninstall <id>
```

Before uninstalling, require `allowUninstall: true`, confirm the plugin id is in `managed-plugins.json`, and run:

```powershell
openclaw plugins uninstall <id> --dry-run
```

Never use `--dangerously-force-unsafe-install` in automation. If OpenClaw blocks an install or update, fail and report the exact plugin id and command.

- [ ] **Step 4: Verify plugin state**

After apply, run:

```powershell
openclaw plugins list --json
```

Expected: every managed plugin id exists with the desired enablement state. Unknown plugins remain untouched. Bundled plugins are never uninstalled.

- [ ] **Step 5: Wire plugin sync into main sync**

`scripts/sync.ps1` should call `scripts/sync-openclaw-plugins.ps1` during dry-run and apply when `openclaw/plugins/managed-plugins.json` exists.

`scripts/auto-sync-after-git.ps1` relevant pathspecs must include:

```text
openclaw/plugins/managed-plugins.json
scripts/sync-openclaw-plugins.ps1
```

## Task 8: Reverse-Import Reviewed OpenClaw Skills

**Artifacts / Locations:**
- Read: `imports/skills-reports/openclaw-inventory.md`
- Create or modify: `skills-source/openclaw-only/<skill>/`
- Archive raw imports under: `imports/skills-archive/`
- Quarantine unsafe imports under: `imports/skills-quarantine/`

- [ ] **Step 1: Select import candidates**

From `openclaw-inventory.md`, import only user/workspace/managed local skills that are not already represented by `skills-source/shared/`.

Do not import bundled OpenClaw package skills unless the reviewer explicitly wants to fork and own that skill in this repo.

- [ ] **Step 2: Stage raw candidates into inbox**

Copy selected raw candidates into:

```text
imports/skills-inbox/openclaw/<machine-id>/<source-root>/<skill>/
```

This inbox remains ignored by Git. It is a temporary review staging area.

- [ ] **Step 3: Promote through normalization**

Extend `scripts/promote-skill.ps1` and `Normalize-SkillDirectory` to accept `openclaw-only`.

For each approved skill, promote to:

```text
skills-source/openclaw-only/<skill>/
```

Keep `.clawhub` only when `scan-secrets.ps1` passes and the directory contains registry metadata rather than credentials or machine-local state.

- [ ] **Step 4: Validate imports**

Run:

```powershell
pwsh -NoProfile -File scripts/build-skills.ps1
pwsh -NoProfile -File scripts/scan-secrets.ps1
```

Expected: OpenClaw build count increases by the number of approved OpenClaw-only imports, and secret scan has no blocking findings.

## Task 9: Add Fake-Home Tests and Live Dry-Run Verification

**Artifacts / Locations:**
- Modify: `tests/fixtures/fake-home/`
- Create: `tests/fixtures/fake-home/.openclaw/skills/`
- Create: `tests/fixtures/fake-home/.openclaw/plugins/installs.json`

- [ ] **Step 1: Create fake OpenClaw fixtures**

Add fixture skills:

```text
tests/fixtures/fake-home/.openclaw/skills/managed-old/SKILL.md
tests/fixtures/fake-home/.openclaw/skills/unknown-local/SKILL.md
tests/fixtures/fake-home/.openclaw/skills/preserve-clawhub/.clawhub/metadata.json
```

Add a sanitized plugin install fixture with one bundled plugin, one managed plugin, and one unknown plugin. Use fake ids and no real package paths.

- [ ] **Step 2: Run fake-home dry-run**

Run:

```powershell
pwsh -NoProfile -File scripts/sync.ps1 -RepoRoot $PWD -HomeRoot tests/fixtures/fake-home
```

Expected: dry-run reports OpenClaw add/update/prune/unknown accurately and makes no file changes.

- [ ] **Step 3: Run fake-home apply**

Run:

```powershell
pwsh -NoProfile -File scripts/sync.ps1 -RepoRoot $PWD -HomeRoot tests/fixtures/fake-home -Apply -BackupRoot "$PWD\tmp\fake-backups"
```

Expected: managed fake skills converge, unknown fake skills remain, preserved `.clawhub` remains, and backup is written under `tmp/fake-backups`.

- [ ] **Step 4: Run real live dry-run only**

Run:

```powershell
pwsh -NoProfile -File scripts/sync.ps1
```

Expected: real dry-run reports Claude, Codex, and OpenClaw plans. No live files change.

## Task 10: Final Validation and Handoff

**Artifacts / Locations:**
- Review: Git diff
- Review: `docs/README.md`
- Review: `STATUS.md`

- [ ] **Step 1: Run required checks**

Run:

```powershell
pwsh -NoProfile -File scripts/build-skills.ps1
pwsh -NoProfile -File scripts/scan-secrets.ps1
pwsh -NoProfile -File scripts/sync.ps1
git status --short --ignored
git diff --check
```

Expected: build and scan pass, sync is dry-run only, generated outputs are ignored, and diff whitespace check passes.

- [ ] **Step 2: Confirm commit scope**

Tracked changes may include:

```text
AGENTS.md
CLAUDE.md
.gitignore
manifests/
scripts/
skills-source/openclaw-only/
openclaw/plugins/managed-plugins.json
docs/
tests/fixtures/
```

Tracked changes must not include:

```text
claude/skills/
codex/skills/
openclaw/skills/
imports/skills-inbox/
imports/skills-archive/raw-copies/
imports/skills-quarantine/
backup/
tmp/
any file from %USERPROFILE%\.openclaw
```

- [ ] **Step 3: Record current state**

Update `STATUS.md` with:

- OpenClaw managed skill count.
- OpenClaw managed plugin count.
- Whether only dry-run or live apply was performed.
- Machine names verified.
- Any unknown OpenClaw live skills or plugins intentionally left unmanaged.

## Acceptance Criteria

- `skills-source/` remains the only hand-maintained skill source tree.
- `openclaw/skills/` is generated and ignored.
- OpenClaw skill sync is target-manifest-scoped and dry-run by default.
- OpenClaw plugin sync uses `openclaw plugins` commands and never edits `installs.json` directly.
- OpenClaw bundled package skills/plugins are preserved unless explicitly forked or enablement-managed.
- No OpenClaw identity, credentials, approvals, device state, auth profiles, sessions, caches, npm payloads, or machine-private paths are committed.
- Existing Claude/Codex behavior, including Codex `.system` preservation, remains unchanged.
