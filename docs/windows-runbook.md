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

## 非秘密审计证据（RC 可携带）

六项验证通过后，在已安装的 lane 目录内生成 schema 2 证据（只读安装产物与已装 Clash；不读订阅、四元组、Key 或出口基线内容）：

```powershell
$p = "$env:LOCALAPPDATA\claude-lane\releases\v1.3.0\scripts\windows-evidence.ps1"
& ([scriptblock]::Create((Get-Content $p -Raw -Encoding UTF8))) -ScriptRoot (Split-Path $p -Parent)
```

输出文件（当前用户 ACL）：

```text
%LOCALAPPDATA%\claude-lane\audit\win32-x64.json
# 或
%LOCALAPPDATA%\claude-lane\audit\win32-arm64.json
```

**只把这一个 `audit\<platform>.json` 回传给发布方。** 证据落盘前会扫描 `sk-…` 与 IPv4/IPv6 模式；匹配则失败关闭且不写文件。

当前实现仍必须在 Windows x64 与 ARM64 真机分别通过 PowerShell 语法、配置写入、回滚和出口实测，才能晋级 stable。

## Phase 6：退出临时模式并完成登录收尾

**只有六项验证已通过（`setup-progress.json` 状态为 `VALIDATION_PASSED`）后才能进入。** 在已安装 lane 目录内以内存脚本块运行（与 rollback / evidence 相同形态，不改 ExecutionPolicy）：

```powershell
$p = "$env:LOCALAPPDATA\claude-lane\releases\v1.3.0\scripts\windows-complete.ps1"
& ([scriptblock]::Create((Get-Content $p -Raw -Encoding UTF8))) -ScriptRoot (Split-Path $p -Parent)
```

仅复查 DeepSeek 残留、不写状态、不启动登录：

```powershell
$p = "$env:LOCALAPPDATA\claude-lane\releases\v1.3.0\scripts\windows-complete.ps1"
& ([scriptblock]::Create((Get-Content $p -Raw -Encoding UTF8))) -CheckOnly -ScriptRoot (Split-Path $p -Parent)
```

脚本严格按序执行，任一步失败即关闭且**不得登录 Anthropic**：

| 步骤 | 含义 |
|---|---|
| 前置门禁 | 状态必须是 `VALIDATION_PASSED`（schema 1、platform windows） |
| 残留检查 (b) | 当前进程、`Start-Process` 新起的干净 PowerShell、以及 User/Machine 级注册表环境三处，`windows-deepseek.ps1` 清单内 16 个环境变量均不存在（只报变量名，绝不打印值）；`%TEMP%` 无 `claude-lane-deepseek-*` 目录 |
| 正常登录 (c) | 校验受控 `claude.exe` 固定路径、SHA-256、Authenticode 后，用不注入任何 DeepSeek/`ANTHROPIC_*`/`CLAUDE_*` 临时变量的新进程启动，**此时用户才登录 Anthropic**；等待该进程退出 |
| 人工确认 (d) | 逐条 `Read-Host y/N`：活跃会话归属地与静态出口一致、已撤销不符旧会话、Privacy 两开关关闭、Windows 区域设置按 `docs/account-safety.md` 处理、知晓三条红线（不跑第二个 VPN / Clash 保持规则模式 / 先开 Clash 再开 Claude）。任一条非 `y` 即失败，不写完成状态 |
| 完成 (e) | 全部通过后写入 `COMPLETED`，并输出 `PHASE6 COMPLETED: windows` |

**残留检查失败时的处置**：不要带残留登录 Anthropic。先确认 DeepSeek 临时会话已退出并走完清理；必要时重启 PowerShell 或整机，再以 `-CheckOnly` 复查；`%TEMP%` 下若仍有 `claude-lane-deepseek-*` 目录可手动删除后重跑。禁止在残留未清时强行进入登录步骤。
