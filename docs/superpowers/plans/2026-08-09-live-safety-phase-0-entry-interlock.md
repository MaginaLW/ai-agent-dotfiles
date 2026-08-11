# Entrypoint Interlock and Preview-Only Automation Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Status:** Prepared from the approved design; implementation has not started. This phase authorizes neither Git staging/commit/publish nor real live Apply/rollback. Keep `ReleaseState=interlocked` throughout.

**Goal:** Stop every production managed-skill Apply path before backup/mutation, make bootstrap and Git hooks non-consumable-preview-only, and install the validation/test foundations required to keep later phase suites visible.

**Approach:** Add a tracked, non-overridable protocol interlock and preserve legacy fake-home coverage through an internal sandbox host rather than public skip/test switches. Replace checkout-executed hooks with an explicitly approved Git-private runner. Move suite discovery and real schema-validation infrastructure forward into this phase so new Phase 1–3 tests cannot be silently omitted; Phase 4 will expand the registry and perform the release switch.

**Materials:** `docs/superpowers/specs/2026-08-09-live-safety-hardening-design.md` §§4.1, 4.6, and Phase 0; current `scripts/auto-sync-after-git.ps1`; current `scripts/bootstrap-clone.ps1`; current `.github/workflows/validate.yml`; [Sourcemeta JSON Schema CLI](https://github.com/sourcemeta/jsonschema) release `v15.6.3` as the compatibility-spike candidate.

**Validation:** In isolated Git repositories, validator/scanner-missing bootstrap emits the appropriate exact stderr token, one stdout installer command, and fixed non-zero exit code; otherwise bootstrap and all post-* hooks write only validated Git-private approvals/events/non-consumable previews and never touch fake live roots. Changed checkout toolchain code is never executed; all production Apply/rollback entrypoints—including explicit retirement—fail before backup; the unified runner discovers all current suites including `config-sync.tests.ps1`; the validator proves Draft 2020-12 behavior rather than merely parsing JSON.

---

### Task 1: Establish the Private-Path, Syntax, and Exactly-Once Runner Foundations

**Artifacts / Locations:**
- Create: `scripts/check-powershell-syntax.ps1`
- Create: `scripts/scan-input-common.ps1`
- Create: `schemas/scan-input-manifest.schema.json`
- Create: `scripts/test-runner-common.ps1`
- Create: `scripts/run-tests.ps1`
- Modify with explicit user approval: `scripts/scan-secrets.ps1`
- Modify with explicit user approval: `.gitleaks.toml`
- Create: `tests/test-timeouts.psd1`
- Create: `tests/test-runner.tests.ps1`
- Create: `tests/private-path-boundary.tests.ps1`
- Create: `tests/scan-input-boundary.tests.ps1`
- Create: `tests/helpers/process-tree.ps1`
- Create: `tests/helpers/failpoint-controller.ps1`
- Create: `tests/fixtures/test-runner/`
- Modify: `.github/workflows/validate.yml`

- [x] **Step 1: Establish the exact Reasonix no-read input boundary**

Before any repository scan, obtain the explicit approval required by `AGENTS.md`. Then stop giving RepoRoot directly to either scanner: build an external filtered ScanInputRoot from tracked+non-ignored policy with a Phase-0 no-follow/identity walker. Exclude the four explicit `.reasonix/desktop-topic-*` paths before content open; reject any reparse entry, hardlink count greater than one, duplicate/protected file identity, non-default NTFS named stream, permission/identity race, or root escape; emit and later register a `scan-input-manifest` v1 binding SourcePolicyHash plus ordered path/length/content hash and traversal evidence, then let fallback/gitleaks consume only the revalidated materialization+manifest. Expose the same Phase-0 regular-tree validation primitive to Tasks 4–6 for approved-runner and committed-data snapshots before any copied code/data is executed or built; no second recursive copier/walker is allowed, and Phase 1 later replaces this shared primitive with SafeTreeWalker. Add access-denied/content-read/access-time sentinels for each protected path, alias/hardlink/junction attempts to them and another outside file, plus an adjacent ordinary `.reasonix` file that must still be scanned and included by clean-candidate gates. Assert no test, archive/copy, status, diff, fallback, gitleaks, bootstrap build or runner-approval process opens the protected files/aliases. This is a privacy input boundary, not a general secret allowlist. If approval is absent, stop Phase 0 before running scan.

- [x] **Step 2: Write failing runner tests**

Create fixture suites for pass, non-zero failure, duplicate SuiteId, missing completion, timeout parent, timeout child, and grandchild heartbeat. Assert stable ordinal discovery, one fresh `pwsh` process per suite, a normalized relative-path SuiteId, complete duration/exit/state fields, and process-tree termination after timeout. Put the reusable PID/tree-kill and named pipe/event failpoint helpers in the two new helper files so Phases 1–2 do not reference nonexistent utilities.

`tests/test-runner.tests.ps1` must exercise `scripts/test-runner-common.ps1` against `tests/fixtures/test-runner/` directly; it must not invoke `run-tests.ps1 -All`, because the full runner discovers `test-runner.tests.ps1` and that would recurse.

Expected: tests fail because the runner and summary do not yet exist.

- [x] **Step 3: Implement the syntax checker**

Use `git ls-files -co --exclude-standard` plus explicit repository allow/exclude roots to parse every current-worktree `*.ps1`, `*.psm1`, and `*.psd1`, including files newly created in this uncommitted phase. Exclude generated/backup/import/private paths and the four protected Reasonix paths without opening them. Report every parser error and exit non-zero if any exist.

- [x] **Step 4: Implement the runner and complete v1 summary**

`scripts/run-tests.ps1 -All -JsonSummaryPath <external>` must discover `tests/*.tests.ps1` directly; fixture-root execution exists only as an internal function in `test-runner-common.ps1` used by the runner regression suite. `tests/test-timeouts.psd1` may change timeouts only and must never list included suites. Write a create-new v1 summary containing discovery hash, unique SuiteIds, per-suite state, configured timeout/budget, explicit `SetupAndNonSuiteBudgetSeconds`/`MarginSeconds`/`RequiredJobTimeoutSeconds`, and discovered/started/completed/passed/failed/timed-out/duplicate/missing/tree-kill-failed counts. Later phases may add suites but must not silently change this summary shape.

- [x] **Step 5: Switch CI suite execution**

Replace the eight hand-maintained suite steps with one runner-driven CI job. Keep build, scan, doctor, generated parity, dangerous-file, schema, and syntax gates as separate workflow steps. Compute and record `RequiredJobTimeoutSeconds = SetupAndNonSuiteBudgetSeconds + sum(Suite.TimeoutSeconds) + MarginSeconds`; the workflow `timeout-minutes` converted to seconds must be strictly greater. If the proven bound cannot fit the platform maximum, stop and amend the design—this roadmap does not introduce shards or aggregate artifacts.

- [x] **Step 6: Verify exact discovery**

Run `pwsh -NoProfile -File tests/test-runner.tests.ps1`, then run the real runner to a new temp summary.

Expected: the baseline nine root suites plus every root suite created so far—including `config-sync.tests.ps1`, `private-path-boundary.tests.ps1`, and `test-runner.tests.ps1`—match a freshly enumerated dynamic discovery snapshot exactly once; never assert a stale hard-coded total. A timeout fixture leaves neither child nor grandchild alive and `tree-kill-failed=0`.

### Task 2: Establish Real Draft 2020-12 Validation

**Artifacts / Locations:**
- Create: `tools/schema-validator/validator.lock.json`
- Create: `tools/gitleaks/gitleaks.lock.json`
- Create: `scripts/install-schema-validator.ps1`
- Create: `scripts/install-gitleaks.ps1`
- Create: `scripts/json-artifact-common.ps1`
- Create: `scripts/semantic-json.ps1`
- Create: `scripts/validate-json-artifacts.ps1`
- Create: `schemas/artifact-contracts.psd1`
- Create: `schemas/artifact-validation-manifest.schema.json`
- Create: `schemas/artifact-validation-summary.schema.json`
- Create: `schemas/test-run-summary.schema.json`
- Create: `tests/schema-validation.tests.ps1`
- Create: `tests/json-canonicalization.tests.ps1`
- Create: `tests/fixtures/json-canonicalization/`
- Create: `tests/fixtures/artifacts/`
- Modify: `tests/private-path-boundary.tests.ps1`
- Modify: `scripts/run-tests.ps1`
- Modify: `scripts/test-runner-common.ps1`
- Modify: `tests/test-runner.tests.ps1`
- Modify: `.github/workflows/validate.yml`

- [x] **Step 1: Run the validator compatibility spike**

In an external temporary directory, obtain the official schema-validator `v15.6.3` Windows asset and published checksum, verify its SHA-256, then test `type`, `const`, `unevaluatedProperties`, `$defs/$ref`, `format`, duplicate-sensitive array fixtures, and a Draft 2020-12 metaschema sentinel. Before invoking it, require the exact Draft 2020-12 `$schema`, allow only a basename-matching `https://ai-agent-dotfiles.invalid/schemas/<name>` non-fetching `$id`, allow `$ref` only as same-document `#...` fragments, and reject cross-file/HTTP(S)/`file:`/other URI/absolute drive/UNC/`..` refs plus every `$dynamicRef`/`$dynamicAnchor`, reparse/hardlink/identity race, and reference text naming each access-denied protected Reasonix path or another external sentinel. The schema itself must be a canonical regular file under approved SchemaRoot. In the same isolated spike select one official gitleaks asset, verify publisher checksum/hash/version/license behavior, and prove the wrapper ignores a malicious PATH-shadow binary.

Expected: all required positive/negative sentinels produce deterministic exit codes. If any required feature fails, stop this plan and amend the validator decision; never fall back to `ConvertFrom-Json` field checks.

- [x] **Step 2: Pin installation metadata**

Record exact version, asset name, release URL, expected version output, published license identifier/source notice, and verified asset SHA-256 in each validator/gitleaks lock. Use both only as external CLI processes; do not link/copy source into repository code. Explicit installers write binaries only to Git-private/current-user approved caches, verify lock hash/version before rename, and never install during validation. Scanner invocation uses only the pinned absolute gitleaks path; `Get-Command`/PATH fallback is forbidden.

- [x] **Step 3: Freeze semantic JSON and document hashes**

Implement the repository's single RFC 8785-compatible subset before any Phase 0 plan emitter: duplicate-key-detecting parse; objects/arrays/strings/booleans/schema-permitted null; integers only in the I-JSON safe range; ordinal UTF-16 property ordering; UTF-8 without BOM and minimal JSON escaping; reject floats, exponents, non-finite and out-of-range values. Provide `Get-SemanticJsonHash`, `Get-PlanHash` over complete PlanPayload, and `Get-DocumentHash` over the complete document excluding only DocumentHash itself. Run property-order, Unicode/escaping, nested/empty/MISSING/null, integer-boundary, duplicate-key and two-fresh-process vectors. This v1 helper is final Phase 0 infrastructure; Phase 1 may verify/consume but must not introduce a second serializer or change its hash semantics.

- [x] **Step 4: Implement the registry and adapter**

First implement a non-emitting `Invoke-FixedJsonSchemaValidation -SchemaPath -InstancePath` primitive that invokes only the already pinned binary and never creates a manifest/summary. It validates the complete no-follow SchemaRoot file and the fixed `$schema`/`$id`/fragment-only `$ref` policy before process launch; dynamic/cross-document reference keywords are rejected and no disallowed target is opened. Use it to bootstrap-validate the artifact manifest and both summary types. The same common file exposes the design's role-bound `Resolve-PrivateArtifactPath`: `ExternalUserArtifact` rejects every worktree/Git/control/backup/recovery/live/source namespace; exact `InternalContractPath` locators separately allow absolute GitCommonDir literal contracts, per-worktree `git --git-path` contracts, fixed ControlBase contracts, and transaction-owned BackupReceipt slots; `EvidenceInputPath` validates each operation's explicit read-only allowlist before first open and rejects reparse, hardlink, ADS, protected/outside alias, and identity race. Public parameters cannot select an internal role. `schemas/artifact-contracts.psd1` then maps an ArtifactKind—including scan-input-manifest v1—to one schema, accepted SchemaVersion, positive fixture, named negative fixtures, and optional named semantic validators for composite-key uniqueness/order/hash/reference DAG rules. Every negative fixture declares `FailureLayer=Schema|Semantic`. `validate-json-artifacts.ps1 -All` validates the registry/fixtures; `-ArtifactManifestPath` fixed-validates the external manifest and every content hash, then runs registered schema and semantic checks. Missing binary, hash mismatch, any disallowed reference keyword/value, unknown ArtifactKind, unsupported version, or disallowed artifact path fails closed.

- [x] **Step 5: Self-validate summaries**

Write each summary create-new, then call the fixed-schema primitive directly against `artifact-validation-summary.schema.json` or `test-run-summary.schema.json`. Never validate a manifest/summary by generating another manifest/summary.

- [x] **Step 6: Wire the CI validator**

Install the pinned schema validator and gitleaks in explicit CI setup steps, verify both cache hashes/versions in separate checks, then run validation/scan without network access, PATH discovery, or dynamic restore. Local fresh-checkout checkpoints run the same explicit installers and `-VerifyOnly` commands before any validator/scan call. Remove parse-only schema loops and hand-written artifact field checks only after their equivalent contracts are registered.

- [x] **Step 7: Verify positive and negative behavior**

Run `tests/schema-validation.tests.ps1`, `tests/scan-input-boundary.tests.ps1`, and the private-artifact-path cases in `tests/private-path-boundary.tests.ps1`. Table-drive worktree root/descendant, arbitrary `.git`/index path, volume/HomeRoot root, valid explicit external root, absolute GitCommonDir literal contracts shared by two linked worktrees, per-worktree `git --git-path` contracts that remain distinct, fixed ControlBase/BackupReceipt internal slots, and operation-specific evidence inputs. For every role test reparse, hardlink, ADS, protected/outside alias and final-identity race before any temp/final artifact or content read; shadow PATH gitleaks and every escaped `$ref`/scan alias must likewise fail before outside/protected content opens.

Expected: every positive fixture passes; missing Reasonix, unknown properties, wrong schema version, duplicate/unsorted fixed-platform/action keys, tampered hash/reference graph, wrong `$schema`/`$id`, cross-file/URI/absolute/UNC/escape `$ref`, and dynamic-reference fixtures fail at their declared schema or semantic layer, while access sentinels prove rejected schema/scan targets were never opened.

### Task 3: Build an Internal Sandbox Host and Production Interlock

**Artifacts / Locations:**
- Create: `scripts/live-safety-policy.psd1`
- Create: `scripts/live-safety-interlock.ps1`
- Create: `scripts/internal/live-transaction-host.ps1`
- Create: `tests/helpers/test-common.ps1`
- Create: `tests/helpers/safety-sandbox.ps1`
- Create: `tests/automation-safety.tests.ps1`
- Modify: `scripts/sync.ps1`
- Modify: `scripts/backup.ps1`
- Modify: `scripts/activate-harness-env.ps1`
- Modify: `scripts/task-skills.ps1`
- Modify: `scripts/rollback-harness-env.ps1`
- Modify: `tests/sync.tests.ps1`
- Modify: `tests/harness-env.tests.ps1`
- Modify: `tests/task-skills.tests.ps1`

- [x] **Step 1: Write failing interlock tests**

For normal sync, retirement sync, env activate, task ensure/sync/close, and env rollback, place sentinels in fake live/backup/state roots and invoke each production entry with `-Apply` plus any currently exposed skip switches. Invoke standalone `backup.ps1` through every public snapshot-creating form as a separate production entry; protect Codex `.system` child content with an access sentinel, not a content assertion.

Expected: tests initially show that Apply or standalone backup can reach traversal/backup/mutation; the desired assertion is non-zero `safety-protocol-upgrade-required` with byte-identical sentinels, zero protected-content opens, and zero new backup/journal/state paths.

- [x] **Step 2: Define the tracked interlock policy**

Set `ProtocolVersion = 3` and `ReleaseState = 'interlocked'`. No CLI argument, environment variable, `-Force`, `-SkipBuild`, `-SkipSecretScan`, arbitrary `HomeRoot`, or retirement manifest may change this decision.

- [x] **Step 3: Extract the internal transaction host**

Move the current fake-home mutation engine behind `scripts/internal/live-transaction-host.ps1` without changing its retirement semantics. Production wrappers may call it only after the policy is released. The test helper creates a fresh temp sandbox, holds an exclusive capability handle, and calls the host in-process; the host rejects any source/live/backup/state/control path outside that sandbox.

- [x] **Step 4: Guard every public Apply before side effects**

Call the interlock immediately after parameter/operation parsing and before build, scan, plan creation, live-tree traversal, backup, directory creation, journal creation, or state writes. Standalone `backup.ps1` must fail here for every invocation that would create a snapshot; it may not retain the legacy full-tree copy as a usable Phase 0 public path. DryRun/status remain available, while Phase 2 owns the future managed-only backup preview/receipt implementation.

- [x] **Step 5: Preserve isolated behavior coverage**

Route existing fake-home mutation assertions through the internal host. Do not add a public `-TestMode`, hidden Apply token, or real-home-capable test parameter.

- [x] **Step 6: Verify the interlock**

Run `tests/automation-safety.tests.ps1`, `tests/sync.tests.ps1`, `tests/harness-env.tests.ps1`, and `tests/task-skills.tests.ps1`.

Expected: production Apply is blocked; isolated engine regressions still exercise current sync/retirement behavior.

### Task 4: Define Git-Private Approval and Non-Consumable Pending-Event Storage

**Artifacts / Locations:**
- Create: `scripts/runner-policy.psd1`
- Create: `scripts/approved-runner-common.ps1`
- Create: `schemas/pending-sync-event.schema.json`
- Create: `schemas/runner-approval-event.schema.json`
- Create: `schemas/approved-runner-state.schema.json`
- Create: `schemas/committed-data-snapshot-manifest.schema.json`
- Create: `schemas/pending-prune-plan.schema.json`
- Create: `tests/approved-runner.tests.ps1`
- Modify: `schemas/artifact-contracts.psd1`

- [x] **Step 1: Write failing storage/identity tests**

Cover normal clones and linked worktrees; create two events in the same millisecond; simulate an existing target name; deny a broad ACL; verify per-worktree event/plan storage under `git rev-parse --git-path ai-agent-dotfiles`, and verify the shared pending lock resolves identically from the absolute GitCommonDir in both worktrees.

- [x] **Step 2: Define the runner policy**

List exact data pathspecs (`skills-source`, `manifests`, `harness-source`, `.agent-harness/task-skills.psd1`) and exact approved toolchain/policy files. This is an allowlist for both working-tree inspection and commit-object snapshot/archive; a whole-tree archive/copy is forbidden, and the four protected `.reasonix` paths are never passed to Git blob/archive APIs. Before any content open/copy, require every selected commit entry to be a regular blob mode (reject symlink/gitlink) and every worktree source/ancestor to pass lstat/no-follow identity, mode/OID, reparse, multi-link, duplicate-identity and ADS checks. Copy only into a create-new controlled tree, rewalk/re-hash it, then permit execution/build. `.gitleaks.toml`, `scripts/scan-secrets.ps1`, scan-input policy, validator/gitleaks locks+installers+approved binary hashes, runner/setup/sync, and their loaded dependencies are always toolchain policy, never data-only. Hash normalized relative path, file length, and SHA-256 for every toolchain file plus the approved commit and stable repo/worktree identities.

- [x] **Step 3: Implement immutable storage helpers**

Use create-new `<utc-ms>-<guid>` names for approval events, non-consumable pending previews, and diagnostics. Store full machine paths only in Git-private artifacts. Write immutable stale/superseded sidecar events rather than editing or deleting the original preview. Serialize every pending-namespace create/sidecar/move under one OS-exclusive regular-file handle at absolute resolved `git rev-parse --git-common-dir` plus literal `ai-agent-dotfiles/pending.lock`, shared by all linked worktrees; events/previews remain in their distinct per-worktree `git --git-path` namespaces. Validate both locator classes/no-follow identities and never acquire canonical/global live locks while holding the pending lock.

- [x] **Step 4: Register and validate pending events**

Register separate v1 contracts for pending/diagnostic events, runner approval events, atomic approved-runner state, and committed-data-snapshot manifests. Pending events require event kind, worktree namespace, trigger, approved/current toolchain hashes, commit, redacted context, plan/diagnostic status, and content hashes. Approval/state bind commit, ToolchainPolicyHash, copied runner tree hash, cache/tool identities, Git-private namespace and pointer generation. Snapshot manifests bind exact allowlisted pathspecs, source commit, Git modes/OIDs, ordered materialized paths/content hashes and no-follow traversal evidence. Reject unknown fields/versions, symlink/gitlink/reparse/hardlink/ADS entries, pointer/event mismatch, and any unregistered metadata file.

- [x] **Step 5: Define reviewed pending-preview retirement**

`plans prune -DryRun -PlanPath <new-external>` uses the Phase 0 semantic-json helper to write a create-new v1 plan only as `ExternalUserArtifact`, binding exact pending/sidecar paths, content hashes, stale references, registry snapshot and selection timestamp. Matching `-Apply -PlanPath <same-external>` acquires only `pending.lock`, revalidates the saved document and each item, then atomically moves only that set into a Git-private retired namespace while retaining redacted audit sidecars; it never accepts an internal preview path, re-enumerates age/hash candidates, hard-deletes an artifact, expands selection, or touches canonical/live state. Hook event creation/sidecar publication uses the same lock, so prune cannot race a producer. Register positive/tamper/drift/new-candidate/concurrent-hook/role-confusion PlanPath negatives before routing the command.

- [x] **Step 6: Verify storage**

Run `tests/approved-runner.tests.ps1` and validate pending event, approval event, approved state, data-snapshot manifest, and prune-plan artifacts through its manifest.

Expected: collisions fail, linked worktrees do not share pending namespaces, and approval/pending files never enter the tracked working tree.

### Task 5: Install a Pinned Runner Instead of Executing Checkout Scripts

**Artifacts / Locations:**
- Modify: `scripts/setup.ps1`
- Modify: `scripts/apply-hooks.ps1`
- Modify: `scripts/check-hooks.ps1`
- Modify: `scripts/auto-sync-after-git.ps1`
- Modify: `tests/automation-safety.tests.ps1`

- [x] **Step 1: Write failing hook trust tests**

Install hooks in a temporary Git repo, alter `scripts/auto-sync-after-git.ps1`, `scripts/sync.ps1`, `.gitleaks.toml`, and one other policy dependency in the checkout, then trigger post-checkout/post-merge/post-rewrite.

Expected: current hooks execute checkout scripts, demonstrating the failure before implementation.

- [x] **Step 2: Record explicit runner approval**

Freeze the runner-only parameter set as `pwsh -NoProfile -File scripts/setup.ps1 -ApproveRunner [-InstallPreCommit] [-InstallAutoSync]`; it rejects canonical `-DryRun/-Apply/-PlanPath`, and the separate `agent-dotfiles.ps1 canonical setup` route rejects runner/hook switches. This explicit approval invocation—not bare bootstrap—first requires every policy-listed toolchain/data path to match the current commit and pass Task 4's regular-blob/no-follow materialization gate before content copy; relevant dirty/untracked paths, Git symlink/gitlink, worktree reparse/hardlink/ADS/identity drift or protected/outside alias produces `working-tree-review-required` and cannot be approved or planned. On a clean safe snapshot, create a validated approval event, copy only the policy-listed toolchain into a create-new versioned Git-private runner directory, rewalk/verify copied hashes, then atomically update a validated approved-runner state file.

- [x] **Step 3: Install inert wrappers**

Hook files resolve the Git-private approved pointer and invoke only its runner. If metadata/runner is absent or invalid, write `runner-review-required` using a minimal inert writer and exit non-zero without loading checkout PowerShell.

- [x] **Step 4: Fail closed on toolchain drift**

The pinned runner compares checkout toolchain/policy hashes to the approved set. Any difference—including `.gitleaks.toml`—produces only `runner-review-required`; only data-path changes may use the pinned toolchain to generate a non-consumable pending preview/diagnostic and an external DryRun command.

- [x] **Step 5: Verify all triggers**

Run the hook trust cases for merge, branch checkout, rebase/rewrite, linked worktree, missing/tampered schema-validator cache, missing/tampered pinned gitleaks cache, PATH-shadow gitleaks, missing runner, changed runner, and source-only changes.

Expected: no checkout script marker executes; validator drift emits only `validator-install-required`, scanner drift/PATH shadow emits only `scanner-install-required`, runner drift emits only `runner-review-required`, and every unsafe case produces zero scan/plan/artifact/live writes beyond its allowed diagnostic text/event.

### Task 6: Make Hook/Bootstrap Output Preview-Only and Require External Actionable Plans

**Artifacts / Locations:**
- Modify: `bootstrap.ps1`
- Modify: `scripts/bootstrap-clone.ps1`
- Modify: `scripts/auto-sync-after-git.ps1`
- Modify: `scripts/agent-dotfiles.ps1`
- Modify: `tests/automation-safety.tests.ps1`

- [x] **Step 1: Define transitional routing**

First reject relevant dirty/untracked toolchain or data paths with `working-tree-review-required`; never silently plan HEAD while showing working-tree data. For a clean checkout, snapshot only Task 4's explicit data allowlist from the exact trigger commit—one allowlisted pathspec set, never a whole-tree `git archive`. Before any isolated build, reject non-regular Git modes and validate the entire extracted snapshot through the Phase-0 no-follow identity/reparse/hardlink/ADS/escape walker; build consumes only that validated tree. Emit the registered committed-data-snapshot manifest and assert it contains only approved paths. Add the full archive→extract→validate→build path to protected/outside alias access sentinels, not only the scanner helper. Phase 0's sealed fixture may run this isolated build/scan to prove snapshot safety, but the production bootstrap/hook emits only `safety-protocol-upgrade-required` after approval and does **not** claim an initial/live plan. Once Phase 2 canonical setup exists and is ready, the composed pinned runner may reuse this exact snapshot path for route-correct DryRun; non-empty roots, legacy/corrupt state and schema 3 authority then route through the later authority contract rather than falling back to full planning.

- [x] **Step 2: Remove all hook Apply calls**

Delete calls to `sync.ps1 -Apply` and `task-skills.ps1 ... -Apply -Automatic`. Mark prune/removal/controller transitions `manual-review-required`, retain pending previews, and deduplicate by context/preview hash; never print an internal preview path as public Apply PlanPath.

- [x] **Step 3: Reverse bootstrap defaults with explicit dependency/code approval**

First bare bootstrap installs/checks only inert wrappers. Check schema-validator then gitleaks caches in fixed order: a missing dependency writes exactly one stderr line `validator-install-required` or `scanner-install-required`, one stdout line containing its absolute explicit install command, exits with the fixed non-zero code, and creates no JSON/pending artifact that would falsely claim validation. After both verifications, an unapproved runner may produce a validator-backed `runner-review-required` event and exactly the `scripts/setup.ps1 -ApproveRunner ...` stdout command. Only after the user runs both pinned installers and that runner-only approval does a later bare bootstrap run read-only diagnostics and isolated planning. While Phase 0 ships alone it emits only `safety-protocol-upgrade-required`, because canonical status/setup do not exist yet. Once Phase 2 enables the Phase 1 canonical control branch, the same pinned bootstrap calls the shared `agent-dotfiles.ps1 canonical status` helper: absent setup emits only `canonical-setup-required` plus the external canonical-setup DryRun command, never an initial/live plan; after separately reviewed canonical setup succeeds, a later invocation may generate only the route-correct non-consumable preview/event and print the exact external DryRun command. The actionable plan and any future Apply command exist only after the user explicitly runs that DryRun into an `ExternalUserArtifact` path. Add `-SkipInitialPlan`; retain `-SkipInitialSync` only as a warning alias. Do not add an Apply switch.

- [x] **Step 4: Add pending-preview inspection/pruning routes**

Add `plans list` and route only the Task 4 contract: `plans prune -DryRun -PlanPath <new>` followed by the same `-Apply -PlanPath <existing>`. Apply consumes the exact reviewed hash-bound set and moves it to retired storage; no implicit plan, current-time re-enumeration, selection expansion, or hard delete.

- [x] **Step 5: Verify preview/event-only behavior**

Run first/second bootstrap and each hook in isolated repos with missing validator, missing/tampered scanner cache, PATH-shadow scanner, missing approval, clean add/update/prune/task-overlay commits, then repeat with relevant tracked and untracked working-tree changes. Separately exercise the snapshot→validate→isolated-build helper through the sealed capability; do not expect a production Phase 0 pending initial plan.

Expected: validator/scanner-missing bootstrap emits its exact stderr token/stdout command/fixed exit tuple and no artifact; only after both installs may runner-missing emit a schema-valid approval event plus stdout command. A later bootstrap after explicit approve produces only `safety-protocol-upgrade-required` in the standalone Phase 0 checkpoint—zero pending initial/live plan. The sealed snapshot manifest contains only policy-allowlisted data and the privacy sentinel proves no protected Reasonix blob/path was opened or copied. The later Phase 2/P4 composed-flow tests own `canonical-setup-required` plus post-setup non-consumable route-preview/exact external-DryRun-command positives; only a separate explicit external DryRun may create an actionable plan. Dirty relevant data produces only `working-tree-review-required`; every trigger performs zero live/backup/state writes.

### Task 7: Synchronize the Immediate Entrypoint Contract

**Artifacts / Locations:**
- Modify: `AGENTS.md`
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `docs/README.md`
- Modify: `docs/ONBOARD_NEW_MACHINE.md`
- Modify: `docs/RESTORE.md`
- Modify: `docs/MERGE_POLICY.md`
- Modify: `STATUS.md`
- Modify: `scripts/doctor.ps1`
- Modify: `tests/doctor.tests.ps1`

- [x] **Step 1: Update current commands**

Replace every statement that bare bootstrap or Git hooks Apply live changes. Document the ordered validator install, pinned gitleaks scanner install, runner approval, and later bootstrap flow separately from plan review and Apply authorization. Include Claude/Codex/Reasonix and state that retirement is never hook-driven. Add a temporary `safety-protocol-upgrade-required` banner to RESTORE/MERGE_POLICY/current STATUS so Phase 0 can ship without any guide still advertising legacy rollback/retirement Apply; Phase 4 replaces the banners with the final contract.

- [x] **Step 2: Update diagnostics**

Doctor/check-hooks report approved runner hash, checkout hash, pending directory, release state, and `runner-review-required`/`safety-protocol-upgrade-required` without modifying hooks or authority. Replace the current Codex `.system` child-marker lookup with a no-follow marker of the `.system` root entry only; never enumerate/open `.codex-system-skills.marker` or any other child. Add normal-directory, missing-entry, reparse-entry, access-denied child and access-time/content-read sentinels proving doctor performs zero `.system` content traversal.

- [x] **Step 3: Add docs contract assertions**

Assert no current guide recommends automatic Apply, no current guide omits Reasonix from managed live scope, and the deprecated switch is described only as an alias.

- [x] **Step 4: Verify docs and doctor**

Run `tests/doctor.tests.ps1`, `tests/automation-safety.tests.ps1`, and `rg` checks for `auto.*Apply`, `initial live sync`, and bare unsafe bootstrap descriptions outside archive/history.

### Task 8: Run the Phase 0 Checkpoint

**Artifacts / Locations:**
- Update evidence in: this plan's completed checkboxes
- Do not update live evidence in: `STATUS.md`

- [x] **Step 1: Run focused verification**

Run:

```powershell
$verify = Join-Path $env:TEMP ("ai-agent-dotfiles-phase0-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $verify | Out-Null
pwsh -NoProfile -File scripts/install-schema-validator.ps1 -Install
pwsh -NoProfile -File scripts/install-schema-validator.ps1 -VerifyOnly
pwsh -NoProfile -File scripts/install-gitleaks.ps1 -Install
pwsh -NoProfile -File scripts/install-gitleaks.ps1 -VerifyOnly
pwsh -NoProfile -File scripts/check-powershell-syntax.ps1
pwsh -NoProfile -File tests/private-path-boundary.tests.ps1
pwsh -NoProfile -File tests/scan-input-boundary.tests.ps1
pwsh -NoProfile -File tests/test-runner.tests.ps1
pwsh -NoProfile -File tests/schema-validation.tests.ps1
pwsh -NoProfile -File tests/approved-runner.tests.ps1
pwsh -NoProfile -File tests/automation-safety.tests.ps1
pwsh -NoProfile -File scripts/run-tests.ps1 -All -JsonSummaryPath (Join-Path $verify 'test-summary.json')
pwsh -NoProfile -File scripts/validate-json-artifacts.ps1 -All -JsonSummaryPath (Join-Path $verify 'artifact-summary.json')
```

Expected: both pinned binaries pass cache hash/version verification; zero failures/timeouts/missing/duplicates; `config-sync` runs once; every production Apply and standalone backup test exits before any side effect, and doctor never opens Codex `.system` content.

- [x] **Step 2: Run repository gates**

Run build, secret scan, doctor, generated parity, and dangerous-file policy through the same commands CI uses. Run unstaged and staged `git diff --check` with `.` plus exactly four literal negative pathspecs for the protected Reasonix leaves—never broad `.reasonix/**`; add a fifth adjacent-file fixture and prove it remains visible/scanned. Before Phase 4 index removal, inspect the four protected files only with exact `git ls-files --stage`/`Test-Path` metadata commands. Do not run unrestricted diff/status/content operations on those four leaves, `sync.ps1 -Apply`, env/task Apply, rollback, or retirement Apply.

- [x] **Step 3: Perform two reviews**

Requirements review: compare all behavior to design Phase 0. Quality review: inspect pinned-runner bundle minimality, ACL/create-new semantics, summary hashes, failure exits, and sandbox escape tests.

- [x] **Step 4: Record the phase result**

Mark Phase 0 complete only if the tracked policy remains `interlocked` and no real live/backup/shared-authority path changed.
