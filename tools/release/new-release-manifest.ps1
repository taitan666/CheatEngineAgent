param(
    [Parameter(Mandatory = $true)][string]$DistDirectory,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$Version,
    [ValidateSet('internal')][string]$Channel = 'internal'
)

$ErrorActionPreference = 'Stop'
$Dist = (Resolve-Path -LiteralPath $DistDirectory).Path
$Files = @(Get-ChildItem -LiteralPath $Dist -File | Where-Object {
    $_.Extension -in @('.exe', '.dll')
} | Sort-Object Name)
if ($Files.Count -eq 0 -or @($Files | Where-Object Extension -eq '.exe').Count -eq 0) {
    throw 'Distribution must contain at least one EXE.'
}
$Entries = @($Files | ForEach-Object {
    $Signature = Get-AuthenticodeSignature -LiteralPath $_.FullName
    [ordered]@{
        name = $_.Name
        length = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        signatureStatus = [string]$Signature.Status
    }
})
$Document = [ordered]@{
    schemaVersion = 1
    version = $Version
    channel = $Channel
    publishable = $false
    files = $Entries
    evidence = [ordered]@{
        acceptance = 'not-recorded'
        malwareScan = 'not-recorded'
        manualGameAndUi = 'not-recorded'
        saveWriteGate9 = 'blocked'
    }
}
$Document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
Write-Output "RELEASE_MANIFEST_CREATED=PASS file_count=$($Files.Count) channel=internal"
exit 0
