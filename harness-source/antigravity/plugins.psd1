@{
    SchemaVersion = 1
    NativeValidationComponents = @('agents', 'hooks', 'mcpServers', 'rules', 'sidecars', 'skills')
    ManagedPlugin = @{
        Name = 'ai-agent-dotfiles'
        DisplayName = 'AI Agent Dotfiles'
        Version = '0.4.1'
        Description = 'Reviewed skills maintained by this repository.'
        Skills = @(
            'git-review',
            'multimodal-generation',
            'systematic-debugging',
            'verification-before-completion'
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
