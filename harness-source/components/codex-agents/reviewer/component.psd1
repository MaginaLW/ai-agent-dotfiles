@{
    SchemaVersion = 1
    Id = 'codex-reviewer'
    Kind = 'CodexAgent'
    TargetPlatforms = @('Codex')
    Requires = @()
    Conflicts = @()
    Outputs = @(
        @{
            Target = '.codex/agents/reviewer.md'
            Mode = 'DirectoryFiles'
            Source = 'content.md'
        }
    )
}
