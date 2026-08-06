# 国内镜像发布手册

发布机环境：macOS 13+、系统 Bash 3.2；额外需要 GnuPG 和 minisign。Windows 运行时签名必须在真实 Windows x64 与 ARM64 主机上复验。所有脚本默认 dry-run，只有 `--execute` 才产生下载、归档或上传。

## 固定基线

| 产品 | 版本 | 平台 |
|---|---:|---|
| Claude Code | `2.1.220` | darwin-arm64、darwin-x64、win32-arm64、win32-x64 |
| Clash Verge Rev | `2.5.2` | macOS arm64 / x64 DMG、Windows ARM64 / x64 setup EXE |
| claude-lane | `1.3.0` | tar.gz、zip |

没有建立 Claude Code 面向公众镜像二进制的再分发授权。因此 Claude Code 不上传 OSS、GitHub Release 或公开 CDN；发布脚本只抓取并核验官方签名 manifest。目标机在订阅代理可用后从 Anthropic 官方固定版本 URL 下载。Clash Verge Rev 同步原始制品、GPL-3.0 许可证和固定 tag 源码链接。

## 发布顺序

先检查 dry-run，再执行官方抓取与验证：

```bash
bash scripts/mirror/fetch-claude-code.sh
bash scripts/mirror/fetch-clash-verge.sh
bash scripts/mirror/upload.sh --scope upstream

bash scripts/mirror/fetch-claude-code.sh --execute
bash scripts/mirror/fetch-clash-verge.sh --execute
bash scripts/mirror/verify-artifacts.sh
```

大体积 Windows 搬运验证包已经退役。两种 Windows 真机直接使用 OSS 候选启动入口进行端到端验证；Intel 版 Claude Code 的 `--version` 仍需在原生 Intel Mac 上复验。

lane 包只能从干净、已审阅并已提交的工作树构建。归档使用运行时文件白名单，不包含外层启动器、`manifests/stable.json` 或发布者工具，避免 manifest 与归档摘要互相引用：

```bash
bash scripts/mirror/build-lane.sh --execute
bash scripts/mirror/generate-manifest.sh --execute
```

## OSS 上传

真实密钥只在权限为 `600` 的 `.env` 或 CI Secret 中提供。Bucket ACL 保持私有，只对发布对象设置 `public-read`。上传器以 V1 请求签名访问 OSS，同时设置 `x-oss-forbid-overwrite: true`；发现同名对象时先下载并比对 SHA-256，内容不同立即停止。

```bash
bash scripts/mirror/upload.sh --execute --profile primary --scope upstream
bash scripts/mirror/upload.sh --execute --profile primary --scope lane
bash scripts/mirror/upload.sh --execute --profile primary --scope bootstrap
```

本轮只启用阿里云 OSS 主源。备用 OSS 使用 `CLAUDE_LANE_BACKUP_OSS_*` 和 `--profile backup`，维护者明确暂缓；启动器允许备用地址为空，但清单必须记录 `backup.enabled=false`。

## stable 人工晋级

`generate-manifest.sh` 只生成 `.mirror-work/manifests/stable.candidate.json`，不会自动改成 released。完成主源回下载、两种 Windows 真机、两种 Mac 真机和无代理端到端验收后，由维护者审阅并清空全部 blocker，再显式运行：

```bash
bash scripts/mirror/promote-stable.sh --candidate .mirror-work/manifests/stable.candidate.json
bash scripts/mirror/promote-stable.sh --execute --candidate .mirror-work/manifests/stable.candidate.json --profile primary
```

晋级脚本要求清单已是 `released`、blocker 为空、主源为 HTTPS、签名状态合格且 Git 工作树干净。当前仓库不满足这些条件，拒绝晋级是预期结果。
