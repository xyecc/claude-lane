#!/usr/bin/env bash
# 回滚到某次部署【之前】的状态。默认回滚**最近一次**（不是最早那次）。
#
# 用法：
#   bash scripts/rollback.sh --list              列出所有备份点
#   bash scripts/rollback.sh                     回滚最近一次部署
#   bash scripts/rollback.sh 20260725-153012     回滚指定备份点
set -euo pipefail

CFG="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
ROOT="$CFG/claude-lane-backups"
SOCK="/tmp/verge/verge-mihomo.sock"

[ -d "$ROOT" ] || { echo "没有任何备份点（$ROOT 不存在）"; exit 1; }

if [ "${1:-}" = "--list" ]; then
  echo "备份点（新 → 旧）："
  for d in $(ls -1r "$ROOT" 2>/dev/null); do
    printf '  %s  ' "$d"
    grep -c '^file' "$ROOT/$d/manifest.tsv" 2>/dev/null | tr -d '\n'
    printf ' 个文件\n'
  done
  exit 0
fi

TARGET="${1:-$(ls -1r "$ROOT" | head -1)}"
DIR="$ROOT/$TARGET"
[ -d "$DIR" ] || { echo "找不到备份点 $TARGET（用 --list 看有哪些）"; exit 1; }

echo "将从备份点 $TARGET 还原以下文件："
awk -F'\t' '$1=="file"{print "  " $3}' "$DIR/manifest.tsv"
printf '确认还原？[y/N] '
read -r ans
case "$ans" in [yY]*) ;; *) echo "已取消"; exit 0;; esac

# 还原前先把「当前状态」也存一份，免得回滚本身变成不可逆操作
SAFETY="$ROOT/prerollback-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SAFETY/files"; cp "$DIR/manifest.tsv" "$SAFETY/manifest.tsv"
awk -F'\t' '$1=="file"{print $2 "\t" $3}' "$DIR/manifest.tsv" | while IFS=$'\t' read -r n path; do
  [ -f "$path" ] && cp -p "$path" "$SAFETY/files/$n"
done

awk -F'\t' '$1=="file"{print $2 "\t" $3}' "$DIR/manifest.tsv" | while IFS=$'\t' read -r n path; do
  cp -p "$DIR/files/$n" "$path" && echo "  ✅ 已还原 $path"
done

echo
echo "文件已还原（回滚前的状态存在 $SAFETY，后悔了可以再滚回来）。"
echo "接下来必须让配置重新生效，二选一："
echo "  ① 打开 Clash Verge →「订阅」页点一下当前订阅卡片（推荐）"
echo "  ② 或热重载：curl -X PUT --unix-socket $SOCK \"http://localhost/configs?force=true\" \\"
echo "       -H 'Content-Type: application/json' -d '{\"path\":\"$CFG/clash-verge.yaml\"}'"
echo
echo "然后确认两件事：内核活着（curl --unix-socket $SOCK http://localhost/version）、能正常上网。"
