#!/usr/bin/env bash
# 烟雾测试：在临时目录里造一套假的 Clash 配置，跑通 backup / rollback / set-credentials 的关键路径。
# **不会碰你真实的 Clash 配置**（靠 CLAUDE_LANE_CFG 把路径整体指到临时目录）。
#
#   bash scripts/selftest.sh
#
# 这些用例全部来自 v1.1.0 真实踩过的坑——改脚本之后先跑它，别再让"只在新用户身上触发"的 bug 溜出去。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JSON_HELPER="$HERE/macos-json.js"
OSASCRIPT="/usr/bin/osascript"
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
- uid: gTEST0000001
  type: groups
  name: null
  file: gTEST0000001.yaml
  updated: 1779193392
- uid: rTEST0000001
  type: rules
  name: null
  file: rTEST0000001.yaml
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

echo "[0] profile-config.sh：只输出安全摘要，并能备份后登记缺失增强文件"
SUMMARY=$(bash "$HERE/profile-config.sh" summary 2>&1); RC=$?
[ "$RC" = "0" ] && printf '%s' "$SUMMARY" | grep -q '"current_uid":"SUB000000001"' &&
  printf '%s' "$SUMMARY" | grep -q '"merge"' && ok "安全摘要包含 uid 与缺失类型" || ng "profiles 安全摘要失败"
printf '%s' "$SUMMARY" | grep -Fq 'https://example.invalid/sub' && ng "安全摘要泄漏订阅 URL" || ok "安全摘要不输出订阅 URL"
PROFILE_REGISTER=$(CLAUDE_LANE_DEPLOY_ID=profile-test bash "$HERE/profile-config.sh" register merge mTEST0000001 2>&1); RC=$?
[ "$RC" = "0" ] && [ -f "$CLAUDE_LANE_CFG/profiles/mTEST0000001.yaml" ] &&
  grep -q '^    merge: mTEST0000001$' "$CLAUDE_LANE_CFG/profiles.yaml" &&
  grep -q '^- uid: mTEST0000001$' "$CLAUDE_LANE_CFG/profiles.yaml" &&
  ok "缺失增强文件已登记并创建" || ng "登记 merge 增强失败（${PROFILE_REGISTER}）"
[ "$(stat -f '%Lp' "$CLAUDE_LANE_CFG/profiles.yaml")" = "600" ] &&
  [ "$(stat -f '%Lp' "$CLAUDE_LANE_CFG/profiles/mTEST0000001.yaml")" = "600" ] &&
  ok "profiles 与新增强文件权限均为 600" || ng "profile-config 写后权限不安全"
printf '%s' "$PROFILE_REGISTER" | grep -Fq 'example.invalid' && ng "登记输出泄漏订阅 URL" || ok "登记输出不含订阅 URL"

echo "[0b] setup-state/subscription-checkpoint：缺订阅正常暂停，导入后可继续"
export CLAUDE_LANE_SETUP_ROOT="$SANDBOX/setup-root"
CHECKPOINT_READY=$(bash "$HERE/subscription-checkpoint.sh" 2>&1); RC=$?
[ "$RC" = "0" ] && printf '%s' "$CHECKPOINT_READY" | grep -q '^SETUP_STATE=SUBSCRIPTION_IMPORTED$' &&
  [ "$(bash "$HERE/setup-state.sh" get)" = "SUBSCRIPTION_IMPORTED" ] &&
  ok "已导入远程订阅时进入 SUBSCRIPTION_IMPORTED" || ng "已导入订阅未通过检查点"
[ "$(stat -f '%Lp' "$CLAUDE_LANE_SETUP_ROOT/setup-progress.json")" = "600" ] &&
  ok "安装进度文件权限为 600" || ng "安装进度文件权限不安全"
grep -Fq 'example.invalid' "$CLAUDE_LANE_SETUP_ROOT/setup-progress.json" &&
  ng "安装进度文件泄漏订阅 URL" || ok "安装进度文件不含订阅 URL"
PROXY_STATE=$(bash "$HERE/setup-state.sh" set PROXY_REACHABLE proxy_reachable 2>&1); RC=$?
[ "$RC" = "0" ] && printf '%s' "$PROXY_STATE" | grep -q '^SETUP_STATE=PROXY_REACHABLE$' &&
  [ "$(bash "$HERE/setup-state.sh" get)" = "PROXY_REACHABLE" ] &&
  ok "代理实测恢复点可安全保存" || ng "PROXY_REACHABLE 状态无法保存"

