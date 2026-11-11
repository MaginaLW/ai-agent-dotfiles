# Subagent policy candidate

- Owner: current root task; source writer committed the candidate on its task branch.
- Baseline: `5117048`; task branch `codex/subagent-capacity`.
- Scope: Codex delegation agreements, shared subagent skill and implementer template,
  Codex work selection, and current status. No additional home config or live deployment
  remains for this batch.
- Acceptance: whole-root shared concurrency (50, lead excluded; lifetime creations uncapped),
  host limits, active expansion and staged minimal context stay explicit; work changes only
  Codex selection; required safety gates remain.
- State: independent review passed with no blocking findings; source commit `30523eb`.
  The live `work` deployment and Codex managed-block config update are present and verified.
  Branch integration into `main`, remote CI and active-record removal remain pending.
- Checks: root re-ran build (12 Claude / 19 Codex), pinned gitleaks (172 files, no leaks),
  skill-creator quick validation, generated parity and `git diff --check`. The pre-Apply dry
  run planned one Codex skill install and the config update; the post-deploy dry run reports
  25 unchanged, 0 install/update/prune/unknown, and config-status reports 3 in-sync.
  No full validation or model/native execution ran.
- Handoff: root task owns integration, remote CI verification and removal of this active record.
