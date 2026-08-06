[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$ManifestFile = ""
)

# Deterministic Windows bootstrap. Supports Windows 10 1809+ on x64/ARM64.
# It stages only fixed, signed artifacts and never logs in to Anthropic.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ExpectedSchema = 1
$ExpectedReleaseStatus = "released"
$ReleaseChannel = "stable"
$ExpectedLaneVersion = "1.3.0"
$ExpectedClaudeVersion = "2.1.220"
$ExpectedClashVersion = "2.5.2"
$Expected = @{
    "claude-win32-arm64" = "07343ace8a2e9ba87eed716e9c0261ce4bda8954c316695e4cb26fd0605de13c"
    "claude-win32-x64" = "af5bf1f1b2aadffc768eccd787084c6fdf9ba81624cbe96c1c6d9ac1a1550231"
    "clash-win32-arm64" = "973fafb5f154e541b34c1315f7de7440daf68d05f2e52fa08da2bcc71b6c3214"
    "clash-win32-x64" = "ba42f00b1082e352352080170fe86ae411bcc854cb13f1b8bebc9025e8a7cbf4"
}

# Release block. Alibaba OSS's own hostname avoids a custom domain, CDN and ICP filing.
$PrimaryBaseUrl = "https://claude-lane-release-prod-20260802-k7m3q9.oss-cn-beijing.aliyuncs.com"
$BackupBaseUrl = ""
$ClaudeOfficialBaseUrl = "https://downloads.claude.ai/claude-code-releases"
$StableManifestPath = "manifests/stable.json"
$StableManifestSha256 = "TBD"
$TestMode = $env:CL_BOOT_TEST_MODE -eq "1"
$TempRoot = ""

