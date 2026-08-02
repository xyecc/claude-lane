#!/usr/bin/env bash
# Claude 专线一键验证（六项）。全绿 = 部署成功；红项对照 docs/troubleshooting.md
# 依赖：macOS 自带的 bash/curl/osascript，无需额外安装

umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
JSON_HELPER="$HERE/macos-json.js"
OSASCRIPT="/usr/bin/osascript"

# 依赖自检：缺工具就直接说清楚怎么装，别让脚本跑到一半才炸
if [ "$(uname)" != "Darwin" ]; then
  printf '\033[31m本脚本只支持 macOS（用到 scutil / stat -f 等 macOS 专用命令）。其他平台见 docs/porting.md。\033[0m\n'
  exit 1
fi
MISSING=""
command -v curl >/dev/null 2>&1 || MISSING="$MISSING curl"
[ -x "$OSASCRIPT" ] || MISSING="$MISSING osascript"
[ -f "$JSON_HELPER" ] || MISSING="$MISSING macos-json.js"
if [ -n "$MISSING" ]; then
  printf '\033[31m缺少依赖:%s\033[0m\n' "$MISSING"
  printf '  curl 缺失   → 极少见，通常是 PATH 被改坏了，检查你的 ~/.zshrc\n'
  printf '  JXA 缺失    → osascript 应由 macOS 自带；确认仓库 scripts/macos-json.js 完整\n'
  exit 1
fi

# --save-baseline：把这次实测到的真实出口 IP 记为基线，以后每次验证都跟它比
SAVE_BASELINE=0
[ "${1:-}" = "--save-baseline" ] && SAVE_BASELINE=1

CFG="${CLAUDE_LANE_CFG:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
STATE="$CFG/claude-lane-state.json"
SOCK="/tmp/verge/verge-mihomo.sock"
LOG="$CFG/logs/service/service_latest.log"
GEN="$CFG/clash-verge.yaml"
FAIL=0
# 版本号的唯一来源是仓库根目录的 VERSION 文件（别再往脚本里写死——v1.1.1 就写串过）
REPO_VERSION=$(tr -d '\r\n ' < "$HERE/../VERSION" 2>/dev/null)
REPO_VERSION=${REPO_VERSION:-unknown}

ok()   { printf '  \033[32m✅ %s\033[0m\n' "$1"; }
bad()  { printf '  \033[31m❌ %s\033[0m\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '     %s\n' "$1"; }
warn() { printf '  \033[33m⚠️  %s\033[0m\n' "$1"; }
mask_value() { printf '%s' "$1" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" mask-value 2>/dev/null; }

# JXA 把 JSON 检查结果输出为 KIND<TAB>MESSAGE；在当前 shell 渲染，避免管道子 shell
# 吞掉失败状态。一个阶段有多条错误时仍只给六项总计增加 1，与旧版语义一致。
render_records() {
  local records="$1" kind message phase_failed=0
  while IFS="$(printf '\t')" read -r kind message; do
    [ -n "$kind" ] || continue
    case "$kind" in
      OK)   ok "$message" ;;
      WARN) warn "$message" ;;
      FAIL) printf '  \033[31m❌ %s\033[0m\n' "$message"; phase_failed=1 ;;
      *)    printf '  \033[31m❌ JSON helper 返回未知结果：%s\033[0m\n' "$kind"; phase_failed=1 ;;
    esac
  done <<EOF
$records
EOF
  [ "$phase_failed" -eq 0 ]
}

# 自动发现：静态节点服务器 IP、混合端口
STATIC_IP=$("$OSASCRIPT" -l JavaScript "$JSON_HELPER" static-server "$GEN" 2>/dev/null || true)
STATIC_IP_MASK=$(mask_value "$STATIC_IP")
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
echo "   静态节点服务器: ${STATIC_IP_MASK:-未找到} | 本地代理端口: $PORT"
[ -z "$STATIC_IP" ] && { bad "生成配置里找不到 US-Static 节点（Phase 3/4 没完成？）"; echo; }

