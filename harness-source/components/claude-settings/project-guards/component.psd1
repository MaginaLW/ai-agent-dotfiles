@{
    SchemaVersion = 1
    Id = 'project-guards'
    Kind = 'ClaudeSettings'
    TargetPlatforms = @('Claude')
    Outputs = @(
        @{
            Target = '.claude/settings.json'
            Mode = 'StructuredMerge'
            MergeStrategy = 'JsonObject'
        }
    )
}
