# 排障手册（14 个真实踩过的坑）

按症状查。每条格式：症状 → 原因 → 处理。前 3 条及第 9、10 条是 2026-07 真机实战新增，第 11、12 条来自 2026-08 在一台干净 Mac 上的远程部署，第 2 条的补充和第 13、14 条来自 2026-11-02（上游版本升级导致规则和检查静默失效），其余继承自本仓库第一版。

> 下面的命令里凡是用到 `$SOCK` 的，先跑 `SOCK=$(bash scripts/probe.sh --sock)`——socket 位置随 Clash Verge 版本变，见 `docs/compatibility.md`。

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
SOCK=$(bash scripts/probe.sh --sock)
curl -X PATCH --unix-socket "$SOCK" http://localhost/configs -d '{"tun":{"enable":false}}'
sleep 2
curl -X PATCH --unix-socket "$SOCK" http://localhost/configs -d '{"tun":{"enable":true}}'
```

**根治**：卸载 Mac 上多余的代理 App。一台 Mac 只留一个接管路由的代理软件。

## 2. Chrome 网页版 claude.ai 显示日本会话，或直接跳「App unavailable in region」（QUIC 漏流）

**症状**：桌面版和 Claude Code 的归属地都正确，只有 Chrome 出问题。有两种表现：
- 会话显示日本东京等机场默认节点的位置；
- **直接跳到 `claude.com/app-unavailable-in-region`**（2026-11-02 实测）。

**原因**：Chrome 用 QUIC（HTTP/3，跑在 UDP/443 上）连 claude.ai。QUIC 没被拦下时，它会绕过本该生效的规则。漏到哪取决于节点支不支持 UDP：
- 节点支持 UDP → 落到 MATCH 兜底，走机场默认节点 → 显示日本；
- 节点**不支持** UDP（模板①的静态节点是 `udp: false`，很多机场节点也是）→ mihomo 会跳过所有指向这些节点的规则，最后**不经任何规则直接 DIRECT** → 国内 IP → 地区不可用。这时 `/connections` 里那条连接的 `rule` 字段是**空的**。

模板③本来就拦了 Chrome 的 QUIC，**为什么还会漏**：v1.2.1 及以前的拦截规则写的是精确进程名 `Google Chrome Helper`。Chrome 156 把联网进程换成了 `Google Chrome Helper (Aperitif)`，精确名对不上，规则静默失效。旧版 `verify.sh` 第 3 项只查规则文本里有没有「Google Chrome」几个字，所以照样打勾。

**确认是不是这个问题**（开着 claude.ai 页面跑）：

```bash
SOCK=$(bash scripts/probe.sh --sock)
curl -s --unix-socket "$SOCK" http://localhost/connections | python3 scripts/lanecheck.py conns -
# 出现「Chrome 的 QUIC 没被拦截：udp claude.ai:443 ← Google Chrome Helper (Aperitif)，规则=（空…），走了 DIRECT」就是它
```

**处理**：
1. 规则最前面换成模板③的正则那条：`AND,((PROCESS-NAME-REGEX,^Google Chrome),(NETWORK,UDP),(DST-PORT,443)),REJECT`。需要 mihomo ≥ v1.18.5（`bash scripts/probe.sh` 会查）。
2. GUI 点一下订阅卡片重新激活。激活时内核会断掉已有连接，一般不重启 Chrome 也能生效；稳妥起见还是 ⌘Q 重开一次。
3. 跑 `verify.sh`，第 3、5 项要全绿。
4. 到 claude.ai 设置里**撤销**漏流期间产生的、归属地不对的会话，然后重新登录。

**不要**用全局 `AND,((NETWORK,UDP),(DST-PORT,443)),REJECT` 来防漏。它会禁掉全机所有应用的 HTTP/3，iCloud/Apple 服务全遭殃。进程级拦截才是对的粒度。

**用的不是 Chrome？** Edge / Arc / Brave 等 Chromium 系浏览器症状完全相同。把模板③最前面那条照抄，正则换成对应浏览器的（模板③注释里有对照表）。这些浏览器在跑却没有拦截规则时，`verify.sh` 第 3 项会黄色提醒。

## 3. 直连测试 静态 IP 失败：`Can't complete SOCKS5 connection`

