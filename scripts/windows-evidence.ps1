[CmdletBinding()]
param(
    [string]$ScriptRoot = "",
    [string]$ProbeSecretFile = ""
)

# RC-install non-secret audit evidence generator (schema 2). Inputs come only
# from %LOCALAPPDATA%\claude-lane install products and the installed Clash
# binary. Never reads profiles, credentials, keys, or exit IP baselines.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$ResolvedScriptRoot = if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
    (Resolve-Path -LiteralPath $ScriptRoot).Path
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
$InstallRoot = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_LANE_SETUP_ROOT)) {
    $env:CLAUDE_LANE_SETUP_ROOT
} else {
    Join-Path $env:LOCALAPPDATA "claude-lane"
}
$AuditDir = Join-Path $InstallRoot "audit"
$StateDir = Join-Path $InstallRoot "state"
$CandidateManifestPath = Join-Path $StateDir "candidate-manifest.json"
$SetupStatePath = Join-Path $InstallRoot "setup-progress.json"
$BaselinePath = Join-Path $InstallRoot "private-state\windows-exit-baseline.json"
$RuntimeSelfTest = Join-Path $ResolvedScriptRoot "windows-runtime-selftest.ps1"

function Stop-Evidence([string]$Message) { throw "停止：$Message" }
function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Protect-Directory([string]$Path) {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $Acl = New-Object Security.AccessControl.DirectorySecurity
    $Acl.SetOwner($Identity)
    $Acl.SetAccessRuleProtection($true, $false)
    $RuleArguments = @(
        $Identity,
        [Security.AccessControl.FileSystemRights]::FullControl,
        ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $Rule = New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList $RuleArguments
    $Acl.AddAccessRule($Rule)
    Set-Acl -LiteralPath $Path -AclObject $Acl
}
function Assert-EvidenceSecrets([string]$JsonText) {
    # Failure-closed: refuse to persist any evidence that looks like a key or IP.
    if ($JsonText -match 'sk-[A-Za-z0-9_-]{8,}') {
        Stop-Evidence "证据内容匹配 API Key 模式；拒绝落盘"
    }
    $Ipv4 = '(?<![0-9])(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(?![0-9])'
    if ($JsonText -match $Ipv4) {
        Stop-Evidence "证据内容匹配 IPv4 模式；拒绝落盘"
    }
    # IPv6: full, compressed, and IPv4-mapped forms (no secret should ever appear).
    $Ipv6 = '(?i)(?:(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,7}:|(?:[0-9a-f]{1,4}:){1,6}:[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,5}(?::[0-9a-f]{1,4}){1,2}|(?:[0-9a-f]{1,4}:){1,4}(?::[0-9a-f]{1,4}){1,3}|(?:[0-9a-f]{1,4}:){1,3}(?::[0-9a-f]{1,4}){1,4}|(?:[0-9a-f]{1,4}:){1,2}(?::[0-9a-f]{1,4}){1,5}|[0-9a-f]{1,4}:(?:(?::[0-9a-f]{1,4}){1,6})|:(?:(?::[0-9a-f]{1,4}){1,7}|:)|::(?:ffff(?::0{1,4}){0,1}:){0,1}(?:(?:25[0-5]|(?:2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3}(?:25[0-5]|(?:2[0-4]|1{0,1}[0-9]){0,1}[0-9])|(?:[0-9a-f]{1,4}:){1,4}:(?:(?:25[0-5]|(?:2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3}(?:25[0-5]|(?:2[0-4]|1{0,1}[0-9]){0,1}[0-9]))'
    if ($JsonText -match $Ipv6) {
        Stop-Evidence "证据内容匹配 IPv6 模式；拒绝落盘"
    }
}
function Write-EvidenceFile([string]$Platform, [string]$JsonText) {
    Assert-EvidenceSecrets $JsonText
    if (-not (Test-Path -LiteralPath $AuditDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $AuditDir | Out-Null
    }
    Protect-Directory $AuditDir
    $EvidencePath = Join-Path $AuditDir ($Platform + ".json")
    $TempPath = Join-Path $AuditDir ("." + $Platform + "-" + [guid]::NewGuid().ToString("N") + ".json")
    try {
        [IO.File]::WriteAllText($TempPath, $JsonText)
        Move-Item -LiteralPath $TempPath -Destination $EvidencePath -Force
    } finally {
        Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue
    }
    return $EvidencePath
}
function Get-NativeArchitecture {
    $Wow = [string]$env:PROCESSOR_ARCHITEW6432
    $Native = [string]$env:PROCESSOR_ARCHITECTURE
    $Chosen = if (-not [string]::IsNullOrWhiteSpace($Wow)) { $Wow } else { $Native }
    $Upper = $Chosen.ToUpperInvariant()
    $Platform = $null
    $NativeArch = $null
    switch -Regex ($Upper) {
        '^(AMD64|X64)$' { $Platform = "win32-x64"; $NativeArch = "AMD64" }
        '^ARM64$' { $Platform = "win32-arm64"; $NativeArch = "ARM64" }
        default { Stop-Evidence "不支持的 Windows 架构：$Chosen" }
    }
    return [ordered]@{
        platform = $Platform
        native_arch = $NativeArch
        processor_architecture = $Native
        processor_architew6432 = $Wow
    }
}
function Get-ClaudeAuthenticode([string]$Path) {
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        Stop-Evidence "Claude Code Authenticode 无效：$($Signature.Status)"
    }
    if ($null -eq $Signature.SignerCertificate -or $Signature.SignerCertificate.Subject -notmatch 'Anthropic,? PBC') {
        Stop-Evidence "Claude Code 发布者不在固定允许列表"
    }
    return [ordered]@{
        status = "verified"
        subject = [string]$Signature.SignerCertificate.Subject
        thumbprint = [string]$Signature.SignerCertificate.Thumbprint
    }
}
function Get-ClashSignatureStatus([string]$Path) {
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid) {
        if ($null -eq $Signature.SignerCertificate -or $Signature.SignerCertificate.Subject -notmatch 'Clash|Verge') {
            Stop-Evidence "Clash Verge 发布者不在固定允许列表"
        }
        return "verified-authenticode"
    }
    if ($Signature.Status -eq [System.Management.Automation.SignatureStatus]::NotSigned) {
        return "authenticode-not-signed+minisign-upstream"
    }
    Stop-Evidence "Clash Verge Authenticode 状态异常：$($Signature.Status)"
}

