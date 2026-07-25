#!/usr/bin/env bash
# 为【本次部署】备份文件。同一次部署可以多次调用，会写进同一个目录。
#
# 用法：
#   bash scripts/backup.sh <文件1> [文件2 ...]
#   CLAUDE_LANE_DEPLOY_ID=20260725-153012 bash scripts/backup.sh <文件...>   # 追加到同一次部署
#
# 输出：最后一行是备份目录的绝对路径（同时也是 deployment id 的目录名）
#
# 语义：
#   - 文件已存在 → 存一份副本，回滚时还原
#   - 文件不存在 → 记为 created，回滚时【删除】它（因为它是本次部署新建的，没有"改动前"可还原）
#
# 为什么不用「同目录 .bak-月日时分」：多次部署后满地 .bak，分不清哪几个属于同一次操作。
set -euo pipefail

CFG="${CLAUDE_LANE_CFG:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
ROOT="$CFG/claude-lane-backups"
DEPLOY_ID="${CLAUDE_LANE_DEPLOY_ID:-$(date +%Y%m%d-%H%M%S)}"
DIR="$ROOT/$DEPLOY_ID"
MAN="$DIR/manifest.tsv"
mkdir -p "$DIR/files"

if [ ! -f "$MAN" ]; then
  VERGE_VER=$(plutil -extract CFBundleShortVersionString raw \
    "/Applications/Clash Verge.app/Contents/Info.plist" 2>/dev/null || echo unknown)
  {
    printf '# claude-lane 备份清单（rollback.sh 按本文件逐行还原）\n'
    printf 'deployment_id\t%s\n' "$DEPLOY_ID"
    printf 'created_at\t%s\n' "$(date '+%F %T')"
    printf 'clash_verge\t%s\n' "$VERGE_VER"
  } > "$MAN"
fi

# 续号：同一次部署多次调用时不覆盖已存副本
n=$(grep -cE '^file' "$MAN" 2>/dev/null || true)
n=${n:-0}

saved=0; marked=0
for f in "$@"; do
  # 已经记录过就跳过，避免重复调用把「部署中途的状态」当成「部署前的状态」覆盖掉
  if awk -F'\t' -v p="$f" '$3==p{found=1} END{exit !found}' "$MAN" 2>/dev/null; then
    continue
  fi
  if [ -f "$f" ]; then
    n=$((n+1))
    cp -p "$f" "$DIR/files/$n"
    printf 'file\t%s\t%s\n' "$n" "$f" >> "$MAN"
    saved=$((saved+1))
  else
    printf 'created\t-\t%s\n' "$f" >> "$MAN"
    marked=$((marked+1))
  fi
done

printf '已备份 %s 个文件、标记 %s 个待新建文件 → %s\n' "$saved" "$marked" "$DIR" >&2
echo "$DIR"
