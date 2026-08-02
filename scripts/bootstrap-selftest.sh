#!/bin/bash

# Failure-closed tests for bootstrap.sh. Every bootstrap invocation is either
# --help or --dry-run; this suite never mounts a DMG, opens an app, or reads the
# real Clash Verge configuration.

set -u
set -o pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BOOTSTRAP="$REPO_DIR/bootstrap.sh"
TMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/claude-lane-bootstrap-selftest.XXXXXX") || exit 1
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  cleanup_status=$?
  case "$TMP_ROOT" in
    "${TMPDIR:-/tmp}"/claude-lane-bootstrap-selftest.*|/tmp/claude-lane-bootstrap-selftest.*)
      /bin/rm -rf -- "$TMP_ROOT" 2>/dev/null || true
      ;;
  esac
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS  %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL  %s\n' "$1" >&2
}

expect_success() {
  test_name=$1
  expected_text=$2
  shift 2
  output_file="$TMP_ROOT/output-$PASS_COUNT-$FAIL_COUNT.txt"
  "$@" >"$output_file" 2>&1
  test_status=$?
  if [ "$test_status" = "0" ] && /usr/bin/grep -Fq -- "$expected_text" "$output_file"; then
    pass "$test_name"
  else
    fail "$test_name"
    /usr/bin/sed -n '1,8p' "$output_file" >&2
  fi
}

expect_failure() {
  test_name=$1
  expected_text=$2
  shift 2
  output_file="$TMP_ROOT/output-$PASS_COUNT-$FAIL_COUNT.txt"
  "$@" >"$output_file" 2>&1
  test_status=$?
  if [ "$test_status" != "0" ] && /usr/bin/grep -Fq -- "$expected_text" "$output_file"; then
    pass "$test_name"
  else
    fail "$test_name"
    /usr/bin/sed -n '1,8p' "$output_file" >&2
  fi
}

test_bootstrap() {
  /usr/bin/env \
    CL_BOOT_TEST_MODE=1 \
    CL_BOOT_TEST_UNAME_S=Darwin \
    CL_BOOT_TEST_UNAME_M=arm64 \
    CL_BOOT_TEST_MACOS_VERSION=14.0 \
    CL_BOOT_TEST_FREE_MB=8192 \
    /bin/bash "$BOOTSTRAP" --dry-run --manifest-file "$1"
}

VALID_MANIFEST="$TMP_ROOT/valid.json"
cat >"$VALID_MANIFEST" <<'JSON'
{
  "schema": 1,
  "release_status": "released",
  "minimum_macos": "13.0",
  "required_free_mb": 2048,
  "claude_lane": {
    "version": "1.3.0",
    "path": "claude-lane/releases/v1.3.0/claude-lane.tar.gz",
    "archive_root": "claude-lane-1.3.0",
    "sha256": "1111111111111111111111111111111111111111111111111111111111111111"
  },
  "claude_code": {
    "version": "2.1.212",
    "manifest_gpg_fingerprint": "31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE",
    "darwin_arm64": {
      "path": "claude-code/releases/2.1.212/claude-darwin-arm64",
      "sha256": "09ecba2ab2df9b6ee5b0695e26f65dea60fb3b6af3d3542ee09f466838d1e574"
    },
    "darwin_x86_64": {
      "path": "claude-code/releases/2.1.212/claude-darwin-x64",
      "sha256": "7681a0634c89fa4474e53c0c794e992944aebf3409a7a2b87ea9f9b0194ea341"
    },
    "win32_arm64": {
      "path": "claude-code/releases/2.1.212/claude-win32-arm64.exe",
      "sha256": "adaa6e3dadb8016755ccd1907a5f249c1bc9bdb6c71d3f7dcea7d5db8f72d0a5",
      "signature_status": "verified-authenticode"
    },
    "win32_x64": {
      "path": "claude-code/releases/2.1.212/claude-win32-x64.exe",
      "sha256": "fe639693fd7e9a881c799867711abb7666dec2a5fefbaba41af6a09e71bcbefa",
      "signature_status": "verified-authenticode"
    }
  },
  "clash_verge": {
    "version": "2.5.2",
    "arm64": {
      "path": "clash-verge/releases/v2.5.2/Clash.Verge_2.5.2_aarch64.dmg",
      "sha256": "94d29405980b5d1d3419dd1de485db3a234d35cef058f79dcce595e01b697219"
    },
    "x86_64": {
      "path": "clash-verge/releases/v2.5.2/Clash.Verge_2.5.2_x64.dmg",
      "sha256": "c9fcec27d3e4b4fffe31f314369aaa4017d80c1293c8b1cb65d85de223e9cb6c"
    },
    "win32_arm64": {
      "path": "clash-verge/releases/v2.5.2/Clash.Verge_2.5.2_arm64-setup.exe",
      "sha256": "973fafb5f154e541b34c1315f7de7440daf68d05f2e52fa08da2bcc71b6c3214",
      "signature_status": "verified-authenticode"
    },
    "win32_x64": {
      "path": "clash-verge/releases/v2.5.2/Clash.Verge_2.5.2_x64-setup.exe",
      "sha256": "ba42f00b1082e352352080170fe86ae411bcc854cb13f1b8bebc9025e8a7cbf4",
      "signature_status": "verified-authenticode"
    }
  }
}
JSON

