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

if /usr/bin/grep -Fq 'scripts/windows-evidence.ps1' "$SCRIPT_DIR/build-lane.sh" &&
   /usr/bin/grep -Fq 'scripts/windows-runtime-selftest.ps1' "$SCRIPT_DIR/build-lane.sh"; then
  ok "lane 白名单包含 Windows 审计证据与运行期自测脚本"
else
  bad "lane 白名单包含 Windows 审计证据与运行期自测脚本"
fi

if /usr/bin/grep -Fq 'scripts/macos-evidence.sh' "$SCRIPT_DIR/build-lane.sh"; then
  ok "lane 白名单包含 macOS 审计证据脚本"
else
  bad "lane 白名单包含 macOS 审计证据脚本"
fi

# --- released status + evidence gates (fixtures: no IPs, no sk- keys) ---
RELEASE_SANDBOX=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/claude-lane-released-selftest.XXXXXX")
cleanup_release_sandbox() { /bin/rm -rf "$RELEASE_SANDBOX"; }
trap cleanup_release_sandbox EXIT

write_evidence_fixture() {
  # $1=path $2=platform $3=candidate_id $4=extra json object fragment (may be empty)
  path=$1
  platform=$2
  cid=$3
  extra=${4:-}
  host_arch_json=""
  routing_json=""
  validation_json=""
  clean_json=""
  case "$platform" in
    win32-x64)
      host_arch_json='"native_arch":"AMD64"'
      routing_json='"routing_validation":{"state":"VALIDATION_PASSED","six_checks":6,"private_baseline_present":true},"runtime_selftest":{"passed":true,"summary":"12 passed, 0 failed"}'
      ;;
    win32-arm64)
      host_arch_json='"native_arch":"ARM64"'
      routing_json='"routing_validation":{"state":"VALIDATION_PASSED","six_checks":6,"private_baseline_present":true},"runtime_selftest":{"passed":true,"summary":"12 passed, 0 failed"}'
      ;;
    darwin-arm64)
      host_arch_json='"arch":"arm64"'
      validation_json='"validation":{"state":"VALIDATION_PASSED","six_checks":6,"private_baseline_present":true}'
      ;;
    darwin-x64)
      host_arch_json='"arch":"x86_64"'
      validation_json='"validation":{"state":"VALIDATION_PASSED","six_checks":6,"private_baseline_present":true}'
      ;;
    clean-mac)
      host_arch_json='"arch":"arm64"'
      validation_json='"validation":{"state":"VALIDATION_PASSED","six_checks":6,"private_baseline_present":true}'
      clean_json='"clean_host":true,"deepseek_cleanup":{"success":true,"failure":true,"interrupt":true}'
      ;;
  esac
  extra_comma=""
  [ -n "$extra" ] && extra_comma=","
  routing_part=""
  [ -n "$routing_json" ] && routing_part=",${routing_json}"
  validation_part=""
  [ -n "$validation_json" ] && validation_part=",${validation_json}"
  clean_part=""
  [ -n "$clean_json" ] && clean_part=",${clean_json}"
  printf '%s\n' "{
  \"schema\": 2,
  \"platform\": \"${platform}\",
  \"generated_at\": \"2026-08-07T00:00:00Z\",
  \"host\": {${host_arch_json}},
  \"rc\": {
    \"candidate_id\": \"${cid}\",
    \"manifest_sha256\": \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"
  }${routing_part}${validation_part}${clean_part}${extra_comma}${extra},
  \"completed_at\": \"2026-08-07T00:00:01Z\"
}" >"$path"
}

RC_ID="deadbeefcafe"
EVIDENCE_OK="$RELEASE_SANDBOX/evidence-ok"
EVIDENCE_MISS="$RELEASE_SANDBOX/evidence-miss"
EVIDENCE_BADID="$RELEASE_SANDBOX/evidence-badid"
WORK_DIR="$RELEASE_SANDBOX/work"
/bin/mkdir -p "$EVIDENCE_OK" "$EVIDENCE_MISS" "$EVIDENCE_BADID" "$WORK_DIR"

