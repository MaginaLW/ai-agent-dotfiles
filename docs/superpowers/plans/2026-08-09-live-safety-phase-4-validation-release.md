# Schema, CI, Documentation, and Safe Release Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Status:** Prepared from the approved design; implementation has not started. This phase grants no Git staging/commit/publish or real live Apply/rollback authorization. `ReleaseState=released` below means only the tested code-protocol switch; it does not publish the repository or authorize mutation.

**Goal:** Close every artifact/schema/test/document contract, stop tracking machine-private Reasonix desktop state without deleting it, and release the new protocol only after complete isolated verification.

**Approach:** Expand the Phase 0 validator registry and unified runner to every artifact/suite introduced in Phases 1–3, then align CI and all current operating guides. Add static policy tests so Reasonix/platform/preview-only/external-plan rules cannot drift again. Perform the protocol release switch as the last code change; afterward collect only read-only and dry-run real-machine evidence and stop for separate Apply authorization.

**Materials:** Approved design §§4.6, 6.5, 7, and 11; Phase 0 validator/test runner; artifacts from Phases 1–3; current `AGENTS.md`, `CLAUDE.md`, README/onboarding/restore/status; four tracked `.reasonix/desktop-topic-*` paths identified only through Git metadata.

**Validation:** Every registered positive artifact passes Draft 2020-12 validation, every negative fixture fails, every test suite executes exactly once, non-suite gates remain in CI, documentation matches the released CLI, the four Reasonix files remain local but leave the Git index, and no real Apply/rollback occurs.

---

### Task 1: Complete the Artifact Contract Registry

**Artifacts / Locations:**
- Modify: `schemas/artifact-contracts.psd1`
- Create: `schemas/repository-validation-summary.schema.json`
- Review (already owned by producer phases): `schemas/sync-plan.schema.json`
- Review (already owned by producer phases): env build/lock/list/status schemas
- Review only: every new Phase 1–3 schema; any mismatch returns to its producer phase for schema/producer/fixture correction or an explicit version bump
- Create/modify: `tests/fixtures/artifacts/`
- Modify: `tests/schema-validation.tests.ps1`

- [ ] **Step 1: Freeze accepted contract versions**

Register exactly: runner-approval-event v1, approved-runner-state v1, committed-data-snapshot-manifest v1, canonical-setup-state v1, global canonical-root-claim v1; canonical transaction/recovery plan/result v1 plus canonical journal header/record v1; sync plan v3 including every Phase 3 OperationKind; backup receipt v1; official rollback/recovery plan v1; live journal header/record v1; live-operation-result v1; home root claims v1; shared authority state v3; pending event v1; pending-prune-plan v1; scan-input-manifest v1; env build v3; env lock v3; env list/status v2; existing doctor/secret/run reports at their validated current versions; test summary v1; artifact manifest/summary v1; and repository-validation-summary v1 with fixed `ReportKind=repository-validation`. Artifact-validation-manifest v1 has strict `ManifestRole=children|final`: children lists only child outputs; final lists that child manifest, all children, and repository summary; neither lists itself and summary may reference only the child manifest. Require each transaction manifest to enumerate header, every published record including the sole terminal `Phase=COMPLETE`/Outcome record, and its zero-or-one fixed result; pass the named chain/derived-head/result-cardinality validator; reject every other version, mutable head/marker artifact, journal-directory inference, or manifest DAG cycle. The backup receipt's separately scoped COMPLETE marker remains its documented non-JSON finalization sentinel.

- [ ] **Step 2: Align env producers and schemas**

Verify Phase 2 emitted env-build v3 and initial named-`full` consumption with complete three-platform materialization/root evidence and MaterializationHash; verify Phase 3 only consumed that frozen shape, kept env-lock v3 frozen, declared `ReasonixSkillCount` in list v2, and replaced clone-local backup/state fields in status v2. If any producer/schema mismatch remains, return the fix and focused tests to the owning phase before continuing; do not first define or reinterpret a producer's shape here.

- [ ] **Step 3: Add one positive fixture per ArtifactKind**

Each fixture must be emitter-derived or built through the same production serializer, have no machine-private path in tracked bytes, and include the expected content hash in a tracked fixture manifest.

- [ ] **Step 4: Add required negative sentinels**

