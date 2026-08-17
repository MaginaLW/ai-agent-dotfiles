@{
    DefaultTimeoutSeconds = 5
    SetupAndNonSuiteBudgetSeconds = 1
    MarginSeconds = 1
    Suites = @{
        'output-cap.tests.ps1' = 20
        'pipe-holder.tests.ps1' = 10
        'timeout-parent.tests.ps1' = 8
    }
}
