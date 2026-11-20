@{
    SchemaVersion = 1
    Id = 'commit-summary'
    Kind = 'Prompt'
    TargetPlatforms = @('Codex')
    Outputs = @(
        @{
            Target = '.agent-harness/generated/prompts/commit-summary.md'
            Mode = 'GeneratedOnly'
        }
    )
}