For each relevant contract include wrong/missing SchemaVersion, unknown property, missing Reasonix, duplicate platform/action name, bad fixed order, malformed hash, forbidden null/MISSING substitution, and remote `$ref`. Plan/receipt/journal/state contracts also need reference-graph and operation-kind mismatch cases. Manifest fixtures cover wrong role, child→summary→final omission, summary→final back-reference, self-reference and content-hash cycle. Every fixture declares whether the schema layer or a named semantic validator must reject it.

- [ ] **Step 5: Verify registry completeness**

Have the test compare registered ArtifactKinds to a committed producer list and fail for an unregistered producer or orphaned schema/fixture.

Expected: every producer in the approved design table has one accepted version/schema/positive fixture; all negatives fail at the intended schema keyword or named semantic validator.

### Task 2: Make Every Emitter Self-Validate

**Artifacts / Locations:**
- Modify: `scripts/json-artifact-common.ps1`
- Modify: canonical/live/backup/recovery/authority/hook/env/doctor/scan/report emitters
- Modify: `scripts/validate-json-artifacts.ps1`
- Modify: `tests/schema-validation.tests.ps1`

- [ ] **Step 1: Add fail-closed emitter tests**

Inject missing validator binary, wrong pinned hash, invalid schema, invalid emitted JSON, manifest content-hash mismatch, and summary self-validation failure.

- [ ] **Step 2: Emit through one adapter**

Each producer writes to a create-new temp artifact, closes/flushes it, creates an external artifact manifest with exact ArtifactKind/schema/content hash, invokes the offline validator, then atomically publishes the final artifact only on PASS.

- [ ] **Step 3: Avoid filename inference and recursion**

The adapter accepts only a registered ArtifactKind; it never guesses schema from filename. Manifest and summary self-checks reuse Phase 0's non-emitting fixed-schema primitive, so neither operation recursively generates another manifest/summary.

- [ ] **Step 4: Verify missing dependency behavior**

Run emitters with the validator cache temporarily unavailable in an isolated environment.

Expected: status that does not emit JSON may remain readable; any command claiming a machine-readable success artifact fails closed and leaves no published invalid artifact.

### Task 3: Finalize the Unified Runner and CI Workflow

**Artifacts / Locations:**
- Modify: `scripts/run-tests.ps1`
- Modify: `scripts/test-runner-common.ps1`
- Modify: `tests/test-timeouts.psd1`
- Modify: `tests/test-runner.tests.ps1`
- Review/reuse without shape changes: `schemas/test-run-summary.schema.json`
- Create: `scripts/run-repository-validation.ps1`
- Create: `tests/repository-validation.tests.ps1`
- Modify: `.github/workflows/validate.yml`

- [ ] **Step 1: Re-run runner adversarial tests**

Cover every new Phase 1–3 suite, duplicate/missing SuiteId, summary path collision, suite-created child/grandchild, timeout, crash, and discovery changing after snapshot.

- [ ] **Step 2: Enforce exactly-once invariants in code and schema**

Keep the Phase 0 v1 summary shape. `Result=PASS` requires discovered=started=completed=passed, all greater than zero, and failed/timed-out/duplicate/missing/tree-kill-failed equal zero. Reject a test file added after discovery rather than silently omitting it.

- [ ] **Step 3: Keep timeout policy separate from discovery**

Allow committed default/per-suite durations only. Unknown timeout override is an error; absence of an override uses default. Kill the entire process tree and prove child/grandchild heartbeat stops.

- [ ] **Step 4: Prove the single-job outer budget and exactly-once execution**

For the one unified-runner CI job, compute `RequiredJobTimeoutSeconds = SetupAndNonSuiteBudgetSeconds + sum(Suite.TimeoutSeconds) + MarginSeconds` and record the components in the v1 summary. The workflow timeout converted to seconds must be strictly greater than that bound; a stale 15-minute timeout is a failing test, not an optimistic default. If the bound exceeds the platform maximum, stop and amend the artifact design—do not silently add shards, discovery manifests, or aggregate summaries in this roadmap.

- [ ] **Step 5: Simplify CI without dropping non-suite gates**

