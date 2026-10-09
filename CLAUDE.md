# CLAUDE.md

@AGENTS.md

## Claude Code notes

- The project rules live in `AGENTS.md`, which is imported above and shared with Codex and ZCode.
  Change rules there, not here.
- `.claude/settings.json` enforces part of those rules through the harness:
  - it denies Edit/Write on the generated `claude/skills/` and `codex/skills/` roots and on Codex
    `.system`;
  - it denies `robocopy`;
  - it allow-lists only the three checks below.
- The generated `reasonix/skills/` root is covered only by the AGENTS.md rule. Live-mutating
  scripts are intentionally not allow-listed. Do not add them or loosen the denies without owner
  approval.

```powershell
pwsh -NoProfile -File scripts/build-skills.ps1
pwsh -NoProfile -File scripts/scan-secrets.ps1
pwsh -NoProfile -File scripts/check-hooks.ps1
```
