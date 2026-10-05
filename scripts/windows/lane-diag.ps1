# claude-lane Windows 诊断：US-Static 不通时，分层判断是 配置 / 凭证 / 静态IP或机场 的问题
# 用法：powershell -ep bypass -f "$([Environment]::GetFolderPath('Desktop'))\lane-diag.ps1"
# 结果同时存到桌面 lane-diag.txt（UTF-16），可传回协助者
$OUT = Join-Path ([Environment]::GetFolderPath('Desktop')) 'lane-diag.txt'
& {
$CFG  = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$PROF = Join-Path $CFG 'profiles'
$utf8 = New-Object System.Text.UTF8Encoding $false

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
function Invoke-Api($path) {
  $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', 'verge-mihomo', [IO.Pipes.PipeDirection]::InOut)
  $pipe.Connect(3000)
  $w = New-Object IO.StreamWriter($pipe); $w.AutoFlush = $true
  $w.Write("GET $path HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`n`r`n")
  $r = New-Object IO.StreamReader($pipe, $utf8)
  $s = $r.ReadToEnd(); $pipe.Dispose()
  ($s -split "`r`n`r`n", 2)[1]
}
$t = [IO.File]::ReadAllText((Join-Path $PROF "$((Get-Current).opt['proxies']).yaml"), $utf8)
function Get-Field($k) {
  $m = [regex]::Match($t, "(?m)^\s+$k\:\s*(.+?)\s*$")
  if (-not $m.Success) { return $null }
  $v = $m.Groups[1].Value
  if ($v -match "^'(.*)'$") { $v = $Matches[1] -replace "''", "'" } elseif ($v -match '^"(.*)"$') { $v = $Matches[1] }
  $v
}
$srv = Get-Field 'server'; $port = Get-Field 'port'; $u = Get-Field 'username'; $pw = Get-Field 'password'
function Mask($s) { if (-not $s) { '(空)' } elseif ($s.Length -gt 6) { $s.Substring(0,6) + '***' } else { '***' } }
function Hide-Host($s) { if ($srv -and $s) { $s -replace [regex]::Escape($srv), (Mask $srv) } else { $s } }

"== 1. 配置文件里的静态 IP 节点"
"  type=$(Get-Field 'type')  udp=$(Get-Field 'udp')  dialer-proxy=$(Get-Field 'dialer-proxy')"
"  主机=$(Mask $srv)  端口=$port  用户名长度=$($u.Length)  密码长度=$($pw.Length)"
"  密码含空白字符: $([bool]($pw -match '\s'))"

"== 2. 绕开链式配置：curl 直接用这组凭证连静态 IP（经 TUN 走机场默认节点）"
$cfgFile = Join-Path $env:TEMP 'lane-curl.cfg'
$cred = "$u`:$pw".Replace('\', '\\').Replace('"', '\"')
[IO.File]::WriteAllText($cfgFile, "proxy-user = `"$cred`"`n", $utf8)
$A = 'other'
try {
  $res = & curl.exe -sS --max-time 25 -K $cfgFile -x "socks5h://$srv`:$port" https://api.ipify.org 2>&1 | Out-String
  $code = $LASTEXITCODE
} finally { Remove-Item $cfgFile -ErrorAction SilentlyContinue }
"  curl 退出码=$code  输出: $(Hide-Host $res.Trim())"
if ($code -eq 0) { $A = 'ok' }
elseif ($code -eq 97 -or $res -match 'auth|User was rejected|Authentication') { $A = 'auth' }
elseif ($code -in 7, 28) { $A = 'unreach' }

"== 3. 走链式配置测 US-Static（Clash 内核 API）"
$B = 'unknown'
try {
  $chain = Invoke-Api '/proxies/US-Chain'
  if ($chain -match '"now":"([^"]*)"') { "  US-Chain 当前节点: $($Matches[1])" }
  $d = Invoke-Api ("/proxies/" + [Uri]::EscapeDataString('🇺🇸 US-Static') + "/delay?timeout=10000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204")
  "  返回: $(Hide-Host $d.Trim())"
  if ($d -match '"delay":\s*(\d+)') { $B = 'ok' } else { $B = 'fail' }
} catch { "  API 连不上: $($_.Exception.Message)" }

"== 4. 内核日志里和静态 IP 相关的最近几行"
$logs = Get-ChildItem (Join-Path $CFG 'logs') -Recurse -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3
$hits = $logs | ForEach-Object { Select-String -Path $_.FullName -Pattern "US-Static|US-Chain|socks5|:$port" -Encoding UTF8 -ErrorAction SilentlyContinue } | Select-Object -Last 12
if ($hits) { $hits | ForEach-Object { '  ' + (Hide-Host $_.Line) } } else { '  （没找到相关日志行）' }

"`n================ 结论 ================"
if ($A -eq 'ok' -and $B -eq 'ok') { '已经通了。重跑 lane-verify.ps1 即可。' }
elseif ($A -eq 'ok') { '静态 IP 和凭证都没问题（curl 能用它上网），问题在链式配置这一层：试着给 US-Chain 换节点；还不行把这份结果发协助者。' }
elseif ($A -eq 'auth') { '静态 IP 拒绝了凭证：用户名/密码不对，或服务商开了 IP 白名单认证。去服务商后台核对（或重置密码后重跑 lane-config.ps1 选 n）。' }
elseif ($A -eq 'unreach') { '连这个静态 IP 本身就连不上（不是配置问题）：IP 过期/未激活/端口不对，或机场节点封了这个端口。先去服务商后台看 IP 状态；后台正常就换机场试。' }
else { '没法自动判断，把整份结果发协助者。' }
} *>&1 | Tee-Object -FilePath $OUT
"`n(saved to $OUT)"