Create one local/CI orchestrator with the exact order: syntax; pinned schema-validator and gitleaks verify; build; filtered-input secret scan; doctor; generated/manifests parity; unified runner; emitted-artifact-manifest validation plus registry/fixture validation; dangerous tracked files; clean tracked/non-ignored state. It receives a shared-policy-approved external OutputRoot and explicit `-ChildArtifactManifestPath`, `-FinalArtifactManifestPath`, and `-JsonSummaryPath`. It first emits every child report and the self-validated children manifest, then emits a repository-validation-summary binding that child manifest hash, then emits/validates the final manifest listing child manifest+children+summary without listing itself; no artifact points forward to the final manifest. It checks every child exit/result and never infers ArtifactKind from filename. Before/after cleanliness compares only tracked plus non-ignored untracked Git state, excluding exactly the four protected Reasonix paths; generated/report/output roots may be ignored and created during validation, so they are governed separately by deterministic parity, `git ls-files`-must-be-empty, and artifact-manifest gates rather than a byte-for-byte pre-run delta. For the exact release commit, “clean checkout” means clean Git porcelain under the same rule, not absence of ignored generated outputs. CI calls this same orchestrator after installing both pinned tools; do not replace non-suite gates with the suite runner.

- [ ] **Step 6: Verify workflow/suite parity**

`tests/repository-validation.tests.ps1` must exercise an extracted orchestration helper with injected gate stubs and a fixture-only runner root; it must never invoke the real orchestrator or `run-tests.ps1 -All`, avoiding orchestrator→runner→suite recursion. After that suite returns, the parent CI/Task 7 process invokes the real orchestrator exactly once. Assert from its external summary/children/final manifests that it executed each named non-suite gate, consumed both explicit manifest paths, produced the acyclic child→summary→final graph, and failed when any gate/result/artifact entry or either manifest was missing.

Expected: the summary discovery snapshot equals the live set of `tests/*.tests.ps1`; `config-sync.tests.ps1` and every new suite appear exactly once in the one runner job; no manual suite path remains in workflow YAML and the job timeout exceeds its computed bound.

### Task 4: Add Repository Safety-Policy Tests

**Artifacts / Locations:**
- Create: `tests/repository-policy.tests.ps1`
- Modify: `.claude/settings.json`
- Modify: `tests/agent-dotfiles.tests.ps1`
- Modify: `tests/automation-safety.tests.ps1`

- [ ] **Step 1: Write static policy assertions**

Assert current AGENTS/CLAUDE/README contracts mention Claude/Codex/Reasonix, canonical `reasonix-only`, per-platform manifest authority, non-consumable-preview/event-only bootstrap/hooks, actionable plans created only by explicit `ExternalUserArtifact` DryRun, external PlanPath, shared authority, `.system`/unknown no-read protection, and no public skip/test Apply capability. The policy test must reject any contract that exposes an internal preview path or bytes as an Apply PlanPath.

- [ ] **Step 2: Guard generated output**

Add deny coverage for `reasonix/skills/**` alongside Claude/Codex generated roots and Codex `.system`. Assert no direct generated-output edit/copy command is allowlisted.

- [ ] **Step 3: Guard retired surfaces**

Assert active CLI/profile/env/schema/test paths do not reintroduce MCP registration or OpenClaw/OpenCode operation; archive/history references remain permitted only with a retired/historical banner.

- [ ] **Step 4: Guard automation and protocol policy**

Assert no hook/bootstrap code contains a reachable Apply invocation, no current doc claims it does, and the release policy has no CLI/environment bypass.

- [ ] **Step 5: Verify policy suite**

Run `tests/repository-policy.tests.ps1` and the existing dispatcher/automation suites.

### Task 5: Synchronize Current Operating Documentation

**Artifacts / Locations:**
- Modify: `AGENTS.md`
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `docs/README.md`
- Modify: `docs/ONBOARD_NEW_MACHINE.md`
- Modify: `docs/RESTORE.md`
- Modify: `docs/MERGE_POLICY.md`
- Modify: `docs/superpowers/specs/2026-07-10-harness-env-design.md`
- Modify: the single tracked file returned by `git ls-files 'docs/superpowers/specs/2026-08-01-*hotplug-design.md'` (abort unless exactly one path resolves)
- Modify after verification: `STATUS.md`

- [ ] **Step 1: Document the three-platform source and manifest contract**

