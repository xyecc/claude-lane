#!/bin/bash

# claude-lane deterministic bootstrap for macOS.
# Keep this file compatible with the system Bash 3.2 shipped by macOS.

set -u
set -o pipefail
umask 077

BOOTSTRAP_VERSION="1"
EXPECTED_SCHEMA="1"
EXPECTED_LANE_VERSION="1.3.0"
EXPECTED_CLAUDE_VERSION="2.1.212"
EXPECTED_CLASH_VERSION="2.5.2"
EXPECTED_GPG_FINGERPRINT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
EXPECTED_CLAUDE_IDENTIFIER="com.anthropic.claude-code"
EXPECTED_CLAUDE_TEAM_ID="Q6L2SF6YDW"
EXPECTED_CLAUDE_ARM64_SHA="09ecba2ab2df9b6ee5b0695e26f65dea60fb3b6af3d3542ee09f466838d1e574"
EXPECTED_CLAUDE_X86_SHA="7681a0634c89fa4474e53c0c794e992944aebf3409a7a2b87ea9f9b0194ea341"
EXPECTED_CLASH_ARM64_SHA="94d29405980b5d1d3419dd1de485db3a234d35cef058f79dcce595e01b697219"
EXPECTED_CLASH_X86_SHA="c9fcec27d3e4b4fffe31f314369aaa4017d80c1293c8b1cb65d85de223e9cb6c"

# Release block. These values intentionally stay unusable until the two
# domestic stores and the immutable stable manifest have passed release gates.
PRIMARY_BASE_URL="https://TBD-PRIMARY.invalid"
BACKUP_BASE_URL="https://TBD-BACKUP.invalid"
STABLE_MANIFEST_PATH="manifests/stable.json"
STABLE_MANIFEST_SHA256="TBD"

DRY_RUN=0
MANIFEST_FILE=""
TEST_MODE="${CL_BOOT_TEST_MODE:-0}"
BOOT_TMP=""
MOUNT_POINT=""
# attach 成功就登记镜像路径，供 cleanup 兜底卸载——不能只靠 MOUNT_POINT，
# 因为「已挂载但挂载点解析失败」正是最容易留下残留的那条路径。
ATTACHED_DMG=""
TEMP_CLAUDE_CONFIG=""
DEPLOY_DEEPSEEK_KEY=""
# 仍持有 Key 的 Claude 子进程 PID；cleanup 必须先终止它再清环境和临时目录。
CLAUDE_CHILD_PID=""
DEPLOYMENT_ID=""
# 安装后才赋值，但失败提示里会引用它们；set -u 下不给初值，
# 一旦将来调用顺序变动，报错路径本身会先崩掉，最难排查。
INSTALLED_LANE=""
INSTALLED_CLAUDE=""
COMPLETION_FILE=""
# 安装目标先写到同目录临时路径，校验后再原子改名；失败时只清理精确临时路径。
PENDING_CLAUDE_INSTALL=""
PENDING_LANE_INSTALL=""
PENDING_CLASH_INSTALL=""

say() {
  printf '%s\n' "$*"
}

warn() {
  printf '警告：%s\n' "$*" >&2
}

die() {
  printf '停止：%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
claude-lane bootstrap.sh

用法：
  bash bootstrap.sh --dry-run
  bash bootstrap.sh --help

参数：
  --dry-run               只检查平台、架构、磁盘与 manifest 门禁
  --help                  显示帮助
  --manifest-file <path>  仅专项测试注入；同时要求 CL_BOOT_TEST_MODE=1

当前 stable 发布块尚未配置国内主备源、manifest 固定摘要和仓库包摘要，
正式运行会在下载或修改系统前失败关闭。
EOF
}

clear_temporary_environment() {
  DEPLOY_DEEPSEEK_KEY=""
  unset DEPLOY_DEEPSEEK_KEY 2>/dev/null || true
  unset ANTHROPIC_BASE_URL 2>/dev/null || true
  unset ANTHROPIC_AUTH_TOKEN 2>/dev/null || true
  unset ANTHROPIC_API_KEY 2>/dev/null || true
  unset ANTHROPIC_MODEL 2>/dev/null || true
  unset ANTHROPIC_DEFAULT_OPUS_MODEL 2>/dev/null || true
  unset ANTHROPIC_DEFAULT_SONNET_MODEL 2>/dev/null || true
  unset ANTHROPIC_DEFAULT_HAIKU_MODEL 2>/dev/null || true
  unset CLAUDE_CODE_SUBAGENT_MODEL 2>/dev/null || true
  unset CLAUDE_CODE_EFFORT_LEVEL 2>/dev/null || true
  unset CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC 2>/dev/null || true
  unset CLAUDE_CODE_SKIP_PROMPT_HISTORY 2>/dev/null || true
  unset CLAUDE_CODE_SUBPROCESS_ENV_SCRUB 2>/dev/null || true
  unset DISABLE_LOGIN_COMMAND 2>/dev/null || true
  unset DISABLE_UPDATES 2>/dev/null || true
  unset DISABLE_AUTOUPDATER 2>/dev/null || true
  unset CLAUDE_CONFIG_DIR 2>/dev/null || true
  unset CLAUDE_LANE_DEPLOY_ID 2>/dev/null || true
}

remove_temp_config() {
  if [ -n "$TEMP_CLAUDE_CONFIG" ]; then
    case "$TEMP_CLAUDE_CONFIG" in
      "$BOOT_TMP"/*) /bin/rm -rf -- "$TEMP_CLAUDE_CONFIG" 2>/dev/null || true ;;
    esac
    TEMP_CLAUDE_CONFIG=""
  fi
}

remove_pending_installs() {
  if [ -n "$PENDING_CLAUDE_INSTALL" ]; then
    case "$PENDING_CLAUDE_INSTALL" in
      "$HOME/Library/Application Support/claude-lane/tools/claude-code/"*/.claude.installing.*)
        /bin/rm -f -- "$PENDING_CLAUDE_INSTALL" 2>/dev/null || true ;;
    esac
    PENDING_CLAUDE_INSTALL=""
  fi
  if [ -n "$PENDING_LANE_INSTALL" ]; then
    case "$PENDING_LANE_INSTALL" in
      "$HOME/Library/Application Support/claude-lane/releases/".v*.installing.*)
        /bin/rm -rf -- "$PENDING_LANE_INSTALL" 2>/dev/null || true ;;
    esac
    PENDING_LANE_INSTALL=""
  fi
  if [ -n "$PENDING_CLASH_INSTALL" ]; then
    case "$PENDING_CLASH_INSTALL" in
      /Applications/.claude-lane-Clash-Verge.installing.*.app)
        if [ -w /Applications ]; then
          /bin/rm -rf -- "$PENDING_CLASH_INSTALL" 2>/dev/null || true
        else
          /usr/bin/sudo -n /bin/rm -rf -- "$PENDING_CLASH_INSTALL" >/dev/null 2>&1 || true
        fi
        ;;
    esac
    PENDING_CLASH_INSTALL=""
  fi
}

