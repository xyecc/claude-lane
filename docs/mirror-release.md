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

## commit 绑定的 RC

真机验收不运行生产 `stable` 入口，也不临时解除它的门禁。先提交待验收代码，再用该 commit 的短 SHA 构建一次性候选入口：

```bash
candidate_id=$(git rev-parse --short=12 HEAD)
candidate_dir=".mirror-work/candidates/$candidate_id"

bash scripts/mirror/build-lane.sh --execute --work-dir "$candidate_dir"
bash scripts/mirror/generate-manifest.sh --execute \
  --status candidate --candidate-id "$candidate_id" --work-dir "$candidate_dir"
bash scripts/mirror/build-bootstrap-candidate.sh --execute --candidate-id "$candidate_id"
bash scripts/mirror/upload.sh --execute --profile primary \
  --scope candidate --candidate-id "$candidate_id"
```

执行前还需把已验签的 Claude 官方 manifest 与四个 Clash 制品放进该候选目录的既定路径。RC 入口只接受同一 commit ID 的 `candidate` manifest，并固定其 SHA-256；上传对象均禁止覆盖：

```text
manifests/candidates/<commit>.json
claude-lane/releases/candidates/<commit>/claude-lane.tar.gz
claude-lane/releases/candidates/<commit>/claude-lane.zip
claude-lane/releases/candidates/<commit>/install.sh
claude-lane/releases/candidates/<commit>/install.ps1
claude-lane/releases/candidates/<commit>/evidence.txt
```

RC 验收不修改 `manifests/stable.json`，也不上传正式 bootstrap 路径。

## OSS 上传

真实密钥只在权限为 `600` 的 `.env` 或 CI Secret 中提供。Bucket ACL 保持私有，只对发布对象设置 `public-read`。上传器以 V1 请求签名访问 OSS，同时设置 `x-oss-forbid-overwrite: true`；发现同名对象时先下载并比对 SHA-256，内容不同立即停止。

```bash
bash scripts/mirror/upload.sh --execute --profile primary --scope upstream
bash scripts/mirror/upload.sh --execute --profile primary --scope lane
```

`--scope bootstrap` 只在全部真机验收通过、stable manifest 已人工晋级后执行，不能用于 RC。

本轮只启用阿里云 OSS 主源。备用 OSS 使用 `CLAUDE_LANE_BACKUP_OSS_*` 和 `--profile backup`，维护者明确暂缓；启动器允许备用地址为空，但清单必须记录 `backup.enabled=false`。

## released 清单生成（证据门禁）

默认运行 `generate-manifest.sh` 只生成 `blocked` 清单；带 `--status candidate` 的 RC 清单也不能晋级。五机验收把非秘密证据 JSON 回传到发布 Mac 的同一目录后，用证据门禁生成 `released` 清单（缺任一文件、schema/platform/candidate_id/验证状态不匹配则立即失败关闭）：

```bash
candidate_id=<RC2十六进制id>
evidence_dir=.mirror-work/release-evidence/$candidate_id
# 目录内必须同时有：
#   win32-x64.json win32-arm64.json darwin-arm64.json darwin-x64.json clean-mac.json

bash scripts/mirror/generate-manifest.sh --execute \
  --status released \
  --candidate-id "$candidate_id" \
  --evidence-dir "$evidence_dir" \
  --output .mirror-work/manifests/stable.released.json
```

通过后门禁会：把 `release_status` 置为 `released`、清空 `release_blockers`、把 `claude_lane.path/windows_path` 改回正式 `releases/v<版本>/…` 路径、保留 `candidate_id` 供追溯，并写入 `release_evidence`（五份证据各自 sha256 + platform，不含证据正文）。摘要仍从本地 `.mirror-work` 制品重算。

## stable 人工晋级

完成主源回下载、两种 Windows 真机、两种 Mac 真机和无代理端到端验收，并已生成 `released` 清单后，由维护者审阅再显式运行：

```bash
bash scripts/mirror/promote-stable.sh --candidate .mirror-work/manifests/stable.released.json
bash scripts/mirror/promote-stable.sh --execute --candidate .mirror-work/manifests/stable.released.json --profile primary
```

晋级脚本要求清单已是 `released`、blocker 为空、主源为 HTTPS、签名状态合格且 Git 工作树干净。当前仓库不满足这些条件，拒绝晋级是预期结果。
