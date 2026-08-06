$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

# Publisher-repo Windows self-test: repository assertions (bootstrap.ps1 text,
# local-rc, dry-run cases) plus the RC-portable runtime subset.

$RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")).Path
$Bootstrap = Join-Path $RepoRoot "bootstrap.ps1"
$LocalRc = Join-Path $RepoRoot "scripts\windows-local-rc.ps1"
$StateTool = Join-Path $RepoRoot "scripts\setup-state.ps1"
$SubscriptionCheckpoint = Join-Path $RepoRoot "scripts\windows-subscription-checkpoint.ps1"
$EvidenceScript = Join-Path $RepoRoot "scripts\windows-evidence.ps1"
$RuntimeSelfTest = Join-Path $RepoRoot "scripts\windows-runtime-selftest.ps1"
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
    Test-PowerShellSyntax "Windows 旧 RC 兼容入口语法" $LocalRc
    Test-PowerShellSyntax "Windows 审计证据脚本语法" $EvidenceScript
    Test-PowerShellSyntax "Windows 运行期自测脚本语法" $RuntimeSelfTest

    $RuntimeOutputLines = @(& powershell.exe -NoProfile -File $RuntimeSelfTest -ScriptRoot (Join-Path $RepoRoot "scripts") 2>&1)
    $RuntimeExit = $LASTEXITCODE
    foreach ($Line in $RuntimeOutputLines) {
        $Text = [string]$Line
        if ($Text -match '^PASS\s+') {
            $script:Passed++
            Write-Output $Text
        } elseif ($Text -match '^FAIL\s+') {
            $script:Failed++
            Write-Output $Text
        } else {
            Write-Output $Text
        }
    }
    if ($RuntimeExit -ne 0) {
        Fail "Windows 运行期自测子集" "exit=$RuntimeExit"
    }

    $BootstrapText = Get-Content -LiteralPath $Bootstrap -Raw -Encoding UTF8
    $CheckpointPosition = $BootstrapText.IndexOf('$CheckpointOutput = @(& $CheckpointBlock')
    $ProxyVerificationPosition = $BootstrapText.IndexOf('$ReleaseManifestUrl = "$ClaudeOfficialBaseUrl/$ExpectedClaudeVersion/manifest.json"')
    $OfficialDownloadPosition = $BootstrapText.IndexOf('Invoke-Download $OfficialClaudeUrl $ClaudeDownload')
    if ($CheckpointPosition -ge 0 -and $ProxyVerificationPosition -gt $CheckpointPosition -and $OfficialDownloadPosition -gt $ProxyVerificationPosition) {
        Pass "Windows 代理实测与 Anthropic 下载严格位于订阅检查点之后"
    } else {
        Fail "Windows 代理实测与 Anthropic 下载严格位于订阅检查点之后" "调用顺序不安全"
    }
    if ($BootstrapText -match '40f281ff188f1cd4f39309da41a219014dad2555d96e9780c67a2138720d12ed' -and
        $BootstrapText -match 'PROXY_REACHABLE.*proxy_reachable') {
        Pass "Windows 代理检查使用固定官方元数据摘要并保存恢复点"
    } else {
        Fail "Windows 代理检查使用固定官方元数据摘要并保存恢复点" "代理实测固定值或恢复点缺失"
    }
    if ($BootstrapText -notmatch 'Unblock-File|ExecutionPolicy' -and
        $BootstrapText -match '\[scriptblock\]::Create\(\(Get-Content -LiteralPath \$CheckpointScript -Raw -Encoding UTF8\)\)' -and
        (Get-Content -LiteralPath $StateTool -Raw -Encoding UTF8) -notmatch 'exit\s+0' -and
        (Get-Content -LiteralPath $SubscriptionCheckpoint -Raw -Encoding UTF8) -notmatch 'exit\s+0') {
        Pass "Windows 不改执行策略且在已校验归档内存执行"
    } else {
        Fail "Windows 不改执行策略且在已校验归档内存执行" "仍存在解除阻止或文件执行入口"
    }
    if ($BootstrapText -match 'Assert-DirectoryTree' -and $BootstrapText -match '不重复下载 Clash 安装包' -and $BootstrapText -match 'WAITING_FOR_SUBSCRIPTION.*SUBSCRIPTION_IMPORTED') {
        Pass "Windows 续跑重验 lane 且不重复下载 Clash 安装包"
    } else {
        Fail "Windows 续跑重验 lane 且不重复下载 Clash 安装包" "恢复状态机静态门禁未满足"
    }
    if ($BootstrapText -match 'candidate-manifest\.json' -and
        $BootstrapText -match 'Join-Path \$InstallRoot "state"' ) {
        Pass "Windows bootstrap 持久化已校验候选 manifest"
    } else {
        Fail "Windows bootstrap 持久化已校验候选 manifest" "缺少 state\\candidate-manifest.json 写入"
    }

    $LocalRcText = Get-Content -LiteralPath $LocalRc -Raw -Encoding UTF8
    if ($LocalRcText -match 'is retired' -and $LocalRcText -match 'fixed OSS bootstrap\.ps1 entry') {
        Pass "旧 Windows 搬运 RC 已退役"
    } else {
        Fail "旧 Windows 搬运 RC 已退役" "兼容入口没有失败关闭"
    }

    $EvidenceText = Get-Content -LiteralPath $EvidenceScript -Raw -Encoding UTF8
    if ($EvidenceText -match 'sk-\[A-Za-z0-9_-]\{8,\}' -and
        $EvidenceText -match 'schema = 2' -and
        $EvidenceText -match 'processor_architew6432' -and
        $EvidenceText -match 'Protect-Directory' -and
        $EvidenceText -match 'Join-Path \$InstallRoot "audit"') {
        Pass "Windows 审计证据 schema 2 与失败关闭秘密扫描门禁"
    } else {
        Fail "Windows 审计证据 schema 2 与失败关闭秘密扫描门禁" "证据脚本静态门禁未满足"
    }

    $ProbeRoot = Join-Path $TempRoot "evidence-probe"
    $ProbeAudit = Join-Path $ProbeRoot "audit"
    New-Item -ItemType Directory -Path $ProbeRoot | Out-Null
    $ProbeFile = Join-Path $TempRoot "forged-evidence.json"
    # Documentation-reserved TEST-NET-3 address; must never be written to audit.
    '{"schema":2,"note":"forged-probe","host":"203.0.113.50"}' | Set-Content -LiteralPath $ProbeFile -Encoding UTF8
    $OldSetupRoot = $env:CLAUDE_LANE_SETUP_ROOT
    try {
        $env:CLAUDE_LANE_SETUP_ROOT = $ProbeRoot
        $ProbeOutput = (& powershell.exe -NoProfile -File $EvidenceScript -ProbeSecretFile $ProbeFile 2>&1 | Out-String)
        $ProbeFailed = $LASTEXITCODE -ne 0
        $WroteEvidence = $false
        if (Test-Path -LiteralPath $ProbeAudit -PathType Container) {
            $WroteEvidence = @(Get-ChildItem -LiteralPath $ProbeAudit -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -gt 0
        }
        if ($ProbeFailed -and -not $WroteEvidence -and $ProbeOutput -match 'IPv4|拒绝落盘') {
            Pass "Windows 证据含 IPv4 时拒绝落盘"
        } else {
            Fail "Windows 证据含 IPv4 时拒绝落盘" $ProbeOutput.Trim()
        }
    } finally {
        if ($null -eq $OldSetupRoot) { Remove-Item Env:CLAUDE_LANE_SETUP_ROOT -ErrorAction SilentlyContinue } else { $env:CLAUDE_LANE_SETUP_ROOT = $OldSetupRoot }
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
