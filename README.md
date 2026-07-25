# Claude 专线：让 Claude 流量走美国静态住宅 IP（agent 一键复刻版）

**v1.1.0** · 仅支持 macOS · 更新日志见 [CHANGELOG.md](CHANGELOG.md)

让 macOS 上的 Claude（网页版 / 桌面版 / Claude Code 全覆盖）永久走一个**固定的美国静态住宅 IP**，其余流量保持你机场订阅的原有规则不变。

> **实际使用情况**：作者按本方案**已稳定使用约一年**，跨越两台 Mac、一台 Windows 电脑，手机（iPhone）上同样在用，**期间账号零异常封禁**。
> 仓库是 2026-04 才开始正式整理成文的，所以 git 历史比实际使用时间短。排障手册里的 10 个坑，全部来自这一年里踩过的真实故障。

配置过程不用你手动改文件——由你自己的 Claude Code agent 照本仓库执行，你只需要提供凭证 + 在图形界面点一次激活。

```
Claude 流量 ──→ Clash TUN ──→ Claude 分组 ──→ 静态IP节点 (socks5)
                                                │ dialer-proxy 链式
                                                └→ US-Chain 分组（机场美国节点）──→ 静态 IP ──→ Anthropic
其他流量  ──→ 机场订阅原有规则（不受影响）
```

Claude 服务器看到的出口 IP = 你的静态住宅 IP，永久固定。

## 平台支持

**方案本身**（Clash 分流 + 链式静态住宅 IP）作者在 macOS、Windows、iPhone 上都实际跑通并长期稳定使用过。**本仓库的自动化部分**（agent 手册、`verify.sh`）是 macOS 专用——这是两件不同的事，看下表：

| 平台 | 方案可用性 | 本仓库的自动化 |
|---|---|---|
| **macOS**（Apple Silicon / Intel） | ✅ 长期稳定使用 | ✅ **完整支持**：agent 全自动 + `verify.sh` 六项体检 |
| **Windows** | ✅ 作者实测跑通并稳定用过 | ❌ 需手动配置。Clash Verge Rev 有 Windows 版、思路完全一样，但配置目录、进程名不同，`verify.sh`（用了 `scutil` / `stat -f`）跑不了 |
| **iPhone / iOS** | ✅ 作者在用（Shadowrocket 小火箭） | ❌ 手机上没有 agent，需手动配；步骤暂未整理成文，见 `docs/iphone-notes.md` |
| Linux | ⚠️ 未试过 | ❌ 不支持（且 Claude 桌面版没有 Linux 版） |

**Windows 用户怎么办**：照 `docs/manual-setup.md` 的思路走，把三处换成 Windows 的对应物——配置目录在 `%APPDATA%` 下的同名文件夹（自己确认一下）、进程名规则里的 `Claude` / `claude.exe` 保持不动（Windows 上本来就是这个名）、`Google Chrome` 改成 `chrome.exe`；验证不能用 `verify.sh`，改成手动跑 `docs/porting.md` 里那两条命令（查 `claude.ai/cdn-cgi/trace` 的出口是不是静态 IP）。规则和模板本身照抄即可。

不用 Clash Verge 的（Surge / sing-box 等），看 `docs/porting.md`——那里把方案抽象成了平台无关的规格。

## 适合谁 / 不适合谁

**适合你，如果**：已经有能用的机场订阅；愿意在终端里敲几条命令、看得懂 agent 说的话；想解决的是"Claude 老提示异常/要验证/会话归属地乱跳"。

**不适合你，如果**：完全没接触过代理软件和终端（本方案的前提是 Claude Code 已经能对话，这本身就要求你的网络已经能用）；想找"装个 App 点一下就好"的方案（那不存在，链式代理必须改配置）；不愿意每月多花几美元买静态 IP。

**卡住了怎么办**：先跑 `bash scripts/verify.sh`，对照 `docs/troubleshooting.md`（10 个真实踩过的坑）；还不行就把 `verify.sh` 的输出贴出来提 issue——**贴之前记得把静态 IP、节点名、订阅名涂掉**。

## 原理（3 分钟版，知其所以然再动手）

**为什么要固定 IP？** 机场节点是共享出口，IP 经常换、还和无数陌生用户共用。在 Claude 看来你就是"今天日本明天美国、和一堆人共用 IP"的可疑账号。一个只有你在用、永不变化的美国住宅 IP，画像干净得多。

**为什么要"链式"？** 美国静态住宅 IP 通常只接受美国来源的连接，从国内直连会被拒/超时。所以先借机场的美国节点出境（第一跳），再从美国连静态 IP（第二跳）。这就是模板里 `dialer-proxy: "US-Chain"` 干的事。

