[CmdletBinding()]
param(
    [string]$DeploymentId = "",
    [switch]$List,
    [string]$ScriptRoot = ""
)

# Restore only files recorded by windows-routing.ps1. Backups can contain ISP
# credentials, so this command never prints file contents.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$InstallRoot = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_LANE_SETUP_ROOT)) {
    $env:CLAUDE_LANE_SETUP_ROOT
} else {
    Join-Path $env:LOCALAPPDATA "claude-lane"
}
$BackupParent = Join-Path $InstallRoot "backups"
$ResolvedScriptRoot = if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) { (Resolve-Path -LiteralPath $ScriptRoot).Path } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$StateTool = Join-Path $ResolvedScriptRoot "setup-state.ps1"

function Stop-Rollback([string]$Message) { throw "停止：$Message" }
function Get-BackupDirectories {
    if (-not (Test-Path -LiteralPath $BackupParent -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $BackupParent -Directory | Where-Object {
        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
        (Test-Path -LiteralPath (Join-Path $_.FullName "manifest.json") -PathType Leaf)
    } | Sort-Object Name -Descending)
}

$Backups = Get-BackupDirectories
if ($List) {
    if ($Backups.Count -eq 0) { Write-Output "NO_BACKUPS"; return }
    foreach ($Backup in $Backups) { Write-Output ("DEPLOYMENT_ID=" + $Backup.Name) }
    return
}
if ([string]::IsNullOrWhiteSpace($DeploymentId)) {
    if ($Backups.Count -eq 0) { Stop-Rollback "没有可用备份" }
    $DeploymentId = $Backups[0].Name
}
if ($DeploymentId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{6,63}$') { Stop-Rollback "deployment id 格式无效" }
$BackupRoot = Join-Path $BackupParent $DeploymentId
$BackupRootResolved = (Resolve-Path -LiteralPath $BackupRoot).Path
$BackupParentResolved = (Resolve-Path -LiteralPath $BackupParent).Path.TrimEnd('\') + '\'
if (-not $BackupRootResolved.StartsWith($BackupParentResolved, [StringComparison]::OrdinalIgnoreCase)) { Stop-Rollback "备份路径越界" }
$ManifestPath = Join-Path $BackupRootResolved "manifest.json"
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { Stop-Rollback "备份清单不存在" }
$ManifestItem = Get-Item -LiteralPath $ManifestPath -Force
if (($ManifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Rollback "备份清单不能是重解析点" }
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$Manifest.schema -ne 1 -or [string]$Manifest.deployment_id -ne $DeploymentId) { Stop-Rollback "备份清单无效" }
$ConfigRoot = [string]$Manifest.config_root
$ConfigRootPrefix = [IO.Path]::GetFullPath($ConfigRoot).TrimEnd('\') + '\'

foreach ($Entry in @($Manifest.entries)) {
    $Target = [IO.Path]::GetFullPath([string]$Entry.path)
    if (-not $Target.StartsWith($ConfigRootPrefix, [StringComparison]::OrdinalIgnoreCase)) { Stop-Rollback "备份目标越过 Clash 配置目录" }
    if (Test-Path -LiteralPath $Target) {
        $TargetItem = Get-Item -LiteralPath $Target -Force
        if ($TargetItem.PSIsContainer -or ($TargetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Rollback "回滚目标不是普通文件" }
    }
    switch ([string]$Entry.state) {
        "file" {
            $BackupName = [string]$Entry.backup
            if ($BackupName -notmatch '^[0-9]{2}-[a-z]+\.yaml$') { Stop-Rollback "备份文件名无效" }
            $Source = Join-Path $BackupRootResolved $BackupName
            if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { Stop-Rollback "备份文件缺失" }
            $SourceItem = Get-Item -LiteralPath $Source -Force
            if (($SourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Rollback "备份文件不能是重解析点" }
            Copy-Item -LiteralPath $Source -Destination $Target -Force
        }
        "created" {
            if (Test-Path -LiteralPath $Target -PathType Leaf) { Remove-Item -LiteralPath $Target -Force }
        }
        default { Stop-Rollback "备份清单包含未知状态" }
    }
}

if (Test-Path -LiteralPath $StateTool -PathType Leaf) {
    $StateBlock = [scriptblock]::Create((Get-Content -LiteralPath $StateTool -Raw -Encoding UTF8))
    & $StateBlock -Set SUBSCRIPTION_IMPORTED -Reason subscription_imported | Out-Null
}
Write-Output "ROLLBACK_COMPLETED=$DeploymentId"
Write-Output "请在 Clash Verge 点击当前订阅卡片重新加载；输出不含任何配置或凭证。"
