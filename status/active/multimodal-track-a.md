# Track A: shared multimodal-generation skill

- Owner decisions: plan §6 (2026-11-15).
- Worktree/branch: separate worktree, branch `antigravity/multimodal-skill-20261115` from `main` `1a40a31`.
- Scope: new `skills-source/shared/multimodal-generation/`; selections `work` (Codex, ZCode),
  `full` (all three); manifests; Antigravity `ManagedPlugin` 0.3.0 → 0.4.0 with test expectation;
  README/manual/STATUS references; plan doc committed with decisions.
- Not authorized here: merge, `work` deploy Apply (adds one install, outside Skill rules 10),
  Antigravity uninstall/reinstall, any paid API call.
- Remaining after merge (each needs authorization): `deploy-skills.ps1 -Environment work` dry run
  → Apply → readback; Antigravity 0.4.0 via the documented uninstall + `antigravity deploy -Apply`
  path with the App closed; one subscription-only acceptance per host.
