#!/usr/bin/env bash
# Claude 专线一键验证（六项）。全绿 = 部署成功；红项对照 docs/troubleshooting.md
# 依赖：macOS 自带的 bash/curl/python3，无需额外安装

# 依赖自检：缺工具就直接说清楚怎么装，别让脚本跑到一半才炸
if [ "$(uname)" != "Darwin" ]; then
  printf '\033[31m本脚本只支持 macOS（用到 scutil / stat -f 等 macOS 专用命令）。其他平台见 docs/porting.md。\033[0m\n'
  exit 1
fi
MISSING=""
for c in python3 curl; do command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"; done
if [ -n "$MISSING" ]; then
  printf '\033[31m缺少依赖:%s\033[0m\n' "$MISSING"
  printf '  python3 缺失 → 跑一次 xcode-select --install（装 macOS 命令行工具，含 python3）\n'
  printf '  curl 缺失   → 极少见，通常是 PATH 被改坏了，检查你的 ~/.zshrc\n'
  exit 1
fi

# --save-baseline：把这次实测到的真实出口 IP 记为基线，以后每次验证都跟它比
SAVE_BASELINE=0
[ "${1:-}" = "--save-baseline" ] && SAVE_BASELINE=1

HERE="$(cd "$(dirname "$0")" && pwd)"
# socket / 内核日志的位置随 Verge 版本变（2.5.8 起 socket 在 /var/run/clash-verge-service/…，日志在 root 目录读不到），
# 一律交给 probe.sh 自动探测，别再写死（v1.2.1 写死 /tmp/verge/… 在 2.5.8 上直接崩了三项）。见 docs/compatibility.md
. "$HERE/probe.sh"      # 设置 CFG / GEN / SOCK（找不到为空）/ LOG（读不到为空）
STATE="$CFG/claude-lane-state.json"
FAIL=0
# 版本号的唯一来源是仓库根目录的 VERSION 文件（别再往脚本里写死——v1.1.1 就写串过）
REPO_VERSION=$(tr -d '\r\n ' < "$(cd "$(dirname "$0")/.." && pwd)/VERSION" 2>/dev/null)
REPO_VERSION=${REPO_VERSION:-unknown}

ok()   { printf '  \033[32m✅ %s\033[0m\n' "$1"; }
bad()  { printf '  \033[31m❌ %s\033[0m\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '     %s\n' "$1"; }
warn() { printf '  \033[33m⚠️  %s\033[0m\n' "$1"; }
# 把 lanecheck.py 的 OK/NG/WARN/NOTE 行渲染成彩色（只渲染，不计数；计数看 lanecheck 的退出码）
render() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "OK "*)   printf '  \033[32m✅ %s\033[0m\n' "${line#OK }" ;;
      "NG "*)   printf '  \033[31m❌ %s\033[0m\n' "${line#NG }" ;;
      "WARN "*) warn "${line#WARN }" ;;
      "NOTE "*) note "${line#NOTE }" ;;
      *)        note "$line" ;;
    esac
  done
}
api() { curl -sS --max-time 8 --unix-socket "$SOCK" "http://localhost/$1" 2>/dev/null; }

# 自动发现：静态节点服务器 IP、混合端口
STATIC_IP=$(python3 - "$GEN" <<'PY'
import io, re, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'name:\s*"?[^"\n]*US-Static[^"\n]*"?[\s\S]{0,200}?server:\s*"?([\w.\-]+)"?', s)
print(m.group(1) if m else "")
PY
)
# 端口自动发现：mixed-port → port(HTTP) → socks-port，都没有才用默认 7897
SCHEME="http"
PORT=$(grep -E '^mixed-port:' "$GEN" | head -1 | grep -oE '[0-9]+')
[ -z "$PORT" ] && PORT=$(grep -E '^port:' "$GEN" | head -1 | grep -oE '[0-9]+')
if [ -z "$PORT" ]; then
  PORT=$(grep -E '^socks-port:' "$GEN" | head -1 | grep -oE '[0-9]+')
  [ -n "$PORT" ] && SCHEME="socks5h"
fi
PORT=${PORT:-7897}
PROXY="$SCHEME://127.0.0.1:$PORT"

echo "== Claude 专线验证 =="
echo "   静态节点服务器: ${STATIC_IP:-未找到} | 本地代理端口: $PORT"
[ -z "$STATIC_IP" ] && { bad "生成配置里找不到 US-Static 节点（Phase 3/4 没完成？）"; echo; }
[ -n "$LOG" ] || note "内核日志读不到（Verge 2.5.8 起写在 root 目录，正常）→ 第 1 项改用路由检查、第 5 项改用实时连接扫描"

