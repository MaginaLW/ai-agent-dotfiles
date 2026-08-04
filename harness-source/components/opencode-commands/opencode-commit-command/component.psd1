@{
    SchemaVersion = 1
    Id = 'opencode-commit-command'
    Kind = 'OpenCodeCommand'
    TargetPlatforms = @('OpenCode')
    Requires = @()
    Conflicts = @()
    Outputs = @(
        @{
            Target = '.opencode/commands/commit-summary.md'
            Mode = 'DirectoryFiles'
            Source = 'content.md'
        }
    )
}
