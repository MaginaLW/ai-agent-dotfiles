@{
    SchemaVersion = 1
    Id = 'commit-command'
    Kind = 'Command'
    TargetPlatforms = @('Claude')
    Requires = @()
    Conflicts = @()
    Outputs = @(
        @{
            Target = '.claude/commands/commit-summary.md'
            Mode = 'DirectoryFiles'
            Source = 'content.md'
        }
    )
}
