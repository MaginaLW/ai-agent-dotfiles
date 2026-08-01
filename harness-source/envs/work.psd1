@{
    SchemaVersion = 1
    Name = 'work'
    Description = '日常编码环境'
    Profile = 'coding'

    Skills = @{
        Claude = @(
            'git-review',
            'systematic-debugging'
        )
        Codex = @(
            'brainstorming',
            'git-review',
            'systematic-debugging',
            'code-review',
            'writing-plans'
        )
    }

    McpTemplates = @('github')
}
