# Offline Windows release-candidate installer. It uses only artifacts inside the
# reviewed validation bundle; it never downloads, logs in, or changes routing.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$WorkDir = Join-Path $RepoRoot ".mirror-work"
$ManifestPath = Join-Path $RepoRoot "manifests\stable.json"
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$ValidationPath = Join-Path $RepoRoot "scripts\windows-validation.ps1"

function Stop-Rc([string]$Message) { throw "停止：$Message" }
function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-FileHash([string]$Path, [string]$Expected, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Rc "缺少 $Label：$Path" }
    if ((Get-Sha256 $Path) -ne $Expected.ToLowerInvariant()) { Stop-Rc "$Label SHA-256 不匹配" }
}
function Assert-Authenticode([string]$Path, [string]$PublisherPattern, [string]$Label) {
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) { Stop-Rc "$Label Authenticode 无效：$($Signature.Status)" }
    if ($null -eq $Signature.SignerCertificate -or $Signature.SignerCertificate.Subject -notmatch $PublisherPattern) { Stop-Rc "$Label 发布者不匹配" }
}
function Assert-ZipEntries([string]$ZipPath, [string]$ExpectedRoot) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($Entry in $Zip.Entries) {
            $Name = $Entry.FullName.Replace('\', '/')
            if ($Name.StartsWith('/') -or $Name -match '(^|/)\.\.(/|$)' -or $Name -match '^[A-Za-z]:') { Stop-Rc "claude-lane ZIP 含不安全路径" }
            if (-not $Name.StartsWith("$ExpectedRoot/")) { Stop-Rc "claude-lane ZIP 根目录不符合 manifest" }
        }
    } finally { $Zip.Dispose() }
}

if (-not [Environment]::Is64BitOperatingSystem) { Stop-Rc "只支持 64 位 Windows" }
if ([Environment]::OSVersion.Version -lt [Version]"10.0.17763") { Stop-Rc "需要 Windows 10 1809 或更高版本" }
if ([int]$Manifest.schema -ne 1 -or [string]$Manifest.claude_lane.version -ne "1.3.0" -or [string]$Manifest.claude_code.version -ne "2.1.212" -or [string]$Manifest.clash_verge.version -ne "2.5.2") { Stop-Rc "固定版本清单不匹配" }
if (-not (Test-Path -LiteralPath $ValidationPath -PathType Leaf)) { Stop-Rc "验证包缺少 Windows 统一验证脚本" }
$ValidationOutput = (& powershell.exe -NoProfile -File $ValidationPath 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $ValidationOutput -notmatch 'VALIDATION PASSED') { Stop-Rc "Windows RC 安装前验证失败：$ValidationOutput" }
Write-Output ($ValidationOutput -split '\r?\n' | Select-Object -Last 2)

$Architecture = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch -Regex ($Architecture.ToUpperInvariant()) {
    "^(AMD64|X64)$" {
        $Platform = "win32-x64"
        $ClaudeEntry = $Manifest.claude_code.win32_x64
        $ClashEntry = $Manifest.clash_verge.win32_x64
        $ClaudeFile = Join-Path $WorkDir "claude-code\releases\2.1.212\claude-win32-x64.exe"
        $ClashFile = Join-Path $WorkDir "clash-verge\releases\v2.5.2\Clash.Verge_2.5.2_x64-setup.exe"
    }
    "^ARM64$" {
        $Platform = "win32-arm64"
        $ClaudeEntry = $Manifest.claude_code.win32_arm64
        $ClashEntry = $Manifest.clash_verge.win32_arm64
        $ClaudeFile = Join-Path $WorkDir "claude-code\releases\2.1.212\claude-win32-arm64.exe"
        $ClashFile = Join-Path $WorkDir "clash-verge\releases\v2.5.2\Clash.Verge_2.5.2_arm64-setup.exe"
    }
    default { Stop-Rc "不支持的 Windows 架构：$Architecture" }
}

$LaneFile = Join-Path $WorkDir "claude-lane\releases\v1.3.0\claude-lane.zip"
Write-Output "Windows RC platform: $Platform"
Assert-FileHash $ClaudeFile ([string]$ClaudeEntry.sha256) "Claude Code"
Assert-Authenticode $ClaudeFile 'Anthropic,? PBC' "Claude Code"
$ClaudeVersionOutput = (& $ClaudeFile --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $ClaudeVersionOutput -notmatch '2\.1\.212') { Stop-Rc "Claude Code 版本检查失败" }

