@{
    SchemaVersion = 1
    DataPathspecs = @(
        'skills-source'
        'manifests'
        'harness-source'
        '.agent-harness/task-skills.psd1'
    )
    # The frozen selection-aware preview routing table (Phase 3 Task 8). The
    # keys are exactly the authority routes emitted by
    # Resolve-HarnessEnvAuthorityRoute; 'environment-preview' is the only action
    # that may materialize a build (always from the committed data snapshot into
    # Git-private scratch, always non-consumable), every other route is
    # diagnostic-only with zero materialization. Explicit setup refuses to
    # approve a runner whose route table differs from the authority route set.
    PreviewRouteActions = @{
        'recovery'                         = @{ Action = 'diagnostic'; Command = 'live recover status' }
        'initial'                          = @{ Action = 'environment-preview'; Command = 'env activate full -DryRun' }
        'activate'                         = @{ Action = 'environment-preview'; Command = 'env activate <name> -DryRun' }
        'migrate'                          = @{ Action = 'diagnostic'; Command = 'env authority migrate <name> -DryRun -PlanPath <external-plan.json>' }
        'adopt'                            = @{ Action = 'diagnostic'; Command = 'env authority adopt <name> -DryRun -PlanPath <external-plan.json>' }
        'repair-adopt'                     = @{ Action = 'diagnostic'; Command = 'env authority repair-adopt <name> -DryRun -PlanPath <external-plan.json>' }
        'takeover'                         = @{ Action = 'diagnostic'; Command = 'env authority takeover <name> -DryRun -PlanPath <external-plan.json>' }
        'controller-owner-action-required' = @{ Action = 'diagnostic'; Command = 'env authority status' }
        'manual-recovery-required'         = @{ Action = 'diagnostic'; Command = 'env authority status' }
    }
    ToolchainPaths = @(
        '.gitleaks.toml'
        'bootstrap.ps1'
        'scripts/approved-hook-entry.ps1'
        'scripts/approved-runner-common.ps1'
        'scripts/runner-policy.psd1'
        'scripts/setup.ps1'
        'scripts/apply-hooks.ps1'
        'scripts/check-hooks.ps1'
        'scripts/bootstrap-clone.ps1'
        'scripts/agent-dotfiles.ps1'
        'scripts/plans.ps1'
        'scripts/auto-sync-after-git.ps1'
        'scripts/build-skills.ps1'
        'scripts/canonical-preflight-common.ps1'
        'scripts/canonical-mutation-common.ps1'
        'scripts/canonical-recovery-common.ps1'
        'scripts/canonical-transaction-common.ps1'
        'scripts/canonical-command-result.ps1'
        'scripts/canonical-transaction.ps1'
        'scripts/canonical-skill-adapter-common.ps1'
        'scripts/skills-common.ps1'
        'scripts/normalize-skill.ps1'
        'scripts/promote-skill.ps1'
        'scripts/auto-merge-skills.ps1'
        'scripts/setup-canonical-transaction.ps1'
        'scripts/recover-canonical-transaction.ps1'
        'scripts/transaction-journal-common.ps1'
        'scripts/sync.ps1'
        'scripts/backup.ps1'
        'scripts/task-skills.ps1'
        'scripts/activate-harness-env.ps1'
        'scripts/build-harness-env.ps1'
        'scripts/harness-env-common.ps1'
        'scripts/json-artifact-common.ps1'
        'scripts/scan-input-common.ps1'
        'scripts/safe-tree-walker.ps1'
        'scripts/target-context-common.ps1'
        'scripts/live-target-context.ps1'
        'scripts/home-authority-common.ps1'
        'scripts/shared-authority-state-common.ps1'
        'scripts/root-claims-registry-common.ps1'
        'scripts/harness-profile-common.ps1'
        'scripts/harness-authority-status-common.ps1'
        'scripts/live-transaction-common.ps1'
        'scripts/backup-receipt-common.ps1'
        'scripts/status-harness-env.ps1'
        'scripts/list-harness-env.ps1'
        'scripts/scan-secrets.ps1'
        'scripts/semantic-json.ps1'
        'scripts/install-gitleaks.ps1'
        'scripts/install-schema-validator.ps1'
        'scripts/live-safety-policy.psd1'
        'scripts/live-safety-interlock.ps1'
        'scripts/validate-json-artifacts.ps1'
        'schemas/artifact-contracts.psd1'
        'schemas/artifact-validation-manifest.schema.json'
        'schemas/pending-sync-event.schema.json'
        'schemas/runner-approval-event.schema.json'
        'schemas/approved-runner-state.schema.json'
        'schemas/committed-data-snapshot-manifest.schema.json'
        'schemas/canonical-root-claim.schema.json'
        'schemas/canonical-setup-state.schema.json'
        'schemas/root-claims.schema.json'
        'schemas/current-env-state.schema.json'
        'schemas/harness-env-build.schema.json'
        'schemas/harness-env-lock.schema.json'
        'schemas/harness-env-list.schema.json'
        'schemas/harness-env-status.schema.json'
        'schemas/live-journal-header.schema.json'
        'schemas/live-journal-record.schema.json'
        'schemas/canonical-journal-header.schema.json'
        'schemas/canonical-journal-record.schema.json'
        'schemas/canonical-journal-manifest.schema.json'
        'schemas/canonical-transaction-plan.schema.json'
        'schemas/canonical-recovery-plan.schema.json'
        'schemas/canonical-transaction-result.schema.json'
        'schemas/pending-prune-plan.schema.json'
        'tools/gitleaks/gitleaks.lock.json'
        'tools/schema-validator/validator.lock.json'
    )
}
