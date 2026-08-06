# Real-host Windows validation entrypoint. It verifies the current architecture
# only, runs failure-closed bootstrap tests, and records non-secret evidence.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$WorkDir = Join-Path $RepoRoot ".mirror-work"
$ManifestPath = Join-Path $RepoRoot "manifests\stable.json"

$VerifyScript = Join-Path $RepoRoot "scripts\mirror\verify-artifacts.ps1"
$SelfTestScript = Join-Path $RepoRoot "scripts\bootstrap-windows-selftest.ps1"
foreach ($Required in @($ManifestPath, $VerifyScript, $SelfTestScript)) {
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

$VerifyOutput = (& powershell.exe -NoProfile -File $VerifyScript -WorkDir $WorkDir -ManifestPath $ManifestPath 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Artifact verification failed:`n$VerifyOutput" }
Write-Output $VerifyOutput

$SelfTestOutput = (& powershell.exe -NoProfile -File $SelfTestScript 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Bootstrap self-test failed:`n$SelfTestOutput" }
Write-Output $SelfTestOutput

$SetupStatePath = Join-Path $env:LOCALAPPDATA "claude-lane\setup-progress.json"
$ExitBaselinePath = Join-Path $env:LOCALAPPDATA "claude-lane\private-state\windows-exit-baseline.json"
if (-not (Test-Path -LiteralPath $SetupStatePath -PathType Leaf)) { throw "Windows routing validation state is missing" }
$SetupState = Get-Content -LiteralPath $SetupStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$SetupState.schema -ne 1 -or [string]$SetupState.state -ne "VALIDATION_PASSED" -or [string]$SetupState.platform -ne "windows") { throw "Windows routing six-check validation has not passed" }
if (-not (Test-Path -LiteralPath $ExitBaselinePath -PathType Leaf)) { throw "Windows routing exit baseline is missing" }

$EvidencePath = Join-Path $WorkDir "windows-audit\$Platform.json"
if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) { throw "Validation evidence was not created: $EvidencePath" }
$Evidence = Get-Content -LiteralPath $EvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
$Evidence | Add-Member -NotePropertyName bootstrap_selftest -NotePropertyValue ([ordered]@{
    passed = $true
    summary = ($SelfTestOutput -split "`r?`n" | Select-Object -Last 1)
}) -Force
$Evidence | Add-Member -NotePropertyName routing_validation -NotePropertyValue ([ordered]@{
    passed = $true
    state = "VALIDATION_PASSED"
    six_checks = 6
    private_baseline_present = $true
}) -Force
$Evidence | Add-Member -NotePropertyName host -NotePropertyValue ([ordered]@{
    os_version = [Environment]::OSVersion.VersionString
    powershell_version = $PSVersionTable.PSVersion.ToString()
    manifest_sha256 = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
}) -Force
$Evidence | Add-Member -NotePropertyName completed_at -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
$Evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8

Write-Output "VALIDATION PASSED: $Platform"
Write-Output "Copy this evidence file back to the publisher Mac: $EvidencePath"
