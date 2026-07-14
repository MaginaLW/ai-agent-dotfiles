@{
    SchemaVersion = 1
    Name = 'multi-platform'
    TargetPlatforms = @('Claude', 'Codex', 'OpenClaw')
    Extends = @('base')

    Components = @{
        Rules = @()
        Prompts = @()
        Commands = @('commit-command')
        Agents = @('claude-reviewer')
        ClaudeSettings = @()
        CodexAgents = @('review-prompt', 'codex-reviewer')
        McpTemplates = @()
        OpenClawConfigs = @('openclaw-project-defaults')
    }

    Future = @{
        ProjectSkills = @()
    }
}
