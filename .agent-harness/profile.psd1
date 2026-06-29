@{
    SchemaVersion = 1
    Name = 'ai-agent-dotfiles'
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