copy_and_replace() {
  target_file=$1
  key_path=$2
  value_type=$3
  value=$4
  /bin/cp "$VALID_MANIFEST" "$target_file" || return 1
  /usr/bin/plutil -replace "$key_path" -"$value_type" "$value" "$target_file"
}

if /bin/bash -n "$BOOTSTRAP"; then
  pass "bootstrap.sh 通过 Bash 语法检查"
else
  fail "bootstrap.sh 通过 Bash 语法检查"
fi

if /bin/bash -n "$REPO_DIR/scripts/bootstrap-complete.sh"; then
  pass "bootstrap 完成标记脚本通过 Bash 语法检查"
else
  fail "bootstrap 完成标记脚本通过 Bash 语法检查"
fi

MARK_HOME="$TMP_ROOT/mark-home"
MARK_ID="20260802-120000"
MARK_FILE="$MARK_HOME/Library/Application Support/claude-lane/bootstrap-status/complete.$MARK_ID"
mark_output=$(/usr/bin/env HOME="$MARK_HOME" CLAUDE_LANE_DEPLOY_ID="$MARK_ID" \
  CLAUDE_LANE_COMPLETION_FILE="$MARK_FILE" /bin/bash "$REPO_DIR/scripts/bootstrap-complete.sh" 2>&1)
mark_status=$?
if [ "$mark_status" = "0" ] && [ "$(/usr/bin/head -n 1 "$MARK_FILE" 2>/dev/null)" = "$MARK_ID" ] && \
   [ "$(/usr/bin/stat -f '%Lp' "$MARK_FILE" 2>/dev/null)" = "600" ] && \
   printf '%s' "$mark_output" | /usr/bin/grep -Fq 'BOOTSTRAP_PHASE6_MARKED'; then
  pass "bootstrap 完成标记原子写入且权限为 600"
else
  fail "bootstrap 完成标记原子写入且权限为 600"
fi

if /usr/bin/env HOME="$MARK_HOME" CLAUDE_LANE_DEPLOY_ID=invalid \
  CLAUDE_LANE_COMPLETION_FILE="$MARK_FILE.invalid" /bin/bash "$REPO_DIR/scripts/bootstrap-complete.sh" >/dev/null 2>&1; then
  fail "bootstrap 完成标记拒绝无效 deployment id"
else
  pass "bootstrap 完成标记拒绝无效 deployment id"
fi

expect_success "--help 不触发发布流程" "当前 stable 发布块尚未配置" \
  /bin/bash "$BOOTSTRAP" --help

expect_failure "正式路径在国内源占位时失败关闭" "国内主备下载源尚未发布" \
  /bin/bash "$BOOTSTRAP" --dry-run

formal_output="$TMP_ROOT/formal-output.txt"
/bin/bash "$BOOTSTRAP" --dry-run >"$formal_output" 2>&1 || true
if ! /usr/bin/grep -Fq '下载 ' "$formal_output"; then
  pass "发布块失败发生在任何下载前"
