[CmdletBinding()]
param(
    [string]$ScriptRoot = "",
    [string]$DeploymentId = ""
)

# Windows 本地确定性路由配置。订阅 URL 与 ISP 四元组不会输出；脚本只接受
# 用户从 Clash Verge GUI 看到的美国节点名，并为所有改动建立受保护备份。

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$ConfigRoot = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_LANE_CLASH_CFG)) {
    $env:CLAUDE_LANE_CLASH_CFG
} else {
    Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"
}
$ProfilesPath = Join-Path $ConfigRoot "profiles.yaml"
$InstallRoot = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_LANE_SETUP_ROOT)) {
    $env:CLAUDE_LANE_SETUP_ROOT
} else {
    Join-Path $env:LOCALAPPDATA "claude-lane"
}
$ResolvedScriptRoot = if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
    (Resolve-Path -LiteralPath $ScriptRoot).Path
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
$StateTool = Join-Path $ResolvedScriptRoot "setup-state.ps1"
$StartMarker = "# claude-lane managed start"
$EndMarker = "# claude-lane managed end"
$SecureValues = @()
$PlainValues = @()
$BstrValues = @()

function Stop-Routing([string]$Message) { throw "停止：$Message" }
function Set-Progress([string]$State, [string]$Reason) {
    if (-not (Test-Path -LiteralPath $StateTool -PathType Leaf)) { Stop-Routing "安装包缺少进度状态工具" }
    $StateBlock = [scriptblock]::Create((Get-Content -LiteralPath $StateTool -Raw -Encoding UTF8))
    & $StateBlock -Set $State -Reason $Reason | Out-Null
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
function Assert-RegularFile([string]$Path, [bool]$MustExist) {
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($MustExist) { Stop-Routing "缺少文件：$Path" }
        return
    }
    $Item = Get-Item -LiteralPath $Path -Force
    if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-Routing "配置目标必须是普通文件：$Path"
    }
}
function Get-ProfileOptions {
    Assert-RegularFile $ProfilesPath $true
    $Lines = @(Get-Content -LiteralPath $ProfilesPath -Encoding UTF8)
    $Current = @()
    $Starts = @()
    for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
        if ($Lines[$Index] -match '^current:\s*([A-Za-z0-9]{1,128})\s*$') {
            $Current += [pscustomobject]@{ Uid = $Matches[1]; Line = $Index }
        }
        if ($Lines[$Index] -match '^([ ]*)-\s*uid:\s*([A-Za-z0-9]{1,128})\s*$') {
            $Starts += [pscustomobject]@{ Line = $Index; Indent = $Matches[1]; Uid = $Matches[2] }
        }
    }
    if ($Current.Count -ne 1) { Stop-Routing "profiles.yaml 的 current 格式不唯一或不受支持" }
    $MatchesForCurrent = @($Starts | Where-Object { $_.Uid -eq $Current[0].Uid })
    if ($MatchesForCurrent.Count -ne 1) { Stop-Routing "current 没有唯一对应的 profile" }
    $Item = $MatchesForCurrent[0]
    $Start = [int]$Item.Line
    $End = $Lines.Count
    foreach ($Candidate in $Starts) {
        if ([int]$Candidate.Line -gt $Start -and [int]$Candidate.Line -lt $End) { $End = [int]$Candidate.Line }
    }
    $PropertyIndent = [string]$Item.Indent + "  "
    $OptionIndent = $PropertyIndent + "  "
    $Type = ""
    $TypeCount = 0
    $UrlReady = $false
    $UrlCount = 0
    $Options = [ordered]@{ proxies = ""; groups = ""; rules = ""; merge = "" }
    $OptionCounts = @{ proxies = 0; groups = 0; rules = 0; merge = 0 }
    for ($Index = $Start + 1; $Index -lt $End; $Index++) {
        $Line = $Lines[$Index]
        if ($Line -match ('^' + [regex]::Escape($PropertyIndent) + 'type:\s*([A-Za-z]+)\s*$')) {
            $TypeCount++
            $Type = $Matches[1]
        }
        if ($Line -match ('^' + [regex]::Escape($PropertyIndent) + 'url:\s*(\S+)\s*$')) {
            $UrlCount++
            $Marker = $Matches[1]
            if ($Marker -notmatch '^(?i:null|["'']{2})$') { $UrlReady = $true }
        }
        foreach ($Kind in @("proxies", "groups", "rules", "merge")) {
            if ($Line -match ('^' + [regex]::Escape($OptionIndent) + [regex]::Escape($Kind) + ':\s*([A-Za-z0-9]{1,128})\s*$')) {
                $OptionCounts[$Kind]++
                $Options[$Kind] = $Matches[1]
            }
        }
    }
    if ($TypeCount -ne 1 -or $Type -ne "remote" -or $UrlCount -ne 1 -or -not $UrlReady) {
        Stop-Routing "当前 profile 不是可用的远程订阅"
    }
    foreach ($Kind in $Options.Keys) {
        if ($OptionCounts[$Kind] -gt 1) { Stop-Routing "当前订阅的 $Kind 增强字段重复" }
    }
    return [pscustomobject]@{ CurrentUid = $Current[0].Uid; Options = $Options }
}
function Get-TargetPaths([object]$Profile) {
    $Targets = [ordered]@{}
    foreach ($Kind in @("proxies", "groups", "rules", "merge")) {
        $Uid = [string]$Profile.Options[$Kind]
        if ([string]::IsNullOrWhiteSpace($Uid)) { $Targets[$Kind] = "" } else { $Targets[$Kind] = Join-Path (Join-Path $ConfigRoot "profiles") "$Uid.yaml" }
    }
    return ,$Targets
}
function Test-ManagedWritable([string]$Path, [string]$Kind) {
    Assert-RegularFile $Path $false
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $true }
    $Text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $StartCount = ([regex]::Matches($Text, '(?m)^[ \t]*' + [regex]::Escape($StartMarker) + '[ \t]*$')).Count
    $EndCount = ([regex]::Matches($Text, '(?m)^[ \t]*' + [regex]::Escape($EndMarker) + '[ \t]*$')).Count
    if ($StartCount -eq 1 -and $EndCount -eq 1 -and $Text.IndexOf($StartMarker) -lt $Text.IndexOf($EndMarker)) { return $true }
    if ($StartCount -ne 0 -or $EndCount -ne 0) { Stop-Routing "$Kind 增强文件的托管标记损坏或重复" }
    $Meaningful = @($Text -split "`r?`n" | Where-Object {
        $Value = $_.Trim()
        -not [string]::IsNullOrWhiteSpace($Value) -and -not $Value.StartsWith("#") -and
        @("prepend: []", "prepend:", "append: []", "append:", "delete: []", "delete:", "{}") -notcontains $Value
    })
    if ($Meaningful.Count -gt 0) { Stop-Routing "$Kind 增强文件已有用户配置且没有 claude-lane 托管标记，拒绝覆盖" }
    return $true
}
function Write-ManagedFile([string]$Path, [string]$Kind, [string]$ManagedBlock, [string]$Skeleton) {
    $Existing = if (Test-Path -LiteralPath $Path -PathType Leaf) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 } else { $Skeleton }
    if ($Existing.Contains($StartMarker)) {
        $Pattern = '(?ms)^[ \t]*' + [regex]::Escape($StartMarker) + '[ \t]*\r?\n.*?^[ \t]*' + [regex]::Escape($EndMarker) + '[ \t]*$'
        $ManagedRegex = [Text.RegularExpressions.Regex]::new($Pattern)
        $Output = $ManagedRegex.Replace($Existing, [Text.RegularExpressions.MatchEvaluator]{ param($Match) $ManagedBlock }, 1)
    } else {
        $Output = $Skeleton.Replace("__CLAUDE_LANE_MANAGED__", $ManagedBlock)
    }
    if (-not $Output.EndsWith("`n")) { $Output += "`n" }
    $Parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    $Temp = Join-Path $Parent (".claude-lane-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [IO.File]::WriteAllText($Temp, $Output, $Utf8NoBom)
        Move-Item -LiteralPath $Temp -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
    }
}
function New-ProtectedBackup([System.Collections.IDictionary]$Targets, [string]$Id) {
    $BackupRoot = Join-Path (Join-Path $InstallRoot "backups") $Id
    if (Test-Path -LiteralPath $BackupRoot) { Stop-Routing "备份 id 已存在，拒绝覆盖：$Id" }
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    Protect-Directory $BackupRoot
    $Entries = @()
    $Index = 0
    foreach ($Kind in $Targets.Keys) {
        $Path = [string]$Targets[$Kind]
        $Entry = [ordered]@{ kind = $Kind; path = $Path; state = "created"; backup = "" }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $Name = ("{0:D2}-{1}.yaml" -f $Index, $Kind)
            Copy-Item -LiteralPath $Path -Destination (Join-Path $BackupRoot $Name)
            $Entry.state = "file"
            $Entry.backup = $Name
        }
        $Entries += $Entry
        $Index++
    }
    $Manifest = [ordered]@{ schema = 1; deployment_id = $Id; config_root = $ConfigRoot; created_at = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"); entries = $Entries }
    [IO.File]::WriteAllText((Join-Path $BackupRoot "manifest.json"), ($Manifest | ConvertTo-Json -Depth 6), $Utf8NoBom)
    return $BackupRoot
}
function Read-Secret([string]$Prompt) {
    $Secure = Read-Host $Prompt -AsSecureString
    if ($null -eq $Secure -or $Secure.Length -eq 0) { Stop-Routing "$Prompt 不能为空" }
    $Pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    $Plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Pointer)
    $script:SecureValues += $Secure
    $script:BstrValues += $Pointer
    $script:PlainValues += $Plain
    return $Plain
}
function Quote-Yaml([string]$Value) { return ($Value | ConvertTo-Json -Compress) }
function Assert-ManagedRouting([System.Collections.IDictionary]$Targets) {
    $ProxyText = Get-Content -LiteralPath ([string]$Targets["proxies"]) -Raw -Encoding UTF8
    $GroupText = Get-Content -LiteralPath ([string]$Targets["groups"]) -Raw -Encoding UTF8
    $RuleText = Get-Content -LiteralPath ([string]$Targets["rules"]) -Raw -Encoding UTF8
    $MergeText = Get-Content -LiteralPath ([string]$Targets["merge"]) -Raw -Encoding UTF8
    if ($ProxyText -notmatch '(?m)^\s*type:\s*socks5(?:\s|#|$)' -or
        $ProxyText -notmatch '(?m)^\s*udp:\s*false(?:\s|#|$)' -or
        $ProxyText -notmatch '(?m)^\s*dialer-proxy:\s*"US-Chain"(?:\s|#|$)') { Stop-Routing "proxies 托管块缺少链式 SOCKS5 安全字段" }
    if ($GroupText -notmatch '(?m)^\s*-\s*name:\s*"Claude"\s*$' -or $GroupText -notmatch '(?m)^\s*-\s*name:\s*"US-Chain"\s*$') { Stop-Routing "groups 托管块不完整" }
    foreach ($Required in @("chrome.exe", "msedge.exe", "claude.exe", "anthropic.com", "claude.ai", "claudeusercontent.com", "http-intake.logs.us5.datadoghq.com", "160.79.104.0/23")) {
        if ($RuleText.IndexOf($Required, [StringComparison]::OrdinalIgnoreCase) -lt 0) { Stop-Routing "rules 托管块不完整" }
    }
    if ($MergeText -notmatch '(?m)^sniffer:\s*$' -or $MergeText -notmatch '(?m)^\s*enable:\s*true\s*$') { Stop-Routing "merge 托管块缺少嗅探配置" }
}

