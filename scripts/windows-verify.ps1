[CmdletBinding()]
param(
    [switch]$SaveBaseline,
    [string]$ScriptRoot = ""
)

# Windows six-check verifier. It never prints full IPs, Clash secrets, profile
# contents or log lines. Full exit baselines remain in a current-user ACL file.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$Passed = 0
$Failed = 0
$ConfigRoot = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_LANE_CLASH_CFG)) {
    $env:CLAUDE_LANE_CLASH_CFG
} else {
    Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"
}
$InstallRoot = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_LANE_SETUP_ROOT)) {
    $env:CLAUDE_LANE_SETUP_ROOT
} else {
    Join-Path $env:LOCALAPPDATA "claude-lane"
}
$Generated = Join-Path $ConfigRoot "clash-verge.yaml"
$LogPath = Join-Path $ConfigRoot "logs\service\service_latest.log"
$BaselineRoot = Join-Path $InstallRoot "private-state"
$BaselinePath = Join-Path $BaselineRoot "windows-exit-baseline.json"
$ResolvedScriptRoot = if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) { (Resolve-Path -LiteralPath $ScriptRoot).Path } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$StateTool = Join-Path $ResolvedScriptRoot "setup-state.ps1"
$ApiHeaders = @{}

function Pass([string]$Name) { $script:Passed++; Write-Output "PASS  $Name" }
function Fail([string]$Name) { $script:Failed++; Write-Output "FAIL  $Name" }
function Mask-Value([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return "***" }
    $Length = [Math]::Min(3, $Value.Length)
    return $Value.Substring(0, $Length) + "***"
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
function Get-YamlScalar([string]$Path, [string]$Key) {
    $MatchesFound = @()
    foreach ($Line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($Line -match ('^' + [regex]::Escape($Key) + ':\s*(.*?)\s*$')) { $MatchesFound += $Matches[1] }
    }
    if ($MatchesFound.Count -ne 1) { throw "$Key 字段缺失或重复" }
    $Value = [string]$MatchesFound[0]
    if ($Value.StartsWith('"') -and $Value.EndsWith('"')) { return [string]($Value | ConvertFrom-Json) }
    if ($Value.StartsWith("'") -and $Value.EndsWith("'")) { return $Value.Substring(1, $Value.Length - 2).Replace("''", "'") }
    return $Value
}
function Invoke-Api([string]$Base, [string]$Path) {
    return Invoke-RestMethod -UseBasicParsing -Uri ($Base + $Path) -Headers $ApiHeaders -Method Get -TimeoutSec 10
}
function Get-Ip([string[]]$Arguments) {
    $Output = (& curl.exe @Arguments 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return "" }
    return $Output
}
function Test-Ip([string]$Value) {
    $Address = $null
    return [Net.IPAddress]::TryParse($Value, [ref]$Address)
}
function Set-Progress([string]$State, [string]$Reason) {
    if (-not (Test-Path -LiteralPath $StateTool -PathType Leaf)) { throw "安装包缺少进度状态工具" }
    $StateBlock = [scriptblock]::Create((Get-Content -LiteralPath $StateTool -Raw -Encoding UTF8))
    & $StateBlock -Set $State -Reason $Reason | Out-Null
}

if (-not (Test-Path -LiteralPath $Generated -PathType Leaf)) { throw "找不到 Clash 生成配置；请先点击当前订阅卡片" }
$GeneratedItem = Get-Item -LiteralPath $Generated -Force
if (($GeneratedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Clash 生成配置不能是重解析点" }
$GeneratedText = Get-Content -LiteralPath $Generated -Raw -Encoding UTF8
$Controller = Get-YamlScalar $Generated "external-controller"
$Secret = Get-YamlScalar $Generated "secret"
if ([string]::IsNullOrWhiteSpace($Controller) -or $Controller -notmatch '^(127\.0\.0\.1|localhost|0\.0\.0\.0):([0-9]{1,5})$') { throw "只允许本机 Mihomo 控制端口" }
$ControllerPort = [int]$Matches[2]
if ($ControllerPort -lt 1 -or $ControllerPort -gt 65535) { throw "Mihomo 控制端口无效" }
$ApiBase = "http://127.0.0.1:$ControllerPort"
if (-not [string]::IsNullOrWhiteSpace($Secret)) { $ApiHeaders.Authorization = "Bearer $Secret" }

$Version = $null
$Configs = $null
try {
    $Version = Invoke-Api $ApiBase "/version"
    $Configs = Invoke-Api $ApiBase "/configs"
    $TunEnabled = $GeneratedText -match '(?ms)^tun:\s*$.*?^\s+enable:\s*true\s*$'
    if ($null -ne $Version -and $null -ne $Configs -and [string]$Configs.mode -eq "rule" -and $TunEnabled) { Pass "Mihomo 内核、TUN 与规则模式" } else { Fail "Mihomo 内核、TUN 与规则模式" }
} catch {
    Fail "Mihomo 内核、TUN 与规则模式"
}

$Proxies = $null
try {
    $Proxies = Invoke-Api $ApiBase "/proxies"
    $ClaudeGroup = $Proxies.proxies.PSObject.Properties["Claude"].Value
    $ChainGroup = $Proxies.proxies.PSObject.Properties["US-Chain"].Value
    if ($null -ne $ClaudeGroup -and $null -ne $ChainGroup -and [string]$ClaudeGroup.now -eq "🇺🇸 US-Static" -and -not [string]::IsNullOrWhiteSpace([string]$ChainGroup.now)) {
        Pass "Claude 与 US-Chain 策略组"
    } else { Fail "Claude 与 US-Chain 策略组" }
} catch { Fail "Claude 与 US-Chain 策略组" }

try {
    $RuleDocument = Invoke-Api $ApiBase "/rules"
    $RulesJson = $RuleDocument | ConvertTo-Json -Depth 8 -Compress
    $Required = @("chrome.exe", "msedge.exe", "claude.exe", "anthropic.com", "claude.com", "claude.ai", "claudeusercontent.com", "http-intake.logs.us5.datadoghq.com", "160.79.104.0/23")
    $Missing = @($Required | Where-Object { $RulesJson.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -lt 0 })
    if ($Missing.Count -eq 0 -and $RulesJson -match '(?i)REJECT' -and $RulesJson -match 'Claude') { Pass "QUIC、进程、域名、遥测与 IP 规则" } else { Fail "QUIC、进程、域名、遥测与 IP 规则" }
} catch { Fail "QUIC、进程、域名、遥测与 IP 规则" }

$MixedPort = 0
if ($null -ne $Configs) {
    foreach ($Name in @("mixed-port", "port")) {
        $Property = $Configs.PSObject.Properties[$Name]
        if ($null -ne $Property -and [int]$Property.Value -gt 0) { $MixedPort = [int]$Property.Value; break }
    }
}
if ($MixedPort -eq 0 -and $GeneratedText -match '(?m)^(?:mixed-port|port):\s*([0-9]{1,5})\s*$') { $MixedPort = [int]$Matches[1] }
$ClaudeIp = ""
$NormalIp = ""
$PendingBaseline = $null
if ($MixedPort -gt 0 -and (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    $Proxy = "http://127.0.0.1:$MixedPort"
    $Trace = Get-Ip -Arguments @("-q", "-fsS", "--max-time", "25", "--proxy", $Proxy, "https://claude.ai/cdn-cgi/trace")
    if ($Trace -match '(?m)^ip=([^\r\n]+)$') { $ClaudeIp = $Matches[1].Trim() }
    $NormalIp = Get-Ip -Arguments @("-q", "-fsS", "--max-time", "15", "--proxy", $Proxy, "https://api.ipify.org")
}
if ((Test-Ip $ClaudeIp) -and (Test-Ip $NormalIp) -and $ClaudeIp -ne $NormalIp) {
    if ($SaveBaseline) {
        $PendingBaseline = [ordered]@{ schema = 1; claude_ip = $ClaudeIp; normal_ip = $NormalIp; saved_at = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") }
        Pass ("Claude / 普通出口隔离（" + (Mask-Value $ClaudeIp) + " / " + (Mask-Value $NormalIp) + "）")
    } elseif (-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) {
        Fail "Claude / 普通出口隔离（本地基线缺失）"
    } else {
        try {
            $Baseline = Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$Baseline.schema -ne 1 -or [string]$Baseline.claude_ip -ne $ClaudeIp -or [string]$Baseline.normal_ip -ne $NormalIp) {
                Fail "Claude / 普通出口隔离（与本地基线不一致）"
            } else {
                Pass ("Claude / 普通出口隔离（" + (Mask-Value $ClaudeIp) + " / " + (Mask-Value $NormalIp) + "）")
            }
        } catch {
            Fail "Claude / 普通出口隔离（本地基线损坏）"
        }
    }
} else { Fail "Claude / 普通出口隔离" }

if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
    $LeakCount = 0
    foreach ($Line in @(Get-Content -LiteralPath $LogPath -Tail 2000 -Encoding UTF8)) {
        if ($Line -match '(?i)anthropic|claude\.ai|claude\.com|claudeusercontent|http-intake\.logs\.us5\.datadoghq\.com' -and $Line -notmatch '(?i)\bClaude\b|US-Static') { $LeakCount++ }
    }
    if ($LeakCount -eq 0) { Pass "近期日志无 Claude 漏流" } else { Fail "近期日志无 Claude 漏流" }
} else { Fail "近期日志无 Claude 漏流" }

$CompetingVpn = @()
$VpnQueryAvailable = $null -ne (Get-Command Get-VpnConnection -ErrorAction SilentlyContinue)
if ($VpnQueryAvailable) {
    try {
        $Connections = @()
        $Connections += @(Get-VpnConnection -ErrorAction Stop)
        $Connections += @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue)
        $CompetingVpn += @($Connections | Where-Object { $_.ConnectionStatus -eq "Connected" -and $_.Name -notmatch '(?i)tailscale' })
        $KnownProcesses = @("openvpn", "wireguard", "outline-client", "shadowsocks", "nekoray", "hiddify", "sing-box", "v2rayN")
        $CompetingVpn += @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $KnownProcesses -contains $_.ProcessName })
    } catch { $VpnQueryAvailable = $false }
}
if ($VpnQueryAvailable -and $CompetingVpn.Count -eq 0) { Pass "未发现并行 Windows VPN 连接" } else { Fail "未发现并行 Windows VPN 连接" }

$ApiHeaders.Clear()
$Secret = ""
if ($Failed -eq 0 -and $Passed -eq 6) {
    if ($SaveBaseline) {
        if ($null -eq $PendingBaseline) { throw "六项验证通过但待保存出口基线缺失" }
        New-Item -ItemType Directory -Force -Path $BaselineRoot | Out-Null
        Protect-Directory $BaselineRoot
        $BaselineTemp = Join-Path $BaselineRoot (".windows-exit-baseline-" + [guid]::NewGuid().ToString("N") + ".tmp")
        try {
            [IO.File]::WriteAllText($BaselineTemp, ($PendingBaseline | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $BaselineTemp -Destination $BaselinePath -Force
        } finally {
            Remove-Item -LiteralPath $BaselineTemp -Force -ErrorAction SilentlyContinue
        }
    }
    Set-Progress VALIDATION_PASSED validation_passed
    Write-Output "VALIDATION PASSED: windows-routing"
    return
}
try { Set-Progress ROUTING_CONFIGURED routing_configured } catch {}
Write-Output "VALIDATION FAILED: $Failed checks failed"
throw "Windows 专线路由六项验证未全部通过"
