#!/usr/bin/env bash
# 烟雾测试：在临时目录里造一套假的 Clash 配置，跑通 backup / rollback / set-credentials 的关键路径。
# **不会碰你真实的 Clash 配置**（靠 CLAUDE_LANE_CFG 把路径整体指到临时目录）。
#
#   bash scripts/selftest.sh
#
# 这些用例全部来自 v1.1.0 真实踩过的坑——改脚本之后先跑它，别再让"只在新用户身上触发"的 bug 溜出去。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()   { printf '  \033[32m✅ %s\033[0m\n' "$1"; PASS=$((PASS+1)); }
ng()   { printf '  \033[31m❌ %s\033[0m\n' "$1"; FAIL=$((FAIL+1)); }

# macOS 没有 timeout(1)，自己实现一个：超时返回 124，用来抓死循环
# （v1.2.0 的 rollback.sh 在「立刻撤销刚才的回滚」时会边读边写同一个 manifest，直接卡死）
with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  local ticks=0 limit=$((secs * 5))
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2; ticks=$((ticks + 1))
    if [ "$ticks" -gt "$limit" ]; then
      kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124
    fi
  done
  wait "$pid"; return $?
}

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CLAUDE_LANE_CFG="$SANDBOX/cfg"
mkdir -p "$CLAUDE_LANE_CFG/profiles"

# 假的 profiles.yaml：一个订阅，挂着 proxies 增强文件 pTEST0000001
cat > "$CLAUDE_LANE_CFG/profiles.yaml" <<'EOF'
current: SUB000000001
items:
- uid: pTEST0000001
  type: proxies
  name: null
  file: pTEST0000001.yaml
  updated: 1779193392
- uid: SUB000000001
  type: remote
  name: Test.yaml
  file: SUB000000001.yaml
  url: https://example.invalid/sub
  option:
    proxies: pTEST0000001
    groups: gTEST0000001
    rules: rTEST0000001
EOF
PROXY_FILE="$CLAUDE_LANE_CFG/profiles/pTEST0000001.yaml"

echo "== claude-lane 烟雾测试 =="
echo "沙箱：$SANDBOX"
echo

echo "[1] backup.sh：已存在的文件要存副本，不存在的要标记为 created"
printf 'old content\n' > "$SANDBOX/exists.yaml"
BK=$(CLAUDE_LANE_DEPLOY_ID=testdeploy bash "$HERE/backup.sh" "$SANDBOX/exists.yaml" "$SANDBOX/willbecreated.yaml" 2>/dev/null | tail -1)
[ -f "$BK/manifest.tsv" ] && ok "生成了备份清单" || ng "没有生成备份清单"
grep -q "^file" "$BK/manifest.tsv" && ok "已存在文件记为 file" || ng "已存在文件没记成 file"
grep -q "^created" "$BK/manifest.tsv" && ok "不存在的文件记为 created" || ng "不存在的文件没记成 created"

echo "[2] backup.sh：同一 deployment 多次调用共用一个备份点，且不重复覆盖"
printf 'changed midway\n' > "$SANDBOX/exists.yaml"
BK2=$(CLAUDE_LANE_DEPLOY_ID=testdeploy bash "$HERE/backup.sh" "$SANDBOX/exists.yaml" 2>/dev/null | tail -1)
[ "$BK" = "$BK2" ] && ok "两次调用同一备份点" || ng "备份点不一致（$BK vs ${BK2}）"
IDX=$(awk -F'\t' '$1=="file"{print $2; exit}' "$BK/manifest.tsv")
grep -q "^old content" "$BK/files/$IDX" && ok "保留的是【部署前】的内容，没被中途状态覆盖" || ng "副本被中途状态覆盖了"

echo "[3] rollback.sh：还原改过的文件 + 删除新建的文件 + 打完整提示（不中途崩）"
printf 'new content\n' > "$SANDBOX/exists.yaml"
printf 'i am new\n' > "$SANDBOX/willbecreated.yaml"
OUT=$(bash "$HERE/rollback.sh" --yes testdeploy 2>&1)
RC=$?
[ "$RC" = "0" ] && ok "回滚退出码 0" || ng "回滚退出码 ${RC}（v1.1.0 会在这里因 \${VAR}中文标点 崩掉）"
grep -q "^old content" "$SANDBOX/exists.yaml" && ok "文件已还原" || ng "文件没还原"
[ ! -f "$SANDBOX/willbecreated.yaml" ] && ok "新建的文件已删除" || ng "新建的文件没删"
printf '%s' "$OUT" | grep -q "让配置重新生效" && ok "收尾提示完整打印" || ng "收尾提示没打出来（脚本中途退出）"

