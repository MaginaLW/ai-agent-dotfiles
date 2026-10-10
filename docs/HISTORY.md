# Design and plan history

Removed code and docs stay in Git history. This page says where to find them.

## Transactional live-sync engine (removed 2026-10-09)

The transactional engine was replaced by `scripts/deploy-skills.ps1` and removed on 2026-10-09,
together with its tests, schemas, Git hooks, approved runner and docs. The last commit that
still has all of it is `c011fb4`.

| Former path | Content |
|---|---|
| `scripts/sync.ps1`, `scripts/live-*`, `scripts/canonical-*`, `scripts/*-harness-env.ps1`, `scripts/task-skills.ps1`, `scripts/backup*.ps1`, `scripts/internal/` | Plan-bound sync and retirement, live and canonical transactions and recovery, environment activate/rollback/authority, task-skill overlay, backup receipts, the sandbox host |
| `scripts/live-safety-policy.psd1`, `scripts/live-safety-interlock.ps1`, `scripts/runner-policy.psd1` | The release policy, the interlock and the runner toolchain list |
| `scripts/setup.ps1`, `scripts/apply-hooks.ps1`, `scripts/check-hooks.ps1`, `scripts/auto-sync-after-git.ps1`, `scripts/approved-*` | The approved Git-private runner and the preview-only Git hooks |
| `schemas/`, `tools/schema-validator/` | JSON artifact schemas and the pinned schema validator |
| `tests/` (about 30 suites), `tests/test-shards.psd1` | Engine test suites and the CI shard partition |
| `docs/RESTORE.md`, `docs/CI_FAILURE_RULES.md` | Rollback/transaction recovery guide and the CI failure rules R1-R11 |

```powershell
git ls-tree -r --name-only c011fb4 -- scripts schemas tests docs
git show c011fb4:docs/CI_FAILURE_RULES.md
```

## Design and plan docs (removed 2026-10-09)

The implementation plans and design specs for finished work were removed from the tree on
2026-10-09 to cut reading cost. The last commit that still has them is `bd46b85`.

| Former path | Content |
|---|---|
| `docs/superpowers/plans/` | Plans: live-safety phases 0-4 and roadmap, hard-kill checkpoints, the post-audit completion plan, harness env phases 1-3, project harness profiles, task-skill hotplug, runtime drift repair, skill/MCP dedup, the agent-platform hardening roadmap |
| `docs/superpowers/specs/` | Designs: live-safety hardening, harness env, task-skill hotplug |
| `docs/specs/` | The Phase 4 schema/CI/release proposal and the project harness profiles design |
| `docs/archive/` | Early sync plan v2, the auto-merge instructions and workflow, the MCP multi-platform design |

To read or restore one:

```powershell
git show bd46b85:docs/superpowers/specs/2026-08-09-live-safety-hardening-design.md
git ls-tree -r --name-only bd46b85 -- docs/superpowers docs/specs docs/archive
```

## Dated status journals and task records (removed 2026-10-10)

The dated status journals and finished task records under `status/archived/` (about 1 MB, mostly
about the removed transactional engine) were removed on 2026-10-10. The last commit that still
has them is `3341ec9`. They may link to files that no longer exist; read those files at the
commits above.

```powershell
git ls-tree -r --name-only 3341ec9 -- status/archived
git show 3341ec9:status/archived/2026-10-08-status-history.md
```

## Skills import and merge pipeline (removed 2026-10-10)

The import pipeline (`imports/` inbox, archive, quarantine and reports; `inventory-`, `analyze-`,
`dedupe-skills.ps1`, `auto-merge-skills.ps1`, `normalize-skill.ps1`, `skill-candidate-common.ps1`
and `docs/MERGE_POLICY.md`) was replaced by the small `scripts/promote-skill.ps1` on 2026-10-10,
together with the build run reports (`report-common.ps1`, `reports/README.md`) and the guide
code-block checker (`check-guide-examples.ps1`). The last commit that still has them is
`3341ec9`.

```powershell
git show 3341ec9:docs/MERGE_POLICY.md
git show 3341ec9:scripts/auto-merge-skills.ps1
```

## ZCode feedback-loop pilot (paused 2026-10-10)

The owner paused this repository's harness-model feedback-loop pilot on 2026-10-10. The full
`docs/ZCODE.md` (adoption notes, source versions, the five method adaptations) and the AGENTS.md
feedback-loop section are in commit `08d9021`; the thirteen dated loop runs are in `3341ec9`.

```powershell
git show 08d9021:docs/ZCODE.md
git show 3341ec9:status/archived/2026-10-09-zcode-feedback-loop-history.md
```

## Skill merge notes (removed 2026-10-10)

Each imported skill carried a `MERGE_NOTES.md` with its upstream source and import details. Some
of them named a machine or a local backup path, so all of them were removed; build had always
excluded them from the generated output. The last commit that has them is `ee96301`.

```powershell
git ls-tree -r --name-only ee96301 -- skills-source | Select-String MERGE_NOTES
git show ee96301:skills-source/shared/brainstorming/MERGE_NOTES.md
```

## Multi-platform harness profile (removed 2026-10-10)

The unused `multi-platform` library profile, the components only it selected (`commit-command`,
`claude-reviewer`, `codex-reviewer`, `review-prompt`) and `tests/harness-multiplatform.tests.ps1`
were removed on 2026-10-10, together with the unused `Future`, `Requires` and `Conflicts` schema
fields. The Command, ClaudeAgent, CodexPrompt and CodexAgent kinds are still supported and tested
in `tests/harness-profile.tests.ps1`. The last commit that still has them is `d11e081`.

```powershell
git show d11e081:harness-source/profiles/multi-platform.psd1
git ls-tree -r --name-only d11e081 -- harness-source/components
```
