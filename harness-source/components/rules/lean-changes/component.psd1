@{
    SchemaVersion = 1
    Id = 'lean-changes'
    Kind = 'Rule'
    TargetPlatforms = @('Codex')
    Outputs = @(
        @{
            Target = 'AGENTS.md'
            Mode = 'ManagedBlock'
            BlockId = 'lean-changes'
        }
    )
}
