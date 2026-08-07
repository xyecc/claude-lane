# 只判断 Clash Verge 是否已有当前远程订阅；绝不输出订阅 URL。
[CmdletBinding()]
param(
    [string]$ScriptRoot = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$ScriptDir = if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
    (Resolve-Path -LiteralPath $ScriptRoot).Path
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
$StateTool = Join-Path $ScriptDir "setup-state.ps1"
$ConfigRoot = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_LANE_CLASH_CFG)) {
    $env:CLAUDE_LANE_CLASH_CFG
} else {
    Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"
}
$Profiles = Join-Path $ConfigRoot "profiles.yaml"

function Set-Progress([string]$State, [string]$Reason) {
    if (-not (Test-Path -LiteralPath $StateTool -PathType Leaf)) { throw "安装包缺少进度状态工具" }
    $StateBlock = [scriptblock]::Create((Get-Content -LiteralPath $StateTool -Raw -Encoding UTF8))
    & $StateBlock -Set $State -Reason $Reason | Out-Null
}
function Get-Progress {
    if (-not (Test-Path -LiteralPath $StateTool -PathType Leaf)) { return "NOT_STARTED" }
    $StateBlock = [scriptblock]::Create((Get-Content -LiteralPath $StateTool -Raw -Encoding UTF8))
    return [string](@(& $StateBlock -Get) | Select-Object -Last 1)
}

if (-not (Test-Path -LiteralPath $Profiles -PathType Leaf)) {
    Set-Progress "WAITING_FOR_SUBSCRIPTION" "profiles_missing"
    Write-Output "SETUP_STATE=WAITING_FOR_SUBSCRIPTION"
    Write-Output "NEXT_ACTION=OPEN_CLASH_AND_IMPORT_SUBSCRIPTION"
    return
}

# Clash Verge 的 profiles.yaml 不是通用 YAML API。这里只接受它写出的窄格式：
# 唯一 current、唯一同 uid 条目、type: remote，以及该条目内非空 url。
$Lines = @(Get-Content -LiteralPath $Profiles -Encoding UTF8)
$CurrentFields = @()
for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
    if ($Lines[$Index] -match '^current:\s*(.*?)\s*$') {
        $CurrentFields += [ordered]@{ value = $Matches[1]; line = $Index }
    }
}
if ($CurrentFields.Count -ne 1) { throw "profiles.yaml 的 current 格式不唯一或不受支持" }
$CurrentUid = ([string]$CurrentFields[0].value).Trim()
if ([string]::IsNullOrWhiteSpace($CurrentUid) -or $CurrentUid -match '^(?i:null|~|["'']{2})$') {
    Set-Progress "WAITING_FOR_SUBSCRIPTION" "subscription_not_imported"
    Write-Output "SETUP_STATE=WAITING_FOR_SUBSCRIPTION"
    Write-Output "NEXT_ACTION=OPEN_CLASH_AND_IMPORT_SUBSCRIPTION"
    return
}
if ($CurrentUid -notmatch '^[A-Za-z0-9]{1,128}$') { throw "profiles.yaml 的 current 格式不受支持" }
$ItemStarts = @()
for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
    if ($Lines[$Index] -match '^([ ]*)-\s*uid:\s*([A-Za-z0-9]{1,128})\s*$') {
        $ItemStarts += [ordered]@{ line = $Index; indent = $Matches[1]; uid = $Matches[2] }
    }
}
$CurrentItems = @($ItemStarts | Where-Object { [string]$_.uid -eq $CurrentUid })
if ($CurrentItems.Count -ne 1) { throw "profiles.yaml 的 current 没有唯一对应条目" }
$CurrentItem = $CurrentItems[0]
$Start = [int]$CurrentItem.line
$End = $Lines.Count
foreach ($Item in $ItemStarts) {
    if ([int]$Item.line -gt $Start -and [int]$Item.line -lt $End) { $End = [int]$Item.line }
}
$PropertyIndent = [string]$CurrentItem.indent + "  "
$Type = ""
$HasUrl = $false
$TypeCount = 0
$UrlCount = 0
for ($Index = $Start + 1; $Index -lt $End; $Index++) {
    if ($Lines[$Index] -match ('^' + [regex]::Escape($PropertyIndent) + 'type:\s*([A-Za-z]+)\s*$')) {
        $TypeCount++
        $Type = $Matches[1]
    }
    if ($Lines[$Index] -match ('^' + [regex]::Escape($PropertyIndent) + 'url:')) {
        $UrlCount++
        if ($Lines[$Index] -match ('^' + [regex]::Escape($PropertyIndent) + 'url:\s*(\S+)\s*$')) {
            $UrlMarker = $Matches[1]
            if ($UrlMarker -notmatch '^(?i:null|["'']{2})$') { $HasUrl = $true }
        }
    }
}
if ($TypeCount -ne 1 -or $UrlCount -gt 1) { throw "当前 profile 的 type/url 格式重复或不受支持" }

if ($Type -eq "remote" -and $HasUrl) {
    $ExistingState = Get-Progress
    $LaterStates = @("PROXY_REACHABLE", "AIRPORT_VERIFIED", "WAITING_FOR_ENHANCEMENT_FILES", "WAITING_FOR_ISP", "WAITING_FOR_ACTIVATION", "ROUTING_CONFIGURED", "VALIDATION_PASSED", "COMPLETED")
    if ($LaterStates -notcontains $ExistingState) { Set-Progress "SUBSCRIPTION_IMPORTED" "subscription_imported" }
    Write-Output "SETUP_STATE=SUBSCRIPTION_IMPORTED"
    Write-Output "NEXT_ACTION=CONTINUE_PREFLIGHT"
} else {
    Set-Progress "WAITING_FOR_SUBSCRIPTION" "subscription_not_imported"
    Write-Output "SETUP_STATE=WAITING_FOR_SUBSCRIPTION"
    Write-Output "NEXT_ACTION=OPEN_CLASH_AND_IMPORT_SUBSCRIPTION"
}
