# 手动部署手册（写给人）

不想用 agent、或者想亲手做一遍搞懂原理的，照这页走。内容和 `CLAUDE.md`（agent 版）完全等价，只是换成人话 + 你自己敲命令。全程约 20–30 分钟。

约定：下文 `$CFG` 指 Clash Verge Rev 的配置目录：

```bash
CFG="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
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
curl -sS --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/proxies | python3 -m json.tool | grep '"name"' | sort -u

# ④ 没有别的 VPN 在跑（除 Tailscale 外不该有 Connected；有就先断开，见排障手册第 1 条）
scutil --nc list
```

把 ③ 里找到的美国节点名**原样记下来**（含 emoji、空格、倍率后缀），第 3 步要逐字用。

## 第 1 步：拿到 iproyal 四元组

iproyal 订单详情里拿 SOCKS5 的 `host / port / username / password` 四样。

**不用测直连**——从国内直连 iproyal 超时是正常的（它通常只接受美国来源），这正是后面要走链式代理的原因。

## 第 2 步：找到四个增强文件

```bash
cat "$CFG/profiles.yaml"
```

- 顶部 `current:` 是当前激活订阅的 uid
- 找到该订阅条目下的 `option:` 段，记下 `proxies` / `groups` / `rules` / `merge` 四个 uid——对应文件就是 `$CFG/profiles/<uid>.yaml`

**option 里缺某个 uid？** 说明那个增强文件还没创建过：打开 Clash Verge → 左侧「订阅」→ 右键当前订阅卡片 → 分别点「编辑节点 / 编辑分组 / 编辑规则 / 编辑 Merge」→ 什么都不改直接保存退出（目的是让 GUI 生成空文件）→ 重新看 `profiles.yaml`。

## 第 3 步：填模板写进去

**先备份**：

```bash
cd "$CFG/profiles"
for f in <proxies的uid> <groups的uid> <rules的uid> <merge的uid>; do cp "$f.yaml" "$f.yaml.bak-$(date +%m%d%H%M)"; done
```

然后把仓库 `templates/` 下四个模板的内容分别写进对应 uid 文件（原文件里已有你自己的内容就合并，别整个覆盖）：

| 模板 | 写进哪 | 要改什么 |
|---|---|---|
| `1-proxies.yaml` | proxies 的 uid 文件 | 填 iproyal 四元组。**`type: socks5`、`udp: false`、`dialer-proxy: "US-Chain"` 三样一个都不能动** |
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
bash scripts/verify.sh
```

**六项全绿才算完成。** 有红项按脚本提示对照 `docs/troubleshooting.md` 修，修完重跑。

## 第 6 步：收尾

1. **⌘Q 完全退出并重启** Chrome 和 Claude 桌面版（不是关窗口，QUIC 会话有缓存）
2. claude.ai → 设置 → 帐户 → **活跃会话**：撤销归属地不对的旧会话，重新登录
3. 确认当前会话归属地 = 静态 IP 所在地（iproyal 美国 IP 常显示弗吉尼亚州阿什本等）
4. 记住 README 的三条红线

## 搞砸了怎么回滚

第 3 步的备份就是后悔药（同一文件多份备份时取**时间最早**的 = 部署前原状）：

```bash
ls -lt "$CFG/profiles/"*.bak-*
cp "$CFG/profiles/<uid>.yaml.bak-<最早时间>" "$CFG/profiles/<uid>.yaml"
```

复制回去后在 GUI「订阅」页再点一次订阅卡片激活，确认能正常上网即恢复原状。
