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
        'canonical-setup-state' = @{
            SchemaVersion = 1
            SchemaPath = 'schemas/canonical-setup-state.schema.json'
            PositiveFixture = 'tests/fixtures/artifacts/canonical-setup-state.valid.json'
            NegativeFixtures = @(
                @{ Name = 'unknown-property'; Path = 'tests/fixtures/artifacts/canonical-setup-state.unknown.invalid.json'; FailureLayer = 'Schema' }
            )
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
