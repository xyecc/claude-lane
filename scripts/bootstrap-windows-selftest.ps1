$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")).Path
$Bootstrap = Join-Path $RepoRoot "bootstrap.ps1"
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
    $Manifest = [ordered]@{
        schema = 1; release_status = "released"; minimum_windows = "10.0.17763"; required_free_mb = 2048
        claude_lane = [ordered]@{ version = "1.3.0"; windows_path = "claude-lane/releases/v1.3.0/claude-lane.zip"; archive_root = "claude-lane-1.3.0"; windows_sha256 = ("1" * 64) }
        claude_code = [ordered]@{
            version = "2.1.212"
            win32_arm64 = [ordered]@{ path = "claude-code/releases/2.1.212/claude-win32-arm64.exe"; sha256 = "adaa6e3dadb8016755ccd1907a5f249c1bc9bdb6c71d3f7dcea7d5db8f72d0a5"; signature_status = "verified-authenticode" }
            win32_x64 = [ordered]@{ path = "claude-code/releases/2.1.212/claude-win32-x64.exe"; sha256 = "fe639693fd7e9a881c799867711abb7666dec2a5fefbaba41af6a09e71bcbefa"; signature_status = "verified-authenticode" }
        }
        clash_verge = [ordered]@{
            version = "2.5.2"
            win32_arm64 = [ordered]@{ path = "clash-verge/releases/v2.5.2/Clash.Verge_2.5.2_arm64-setup.exe"; sha256 = "973fafb5f154e541b34c1315f7de7440daf68d05f2e52fa08da2bcc71b6c3214"; signature_status = "verified-authenticode" }
            win32_x64 = [ordered]@{ path = "clash-verge/releases/v2.5.2/Clash.Verge_2.5.2_x64-setup.exe"; sha256 = "ba42f00b1082e352352080170fe86ae411bcc854cb13f1b8bebc9025e8a7cbf4"; signature_status = "verified-authenticode" }
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
