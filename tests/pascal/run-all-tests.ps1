$ErrorActionPreference = 'Continue'
$root = 'C:\Users\taitan666\Downloads\cheat-engine-7.5\cheat-engine-agnet'
$runner = Join-Path $root 'tests\pascal\run-test-program.ps1'

# Parameterized programs need a live target process, so they are driven by their
# own integration scripts instead of the generic single-program runner. Running
# them here would fail on missing command-line arguments rather than on a real
# defect, so they are reported as skipped and their integration script owns them.
$parameterized = @{
  'test_win32_child_process.pas' = 'tests\integration\test-win32-child-process.ps1'
}

$tests = Get-ChildItem -Path (Join-Path $root 'tests\pascal') -Filter 'test_*.pas' |
  Sort-Object Name
$pass = 0
$fail = 0
$skip = 0
$failed = @()
foreach ($t in $tests) {
  if ($parameterized.ContainsKey($t.Name)) {
    $skip++
    Write-Output "SKIP $($t.Name) :: parameterized, run $($parameterized[$t.Name])"
    continue
  }
  $out = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner `
    -Program $t.FullName 2>&1
  if ($out -match 'PASCAL_TEST=PASS') {
    $pass++
    Write-Output "PASS $($t.Name)"
  } else {
    $fail++
    $failed += $t.Name
    $reason = ($out | Select-String -Pattern 'Fatal|Error:|EAssertionFailed|Exception|Fatal:' |
      Select-Object -First 2) -join ' | '
    Write-Output "FAIL $($t.Name) :: $reason"
  }
}
Write-Output "SUMMARY pass=$pass fail=$fail skip=$skip total=$($tests.Count)"
if ($failed.Count -gt 0) { Write-Output ("FAILED_LIST=" + ($failed -join ',')) }
