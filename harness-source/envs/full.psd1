@{
    SchemaVersion = 1
    Name = 'full'
    Description = '全量基线环境（等于当前全部受管 skills；激活为零裁剪）'
    Profile = 'coding'

    Skills = @{
        Claude = @(
            'brainstorming',
            'codex-cli-runtime',
            'codex-result-handling',
            'control-chrome',
            'git-review',
            'gpt-5-4-prompting',
            'latex-tectonic',
            'paper-polish',
            'path-risk',
            'placeholder-ok',
            'subagent-driven-development',
            'systematic-debugging',
            'verification-before-completion',
            'writing-plans',
            'writing-skills'
        )
        Codex = @(
            'brainstorming',
            'chatgpt-apps',
            'cli-creator',
            'code-review',
            'codex-repo-maintainer',
            'control-chrome',
            'control-in-app-browser',
            'define-goal',
            'git-review',
            'google-drive-comments',
            'hatch-pet',
            'latex-tectonic',
            'paper-polish',
            'path-risk',
            'placeholder-ok',
            'security-best-practices',
            'security-ownership-map',
            'security-threat-model',
            'subagent-driven-development',
            'systematic-debugging',
            'verification-before-completion',
            'writing-plans',
            'writing-skills'
        )
        Reasonix = @(
            'brainstorming',
            'control-chrome',
            'git-review',
            'latex-tectonic',
            'paper-polish',
            'path-risk',
            'placeholder-ok',
            'subagent-driven-development',
            'systematic-debugging',
            'verification-before-completion',
            'writing-plans',
            'writing-skills'
        )
    }

    McpTemplates = @('github')
}
