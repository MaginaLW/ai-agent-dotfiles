# Project Harness Profiles Design

Date: 2026-06-29
Status: proposed design

## Goal

Build a project-level harness profile system that works like a conservative
Anaconda-style environment manager for agent harness configuration:

```text
Global Library -> Project Profile -> Local Overlay
```

The global repository remains the reusable library of reviewed components. Each
project declares the components it wants in `.agent-harness/profile.psd1`. The
profile tooling composes those components into project-local harness files after
dry-run review. Machine-private state remains local and is never captured into
the repository.

## Non-Goals

- Do not switch or rewrite `~/.claude`, `~/.codex`, or `~/.openclaw` in the
  first version.
- Do not support project-local skills in the first version.
- Do not allow arbitrary external component paths, URLs, UNC paths, or home
  directory references.
- Do not commit generated harness output as a second source of truth.
- Do not weaken the existing secret scan, path scan, Codex `.system`, or
  generated-output protections.

## Existing Fit

The repository already has the safety posture this feature needs:

- `manifests/whitelist.psd1` defines managed harness config scope.
- `scripts/config-status.ps1`, `scripts/config-pull.ps1`, and
  `scripts/config-push.ps1` are whitelist-scoped and dry-run by default.
- `scripts/config-push.ps1` has both secret and machine-private path gates.
- Skills already use a source/build/generated/live separation.
- The repository already distinguishes global harness config such as
  `claude/settings.json` from project guardrails such as `.claude/settings.json`.

This design should extend those patterns instead of inventing a separate sync
style.

## Core Model

### Global Library

The dotfiles repository owns reviewed, reusable harness components:

```text
harness-source/
  components/
    rules/
    prompts/
    commands/
    agents/
    claude-settings/
    codex-agents/
    mcp-templates/
  profiles/
    base.psd1
    coding.psd1
    writing.psd1
    security-review.psd1
```

`harness-source/` is hand-maintained source. It is analogous to
`skills-source/`, but for project harness composition rather than platform skill
runtime output.

### Project Profile

Each project opts into a combination:

```text
project-repo/
  .agent-harness/
    profile.psd1
    generated/        # derived output, gitignored by default
```

The profile is declarative. It names components and profiles; it does not embed
machine-private values.

### Local Overlay

Local machine state remains outside this system:

- auth files
- sessions
- caches
- CLI history
- absolute local paths
- API keys, tokens, passwords, and credentials
- machine-specific proxy or launcher configuration

Profiles may reference environment variable names, but not secret values.

## Profile Schema

The first version uses PowerShell data files because the repository already uses
PowerShell 7+ scripts and `.psd1` manifests.

Example project profile:

```powershell
@{
    SchemaVersion = 1
    Name = 'example-project'
    TargetPlatforms = @('Claude', 'Codex')

    Extends = @('base', 'coding')

    Components = @{
        Rules = @(
            'safe-file-edits',
            'no-generated-output-edits'
        )
        Prompts = @(
            'commit-summary',
            'pr-review'
        )
        Commands = @()
        Agents = @()
        ClaudeSettings = @(
            'project-guards'
        )
        CodexAgents = @(
            'default-codex-project'
        )
        McpTemplates = @()
    }

    Future = @{
        ProjectSkills = @() # reserved; first version reports not implemented
    }
}
```

Rules:

- `SchemaVersion` is required.
- `TargetPlatforms` is required and may include `Claude`, `Codex`, and
  `OpenClaw`.
- `Extends` is optional and resolves against `harness-source/profiles/`.
- Component names resolve only inside `harness-source/components/` or the
  current project's `.agent-harness/overlays/`.
- Absolute paths, `..` escapes, UNC paths, URLs, and home-directory references
  are invalid.
- Unknown fields fail validation unless explicitly under `Future`.

## Component Schema

Each component has metadata and content. A component directory is preferred over
a single loose file because it can grow without changing the profile schema:

```text
harness-source/components/rules/safe-file-edits/
  component.psd1
  content.md
```

Example metadata:

```powershell
@{
    SchemaVersion = 1
    Id = 'safe-file-edits'
    Kind = 'Rule'
    TargetPlatforms = @('Claude', 'Codex')
    Requires = @()
    Conflicts = @()
    Outputs = @(
        @{
            Target = 'AGENTS.md'
            Mode = 'ManagedBlock'
            BlockId = 'agent-harness'
        }
    )
}
```

Rules:

- `Id` must be globally unique across `harness-source/components/`.
- `SchemaVersion`, `Kind`, and `TargetPlatforms` are required.
- `Requires` and `Conflicts` are validated before generation.
- Unsupported platform/component combinations are reported during build.
- Two components may not write the same target unless the target has an explicit
  merge strategy.

## Merge And Ownership Rules

### Profile Merge

- `Extends` resolves in listed order.
- Later profiles override earlier profiles for scalar values.
- Project profile values override inherited profile values.
- Arrays are appended with stable de-duplication.
- Objects are deep-merged.
- Conflicting components fail with a conflict report.

### File Ownership

Targets use explicit ownership modes:

| Mode | Meaning |
| --- | --- |
| `ManagedBlock` | Replace only a marked block inside an existing file. |
| `StructuredMerge` | Parse and merge a structured file such as JSON. |
| `DirectoryFiles` | Manage selected files under an allowlisted directory. |
| `GeneratedOnly` | Emit review output under `.agent-harness/generated/`. |

`AGENTS.md` and `CLAUDE.md` default to `ManagedBlock`, not whole-file
replacement:

