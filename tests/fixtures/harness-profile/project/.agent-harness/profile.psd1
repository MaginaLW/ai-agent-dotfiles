@{
    SchemaVersion = 1
    Name = 'fixture-harness-profile'
    TargetPlatforms = @('Claude', 'Codex')

    Extends = @('coding')

    Components = @{
        Rules = @()
        Prompts = @()
        Commands = @()
        Agents = @()
        ClaudeSettings = @()
        CodexAgents = @()
        McpTemplates = @()
    }

    Future = @{
        ProjectSkills = @()
    }
}
