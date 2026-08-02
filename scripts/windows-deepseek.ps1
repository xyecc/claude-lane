# Start the fixed Claude Code binary against DeepSeek in a temporary, isolated
# session. The API key is read as SecureString, passed only in the child process
# environment, and never persisted or placed in command-line arguments.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$InstallRoot = Join-Path $env:LOCALAPPDATA "claude-lane"
$ClaudePath = Join-Path $InstallRoot "tools\claude-code\2.1.212\claude.exe"
$LaneRoot = Join-Path $InstallRoot "releases\v1.3.0"
$TempConfig = Join-Path ([IO.Path]::GetTempPath()) ("claude-lane-deepseek-" + [guid]::NewGuid().ToString("N"))
$ChildProcess = $null
$SecureKey = $null
$PlainKey = $null
$KeyBstr = [IntPtr]::Zero

function Stop-DeepSeek([string]$Message) { throw "停止：$Message" }
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
    $Info.WorkingDirectory = $LaneRoot
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $Capture
    $Info.RedirectStandardOutput = $Capture
    $Info.RedirectStandardError = $Capture

    $Process = New-Object Diagnostics.Process
    $Process.StartInfo = $Info
    $Started = $false
    try {
        Set-ClaudeEnvironment $Info $AuthToken
        if (-not $Process.Start()) { Stop-DeepSeek "无法启动 Claude Code" }
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
                Stop-DeepSeek "DeepSeek 文本握手超时"
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
    if (-not (Test-Path -LiteralPath $ClaudePath -PathType Leaf)) { Stop-DeepSeek "未找到受控 Claude Code，请先运行 windows-local-rc.ps1" }
    if (-not (Test-Path -LiteralPath (Join-Path $LaneRoot "VERSION") -PathType Leaf) -or (Get-Content -LiteralPath (Join-Path $LaneRoot "VERSION") -Raw).Trim() -ne "1.3.0") { Stop-DeepSeek "未找到固定版 claude-lane" }

    $Architecture = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($Architecture.ToUpperInvariant()) {
        "^(AMD64|X64)$" { $ExpectedHash = "fe639693fd7e9a881c799867711abb7666dec2a5fefbaba41af6a09e71bcbefa" }
        "^ARM64$" { $ExpectedHash = "adaa6e3dadb8016755ccd1907a5f249c1bc9bdb6c71d3f7dcea7d5db8f72d0a5" }
        default { Stop-DeepSeek "不支持的 Windows 架构：$Architecture" }
    }
    if ((Get-Sha256 $ClaudePath) -ne $ExpectedHash) { Stop-DeepSeek "已安装 Claude Code SHA-256 不匹配" }
    $Signature = Get-AuthenticodeSignature -LiteralPath $ClaudePath
    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or $null -eq $Signature.SignerCertificate -or $Signature.SignerCertificate.Subject -notmatch 'Anthropic,? PBC') { Stop-DeepSeek "已安装 Claude Code Authenticode 无效或发布者不匹配" }

    New-Item -ItemType Directory -Path $TempConfig | Out-Null
    Protect-Directory $TempConfig

    Write-Output "请输入额度受限、可撤销的 DeepSeek API Key；输入内容不会显示或保存。"
    $SecureKey = Read-Host "DeepSeek API Key" -AsSecureString
    if ($null -eq $SecureKey -or $SecureKey.Length -eq 0) { Stop-DeepSeek "DeepSeek API Key 不能为空" }
    $KeyBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureKey)
    $PlainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($KeyBstr)

    $HandshakeArgs = '--print --output-format json --no-session-persistence --setting-sources "" --strict-mcp-config --permission-mode dontAsk --tools "" --model "deepseek-v4-flash" "Reply with exactly CLAUDE_LANE_HANDSHAKE_OK. Do not call tools."'
    $Handshake = Invoke-Claude $HandshakeArgs $PlainKey $true 120
    if ([int]$Handshake.exit_code -ne 0 -or [string]$Handshake.stdout -notmatch 'CLAUDE_LANE_HANDSHAKE_OK') {
        $Diagnostic = Get-SafeDiagnostic (([string]$Handshake.stderr) + "`n" + ([string]$Handshake.stdout)) $PlainKey
        if ([string]::IsNullOrWhiteSpace($Diagnostic)) { $Diagnostic = "Claude Code 返回码 $($Handshake.exit_code)" }
        Stop-DeepSeek "DeepSeek 文本握手失败：$Diagnostic"
    }

    Write-Output "DeepSeek 文本握手通过。正在启动临时 Claude Code 会话。"
    Write-Output "本会话只开放 Read/Edit/Write；不开放 Bash，退出后自动清理 Key 和临时配置。"
    $InteractiveArgs = '--no-session-persistence --setting-sources "" --strict-mcp-config --permission-mode default --model "deepseek-v4-flash" --tools "Read,Edit,Write"'
    $Session = Invoke-Claude $InteractiveArgs $PlainKey $false 0
    if ([int]$Session.exit_code -ne 0) { Write-Warning "Claude Code 会话返回 $($Session.exit_code)；临时状态仍会清理。" }
} finally {
    if ($null -ne $ChildProcess -and -not $ChildProcess.HasExited) {
        try { $ChildProcess.Kill(); $ChildProcess.WaitForExit() } catch {}
    }
    $PlainKey = $null
    if ($KeyBstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($KeyBstr); $KeyBstr = [IntPtr]::Zero }
    if ($null -ne $SecureKey) { $SecureKey.Dispose(); $SecureKey = $null }
    if (Test-Path -LiteralPath $TempConfig) { Remove-Item -LiteralPath $TempConfig -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $TempConfig) {
        Write-Warning "DeepSeek 子进程已结束且 Key 已释放，但临时配置目录清理失败：$TempConfig"
    } else {
        Write-Output "DeepSeek 临时 Key、子进程环境和配置目录已清理。"
    }
}
