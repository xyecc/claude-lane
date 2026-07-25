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
    case "$d" in
      prerollback-*) tag="  ← 回滚快照（用它可撤销那次回滚）" ;;
      *)             tag="" ;;
    esac
    printf '  %s   还原 %s 个文件 / 删除 %s 个新建文件%s\n' "$d" "${f:-0}" "${c:-0}" "$tag"
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
# 不给 id 时默认回滚【最近一次部署】，不会误选回滚快照（prerollback-* 排序时会排在数字前面）。
# 要撤销上一次回滚，请显式传那个 prerollback-* 的 id（回滚结束时会打印出来）。
[ -n "$TARGET" ] || TARGET=$(ls -1r "$ROOT" | grep -v '^prerollback-' | head -1)
[ -n "$TARGET" ] || { echo "没有可回滚的部署备份点（只有回滚快照的话请显式指定 id，--list 可查看）"; exit 1; }

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

# 还原前把「当前状态」也存一份，让回滚本身也可后悔。
#
# 两个关键点（v1.2.0 这里都错过）：
# ① 记录的 kind 必须反映【当前】状态，不能照抄原清单：
#    当前文件在 → file（存副本，撤销回滚时还原）；当前文件不在 → created（撤销回滚时删除）。
#    照抄原清单的话，部署新建的那些文件会被记成 created，撤销回滚时不但不还原，反而再删一次。
# ② 目录名不能只用秒级时间戳：紧接着撤销刚才的回滚时会和 TARGET 撞名，
#    一旦撞名就成了「边读 manifest.tsv 边往同一个文件追加」→ 无限循环。用 mktemp 保证唯一。
SAFETY=$(mktemp -d "$ROOT/prerollback-$(date +%Y%m%d-%H%M%S)-XXXXXX")
mkdir -p "$SAFETY/files"
cp "$MAN" "$SAFETY/manifest-source.tsv"
{
  printf '# claude-lane 回滚快照（撤销回滚用）\n'
  printf 'snapshot_of\t%s\n' "$TARGET"
  printf 'created_at\t%s\n' "$(date '+%F %T')"
} > "$SAFETY/manifest.tsv"

i=0
while IFS=$'\t' read -r kind idx path; do
  case "$kind" in file|created) ;; *) continue ;; esac
  if [ -f "$path" ]; then
    i=$((i+1))
    cp -p "$path" "$SAFETY/files/$i"
    printf 'file\t%s\t%s\n' "$i" "$path" >> "$SAFETY/manifest.tsv"
  else
    printf 'created\t-\t%s\n' "$path" >> "$SAFETY/manifest.tsv"
  fi
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

文件已处理完。回滚前的状态已快照，**这次回滚也能撤销**：

  bash scripts/rollback.sh $(basename "$SAFETY")

接下来必须让配置重新生效，二选一：
  ① 打开 Clash Verge →「订阅」页点一下当前订阅卡片（推荐）
  ② 或热重载：
     curl -X PUT --unix-socket ${SOCK} "http://localhost/configs?force=true" \\
       -H 'Content-Type: application/json' -d '{"path":"${CFG}/clash-verge.yaml"}'

然后确认两件事：内核活着（curl --unix-socket ${SOCK} http://localhost/version）、能正常上网。
EOF