echo "[1/6] 内核与 TUN"
ACTIVATED_AT=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$GEN" 2>/dev/null)
if curl -fsS --max-time 5 --unix-socket "$SOCK" http://localhost/version >/dev/null 2>&1; then
  ok "mihomo API 可达"
else
  bad "mihomo API 不可达（Clash 没在跑，或非 unix-socket 模式）"
fi
CONFIG_RECORDS=$("$OSASCRIPT" -l JavaScript "$JSON_HELPER" verify-config "$GEN" 2>/dev/null)
if [ "$?" -ne 0 ] || [ -z "$CONFIG_RECORDS" ]; then
  CONFIG_RECORDS=$(printf 'FAIL\t无法读取或检查生成配置')
fi
render_records "$CONFIG_RECORDS" || FAIL=$((FAIL+1))
if [ ! -r "$LOG" ]; then
  bad "内核日志不存在或不可读，无法确认 TUN 启动状态"
elif [ -z "$ACTIVATED_AT" ]; then
  bad "无法确定本次配置激活时间，拒绝跳过 TUN 日志边界"
elif awk -v start="[$ACTIVATED_AT" '$0 >= start' "$LOG" 2>/dev/null |
     grep -q "Start TUN listening error"; then
  bad "TUN 启动失败（add route: file exists → 有其他 VPN 占路由，见排障手册第 1 条）"
else
  ok "TUN 无启动错误"
fi

