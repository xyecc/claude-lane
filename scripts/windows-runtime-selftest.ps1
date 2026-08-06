[CmdletBinding()]
param(
    [string]$ScriptRoot = ""
)

# RC-portable runtime self-test. Only depends on lane-archive scripts:
# setup-state, windows-subscription-checkpoint, windows-routing, windows-verify,
# windows-rollback, windows-deepseek. No Git, no repo root, no bootstrap.ps1.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$ResolvedScriptRoot = if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
    (Resolve-Path -LiteralPath $ScriptRoot).Path
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
$DeepSeekLauncher = Join-Path $ResolvedScriptRoot "windows-deepseek.ps1"
$StateTool = Join-Path $ResolvedScriptRoot "setup-state.ps1"
$SubscriptionCheckpoint = Join-Path $ResolvedScriptRoot "windows-subscription-checkpoint.ps1"
$RoutingTool = Join-Path $ResolvedScriptRoot "windows-routing.ps1"
$RoutingVerifier = Join-Path $ResolvedScriptRoot "windows-verify.ps1"
$RoutingRollback = Join-Path $ResolvedScriptRoot "windows-rollback.ps1"
$CompleteTool = Join-Path $ResolvedScriptRoot "windows-complete.ps1"
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("claude-lane-windows-runtime-selftest-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempRoot | Out-Null
$Passed = 0
$Failed = 0

function Pass([string]$Name) { $script:Passed++; Write-Output "PASS  $Name" }
function Fail([string]$Name, [string]$Detail) { $script:Failed++; Write-Output "FAIL  $Name`n      $Detail" }
function Test-PowerShellSyntax([string]$Name, [string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail $Name "missing: $Path"
        return
    }
    $Tokens = $null
    $Errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count -eq 0) { Pass $Name } else { Fail $Name (($Errors | ForEach-Object { $_.Message }) -join "; ") }
}