**为什么只有 Claude 走这条线？** 住宅 IP 带宽小、流量贵，扛不住日常刷网页；而且"这个 IP 只访问 Anthropic"本身就是最干净的画像。所以用 Clash 的分流规则精确圈出 Claude 的流量（按进程名 + 域名 + IP 段三层兜底），其余流量照旧走机场。

**QUIC 拦截是干嘛的？** Chrome 会用 UDP 的 QUIC 协议直连，绕过域名识别导致漏流（实测会漏到日本节点）。把 Chrome 的 QUIC 拒掉，它会无感回落到 TCP，就能被规则抓住了。

## 你需要准备的三样东西

1. **机场订阅**（套餐里**必须有美国节点**）。已经在用 Clash Verge Rev 最好；用别的代理软件、或者干脆什么都没装也行——agent 会帮你装 Verge 并迁移，你只需提供订阅链接（原来的代理软件要退出卸载）
2. **美国静态住宅 IP** 一份（要求见下）
3. **Claude Code** 已安装、能正常对话

### 静态住宅 IP 的具体要求（买错了整套白搭）

| 项 | 要求 | 说明 |
|---|---|---|
| 地区 | **美国** | 别选新加坡/日本，本方案的价值就在美国出口 |
| 类型 | **静态住宅（Static Residential / ISP）** | ⚠️ **不能是动态或轮换（Rotating）IP**——每次请求换 IP 的话画像比机场还乱，等于白买 |
| 协议 | **SOCKS5** | 有的服务商默认给 HTTP 凭证，要在订单里切到 SOCKS5 |
| 带宽/档位 | **最低档就够** | Claude 的流量非常小（纯文本对话 + API），最低带宽/最小流量包都用不完 |
| UDP | **不需要** | 模板里刻意设了 `udp: false`（这是防 QUIC 漏流的一环），服务商支不支持 UDP 都无所谓 |
| 数量 | **1 个** | 多台设备可以共用同一个（见 FAQ） |

拿到手应该是这样一组四元组（示例是假的）：

```
主机(host)      : 198.51.100.10        ← 也可能是域名形式
端口(port)      : 12324
用户名(username): user_abc123
密码(password)  : pAsSw0rd_xyz
```

具体买哪家**本仓库不做推荐**（理由见下方「购买渠道」一节），按上表的要求自己挑一家即可。

## 快速开始

```bash
git clone https://github.com/maien210/claude-lane
cd claude-lane
claude
```

然后对 Claude 说一句：

> **按这个仓库的流程给本机配置 Claude 专线，先做环境体检。**

### agent 会带你走的流程

```
你说一句话
   │
   ├─ Phase -1  探测本机代理软件
   │            ├─ 没装 Verge → 帮你 brew 装好 → 【你贴一次订阅链接】→ 开 TUN
   │            └─ 用的别的软件 → 引导迁移（原软件要退出卸载）
   │
   ├─ Phase 0   环境体检（只读）：内核/TUN/规则模式/美国节点/其他VPN/依赖工具
   │            └─ 有问题就停下告诉你，不硬闯
   │
   ├─ Phase 1   【你自己跑 `! bash scripts/set-credentials.sh` 填四元组】
   │            密码隐藏输入、不经过 AI 对话；agent 只看到打码信息
   │            （美国节点默认全用，不问你）
   │
   ├─ Phase 2-3 定位4个增强文件 → 备份 → 按模板写入配置   （全自动）
   │
   ├─ Phase 4   【你在 Clash Verge「订阅」页点一下订阅卡片】← 唯一必须的 GUI 操作
   │            agent 随即查日志确认 TUN 没报错
   │
   ├─ Phase 5   跑 verify.sh 六项验证，不全绿不算完      （全自动，红了它去修）
   │
   └─ Phase 6   agent 代你重启 Chrome / Claude 桌面版
                └─【你去 claude.ai 撤销旧会话重登】← 最后一件手工活
```

**你全程要动手的只有四件事**：事先买好静态 IP；（新装 Verge 时）贴一次订阅链接；跑一次凭证脚本；在 GUI 点一次激活 + 最后去 claude.ai 撤销旧会话。

> 🔒 **凭证不进对话**：静态 IP 的账号密码由你自己跑 `scripts/set-credentials.sh` 写入本机（密码隐藏输入），AI 全程只看到打码后的确认信息。贴进聊天框等于发到模型服务端、并留在本机会话记录里。

不想用 agent、或想亲手做一遍搞懂每一步的：照 **`docs/manual-setup.md`**（人肉版手册，和 agent 流程完全等价，约 20–30 分钟）。

