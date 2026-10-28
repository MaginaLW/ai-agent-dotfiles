@{
    SchemaVersion = 1
    Name = 'full'
    Description = '全量基线环境（全部受管 skills，不做裁剪）'

    Skills = @{
        Claude = @(
            'boring-engineering',
            'brainstorming',
            'git-review',
            'meng-cmame-writing',
            'paper-polish',
            'subagent-driven-development',
            'systematic-debugging',
            'verification-before-completion',
            'writing-plans'
        )
        Codex = @(
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
            'subagent-driven-development',
            'systematic-debugging',
            'verification-before-completion',
            'writing-plans'
        )
        Reasonix = @()
        Zcode = @(
            'boring-engineering',
            'brainstorming',
            'git-review',
            'meng-cmame-writing',
            'paper-polish',
            'subagent-driven-development',
            'systematic-debugging',
            'verification-before-completion',
            'writing-plans'
        )
    }
}
