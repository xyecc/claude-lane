# 国内镜像发布手册

发布机环境：macOS 13+、系统 Bash 3.2；额外需要 GnuPG 和 minisign。Windows Authenticode 必须在真实 Windows x64 与 ARM64 主机上复验。所有脚本默认 dry-run，只有 `--execute` 才产生下载、归档或上传。

## 固定基线

| 产品 | 版本 | 平台 |
|---|---:|---|
| Claude Code | `2.1.212` | darwin-arm64、darwin-x64、win32-arm64、win32-x64 |
| Clash Verge Rev | `2.5.2` | macOS arm64 / x64 DMG、Windows ARM64 / x64 setup EXE |
| claude-lane | `1.3.0` | tar.gz、zip |

Anthropic 官方安装文档提到组织可通过自己的渠道分发固定版本，但没有由此建立本项目面向公众镜像二进制的授权。因此 Claude Code 当前只能进入私有 OSS / 受控缓存，不能上传到 GitHub Release 或公开 CDN。Clash Verge Rev 同步原始制品、GPL-3.0 许可证和固定 tag 源码链接。

## 发布顺序

```bash
bash scripts/mirror/fetch-claude-code.sh
bash scripts/mirror/fetch-clash-verge.sh
bash scripts/mirror/upload.sh --scope upstream
```

确认 dry-run 输出后下载并验证：

```bash
bash scripts/mirror/fetch-claude-code.sh --execute
bash scripts/mirror/fetch-clash-verge.sh --execute
bash scripts/mirror/verify-artifacts.sh
```

把 `.mirror-work` 安全传到两种真实 Windows 发布机，在各自主机运行：

```powershell
powershell.exe -NoProfile -File scripts\mirror\verify-artifacts.ps1
powershell.exe -NoProfile -File scripts\bootstrap-windows-selftest.ps1
```

两个审计 JSON 都回收到 `.mirror-work/windows-audit/` 后，才允许生成候选清单。Intel 版 Claude Code 的 `--version` 仍需在原生 Intel Mac 上复验。lane 包只能从干净、已审阅并已提交的工作树构建；归档使用运行时文件白名单，不包含外层启动器、`manifests/stable.json` 或发布者工具，从而避免 manifest 与归档摘要互相引用：

```bash
bash scripts/mirror/build-lane.sh --execute
bash scripts/mirror/generate-manifest.sh --execute
```

## OSS 上传

真实密钥只在权限为 `600` 的 `.env` 或 CI Secret 中提供。上传器以 V1 请求签名访问私有 OSS，设置 `x-oss-forbid-overwrite: true`；发现同名对象时先下载并比对 SHA-256，内容不同立即停止。

```bash
bash scripts/mirror/upload.sh --execute --profile primary --scope upstream
bash scripts/mirror/upload.sh --execute --profile primary --scope lane
```

备用 OSS 使用 `CLAUDE_LANE_BACKUP_OSS_*` 环境项和 `--profile backup`。目前备用存储未配置，不能晋级 stable。

## stable 人工晋级

`generate-manifest.sh` 只生成 `.mirror-work/manifests/stable.candidate.json`，不会把状态改成 released。完成主备回下载、两种 Windows 真机、两种 Mac 真机和无代理端到端验收后，由维护者审阅并清空全部 blocker、填写两个受控 HTTPS 网关，再显式运行：

```bash
bash scripts/mirror/promote-stable.sh --candidate .mirror-work/manifests/stable.candidate.json
bash scripts/mirror/promote-stable.sh --execute --candidate .mirror-work/manifests/stable.candidate.json --profile primary
```

晋级脚本要求清单已是 `released`、blocker 为空、主备网关均为 HTTPS、Windows 四项 Authenticode 全部 verified 且 Git 工作树干净。当前仓库不满足这些条件，拒绝晋级是预期结果。