echo "[4] set-credentials.sh：全新空文件 + 密码含双引号反斜杠（v1.1.0 两个 bug 的交叉点）"
printf 'prepend: []\n\nappend: []\n\ndelete: []\n' > "$PROXY_FILE"
OUT=$(printf '198.51.100.10\n12324\nu"ser\np"ass\\word\n' | bash "$HERE/set-credentials.sh" 2>&1)
RC=$?
[ "$RC" = "0" ] && ok "脚本正常结束（v1.1.0 在空文件上会静默退出）" || ng "脚本退出码 $RC"
printf '%s' "$OUT" | grep -q "凭证已写入" && ok "打印了成功信息" || ng "没打印成功信息"
printf '%s' "$OUT" | grep -q 'p"ass' && ng "输出里泄漏了明文密码" || ok "输出里没有明文密码"
python3 - "$PROXY_FILE" <<'PY' && ok "写出的用户名/密码转义正确（可被 JSON/YAML 解析且值无损）" || ng "转义有问题：写出的是非法 YAML"
import json, re, sys
s = open(sys.argv[1], encoding="utf-8").read()
u = re.search(r'^\s*username:\s*(.+)$', s, re.M).group(1).strip()
p = re.search(r'^\s*password:\s*(.+)$', s, re.M).group(1).strip()
assert json.loads(u) == 'u"ser', u
assert json.loads(p) == 'p"ass\\word', p
PY
[ "$(stat -f '%Lp' "$PROXY_FILE")" = "600" ] && ok "文件权限 600" || ng "文件权限不是 600"

echo "[5] set-credentials.sh：重复运行只替换托管块，用户自己加的节点原样保留"
cat >> "$PROXY_FILE" <<'EOF'
  - name: "我自己加的节点"
    type: ss
EOF
OUT=$(printf '203.0.113.9\n8080\nu2\np2\n' | bash "$HERE/set-credentials.sh" 2>&1); RC=$?
[ "$RC" = "0" ] && ok "重复运行成功" || ng "重复运行失败（退出码 ${RC}）"
grep -q "我自己加的节点" "$PROXY_FILE" && ok "用户自有节点保留" || ng "用户自有节点被抹掉了"
grep -q "203.0.113.9" "$PROXY_FILE" && ok "凭证已更新" || ng "凭证没更新"
[ "$(grep -c 'US-Static' "$PROXY_FILE")" = "1" ] && ok "没有产生重复节点" || ng "产生了重复节点"

echo "[6] set-credentials.sh：文件里有用户内容且无托管标记时，拒绝改动"
printf 'prepend: []\n\nappend:\n  - name: "别人的节点"\n    type: ss\n\ndelete: []\n' > "$PROXY_FILE"
OUT=$(printf '203.0.113.9\n8080\nu2\np2\n' | bash "$HERE/set-credentials.sh" 2>&1); RC=$?
[ "$RC" = "3" ] && ok "正确返回冲突码 3" || ng "冲突时退出码是 ${RC}（应为 3）"
grep -q "别人的节点" "$PROXY_FILE" && ok "没动用户的文件" || ng "把用户的文件改坏了"

echo "[7] 回滚快照：回滚之后【立即】撤销回滚，两类文件都要完整恢复，且不能卡死"
A="$SANDBOX/deploy-A.yaml"   # 部署前就存在，部署时被改
B="$SANDBOX/deploy-B.yaml"   # 部署前不存在，部署时新建
printf 'A: before deploy\n' > "$A"; rm -f "$B"
CLAUDE_LANE_DEPLOY_ID=undo-test bash "$HERE/backup.sh" "$A" "$B" >/dev/null 2>&1
printf 'A: after deploy\n' > "$A"; printf 'B: created by deploy\n' > "$B"   # 模拟部署改动

