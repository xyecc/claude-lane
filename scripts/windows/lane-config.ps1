# claude-lane Windows 配置脚本：把静态 IP 专线写进 Clash Verge Rev 当前订阅的四个增强文件
# 用法（对方电脑 PowerShell）：powershell -ep bypass -f "$([Environment]::GetFolderPath('Desktop'))\lane-config.ps1"
# 前提：已导入含美国节点的订阅并点过卡片激活。凭证在对方电脑上隐藏输入，不经过协助者。
$ErrorActionPreference = 'Stop'
$CFG  = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$PROF = Join-Path $CFG 'profiles'
$utf8 = New-Object System.Text.UTF8Encoding $false
# 注意：函数名别用单字母，PowerShell 内置别名（如 R = Invoke-History）优先于函数
function Die($m) { Write-Host "`n[STOP] $m" -ForegroundColor Red; exit 1 }

# 读 profiles.yaml：当前订阅 uid / 名字 / 四个增强文件 uid
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
# Mihomo 控制 API：Verge 在 Windows 上走命名管道
function Invoke-Api($path) {
  $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', 'verge-mihomo', [IO.Pipes.PipeDirection]::InOut)
  $pipe.Connect(3000)
  $w = New-Object IO.StreamWriter($pipe); $w.AutoFlush = $true
  $w.Write("GET $path HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`n`r`n")
  $r = New-Object IO.StreamReader($pipe, $utf8)
  $s = $r.ReadToEnd(); $pipe.Dispose()
  ($s -split "`r`n`r`n", 2)[1]
}
function Get-Field($text, $k) {
  $m = [regex]::Match($text, "(?m)^\s+$k\:\s*(.+?)\s*$")
  if (-not $m.Success) { return $null }
  $v = $m.Groups[1].Value
  if ($v -match "^'(.*)'$") { $v = $Matches[1] -replace "''", "'" } elseif ($v -match '^"(.*)"$') { $v = $Matches[1] }
  $v
}
function Read-Secret($prompt) {
  $s = Read-Host $prompt -AsSecureString
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Quote-Single($s) { "'" + ($s -replace "'", "''") + "'" }
function Quote-Double($s) { '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }

$US = '美国|🇺🇸|\bUSA?\b|United States|America|Los Angeles|San Jose|Seattle|Dallas|Phoenix|Ashburn|LAX|SJC'

# ---- 0. 定位当前订阅 + 前置检查 ----
if (-not (Test-Path (Join-Path $CFG 'profiles.yaml'))) { Die "没找到 Clash Verge 配置目录：$CFG" }
$c = Get-Current
Write-Host "当前激活的订阅: $($c.name)  ($($c.uid))"
$F = [ordered]@{}
foreach ($k in 'proxies','groups','rules','merge') {
  if (-not $c.opt[$k]) { Die "当前订阅缺少 $k 增强文件。到订阅页右键当前卡片 → 编辑节点/编辑分组/编辑规则/编辑 Merge 各打开一次直接保存，再重跑" }
  $F[$k] = Join-Path $PROF "$($c.opt[$k]).yaml"
  if (-not (Test-Path $F[$k])) { Die "缺少增强文件 $($F[$k])" }
  $t = [IO.File]::ReadAllText($F[$k], $utf8)
  $body = (($t -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join '' -replace '\s',''
  if ($t -notmatch 'claude-lane managed' -and $body -ne '' -and $body -ne 'prepend:[]append:[]delete:[]') {
    Die "$k 文件里有对方自己写的内容，不能直接覆盖：$($F[$k])"
  }
}
Write-Host "[OK] 前置检查通过" -ForegroundColor Green

# ---- 1. 从当前订阅里找美国节点 ----
$sub = [IO.File]::ReadAllText((Join-Path $PROF "$($c.uid).yaml"), $utf8)
$blk = [regex]::Match($sub, '(?ms)^proxies:[^\n]*\n(.*?)(?=^[^\s#-]|\z)').Groups[1].Value
$all = @([regex]::Matches($blk, '(?m)^\s*-\s*\{?\s*name:\s*(.+?)\s*(,|\}|$)') | ForEach-Object { $_.Groups[1].Value.Trim("'`" ") })
$us  = @($all | Where-Object { $_ -match $US -and $_ -notmatch 'US-Static' })
Write-Host "订阅共 $($all.Count) 个节点，其中美国节点 $($us.Count) 个"
if ($us.Count -eq 0) { $all | ForEach-Object { "  $_" }; Die '没识别出美国节点，把上面的节点列表截图发给协助者' }

# ---- 2. 测延迟排序（内核 API；测不了就按订阅顺序） ----
$scored = foreach ($n in $us) {
  $ms = 99999
  try {
    $b = Invoke-Api ("/proxies/" + [Uri]::EscapeDataString($n) + "/delay?timeout=4000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204")
    if ($b -match '"delay":\s*(\d+)') { $ms = [int]$Matches[1] }
  } catch {}
  Write-Host ("  {0,-6} {1}" -f $(if ($ms -lt 99999) { "${ms}ms" } else { '超时' }), $n)
  [pscustomobject]@{ n = $n; ms = $ms }
}
$ordered = @($scored | Sort-Object ms | ForEach-Object { $_.n })
if (@($scored | Where-Object { $_.ms -lt 99999 }).Count -eq 0) {
  Write-Host '  （全部测不出延迟：内核 API 不通或订阅没激活，按订阅原顺序写入）' -ForegroundColor Yellow
  $ordered = $us
}

# ---- 3. 凭证：沿用之前写过的，或粘贴整串 主机:端口:用户名:密码 ----
$h = $null
$prev = Get-ChildItem $PROF -Filter 'p*.yaml' | Where-Object { $_.FullName -ne $F['proxies'] } | Sort-Object LastWriteTime -Descending |
  Where-Object { [IO.File]::ReadAllText($_.FullName, $utf8) -match 'US-Static' } | Select-Object -First 1
$cand = @($prev | ForEach-Object { $_.FullName }) + @($F['proxies'])
foreach ($pf in $cand) {
  $pt = [IO.File]::ReadAllText($pf, $utf8)
  $ph = Get-Field $pt 'server'
  if ($pt -match 'US-Static' -and $ph) {
    $ans = Read-Host "发现之前写过的静态 IP（主机 $($ph.Substring(0, [Math]::Min(4, $ph.Length)))***，端口 $(Get-Field $pt 'port')），直接沿用？[Y/n]"
    if ($ans -notmatch '^[nN]') { $h = $ph; $port = Get-Field $pt 'port'; $u = Get-Field $pt 'username'; $pw = Get-Field $pt 'password' }
    break
  }
}
if (-not $h) {
  Write-Host "`n粘贴服务商给的整串  主机:端口:用户名:密码  然后回车（输入不显示）" -ForegroundColor Cyan
  $line  = (Read-Secret '整串').Trim()
  $line2 = (Read-Secret '再粘一次（核对远程粘贴没丢字）').Trim()
  if ($line -ne $line2) { Die '两次不一致（远程粘贴可能丢字），重跑一次本脚本即可' }
  $parts = $line.Split(':', 4)
  if ($parts.Count -ne 4) { Die "格式不对：应该是 主机:端口:用户名:密码 四段，实际 $($parts.Count) 段" }
  $h, $port, $u, $pw = $parts[0].Trim(), $parts[1].Trim(), $parts[2].Trim(), $parts[3]
  $line = $null; $line2 = $null
}
if (-not $h -or $h -match '\s') { Die '主机为空或含空格' }
if ($port -notmatch '^\d{1,5}$' -or [int]$port -gt 65535) { Die "端口不对（长度 $($port.Length)）" }
if (-not $u) { Die '用户名为空' }
if (-not $pw) { Die '密码为空' }

# ---- 4. 备份 ----
$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$BAK = Join-Path $CFG "claude-lane-backup\$ts"
New-Item -ItemType Directory -Force -Path $BAK | Out-Null
Copy-Item (Join-Path $CFG 'profiles.yaml') $BAK
foreach ($p in $F.Values) { Copy-Item $p $BAK }
Write-Host "[OK] 已备份到 $BAK" -ForegroundColor Green

# ---- 5. 写入（UTF-8 无 BOM、LF） ----
$proxies = @"
# claude-lane managed (Windows) - static IP node
prepend: []

append:
  # claude-lane managed start
  - name: "🇺🇸 US-Static"
    type: socks5
    server: $h
    port: $port
    username: $(Quote-Single $u)
    password: $(Quote-Single $pw)
    udp: false
    dialer-proxy: "US-Chain"
  # claude-lane managed end

delete: []
"@
$groups = "# claude-lane managed (Windows)`nprepend:`n  - name: `"Claude`"`n    type: select`n    proxies:`n      - `"🇺🇸 US-Static`"`n`n" +
  "  - name: `"US-Chain`"`n    type: select`n    proxies:`n" +
  (($ordered | ForEach-Object { "      - $(Quote-Double $_)" }) -join "`n") + "`n`nappend: []`n`ndelete: []`n"
# 规则 = templates/3-rules.yaml 的 Windows 版（进程名换成 .exe）。顺序敏感：QUIC 拦截在最前
$rules = @'
# claude-lane managed (Windows)
prepend:
  - "AND,((PROCESS-NAME,chrome.exe),(NETWORK,UDP),(DST-PORT,443)),REJECT"
  - "AND,((PROCESS-NAME,msedge.exe),(NETWORK,UDP),(DST-PORT,443)),REJECT"
  - "AND,((PROCESS-NAME,Claude.exe),(NETWORK,UDP)),REJECT"
  - "AND,((PROCESS-NAME,claude.exe),(NETWORK,UDP)),REJECT"
  - "PROCESS-NAME,Claude.exe,Claude"
  - "PROCESS-NAME,claude.exe,Claude"
  - "DOMAIN-SUFFIX,anthropic.com,Claude"
  - "DOMAIN-SUFFIX,claude.com,Claude"
  - "DOMAIN-SUFFIX,claude.ai,Claude"
  - "DOMAIN-SUFFIX,claudeusercontent.com,Claude"
  - "DOMAIN-KEYWORD,anthropic,Claude"
  - "DOMAIN-SUFFIX,http-intake.logs.us5.datadoghq.com,Claude"
  - "IP-CIDR,160.79.104.0/23,Claude,no-resolve"

append: []

delete: []
'@
# = templates/4-merge.yaml 的 sniffer 段
$merge = @'
# claude-lane managed (Windows)
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
'@
$out = @{ proxies = $proxies; groups = $groups; rules = $rules; merge = $merge }
foreach ($k in $F.Keys) { [IO.File]::WriteAllText($F[$k], (($out[$k] -replace "`r`n", "`n").TrimEnd("`n") + "`n"), $utf8) }
$pwLen = $pw.Length; $pw = $null

# ---- 6. 打码回显 ----
$hm = if ($h.Length -gt 4) { $h.Substring(0,4) + '***' } else { '***' }
Write-Host "`n[OK] 已写入四个增强文件（订阅：$($c.name)）" -ForegroundColor Green
Write-Host "  主机: $hm  端口: $port  用户名长度: $($u.Length)  密码长度: $pwLen"
Write-Host "  US-Chain 首选: $($ordered[0])  （共 $($ordered.Count) 个）"
Write-Host "  备份: $BAK"
$vg = Join-Path $CFG 'verge.yaml'
if ((Test-Path $vg) -and ([IO.File]::ReadAllText($vg, $utf8) -notmatch '(?m)^enable_tun_mode:\s*true')) {
  Write-Host "`n⚠ TUN 还没开：Clash Verge「设置」里打开 TUN 模式（提示装服务就点安装）" -ForegroundColor Yellow
}
Write-Host "`n下一步：Clash Verge 订阅页点一下当前订阅卡片（让配置合并生效），然后跑 lane-verify" -ForegroundColor Cyan
