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

CFG="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
SOCK="/tmp/verge/verge-mihomo.sock"
LOG="$CFG/logs/service/service_latest.log"
GEN="$CFG/clash-verge.yaml"
FAIL=0

ok()   { printf '  \033[32m✅ %s\033[0m\n' "$1"; }
bad()  { printf '  \033[31m❌ %s\033[0m\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '     %s\n' "$1"; }

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

echo "[1/6] 内核与 TUN"
if curl -sS --max-time 5 --unix-socket "$SOCK" http://localhost/version >/dev/null 2>&1; then
  ok "mihomo API 可达"
else
  bad "mihomo API 不可达（Clash 没在跑，或非 unix-socket 模式）"
fi
if tail -50 "$LOG" 2>/dev/null | grep -q "Start TUN listening error"; then
  bad "TUN 启动失败（add route: file exists → 有其他 VPN 占路由，见排障手册第 1 条）"
else
  ok "TUN 无启动错误"
fi

echo "[2/6] 策略组状态"
python3 - "$SOCK" <<'PY' || FAIL=$((FAIL+1))
import json, subprocess, sys
out = subprocess.run(["curl","-sS","--max-time","8","--unix-socket",sys.argv[1],
                      "http://localhost/proxies"], capture_output=True, text=True).stdout
data = json.loads(out)["proxies"]
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
PY

echo "[3/6] 规则完整性"
python3 - "$SOCK" <<'PY' || FAIL=$((FAIL+1))
import json, subprocess, sys
out = subprocess.run(["curl","-sS","--max-time","8","--unix-socket",sys.argv[1],
                      "http://localhost/rules"], capture_output=True, text=True).stdout
rules = json.loads(out)["rules"]
fails = []
head = rules[:12]
if any("Google Chrome" in r["payload"] and r["proxy"]=="REJECT" for r in head):
    print("  \033[32m✅ Chrome QUIC 拦截在规则最前\033[0m")
else: fails.append("规则最前面没有 Chrome QUIC 拦截（漏流风险，检查模板③顺序）")
glb = [r for r in rules if r["proxy"]=="REJECT" and "udp" in r["payload"].lower()
       and "443" in r["payload"] and "ProcessName" not in r["payload"]]
if glb: fails.append("存在全局 UDP/443 REJECT（误伤全机 HTTP/3，应删除）")
else: print("  \033[32m✅ 无全局 UDP/443 拦截\033[0m")
if any(r["payload"]=="claude.com" for r in rules if r["type"]=="DomainSuffix"):
    print("  \033[32m✅ claude.com 域名规则存在\033[0m")
else: fails.append("缺 DOMAIN-SUFFIX,claude.com 规则")
if any("datadoghq" in r["payload"] for r in rules):
    print("  \033[32m✅ 遥测域名规则存在\033[0m")
else: fails.append("缺遥测域名规则（DOMAIN-SUFFIX,http-intake.logs.us5.datadoghq.com,Claude）——进程规则抓不到它，会漏到默认节点，见排障手册第 9 条")
# 进程规则核对：不看"有没有写 claude.exe"，看当前【真实在跑】的 Claude 进程有没有对应规则。
# （磁盘文件叫 claude.exe，但 mihomo 匹配的是 ps comm，macOS 上实测是小写 claude——只写 exe 会静默漏遥测）
running = sorted({l.rsplit("/",1)[-1].strip() for l in subprocess.run(
    ["ps","-axo","comm"], capture_output=True, text=True).stdout.splitlines()
    if "claude" in l.rsplit("/",1)[-1].lower()})
ruled = {r["payload"] for r in rules if r["type"]=="ProcessName"}
missing = [p for p in running if p not in ruled]
if not running:
    print("  \033[33m⚠️ 当前没有 Claude 进程在跑，跳过进程规则核对（开着 Claude 再跑一次更准）\033[0m")
elif missing:
    fails.append("这些正在运行的 Claude 进程没有对应规则（遥测会漏到默认节点）: %s" % missing)
else:
    print("  \033[32m✅ 在跑的 Claude 进程都有对应规则（%s）\033[0m" % ", ".join(running))
for f in fails: print("  \033[31m❌ %s\033[0m" % f)
sys.exit(1 if fails else 0)
PY

echo "[4/6] 出口双验（关键）"
# 先探本地代理端口；不通时直接给原因，跳过双验避免误报成"出口错误"
if ! curl -sS --max-time 8 --proxy "$PROXY" -o /dev/null https://api.ipify.org 2>/dev/null; then
  bad "本地代理端口不通（$PROXY），跳过出口双验"
  note "确认 Verge 设置→端口 里开启的端口类型和号码；本脚本按 mixed-port > port > socks-port 顺序自动发现"
else
  TRACE_IP=$(curl -sS --max-time 25 --proxy "$PROXY" https://claude.ai/cdn-cgi/trace 2>/dev/null | grep '^ip=' | cut -d= -f2 | tr -d '\r ')
  if [ -n "$TRACE_IP" ] && [ "$TRACE_IP" = "$STATIC_IP" ]; then
    ok "claude.ai 出口 = ${TRACE_IP} <- 静态IP, 正确"
  else
    bad "claude.ai 出口 = ${TRACE_IP:-请求失败}, 应为 ${STATIC_IP}"
  fi
  NORM_IP=$(curl -sS --max-time 15 --proxy "$PROXY" https://api.ipify.org 2>/dev/null | tr -d '\r ')
  if [ -n "$NORM_IP" ] && [ "$NORM_IP" != "$STATIC_IP" ]; then
    ok "普通流量出口 = ${NORM_IP} <- 机场节点, 未误走静态"
  else
    bad "普通流量出口异常 = ${NORM_IP:-请求失败} (等于静态IP说明有组误选, 见第2项)"
  fi
fi

echo "[5/6] 日志漏流扫描"
# 假设：mihomo 日志行首时间戳格式为 [YYYY-MM-DD HH:MM:SS…（靠字符串比较过滤激活前的旧日志）。
# 若日志格式变更，过滤会静默失效——激活前的旧漏流记录也会被算进来，出现莫名其妙的红项时先人工看日志时间。
ACTIVATED_AT=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$GEN" 2>/dev/null)
LEAK=$(awk -v start="[$ACTIVATED_AT" 'start == "[" || $0 >= start' "$LOG" 2>/dev/null \
       | tail -800 | grep -iE "claude|anthropic|datadoghq|statsig" | grep " using " \
       | grep -v "using Claude\[" | grep -v "using REJECT" | tail -5)
if [ -z "$LEAK" ]; then
  ok "本次激活后无 Claude/Anthropic 流量走到非 Claude 组"
else
  bad "本次激活后发现漏流记录（Claude 流量走了别的组）："
  echo "$LEAK" | while IFS= read -r l; do note "$l"; done
fi

echo "[6/6] 其他 VPN 检测"
OTHERVPN=$(scutil --nc list 2>/dev/null | grep "(Connected)" | grep -iv tailscale)
if [ -z "$OTHERVPN" ]; then
  ok "无其他 VPN 在运行"
else
  bad "有其他 VPN 处于 Connected（会抢路由，必须断开）："
  note "$OTHERVPN"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m== 六项全部通过，部署成功 ==\033[0m\n'
else
  printf '\033[31m== %s 项未通过，对照 docs/troubleshooting.md 处理后重跑 ==\033[0m\n' "$FAIL"
fi
exit "$FAIL"