else
  fail "发布块失败发生在任何下载前"
fi

expect_failure "manifest 注入离开测试模式即拒绝" "只允许在 CL_BOOT_TEST_MODE=1" \
  /bin/bash "$BOOTSTRAP" --dry-run --manifest-file "$VALID_MANIFEST"

expect_failure "测试模式禁止真实安装" "测试模式只允许 --dry-run" \
  /usr/bin/env CL_BOOT_TEST_MODE=1 /bin/bash "$BOOTSTRAP" --manifest-file "$VALID_MANIFEST"

expect_success "有效 arm64 manifest dry-run 通过" "dry-run 通过" \
  test_bootstrap "$VALID_MANIFEST"

expect_success "有效 x86_64 manifest dry-run 通过" "架构：x86_64" \
  /usr/bin/env CL_BOOT_TEST_MODE=1 CL_BOOT_TEST_UNAME_S=Darwin CL_BOOT_TEST_UNAME_M=x86_64 \
    CL_BOOT_TEST_MACOS_VERSION=14.0 CL_BOOT_TEST_FREE_MB=8192 \
    /bin/bash "$BOOTSTRAP" --dry-run --manifest-file "$VALID_MANIFEST"

expect_failure "非 macOS 平台停止" "只支持 macOS" \
  /usr/bin/env CL_BOOT_TEST_MODE=1 CL_BOOT_TEST_UNAME_S=Linux CL_BOOT_TEST_UNAME_M=arm64 \
    CL_BOOT_TEST_MACOS_VERSION=14.0 CL_BOOT_TEST_FREE_MB=8192 \
    /bin/bash "$BOOTSTRAP" --dry-run --manifest-file "$VALID_MANIFEST"

blocked_manifest="$TMP_ROOT/blocked.json"
copy_and_replace "$blocked_manifest" release_status string blocked
expect_failure "未发布 manifest 停止" "尚未达到 released" test_bootstrap "$blocked_manifest"

placeholder_manifest="$TMP_ROOT/placeholder.json"
copy_and_replace "$placeholder_manifest" claude_lane.sha256 string TBD
expect_failure "仓库包摘要占位停止" "claude-lane SHA-256 尚未发布" test_bootstrap "$placeholder_manifest"

schema_manifest="$TMP_ROOT/schema.json"
copy_and_replace "$schema_manifest" schema integer 2
expect_failure "未知 schema 停止" "不支持的 manifest schema" test_bootstrap "$schema_manifest"

claude_hash_manifest="$TMP_ROOT/claude-hash.json"
copy_and_replace "$claude_hash_manifest" claude_code.darwin_arm64.sha256 string 1111111111111111111111111111111111111111111111111111111111111111
expect_failure "Claude Code 固定摘要漂移停止" "arm64 摘要不匹配" test_bootstrap "$claude_hash_manifest"

clash_hash_manifest="$TMP_ROOT/clash-hash.json"
copy_and_replace "$clash_hash_manifest" clash_verge.x86_64.sha256 string 1111111111111111111111111111111111111111111111111111111111111111
expect_failure "未选架构的 Clash 摘要漂移也停止" "x86_64 摘要不匹配" test_bootstrap "$clash_hash_manifest"

windows_hash_manifest="$TMP_ROOT/windows-hash.json"
copy_and_replace "$windows_hash_manifest" claude_code.win32_x64.sha256 string 1111111111111111111111111111111111111111111111111111111111111111
expect_failure "Windows 固定摘要漂移也阻止完整矩阵发布" "Windows x64 摘要不匹配" test_bootstrap "$windows_hash_manifest"

windows_signature_manifest="$TMP_ROOT/windows-signature.json"
copy_and_replace "$windows_signature_manifest" clash_verge.win32_arm64.signature_status string pending-windows-arm64
expect_failure "Windows 真机签名证据缺失阻止完整矩阵发布" "Windows arm64 尚未通过真实 Windows 签名验证" test_bootstrap "$windows_signature_manifest"

