# Runtime Drift and Guard Repair Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** Restore the local validation gate, make OpenClaw plugin inspection fail fast instead of hanging, repair stale generated environment staging, and prepare the current machine's managed skill state without silently switching the project between `full` and `work` environments.

**Approach:** Repair the two stale, local raw-import examples using the already-correct canonical wording rather than weakening secret scanning. Add a bounded OpenClaw CLI probe with sanitized config fallback and regression tests, rebuild the generated environment staging, then rebuild, scan, generate and review a fingerprint-bound sync plan. Leave live apply and the `full` versus `work` environment choice explicit because the local OpenClaw CLI does not return and switching environments can prune managed skills.

**Materials:** `skills-source/codex-only/security-best-practices/`, the two matching files under `imports/skills-inbox/` and `imports/skills-archive/`, `scripts/scan-secrets.ps1`, `scripts/sync-openclaw-plugins.ps1`, `tests/openclaw-plugin.tests.ps1`, `scripts/sync.ps1`, `scripts/status-harness-env.ps1`, and `STATUS.md`.

**Validation:** `scan-secrets.ps1` exits 0 without a whitelist; the plugin regression suite proves a hung CLI falls back within the configured timeout; build and all regression suites pass; the sync dry-run contains only the known `codex/hatch-pet` update with no prune and `.system` preserved; final Git status is clean except for intentional tracked documentation/code changes.

---

### Task 1: Repair the local raw-import false positives

**Artifacts / Locations:**
- Modify: `imports/skills-inbox/magina-laptop/codex/security-best-practices/references/javascript-express-web-server-security.md` (ignored local raw import)
- Modify: `imports/skills-archive/merged/magina-laptop/codex/security-best-practices/references/javascript-express-web-server-security.md` (ignored local raw archive)
- Review: `skills-source/codex-only/security-best-practices/references/javascript-express-web-server-security.md`

- [x] **Step 1: Compare the canonical and imported wording**

Read the matching section and confirm the only blocking difference is the illustrative quoted values on line 341; preserve all other raw-import content.

- [x] **Step 2: Rewrite only the stale illustrative sentence**

Replace the quoted literal examples with the descriptive wording already present in the canonical source: explain that a session secret must not be hard-coded and should be loaded from an environment variable or secret manager. Do not add `scan-ok`, edit `.gitleaks.toml`, or exclude `imports/` from scanning.

- [x] **Step 3: Verify the security gate**

Run `pwsh -NoProfile -File scripts/scan-secrets.ps1`. Expected: exit 0, no gitleaks findings, and only non-blocking keyword hints if any remain.

- [x] **Step 4: Record the evidence**

Capture the scan result in the final handoff and note that the ignored raw-import copies were changed locally and are not commit candidates.

### Task 2: Bound the OpenClaw live-state probe

**Artifacts / Locations:**
- Modify: `scripts/sync-openclaw-plugins.ps1`
- Modify: `tests/openclaw-plugin.tests.ps1`
- Review: `openclaw/plugins/managed-plugins.json`

- [x] **Step 1: Add a failing timeout regression case**

Extend the isolated fake-home test with a fake `openclaw` command that never returns. Assert that plugin dry-run exits within the probe timeout, reports the timeout, and falls back to `installs.json` without mutating it.

- [x] **Step 2: Implement the smallest root-cause fix**

Route only the read-only `plugins list --json` probe through a bounded process invocation. On timeout, terminate the child process tree, emit a redacted diagnostic, and use the existing sanitized `installs.json` fallback. Keep apply lifecycle commands unchanged and still CLI-only.

- [x] **Step 3: Verify plugin behavior**

Run `pwsh -NoProfile -File tests/openclaw-plugin.tests.ps1` and verify the new timeout case plus existing managed/unknown plugin assertions pass.

### Task 3: Reconcile the observed managed skill drift

**Artifacts / Locations:**
- Generate: ignored runtime output under `claude/skills/`, `codex/skills/`, and `openclaw/skills/`
- Generate: an external plan under `$env:TEMP`
- Review: `scripts/sync.ps1` dry-run output and `env/status` evidence

- [x] **Step 1: Rebuild and scan before any live mutation**

Run `scripts/build-skills.ps1`, `scripts/scan-secrets.ps1`, and a normal `scripts/sync.ps1 -DryRun -PlanPath <external-plan>` in that order.

- [x] **Step 2: Review the exact plan**

Require Claude `+0 ~0 -0`, OpenClaw `+0 ~0 -0`, Codex `+0 ~1 -0` for `hatch-pet`, no prune/unknown actions, and preserved `.system`.

- [ ] **Step 3: Apply only the reviewed skill plan**

Do not apply in this repair: `sync.ps1` also invokes OpenClaw plugin sync, while the CLI list probe times out and the config fallback cannot attest installation/source parity. The skill plan is ready, but a separate explicit apply is required after the OpenClaw CLI/live-state blocker is resolved.

- [x] **Step 4: Keep environment switching explicit**

Do not run `env activate` automatically. The three environment stagings and locks were rebuilt and are valid; the remaining `active=full` versus project `RequiredEnv=work` decision is reported with a fresh dry-run recommendation. Switching to `work` is a separate, potentially pruning operation.

### Task 4: Update evidence-backed repository status

**Artifacts / Locations:**
- Modify: `STATUS.md`
- Review: `scripts/check-hooks.ps1`, `scripts/status-harness-env.ps1`, `scripts/status-harness-profile.ps1`, and final Git status

- [x] **Step 1: Update stale machine evidence**

Record the current date, actual installed auto-sync hooks, the successful local validation counts, the resolved scan state, the observed `hatch-pet` dry-run result, and the remaining explicit environment/plugin limitations.

- [x] **Step 2: Verify the repository handoff**

Run the full regression suite, `git diff --check`, `git status --short --branch`, `check-hooks.ps1`, and fresh environment/profile status commands. Do not claim environment activation or plugin parity unless those live operations actually succeed.
