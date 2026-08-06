# Claude 专线：只让 Claude 走美国静态住宅 IP

**v1.3.0** · macOS 专线路由已实现；Windows 专线路由进入候选验收 · 镜像启动链覆盖 macOS / Windows x64 / ARM64 · 版本以 [`VERSION`](VERSION) 为准 · [更新日志](CHANGELOG.md)

让 macOS 上的 Claude 网页版、桌面版和 Claude Code 固定走一个美国静态住宅 IP；其他流量继续使用机场订阅原有规则。

```text
Claude 流量 → Clash TUN → Claude 分组 → 静态 SOCKS5
                                            ↑ dialer-proxy
                                      机场美国节点

其他流量   → 机场订阅原有规则
```

## v1.3.0 当前状态

本版加入 manifest 驱动、可暂停恢复的 `bootstrap.sh` 与 `bootstrap.ps1`。固定上游基线为 Claude Code `2.1.220`、Clash Verge Rev `2.5.2`，覆盖 macOS Apple Silicon / Intel 与 Windows ARM64 / x64。Clash 四个平台安装包已发布到阿里云 OSS 并完成匿名回下载校验；Claude Code 不进入国内公开镜像，而是在订阅代理可用后从 Anthropic 官方固定版本地址下载。备用源按维护者决定暂缓，stable 仍因 lane 归档、真机和端到端证据未齐而**保持阻断**。

因此：

- 启动器遇到示例域名、`TBD`、空值或非 64 位 SHA-256 时会在修改系统前安全停止；
- 目前没有可公开复制的 stable 国内安装命令；
- lane 归档、Windows 双架构真机、Intel Mac 和无代理干净 Mac 端到端验收尚未全部完成；
- 不再生成含大体积制品的 Windows 搬运验证包；Windows 使用同一 OSS 启动链，本地路由配置、备份、回滚和六项验证已经实现但仍待双架构真机验收；
- 不要删掉校验或临时换第三方镜像来绕过门禁。

分发清单、签名、对象存储和发布门禁见 [`docs/bootstrap.md`](docs/bootstrap.md)。当前可先审阅 [`RUNBOOK.md`](RUNBOOK.md)，或在已有 Clash Verge 环境上使用 [`docs/manual-setup.md`](docs/manual-setup.md)。

## 方案边界

| 平台 | 分流方案 | 本仓库自动化 |
|---|---|---|
| macOS（Apple Silicon / Intel） | 支持 | 完整 RUNBOOK 目标平台；stable 待发布 |
| Windows（ARM64 / x64） | 候选实现 | 固定版镜像下载、验签、检查点、路由配置、回滚与六项验证已实现；等待双架构真机验收 |
| iPhone / iOS | 可用其他客户端实现 | 不支持，见 [`docs/iphone-notes.md`](docs/iphone-notes.md) |
| Linux | 未验证 | 不支持 |

本仓库只解决网络出口的一致性，不保证账号状态，也不能代替遵守 Anthropic、机场和静态 IP 服务商的条款。

## 需要准备

1. 一份含美国节点的机场订阅；开始安装时可以暂时没有，Clash Verge 装好后会在订阅检查点暂停；
2. 一个美国静态住宅 / ISP SOCKS5；不能是动态或轮换 IP；
3. 一台受支持的 macOS；
4. bootstrap 正式发布后，一枚额度受限、可撤销的安装专用 DeepSeek API Key。

静态 SOCKS5 最低带宽通常足够，模板明确使用 `udp: false`。多台设备可以共用同一个静态出口，但每台设备都要单独部署。

## 凭证边界

- 机场订阅链接只粘贴到 Clash Verge GUI，绝不发给 Agent；
- 静态 IP 的 host、port、username、password 只通过 `scripts/set-credentials.sh` 在本地隐藏输入；
- DeepSeek Key 由 bootstrap 从终端隐藏读取，只作为 Claude Code 子进程环境变量，不进入命令参数、Shell 历史、仓库或用户级配置；
- Agent 不读取完整 Clash 配置或凭证块，只接收打码状态；
- 提 Issue 前必须遮掉 IP、节点名、订阅名和所有凭证。