fingerprint_manifest="$TMP_ROOT/fingerprint.json"
copy_and_replace "$fingerprint_manifest" claude_code.manifest_gpg_fingerprint string 0000000000000000000000000000000000000000
expect_failure "Claude Code GPG 指纹漂移停止" "GPG 指纹不匹配" test_bootstrap "$fingerprint_manifest"

unsafe_path_manifest="$TMP_ROOT/unsafe-path.json"
copy_and_replace "$unsafe_path_manifest" claude_lane.path string https://evil.invalid/archive.tar.gz
expect_failure "manifest 不能重定向到其他域名" "claude-lane 路径无效" test_bootstrap "$unsafe_path_manifest"

latest_path_manifest="$TMP_ROOT/latest-path.json"
copy_and_replace "$latest_path_manifest" claude_lane.path string claude-lane/releases/latest/claude-lane.tar.gz
expect_failure "manifest 拒绝 latest 路径" "claude-lane 路径无效" test_bootstrap "$latest_path_manifest"

old_macos_output="$TMP_ROOT/old-macos.txt"
/usr/bin/env CL_BOOT_TEST_MODE=1 CL_BOOT_TEST_UNAME_S=Darwin CL_BOOT_TEST_UNAME_M=arm64 \
  CL_BOOT_TEST_MACOS_VERSION=12.6 CL_BOOT_TEST_FREE_MB=8192 \
  /bin/bash "$BOOTSTRAP" --dry-run --manifest-file "$VALID_MANIFEST" >"$old_macos_output" 2>&1
old_macos_status=$?
if [ "$old_macos_status" != "0" ] && /usr/bin/grep -Fq '需要 macOS 13.0' "$old_macos_output"; then
  pass "macOS 13 最低版本门禁"
else
  fail "macOS 13 最低版本门禁"
fi

disk_output="$TMP_ROOT/disk.txt"
/usr/bin/env CL_BOOT_TEST_MODE=1 CL_BOOT_TEST_UNAME_S=Darwin CL_BOOT_TEST_UNAME_M=arm64 \
  CL_BOOT_TEST_MACOS_VERSION=14.0 CL_BOOT_TEST_FREE_MB=512 \
  /bin/bash "$BOOTSTRAP" --dry-run --manifest-file "$VALID_MANIFEST" >"$disk_output" 2>&1
disk_status=$?
if [ "$disk_status" != "0" ] && /usr/bin/grep -Fq '磁盘空间不足' "$disk_output"; then
  pass "磁盘空间门禁"
else
  fail "磁盘空间门禁"
fi

invalid_json="$TMP_ROOT/invalid.json"
printf '{invalid json\n' >"$invalid_json"
expect_failure "无效 JSON 停止" "manifest 不是有效 JSON" test_bootstrap "$invalid_json"

expect_failure "缺失测试 manifest 停止" "测试 manifest 不存在" \
  /usr/bin/env CL_BOOT_TEST_MODE=1 /bin/bash "$BOOTSTRAP" --dry-run --manifest-file "$TMP_ROOT/missing.json"

if ! /usr/bin/grep -Eq '(^|[^A-Za-z])(python3?|jq|brew|npm|git clone)([^A-Za-z]|$)' "$BOOTSTRAP"; then
  pass "启动器无 Git/Homebrew/Node/Python/jq 运行依赖"
else
  fail "启动器无 Git/Homebrew/Node/Python/jq 运行依赖"
fi

if ! /usr/bin/grep -Eq 'declare[[:space:]]+-A|mapfile|readarray|\$\{[^}]*,,[^}]*\}' "$BOOTSTRAP"; then
  pass "启动器未使用 Bash 4 专属语法"
else
  fail "启动器未使用 Bash 4 专属语法"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 秘密隔离与归档安全的回归测试（v1.3.0 主审补充）
# ─────────────────────────────────────────────────────────────────────────────

# [P0 回归] DeepSeek Key 绝不能作为 env 的赋值参数出现——那会进 argv，全机 ps 可见
if /usr/bin/grep -Eq 'ANTHROPIC_AUTH_TOKEN=("?\$|"\$\{)' "$BOOTSTRAP"; then
  fail "Key 不得写成 env/命令的赋值参数（会进 argv 被 ps 看到）"
