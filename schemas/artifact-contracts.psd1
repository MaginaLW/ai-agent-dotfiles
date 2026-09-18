@{
    SchemaVersion = 1
    # Deliberately unregistered schema files: the producer/registry completeness test
    # fails for any schemas/*.schema.json that is neither registered below nor listed here.
    UnregisteredSchemas = @(
        @{ SchemaPath = 'schemas/harness-component.schema.json'; Reason = 'project-profile component contract, outside the live-protocol table' }
        @{ SchemaPath = 'schemas/harness-platform-output.schema.json'; Reason = 'project-profile platform output contract, outside the live-protocol table' }
    )
    # Fixture files referenced as nested payloads by registered fixtures; they are not
    # contract rows and must never be flagged as orphans by the completeness test.
    NestedPayloadFixtures = @(
        'tests/fixtures/artifacts/manifest-target.json'
    )
    Contracts = @{
        'canonical-journal-header' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-journal-header.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-journal-header.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-journal-header.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/canonical-journal-header.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/canonical-journal-header.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'malformed-hash'; Path = 'tests/fixtures/artifacts/canonical-journal-header.malformed-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/canonical-journal-header.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'canonical-journal-record' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-journal-record.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-journal-record.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-journal-record.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/canonical-journal-record.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/canonical-journal-record.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'malformed-hash'; Path = 'tests/fixtures/artifacts/canonical-journal-record.malformed-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/canonical-journal-record.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'canonical-journal-manifest' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-journal-manifest.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-journal-manifest.valid.json'
            NegativeFixtures = @(
                @{ Name = 'hash-chain-break'; Path = 'tests/fixtures/artifacts/canonical-journal-manifest.hash-break.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'embedded-unknown-property'; Path = 'tests/fixtures/artifacts/canonical-journal-manifest.embedded-unknown.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'embedded-cross-shape'; Path = 'tests/fixtures/artifacts/canonical-journal-manifest.cross-shape.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'target-phase-order'; Path = 'tests/fixtures/artifacts/canonical-journal-manifest.phase-order.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'target-tuple-semantics'; Path = 'tests/fixtures/artifacts/canonical-journal-manifest.tuple-semantics.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'result-projection-binding'; Path = 'tests/fixtures/artifacts/canonical-journal-manifest.result-projection.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-CanonicalJournalManifestSemantics'
        }
        'canonical-root-claim' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-root-claim.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-root-claim.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-root-claim.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/canonical-root-claim.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/canonical-root-claim.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'malformed-hash'; Path = 'tests/fixtures/artifacts/canonical-root-claim.malformed-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/canonical-root-claim.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'root-claims' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/root-claims.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/root-claims.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/root-claims.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-platform'; Path = 'tests/fixtures/artifacts/root-claims.missing-platform.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/root-claims.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'platform-order'; Path = 'tests/fixtures/artifacts/root-claims.platform-order.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'platform-duplicate'; Path = 'tests/fixtures/artifacts/root-claims.platform-duplicate.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'branch-crossing'; Path = 'tests/fixtures/artifacts/root-claims.branch-crossing.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'self-hash'; Path = 'tests/fixtures/artifacts/root-claims.self-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'authority-key'; Path = 'tests/fixtures/artifacts/root-claims.authority-key.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'noncanonical-location'; Path = 'tests/fixtures/artifacts/root-claims.noncanonical-location.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'noncanonical-sid'; Path = 'tests/fixtures/artifacts/root-claims.noncanonical-sid.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'fallback-absent'; Path = 'tests/fixtures/artifacts/root-claims.fallback-absent.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'volume-conflict'; Path = 'tests/fixtures/artifacts/root-claims.volume-conflict.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'identity-alias'; Path = 'tests/fixtures/artifacts/root-claims.identity-alias.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'parent-remainder'; Path = 'tests/fixtures/artifacts/root-claims.parent-remainder.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'overlap'; Path = 'tests/fixtures/artifacts/root-claims.overlap.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-RootClaimsSemantics'
        }
        'root-claims-occupancy' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/root-claims-occupancy.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/root-claims-occupancy.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/root-claims-occupancy.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/root-claims-occupancy.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'identity-mismatch'; Path = 'tests/fixtures/artifacts/root-claims-occupancy.identity-mismatch.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-RootClaimsOccupancySemantics'
        }
        'canonical-setup-state' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-setup-state.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-setup-state.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-setup-state.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/canonical-setup-state.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/canonical-setup-state.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'malformed-hash'; Path = 'tests/fixtures/artifacts/canonical-setup-state.malformed-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/canonical-setup-state.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'current-env-state' = @{
            SchemaVersion = 3
            SchemaPath = 'schemas/current-env-state.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/current-env-state.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/current-env-state.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-platform'; Path = 'tests/fixtures/artifacts/current-env-state.missing-platform.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/current-env-state.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'platform-order'; Path = 'tests/fixtures/artifacts/current-env-state.platform-order.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'platform-duplicate'; Path = 'tests/fixtures/artifacts/current-env-state.platform-duplicate.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'selection-kind'; Path = 'tests/fixtures/artifacts/current-env-state.selection-kind.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'initial-not-full'; Path = 'tests/fixtures/artifacts/current-env-state.initial-not-full.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'bad-uuid'; Path = 'tests/fixtures/artifacts/current-env-state.bad-uuid.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'safe-integer'; Path = 'tests/fixtures/artifacts/current-env-state.safe-integer.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'unsafe-skill'; Path = 'tests/fixtures/artifacts/current-env-state.unsafe-skill.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'overlong-skill'; Path = 'tests/fixtures/artifacts/current-env-state.overlong-skill.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'controller-receipt-crossing'; Path = 'tests/fixtures/artifacts/current-env-state.controller-receipt.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'receipt-ref-crossing'; Path = 'tests/fixtures/artifacts/current-env-state.receipt-ref.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'live-recover-kind'; Path = 'tests/fixtures/artifacts/current-env-state.live-recover.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'self-hash'; Path = 'tests/fixtures/artifacts/current-env-state.self-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'target-intent'; Path = 'tests/fixtures/artifacts/current-env-state.target-intent.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'final-target-hash'; Path = 'tests/fixtures/artifacts/current-env-state.final-target-hash.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'unsorted-skills'; Path = 'tests/fixtures/artifacts/current-env-state.unsorted-skills.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'skill-case-collision'; Path = 'tests/fixtures/artifacts/current-env-state.skill-case-collision.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'reserved-skill'; Path = 'tests/fixtures/artifacts/current-env-state.reserved-skill.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'path-location'; Path = 'tests/fixtures/artifacts/current-env-state.path-location.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'duplicate-identity'; Path = 'tests/fixtures/artifacts/current-env-state.duplicate-identity.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'overlap'; Path = 'tests/fixtures/artifacts/current-env-state.overlap.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-CurrentEnvStateSemantics'
        }
        'canonical-transaction-plan' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-transaction-plan.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-transaction-plan.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-transaction-plan.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'plan-hash-tamper'; Path = 'tests/fixtures/artifacts/canonical-transaction-plan.plan-hash.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'document-hash-tamper'; Path = 'tests/fixtures/artifacts/canonical-transaction-plan.document-hash.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-CanonicalTransactionPlanSemantics'
        }
        'canonical-recovery-plan' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-recovery-plan.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-recovery-plan.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-recovery-plan.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'plan-hash-tamper'; Path = 'tests/fixtures/artifacts/canonical-recovery-plan.plan-hash.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'document-hash-tamper'; Path = 'tests/fixtures/artifacts/canonical-recovery-plan.document-hash.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-CanonicalRecoveryPlanSemantics'
        }
        'rollback-plan' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/rollback-plan.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/rollback-plan.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/rollback-plan.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'finalize-partial-receipt'; Path = 'tests/fixtures/artifacts/rollback-plan.finalize-partial-receipt.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'environment-rollback-missing-receipt'; Path = 'tests/fixtures/artifacts/rollback-plan.environment-rollback-missing-receipt.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'state-only-receipt-crossing'; Path = 'tests/fixtures/artifacts/rollback-plan.state-only-receipt-crossing.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'state-only-missing-preimage'; Path = 'tests/fixtures/artifacts/rollback-plan.state-only-missing-preimage.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'plan-hash-tamper'; Path = 'tests/fixtures/artifacts/rollback-plan.plan-hash-tamper.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'document-hash-tamper'; Path = 'tests/fixtures/artifacts/rollback-plan.document-hash-tamper.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'plan-action-mismatch'; Path = 'tests/fixtures/artifacts/rollback-plan.plan-action-mismatch.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'closing-plan-kind-mismatch'; Path = 'tests/fixtures/artifacts/rollback-plan.closing-plan-kind-mismatch.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'projection-outcome-mismatch'; Path = 'tests/fixtures/artifacts/rollback-plan.projection-outcome-mismatch.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'operation-kind-substitution'; Path = 'tests/fixtures/artifacts/rollback-plan.operation-kind-substitution.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'chain-order-break'; Path = 'tests/fixtures/artifacts/rollback-plan.chain-order-break.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'complete-chain-present'; Path = 'tests/fixtures/artifacts/rollback-plan.complete-chain-present.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'claims-binding-missing'; Path = 'tests/fixtures/artifacts/rollback-plan.claims-binding-missing.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'journal-head-mismatch'; Path = 'tests/fixtures/artifacts/rollback-plan.journal-head-mismatch.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'duplicate-consumed-hash'; Path = 'tests/fixtures/artifacts/rollback-plan.duplicate-consumed-hash.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'state-preimage-path-orphan'; Path = 'tests/fixtures/artifacts/rollback-plan.state-preimage-path-orphan.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'environment-rollback-source-kind'; Path = 'tests/fixtures/artifacts/rollback-plan.environment-rollback-source-kind.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'environment-rollback-intent-kind'; Path = 'tests/fixtures/artifacts/rollback-plan.environment-rollback-intent-kind.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'environment-rollback-authority-key'; Path = 'tests/fixtures/artifacts/rollback-plan.environment-rollback-authority-key.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-RollbackPlanSemantics'
        }
        'sync-plan' = @{
            SchemaVersion = 3
            SchemaPath = 'schemas/sync-plan.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/sync-plan.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/sync-plan.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/sync-plan.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'live-recover-kind'; Path = 'tests/fixtures/artifacts/sync-plan.live-recover-kind.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'environment-rollback-kind'; Path = 'tests/fixtures/artifacts/sync-plan.environment-rollback-kind.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'live-recover-abandon-kind'; Path = 'tests/fixtures/artifacts/sync-plan.live-recover-abandon-kind.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'live-recover-rollback-kind'; Path = 'tests/fixtures/artifacts/sync-plan.live-recover-rollback-kind.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'runtime-receipt'; Path = 'tests/fixtures/artifacts/sync-plan.runtime-receipt.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'plan-hash-mismatch'; Path = 'tests/fixtures/artifacts/sync-plan.plan-hash-mismatch.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'document-hash-mismatch'; Path = 'tests/fixtures/artifacts/sync-plan.document-hash-mismatch.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-LiveSyncPlanSemantics'
        }
        'live-journal-header' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/live-journal-header.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/live-journal-header.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/live-journal-header.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'receipt-ref-crossing'; Path = 'tests/fixtures/artifacts/live-journal-header.receipt-ref-crossing.invalid.json'; FailureLayer = 'Schema' }
            )
            SemanticValidator = 'Test-LiveJournalHeaderSemantics'
        }
        'live-journal-record' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/live-journal-record.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/live-journal-record.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/live-journal-record.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'closing-crossing'; Path = 'tests/fixtures/artifacts/live-journal-record.closing-crossing.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-LiveJournalRecordSemantics'
        }
        'live-operation-result' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/live-operation-result.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/live-operation-result.valid.json'
            NegativeFixtures = @(
                @{ Name = 'scope-crossing'; Path = 'tests/fixtures/artifacts/live-operation-result.scope-crossing.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'receipt-state-crossing'; Path = 'tests/fixtures/artifacts/live-operation-result.receipt-state-crossing.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-LiveOperationResultSemantics'
        }
        'backup-receipt' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/backup-receipt.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/backup-receipt.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/backup-receipt.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/backup-receipt.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'copied-crossing'; Path = 'tests/fixtures/artifacts/backup-receipt.copied-crossing.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'marker-crossing'; Path = 'tests/fixtures/artifacts/backup-receipt.marker-crossing.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'intent-binding'; Path = 'tests/fixtures/artifacts/backup-receipt.intent-binding.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'self-hash'; Path = 'tests/fixtures/artifacts/backup-receipt.self-hash.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'target-order'; Path = 'tests/fixtures/artifacts/backup-receipt.target-order.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'transaction-receipt-alias'; Path = 'tests/fixtures/artifacts/backup-receipt.transaction-receipt-alias.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-BackupReceiptSemantics'
        }
        'harness-env-build' = @{
            SchemaVersion = 3
            SchemaPath = 'schemas/harness-env-build.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/harness-env-build.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/harness-env-build.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/harness-env-build.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-platform-root'; Path = 'tests/fixtures/artifacts/harness-env-build.missing-platform-root.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'hash-mismatch'; Path = 'tests/fixtures/artifacts/harness-env-build.hash-mismatch.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-HarnessEnvBuildSemantics'
        }
        'harness-env-list' = @{
            SchemaVersion = 2
            SchemaPath = 'schemas/harness-env-list.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/harness-env-list.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/harness-env-list.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/harness-env-list.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-reasonix-count'; Path = 'tests/fixtures/artifacts/harness-env-list.missing-reasonix-count.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-route'; Path = 'tests/fixtures/artifacts/harness-env-list.wrong-route.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'probed-status'; Path = 'tests/fixtures/artifacts/harness-env-list.probed-status.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'capability-hash'; Path = 'tests/fixtures/artifacts/harness-env-list.capability-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'intended-root-on-claims'; Path = 'tests/fixtures/artifacts/harness-env-list.intended-root-on-claims.invalid.json'; FailureLayer = 'Schema' }
            )
            SemanticValidator = 'Test-HarnessEnvAuthorityDocumentSemantics'
        }
        'harness-env-status' = @{
            SchemaVersion = 2
            SchemaPath = 'schemas/harness-env-status.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/harness-env-status.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/harness-env-status.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/harness-env-status.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-reasonix-count'; Path = 'tests/fixtures/artifacts/harness-env-status.missing-reasonix-count.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-route'; Path = 'tests/fixtures/artifacts/harness-env-status.wrong-route.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'probed-status'; Path = 'tests/fixtures/artifacts/harness-env-status.probed-status.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'backup-reference'; Path = 'tests/fixtures/artifacts/harness-env-status.backup-reference.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'route-facts-mismatch'; Path = 'tests/fixtures/artifacts/harness-env-status.route-facts-mismatch.invalid.json'; FailureLayer = 'Semantic' }
                @{ Name = 'next-operation-mismatch'; Path = 'tests/fixtures/artifacts/harness-env-status.next-operation-mismatch.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-HarnessEnvAuthorityDocumentSemantics'
        }
        'harness-env-lock' = @{
            SchemaVersion = 3
            SchemaPath = 'schemas/harness-env-lock.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/harness-env-lock.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/harness-env-lock.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/harness-env-lock.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-platform'; Path = 'tests/fixtures/artifacts/harness-env-lock.missing-platform.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'self-hash'; Path = 'tests/fixtures/artifacts/harness-env-lock.self-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'runtime-ref'; Path = 'tests/fixtures/artifacts/harness-env-lock.runtime-ref.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'canonical-transaction-result' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-transaction-result.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-transaction-result.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-transaction-result.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/canonical-transaction-result.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/canonical-transaction-result.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'malformed-hash'; Path = 'tests/fixtures/artifacts/canonical-transaction-result.malformed-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/canonical-transaction-result.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'canonical-build-result' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/run-report.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-build-result.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-build-result.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/canonical-build-result.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/canonical-build-result.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/canonical-build-result.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'canonical-secret-scan-result' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/secret-scan.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-secret-scan-result.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-secret-scan-result.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/canonical-secret-scan-result.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/canonical-secret-scan-result.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/canonical-secret-scan-result.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'doctor-report' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/doctor-report.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/doctor-report.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/doctor-report.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'artifact-kind-field'; Path = 'tests/fixtures/artifacts/doctor-report.artifact-kind-field.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/doctor-report.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/doctor-report.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/doctor-report.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'scan-input-manifest' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/scan-input-manifest.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/scan-input-manifest.valid.json'
            NegativeFixtures = @(
                @{ Name = 'missing-protected-path'; Path = 'tests/fixtures/artifacts/scan-input-manifest.missing-protected.invalid.json'; FailureLayer = 'Schema' }
            )
            SemanticValidator = 'Test-ScanInputManifestSemantics'
        }
        'test-run-summary' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/test-run-summary.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/test-run-summary.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/test-run-summary.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/test-run-summary.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/test-run-summary.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'malformed-hash'; Path = 'tests/fixtures/artifacts/test-run-summary.malformed-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/test-run-summary.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
            SemanticValidator = 'Test-TestRunSummarySemantics'
        }
        'artifact-validation-manifest' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/artifact-validation-manifest.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/artifact-validation-manifest.valid.json'
            NegativeFixtures = @(
                @{ Name = 'tampered-content-hash'; Path = 'tests/fixtures/artifacts/artifact-validation-manifest.tampered.invalid.json'; FailureLayer = 'Semantic' }
            )
            SemanticValidator = 'Test-ArtifactManifestSemantics'
        }
        'artifact-validation-summary' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/artifact-validation-summary.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/artifact-validation-summary.valid.json'
            NegativeFixtures = @(
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/artifact-validation-summary.wrong-version.invalid.json'; FailureLayer = 'Schema' }
            )
            SemanticValidator = 'Test-ArtifactValidationSummarySemantics'
        }
        'repository-validation-summary' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/repository-validation-summary.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/repository-validation-summary.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/repository-validation-summary.unknown-property.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/repository-validation-summary.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/repository-validation-summary.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-report-kind'; Path = 'tests/fixtures/artifacts/repository-validation-summary.wrong-report-kind.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'final-role-reference'; Path = 'tests/fixtures/artifacts/repository-validation-summary.final-role-reference.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forward-final-reference'; Path = 'tests/fixtures/artifacts/repository-validation-summary.forward-final-reference.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'malformed-hash'; Path = 'tests/fixtures/artifacts/repository-validation-summary.malformed-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/repository-validation-summary.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'duplicate-gate'; Path = 'tests/fixtures/artifacts/repository-validation-summary.duplicate-gate.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'pending-sync-event' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/pending-sync-event.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/pending-sync-event.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/pending-sync-event.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/pending-sync-event.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/pending-sync-event.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'malformed-hash'; Path = 'tests/fixtures/artifacts/pending-sync-event.malformed-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/pending-sync-event.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'runner-approval-event' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/runner-approval-event.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/runner-approval-event.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/runner-approval-event.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/runner-approval-event.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/runner-approval-event.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'malformed-hash'; Path = 'tests/fixtures/artifacts/runner-approval-event.malformed-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/runner-approval-event.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'approved-runner-state' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/approved-runner-state.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/approved-runner-state.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/approved-runner-state.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/approved-runner-state.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/approved-runner-state.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'malformed-hash'; Path = 'tests/fixtures/artifacts/approved-runner-state.malformed-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/approved-runner-state.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'committed-data-snapshot-manifest' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/committed-data-snapshot-manifest.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/committed-data-snapshot-manifest.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/committed-data-snapshot-manifest.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/committed-data-snapshot-manifest.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/committed-data-snapshot-manifest.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'malformed-hash'; Path = 'tests/fixtures/artifacts/committed-data-snapshot-manifest.malformed-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/committed-data-snapshot-manifest.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'pending-prune-plan' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/pending-prune-plan.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/pending-prune-plan.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/pending-prune-plan.unknown.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'wrong-version'; Path = 'tests/fixtures/artifacts/pending-prune-plan.wrong-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'missing-schema-version'; Path = 'tests/fixtures/artifacts/pending-prune-plan.missing-schema-version.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'malformed-hash'; Path = 'tests/fixtures/artifacts/pending-prune-plan.malformed-hash.invalid.json'; FailureLayer = 'Schema' }
                @{ Name = 'forbidden-null'; Path = 'tests/fixtures/artifacts/pending-prune-plan.forbidden-null.invalid.json'; FailureLayer = 'Schema' }
            )
        }
    }
}
