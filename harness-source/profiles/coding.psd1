@{
    SchemaVersion = 1
    Name = 'coding'
    TargetPlatforms = @('Claude', 'Codex')

    Extends = @('base')

    Components = @{
        Prompts = @(
            'commit-summary'
        )
    }
}