else
  pass "Key 不得写成 env/命令的赋值参数（会进 argv 被 ps 看到）"
fi

# [P0 回归] Key 必须经文件描述符交给内层 shell，且不得走 heredoc/here-string（会落临时文件）
if /usr/bin/grep -Fq 'read -r ANTHROPIC_AUTH_TOKEN <&3' "$BOOTSTRAP" && \
   ! /usr/bin/grep -Fq '<<<"$DEPLOY_DEEPSEEK_KEY"' "$BOOTSTRAP"; then
  pass "Key 经 fd 3 传入且未使用 here-string"
else
  fail "Key 经 fd 3 传入且未使用 here-string"
fi

# [P0 回归] bash 3.2 + set -u 下空数组必须用 ${arr[@]+"${arr[@]}"} 展开，否则握手必崩
# 安全写法 ${arr[@]+"${arr[@]}"} 内部本来就含 "${arr[@]}"，所以不能只搜后者。
# 判据：出现 _turn_args[@] 的行，必须同时出现 [@]+ 这个默认值展开标记。
if /usr/bin/awk '
  /_turn_args\[@\]/ && !/_turn_args\[@\]\+/ { bad=1 }
  END { exit bad+0 }
' "$BOOTSTRAP"; then
  pass "turn_args 必须用 bash 3.2 安全展开（裸 \"\${arr[@]}\" 在 set -u 下会崩）"
else
  fail "turn_args 必须用 bash 3.2 安全展开（裸 \"\${arr[@]}\" 在 set -u 下会崩）"
fi

# 平台行为钉子：确认「空数组 + set -u 会 unbound」这个前提在本机成立，
# 上面那条静态检查才有意义。若哪天 /bin/bash 升级到 4+，这里会提醒重新评估。
if /bin/bash -c 'set -u; a=(); printf "%s" "${a[@]}"' >/dev/null 2>&1; then
  fail "平台前提：系统 bash 在 set -u 下展开空数组应报错"
else
  pass "平台前提：系统 bash 在 set -u 下展开空数组应报错"
fi

# [P0 回归] DMG attach 成功即登记，挂载点解析失败时 cleanup 仍能卸载
if /usr/bin/grep -Fq 'ATTACHED_DMG="$clash_dmg"' "$BOOTSTRAP" && \
   /usr/bin/grep -Fq 'hdiutil detach "$ATTACHED_DMG"' "$BOOTSTRAP"; then
  pass "DMG attach 成功即登记，cleanup 可按镜像兜底卸载"
else
  fail "DMG attach 成功即登记，cleanup 可按镜像兜底卸载"
fi

# [P1 回归] 子进程环境剥离必须实测，不能只设变量
if /usr/bin/grep -Fq 'CLAUDE_LANE_SCRUB_LEAK' "$BOOTSTRAP" && \
   /usr/bin/grep -Fq 'CLAUDE_LANE_SCRUB_OK' "$BOOTSTRAP"; then
  pass "握手阶段实测 Bash 工具子进程已剥离 Key"
else
  fail "握手阶段实测 Bash 工具子进程已剥离 Key"
fi

# [P1 回归] 正式路径不能由 ditto 直接写入：同目录暂存、校验、mv 才能避免半安装。
if /usr/bin/grep -Fq 'PENDING_CLAUDE_INSTALL="$tools_root/.claude.installing.$$"' "$BOOTSTRAP" && \
   /usr/bin/grep -Fq '/bin/mv -- "$PENDING_CLAUDE_INSTALL" "$installed_claude"' "$BOOTSTRAP" && \
   ! /usr/bin/grep -Fq 'ditto "$STAGED_CLAUDE" "$installed_claude"' "$BOOTSTRAP"; then
  pass "Claude Code 使用同目录暂存与原子启用"
else
  fail "Claude Code 使用同目录暂存与原子启用"
fi

if /usr/bin/grep -Fq 'PENDING_LANE_INSTALL="$release_parent/.v${lane_version}.installing.$$"' "$BOOTSTRAP" && \
   /usr/bin/grep -Fq '/bin/mv -- "$PENDING_LANE_INSTALL" "$release_target"' "$BOOTSTRAP" && \
   ! /usr/bin/grep -Fq 'ditto "$STAGED_LANE" "$release_target"' "$BOOTSTRAP"; then
  pass "claude-lane 使用同目录暂存与原子启用"
