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

    OpenClaw = @{
        HomeRelativeRoot = '.openclaw'
        RepoRelativeRoot = 'openclaw'
        PushItems = @('plugins/managed-plugins.json')
        PullItems = @('plugins/managed-plugins.json')
        ExcludedItems = @('identity', 'credentials', 'devices', 'sessions', 'logs', 'cache', 'npm', 'plugins/installs.json', 'exec-approvals.json', 'node.json', 'auth-profiles.json')
    }

    Skills = @{
        SourceRoot = 'skills-source'
        SharedSource = 'skills-source/shared'
        ClaudeOnlySource = 'skills-source/claude-only'
        CodexOnlySource = 'skills-source/codex-only'
        OpenClawOnlySource = 'skills-source/openclaw-only'
        GeneratedClaude = 'claude/skills'
        GeneratedCodex = 'codex/skills'
        GeneratedOpenClaw = 'openclaw/skills'
        InstallClaudeHomeRelative = '.claude/skills'
        InstallCodexHomeRelative = '.agents/skills'
        InstallOpenClawHomeRelative = '.openclaw/skills'
        ManagedSkillsManifest = 'manifests/managed-skills.txt'
        ManagedSkillsClaudeManifest = 'manifests/managed-skills.claude.txt'
        ManagedSkillsCodexManifest = 'manifests/managed-skills.codex.txt'
        ManagedSkillsOpenClawManifest = 'manifests/managed-skills.openclaw.txt'
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
