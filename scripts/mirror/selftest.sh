#!/bin/bash

set -u
set -o pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

if /usr/bin/plutil -convert xml1 -o /dev/null "$REPO_ROOT/manifests/stable.json" >/dev/null 2>&1; then ok "stable manifest JSON 可解析"; else bad "stable manifest JSON 可解析"; fi
if [ "$(/usr/bin/plutil -extract release_status raw -o - "$REPO_ROOT/manifests/stable.json")" = blocked ]; then ok "stable manifest 默认阻断"; else bad "stable manifest 默认阻断"; fi
if /usr/bin/grep -Fqx 'EXPECTED_RELEASE_STATUS="released"' "$REPO_ROOT/bootstrap.sh" &&
   /usr/bin/grep -Fqx '$ExpectedReleaseStatus = "released"' "$REPO_ROOT/bootstrap.ps1"; then
  ok "生产 bootstrap 只接受 released"
else
  bad "生产 bootstrap 只接受 released"
fi

for key in clash_verge.arm64 clash_verge.x86_64 clash_verge.win32_arm64 clash_verge.win32_x64; do
  path=$(/usr/bin/plutil -extract "$key.path" raw -o - "$REPO_ROOT/manifests/stable.json" 2>/dev/null || true)
  sha=$(/usr/bin/plutil -extract "$key.sha256" raw -o - "$REPO_ROOT/manifests/stable.json" 2>/dev/null || true)
  case "$path" in *latest*|http*|/*|*../*) bad "$key 使用不可变相对路径"; continue ;; esac
  if printf '%s' "$sha" | /usr/bin/grep -Eq '^[0-9a-f]{64}$'; then ok "$key 使用不可变相对路径与 SHA-256"; else bad "$key 使用不可变相对路径与 SHA-256"; fi
done

for key in claude_code.darwin_arm64 claude_code.darwin_x86_64 claude_code.win32_arm64 claude_code.win32_x64; do
  sha=$(/usr/bin/plutil -extract "$key.sha256" raw -o - "$REPO_ROOT/manifests/stable.json" 2>/dev/null || true)
  url=$(/usr/bin/plutil -extract "$key.official_url" raw -o - "$REPO_ROOT/manifests/stable.json" 2>/dev/null || true)
  if printf '%s' "$sha" | /usr/bin/grep -Eq '^[0-9a-f]{64}$' && printf '%s' "$url" | /usr/bin/grep -Eq '^https://downloads\.claude\.ai/claude-code-releases/[0-9]+\.[0-9]+\.[0-9]+/'; then
    ok "$key 固定官方 URL 与签名 manifest SHA-256"
  else
    bad "$key 固定官方 URL 与签名 manifest SHA-256"
  fi
done

upload_output=$(/bin/bash "$SCRIPT_DIR/upload.sh" --file /tmp/x --key clash-verge/releases/1/x 2>&1)
if printf '%s' "$upload_output" | /usr/bin/grep -Fq 'dry-run'; then ok "上传器默认 dry-run"; else bad "上传器默认 dry-run"; fi
promote_output=$(/bin/bash "$SCRIPT_DIR/promote-stable.sh" --candidate "$REPO_ROOT/manifests/stable.json" 2>&1 || true)
if printf '%s' "$promote_output" | /usr/bin/grep -Fq 'promotion refused'; then ok "blocked stable 无法晋级"; else bad "blocked stable 无法晋级"; fi
candidate_output=$(/bin/bash "$SCRIPT_DIR/generate-manifest.sh" --work-dir "/tmp/claude-lane-candidate-path-test" 2>&1)
if printf '%s' "$candidate_output" | /usr/bin/grep -Fq '/tmp/claude-lane-candidate-path-test/manifests/stable.candidate.json'; then
  ok "候选 manifest 默认输出跟随 --work-dir"
else
  bad "候选 manifest 默认输出跟随 --work-dir"
fi
rc_output=$(/bin/bash "$SCRIPT_DIR/build-bootstrap-candidate.sh" --candidate-id "$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)" 2>&1)
if /bin/bash -n "$SCRIPT_DIR/build-bootstrap-candidate.sh" &&
   printf '%s' "$rc_output" | /usr/bin/grep -Fq 'dry-run: no RC bootstrap entries built' &&
   /usr/bin/grep -Fq 'EXPECTED_RELEASE_STATUS="candidate"' "$SCRIPT_DIR/build-bootstrap-candidate.sh" &&
   /usr/bin/grep -Fq 'manifests/candidates/' "$SCRIPT_DIR/build-bootstrap-candidate.sh"; then
  ok "RC bootstrap 构建器绑定 candidate 状态、commit 路径与 manifest 摘要"
else
  bad "RC bootstrap 构建器绑定 candidate 状态、commit 路径与 manifest 摘要"
fi
candidate_upload_output=$(/bin/bash "$SCRIPT_DIR/upload.sh" --scope candidate --candidate-id deadbee 2>&1)
if printf '%s' "$candidate_upload_output" | /usr/bin/grep -Fq 'dry-run'; then ok "RC 上传器默认 dry-run"; else bad "RC 上传器默认 dry-run"; fi
if /usr/bin/grep -Fq 'claude-lane/releases/candidates/$CANDIDATE_ID/claude-lane.tar.gz' "$SCRIPT_DIR/generate-manifest.sh" &&
   /usr/bin/grep -Fq 'claude-lane/releases/candidates/$CANDIDATE_ID/claude-lane.zip' "$SCRIPT_DIR/upload.sh"; then
  ok "RC lane 归档使用 commit 专属不可覆盖路径"
else
  bad "RC lane 归档使用 commit 专属不可覆盖路径"
fi
if /usr/bin/grep -Fq 'x-oss-forbid-overwrite: true' "$SCRIPT_DIR/upload.sh"; then ok "OSS 上传显式禁止覆盖"; else bad "OSS 上传显式禁止覆盖"; fi
if /usr/bin/grep -Fq 'x-oss-object-acl: public-read' "$SCRIPT_DIR/upload.sh"; then ok "OSS 正式对象使用逐对象 public-read"; else bad "OSS 正式对象使用逐对象 public-read"; fi
if ! /usr/bin/grep -Eq '(ACCESS_KEY_SECRET=.{8,}|ANTHROPIC_AUTH_TOKEN=.{8,}|sk-[A-Za-z0-9]{12,})' "$REPO_ROOT/manifests/stable.json" "$REPO_ROOT/bootstrap.sh" "$REPO_ROOT/bootstrap.ps1"; then ok "发布清单与启动器无明文凭据"; else bad "发布清单与启动器无明文凭据"; fi
if ! /usr/bin/grep -Eq 'Unblock-File|ExecutionPolicy' "$REPO_ROOT/bootstrap.ps1" &&
   /usr/bin/grep -Fq '[scriptblock]::Create((Get-Content -LiteralPath $CheckpointScript -Raw -Encoding UTF8))' "$REPO_ROOT/bootstrap.ps1"; then
  ok "Windows 不解除下载阻止且在已校验归档内存执行"
else
  bad "Windows 不解除下载阻止且在已校验归档内存执行"
fi
if ! /usr/bin/grep -Eqi 'github\.com|npmjs|brew\.sh|homebrew' "$REPO_ROOT/bootstrap.sh" "$REPO_ROOT/bootstrap.ps1" &&
   /usr/bin/grep -Fq 'anthropic-official-after-proxy' "$REPO_ROOT/bootstrap.sh" "$REPO_ROOT/bootstrap.ps1"; then
  ok "客户端仅在代理后使用固定 Anthropic 官方下载源"
else
  bad "客户端仅在代理后使用固定 Anthropic 官方下载源"
fi

if /usr/bin/grep -Fq 'manifests/stable.json and publisher tooling also avoids a circular digest' "$SCRIPT_DIR/build-lane.sh" &&
   /usr/bin/grep -Fq -- "--mtime='1970-01-01T00:00:00Z'" "$SCRIPT_DIR/build-lane.sh" &&
   /usr/bin/grep -Fq 'HEAD_TREE=$(git rev-parse' "$SCRIPT_DIR/build-lane.sh" &&
   /usr/bin/grep -Fq 'scripts/windows-routing.ps1' "$SCRIPT_DIR/build-lane.sh" &&
   /usr/bin/grep -Fq 'scripts/windows-verify.ps1' "$SCRIPT_DIR/build-lane.sh" &&
   /usr/bin/grep -Fq 'scripts/windows-rollback.ps1' "$SCRIPT_DIR/build-lane.sh" &&
   /usr/bin/grep -Fq 'scripts/windows-deepseek.ps1' "$SCRIPT_DIR/build-lane.sh"; then
  ok "lane 归档使用运行时白名单并规避清单哈希循环"
else
  bad "lane 归档使用运行时白名单并规避清单哈希循环"
fi

if /bin/bash -n "$SCRIPT_DIR/build-windows-validation-bundle.sh" &&
   /bin/bash "$SCRIPT_DIR/build-windows-validation-bundle.sh" 2>&1 | /usr/bin/grep -Fq 'retired' &&
   ! /bin/bash "$SCRIPT_DIR/build-windows-validation-bundle.sh" --execute >/dev/null 2>&1; then
  ok "239MB Windows 搬运包已退役且不能重新生成"
else
  bad "239MB Windows 搬运包已退役且不能重新生成"
fi

printf '\nmirror selftest: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
