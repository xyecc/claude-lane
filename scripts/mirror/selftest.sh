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

for key in claude_code.darwin_arm64 claude_code.darwin_x86_64 claude_code.win32_arm64 claude_code.win32_x64 clash_verge.arm64 clash_verge.x86_64 clash_verge.win32_arm64 clash_verge.win32_x64; do
  path=$(/usr/bin/plutil -extract "$key.path" raw -o - "$REPO_ROOT/manifests/stable.json" 2>/dev/null || true)
  sha=$(/usr/bin/plutil -extract "$key.sha256" raw -o - "$REPO_ROOT/manifests/stable.json" 2>/dev/null || true)
  case "$path" in *latest*|http*|/*|*../*) bad "$key 使用不可变相对路径"; continue ;; esac
  if printf '%s' "$sha" | /usr/bin/grep -Eq '^[0-9a-f]{64}$'; then ok "$key 使用不可变相对路径与 SHA-256"; else bad "$key 使用不可变相对路径与 SHA-256"; fi
done

upload_output=$(/bin/bash "$SCRIPT_DIR/upload.sh" --file /tmp/x --key claude-code/releases/1/x 2>&1)
if printf '%s' "$upload_output" | /usr/bin/grep -Fq 'dry-run'; then ok "上传器默认 dry-run"; else bad "上传器默认 dry-run"; fi
promote_output=$(/bin/bash "$SCRIPT_DIR/promote-stable.sh" --candidate "$REPO_ROOT/manifests/stable.json" 2>&1 || true)
if printf '%s' "$promote_output" | /usr/bin/grep -Fq 'promotion refused'; then ok "blocked stable 无法晋级"; else bad "blocked stable 无法晋级"; fi
if /usr/bin/grep -Fq 'x-oss-forbid-overwrite: true' "$SCRIPT_DIR/upload.sh"; then ok "OSS 上传显式禁止覆盖"; else bad "OSS 上传显式禁止覆盖"; fi
if ! /usr/bin/grep -Eq '(ACCESS_KEY_SECRET=.{8,}|ANTHROPIC_AUTH_TOKEN=.{8,}|sk-[A-Za-z0-9]{12,})' "$REPO_ROOT/manifests/stable.json" "$REPO_ROOT/bootstrap.sh" "$REPO_ROOT/bootstrap.ps1"; then ok "发布清单与启动器无明文凭据"; else bad "发布清单与启动器无明文凭据"; fi
if ! /usr/bin/grep -Eq 'downloads\.claude\.ai|github\.com|npmjs|brew\.sh|homebrew' "$REPO_ROOT/bootstrap.sh" "$REPO_ROOT/bootstrap.ps1"; then ok "客户端启动器不含官方海外下载域名"; else bad "客户端启动器不含官方海外下载域名"; fi
if /usr/bin/grep -Fq 'manifests/stable.json and publisher tooling also avoids a circular digest' "$SCRIPT_DIR/build-lane.sh" &&
   /usr/bin/grep -Fq -- "--mtime='1970-01-01T00:00:00Z'" "$SCRIPT_DIR/build-lane.sh" &&
   /usr/bin/grep -Fq 'HEAD_TREE=$(git rev-parse' "$SCRIPT_DIR/build-lane.sh" &&
   /usr/bin/grep -Fq 'scripts/set-credentials.sh scripts/verify.sh templates' "$SCRIPT_DIR/build-lane.sh"; then
  ok "lane 归档使用运行时白名单并规避清单哈希循环"
else
  bad "lane 归档使用运行时白名单并规避清单哈希循环"
fi
if /bin/bash -n "$SCRIPT_DIR/build-windows-validation-bundle.sh" &&
   /bin/bash "$SCRIPT_DIR/build-windows-validation-bundle.sh" 2>&1 | /usr/bin/grep -Fq 'dry-run: no bundle created' &&
   /usr/bin/grep -Fq 'scripts/windows-validation.ps1' "$SCRIPT_DIR/build-windows-validation-bundle.sh" &&
   /usr/bin/grep -Fq 'scripts/windows-local-rc.ps1' "$SCRIPT_DIR/build-windows-validation-bundle.sh" &&
   /usr/bin/grep -Fq 'scripts/windows-deepseek.ps1' "$SCRIPT_DIR/build-windows-validation-bundle.sh" &&
   /usr/bin/grep -Fq 'VALIDATION PASSED' "$REPO_ROOT/scripts/windows-validation.ps1" &&
   /usr/bin/grep -Fq 'RC INSTALL PASSED' "$REPO_ROOT/scripts/windows-local-rc.ps1" &&
   /usr/bin/grep -Fq 'SecureStringToBSTR' "$REPO_ROOT/scripts/windows-deepseek.ps1" &&
   /usr/bin/grep -Fq 'ZeroFreeBSTR' "$REPO_ROOT/scripts/windows-deepseek.ps1" &&
   /usr/bin/grep -Fq "printf '\\357\\273\\277'" "$SCRIPT_DIR/build-windows-validation-bundle.sh" &&
   /usr/bin/grep -Fq 'bootstrap_selftest.passed' "$SCRIPT_DIR/generate-manifest.sh" &&
   /usr/bin/grep -Fq 'host.manifest_sha256' "$SCRIPT_DIR/generate-manifest.sh"; then
  ok "Windows 真机验证包默认 dry-run，审计证据绑定固定清单与自测"
else
  bad "Windows 真机验证包默认 dry-run，审计证据绑定固定清单与自测"
fi

printf '\nmirror selftest: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
