@{
    SchemaVersion = 1
    Id = 'opencode-reviewer'
    Kind = 'OpenCodeAgent'
    TargetPlatforms = @('OpenCode')
    Requires = @()
    Conflicts = @()
    Outputs = @(
        @{
            Target = '.opencode/agents/reviewer.md'
            Mode = 'DirectoryFiles'
            Source = 'content.md'
        }
    )
}