## 部署流程

正式 bootstrap 分发配置完成后，预期流程如下：

```text
bootstrap.sh
  ├─ 检查 macOS、CPU、磁盘和已有代理
  ├─ 读取固定版本 manifest，从阿里云 OSS 下载仓库包和 Clash Verge
  ├─ 安装并打开 Clash Verge
  ├─ 没有订阅 → 保存 WAITING_FOR_SUBSCRIPTION 后正常暂停
  ├─ 用户在 GUI 本地导入订阅；重新运行后从检查点继续
  ├─ 代理可用后从 Anthropic 官方地址下载固定版 Claude Code 并验签
  ├─ 从终端隐藏读取 DeepSeek 安装 Key
  ├─ 用 deepseek-v4-flash / max 做模型与只读工具自检
  └─ 启动 Agent 完整读取 RUNBOOK.md
       ├─ Phase -1～0：代理归一和只读体检
       ├─ Phase 1：用户本地隐藏输入静态 IP 四元组
       ├─ Phase 2～3：定位、备份并写入增强文件
       ├─ Phase 4：用户在 Clash Verge 点订阅卡片激活
       ├─ Phase 5：verify.sh 六项验证
       └─ Phase 6：退出 DeepSeek 临时模式，用户再登录 Claude
```

检查点完整状态与用户/自动化边界见 [`docs/setup-checkpoints.md`](docs/setup-checkpoints.md)。机场订阅、ISP 凭证、付款和最终账号登录都是明确的人工作业，不会被误报成安装失败。

订阅检查点之前不得访问或登录 Anthropic。检查点之后只允许通过已验证代理访问 Anthropic 官方固定版下载地址；六项验证全绿后，启动器才清理 DeepSeek 临时环境、配置、会话和日志，并用干净环境进入正常 Claude 登录流程。

Agent 的唯一权威手册是 [`RUNBOOK.md`](RUNBOOK.md)：

- `CLAUDE.md`：默认 Claude Code 入口；
- `AGENTS.md`：其他 Agent 的人工恢复 / 兼容入口；
- `QWEN.md`：Qwen Code 兼容入口。

## 手工部署

已经装好 Clash Verge、已经导入订阅且网络可用时，可按 [`docs/manual-setup.md`](docs/manual-setup.md) 手工部署。它不等于无代理 bootstrap，也不代表国内分发链路已验收。

Agent 执行时必须完整读取 `RUNBOOK.md`，严格遵守 STOP、备份、回滚、隐私和 Phase 6 清理要求。六项验证未全绿不得宣布完成。

## 日常体检

```bash
bash scripts/verify.sh
```

首次部署全绿时使用：

```bash
bash scripts/verify.sh --save-baseline
```

它会记录真实出口基线并检查：

1. Mihomo 内核与 TUN；
2. Claude / US-Chain 策略组；
3. QUIC、进程、域名和遥测规则；
4. Claude 出口与普通出口隔离；
5. 日志漏流；
6. 其他 VPN。

有红项就按 [`docs/troubleshooting.md`](docs/troubleshooting.md) 处理。配置失败时使用：

```bash
bash scripts/rollback.sh --list
bash scripts/rollback.sh <deployment-id>
```

## 常见问题

**为什么要链式代理？** 很多美国静态住宅 SOCKS5 不接受中国来源直连。`dialer-proxy: "US-Chain"` 先经机场美国节点出境，再连接静态出口。

**会影响其他网站吗？** 不会。规则只把 Claude 进程、域名和 IP 段送到专线，其他流量沿用机场规则。

**为什么拦截 QUIC？** Chrome 的 UDP/QUIC 可能绕过域名识别。只拒绝 Chrome 的 UDP/443，让它回退 TCP；不会全局拦截 UDP/443。

