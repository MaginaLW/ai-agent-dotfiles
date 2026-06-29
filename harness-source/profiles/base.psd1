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
        Prompts = @()
        Commands = @()
        Agents = @()
        ClaudeSettings = @(
            'project-guards'
        )
        CodexAgents = @()
        McpTemplates = @()
    }

    Future = @{
        ProjectSkills = @()
    }
}
