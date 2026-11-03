#!/usr/bin/env bash
# 环境探测：本机 Clash Verge / mihomo / Chrome / Claude Code 的版本与关键路径，并给出兼容性提示。
#
#   bash scripts/probe.sh              打印探测报告（agent 部署、排障的第一步）
#   bash scripts/probe.sh --sock       只输出 mihomo 控制 socket 路径（找不到时退出码 1）
#   bash scripts/probe.sh --candidates 列出 socket 候选路径（selftest 用）
#   . scripts/probe.sh                 被其他脚本 source：只设置 CFG / GEN / SOCK / LOG 并定义 lane_* 函数，不打印
#
# 为什么要有它：这些路径和进程名会随上游版本变，写死就会在某次升级后静默失效。
#   2026-11-02 实例：Verge 2.5.8 服务模式把 socket 挪到 /var/run/clash-verge-service/users/<uid>/，
#   而生成配置里写的 external-controller-unix 指向一个根本不存在的文件；内核日志也挪进了 root 才能读的目录。
#   verify.sh 写死 /tmp/verge/... 于是前三项直接崩溃。所有已知差异记录在 docs/compatibility.md。
#
# 测试钩子：CLAUDE_LANE_SOCK=<路径>（设了就只认它，不再自动探测）；CLAUDE_LANE_PS_ARGS=<伪造的 ps 参数文本>

CFG="${CLAUDE_LANE_CFG:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
GEN="$CFG/clash-verge.yaml"
LANE_MIN_MIHOMO="1.18.5"          # 模板③的 PROCESS-NAME-REGEX / PROCESS-PATH-REGEX 从这一版开始支持
LANE_VERGE_VERIFIED="2.5.1 2.5.8" # 实机验证过的 Verge 版本（与 docs/compatibility.md 同步维护）

# socket 候选，按可信度排序
lane_sock_candidates() {
  if [ -n "${CLAUDE_LANE_SOCK:-}" ]; then printf '%s\n' "${CLAUDE_LANE_SOCK}"; return; fi
  local args
  args="${CLAUDE_LANE_PS_ARGS-$(ps -axww -o args= 2>/dev/null)}"
  # ① 运行中内核的启动参数 —— 最准。Verge 2.5.8 服务模式下配置文件里写的路径是错的，以它为准
  printf '%s\n' "$args" | sed -n 's/.*verge-mihomo.* -ext-ctl-unix \([^ ]*\).*/\1/p'
  # ② 生成配置里的 external-controller-unix
  [ -r "$GEN" ] && sed -n 's/^external-controller-unix:[[:space:]]*//p' "$GEN" | tr -d "\"'"
  # ③ 老版本的固定位置（2.5.1 及更早）
  printf '%s\n' /tmp/verge/verge-mihomo.sock
}

# 第一个真能应答 /version 的 socket
lane_find_sock() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] && [ -S "$s" ] || continue
    if curl -s --max-time 3 --unix-socket "$s" http://localhost/version >/dev/null 2>&1; then
      printf '%s\n' "$s"; return 0
    fi
  done < <(lane_sock_candidates | awk 'NF && !seen[$0]++')
  return 1
}

