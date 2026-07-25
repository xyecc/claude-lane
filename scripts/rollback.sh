#!/usr/bin/env bash
# 回滚到某次部署【之前】的状态。默认回滚**最近一次**（不是最早那次）。
#
# 用法：
#   bash scripts/rollback.sh --list              列出所有备份点
#   bash scripts/rollback.sh                     回滚最近一次部署
#   bash scripts/rollback.sh 20260725-153012     回滚指定备份点
#   bash scripts/rollback.sh --yes               不询问直接回滚（脚本/agent 用）
set -euo pipefail

CFG="${CLAUDE_LANE_CFG:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
ROOT="$CFG/claude-lane-backups"
SOCK="/tmp/verge/verge-mihomo.sock"

[ -d "$ROOT" ] || { echo "没有任何备份点（${ROOT} 不存在）"; exit 1; }

if [ "${1:-}" = "--list" ]; then
  echo "备份点（新 → 旧）："
  for d in $(ls -1r "$ROOT" 2>/dev/null); do
    man="$ROOT/$d/manifest.tsv"
    [ -f "$man" ] || continue
    f=$(grep -cE '^file' "$man" 2>/dev/null || true)
    c=$(grep -cE '^created' "$man" 2>/dev/null || true)
    printf '  %s   还原 %s 个文件 / 删除 %s 个新建文件\n' "$d" "${f:-0}" "${c:-0}"
  done
  exit 0
fi

ASSUME_YES=0
TARGET=""
for a in "$@"; do
  case "$a" in
    --yes) ASSUME_YES=1 ;;
    -*) echo "未知参数：$a"; exit 1 ;;
    *) TARGET="$a" ;;
  esac
done
[ -n "$TARGET" ] || TARGET=$(ls -1r "$ROOT" | head -1)

DIR="$ROOT/$TARGET"
MAN="$DIR/manifest.tsv"
[ -f "$MAN" ] || { echo "找不到备份点 ${TARGET}（用 --list 看有哪些）"; exit 1; }

echo "备份点 ${TARGET} 将执行："
awk -F'\t' '$1=="file"{print "  还原  " $3}  $1=="created"{print "  删除  " $3 "  （本次部署新建）"}' "$MAN"

if [ "$ASSUME_YES" != "1" ]; then
  printf '确认？[y/N] '
  read -r ans
  case "$ans" in [yY]*) ;; *) echo "已取消"; exit 0;; esac
fi

# 还原前把「当前状态」也存一份，让回滚本身也可后悔
SAFETY="$ROOT/prerollback-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SAFETY/files"
cp "$MAN" "$SAFETY/manifest-source.tsv"
i=0
while IFS=$'\t' read -r kind idx path; do
  case "$kind" in file|created) ;; *) continue ;; esac
  i=$((i+1))
  [ -f "$path" ] && cp -p "$path" "$SAFETY/files/$i" || true
  printf '%s\t%s\t%s\n' "$kind" "$i" "$path" >> "$SAFETY/manifest.tsv"
done < "$MAN"

# 执行还原 / 删除
while IFS=$'\t' read -r kind idx path; do
  case "$kind" in
    file)
      if [ -f "$DIR/files/$idx" ]; then
        cp -p "$DIR/files/$idx" "$path" && echo "  ✅ 已还原 ${path}"
      else
        echo "  ⚠️ 备份副本缺失，跳过：${path}"
      fi
      ;;
    created)
      if [ -f "$path" ]; then
        rm -f "$path" && echo "  🗑  已删除本次新建的 ${path}"
      fi
      ;;
  esac
done < "$MAN"

cat <<EOF

文件已处理完（回滚前的状态存在 ${SAFETY} ，后悔了可以从那里再取回来）。

接下来必须让配置重新生效，二选一：
  ① 打开 Clash Verge →「订阅」页点一下当前订阅卡片（推荐）
  ② 或热重载：
     curl -X PUT --unix-socket ${SOCK} "http://localhost/configs?force=true" \\
       -H 'Content-Type: application/json' -d '{"path":"${CFG}/clash-verge.yaml"}'

然后确认两件事：内核活着（curl --unix-socket ${SOCK} http://localhost/version）、能正常上网。
EOF
