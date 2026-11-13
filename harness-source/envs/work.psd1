@{
    SchemaVersion = 1
    Name = 'work'
    Description = '日常编码、审查与科研写作环境；其他专用 skills 按需选择'

    Skills = @{
        Claude = @()
        Codex = @(
            'antigravity-delegation',
            'approval-feedback',
            'boring-engineering',
            'git-review',
            'meng-cmame-writing',
            'paper-polish',
            'session-learnings',
            'subagent-driven-development',
            'systematic-debugging',
            'tool-scope'
        )
        Zcode = @(
            'approval-feedback',
            'boring-engineering',
            'git-review',
            'meng-cmame-writing',
            'paper-polish',
            'session-learnings',
            'systematic-debugging',
            'tool-scope'
        )
    }
}
