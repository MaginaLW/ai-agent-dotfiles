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
        PushItems = @(
            'config.toml'
            'AGENTS.md'
            'prompts'
        )
        PullItems = @(
            'config.toml'
            'AGENTS.md'
            'prompts'
        )
        ExcludedItems = @(
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

    Skills = @{
        SourceRoot = 'skills-source'
        SharedSource = 'skills-source/shared'
        ClaudeOnlySource = 'skills-source/claude-only'
        CodexOnlySource = 'skills-source/codex-only'
        GeneratedClaude = 'claude/skills'
        GeneratedCodex = 'codex/skills'
        InstallClaudeHomeRelative = '.claude/skills'
        InstallCodexHomeRelative = '.agents/skills'
        ManagedSkillsManifest = 'manifests/managed-skills.txt'
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
