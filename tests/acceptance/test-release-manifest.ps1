$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Generator = Join-Path $ProjectRoot 'tools\release\new-release-manifest.ps1'
$Verifier = Join-Path $ProjectRoot 'tools\release\test-release-manifest.ps1'
$Fixture = Join-Path $env:TEMP ('cea-release-' + [guid]::NewGuid().ToString('N'))
$Dist = Join-Path $Fixture 'dist'
$Manifest = Join-Path $Fixture 'internal-manifest.json'
New-Item -ItemType Directory -Path $Dist | Out-Null
try {
    [System.IO.File]::WriteAllText((Join-Path $Dist 'App.exe'), 'fixture-exe')
    [System.IO.File]::WriteAllText((Join-Path $Dist 'data.dll'), 'fixture-dll')
    & $Generator -DistDirectory $Dist -ManifestPath $Manifest -Version '0.0.0-test' -Channel internal
    if ($LASTEXITCODE -ne 0) { throw 'generator failed' }
    $Raw = [System.IO.File]::ReadAllText($Manifest)
    if ($Raw.Contains($Fixture) -or $Raw.Contains($env:USERPROFILE)) {
        throw 'manifest leaked an absolute local path'
    }
    & $Verifier -DistDirectory $Dist -ManifestPath $Manifest -Mode internal
    if ($LASTEXITCODE -ne 0) { throw 'clean internal fixture rejected' }
    & $Verifier -DistDirectory $Dist -ManifestPath $Manifest -Mode public
    if ($LASTEXITCODE -eq 0) { throw 'unsigned fixture passed public gate' }
    $PublicObject = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
    $PublicObject.channel = 'public'
    $PublicObject.publishable = $true
    foreach ($Field in @('acceptance', 'malwareScan', 'manualGameAndUi', 'saveWriteGate9')) {
        $PublicObject.evidence.$Field = 'passed'
    }
    $PublicObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Manifest -Encoding UTF8
    $Output = & $Verifier -DistDirectory $Dist -ManifestPath $Manifest -Mode public
    if (($LASTEXITCODE -eq 0) -or ($Output -notmatch 'unsigned_or_untrusted')) {
        throw 'unsigned public fixture did not fail the signature gate'
    }
    foreach ($Field in @('acceptance', 'malwareScan', 'manualGameAndUi', 'saveWriteGate9')) {
        $PublicObject.evidence.$Field = 'missing'
        $PublicObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Manifest -Encoding UTF8
        $Output = & $Verifier -DistDirectory $Dist -ManifestPath $Manifest -Mode public
        if (($LASTEXITCODE -eq 0) -or ($Output -notmatch "evidence_$Field")) {
            throw "public gate did not isolate missing evidence: $Field"
        }
        $PublicObject.evidence.$Field = 'passed'
    }
    $PublicObject.channel = 'internal'
    $PublicObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Manifest -Encoding UTF8
    $Output = & $Verifier -DistDirectory $Dist -ManifestPath $Manifest -Mode public
    if (($LASTEXITCODE -eq 0) -or ($Output -notmatch 'not_public_channel')) {
        throw 'wrong public channel was not rejected independently'
    }
    & $Generator -DistDirectory $Dist -ManifestPath $Manifest -Version '0.0.0-test' -Channel internal
    if ($LASTEXITCODE -ne 0) { throw 'fixture manifest reset failed' }
    [System.IO.File]::AppendAllText((Join-Path $Dist 'data.dll'), 'tampered')
    & $Verifier -DistDirectory $Dist -ManifestPath $Manifest -Mode internal
    if ($LASTEXITCODE -eq 0) { throw 'tampered DLL passed verification' }
    [System.IO.File]::WriteAllText((Join-Path $Dist 'data.dll'), 'fixture-dll')
    Remove-Item -LiteralPath (Join-Path $Dist 'App.exe')
    & $Verifier -DistDirectory $Dist -ManifestPath $Manifest -Mode internal
    if ($LASTEXITCODE -eq 0) { throw 'missing EXE passed verification' }
    [System.IO.File]::WriteAllText((Join-Path $Dist 'App.exe'), 'fixture-exe')
    $Object = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
    $Object.files[0].name = '..\escaped.dll'
    $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Manifest -Encoding UTF8
    & $Verifier -DistDirectory $Dist -ManifestPath $Manifest -Mode internal
    if ($LASTEXITCODE -eq 0) { throw 'path traversal in manifest passed verification' }
    Write-Output 'RELEASE_MANIFEST=PASS'
} finally {
    $TempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    $ResolvedFixture = [System.IO.Path]::GetFullPath($Fixture)
    if (-not $ResolvedFixture.StartsWith($TempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fixture cleanup target escaped temp directory.'
    }
    Remove-Item -LiteralPath $ResolvedFixture -Recurse -Force
}
exit 0
