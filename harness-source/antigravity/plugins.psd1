@{
    SchemaVersion = 1
    NativeValidationComponents = @('agents', 'hooks', 'mcpServers', 'rules', 'sidecars', 'skills')
    ManagedPlugin = @{
        Name = 'ai-agent-dotfiles'
        DisplayName = 'AI Agent Dotfiles'
        Version = '0.4.0'
        Description = 'Reviewed skills maintained by this repository.'
        Skills = @(
            'git-review',
            'multimodal-generation',
            'systematic-debugging',
            'verification-before-completion'
        )
    }
    ExternalPlugins = @()
}