WAIT_CFG="$SANDBOX/wait-cfg"
mkdir -p "$WAIT_CFG"
CHECKPOINT_WAIT=$(CLAUDE_LANE_CFG="$WAIT_CFG" CLAUDE_LANE_SETUP_ROOT="$SANDBOX/wait-state" \
  bash "$HERE/subscription-checkpoint.sh" 2>&1); RC=$?
[ "$RC" = "0" ] && printf '%s' "$CHECKPOINT_WAIT" | grep -q '^SETUP_STATE=WAITING_FOR_SUBSCRIPTION$' &&
  [ "$(CLAUDE_LANE_SETUP_ROOT="$SANDBOX/wait-state" bash "$HERE/setup-state.sh" get)" = "WAITING_FOR_SUBSCRIPTION" ] &&
  ok "profiles.yaml 缺失时正常暂停而非失败" || ng "缺订阅没有进入等待状态"

NULL_CFG="$SANDBOX/null-url-cfg"
mkdir -p "$NULL_CFG"
sed 's#url: https://example.invalid/sub#url: null#' "$CLAUDE_LANE_CFG/profiles.yaml" >"$NULL_CFG/profiles.yaml"
CHECKPOINT_NULL=$(CLAUDE_LANE_CFG="$NULL_CFG" CLAUDE_LANE_SETUP_ROOT="$SANDBOX/null-state" \
  bash "$HERE/subscription-checkpoint.sh" 2>&1); RC=$?
[ "$RC" = "0" ] && printf '%s' "$CHECKPOINT_NULL" | grep -q '^SETUP_STATE=WAITING_FOR_SUBSCRIPTION$' &&
  ok "空订阅 URL 不会被误判为已导入" || ng "空订阅 URL 被错误放行"

LOCAL_CFG="$SANDBOX/local-current-cfg"
mkdir -p "$LOCAL_CFG"
cat >"$LOCAL_CFG/profiles.yaml" <<'EOF'
current: LOCAL0000001
items:
- uid: LOCAL0000001
  type: local
  name: Local.yaml
  file: LOCAL0000001.yaml
EOF
CHECKPOINT_LOCAL=$(CLAUDE_LANE_CFG="$LOCAL_CFG" CLAUDE_LANE_SETUP_ROOT="$SANDBOX/local-state" \
  bash "$HERE/subscription-checkpoint.sh" 2>&1); RC=$?
[ "$RC" = "0" ] && printf '%s' "$CHECKPOINT_LOCAL" | grep -q '^SETUP_STATE=WAITING_FOR_SUBSCRIPTION$' &&
  ok "当前为本地 profile 时正常等待远程订阅" || ng "本地 profile 被当成配置损坏"

NULL_CURRENT_CFG="$SANDBOX/null-current-cfg"
mkdir -p "$NULL_CURRENT_CFG"
sed 's/^current: .*/current: null/' "$CLAUDE_LANE_CFG/profiles.yaml" >"$NULL_CURRENT_CFG/profiles.yaml"
CHECKPOINT_NULL_CURRENT=$(CLAUDE_LANE_CFG="$NULL_CURRENT_CFG" CLAUDE_LANE_SETUP_ROOT="$SANDBOX/null-current-state" \
  bash "$HERE/subscription-checkpoint.sh" 2>&1); RC=$?
[ "$RC" = "0" ] && printf '%s' "$CHECKPOINT_NULL_CURRENT" | grep -q '^SETUP_STATE=WAITING_FOR_SUBSCRIPTION$' &&
  ok "Clash 首次启动的 current:null 正常等待订阅" || ng "current:null 被误判为配置损坏"

BAD_PROFILE_CFG="$SANDBOX/bad-profile-cfg"
mkdir -p "$BAD_PROFILE_CFG"
cp "$CLAUDE_LANE_CFG/profiles.yaml" "$BAD_PROFILE_CFG/profiles.yaml"
printf 'current: remoteTEST001\n' >> "$BAD_PROFILE_CFG/profiles.yaml"
BAD_SUMMARY=$(CLAUDE_LANE_CFG="$BAD_PROFILE_CFG" /bin/bash "$HERE/profile-config.sh" summary 2>&1)
BAD_SUMMARY_STATUS=$?
[ "$BAD_SUMMARY_STATUS" != "0" ] && ok "重复 current 的 profiles 摘要失败关闭" || ng "重复 current 被摘要解析器放行"
BAD_CREDENTIALS=$(CLAUDE_LANE_CFG="$BAD_PROFILE_CFG" /bin/bash "$HERE/set-credentials.sh" </dev/null 2>&1)
BAD_CREDENTIALS_STATUS=$?
[ "$BAD_CREDENTIALS_STATUS" != "0" ] && ok "凭证定位复用严格 profiles 解析器" || ng "凭证定位在歧义 profiles 上继续运行"

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
printf '%s' "$OUT" | grep -Fq '198.51.100.10' && ng "输出里泄漏了完整 host" || ok "输出里没有完整 host"
printf '%s' "$OUT" | grep -Fq '12324' && ng "输出里泄漏了完整端口" || ok "输出里没有完整端口"
printf '%s' "$OUT" | grep -Fq 'u"ser' && ng "输出里泄漏了完整用户名" || ok "输出里没有完整用户名"
printf 'u"ser\0p"ass\\word\0' |
  "$OSASCRIPT" -l JavaScript "$JSON_HELPER" assert-json-scalars \
    "$PROXY_FILE" username password >/dev/null 2>&1 &&
  ok "写出的用户名/密码转义正确（可被 JSON/YAML 解析且值无损）" || ng "转义有问题：写出的是非法 YAML"
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
[ "$(stat -f '%Lp' "$PROXY_FILE")" = "600" ] && ok "替换后文件权限仍为 600" || ng "替换后文件权限不是 600"

