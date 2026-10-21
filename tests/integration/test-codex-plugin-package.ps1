$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$PluginRoot = Join-Path $ProjectRoot 'tools\codex-mcp\plugin'
$ManifestPath = Join-Path $PluginRoot '.codex-plugin\plugin.json'
$McpPath = Join-Path $PluginRoot '.mcp.json'

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Missing Codex plugin manifest: $ManifestPath"
}
if (-not (Test-Path -LiteralPath $McpPath)) {
    throw "Missing Codex plugin MCP configuration: $McpPath"
}

$Manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
$Mcp = Get-Content -Raw -LiteralPath $McpPath | ConvertFrom-Json

if ($Manifest.name -ne 'cheat-engine-agent') { throw 'Unexpected plugin name' }
if ($Manifest.mcpServers -ne './.mcp.json') { throw 'Plugin does not reference .mcp.json' }
$Server = $Mcp.mcpServers.cheat_engine_agent
if ($null -eq $Server) { throw 'Missing cheat_engine_agent MCP server' }
if ($Server.type -ne 'http') { throw 'MCP transport is not HTTP' }
if ($Server.url -ne 'http://127.0.0.1:32145/mcp') { throw 'MCP endpoint is not loopback' }
if ($Server.bearer_token_env_var -ne 'CEA_MCP_TOKEN') { throw 'MCP bearer environment reference is missing' }
if ($Server.default_tools_approval_mode -ne 'prompt') { throw 'MCP tools are not approval-gated' }

$Raw = (Get-Content -Raw -LiteralPath $ManifestPath) + (Get-Content -Raw -LiteralPath $McpPath)
if ($Raw -match '(?i)bearer\s+[a-z0-9_-]{16,}|sk-[a-z0-9_-]{12,}') {
    throw 'Plugin package contains a credential-like literal'
}

Write-Output 'CODEX_PLUGIN_PACKAGE=PASS server=cheat_engine_agent auth=env approval=prompt'
