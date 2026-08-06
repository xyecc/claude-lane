#!/usr/bin/env bash
# RC-install non-secret audit evidence generator (schema 2) for macOS.
# Inputs come only from the local claude-lane install products and installed
# Clash Verge. Never reads profiles, credentials, keys, or exit IP baselines.

set -u
set -o pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
JSON_HELPER="$HERE/macos-json.js"
OSASCRIPT="/usr/bin/osascript"

INSTALL_ROOT="${CLAUDE_LANE_SETUP_ROOT:-$HOME/Library/Application Support/claude-lane}"
AUDIT_DIR="$INSTALL_ROOT/audit"
STATE_DIR="$INSTALL_ROOT/state"
CANDIDATE_MANIFEST="$STATE_DIR/candidate-manifest.json"
SETUP_STATE="$INSTALL_ROOT/setup-progress.json"
# Baseline path mirrors verify.sh; only existence is checked, content is never read.
CFG_DIR="${CLAUDE_LANE_CFG:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
BASELINE_PATH="$CFG_DIR/claude-lane-state.json"

PROBE_SECRET_FILE=""

usage() {
  cat <<'EOF'
用法：
  bash scripts/macos-evidence.sh
  bash scripts/macos-evidence.sh --probe-secret-file <path>
EOF
}

die() {
  printf '停止：%s\n' "$*" >&2
  exit 1
}

say() {
  printf '%s\n' "$*"
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --probe-secret-file)
      [ "$#" -ge 2 ] || die "--probe-secret-file 缺少路径"
      PROBE_SECRET_FILE=$2
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
  shift
done

[ "$(/usr/bin/uname -s)" = "Darwin" ] || die "本脚本只支持 macOS"
[ -x "$OSASCRIPT" ] || die "缺少 osascript"
[ -f "$JSON_HELPER" ] || die "缺少 macos-json.js"

assert_no_secrets() {
  text=$1
  printf '%s' "$text" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" assert-no-secrets >/dev/null ||
    die "证据内容命中秘密扫描规则；拒绝落盘"
}

write_evidence_file() {
  platform=$1
  json_text=$2
  assert_no_secrets "$json_text"
  /bin/mkdir -p "$AUDIT_DIR" || die "无法创建审计目录"
  /bin/chmod 700 "$AUDIT_DIR" || die "无法设置审计目录权限"
  evidence_path="$AUDIT_DIR/${platform}.json"
  tmp_path="$AUDIT_DIR/.${platform}.$$.$RANDOM.json"
  printf '%s\n' "$json_text" >"$tmp_path" || die "无法写入临时证据文件"
  /bin/chmod 600 "$tmp_path" || die "无法设置临时证据权限"
  /bin/mv -f -- "$tmp_path" "$evidence_path" || die "无法落盘证据文件"
  say "EVIDENCE_WRITTEN=$evidence_path"
  say "VALIDATION PASSED: $platform"
  say "Copy this single evidence file back to the publisher Mac: $evidence_path"
}

# Selftest-only path: attempt to persist a forged JSON through the secret gate.
if [ -n "$PROBE_SECRET_FILE" ]; then
  [ -f "$PROBE_SECRET_FILE" ] || die "ProbeSecretFile 不存在"
  probe_text=$(/bin/cat "$PROBE_SECRET_FILE") || die "无法读取 ProbeSecretFile"
  machine=$(/usr/bin/uname -m)
  case "$machine" in
    arm64) probe_platform="darwin-arm64" ;;
    x86_64) probe_platform="darwin-x64" ;;
    *) die "不支持的 macOS 架构：$machine" ;;
  esac
  write_evidence_file "$probe_platform" "$probe_text"
  exit 0
fi

[ -f "$CANDIDATE_MANIFEST" ] || die "缺少已校验候选 manifest：$CANDIDATE_MANIFEST"
[ -f "$SETUP_STATE" ] || die "缺少安装进度：$SETUP_STATE"
/usr/bin/plutil -convert xml1 -o /dev/null -- "$CANDIDATE_MANIFEST" >/dev/null 2>&1 ||
  die "候选 manifest 不是有效 JSON"
/usr/bin/plutil -convert xml1 -o /dev/null -- "$SETUP_STATE" >/dev/null 2>&1 ||
  die "安装进度不是有效 JSON"

manifest_sha=$(sha256_file "$CANDIDATE_MANIFEST") || die "无法计算 manifest SHA-256"
candidate_id=$(/usr/bin/plutil -extract candidate_id raw -o - "$CANDIDATE_MANIFEST" 2>/dev/null || true)
if [ -z "$candidate_id" ]; then
  candidate_id="released"
fi
claude_version=$(/usr/bin/plutil -extract claude_code.version raw -o - "$CANDIDATE_MANIFEST" 2>/dev/null) ||
  die "候选 manifest 缺少 claude_code.version"
clash_version=$(/usr/bin/plutil -extract clash_verge.version raw -o - "$CANDIDATE_MANIFEST" 2>/dev/null) ||
  die "候选 manifest 缺少 clash_verge.version"

machine=$(/usr/bin/uname -m)
case "$machine" in
  arm64)
    platform="darwin-arm64"
    host_arch="arm64"
    claude_manifest_key="claude_code.darwin_arm64.sha256"
    ;;
  x86_64)
    platform="darwin-x64"
    host_arch="x86_64"
    claude_manifest_key="claude_code.darwin_x86_64.sha256"
    ;;
  *)
    die "不支持的 macOS 架构：$machine"
    ;;