**症状**：`curl --socks5-hostname 'user:pass@host:port' https://api.ipify.org` 超时或报 SOCKS5 错误。

**原因**：**这是正常的**。美国静态住宅 IP 通常只接受美国来源的连接，从国内（或经日本等非美节点）直连会被拒。这正是必须用 `dialer-proxy` 链式（先到机场美国节点再连 静态IP）的原因。

**处理**：不用处理。判断 静态 IP 是否可用，看 `verify.sh` 第 4 项（走完整链路测出口）。链路通了直连失败无所谓。

## 4. Merge 文件里写 `append-proxies` 不生效

**原因**：订阅同时挂载了专用 proxies/groups/rules 增强文件时，Merge 文件里的 `append-proxies/prepend-rules` 会被忽略。

**处理**：代理/分组/规则分别写进对应的专用增强文件（模板①②③），Merge 只放 sniffer、dns 等顶层配置（模板④）。

## 5. DOMAIN 规则匹配不到 Claude 桌面版流量

**原因**：Claude 桌面版（Electron）自己解析 DNS，TUN 只看到 IP。

**处理**：靠 PROCESS-NAME 规则按进程名匹配（模板③第 3 组）+ sniffer 嗅探兜底（模板④）。这也是为什么两样都不能省。

## 6. 改了配置文件 GUI 没反应

**原因**：内核缓存了上次合并的配置；直接改 `clash-verge.yaml`（生成文件）会在下次激活时被覆盖。

**处理**：永远改 `profiles/` 下的增强文件，改完在 GUI「订阅」页点一下订阅卡片重新激活。

## 7. 静态 IP 直连不稳/被墙

**原因**：静态 IP 的服务器 可能被 GFW 干扰，或国内到美国公网路由质量差。

**处理**：`dialer-proxy: "US-Chain"` 链式（模板①已内置）。永远不要把静态节点的 `dialer-proxy` 去掉。

## 8. 普通网站变慢/全部流量走了静态 IP

**症状**：`verify.sh` 第 2 项报"其他组误用静态节点"，或第 4 项普通流量出口 = 静态 IP。

**原因**：在 GUI 里手滑把「国外流量」之类的大组选成了 `🇺🇸 US-Static`。静态住宅 IP 带宽小，扛不住全部流量，而且会污染"只有 Claude 用这个 IP"的画像。

**处理**：GUI「代理」页把误选的组改回机场节点；只有 `Claude` 组该指向静态节点。

## 9. Claude Code 的遥测流量走了默认机场节点

**症状**：Claude API 和 `claude.ai` 已走静态 IP，但日志里出现 `http-intake.logs.us5.datadoghq.com` 命中 `Match using Final[...]`（走了默认节点）。

**原因（2026-07-25 实机排查，本条已重写）**：有**两层**原因，只解决第一层不够。

**第一层：进程名写错了。** Claude Code 在磁盘上的可执行文件确实叫 `claude.exe`（macOS 上也是，见 `CLAUDE_CODE_EXECPATH`），**但 mihomo 匹配的是内核看到的进程名**（`ps -axo comm`），实测是**小写 `claude`**。所以只写 `PROCESS-NAME,claude.exe` 的规则永远不命中。

**第二层（关键）：这条连接的进程根本识别不出来。** 补上小写 `claude` 规则、确认 `/rules` 里有了之后，遥测**仍然**在漏。查 mihomo 的 `/connections` 才看明白：这条连接的 `process` 字段是**空的**（同一时刻别的连接都有值，比如 `Google Chrome Helper`）——mihomo 没能把它归属到任何进程，于是所有 `PROCESS-NAME` 规则都无从匹配，请求落到 MATCH 兜底、从机场默认节点出去了。作者自己的机器就这么静默漏了一段时间，而当时 `verify.sh` 还是全绿（它只检查规则存不存在，不检查有没有真的命中）。

**所以正解是加域名规则**（模板③第 4b 组已内置）：

```yaml
- "DOMAIN-SUFFIX,http-intake.logs.us5.datadoghq.com,Claude"
```

⚠️ **不要**图省事写成 `DOMAIN-SUFFIX,datadoghq.com,Claude`——那会把其他网站的 Datadog 前端埋点也导进你的静态 IP，反而污染"这个 IP 只访问 Anthropic"的画像。

