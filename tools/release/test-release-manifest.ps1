param(
    [Parameter(Mandatory = $true)][string]$DistDirectory,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [ValidateSet('internal', 'public')][string]$Mode = 'internal'
)

$ErrorActionPreference = 'Stop'
function Deny([string]$Reason) {
    Write-Output "RELEASE_MANIFEST=FAIL reason=$Reason"
    exit 1
}
$Dist = (Resolve-Path -LiteralPath $DistDirectory).Path
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ($Manifest.schemaVersion -ne 1 -or $Manifest.files.Count -lt 1) { Deny 'invalid_schema' }
if ($Mode -eq 'public') {
    if ($Manifest.channel -ne 'public' -or $Manifest.publishable -ne $true) {
        Deny 'not_public_channel'
    }
    foreach ($Field in @('acceptance', 'malwareScan', 'manualGameAndUi', 'saveWriteGate9')) {
        if ($Manifest.evidence.$Field -ne 'passed') { Deny "evidence_$Field" }
    }
}
$Actual = @(Get-ChildItem -LiteralPath $Dist -File | Where-Object {
    $_.Extension -in @('.exe', '.dll')
} | Sort-Object Name)
if ($Actual.Count -ne $Manifest.files.Count) { Deny 'file_set_mismatch' }
$Names = @{}
foreach ($Entry in $Manifest.files) {
    $Name = [string]$Entry.name
    if ($Name -notmatch '^[^\\/:*?"<>|]+\.(exe|dll)$' -or
        $Name -eq '.' -or $Name -eq '..' -or $Names.ContainsKey($Name)) {
        Deny 'unsafe_or_duplicate_name'
    }
    $Names[$Name] = $true
    $Path = Join-Path $Dist $Name
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Deny 'missing_file' }
    $File = Get-Item -LiteralPath $Path
    if ($File.Length -ne [long]$Entry.length) { Deny 'length_mismatch' }
    $Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Hash -ne [string]$Entry.sha256) { Deny 'hash_mismatch' }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$Signature.Status -ne [string]$Entry.signatureStatus) {
        Deny 'signature_status_changed'
    }
    if ($Mode -eq 'public' -and [string]$Signature.Status -ne 'Valid') {
        Deny 'unsigned_or_untrusted'
    }
}
foreach ($File in $Actual) {
    if (-not $Names.ContainsKey($File.Name)) { Deny 'unlisted_file' }
}
if ($Mode -eq 'public') {
    Write-Output 'RELEASE_MANIFEST=PASS mode=public'
} else {
    if ($Manifest.channel -ne 'internal' -or $Manifest.publishable -ne $false) {
        Deny 'not_internal_channel'
    }
    Write-Output 'RELEASE_MANIFEST=PASS mode=internal publishable=false'
}
exit 0