# Selftest-only path: attempt to persist a forged JSON through the secret gate.
if (-not [string]::IsNullOrWhiteSpace($ProbeSecretFile)) {
    if (-not (Test-Path -LiteralPath $ProbeSecretFile -PathType Leaf)) {
        Stop-Evidence "ProbeSecretFile 不存在"
    }
    $ProbeText = Get-Content -LiteralPath $ProbeSecretFile -Raw -Encoding UTF8
    $ArchInfo = Get-NativeArchitecture
    $Written = Write-EvidenceFile ([string]$ArchInfo.platform) $ProbeText
    Write-Output "PROBE_WRITTEN=$Written"
    return
}

if (-not (Test-Path -LiteralPath $CandidateManifestPath -PathType Leaf)) {
    Stop-Evidence "缺少已校验候选 manifest：$CandidateManifestPath"
}
if (-not (Test-Path -LiteralPath $SetupStatePath -PathType Leaf)) {
    Stop-Evidence "缺少安装进度：$SetupStatePath"
}
if (-not (Test-Path -LiteralPath $RuntimeSelfTest -PathType Leaf)) {
    Stop-Evidence "安装包缺少 windows-runtime-selftest.ps1"
}

$ManifestSha = Get-FileSha256 $CandidateManifestPath
$Manifest = Get-Content -LiteralPath $CandidateManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$CandidateId = ""
if ($null -ne $Manifest.PSObject.Properties["candidate_id"] -and -not [string]::IsNullOrWhiteSpace([string]$Manifest.candidate_id)) {
    $CandidateId = [string]$Manifest.candidate_id
} else {
    $CandidateId = "released"
}
$ClaudeVersion = [string]$Manifest.claude_code.version
$ClashVersion = [string]$Manifest.clash_verge.version
if ([string]::IsNullOrWhiteSpace($ClaudeVersion) -or [string]::IsNullOrWhiteSpace($ClashVersion)) {
    Stop-Evidence "候选 manifest 缺少固定版本字段"
}

