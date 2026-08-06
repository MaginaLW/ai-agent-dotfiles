@{
    SchemaVersion = 1
    Name = 'multi-platform'
    TargetPlatforms = @('Claude', 'Codex')
    Extends = @('base')

    Components = @{
        Rules = @()
        Prompts = @()
        Commands = @('commit-command')
        Agents = @('claude-reviewer')
        ClaudeSettings = @()
        CodexAgents = @('review-prompt', 'codex-reviewer')
        McpTemplates = @()
    }

    Future = @{
        ProjectSkills = @()
    }
}
