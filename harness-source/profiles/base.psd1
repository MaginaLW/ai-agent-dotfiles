@{
    SchemaVersion = 1
    Name = 'base'
    TargetPlatforms = @('Claude', 'Codex')

    Extends = @()

    Components = @{
        Rules = @(
            'safe-file-edits',
            'no-generated-output-edits'
        )
        ClaudeSettings = @(
            'project-guards'
        )
    }
}