esac

claude_path="$INSTALL_ROOT/tools/claude-code/$claude_version/claude"
[ -f "$claude_path" ] || die "找不到已安装 Claude Code：$claude_version"
[ ! -L "$claude_path" ] || die "Claude Code 路径不能是符号链接"
claude_sha=$(sha256_file "$claude_path") || die "无法计算 Claude Code SHA-256"
expected_claude_sha=$(/usr/bin/plutil -extract "$claude_manifest_key" raw -o - "$CANDIDATE_MANIFEST" 2>/dev/null) ||
  die "候选 manifest 缺少 $claude_manifest_key"
claude_sha_lc=$(printf '%s' "$claude_sha" | /usr/bin/tr 'A-F' 'a-f')
expected_claude_sha_lc=$(printf '%s' "$expected_claude_sha" | /usr/bin/tr 'A-F' 'a-f')
[ "$claude_sha_lc" = "$expected_claude_sha_lc" ] ||
  die "已安装 Claude Code SHA-256 与候选 manifest 固定摘要不符"

/usr/bin/codesign --verify --strict --verbose=2 "$claude_path" >/dev/null 2>&1 ||
  die "Claude Code 的 codesign --verify 失败"
# spctl on a raw executable may report "rejected" on some systems; still record assess outcome.
spctl_status="assessed"
if /usr/sbin/spctl --assess --type execute --verbose=2 "$claude_path" >/dev/null 2>&1; then
  spctl_status="accepted"
else
  spctl_status="not-accepted"
fi
codesign_status="verified"

claude_version_output=$("$claude_path" --version 2>/dev/null | /usr/bin/head -n 1) ||
  die "无法读取 Claude Code 版本"
printf '%s' "$claude_version_output" | /usr/bin/grep -Fq "$claude_version" ||
  die "Claude Code 版本输出与固定版本不符"
# Strip characters that would break JSON string literals; evidence is non-secret status only.
claude_version_safe=$(printf '%s' "$claude_version_output" | /usr/bin/tr -cd 'A-Za-z0-9 ._-+()/' | /usr/bin/head -c 120)

clash_app="/Applications/Clash Verge.app"
[ -d "$clash_app" ] || die "找不到已安装的 Clash Verge"
[ ! -L "$clash_app" ] || die "Clash Verge 路径不能是符号链接"
clash_file_version=$(/usr/bin/defaults read "$clash_app/Contents/Info" CFBundleShortVersionString 2>/dev/null) ||
  die "无法读取 Clash Verge 版本"
printf '%s' "$clash_file_version" | /usr/bin/grep -Fq "$clash_version" ||
  die "Clash Verge 产品版本与固定版本不符"
clash_source="installed-app"

setup_schema=$(/usr/bin/plutil -extract schema raw -o - "$SETUP_STATE" 2>/dev/null) ||
  die "安装进度缺少 schema"
setup_platform=$(/usr/bin/plutil -extract platform raw -o - "$SETUP_STATE" 2>/dev/null) ||
  die "安装进度缺少 platform"
[ "$setup_schema" = "1" ] || die "安装进度 schema 无效"
[ "$setup_platform" = "darwin" ] || die "安装进度平台无效"
validation_state=$(/usr/bin/plutil -extract state raw -o - "$SETUP_STATE" 2>/dev/null) ||
  die "安装进度缺少 state"
[ "$validation_state" = "VALIDATION_PASSED" ] ||
  die "六项验证尚未通过（当前状态：${validation_state}）"

if [ -f "$BASELINE_PATH" ] && [ ! -L "$BASELINE_PATH" ]; then
  baseline_present="true"
else
  baseline_present="false"
fi

os_product=$(/usr/bin/sw_vers -productVersion 2>/dev/null || printf 'unknown')
os_build=$(/usr/bin/sw_vers -buildVersion 2>/dev/null || printf 'unknown')
os_product_safe=$(printf '%s' "$os_product" | /usr/bin/tr -cd '0-9.')
os_build_safe=$(printf '%s' "$os_build" | /usr/bin/tr -cd 'A-Za-z0-9')
generated_at=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
completed_at=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')

# Only fixed enums, versions, and digests enter the evidence JSON — no free-form secrets.
json_text=$(printf '%s' "{
  \"schema\": 2,
  \"platform\": \"${platform}\",
  \"generated_at\": \"${generated_at}\",
  \"host\": {
    \"os_version\": \"${os_product_safe}\",
    \"os_build\": \"${os_build_safe}\",
    \"arch\": \"${host_arch}\"
  },
  \"rc\": {
    \"candidate_id\": \"${candidate_id}\",
    \"manifest_sha256\": \"${manifest_sha}\"
  },
  \"claude_code\": {
    \"version\": \"${claude_version}\",
    \"sha256\": \"${claude_sha_lc}\",
    \"codesign\": {
      \"status\": \"${codesign_status}\",
      \"spctl\": \"${spctl_status}\"
    },
    \"version_output\": \"${claude_version_safe}\"
  },
  \"clash_verge\": {
    \"version\": \"${clash_version}\",
    \"install_source\": \"${clash_source}\"
  },
  \"validation\": {
    \"state\": \"VALIDATION_PASSED\",
    \"six_checks\": 6,
    \"private_baseline_present\": ${baseline_present}
  },
  \"completed_at\": \"${completed_at}\"
}")

write_evidence_file "$platform" "$json_text"
