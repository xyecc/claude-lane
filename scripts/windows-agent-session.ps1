[CmdletBinding()]
param(
    [string]$ScriptRoot = ""
)

# v1.4 Windows agent session: verify the pinned Claude Code binary, read the
# DeepSeek key as SecureString, handshake, then start an interactive session
# that reads RUNBOOK-WIN.md and drives the audited toolbox scripts. The key
# lives only in the child process environment; permission-mode stays default
# so every command the agent runs is confirmed by the user in the UI.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$ResolvedScriptRoot = if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
    (Resolve-Path -LiteralPath $ScriptRoot).Path
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
$RepoRoot = (Resolve-Path (Join-Path $ResolvedScriptRoot "..")).Path
$RunbookPath = Join-Path $RepoRoot "RUNBOOK-WIN.md"
$InstallRoot = Join-Path $env:LOCALAPPDATA "claude-lane"
$ClaudePath = Join-Path $InstallRoot "tools\claude-code\2.1.220\claude.exe"
$TempConfig = Join-Path ([IO.Path]::GetTempPath()) ("claude-lane-agent-" + [guid]::NewGuid().ToString("N"))
# script: 前缀是必须的：本文件可能以内存脚本块方式运行（见 windows-routing.ps1 同注）。
$script:ChildProcess = $null
$SecureKey = $null
$PlainKey = $null
$KeyBstr = [IntPtr]::Zero

