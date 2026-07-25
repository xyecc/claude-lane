#!/usr/bin/env bash
# 把静态住宅 IP 的四元组写进 Clash 的 proxies 增强文件——**全程不经过 AI 对话**。
#
# 为什么要这样：把账号密码贴进聊天框，等于把它发到模型服务端、并留在本机会话记录里。
# 这个脚本由你自己在终端跑，密码隐藏输入，AI 只看得到打码后的确认信息。
#
# 用法（在仓库目录下）：
#   bash scripts/set-credentials.sh
#   # 在 Claude Code 里请你自己敲，或在输入框打：  ! bash scripts/set-credentials.sh
#   # （AI 代跑是拿不到你的键盘输入的）
set -euo pipefail

CFG="${CLAUDE_LANE_CFG:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
NODE_NAME="🇺🇸 US-Static"
MARK_START="# claude-lane managed start"
MARK_END="# claude-lane managed end"

command -v python3 >/dev/null 2>&1 || { echo "缺 python3，先跑 xcode-select --install"; exit 1; }
[ -f "$CFG/profiles.yaml" ] || { echo "找不到 Clash Verge 配置（${CFG}）——先装好 Verge 并导入订阅"; exit 1; }

# ── 定位当前订阅挂载的 proxies 增强文件
TARGET=$(python3 - "$CFG/profiles.yaml" <<'PY'
import io, re, sys
lines = io.open(sys.argv[1], encoding="utf-8").read().splitlines()
cur = next((m.group(1) for l in lines for m in [re.match(r'^current:\s*(\S+)', l)] if m), None)
if not cur: sys.exit(0)
out, i = "", 0
while i < len(lines):
    if re.match(r'^-\s*uid:\s*%s\s*$' % re.escape(cur), lines[i]):
        j = i + 1
        while j < len(lines) and not lines[j].startswith('- '):
            m = re.match(r'^\s+proxies:\s*(\S+)\s*$', lines[j])
            if m: out = m.group(1)
            j += 1
        break
    i += 1
print(out)
PY
)

if [ -z "$TARGET" ]; then
  echo "❌ 当前订阅还没有 proxies 增强文件。"
  echo "   请在 Clash Verge「订阅」页右键当前订阅 →「编辑节点」→ 不改任何东西直接保存，"
  echo "   让 GUI 生成这个文件，然后重跑本脚本。"
  exit 1
fi
FILE="$CFG/profiles/$TARGET.yaml"
echo "目标文件：${FILE}"

# 沿用文件里已有的静态节点名（老版本配出来的名字可能不同）——
# 换成新名字会让 groups 里的 Claude 组指向一个不存在的节点，直接断网。
# ⚠️ `|| true` 不能省：grep 找不到时返回 1，配合 set -e + pipefail 会让脚本静默退出（v1.1.0 的 bug）
EXIST=""
if [ -f "$FILE" ]; then
  EXIST=$(grep -oE 'name:[[:space:]]*"[^"]*US-Static[^"]*"' "$FILE" 2>/dev/null | head -1 \
          | sed -E 's/^name:[[:space:]]*"(.*)"$/\1/' || true)
fi
if [ -n "$EXIST" ] && [ "$EXIST" != "$NODE_NAME" ]; then
  NODE_NAME="$EXIST"
  echo "沿用已有节点名：${NODE_NAME}"
fi
echo

# ── 收集四元组（密码隐藏输入，全程不回显完整值）
read -r -p "静态 IP 主机（host，如 198.51.100.10 或域名）: " HOST
read -r -p "端口（port）: " PORT
read -r -p "用户名（username）: " USERNAME
read -r -s -p "密码（password，输入时不显示）: " PASSWORD; echo
echo

[ -n "$HOST" ] && [ -n "$PORT" ] && [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || { echo "❌ 四项都不能为空"; exit 1; }
case "$PORT" in ''|*[!0-9]*) echo "❌ 端口必须是数字"; exit 1;; esac

# ── 备份（独立目录；同一次部署可用 CLAUDE_LANE_DEPLOY_ID 共用一个备份点）
BK=$(bash "$(dirname "$0")/backup.sh" "$FILE" | tail -1)

