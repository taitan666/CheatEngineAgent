$ErrorActionPreference = 'Stop'

# Compiles the Lazarus desktop application (app\lazarus\cheat_engine_agent.lpr)
# with the LCL, without launching lazbuild. This is the 1H verification gate:
# it proves the player-level workspace in cea_main_form.pas compiles.
#
# lazbuild itself cannot run inside the DSH sandbox (it needs to write
# %LOCALAPPDATA%\lazarus), so this script drives ppcx64 directly.

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$LazarusRoot = 'C:\lazarus'
$CompilerCandidates = @(@(
    (Get-Command fpc -ErrorAction SilentlyContinue).Source,
    (Join-Path $LazarusRoot 'fpc\3.2.2\bin\x86_64-win64\fpc.exe')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)

if ($CompilerCandidates.Count -eq 0) {
    throw 'FPC was not found on PATH or at the Lazarus 2.2.2 default location.'
}
$Compiler = $CompilerCandidates[0]

$LclUnits = Join-Path $LazarusRoot 'lcl\units\x86_64-win64'
if (-not (Test-Path -LiteralPath (Join-Path $LclUnits 'forms.ppu'))) {
    throw "LCL compiled units were not found: $LclUnits"
}

$OutputDirectory = Join-Path $env:TEMP ('cea-fpc-app-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null

$SourceDirectories = @(
    'src\app', 'src\contracts', 'src\core', 'src\core\state',
    'src\core\governance', 'src\core\execution', 'src\core\reverse',
    'src\domain\ce',
    'src\domain\reverse', 'src\domain\save', 'src\domain\ct-draft',
    'src\domain\state-model', 'src\domain\profile', 'src\domain\ui-schema',
    'src\domain\gcm',
    'src\core\save', 'src\core\ct-draft', 'src\core\command', 'src\core\capture',
    'src\core\profile', 'src\core\mapping', 'src\core\events', 'src\core\gcm', 'src\core\ui',
    'src\core\discovery',
    'src\platform\ce',
    'src\platform\windows', 'src\platform\save-fixtures',
    'src\knowledge\ct', 'src\llm', 'src\infrastructure',
    'src\infrastructure\windows', 'src\mcp', 'src\ui',
    'app\lazarus'
) | ForEach-Object { '-Fu' + (Join-Path $ProjectRoot $_) }

$CompilerArguments = @(
    '-B', '-Mobjfpc', '-Sh', '-Sa',
    ('-Fu' + $LclUnits),
    ('-Fu' + (Join-Path $LclUnits 'win32')),
    ('-Fu' + (Join-Path $LazarusRoot 'components\lazutils\lib\x86_64-win64')),
    ('-FU' + $OutputDirectory),
    ('-FE' + $OutputDirectory)
) + $SourceDirectories + @(Join-Path $ProjectRoot 'app\lazarus\cheat_engine_agent.lpr')

& $Compiler @CompilerArguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$Executable = Join-Path $OutputDirectory 'cheat_engine_agent.exe'
if (-not (Test-Path -LiteralPath $Executable)) {
    throw "FPC did not create the expected executable: $Executable"
}

$PersistentBuildRoot = Join-Path $ProjectRoot 'build'
$LeakedArtifacts = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File |
    Where-Object {
        ($_.Extension -in '.o', '.ppu' -or $_.Name -eq 'cheat_engine_agent.exe') -and
        -not $_.FullName.StartsWith($PersistentBuildRoot,
            [StringComparison]::OrdinalIgnoreCase)
    })
if ($LeakedArtifacts.Count -gt 0) {
    throw "Build artifacts leaked into the project tree: $($LeakedArtifacts.FullName -join ', ')"
}

Write-Output "PASCAL_APP_COMPILE=PASS compiler=$(& $Compiler -iV) output=$Executable"
