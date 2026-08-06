param(
    [string]$WorkDir = "",
    [string]$ManifestPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = Join-Path $RepoRoot ".mirror-work" }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $RepoRoot "manifests\stable.json" }
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Assert-FileHash([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing artifact: $Path" }
    $Actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected.ToLowerInvariant()) { throw "SHA-256 mismatch: $Path" }
}

function Assert-Authenticode([string]$Path, [string]$PublisherPattern) {
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Authenticode verification failed ($($Signature.Status)): $Path"
    }
    if ($null -eq $Signature.SignerCertificate -or $Signature.SignerCertificate.Subject -notmatch $PublisherPattern) {
        throw "Unexpected Authenticode publisher: $Path"
    }
    return [ordered]@{
        status = "verified"
        subject = $Signature.SignerCertificate.Subject
        thumbprint = $Signature.SignerCertificate.Thumbprint
        not_before = $Signature.SignerCertificate.NotBefore.ToUniversalTime().ToString("o")
        not_after = $Signature.SignerCertificate.NotAfter.ToUniversalTime().ToString("o")
        timestamp_subject = if ($null -ne $Signature.TimeStamperCertificate) { $Signature.TimeStamperCertificate.Subject } else { "" }
    }
}

function Assert-ClashSignature([string]$Path, [string]$UpstreamStatus) {
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid) {
        if ($null -eq $Signature.SignerCertificate -or $Signature.SignerCertificate.Subject -notmatch 'Clash|Verge') {
            throw "Unexpected Authenticode publisher: $Path"
        }
        return [ordered]@{
            status = "verified-authenticode"
            subject = $Signature.SignerCertificate.Subject
            thumbprint = $Signature.SignerCertificate.Thumbprint
            upstream_signature = $UpstreamStatus
        }
    }
    if ($Signature.Status -eq [System.Management.Automation.SignatureStatus]::NotSigned -and $UpstreamStatus -match '^verified-tauri-minisign') {
        return [ordered]@{
            status = "authenticode-not-signed"
            subject = ""
            thumbprint = ""
            upstream_signature = $UpstreamStatus
        }
    }
    throw "Clash signature verification failed ($($Signature.Status), upstream=$UpstreamStatus): $Path"
}

$ClaudeVersion = [string]$Manifest.claude_code.version
$ClashVersion = [string]$Manifest.clash_verge.version
$ClaudeDir = Join-Path $WorkDir "claude-code\releases\$ClaudeVersion"
$ClashDir = Join-Path $WorkDir "clash-verge\releases\v$ClashVersion"
$Architecture = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
    $env:PROCESSOR_ARCHITEW6432
} else {
    $env:PROCESSOR_ARCHITECTURE
}
switch -Regex ($Architecture.ToUpperInvariant()) {
    "^(AMD64|X64)$" {
        $ClaudeEntry = $Manifest.claude_code.win32_x64
        $ClaudeFile = Join-Path $ClaudeDir "claude-win32-x64.exe"
        $ClashEntry = $Manifest.clash_verge.win32_x64
        $ClashFile = Join-Path $ClashDir "Clash.Verge_${ClashVersion}_x64-setup.exe"
        $Platform = "win32-x64"
    }
    "^ARM64$" {
        $ClaudeEntry = $Manifest.claude_code.win32_arm64
        $ClaudeFile = Join-Path $ClaudeDir "claude-win32-arm64.exe"
        $ClashEntry = $Manifest.clash_verge.win32_arm64
        $ClashFile = Join-Path $ClashDir "Clash.Verge_${ClashVersion}_arm64-setup.exe"
        $Platform = "win32-arm64"
    }
    default { throw "Unsupported Windows architecture: $Architecture" }
}

Assert-FileHash $ClaudeFile ([string]$ClaudeEntry.sha256)
$ClaudeSignature = Assert-Authenticode $ClaudeFile 'Anthropic,? PBC'
$VersionOutput = (& $ClaudeFile --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $VersionOutput -notmatch [regex]::Escape($ClaudeVersion)) { throw "Claude version verification failed" }

Assert-FileHash $ClashFile ([string]$ClashEntry.sha256)
$ClashSignature = Assert-ClashSignature $ClashFile ([string]$ClashEntry.signature_status)
$FileVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ClashFile).ProductVersion
if ([string]::IsNullOrWhiteSpace($FileVersion) -or $FileVersion -notmatch [regex]::Escape($ClashVersion)) {
    throw "Clash installer version verification failed"
}

$AuditDir = Join-Path $WorkDir "windows-audit"
New-Item -ItemType Directory -Force -Path $AuditDir | Out-Null
$Evidence = [ordered]@{
    schema = 1
    platform = $Platform
    verified_at = [DateTime]::UtcNow.ToString("o")
    passed = $true
    claude_code = [ordered]@{ version = $ClaudeVersion; signature = $ClaudeSignature; version_output = $VersionOutput }
    clash_verge = [ordered]@{ version = $ClashVersion; signature = $ClashSignature; file_version = $FileVersion }
}
$EvidencePath = Join-Path $AuditDir "$Platform.json"
$Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
Write-Output "verified $Platform; evidence: $EvidencePath"
