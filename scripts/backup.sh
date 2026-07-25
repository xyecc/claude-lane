#!/usr/bin/env bash
# 为【本次部署】创建独立备份目录，把传入的文件原样存进去 + 写一份清单。
# 用法：bash scripts/backup.sh <文件1> [文件2 ...]
# 输出：最后一行是备份目录的绝对路径（调用方拿去记录，回滚时用）
#
# 为什么不用「同目录 .bak-月日时分」：多次部署后满地都是 .bak 文件，
# 回滚时根本分不清哪几个属于同一次操作（早期版本让人「取时间最早的那份」，
# 部署过几次之后那份可能是几个月前的状态，会恢复过头）。
set -euo pipefail

CFG="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
ROOT="$CFG/claude-lane-backups"
DIR="$ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIR/files"

VERGE_VER=$(plutil -extract CFBundleShortVersionString raw \
  "/Applications/Clash Verge.app/Contents/Info.plist" 2>/dev/null || echo unknown)

{
  echo "# claude-lane 备份清单（回滚时按本文件逐行还原）"
  printf "created_at\t%s\n" "$(date "+%F %T")"
  printf 'clash_verge\t%s\n' "$VERGE_VER"
} > "$DIR/manifest.tsv"

n=0
for f in "$@"; do
  if [ ! -f "$f" ]; then
    printf 'missing\t%s\n' "$f" >> "$DIR/manifest.tsv"
    continue
  fi
  n=$((n+1))
  cp -p "$f" "$DIR/files/$n"
  printf 'file\t%s\t%s\n' "$n" "$f" >> "$DIR/manifest.tsv"
done

echo "已备份 $n 个文件 → $DIR" >&2
echo "$DIR"
