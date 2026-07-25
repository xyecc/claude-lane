# 排障手册（10 个真实踩过的坑）

按症状查。每条格式：症状 → 原因 → 处理。前 3 条及第 9、10 条是 2026-07 真机实战新增，其余继承自本仓库第一版。

---

## 1. TUN 起不来：日志报 `Start TUN listening error: add route: ... file exists`（最凶的坑）

**症状**：重载配置后整机断外网/全部超时；日志里有上面这行；重启 Clash 内核、重启特权服务都没用。

**原因**：**另一个 VPN/代理 App 抢占了系统路由**（实战案例是 Mac 版 Shadowrocket 被人点了连接，它的 PacketTunnel 建了自己的 utun 并加了同样的 1/8、2/7…分片路由）。Clash 拆掉自己 TUN 后路由加不回去，流量全灌进对方的隧道。

**处理**（依次执行）：

```bash
# ① 看分片路由挂在哪个 utun 上
netstat -rn -f inet | head -20
# ② 找出持有者进程（unit N 对应 utun(N-1)，比如 unit 5 = utun4）
lsof -n | grep utun_control
# ③ 列出 VPN，停掉冲突的那个（保留 Tailscale；不需要 sudo）
scutil --nc list
scutil --nc stop <冲突VPN的UUID>
# ④ 释放后让 Clash 重建 TUN
curl -X PATCH --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/configs -d '{"tun":{"enable":false}}'
sleep 2
curl -X PATCH --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/configs -d '{"tun":{"enable":true}}'
```

**根治**：卸载 Mac 上多余的代理 App。一台 Mac 只留一个接管路由的代理软件。

## 2. Chrome 网页版 claude.ai 显示日本/其他国家会话（QUIC 漏流）

**症状**：桌面版/Claude Code 归属地正确，唯独 Chrome 里的会话显示日本东京等机场默认节点位置。

**原因**：Chrome 用 QUIC（HTTP/3，UDP/443）直连，mihomo 对 QUIC 的域名嗅探不可靠，流量落到 MATCH 兜底走了默认节点。TCP 的 TLS 嗅探则 100% 可靠。

**处理**：确认规则最前面有模板③的两条 Chrome QUIC 拦截（`verify.sh` 第 3 项会查）；然后 **⌘Q 完全退出 Chrome 重开**（QUIC 会话有缓存，不重启不生效）；最后到 claude.ai 设置里撤销旧会话重新登录。

**不要**用全局 `AND,((NETWORK,UDP),(DST-PORT,443)),REJECT` 来防漏——它会禁掉全机所有应用的 HTTP/3，iCloud/Apple 服务全遭殃。进程级拦截才是对的粒度。

**用的不是 Chrome？** 模板③只拦了 Google Chrome 的 QUIC。Edge / Arc / Brave 等其他 Chromium 系浏览器症状完全相同，把模板③最前面两条规则照抄、进程名换成对应浏览器的即可（模板③注释里有进程名对照表）。`verify.sh` 第 3 项只检查 Chrome 那两条，其他浏览器的规则要自己确认。

## 3. 直连测试 iproyal 失败：`Can't complete SOCKS5 connection`

**症状**：`curl --socks5-hostname 'user:pass@host:port' https://api.ipify.org` 超时或报 SOCKS5 错误。

**原因**：**这是正常的**。iproyal 静态住宅 IP 通常只接受美国来源的连接，从国内（或经日本等非美节点）直连会被拒。这正是必须用 `dialer-proxy` 链式（先到机场美国节点再连 iproyal）的原因。

**处理**：不用处理。判断 iproyal 是否可用，看 `verify.sh` 第 4 项（走完整链路测出口）。链路通了直连失败无所谓。

## 4. Merge 文件里写 `append-proxies` 不生效

**原因**：订阅同时挂载了专用 proxies/groups/rules 增强文件时，Merge 文件里的 `append-proxies/prepend-rules` 会被忽略。

