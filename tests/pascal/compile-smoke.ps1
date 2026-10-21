$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$CompilerCandidates = @(@(
    (Get-Command fpc -ErrorAction SilentlyContinue).Source,
    'C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)

if ($CompilerCandidates.Count -eq 0) {
    throw 'FPC was not found on PATH or at the Lazarus 2.2.2 default location.'
}

$Compiler = $CompilerCandidates[0]
$OutputDirectory = Join-Path $env:TEMP ('cea-fpc-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null

$UnitDirectories = @(
    'src\app', 'src\contracts', 'src\core', 'src\core\state',
    'src\core\governance', 'src\core\execution', 'src\core\reverse',
    'src\domain\ce',
    'src\domain\reverse', 'src\domain\save', 'src\domain\ct-draft',
    'src\domain\state-model', 'src\domain\profile', 'src\domain\ui-schema',
    'src\domain\gcm',
    'src\core\save', 'src\core\ct-draft', 'src\core\command', 'src\core\capture',
    'src\core\profile', 'src\core\mapping', 'src\core\events', 'src\core\gcm',
    'src\core\ui',
    'src\core\discovery',
    'src\platform\ce',
    'src\platform\windows', 'src\platform\save-fixtures',
    'src\knowledge\ct', 'src\llm', 'src\infrastructure',
    'src\infrastructure\windows', 'src\mcp', 'src\ui'
) | ForEach-Object { '-Fu' + (Join-Path $ProjectRoot $_) }

$CompilerArguments = @(
    '-B', '-Mobjfpc', '-Sh', '-Sa',
    ('-Fu' + (Join-Path $ProjectRoot 'tests\pascal')),
    ('-FU' + $OutputDirectory),
    ('-FE' + $OutputDirectory)
) + $UnitDirectories + @(Join-Path $ProjectRoot 'tests\pascal\compile_smoke.pas')

& $Compiler @CompilerArguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$Executable = Join-Path $OutputDirectory 'compile_smoke.exe'
if (-not (Test-Path -LiteralPath $Executable)) {
    throw "FPC did not create the expected executable: $Executable"
}

& $Executable
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$PersistentBuildRoot = Join-Path $ProjectRoot 'build'
$LeakedArtifacts = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File |
    Where-Object {
        ($_.Extension -in '.o', '.ppu' -or $_.Name -eq 'compile_smoke.exe') -and
        -not $_.FullName.StartsWith($PersistentBuildRoot,
            [StringComparison]::OrdinalIgnoreCase)
    })
if ($LeakedArtifacts.Count -gt 0) {
    throw "Build artifacts leaked into the project tree: $($LeakedArtifacts.FullName -join ', ')"
}

Write-Output "PASCAL_COMPILE_SMOKE=PASS compiler=$(& $Compiler -iV) output=$Executable"