$ArchInfo = Get-NativeArchitecture
$Platform = [string]$ArchInfo.platform
$ClaudePath = Join-Path $InstallRoot ("tools\claude-code\" + $ClaudeVersion + "\claude.exe")
if (-not (Test-Path -LiteralPath $ClaudePath -PathType Leaf)) {
    Stop-Evidence "找不到已安装 Claude Code：$ClaudeVersion"
}
$ClaudeItem = Get-Item -LiteralPath $ClaudePath -Force
if (($ClaudeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    Stop-Evidence "Claude Code 路径不能是重解析点"
}
$ClaudeSha = Get-FileSha256 $ClaudePath
$ClaudeManifestKey = if ($Platform -eq "win32-x64") { "win32_x64" } else { "win32_arm64" }
$ClaudeManifestEntry = $Manifest.claude_code.$ClaudeManifestKey
if ($null -eq $ClaudeManifestEntry -or [string]$ClaudeManifestEntry.sha256 -ne $ClaudeSha) {
    Stop-Evidence "已安装 Claude Code SHA-256 与候选 manifest 固定摘要不符"
}
$ClaudeAuth = Get-ClaudeAuthenticode $ClaudePath
$ClaudeVersionOutput = (& $ClaudePath --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $ClaudeVersionOutput -notmatch [regex]::Escape($ClaudeVersion)) {
    Stop-Evidence "Claude Code 版本输出与固定版本不符"
}

$ClashCandidates = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Clash Verge\Clash Verge.exe"),
    (Join-Path $env:ProgramFiles "Clash Verge\Clash Verge.exe")
)
$ClashPath = $null
foreach ($Candidate in $ClashCandidates) {
    if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
        $ClashPath = $Candidate
        break
    }
}
if ([string]::IsNullOrWhiteSpace($ClashPath)) {
    Stop-Evidence "找不到已安装的 Clash Verge"
}
$ClashItem = Get-Item -LiteralPath $ClashPath -Force
if (($ClashItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    Stop-Evidence "Clash Verge 路径不能是重解析点"
}
$ClashSigStatus = Get-ClashSignatureStatus $ClashPath
$ClashFileVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ClashPath).ProductVersion
if ([string]::IsNullOrWhiteSpace($ClashFileVersion) -or $ClashFileVersion -notmatch [regex]::Escape($ClashVersion)) {
    Stop-Evidence "Clash Verge 产品版本与固定版本不符"
}

$SetupState = Get-Content -LiteralPath $SetupStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$SetupState.schema -ne 1 -or [string]$SetupState.platform -ne "windows") {
    Stop-Evidence "安装进度 schema 或平台无效"
}
$RoutingState = [string]$SetupState.state
if ($RoutingState -ne "VALIDATION_PASSED") {
    Stop-Evidence "六项验证尚未通过（当前状态：$RoutingState）"
}
$BaselinePresent = Test-Path -LiteralPath $BaselinePath -PathType Leaf

$RuntimeOutput = (& powershell.exe -NoProfile -File $RuntimeSelfTest -ScriptRoot $ResolvedScriptRoot 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
    Stop-Evidence "运行期自测失败"
}
$RuntimeLines = @($RuntimeOutput -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$RuntimeSummary = if ($RuntimeLines.Count -gt 0) { [string]$RuntimeLines[$RuntimeLines.Count - 1] } else { "" }
if ($RuntimeSummary -notmatch '(\d+) passed, 0 failed') {
    Stop-Evidence "运行期自测未返回全绿汇总"
}

$GeneratedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$Evidence = [ordered]@{
    schema = 2
    platform = $Platform
    generated_at = $GeneratedAt
    host = [ordered]@{
        os_version = [Environment]::OSVersion.VersionString
        powershell_version = $PSVersionTable.PSVersion.ToString()
        native_arch = [string]$ArchInfo.native_arch
        processor_architecture = [string]$ArchInfo.processor_architecture
        processor_architew6432 = [string]$ArchInfo.processor_architew6432
    }
    rc = [ordered]@{
        candidate_id = $CandidateId
        manifest_sha256 = $ManifestSha
    }
    claude_code = [ordered]@{
        version = $ClaudeVersion
        sha256 = $ClaudeSha
        authenticode = $ClaudeAuth
        version_output = $ClaudeVersionOutput
    }
    clash_verge = [ordered]@{
        version = $ClashVersion
        install_source = "installed-app"
        signature_status = $ClashSigStatus
    }
    runtime_selftest = [ordered]@{
        passed = $true
        summary = $RuntimeSummary
    }
    routing_validation = [ordered]@{
        state = "VALIDATION_PASSED"
        six_checks = 6
        private_baseline_present = [bool]$BaselinePresent
    }
    completed_at = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

$JsonText = $Evidence | ConvertTo-Json -Depth 10
$EvidencePath = Write-EvidenceFile $Platform $JsonText
Write-Output "EVIDENCE_WRITTEN=$EvidencePath"
Write-Output "VALIDATION PASSED: $Platform"
Write-Output "Copy this single evidence file back to the publisher Mac: $EvidencePath"