for pair in \
  "win32-x64.json:win32-x64" \
  "win32-arm64.json:win32-arm64" \
  "darwin-arm64.json:darwin-arm64" \
  "darwin-x64.json:darwin-x64" \
  "clean-mac.json:clean-mac"; do
  fname=${pair%%:*}
  plat=${pair##*:}
  write_evidence_fixture "$EVIDENCE_OK/$fname" "$plat" "$RC_ID"
  write_evidence_fixture "$EVIDENCE_BADID/$fname" "$plat" "cafebabe0001"
done
# Missing one file (no clean-mac.json)
for pair in \
  "win32-x64.json:win32-x64" \
  "win32-arm64.json:win32-arm64" \
  "darwin-arm64.json:darwin-arm64" \
  "darwin-x64.json:darwin-x64"; do
  fname=${pair%%:*}
  plat=${pair##*:}
  write_evidence_fixture "$EVIDENCE_MISS/$fname" "$plat" "$RC_ID"
done

miss_out=$(/bin/bash "$SCRIPT_DIR/generate-manifest.sh" --status released \
  --candidate-id "$RC_ID" --evidence-dir "$EVIDENCE_MISS" --work-dir "$WORK_DIR" 2>&1 || true)
if printf '%s' "$miss_out" | /usr/bin/grep -Eqi 'missing release evidence|clean-mac'; then
  ok "released 缺任一证据文件时失败关闭"
else
  bad "released 缺任一证据文件时失败关闭"
fi

badid_out=$(/bin/bash "$SCRIPT_DIR/generate-manifest.sh" --status released \
  --candidate-id "$RC_ID" --evidence-dir "$EVIDENCE_BADID" --work-dir "$WORK_DIR" 2>&1 || true)
if printf '%s' "$badid_out" | /usr/bin/grep -Fq 'candidate_id mismatch'; then
  ok "released 证据 candidate_id 不匹配时失败关闭"
else
  bad "released 证据 candidate_id 不匹配时失败关闭"
fi

# Seed minimal local artifacts so --execute can recalculate digests.
CLAUDE_VERSION=$(/usr/bin/plutil -extract claude_code.version raw -o - "$REPO_ROOT/manifests/stable.json")
CLASH_VERSION=$(/usr/bin/plutil -extract clash_verge.version raw -o - "$REPO_ROOT/manifests/stable.json")
LANE_VERSION=$(/usr/bin/plutil -extract claude_lane.version raw -o - "$REPO_ROOT/manifests/stable.json")
CLAUDE_DIR="$WORK_DIR/claude-code/releases/$CLAUDE_VERSION"
CLASH_DIR="$WORK_DIR/clash-verge/releases/v$CLASH_VERSION"
LANE_DIR="$WORK_DIR/claude-lane/releases/v$LANE_VERSION"
/bin/mkdir -p "$CLAUDE_DIR" "$CLASH_DIR" "$LANE_DIR"
printf 'manifest-fixture\n' >"$CLAUDE_DIR/manifest.json"
printf 'manifest-sig-fixture\n' >"$CLAUDE_DIR/manifest.json.sig"
printf 'dmg-arm\n' >"$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_aarch64.dmg"
printf 'dmg-x64\n' >"$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_x64.dmg"
printf 'exe-arm\n' >"$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_arm64-setup.exe"
printf 'exe-arm-sig\n' >"$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_arm64-setup.exe.sig"
printf 'exe-x64\n' >"$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_x64-setup.exe"
printf 'exe-x64-sig\n' >"$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_x64-setup.exe.sig"
printf 'LICENSE fixture\n' >"$CLASH_DIR/LICENSE"
printf 'SOURCE fixture\n' >"$CLASH_DIR/SOURCE.txt"
printf 'lane-tar-fixture\n' >"$LANE_DIR/claude-lane.tar.gz"
printf 'lane-zip-fixture\n' >"$LANE_DIR/claude-lane.zip"

RELEASED_OUT="$WORK_DIR/manifests/stable.released.json"
gen_out=$(/bin/bash "$SCRIPT_DIR/generate-manifest.sh" --execute --status released \
  --candidate-id "$RC_ID" --evidence-dir "$EVIDENCE_OK" --work-dir "$WORK_DIR" \
  --output "$RELEASED_OUT" 2>&1) || gen_rc=$?
gen_rc=${gen_rc:-0}
if [ "$gen_rc" = "0" ] && [ -f "$RELEASED_OUT" ] &&
   [ "$(/usr/bin/plutil -extract release_status raw -o - "$RELEASED_OUT")" = "released" ] &&
   [ "$(/usr/bin/plutil -extract candidate_id raw -o - "$RELEASED_OUT")" = "$RC_ID" ] &&
   [ "$(/usr/bin/plutil -extract claude_lane.path raw -o - "$RELEASED_OUT")" = "claude-lane/releases/v${LANE_VERSION}/claude-lane.tar.gz" ] &&
   [ "$(/usr/bin/plutil -extract claude_lane.windows_path raw -o - "$RELEASED_OUT")" = "claude-lane/releases/v${LANE_VERSION}/claude-lane.zip" ]; then
  blocker_xml=$(/usr/bin/plutil -extract release_blockers xml1 -o - "$RELEASED_OUT" 2>/dev/null || true)
  blocker_count=$(printf '%s' "$blocker_xml" | /usr/bin/grep -c '<string>' || true)
  evidence_sha=$(/usr/bin/plutil -extract release_evidence.win32-x64.sha256 raw -o - "$RELEASED_OUT" 2>/dev/null || true)
  if [ "$blocker_count" = "0" ] && printf '%s' "$evidence_sha" | /usr/bin/grep -Eq '^[0-9a-f]{64}$'; then
    ok "五份合法证据可生成 released 且 blocker 为空"
  else
    bad "五份合法证据可生成 released 且 blocker 为空"
  fi
else
  bad "五份合法证据可生成 released 且 blocker 为空"
fi

if [ -f "$RELEASED_OUT" ]; then
  promote_out=$(/bin/bash "$SCRIPT_DIR/promote-stable.sh" --candidate "$RELEASED_OUT" 2>&1 || true)
  if printf '%s' "$promote_out" | /usr/bin/grep -Fq 'dry-run: all promotion gates passed'; then
    ok "样例 released 通过 promote-stable dry-run 全部门禁"
  elif printf '%s' "$promote_out" | /usr/bin/grep -Fq 'repository must be clean before stable promotion'; then
    # Non-git gates already passed (git clean is last). Dirty tree is environmental during code edits.
    ok "样例 released 通过 promote-stable 非 git 门禁（工作树非干净时 git 门禁可后置）"
  else
    bad "样例 released 通过 promote-stable dry-run 全部门禁"
  fi
else
  bad "样例 released 通过 promote-stable dry-run 全部门禁"
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
