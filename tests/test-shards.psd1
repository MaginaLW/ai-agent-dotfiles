# Static, tracked partition of the repository root test suites across the three CI
# shard jobs (.github/workflows/validate.yml jobs validate-tests-1..3). Owner decision
# 2026-09-19: the proven 42-suite budget (RequiredJobTimeoutSeconds 29955 s = 499.25 min
# after the 2026-09-26 re-derivation; 27555 s = 459.25 min at the 2026-09-19 decision)
# structurally cannot fit one GitHub hosted-runner job (360-minute ceiling), so the
# single-job contract is replaced by this partition; the earlier "do not shard" line in
# docs/specs/2026-09-16-phase4-schema-ci-release-proposal.md Task 3 is superseded.
#
# Contract (asserted by tests/test-runner.tests.ps1 and enforced fail-closed by
# scripts/run-tests.ps1 whenever -ShardCount/-ShardIndex are passed):
#   - The union of the shard lists below must equal the runner's discovered suite set
#     (tests/*.tests.ps1) exactly once: no duplicates, no omissions, no extras.
#   - Each shard job's timeout-minutes must stay strictly above that shard's summed
#     budget (its tests/test-timeouts.psd1 entry; DefaultTimeoutSeconds = 120 otherwise)
#     plus SetupAndNonSuiteBudgetSeconds (300) plus MarginSeconds (120), and below the
#     360-minute hosted-runner job ceiling (21600 s).
#   - scripts/run-tests.ps1 without -ShardCount/-ShardIndex never reads this file and
#     keeps the unsharded -All contract byte-for-byte.
#
# How to rebalance when suites are added or budgets change:
#   1. Give the suite an explicit budget in tests/test-timeouts.psd1.
#   2. Add its lowercase file name to exactly ONE shard list below.
#   3. Recompute every shard's summed budget + 300 + 120; keep each below its job's
#      timeout-minutes x 60 and below 21600 s, and keep the measured wall clocks roughly
#      even (canonical-hard-kill stays alone-ish in shard 1 per the owner decision).
#   4. Raise the corresponding job's timeout-minutes only when its inequality breaks.
#
# Budget re-derivation 2026-09-26 (shard 3 only; evidence in docs/CI_FAILURE_RULES.md R2):
# shard 3's job ran 5417 s on run #147 and killed canonical-command-result (900 s),
# harness-authority (900 s) and harness-env (600 s) at their budgets. CI per-suite
# durations are unavailable (job log API is admin-only), so the runner factor can only
# be bounded: the three kills prove factor >= 1.31 / 1.46 / 1.60 respectively against the
# five clean 42-suite gate runs (555-689 s / 322-410 s / 439-561 s), and the residual
# estimate for the other 24 suites (<= 3017 s against 1883 s clean) bounds it by ~1.6x.
# The three killed suites were re-tiered to ~2x their clean maxima; live-recovery
# (477-598 s, <= 66% of its old tier) was considered and deliberately left at 900 s
# because no measurement shows it near its tier.
#
# Budget re-tiering 2026-09-26, shard 2: the three candidate runs of that evening
# (runs #148, #149, #150 on codex/post-audit-c12) each failed shard 2 on the same
# suite - backup-recovery.tests.ps1 timed out at its 900 s tier while the other seven
# shard-2 suites passed, and the same runs' shard 3 passed on the new tiers. Five clean
# gate runs measured backup-recovery at 520-692 s (58-77% of the old tier), so the tier
# is doubled to 1500 s the same way as the shard-3 kills; shard 2's job timeout already
# covers 9780 + 300 + 120 = 10200 s at 185 minutes.
@{
    '1' = @(
        'automation-safety.tests.ps1'              # 600
        'canonical-hard-kill.tests.ps1'            # 5400 (measured 2575 s: alone-ish shard)
        'canonical-mutation-blockers.tests.ps1'    # 600
        'canonical-mutation-parent-lease.tests.ps1'# 420
        'canonical-transaction.tests.ps1'          # 360
        'live-concurrency.tests.ps1'               # 300
        'repository-policy.tests.ps1'              # 600
    )
    '2' = @(
        'backup-receipt.tests.ps1'                 # 300
        'backup-recovery.tests.ps1'                # 1500
        'canonical-hard-kill-reap-semantics.tests.ps1' # 60
        'canonical-preflight.tests.ps1'            # 120
        'canonical-recovery.tests.ps1'             # 1200
        'canonical-transaction-apply.tests.ps1'    # 1800
        'root-claims-registry.tests.ps1'           # 3600
        'skills-import.tests.ps1'                  # 1200
    )
    '3' = @(
        'agent-dotfiles.tests.ps1'                 # 150
        'approved-runner.tests.ps1'                # 900
        'approved-runner-exact-byte.tests.ps1'     # 120
        'canonical-command-result.tests.ps1'       # 1800
        'canonical-production-seams.tests.ps1'     # 600
        'config-sync.tests.ps1'                    # 90
        'doctor.tests.ps1'                         # 60
        'harness-authority.tests.ps1'              # 1500
        'harness-env.tests.ps1'                    # 1200
        'harness-multiplatform.tests.ps1'          # 210
        'harness-profile.tests.ps1'                # 90
        'home-authority.tests.ps1'                 # 180
        'json-artifact-exact-byte.tests.ps1'       # 120
        'json-canonicalization.tests.ps1'          # 120
        'live-plan.tests.ps1'                      # 180
        'live-recovery.tests.ps1'                  # 900
        'path-safety.tests.ps1'                    # 120
        'powershell-syntax-gate.tests.ps1'         # 90
        'private-path-boundary.tests.ps1'          # 120
        'repository-validation.tests.ps1'          # 600
        'safe-tree-walker.tests.ps1'               # 120
        'scan-input-boundary.tests.ps1'            # 120
        'schema-validation.tests.ps1'              # 120
        'sync.tests.ps1'                           # 1200
        'task-skills.tests.ps1'                    # 900
        'test-runner.tests.ps1'                    # 45
        'transaction-journal-exact-byte.tests.ps1' # 120
    )
}
