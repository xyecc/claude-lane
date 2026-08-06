#!/usr/bin/env bash
# 持久化非秘密安装进度。状态文件只保存固定枚举，不保存订阅、IP 或 Key。
set -euo pipefail
umask 077

STATE_ROOT="${CLAUDE_LANE_SETUP_ROOT:-$HOME/Library/Application Support/claude-lane}"
STATE_FILE="$STATE_ROOT/setup-progress.json"

usage() {
  cat <<'EOF'
用法：
  bash scripts/setup-state.sh get
  bash scripts/setup-state.sh show
  bash scripts/setup-state.sh set <状态> <原因码>
EOF
}

valid_state() {
  case "$1" in
    CLASH_INSTALLED|WAITING_FOR_SUBSCRIPTION|SUBSCRIPTION_IMPORTED|PROXY_REACHABLE|AIRPORT_VERIFIED|WAITING_FOR_ISP|ROUTING_CONFIGURED|VALIDATION_PASSED|COMPLETED) return 0 ;;
  esac
  return 1
}

valid_reason() {
  case "$1" in
    clash_installed|profiles_missing|subscription_not_imported|subscription_imported|proxy_reachable|airport_verified|isp_required|routing_configured|validation_passed|completed) return 0 ;;
  esac
  return 1
}

read_state() {
  if [ ! -e "$STATE_FILE" ]; then
    printf 'NOT_STARTED\n'
    return 0
  fi
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || {
    echo "安装进度文件类型不安全" >&2
    return 1
  }
  value=$(/usr/bin/plutil -extract state raw -o - "$STATE_FILE" 2>/dev/null) || {
    echo "安装进度文件损坏" >&2
    return 1
  }
  valid_state "$value" || {
    echo "安装进度包含未知状态" >&2
    return 1
  }
  printf '%s\n' "$value"
}

write_state() {
  state=$1
  reason=$2
  valid_state "$state" || { echo "未知安装状态：$state" >&2; return 2; }
  valid_reason "$reason" || { echo "未知安装原因码：$reason" >&2; return 2; }
  [ ! -L "$STATE_ROOT" ] && [ ! -L "$STATE_FILE" ] || {
    echo "安装进度路径不能是符号链接" >&2
    return 1
  }
  /bin/mkdir -p "$STATE_ROOT"
  /bin/chmod 700 "$STATE_ROOT"
  tmp="$STATE_ROOT/.setup-progress.$$"
  trap '/bin/rm -f -- "$tmp"' EXIT INT TERM
  updated_at=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '{\n  "schema": 1,\n  "state": "%s",\n  "platform": "darwin",\n  "reason": "%s",\n  "updated_at": "%s"\n}\n' \
    "$state" "$reason" "$updated_at" >"$tmp"
  /bin/chmod 600 "$tmp"
  /bin/mv -f -- "$tmp" "$STATE_FILE"
  trap - EXIT INT TERM
}

command_name="${1:-}"
case "$command_name" in
  get)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    read_state
    ;;
  show)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    printf 'SETUP_STATE=%s\n' "$(read_state)"
    ;;
  set)
    [ "$#" -eq 3 ] || { usage; exit 2; }
    write_state "$2" "$3"
    printf 'SETUP_STATE=%s\n' "$2"
    ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
