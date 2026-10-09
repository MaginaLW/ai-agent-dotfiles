@{
    DefaultTimeoutSeconds = 120
    SetupAndNonSuiteBudgetSeconds = 300
    MarginSeconds = 120
    Suites = @{
        'agent-dotfiles.tests.ps1' = 150
        'config-sync.tests.ps1' = 90
        'deploy-skills.tests.ps1' = 120
        'doctor.tests.ps1' = 60
        'guide-examples.tests.ps1' = 60
        'powershell-syntax-gate.tests.ps1' = 90
        'repository-policy.tests.ps1' = 120
        'harness-multiplatform.tests.ps1' = 120
        'harness-profile.tests.ps1' = 120
        'scan-secrets.tests.ps1' = 120
        'skills-import.tests.ps1' = 300
        'test-runner.tests.ps1' = 60
    }
}