# 内核日志：读得到才返回。Verge 2.5.8 服务模式写在 /Library/Application Support/clash-verge-service/（root），读不到是正常的
lane_find_log() {
  local f
  for f in "$CFG/service-logs/service/service_latest.log" "$CFG/logs/service/service_latest.log"; do
    [ -r "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

lane_plist_ver() { plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist" 2>/dev/null; }
lane_mihomo_ver() {
  [ -n "${1:-}" ] || return 1
  curl -s --max-time 3 --unix-socket "$1" http://localhost/version 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null
}
# a >= b ?（版本号逐段比较，忽略前缀 v 和非数字后缀）
lane_ver_ge() {
  python3 - "$1" "$2" <<'PY'
import re, sys
f = lambda s: [int(x) for x in re.findall(r"\d+", s)[:3]]
sys.exit(0 if f(sys.argv[1]) >= f(sys.argv[2]) else 1)
PY
}

SOCK=$(lane_find_sock || true)
LOG=$(lane_find_log || true)

# 被 source 时到此为止
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0 2>/dev/null; fi

case "${1:-}" in
  --sock)       [ -n "$SOCK" ] && { printf '%s\n' "$SOCK"; exit 0; }; exit 1 ;;
  --candidates) lane_sock_candidates | awk 'NF && !seen[$0]++'; exit 0 ;;
esac

ok()   { printf '  \033[32m✅ %s\033[0m\n' "$1"; }
bad()  { printf '  \033[31m❌ %s\033[0m\n' "$1"; }
warn() { printf '  \033[33m⚠️  %s\033[0m\n' "$1"; }
row()  { printf '  %s：%s\n' "$1" "$2"; }

VERGE_VER=$(lane_plist_ver "/Applications/Clash Verge.app")
MIHOMO_VER=$(lane_mihomo_ver "$SOCK")
CHROME_INSTALLED=$(lane_plist_ver "/Applications/Google Chrome.app")
CHROME_RUNNING=$(ps -axww -o comm= | sed -n 's#.*Google Chrome Framework.framework/Versions/\([^/]*\)/.*#\1#p' | sort -u | tr '\n' ' ' | sed 's/ $//')
CC_LINK=$(command -v claude 2>/dev/null)
CC_REAL=""
[ -n "$CC_LINK" ] && CC_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CC_LINK" 2>/dev/null)

echo "== claude-lane 环境探测 =="
row "Clash Verge"   "${VERGE_VER:-未安装/读不到}"
row "mihomo 内核"   "${MIHOMO_VER:-连不上}"
row "控制 socket"   "${SOCK:-找不到}"
row "内核日志"      "${LOG:-读不到（Verge 2.5.8 起在 root 目录，正常；verify.sh 自动改用 API/路由检查）}"
row "Chrome"        "已安装 ${CHROME_INSTALLED:-无}；运行中 ${CHROME_RUNNING:-未运行}"
row "Claude Code"   "${CC_REAL:-未安装}"
echo
echo "兼容性提示（详见 docs/compatibility.md）："
N=0
if [ -z "$SOCK" ]; then
  bad "找不到能应答的 mihomo socket：Clash 没在跑，或遇到了没记录过的新版本（按 docs/compatibility.md「遇到新版本」处理）"; N=$((N+1))
  note_c=$(lane_sock_candidates | awk 'NF && !seen[$0]++' | tr '\n' ' ')
  printf '     试过的候选：%s\n' "$note_c"
elif [ -n "$MIHOMO_VER" ] && ! lane_ver_ge "$MIHOMO_VER" "$LANE_MIN_MIHOMO"; then
  bad "mihomo ${MIHOMO_VER} 太旧：模板③用到 PROCESS-NAME-REGEX / PROCESS-PATH-REGEX，需要 ≥ v${LANE_MIN_MIHOMO}，先升级 Clash Verge"; N=$((N+1))
else
  ok "mihomo ${MIHOMO_VER} 支持模板③的正则进程规则（≥ v${LANE_MIN_MIHOMO}）"
fi
if [ -n "$VERGE_VER" ]; then
  case " $LANE_VERGE_VERIFIED " in
    *" $VERGE_VER "*) ok "Clash Verge ${VERGE_VER} 是实机验证过的版本" ;;
    *) warn "Clash Verge ${VERGE_VER} 没有实机验证记录：部署后 verify.sh 必须全绿，且第 1、5 项要真的执行了（不能是跳过）；有新差异补进 docs/compatibility.md" ;;
  esac
fi
CHROME_OLD=$(printf '%s\n' $CHROME_RUNNING | grep -vxF "${CHROME_INSTALLED:-none}" | tr '\n' ' ' | sed 's/ $//')
if [ -n "$CHROME_INSTALLED" ] && [ -n "$CHROME_OLD" ]; then
  warn "Chrome 已下载新版 ${CHROME_INSTALLED}，但还有进程在跑旧版 ${CHROME_OLD}：重启后进程名可能变，重启 Chrome 后再跑一次 verify.sh"
fi
case "$CC_REAL" in
  */.local/share/claude/versions/*)
    ok "Claude Code 是原生安装版：mihomo 看到的进程名是版本号「${CC_REAL##*/}」，靠模板③的 PROCESS-PATH-REGEX 覆盖" ;;
esac
[ "$N" -eq 0 ] || exit 1