```markdown
<!-- BEGIN AGENT-HARNESS: generated -->
...
<!-- END AGENT-HARNESS: generated -->
```

If a document exists without the markers, apply does not modify it by default.
The dry-run report tells the user to add markers or use a future explicit
override.

### Settings Merge

`.claude/settings.json` uses `StructuredMerge`.

- Non-managed existing keys are preserved.
- Managed keys are updated from composed fragments.
- `permissions.deny` may only be appended to or tightened.
- A profile may not remove existing global safety denies.
- Permission changes are shown in the status and apply dry-run reports.

## First-Version Write Scope

The apply script may only write project-local paths in this allowlist:

```text
AGENTS.md
CLAUDE.md
.claude/settings.json
.claude/commands/
.claude/agents/
.codex/prompts/
.agent-harness/generated/
```

Every target path must be normalized and resolved before writing. The resolved
path must remain inside the project root and within the allowlist. This check
must reject `..` escapes, UNC paths, absolute paths, symlink or junction
escapes, and case-normalization tricks.

## Generated Output

`build-harness-profile.ps1` writes derived output under:

```text
.agent-harness/generated/
```

This directory is gitignored by default. It contains review artifacts such as:

```text
manifest.json
plan.json
AGENTS.generated.md
CLAUDE.generated.md
claude-settings.generated.json
```

`manifest.json` records:

- profile path
- resolved `Extends` chain
- component IDs
- source paths
- content hashes
- target platforms
- generator version
- generated timestamp

This is not a lockfile in the first version. A future
`.agent-harness/profile.lock.json` can add locked reproducibility once the
schema and merge rules have stabilized.

## Script Responsibilities

### `scripts/status-harness-profile.ps1`

Read-only. It reports:

- project profile location
- resolved profiles and components
- missing, duplicate, unsupported, required, or conflicting components
- target files and ownership modes
- permission diffs
- whether generated output differs from the project targets
- whether apply would add, update, or skip each target

It never writes.

### `scripts/build-harness-profile.ps1`

Builds generated review output only.

Required behavior:

- read `.agent-harness/profile.psd1`
- validate schema
- resolve `Extends`
- validate component IDs, dependencies, conflicts, and target platforms
- generate `.agent-harness/generated/`
- run secret scanning against profile, components, and generated output
- run machine-private path scanning against profile, components, and generated
  output
- produce a manifest and human-readable summary

It does not modify active harness files such as `AGENTS.md`,
`CLAUDE.md`, or `.claude/settings.json`.

### `scripts/apply-harness-profile.ps1`

Dry-run by default. With `-Apply`, it writes only allowlisted project targets.

Required behavior:

- run the same validation as build
- show add/update/skip plan before applying
- back up every project file that will be overwritten
- write a backup manifest with original path, backup path, action, hash, and
  timestamp
- apply changes file-by-file
- on write failure, restore files already changed when possible
- report any partial failure clearly
- never touch home-level harness directories

## Security Gates

The safety model applies to all of these:

- project profile
- inherited profiles
- component metadata
- component content
- generated output
- apply targets

Required gates:

- `scripts/scan-secrets.ps1`
- machine-private path scan
- repo-local path normalization
- component source boundary check
- target allowlist check
- permission tightening check

Allowed examples:

```text
GITHUB_PAT
OPENAI_API_KEY
ANTHROPIC_API_KEY
```

These are names only. Real values are forbidden.

## Tests

First-version tests should use a fake project under `tmp/` or a test fixture.

Required cases:

- status is read-only
- build writes only `.agent-harness/generated/`
- apply dry-run writes nothing
- apply writes only allowlisted project paths
- repeated build is idempotent
- apply followed by status is clean
- existing `AGENTS.md` without markers is not modified
- marker block replacement works
- `.claude/settings.json` preserves unmanaged keys
- `permissions.deny` cannot be removed
- duplicate component IDs fail
- `Requires` and `Conflicts` are enforced
- unsupported target platform is reported
- path escape attempts fail
- secret and machine-private path gates fail closed

## Implementation Phases

### Phase 1: Design And Fixtures

- Add this design document.
- Add fixture profiles and component examples.
- Decide exact `.psd1` schema names.

### Phase 2: Read-Only Status

- Implement `status-harness-profile.ps1`.
- Add validation for schema, component resolution, conflicts, and target paths.

### Phase 3: Build Generated Output

- Implement `build-harness-profile.ps1`.
- Generate review artifacts under `.agent-harness/generated/`.
- Add manifest hash reporting.

### Phase 4: Apply Project Targets

- Implement `apply-harness-profile.ps1`.
- Add backup manifest and failure recovery.
- Add managed block and structured merge writers.

### Phase 5: Hardening

- Add regression tests.
- Add documentation to `docs/README.md`.
- Update `AGENTS.md` and `CLAUDE.md` scope triggers after scripts exist.

## Later Decisions

These are intentionally out of first-version scope:

- committed `.agent-harness/profile.lock.json`
- project-local `.agents/skills` or `.claude/skills`
- external component registries or caches
- JSON export for non-PowerShell consumers
- a dedicated `restore-harness-profile.ps1`
- automatic activation of home-level harness environments

## Acceptance Criteria

- The global repository remains the component source of truth.
- A project can declare a harness profile without copying global home config.
- Dry-run shows what will be generated and applied.
- Generated output is disposable and gitignored by default.
- Apply writes only allowlisted project paths.
- Existing project docs are not overwritten unless managed markers are present.
- `.claude/settings.json` permissions can only become stricter.
- Secrets, machine-private paths, and unsafe external references fail closed.
- Repeated build/apply/status cycles are idempotent.
