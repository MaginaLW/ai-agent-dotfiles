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

Dated status logs live in [`status/archived/`](../status/archived/). Archived records may link
to files that no longer exist; read those files at the commits above.
