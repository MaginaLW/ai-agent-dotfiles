@{
    SchemaVersion = 1
    Id = 'review-prompt'
    Kind = 'CodexPrompt'
    TargetPlatforms = @('Codex')
    Requires = @()
    Conflicts = @()
    Outputs = @(
        @{
            Target = '.codex/prompts/review.md'
            Mode = 'DirectoryFiles'
            Source = 'content.md'
        }
    )
}