function Stop-Bootstrap([string]$Message) { throw "停止：$Message" }
function Test-Sha256([string]$Value) { return $Value -match '^[0-9a-fA-F]{64}$' -and $Value -notmatch '^0{64}$' }
function Test-Placeholder([string]$Value) { return [string]::IsNullOrWhiteSpace($Value) -or $Value -match '(?i)TBD|TODO|\.invalid|待发布|待填写' }
function Test-RelativePath([string]$Value) {
    return -not (Test-Placeholder $Value) -and $Value -match '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -and
        $Value -notmatch '(^|/)\.\.(/|$)' -and $Value -notmatch '(?i)(^|[._/-])latest([._/-]|$)'
}
function Get-ArchitectureName {
    $Name = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($Name.ToUpperInvariant()) {
        '^(AMD64|X64)$' { return 'x64' }
        '^ARM64$' { return 'arm64' }
        default { Stop-Bootstrap "不支持的 Windows CPU 架构：$Name" }
    }
}
function Get-FileSha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Join-DownloadUrl([string]$Base, [string]$Path) { return $Base.TrimEnd('/') + '/' + $Path.TrimStart('/') }
function Invoke-Download([string]$Url, [string]$Output) {
    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Output -TimeoutSec 600 -MaximumRedirection 5
            return
        } catch {
            Remove-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue
            if ($Attempt -eq 3) { throw }
            Start-Sleep -Seconds 2
        }
    }
}
function Get-CheckedArtifact([string]$Path, [string]$Sha256, [string]$Destination, [string]$Label) {
    foreach ($Base in @($PrimaryBaseUrl, $BackupBaseUrl)) {
        if ([string]::IsNullOrWhiteSpace($Base)) { continue }
        $Part = "$Destination.part"
        Remove-Item -LiteralPath $Part -Force -ErrorAction SilentlyContinue
        try {
            Write-Output "下载 $Label：$Base"
            Invoke-Download (Join-DownloadUrl $Base $Path) $Part
            if ((Get-FileSha256 $Part) -eq $Sha256.ToLowerInvariant()) {
                Move-Item -LiteralPath $Part -Destination $Destination
                return
            }
            Write-Warning "$Label 摘要不一致，尝试下一个已配置国内源"
        } catch {
            Write-Warning "$Label 下载失败，尝试下一个已配置国内源"
        }
    }
    Stop-Bootstrap "$Label 的已配置国内源均未通过下载与 SHA-256 校验"
}
function Assert-Authenticode([string]$Path, [string]$PublisherPattern, [string]$Label) {
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) { Stop-Bootstrap "$Label Authenticode 无效：$($Signature.Status)" }
    if ($null -eq $Signature.SignerCertificate -or $Signature.SignerCertificate.Subject -notmatch $PublisherPattern) { Stop-Bootstrap "$Label 发布者不在固定允许列表" }
}
function Assert-ClashSignature([string]$Path, [string]$ExpectedStatus) {
    if ($ExpectedStatus -ne "verified-tauri-minisign-runtime-authenticode") { Stop-Bootstrap "Clash Verge Rev 上游签名策略不受支持" }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid) {
        if ($null -eq $Signature.SignerCertificate -or $Signature.SignerCertificate.Subject -notmatch 'Clash|Verge') { Stop-Bootstrap "Clash Verge Rev 发布者不在固定允许列表" }
        return
    }
    if ($Signature.Status -eq [System.Management.Automation.SignatureStatus]::NotSigned) {
        Write-Warning "上游 Clash 安装器未带 Authenticode；已由发布端 Tauri minisign 与固定 SHA-256 双重锁定。"
        return
    }
    Stop-Bootstrap "Clash Verge Rev Authenticode 状态异常：$($Signature.Status)"
}
function Assert-ZipEntries([string]$ZipPath, [string]$ExpectedRoot) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($Entry in $Zip.Entries) {
            $Name = $Entry.FullName.Replace('\', '/')
            if ($Name.StartsWith('/') -or $Name -match '(^|/)\.\.(/|$)' -or $Name -match '^[A-Za-z]:') { Stop-Bootstrap "claude-lane ZIP 含不安全路径" }
            if (-not $Name.StartsWith("$ExpectedRoot/")) { Stop-Bootstrap "claude-lane ZIP 根目录不符合 manifest" }
        }
    } finally { $Zip.Dispose() }
}
function Assert-DirectoryTree([string]$ExpectedRoot, [string]$ActualRoot) {
    $ExpectedPrefix = $ExpectedRoot.TrimEnd('\') + '\'
    $ActualPrefix = $ActualRoot.TrimEnd('\') + '\'
    $ExpectedFiles = @{}
    $ActualFiles = @{}
    foreach ($Item in @(Get-ChildItem -LiteralPath $ExpectedRoot -Recurse -Force)) {
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Bootstrap "固定 lane 归档含重解析点" }
        if (-not $Item.PSIsContainer) {
            $Relative = $Item.FullName.Substring($ExpectedPrefix.Length).Replace('\', '/')
            $ExpectedFiles[$Relative] = Get-FileSha256 $Item.FullName
        }
    }
    foreach ($Item in @(Get-ChildItem -LiteralPath $ActualRoot -Recurse -Force)) {
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Bootstrap "续跑的 claude-lane 目录含重解析点" }
        if (-not $Item.PSIsContainer) {
            $Relative = $Item.FullName.Substring($ActualPrefix.Length).Replace('\', '/')
            $ActualFiles[$Relative] = Get-FileSha256 $Item.FullName
        }
    }
    if ($ExpectedFiles.Count -ne $ActualFiles.Count) { Stop-Bootstrap "续跑的 claude-lane 文件清单与固定归档不一致" }
    foreach ($Relative in $ExpectedFiles.Keys) {
        if (-not $ActualFiles.ContainsKey($Relative) -or $ActualFiles[$Relative] -ne $ExpectedFiles[$Relative]) {
            Stop-Bootstrap "续跑的 claude-lane 内容与固定归档不一致"
        }
    }
}

try {
    if (-not [Environment]::Is64BitOperatingSystem) { Stop-Bootstrap "只支持 64 位 Windows" }
    if ([Environment]::OSVersion.Version -lt [Version]"10.0.17763") { Stop-Bootstrap "需要 Windows 10 1809 或更高版本" }
    if (-not [string]::IsNullOrWhiteSpace($ManifestFile) -and -not $TestMode) { Stop-Bootstrap "-ManifestFile 只允许在 CL_BOOT_TEST_MODE=1 下使用" }
    if ($TestMode -and (-not $DryRun -or [string]::IsNullOrWhiteSpace($ManifestFile))) { Stop-Bootstrap "测试模式只允许带 manifest 的 -DryRun" }

    $Arch = Get-ArchitectureName
    $TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("claude-lane-bootstrap-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $TempRoot | Out-Null

    if ([string]::IsNullOrWhiteSpace($ManifestFile)) {
        if (Test-Placeholder $PrimaryBaseUrl -or -not $PrimaryBaseUrl.StartsWith("https://", [StringComparison]::OrdinalIgnoreCase)) { Stop-Bootstrap "国内主下载源尚未发布，启动器保持失败关闭" }
        if (-not [string]::IsNullOrWhiteSpace($BackupBaseUrl) -and (Test-Placeholder $BackupBaseUrl -or -not $BackupBaseUrl.StartsWith("https://", [StringComparison]::OrdinalIgnoreCase))) { Stop-Bootstrap "备用下载源配置无效" }
        if (-not (Test-Sha256 $StableManifestSha256)) { Stop-Bootstrap "$ReleaseChannel manifest 固定摘要尚未发布" }
        $ManifestFile = Join-Path $TempRoot "stable.json"
        Get-CheckedArtifact $StableManifestPath $StableManifestSha256 $ManifestFile "$ReleaseChannel manifest"
    }
    $ManifestFile = (Resolve-Path -LiteralPath $ManifestFile).Path
    $Manifest = Get-Content -LiteralPath $ManifestFile -Raw | ConvertFrom-Json

    if ([int]$Manifest.schema -ne $ExpectedSchema) { Stop-Bootstrap "不支持的 manifest schema" }
    if ([string]$Manifest.release_status -ne $ExpectedReleaseStatus) { Stop-Bootstrap "manifest 尚未达到 $ExpectedReleaseStatus 状态" }
    if ([string]$Manifest.claude_lane.version -ne $ExpectedLaneVersion -or [string]$Manifest.claude_code.version -ne $ExpectedClaudeVersion -or [string]$Manifest.clash_verge.version -ne $ExpectedClashVersion) { Stop-Bootstrap "manifest 固定版本漂移" }
    if ([string]$Manifest.minimum_windows -ne "10.0.17763") { Stop-Bootstrap "Windows 最低版本门禁漂移" }

    $ClaudeKey = "win32_$Arch"
    $ClaudeEntry = $Manifest.claude_code.$ClaudeKey
    $ClashEntry = $Manifest.clash_verge.$ClaudeKey
    $LanePath = [string]$Manifest.claude_lane.windows_path
    $LaneSha = [string]$Manifest.claude_lane.windows_sha256
    foreach ($EntryPath in @($LanePath, [string]$ClashEntry.path)) { if (-not (Test-RelativePath $EntryPath)) { Stop-Bootstrap "manifest 含无效 Windows 路径" } }
    if (-not (Test-Sha256 $LaneSha)) { Stop-Bootstrap "claude-lane Windows ZIP 摘要尚未发布" }
    if ([string]$ClaudeEntry.sha256 -ne $Expected["claude-win32-$Arch"] -or [string]$ClashEntry.sha256 -ne $Expected["clash-win32-$Arch"]) { Stop-Bootstrap "Windows 固定摘要漂移" }
    if ([string]$Manifest.claude_code.distribution -ne "anthropic-official-after-proxy") { Stop-Bootstrap "Claude Code 必须在代理可用后从 Anthropic 官方源安装" }
    if ([string]$ClashEntry.signature_status -ne "verified-tauri-minisign-runtime-authenticode") { Stop-Bootstrap "Clash Verge 上游签名证据尚未完成" }

    Write-Output "Windows 架构：$Arch"
    if ($DryRun) { Write-Output "dry-run 通过：固定版本、路径、摘要及 Windows 签名证据门禁有效"; exit 0 }

    $env:DISABLE_UPDATES = "1"
    $env:DISABLE_AUTOUPDATER = "1"
    $InstallRoot = Join-Path $env:LOCALAPPDATA "claude-lane"
    $LaneRoot = [string]$Manifest.claude_lane.archive_root
    $ReleaseTarget = Join-Path $InstallRoot "releases\v$ExpectedLaneVersion"
    $KnownClash = @(@((Join-Path $env:LOCALAPPDATA "Programs\Clash Verge\Clash Verge.exe"), (Join-Path $env:ProgramFiles "Clash Verge\Clash Verge.exe")) | Where-Object { Test-Path -LiteralPath $_ })
    $StateFile = Join-Path $InstallRoot "setup-progress.json"
    $ResumeReady = $false
    if ((Test-Path -LiteralPath $StateFile -PathType Leaf) -and (Test-Path -LiteralPath $ReleaseTarget -PathType Container) -and $KnownClash.Count -gt 0) {
        $SavedState = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        if ([int]$SavedState.schema -ne 1) { Stop-Bootstrap "安装进度文件 schema 无效" }
        if (@("WAITING_FOR_SUBSCRIPTION", "SUBSCRIPTION_IMPORTED") -contains [string]$SavedState.state) {
            $InstalledVersion = Join-Path $ReleaseTarget "VERSION"
            if (-not (Test-Path -LiteralPath $InstalledVersion -PathType Leaf) -or (Get-Content -LiteralPath $InstalledVersion -Raw).Trim() -ne $ExpectedLaneVersion) { Stop-Bootstrap "续跑所需的固定版 claude-lane 缺失" }
            $ResumeLaneDownload = Join-Path $TempRoot "resume-claude-lane.zip"
            $ResumeExtract = Join-Path $TempRoot "resume-lane"
            Get-CheckedArtifact $LanePath $LaneSha $ResumeLaneDownload "claude-lane 续跑校验包"
            Assert-ZipEntries $ResumeLaneDownload $LaneRoot
            [IO.Compression.ZipFile]::ExtractToDirectory($ResumeLaneDownload, $ResumeExtract)
            Assert-DirectoryTree (Join-Path $ResumeExtract $LaneRoot) $ReleaseTarget
            Assert-ClashSignature $KnownClash[0] ([string]$ClashEntry.signature_status)
            $ResumeReady = $true
            Write-Output "检测到已安装 Clash Verge 与固定版 lane；已重验小型 lane 包，不重复下载 Clash 安装包。"
        }
    }

    if (-not $ResumeReady) {
        $ClashDownload = Join-Path $TempRoot "clash-setup.exe"
        $LaneDownload = Join-Path $TempRoot "claude-lane.zip"
        Get-CheckedArtifact ([string]$ClashEntry.path) ([string]$ClashEntry.sha256) $ClashDownload "Clash Verge Rev"
        Get-CheckedArtifact $LanePath $LaneSha $LaneDownload "claude-lane"
        Assert-ClashSignature $ClashDownload ([string]$ClashEntry.signature_status)
        Assert-ZipEntries $LaneDownload $LaneRoot
        if (-not (Test-Path -LiteralPath $ReleaseTarget)) {
            $Extract = Join-Path $TempRoot "lane"
            [IO.Compression.ZipFile]::ExtractToDirectory($LaneDownload, $Extract)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ReleaseTarget) | Out-Null
            Move-Item -LiteralPath (Join-Path $Extract $LaneRoot) -Destination $ReleaseTarget
        }

        if ($KnownClash.Count -eq 0) {
            Write-Output "启动已通过固定摘要和上游 Tauri minisign 验证的 Clash Verge Rev 安装器；请在 Windows 界面中确认安装。"
            $Process = Start-Process -FilePath $ClashDownload -Wait -PassThru
            if ($Process.ExitCode -ne 0) { Stop-Bootstrap "Clash Verge Rev 安装器返回 $($Process.ExitCode)" }
        } else {
            Write-Output "检测到现有 Clash Verge，未覆盖：$($KnownClash[0])"
        }
    } else {
        Write-Output "已恢复上一轮安装状态。"
    }

    $StateScript = Join-Path $ReleaseTarget "scripts\setup-state.ps1"
    $CheckpointScript = Join-Path $ReleaseTarget "scripts\windows-subscription-checkpoint.ps1"
    if (-not (Test-Path -LiteralPath $StateScript -PathType Leaf) -or -not (Test-Path -LiteralPath $CheckpointScript -PathType Leaf)) { Stop-Bootstrap "安装包缺少订阅检查点" }
    $StateBlock = [scriptblock]::Create((Get-Content -LiteralPath $StateScript -Raw))
    $CheckpointBlock = [scriptblock]::Create((Get-Content -LiteralPath $CheckpointScript -Raw))
    if (-not $ResumeReady) { & $StateBlock -Set CLASH_INSTALLED -Reason clash_installed | Out-Null }
    $CheckpointOutput = @(& $CheckpointBlock -ScriptRoot (Split-Path -Parent $CheckpointScript))
    $CheckpointOutput | Write-Output
    if ($CheckpointOutput -contains "SETUP_STATE=WAITING_FOR_SUBSCRIPTION") {
        Write-Output "Windows 固定版下载与安装阶段完成；当前正常暂停在“等待机场订阅”。"
        Write-Output "请在 Clash Verge → 订阅中粘贴订阅链接并更新；完成后重新运行同一启动命令。"
        exit 0
    }
    if ($CheckpointOutput -notcontains "SETUP_STATE=SUBSCRIPTION_IMPORTED") { Stop-Bootstrap "订阅检查点返回未知状态" }

    # 只有订阅检查点通过后才允许请求 Anthropic 官方下载域名。
    $ClaudeTarget = Join-Path $InstallRoot "tools\claude-code\$ExpectedClaudeVersion\claude.exe"
    if (Test-Path -LiteralPath $ClaudeTarget -PathType Leaf) {
        if ((Get-FileSha256 $ClaudeTarget) -ne [string]$ClaudeEntry.sha256) { Stop-Bootstrap "现有受控 Claude Code 与固定摘要不符；拒绝覆盖" }
        Assert-Authenticode $ClaudeTarget 'Anthropic,? PBC' "现有 Claude Code"
    } else {
        $ClaudeDownload = Join-Path $TempRoot "claude.exe"
        $OfficialClaudeUrl = "$ClaudeOfficialBaseUrl/$ExpectedClaudeVersion/win32-$Arch/claude.exe"
        Write-Output "机场订阅已就绪；从 Anthropic 官方源下载固定版 Claude Code $ExpectedClaudeVersion"
        Invoke-Download $OfficialClaudeUrl $ClaudeDownload
        if ((Get-FileSha256 $ClaudeDownload) -ne [string]$ClaudeEntry.sha256) { Stop-Bootstrap "Anthropic 官方 Claude Code SHA-256 不匹配" }
        Assert-Authenticode $ClaudeDownload 'Anthropic,? PBC' "Claude Code"
        $ClaudeOutput = (& $ClaudeDownload --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $ClaudeOutput -notmatch [regex]::Escape($ExpectedClaudeVersion)) { Stop-Bootstrap "Claude Code 实际版本不符" }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ClaudeTarget) | Out-Null
        Move-Item -LiteralPath $ClaudeDownload -Destination $ClaudeTarget
    }

    $DeepSeekLauncher = Join-Path $ReleaseTarget "scripts\windows-deepseek.ps1"
    if (-not (Test-Path -LiteralPath $DeepSeekLauncher -PathType Leaf)) { Stop-Bootstrap "安装包缺少 Windows DeepSeek 启动器" }
    Write-Output "Claude Code 官方固定版安装与签名校验通过；进入本地 DeepSeek 与专线配置阶段。"
    $LauncherText = Get-Content -LiteralPath $DeepSeekLauncher -Raw
    & ([scriptblock]::Create($LauncherText))
} finally {
    Remove-Item Env:DISABLE_UPDATES -ErrorAction SilentlyContinue
    Remove-Item Env:DISABLE_AUTOUPDATER -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($TempRoot) -and (Test-Path -LiteralPath $TempRoot)) { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