## 日常使用（部署完成后）

平时什么都不用管。**唯一要记住的一个动作**：感觉不对劲（会话归属地变了、Claude 突然要验证、连不上）就跑一遍体检：

```bash
bash scripts/verify.sh
```

它会拿当前出口和**部署时实测记录的基线**比对（存在 `claude-lane-state.json`），所以能发现「出口悄悄换了」。换过静态 IP 之后确认无误，用 `bash scripts/verify.sh --save-baseline` 更新基线。

配好的机器应该长这样（IP 是示例）：

```
== Claude 专线验证 ==
   静态节点服务器: 198.51.100.10 | 本地代理端口: 7897
[1/6] 内核与 TUN
  ✅ mihomo API 可达
  ✅ TUN 无启动错误
[2/6] 策略组状态
  ✅ Claude 组 → 🇺🇸 US-Static
  ✅ US-Chain 组 → 🇺🇸 美国节点 03
  ✅ 无其他组误用静态节点
[3/6] 规则完整性
  ✅ Chrome QUIC 拦截在规则最前
  ✅ 无全局 UDP/443 拦截
  ✅ claude.com 域名规则存在
  ✅ 在跑的 Claude 进程都有对应规则（Claude, Claude Helper, claude）
  ✅ 遥测域名规则存在
[4/6] 出口双验（关键）
  ✅ claude.ai 出口 = 198.51.100.10 (US) <- 与基线一致
  ✅ 普通流量出口 = 203.0.113.55 <- 机场节点, 未误走静态
[5/6] 日志漏流扫描
  ✅ 本次激活后无 Claude/Anthropic 流量走到非 Claude 组
[6/6] 其他 VPN 检测
  ✅ 无其他 VPN 在运行

== 六项全部通过，部署成功 ==
```

六项全绿 = 专线没问题，别处找原因；有红项 = 按提示对照 `docs/troubleshooting.md` 处理。

## 常见问题（FAQ）

**一共要花多少钱？** 机场订阅（你本来就有）+ 美国静态住宅 IP 约 $4–6/月（最低带宽档就够，流量只有 Claude 在用）。

**静态住宅 IP 有什么要求？** 见上面「静态住宅 IP 的具体要求」那张表——**最容易买错的是买成了轮换（Rotating）IP**，那个不能用。本仓库不推荐具体服务商。

**配完多久生效？** 立即。但浏览器和桌面版有连接缓存，**必须 ⌘Q 重启**才切到新链路；claude.ai 的旧会话记录的还是老 IP，要手动撤销重登。

**会影响我其他网站的速度吗？** 不会。只有 Claude 流量走静态 IP，其余流量按规则走机场原有链路，不经过静态 IP。

**订阅付款也要走静态 IP 吗？** 默认**不走**（v1.1.0 起支付规则移到了 `templates/optional-payment-rules.yaml`，默认不启用）。两个原因：一是加了之后你在**任何网站**用 Stripe / Google Pay 付款都会走静态 IP，会稀释"这个 IP 只访问 Anthropic"的画像；二是 Claude 订阅**中国大陆发行的卡全部不可用**（借记、信用卡都不行），只能用海外办理的信用卡或虚拟卡——卡本身不行的话，改 IP 也没用。确有需要再照那个模板追加。

**配砸了怎么恢复？** `bash scripts/rollback.sh` 回滚**最近一次**部署（`--list` 看所有备份点）。每次部署的备份都在自己的时间戳目录里，回滚只碰这一次的改动，不会把你几个月前的配置也翻出来。

**多台设备能共用同一个静态 IP 吗？** 能，而且推荐——"同一个住宅 IP 上有个人在多台设备用 Claude"本身就是很正常的画像，比每台机器一个 IP 更自然。带宽也够（Claude 流量很小）。注意：**每台机器都要各自部署一遍**（配置是写在本机 Clash 里的），而且模板升级后每台都要重新对齐（见排障手册第 10 条）。

**静态 IP 到期忘续费会怎样？** Claude 流量会全部失败（Claude 组指着一个连不上的节点）。跑 `verify.sh` 第 4 项会红。续费后 IP 不变，什么都不用改。

**换了机场 / 订阅更新了怎么办？** 订阅自动更新不影响增强文件（这是用增强文件而不是直接改配置的原因）。换机场则要重跑一遍部署（美国节点名变了，US-Chain 里的名字要对齐）。

**都配好了，为什么 Claude 有时候还是提示异常 / 要我验证？** 先跑 `verify.sh` 定位是不是专线的问题：