with_timeout 20 bash "$HERE/rollback.sh" --yes undo-test >"$SANDBOX/r1.log" 2>&1
RC1=$?
[ "$RC1" != "124" ] && ok "第一次回滚没卡死" || ng "第一次回滚超时卡死"
grep -q "^A: before deploy" "$A" && ok "回滚：A 还原到部署前" || ng "回滚：A 没还原"
[ ! -f "$B" ] && ok "回滚：B（部署新建）已删除" || ng "回滚：B 没删掉"

# 立刻撤销刚才那次回滚——不加任何 sleep，专门制造「同一秒内」的目录撞名场景
SNAP=$(awk '/scripts\/rollback\.sh prerollback-/{print $NF}' "$SANDBOX/r1.log" | tail -1)
[ -n "$SNAP" ] && ok "回滚输出里给出了撤销用的快照 id（${SNAP}）" || ng "没拿到快照 id"
with_timeout 20 bash "$HERE/rollback.sh" --yes "$SNAP" >"$SANDBOX/r2.log" 2>&1
RC2=$?
[ "$RC2" != "124" ] && ok "撤销回滚没卡死（v1.2.0 会在这里无限循环）" || ng "撤销回滚超时卡死"
grep -q "^A: after deploy" "$A" && ok "撤销：A 恢复成回滚前（部署后）的内容" || ng "撤销：A 内容不对（$(head -1 "$A" 2>/dev/null)）"
[ -f "$B" ] && grep -q "^B: created by deploy" "$B" && ok "撤销：B 被重新创建且内容完整" || ng "撤销：B 没恢复（部署新建的文件被记成 created 就会这样）"

# 再撤销一次（撤销的撤销），确认可以来回滚且状态自洽
SNAP2=$(awk '/scripts\/rollback\.sh prerollback-/{print $NF}' "$SANDBOX/r2.log" | tail -1)
if [ -n "$SNAP2" ]; then
  with_timeout 20 bash "$HERE/rollback.sh" --yes "$SNAP2" >/dev/null 2>&1
  RC3=$?
  [ "$RC3" != "124" ] && ok "连续第三次回滚仍不卡死" || ng "第三次回滚卡死"
  grep -q "^A: before deploy" "$A" && [ ! -f "$B" ] && ok "来回滚状态自洽（又回到部署前）" || ng "来回滚后状态不自洽"
else
  ng "第二次回滚没产出快照 id"
fi

# 不带 id 时不应误选回滚快照
DEFAULT_TARGET=$(bash "$HERE/rollback.sh" --list | grep -v '回滚快照' | awk '/还原/{print $1; exit}')
printf '%s' "$DEFAULT_TARGET" | grep -qv '^prerollback-' && ok "--list 能区分部署备份点和回滚快照" || ng "--list 没区分回滚快照"

echo "[8] 静态检查：脚本里不能出现 \$VAR 紧跟中文标点（bash 会把标点首字节吃进变量名）"
LINT=$(python3 - "$HERE" <<'PY'
import os, re, sys
# $VAR 后面直接跟非 ASCII 字符 → bash 会把该字符的首字节当成变量名的一部分，
# set -u 下直接报 unbound variable（v1.1.0 踩过 5 处，写这个测试时又踩了 1 处）。
# ${VAR} 形式安全，所以只匹配未加花括号的。
pat = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]')
hits = []
for fn in sorted(os.listdir(sys.argv[1])):
    if not fn.endswith(".sh"): continue
    path = os.path.join(sys.argv[1], fn)
    for i, line in enumerate(open(path, encoding="utf-8"), 1):
        if pat.search(line):
            hits.append(f"{fn}:{i}")
print(" ".join(hits))
PY
)
[ -z "$LINT" ] && ok "所有脚本都用了 \${VAR} 形式" || ng "这些位置有隐患：${LINT}"

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m== 全部 %s 项通过 ==\033[0m\n' "$PASS"
else
  printf '\033[31m== %s 项通过，%s 项失败 ==\033[0m\n' "$PASS" "$FAIL"
fi
echo "（verify.sh 依赖真实网络和 Clash 内核，不在本烟雾测试范围内）"
exit "$FAIL"
