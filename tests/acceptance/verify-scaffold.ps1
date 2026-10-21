$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$RequiredFiles = @(
    'README.md',
    'bootstrap/project-bootstrap.yaml',
    'bootstrap/application-descriptor.yaml',
    'bootstrap/feature-set-lite.yaml',
    'schemas/manifest.json',
    'schemas/agentos/effect.schema.json',
    'schemas/ce-domain/process.schema.json',
    'schemas/ct-knowledge/cheat-table.schema.json',
    'schemas/llm/model-invocation.schema.json',
    'config/policies/single-player-only.yaml',
    'config/policies/no-model-training.yaml',
    'src/contracts/cea_ports.pas',
    'src/core/cea_runtime.pas',
    'src/platform/windows/cea_win32_engine_runtime.pas',
    'tools/schema-check/check-schemas.ps1'
)

$Missing = @($RequiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ProjectRoot $_)) })
if ($Missing.Count -gt 0) {
    throw "Missing required scaffold files: $($Missing -join ', ')"
}

$JsonFiles = Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'schemas') -Recurse -Filter '*.json'
foreach ($JsonFile in $JsonFiles) {
    Get-Content -LiteralPath $JsonFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
}

$PolicyText = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config/policies/single-player-only.yaml') -Raw -Encoding UTF8
if ($PolicyText -notmatch 'override_allowed:\s*false') {
    throw 'Single-player restriction must be immutable.'
}

$TrainingText = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config/policies/no-model-training.yaml') -Raw -Encoding UTF8
if ($TrainingText -notmatch 'override_allowed:\s*false') {
    throw 'Model-training prohibition must be immutable.'
}

$PascalFiles = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'src') -Recurse -Filter '*.pas')
# Read access is allowed only in reviewed read-only backends. Each of them is
# listed explicitly so that adding a new process-reading file is a deliberate
# review decision rather than an accident.
$ApprovedReadOnlyBackend = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'src/platform/windows/cea_win32_readonly_backend.pas')).Path
$ApprovedEffectBackend = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'src/platform/windows/cea_win32_effect_backend.pas')).Path
$ApprovedPointerReader = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot 'src/platform/windows/cea_win32_pointer_reader.pas')).Path
$ApprovedReadBackends = @($ApprovedReadOnlyBackend, $ApprovedEffectBackend, $ApprovedPointerReader)
foreach ($PascalFile in $PascalFiles) {
    $Text = Get-Content -LiteralPath $PascalFile.FullName -Raw -Encoding UTF8
    if (($Text -match '\bOpenProcess\b|\bReadProcessMemory\b') -and
        ($PascalFile.FullName -notin $ApprovedReadBackends)) {
        throw "Process API outside approved backend: $($PascalFile.FullName)"
    }
}
# The pointer reader must stay read-only: it resolves chains, it never writes.
$PointerReaderText = Get-Content -LiteralPath $ApprovedPointerReader -Raw -Encoding UTF8
if ($PointerReaderText -match '\bWriteProcessMemory\b|\bPROCESS_VM_WRITE\b|\bPROCESS_VM_OPERATION\b|PROCESS_ALL_ACCESS') {
    throw 'Approved pointer reader must never request write access to a target process.'
}
$NonEffectSourceText = ($PascalFiles | Where-Object { $_.FullName -ne $ApprovedEffectBackend } |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
$WriteCalls = '\bWriteProcessMemory\b|\bPROCESS_VM_WRITE\b|\bPROCESS_VM_OPERATION\b'
if ($NonEffectSourceText -match $WriteCalls) {
    throw 'Memory write capability found outside the approved effect backend.'
}
$SourceText = ($PascalFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
$ForbiddenCalls = '\bCreateRemoteThread\b|\bVirtualProtectEx\b|\bNtWriteVirtualMemory\b|\bPROCESS_ALL_ACCESS\b|\bAdjustTokenPrivileges\b|\bDeviceIoControl\b|Authorization:'
if ($SourceText -match $ForbiddenCalls) {
    throw 'Forbidden injection, executable-page mutation, privilege, kernel-device, or inline-credential capability found.'
}
$EffectBackendText = Get-Content -LiteralPath $ApprovedEffectBackend -Raw -Encoding UTF8
if (($EffectBackendText -notmatch '\bCompareWriteReadback\b') -or
    ($EffectBackendText -notmatch '\bWriteProcessMemory\b') -or
    ($EffectBackendText -notmatch '\bReadProcessMemory\b')) {
    throw 'Approved effect backend must retain compare-write-readback semantics.'
}

Write-Output "SCAFFOLD_ACCEPTANCE=PASS files=$($RequiredFiles.Count) json=$($JsonFiles.Count)"
