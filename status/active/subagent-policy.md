# Subagent policy candidate

- Owner: current root task; source writer committed the candidate on its task branch.
- Baseline: `5117048`; task branch `codex/subagent-capacity`.
- Scope: Codex delegation agreements, shared subagent skill and implementer template,
  Codex work selection, and current status. No home config or live deployment in this batch.
- Acceptance: whole-root shared concurrency (50, lead excluded; lifetime creations uncapped),
  host limits, active expansion and staged minimal context stay explicit; work changes only
  Codex selection; required safety gates remain.
- State: independent review passed with no blocking findings; source commit `30523eb`.
  Integration and live deployment are pending a separate owner decision.
- Checks: root re-ran build (12 Claude / 19 Codex), pinned gitleaks (172 files, no leaks),
  skill-creator quick validation, generated parity, `git diff --check`, and the `work`
  combined deployment dry run. The dry run planned one Codex skill install and the Codex
  managed-block config update; every other selected skill was unchanged. No full validation,
  model/native execution or live Apply ran.
- Handoff: root task owns integration, deployment and removal of this active record.
