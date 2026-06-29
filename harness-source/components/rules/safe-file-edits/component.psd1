@{
    SchemaVersion = 1
    Id = 'safe-file-edits'
    Kind = 'Rule'
    TargetPlatforms = @('Claude', 'Codex')
    Requires = @()
    Conflicts = @()
    Outputs = @(
        @{
            Target = 'AGENTS.md'
            Mode = 'ManagedBlock'
            BlockId = 'safe-file-edits'
        }
    )
}
