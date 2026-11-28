@{
    SchemaVersion = 1
    NativeValidationComponents = @('agents', 'hooks', 'mcpServers', 'rules', 'sidecars', 'skills')
    ManagedPlugin = @{
        Name = 'ai-agent-dotfiles'
        DisplayName = 'AI Agent Dotfiles'
        Version = '0.5.0'
        Description = 'Reviewed skills maintained by this repository.'
        Skills = @(
            'brainstorming',
            'git-review',
            'meng-cmame-writing',
            'multimodal-generation',
            'paper-polish',
            'session-learnings',
            'systematic-debugging',
            'verification-before-completion',
            'writing-plans'
        )
    }
    ExternalPlugins = @(
        @{
            Name = 'unity'
            Source = 'antigravity-plugins-partners'
            Version = 'ANY'
            Enabled = $true
        }
    )
}
