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

$EvidencePath = Join-Path $WorkDir "windows-audit\$Platform.json"
if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) { throw "Validation evidence was not created: $EvidencePath" }
$Evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
$Evidence | Add-Member -NotePropertyName bootstrap_selftest -NotePropertyValue ([ordered]@{
    passed = $true
    summary = ($SelfTestOutput -split "`r?`n" | Select-Object -Last 1)
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
