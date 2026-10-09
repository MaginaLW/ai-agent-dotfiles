@{
    SchemaVersion = 1
    Name = 'full'
    Description = '全量基线环境（等于当前全部受管 skills；激活为零裁剪）'
    Profile = 'coding'

    Skills = @{
        Claude = @(
            'boring-engineering',
            'brainstorming',
            'git-review',
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
            'paper-polish',
            'security-best-practices',
            'security-ownership-map',
            'security-threat-model',
            'subagent-driven-development',
            'systematic-debugging',
            'verification-before-completion',
            'writing-plans'
        )
        Reasonix = @(
            'boring-engineering',
            'brainstorming',
            'git-review',
            'paper-polish',
            'subagent-driven-development',
            'systematic-debugging',
            'verification-before-completion',
            'writing-plans'
        )
    }
}
