@{
    SchemaVersion = 1
    Contracts = @{
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
