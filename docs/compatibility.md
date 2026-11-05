# 版本兼容记录

本方案依赖几样会随上游升级而变的东西：**Clash Verge 的 socket / 日志位置、mihomo 支持的规则类型、浏览器和 Claude 的进程名**。它们一变，写死的规则和检查会**静默失效**：规则不报错、verify.sh 也可能照样打勾，流量却已经漏出去了。

这份文件记录每个实测过的版本差异。**每条都标了实测日期和证据来源；没实测过的明确写「未实测」。**

> **给 agent**：部署或排障的第一步跑 `bash scripts/probe.sh`，它会读出本机各组件的版本和路径，并对照下面的已知情况给出提示。碰到这里没记录过的版本，按最后一节处理，处理完**把新情况补进这份文件**。

---

## Clash Verge Rev（macOS）

| 版本 | mihomo 控制 socket | 内核日志 | 证据 |
|---|---|---|---|
| 2.x 早期（2026-07） | `/tmp/verge/verge-mihomo.sock` | `$CFG/logs/service/service_latest.log` | 2026-07 首版部署实测 |
| 2.5.1（2026-08 ~ 10） | `/tmp/verge/verge-mihomo.sock` | `$CFG/service-logs/service/service_latest.log` | 2026-09-24 `verify.sh` 全绿并记基线；日志路径来自 2026-10-05 的修复提交 |
| **2.5.8**（2026-10 起） | **`/var/run/clash-verge-service/users/<uid>/verge-mihomo.sock`**（服务模式，由内核启动参数 `-ext-ctl-unix` 指定） | **读不到**：写在 `/Library/Application Support/clash-verge-service/users/<uid>/`，只有 root 能读；`$CFG/service-logs/service/` 是空的 | 2026-11-02 实测 |
| **2.5.9 / 2.5.10**（2026-11 起，捆绑 mihomo v1.19.33） | 同 2.5.8 | 同 2.5.8（读不到） | 2026-11-05 从 2.5.8 升到 2.5.10 实测：`verify.sh` 六项全绿，增强文件和规则原样生效 |

`$CFG` = `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev`

**2.5.8 有两个坑：**

- 生成配置 `clash-verge.yaml` 里的 `external-controller-unix` 写的是 `/var/folders/.../T/verge-mihomo.sock`，**这个文件根本不存在**。照配置文件找 socket 一定找错，必须以运行中内核的启动参数为准：`ps -axww -o args | grep verge-mihomo`，取 `-ext-ctl-unix` 后面的路径。`probe.sh` 已经按这个优先级自动探测。
- 日志读不到以后，`verify.sh` 原来靠日志的两项（TUN 启动错误、漏流扫描）没法再用。v1.2.2 起改成：第 1 项检查「发往 Anthropic 的路由是否经过 Clash 的 TUN 网卡」，第 5 项扫描 API 的实时连接。

**没变的地方**（2.5.8 实测）：增强文件机制照旧（`profiles.yaml` 里订阅条目的 `option` 指向 uid 文件），GUI 点订阅卡片重新激活照旧，unix socket 不需要 secret。

**2.5.9 / 2.5.10 实测没有新坑**（2026-11-05）。2.5.9 在虚拟网卡设置里新增了「DNS 模式」选项，对应内核的 `tun.dns-mode`；不去动它时生成配置里没有这个字段，`/configs` 里是空值，`dns.enhanced-mode: fake-ip` 照旧。**别为了这个选项改 DNS 设置**：fake-ip 是 UDP 连接也能认出域名的前提，改坏了域名规则会对 QUIC 失效。

## mihomo 内核

| 能力 / 行为 | 版本 | 证据 |
|---|---|---|
| `PROCESS-NAME-REGEX` / `PROCESS-PATH-REGEX` 规则（模板③从 v1.2.2 起用到） | **≥ v1.18.5** 才支持 | mihomo 发布记录；v1.19.32 实测可用（2026-11-03：`/rules` 里加载为 `ProcessNameRegex` / `ProcessPathRegex`，重载后新建的 Claude Code 连接全部命中路径规则） |
| 规则命中了，但目标节点不支持 UDP → **跳过这条继续往下匹配**；所有命中的规则都不支持 UDP → **不经任何规则直接 DIRECT**（`/connections` 里 `rule` 字段为空） | v1.19.32 实测 | 2026-11-02：Chrome 的 QUIC 因此从国内 IP 直连 claude.ai |
| `AND` 里组合「域名 / IP 段 + `NETWORK,UDP`」（模板③第 0 节，按目的地拒绝 UDP）；`IP-CIDR` 子规则可带 `no-resolve` | v1.19.33 实测可用 | 2026-11-05：`verge-mihomo -t` 语法检查通过，`/rules` 里显示为 `((DomainSuffix,claude.ai) && (Network,udp))`、`((IPCIDR,160.79.104.0/23) && (Network,udp))`。UDP 连接靠 fake-ip 认出域名。GUI 激活后实测：非 Chrome 程序发往 `claude.ai:443` 和 `160.79.104.10:443` 的 UDP 分别命中这两条并被 REJECT |
| `/rules` 每条规则带 `extra.hitCount` / `missCount` | v1.19.33 有 | 2026-11-05 实测：不读日志也能确认某条规则真的命中过 |
| `tun.dns-mode`（Verge 2.5.9 起的「DNS 模式」）；同版还修了「重载配置时 fake-ip 分配状态丢失」和 crypto/tls 的 CVE-2026-97031 | v1.19.33 新增 | mihomo v1.19.33 发布记录；2026-11-05 实测：不设置时为空值，fake-ip 照旧，规则和进程/路径匹配行为不变 |
| 进程名取的是**解析过符号链接的真实可执行文件**（`proc_pidpath`），不是 `ps` 显示的名字 | v1.19.32 实测 | 2026-11-02：Claude Code 在 `ps` 里叫 `claude`，在 mihomo 里叫 `2.1.316` |