echo "[1/6] 内核与 TUN"
if [ -n "$SOCK" ]; then
  ok "mihomo API 可达（$(lane_mihomo_ver "$SOCK")，${SOCK}）"
else
  bad "mihomo API 不可达：Clash 没在跑，或 socket 不在已知位置（跑 bash scripts/probe.sh 看试过哪些路径，对照 docs/compatibility.md）"
fi
if [ -n "$LOG" ] && tail -50 "$LOG" 2>/dev/null | grep -q "Start TUN listening error"; then
  bad "TUN 启动失败（add route: file exists → 有其他 VPN 占路由，见排障手册第 1 条）"
elif [ -n "$SOCK" ]; then
  # 不依赖日志的判法：TUN 开着，且发往 Anthropic 的流量确实路由到 Clash 的 TUN 网卡
  TUN_INFO=$(api configs | python3 -c 'import json,sys; t=json.load(sys.stdin).get("tun") or {}; print("on" if t.get("enable") else "off", t.get("device") or "")' 2>/dev/null)
  TUN_STATE=${TUN_INFO%% *}; TUN_DEV=${TUN_INFO#* }
  ROUTE_IF=$(route -n get 160.79.104.10 2>/dev/null | awk '/interface:/{print $2}')
  if [ "$TUN_STATE" != "on" ]; then
    bad "TUN 模式没开（Verge 设置里打开 TUN，保持规则模式）"
  elif { [ -n "$TUN_DEV" ] && [ "$ROUTE_IF" = "$TUN_DEV" ]; } || { [ -z "$TUN_DEV" ] && [ "${ROUTE_IF#utun}" != "$ROUTE_IF" ]; }; then
    ok "TUN 已接管路由（Anthropic 流量走 ${ROUTE_IF}）"
  else
    bad "Anthropic 流量路由到了 ${ROUTE_IF:-未知网卡}，不是 Clash 的 ${TUN_DEV:-TUN}——有别的 VPN 占着路由（排障手册第 1 条）"
  fi
else
  bad "API 不可达、日志也读不到，无法判断 TUN 状态"
fi

echo "[2/6] 策略组状态"
if [ -z "$SOCK" ]; then
  bad "跳过：mihomo API 不可达（见第 1 项）"
else
api proxies | python3 -c '
import json, sys
data = json.load(sys.stdin)["proxies"]
fails = []
cl = data.get("Claude", {})
if "US-Static" in str(cl.get("now")): print("  \033[32m✅ Claude 组 → %s\033[0m" % cl.get("now"))
else: fails.append("Claude 组指向 %s（应指向静态节点）" % cl.get("now"))
uc = data.get("US-Chain", {})
if uc.get("now"): print("  \033[32m✅ US-Chain 组 → %s\033[0m" % uc.get("now"))
else: fails.append("US-Chain 组不存在或未选节点")
wrong = [n for n,p in data.items()
         if p.get("type")=="Selector" and n not in ("Claude",) and "US-Static" in str(p.get("now"))]
if wrong: fails.append("这些组误选了静态节点（普通流量会走静态IP）: %s" % wrong)
else: print("  \033[32m✅ 无其他组误用静态节点\033[0m")
for f in fails: print("  \033[31m❌ %s\033[0m" % f)
sys.exit(1 if fails else 0)
' || FAIL=$((FAIL+1))
fi

echo "[3/6] 规则完整性"
# 不看"规则文本里有没有某几个字"，而是拿【此刻真实在跑】的浏览器 / Claude 进程（取法与 mihomo 相同）逐个去对规则：
# 进程名会随上游版本变（Chrome 156 的 Aperitif、Claude Code 原生版的版本号进程名），只查文本会一直假绿。
if [ -z "$SOCK" ]; then
  bad "跳过：mihomo API 不可达（见第 1 项）"
else
  OUT=$(api rules | python3 "$HERE/lanecheck.py" rules - 2>&1); RC=$?
  printf '%s\n' "$OUT" | render
  [ "$RC" -eq 0 ] || FAIL=$((FAIL+1))
fi

echo "[4/6] 出口双验（关键）"
# 先探本地代理端口；不通时直接给原因，跳过双验避免误报成"出口错误"
if ! curl -sS --max-time 8 --proxy "$PROXY" -o /dev/null https://api.ipify.org 2>/dev/null; then
  bad "本地代理端口不通（${PROXY}），跳过出口双验"
  note "确认 Verge 设置→端口 里开启的端口类型和号码；本脚本按 mixed-port > port > socks-port 顺序自动发现"
else
  TRACE=$(curl -sS --max-time 25 --proxy "$PROXY" https://claude.ai/cdn-cgi/trace 2>/dev/null)
  TRACE_IP=$(printf '%s' "$TRACE" | grep '^ip=' | cut -d= -f2 | tr -d '\r ')
  TRACE_LOC=$(printf '%s' "$TRACE" | grep '^loc=' | cut -d= -f2 | tr -d '\r ')
  NORM_IP=$(curl -sS --max-time 15 --proxy "$PROXY" https://api.ipify.org 2>/dev/null | tr -d '\r ')
  BASE_IP=$(python3 -c "
import json,sys
try: print(json.load(open('$STATE')).get('claude_exit_ip',''))
except Exception: print('')" 2>/dev/null)

  # 有基线：跟【上次实测到的真实出口】比，能发现出口悄悄变了
  # 无基线（首次）：**不要求**出口等于配置里的服务器地址——服务商的入口地址常常不等于最终住宅出口 IP，
  #                 那样判会让这类用户永远建立不了基线（v1.1.0 的死锁 bug）。首次只验三件事：
  #                 出口拿得到、国家是 US、且与普通流量出口不同（证明确实走了专线）。
  if [ -n "$BASE_IP" ]; then
    if [ -n "$TRACE_IP" ] && [ "$TRACE_IP" = "$BASE_IP" ]; then
      ok "claude.ai 出口 = ${TRACE_IP} (${TRACE_LOC:-?}) <- 与基线一致"
    else
      bad "claude.ai 出口变了：现在 ${TRACE_IP:-请求失败} (${TRACE_LOC:-?})，基线是 ${BASE_IP}"
      note "静态 IP 换了/到期了？确认无误后用 bash scripts/verify.sh --save-baseline 更新基线"
    fi
  elif [ -z "$TRACE_IP" ]; then
    bad "拿不到 claude.ai 的出口 IP（链路不通？先看第 1、2 项）"
  elif [ -n "$NORM_IP" ] && [ "$TRACE_IP" = "$NORM_IP" ]; then
    bad "Claude 出口和普通流量出口相同（${TRACE_IP}）—— 说明 Claude 流量没走专线"
  else
    ok "claude.ai 出口 = ${TRACE_IP} (${TRACE_LOC:-?}) <- 与普通流量分离, 正常"
    if [ -n "$STATIC_IP" ] && [ "$TRACE_IP" != "$STATIC_IP" ]; then
      note "出口 ${TRACE_IP} 与配置里的服务器地址 ${STATIC_IP} 不同——这很正常（服务商入口≠住宅出口）"
    fi
    note "尚未记录出口基线，跑一次记下来：bash scripts/verify.sh --save-baseline"
  fi

  if [ -n "$TRACE_LOC" ] && [ "$TRACE_LOC" != "US" ]; then
    bad "出口国家是 ${TRACE_LOC}，不是 US（静态 IP 被回收换区了？）"
  fi

  # 普通流量必须与【Claude 的真实出口】不同（不是与配置里的服务器地址比）
  EXPECT_EXIT="${BASE_IP:-$TRACE_IP}"
  if [ -z "$NORM_IP" ]; then
    bad "普通流量出口请求失败"
  elif [ -n "$EXPECT_EXIT" ] && [ "$NORM_IP" = "$EXPECT_EXIT" ]; then
    bad "普通流量出口 = ${NORM_IP}，与 Claude 出口相同（有组误选了静态节点，见第 2 项）"
  else
    ok "普通流量出口 = ${NORM_IP} <- 机场节点, 未误走静态"
  fi
fi

echo "[5/6] 漏流扫描"
# ① 实时连接（不依赖日志，任何 Verge 版本都能做）：Claude 相关连接是否都走了 Claude 组、
#    浏览器 / Claude 进程有没有漏网的 UDP（QUIC）。只能看到此刻开着的连接，所以开着 claude.ai 跑更准。
if [ -n "$SOCK" ]; then
  OUT=$(api connections | python3 "$HERE/lanecheck.py" conns - 2>&1); RC=$?
  printf '%s\n' "$OUT" | render
  [ "$RC" -eq 0 ] || FAIL=$((FAIL+1))
fi
# ② 内核日志（读得到才做，能看到激活以来的历史连接）
# 假设：mihomo 日志行首时间戳格式为 [YYYY-MM-DD HH:MM:SS…（靠字符串比较过滤激活前的旧日志）。
# 若日志格式变更，过滤会静默失效——激活前的旧漏流记录也会被算进来，出现莫名其妙的红项时先人工看日志时间。
if [ -n "$LOG" ]; then
  ACTIVATED_AT=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$GEN" 2>/dev/null)
  LEAK=$(awk -v start="[$ACTIVATED_AT" 'start == "[" || $0 >= start' "$LOG" 2>/dev/null \
         | tail -800 | grep -iE "claude|anthropic|datadoghq|statsig" | grep " using " \
         | grep -v "using Claude\[" | grep -v "using REJECT" | tail -5)
  if [ -z "$LEAK" ]; then
    ok "日志：本次激活后无 Claude/Anthropic 流量走到非 Claude 组"
  else
    bad "日志：本次激活后发现漏流记录（Claude 流量走了别的组）："
    echo "$LEAK" | while IFS= read -r l; do note "$l"; done
  fi
elif [ -z "$SOCK" ]; then
  bad "API 不可达、日志也读不到，漏流扫描无法进行"
fi

echo "[6/6] 其他 VPN 检测"
OTHERVPN=$(scutil --nc list 2>/dev/null | grep "(Connected)" | grep -iv tailscale)
if [ -z "$OTHERVPN" ]; then
  ok "无其他 VPN 在运行"
else
  bad "有其他 VPN 处于 Connected（会抢路由，必须断开）："
  note "$OTHERVPN"
fi

echo "[版本] 本机部署的模板版本 vs 仓库当前版本"
DEPLOYED_VERSION=$(python3 -c "
import json
try: print(json.load(open('$STATE')).get('template_version',''))
except Exception: print('')" 2>/dev/null)
if [ -z "$DEPLOYED_VERSION" ]; then
  note "本机还没记录部署版本（跑一次 bash scripts/verify.sh --save-baseline 记下来）"
elif [ "$DEPLOYED_VERSION" = "$REPO_VERSION" ]; then
  ok "版本一致（${REPO_VERSION}）"
elif [ "$SAVE_BASELINE" = "1" ]; then
  note "本机记录是 ${DEPLOYED_VERSION}；本次 --save-baseline 全绿则改记为 ${REPO_VERSION}（前提：已按 templates/ 对齐并在 GUI 激活）"
else
  warn "配置漂移：本机是 ${DEPLOYED_VERSION}，仓库已到 ${REPO_VERSION}"
  note "仓库模板更新不会自动同步到已部署的机器（见排障手册第 10 条）。"
  note "让 agent 按最新 templates/ 重新对齐一次，GUI 激活后再跑 bash scripts/verify.sh --save-baseline"
fi

echo
# 记录/更新出口基线（只在全绿时写，免得把出错状态记成基线）
if [ "$SAVE_BASELINE" = "1" ]; then
  if [ "$FAIL" -eq 0 ] && [ -n "${TRACE_IP:-}" ]; then
    VERGE_VER=$(plutil -extract CFBundleShortVersionString raw \
      "/Applications/Clash Verge.app/Contents/Info.plist" 2>/dev/null || echo unknown)
    python3 - "$STATE" "$TRACE_IP" "${TRACE_LOC:-}" "$VERGE_VER" "$(date '+%F')" "$REPO_VERSION" <<'PY'
import json, sys
state, ip, loc, ver, day, tpl = sys.argv[1:7]
try: d = json.load(open(state))
except Exception: d = {}
d.update({"template_version": tpl, "claude_exit_ip": ip, "country": loc,
          "clash_verge": ver, "baseline_saved_at": day})
d.setdefault("installed_at", day)
json.dump(d, open(state, "w"), ensure_ascii=False, indent=2)
PY
    printf '\033[32m已记录出口基线：%s (%s) → %s\033[0m\n' "$TRACE_IP" "${TRACE_LOC:-?}" "$STATE"
  else
    printf '\033[33m未记录基线：验证没有全绿，或没拿到出口 IP（先把红项修完再记）\033[0m\n'
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m== 六项全部通过，部署成功 ==\033[0m\n'
else
  printf '\033[31m== %s 项未通过，对照 docs/troubleshooting.md 处理后重跑 ==\033[0m\n' "$FAIL"
fi
exit "$FAIL"