echo "[6] set-credentials.sh：文件里有用户内容且无托管标记时，拒绝改动"
printf 'prepend: []\n\nappend:\n  - name: "别人的节点"\n    type: ss\n\ndelete: []\n' > "$PROXY_FILE"
OUT=$(printf '203.0.113.9\n8080\nu2\np2\n' | bash "$HERE/set-credentials.sh" 2>&1); RC=$?
[ "$RC" = "3" ] && ok "正确返回冲突码 3" || ng "冲突时退出码是 ${RC}（应为 3）"
grep -q "别人的节点" "$PROXY_FILE" && ok "没动用户的文件" || ng "把用户的文件改坏了"

echo "[6b] set-credentials.sh：密码含 marker 文本、或 marker 重复时不能残留旧凭证"
printf 'prepend: []\n\nappend: []\n\ndelete: []\n' > "$PROXY_FILE"
OUT=$(printf '203.0.113.10\n443\nu3\npw # claude-lane managed end tail\n' |
  bash "$HERE/set-credentials.sh" 2>&1); RC=$?
[ "$RC" = "0" ] && [ "$(grep -c '^[[:space:]]*# claude-lane managed end[[:space:]]*$' "$PROXY_FILE")" = "1" ] &&
  ok "凭证里的 marker 子串不会截断托管块" || ng "marker 子串破坏了托管块"
cat >> "$PROXY_FILE" <<'EOF'
  # claude-lane managed start
  # claude-lane managed end
EOF
BEFORE=$(cksum "$PROXY_FILE")
OUT=$(printf '203.0.113.11\n443\nu4\np4\n' | bash "$HERE/set-credentials.sh" 2>&1); RC=$?
[ "$RC" != "0" ] && [ "$(cksum "$PROXY_FILE")" = "$BEFORE" ] &&
  ok "重复 marker 时失败关闭且文件不变" || ng "重复 marker 未被拒绝或改动了文件"

# 恢复后续端口测试需要的冲突文件。
printf 'prepend: []\n\nappend:\n  - name: "别人的节点"\n    type: ss\n\ndelete: []\n' > "$PROXY_FILE"

echo "[7] set-credentials.sh：端口必须在 1..65535，拒绝后文件不变"
BEFORE=$(cksum "$PROXY_FILE")
OUT=$(printf '203.0.113.9\n70000\nu2\np2\n' | bash "$HERE/set-credentials.sh" 2>&1); RC=$?
[ "$RC" = "1" ] && ok "越界端口返回 1" || ng "越界端口退出码是 ${RC}（应为 1）"
printf '%s' "$OUT" | grep -q "1..65535" && ok "越界提示清楚" || ng "缺少端口范围提示"
[ "$(cksum "$PROXY_FILE")" = "$BEFORE" ] && ok "拒绝越界端口时配置未改" || ng "拒绝越界端口却改了配置"

echo "[8] set-credentials.sh：PATH 中完全没有 python3 仍能运行"
NO_PY_PATH="$SANDBOX/no-python-path"
mkdir -p "$NO_PY_PATH"
for tool in dirname grep head sed tail plutil awk; do
  ln -s "$(command -v "$tool")" "$NO_PY_PATH/$tool"
done
MIN_PATH="$NO_PY_PATH:/bin:/usr/sbin:/sbin"
if PATH="$MIN_PATH" command -v python3 >/dev/null 2>&1; then
  ng "无 Python 测试 PATH 仍能找到 python3"
else
  ok "测试 PATH 已排除 python3"
fi
printf 'prepend: []\n\nappend: []\n\ndelete: []\n' > "$PROXY_FILE"
OUT=$(printf '203.0.113.8\n00443\nno-python\np"ass\\word\n' |
  PATH="$MIN_PATH" bash "$HERE/set-credentials.sh" 2>&1); RC=$?
