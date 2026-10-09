# Design and plan history

The implementation plans and design specs for finished work were removed from the tree on
2026-10-09 to cut reading cost. Git keeps them. The last commit that still has them is
`bd46b85`.

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

Dated status logs live in [`status/archived/`](../status/archived/).