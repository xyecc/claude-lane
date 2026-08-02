#!/bin/bash
# 由 bootstrap 启动的 Agent 在 Phase 6 最后调用。只写非秘密完成标记；
# 父启动器仍会独立执行 verify.sh，不能用本标记代替六项验证。
set -u
set -o pipefail
umask 077

DEPLOY_ID=${CLAUDE_LANE_DEPLOY_ID:-}
TARGET=${CLAUDE_LANE_COMPLETION_FILE:-}
STATUS_DIR="$HOME/Library/Application Support/claude-lane/bootstrap-status"
LANE_ROOT="$HOME/Library/Application Support/claude-lane"

printf '%s' "$DEPLOY_ID" | LC_ALL=C /usr/bin/grep -Eq '^[0-9]{8}-[0-9]{6}$' || {
  printf '缺少有效的 CLAUDE_LANE_DEPLOY_ID\n' >&2
  exit 2
}
[ "$TARGET" = "$STATUS_DIR/complete.$DEPLOY_ID" ] || {
  printf '完成标记路径无效\n' >&2
  exit 2
}
[ ! -L "$LANE_ROOT" ] && [ ! -L "$STATUS_DIR" ] && [ ! -L "$TARGET" ] || {
  printf '完成标记路径不能是符号链接\n' >&2
  exit 2
}

/bin/mkdir -p "$STATUS_DIR" || exit 1
/bin/chmod 700 "$STATUS_DIR" || exit 1
TEMP_TARGET="$TARGET.tmp.$$"
[ ! -e "$TEMP_TARGET" ] && [ ! -L "$TEMP_TARGET" ] || {
  printf '完成标记临时路径已存在\n' >&2
  exit 2
}
trap '/bin/rm -f -- "$TEMP_TARGET" 2>/dev/null || true' EXIT INT TERM HUP
printf '%s\n' "$DEPLOY_ID" >"$TEMP_TARGET" || exit 1
/bin/chmod 600 "$TEMP_TARGET" || exit 1
/bin/mv -f -- "$TEMP_TARGET" "$TARGET" || exit 1
trap - EXIT INT TERM HUP
printf 'BOOTSTRAP_PHASE6_MARKED\n'
