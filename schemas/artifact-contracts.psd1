@{
    SchemaVersion = 1
    Contracts = @{
        'canonical-journal-header' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-journal-header.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-journal-header.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-journal-header.unknown.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'canonical-journal-record' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-journal-record.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-journal-record.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-journal-record.unknown.invalid.json'; FailureLayer = 'Schema' }
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
        'canonical-setup-state' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-setup-state.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-setup-state.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-setup-state.unknown.invalid.json'; FailureLayer = 'Schema' }
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
        'canonical-transaction-result' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-transaction-result.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-transaction-result.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-transaction-result.unknown.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'canonical-build-result' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/run-report.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-build-result.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-build-result.unknown.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'canonical-secret-scan-result' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/secret-scan.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-secret-scan-result.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-secret-scan-result.unknown.invalid.json'; FailureLayer = 'Schema' }
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
        'pending-sync-event' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/pending-sync-event.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/pending-sync-event.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/pending-sync-event.unknown.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'runner-approval-event' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/runner-approval-event.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/runner-approval-event.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/runner-approval-event.unknown.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'approved-runner-state' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/approved-runner-state.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/approved-runner-state.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/approved-runner-state.unknown.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'committed-data-snapshot-manifest' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/committed-data-snapshot-manifest.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/committed-data-snapshot-manifest.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/committed-data-snapshot-manifest.unknown.invalid.json'; FailureLayer = 'Schema' }
            )
        }
        'pending-prune-plan' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/pending-prune-plan.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/pending-prune-plan.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/pending-prune-plan.unknown.invalid.json'; FailureLayer = 'Schema' }
            )
        }
    }
}
