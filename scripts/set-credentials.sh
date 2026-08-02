#!/usr/bin/env bash
# 把静态住宅 IP 的四元组写进 Clash 的 proxies 增强文件——**全程不经过 AI 对话**。
#
# 为什么要这样：把账号密码贴进聊天框，等于把它发到模型服务端、并留在本机会话记录里。
# 这个脚本由你自己在终端跑，密码隐藏输入，AI 只看得到打码后的确认信息。
#
# 用法（在仓库目录下）：
#   bash scripts/set-credentials.sh
#   # 请在真实终端里亲自运行；Agent 代跑拿不到你的隐藏键盘输入。
set -euo pipefail
umask 077

CFG="${CLAUDE_LANE_CFG:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
NODE_NAME="🇺🇸 US-Static"
MARK_START="# claude-lane managed start"
MARK_END="# claude-lane managed end"
HERE="$(cd "$(dirname "$0")" && pwd)"
JSON_HELPER="$HERE/macos-json.js"
OSASCRIPT="/usr/bin/osascript"

[ -x "$OSASCRIPT" ] && [ -f "$JSON_HELPER" ] || {
  echo "缺少 macOS 系统 JXA 或仓库辅助文件（${JSON_HELPER}）"
  exit 1
}
[ -f "$CFG/profiles.yaml" ] || { echo "找不到 Clash Verge 配置（${CFG}）——先装好 Verge 并导入订阅"; exit 1; }

# ── 定位当前订阅挂载的 proxies 增强文件
TARGET=$("$OSASCRIPT" -l JavaScript "$JSON_HELPER" profile-proxies "$CFG/profiles.yaml")

if [ -z "$TARGET" ]; then
  echo "❌ 当前订阅还没有 proxies 增强文件。"
  echo "   请在 Clash Verge「订阅」页右键当前订阅 →「编辑节点」→ 不改任何东西直接保存，"
  echo "   让 GUI 生成这个文件，然后重跑本脚本。"
  exit 1
fi
FILE="$CFG/profiles/$TARGET.yaml"
[ ! -L "$FILE" ] || { echo "❌ proxies 增强文件不能是符号链接，已停止以防写到配置目录之外"; exit 1; }
echo "目标文件：${FILE}"

# 沿用文件里已有的静态节点名（老版本配出来的名字可能不同）——
# 换成新名字会让 groups 里的 Claude 组指向一个不存在的节点，直接断网。
# ⚠️ `|| true` 不能省：grep 找不到时返回 1，配合 set -e + pipefail 会让脚本静默退出（v1.1.0 的 bug）
EXIST=""
if [ -f "$FILE" ]; then
  EXIST=$("$OSASCRIPT" -l JavaScript "$JSON_HELPER" managed-name \
    "$FILE" "$MARK_START" "$MARK_END")
fi
if [ -n "$EXIST" ] && [ "$EXIST" != "$NODE_NAME" ]; then
  NODE_NAME="$EXIST"
  SAFE_NODE_NAME=$(printf '%s' "$NODE_NAME" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" display-value)
  echo "沿用已有节点名：${SAFE_NODE_NAME}"
fi
echo

# ── 收集四元组（四项全部隐藏输入，防止终端回显/录屏泄漏）
echo "下面四项输入均不显示，输完每项按回车。"
read -r -s -p "静态 IP 主机（host）: " HOST; echo
read -r -s -p "端口（port）: " PORT; echo
read -r -s -p "用户名（username）: " USERNAME; echo
read -r -s -p "密码（password）: " PASSWORD; echo
echo

[ -n "$HOST" ] && [ -n "$PORT" ] && [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || { echo "❌ 四项都不能为空"; exit 1; }
case "$PORT" in ''|*[!0-9]*) echo "❌ 端口必须是数字"; exit 1;; esac
# 去掉前导零，既方便做范围判断，也避免 YAML 把端口误读成八进制。
while [ "${PORT#0}" != "$PORT" ]; do PORT=${PORT#0}; done
PORT=${PORT:-0}
if [ "${#PORT}" -gt 5 ] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "❌ 端口必须在 1..65535 之间"
  exit 1
fi

# ── 备份（独立目录；同一次部署可用 CLAUDE_LANE_DEPLOY_ID 共用一个备份点）
BK=$(bash "$HERE/backup.sh" "$FILE" | tail -1)

# ── 写入：有 managed 标记就只替换标记之间的内容；否则仅在文件是空骨架时整份重写
#    四元组以 NUL 分隔从 stdin 交给 JXA；不进入命令行参数或子进程环境。
#    JXA 用 JSON.stringify 转义（合法 JSON 字符串同时也是合法 YAML 双引号标量）。
RC=0
MODE=$(printf '%s\0%s\0%s\0%s\0' "$HOST" "$PORT" "$USERNAME" "$PASSWORD" |
  "$OSASCRIPT" -l JavaScript "$JSON_HELPER" credentials-write \
    "$FILE" "$NODE_NAME" "$MARK_START" "$MARK_END") || RC=$?
unset PASSWORD

if [ "$MODE" = "MODE=conflict" ]; then
  echo "⚠️ 这个文件里已经有你自己的其他节点配置，脚本不擅自改动。"
  echo "   已备份到 ${BK} 。把这句话告诉 AI，让它帮你合并（它不需要知道你的密码）。"
  exit 3
fi
[ "$RC" = "0" ] || { echo "❌ 写入失败（退出码 ${RC}），配置未改动，备份在 ${BK}"; exit "$RC"; }

chmod 600 "$FILE"

# 校验托管块：JSON/YAML 字符串可解析，且 socks5 / udp / dialer-proxy 三项齐全。
"$OSASCRIPT" -l JavaScript "$JSON_HELPER" validate-managed \
  "$FILE" "$NODE_NAME" "$MARK_START" "$MARK_END" >/dev/null || {
  echo "❌ 生成的配置无法解析！已保留备份，请用 rollback.sh 回滚"
  exit 1
}

MASK_HOST=$(printf '%s' "$HOST" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" mask-value)
MASK_USER=$(printf '%s' "$USERNAME" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" mask-value)
SAFE_NODE_NAME=$(printf '%s' "$NODE_NAME" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" display-value)
unset HOST PORT USERNAME
cat <<EOF

✅ 凭证已写入本机配置（权限 600，仅你可读）
   节点名 : ${SAFE_NODE_NAME}
   主机   : ${MASK_HOST}      端口: ***
   用户名 : ${MASK_USER}      密码: ***（未回显、未进入任何对话）
   备份   : ${BK}

把上面这几行贴给 AI 就够了（都是打码的）。接下来它会继续配分组和规则。
EOF