List shared/claude-only/codex-only/reasonix-only, all three generated/live roots, per-platform manifests as prune authority, and union manifest as inventory only. Do not restore removed MCP or deleted canonical skills.

- [ ] **Step 2: Document entrypoint trust and plan separation**

Document the staged fresh-clone flow: first bare bootstrap installs/checks inert wrappers and emits validator/scanner/runner diagnostics; explicit pinned schema-validator and gitleaks installs plus `scripts/setup.ps1 -ApproveRunner` follow. A later bootstrap with no canonical setup emits only `canonical-setup-required`; the user separately reviews/applies `agent-dotfiles.ps1 canonical setup`, then starts a new bootstrap/status invocation before any initial/live preview can be generated. Hooks create only non-consumable Git-private previews/events plus an exact public DryRun command; the actionable plan and matching Apply always use the same external PlanPath. Describe `-SkipInitialPlan` and the deprecated alias accurately.

- [ ] **Step 3: Document authority and recovery routing**

Onboarding first checks canonical recovery, then calls zero-write `agent-dotfiles.ps1 canonical status` for setup-state/global claim. Missing setup chooses only `canonical-setup-required`, emits the external setup DryRun command, and stops; after a separately authorized setup Apply, a new invocation may collect any intended first-authority custom Reasonix root and pass it to `env authority status -ReasonixLiveSkillsPath`. The same root/context must reach initial/migrate/adopt DryRun/Apply. Live status then chooses exactly one of initial, ordinary activation, migrate, adopt, repair-adopt, takeover, recovery, `controller-owner-action-required`, or manual recovery. Owner-action/manual routes stop without build/plan; recovery builds only recovery evidence; adopt/repair-adopt require an explicit user-selected name. Restore docs require exact COMPLETE receipt linked to a committed source transaction, snapshot hashes, current context, pre-rollback receipt, and reviewed abandon/rollback/finalize.

- [ ] **Step 4: Document `.system` and unknown marker-only scope**

Remove every statement that backup copies `.system` contents. Explain that unknown and `.system` content is never traversed; only root-entry marker evidence is recorded and preserved.

- [ ] **Step 5: Document formal retirement**

Keep external explicit retirement, now as `OperationKind=retirement` under shared authority/active-selection/receipt/state/journal/recovery. It rejects selected lock/task targets, allows only stale out-of-selection managed targets, and advances authority generation so old plans cannot replay. Hooks never create/consume it; legacy schema 2 plan/manifest pairs are not accepted by the new protocol.

- [ ] **Step 6: Mark superseded designs**

Add short banners to the old harness-env/task-hotplug designs pointing to the approved 2026-08-09 safety design for live mutation behavior. Do not rewrite historical body text or revive removed active specs.

- [ ] **Step 7: Redact current status and resolve publication handling**

Verify Roadmap Task 1 replaced the **worktree** STATUS machine-private paths with backup basenames, the device name with a generic redacted label, and `.system` content hash/count with marker-presence evidence; HEAD/index may still contain the acknowledged historical bytes until Task 8 obtains staging authorization. Confirm the user has made one separate decision covering both the already-public `7d9dd08` STATUS values and the four opaque historical `.reasonix` blobs; this phase does not authorize reading those blobs, history rewrite, or force-push. If current/untracked STATUS still exposes values—or public-history handling is unresolved—stop before the release-candidate commit. Record implementation status only from fresh verification.

- [ ] **Step 8: Run policy/docs checks**

Run repository-policy tests and targeted `rg` searches outside archive/history for obsolete auto-Apply, latest-backup, repo-local authority, `.system` full-backup, Claude/Codex-only, and internal-plan wording.

### Task 6: Stop Tracking Reasonix Desktop State Without Reading or Deleting It

This task changes the Git index and therefore requires a separate explicit user authorization at execution time; approval of this plan is not that authorization. Without it, stop before Step 2 and keep the files untouched.

**Artifacts / Locations:**
- Modify: `.gitignore`
- Create: `scripts/untrack-private-paths.ps1`
- Create: `tests/private-index-removal.tests.ps1`
- Remove from Git index only: `.reasonix/desktop-topic-auto-title-meta.json`
- Remove from Git index only: `.reasonix/desktop-topic-created-at.json`
- Remove from Git index only: `.reasonix/desktop-topic-title-sources.json`
- Remove from Git index only: `.reasonix/desktop-topic-titles.json`

