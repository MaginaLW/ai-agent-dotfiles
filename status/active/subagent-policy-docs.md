# Subagent policy documentation

- Owner: current root task; primary checkout.
- Baseline: `258b528`.
- Scope: update `README.md` and `docs/README.md` for the Codex `work` selection and the shared
  subagent skill. No skill, environment, live, config, deploy or behavior changes.
- Acceptance: the 8/9/8 `work` selection and `full` coverage are accurate; skill scope and
  authority boundaries are linked without duplicating volatile host limits.
- State: documentation ready; validation passed.
- Checks: pinned gitleaks (172 files, no leaks) and `git diff --check` passed. No build, tests or live changes were needed.
- Handoff: root task owns commit, push, CI verification and removal.