cleanup() {
  cleanup_status=$?
  trap - EXIT INT TERM HUP

  # ① 先终止仍在跑的 Claude 子进程。清掉父进程的变量不等于秘密消失：
  #    子进程 environ 里还有 ANTHROPIC_AUTH_TOKEN，而且下面就要 rm -rf 掉它正在
  #    使用的 CLAUDE_CONFIG_DIR。Ctrl+C 时这一步不做，Claude 会变成孤儿继续持有 Key。
  if [ -n "$BOOT_TMP" ] && [ -f "$BOOT_TMP/claude-child.pid" ]; then
    CLAUDE_CHILD_PID=$(/usr/bin/head -n 1 "$BOOT_TMP/claude-child.pid" 2>/dev/null || true)
    case "$CLAUDE_CHILD_PID" in
      ''|*[!0-9]*) CLAUDE_CHILD_PID="" ;;
    esac
  fi
  if [ -n "$CLAUDE_CHILD_PID" ]; then
    /bin/kill -TERM "$CLAUDE_CHILD_PID" 2>/dev/null || true
    /bin/sleep 1
    /bin/kill -KILL "$CLAUDE_CHILD_PID" 2>/dev/null || true
    wait "$CLAUDE_CHILD_PID" 2>/dev/null || true
    CLAUDE_CHILD_PID=""
  fi

  clear_temporary_environment
  remove_pending_installs

  if [ -n "$MOUNT_POINT" ]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
    MOUNT_POINT=""
  fi
  # ② 挂载点解析失败时 MOUNT_POINT 为空，但镜像其实已经挂上了——按镜像路径兜底卸载
  if [ -n "$ATTACHED_DMG" ]; then
    /usr/bin/hdiutil detach "$ATTACHED_DMG" -force -quiet >/dev/null 2>&1 || true
    ATTACHED_DMG=""
  fi

  if [ -n "$BOOT_TMP" ]; then
    case "$BOOT_TMP" in
      "${TMPDIR:-/tmp}"/claude-lane-bootstrap.*|/tmp/claude-lane-bootstrap.*)
        /bin/rm -rf -- "$BOOT_TMP" 2>/dev/null || true
        ;;
    esac
  fi

  exit "$cleanup_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --manifest-file)
      [ "$#" -ge 2 ] || die "--manifest-file 缺少路径"
      MANIFEST_FILE=$2
      shift
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
  shift
done

if [ -n "$MANIFEST_FILE" ] && [ "$TEST_MODE" != "1" ]; then
  die "--manifest-file 只允许在 CL_BOOT_TEST_MODE=1 下使用"
fi

if [ "$TEST_MODE" = "1" ]; then
  [ -n "$MANIFEST_FILE" ] || die "测试模式必须显式传入 --manifest-file"
  [ "$DRY_RUN" = "1" ] || die "测试模式只允许 --dry-run，禁止执行安装"
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少 macOS 系统组件：$1"
}

lowercase() {
  LC_ALL=C /usr/bin/tr '[:upper:]' '[:lower:]'
}

is_placeholder() {
  placeholder_value=$(printf '%s' "$1" | lowercase)
  case "$placeholder_value" in
    ""|*tbd*|*todo*|*example.invalid*|*.invalid*|*待填写*|*待发布*) return 0 ;;
  esac
  return 1
}

valid_sha256() {
  sha_value=$1
  is_placeholder "$sha_value" && return 1
  printf '%s' "$sha_value" | LC_ALL=C /usr/bin/grep -Eq '^[0-9a-fA-F]{64}$' || return 1
  [ "$sha_value" != "0000000000000000000000000000000000000000000000000000000000000000" ]
}

