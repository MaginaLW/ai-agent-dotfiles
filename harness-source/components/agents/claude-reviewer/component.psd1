@{
    SchemaVersion = 1
    Id = 'claude-reviewer'
    Kind = 'ClaudeAgent'
    TargetPlatforms = @('Claude')
    Requires = @()
    Conflicts = @()
    Outputs = @(
        @{
            Target = '.claude/agents/reviewer.md'
            Mode = 'DirectoryFiles'
            Source = 'content.md'
        }
    )
}
