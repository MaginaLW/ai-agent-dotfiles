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
            '*.sqlite'
            '*.sqlite*'
            'volumes'
            '*.local.toml'
        )
    }

    Reasonix = @{
        HomeRelativeRoot = 'AppData/Roaming/reasonix'
        RepoRelativeRoot = 'reasonix'
        # config.toml / .env are machine-private (provider credentials, sessions,
        # workspace state) and must never be captured or deployed. skills/ is
        # managed by scripts/deploy-skills.ps1, not config-sync. commands/ can be added
        # here once repo-managed reasonix commands exist.
        PushItems = @('AGENTS.md', 'REASONIX.md')
        PullItems = @('AGENTS.md', 'REASONIX.md')
        ExcludedItems = @('config.toml', '.env', 'credentials', 'sessions', 'state', 'projects', 'stats', 'repair', 'crash-fatal', 'install-id', 'metrics-pending.json', 'desktop-*', 'global', 'global-workspace', 'commands', 'skills')
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