第二条行为决定了 QUIC 漏到哪：节点支持 UDP，就漏到机场默认节点（会话显示日本等地）；节点不支持 UDP（模板①的静态节点就是 `udp: false`，很多机场节点也是），就直连国内 IP，claude.ai 直接跳「App unavailable in region」。

## Google Chrome（macOS）

| 版本 | 负责联网的进程名 | 证据 |
|---|---|---|
| 2026-07 时的版本 | `Google Chrome Helper` | 2026-07 部署实测（当时 `/connections` 里就是这个名字） |
| **156.0.8078.49** | **`Google Chrome Helper (Aperitif)`**（另有 `(Aperitif Renderer)` / `(Aperitif GPU)` / `(Aperitif Alerts)`） | 2026-11-02 实测 |
| 156.0.8078.80 | 同上，仍是 `(Aperitif)` 系列 | 2026-11-05 重启 Chrome 后实测 |

**不能按版本号预测。** Chrome 156 的安装包里两套 Helper 都有：日常使用的 Chrome 实例走 `(Aperitif)` 系列；同一台机器上被自动化工具单独拉起的另一个实例（156.0.8078.74）走的是普通 `Google Chrome Helper`。这更像灰度实验，而不是版本切换。所以模板③从 v1.2.2 起改用 `PROCESS-NAME-REGEX,^Google Chrome`，覆盖所有以它开头的进程（含 Beta / Canary）。`verify.sh` 第 3 项会拿**此刻在跑的** Chrome 进程逐个去对规则。

**其他浏览器**：v1.2.3 起模板③第 0 节**按目的地**拒绝发往 Claude 的 UDP，跟浏览器叫什么无关，Safari（网络请求走系统进程 `com.apple.WebKit.Networking`，没法按进程拦）、Edge、Brave、Arc 都兜得住。想给它们再加一道按进程的保险，正则分别是 Edge `^Microsoft Edge`、Brave `^Brave Browser`、Arc `^Arc( Helper.*)?$`（均未实测）。

## Claude Code

| 安装方式 / 版本 | mihomo 看到的进程名 | 规则写法 | 证据 |
|---|---|---|---|
| 2026-07 时的安装 | `claude`（磁盘文件名是 `claude.exe`） | `PROCESS-NAME,claude` | 2026-07-25 实测，见排障手册第 9 条 |
| **原生安装版 2.1.316** | **版本号本身，如 `2.1.316`**（`~/.local/bin/claude` 是符号链接，指向 `~/.local/share/claude/versions/2.1.316`） | `PROCESS-PATH-REGEX,/.local/share/claude/versions/` | 2026-11-02 实测 |
| npm 全局安装 | 大概率是 `node` | 没法按进程分流（会把所有 node 程序都拽进来），只能靠域名规则 | **未实测，推测** |

版本号进程名**每次升级都会变**，所以只能按路径匹配。只靠名字规则时，访问 anthropic 域名的请求还有域名规则兜着，但其他请求会漏到机场默认节点。

## Claude 桌面版

| 版本 | 进程名 | 证据 |
|---|---|---|
| 2026-07 ~ 4.4212.0 | `Claude`、`Claude Helper`、`Claude Helper (GPU)`、`Claude Helper (Renderer)`、`Claude Helper (Plugin)` | 2026-11-02 实测没变 |

---

## 遇到没记录过的版本怎么办（给 agent）

1. **先跑 `bash scripts/probe.sh`。** 找不到 socket 时：
   - `ps -axww -o args | grep verge-mihomo`，看启动参数里的 `-ext-ctl-unix`；
   - 或者 `lsof -U 2>/dev/null | grep -i mihomo`。
   - 找到了就用 `CLAUDE_LANE_SOCK=<路径> bash scripts/verify.sh` 先跑通，再把路径规律加进 `probe.sh` 的候选列表。
2. **跑 `bash scripts/verify.sh`。** 任何一项是因为「读不到 / 连不上」而跳过的，都不能当作通过。
3. **怀疑有漏流时，看实时连接，别猜：**
   ```bash
   SOCK=$(bash scripts/probe.sh --sock)
   curl -s --unix-socket "$SOCK" http://localhost/connections | python3 scripts/lanecheck.py conns -
   ```
   要找的是两种连接：`rule` 为空且走 `DIRECT` 的（规则全被跳过了）；或者 claude 相关域名没走 `Claude` 组的。每条连接的 `process` / `processPath` 字段就是规则要匹配的值。**写规则时优先用正则或路径，别写精确名。**
4. **记录下来。** 改完要做到：
   - 这份文件加一行（版本、日期、变了什么、证据）；
   - 需要的话同步改 `templates/3-rules.yaml`、`scripts/lanecheck.py` 里的已知进程名列表、`scripts/probe.sh` 里的已验证 Verge 版本；
   - 把真实样本加进 `scripts/selftest.sh`，再跑一遍确认全过；
   - 症状是新的，就在排障手册里加一条。
