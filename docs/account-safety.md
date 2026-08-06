# 账号安全清单（本方案之外，别自己给自己挖坑）

专线只解决"出口 IP 干净稳定"。这页记本机环境、Claude 设置、设备和日常使用中容易遗漏的事。

---

## 一、环境变量：别乱设遥测开关

**结论：本方案不把遥测相关环境变量持久化到用户环境。** bootstrap 只在隔离的安装子进程中临时关闭非必要流量，并在 Phase 6 清理；日常环境不要长期设置。

### `DISABLE_TELEMETRY=1` 是什么（官方文档）

Claude Code 官方环境变量参考里明确写着：设为 1 会退出遥测；遥测事件**不包含**你的代码、文件路径或 bash 命令；**同时也会禁用「功能标志（feature flag）获取」，因此仍在灰度推出的某些功能可能不可用**。

翻译成人话：设了它，Anthropic 收不到你的延迟/可靠性统计，**顺带你也拿不到新功能**（新出的斜杠命令会莫名其妙用不了）。`DO_NOT_TRACK=1` 等价于它。

隐私敏感的企业环境用它是官方支持的正常配置——**官方文档里没有任何一句说禁用遥测会影响账号信誉或触发风控**。

### 社区传闻：切换遥测状态导致封号（⚠️ 存疑，n=1）

2026-07 有开发者复盘：长期设着 `DISABLE_TELEMETRY=1`，某天 `unset` 掉之后跑了个任务，随即收到账号 Suspended 邮件（邮件措辞是"内部调查发现与你账号关联的可疑信号，违反使用政策"）。他推测是"长期零遥测静默 → 突然开始上报"这种行为骤变触发了风控。

**怎么看这件事**：这是单个案例的时间相关性，不是因果证据，官方也从没这么说过。"可疑信号"类封号在国内用户里更常见的已知诱因是共享/频繁跳变的出口 IP、账号共用、地区限制——这也正是本方案（固定美国住宅 IP）要解决的问题。

**保守做法**（成本几乎为零，照做不亏）：

1. 就别设 `DISABLE_TELEMETRY` / `DO_NOT_TRACK` / `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`，保持默认
2. 万一你以前设过：删掉之后**先歇一会儿再跑重活**，别"刚改完立刻开大任务"
3. 自查三处（都设过才算干净）：

> v1.3.0 bootstrap 会在隔离的安装子进程中临时设置 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`，并在 Phase 6 清理；这不等于建议写入用户长期配置。

```bash
[ "${DISABLE_TELEMETRY+x}" = x ] && echo DISABLE_TELEMETRY
[ "${DO_NOT_TRACK+x}" = x ] && echo DO_NOT_TRACK
[ "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC+x}" = x ] && echo CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
# 全局设置：只打印匹配的键名和冒号，不打印任何值 / API Key
grep -ioE '"[^"[:space:]]*(telemetry|nonessential|do_not_track)[^"]*"[[:space:]]*:' \
  "$HOME/.claude/settings.json" 2>/dev/null
grep -hioE 'DISABLE_TELEMETRY|DO_NOT_TRACK|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' \
  ~/.zshrc ~/.zprofile ~/.zshenv 2>/dev/null | sort -u
