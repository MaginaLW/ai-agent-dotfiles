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

    OpenCode = @{
        HomeRelativeRoot = '.config/opencode'
        RepoRelativeRoot = 'opencode'
        # The main opencode.json(c) may contain provider, MCP, file, or machine
        # specific settings. Manage only portable instruction/command/agent files.
        PushItems = @('AGENTS.md', 'commands', 'agents')
        PullItems = @('AGENTS.md', 'commands', 'agents')
        ExcludedItems = @('opencode.json', 'opencode.jsonc', 'auth.json', 'cache', 'log', 'storage', 'node_modules', 'plugins')
    }

    Skills = @{
        SourceRoot = 'skills-source'
        SharedSource = 'skills-source/shared'
        ClaudeOnlySource = 'skills-source/claude-only'
        CodexOnlySource = 'skills-source/codex-only'
        OpenCodeOnlySource = 'skills-source/opencode-only'
        GeneratedClaude = 'claude/skills'
        GeneratedCodex = 'codex/skills'
        GeneratedOpenCode = 'opencode/skills'
        InstallClaudeHomeRelative = '.claude/skills'
        InstallCodexHomeRelative = '.agents/skills'
        InstallOpenCodeHomeRelative = '.config/opencode/skills'
        ManagedSkillsManifest = 'manifests/managed-skills.txt'
        ManagedSkillsClaudeManifest = 'manifests/managed-skills.claude.txt'
        ManagedSkillsCodexManifest = 'manifests/managed-skills.codex.txt'
        ManagedSkillsOpenCodeManifest = 'manifests/managed-skills.opencode.txt'
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
