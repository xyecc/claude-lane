[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [string]$ScriptRoot = ""
)

# Windows Phase 6: residue checks, clean Anthropic login, human checklist,
# then COMPLETED. Never prints environment variable values — only names.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

# Same 16 names as windows-deepseek.ps1 Set-ClaudeEnvironment Remove list.
$DeepSeekEnvNames = @(
    "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_EFFORT_LEVEL", "CLAUDE_CONFIG_DIR",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CODE_SKIP_PROMPT_HISTORY",
    "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", "DISABLE_LOGIN_COMMAND", "DISABLE_UPDATES", "DISABLE_AUTOUPDATER"
)

$ResolvedScriptRoot = if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
    (Resolve-Path -LiteralPath $ScriptRoot).Path
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
$StateTool = Join-Path $ResolvedScriptRoot "setup-state.ps1"
$StateRoot = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_LANE_SETUP_ROOT)) {
    $env:CLAUDE_LANE_SETUP_ROOT
} else {
    Join-Path $env:LOCALAPPDATA "claude-lane"
}
$StateFile = Join-Path $StateRoot "setup-progress.json"
# Fixed install paths match windows-deepseek.ps1 (not CLAUDE_LANE_SETUP_ROOT).
$ClaudeInstallRoot = Join-Path $env:LOCALAPPDATA "claude-lane"
$ClaudePath = Join-Path $ClaudeInstallRoot "tools\claude-code\2.1.220\claude.exe"
$LaneRoot = Join-Path $ClaudeInstallRoot "releases\v1.3.0"