**自查与验证**：

```bash
# 本机在跑的 Claude 进程有没有都被规则覆盖（取进程名的方式与 mihomo 一致，别用 ps 看——见第 14 条）
SOCK=$(bash scripts/probe.sh --sock)
curl -s --unix-socket "$SOCK" http://localhost/rules | python3 scripts/lanecheck.py rules -
# 遥测此刻走了哪个组：应为 Claude，不是 Final
curl -s --unix-socket "$SOCK" http://localhost/connections | python3 scripts/lanecheck.py conns -
```

`verify.sh` 已相应加强：第 3 项改为核对**当前真实在跑**的 Claude 进程是否都有规则（不再只看规则存不存在），第 5 项漏流扫描纳入 `datadoghq` / `statsig` 域名。

## 10. 配置漂移：仓库模板升级了，旧机器还在跑老规则（2026-07 真实案例）

**症状**：某台机器"以前一直没事"，突然发现 `claude.ai` 漏到默认节点（如日本）；查配置发现根本没有 QUIC 拦截、`claude.exe` 等新规则。

**原因**：模板在一台机器上排障升级后（如 2026-07 新增 QUIC 拦截），**其他机器不会自动同步**——增强文件是每台机器本地写入的，仓库更新≠机器更新。隔两个月自己都忘了哪台刷过哪台没刷。

**处理**：每次仓库模板更新后，在**每一台**用本方案的机器上重跑一遍部署（agent 对齐 `templates/` → GUI 激活 → `verify.sh`）。`verify.sh` 第 3 项（规则完整性）就能自检本机是否落后。

> 📌 **给拿到本仓库的新用户**：这条只在你有多台机器时相关。单机用户按 README 正常部署即可；多台机器的话，记住"仓库更新后每台都要重新对齐一次"。

## 11. 干净 Mac 一跑命令就弹「Install Command Line Developer Tools」（2026-08 真实案例）

**症状**：从没装过 Xcode 的 Mac 上，agent 一执行 `git clone` 或脚本一调用 `python3`，系统就弹出 1.5 GB 起步的命令行工具安装框；换 Claude Code / Codex / Grok 三个 agent 都卡在同一个框上。

**原因**：macOS 自带的 `/usr/bin/git` 和 `/usr/bin/python3` 都是 Xcode 命令行工具（CLT）的壳命令，本身不可用。README 的前提「Claude Code 已能对话」在干净机器上不成立——卡住的不是 agent，是环境。

**处理**（先铺平依赖，再让 agent 上）：

- **git 完全不需要**：用 curl 下载 zip 代替 clone（`curl` / `unzip` 是 macOS 自带、不依赖 CLT）：
  ```bash
  cd ~ && curl -fL https://codeload.github.com/xyecc/claude-lane/zip/refs/heads/main \
    -o claude-lane.zip && unzip -oq claude-lane.zip && rm -rf claude-lane \
    && mv claude-lane-main claude-lane && cd claude-lane && ls
  ```
- **python3 是真依赖**（`verify.sh` 和 `set-credentials.sh` 都要），但不必装 CLT——python.org 官方包只要 65 MB：
  ```bash
  curl --http1.1 -fL --progress-bar \
    https://www.python.org/ftp/python/3.13.15/python-3.13.15-macos11.pkg \
    -o ~/Downloads/python3.pkg
  sudo installer -pkg ~/Downloads/python3.pkg -target /
  /usr/local/bin/python3 --version    # 验证
  rm ~/Downloads/python3.pkg
  ```
  （版本号以 python.org 当前稳定版为准）
- agent 启动时习惯性探测 git 触发的弹框，**点「停止」即可**，不影响后续；可能会弹多次。

## 12. 代理环境下载大文件报 `curl: (92) HTTP/2 stream … not closed cleanly`

**症状**：经 Clash 下载几十 MB 以上的文件（安装脚本、二进制包）反复中断，报 `curl: (92) HTTP/2 stream 1 was not closed cleanly before end of the underlying stream`；有的安装脚本还会无限重试、又因为 `-s` 静默连进度都看不到。

**原因**：代理链路上的 HTTP/2 长流不稳定，多路并发 range 请求更容易崩。

