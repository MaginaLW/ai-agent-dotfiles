@{
    SchemaVersion = 1
    Name = 'full'
    Description = '全量基线环境（全部受管 skills，不做裁剪）'

    Skills = @{
        Codex = @(
            'brainstorming',
            'chatgpt-apps',
            'cli-creator',
            'coderabbit-review',
            'define-goal',
            'git-review',
            'grill-me',
            'meng-cmame-writing',
            'multimodal-generation',
            'paper-polish',
            'security-best-practices',
            'security-ownership-map',
            'security-threat-model',
            'session-learnings',
            'swarm',
            'systematic-debugging',
            'teamwork',
            'tool-scope',
            'verification-before-completion',
            'writing-plans'
        )
    }
}
