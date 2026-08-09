@{
    SchemaVersion = 1
    Name = 'coding'
    TargetPlatforms = @('Claude', 'Codex')

    Extends = @('base')

    Components = @{
        Rules = @()
        Prompts = @(
            'commit-summary'
        )
        Commands = @()
        Agents = @()
        ClaudeSettings = @()
        CodexAgents = @()
    }

    Future = @{
        ProjectSkills = @()
    }
}
