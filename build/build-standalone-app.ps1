$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$LazBuild = 'C:\lazarus\lazbuild.exe'
$FpcBin = 'C:\lazarus\fpc\3.2.2\bin\x86_64-win64'
$ProjectFile = Join-Path $ProjectRoot 'app\lazarus\cheat_engine_agent.lpi'
$Executable = Join-Path $ProjectRoot 'dist\CheatEngineAgent.exe'
$SqliteSource = Join-Path $ProjectRoot 'vendor\sqlite3\sqlite3.dll'
$SqliteDestination = Join-Path $ProjectRoot 'dist\sqlite3.dll'

if (-not (Test-Path -LiteralPath $LazBuild)) {
    throw "Lazarus build tool was not found: $LazBuild"
}
$env:PATH = $FpcBin + ';' + $env:PATH
& $LazBuild -B $ProjectFile
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if (-not (Test-Path -LiteralPath $Executable)) {
    throw "Standalone application was not created: $Executable"
}
if (-not (Test-Path -LiteralPath $SqliteSource)) {
    throw "SQLite runtime dependency was not found: $SqliteSource"
}
Copy-Item -LiteralPath $SqliteSource -Destination $SqliteDestination -Force
& (Join-Path $ProjectRoot 'tools\release\new-release-manifest.ps1') -DistDirectory (Join-Path $ProjectRoot 'dist') -ManifestPath (Join-Path $ProjectRoot 'dist\internal-release-manifest.json') -Version 'development' -Channel internal
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$BuiltFile = Get-Item -LiteralPath $Executable
$SqliteFile = Get-Item -LiteralPath $SqliteDestination
Write-Output "STANDALONE_APP_BUILD=PASS bytes=$($BuiltFile.Length) sqlite_bytes=$($SqliteFile.Length) executable=$($BuiltFile.FullName)"
