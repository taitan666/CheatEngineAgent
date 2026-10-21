$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Compiler = 'C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
$Source = Join-Path $PSScriptRoot 'cea_self_target.pas'
$PluginSource = Join-Path $PSScriptRoot 'cea_self_target_plugin.pas'
$OutputDirectory = Join-Path $env:TEMP ('cea-self-target-' + [guid]::NewGuid().ToString('N'))

if (-not (Test-Path -LiteralPath $Compiler)) {
    throw "FPC was not found: $Compiler"
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
& $Compiler -Mobjfpc -Sh ('-FU' + $OutputDirectory) `
    ('-FE' + $OutputDirectory) $Source
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $Compiler -Mobjfpc -Sh ('-FU' + $OutputDirectory) `
    ('-FE' + $OutputDirectory) $PluginSource
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$Executable = Join-Path $OutputDirectory 'cea_self_target.exe'
if (-not (Test-Path -LiteralPath $Executable)) {
    throw "Self-target executable was not created: $Executable"
}
$Plugin = Join-Path $OutputDirectory 'cea_self_target_plugin.dll'
if (-not (Test-Path -LiteralPath $Plugin)) {
    throw "Self-target plugin was not created: $Plugin"
}
Write-Output "CEA_SELF_TARGET_BUILD=PASS executable=$Executable"
Write-Output "CEA_SELF_TARGET_PLUGIN_BUILD=PASS plugin=$Plugin"