[ "$RC" = "0" ] && ok "无 Python 环境写入成功" || ng "无 Python 环境写入失败（退出码 ${RC}）"
grep -q '^    port: 443$' "$PROXY_FILE" && ok "端口前导零已规范化" || ng "端口没有规范化为十进制"

echo "[9] macos-json.js：状态基线读写、字段保留和 API JSON 判定"
SECRET_IP='203.0.113.77'
MASKED_IP=$(printf '%s' "$SECRET_IP" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" mask-value)
[ "$MASKED_IP" = "203***" ] && ok "IP/域名统一只保留 3 字符前缀" || ng "掩码结果不正确：${MASKED_IP}"
printf '%s' "$MASKED_IP" | grep -Fq "$SECRET_IP" && ng "掩码结果仍含完整 IP" || ok "掩码结果不含完整 IP"
MASKED_V6=$(printf '%s' '2001:db8::1234' | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" mask-value)
MASKED_HOST=$(printf '%s' 'static.example.com' | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" mask-value)
[ "$MASKED_V6" = "200***" ] && [ "$MASKED_HOST" = "sta***" ] &&
  ok "IPv6 与域名使用同一掩码规则" || ng "IPv6/域名掩码不一致"
MASKED_SHORT=$(printf '%s' 'ab' | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" mask-value)
[ "$MASKED_SHORT" = "***" ] && ok "短值不会被掩码前缀完整泄漏" || ng "短值掩码泄漏：${MASKED_SHORT}"
STATE_FILE="$SANDBOX/claude-lane-state.json"
printf '%s\0%s\0%s\0%s\0%s\0' '198.51.100.20' US 2.5.2 2026-08-01 1.3.0 |
  "$OSASCRIPT" -l JavaScript "$JSON_HELPER" state-update "$STATE_FILE" >/dev/null 2>&1
RC=$?
[ "$RC" = "0" ] && ok "JXA 原子创建状态文件" || ng "JXA 创建状态文件失败（退出码 ${RC}）"
[ "$("$OSASCRIPT" -l JavaScript "$JSON_HELPER" json-get "$STATE_FILE" claude_exit_ip)" = "198.51.100.20" ] &&
  ok "JXA 能读取出口基线" || ng "JXA 读取出口基线失败"
printf '%s\0%s\0%s\0%s\0%s\0' '198.51.100.21' US 2.5.3 2026-08-02 1.3.1 |
  "$OSASCRIPT" -l JavaScript "$JSON_HELPER" state-update "$STATE_FILE" >/dev/null 2>&1
INSTALLED=$("$OSASCRIPT" -l JavaScript "$JSON_HELPER" json-get "$STATE_FILE" installed_at)
[ "$INSTALLED" = "2026-08-01" ] && ok "更新基线时保留 installed_at" || ng "更新基线覆盖了 installed_at"

PROXY_JSON='{"proxies":{"Claude":{"now":"🇺🇸 US-Static"},"US-Chain":{"now":"US-A"},"DIRECT":{"type":"Selector","now":"US-A"}}}'
PROXY_CHECK=$(printf '%s' "$PROXY_JSON" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" verify-proxies)
printf '%s' "$PROXY_CHECK" | grep -q '^OK.*Claude 组' &&
  printf '%s' "$PROXY_CHECK" | grep -q '^OK.*无其他组误用' && ok "策略组 JSON 判定通过" || ng "策略组 JSON 判定错误"
PROXY_NAMES=$(printf '%s' "$PROXY_JSON" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" proxy-names)
printf '%s' "$PROXY_NAMES" | grep -qx 'Claude' &&
  printf '%s' "$PROXY_NAMES" | grep -qx 'US-Chain' && ok "节点名列表解析通过" || ng "节点名列表解析错误"
BAD_PROXY_JSON='{"proxies":{"Claude":{"now":"🇺🇸 US-Static"},"US-Chain":{"now":"US-A"},"DIRECT":{"type":"Selector","now":"🇺🇸 US-Static"}}}'
BAD_PROXY_CHECK=$(printf '%s' "$BAD_PROXY_JSON" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" verify-proxies)
printf '%s' "$BAD_PROXY_CHECK" | grep -q '^FAIL.*误选了静态节点' && ok "能发现普通组误用静态节点" || ng "漏报普通组误用静态节点"
BAD_FALLBACK_JSON='{"proxies":{"Claude":{"now":"🇺🇸 US-Static"},"US-Chain":{"now":"US-A"},"Fallback":{"type":"Fallback","now":"🇺🇸 US-Static"}}}'
BAD_FALLBACK_CHECK=$(printf '%s' "$BAD_FALLBACK_JSON" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" verify-proxies)
printf '%s' "$BAD_FALLBACK_CHECK" | grep -q '^FAIL.*误选了静态节点' && ok "能发现非 Selector 组误用静态节点" || ng "漏报 Fallback/URLTest 等组误用"

RULE_JSON='{"rules":[{"type":"And","payload":"((ProcessName,Google Chrome Helper),(Network,udp),(DstPort,443))","proxy":"REJECT"},{"type":"And","payload":"((ProcessName,Google Chrome),(Network,udp),(DstPort,443))","proxy":"REJECT"},{"type":"DomainSuffix","payload":"anthropic.com","proxy":"Claude"},{"type":"DomainSuffix","payload":"claude.com","proxy":"Claude"},{"type":"DomainSuffix","payload":"claude.ai","proxy":"Claude"},{"type":"DomainSuffix","payload":"claudeusercontent.com","proxy":"Claude"},{"type":"DomainSuffix","payload":"http-intake.logs.us5.datadoghq.com","proxy":"Claude"},{"type":"IPCIDR","payload":"160.79.104.0/23","proxy":"Claude"},{"type":"ProcessName","payload":"Claude","proxy":"Claude"},{"type":"ProcessName","payload":"Claude Helper","proxy":"Claude"},{"type":"ProcessName","payload":"claude","proxy":"Claude"},{"type":"ProcessName","payload":"claude.exe","proxy":"Claude"}]}'
RULE_CHECK=$(printf '%s\0%s\n' "$RULE_JSON" '/usr/local/bin/claude' |
  "$OSASCRIPT" -l JavaScript "$JSON_HELPER" verify-rules)
printf '%s' "$RULE_CHECK" | grep -q '^OK.*Chrome.*QUIC' &&
  printf '%s' "$RULE_CHECK" | grep -q '^OK.*进程都有对应规则' && ok "规则 JSON 与进程判定通过" || ng "规则 JSON 判定错误"

FALSE_RULE_JSON='{"rules":[{"type":"ProcessName","payload":"Google Chrome","proxy":"REJECT"},{"type":"DomainSuffix","payload":"claude.com","proxy":"DIRECT"},{"type":"DomainSuffix","payload":"http-intake.logs.us5.datadoghq.com","proxy":"DIRECT"},{"type":"ProcessName","payload":"claude","proxy":"DIRECT"}]}'
FALSE_RULE_CHECK=$(printf '%s\0%s\n' "$FALSE_RULE_JSON" '/usr/local/bin/claude' |
  "$OSASCRIPT" -l JavaScript "$JSON_HELPER" verify-rules)
printf '%s' "$FALSE_RULE_CHECK" | grep -q '^FAIL.*UDP/443' &&
  printf '%s' "$FALSE_RULE_CHECK" | grep -q '^FAIL.*核心域名' &&
  printf '%s' "$FALSE_RULE_CHECK" | grep -q '^FAIL.*遥测域名' &&
  printf '%s' "$FALSE_RULE_CHECK" | grep -q '^FAIL.*没有指向 Claude 组' &&
  ok "不会把错误目标组或普通 Chrome REJECT 判成全绿" || ng "规则目标组存在假阳性"

CONTROL_PROXY_JSON=$(printf '{"proxies":{"Claude":{"now":"US-Static\\u001b[2J\\nFAKE"},"US-Chain":{"now":"US-A\\tBAD"}}}')
CONTROL_OUT=$(printf '%s' "$CONTROL_PROXY_JSON" | "$OSASCRIPT" -l JavaScript "$JSON_HELPER" verify-proxies)
if printf '%s' "$CONTROL_OUT" | grep -Fq "$(printf '\033')" ||
   printf '%s\n' "$CONTROL_OUT" | grep -qx 'FAKE'; then
  ng "API 动态字段仍能注入终端控制字符"
elif printf '%s' "$CONTROL_OUT" | grep -Fq '\u001b' &&
     printf '%s' "$CONTROL_OUT" | grep -Fq '\u000a' &&
     printf '%s' "$CONTROL_OUT" | grep -Fq '\u0009'; then
  ok "API 动态字段控制字符已转为可见文本"
else
  ng "控制字符清洗结果不完整：${CONTROL_OUT}"
fi

echo "[10] verify.sh：模拟六项全绿时，stdout/stderr 不泄漏完整 host/IP"
VERIFY_BIN="$SANDBOX/verify-bin"
VERIFY_CFG="$SANDBOX/verify-cfg"
mkdir -p "$VERIFY_BIN" "$VERIFY_CFG/logs/service"
cat > "$VERIFY_BIN/uname" <<'EOF'
#!/bin/bash
echo Darwin
EOF
cat > "$VERIFY_BIN/curl" <<'EOF'
#!/bin/bash
case "$*" in
  *localhost/version*)  printf '%s' '{"version":"test"}' ;;
  *localhost/proxies*)  printf '%s' '{"proxies":{"Claude":{"now":"🇺🇸 US-Static"},"US-Chain":{"now":"US-A"},"DIRECT":{"type":"Selector","now":"US-A"}}}' ;;
  *localhost/rules*)    printf '%s' '{"rules":[{"type":"And","payload":"((ProcessName,Google Chrome Helper),(Network,udp),(DstPort,443))","proxy":"REJECT"},{"type":"And","payload":"((ProcessName,Google Chrome),(Network,udp),(DstPort,443))","proxy":"REJECT"},{"type":"And","payload":"((ProcessName,Claude Helper),(Network,udp))","proxy":"REJECT"},{"type":"And","payload":"((ProcessName,Claude Helper (GPU)),(Network,udp))","proxy":"REJECT"},{"type":"And","payload":"((ProcessName,Claude Helper (Renderer)),(Network,udp))","proxy":"REJECT"},{"type":"And","payload":"((ProcessName,Claude Helper (Plugin)),(Network,udp))","proxy":"REJECT"},{"type":"And","payload":"((ProcessName,Claude),(Network,udp))","proxy":"REJECT"},{"type":"And","payload":"((ProcessName,claude.exe),(Network,udp))","proxy":"REJECT"},{"type":"And","payload":"((ProcessName,claude),(Network,udp))","proxy":"REJECT"},{"type":"ProcessName","payload":"Claude Helper","proxy":"Claude"},{"type":"ProcessName","payload":"Claude Helper (GPU)","proxy":"Claude"},{"type":"ProcessName","payload":"Claude Helper (Renderer)","proxy":"Claude"},{"type":"ProcessName","payload":"Claude Helper (Plugin)","proxy":"Claude"},{"type":"ProcessName","payload":"Claude","proxy":"Claude"},{"type":"ProcessName","payload":"claude.exe","proxy":"Claude"},{"type":"ProcessName","payload":"claude","proxy":"Claude"},{"type":"DomainSuffix","payload":"anthropic.com","proxy":"Claude"},{"type":"DomainSuffix","payload":"claude.com","proxy":"Claude"},{"type":"DomainSuffix","payload":"claude.ai","proxy":"Claude"},{"type":"DomainSuffix","payload":"claudeusercontent.com","proxy":"Claude"},{"type":"DomainSuffix","payload":"http-intake.logs.us5.datadoghq.com","proxy":"Claude"},{"type":"IPCIDR","payload":"160.79.104.0/23","proxy":"Claude"}]}' ;;
  *claude.ai/cdn-cgi/trace*)
    printf 'ip=%s\n' "${VERIFY_TRACE_IP:-203.0.113.77}"
    [ "${VERIFY_TRACE_NO_LOC:-0}" = "1" ] || printf 'loc=%s\n' "${VERIFY_TRACE_LOC:-US}"
    ;;
  *api.ipify.org*) case "$*" in *'-o /dev/null'*) : ;; *) printf '%s' '192.0.2.44' ;; esac ;;
  *) exit 1 ;;