```

三组都没输出 = 没发现持久化开关。也可以直接跑 `claude doctor`，它会报告功能标志校验是否被禁用。

---

## 二、网页版（claude.ai）侧的习惯

专线配好之后，网页版这边有几件事仍然靠你自己：

1. **配完必须撤销旧会话**：claude.ai → 设置 → 帐户 → 活跃会话，把归属地不是静态 IP 所在地的会话全部撤销并重新登录。不撤销的话，账号在服务端仍然挂着"来自日本/其他地区"的活跃会话，等于专线白配了一半。
2. **一个浏览器 profile 只登一个 Claude 账号**。同一浏览器里来回切多个账号，Cookie/指纹会把它们关联起来——这是"可疑信号"里最常见的一类。
3. **确认浏览器流量真的走了专线**：`verify.sh` 第 3 项查的就是浏览器 QUIC 拦截规则在不在。用 Chrome 之外的 Chromium 浏览器（Edge / Arc / Brave）要自己补规则，见模板③注释和排障手册第 2 条。
4. **改完配置一定 ⌘Q 完全退出浏览器再开**（不是关窗口）——QUIC 会话和连接池有缓存，不重启就还在走老链路。
5. **别在公共网络/共享 IP 上登你的 Claude 账号**（咖啡馆 WiFi、公司出口、机场共享节点），画像一乱就白费。

### Claude 隐私开关

打开 Claude → Settings → Privacy，把下面两项都关闭：

- `Location metadata`
- `Help improve our AI models`

两个开关都应显示为灰色关闭状态。

### 手机设备

手机没有配好同等链式出口时，不要用它登录或使用 Claude。如果只为支付临时登录，支付完后立即回到网页的「设置 → 帐户 → 活跃会话」，撤销该手机设备的会话。

---

## 三、设备侧：系统地区设成美国

**把 macOS 的「地区」设成美国**：系统设置 → 通用 → 语言与地区 → **地区：美国**。

道理很简单：出口 IP 已经是美国了，设备侧也报美国，两边一致。**地区只影响日期/数字/温度这些格式，界面语言完全不用改**——保持中文没有任何问题（美国有大量中文用户，"中文界面 + 美国 IP"是极常见的合法组合）。代价接近于零，做了不亏。

查当前值：

```bash
defaults read -g AppleLocale        # 期望形如 zh-Hans_US（语言中文 + 地区 US）
defaults read -g AppleLanguages     # 形如 ("zh-Hans-US", "en-US")
```

**时区要不要一起改？不强制，看你的实际情况。** 时区是设备侧唯一会"明显对不上"的项——网页能读到你的时区是 `Asia/Shanghai`，而 IP 在美国。

```bash
ls -l /etc/localtime | sed 's|.*/zoneinfo/||'   # 看当前时区
```

- **主要用 Claude、不依赖本机日历提醒的** → 改成美东（如 `America/New_York`）更一致
- **人在国内、日程全按北京时间的** → 别改。改了之后日历、提醒、会议时间全部错位，日常代价很实在；而且"美国 IP + 中国时区"本来就是你的真实处境，并不反常

⚠️ **别为这个装浏览器时区伪装扩展**：扩展本身会给 claude.ai 增加新的指纹特征，还可能被识别成自动化工具——为了消除一个弱信号引入一个更强的信号，方向反了。

> 说明：以上属于"一致性卫生"，**Anthropic 没有任何官方说法**表示它看这些。真正已知有效的仍然是固定干净的出口 IP + 会话卫生。地区设置便宜就顺手做，时区代价大就按需。

## 四、日常使用和账号保管

1. **先开 Clash，再开 Claude**。先确认 Clash 内核、TUN 和规则模式正常，再启动 Claude 桌面版、浏览器或 Claude Code。
2. **Clash Verge 可开轻量模式**，前提是轻量模式不会停止内核或 TUN。开启后跑一次 `bash scripts/verify.sh`。
3. **机场和 ISP 账号由使用者自己保管**。账号、续费日期和找回方式放进密码管理器；订阅链接、ISP 凭证和 API Key 不得记在本仓库、对话、脚本或明文笔记里。

## 五、一句话总结

**能拿到官方依据的**：遥测开关是正常配置项，但 `DISABLE_TELEMETRY` 会连带关掉新功能获取，所以没必要设。
**没有官方依据、只是保守起见**：不要在"长期关闭"和"开启"之间来回切，尤其别切完立刻跑重活。
**真正已知会招风控的**：出口 IP 乱跳、多账号混用、共享网络——这才是本方案存在的理由。