echo "[2/6] 策略组状态"
PROXIES_JSON=$(curl -fsS --max-time 8 --unix-socket "$SOCK" http://localhost/proxies 2>/dev/null)
PROXY_RECORDS=$(printf '%s' "$PROXIES_JSON" |
  "$OSASCRIPT" -l JavaScript "$JSON_HELPER" verify-proxies 2>/dev/null)
if [ "$?" -ne 0 ] || [ -z "$PROXY_RECORDS" ]; then
  PROXY_RECORDS=$(printf 'FAIL\tmihomo /proxies JSON 检查失败（内核 API 异常）')
fi
render_records "$PROXY_RECORDS" || FAIL=$((FAIL+1))

echo "[3/6] 规则完整性"
# 进程规则核对：不看"有没有写 claude.exe"，看当前【真实在跑】的 Claude 进程有没有对应规则。
# （磁盘文件叫 claude.exe，但 mihomo 匹配的是 ps comm，macOS 上实测是小写 claude——只写 exe 会静默漏遥测）
RULES_JSON=$(curl -fsS --max-time 8 --unix-socket "$SOCK" http://localhost/rules 2>/dev/null)
PROCESS_LIST=""
PROCESS_CHECK_FAILED=0
PROCESS_LIST=$(ps -axo comm 2>/dev/null) || PROCESS_CHECK_FAILED=1
RULE_RECORDS=$(printf '%s\0%s' "$RULES_JSON" "$PROCESS_LIST" |
  "$OSASCRIPT" -l JavaScript "$JSON_HELPER" verify-rules 2>/dev/null)
if [ "$?" -ne 0 ] || [ -z "$RULE_RECORDS" ]; then
  RULE_RECORDS=$(printf 'FAIL\tmihomo /rules JSON 检查失败（内核 API 异常）')
fi
render_records "$RULE_RECORDS" || FAIL=$((FAIL+1))
[ "$PROCESS_CHECK_FAILED" -eq 0 ] || bad "无法读取进程列表，不能确认 Claude 进程规则覆盖"

echo "[4/6] 出口双验（关键）"
# 先探本地代理端口；不通时直接给原因，跳过双验避免误报成"出口错误"
if ! curl -fsS --max-time 8 --proxy "$PROXY" -o /dev/null https://api.ipify.org 2>/dev/null; then
  bad "本地代理端口不通（${PROXY}），跳过出口双验"
  note "确认 Verge 设置→端口 里开启的端口类型和号码；本脚本按 mixed-port > port > socks-port 顺序自动发现"
else
  TRACE=$(curl -fsS --max-time 25 --proxy "$PROXY" https://claude.ai/cdn-cgi/trace 2>/dev/null)
  TRACE_IP=$(printf '%s' "$TRACE" | grep '^ip=' | cut -d= -f2 | tr -d '\r ')
  TRACE_LOC=$(printf '%s' "$TRACE" | grep '^loc=' | cut -d= -f2 | tr -d '\r ')
  NORM_IP=$(curl -fsS --max-time 15 --proxy "$PROXY" https://api.ipify.org 2>/dev/null | tr -d '\r ')
  [ "$(printf '%s' "$TRACE_IP" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" valid-ip 2>/dev/null)" = "YES" ] || TRACE_IP=""
  [ "$(printf '%s' "$NORM_IP" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" valid-ip 2>/dev/null)" = "YES" ] || NORM_IP=""
  BASE_IP=""
  if [ -f "$STATE" ]; then
    BASE_IP=$("$OSASCRIPT" -l JavaScript "$JSON_HELPER" json-get "$STATE" claude_exit_ip 2>/dev/null)
    if [ "$?" -ne 0 ]; then
      bad "出口基线状态文件损坏，拒绝忽略或覆盖"
      BASE_IP=""
    elif [ -n "$BASE_IP" ] &&
         [ "$(printf '%s' "$BASE_IP" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" valid-ip 2>/dev/null)" != "YES" ]; then
      bad "出口基线不是有效 IP，拒绝按无基线继续"
      BASE_IP=""
    fi
  fi
  TRACE_IP_MASK=$(mask_value "$TRACE_IP")
  NORM_IP_MASK=$(mask_value "$NORM_IP")
  BASE_IP_MASK=$(mask_value "$BASE_IP")

  # 有基线：跟【上次实测到的真实出口】比，能发现出口悄悄变了
  # 无基线（首次）：**不要求**出口等于配置里的服务器地址——服务商的入口地址常常不等于最终住宅出口 IP，
  #                 那样判会让这类用户永远建立不了基线（v1.1.0 的死锁 bug）。首次只验三件事：
  #                 出口拿得到、国家是 US、且与普通流量出口不同（证明确实走了专线）。
  if [ -n "$BASE_IP" ]; then
    if [ -n "$TRACE_IP" ] && [ "$TRACE_IP" = "$BASE_IP" ]; then
      ok "claude.ai 出口 = ${TRACE_IP_MASK} (${TRACE_LOC:-?}) <- 与基线一致"
    elif [ -n "$TRACE_IP" ] && [ "$SAVE_BASELINE" = "1" ]; then
      warn "claude.ai 出口与旧基线不同；已显式请求更新，其他检查全绿后才会写入新基线"
    else
      bad "claude.ai 出口变了：现在 ${TRACE_IP_MASK:-请求失败} (${TRACE_LOC:-?})，基线是 ${BASE_IP_MASK}"
      note "静态 IP 换了/到期了？确认无误后用 bash scripts/verify.sh --save-baseline 更新基线"
    fi
  elif [ -z "$TRACE_IP" ]; then
    bad "拿不到 claude.ai 的出口 IP（链路不通？先看第 1、2 项）"
  elif [ -n "$NORM_IP" ] && [ "$TRACE_IP" = "$NORM_IP" ]; then
    bad "Claude 出口和普通流量出口相同（${TRACE_IP_MASK}）—— 说明 Claude 流量没走专线"
  else
    ok "claude.ai 出口 = ${TRACE_IP_MASK} (${TRACE_LOC:-?}) <- 与普通流量分离, 正常"
    if [ -n "$STATIC_IP" ] && [ "$TRACE_IP" != "$STATIC_IP" ]; then
      note "出口 ${TRACE_IP_MASK} 与配置里的服务器地址 ${STATIC_IP_MASK} 不同——这很正常（服务商入口≠住宅出口）"
    fi
    note "尚未记录出口基线，跑一次记下来：bash scripts/verify.sh --save-baseline"
  fi

  if [ "$TRACE_LOC" != "US" ]; then
    bad "出口国家不是 US 或无法确认（静态 IP 被回收换区了？）"
  fi

  # 普通流量必须与【Claude 的真实出口】不同（不是与配置里的服务器地址比）
  EXPECT_EXIT="$TRACE_IP"
  if [ -z "$NORM_IP" ]; then
    bad "普通流量出口请求失败"
  elif [ -n "$EXPECT_EXIT" ] && [ "$NORM_IP" = "$EXPECT_EXIT" ]; then
    bad "普通流量出口 = ${NORM_IP_MASK}，与 Claude 出口相同（有组误选了静态节点，见第 2 项）"
  else
    ok "普通流量出口 = ${NORM_IP_MASK} <- 机场节点, 未误走静态"
  fi
fi

echo "[5/6] 日志漏流扫描"
# 假设：mihomo 日志行首时间戳格式为 [YYYY-MM-DD HH:MM:SS…（靠字符串比较过滤激活前的旧日志）。
# 若日志格式变更，过滤会静默失效——激活前的旧漏流记录也会被算进来，出现莫名其妙的红项时先人工看日志时间。
LEAK=$(awk -v start="[$ACTIVATED_AT" 'start == "[" || $0 >= start' "$LOG" 2>/dev/null \
       | grep -iE "claude|anthropic|datadoghq|statsig" | grep " using " \
       | grep -v "using Claude\[" | grep -v "using REJECT" | tail -5)
if [ -z "$LEAK" ]; then
  ok "本次激活后无 Claude/Anthropic 流量走到非 Claude 组"
else
  bad "本次激活后发现漏流记录（Claude 流量走了别的组）："
  note "具体记录默认不输出，避免地址进入 Agent 对话；请只在本机查看 ${LOG}"
fi

echo "[6/6] 其他 VPN 检测"
VPN_LIST=""
if ! VPN_LIST=$(scutil --nc list 2>/dev/null); then
  bad "scutil 查询失败，不能确认是否有其他 VPN"
elif ! OTHERVPN=$(printf '%s\n' "$VPN_LIST" | grep "(Connected)" | grep -iv tailscale); then
  ok "无其他 VPN 在运行"
else
  bad "有其他 VPN 处于 Connected（会抢路由，必须断开）："
  note "$(printf '%s' "$OTHERVPN" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" display-value 2>/dev/null)"
fi

echo "[版本] 本机部署的模板版本 vs 仓库当前版本"
DEPLOYED_VERSION=$("$OSASCRIPT" -l JavaScript "$JSON_HELPER" json-get "$STATE" template_version 2>/dev/null || true)
if [ -z "$DEPLOYED_VERSION" ]; then
  note "本机还没记录部署版本（跑一次 bash scripts/verify.sh --save-baseline 记下来）"
elif [ "$DEPLOYED_VERSION" = "$REPO_VERSION" ]; then
  ok "版本一致（${REPO_VERSION}）"
else
  SAFE_DEPLOYED_VERSION=$(printf '%s' "$DEPLOYED_VERSION" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" display-value 2>/dev/null)
  warn "配置漂移：本机是 ${SAFE_DEPLOYED_VERSION}，仓库已到 ${REPO_VERSION}"
  note "仓库模板更新不会自动同步到已部署的机器（见排障手册第 10 条）。"
  note "让 agent 按最新 templates/ 重新对齐一次，GUI 激活后再跑 bash scripts/verify.sh --save-baseline"
fi

echo
# 记录/更新出口基线（只在全绿时写，免得把出错状态记成基线）
if [ "$SAVE_BASELINE" = "1" ]; then
  if [ "$FAIL" -eq 0 ] && [ -n "${TRACE_IP:-}" ]; then
    VERGE_VER=$(plutil -extract CFBundleShortVersionString raw \
      "/Applications/Clash Verge.app/Contents/Info.plist" 2>/dev/null || echo unknown)
    if printf '%s\0%s\0%s\0%s\0%s\0' \
      "$TRACE_IP" "${TRACE_LOC:-}" "$VERGE_VER" "$(date '+%F')" "$REPO_VERSION" |
      "$OSASCRIPT" -l JavaScript "$JSON_HELPER" state-update "$STATE" >/dev/null &&
      chmod 600 "$STATE"; then
      printf '\033[32m已记录出口基线：%s (%s) → %s\033[0m\n' "$(mask_value "$TRACE_IP")" "${TRACE_LOC:-?}" "$STATE"
    else
      bad "出口验证已通过，但基线状态文件写入失败：${STATE}"
    fi
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
