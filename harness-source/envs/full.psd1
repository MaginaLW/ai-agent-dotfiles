@{
    SchemaVersion = 1
    Name = 'full'
    Description = '全量基线环境（全部受管 skills，不做裁剪）'

    Skills = @{
        Claude = @(
            'approval-feedback',
            'boring-engineering',
            'brainstorming',
            'git-review',
            'meng-cmame-writing',
            'paper-polish',
            'session-learnings',
            'subagent-driven-development',
            'systematic-debugging',
            'tool-scope',
            'verification-before-completion',
            'writing-plans'
        )
        Codex = @(
            'approval-feedback',
            'boring-engineering',
            'brainstorming',
            'chatgpt-apps',
            'cli-creator',
            'coderabbit-review',
            'define-goal',
            'git-review',
            'hatch-pet',
            'meng-cmame-writing',
            'paper-polish',
            'security-best-practices',
            'security-ownership-map',
            'security-threat-model',
            'session-learnings',
            'subagent-driven-development',
            'systematic-debugging',
            'tool-scope',
            'verification-before-completion',
            'writing-plans'
        )
        Zcode = @(
            'approval-feedback',
            'boring-engineering',
            'brainstorming',
            'git-review',
            'meng-cmame-writing',
            'paper-polish',
            'session-learnings',
            'subagent-driven-development',
            'systematic-debugging',
            'tool-scope',
            'verification-before-completion',
            'writing-plans'
        )
    }
}
