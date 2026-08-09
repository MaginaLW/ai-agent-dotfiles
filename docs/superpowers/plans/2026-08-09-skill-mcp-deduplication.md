# Skill and MCP Deduplication Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** Remove all locally installed ArkCLI skills, then reduce repository-managed skill and MCP duplication without losing distinct capabilities or touching protected/private state.

**Approach:** First use ArkCLI's ownership-aware uninstall path and verify every detected agent root. Then inventory canonical `skills-source/` content, manifests, environment references, task overlays, and MCP templates; classify overlaps by trigger, workflow, implementation, and consumers. Apply only evidence-backed deletions or merges at canonical sources, update dependent references and status, and deploy through the repository's bound dry-run/apply workflow.

**Materials:** `AGENTS.md`, `docs/README.md`, `STATUS.md`, `skills-source/`, `manifests/`, `harness-source/envs/`, `.agent-harness/task-skills.psd1`, `harness-source/components/mcp-templates/`, `scripts/build-skills.ps1`, `scripts/scan-secrets.ps1`, `scripts/sync.ps1`, and local ArkCLI ownership manifests.

**Validation:** ArkCLI prefix directories and ownership manifests are absent from detected roots; canonical skill references are internally consistent; focused and repository regression checks pass; build and secret scan pass; the reviewed sync plan contains only intended managed changes; final live parity passes and Codex `.system` remains present.

---

### Task 1: Uninstall ArkCLI-managed skills

**Artifacts / Locations:**
- Review: detected agent skill roots from `arkcli +connect list`
- Modify: only ArkCLI-owned entries in detected live skill roots
- Preserve: `~/.codex/skills/.system`, unrelated skills, repository files

- [x] **Step 1: Capture the baseline**

Run `arkcli +connect list`, inspect `.arkcli-managed-skills.json` files, and enumerate `ark-*` / `arkcli-*` directories in detected roots.

- [x] **Step 2: Execute the ownership-aware uninstall**

Run `arkcli +connect uninstall` with AI-agent attribution variables scoped to that command. Use `--purge-prefix` only if ownership-aware uninstall leaves ArkCLI-prefixed remnants and evidence confirms they are ArkCLI artifacts covered by the user's explicit request.

- [x] **Step 3: Verify the result**

Re-run the root inventory and confirm no ArkCLI skill directories or ArkCLI ownership manifests remain, while non-ArkCLI counts and Codex `.system` are unchanged.

- [x] **Step 4: Record the result**

Capture removed counts, roots, any protected modified entries, and whether a Codex task restart is needed to refresh the cached catalog.

### Task 2: Audit repository skills and dependency references

**Artifacts / Locations:**
- Review: `skills-source/`, `manifests/`, `harness-source/envs/`, `.agent-harness/task-skills.psd1`, skill cross-references, Git history
- Produce: evidence-backed keep / merge / delete classification

- [x] **Step 1: Build a canonical inventory**

Extract each skill's platform, name, description, files, size, references, manifest membership, environment membership, and cross-skill dependencies.

- [x] **Step 2: Detect real overlap**

Compare exact content hashes, normalized content similarity, trigger overlap, workflow overlap, and platform-specific differences. Distinguish duplicate implementations from complementary routing or review layers.

- [x] **Step 3: Check consumers and history**

Use `rg` and Git history to identify active references, recent intentional additions, and deprecated platform remnants before recommending removal or merge.

- [x] **Step 4: Record the classification**

For every candidate, state the retained target, removed source, capability impact, dependency edits, and confidence. Do not modify candidates whose distinction or consumer set remains ambiguous.

### Task 3: Audit MCP templates and harness leftovers

**Artifacts / Locations:**
- Review: `harness-source/components/mcp-templates/`, `harness-source/envs/`, MCP schemas/tests, retired-platform references
- Produce: evidence-backed keep / merge / delete classification

- [x] **Step 1: Inventory templates and consumers**

Extract template IDs, commands, arguments, required environment variables, profile/environment consumers, tests, and documentation references.

- [x] **Step 2: Identify redundancy and obsolete references**

Flag duplicate servers, unused templates, contradictory templates, and references to retired OpenClaw/OpenCode support; distinguish historical evidence from active configuration.

- [x] **Step 3: Verify safety implications**

Confirm that any candidate removal does not change live MCP registration implicitly and does not expose environment-variable values or machine-private paths.

- [x] **Step 4: Record the classification**

State which templates and harness components should remain, merge, or be removed, with exact consumers and confidence.

### Task 4: Apply the approved canonical cleanup

**Artifacts / Locations:**
- Modify: only canonical sources and their tracked dependent references
- Never modify directly: `claude/skills/`, `codex/skills/`, `reasonix/skills/`, live roots, `.agent-harness/generated/`, Codex `.system`

- [x] **Step 1: Remove or merge high-confidence candidates**

Use `apply_patch` for tracked file edits. Preserve the stronger trigger description and unique workflow/reference content when merging; remove dependent manifest/environment/task references atomically with the source.

- [x] **Step 2: Update durable status**

Update `STATUS.md` with current counts and evidence. Update other documentation only where it describes active behavior and would otherwise become false.

- [x] **Step 3: Review scope**

Inspect `git diff --stat`, `git diff --name-status`, and targeted diffs; confirm unrelated `.reasonix` changes and the pre-existing live-safety design file are untouched.

- [x] **Step 4: Run focused checks**

Run skill inventory/dedupe analysis plus any tests covering changed environment, task overlay, MCP, or sync behavior.

### Task 5: Build, scan, deploy, and attest

**Artifacts / Locations:**
- Generate: ignored platform skill outputs and an external fingerprint-bound sync plan
- Modify live: only through `scripts/sync.ps1 -Apply -PlanPath <reviewed-plan>`

- [x] **Step 1: Rebuild generated outputs**

Run `pwsh -NoProfile -File scripts/build-skills.ps1` and confirm platform counts match canonical sources and intended deletions.

- [x] **Step 2: Run secret and regression checks**

Run `pwsh -NoProfile -File scripts/scan-secrets.ps1`, `git diff --check`, and focused regression suites selected in Task 4. All must exit zero.

- [x] **Step 3: Generate and review the sync plan**

Run `pwsh -NoProfile -File scripts/sync.ps1 -DryRun -PlanPath <external-plan>`; verify every add/update/no-op/prune and confirm `.system` preservation before applying the exact same plan.

- [x] **Step 4: Apply and verify live parity**

Run `pwsh -NoProfile -File scripts/sync.ps1 -Apply -PlanPath <external-plan>`, then a fresh read-only status/parity check. Record backup ID, final counts, remaining unknown directories, and residual recommendations.
