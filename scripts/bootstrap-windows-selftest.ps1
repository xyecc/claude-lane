$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")).Path
$Bootstrap = Join-Path $RepoRoot "bootstrap.ps1"
$DeepSeekLauncher = Join-Path $RepoRoot "scripts\windows-deepseek.ps1"
$LocalRc = Join-Path $RepoRoot "scripts\windows-local-rc.ps1"
$StateTool = Join-Path $RepoRoot "scripts\setup-state.ps1"
$SubscriptionCheckpoint = Join-Path $RepoRoot "scripts\windows-subscription-checkpoint.ps1"
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("claude-lane-windows-selftest-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempRoot | Out-Null
$Passed = 0
$Failed = 0
$Architecture = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
    $env:PROCESSOR_ARCHITEW6432
} else {
    $env:PROCESSOR_ARCHITECTURE
}
$IsArm64 = $Architecture.ToUpperInvariant() -eq "ARM64"

function Pass([string]$Name) { $script:Passed++; Write-Output "PASS  $Name" }
function Fail([string]$Name, [string]$Detail) { $script:Failed++; Write-Output "FAIL  $Name`n      $Detail" }
function Test-PowerShellSyntax([string]$Name, [string]$Path) {
    $Tokens = $null
    $Errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count -eq 0) { Pass $Name } else { Fail $Name (($Errors | ForEach-Object { $_.Message }) -join "; ") }
}
function Invoke-Case([string]$Name, [object]$Manifest, [bool]$ShouldPass, [string]$Expected) {
    $Path = Join-Path $TempRoot (([guid]::NewGuid().ToString("N")) + ".json")
    $Manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
    $Old = $env:CL_BOOT_TEST_MODE
    try {
        $env:CL_BOOT_TEST_MODE = "1"
        $Output = (& powershell.exe -NoProfile -File $Bootstrap -DryRun -ManifestFile $Path 2>&1 | Out-String)
        $Succeeded = $LASTEXITCODE -eq 0
        if ($Succeeded -eq $ShouldPass -and $Output -match [regex]::Escape($Expected)) { Pass $Name } else { Fail $Name $Output.Trim() }
    } finally {
        if ($null -eq $Old) { Remove-Item Env:CL_BOOT_TEST_MODE -ErrorAction SilentlyContinue } else { $env:CL_BOOT_TEST_MODE = $Old }
    }
}