esac
EOF
cat > "$VERIFY_BIN/ps" <<'EOF'
#!/bin/bash
printf 'COMM\n/usr/local/bin/claude\n'
EOF
cat > "$VERIFY_BIN/scutil" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$VERIFY_BIN/stat" <<'EOF'
#!/bin/bash
printf '%s\n' '2026-08-01 00:00:00'
EOF
chmod +x "$VERIFY_BIN/uname" "$VERIFY_BIN/curl" "$VERIFY_BIN/ps" "$VERIFY_BIN/scutil" "$VERIFY_BIN/stat"
cat > "$VERIFY_CFG/clash-verge.yaml" <<'EOF'
mixed-port: 7897
mode: rule
tun:
  enable: true
proxies:
  - name: "🇺🇸 US-Static"
    server: "198.51.100.99"
EOF
: > "$VERIFY_CFG/logs/service/service_latest.log"
VERIFY_OUT=$(PATH="$VERIFY_BIN:$PATH" CLAUDE_LANE_CFG="$VERIFY_CFG" bash "$HERE/verify.sh" --save-baseline 2>&1)
VERIFY_RC=$?
[ "$VERIFY_RC" = "0" ] && ok "模拟六项验证全绿" || ng "模拟 verify.sh 失败（退出码 ${VERIFY_RC}）"
VERIFY_SECRETS="198.51.100.99 203.0.113.77 192.0.2.44"
VERIFY_LEAK=""
for secret in $VERIFY_SECRETS; do
  if printf '%s' "$VERIFY_OUT" | grep -Fq "$secret"; then VERIFY_LEAK="$VERIFY_LEAK $secret"; fi