# ── 写入：有 managed 标记就只替换标记之间的内容；否则仅在文件是空骨架时整份重写
#    所有值一律用 json.dumps 转义（密码里有 " 或 \ 时直接拼字符串会写出非法 YAML —— v1.1.0 的 bug）
export CL_HOST="$HOST" CL_PORT="$PORT" CL_USER="$USERNAME" CL_PASS="$PASSWORD" \
       CL_FILE="$FILE" CL_NODE="$NODE_NAME" CL_S="$MARK_START" CL_E="$MARK_END"
RC=0
python3 <<'PY' || RC=$?
import io, json, os, re, sys
q = lambda s: json.dumps(s, ensure_ascii=False)   # 合法 JSON 字符串同时也是合法 YAML 双引号标量
f, node = os.environ["CL_FILE"], os.environ["CL_NODE"]
S, E = os.environ["CL_S"], os.environ["CL_E"]
block = "\n".join([
 f"  {S}",
 f"  - name: {q(node)}",
 "    type: socks5                      # 必须 socks5",
 f"    server: {q(os.environ['CL_HOST'])}",
 f"    port: {int(os.environ['CL_PORT'])}",
 f"    username: {q(os.environ['CL_USER'])}",
 f"    password: {q(os.environ['CL_PASS'])}",
 "    udp: false                        # 必须 false：防 QUIC 漏流的一环",
 '    dialer-proxy: "US-Chain"          # 必须：先走机场美国节点再连静态 IP',
 f"  {E}",
])
old = io.open(f, encoding="utf-8").read() if os.path.exists(f) else ""
if S in old and E in old:                       # 幂等：只替换既有托管块，别的内容一律不碰
    new = re.sub(r"[ \t]*" + re.escape(S) + r".*?" + re.escape(E), block, old, flags=re.S)
    io.open(f, "w", encoding="utf-8").write(new if new.endswith("\n") else new + "\n")
    print("MODE=replace")
else:
    meaningful = [l for l in old.splitlines()
                  if l.strip() and not l.strip().startswith("#")
                  and l.strip() not in ("prepend: []", "append: []", "delete: []",
                                        "prepend:", "append:", "delete:")]
    if meaningful:                              # 文件里有别人的内容 → 不擅自动，交给 agent 合并
        print("MODE=conflict"); sys.exit(3)
    io.open(f, "w", encoding="utf-8").write(
        "# 由 claude-lane 的 set-credentials.sh 写入；凭证只存在本机，切勿提交进任何 git 仓库\n"
        "prepend: []\n\nappend:\n" + block + "\n\ndelete: []\n")
    print("MODE=create")
PY
unset CL_PASS PASSWORD

if [ "$RC" = "3" ]; then
  echo "⚠️ 这个文件里已经有你自己的其他节点配置，脚本不擅自改动。"
  echo "   已备份到 ${BK} 。把这句话告诉 AI，让它帮你合并（它不需要知道你的密码）。"
  exit 3
fi
[ "$RC" = "0" ] || { echo "❌ 写入失败（退出码 ${RC}），配置未改动，备份在 ${BK}"; exit "$RC"; }

chmod 600 "$FILE"

# 校验写出来的 YAML 至少能被解析（有 pyyaml 才做严格校验，没有则退回括号/缩进粗查）
python3 - "$FILE" <<'PY' || { echo "❌ 生成的配置无法解析！已保留备份，请用 rollback.sh 回滚"; exit 1; }
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
PY

MASK_HOST=$(printf '%s' "$HOST" | sed -E 's/^(.{0,6}).*$/\1***/')
MASK_USER=$(printf '%s' "$USERNAME" | sed -E 's/^(.{0,3}).*$/\1***/')
cat <<EOF

✅ 凭证已写入本机配置（权限 600，仅你可读）
   节点名 : ${NODE_NAME}
   主机   : ${MASK_HOST}      端口: ${PORT}
   用户名 : ${MASK_USER}      密码: ***（未回显、未进入任何对话）
   备份   : ${BK}

把上面这几行贴给 AI 就够了（都是打码的）。接下来它会继续配分组和规则。
EOF