function Stop-Agent([string]$Message) { throw "停止：$Message" }
function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
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
function Set-ClaudeEnvironment([Diagnostics.ProcessStartInfo]$Info, [string]$AuthToken) {
    foreach ($Name in @(
        "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_EFFORT_LEVEL", "CLAUDE_CONFIG_DIR",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CODE_SKIP_PROMPT_HISTORY",
        "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", "DISABLE_LOGIN_COMMAND", "DISABLE_UPDATES", "DISABLE_AUTOUPDATER"
    )) { $Info.EnvironmentVariables.Remove($Name) }

    $Info.EnvironmentVariables["ANTHROPIC_BASE_URL"] = "https://api.deepseek.com/anthropic"
    $Info.EnvironmentVariables["ANTHROPIC_AUTH_TOKEN"] = $AuthToken
    $Info.EnvironmentVariables["ANTHROPIC_MODEL"] = "deepseek-v4-flash"
    $Info.EnvironmentVariables["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "deepseek-v4-flash"
    $Info.EnvironmentVariables["ANTHROPIC_DEFAULT_SONNET_MODEL"] = "deepseek-v4-flash"
    $Info.EnvironmentVariables["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "deepseek-v4-flash"
    $Info.EnvironmentVariables["CLAUDE_CODE_SUBAGENT_MODEL"] = "deepseek-v4-flash"
    $Info.EnvironmentVariables["CLAUDE_CODE_EFFORT_LEVEL"] = "max"
    $Info.EnvironmentVariables["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    $Info.EnvironmentVariables["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
    $Info.EnvironmentVariables["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1"
    $Info.EnvironmentVariables["DISABLE_LOGIN_COMMAND"] = "1"
    $Info.EnvironmentVariables["DISABLE_UPDATES"] = "1"
    $Info.EnvironmentVariables["DISABLE_AUTOUPDATER"] = "1"
    $Info.EnvironmentVariables["CLAUDE_CONFIG_DIR"] = $TempConfig
}
function Clear-StartInfoSecret([Diagnostics.ProcessStartInfo]$Info) {
    if ($null -ne $Info) {
        $Info.EnvironmentVariables.Remove("ANTHROPIC_AUTH_TOKEN")
        $Info.EnvironmentVariables.Remove("ANTHROPIC_API_KEY")
    }
}
function Invoke-Claude([string]$Arguments, [string]$AuthToken, [bool]$Capture, [int]$TimeoutSeconds) {
    $Info = New-Object Diagnostics.ProcessStartInfo
    $Info.FileName = $ClaudePath
    $Info.Arguments = $Arguments
    $Info.WorkingDirectory = $RepoRoot
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $Capture
    $Info.RedirectStandardOutput = $Capture
    $Info.RedirectStandardError = $Capture

    $Process = New-Object Diagnostics.Process
    $Process.StartInfo = $Info
    $Started = $false
    try {
        Set-ClaudeEnvironment $Info $AuthToken
        if (-not $Process.Start()) { Stop-Agent "无法启动 Claude Code" }
        $Started = $true
        $script:ChildProcess = $Process
        Clear-StartInfoSecret $Info
        $AuthToken = $null

        if ($Capture) {
            $OutTask = $Process.StandardOutput.ReadToEndAsync()
            $ErrTask = $Process.StandardError.ReadToEndAsync()
            if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
                $Process.Kill()
                $Process.WaitForExit()
                Stop-Agent "DeepSeek 文本握手超时"
            }
            $Process.WaitForExit()
            return [ordered]@{
                exit_code = $Process.ExitCode
                stdout = $OutTask.Result
                stderr = $ErrTask.Result
            }
        }

        $Process.WaitForExit()
        return [ordered]@{ exit_code = $Process.ExitCode; stdout = ""; stderr = "" }
    } finally {
        Clear-StartInfoSecret $Info
        if ($Started -and -not $Process.HasExited) {
            try { $Process.Kill(); $Process.WaitForExit() } catch {}
        }
        $script:ChildProcess = $null
        if ($null -ne $Process) { $Process.Dispose() }
    }
}
function Get-SafeDiagnostic([string]$Text, [string]$Secret) {
    $Safe = $Text
    if (-not [string]::IsNullOrEmpty($Secret)) { $Safe = $Safe.Replace($Secret, "[REDACTED]") }
    $Safe = $Safe -replace '(?i)sk-[A-Za-z0-9_-]{8,}', '[REDACTED]'
    if ($Safe.Length -gt 1000) { $Safe = $Safe.Substring(0, 1000) }
    return $Safe.Trim()
}

try {
    if (-not (Test-Path -LiteralPath $RunbookPath -PathType Leaf)) { Stop-Agent "仓库缺少 RUNBOOK-WIN.md；请在完整的仓库目录内运行" }
    if (-not (Test-Path -LiteralPath $ClaudePath -PathType Leaf)) { Stop-Agent "未找到受控 Claude Code（$ClaudePath）。请先用 v1.3 启动链装好固定版，或将固定版放到该路径" }

    $Architecture = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($Architecture.ToUpperInvariant()) {
        "^(AMD64|X64)$" { $ExpectedHash = "af5bf1f1b2aadffc768eccd787084c6fdf9ba81624cbe96c1c6d9ac1a1550231" }
        "^ARM64$" { $ExpectedHash = "07343ace8a2e9ba87eed716e9c0261ce4bda8954c316695e4cb26fd0605de13c" }
        default { Stop-Agent "不支持的 Windows 架构：$Architecture" }
    }
    if ((Get-Sha256 $ClaudePath) -ne $ExpectedHash) { Stop-Agent "已安装 Claude Code SHA-256 不匹配" }
    $Signature = Get-AuthenticodeSignature -LiteralPath $ClaudePath
    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or $null -eq $Signature.SignerCertificate -or $Signature.SignerCertificate.Subject -notmatch 'Anthropic,? PBC') { Stop-Agent "已安装 Claude Code Authenticode 无效或发布者不匹配" }

    New-Item -ItemType Directory -Path $TempConfig | Out-Null
    Protect-Directory $TempConfig

    Write-Output "请输入额度受限、可撤销的 DeepSeek API Key；输入内容不会显示或保存。"
    $SecureKey = Read-Host "DeepSeek API Key" -AsSecureString
    if ($null -eq $SecureKey -or $SecureKey.Length -eq 0) { Stop-Agent "DeepSeek API Key 不能为空" }
    $KeyBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureKey)
    $PlainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($KeyBstr)

    $HandshakeArgs = '--print --output-format json --no-session-persistence --setting-sources "" --strict-mcp-config --permission-mode dontAsk --tools "" --model "deepseek-v4-flash" "Reply with exactly CLAUDE_LANE_HANDSHAKE_OK. Do not call tools."'
    $Handshake = Invoke-Claude $HandshakeArgs $PlainKey $true 120
    if ([int]$Handshake.exit_code -ne 0 -or [string]$Handshake.stdout -notmatch 'CLAUDE_LANE_HANDSHAKE_OK') {
        $Diagnostic = Get-SafeDiagnostic (([string]$Handshake.stderr) + "`n" + ([string]$Handshake.stdout)) $PlainKey
        if ([string]::IsNullOrWhiteSpace($Diagnostic)) { $Diagnostic = "Claude Code 返回码 $($Handshake.exit_code)" }
        Stop-Agent "DeepSeek 文本握手失败：$Diagnostic"
    }

    Write-Output "DeepSeek 文本握手通过。正在启动 Agent 会话（工作目录：$RepoRoot）。"
    Write-Output "Agent 将读取 RUNBOOK-WIN.md 并驱动工具脚本；它执行的每条命令都会请你在界面里确认。"
    Write-Output "退出会话后自动清理 Key 与临时配置。"
    $InteractiveArgs = '--no-session-persistence --setting-sources "" --strict-mcp-config --permission-mode default --model "deepseek-v4-flash" "先完整读取本目录的 RUNBOOK-WIN.md，然后严格按该手册执行；除手册列出的工具脚本调用外不要运行其他命令，也绝不索要用户的订阅链接、静态 IP 四元组或任何密钥。"'
    $Session = Invoke-Claude $InteractiveArgs $PlainKey $false 0
    if ([int]$Session.exit_code -ne 0) { Write-Warning "Claude Code 会话返回 $($Session.exit_code)；临时状态仍会清理。" }
} finally {
    if ($null -ne $script:ChildProcess -and -not $script:ChildProcess.HasExited) {
        try { $script:ChildProcess.Kill(); $script:ChildProcess.WaitForExit() } catch {}
    }
    $PlainKey = $null
    if ($KeyBstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($KeyBstr); $KeyBstr = [IntPtr]::Zero }
    if ($null -ne $SecureKey) { $SecureKey.Dispose(); $SecureKey = $null }
    if (Test-Path -LiteralPath $TempConfig) { Remove-Item -LiteralPath $TempConfig -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $TempConfig) {
        Write-Warning "Agent 子进程已结束且 Key 已释放，但临时配置目录清理失败：$TempConfig"
    } else {
        Write-Output "DeepSeek 临时 Key、子进程环境和配置目录已清理。"
    }
}
