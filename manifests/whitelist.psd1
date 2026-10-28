@{
    Claude = @{
        HomeRelativeRoot = '.claude'
        RepoRelativeRoot = 'claude'
        PushItems = @(
            'settings.json'
            'CLAUDE.md'
            'commands'
            'agents'
            'output-styles'
        )
        PullItems = @(
            'settings.json'
            'CLAUDE.md'
            'commands'
            'agents'
            'output-styles'
        )
        ExcludedItems = @(
            '.credentials.json'
            'projects'
            'history*'
            'todos'
            'statsig'
            'shell-snapshots'
            'logs'
            'plugins/repos'
            'agent-memory'
            'ide'
            'downloads'
            'file-history'
            'local'
            '*.local.json'
        )
    }

    Codex = @{
        HomeRelativeRoot = '.codex'
        RepoRelativeRoot = 'codex'
        # config.toml is intentionally NOT synced: Codex co-mingles machine-private
        # state into it ([projects.*] path history, [mcp_servers.*] absolute exe
        # paths, [marketplaces.*] cache paths, notify path). It is unsafe to capture
        # (leaks private paths) and unsafe to deploy (would clobber local state).
        PushItems = @(
            'AGENTS.md'
            'prompts'
        )
        PullItems = @(
            'AGENTS.md'
            'prompts'
        )
        ExcludedItems = @(
            'config.toml'
            'auth.json'
            'sessions'
            'log'
            'cache'
            'history.jsonl'
            '*.sqlite*'
            'volumes'
            '*.local.toml'
        )
    }

    CommonExcludedItems = @(
        '.env'
        '.env.*'
        '*.key'
        '*.pem'
        '*.p12'
        '*.pfx'
        'id_rsa'
        'id_ed25519'
        '.ssh'
        'backup'
        'tmp'
        '*.bak'
        '*.tmp'
    )
}
