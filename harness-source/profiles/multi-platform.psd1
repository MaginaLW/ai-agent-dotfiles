@{
    SchemaVersion = 1
    Name = 'multi-platform'
    TargetPlatforms = @('Claude', 'Codex', 'OpenCode')
    Extends = @('base')

    Components = @{
        Rules = @()
        Prompts = @()
        Commands = @('commit-command')
        Agents = @('claude-reviewer')
        ClaudeSettings = @()
        CodexAgents = @('review-prompt', 'codex-reviewer')
        McpTemplates = @()
        OpenCodeCommands = @('opencode-commit-command')
        OpenCodeAgents = @('opencode-reviewer')
    }

    Future = @{
        ProjectSkills = @()
    }
}
