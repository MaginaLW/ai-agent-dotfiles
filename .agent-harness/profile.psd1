@{
    SchemaVersion = 1
    Name = 'ai-agent-dotfiles'
    TargetPlatforms = @('Claude', 'Codex')

    Extends = @('coding')

    RequiredEnv = 'work'

    Components = @{
        Rules = @()
        Prompts = @()
        Commands = @()
        Agents = @()
        ClaudeSettings = @()
        CodexAgents = @()
    }

    Future = @{
        ProjectSkills = @()
    }
}