- [ ] **Step 1: Verify paths through metadata only**

Run `git ls-files --stage --` and `git ls-tree HEAD --` followed by the four literal paths, plus `Test-Path -PathType Leaf` for those same literals. Require exactly one stage-0 entry per path, identical mode/OID in index and HEAD, no unmerged entry and no pre-existing staged drift. Before copying index bytes, require `git rev-parse --shared-index-path` to return no path, reject a main-index `link` extension, require sparse-index config disabled and reject any sparse-directory entry; protocol v1 reports `unsupported-split-index|unsupported-sparse-index` without changing index/worktree. Record the standalone real Git index path/hash/header/extensions plus an ordered stage listing of every non-protected entry; this is index metadata, not file content. Do not use a wildcard/directory pathspec or call `Get-Content`, worktree hash/copy/diff/status, or any content-reading command on the protected paths.

Expected: Git lists exactly four tracked paths; all four local files exist.

- [ ] **Step 2: Add one anchored ignore rule**

Add `/.reasonix/desktop-topic-*` to `.gitignore`. Do not ignore all `.reasonix` or delete the directory.

- [ ] **Step 3: Prepare and atomically replace an index-only snapshot**

Do not use `git rm --cached`: its index refresh/check-local-mod path may open racy worktree files. Only after Step 1 proves a standalone nonsparse main index, `scripts/untrack-private-paths.ps1` may copy those exact Git index bytes into a Git-private temporary `GIT_INDEX_FILE`, run `git update-index --force-remove --` with the four literal paths against that temporary index, and verify the temp index is self-contained and differs only by those four stage-0 deletions. It then create-new acquires the real `index.lock`, revalidates the real index hash/identity/extensions, still-absent shared-index path, nonsparse state and all non-protected stage entries against Step 1, writes/flushes the prepared index bytes to the lock, and atomically renames it over the index. Any split/sparse index, concurrent index/shared-index/config change, unmerged/staged mismatch, missing leaf, temp-index extra delta, lock collision, or no-read sentinel fails with the original index untouched. The helper accepts no wildcard/recursive/force-path input and never opens the four worktree files or blob contents.

- [ ] **Step 4: Verify preservation**

Run:

```powershell
git ls-files -- .reasonix/desktop-topic-auto-title-meta.json .reasonix/desktop-topic-created-at.json .reasonix/desktop-topic-title-sources.json .reasonix/desktop-topic-titles.json
Test-Path -PathType Leaf .reasonix/desktop-topic-auto-title-meta.json
Test-Path -PathType Leaf .reasonix/desktop-topic-created-at.json
Test-Path -PathType Leaf .reasonix/desktop-topic-title-sources.json
Test-Path -PathType Leaf .reasonix/desktop-topic-titles.json
git check-ignore -v --no-index -- .reasonix/desktop-topic-auto-title-meta.json .reasonix/desktop-topic-created-at.json .reasonix/desktop-topic-title-sources.json .reasonix/desktop-topic-titles.json
git diff -- .gitignore
git ls-tree HEAD -- .reasonix/desktop-topic-auto-title-meta.json .reasonix/desktop-topic-created-at.json .reasonix/desktop-topic-title-sources.json .reasonix/desktop-topic-titles.json
```

Expected: `git ls-files` is empty; every Test-Path is True; all files match the anchored ignore rule; `git ls-tree HEAD` still reports the four historical entries without reading blobs; every non-protected index entry exactly matches the pre-snapshot; and the worktree diff shows only the intended `.gitignore` rule for that file. Run split-index/sharedindex, sparse-index, racy-stat, modified-worktree, access-denied, concurrent-index/config, linked-worktree and forced process-kill tests; unsupported index modes leave original index/worktree untouched, and access telemetry shows zero protected file/blob opens with local files present.

### Task 7: Run the Full Interlocked Implementation Candidate

**Artifacts / Locations:**
- Create outside tracked tree: validation/test summaries plus children and final emitted-artifact manifests
- Review: `scripts/live-safety-policy.psd1`
- Update evidence after pass: this plan

- [ ] **Step 1: Exercise released-route logic only through sealed test seams**

