$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$SchemaRoot = Join-Path $ProjectRoot 'schemas'
$SchemaFiles = @(Get-ChildItem -LiteralPath $SchemaRoot -Recurse -Filter '*.json')
if ($SchemaFiles.Count -eq 0) { throw 'No schema JSON files found.' }

$Ids = @{}
foreach ($File in $SchemaFiles) {
    try {
        $Document = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Invalid JSON: $($File.FullName): $($_.Exception.Message)"
    }
    if (-not $Document.'$schema') { throw "Missing `$schema: $($File.FullName)" }
    if (-not $Document.'$id') { throw "Missing `$id: $($File.FullName)" }
    if ($Document.'$schema' -ne 'https://json-schema.org/draft/2020-12/schema') {
        throw "Unexpected JSON Schema dialect: $($File.FullName)"
    }
    if ($Ids.ContainsKey($Document.'$id')) { throw "Duplicate `$id: $($Document.'$id')" }
    $Ids[$Document.'$id'] = $File.FullName

    $Text = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
    $RelativeRefs = [regex]::Matches($Text, '"\$ref"\s*:\s*"(?!#|https?://)([^"#]+)')
    foreach ($Match in $RelativeRefs) {
        $Target = Join-Path $File.DirectoryName $Match.Groups[1].Value
        if (-not (Test-Path -LiteralPath $Target)) { throw "Unresolved local reference '$($Match.Groups[1].Value)' in $($File.FullName)" }
    }
}

$ManifestPath = Join-Path $SchemaRoot 'manifest.json'
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ManifestEntries = @($Manifest.schemas)
foreach ($Entry in $ManifestEntries) {
    if (-not (Test-Path -LiteralPath (Join-Path $SchemaRoot $Entry))) {
        throw "Schema manifest entry does not exist: $Entry"
    }
}
$ExpectedEntries = @($SchemaFiles | Where-Object Name -ne 'manifest.json' | ForEach-Object {
    $_.FullName.Substring($SchemaRoot.Length + 1).Replace('\', '/')
})
$MissingManifestEntries = @($ExpectedEntries | Where-Object { $_ -notin $ManifestEntries })
if ($MissingManifestEntries.Count -gt 0) { throw "Schemas missing from manifest: $($MissingManifestEntries -join ', ')" }

$FinishedInvalid = Get-Content -LiteralPath (Join-Path $ProjectRoot 'tests/contracts/negative/finished-without-outcome.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (($FinishedInvalid.execution_status -ne 'finished') -or ($null -ne $FinishedInvalid.outcome)) {
    throw 'Finished-task negative fixture does not exercise missing outcome.'
}
$WriteInvalid = Get-Content -LiteralPath (Join-Path $ProjectRoot 'tests/contracts/negative/write-without-approval.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($WriteInvalid.PSObject.Properties.Name -contains 'approval_ref') {
    throw 'Write negative fixture unexpectedly contains approval_ref.'
}
$ProviderInvalid = Get-Content -LiteralPath (Join-Path $ProjectRoot 'tests/contracts/negative/provider-with-api-key.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($ProviderInvalid.PSObject.Properties.Name -notcontains 'api_key') {
    throw 'Provider negative fixture does not exercise forbidden inline secret.'
}

$SinglePlayerPolicy = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config/policies/single-player-only.yaml') -Raw -Encoding UTF8
$NoTrainingPolicy = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config/policies/no-model-training.yaml') -Raw -Encoding UTF8
if ($SinglePlayerPolicy -notmatch 'override_allowed:\s*false') { throw 'Single-player policy is not immutable.' }
if ($NoTrainingPolicy -notmatch 'override_allowed:\s*false') { throw 'No-training policy is not immutable.' }

$ManifestUnits = @(Get-Content -LiteralPath (Join-Path $ProjectRoot 'build/unit-manifest.txt') -Encoding UTF8 | Where-Object { $_.Trim() })
$MissingUnits = @($ManifestUnits | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ProjectRoot $_)) })
if ($MissingUnits.Count -gt 0) { throw "Pascal unit manifest entries do not exist: $($MissingUnits -join ', ')" }

$PascalFiles = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'src') -Recurse -Filter '*.pas')
$ApprovedReadOnlyBackend = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'src/platform/windows/cea_win32_readonly_backend.pas')).Path
$ApprovedEffectBackend = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'src/platform/windows/cea_win32_effect_backend.pas')).Path
$ReadApiPattern = '\bOpenProcess\b|\bReadProcessMemory\b'
# Read access lives only in reviewed read-only backends; each is listed by name
# so adding a new process-reading file requires an explicit review decision.
$ApprovedPointerReader = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'src/platform/windows/cea_win32_pointer_reader.pas')).Path
$ApprovedReadBackends = @($ApprovedReadOnlyBackend, $ApprovedEffectBackend, $ApprovedPointerReader)
foreach ($PascalFile in $PascalFiles) {
    $Text = Get-Content -LiteralPath $PascalFile.FullName -Raw -Encoding UTF8
    if (($Text -match $ReadApiPattern) -and
        ($PascalFile.FullName -notin $ApprovedReadBackends)) {
        throw "Process API outside approved backend: $($PascalFile.FullName)"
    }
}
$PointerReaderText = Get-Content -LiteralPath $ApprovedPointerReader -Raw -Encoding UTF8
if ($PointerReaderText -match '\bWriteProcessMemory\b|\bPROCESS_VM_WRITE\b|\bPROCESS_VM_OPERATION\b|PROCESS_ALL_ACCESS') {
    throw 'Approved pointer reader must never request write access to a target process.'
}
$NonEffectPascalText = ($PascalFiles | Where-Object { $_.FullName -ne $ApprovedEffectBackend } |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
if ($NonEffectPascalText -match '\bWriteProcessMemory\b|\bPROCESS_VM_WRITE\b|\bPROCESS_VM_OPERATION\b') {
    throw 'Memory write capability found outside the approved effect backend.'
}
$PascalText = ($PascalFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
$ForbiddenOperationalPattern = '\bVirtualProtectEx\b|\bCreateRemoteThread\b|\bNtWriteVirtualMemory\b|\bPROCESS_ALL_ACCESS\b|\bAdjustTokenPrivileges\b|\bDeviceIoControl\b|Authorization:'
if ($PascalText -match $ForbiddenOperationalPattern) {
    throw 'Forbidden injection, executable-page mutation, privilege, kernel-device, or inline-credential capability found.'
}
$EffectBackendText = Get-Content -LiteralPath $ApprovedEffectBackend -Raw -Encoding UTF8
if (($EffectBackendText -notmatch '\bCompareWriteReadback\b') -or
    ($EffectBackendText -notmatch '\bWriteProcessMemory\b') -or
    ($EffectBackendText -notmatch '\bReadProcessMemory\b')) {
    throw 'Approved effect backend must retain compare-write-readback semantics.'
}

Write-Output "SCHEMA_CHECK=PASS schemas=$($SchemaFiles.Count) ids=$($Ids.Count) manifest=$($ManifestEntries.Count) units=$($ManifestUnits.Count)"
