# Builds a distributable release of the standalone application without lazbuild.
#
# lazbuild cannot run inside the DSH sandbox (it needs to write %LOCALAPPDATA%\lazarus)
# and its project file is not the authority for the unit search path, so this script
# drives the FPC compiler directly with the same flags the LCL GUI target needs.
#
# Output:
#   dist\CheatEngineAgent.exe
#   dist\sqlite3.dll
#   dist\release-manifest.json   (sha256 + length for every shipped file)
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build\build-release.ps1 -Version 0.1.0

param(
    [string]$Version = 'development'
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$LazarusRoot = 'C:\lazarus'

$CompilerCandidates = @(@(
    (Get-Command fpc -ErrorAction SilentlyContinue).Source,
    (Join-Path $LazarusRoot 'fpc\3.2.2\bin\x86_64-win64\fpc.exe')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
if ($CompilerCandidates.Count -eq 0) {
    throw 'FPC was not found on PATH or at the Lazarus 3.2.2 default location.'
}
$Compiler = $CompilerCandidates[0]

$LclUnits = Join-Path $LazarusRoot 'lcl\units\x86_64-win64'
if (-not (Test-Path -LiteralPath (Join-Path $LclUnits 'forms.ppu'))) {
    throw "LCL compiled units were not found: $LclUnits"
}

$UnitOutput = Join-Path $ProjectRoot 'build\lazarus\x86_64-win64-release'
New-Item -ItemType Directory -Force -Path $UnitOutput | Out-Null

$DistDirectory = Join-Path $ProjectRoot 'dist'
New-Item -ItemType Directory -Force -Path $DistDirectory | Out-Null

$SourceDirectories = @(
    'src\app', 'src\contracts', 'src\core', 'src\core\state',
    'src\core\governance', 'src\core\execution', 'src\core\reverse',
    'src\core\save', 'src\core\ct-draft', 'src\core\command', 'src\core\capture',
    'src\core\profile', 'src\core\mapping', 'src\core\events', 'src\core\gcm',
    'src\core\ui', 'src\core\discovery',
    'src\domain\ce', 'src\domain\reverse', 'src\domain\save', 'src\domain\ct-draft',
    'src\domain\state-model', 'src\domain\profile', 'src\domain\ui-schema',
    'src\domain\gcm',
    'src\platform\ce', 'src\platform\windows', 'src\platform\save-fixtures',
    'src\knowledge\ct', 'src\llm', 'src\infrastructure',
    'src\infrastructure\windows', 'src\mcp', 'src\ui',
    'app\lazarus'
) | ForEach-Object { '-Fu' + (Join-Path $ProjectRoot $_) }

$CompilerArguments = @(
    '-B', '-Mobjfpc', '-Sh', '-Sa', '-O2', '-WG',
    ('-Fu' + $LclUnits),
    ('-Fu' + (Join-Path $LclUnits 'win32')),
    ('-Fu' + (Join-Path $LazarusRoot 'components\lazutils\lib\x86_64-win64')),
    ('-FU' + $UnitOutput),
    ('-FE' + $DistDirectory)
) + $SourceDirectories + @(Join-Path $ProjectRoot 'app\lazarus\cheat_engine_agent.lpr')

Write-Output "RELEASE_BUILD_COMPILER=$Compiler"
& $Compiler @CompilerArguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$Built = Join-Path $DistDirectory 'cheat_engine_agent.exe'
if (-not (Test-Path -LiteralPath $Built)) {
    throw "FPC did not create the expected executable: $Built"
}
$Executable = Join-Path $DistDirectory 'CheatEngineAgent.exe'
Move-Item -LiteralPath $Built -Destination $Executable -Force

$SqliteSource = Join-Path $ProjectRoot 'vendor\sqlite3\sqlite3.dll'
if (-not (Test-Path -LiteralPath $SqliteSource)) {
    throw "SQLite runtime dependency was not found: $SqliteSource"
}
Copy-Item -LiteralPath $SqliteSource -Destination (Join-Path $DistDirectory 'sqlite3.dll') -Force

$ManifestFiles = @()
foreach ($Name in @('CheatEngineAgent.exe', 'sqlite3.dll')) {
    $Path = Join-Path $DistDirectory $Name
    $Item = Get-Item -LiteralPath $Path
    $ManifestFiles += [ordered]@{
        name   = $Name
        length = $Item.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
    }
}

$Manifest = [ordered]@{
    schemaVersion   = 1
    version         = $Version
    channel         = 'prerelease'
    publishable     = $false
    compiler        = (& $Compiler -iV).Trim()
    target          = 'x86_64-win64'
    builtAt         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    signatureStatus = 'NotSigned'
    files           = $ManifestFiles
    boundaries      = @(
        'Unsigned development build: Windows SmartScreen will warn and no Authenticode chain is claimed.',
        'Real-game write support requires a separately verified game/version Codec and an authorized sample; it is not inferred from fixture tests.',
        'No AgentOS conformance level is claimed (see docs/agentos-conformance-transformation-plan.md).'
    )
}
$ManifestPath = Join-Path $DistDirectory 'release-manifest.json'
$Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8

$ExecutableItem = Get-Item -LiteralPath $Executable
Write-Output "RELEASE_BUILD=PASS version=$Version bytes=$($ExecutableItem.Length) sqlite_bytes=$((Get-Item (Join-Path $DistDirectory 'sqlite3.dll')).Length) executable=$Executable manifest=$ManifestPath"
