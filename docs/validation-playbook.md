# v1.3.0 真机验收任务书

验证对象固定为 GitHub 分支 `codex/bootstrap-v1.3.0`。验证期间不合并 `main`、不更新 stable、不跳过签名或发布门禁。

## 安全边界

- 不把 DeepSeek Key、机场订阅、静态 IP 四元组、完整 Clash 配置或真实出口 IP 写进结果文件、聊天或 Git。
- macOS 严格按根目录 `RUNBOOK.md` 的 Phase -1～6 执行；命中 STOP 就停止并按 deployment id 回滚。
- Windows 不使用执行策略绕过、不关闭系统安全、不跳过 Authenticode。
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

当前 stable 是 `blocked`，不得通过测试注入参数把生产 `bootstrap.sh` 当作已发布启动器运行。无依赖干净 Mac 的 Bootstrap 端到端验收要等主备下载网关和候选制品就绪后执行。

## Windows x64 / ARM64

在发布 Mac 上生成搬运包：

```bash
bash scripts/mirror/build-windows-validation-bundle.sh --execute
```

把下面两个文件复制到 Windows，先核对 `.sha256`，再解压 ZIP：

```text
.mirror-work/validation/claude-lane-windows-validation.zip
.mirror-work/validation/claude-lane-windows-validation.zip.sha256
```

Windows PowerShell 校验命令：

```powershell
$Expected = ((Get-Content .\claude-lane-windows-validation.zip.sha256) -split '\s+')[0].ToLowerInvariant()
$Actual = (Get-FileHash .\claude-lane-windows-validation.zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Actual -ne $Expected) { throw "Windows 验证包 SHA-256 不匹配" }
```

在解压目录打开 PowerShell：

```powershell
$env:PROCESSOR_ARCHITECTURE
powershell.exe -NoProfile -File .\scripts\windows-validation.ps1
```

一台机器只记录自身原生架构。成功标志为：

```text
VALIDATION PASSED: win32-x64
```

或：

```text
VALIDATION PASSED: win32-arm64
```

把对应文件复制回发布 Mac 的 `.mirror-work/windows-audit/`：

```text
win32-x64.json
win32-arm64.json
```

验证脚本不会安装 Clash 或修改 Windows 路由；正式安装链要在受控下载网关发布后另做端到端验收。Windows 专线路由当前仍按 `docs/porting.md` 人工处理。

## 验收矩阵

| 项目 | 通过证据 |
|---|---|
| Apple Silicon Mac | RUNBOOK 六项全绿、DeepSeek 清理、正常 Claude 登录 |
| Intel Mac | 原生 `claude-darwin-x64 --version` 与完整规定测试 |
| Windows x64 | `windows-audit/win32-x64.json`，含 Authenticode 与 Bootstrap 自测 |
| Windows ARM64 | `windows-audit/win32-arm64.json`，含 Authenticode 与 Bootstrap 自测 |
| 干净 Mac Bootstrap | 无预装依赖端到端成功，成功/失败/中断均无临时凭证残留 |
| 国内分发 | 主备独立故障域上传、回下载、同一 SHA-256、受控 HTTPS 网关 |

全部完成后才能清空 blocker、把 candidate 改为 `released`、晋级 stable、合并 `main` 并打 v1.3.0 标签。