valid_relative_path() {
  relative_value=$1
  is_placeholder "$relative_value" && return 1
  case "$relative_value" in
    /*|*://*|*\?*|*\#*) return 1 ;;
  esac
  printf '%s' "$relative_value" | LC_ALL=C /usr/bin/grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || return 1
  printf '%s' "$relative_value" | LC_ALL=C /usr/bin/grep -Eq '(^|/)\.\.(/|$)' && return 1
  printf '%s' "$relative_value" | LC_ALL=C /usr/bin/grep -Eqi '(^|[._/-])latest([._/-]|$)' && return 1
  return 0
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

version_at_least() {
  have_version=$1
  need_version=$2
  /usr/bin/awk -v have="$have_version" -v need="$need_version" 'BEGIN {
    hn=split(have,h,"."); nn=split(need,n,"."); max=(hn>nn?hn:nn);
    for(i=1;i<=max;i++){hv=(i<=hn?h[i]+0:0); nv=(i<=nn?n[i]+0:0);
      if(hv>nv) exit 0; if(hv<nv) exit 1}
    exit 0
  }'
}

manifest_get() {
  manifest_key=$1
  /usr/bin/plutil -extract "$manifest_key" raw -o - "$MANIFEST_FILE" 2>/dev/null
}

download_url() {
  source_url=$1
  output_file=$2
  /usr/bin/curl -q --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --connect-timeout 10 --max-time 600 --retry 2 --retry-delay 1 \
    --output "$output_file" "$source_url"
}

join_url() {
  join_base=${1%/}
  join_path=${2#/}
  printf '%s/%s' "$join_base" "$join_path"
}

download_checked() {
  artifact_path=$1
  artifact_sha=$2
  artifact_dest=$3
  artifact_label=$4

  for artifact_base in "$PRIMARY_BASE_URL" "$BACKUP_BASE_URL"; do
    artifact_url=$(join_url "$artifact_base" "$artifact_path")
    artifact_part="${artifact_dest}.part"
    /bin/rm -f -- "$artifact_part" "$artifact_dest" 2>/dev/null || true
    say "下载 ${artifact_label}：${artifact_base}"
    if download_url "$artifact_url" "$artifact_part"; then
      actual_sha=$(sha256_file "$artifact_part" 2>/dev/null || true)
      if [ "$(printf '%s' "$actual_sha" | lowercase)" = "$(printf '%s' "$artifact_sha" | lowercase)" ]; then
        /bin/mv -- "$artifact_part" "$artifact_dest" || die "无法保存 ${artifact_label}"
        return 0
      fi
      warn "${artifact_label} 摘要不一致，尝试备用源"
    else
      warn "${artifact_label} 下载失败，尝试备用源"
    fi
  done

  /bin/rm -f -- "${artifact_dest}.part" "$artifact_dest" 2>/dev/null || true
  die "${artifact_label} 的主备源均未通过下载与 SHA-256 校验"
}

make_temp_dir() {
  [ -n "$BOOT_TMP" ] && return 0
  temp_parent=${TMPDIR:-/tmp}
  BOOT_TMP=$(/usr/bin/mktemp -d "${temp_parent%/}/claude-lane-bootstrap.XXXXXX") || die "无法创建临时目录"
  /bin/chmod 700 "$BOOT_TMP" || die "无法保护临时目录"
}

validate_release_block() {
  for release_base in "$PRIMARY_BASE_URL" "$BACKUP_BASE_URL"; do
    is_placeholder "$release_base" && die "国内主备下载源尚未发布，启动器保持失败关闭"
    case "$release_base" in
      https://*) ;;
      *) die "下载源必须使用 HTTPS" ;;
    esac
  done
  valid_sha256 "$STABLE_MANIFEST_SHA256" || die "stable manifest 的固定 SHA-256 尚未发布"
}

load_manifest() {
  if [ -n "$MANIFEST_FILE" ]; then
    [ -f "$MANIFEST_FILE" ] || die "测试 manifest 不存在"
    MANIFEST_FILE=$(cd "$(dirname "$MANIFEST_FILE")" 2>/dev/null && pwd)/$(basename "$MANIFEST_FILE")
    [ -f "$MANIFEST_FILE" ] || die "无法解析测试 manifest 路径"
    return 0
  fi

  validate_release_block
  make_temp_dir
  MANIFEST_FILE="$BOOT_TMP/stable.json"
  download_checked "$STABLE_MANIFEST_PATH" "$STABLE_MANIFEST_SHA256" "$MANIFEST_FILE" "stable manifest"
}

validate_manifest() {
  # Some macOS plutil builds parse JSON for -extract/-convert but make -lint
  # plist-only. Conversion to an unused plist validates the JSON consistently.
  /usr/bin/plutil -convert xml1 -o /dev/null -- "$MANIFEST_FILE" >/dev/null 2>&1 || die "manifest 不是有效 JSON"

  manifest_schema=$(manifest_get schema) || die "manifest 缺少 schema"
  release_status=$(manifest_get release_status) || die "manifest 缺少 release_status"
  minimum_macos=$(manifest_get minimum_macos) || die "manifest 缺少 minimum_macos"
  required_free_mb=$(manifest_get required_free_mb) || die "manifest 缺少 required_free_mb"

  lane_version=$(manifest_get claude_lane.version) || die "manifest 缺少 claude_lane.version"
  lane_path=$(manifest_get claude_lane.path) || die "manifest 缺少 claude_lane.path"
  lane_root=$(manifest_get claude_lane.archive_root) || die "manifest 缺少 claude_lane.archive_root"
  lane_sha=$(manifest_get claude_lane.sha256) || die "manifest 缺少 claude_lane.sha256"

  claude_version=$(manifest_get claude_code.version) || die "manifest 缺少 claude_code.version"
  gpg_fingerprint=$(manifest_get claude_code.manifest_gpg_fingerprint) || die "manifest 缺少 Claude Code GPG 指纹"
  claude_arm_path=$(manifest_get claude_code.darwin_arm64.path) || die "manifest 缺少 Claude Code arm64 路径"
  claude_arm_sha=$(manifest_get claude_code.darwin_arm64.sha256) || die "manifest 缺少 Claude Code arm64 摘要"
  claude_x86_path=$(manifest_get claude_code.darwin_x86_64.path) || die "manifest 缺少 Claude Code x86_64 路径"
  claude_x86_sha=$(manifest_get claude_code.darwin_x86_64.sha256) || die "manifest 缺少 Claude Code x86_64 摘要"

  clash_version=$(manifest_get clash_verge.version) || die "manifest 缺少 Clash Verge 版本"
  clash_arm_path=$(manifest_get clash_verge.arm64.path) || die "manifest 缺少 Clash Verge arm64 路径"
  clash_arm_sha=$(manifest_get clash_verge.arm64.sha256) || die "manifest 缺少 Clash Verge arm64 摘要"
  clash_x86_path=$(manifest_get clash_verge.x86_64.path) || die "manifest 缺少 Clash Verge x86_64 路径"
  clash_x86_sha=$(manifest_get clash_verge.x86_64.sha256) || die "manifest 缺少 Clash Verge x86_64 摘要"

  [ "$manifest_schema" = "$EXPECTED_SCHEMA" ] || die "不支持的 manifest schema：$manifest_schema"
  [ "$release_status" = "released" ] || die "manifest 尚未达到 released 状态"
  [ "$lane_version" = "$EXPECTED_LANE_VERSION" ] || die "claude-lane 版本未固定为 $EXPECTED_LANE_VERSION"
  [ "$claude_version" = "$EXPECTED_CLAUDE_VERSION" ] || die "Claude Code 版本未固定为 $EXPECTED_CLAUDE_VERSION"
  [ "$clash_version" = "$EXPECTED_CLASH_VERSION" ] || die "Clash Verge 版本未固定为 $EXPECTED_CLASH_VERSION"

  printf '%s' "$minimum_macos" | LC_ALL=C /usr/bin/grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' || die "minimum_macos 格式无效"
  version_at_least "$minimum_macos" "13.0" || die "manifest 不得把最低 macOS 降到 13 以下"
  printf '%s' "$required_free_mb" | LC_ALL=C /usr/bin/grep -Eq '^[0-9]+$' || die "required_free_mb 必须是整数"
  [ "$required_free_mb" -ge 1024 ] 2>/dev/null || die "required_free_mb 低于安全下限"

  valid_relative_path "$lane_path" || die "claude-lane 路径无效或仍是占位值"
  printf '%s' "$lane_root" | LC_ALL=C /usr/bin/grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || die "archive_root 无效"
  valid_sha256 "$lane_sha" || die "claude-lane SHA-256 尚未发布或格式无效"
  valid_relative_path "$claude_arm_path" || die "Claude Code arm64 路径无效"
  valid_relative_path "$claude_x86_path" || die "Claude Code x86_64 路径无效"
  valid_relative_path "$clash_arm_path" || die "Clash Verge arm64 路径无效"
  valid_relative_path "$clash_x86_path" || die "Clash Verge x86_64 路径无效"

  [ "$(printf '%s' "$gpg_fingerprint" | lowercase)" = "$(printf '%s' "$EXPECTED_GPG_FINGERPRINT" | lowercase)" ] || die "Claude Code manifest 的 GPG 指纹不匹配"
  [ "$(printf '%s' "$claude_arm_sha" | lowercase)" = "$EXPECTED_CLAUDE_ARM64_SHA" ] || die "Claude Code arm64 摘要不匹配启动器固定基线"
  [ "$(printf '%s' "$claude_x86_sha" | lowercase)" = "$EXPECTED_CLAUDE_X86_SHA" ] || die "Claude Code x86_64 摘要不匹配启动器固定基线"
  [ "$(printf '%s' "$clash_arm_sha" | lowercase)" = "$EXPECTED_CLASH_ARM64_SHA" ] || die "Clash Verge arm64 摘要不匹配固定基线"
  [ "$(printf '%s' "$clash_x86_sha" | lowercase)" = "$EXPECTED_CLASH_X86_SHA" ] || die "Clash Verge x86_64 摘要不匹配固定基线"
}

detect_platform() {
  platform_name=$(/usr/bin/uname -s)
  machine_name=$(/usr/bin/uname -m)
  rosetta_translated=0

  if [ "$TEST_MODE" = "1" ]; then
    platform_name=${CL_BOOT_TEST_UNAME_S:-$platform_name}
    machine_name=${CL_BOOT_TEST_UNAME_M:-$machine_name}
  elif [ "$machine_name" = "x86_64" ]; then
    translated_value=$(/usr/sbin/sysctl -in sysctl.proc_translated 2>/dev/null || true)
    if [ "$translated_value" = "1" ]; then
      machine_name="arm64"
      rosetta_translated=1
    fi
  fi

  [ "$platform_name" = "Darwin" ] || die "只支持 macOS；其他平台请看 docs/porting.md"
  case "$machine_name" in
    arm64)
      ARTIFACT_ARCH="arm64"
      claude_path=$claude_arm_path
      claude_sha=$claude_arm_sha
      clash_path=$clash_arm_path
      clash_sha=$clash_arm_sha
      ;;
    x86_64)
      ARTIFACT_ARCH="x86_64"
      claude_path=$claude_x86_path
      claude_sha=$claude_x86_sha
      clash_path=$clash_x86_path
      clash_sha=$clash_x86_sha
      ;;
    *)
      die "不支持的 CPU 架构：$machine_name"
      ;;
  esac

  if [ "$rosetta_translated" = "1" ]; then
    say "检测到 Rosetta 进程，按 Apple Silicon arm64 选择产物"
  else
    say "架构：$ARTIFACT_ARCH"
  fi
}

check_macos_and_disk() {
  macos_version=$(/usr/bin/sw_vers -productVersion)
  if [ "$TEST_MODE" = "1" ]; then
    macos_version=${CL_BOOT_TEST_MACOS_VERSION:-$macos_version}
  fi
  version_at_least "$macos_version" "$minimum_macos" || die "需要 macOS $minimum_macos 或更高版本，当前为 $macos_version"

  free_mb=$(/bin/df -Pk "$HOME" | /usr/bin/awk 'END {print int($4/1024)}')
  if [ "$TEST_MODE" = "1" ]; then
    free_mb=${CL_BOOT_TEST_FREE_MB:-$free_mb}
  fi
  printf '%s' "$free_mb" | LC_ALL=C /usr/bin/grep -Eq '^[0-9]+$' || die "无法确定剩余磁盘空间"
  [ "$free_mb" -ge "$required_free_mb" ] || die "磁盘空间不足：需要 ${required_free_mb} MiB，当前约 ${free_mb} MiB"
  say "macOS ${macos_version}；可用磁盘约 ${free_mb} MiB"
}

require_base_tools() {
  require_command /usr/bin/uname
  require_command /usr/bin/sw_vers
  require_command /bin/df
  require_command /usr/bin/awk
  require_command /usr/bin/grep
  require_command /usr/bin/plutil
  require_command /usr/bin/tr
  require_command /usr/bin/shasum
}

require_install_tools() {
  require_command /usr/bin/curl
  require_command /usr/bin/codesign
  require_command /usr/sbin/spctl
  require_command /usr/bin/hdiutil
  require_command /usr/bin/ditto
  require_command /usr/bin/tar
  require_command /usr/bin/osascript
  require_command /usr/bin/open
  require_command /usr/bin/diff
}

require_tty() {
  [ -r /dev/tty ] && [ -w /dev/tty ] || die "需要交互式终端，无法从 /dev/tty 安全读取输入"
}

verify_executable_signature() {
  signed_file=$1
  signed_label=$2
  /usr/bin/codesign --verify --strict --verbose=2 "$signed_file" >/dev/null 2>&1 || die "$signed_label 的 macOS 代码签名校验失败"
  signature_info=$(/usr/bin/codesign -d --verbose=4 "$signed_file" 2>&1) || die "无法读取 $signed_label 的签名身份"
  printf '%s\n' "$signature_info" | /usr/bin/grep -Fqx "Identifier=$EXPECTED_CLAUDE_IDENTIFIER" || die "$signed_label 的签名标识不属于 Claude Code"
  printf '%s\n' "$signature_info" | /usr/bin/grep -Fqx "TeamIdentifier=$EXPECTED_CLAUDE_TEAM_ID" || die "$signed_label 的签名团队不属于 Anthropic"
}

verify_app_signature() {
  signed_app=$1
  signed_label=$2
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$signed_app" >/dev/null 2>&1 || die "$signed_label 的 macOS 代码签名校验失败"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$signed_app" >/dev/null 2>&1 || die "$signed_label 未通过 Gatekeeper 评估"
}

validate_archive() {
  archive_file=$1
  list_file="$BOOT_TMP/archive-list.txt"
  verbose_file="$BOOT_TMP/archive-list-verbose.txt"
  /usr/bin/tar -tzf "$archive_file" >"$list_file" 2>/dev/null || die "claude-lane 归档损坏"
  [ -s "$list_file" ] || die "claude-lane 归档为空"
  /usr/bin/awk -v root="$lane_root" '
    BEGIN { bad=0 }
    /^\// { bad=1 }
    /(^|\/)\.\.($|\/)/ { bad=1 }
    $0 != root && index($0, root "/") != 1 { bad=1 }
    END { exit bad }
  ' "$list_file" || die "claude-lane 归档结构不安全或顶层目录不匹配"

  # 只挡 ../ 是不够的：包里放一个 sub -> /etc 的符号链接，再往 sub/xxx 写，
  # 就能落到解压目录外（经典 tar-slip）。`tar -tzf` 的纯路径列表看不出链接类型，
  # 必须用 -tvzf：symlink 的模式位以 l 开头（行内带 " -> "），
  # hardlink 以 h 开头（行内带 " link to "）。本项目的包里两者都不该出现。
  /usr/bin/tar -tvzf "$archive_file" >"$verbose_file" 2>/dev/null || die "claude-lane 归档损坏"
  /usr/bin/awk '
    $1 ~ /^l/ { exit 1 }
    $1 ~ /^h/ { exit 1 }
    / -> / { exit 1 }
    / link to / { exit 1 }
  ' "$verbose_file" || die "claude-lane 归档含符号链接或硬链接，拒绝解压"
}

stage_artifacts() {
  make_temp_dir
  STAGED_CLAUDE="$BOOT_TMP/claude"
  STAGED_ARCHIVE="$BOOT_TMP/claude-lane.tar.gz"
  STAGED_EXTRACT="$BOOT_TMP/extracted"

  download_checked "$claude_path" "$claude_sha" "$STAGED_CLAUDE" "Claude Code $claude_version"
  /bin/chmod 755 "$STAGED_CLAUDE" || die "无法设置 Claude Code 执行权限"
  verify_executable_signature "$STAGED_CLAUDE" "Claude Code"

  claude_version_output=$(
    "$STAGED_CLAUDE" --version 2>/dev/null | /usr/bin/head -n 1
  ) || die "无法读取 Claude Code 版本"
  printf '%s' "$claude_version_output" | /usr/bin/grep -Fq "$EXPECTED_CLAUDE_VERSION" || die "Claude Code 实际版本与 manifest 不一致"

  download_checked "$lane_path" "$lane_sha" "$STAGED_ARCHIVE" "claude-lane $lane_version"
  validate_archive "$STAGED_ARCHIVE"
  /bin/mkdir -p "$STAGED_EXTRACT" || die "无法创建解压目录"
  /usr/bin/tar -xzf "$STAGED_ARCHIVE" -C "$STAGED_EXTRACT" || die "无法解压 claude-lane"
  # 解压后二次确认：即使上面的清单校验被绕过，落地结果里也不允许有链接
  if /usr/bin/find "$STAGED_EXTRACT" \( -type l -o \( -type f -links +1 \) \) -print 2>/dev/null | /usr/bin/grep -q .; then
    die "解压结果含符号链接或硬链接，拒绝继续"
  fi
  STAGED_LANE="$STAGED_EXTRACT/$lane_root"
  [ -f "$STAGED_LANE/RUNBOOK.md" ] || die "归档缺少 RUNBOOK.md"
  [ -f "$STAGED_LANE/VERSION" ] || die "归档缺少 VERSION"
  for required_release_file in \
    scripts/backup.sh scripts/rollback.sh scripts/selftest.sh scripts/verify.sh \
    scripts/set-credentials.sh scripts/profile-config.sh scripts/macos-json.js \
    scripts/bootstrap-complete.sh templates/1-proxies.yaml templates/2-groups.yaml \
    templates/3-rules.yaml templates/4-merge.yaml templates/optional-payment-rules.yaml \
    docs/troubleshooting.md docs/account-safety.md docs/porting.md; do
    [ -f "$STAGED_LANE/$required_release_file" ] || die "归档缺少运行必需文件：$required_release_file"
  done
  archive_version=$(/usr/bin/awk 'NR==1 {gsub(/[[:space:]]/,""); print; exit}' "$STAGED_LANE/VERSION")
  [ "$archive_version" = "$lane_version" ] || die "归档内 VERSION 与 manifest 不一致"
}

preflight_claude_cli() {
  help_file="$BOOT_TMP/claude-help.txt"
  "$STAGED_CLAUDE" --help >"$help_file" 2>&1 || die "Claude Code CLI 自检失败"
  for required_flag in '--print' '--output-format' '--tools' '--allowedTools' '--no-session-persistence' '--setting-sources' '--strict-mcp-config' '--permission-mode'; do
    /usr/bin/grep -Fq -- "$required_flag" "$help_file" || die "固定版 Claude Code 缺少所需参数：$required_flag"
  done
  if /usr/bin/grep -Fq -- '--max-turns' "$help_file"; then
    CLAUDE_HAS_MAX_TURNS=1
  else
    CLAUDE_HAS_MAX_TURNS=0
    warn "固定版 CLI 未公开 --max-turns；握手仍受启动器外部超时限制"
  fi
}

run_with_timeout() {
  timeout_seconds=$1
  stdout_file=$2
  stderr_file=$3
  shift 3

  "$@" >"$stdout_file" 2>"$stderr_file" </dev/null &
  timed_pid=$!
  # 登记给 cleanup：这个子进程在后台，父进程在下面的 sleep 循环里，
  # 此时收到 INT/TERM 会立刻走 trap → cleanup，若不先杀它，它会带着 Key
  # 变成孤儿，而且 cleanup 正要 rm -rf 掉它在用的 CLAUDE_CONFIG_DIR。
  # ⚠️ 用文件不用变量：本函数是在 ( cd ...; ... ) 子 shell 里调用的，
  #    子 shell 的变量赋值传不回跑 cleanup 的父进程。
  [ -n "$BOOT_TMP" ] && printf '%s\n' "$timed_pid" >"$BOOT_TMP/claude-child.pid" 2>/dev/null || true
  elapsed_seconds=0
  while /bin/kill -0 "$timed_pid" 2>/dev/null; do
    if [ "$elapsed_seconds" -ge "$timeout_seconds" ]; then
      /bin/kill -TERM "$timed_pid" 2>/dev/null || true
      /bin/sleep 2
      /bin/kill -KILL "$timed_pid" 2>/dev/null || true
      wait "$timed_pid" 2>/dev/null || true
      [ -n "$BOOT_TMP" ] && /bin/rm -f -- "$BOOT_TMP/claude-child.pid" 2>/dev/null || true
      return 124
    fi
    /bin/sleep 1
    elapsed_seconds=$((elapsed_seconds + 1))
  done
  timed_status=0
  wait "$timed_pid" || timed_status=$?
  [ -n "$BOOT_TMP" ] && /bin/rm -f -- "$BOOT_TMP/claude-child.pid" 2>/dev/null || true
  return "$timed_status"
}

# 用固定的干净环境跑 Claude Code。
# ⚠️ Key 绝不能出现在任何 argv 里：`env -i NAME=value cmd` 的 `NAME=value` 属于 env 的
#    命令行参数，全机任何用户 `ps auxww` 都看得到。所以这里把 Key 单独从文件描述符 3
#    读进来、在受控子 shell 内 export 后再 exec，argv 中只剩非秘密变量。
#    fd 3 用进程替换喂入（printf 是 bash 内建，不产生独立进程，也不落临时文件）；
#    stdin 保持空闲，交互调用仍可自行绑定 /dev/tty。
run_deepseek_claude() {
  /usr/bin/env -i \
    HOME="$HOME" \
    USER="${USER:-}" \
    LOGNAME="${LOGNAME:-${USER:-}}" \
    SHELL="/bin/bash" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${TMPDIR:-/tmp}" \
    TERM="${TERM:-xterm-256color}" \
    LANG="${LANG:-en_US.UTF-8}" \
    ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic" \
    ANTHROPIC_MODEL="deepseek-v4-flash" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-v4-flash" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-flash" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash" \
    CLAUDE_CODE_SUBAGENT_MODEL="deepseek-v4-flash" \
    CLAUDE_CODE_EFFORT_LEVEL="max" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1" \
    CLAUDE_CODE_SKIP_PROMPT_HISTORY="1" \
    CLAUDE_CODE_SUBPROCESS_ENV_SCRUB="1" \
    DISABLE_LOGIN_COMMAND="1" \
    DISABLE_UPDATES="1" \
    DISABLE_AUTOUPDATER="1" \
    CLAUDE_CONFIG_DIR="$TEMP_CLAUDE_CONFIG" \
    CLAUDE_LANE_DEPLOY_ID="$DEPLOYMENT_ID" \
    CLAUDE_LANE_COMPLETION_FILE="$COMPLETION_FILE" \
    /bin/bash -c '
      IFS= read -r ANTHROPIC_AUTH_TOKEN <&3 || exit 1
      [ -n "$ANTHROPIC_AUTH_TOKEN" ] || exit 1
      export ANTHROPIC_AUTH_TOKEN
      exec 3<&-
      exec "$@"
    ' claude-lane-deepseek-shim "$@" 3< <(printf '%s\n' "$DEPLOY_DEEPSEEK_KEY")
}

read_deepseek_key() {
  require_tty
  printf '请输入额度受限、可撤销的安装专用 DeepSeek API Key: ' >/dev/tty
  IFS= read -r -s DEPLOY_DEEPSEEK_KEY </dev/tty || die "读取 DeepSeek Key 失败"
  printf '\n' >/dev/tty
  [ -n "$DEPLOY_DEEPSEEK_KEY" ] || die "DeepSeek Key 不能为空"
}

run_handshake() {
  preflight_claude_cli
  TEMP_CLAUDE_CONFIG="$BOOT_TMP/claude-config"
  /bin/mkdir -p "$TEMP_CLAUDE_CONFIG" || die "无法创建临时 Claude 配置目录"
  /bin/chmod 700 "$TEMP_CLAUDE_CONFIG" || die "无法保护临时 Claude 配置目录"
  read_deepseek_key

  handshake_out="$BOOT_TMP/handshake.json"
  handshake_err="$BOOT_TMP/handshake.err"
  read_out="$BOOT_TMP/read-check.json"
  read_err="$BOOT_TMP/read-check.err"

  # ⚠️ 数组必须用 ${arr[@]+"${arr[@]}"} 展开：macOS 系统 bash 3.2.57 在 set -u 下
  #    展开空数组 "${arr[@]}" 会直接报 unbound variable 退出。固定版 CLI 通常没有
  #    --max-turns（见交接文档 4.4），也就是空数组才是常态，写错这里握手必炸。
  if [ "$CLAUDE_HAS_MAX_TURNS" = "1" ]; then
    handshake_turn_args=(--max-turns 1)
    read_turn_args=(--max-turns 2)
  else
    handshake_turn_args=()
    read_turn_args=()
  fi

  (
    cd "$STAGED_LANE" || exit 1
    run_with_timeout 120 "$handshake_out" "$handshake_err" \
      run_deepseek_claude "$STAGED_CLAUDE" --print \
      --output-format json --no-session-persistence --setting-sources "" --strict-mcp-config \
      --permission-mode dontAsk --tools "" ${handshake_turn_args[@]+"${handshake_turn_args[@]}"} \
      '只回复 CLAUDE_LANE_HANDSHAKE_OK，不要调用工具。'
  ) || die "DeepSeek 文本握手失败或超时；未安装 Clash Verge"
  /usr/bin/grep -Fq 'CLAUDE_LANE_HANDSHAKE_OK' "$handshake_out" || die "DeepSeek 文本握手返回值不符合预期"

  (
    cd "$STAGED_LANE" || exit 1
    run_with_timeout 120 "$read_out" "$read_err" \
      run_deepseek_claude "$STAGED_CLAUDE" --print \
      --output-format json --no-session-persistence --setting-sources "" --strict-mcp-config \
      --permission-mode dontAsk --tools "Read" \
      --allowedTools "Read($STAGED_LANE/VERSION)" ${read_turn_args[@]+"${read_turn_args[@]}"} \
      '必须用 Read 工具读取当前目录 VERSION；若内容是 1.3.0，只回复 CLAUDE_LANE_READ_OK:1.3.0。'
  ) || die "DeepSeek 只读工具握手失败或超时；未安装 Clash Verge"
  /usr/bin/grep -Fq 'CLAUDE_LANE_READ_OK:1.3.0' "$read_out" || die "DeepSeek 只读工具握手返回值不符合预期"

  # 第三步：实测 CLAUDE_CODE_SUBPROCESS_ENV_SCRUB 是否真的生效。
  # 光设这个变量不算数——固定版 CLI 若没实现它，Claude 用 Bash 工具跑的每个孙进程
  # （selftest.sh / verify.sh 等）都会继承 ANTHROPIC_AUTH_TOKEN，`ps e` 或脚本误打日志
  # 就能把 Key 带出去。探针只报「有/无」，绝不打印值本身。
  scrub_probe="$BOOT_TMP/scrub-probe.sh"
  /bin/cat >"$scrub_probe" <<'PROBE'
#!/bin/bash
scrub_leak=""
for scrub_var in ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY; do
  eval "scrub_val=\${${scrub_var}:-}"
  [ -n "$scrub_val" ] && scrub_leak="$scrub_leak $scrub_var"
done
if [ -n "$scrub_leak" ]; then
  printf 'CLAUDE_LANE_SCRUB_LEAK:%s\n' "$scrub_leak"
else
  printf 'CLAUDE_LANE_SCRUB_OK\n'
fi
PROBE
  /bin/chmod 700 "$scrub_probe" || die "无法准备子进程环境探针"
  scrub_out="$BOOT_TMP/scrub-check.json"
  scrub_err="$BOOT_TMP/scrub-check.err"
  (
    cd "$STAGED_LANE" || exit 1
    run_with_timeout 120 "$scrub_out" "$scrub_err" \
      run_deepseek_claude "$STAGED_CLAUDE" --print \
      --output-format json --no-session-persistence --setting-sources "" --strict-mcp-config \
      --permission-mode dontAsk --tools "Bash" \
      --allowedTools "Bash(bash $scrub_probe)" ${read_turn_args[@]+"${read_turn_args[@]}"} \
      "必须用 Bash 工具原样执行命令 bash $scrub_probe，然后只回复它输出的那一行。"
  ) || die "DeepSeek 子进程环境探测失败或超时；未安装 Clash Verge"
  if /usr/bin/grep -Fq 'CLAUDE_LANE_SCRUB_LEAK' "$scrub_out"; then
    die "固定版 Claude Code 未实现 CLAUDE_CODE_SUBPROCESS_ENV_SCRUB：Bash 工具的子进程仍继承 DeepSeek Key，按失败关闭中止"
  fi
  /usr/bin/grep -Fq 'CLAUDE_LANE_SCRUB_OK' "$scrub_out" || die "无法确认 Bash 工具子进程已剥离 Key，按失败关闭中止"
  /bin/rm -f -- "$scrub_probe" 2>/dev/null || true

  say "DeepSeek 文本、只读工具与子进程环境隔离握手均通过"
}

install_claude_and_lane() {
  tools_root="$HOME/Library/Application Support/claude-lane/tools/claude-code/$claude_version"
  installed_claude="$tools_root/claude"
  release_parent="$HOME/Library/Application Support/claude-lane/releases"
  release_target="$release_parent/v$lane_version"
  current_link="$HOME/Library/Application Support/claude-lane/current"

  /bin/mkdir -p "$tools_root" "$release_parent" || die "无法创建 claude-lane 安装目录"

  if [ -e "$installed_claude" ]; then
    installed_sha=$(sha256_file "$installed_claude" 2>/dev/null || true)
    [ "$(printf '%s' "$installed_sha" | lowercase)" = "$(printf '%s' "$claude_sha" | lowercase)" ] || die "受控目录已有不同 Claude Code，拒绝覆盖"
    verify_executable_signature "$installed_claude" "已安装 Claude Code"
  else
    PENDING_CLAUDE_INSTALL="$tools_root/.claude.installing.$$"
    [ ! -e "$PENDING_CLAUDE_INSTALL" ] && [ ! -L "$PENDING_CLAUDE_INSTALL" ] || die "Claude Code 临时安装路径已存在"
    /usr/bin/ditto "$STAGED_CLAUDE" "$PENDING_CLAUDE_INSTALL" || die "无法暂存 Claude Code"
    /bin/chmod 755 "$PENDING_CLAUDE_INSTALL" || die "无法设置暂存 Claude Code 权限"
    installed_sha=$(sha256_file "$PENDING_CLAUDE_INSTALL" 2>/dev/null || true)
    [ "$(printf '%s' "$installed_sha" | lowercase)" = "$(printf '%s' "$claude_sha" | lowercase)" ] || die "安装后的 Claude Code 摘要不一致"
    verify_executable_signature "$PENDING_CLAUDE_INSTALL" "暂存 Claude Code"
    [ ! -e "$installed_claude" ] && [ ! -L "$installed_claude" ] || die "Claude Code 正式路径在安装期间被占用"
    /bin/mv -- "$PENDING_CLAUDE_INSTALL" "$installed_claude" || die "无法原子启用 Claude Code"
    PENDING_CLAUDE_INSTALL=""
  fi

  if [ -e "$release_target" ]; then
    [ -d "$release_target" ] || die "版本目录已存在但不是目录，拒绝覆盖"
    /usr/bin/diff -qr "$STAGED_LANE" "$release_target" >/dev/null 2>&1 || die "版本目录已有本地改动，拒绝覆盖"
  else
    PENDING_LANE_INSTALL="$release_parent/.v${lane_version}.installing.$$"
    [ ! -e "$PENDING_LANE_INSTALL" ] && [ ! -L "$PENDING_LANE_INSTALL" ] || die "claude-lane 临时安装路径已存在"
    /usr/bin/ditto "$STAGED_LANE" "$PENDING_LANE_INSTALL" || die "无法暂存 claude-lane 仓库包"
    /usr/bin/diff -qr "$STAGED_LANE" "$PENDING_LANE_INSTALL" >/dev/null 2>&1 || die "暂存 claude-lane 内容校验失败"
    [ ! -e "$release_target" ] && [ ! -L "$release_target" ] || die "claude-lane 正式版本路径在安装期间被占用"
    /bin/mv -- "$PENDING_LANE_INSTALL" "$release_target" || die "无法原子启用 claude-lane 仓库包"
    PENDING_LANE_INSTALL=""
  fi

  if [ ! -e "$current_link" ] && [ ! -L "$current_link" ]; then
    /bin/ln -s "$release_target" "$current_link" || die "无法创建 current 链接"
  elif [ -L "$current_link" ] && [ "$(/usr/bin/readlink "$current_link")" = "$release_target" ]; then
    :
  else
    warn "保留已有 current 入口；本次直接使用 $release_target"
  fi

  INSTALLED_CLAUDE="$installed_claude"
  INSTALLED_LANE="$release_target"
}

plist_mount_point() {
  plist_file=$1
  /usr/bin/osascript -l JavaScript - "$plist_file" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  var dict = $.NSDictionary.dictionaryWithContentsOfFile(argv[0]);
  if (!dict) throw new Error('invalid hdiutil plist');
  var entities = dict.objectForKey('system-entities');
  if (!entities) throw new Error('missing system-entities');
  for (var i = 0; i < entities.count; i++) {
    var point = entities.objectAtIndex(i).objectForKey('mount-point');
    if (point) return ObjC.unwrap(point);
  }
  throw new Error('missing mount-point');
}
JXA
}

confirm_install() {
  require_tty
  printf '将安装已校验的 Clash Verge Rev %s 到 /Applications，继续？[y/N] ' "$clash_version" >/dev/tty
  IFS= read -r confirm_answer </dev/tty || return 1
  case "$confirm_answer" in
    y|Y|yes|YES) return 0 ;;
  esac
  return 1
}

install_or_validate_clash() {
  CLASH_APP="/Applications/Clash Verge.app"
  if [ -e "$CLASH_APP" ]; then
    [ -d "$CLASH_APP" ] || die "$CLASH_APP 已存在但不是 App，拒绝覆盖"
    verify_app_signature "$CLASH_APP" "现有 Clash Verge"
    clash_existing_version=$(/usr/bin/defaults read "$CLASH_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || printf '未知')
    say "保留现有 Clash Verge（版本：${clash_existing_version}），不会覆盖"
    /usr/bin/open "$CLASH_APP" || die "无法打开现有 Clash Verge"
    return 0
  fi

  clash_dmg="$BOOT_TMP/clash-verge.dmg"
  attach_plist="$BOOT_TMP/hdiutil-attach.plist"
  download_checked "$clash_path" "$clash_sha" "$clash_dmg" "Clash Verge Rev $clash_version"
  /usr/bin/hdiutil attach "$clash_dmg" -nobrowse -readonly -plist >"$attach_plist" || die "Clash Verge DMG 挂载失败"
  # attach 成功即登记：后面任何一步 die，cleanup 都能按镜像路径把它卸掉
  ATTACHED_DMG="$clash_dmg"
  MOUNT_POINT=$(plist_mount_point "$attach_plist" 2>/dev/null) || die "无法从 hdiutil 结果解析实际挂载点"
  [ -d "$MOUNT_POINT" ] || die "DMG 挂载点不存在"

  mounted_app=""
  if [ -d "$MOUNT_POINT/Clash Verge.app" ]; then
    mounted_app="$MOUNT_POINT/Clash Verge.app"
  else
    mounted_app=$(/usr/bin/find "$MOUNT_POINT" -maxdepth 2 -type d -name 'Clash Verge.app' -print | /usr/bin/head -n 1)
  fi
  [ -n "$mounted_app" ] && [ -d "$mounted_app" ] || die "DMG 中未找到 Clash Verge.app"
  verify_app_signature "$mounted_app" "DMG 内 Clash Verge"
  confirm_install || die "用户取消安装 Clash Verge"

  PENDING_CLASH_INSTALL="/Applications/.claude-lane-Clash-Verge.installing.$$.app"
  [ ! -e "$PENDING_CLASH_INSTALL" ] && [ ! -L "$PENDING_CLASH_INSTALL" ] || die "Clash Verge 临时安装路径已存在"

  if [ -w /Applications ]; then
    /usr/bin/ditto "$mounted_app" "$PENDING_CLASH_INSTALL" || die "暂存 Clash Verge 失败"
    verify_app_signature "$PENDING_CLASH_INSTALL" "暂存 Clash Verge"
    [ ! -e "$CLASH_APP" ] && [ ! -L "$CLASH_APP" ] || die "Clash Verge 正式路径在安装期间被占用"
    /bin/mv -- "$PENDING_CLASH_INSTALL" "$CLASH_APP" || die "无法原子启用 Clash Verge"
  else
    say "macOS 将请求管理员权限以写入 /Applications"
    /usr/bin/sudo /usr/bin/ditto "$mounted_app" "$PENDING_CLASH_INSTALL" || die "暂存 Clash Verge 失败"
    verify_app_signature "$PENDING_CLASH_INSTALL" "暂存 Clash Verge"
    [ ! -e "$CLASH_APP" ] && [ ! -L "$CLASH_APP" ] || die "Clash Verge 正式路径在安装期间被占用"
    /usr/bin/sudo /bin/mv -- "$PENDING_CLASH_INSTALL" "$CLASH_APP" || die "无法原子启用 Clash Verge"
  fi
  PENDING_CLASH_INSTALL=""
  verify_app_signature "$CLASH_APP" "已安装 Clash Verge"

  /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || die "无法安全卸载 Clash Verge DMG"
  MOUNT_POINT=""
  ATTACHED_DMG=""
  /usr/bin/open "$CLASH_APP" || die "无法打开 Clash Verge"
  say "Clash Verge Rev $clash_version 已安装并打开"
}

run_interactive_agent() {
  DEPLOYMENT_ID=$(/bin/date +%Y%m%d-%H%M%S)
  completion_dir="$HOME/Library/Application Support/claude-lane/bootstrap-status"
  COMPLETION_FILE="$completion_dir/complete.$DEPLOYMENT_ID"
  [ ! -L "$completion_dir" ] && [ ! -L "$COMPLETION_FILE" ] || die "bootstrap 完成标记路径不能是符号链接"
  /bin/mkdir -p "$completion_dir" || die "无法创建 bootstrap 状态目录"
  /bin/chmod 700 "$completion_dir" || die "无法保护 bootstrap 状态目录"
  /bin/rm -f -- "$COMPLETION_FILE" || die "无法清理旧的 bootstrap 完成标记"
  say "本次 deployment id：$DEPLOYMENT_ID"
  say "用户运行 set-credentials.sh 时必须复制使用这个 id。"

  agent_prompt="完整读取 ${INSTALLED_LANE}/RUNBOOK.md，并严格按 Phase -1 到 Phase 6 执行。当前固定 CLAUDE_LANE_DEPLOY_ID=${DEPLOYMENT_ID}；所有 backup.sh 和用户本地 set-credentials.sh 命令必须复用它。命中 STOP、GUI 或权限条件时暂停说明；不得读取或回显任何秘密。六项验证全绿并完成 Phase 6 后，最后执行 /bin/bash scripts/bootstrap-complete.sh 写入非秘密完成标记，再退出本次 DeepSeek Claude Code。"

  (
    cd "$INSTALLED_LANE" || exit 1
    run_deepseek_claude "$INSTALLED_CLAUDE" \
      --no-session-persistence --setting-sources "" --strict-mcp-config --permission-mode default \
      --model "deepseek-v4-flash" --tools "Bash,Read,Edit,Write" \
      --allowedTools "Read($INSTALLED_LANE/**)" \
      --allowedTools "Bash(uname -s)" \
      --allowedTools "Bash(uname -m)" \
      --allowedTools "Bash(scutil --nc list)" \
      --allowedTools "Bash(pgrep -fl verge-mihomo)" \
      --allowedTools "Bash(defaults read -g AppleLocale)" \
      --allowedTools "Bash(/bin/bash scripts/bootstrap-complete.sh)" \
      "$agent_prompt" </dev/tty >/dev/tty 2>/dev/tty
  )
  agent_status=$?

  # The secret and all temporary Claude state disappear before any independent
  # verification or normal Anthropic login process can start.
  clear_temporary_environment
  remove_temp_config

  if [ "$agent_status" != "0" ]; then
    /bin/rm -f -- "$COMPLETION_FILE" 2>/dev/null || true
    warn "已安装的 Clash Verge 和 claude-lane 仓库包保留在本机，未删除。"
    warn "要撤回本次部署对 Clash 配置的改动，运行："
    warn "  cd '$INSTALLED_LANE' && bash scripts/rollback.sh $DEPLOYMENT_ID"
    warn "先看会动哪些文件：bash scripts/rollback.sh --list"
    die "部署 Agent 未正常结束；DeepSeek 临时状态已清理，未启动普通 Claude 登录"
  fi
  completion_value=$(/usr/bin/head -n 1 "$COMPLETION_FILE" 2>/dev/null || true)
  if [ "$completion_value" != "$DEPLOYMENT_ID" ]; then
    /bin/rm -f -- "$COMPLETION_FILE" 2>/dev/null || true
    warn "Agent 已退出，但没有有效的 Phase 6 完成标记。"
    warn "撤回本次部署：cd '$INSTALLED_LANE' && bash scripts/rollback.sh $DEPLOYMENT_ID"
    die "不能确认 Agent 完成 Phase 6；DeepSeek 临时状态已清理，未启动普通 Claude 登录"
  fi
}

verify_independently() {
  say "启动器正在独立复验六项并保存出口基线……"
  # unset 列表必须与 clear_temporary_environment 一致，否则「干净环境」名不副实：
  # 用户外壳里预置的同名变量会漏进复验。少一个都算防御深度缺口。
  if (
    unset DEPLOY_DEEPSEEK_KEY 2>/dev/null || true
    unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL
    unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
    unset CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL CLAUDE_CONFIG_DIR
    unset CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_SKIP_PROMPT_HISTORY
    unset CLAUDE_CODE_SUBPROCESS_ENV_SCRUB DISABLE_LOGIN_COMMAND DISABLE_UPDATES DISABLE_AUTOUPDATER
    unset CLAUDE_LANE_DEPLOY_ID
    cd "$INSTALLED_LANE" || exit 1
    /bin/bash scripts/verify.sh --save-baseline
  ) </dev/tty >/dev/tty 2>/dev/tty; then
    /bin/rm -f -- "$COMPLETION_FILE" 2>/dev/null || true
    COMPLETION_FILE=""
    return 0
  fi
  warn "六项验证没过，本机改动仍在。撤回本次部署："
  warn "  cd '$INSTALLED_LANE' && bash scripts/rollback.sh $DEPLOYMENT_ID"
  warn "对照 docs/troubleshooting.md 修完后可重跑：bash scripts/verify.sh --save-baseline"
  die "六项独立复验未全绿；不会启动普通 Claude 登录"
}

install_normal_entry_if_safe() {
  local_bin="$HOME/.local/bin"
  normal_entry="$local_bin/claude"
  existing_claude=$(command -v claude 2>/dev/null || true)

  if [ -n "$existing_claude" ]; then
    say "保留用户现有 Claude 命令：$existing_claude；本次正常登录仍使用已校验的受控二进制"
    NORMAL_CLAUDE="$INSTALLED_CLAUDE"
    return 0
  fi

  /bin/mkdir -p "$local_bin" || die "无法创建 $local_bin"
  if [ -e "$normal_entry" ] || [ -L "$normal_entry" ]; then
    warn "保留已有 ${normal_entry}；普通 Claude 请直接运行受控路径"
    NORMAL_CLAUDE="$INSTALLED_CLAUDE"
  else
    /bin/ln -s "$INSTALLED_CLAUDE" "$normal_entry" || die "无法创建普通 claude 入口"
    NORMAL_CLAUDE="$normal_entry"
  fi
}

start_normal_claude() {
  clear_temporary_environment
  say "六项验证全绿；现在启动不含 DeepSeek 环境的普通 Claude 登录流程。"
  (
    unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL
    unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
    unset CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL CLAUDE_CONFIG_DIR
    unset CLAUDE_CODE_SUBPROCESS_ENV_SCRUB DISABLE_LOGIN_COMMAND DISABLE_UPDATES DISABLE_AUTOUPDATER
    exec "$NORMAL_CLAUDE" --setting-sources "" --strict-mcp-config
  ) </dev/tty >/dev/tty 2>/dev/tty
  normal_status=$?
  [ "$normal_status" = "0" ] || die "专线已验证，但普通 Claude 登录流程未正常结束"
}

main() {
  require_base_tools
  load_manifest
  validate_manifest
  detect_platform
  check_macos_and_disk

  if [ "$DRY_RUN" = "1" ]; then
    say "dry-run 通过：manifest、macOS、架构与磁盘门禁有效；未执行下载或安装"
    return 0
  fi

  [ "$TEST_MODE" != "1" ] || die "测试模式禁止执行安装"
  require_install_tools
  require_tty
  make_temp_dir

  if [ -e "/Applications/Clash Verge.app" ]; then
    say "检测到现有 /Applications/Clash Verge.app；后续只校验并保留，不覆盖"
  fi
  existing_claude=$(command -v claude 2>/dev/null || true)
  if [ -n "$existing_claude" ]; then
    say "检测到现有 Claude 命令：${existing_claude}；本次使用隔离的固定版，不覆盖"
  fi

  stage_artifacts
  run_handshake
  install_claude_and_lane
  install_or_validate_clash
  run_interactive_agent
  verify_independently
  install_normal_entry_if_safe
  start_normal_claude
  say "claude-lane $lane_version 部署、六项复验与普通 Claude 登录流程完成"
}

main
