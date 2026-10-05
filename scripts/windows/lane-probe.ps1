# claude-lane Windows 体检（只读，不改任何东西）
# 用法：powershell -ep bypass -f "$([Environment]::GetFolderPath('Desktop'))\lane-probe.ps1"
# 结果同时存到桌面 lane-probe.txt（UTF-16），可传回协助者；订阅链接不会出现在输出里
$OUT = Join-Path ([Environment]::GetFolderPath('Desktop')) 'lane-probe.txt'
& {
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
$CFG  = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$PROF = Join-Path $CFG 'profiles'
$utf8 = New-Object System.Text.UTF8Encoding $false
$US = '美国|🇺🇸|\bUSA?\b|United States|America|Los Angeles|San Jose|Seattle|Dallas|Phoenix|Ashburn|LAX|SJC'

"== 系统"
"  $([Environment]::OSVersion.VersionString)  $env:PROCESSOR_ARCHITECTURE  管理员=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

"== 代理/VPN 类进程（除 clash-verge / verge-mihomo 外出现别的都要先退出）"
Get-Process | Where-Object { $_.Name -match 'clash|verge|mihomo|v2ray|xray|sing-box|nekoray|shadowsocks|trojan|flclash|hiddify|tailscale|wireguard|openvpn' } |
  ForEach-Object { "  $($_.Name)" } | Sort-Object -Unique

"== 网卡（留意 TAP / WireGuard / 别家 TUN）"
Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object { "  $($_.Name) | $($_.InterfaceDescription)" }

"== Clash Verge"
if (-not (Test-Path (Join-Path $CFG 'profiles.yaml'))) { "  ✗ 没找到配置目录 $CFG（没装或没用过 Clash Verge Rev）"; return }
$lines = [IO.File]::ReadAllLines((Join-Path $CFG 'profiles.yaml'), $utf8)
$cur = $null; $name = $null; $opt = @{}; $in = $false; $remotes = 0
foreach ($l in $lines) { if ($l -match '^current:\s*(\S+)') { $cur = $Matches[1]; break } }
foreach ($l in $lines) {
  if ($l -match '^  type:\s*remote') { $remotes++ }
  if ($l -match '^- uid:\s*(\S+)') { $in = ($Matches[1] -eq $cur); continue }
  if (-not $in) { continue }
  if ($l -match '^  name:\s*(.+?)\s*$') { $name = $Matches[1] }
  if ($l -match '^    (proxies|groups|rules|merge):\s*(\S+)\s*$') { $opt[$Matches[1]] = $Matches[2] }
}
"  订阅数=$remotes  当前订阅=$name ($cur)"
foreach ($k in 'proxies','groups','rules','merge') {
  if (-not $opt[$k]) { "  $k 增强文件: ✗ 未登记"; continue }
  $p = Join-Path $PROF "$($opt[$k]).yaml"
  if (-not (Test-Path $p)) { "  $k 增强文件: ✗ 文件不存在"; continue }
  $t = [IO.File]::ReadAllText($p, $utf8)
  $body = (($t -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join '' -replace '\s',''
  $state = if ($t -match 'claude-lane managed') { '已是 claude-lane 写的' } elseif ($body -eq '' -or $body -eq 'prepend:[]append:[]delete:[]') { '空（可直接写）' } else { '⚠ 有对方自己的内容' }
  "  $k 增强文件: $state"
}
$gen = if (Test-Path (Join-Path $CFG 'clash-verge.yaml')) { [IO.File]::ReadAllText((Join-Path $CFG 'clash-verge.yaml'), $utf8) } else { '' }
$vg  = if (Test-Path (Join-Path $CFG 'verge.yaml')) { [IO.File]::ReadAllText((Join-Path $CFG 'verge.yaml'), $utf8) } else { '' }
"  模式=$(([regex]'(?m)^mode:\s*(\S+)').Match($gen).Groups[1].Value)  TUN=$(([regex]'(?m)^enable_tun_mode:\s*(\S+)').Match($vg).Groups[1].Value)  系统代理=$(([regex]'(?m)^enable_system_proxy:\s*(\S+)').Match($vg).Groups[1].Value)"

"== 当前订阅里的美国节点"
if ($cur -and (Test-Path (Join-Path $PROF "$cur.yaml"))) {
  $sub = [IO.File]::ReadAllText((Join-Path $PROF "$cur.yaml"), $utf8)
  $blk = [regex]::Match($sub, '(?ms)^proxies:[^\n]*\n(.*?)(?=^[^\s#-]|\z)').Groups[1].Value
  $all = @([regex]::Matches($blk, '(?m)^\s*-\s*\{?\s*name:\s*(.+?)\s*(,|\}|$)') | ForEach-Object { $_.Groups[1].Value.Trim("'`" ") })
  $us  = @($all | Where-Object { $_ -match $US })
  "  共 $($all.Count) 个节点，美国 $($us.Count) 个"
  $us | ForEach-Object { "  $_" }
  if ($us.Count -eq 0) { '  （没识别出美国节点，全部节点名：）'; $all | ForEach-Object { "    $_" } }
}

"== 当前出口 IP"
try { "  " + (Invoke-WebRequest https://api.ipify.org -UseBasicParsing -TimeoutSec 15).Content } catch { "  FAIL: $($_.Exception.Message)" }
"== END"
} *>&1 | Tee-Object -FilePath $OUT
"`n(saved to $OUT)"
