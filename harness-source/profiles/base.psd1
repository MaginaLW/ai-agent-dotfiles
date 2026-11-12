@{
    SchemaVersion = 1
    Name = 'base'
    TargetPlatforms = @('Codex')

    Extends = @()

    Components = @{
        Rules = @(
            'safe-file-edits',
            'no-generated-output-edits'
        )
    }
}
