# v1.3.0 真机验收任务书

验证对象固定为 GitHub 分支 `codex/bootstrap-v1.3.0`。验证期间不合并 `main`、不更新 stable、不跳过签名或发布门禁。

## 安全边界

- 不把 DeepSeek Key、机场订阅、静态 IP 四元组、完整 Clash 配置或真实出口 IP 写进结果文件、聊天或 Git。
- macOS 严格按根目录 `RUNBOOK.md` 的 Phase -1～6 执行；命中 STOP 就停止并按 deployment id 回滚。
- Windows 不使用执行策略绕过、不关闭系统安全。Claude Code 必须通过 Authenticode；Clash Verge Rev 必须通过固定 SHA-256、上游 Tauri minisign 与原生版本检查，并记录其 Authenticode 实际状态。
- RC 真机证据写在 `%LOCALAPPDATA%\claude-lane\audit\<platform>.json`（schema 2，当前用户 ACL）；只回传这一个文件。原始配置、日志和出口基线不是可回收证据。

## Apple Silicon Mac

先确认代码与架构：

```bash
git switch codex/bootstrap-v1.3.0
git pull --ff-only
uname -m
git status --short --branch
```

预期为 `arm64` 且工作树干净。发布者侧非交互检查：

```bash
bash scripts/selftest.sh
bash scripts/bootstrap-selftest.sh
bash scripts/mirror/selftest.sh
bash scripts/mirror/verify-artifacts.sh
```

真实专线路由实验必须由执行 Agent 完整读取 `RUNBOOK.md` 后，从 Phase -1 开始。Phase 5 六项全绿、Phase 6 清理完成、普通 `claude` 不再指向 DeepSeek，且用户完成正常登录，才记录 Apple Silicon 通过。

当前 stable 是 `blocked`，不得通过测试注入参数把生产 `bootstrap.sh` 当作已发布启动器运行。发布者提供 commit 绑定的 RC 地址后，Apple Silicon 与 Intel Mac 分别执行该地址；入口只接受对应 commit 的候选清单。

```bash
curl -fL "https://claude-lane-release-prod-20260802-k7m3q9.oss-cn-beijing.aliyuncs.com/claude-lane/releases/candidates/<commit>/install.sh" -o /tmp/claude-lane-rc.sh
shasum -a 256 /tmp/claude-lane-rc.sh
bash /tmp/claude-lane-rc.sh
```

先把显示的摘要与发布者提供的 `evidence.txt` 对照；不一致立即停止。

## Windows x64 / ARM64

不再生成或传输大体积 Windows 验证 ZIP。stable 入口发布前，两种 Windows 真机直接下载同一 commit 的 RC：

```powershell
$id = "<commit>"
$base = "https://claude-lane-release-prod-20260802-k7m3q9.oss-cn-beijing.aliyuncs.com/claude-lane/releases/candidates/$id"
Invoke-WebRequest "$base/install.ps1" -OutFile "$env:TEMP\claude-lane-rc.ps1"
Invoke-WebRequest "$base/evidence.txt" -OutFile "$env:TEMP\claude-lane-evidence.txt"
$expected = ((Select-String '^install_ps1_sha256=' "$env:TEMP\claude-lane-evidence.txt").Line -split '=', 2)[1]
$actual = (Get-FileHash "$env:TEMP\claude-lane-rc.ps1" -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw "RC 启动器 SHA-256 不匹配" }
& ([scriptblock]::Create((Get-Content "$env:TEMP\claude-lane-rc.ps1" -Raw -Encoding UTF8)))
```

先将哈希与 evidence 中的 `install_ps1_sha256` 对照。不得使用 `ExecutionPolicy Bypass`、`Unblock-File` 或关闭 SmartScreen。stable 发布后，用户入口才是：

```powershell
irm https://claude-lane-release-prod-20260802-k7m3q9.oss-cn-beijing.aliyuncs.com/claude-lane/releases/bootstrap/v1/install.ps1 | iex
```

最终命令目前仅表示固定路径，`manifests/stable.json` 仍为 `blocked` 时不得执行。候选验证必须确认：系统临时目录下载、架构自动识别、Clash 固定 SHA-256、上游 Tauri minisign、运行时 Authenticode、安装成功和订阅检查点全部成立。

没有订阅时保存 `WAITING_FOR_SUBSCRIPTION` 并正常结束；用户在 Clash Verge GUI 本地导入后，重新运行同一命令。代理通过后才允许从 Anthropic 官方固定版 URL 下载 Claude Code，并强制核对 SHA-256、Authenticode 和版本。随后按 `WAITING_FOR_ENHANCEMENT_FILES`、`WAITING_FOR_ISP`、`WAITING_FOR_ACTIVATION` 三个固定卡点完成本地路由；六项验证全绿后才隐藏读取 DeepSeek API Key、完成文本握手并进入临时 Claude Code 会话。

等待订阅的成功暂停标志：

```text
SETUP_STATE=WAITING_FOR_SUBSCRIPTION
```

通过订阅检查点后才会出现 DeepSeek Key 隐藏输入。

DeepSeek 会话只开放 Read/Edit/Write，不开放 Bash；Key 只进入 Claude 子进程环境，不写当前 PowerShell 环境、参数、文件或历史。退出后自动删除临时配置。以后再次启动：

```powershell
& "$env:LOCALAPPDATA\claude-lane\bin\start-deepseek.cmd"
```

一台机器只记录自身原生架构。成功标志为：

```text
VALIDATION PASSED: win32-x64
```

或：

```text
VALIDATION PASSED: win32-arm64
```

六项验证全绿后，在 RC 安装环境运行审计证据入口（无 Git、无仓库、无 `.mirror-work`）：

```powershell
$p = "$env:LOCALAPPDATA\claude-lane\releases\v1.3.0\scripts\windows-evidence.ps1"
& ([scriptblock]::Create((Get-Content $p -Raw -Encoding UTF8))) -ScriptRoot (Split-Path $p -Parent)
```

成功时输出 `VALIDATION PASSED: win32-x64` 或 `win32-arm64`，并写入：

```text
%LOCALAPPDATA%\claude-lane\audit\win32-x64.json
%LOCALAPPDATA%\claude-lane\audit\win32-arm64.json
```

**用户只把对应架构的单个 `audit\<platform>.json` 文件回传给发布 Mac**（不要回传配置、日志或 private-state）。发布侧也可运行 `scripts/windows-validation.ps1`，它复用同一 evidence 生成逻辑。

Windows 真机还必须验证：四元组不回显、受保护备份可恢复、用户自有增强文件冲突时失败关闭、GUI 激活后六项验证均通过。任一项失败都不得生成 `VALIDATION PASSED` 审计证据。

## 验收矩阵

| 项目 | 通过证据 |
|---|---|
| Apple Silicon Mac | RUNBOOK 六项全绿、DeepSeek 清理、正常 Claude 登录 |
| Intel Mac | 原生 `claude-darwin-x64 --version` 与完整规定测试 |
| Windows x64 | `%LOCALAPPDATA%\claude-lane\audit\win32-x64.json`（schema 2：Authenticode、运行期自测、路由六项） |
| Windows ARM64 | `%LOCALAPPDATA%\claude-lane\audit\win32-arm64.json`（schema 2：同上） |
| 干净 Mac Bootstrap | 无预装依赖端到端成功，成功/失败/中断均无临时凭证残留 |
| 国内分发 | 阿里云 OSS 主源公开对象上传、匿名回下载、同一 SHA-256 |

全部完成后才能清空 blocker、把 candidate 改为 `released`、晋级 stable、合并 `main` 并打 v1.3.0 标签。
