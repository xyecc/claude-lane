# 移植规格：在非 Clash Verge 客户端上复刻本方案（⚠️ 未验证）

> 本方案只在 **Clash Verge Rev（mihomo 内核）/ macOS** 上真机验证过。你若执意用别的代理客户端，这页把方案抽象成和具体软件无关的「目标状态」，供你（或你的 agent）自行移植。**移植结果自负，排障手册里的坑不保证适用。** 首选方案永远是迁移到 Clash Verge Rev（订阅链接通用，导入即可）。

## 目标状态（四条，缺一不可）

**① 一个链式出口节点。** 静态住宅 IP 以 SOCKS5 节点接入，**必须经由机场美国节点中转**（静态 IP 通常只接受美国来源，国内直连不通），且 UDP 禁用（强制流量走 TCP，配合 ③ 防漏）。各内核的"链式"叫法：

| 内核/客户端 | 链式字段 |
|---|---|
| mihomo（Clash 系） | `dialer-proxy` |
| Surge | `underlying-proxy` |
| sing-box | `detour` |
| Shadowrocket (iOS) | 代理链 / relay（版本能力不一） |

**② 三层规则圈住 Claude 流量**，全部导向 ① 的出口（顺序：进程 → 域名 → IP 段）：

- 进程名：`Claude`、`Claude Helper`（及 GPU/Renderer/Plugin 变体）、`claude.exe`（Claude Code）
- 域名后缀：`anthropic.com`、`claude.com`、`claude.ai`、`claudeusercontent.com`；域名关键词 `anthropic`
- IP 段兜底：`160.79.104.0/23`（Anthropic 自有段，no-resolve）

**③ QUIC 拦截。** 浏览器进程与 Claude 桌面进程的 UDP/443 必须 REJECT（浏览器会用 QUIC 绕过域名识别漏到默认节点；拒掉后无感回落 TCP）。**注意粒度必须是进程级**——全局禁 UDP/443 会废掉全机 HTTP/3。**客户端若没有进程级规则能力（多数简易 V2ray 客户端、全部 iOS 端），做不到等价效果，②的进程层和本条都会缺失，漏流风险自负。**

**④ 域名嗅探（sniffer）开启**，对 TLS/HTTP/QUIC 嗅探并对 anthropic/claude 域族强制回填域名——Claude 桌面版自解析 DNS，TUN 只见 IP，不开嗅探则域名规则落空。

## 验收标准（等价于 verify.sh 的核心两项）

经该客户端代理后：

```bash
curl https://claude.ai/cdn-cgi/trace   # ip= 必须等于静态 IP
curl https://api.ipify.org             # 必须等于机场节点 IP（≠静态 IP，证明没有全局误走）
```

外加：日志里 Claude/Anthropic 相关连接全部命中你的专用出口组；浏览器重启后（清 QUIC 缓存）claude.ai 会话归属地 = 静态 IP 地区。

## 可行性速查

| 客户端 | 判断 |
|---|---|
| mihomo 内核系（ClashX Meta、Mihomo Party、FlClash、Stash 桌面版…） | 能力齐全，理论可行；差异在配置文件位置与注入方式 |
| Surge (Mac) | 有链式和进程规则，理论可行，语法全部重写 |
| sing-box 系 | 有 detour 与 process_name，理论可行，JSON 配置自己拼 |
| 简易 V2ray 类 / 仅全局代理类 | ❌ 无进程分流或无链式，做不到等价效果 |
| iOS 全部 | 无进程级能力，参见 `iphone-notes.md`（同为未验证思路） |