try {
    Test-PowerShellSyntax "Windows DeepSeek 启动器语法" $DeepSeekLauncher
    Test-PowerShellSyntax "Windows 旧 RC 兼容入口语法" $LocalRc
    Test-PowerShellSyntax "Windows 进度状态工具语法" $StateTool
    Test-PowerShellSyntax "Windows 订阅检查点语法" $SubscriptionCheckpoint
    $CheckpointConfig = Join-Path $TempRoot "checkpoint-config"
    $CheckpointState = Join-Path $TempRoot "checkpoint-state"
    New-Item -ItemType Directory -Path $CheckpointConfig | Out-Null
    "current: null`nitems: []`n" | Set-Content -LiteralPath (Join-Path $CheckpointConfig "profiles.yaml") -Encoding UTF8
    $OldConfigRoot = $env:CLAUDE_LANE_CLASH_CFG
    $OldStateRoot = $env:CLAUDE_LANE_SETUP_ROOT
    try {
        $env:CLAUDE_LANE_CLASH_CFG = $CheckpointConfig
        $env:CLAUDE_LANE_SETUP_ROOT = $CheckpointState
        $CheckpointResult = (& powershell.exe -NoProfile -File $SubscriptionCheckpoint 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0 -and $CheckpointResult -match 'SETUP_STATE=WAITING_FOR_SUBSCRIPTION') {
            Pass "Windows 首次启动 current:null 正常等待订阅"
        } else {
            Fail "Windows 首次启动 current:null 正常等待订阅" $CheckpointResult.Trim()
        }
    } finally {
        if ($null -eq $OldConfigRoot) { Remove-Item Env:CLAUDE_LANE_CLASH_CFG -ErrorAction SilentlyContinue } else { $env:CLAUDE_LANE_CLASH_CFG = $OldConfigRoot }
        if ($null -eq $OldStateRoot) { Remove-Item Env:CLAUDE_LANE_SETUP_ROOT -ErrorAction SilentlyContinue } else { $env:CLAUDE_LANE_SETUP_ROOT = $OldStateRoot }
    }
    $BootstrapText = Get-Content -LiteralPath $Bootstrap -Raw
    $CheckpointPosition = $BootstrapText.IndexOf('$CheckpointOutput = @(& $CheckpointScript)')
    $OfficialDownloadPosition = $BootstrapText.IndexOf('Invoke-Download $OfficialClaudeUrl $ClaudeDownload')
    if ($CheckpointPosition -ge 0 -and $OfficialDownloadPosition -gt $CheckpointPosition) {
        Pass "Windows Anthropic 官方下载严格位于订阅检查点之后"
    } else {
        Fail "Windows Anthropic 官方下载严格位于订阅检查点之后" "调用顺序不安全"
    }
    if ($BootstrapText -match 'Assert-DirectoryTree' -and $BootstrapText -match '不重复下载 Clash 安装包' -and $BootstrapText -match 'WAITING_FOR_SUBSCRIPTION.*SUBSCRIPTION_IMPORTED') {
        Pass "Windows 续跑重验 lane 且不重复下载 Clash 安装包"
    } else {
        Fail "Windows 续跑重验 lane 且不重复下载 Clash 安装包" "恢复状态机静态门禁未满足"
    }
    $DeepSeekText = Get-Content -LiteralPath $DeepSeekLauncher -Raw
    if ($DeepSeekText -match 'Read-Host\s+"DeepSeek API Key"\s+-AsSecureString' -and
        $DeepSeekText -match 'SecureStringToBSTR' -and $DeepSeekText -match 'ZeroFreeBSTR' -and
        $DeepSeekText -match 'EnvironmentVariables\["ANTHROPIC_AUTH_TOKEN"\]' -and
        $DeepSeekText -notmatch '\$env:ANTHROPIC_AUTH_TOKEN\s*=' -and
        $DeepSeekText -notmatch '\.Arguments\s*=.*AuthToken') {
        Pass "DeepSeek Key 隐藏输入且不进入当前环境或 argv"
    } else {
        Fail "DeepSeek Key 隐藏输入且不进入当前环境或 argv" "安全注入静态门禁未满足"
    }
    if ($DeepSeekText -match '--tools\s+"Read,Edit,Write"' -and
        $DeepSeekText -notmatch '--tools\s+"Bash' -and
        $DeepSeekText -match 'CLAUDE_CODE_SUBPROCESS_ENV_SCRUB' -and
        $DeepSeekText -match 'Remove-Item -LiteralPath \$TempConfig -Recurse') {
        Pass "DeepSeek 临时会话隔离工具并清理配置"
    } else {
        Fail "DeepSeek 临时会话隔离工具并清理配置" "工具或清理静态门禁未满足"
    }
    $LocalRcText = Get-Content -LiteralPath $LocalRc -Raw
    if ($LocalRcText -match 'is retired' -and $LocalRcText -match 'fixed OSS bootstrap\.ps1 entry') {
        Pass "旧 Windows 搬运 RC 已退役"
    } else {
        Fail "旧 Windows 搬运 RC 已退役" "兼容入口没有失败关闭"
    }

    $Manifest = [ordered]@{
        schema = 1; release_status = "released"; minimum_windows = "10.0.17763"; required_free_mb = 2048
        claude_lane = [ordered]@{ version = "1.3.0"; windows_path = "claude-lane/releases/v1.3.0/claude-lane.zip"; archive_root = "claude-lane-1.3.0"; windows_sha256 = ("1" * 64) }
        claude_code = [ordered]@{
            version = "2.1.220"
            distribution = "anthropic-official-after-proxy"
            win32_arm64 = [ordered]@{ sha256 = "07343ace8a2e9ba87eed716e9c0261ce4bda8954c316695e4cb26fd0605de13c" }
            win32_x64 = [ordered]@{ sha256 = "af5bf1f1b2aadffc768eccd787084c6fdf9ba81624cbe96c1c6d9ac1a1550231" }
        }
        clash_verge = [ordered]@{
            version = "2.5.2"
            win32_arm64 = [ordered]@{ path = "clash-verge/releases/v2.5.2/Clash.Verge_2.5.2_arm64-setup.exe"; sha256 = "973fafb5f154e541b34c1315f7de7440daf68d05f2e52fa08da2bcc71b6c3214"; signature_status = "verified-tauri-minisign-runtime-authenticode" }
            win32_x64 = [ordered]@{ path = "clash-verge/releases/v2.5.2/Clash.Verge_2.5.2_x64-setup.exe"; sha256 = "ba42f00b1082e352352080170fe86ae411bcc854cb13f1b8bebc9025e8a7cbf4"; signature_status = "verified-tauri-minisign-runtime-authenticode" }
        }
    }
    Invoke-Case "有效 Windows 固定清单 dry-run 通过" $Manifest $true "dry-run 通过"
    $BadHash = $Manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    if ($IsArm64) { $BadHash.claude_code.win32_arm64.sha256 = "2" * 64 } else { $BadHash.claude_code.win32_x64.sha256 = "2" * 64 }
    Invoke-Case "Windows 固定摘要漂移停止" $BadHash $false "固定摘要漂移"
    $Pending = $Manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    if ($IsArm64) { $Pending.clash_verge.win32_arm64.signature_status = "pending" } else { $Pending.clash_verge.win32_x64.signature_status = "pending" }
    Invoke-Case "Windows Authenticode 证据缺失停止" $Pending $false "证据尚未完成"
    $Unsafe = $Manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $Unsafe.claude_lane.windows_path = "../outside.zip"
    Invoke-Case "Windows ZIP 越界路径停止" $Unsafe $false "无效 Windows 路径"
} finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Windows bootstrap selftest: $Passed passed, $Failed failed"
if ($Failed -ne 0) { exit 1 }