else
  fail "claude-lane 使用同目录暂存与原子启用"
fi

if /usr/bin/grep -Fq 'PENDING_CLASH_INSTALL="/Applications/.claude-lane-Clash-Verge.installing.$$.app"' "$BOOTSTRAP" && \
   /usr/bin/grep -Fq 'verify_app_signature "$PENDING_CLASH_INSTALL" "暂存 Clash Verge"' "$BOOTSTRAP" && \
   ! /usr/bin/grep -Fq 'ditto "$mounted_app" "$CLASH_APP"' "$BOOTSTRAP"; then
  pass "Clash Verge 使用同目录暂存、验签与原子启用"
else
  fail "Clash Verge 使用同目录暂存、验签与原子启用"
fi

if /usr/bin/grep -Fq 'scripts/bootstrap-complete.sh' "$BOOTSTRAP" && \
   /usr/bin/grep -Fq 'completion_value=' "$BOOTSTRAP" && \
   /usr/bin/grep -Fq 'verify_independently' "$BOOTSTRAP"; then
  pass "普通 Claude 前要求 Phase 6 标记与独立复验"
else
  fail "普通 Claude 前要求 Phase 6 标记与独立复验"
fi

if /usr/bin/grep -Fq 'scripts/profile-config.sh scripts/macos-json.js' "$BOOTSTRAP" && \
   /usr/bin/grep -Fq 'scripts/bootstrap-complete.sh templates/1-proxies.yaml' "$BOOTSTRAP" && \
   /usr/bin/grep -Fq 'docs/troubleshooting.md docs/account-safety.md docs/porting.md' "$BOOTSTRAP"; then
  pass "仓库包安装前检查运行必需脚本与模板"
else
  fail "仓库包安装前检查运行必需脚本与模板"
fi

if /usr/bin/grep -Fq 'NORMAL_CLAUDE="$INSTALLED_CLAUDE"' "$BOOTSTRAP" && \
   /usr/bin/grep -Fq 'exec "$NORMAL_CLAUDE" --setting-sources "" --strict-mcp-config' "$BOOTSTRAP"; then
  pass "正常登录使用受控二进制并忽略用户 provider 设置"
else
  fail "正常登录使用受控二进制并忽略用户 provider 设置"
fi

strict_mcp_count=$(/usr/bin/grep -c -- '--strict-mcp-config' "$BOOTSTRAP" || true)
if [ "$strict_mcp_count" -ge 6 ]; then
  pass "固定 CLI 预检及所有 Claude 启动均隔离用户 MCP"
else
  fail "固定 CLI 预检及所有 Claude 启动均隔离用户 MCP"
fi

if ! /usr/bin/grep -Fq -- '--allowedTools "Bash(bash scripts/verify.sh' "$BOOTSTRAP"; then
  pass "verify 与配置写入不自动批准，保留用户权限确认"
else
  fail "verify 与配置写入不自动批准，保留用户权限确认"
fi

EXEC_SIG_BODY=$(/usr/bin/sed -n '/^verify_executable_signature() {/,/^}/p' "$BOOTSTRAP")
if printf '%s' "$EXEC_SIG_BODY" | /usr/bin/grep -Fq 'EXPECTED_CLAUDE_TEAM_ID' && \
   printf '%s' "$EXEC_SIG_BODY" | /usr/bin/grep -Fq 'EXPECTED_CLAUDE_IDENTIFIER' && \
   ! printf '%s' "$EXEC_SIG_BODY" | /usr/bin/grep -Fq 'spctl'; then
  pass "Claude 单文件二进制用 codesign 身份校验而非 App Gatekeeper"
else
  fail "Claude 单文件二进制用 codesign 身份校验而非 App Gatekeeper"
fi