done
[ -z "$VERIFY_LEAK" ] && ok "verify 输出不含完整静态/Claude/普通出口 IP" || ng "verify 输出泄漏完整 IP:${VERIFY_LEAK}"
printf '%s' "$VERIFY_OUT" | grep -Fq '198***' &&
  printf '%s' "$VERIFY_OUT" | grep -Fq '203***' &&
  printf '%s' "$VERIFY_OUT" | grep -Fq '192***' && ok "verify 输出统一使用 3 字符掩码" || ng "verify 输出缺少预期掩码"
[ "$("$OSASCRIPT" -l JavaScript "$JSON_HELPER" json-get "$VERIFY_CFG/claude-lane-state.json" claude_exit_ip)" = "203.0.113.77" ] &&
  ok "状态文件内部保留完整出口用于比较" || ng "状态文件没有保存完整出口"
[ "$(stat -f '%Lp' "$VERIFY_CFG/claude-lane-state.json")" = "600" ] && ok "状态文件权限 600" || ng "状态文件权限不是 600"

VERIFY_CHANGED=$(PATH="$VERIFY_BIN:$PATH" CLAUDE_LANE_CFG="$VERIFY_CFG" VERIFY_TRACE_IP=203.0.113.88 \
  bash "$HERE/verify.sh" --save-baseline 2>&1); VERIFY_CHANGED_RC=$?
