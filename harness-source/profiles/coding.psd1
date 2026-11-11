@{
    SchemaVersion = 1
    Name = 'coding'
    TargetPlatforms = @('Codex')

    Extends = @('base')

    Components = @{
        Prompts = @(
            'commit-summary'
        )
    }
}
