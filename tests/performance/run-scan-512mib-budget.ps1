$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Program = Join-Path $PSScriptRoot 'test_scan_512mib_budget.pas'

& (Join-Path $ProjectRoot 'tests\pascal\run-test-program.ps1') -Program $Program
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
