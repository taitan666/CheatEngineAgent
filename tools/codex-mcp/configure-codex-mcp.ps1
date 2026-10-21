param(
    [switch]$Remove,
    [switch]$StartApplication
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Executable = Join-Path $ProjectRoot 'dist\CheatEngineAgent.exe'
$VariableName = 'CEA_MCP_TOKEN'

if ($Remove) {
    [Environment]::SetEnvironmentVariable($VariableName, $null, 'User')
    Remove-Item -Path "Env:$VariableName" -ErrorAction SilentlyContinue
    Write-Output 'CEA_MCP_TOKEN=REMOVED restart_codex=true'
    exit 0
}

$Bytes = New-Object byte[] 32
$Generator = [Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $Generator.GetBytes($Bytes)
} finally {
    $Generator.Dispose()
}
$Token = [BitConverter]::ToString($Bytes).Replace('-', '').ToLowerInvariant()
[Environment]::SetEnvironmentVariable($VariableName, $Token, 'User')
Set-Item -Path "Env:$VariableName" -Value $Token
$Token = $null
[Array]::Clear($Bytes, 0, $Bytes.Length)

if ($StartApplication) {
    if (-not (Test-Path -LiteralPath $Executable)) {
        throw "Build the standalone application first: $Executable"
    }
    Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable -Parent)
}

Write-Output 'CEA_MCP_TOKEN=CONFIGURED endpoint=http://127.0.0.1:32145/mcp restart_codex=true'
