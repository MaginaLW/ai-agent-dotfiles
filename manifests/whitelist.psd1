@{
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

    Antigravity = @{
        HomeRelativeRoot = '.gemini/config'
        RepoRelativeRoot = 'antigravity'
        # Runtime settings, plugin caches, project state and machine-local files stay outside sync scope.
        # mcp_config.json is managed per-entry by mcp-sync, remains outside config-sync, and is ignored by .gitignore.
        PushItems = @(
            'AGENTS.md'
        )
        PullItems = @(
            'AGENTS.md'
        )
        ExcludedItems = @(
            'config.json'
            'import_manifest.json'
            'node_modules'
            'plugins'
            'projects'
            'sidecars'
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
