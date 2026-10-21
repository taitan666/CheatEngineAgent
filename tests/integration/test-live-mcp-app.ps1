$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Executable = (Resolve-Path (Join-Path $ProjectRoot 'dist\CheatEngineAgent.exe')).Path
$Token = [Environment]::GetEnvironmentVariable('CEA_MCP_TOKEN', 'User')
if ([string]::IsNullOrEmpty($Token)) {
    throw 'CEA_MCP_TOKEN is missing; run tools\codex-mcp\configure-codex-mcp.ps1'
}

$env:CEA_MCP_TOKEN = $Token
$Process = Start-Process -FilePath $Executable `
    -WorkingDirectory (Split-Path $Executable -Parent) `
    -WindowStyle Hidden -PassThru
try {
    $Ready = $false
    for ($Attempt = 0; $Attempt -lt 50; $Attempt++) {
        try {
            $Client = [Net.Sockets.TcpClient]::new()
            $Client.Connect('127.0.0.1', 32145)
            $Client.Dispose()
            $Ready = $true
            break
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $Ready) { throw 'MCP port did not open' }

    $Headers = @{
        Authorization = 'Bearer ' + $Token
        Accept = 'application/json, text/event-stream'
    }
    $InitializeBody = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"codex-smoke","version":"1"}}}'
    $Initialize = Invoke-RestMethod -Method Post `
        -Uri 'http://127.0.0.1:32145/mcp' -Headers $Headers `
        -ContentType 'application/json' -Body $InitializeBody
    $ListBody = '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    $List = Invoke-RestMethod -Method Post `
        -Uri 'http://127.0.0.1:32145/mcp' -Headers $Headers `
        -ContentType 'application/json' -Body $ListBody
    $HealthBody = '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"cea.health","arguments":{}}}'
    $Health = Invoke-RestMethod -Method Post `
        -Uri 'http://127.0.0.1:32145/mcp' -Headers $Headers `
        -ContentType 'application/json' -Body $HealthBody

    if ($Initialize.result.serverInfo.name -ne 'cheat-engine-agent') {
        throw 'Unexpected MCP server name'
    }
    if (-not ($List.result.tools.name -contains 'cea.health')) {
        throw 'Health tool is missing'
    }
    if (-not ($List.result.tools.name -contains 'cea.request_memory_write')) {
        throw 'Governed write-request tool is missing'
    }
    if ($null -eq $Health.result -or $Health.error) {
        throw 'cea.health tool call failed'
    }
    Write-Output "LIVE_MCP_HANDSHAKE=PASS protocol=$($Initialize.result.protocolVersion) tools=$($List.result.tools.Count) health=pass"
} finally {
    $Token = $null
    Remove-Item Env:CEA_MCP_TOKEN -ErrorAction SilentlyContinue
    if ($Process -and -not $Process.HasExited) {
        $Process.CloseMainWindow() | Out-Null
        if (-not $Process.WaitForExit(3000)) {
            Stop-Process -Id $Process.Id
        }
    }
}
