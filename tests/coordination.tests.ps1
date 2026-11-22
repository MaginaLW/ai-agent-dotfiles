#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
    & python -B -m unittest coordination_protocol_test swarm_mailbox_test swarm_run_test swarm_upstream_test teamwork_gsd_test
} finally {
    Pop-Location
}
exit $LASTEXITCODE
