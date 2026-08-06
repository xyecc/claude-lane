# Windows 安装与恢复手册

Windows 启动器覆盖 Windows 10 1809+ 的 x64 与 ARM64，阶段顺序固定：

1. 从国内 OSS 下载并校验 Clash Verge Rev 与 `claude-lane`。
2. 安装 Clash Verge；没有远程订阅时保存 `WAITING_FOR_SUBSCRIPTION` 并正常暂停。
3. 用户只在 Clash Verge GUI 粘贴机场订阅，重新运行同一条安装命令。
4. 订阅检查点通过后，先下载并核对固定 SHA-256 的 Anthropic 小型版本元数据；失败时保存检查点，提示用户选择可用美国节点并开启 TUN 或系统代理。
5. 代理实测通过并保存 `PROXY_REACHABLE` 后，从 Anthropic 官方源下载固定版 Claude Code；后续 Agent 确认美国节点后才记录 `AIRPORT_VERIFIED`。
6. 强制核对 SHA-256、Authenticode 发布者和 `claude --version`。
7. 检查当前订阅的四类增强文件；缺失时保存 `WAITING_FOR_ENHANCEMENT_FILES`，用户在 Clash Verge 编辑器中原样保存后重跑。
8. 未准备 ISP 时保存 `WAITING_FOR_ISP`；准备好后，用户输入 GUI 中可见的美国节点名，并隐藏输入 ISP 四元组。
9. 原子写入四类托管配置并建立当前用户专属 ACL 备份，保存 `WAITING_FOR_ACTIVATION`；用户点击当前订阅卡片、开启 TUN、保持规则模式后重跑。
10. 执行六项验证；全部通过才保存 `VALIDATION_PASSED`，随后本地隐藏读取 DeepSeek API Key 并启动临时隔离会话。

## 安全边界

- 不把机场订阅、DeepSeek Key 或 ISP 四元组发给 Agent。
- 不修改 PowerShell ExecutionPolicy；启动器使用当前进程内的脚本块继续执行。
- 不使用未知下载站、GitHub 反代、`latest` 路径或关闭 Windows 安全功能。
- 已安装的用户 Claude Code 与 Clash Verge 保留；固定 Claude Code 使用 `%LOCALAPPDATA%\claude-lane\tools` 隔离目录。
- DeepSeek Key 只进入 Claude Code 子进程环境，退出后释放并删除临时配置。

## 固定暂停点

以下状态都不是安装失败；按屏幕提示处理后重新运行同一条 RC / stable 命令：

| 状态 | 用户动作 |
|---|---|
| `WAITING_FOR_SUBSCRIPTION` | 在 Clash Verge GUI 导入机场订阅 |
| `WAITING_FOR_ENHANCEMENT_FILES` | 在当前订阅卡片打开缺失的节点/分组/规则/Merge 编辑器并原样保存 |
| `WAITING_FOR_ISP` | 自行准备并付款购买静态住宅 ISP SOCKS5 |
| `WAITING_FOR_ACTIVATION` | 点击当前订阅卡片，开启 TUN，保持规则模式 |

## 本地配置与回滚

`windows-routing.ps1` 只接受用户在 Clash GUI 中看到的美国节点名；不读取或输出订阅 URL。host、port、username、password 四项均隐藏输入，写入前会确认目标是空骨架或已有唯一托管块，发现用户自有内容时停止，不擅自覆盖。

每轮写入都生成 deployment id 和受保护备份。需要回滚时在已安装 lane 目录内以内存脚本块运行，避免修改 PowerShell 执行策略：

```powershell
$p = "$env:LOCALAPPDATA\claude-lane\releases\v1.3.0\scripts\windows-rollback.ps1"
& ([scriptblock]::Create((Get-Content $p -Raw -Encoding UTF8))) -List -ScriptRoot (Split-Path $p -Parent)
& ([scriptblock]::Create((Get-Content $p -Raw -Encoding UTF8))) -DeploymentId "<deployment-id>" -ScriptRoot (Split-Path $p -Parent)
```

回滚不打印配置或凭证；完成后必须回到 Clash Verge 点击当前订阅卡片重新加载。

## 六项门禁

`windows-verify.ps1` 只输出通过/失败和打码出口，检查：Mihomo/TUN/规则模式、Claude/US-Chain 策略组、QUIC/进程/域名/遥测/IP 规则、Claude 与普通出口隔离、近期日志漏流、并行 Windows VPN。六项未全部通过，不启动 DeepSeek 会话，也不得宣布完成。

当前实现仍必须在 Windows x64 与 ARM64 真机分别通过 PowerShell 语法、配置写入、回滚和出口实测，才能晋级 stable。