try {
    if (-not [Environment]::Is64BitOperatingSystem) { Stop-Routing "只支持 64 位 Windows" }
    if ([string]::IsNullOrWhiteSpace($DeploymentId)) { $DeploymentId = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8) }
    if ($DeploymentId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{6,63}$') { Stop-Routing "deployment id 格式无效" }
    $Profile = Get-ProfileOptions
    $Targets = Get-TargetPaths $Profile
    $Missing = @($Targets.Keys | Where-Object { [string]::IsNullOrWhiteSpace([string]$Targets[$_]) })
    if ($Missing.Count -gt 0) {
        Set-Progress WAITING_FOR_ENHANCEMENT_FILES enhancement_files_missing
        Write-Output "SETUP_STATE=WAITING_FOR_ENHANCEMENT_FILES"
        Write-Output ("MISSING_TYPES=" + ($Missing -join ','))
        Write-Output "请在 Clash Verge 当前订阅卡片依次打开缺失类型的编辑器，不修改内容直接保存，然后重新运行同一命令。"
        return
    }
    foreach ($Kind in $Targets.Keys) { [void](Test-ManagedWritable ([string]$Targets[$Kind]) $Kind) }

    $AllManaged = $true
    foreach ($Kind in $Targets.Keys) {
        $Path = [string]$Targets[$Kind]
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or -not (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Contains($StartMarker)) { $AllManaged = $false }
    }
    if ($AllManaged) {
        Assert-ManagedRouting $Targets
        $Confirmed = Read-Host "检测到路由配置已写入。请在 Clash Verge 点当前订阅卡片、开启 TUN 并保持规则模式；完成后输入 YES"
        if ($Confirmed -ceq "YES") {
            Set-Progress ROUTING_CONFIGURED routing_configured
            Write-Output "SETUP_STATE=ROUTING_CONFIGURED"
        } else {
            Set-Progress WAITING_FOR_ACTIVATION activation_required
            Write-Output "SETUP_STATE=WAITING_FOR_ACTIVATION"
        }
        return
    }

    Set-Progress WAITING_FOR_ISP isp_required
    $Ready = Read-Host "是否已准备静态住宅 ISP SOCKS5 四元组？准备好请输入 YES，否则直接回车暂停"
    if ($Ready -cne "YES") {
        Write-Output "SETUP_STATE=WAITING_FOR_ISP"
        Write-Output "NEXT_ACTION=PREPARE_STATIC_ISP_SOCKS5"
        return
    }
    Write-Output "请从 Clash Verge 当前订阅中复制美国节点名；多个节点用英文分号分隔。节点名可以显示，订阅 URL 不要粘贴。"
    $NodeInput = Read-Host "美国节点名"
    $Nodes = @($NodeInput -split ';' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Nodes.Count -eq 0 -or $Nodes.Count -gt 20) { Stop-Routing "至少需要 1 个、最多 20 个美国节点名" }
    foreach ($Node in $Nodes) {
        if ($Node.Length -gt 200 -or $Node -match '[\r\n]' -or $Node -match '(?i)^https?://') { Stop-Routing "美国节点名格式无效" }
    }
    $HostValue = Read-Secret "静态 IP 主机（隐藏输入）"
    $PortValue = Read-Secret "静态 IP 端口（隐藏输入）"
    $UserValue = Read-Secret "静态 IP 用户名（隐藏输入）"
    $PasswordValue = Read-Secret "静态 IP 密码（隐藏输入）"
    if ($PortValue -notmatch '^[0-9]{1,5}$' -or [int]$PortValue -lt 1 -or [int]$PortValue -gt 65535) { Stop-Routing "端口必须在 1..65535" }

    $BackupRoot = New-ProtectedBackup $Targets $DeploymentId
    $ProxyBlock = @"
  $StartMarker
  - name: "🇺🇸 US-Static"
    type: socks5
    server: $(Quote-Yaml $HostValue)
    port: $([int]$PortValue)
    username: $(Quote-Yaml $UserValue)
    password: $(Quote-Yaml $PasswordValue)
    udp: false
    dialer-proxy: "US-Chain"
  $EndMarker
"@
    $NodeLines = @($Nodes | ForEach-Object { '      - ' + (Quote-Yaml $_) }) -join "`n"
    $GroupBlock = @"
  $StartMarker
  - name: "Claude"
    type: select
    proxies:
      - "🇺🇸 US-Static"
  - name: "US-Chain"
    type: select
    proxies:
$NodeLines
  $EndMarker
"@
    $RuleBlock = @"
  $StartMarker
  - "AND,((PROCESS-NAME,chrome.exe),(NETWORK,UDP),(DST-PORT,443)),REJECT"
  - "AND,((PROCESS-NAME,msedge.exe),(NETWORK,UDP),(DST-PORT,443)),REJECT"
  - "AND,((PROCESS-NAME,claude.exe),(NETWORK,UDP)),REJECT"
  - "PROCESS-NAME,claude.exe,Claude"
  - "DOMAIN-SUFFIX,anthropic.com,Claude"
  - "DOMAIN-SUFFIX,claude.com,Claude"
  - "DOMAIN-SUFFIX,claude.ai,Claude"
  - "DOMAIN-SUFFIX,claudeusercontent.com,Claude"
  - "DOMAIN-KEYWORD,anthropic,Claude"
  - "DOMAIN-SUFFIX,http-intake.logs.us5.datadoghq.com,Claude"
  - "IP-CIDR,160.79.104.0/23,Claude,no-resolve"
  $EndMarker
"@
    $MergeBlock = @"
$StartMarker
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  sniff:
    QUIC:
      ports: [443]
    TLS:
      ports: [443, 8443]
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
  force-domain:
    - "+.anthropic.com"
    - "+.claude.com"
    - "+.claude.ai"
    - "+.claudeusercontent.com"
$EndMarker
"@
    try {
        Write-ManagedFile ([string]$Targets["proxies"]) "proxies" $ProxyBlock "prepend: []`n`nappend:`n__CLAUDE_LANE_MANAGED__`n`ndelete: []`n"
        Write-ManagedFile ([string]$Targets["groups"]) "groups" $GroupBlock "prepend:`n__CLAUDE_LANE_MANAGED__`n`nappend: []`n`ndelete: []`n"
        Write-ManagedFile ([string]$Targets["rules"]) "rules" $RuleBlock "prepend:`n__CLAUDE_LANE_MANAGED__`n`nappend: []`n`ndelete: []`n"
        Write-ManagedFile ([string]$Targets["merge"]) "merge" $MergeBlock "__CLAUDE_LANE_MANAGED__`n"
        Assert-ManagedRouting $Targets
    } catch {
        Stop-Routing "配置写入或本地复验失败；使用 deployment id $DeploymentId 执行回滚"
    }
    $PlainValues = @()
    Set-Progress WAITING_FOR_ACTIVATION activation_required
    Write-Output "SETUP_STATE=WAITING_FOR_ACTIVATION"
    Write-Output "DEPLOYMENT_ID=$DeploymentId"
    Write-Output "US_NODE_COUNT=$($Nodes.Count)"
    Write-Output "CREDENTIALS=stored-locally-redacted"
    Write-Output "请在 Clash Verge 点当前订阅卡片，开启 TUN 并保持规则模式，然后重新运行同一命令。"
    Write-Output "备份已保存在当前用户专属 ACL 目录；需要回滚时使用上面的 deployment id。"
} finally {
    $PlainValues = @()
    foreach ($Pointer in $BstrValues) {
        if ($Pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer) }
    }
    foreach ($Secure in $SecureValues) {
        if ($null -ne $Secure) { $Secure.Dispose() }
    }
    $BstrValues = @()
    $SecureValues = @()
}