**支付流量也走专线吗？** 默认不走。`templates/optional-payment-rules.yaml` 会让其他网站的 Stripe / Google Pay 也走静态 IP，只有明确需要时才启用。

**订阅更新会覆盖配置吗？** 增强文件通常会继续生效；更换机场或美国节点名变化后需要重新对齐。异常先跑 `scripts/verify.sh`。

**还在使用其他 VPN 怎么办？** macOS 上不要同时运行第二个代理或 VPN App。除 Tailscale 外发现已连接 VPN 时，RUNBOOK 要求停止部署。

## 三条红线

1. 不同时运行第二个 VPN / 代理 App；
2. Clash 保持规则模式，不切全局或直连；
3. 订阅更新或出现异常时，先运行 `scripts/verify.sh`，六项未全绿不继续登录。

另外，配置变更后要完全退出并重启 Chrome 与 Claude；订阅、四元组、模型 Key 和完整配置不得发进对话或 Git。

## 仓库结构

| 文件 | 用途 |
|---|---|
| `RUNBOOK.md` | Agent 无关的唯一权威执行手册 |
| `CLAUDE.md` / `AGENTS.md` / `QWEN.md` | 各 Agent 的精简入口 |
| `bootstrap.sh` | Bash 3.2 确定性启动器；分发资源未配置时安全停止 |
| `bootstrap.ps1` | Windows 10 1809+ x64 / ARM64 固定版下载、验签与安装启动器 |
| `manifests/stable.json` | 固定版本、主备源和 SHA-256 清单 |
| `docs/bootstrap.md` | 国内分发、签名、离线包和发布门禁 |
| `docs/mirror-release.md` | 发布者侧抓取、验签、上传与 stable 人工晋级手册 |
| `templates/` | Clash Verge 四类增强模板与可选支付规则 |
| `scripts/set-credentials.sh` | 本地隐藏输入静态 IP 四元组 |
| `scripts/macos-json.js` | 基于 macOS 自带 JXA 的 JSON / 转义辅助工具 |
| `scripts/backup.sh` / `scripts/rollback.sh` | 按 deployment id 精确备份与回滚 |
| `scripts/verify.sh` | 六项验证与出口基线 |
| `scripts/selftest.sh` | 配置脚本烟雾测试 |
| `scripts/bootstrap-selftest.sh` | bootstrap 失败关闭与恢复测试 |
| `scripts/bootstrap-windows-selftest.ps1` | Windows 清单与签名证据失败关闭测试 |
| `scripts/windows-validation.ps1` | Windows 真机验签、自测与非秘密审计证据入口 |
| `scripts/windows-local-rc.ps1` | 已退役的 Windows 搬运 RC 兼容入口；失败关闭 |
| `scripts/windows-deepseek.ps1` | Windows 本地隐藏读取 Key、握手并启动隔离 DeepSeek Claude 会话 |
| `scripts/windows-routing.ps1` | Windows 本地隐藏输入 ISP、写入四类增强配置并建立安全备份 |
| `scripts/windows-verify.ps1` / `windows-rollback.ps1` | Windows 六项验证与按 deployment id 回滚 |
| `scripts/mirror/build-windows-validation-bundle.sh` | 已退役的兼容入口；拒绝生成大体积搬运包 |
| `scripts/mirror/` | macOS 发布机镜像抓取、验证、清单、OSS 上传和人工晋级工具 |
| `scripts/bootstrap-complete.sh` | Phase 6 非秘密完成标记；仍需父启动器独立六项复验 |
| `docs/validation-playbook.md` | v1.3.0 Mac / Windows 真机验收任务书 |
| `docs/troubleshooting.md` | 常见故障排查 |
| `docs/account-safety.md` | 账号与设备侧注意事项 |

---

> 本仓库仅作个人网络配置技术记录与学习交流。使用前请自行了解并遵守所在地法律法规及相关服务条款，风险自负。
