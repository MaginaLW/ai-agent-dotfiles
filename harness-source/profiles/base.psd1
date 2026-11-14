@{
    SchemaVersion = 1
    Name = 'base'
    TargetPlatforms = @('Codex')

    Extends = @()

    Components = @{
        Rules = @(
            'safe-file-edits',
            'lean-changes',
            'no-generated-output-edits'
        )
    }
}
