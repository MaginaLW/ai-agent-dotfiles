@{
    SchemaVersion = 1
    Id = 'no-generated-output-edits'
    Kind = 'Rule'
    TargetPlatforms = @('Codex')
    Outputs = @(
        @{
            Target = 'AGENTS.md'
            Mode = 'ManagedBlock'
            BlockId = 'no-generated-output-edits'
        }
    )
}
