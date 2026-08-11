@{
    DefaultTimeoutSeconds = 120
    SetupAndNonSuiteBudgetSeconds = 300
    MarginSeconds = 120
    Suites = @{
        'agent-dotfiles.tests.ps1' = 150
        'approved-runner.tests.ps1' = 210
        'config-sync.tests.ps1' = 90
        'doctor.tests.ps1' = 60
        'harness-env.tests.ps1' = 180
        'harness-multiplatform.tests.ps1' = 210
        'harness-profile.tests.ps1' = 90
        'skills-import.tests.ps1' = 45
        'sync.tests.ps1' = 90
        'task-skills.tests.ps1' = 120
        'test-runner.tests.ps1' = 45
    }
}