[ "$VERIFY_CHANGED_RC" = "0" ] &&
  [ "$("$OSASCRIPT" -l JavaScript "$JSON_HELPER" json-get "$VERIFY_CFG/claude-lane-state.json" claude_exit_ip)" = "203.0.113.88" ] &&
  ok "显式 --save-baseline 可在其余检查全绿时更新旧基线" || ng "出口变化后无法安全更新基线"

VERIFY_NO_LOC=$(PATH="$VERIFY_BIN:$PATH" CLAUDE_LANE_CFG="$VERIFY_CFG" VERIFY_TRACE_IP=203.0.113.88 \
  VERIFY_TRACE_NO_LOC=1 bash "$HERE/verify.sh" 2>&1); VERIFY_NO_LOC_RC=$?
[ "$VERIFY_NO_LOC_RC" != "0" ] && printf '%s' "$VERIFY_NO_LOC" | grep -q '出口国家不是 US' &&
  ok "出口地区缺失时失败关闭" || ng "出口地区缺失仍被判为全绿"

cp "$VERIFY_CFG/claude-lane-state.json" "$SANDBOX/state-good.json"
printf '{broken\n' > "$VERIFY_CFG/claude-lane-state.json"
VERIFY_BAD_STATE=$(PATH="$VERIFY_BIN:$PATH" CLAUDE_LANE_CFG="$VERIFY_CFG" bash "$HERE/verify.sh" --save-baseline 2>&1); VERIFY_BAD_STATE_RC=$?
[ "$VERIFY_BAD_STATE_RC" != "0" ] && printf '%s' "$VERIFY_BAD_STATE" | grep -q '状态文件损坏' &&
  grep -q '^{broken' "$VERIFY_CFG/claude-lane-state.json" &&
  ok "损坏的基线状态不会被忽略或覆盖" || ng "损坏 state 被当成无基线或遭覆盖"
cp "$SANDBOX/state-good.json" "$VERIFY_CFG/claude-lane-state.json"

mv "$VERIFY_CFG/logs/service/service_latest.log" "$SANDBOX/service.log"
VERIFY_NO_LOG=$(PATH="$VERIFY_BIN:$PATH" CLAUDE_LANE_CFG="$VERIFY_CFG" bash "$HERE/verify.sh" 2>&1); VERIFY_NO_LOG_RC=$?
[ "$VERIFY_NO_LOG_RC" != "0" ] && printf '%s' "$VERIFY_NO_LOG" | grep -q '日志不存在或不可读' &&
  ok "内核日志缺失时失败关闭" || ng "日志缺失仍被判 TUN 正常"
mv "$SANDBOX/service.log" "$VERIFY_CFG/logs/service/service_latest.log"

echo "[11] 回滚快照：回滚之后【立即】撤销回滚，两类文件都要完整恢复，且不能卡死"
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

