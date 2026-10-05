# claude-lane Windows 验收：7 项检查，全 PASS 才算部署完成
# 用法：powershell -ep bypass -f "$([Environment]::GetFolderPath('Desktop'))\lane-verify.ps1"
$CFG  = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$PROF = Join-Path $CFG 'profiles'
$utf8 = New-Object System.Text.UTF8Encoding $false
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'

function Get-Current {
  $lines = [IO.File]::ReadAllLines((Join-Path $CFG 'profiles.yaml'), $utf8)
  $cur = $null; $name = $null; $opt = @{}; $in = $false
  foreach ($l in $lines) { if ($l -match '^current:\s*(\S+)') { $cur = $Matches[1]; break } }
  foreach ($l in $lines) {
    if ($l -match '^- uid:\s*(\S+)') { $in = ($Matches[1] -eq $cur); continue }
    if (-not $in) { continue }
    if ($l -match '^  name:\s*(.+?)\s*$') { $name = $Matches[1] }
    if ($l -match '^    (proxies|groups|rules|merge):\s*(\S+)\s*$') { $opt[$Matches[1]] = $Matches[2] }
  }
  [pscustomobject]@{ uid = $cur; name = $name; opt = $opt }
}
$script:fail = 0
# 别叫 R：R 是 Invoke-History 的内置别名，会盖掉同名函数
function Test-Item($ok, $msg) {
  if ($ok) { Write-Host "[PASS] $msg" -ForegroundColor Green } else { Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:fail++ }
}
function Mask($ip) { if (-not $ip) { '(无)' } elseif ($ip.Length -gt 6) { $ip.Substring(0,6) + '***' } else { '***' } }

$gen = [IO.File]::ReadAllText((Join-Path $CFG 'clash-verge.yaml'), $utf8)
$vg  = [IO.File]::ReadAllText((Join-Path $CFG 'verge.yaml'), $utf8)
Test-Item ($vg -match '(?m)^enable_tun_mode:\s*true') 'TUN 已开启'
Test-Item ($gen -match '(?m)^mode:\s*rule') '规则模式'
Test-Item ($gen -match 'US-Static' -and $gen -match 'US-Chain') '生成配置里有 US-Static / US-Chain（增强文件已合并）'
Test-Item ($gen -match 'DOMAIN-SUFFIX,claude\.ai,Claude') '生成配置里有 Claude 规则'
Test-Item ($gen -match '(?m)^sniffer:') '生成配置里有 sniffer'

$px  = [IO.File]::ReadAllText((Join-Path $PROF "$((Get-Current).opt['proxies']).yaml"), $utf8)
$srv = ([regex]'(?m)^\s+server:\s*(\S+)').Match($px).Groups[1].Value
try { $staticIPs = @([Net.Dns]::GetHostAddresses($srv) | ForEach-Object { $_.IPAddressToString }) } catch { $staticIPs = @($srv) }
$cl = $null; $ap = $null
try { $t = (Invoke-WebRequest https://claude.ai/cdn-cgi/trace -UseBasicParsing -TimeoutSec 20).Content; $cl = ([regex]'(?m)^ip=(\S+)').Match($t).Groups[1].Value }
catch { Write-Host "  claude.ai 请求失败: $($_.Exception.Message)" }
try { $ap = (Invoke-WebRequest https://api.ipify.org -UseBasicParsing -TimeoutSec 20).Content.Trim() }
catch { Write-Host "  ipify 请求失败: $($_.Exception.Message)" }
Test-Item ($cl -and ($staticIPs -contains $cl)) 'claude.ai 出口 = 静态 IP'
Test-Item ($ap -and -not ($staticIPs -contains $ap)) '其他网站出口 ≠ 静态 IP（没有全局误走静态）'
Write-Host ("  静态 IP: {0}   claude.ai 看到: {1}   其他网站看到: {2}" -f (Mask $staticIPs[0]), (Mask $cl), $ap)
if ($cl) {
  try {
    $geo = (Invoke-WebRequest "https://ipinfo.io/$cl/json" -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
    Write-Host "  claude.ai 出口归属: $($geo.city), $($geo.region), $($geo.country)  $($geo.org)"
  } catch {}
}
if ($script:fail -eq 0) { Write-Host "`n全部通过" -ForegroundColor Green }
else { Write-Host "`n$($script:fail) 项未通过 → 跑 lane-diag.ps1 定位是哪一层" -ForegroundColor Red }
