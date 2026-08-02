# 手动部署手册（写给人）

不想用 Agent、或者想亲手做一遍搞懂原理的，照这页走。权威 Agent 流程现位于根目录 `RUNBOOK.md`；本页保留人工部署路径。全程约 20–30 分钟。

前提：Clash Verge Rev 已装好、机场订阅已导入。还没装的：从 [Clash Verge Rev 官方 Releases](https://github.com/clash-verge-rev/clash-verge-rev/releases) 下载对应架构的正式版 DMG，确认 macOS 签名后安装；不要依赖 Homebrew 或第三方镜像。然后在「订阅」页直接粘贴链接、打开 TUN、保持规则模式；原代理软件必须先退出。无代理机器的国内安装要等 [`docs/bootstrap.md`](bootstrap.md) 所列分发门禁通过。

先 `cd <仓库目录>`；下文命令都从仓库根目录执行。`$CFG` 指 Clash Verge Rev 的配置目录：

```bash
CFG="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
export CLAUDE_LANE_DEPLOY_ID=$(date +%Y%m%d-%H%M%S)
printf '本次 deployment id：%s\n' "$CLAUDE_LANE_DEPLOY_ID"
```

---

## 第 0 步：环境体检（只看不改）

四条都过了再往下走：

```bash
# ① Clash 内核在跑（有输出即可）
pgrep -fl verge-mihomo

# ② TUN 开着、规则模式（应看到 enable: true 和 mode: rule）
grep -A2 '^tun:' "$CFG/clash-verge.yaml" | head -3; grep '^mode:' "$CFG/clash-verge.yaml"

# ③ 订阅里有美国节点（在输出里找 美国/US/🇺🇸/Los Angeles 等；注意 US 会误匹配 AUS/RUS）
curl -sS --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/proxies \
  | /usr/bin/osascript -l JavaScript scripts/macos-json.js proxy-names

# ④ 没有别的 VPN 在跑（除 Tailscale 外不该有 Connected；有就先断开，见排障手册第 1 条）
scutil --nc list
```

把 ③ 里找到的美国节点名**原样记下来**（含 emoji、空格、倍率后缀），第 3 步要逐字用。

## 第 1 步：拿到静态IP四元组

在静态 IP 服务商的订单详情里拿 SOCKS5 的 `host / port / username / password` 四样。

**不用测直连**——从国内直连 静态IP 超时是正常的（它通常只接受美国来源），这正是后面要走链式代理的原因。

## 第 2 步：找到四个增强文件

```bash
# 只输出安全摘要，不显示订阅 URL、订阅名或 profiles 原文
bash scripts/profile-config.sh summary
```

- `current_uid` 是当前激活订阅的 uid；`current_type` 必须是 `remote`
- `options` 给出 `proxies` / `groups` / `rules` / `merge` 四个 uid；对应文件是 `$CFG/profiles/<uid>.yaml`

**summary 的 `missing` 里有类型？** 用同一个 deployment id 逐项登记：

```bash
CLAUDE_LANE_DEPLOY_ID="$CLAUDE_LANE_DEPLOY_ID" bash scripts/profile-config.sh register proxies
CLAUDE_LANE_DEPLOY_ID="$CLAUDE_LANE_DEPLOY_ID" bash scripts/profile-config.sh register groups
CLAUDE_LANE_DEPLOY_ID="$CLAUDE_LANE_DEPLOY_ID" bash scripts/profile-config.sh register rules
CLAUDE_LANE_DEPLOY_ID="$CLAUDE_LANE_DEPLOY_ID" bash scripts/profile-config.sh register merge
bash scripts/profile-config.sh summary
```

只执行缺失类型。脚本会先备份再创建；不要直接打开或打印 `profiles.yaml`。

## 第 3 步：填模板写进去

**先备份**（一条命令，备份进独立的时间戳目录，方便日后精确回滚）：

```bash
cd <仓库目录>
CLAUDE_LANE_DEPLOY_ID="$CLAUDE_LANE_DEPLOY_ID" bash scripts/backup.sh "$CFG/profiles.yaml" \
                       "$CFG/profiles/<proxies的uid>.yaml" "$CFG/profiles/<groups的uid>.yaml" \
                       "$CFG/profiles/<rules的uid>.yaml" "$CFG/profiles/<merge的uid>.yaml"
```

然后把仓库 `templates/` 下四个模板的内容分别写进对应 uid 文件（原文件里已有你自己的内容就合并，别整个覆盖）：

| 模板 | 写进哪 | 要改什么 |
|---|---|---|
| `1-proxies.yaml` | proxies 的 uid 文件 | **别手填**：跑 `CLAUDE_LANE_DEPLOY_ID="$CLAUDE_LANE_DEPLOY_ID" bash scripts/set-credentials.sh`（四项均隐藏输入、自动定位文件、自动备份）。**`type: socks5`、`udp: false`、`dialer-proxy: "US-Chain"` 三样一个都不能少** |
| `2-groups.yaml` | groups 的 uid 文件 | `US-Chain` 里填第 0 步记下的美国节点名，**逐字一致** |
| `3-rules.yaml` | rules 的 uid 文件 | 整体照抄，**顺序不能动**（QUIC 拦截必须最前） |
| `4-merge.yaml` | merge 的 uid 文件 | sniffer 段照抄（文件里已有别的顶层配置就保留、追加） |

## 第 4 步：激活

打开 Clash Verge → 左侧「订阅」→ **点一下当前订阅卡片**（触发重新合并 + 内核加载）。

激活后立刻查一眼日志：

```bash
tail -20 "$CFG/logs/service/service_latest.log" | grep -i "Start TUN listening error"
```

有输出（`add route: ... file exists`）= 有别的 VPN 抢路由，转排障手册第 1 条，**不要反复重启内核硬试**。

## 第 5 步：验证

```bash
bash scripts/verify.sh --save-baseline
```

**六项全绿才算完成**（`--save-baseline` 会把实测出口 IP 记为基线，以后 `bash scripts/verify.sh` 就跟它比）。 有红项按脚本提示对照 `docs/troubleshooting.md` 修，修完重跑。

## 第 6 步：收尾

1. **⌘Q 完全退出并重启** Chrome 和 Claude 桌面版（不是关窗口，QUIC 会话有缓存）
2. claude.ai → 设置 → 帐户 → **活跃会话**：撤销归属地不对的旧会话，重新登录
3. 确认当前会话归属地 = 静态 IP 所在地（美国住宅 IP 常显示弗吉尼亚州阿什本等）
4. 记住 README 的三条红线

## 搞砸了怎么回滚

第 3 步的备份就是后悔药，一条命令回滚**最近一次**部署：

```bash
bash scripts/rollback.sh "$CLAUDE_LANE_DEPLOY_ID"
```

脚本会先列出要还原的文件让你确认，还原前也会把当前状态存一份。还原完在 GUI「订阅」页点一次订阅卡片激活，确认能正常上网即恢复原状。