function Stop-Complete([string]$Message) {
    throw "停止：$Message"
}
function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-PresentEnvNames {
    $Present = New-Object System.Collections.Generic.List[string]
    foreach ($Name in $DeepSeekEnvNames) {
        # Existence only — never read or emit values.
        if (Test-Path -Path ("Env:" + $Name)) {
            [void]$Present.Add($Name)
        }
    }
    return @($Present.ToArray())
}
function Get-FreshProcessPresentEnvNames {
    # Spawn a new powershell; collect name-only results via temp file (no pipe of secrets).
    $ResultFile = Join-Path ([IO.Path]::GetTempPath()) ("claude-lane-envcheck-" + [guid]::NewGuid().ToString("N") + ".txt")
    $Process = $null
    try {
        $QuotedNames = @()
        foreach ($Name in $DeepSeekEnvNames) {
            $QuotedNames += ('"{0}"' -f $Name)
        }
        $NameBlock = [string]::Join(",`r`n    ", $QuotedNames)
        $ResultLiteral = $ResultFile.Replace("'", "''")
        $ScriptBody = @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
`$Names = @(
    $NameBlock
)
`$Present = New-Object System.Collections.Generic.List[string]
foreach (`$Name in `$Names) {
    if (Test-Path -Path ("Env:" + `$Name)) { [void]`$Present.Add(`$Name) }
}
if (`$Present.Count -eq 0) {
    Set-Content -LiteralPath '$ResultLiteral' -Value 'CLEAN' -Encoding ASCII
} else {
    Set-Content -LiteralPath '$ResultLiteral' -Value ('PRESENT ' + (`$Present -join ' ')) -Encoding ASCII
}
"@
        # EncodedCommand avoids ExecutionPolicy blocks on temp .ps1 files; body only has names.
        $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ScriptBody))
        $Info = New-Object Diagnostics.ProcessStartInfo
        $Info.FileName = "powershell.exe"
        $Info.Arguments = "-NoProfile -NonInteractive -EncodedCommand $Encoded"
        $Info.UseShellExecute = $false
        $Info.CreateNoWindow = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Process = New-Object Diagnostics.Process
        $Process.StartInfo = $Info
        if (-not $Process.Start()) {
            Stop-Complete "无法启动干净 PowerShell 做环境残留检查"
        }
        $null = $Process.StandardOutput.ReadToEnd()
        $null = $Process.StandardError.ReadToEnd()
        $Process.WaitForExit()
        if ($Process.ExitCode -ne 0) {
            Stop-Complete "干净进程环境检查失败（exit $($Process.ExitCode)）。禁止登录 Anthropic。"
        }
        if (-not (Test-Path -LiteralPath $ResultFile -PathType Leaf)) {
            Stop-Complete "干净进程环境检查无结果文件。禁止登录 Anthropic。"
        }
        $Result = (Get-Content -LiteralPath $ResultFile -Raw -Encoding ASCII).Trim()
        if ($Result -eq "CLEAN") {
            return @()
        }
        if ($Result.StartsWith("PRESENT ")) {
            $NamesPart = $Result.Substring(8).Trim()
            if ([string]::IsNullOrWhiteSpace($NamesPart)) { return @() }
            return @($NamesPart.Split(@(" "), [StringSplitOptions]::RemoveEmptyEntries))
        }
        Stop-Complete "干净进程环境检查输出异常。禁止登录 Anthropic。"
    } finally {
        Remove-Item -LiteralPath $ResultFile -Force -ErrorAction SilentlyContinue
        if ($null -ne $Process) {
            try { $Process.Dispose() } catch {}
        }
    }
}
function Get-PersistedEnvNames {
    # Registry-scope residue: User/Machine values survive into every new terminal,
    # which a spawned child (inheriting this process env) cannot reveal.
    # Existence only — values are tested for presence, never printed.
    $Present = New-Object System.Collections.Generic.List[string]
    foreach ($Name in $DeepSeekEnvNames) {
        foreach ($Scope in @([EnvironmentVariableTarget]::User, [EnvironmentVariableTarget]::Machine)) {
            if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($Name, $Scope))) {
                [void]$Present.Add($Name)
                break
            }
        }
    }
    return @($Present.ToArray())
}
function Test-DeepSeekResidue {
    $CurrentPresent = @(Get-PresentEnvNames)
    if ($CurrentPresent.Count -gt 0) {
        Write-Output ("RESIDUE_CURRENT_PROCESS present: " + ($CurrentPresent -join " "))
        Stop-Complete ("当前进程仍有 DeepSeek 残留环境变量（仅列名）：" + ($CurrentPresent -join ", ") + "。禁止登录 Anthropic。请先走 windows-deepseek 清理路径或重启 PowerShell/机器后以 -CheckOnly 复查。")
    }
    Write-Output "RESIDUE_CURRENT_PROCESS clean"

    $FreshPresent = @(Get-FreshProcessPresentEnvNames)
    if ($FreshPresent.Count -gt 0) {
        Write-Output ("RESIDUE_FRESH_PROCESS present: " + ($FreshPresent -join " "))
        Stop-Complete ("干净新进程仍有 DeepSeek 残留环境变量（仅列名）：" + ($FreshPresent -join ", ") + "。禁止登录 Anthropic。请重启机器或清除用户/系统级环境变量后复查。")
    }
    Write-Output "RESIDUE_FRESH_PROCESS clean"

    $PersistedPresent = @(Get-PersistedEnvNames)
    if ($PersistedPresent.Count -gt 0) {
        Write-Output ("RESIDUE_PERSISTED_ENV present: " + ($PersistedPresent -join " "))
        Stop-Complete ("User/Machine 级注册表仍有 DeepSeek 残留环境变量（仅列名）：" + ($PersistedPresent -join ", ") + "。禁止登录 Anthropic。请在系统环境变量设置中删除后复查。")
    }
    Write-Output "RESIDUE_PERSISTED_ENV clean"

    $TempRoot = [IO.Path]::GetTempPath()
    $LeftoverNames = @()
    if (Test-Path -LiteralPath $TempRoot -PathType Container) {
        $LeftoverNames = @(Get-ChildItem -LiteralPath $TempRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "claude-lane-deepseek-*" } |
            ForEach-Object { $_.Name })
    }
    if ($LeftoverNames.Count -gt 0) {
        Write-Output ("RESIDUE_TEMP_DIRS present: " + ($LeftoverNames -join " "))
        Stop-Complete ("TEMP 下仍有 claude-lane-deepseek-* 目录残留：" + ($LeftoverNames -join ", ") + "。禁止登录 Anthropic。请删除后复查。")
    }
    Write-Output "RESIDUE_TEMP_DIRS clean"
    Write-Output "RESIDUE_CHECK_OK"
}
function Assert-ValidationPassed {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        Stop-Complete "缺少安装进度文件；Phase 6 要求状态已是 VALIDATION_PASSED"
    }
    $StateItem = Get-Item -LiteralPath $StateFile -Force
    if (($StateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-Complete "安装进度文件不能是重解析点"
    }
    $Document = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$Document.schema -ne 1) {
        Stop-Complete "安装进度 schema 无效（需要 1）"
    }
    if ([string]$Document.platform -ne "windows") {
        Stop-Complete "安装进度 platform 不是 windows"
    }
    $Current = [string]$Document.state
    if ($Current -ne "VALIDATION_PASSED") {
        Stop-Complete "前置门禁失败：当前状态为 $Current，需要 VALIDATION_PASSED 才能进入 Phase 6"
    }
    Write-Output "GATE_OK VALIDATION_PASSED"
}
function Assert-ControlledClaude {
    if (-not (Test-Path -LiteralPath $ClaudePath -PathType Leaf)) {
        Stop-Complete "未找到受控 Claude Code，请先重新运行同一条 bootstrap 命令"
    }
    $ClaudeItem = Get-Item -LiteralPath $ClaudePath -Force
    if (($ClaudeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-Complete "Claude Code 路径不能是重解析点"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $LaneRoot "VERSION") -PathType Leaf) -or
        (Get-Content -LiteralPath (Join-Path $LaneRoot "VERSION") -Raw -Encoding UTF8).Trim() -ne "1.3.0") {
        Stop-Complete "未找到固定版 claude-lane"
    }
    $Architecture = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }
    switch -Regex ($Architecture.ToUpperInvariant()) {
        "^(AMD64|X64)$" { $ExpectedHash = "af5bf1f1b2aadffc768eccd787084c6fdf9ba81624cbe96c1c6d9ac1a1550231" }
        "^ARM64$" { $ExpectedHash = "07343ace8a2e9ba87eed716e9c0261ce4bda8954c316695e4cb26fd0605de13c" }
        default { Stop-Complete "不支持的 Windows 架构：$Architecture" }
    }
    if ((Get-Sha256 $ClaudePath) -ne $ExpectedHash) {
        Stop-Complete "已安装 Claude Code SHA-256 不匹配"
    }
    $Signature = Get-AuthenticodeSignature -LiteralPath $ClaudePath
    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $Signature.SignerCertificate -or
        $Signature.SignerCertificate.Subject -notmatch 'Anthropic,? PBC') {
        Stop-Complete "已安装 Claude Code Authenticode 无效或发布者不匹配"
    }
}
function Start-CleanClaudeLogin {
    Assert-ControlledClaude
    $Info = New-Object Diagnostics.ProcessStartInfo
    $Info.FileName = $ClaudePath
    $Info.Arguments = ""
    $Info.WorkingDirectory = $LaneRoot
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $false
    # Do not inject any ANTHROPIC_*/CLAUDE_* ; scrub the DeepSeek list if inherited.
    foreach ($Name in $DeepSeekEnvNames) {
        $Info.EnvironmentVariables.Remove($Name)
    }
    $Process = $null
    try {
        $Process = New-Object Diagnostics.Process
        $Process.StartInfo = $Info
        if (-not $Process.Start()) {
            Stop-Complete "无法启动干净 Claude Code 登录进程"
        }
        Write-Output "已用不注入 DeepSeek/临时变量的新进程启动受控 claude.exe。"
        Write-Output "请在此窗口完成 Anthropic 正常登录；关闭该进程后脚本继续人工确认清单。"
        $Process.WaitForExit()
        Write-Output ("CLAUDE_LOGIN_EXIT=" + $Process.ExitCode)
    } finally {
        if ($null -ne $Process) {
            if (-not $Process.HasExited) {
                try { $Process.Kill(); $Process.WaitForExit() } catch {}
            }
            $Process.Dispose()
        }
    }
}
function Confirm-Yes([string]$Prompt) {
    $Answer = Read-Host ($Prompt + " [y/N]")
    if ($Answer -cne "y" -and $Answer -cne "Y") {
        Stop-Complete ("人工确认未通过（需要 y）：" + $Prompt)
    }
}
function Confirm-HumanChecklist {
    Write-Output ""
    Write-Output "=== Phase 6 人工确认清单（逐条输入 y 确认；非 y 则失败退出、不写 COMPLETED）==="
    Confirm-Yes "claude.ai → 设置 → 帐户 → 活跃会话：当前会话归属地已与静态出口地区一致"
    Confirm-Yes "已撤销归属地不符的旧会话，并已在专线出口下重新登录"
    Confirm-Yes "Claude → Settings → Privacy：Location metadata 与 Help improve our AI models 均已关闭"
    Confirm-Yes "Windows 区域设置已按 docs/account-safety.md 处理（区域/国家与美国出口一致；界面语言可不改）"
    Confirm-Yes "已知晓三条红线：不运行第二个 VPN；Clash 保持规则模式；先开 Clash 再开 Claude"
    Write-Output "HUMAN_CHECKLIST_OK"
}
function Set-CompletedState {
    if (-not (Test-Path -LiteralPath $StateTool -PathType Leaf)) {
        Stop-Complete "安装包缺少 setup-state.ps1"
    }
    $StateBlock = [scriptblock]::Create((Get-Content -LiteralPath $StateTool -Raw -Encoding UTF8))
    & $StateBlock -Set COMPLETED -Reason completed | Out-Null
    Write-Output "SETUP_STATE=COMPLETED"
    Write-Output "PHASE6 COMPLETED: windows"
}

# --- entry ---
if ($CheckOnly) {
    # Residue only: no state write, no login launch.
    Test-DeepSeekResidue
    return
}

Assert-ValidationPassed
Test-DeepSeekResidue
Start-CleanClaudeLogin
Confirm-HumanChecklist
Set-CompletedState