**处理**：代理下任何大文件都带这三个参数：

```bash
curl --http1.1 -C - --progress-bar -fL <url> -o <file>
```

- `--http1.1` 避开 HTTP/2 崩流
- `-C -` 断点续传（断了重跑同一条命令接着下）
- `--progress-bar` 看得见进度

> 文件已完整时再跑带 `-C -` 的命令会报 `curl: (22) … error: 416`——那是「没得续了」，**无害**，说明文件是好的。

## 13. Clash Verge 升到 2.5.8 后，`verify.sh` 崩出 Python traceback、「mihomo API 不可达」（2026-11-02 真实案例）

**症状**：Clash 明明在正常工作，`verify.sh` 却报 `mihomo API 不可达`，第 2、3 项崩出 `json.decoder.JSONDecodeError`；顶部还有黄字「读不到内核日志」。

**原因**：Verge 2.5.8 的服务模式把两样东西挪了位置：
- 控制 socket 从 `/tmp/verge/verge-mihomo.sock` 挪到了 `/var/run/clash-verge-service/users/<uid>/verge-mihomo.sock`。而且生成配置里写的 `external-controller-unix` 指向一个不存在的文件，照配置找也找不到。
- 内核日志写进了只有 root 能读的 `/Library/Application Support/clash-verge-service/`。

v1.2.1 的 `verify.sh` 写死了老路径，于是前三项崩溃。第 5 项「无漏流」因为读不到日志、什么都没检查，**却照样打勾**。作者自己的机器就是这么带着 Chrome QUIC 漏流（第 2 条）跑了好几天没被发现。

**处理**：更新到 v1.2.2 及以上。路径改由 `scripts/probe.sh` 自动探测（优先读运行中内核的 `-ext-ctl-unix` 启动参数）；读不到日志时，第 1 项改为检查路由是否经过 Clash 的 TUN 网卡，第 5 项改为扫描实时连接。以后再遇到没记录过的 Verge 版本，按 `docs/compatibility.md` 最后一节处理。

## 14. Claude Code 的进程规则不命中：mihomo 看到的进程名是版本号（2026-11-02 真实案例）

**症状**：`verify.sh` 第 3 项报「这些在跑的 Claude 进程没有进程规则: ['2.1.316']」；或者 `/connections` 里 Claude Code 的连接 `process` 字段是一串版本号，命中的是域名规则而不是进程规则。

**原因**：Claude Code 原生安装版的可执行文件在 `~/.local/share/claude/versions/<版本号>`，`~/.local/bin/claude` 只是指向它的符号链接。mihomo 取进程名用的是**解析过符号链接的真实文件名**，也就是 `2.1.316` 这样的版本号，而且每次升级都会变。`ps` 显示的是启动时的名字 `claude`，所以拿 `ps` 去核对会误以为规则是对的（旧版 `verify.sh` 就是这么判断的）。

后果：访问 Anthropic 域名的请求还有域名规则兜着；其他请求（以及 UDP）不经过 Claude 组，会漏到机场默认节点。

**处理**：用模板③里按路径匹配的两条，需要 mihomo ≥ v1.18.5：

```yaml
- "AND,((PROCESS-PATH-REGEX,/.local/share/claude/versions/),(NETWORK,UDP)),REJECT"   # 放在 UDP 拦截组
- "PROCESS-PATH-REGEX,/.local/share/claude/versions/,Claude"                          # 放在进程导流组
```

激活后跑 `verify.sh`，第 3 项应该列出 `2.1.316` 这类版本号进程且全绿。

---

## 快速自检命令备忘

```bash
# 环境探测（版本、socket、兼容性提示）
bash scripts/probe.sh
# 六项全套
bash scripts/verify.sh
SOCK=$(bash scripts/probe.sh --sock)
# 此刻的连接有没有漏（开着 claude.ai / Claude 桌面版跑）；每条连接实际命中的规则在 rule 字段
curl -s --unix-socket "$SOCK" http://localhost/connections | python3 scripts/lanecheck.py conns -
# 策略组当前指向
curl -sS --unix-socket "$SOCK" http://localhost/proxies | python3 -m json.tool | grep -A2 '"Claude"'
```