try {
    Test-PowerShellSyntax "Windows DeepSeek 启动器语法" $DeepSeekLauncher
    Test-PowerShellSyntax "Windows 进度状态工具语法" $StateTool
    Test-PowerShellSyntax "Windows 订阅检查点语法" $SubscriptionCheckpoint
    Test-PowerShellSyntax "Windows 专线路由配置语法" $RoutingTool
    Test-PowerShellSyntax "Windows 专线路由六项验证语法" $RoutingVerifier
    Test-PowerShellSyntax "Windows 专线路由回滚语法" $RoutingRollback
    Test-PowerShellSyntax "Windows Phase 6 收尾语法" $CompleteTool

    $CheckpointConfig = Join-Path $TempRoot "checkpoint-config"
    $CheckpointState = Join-Path $TempRoot "checkpoint-state"
    New-Item -ItemType Directory -Path $CheckpointConfig | Out-Null
    "current: null`nitems: []`n" | Set-Content -LiteralPath (Join-Path $CheckpointConfig "profiles.yaml") -Encoding UTF8
    $OldConfigRoot = $env:CLAUDE_LANE_CLASH_CFG
    $OldStateRoot = $env:CLAUDE_LANE_SETUP_ROOT
    try {
        $env:CLAUDE_LANE_CLASH_CFG = $CheckpointConfig
        $env:CLAUDE_LANE_SETUP_ROOT = $CheckpointState
        $CheckpointResult = (& powershell.exe -NoProfile -File $SubscriptionCheckpoint -ScriptRoot $ResolvedScriptRoot 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0 -and $CheckpointResult -match 'SETUP_STATE=WAITING_FOR_SUBSCRIPTION') {
            Pass "Windows 首次启动 current:null 正常等待订阅"
        } else {
            Fail "Windows 首次启动 current:null 正常等待订阅" $CheckpointResult.Trim()
        }
    } finally {
        if ($null -eq $OldConfigRoot) { Remove-Item Env:CLAUDE_LANE_CLASH_CFG -ErrorAction SilentlyContinue } else { $env:CLAUDE_LANE_CLASH_CFG = $OldConfigRoot }
        if ($null -eq $OldStateRoot) { Remove-Item Env:CLAUDE_LANE_SETUP_ROOT -ErrorAction SilentlyContinue } else { $env:CLAUDE_LANE_SETUP_ROOT = $OldStateRoot }
    }

    $RoutingConfig = Join-Path $TempRoot "routing-config"
    $RoutingState = Join-Path $TempRoot "routing-state"
    New-Item -ItemType Directory -Path $RoutingConfig | Out-Null
    @"
current: SUB000000001
items:
- uid: SUB000000001
  type: remote
  name: Test.yaml
  file: SUB000000001.yaml
  url: https://example.invalid/sub
  option:
"@ | Set-Content -LiteralPath (Join-Path $RoutingConfig "profiles.yaml") -Encoding UTF8
    $OldConfigRoot = $env:CLAUDE_LANE_CLASH_CFG
    $OldStateRoot = $env:CLAUDE_LANE_SETUP_ROOT
    try {
        $env:CLAUDE_LANE_CLASH_CFG = $RoutingConfig
        $env:CLAUDE_LANE_SETUP_ROOT = $RoutingState
        $RoutingResult = (& powershell.exe -NoProfile -File $RoutingTool -ScriptRoot $ResolvedScriptRoot 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0 -and $RoutingResult -match 'SETUP_STATE=WAITING_FOR_ENHANCEMENT_FILES' -and $RoutingResult -notmatch 'example\.invalid') {
            Pass "Windows 缺增强文件时安全暂停且不泄漏订阅"
        } else {
            Fail "Windows 缺增强文件时安全暂停且不泄漏订阅" $RoutingResult.Trim()
        }
        $CheckpointResult = (& powershell.exe -NoProfile -File $SubscriptionCheckpoint -ScriptRoot $ResolvedScriptRoot 2>&1 | Out-String)
        $SavedRoutingState = Get-Content -LiteralPath (Join-Path $RoutingState "setup-progress.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0 -and $CheckpointResult -match 'SETUP_STATE=SUBSCRIPTION_IMPORTED' -and [string]$SavedRoutingState.state -eq "WAITING_FOR_ENHANCEMENT_FILES") {
            Pass "Windows 重验订阅时不降级后续恢复点"
        } else {
            Fail "Windows 重验订阅时不降级后续恢复点" $CheckpointResult.Trim()
        }
    } finally {
        if ($null -eq $OldConfigRoot) { Remove-Item Env:CLAUDE_LANE_CLASH_CFG -ErrorAction SilentlyContinue } else { $env:CLAUDE_LANE_CLASH_CFG = $OldConfigRoot }
        if ($null -eq $OldStateRoot) { Remove-Item Env:CLAUDE_LANE_SETUP_ROOT -ErrorAction SilentlyContinue } else { $env:CLAUDE_LANE_SETUP_ROOT = $OldStateRoot }
    }

    $RoutingText = Get-Content -LiteralPath $RoutingTool -Raw -Encoding UTF8
    $VerifyText = Get-Content -LiteralPath $RoutingVerifier -Raw -Encoding UTF8
    if ($RoutingText -match 'Read-Host\s+\$Prompt\s+-AsSecureString' -and
        $RoutingText -match 'Read-Secret\s+"静态 IP 密码（隐藏输入）"' -and
        $RoutingText -match 'ZeroFreeBSTR' -and $RoutingText -match 'SetAccessRuleProtection\(\$true, \$false\)' -and
        $RoutingText -notmatch 'Write-Output.*PasswordValue' -and
        $VerifyText -match 'VALIDATION PASSED: windows-routing' -and $VerifyText -match '\$Passed -eq 6') {
        Pass "Windows ISP 隐藏输入、受保护备份与六项门禁"
    } else {
        Fail "Windows ISP 隐藏输入、受保护备份与六项门禁" "路由脚本安全静态门禁未满足"
    }
    $AllPassedPosition = $VerifyText.IndexOf('if ($Failed -eq 0 -and $Passed -eq 6)')
    $BaselineWritePosition = $VerifyText.IndexOf('[IO.File]::WriteAllText($BaselineTemp')
    if ($AllPassedPosition -ge 0 -and $BaselineWritePosition -gt $AllPassedPosition -and
        $VerifyText -match '本地基线缺失' -and $VerifyText -match 'Set-Progress ROUTING_CONFIGURED routing_configured') {
        Pass "Windows 出口基线仅在六项全绿后保存且失败撤销通过状态"
    } else {
        Fail "Windows 出口基线仅在六项全绿后保存且失败撤销通过状态" "基线写入或失败状态门禁不安全"
    }

    $DeepSeekText = Get-Content -LiteralPath $DeepSeekLauncher -Raw -Encoding UTF8
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

    $CompleteText = Get-Content -LiteralPath $CompleteTool -Raw -Encoding UTF8
    $ResidueNames = @(
        "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_EFFORT_LEVEL", "CLAUDE_CONFIG_DIR",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CODE_SKIP_PROMPT_HISTORY",
        "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", "DISABLE_LOGIN_COMMAND", "DISABLE_UPDATES", "DISABLE_AUTOUPDATER"
    )
    $MissingEnvNames = @($ResidueNames | Where-Object { $CompleteText -notmatch [regex]::Escape($_) })
    # Entry order: gate → residue → clean login → human checklist → COMPLETED write.
    $EntryOrderOk = $CompleteText -match '(?s)Assert-ValidationPassed\s+Test-DeepSeekResidue\s+Start-CleanClaudeLogin\s+Confirm-HumanChecklist\s+Set-CompletedState'
    $CheckOnlyOk = $CompleteText -match '(?s)if\s*\(\s*\$CheckOnly\s*\)\s*\{[^}]*Test-DeepSeekResidue'
    $CompletedOnlyInSetter = ($CompleteText -match '-Set COMPLETED') -and
        ($CompleteText.IndexOf('function Set-CompletedState') -ge 0) -and
        ($CompleteText.IndexOf('-Set COMPLETED') -gt $CompleteText.IndexOf('function Set-CompletedState')) -and
        ($CompleteText.IndexOf('function Set-CompletedState') -gt $CompleteText.IndexOf('function Confirm-HumanChecklist'))
    if ($MissingEnvNames.Count -eq 0 -and $EntryOrderOk -and $CheckOnlyOk -and $CompletedOnlyInSetter -and
        $CompleteText -match '\[switch\]\$CheckOnly' -and
        $CompleteText -match 'VALIDATION_PASSED' -and
        $CompleteText -match 'claude-lane-deepseek-\*' -and
        $CompleteText -match 'EnvironmentVariableTarget\]::User' -and
        $CompleteText -match 'EnvironmentVariableTarget\]::Machine' -and
        $CompleteText -match 'PHASE6 COMPLETED: windows' -and
        $CompleteText -match 'Test-Path -Path \("Env:"' -and
        $CompleteText -notmatch 'Write-Output.*\$env:ANTHROPIC' -and
        $CompleteText -notmatch 'Write-Host.*\$env:ANTHROPIC') {
        Pass "Phase 6 收尾：16 变量残留检查、VALIDATION_PASSED 前置、COMPLETED 仅清单后写入"
    } else {
        Fail "Phase 6 收尾：16 变量残留检查、VALIDATION_PASSED 前置、COMPLETED 仅清单后写入" (
            "static gate failed; missing names=" + ($MissingEnvNames -join ","))
    }

    $ProbeValue = "sandbox-residue-value-must-never-appear-" + [guid]::NewGuid().ToString("N")
    $OldProbe = [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "Process")
    try {
        [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $ProbeValue, "Process")
        $CheckOutput = (& powershell.exe -NoProfile -File $CompleteTool -CheckOnly -ScriptRoot $ResolvedScriptRoot 2>&1 | Out-String)
        $CheckExit = $LASTEXITCODE
        if ($CheckExit -ne 0 -and $CheckOutput -notmatch [regex]::Escape($ProbeValue) -and
            $CheckOutput -match 'ANTHROPIC_BASE_URL' -and $CheckOutput -match '禁止登录 Anthropic') {
            Pass "伪造残留环境变量时 -CheckOnly 拒绝通过且不输出变量值"
        } else {
            Fail "伪造残留环境变量时 -CheckOnly 拒绝通过且不输出变量值" (
                "exit=$CheckExit output=" + $CheckOutput.Trim())
        }
    } finally {
        if ($null -eq $OldProbe) {
            [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $null, "Process")
        } else {
            [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $OldProbe, "Process")
        }
    }
} finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "Windows runtime selftest: $Passed passed, $Failed failed"
if ($Failed -ne 0) { exit 1 }
