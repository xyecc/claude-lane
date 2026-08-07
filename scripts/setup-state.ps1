[CmdletBinding(DefaultParameterSetName = "Get")]
param(
    [Parameter(ParameterSetName = "Set", Mandatory = $true)]
    [ValidateSet("CLASH_INSTALLED", "WAITING_FOR_SUBSCRIPTION", "SUBSCRIPTION_IMPORTED", "PROXY_REACHABLE", "AIRPORT_VERIFIED", "WAITING_FOR_ENHANCEMENT_FILES", "WAITING_FOR_ISP", "WAITING_FOR_ACTIVATION", "ROUTING_CONFIGURED", "VALIDATION_PASSED", "COMPLETED")]
    [string]$Set,
    [Parameter(ParameterSetName = "Set", Mandatory = $true)]
    [ValidateSet("clash_installed", "profiles_missing", "subscription_not_imported", "subscription_imported", "proxy_reachable", "airport_verified", "enhancement_files_missing", "isp_required", "activation_required", "routing_configured", "validation_passed", "completed")]
    [string]$Reason,
    [Parameter(ParameterSetName = "Get")]
    [switch]$Get
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$StateRoot = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_LANE_SETUP_ROOT)) { $env:CLAUDE_LANE_SETUP_ROOT } else { Join-Path $env:LOCALAPPDATA "claude-lane" }
$StateFile = Join-Path $StateRoot "setup-progress.json"
$AllowedStates = @("CLASH_INSTALLED", "WAITING_FOR_SUBSCRIPTION", "SUBSCRIPTION_IMPORTED", "PROXY_REACHABLE", "AIRPORT_VERIFIED", "WAITING_FOR_ENHANCEMENT_FILES", "WAITING_FOR_ISP", "WAITING_FOR_ACTIVATION", "ROUTING_CONFIGURED", "VALIDATION_PASSED", "COMPLETED")

if (Test-Path -LiteralPath $StateRoot) {
    $RootItem = Get-Item -LiteralPath $StateRoot -Force
    if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "安装进度目录不能是重解析点" }
}
if (Test-Path -LiteralPath $StateFile) {
    $StateItem = Get-Item -LiteralPath $StateFile -Force
    if (($StateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "安装进度文件不能是重解析点" }
}

if ($PSCmdlet.ParameterSetName -eq "Set") {
    New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
    $TempFile = Join-Path $StateRoot (".setup-progress-" + [guid]::NewGuid().ToString("N") + ".json")
    try {
        [ordered]@{
            schema = 1
            state = $Set
            platform = "windows"
            reason = $Reason
            updated_at = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        } | ConvertTo-Json | Set-Content -LiteralPath $TempFile -Encoding UTF8
        Move-Item -LiteralPath $TempFile -Destination $StateFile -Force
    } finally {
        Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue
    }
    Write-Output "SETUP_STATE=$Set"
    return
}

if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
    Write-Output "NOT_STARTED"
    return
}
$Document = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$Document.schema -ne 1 -or $AllowedStates -notcontains [string]$Document.state) { throw "安装进度文件损坏或包含未知状态" }
Write-Output ([string]$Document.state)
