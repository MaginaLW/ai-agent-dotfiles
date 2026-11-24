@{
    # Seconds per suite. scripts/run-tests.ps1 refuses to start unless every
    # tests/*.tests.ps1 suite has exactly one entry here.
    Suites = @{
        'agent-dotfiles.tests.ps1' = 140
        'antigravity-plugins.tests.ps1' = 75
        'build-skills.tests.ps1' = 30
        'config-sync.tests.ps1' = 180
        'coordination.tests.ps1' = 90
        'deploy.tests.ps1' = 100
        'deploy-skills.tests.ps1' = 110
        'doctor.tests.ps1' = 30
        'mcp-sync.tests.ps1' = 45
        'pinned-tool.tests.ps1' = 30
        'powershell-syntax-gate.tests.ps1' = 45
        'repository-policy.tests.ps1' = 30
        'harness-profile.tests.ps1' = 140
        'scan-secrets.tests.ps1' = 90
        'promote-skill.tests.ps1' = 60
        'test-runner.tests.ps1' = 60
    }
}