Keep the tracked policy interlocked. Exercise the pure release decision and complete transaction host through the sealed internal sandbox/capability factory; production wrappers remain blocked. Do not edit a policy copy and call it a release candidate, because policy bytes are part of ToolchainPolicyHash.

- [ ] **Step 2: Verify the current implementation snapshot without cloning bare HEAD**

Verify staged, unstaged, and untracked implementation inputs separately and record their hashes using `.` plus exactly four protected Reasonix literal negative pathspecs, never broad `.reasonix/**`. A fifth adjacent `.reasonix` file must remain visible and fail the clean gate unless intentionally handled. For the four protected paths, use only literal index/path-existence metadata and never hash/diff/blob output. A temporary clone of bare HEAD is not representative while required bytes are outside a commit; do not substitute it for the working-tree candidate or imply public released behavior was tested.

Expected: sealed tests prove external-plan/build/scan/receipt/journal/authority/recovery behavior, while every real production wrapper still exits at the interlock.

- [ ] **Step 3: Run all local gates with the real policy interlocked**

```powershell
$verify = Join-Path $env:TEMP ("ai-agent-dotfiles-release-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $verify | Out-Null
pwsh -NoProfile -File scripts/install-schema-validator.ps1 -Install
pwsh -NoProfile -File scripts/install-schema-validator.ps1 -VerifyOnly
pwsh -NoProfile -File scripts/install-gitleaks.ps1 -Install
pwsh -NoProfile -File scripts/install-gitleaks.ps1 -VerifyOnly
pwsh -NoProfile -File scripts/run-repository-validation.ps1 -OutputRoot $verify -ChildArtifactManifestPath (Join-Path $verify 'child-artifacts.json') -FinalArtifactManifestPath (Join-Path $verify 'final-artifacts.json') -JsonSummaryPath (Join-Path $verify 'repository-validation.json')
```

Expected: every command and named sub-gate exits zero; suite counts are exact; generated/manifests parity, dangerous-file policy, before/after clean-state proof, registry positives/negatives, and both acyclic emitted-artifact manifests validate; no real live/authority/backup path changes.

- [ ] **Step 4: Run two independent reviews**

Requirements review compares every design completion item to code/test evidence. Quality review checks dependency hash/license record, path/walker/lock/journal implementation, error messages, docs, CI, and recovery ergonomics.

- [ ] **Step 5: Resolve every review finding**

Rerun the focused failing suite, then the full gate list after each correction. Do not waive a hard-kill, schema, or no-read failure.

### Task 8: Create and Verify One Exact Released Candidate Without Applying It

**Artifacts / Locations:**
- Modify last: `scripts/live-safety-policy.psd1`
- Modify: Phase 0 interlock tests to assert released routing in isolated copies and no bypass in production
- Require separately: one user-authorized, reviewed local release-candidate commit
- Update: `STATUS.md`

- [ ] **Step 1: Obtain separate commit authorization and create the released candidate**

After Task 7 passes, stop unless the user separately authorizes editing/staging/committing the reviewed implementation. Change only `ReleaseState` from `interlocked` to `released`, rerun focused policy tests, then review complete candidate content with `.` plus exactly four protected Reasonix literal negative pathspecs; review those four paths only through literal `git ls-files --stage`/`git ls-tree`/path-existence metadata and never through patch/blob/status output. A fifth adjacent `.reasonix` entry remains in the full candidate and clean gate. Stage the exact candidate, verify staged and worktree STATUS contain none of the redacted path/device/fingerprint values, and verify the index-only Reasonix removal/anchored ignore through those four literal metadata paths without opening content. Then create one local release-candidate commit containing all implementation bytes plus the released policy. Record its exact commit and ToolchainPolicyHash. This is not push/publication, history rewrite, or live authorization. Do not amend it, add a switch/override/fallback, or treat a dirty policy edit as a candidate.

- [ ] **Step 2: Test that exact commit under a disposable OS identity**

