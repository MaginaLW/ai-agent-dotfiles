@{
    DefaultTimeoutSeconds = 120
    SetupAndNonSuiteBudgetSeconds = 300
    MarginSeconds = 120
    Suites = @{
        'agent-dotfiles.tests.ps1' = 150
        'approved-runner.tests.ps1' = 900
        'canonical-hard-kill.tests.ps1' = 5400
        'canonical-hard-kill-reap-semantics.tests.ps1' = 60
        'canonical-command-result.tests.ps1' = 420
        'canonical-mutation-blockers.tests.ps1' = 600
        'canonical-mutation-parent-lease.tests.ps1' = 420
        'canonical-recovery.tests.ps1' = 1200
        'canonical-transaction-apply.tests.ps1' = 1800
        'canonical-transaction.tests.ps1' = 360
        'config-sync.tests.ps1' = 90
        'doctor.tests.ps1' = 60
        'home-authority.tests.ps1' = 180
        'live-concurrency.tests.ps1' = 300
        'root-claims-registry.tests.ps1' = 600
        'harness-env.tests.ps1' = 180
        'harness-multiplatform.tests.ps1' = 210
        'harness-profile.tests.ps1' = 90
        'skills-import.tests.ps1' = 1200
        'sync.tests.ps1' = 90
        'task-skills.tests.ps1' = 120
        'test-runner.tests.ps1' = 45
    }
}
