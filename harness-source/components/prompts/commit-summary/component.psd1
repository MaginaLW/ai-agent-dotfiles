@{
    SchemaVersion = 1
    Id = 'commit-summary'
    Kind = 'Prompt'
    TargetPlatforms = @('Claude', 'Codex')
    Outputs = @(
        @{
            Target = '.agent-harness/generated/prompts/commit-summary.md'
            Mode = 'GeneratedOnly'
        }
    )
}