For **each mutually exclusive positive route**—initial, migrate, adopt, repair-adopt, takeover, environment/task/retirement/rollback, and recovery—start from a separate fresh disposable Windows user/Windows Sandbox/ephemeral VM snapshot (or platform-equivalent isolated CI worker) with route-specific schema-valid seed evidence. Its real HOME, USERPROFILE, LOCALAPPDATA, APPDATA, ControlBase, BackupRoot, Git-private runner cache, validator cache, and scanner cache are all disposable and asserted distinct from the host; never erase immutable claims between cases to manufacture another route. In every snapshot clone the exact released commit, install/verify the pinned schema validator and gitleaks, run `scripts/setup.ps1 -ApproveRunner`, then DryRun/review/Apply the public canonical setup plan and start a new invocation before the route-specific public plans. Do not add public ControlBase/HomeRoot overrides or change policy bytes. Verify the host user's real roots never change.

- [ ] **Step 3: Run the entire gate list on the same immutable commit**

Run the Task 7 gate list inside the disposable clone and require a clean checkout afterward. Review schema registry completeness and the clone-specific `.reasonix` policy assertions: none of the four paths is tracked, the anchored ignore/no-read rules validate by literal path, and no test requires those machine-local files to exist. The four `Test-Path=True` preservation assertions apply only to the original authorized worktree in Task 6. The tested commit/hash must equal Step 1 exactly.

- [ ] **Step 4: Reject failures by creating a new candidate, never by dirty patching**

If any check fails, mark this candidate rejected, return to the owning phase, and require a new separately reviewed commit before repeating Step 2. Never flip policy again inside the clone or claim the failed commit was tested after an uncommitted fix.

- [ ] **Step 5: Record only verified release facts**

Update STATUS with protocol/schema/runner versions and observed test totals. Explicitly state that real authority/live state is still unchanged and real Apply remains unperformed.

### Task 9: Collect Real-Machine Status and Dry-Run Evidence, Then Stop

**Artifacts / Locations:**
- Create outside tracked tree: one route-correct plan and its artifact manifest/validation summary
- Update after evidence: `STATUS.md`

- [ ] **Step 1: Run only read-only commands**

Run doctor, check-hooks, config status, env list/status, task status, `agent-dotfiles.ps1 canonical status`, `canonical recover status`, and `live recover status`. The zero-write canonical selector runs before live authority routing; do not inspect protected `.reasonix` content.

- [ ] **Step 2: Select the route and prepare only its required evidence without Apply**

Current evidence says legacy schema 2 state names `work`, its task overlay is empty, live 2/4/2 parity passes, and the old commit-bound staging lock is stale after `7d9dd08`. Branch first: unresolved canonical/live recovery uses only recovery evidence; missing canonical setup emits a canonical setup DryRun plan and stops for separate Apply authorization. Only after setup succeeds and a new invocation restarts status may it call `env authority status` (with the intended first-authority `-ReasonixLiveSkillsPath` if any). Then owner-action/manual reports and stops; recovery prepares only transaction evidence; takeover validates existing parity/state-only evidence; initial/ordinary/migrate/adopt/repair-adopt let their DryRun command create and bind its own external env-build v3 materialization where required. Migrate preserves exact legacy state plus matching stale old activation lock as immutable evidence only, while using a separate fresh current lock. Adopt/repair-adopt require an explicit user-selected name if status cannot trust one; adopt has no old-lock prerequisite, while repair binds valid claims plus CORRUPT exact state evidence or a MISSING marker and treats any old lock as optional untrusted evidence. Do not use ordinary activation unless status uniquely selects it.

- [ ] **Step 3: Generate, validate, and manually review the dry-run**

Generate exactly one plan selected by the current invocation: canonical setup when setup is missing, otherwise the initial/environment/migrate/adopt/repair-adopt/takeover/recovery plan selected by live status. Setup/owner-action/manual routes do not fall through to another plan in the same invocation. Using only route-owned fresh evidence where required, validate its artifact manifest, PlanHash/DocumentHash, route-specific old evidence/fresh lock, all three root claims/actions, controller, task baseline, unknown/`.system` markers, and expected backup targets. Expect a migration-only route with no live mutation only if status re-confirms current parity; treat any unexplained mutation, especially `work` prune, as evidence requiring user review rather than authorization.

- [ ] **Step 4: Stop before Apply**

Report route, plan path, redacted hashes, and per-platform add/update/no-op/prune counts. Wait for a later explicit user authorization before any real migrate/adopt/repair-adopt/takeover/activation/retirement/rollback/recovery Apply.