Assert-FileHash $ClashFile ([string]$ClashEntry.sha256) "Clash Verge Rev"
Assert-Authenticode $ClashFile 'Clash|Verge' "Clash Verge Rev"
$ClashVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ClashFile).ProductVersion
if ([string]::IsNullOrWhiteSpace($ClashVersion) -or $ClashVersion -notmatch '2\.5\.2') { Stop-Rc "Clash Verge Rev 版本检查失败" }

Assert-FileHash $LaneFile ([string]$Manifest.claude_lane.windows_sha256) "claude-lane"
$LaneRoot = [string]$Manifest.claude_lane.archive_root
Assert-ZipEntries $LaneFile $LaneRoot

$InstallRoot = Join-Path $env:LOCALAPPDATA "claude-lane"
$ClaudeTarget = Join-Path $InstallRoot "tools\claude-code\2.1.212\claude.exe"
if (Test-Path -LiteralPath $ClaudeTarget) {
    Assert-FileHash $ClaudeTarget ([string]$ClaudeEntry.sha256) "现有 Claude Code"
    Assert-Authenticode $ClaudeTarget 'Anthropic,? PBC' "现有 Claude Code"
    Write-Output "保留已校验的 Claude Code：$ClaudeTarget"
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ClaudeTarget) | Out-Null
    Copy-Item -LiteralPath $ClaudeFile -Destination $ClaudeTarget
    Write-Output "已安装 Claude Code：$ClaudeTarget"
}

$ReleaseTarget = Join-Path $InstallRoot "releases\v1.3.0"
if (Test-Path -LiteralPath $ReleaseTarget) {
    $InstalledVersion = Join-Path $ReleaseTarget "VERSION"
    if (-not (Test-Path -LiteralPath $InstalledVersion -PathType Leaf) -or (Get-Content -LiteralPath $InstalledVersion -Raw).Trim() -ne "1.3.0") { Stop-Rc "现有 claude-lane 目录不是固定版本，拒绝覆盖" }
    Write-Output "保留现有 claude-lane：$ReleaseTarget"
} else {
    $ExtractRoot = Join-Path ([IO.Path]::GetTempPath()) ("claude-lane-rc-" + [guid]::NewGuid().ToString("N"))
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($LaneFile, $ExtractRoot)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ReleaseTarget) | Out-Null
        Move-Item -LiteralPath (Join-Path $ExtractRoot $LaneRoot) -Destination $ReleaseTarget
    } finally {
        if (Test-Path -LiteralPath $ExtractRoot) { Remove-Item -LiteralPath $ExtractRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Output "已安装 claude-lane：$ReleaseTarget"
}

$KnownClash = @(@(
    (Join-Path $env:LOCALAPPDATA "Programs\Clash Verge\Clash Verge.exe"),
    (Join-Path $env:ProgramFiles "Clash Verge\Clash Verge.exe")
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
if ($KnownClash.Count -eq 0) {
    Write-Output "即将启动已验签的 Clash Verge Rev 安装器；请在 Windows 界面确认安装。"
    $Process = Start-Process -FilePath $ClashFile -Wait -PassThru
    if ($Process.ExitCode -ne 0) { Stop-Rc "Clash Verge Rev 安装器返回 $($Process.ExitCode)" }
} else {
    Write-Output "检测到现有 Clash Verge，未覆盖：$($KnownClash[0])"
}

Write-Output "RC INSTALL PASSED: $Platform"
Write-Output "Claude Code path: $ClaudeTarget"
Write-Output "Windows 专线路由尚未自动配置。"

$LauncherSource = Join-Path $RepoRoot "scripts\windows-deepseek.ps1"
if (-not (Test-Path -LiteralPath $LauncherSource -PathType Leaf)) { Stop-Rc "验证包缺少 DeepSeek 启动器" }
$LauncherDir = Join-Path $InstallRoot "bin"
$LauncherTarget = Join-Path $LauncherDir "start-deepseek.ps1"
$CommandTarget = Join-Path $LauncherDir "start-deepseek.cmd"
New-Item -ItemType Directory -Force -Path $LauncherDir | Out-Null
Copy-Item -LiteralPath $LauncherSource -Destination $LauncherTarget -Force
@'
@echo off
powershell.exe -NoProfile -File "%~dp0start-deepseek.ps1"
'@ | Set-Content -LiteralPath $CommandTarget -Encoding ASCII
Write-Output "DeepSeek 启动入口：$CommandTarget"
Write-Output "现在进入 DeepSeek API Key 隐藏输入和文本握手。"
& $LauncherTarget