# ── validate_archive 的功能测试：直接抽取 bootstrap.sh 里的真函数来跑，
#    不在测试里复制一份实现（复制品会和真代码悄悄漂移）。
ARCH_WORK="$TMP_ROOT/arch-work"
/bin/mkdir -p "$ARCH_WORK"
build_archive_harness() {
  harness_file=$1
  {
    printf '#!/bin/bash\nset -u\n'
    printf 'die() { printf "%%s\\n" "$*"; exit 1; }\n'
    printf 'BOOT_TMP=%s\n' "$ARCH_WORK"
    printf 'lane_root=claude-lane-1.3.0\n'
    /usr/bin/sed -n '/^validate_archive() {/,/^}/p' "$BOOTSTRAP"
    printf 'validate_archive "$1"\n'
    printf 'printf "ARCHIVE_ACCEPTED\\n"\n'
  } >"$harness_file"
}
ARCH_HARNESS="$TMP_ROOT/validate-archive-harness.sh"
build_archive_harness "$ARCH_HARNESS"

make_archive() {
  archive_src="$TMP_ROOT/src-$1"
  /bin/rm -rf -- "$archive_src"
  /bin/mkdir -p "$archive_src/claude-lane-1.3.0"
  printf '1.3.0\n' >"$archive_src/claude-lane-1.3.0/VERSION"
  printf 'runbook\n' >"$archive_src/claude-lane-1.3.0/RUNBOOK.md"
  printf 'real\n' >"$archive_src/claude-lane-1.3.0/real.txt"
}

# 干净包必须通过（防止校验收紧过头把正常包也挡了）
make_archive clean
( cd "$TMP_ROOT/src-clean" && /usr/bin/tar -czf "$TMP_ROOT/clean.tar.gz" claude-lane-1.3.0 )
expect_success "干净归档应通过结构校验" "ARCHIVE_ACCEPTED" \
  /bin/bash "$ARCH_HARNESS" "$TMP_ROOT/clean.tar.gz"

# 符号链接逃逸：包里放 evil-link -> /etc/passwd
make_archive symlink
/bin/ln -s /etc/passwd "$TMP_ROOT/src-symlink/claude-lane-1.3.0/evil-link"
( cd "$TMP_ROOT/src-symlink" && /usr/bin/tar -czf "$TMP_ROOT/symlink.tar.gz" claude-lane-1.3.0 )
expect_failure "归档含符号链接应拒绝解压" "符号链接或硬链接" \
  /bin/bash "$ARCH_HARNESS" "$TMP_ROOT/symlink.tar.gz"

# 硬链接逃逸
make_archive hardlink
/bin/ln "$TMP_ROOT/src-hardlink/claude-lane-1.3.0/real.txt" \
        "$TMP_ROOT/src-hardlink/claude-lane-1.3.0/hard-link"
( cd "$TMP_ROOT/src-hardlink" && /usr/bin/tar -czf "$TMP_ROOT/hardlink.tar.gz" claude-lane-1.3.0 )
expect_failure "归档含硬链接应拒绝解压" "符号链接或硬链接" \
  /bin/bash "$ARCH_HARNESS" "$TMP_ROOT/hardlink.tar.gz"

# 路径穿越仍要挡住（原有能力的回归）
make_archive traversal
( cd "$TMP_ROOT/src-traversal" && /usr/bin/tar -czf "$TMP_ROOT/traversal.tar.gz" \
    claude-lane-1.3.0 ../src-traversal/claude-lane-1.3.0/VERSION 2>/dev/null || true )
if [ -f "$TMP_ROOT/traversal.tar.gz" ]; then
  expect_failure "归档含越界路径应拒绝" "结构不安全" \
    /bin/bash "$ARCH_HARNESS" "$TMP_ROOT/traversal.tar.gz"
fi

if /usr/bin/plutil -convert xml1 -o /dev/null -- "$REPO_DIR/manifests/stable.json" >/dev/null 2>&1 && \
   /usr/bin/grep -Fq '"release_status": "blocked"' "$REPO_DIR/manifests/stable.json" && \
   /usr/bin/grep -Fq '"base_url": "TBD"' "$REPO_DIR/manifests/stable.json"; then
  pass "仓库 stable manifest 保持发布门禁"
else
  fail "仓库 stable manifest 保持发布门禁"
fi

printf '\nbootstrap selftest: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
