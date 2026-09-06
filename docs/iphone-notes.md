# iPhone（iOS）配法：Shadowrocket 小火箭

**能做到。** iOS 上用 **Shadowrocket（小火箭）** 可以配出和 Mac 等价的效果——只有 Claude 相关流量走美国静态住宅 IP，其余走机场。作者本人的 iPhone 就是这么配的，长期在用；下面的配方来自 2026-08 一次真机部署，**已验证可用**。

手机上没有 agent，全部在 App 界面里点，5 分钟。目标状态和 Mac 一致（见 [`porting.md`](porting.md)），只是 iOS 没有进程级分流，只能做域名 + IP 两层。

## 1. 关键概念：链式那一跳，小火箭叫「代理通过」

对应 mihomo 的 `dialer-proxy`。这是整个 iOS 配置里唯一说不清、也最容易卡住的字段——静态节点的「代理通过」选一个机场美国节点，链就成立了。

## 2. 静态节点（首页 → 右上 `+`）

| 字段 | 值 |
|---|---|
| 类型 | **Socks5** |
| 地址 / 端口 / 用户 / 密码 | 静态 IP 的四元组 |
| 算法 | auto |
| 插件 | none |
| TCP 快速打开 | **关** |
| **UDP 转发** | **关**（防 QUIC 漏流的一环，对应模板里的 `udp: false`） |
| **代理通过** | **选一个机场美国节点** ← 链式就靠它 |
| 备注 | 例如 `静态住宅-US` |

**搭对了的标志**：节点列表里该节点显示成 **`SOCKS5 > SHADOWSOCKS`**（有箭头 = 链已成立），且它归到首页的「**本地节点**」分组下。

## 3. 规则（配置 → 当前 `.conf` → 编辑 → 规则 → 右上 `+`）

只需两条，加完**拖到规则列表最顶端**（别被前面的规则截胡）：

| 类型 | 域名 | 策略 |
|---|---|---|
| `DOMAIN-KEYWORD` | `claude` | **LOCAL-SERVERS** |
| `DOMAIN-KEYWORD` | `anthropic` | **LOCAL-SERVERS** |

「扩展匹配」「预匹配」两个开关都保持**关**。

> `LOCAL-SERVERS` 就是「本地节点」那个组，静态节点在里面。
> 两条 keyword 已覆盖 claude.ai / claude.com / claudeusercontent.com / anthropic.com 全套，不必再加 DOMAIN-SUFFIX。
> 可选兜底：`IP-CIDR` `160.79.104.0/23` → LOCAL-SERVERS（Anthropic 自有段，DNS 被污染时用）。

## 4. 验收（必做，两条都要对）

Safari 里依次打开：

| 地址 | 期望 |
|---|---|
| `https://claude.ai/cdn-cgi/trace` | 返回里的 `ip=` **等于静态 IP** |
| `https://api.ipify.org` | **等于机场节点 IP**，≠ 静态 IP |

第二条尤其重要——它证明**没有全局误走静态 IP**（住宅 IP 带宽小、流量贵，全走上去会很难受）。

## 5. iOS 天然做不到的

**无进程级分流能力。** Mac 版那套「按进程名圈住 Claude / Claude Helper」和「只拒浏览器的 QUIC」在手机上都不存在，只能做**域名 + IP 两层**。够用，但比 Mac 糙。

## 6. 红线不变

⚠️ **Mac 上不要装 Shadowrocket**。Mac 版会和 Clash Verge 抢系统路由，轻则规则失效、重则整机断网（排障手册第 1 条就是这个坑）。**手机版没有这个问题**——手机用小火箭、Mac 用 Clash Verge，两边同时用互不干扰。多台设备**共用同一个静态 IP 是推荐做法**（见 [FAQ](faq.md)）。
