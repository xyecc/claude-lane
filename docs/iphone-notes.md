# iPhone 侧思路（附录，⚠️ 未实机验证）

> 本页只是思路记录，**没有像 Mac 流程那样经过真机验证**。照做前自己评估，跑通了欢迎回来补充。

## 目标

和 Mac 一致：iPhone 上只有 Claude App / claude.ai 的流量走 静态住宅 IP，其余走机场。

## 工具

Shadowrocket（iOS 版）。注意：**Mac 版 Shadowrocket 不要装**——它会和 Clash Verge 抢路由（见排障手册第 1 条），手机上没这个问题。

## 思路

1. **节点**：添加 静态 IP SOCKS5 节点（host/port/user/pass 四元组）
2. **链式**：Shadowrocket 的代理链能力取决于版本——查你版本里有没有「代理链 / Proxy Chain / relay」类型的节点或分组。如果有：建一条 机场美国节点 → 静态 IP 的链；如果没有，静态IP 直连在部分运营商网络下可能碰运气能通（美国来源限制主要影响数据中心来源，实测口径不一）
3. **分流规则**（规则模式下添加，目标选到上面的链式出口，**千万不要选 DIRECT**——那是直连，等于绕过代理）：

```text
DOMAIN-SUFFIX,anthropic.com,<链式出口>
DOMAIN-SUFFIX,claude.com,<链式出口>
DOMAIN-SUFFIX,claude.ai,<链式出口>
DOMAIN-SUFFIX,claudeusercontent.com,<链式出口>
DOMAIN-KEYWORD,anthropic,<链式出口>
```

4. **验证**：Safari 开 `https://claude.ai/cdn-cgi/trace`，`ip=` 应为静态 IP；再开 `https://api.ipify.org` 应为机场 IP

## 已知风险

- iOS 上 App 的 QUIC 流量是否会绕过域名规则未验证（Mac 上 Chrome 会，见排障手册第 2 条）
- Shadowrocket 各版本链式能力差异大，本页不保证你的版本可行
