@{
    # Seconds per suite. scripts/run-tests.ps1 refuses to start unless every
    # tests/*.tests.ps1 suite has exactly one entry here.
    Suites = @{
        'agent-dotfiles.tests.ps1' = 150
        'config-sync.tests.ps1' = 90
        'deploy-skills.tests.ps1' = 120
        'doctor.tests.ps1' = 60
        'powershell-syntax-gate.tests.ps1' = 90
        'repository-policy.tests.ps1' = 120
        'harness-multiplatform.tests.ps1' = 120
        'harness-profile.tests.ps1' = 120
        'scan-secrets.tests.ps1' = 120
        'promote-skill.tests.ps1' = 60
        'test-runner.tests.ps1' = 60
    }
}
