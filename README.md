# Claude 专线：让 Claude 流量走美国静态住宅 IP（agent 一键复刻版）

让 macOS 上的 Claude（网页版 / 桌面版 / Claude Code 全覆盖）永久走一个**固定的美国静态住宅 IP**，其余流量保持你机场订阅的原有规则不变。

配置过程不用你手动改文件——由你自己的 Claude Code agent 照本仓库执行，你只需要提供凭证 + 在图形界面点一次激活。两台真机（2026-07）完整验证过。

```
Claude 流量 ──→ Clash TUN ──→ Claude 分组 ──→ iproyal 静态节点 (socks5)
                                                │ dialer-proxy 链式
                                                └→ US-Chain 分组（机场美国节点）──→ iproyal ──→ Anthropic
其他流量  ──→ 机场订阅原有规则（不受影响）
```

Claude 服务器看到的出口 IP = 你的 iproyal 静态 IP，永久固定。

## 原理（3 分钟版，知其所以然再动手）

**为什么要固定 IP？** 机场节点是共享出口，IP 经常换、还和无数陌生用户共用。在 Claude 看来你就是"今天日本明天美国、和一堆人共用 IP"的可疑账号。一个只有你在用、永不变化的美国住宅 IP，画像干净得多。

**为什么要"链式"？** iproyal 的静态住宅 IP 通常只接受美国来源的连接，从国内直连会被拒/超时。所以先借机场的美国节点出境（第一跳），再从美国连 iproyal（第二跳）。这就是模板里 `dialer-proxy: "US-Chain"` 干的事。

**为什么只有 Claude 走这条线？** 住宅 IP 带宽小、流量贵，扛不住日常刷网页；而且"这个 IP 只访问 Anthropic"本身就是最干净的画像。所以用 Clash 的分流规则精确圈出 Claude 的流量（按进程名 + 域名 + IP 段三层兜底），其余流量照旧走机场。

**QUIC 拦截是干嘛的？** Chrome 会用 UDP 的 QUIC 协议直连，绕过域名识别导致漏流（实测会漏到日本节点）。把 Chrome 的 QUIC 拒掉，它会无感回落到 TCP，就能被规则抓住了。

## 你需要准备的三样东西

1. **Clash Verge Rev** 已安装、已导入机场订阅（订阅里**必须有美国节点**），开着 TUN（虚拟网卡）+ 规则模式能正常上网
2. **iproyal 静态住宅 IP** 一份：`host:port:username:password` 四元组，协议 **SOCKS5**
3. **Claude Code** 已安装、能正常对话

## 快速开始

```bash
git clone https://github.com/maien210/claude-lane
cd claude-lane
claude
```

然后对 Claude 说一句：

> **按这个仓库的流程给本机配置 Claude 专线，先做环境体检。**

agent 会自己完成：环境体检 → 向你要 iproyal 四元组 → 备份并写入配置 → 请你在 GUI 点一次激活 → 跑 `scripts/verify.sh` 全链路验证 → 教你收尾（重启浏览器、清理旧会话）。

不想用 agent、或想亲手做一遍搞懂每一步的：照 **`docs/manual-setup.md`**（人肉版手册，和 agent 流程完全等价，约 20–30 分钟）。

## 日常使用（部署完成后）

平时什么都不用管。**唯一要记住的一个动作**：感觉不对劲（会话归属地变了、Claude 突然要验证、连不上）就跑一遍体检：

```bash
bash scripts/verify.sh
```

六项全绿 = 专线没问题，别处找原因；有红项 = 按提示对照 `docs/troubleshooting.md` 处理。

## 常见问题（FAQ）

**一共要花多少钱？** 机场订阅（你本来就有）+ iproyal 静态住宅 IP 约 $4–6/月（选美国、最低带宽档就够，流量只有 Claude 在用）。

**iproyal 怎么买？** [iproyal.com/static-residential-proxies](https://iproyal.com/static-residential-proxies/) → 地区选 United States → 付款后在订单详情（Proxy details）里拿 SOCKS5 的 host/port/username/password 四元组。支持支付宝。

**配完多久生效？** 立即。但浏览器和桌面版有连接缓存，**必须 ⌘Q 重启**才切到新链路；claude.ai 的旧会话记录的还是老 IP，要手动撤销重登。

**会影响我其他网站的速度吗？** 不会。只有 Claude 流量走静态 IP，其余流量走机场原有规则，一个字节都不经过 iproyal。唯一例外：模板③默认把 Stripe 支付也导过去了（避免付款风控），不想要可以删（模板里有注释）。

**iproyal 到期忘续费会怎样？** Claude 流量会全部失败（Claude 组指着一个连不上的节点）。跑 `verify.sh` 第 4 项会红。续费后 IP 不变，什么都不用改。

**换了机场 / 订阅更新了怎么办？** 订阅自动更新不影响增强文件（这是用增强文件而不是直接改配置的原因）。换机场则要重跑一遍部署（美国节点名变了，US-Chain 里的名字要对齐）。

## 购买渠道

| 服务 | 链接 | 备注 |
|---|---|---|
| Clash Verge Rev | [GitHub Releases](https://github.com/clash-verge-rev/clash-verge-rev/releases) | 官方唯一下载渠道 |
| iproyal 静态住宅 IP | [iproyal.com/static-residential-proxies](https://iproyal.com/static-residential-proxies/) | 地区选美国；下单后在订单详情里拿 SOCKS5 四元组 |
| 机场订阅 | —— | 任一含美国节点的订阅服务即可（你现在能正常上网用的那个大概率就行，确认套餐里有美国节点） |
| Claude Desktop | [claude.ai/download](https://claude.ai/download) | 用桌面版的装 |
| Claude Code | `npm install -g @anthropic-ai/claude-code` | agent 执行的前提 |

> ⚠️ **安全提示：** iproyal / 机场的账号密码只存在本机 Clash 的配置文件里，**绝不要提交进任何 git 仓库、贴进任何群聊**。

## 红线（配完必读）

1. **本机不要再装 / 开第二个代理或 VPN App**（Shadowrocket、Surge 等）——会和 Clash 抢系统路由，轻则规则失效、重则整机断网。手机版 Shadowrocket 不受影响，是 Mac 上不行。
2. Clash 保持**规则模式**，不要切"全局"或"直连"（全局模式下 Claude 专线规则全部失效）。
3. 每次改配置后：**⌘Q 完全退出并重启** Chrome 和 Claude 桌面版（QUIC/连接有缓存）。
4. 出问题先跑 `scripts/verify.sh`，看哪项红了，对照 `docs/troubleshooting.md` 处理。

## 仓库结构

| 文件 | 用途 |
|---|---|
| `CLAUDE.md` | agent 执行手册（七阶段流程，Claude Code 进入本目录自动加载） |
| `docs/manual-setup.md` | 人肉版部署手册（不用 agent 的等价流程） |
| `templates/` | 4 个 Clash 增强文件模板（填空即用） |
| `scripts/verify.sh` | 一键六项验证（出口 IP、组状态、规则、漏流扫描等） |
| `docs/troubleshooting.md` | 排障手册（10 个真实踩过的坑） |
| `docs/iphone-notes.md` | iPhone 侧思路（附录，未验证） |

---

> **免责声明**：本仓库仅作个人网络配置技术记录与学习交流之用。使用前请自行了解并遵守所在地法律法规及相关服务的使用条款，风险自负。请勿公开传播本仓库内容。