echo "[12] 静态检查：脚本里不能出现 \$VAR 紧跟中文标点（bash 会把标点首字节吃进变量名）"
# LC_ALL=C 按字节匹配；[^ -~] 是非 ASCII 可打印字符。${VAR} 形式不会命中。
LINT=$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$HERE"/*.sh 2>/dev/null || true)
[ -z "$LINT" ] && ok "所有脚本都用了 \${VAR} 形式" || ng "这些位置有隐患：${LINT}"

RUNTIME_PY=$(grep -nE '(^|[[:space:]])python3([[:space:]]|$)' \
  "$HERE/set-credentials.sh" "$HERE/profile-config.sh" "$HERE/verify.sh" 2>/dev/null || true)
[ -z "$RUNTIME_PY" ] && ok "运行期脚本不再调用 python3" || ng "仍有 Python 运行期调用：${RUNTIME_PY}"

echo "[13] macos-evidence.sh：语法与关键静态门禁（秘密扫描 / 失败关闭 / 不读基线内容）"
if [ -f "$HERE/macos-evidence.sh" ] && /bin/bash -n "$HERE/macos-evidence.sh"; then
  ok "macos-evidence.sh 存在且 bash -n 通过"
else
  ng "macos-evidence.sh 缺失或语法错误"
fi
if /usr/bin/grep -Fq 'assert-no-secrets' "$HERE/macos-evidence.sh" &&
   /usr/bin/grep -Fq 'assert-no-secrets' "$HERE/macos-json.js" &&
   /usr/bin/grep -Fq 'sk-[A-Za-z0-9_-]{8,}' "$HERE/macos-json.js"; then
  ok "macos-evidence 含秘密扫描门禁（Key/IP 模式）"
else
  ng "macos-evidence 缺少秘密扫描门禁"
fi
if /usr/bin/grep -Fq '六项验证尚未通过' "$HERE/macos-evidence.sh" &&
   /usr/bin/grep -Fq 'VALIDATION_PASSED' "$HERE/macos-evidence.sh" &&
   /usr/bin/grep -Fq '拒绝落盘' "$HERE/macos-evidence.sh"; then
  ok "macos-evidence 验证失败与秘密命中均为失败关闭"
else
  ng "macos-evidence 缺少失败关闭断言"
fi
# Baseline existence only: must not call json-get / plutil -extract / cat on the baseline path.
if /usr/bin/grep -Fq 'BASELINE_PATH' "$HERE/macos-evidence.sh" &&
   /usr/bin/grep -Eq '\[ -f "\$BASELINE_PATH" \]' "$HERE/macos-evidence.sh" &&
   ! /usr/bin/grep -E 'json-get.*BASELINE|plutil.*BASELINE_PATH|/bin/cat "\$BASELINE_PATH"' "$HERE/macos-evidence.sh" >/dev/null; then
  ok "macos-evidence 只检查基线存在性、不读内容"
else
  ng "macos-evidence 可能读取基线内容或未做存在性检查"
fi
if /usr/bin/grep -Fq -- '--probe-secret-file' "$HERE/macos-evidence.sh"; then
  ok "macos-evidence 支持 --probe-secret-file 自测钩子"
else
  ng "macos-evidence 缺少 --probe-secret-file 钩子"
fi

# Probe: forged evidence containing a reserved-looking key must not be written.
PROBE_ROOT="$SANDBOX/macos-evidence-probe"
export CLAUDE_LANE_SETUP_ROOT="$PROBE_ROOT"
/bin/mkdir -p "$PROBE_ROOT"
printf '%s\n' '{"schema":2,"note":"sk-probeKEY12345678 must not land"}' >"$PROBE_ROOT/forged.json"
PROBE_OUT=$(/bin/bash "$HERE/macos-evidence.sh" --probe-secret-file "$PROBE_ROOT/forged.json" 2>&1) || PROBE_RC=$?
PROBE_RC=${PROBE_RC:-0}
if [ "$PROBE_RC" != "0" ] &&
   printf '%s' "$PROBE_OUT" | /usr/bin/grep -Eq 'API Key|拒绝落盘|秘密' &&
   [ ! -f "$PROBE_ROOT/audit/darwin-arm64.json" ] &&
   [ ! -f "$PROBE_ROOT/audit/darwin-x64.json" ]; then
  ok "macos-evidence 命中 Key 模式时拒绝落盘"
else
  ng "macos-evidence Key 探针未失败关闭（rc=${PROBE_RC}）"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m== 全部 %s 项通过 ==\033[0m\n' "$PASS"
else
  printf '\033[31m== %s 项通过，%s 项失败 ==\033[0m\n' "$PASS" "$FAIL"
fi
echo "（verify.sh 依赖真实网络和 Clash 内核，不在本烟雾测试范围内）"
exit "$FAIL"