**处理**：代理/分组/规则分别写进对应的专用增强文件（模板①②③），Merge 只放 sniffer、dns 等顶层配置（模板④）。

## 5. DOMAIN 规则匹配不到 Claude 桌面版流量

**原因**：Claude 桌面版（Electron）自己解析 DNS，TUN 只看到 IP。

**处理**：靠 PROCESS-NAME 规则按进程名匹配（模板③第 3 组）+ sniffer 嗅探兜底（模板④）。这也是为什么两样都不能省。

## 6. 改了配置文件 GUI 没反应

**原因**：内核缓存了上次合并的配置；直接改 `clash-verge.yaml`（生成文件）会在下次激活时被覆盖。

**处理**：永远改 `profiles/` 下的增强文件，改完在 GUI「订阅」页点一下订阅卡片重新激活。

## 7. iproyal IP 直连不稳/被墙

**原因**：iproyal 服务器 IP 可能被 GFW 干扰，或国内到美国公网路由质量差。

**处理**：`dialer-proxy: "US-Chain"` 链式（模板①已内置）。永远不要把静态节点的 `dialer-proxy` 去掉。

## 8. 普通网站变慢/全部流量走了静态 IP

**症状**：`verify.sh` 第 2 项报"其他组误用静态节点"，或第 4 项普通流量出口 = 静态 IP。

**原因**：在 GUI 里手滑把「国外流量」之类的大组选成了 `🇺🇸 US-Static-iproyal`。静态住宅 IP 带宽小，扛不住全部流量，而且会污染"只有 Claude 用这个 IP"的画像。

**处理**：GUI「代理」页把误选的组改回机场节点；只有 `Claude` 组该指向静态节点。

## 9. Claude Code 的遥测流量走了默认机场节点

**症状**：Claude API 和 `claude.ai` 已走静态 IP，但日志里仍出现 `claude.exe` 访问 `http-intake.logs.us5.datadoghq.com`，并命中 `Final` 或默认代理组。

**原因**：macOS 上的 Claude Code 原生可执行文件名也是 `claude.exe`。只配置 `Claude` / `Claude Helper` 进程规则时，Anthropic 域名能被域名规则兜住，但 Datadog 等遥测域名会漏到默认组。

**处理**：确认规则中同时存在 `PROCESS-NAME,claude.exe,Claude` 和对应的 UDP 拒绝规则；重新激活订阅后再运行 `verify.sh`。

## 10. 配置漂移：仓库模板升级了，旧机器还在跑老规则（2026-07 真实案例）

**症状**：某台机器"以前一直没事"，突然发现 `claude.ai` 漏到默认节点（如日本）；查配置发现根本没有 QUIC 拦截、`claude.exe` 等新规则。

**原因**：模板在一台机器上排障升级后（如 2026-07 新增 QUIC 拦截），**其他机器不会自动同步**——增强文件是每台机器本地写入的，仓库更新≠机器更新。隔两个月自己都忘了哪台刷过哪台没刷。

**处理**：每次仓库模板更新后，在**每一台**用本方案的机器上重跑一遍部署（agent 对齐 `templates/` → GUI 激活 → `verify.sh`）。`verify.sh` 第 3 项（规则完整性）就能自检本机是否落后。

> 📌 **给拿到本仓库的新用户**：这条只在你有多台机器时相关。单机用户按 README 正常部署即可；多台机器的话，记住"仓库更新后每台都要重新对齐一次"。

---

## 快速自检命令备忘

```bash
# 六项全套
bash scripts/verify.sh
# 看某条流量实际命中了哪条规则（跑一次 Claude 后看日志尾部）
tail -50 "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/logs/service/service_latest.log" | grep -iE "claude|anthropic"
# 策略组当前指向
curl -sS --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/proxies | python3 -m json.tool | grep -A2 '"Claude"'
```
