@{
    SchemaVersion = 1
    Id = 'no-generated-output-edits'
    Kind = 'Rule'
    TargetPlatforms = @('Claude', 'Codex')
    Requires = @()
    Conflicts = @()
    Outputs = @(
        @{
            Target = 'AGENTS.md'
            Mode = 'ManagedBlock'
            BlockId = 'no-generated-output-edits'
        }
    )
}
