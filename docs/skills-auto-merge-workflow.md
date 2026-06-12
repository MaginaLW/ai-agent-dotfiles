# Skills Auto-Merge Workflow

Phase 2.6 adds a local-only workflow for collecting and consolidating Claude Code and Codex skills before any real sync exists.

## Flow

1. Inventory each machine into `imports/skills-inbox/<machine-id>/`.
2. Analyze inbox skills and current `skills-source/` into structured reports.
3. Auto-merge low-risk duplicates and similar skills into `skills-source/`.
4. Move high-risk skills into `imports/skills-quarantine/`.
5. Archive duplicate or superseded raw copies under `imports/skills-archive/`.
6. Run `scripts/build-skills.ps1` to regenerate Claude and Codex build outputs.
7. Run `scripts/scan-secrets.ps1` before any commit.

## Human Review

The workflow is intended to auto-integrate low-risk skills. You do not need to promote each skill manually.

Review these outputs instead:

- `imports/skills-reports/skills-analysis.md`
- `imports/skills-reports/auto-merge-report.md`
- quarantine counts and reasons

## Safety

This workflow does not write to real `~/.claude`, `~/.codex`, `~/.agents/skills`, or `~/.claude.json`.

Use `-HomeRoot` explicitly for inventory. In phase 2.6 tests, `-HomeRoot` must point at `tests/fixtures/fake-home`.
