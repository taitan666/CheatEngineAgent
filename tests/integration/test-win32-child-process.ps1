$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$BuildOutput = & (Join-Path $ProjectRoot 'tests\fixtures\process\build-self-target.ps1')
$BuildOutput | Write-Output
$BuildLine = $BuildOutput | Where-Object { $_ -like 'CEA_SELF_TARGET_BUILD=PASS*' }
if (-not $BuildLine) { throw 'Self-target build did not return its executable' }
$TargetExecutable = ($BuildLine -split 'executable=', 2)[1]
$PluginLine = $BuildOutput | Where-Object { $_ -like 'CEA_SELF_TARGET_PLUGIN_BUILD=PASS*' }
if (-not $PluginLine) { throw 'Self-target build did not return its plugin' }
$TargetPlugin = ($PluginLine -split 'plugin=', 2)[1]
$LoadMarker = Join-Path ([IO.Path]::GetTempPath()) `
    ('cea-load-plugin-' + [guid]::NewGuid().ToString('N') + '.marker')

$StartInfo = [Diagnostics.ProcessStartInfo]::new()
$StartInfo.FileName = $TargetExecutable
$StartInfo.Arguments = '"' + $TargetPlugin + '" "' + $LoadMarker + '"'
$StartInfo.UseShellExecute = $false
$StartInfo.RedirectStandardOutput = $true
$StartInfo.RedirectStandardInput = $true
$StartInfo.CreateNoWindow = $true
$Target = [Diagnostics.Process]::Start($StartInfo)
try {
    $HandshakeText = $Target.StandardOutput.ReadLine()
    $Handshake = $HandshakeText | ConvertFrom-Json
    if ($Handshake.pid -ne $Target.Id) { throw 'Self-target PID mismatch' }
    & (Join-Path $ProjectRoot 'tests\pascal\run-test-program.ps1') `
        -Program (Join-Path $ProjectRoot 'tests\pascal\test_win32_child_process.pas') `
        -Arguments @([string]$Handshake.pid, [string]$Handshake.address,
            [string]$Handshake.size, $LoadMarker)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    if (-not $Target.HasExited) {
        $Target.StandardInput.WriteLine('exit')
        $Target.StandardInput.Close()
        if (-not $Target.WaitForExit(5000)) {
            Stop-Process -Id $Target.Id
        }
    }
    Remove-Item -LiteralPath $LoadMarker -Force -ErrorAction SilentlyContinue
}

Write-Output 'WIN32_CHILD_PROCESS_INTEGRATION=PASS'
