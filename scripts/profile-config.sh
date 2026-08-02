#!/usr/bin/env bash
# 安全读取/登记 Clash Verge 增强文件：不向 Agent 输出 profiles.yaml 原文或订阅 URL。
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="${CLAUDE_LANE_CFG:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
PROFILES="$CFG/profiles.yaml"
HELPER="$HERE/macos-json.js"
OSASCRIPT="/usr/bin/osascript"

usage() {
  cat <<'EOF'
用法：
  bash scripts/profile-config.sh summary
  CLAUDE_LANE_DEPLOY_ID=<id> bash scripts/profile-config.sh register <proxies|groups|rules|merge> [uid]
EOF
}

[ -x "$OSASCRIPT" ] && [ -f "$HELPER" ] || { echo "缺少 macOS JXA 或辅助脚本"; exit 1; }
[ -f "$PROFILES" ] || { echo "找不到 Clash Verge profiles.yaml"; exit 1; }
[ ! -L "$PROFILES" ] || { echo "profiles.yaml 不能是符号链接"; exit 1; }

COMMAND="${1:-}"
case "$COMMAND" in
  summary)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    "$OSASCRIPT" -l JavaScript "$HELPER" profile-summary "$PROFILES"
    ;;
  register)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage; exit 2; }
    TYPE="$2"
    case "$TYPE" in
      proxies) PREFIX=p ;;
      groups)  PREFIX=g ;;
      rules)   PREFIX=r ;;
      merge)   PREFIX=m ;;
      *) echo "增强类型不受支持：${TYPE}"; exit 2 ;;
    esac
    [ -n "${CLAUDE_LANE_DEPLOY_ID:-}" ] || {
      echo "缺少 CLAUDE_LANE_DEPLOY_ID；拒绝创建独立备份点"
      exit 2
    }
    if [ "$#" -eq 3 ]; then
      UID_VALUE="$3"
    else
      UID_VALUE="${PREFIX}$(uuidgen | tr -d '-' | cut -c1-11)"
    fi
    printf '%s' "$UID_VALUE" | LC_ALL=C grep -Eq "^${PREFIX}[A-Za-z0-9]{11}$" || {
      echo "增强 uid 格式错误"
      exit 2
    }
    TARGET="$CFG/profiles/$UID_VALUE.yaml"
    [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ] || {
      echo "目标增强文件已经存在，拒绝覆盖"
      exit 3
    }
    mkdir -p "$CFG/profiles"
    BK=$(bash "$HERE/backup.sh" "$PROFILES" "$TARGET" | tail -1)
    CLEAN_TARGET=1
    cleanup_partial() {
      [ "${CLEAN_TARGET:-0}" = "1" ] && rm -f "$TARGET"
    }
    trap cleanup_partial EXIT INT TERM
    case "$TYPE" in
      merge) printf '{}\n' > "$TARGET" ;;
      *) printf 'prepend: []\n\nappend: []\n\ndelete: []\n' > "$TARGET" ;;
    esac
    chmod 600 "$TARGET"
    RESULT=$("$OSASCRIPT" -l JavaScript "$HELPER" profile-register \
      "$PROFILES" "$TYPE" "$UID_VALUE" "$(date +%s)")
    chmod 600 "$PROFILES"
    CLEAN_TARGET=0
    trap - EXIT INT TERM
    printf '%s\n' "$RESULT"
    printf 'TARGET_UID=%s\nBACKUP=%s\n' "$UID_VALUE" "$BK"
    ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
