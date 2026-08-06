#!/usr/bin/env bash
# 只判断 Clash Verge 是否已有当前远程订阅；绝不输出订阅 URL。
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="${CLAUDE_LANE_CFG:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
PROFILES="$CFG/profiles.yaml"
STATE_TOOL="$HERE/setup-state.sh"

[ -f "$STATE_TOOL" ] || { echo "缺少安装状态工具" >&2; exit 1; }

if [ ! -e "$PROFILES" ]; then
  bash "$STATE_TOOL" set WAITING_FOR_SUBSCRIPTION profiles_missing >/dev/null
  printf 'SETUP_STATE=WAITING_FOR_SUBSCRIPTION\n'
  printf 'NEXT_ACTION=OPEN_CLASH_AND_IMPORT_SUBSCRIPTION\n'
  exit 0
fi
[ -f "$PROFILES" ] && [ ! -L "$PROFILES" ] || {
  echo "profiles.yaml 文件类型不安全" >&2
  exit 1
}

# Clash 首次启动后可能先写出 `current: null`，直到用户真正选中一条订阅。
# 这是正常等待状态，不应交给严格 profile 解析器当成损坏；重复 current 或
# 其他非空但不受支持的格式仍然失败关闭。
if current_value=$(/usr/bin/awk '
  /^current:/ { count += 1; value = $0; sub(/^current:[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value) }
  END { if (count != 1) exit 1; print value }
' "$PROFILES"); then
  case "$current_value" in
    ''|null|NULL|Null|'~'|'""'|"''")
      bash "$STATE_TOOL" set WAITING_FOR_SUBSCRIPTION subscription_not_imported >/dev/null
      printf 'SETUP_STATE=WAITING_FOR_SUBSCRIPTION\n'
      printf 'NEXT_ACTION=OPEN_CLASH_AND_IMPORT_SUBSCRIPTION\n'
      exit 0
      ;;
  esac
else
  echo "profiles.yaml 的 current 格式不唯一或不受支持" >&2
  exit 1
fi

summary=$(bash "$HERE/profile-config.sh" summary) || exit 1
case "$summary" in
  *'"current_type":"remote"'*'"url_ready":true'*)
    bash "$STATE_TOOL" set SUBSCRIPTION_IMPORTED subscription_imported >/dev/null
    printf 'SETUP_STATE=SUBSCRIPTION_IMPORTED\n'
    printf 'NEXT_ACTION=CONTINUE_PREFLIGHT\n'
    ;;
  *)
    bash "$STATE_TOOL" set WAITING_FOR_SUBSCRIPTION subscription_not_imported >/dev/null
    printf 'SETUP_STATE=WAITING_FOR_SUBSCRIPTION\n'
    printf 'NEXT_ACTION=OPEN_CLASH_AND_IMPORT_SUBSCRIPTION\n'
    ;;
esac
