param(
    [Parameter(Mandatory = $true)]
    [string]$Program,
    [string[]]$Arguments = @()
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ProgramPath = if (Test-Path -LiteralPath $Program) {
    (Resolve-Path -LiteralPath $Program).Path
} else {
    # A relative -Program is resolved against the project root so callers do
    # not depend on the shell's current directory.
    (Resolve-Path -LiteralPath (Join-Path $ProjectRoot $Program)).Path
}
$CompilerCandidates = @(@(
    (Get-Command fpc -ErrorAction SilentlyContinue).Source,
    'C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)

if ($CompilerCandidates.Count -eq 0) {
    throw 'FPC was not found on PATH or at the Lazarus 2.2.2 default location.'
}

$Compiler = $CompilerCandidates[0]
$OutputDirectory = Join-Path $env:TEMP ('cea-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null

$UnitDirectories = @(
    'src\app', 'src\contracts', 'src\core', 'src\core\state', 'src\core\governance',
    'src\core\execution', 'src\core\reverse', 'src\domain\ce',
    'src\domain\reverse', 'src\domain\save', 'src\domain\ct-draft',
    'src\domain\state-model', 'src\domain\profile', 'src\domain\ui-schema',
    'src\domain\gcm',
    'src\core\save', 'src\core\ct-draft', 'src\core\command', 'src\core\capture',
    'src\core\profile', 'src\core\mapping', 'src\core\events', 'src\core\gcm', 'src\core\ui',
    'src\core\discovery',
    'src\knowledge\ct', 'src\llm', 'src\platform\ce',
    'src\platform\windows', 'src\platform\save-fixtures',
    'src\infrastructure', 'src\infrastructure\windows', 'src\mcp', 'src\ui',
    'tests\pascal', 'tests\pascal\fakes',
    'tests\fakes', 'tests\integration'
) | ForEach-Object { '-Fu' + (Join-Path $ProjectRoot $_) }

$CompilerArguments = @(
    '-B', '-Mobjfpc', '-Sh', '-Sa',
    ('-FU' + $OutputDirectory),
    ('-FE' + $OutputDirectory)
) + $UnitDirectories + @($ProgramPath)

& $Compiler @CompilerArguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$ExecutableName = [System.IO.Path]::GetFileNameWithoutExtension($ProgramPath) + '.exe'
$Executable = Join-Path $OutputDirectory $ExecutableName
if (-not (Test-Path -LiteralPath $Executable)) {
    throw "FPC did not create the expected executable: $Executable"
}

$DependencyDirectory = Join-Path $ProjectRoot 'vendor\sqlite3'
$PreviousPath = $env:PATH
Push-Location $ProjectRoot
try {
    if (Test-Path -LiteralPath $DependencyDirectory) {
        $env:PATH = $DependencyDirectory + [System.IO.Path]::PathSeparator + $env:PATH
    }
    & $Executable @Arguments
    $ProgramExitCode = $LASTEXITCODE
} finally {
    $env:PATH = $PreviousPath
    Pop-Location
}
if ($ProgramExitCode -ne 0) { exit $ProgramExitCode }

$PersistentBuildRoot = Join-Path $ProjectRoot 'build'
$LeakedArtifacts = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File |
    Where-Object {
        ($_.Extension -in '.o', '.ppu' -or $_.Name -eq $ExecutableName) -and
        -not $_.FullName.StartsWith($PersistentBuildRoot,
            [StringComparison]::OrdinalIgnoreCase)
    })
if ($LeakedArtifacts.Count -gt 0) {
    throw "Build artifacts leaked into the project tree: $($LeakedArtifacts.FullName -join ', ')"
}

Write-Output "PASCAL_TEST=PASS program=$ProgramPath output=$Executable"