- **六项全绿** → 不是专线的事。常见原因：claude.ai 里还挂着旧地区的活跃会话没撤销（最常见）；同一浏览器登了多个 Claude 账号；账号本身触发了别的风控（见 `docs/account-safety.md`）；或者就是 Anthropic 侧的临时抽风，等等再看。
- **第 4 项红**（出口不对）→ 静态 IP 挂了或到期，或链式的美国节点不通。
- **第 2 项红**（组指向错）→ 在 GUI 里手滑把组改了，改回去。
- **浏览器里异常但桌面版正常** → 典型 QUIC 漏流，见排障手册第 2 条；用 Edge/Arc/Brave 的要自己补拦截规则。

**我现在用的不是 Clash Verge（Surge / ClashX / sing-box……）怎么办？** agent 会帮你装 Clash Verge 并把订阅迁过来（订阅链接是通用的），原软件退出卸载即可——顺便排掉"双代理抢路由"这颗雷。执意留在原软件的，看 `docs/porting.md` 自己移植：那条路没验证过，不担保。

## 购买渠道

| 服务 | 链接 | 备注 |
|---|---|---|
| Clash Verge Rev | [GitHub Releases](https://github.com/clash-verge-rev/clash-verge-rev/releases) | 官方唯一下载渠道；也可 `brew install --cask clash-verge-rev` |
| 美国静态住宅 IP | 自行选择服务商 | 要求见上面那张表：美国 + 静态住宅 + SOCKS5，**别买轮换 IP** |
| 机场订阅 | 自行选择服务商 | 任一含美国节点的订阅即可（你现在能正常上网用的那个大概率就行，确认套餐里有美国节点） |
| Claude Desktop | [claude.ai/download](https://claude.ai/download) | 用桌面版的装 |
| Claude Code | `npm install -g @anthropic-ai/claude-code` | agent 执行的前提 |

> **为什么不写具体服务商**：一是这类服务用的人一多质量就掉（住宅 IP 段被滥用后照样会被风控），二是本仓库不想变成广告位。按上面那张表的硬性要求去挑，任何满足条件的服务商都能用。

> ⚠️ **安全提示：** 静态 IP / 机场的账号密码只存在本机 Clash 的配置文件里，**绝不要提交进任何 git 仓库、贴进任何群聊**。

## 红线（配完必读）

1. **本机不要再装 / 开第二个代理或 VPN App**（Shadowrocket、Surge 等）——会和 Clash 抢系统路由，轻则规则失效、重则整机断网。手机版 Shadowrocket 不受影响，是 Mac 上不行。
2. Clash 保持**规则模式**，不要切"全局"或"直连"（全局模式下 Claude 专线规则全部失效）。
3. 每次改配置后：**⌘Q 完全退出并重启** Chrome 和 Claude 桌面版（QUIC/连接有缓存）。
4. 出问题先跑 `scripts/verify.sh`，看哪项红了，对照 `docs/troubleshooting.md` 处理。
5. **别乱设遥测环境变量**（`DISABLE_TELEMETRY` 等），也别在网页版里多账号混用——见 `docs/account-safety.md`。专线只保证出口 IP 干净，这些坑它管不了。

## 仓库结构

| 文件 | 用途 |
|---|---|
| `CLAUDE.md` | agent 执行手册（含安装迁移的全阶段流程，Claude Code 进入本目录自动加载） |
| `docs/manual-setup.md` | 人肉版部署手册（不用 agent 的等价流程） |
| `docs/porting.md` | 非 Clash Verge 客户端的移植规格（未验证，不担保） |
| `templates/` | 4 个 Clash 增强文件模板（填空即用） |
| `scripts/verify.sh` | 一键六项验证（`--save-baseline` 记录出口基线） |
| `scripts/set-credentials.sh` | 本地隐藏输入写凭证，不经过 AI 对话 |
| `scripts/backup.sh` / `rollback.sh` | 按次备份 / 精确回滚最近一次部署 |
| `templates/optional-payment-rules.yaml` | 可选：让订阅付款也走静态 IP（默认不启用） |
| `docs/account-safety.md` | 账号安全清单（遥测环境变量的真相 + 网页版侧习惯） |
| `docs/troubleshooting.md` | 排障手册（10 个真实踩过的坑） |
| `docs/iphone-notes.md` | iPhone（小火箭）能配，步骤未整理；附一条 Mac 红线 |
| `CHANGELOG.md` | 版本更新日志 |

---

> **免责声明**：本仓库仅作个人网络配置技术记录与学习交流之用。使用前请自行了解并遵守所在地法律法规及相关服务的使用条款，风险自负。作者不对账号状态、第三方服务的可用性或使用本方案产生的任何后果负责。
