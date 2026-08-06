# Publisher-side Windows validation entry. Reuses the RC-portable evidence
# generator (schema 2) so repo and install-host evidence stay identical.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$SelfTestScript = Join-Path $RepoRoot "scripts\bootstrap-windows-selftest.ps1"
$EvidenceScript = Join-Path $RepoRoot "scripts\windows-evidence.ps1"
foreach ($Required in @($SelfTestScript, $EvidenceScript)) {
    if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Missing validation input: $Required" }
}

$Architecture = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
    $env:PROCESSOR_ARCHITEW6432
} else {
    $env:PROCESSOR_ARCHITECTURE
}
switch -Regex ($Architecture.ToUpperInvariant()) {
    "^(AMD64|X64)$" { $Platform = "win32-x64" }
    "^ARM64$" { $Platform = "win32-arm64" }
    default { throw "Unsupported Windows architecture: $Architecture" }
}

Write-Output "Windows validation platform: $Platform"

$SelfTestOutput = (& powershell.exe -NoProfile -File $SelfTestScript 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Bootstrap self-test failed:`n$SelfTestOutput" }
Write-Output $SelfTestOutput

$EvidenceOutput = (& powershell.exe -NoProfile -File $EvidenceScript -ScriptRoot $ScriptDir 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Evidence generation failed:`n$EvidenceOutput" }
Write-Output $EvidenceOutput

$EvidencePath = Join-Path $env:LOCALAPPDATA "claude-lane\audit\$Platform.json"
if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_LANE_SETUP_ROOT)) {
    $EvidencePath = Join-Path $env:CLAUDE_LANE_SETUP_ROOT "audit\$Platform.json"
}
if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
    throw "Validation evidence was not created: $EvidencePath"
}
$Evidence = Get-Content -LiteralPath $EvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$Evidence.schema -ne 2 -or [string]$Evidence.platform -ne $Platform) {
    throw "Evidence schema or platform mismatch"
}

Write-Output "VALIDATION PASSED: $Platform"
Write-Output "Copy this single evidence file back to the publisher Mac: $EvidencePath"
