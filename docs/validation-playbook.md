# v1.3.0 真机验收任务书

验证对象固定为 GitHub 分支 `codex/bootstrap-v1.3.0`。验证期间不合并 `main`、不更新 stable、不跳过签名或发布门禁。

## 安全边界

- 不把 DeepSeek Key、机场订阅、静态 IP 四元组、完整 Clash 配置或真实出口 IP 写进结果文件、聊天或 Git。
- macOS 严格按根目录 `RUNBOOK.md` 的 Phase -1～6 执行；命中 STOP 就停止并按 deployment id 回滚。
- Windows 不使用执行策略绕过、不关闭系统安全。Claude Code 必须通过 Authenticode；Clash Verge Rev 必须通过固定 SHA-256、上游 Tauri minisign 与原生版本检查，并记录其 Authenticode 实际状态。
- `.mirror-work/windows-audit/*.json` 是可以回收的非秘密证据；原始配置和日志不是。

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

当前 stable 是 `blocked`，不得通过测试注入参数把生产 `bootstrap.sh` 当作已发布启动器运行。无依赖干净 Mac 的 Bootstrap 端到端验收要等主源候选制品就绪后执行。

## Windows x64 / ARM64

不再生成或传输大体积 Windows 验证 ZIP。stable 入口发布前，发布者把同一份 `bootstrap.ps1` 作为候选脚本放到受控 Windows x64 与 ARM64 主机；stable 发布后，用户入口为：

```powershell
irm https://claude-lane-release-prod-20260802-k7m3q9.oss-cn-beijing.aliyuncs.com/claude-lane/releases/bootstrap/v1/install.ps1 | iex
```

该命令目前仅表示最终固定路径，`manifests/stable.json` 仍为 `blocked` 时不得执行。候选验证必须确认：系统临时目录下载、架构自动识别、Clash 固定 SHA-256、上游 Tauri minisign、运行时 Authenticode、安装成功和订阅检查点全部成立。

没有订阅时保存 `WAITING_FOR_SUBSCRIPTION` 并正常结束；用户在 Clash Verge GUI 本地导入后，重新运行同一命令。代理通过后才允许从 Anthropic 官方固定版 URL 下载 Claude Code，并强制核对 SHA-256、Authenticode 和版本。随后才隐藏读取 DeepSeek API Key、完成文本握手并进入临时 Claude Code 会话。它不自动修改 Windows 专线路由。

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

把对应非秘密审计文件复制回发布 Mac 的 `.mirror-work/windows-audit/`：

```text
win32-x64.json
win32-arm64.json
```

Windows 专线路由当前仍按 `docs/porting.md` 人工处理。

## 验收矩阵

| 项目 | 通过证据 |
|---|---|
| Apple Silicon Mac | RUNBOOK 六项全绿、DeepSeek 清理、正常 Claude 登录 |
| Intel Mac | 原生 `claude-darwin-x64 --version` 与完整规定测试 |
| Windows x64 | `windows-audit/win32-x64.json`，含 Authenticode 与 Bootstrap 自测 |
| Windows ARM64 | `windows-audit/win32-arm64.json`，含 Authenticode 与 Bootstrap 自测 |
| 干净 Mac Bootstrap | 无预装依赖端到端成功，成功/失败/中断均无临时凭证残留 |
| 国内分发 | 阿里云 OSS 主源公开对象上传、匿名回下载、同一 SHA-256 |

全部完成后才能清空 blocker、把 candidate 改为 `released`、晋级 stable、合并 `main` 并打 v1.3.0 标签。
