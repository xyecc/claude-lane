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

echo "[9] add-static.rb：加第二个静态 IP 只插入文本，不能抹掉 managed 标记和注释（旧版整份 YAML.dump 抹过）"
CFG9="$SANDBOX/cfg9"; mkdir -p "$CFG9"
cat > "$SANDBOX/t9.rb" <<'RB'
require ARGV[0]
base = ARGV[1]
NODE = { 'name' => '🇺🇸 US-Static-2', 'type' => 'socks5', 'server' => '203.0.113.7', 'port' => 11324,
         'username' => 'u2', 'password' => %q{p'a:ss"w\d}, 'udp' => false, 'dialer-proxy' => 'US-Chain' }
RUNTIME = "proxies:\n- {name: \"🇺🇸 US-Static\", type: socks5}\nproxy-groups:\n- {name: Claude, type: select, proxies: [\"🇺🇸 US-Static\"]}\n- {name: US-Chain, type: select, proxies: [a]}\n"
CASES = {
  # set-credentials.sh 写出来的样子：两格缩进 + managed 标记 + 行尾注释
  'template' => [
    "# 由 claude-lane 的 set-credentials.sh 写入\nprepend: []\n\nappend:\n  # claude-lane managed start\n  - name: \"🇺🇸 US-Static\"\n    type: socks5                      # 必须 socks5\n    server: \"198.51.100.10\"\n    port: 12324\n    udp: false\n    dialer-proxy: \"US-Chain\"\n  # claude-lane managed end\n\ndelete: []\n",
    "# 模板②\nprepend:\n  # Claude 流量的最终出口\n  - name: \"Claude\"\n    type: select\n    proxies:\n      - \"🇺🇸 US-Static\"\n\n  - name: \"US-Chain\"\n    type: select\n    proxies:\n      - \"a\"\n\nappend: []\n\ndelete: []\n"],
  # 旧版 add-static.rb 整份 YAML.dump 之后的样子：顶格「- 」+ 转义 emoji + ---
  'dumped' => [
    "---\nprepend: []\nappend:\n- name: \"\\U0001F1FA\\U0001F1F8 US-Static\"\n  type: socks5\n  port: 1\ndelete: []\n",
    "---\nprepend:\n- name: Claude\n  type: select\n  proxies:\n  - \"\\U0001F1FA\\U0001F1F8 US-Static\"\n- name: US-Chain\n  type: select\n  proxies:\n  - a\nappend: []\ndelete: []\n"],
  # 空 append + 分组用行内列表
  'flow' => [
    "prepend:\n  - {name: \"🇺🇸 US-Static\", type: socks5}\nappend: []\ndelete: []\n",
    "prepend:\n  - name: Claude\n    type: select\n    proxies: [\"🇺🇸 US-Static\"]\n  - {name: US-Chain, type: select, proxies: [a]}\n"]
}
CASES.each do |name, (ptxt, gtxt)|
  cfg = File.join(base, name)
  Dir.mkdir(cfg) rescue nil
  Dir.mkdir(File.join(cfg, 'profiles')) rescue nil
  File.write(File.join(cfg, 'profiles.yaml'), "current: SUB\nitems:\n- uid: SUB\n  type: remote\n  option:\n    proxies: pX\n    groups: gX\n")
  File.write(File.join(cfg, 'profiles', 'pX.yaml'), ptxt)
  File.write(File.join(cfg, 'profiles', 'gX.yaml'), gtxt)
  File.write(File.join(cfg, 'clash-verge.yaml'), RUNTIME)
  begin
    changes, = second_static_changes(cfg, NODE)
    pnew = changes[File.join(cfg, 'profiles', 'pX.yaml')]
    gnew = changes[File.join(cfg, 'profiles', 'gX.yaml')]
    File.write(File.join(cfg, 'profiles', 'pX.yaml'), pnew)
    File.write(File.join(cfg, 'profiles', 'gX.yaml'), gnew)
    p = YAML.safe_load(pnew); g = YAML.safe_load(gnew)
    puts(p['append'].last == NODE ? "OK #{name}：新节点写入且值无损（密码含 ' : \" \\）" : "NG #{name}：新节点不对 #{p['append'].last.inspect}")
    claude = (g['prepend'] || []).find { |x| x['name'] == 'Claude' }
    puts(claude['proxies'] == ['🇺🇸 US-Static', '🇺🇸 US-Static-2'] ? "OK #{name}：Claude 分组追加了 US-Static-2" : "NG #{name}：Claude 分组 #{claude['proxies'].inspect}")
    lost = (ptxt.lines + gtxt.lines).map(&:rstrip).select { |l| l.strip.start_with?('#') } - (pnew.lines + gnew.lines).map(&:rstrip)
    puts(lost.empty? ? "OK #{name}：注释和 managed 标记一行没丢" : "NG #{name}：丢了 #{lost.inspect}")
  rescue => e
    puts "NG #{name}：抛错 #{e.class}: #{e.message}"
  end
end
RB
while IFS= read -r line; do
  case "$line" in OK\ *) ok "${line#OK }" ;; NG\ *) ng "${line#NG }" ;; *) ng "ruby 输出异常：${line}" ;; esac
done < <(ruby "$SANDBOX/t9.rb" "$HERE/add-static.rb" "$CFG9" 2>&1)
# 加完第二条以后，set-credentials.sh 还能找到托管块、只替换第一条（这正是旧版坏掉的地方）
OUT=$(printf '198.51.100.99\n12324\nu1\np1\n' | CLAUDE_LANE_CFG="$CFG9/template" bash "$HERE/set-credentials.sh" 2>&1); RC=$?
P9="$CFG9/template/profiles/pX.yaml"
[ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q 'MODE=replace\|凭证已写入' && ok "加完第二条后 set-credentials 仍能替换托管块" || ng "加完第二条后 set-credentials 失败（退出码 ${RC}）"
grep -q '198.51.100.99' "$P9" && grep -q 'US-Static-2' "$P9" && ok "第一条凭证已更新，第二条原样保留" || ng "替换后第一条没更新或第二条丢了"

echo "[10] lanecheck.py rules：拿真实进程名对规则（2026-11-02 Chrome Aperitif / Claude Code 版本号进程名两个坑）"
LC="$HERE/lanecheck.py"; T10="$SANDBOX/t10"; mkdir -p "$T10"
TAB=$(printf '\t')
# 本机实测过的进程名全集（名字<TAB>mihomo 看到的真实路径），见 docs/compatibility.md
cat > "$T10/ps-all.txt" <<EOF
Google Chrome${TAB}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome
Google Chrome Helper${TAB}/Applications/Google Chrome.app/Contents/Frameworks/x/Google Chrome Helper
Google Chrome Helper (Aperitif)${TAB}/Applications/Google Chrome.app/Contents/Frameworks/x/Google Chrome Helper (Aperitif)
Google Chrome Helper (Aperitif Renderer)${TAB}/Applications/Google Chrome.app/Contents/Frameworks/x/Google Chrome Helper (Aperitif Renderer)
Claude${TAB}/Applications/Claude.app/Contents/MacOS/Claude
Claude Helper${TAB}/Applications/Claude.app/Contents/Frameworks/Claude Helper
Claude Helper (GPU)${TAB}/Applications/Claude.app/Contents/Frameworks/Claude Helper (GPU)
Claude Helper (Renderer)${TAB}/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer)
2.1.316${TAB}/Users/someone/.local/share/claude/versions/2.1.316
claude${TAB}/opt/homebrew/bin/claude
EOF
# 修复前（v1.2.1 模板）的 Chrome 规则 + 本机 API 返回的格式
cat > "$T10/old-api.json" <<'EOF'
{"rules":[
 {"type":"AND","payload":"((ProcessName,Google Chrome Helper) && (Network,udp) && (DstPort,443))","proxy":"REJECT"},
 {"type":"AND","payload":"((ProcessName,Google Chrome) && (Network,udp) && (DstPort,443))","proxy":"REJECT"},
 {"type":"DomainSuffix","payload":"claude.com","proxy":"Claude"},
 {"type":"DomainSuffix","payload":"http-intake.logs.us5.datadoghq.com","proxy":"Claude"},
 {"type":"Match","payload":"","proxy":"Final"}]}
EOF
printf 'Google Chrome Helper (Aperitif)\t/x/Google Chrome Helper (Aperitif)\n' > "$T10/ps-aperitif.txt"
OUT=$(python3 "$LC" rules "$T10/old-api.json" --ps "$T10/ps-aperitif.txt" 2>&1); RC=$?
[ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'Aperitif' && ok "旧的精确名规则遇到 Aperitif 进程会报红（今天的 bug 能被抓到）" || ng "Aperitif 没被识别为未覆盖（退出码 ${RC}）：${OUT}"
OUT=$(python3 "$LC" rules "$HERE/../templates/3-rules.yaml" --ps "$T10/ps-all.txt" 2>&1); RC=$?
[ "$RC" = "0" ] && ! printf '%s' "$OUT" | grep -q '^NG' && ok "模板③覆盖所有已知进程名（Chrome 各 Helper / Claude 桌面版 / Claude Code 版本号进程）" || ng "模板③有进程没覆盖：${OUT}"
# 进程名自带括号的 API 写法要能正确拆开
cat > "$T10/paren.json" <<'EOF'
{"rules":[
 {"type":"AND","payload":"((DomainSuffix,anthropic.com) && (Network,udp))","proxy":"REJECT"},
 {"type":"AND","payload":"((DomainSuffix,claude.ai) && (Network,udp))","proxy":"REJECT"},
 {"type":"AND","payload":"((DomainSuffix,claude.com) && (Network,udp))","proxy":"REJECT"},
 {"type":"AND","payload":"((DomainSuffix,claudeusercontent.com) && (Network,udp))","proxy":"REJECT"},
 {"type":"AND","payload":"((DomainKeyword,anthropic) && (Network,udp))","proxy":"REJECT"},
 {"type":"AND","payload":"((IPCIDR,160.79.104.0/23) && (Network,udp))","proxy":"REJECT"},
 {"type":"AND","payload":"((ProcessNameRegex,^Google Chrome) && (Network,udp) && (DstPort,443))","proxy":"REJECT"},
 {"type":"AND","payload":"((ProcessName,Claude Helper (GPU)) && (Network,udp))","proxy":"REJECT"},
 {"type":"ProcessName","payload":"Claude Helper (GPU)","proxy":"Claude"},
 {"type":"DomainSuffix","payload":"claude.com","proxy":"Claude"},
 {"type":"DomainSuffix","payload":"http-intake.logs.us5.datadoghq.com","proxy":"Claude"}]}
EOF
printf 'Claude Helper (GPU)\t/x/Claude Helper (GPU)\n' > "$T10/ps-gpu.txt"
OUT=$(python3 "$LC" rules "$T10/paren.json" --ps "$T10/ps-gpu.txt" 2>&1); RC=$?
[ "$RC" = "0" ] && ok "进程名带括号（Claude Helper (GPU)）的 AND 规则解析正确" || ng "带括号的进程名解析错了：${OUT}"
# 版本号进程名只靠名字规则 → 必须报红
OUT=$(python3 "$LC" rules "$T10/paren.json" --ps <(printf '2.1.316\t/Users/u/.local/share/claude/versions/2.1.316\n') 2>&1); RC=$?
[ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q '2.1.316' && ok "Claude Code 版本号进程名没有路径规则时会报红" || ng "版本号进程名没被发现：${OUT}"
# 顺序：QUIC 拦截排在 Claude 导流规则后面要报红；全局 UDP/443 拦截要报红
cat > "$T10/order.json" <<'EOF'
{"rules":[
 {"type":"DomainSuffix","payload":"claude.ai","proxy":"Claude"},
 {"type":"AND","payload":"((ProcessNameRegex,^Google Chrome) && (Network,udp) && (DstPort,443))","proxy":"REJECT"},
 {"type":"AND","payload":"((Network,udp) && (DstPort,443))","proxy":"REJECT"},
 {"type":"DomainSuffix","payload":"claude.com","proxy":"Claude"},
 {"type":"DomainSuffix","payload":"http-intake.logs.us5.datadoghq.com","proxy":"Claude"}]}
EOF
OUT=$(python3 "$LC" rules "$T10/order.json" --ps "$T10/ps-aperitif.txt" 2>&1)
printf '%s' "$OUT" | grep -q '排在' && ok "QUIC 拦截排在 Claude 规则后面会报红" || ng "没发现顺序错误：${OUT}"
printf '%s' "$OUT" | grep -q '^NG 存在全局' && ok "全局 UDP/443 拦截会报红" || ng "没发现全局 UDP/443 拦截：${OUT}"

echo "[11] lanecheck.py conns：实时连接漏流（样本是 2026-11-02 现场抓到的那条）"
cat > "$T10/leak.json" <<'EOF'
{"connections":[
 {"metadata":{"network":"udp","host":"claude.ai","destinationPort":"443","process":"Google Chrome Helper (Aperitif)","processPath":"/x"},"rule":"","rulePayload":"","chains":["DIRECT"]},
 {"metadata":{"network":"tcp","host":"api.anthropic.com","destinationPort":"443","process":"2.1.316","processPath":"/Users/u/.local/share/claude/versions/2.1.316"},"rule":"DomainSuffix","chains":["🇺🇸 US-Static-2","Claude"]}]}
EOF
OUT=$(python3 "$LC" conns "$T10/leak.json" 2>&1); RC=$?
[ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'Chrome 的 QUIC 没被拦截' && ok "Chrome QUIC 直连（规则为空、走 DIRECT）被识别为漏流" || ng "没识别出 QUIC 漏流：${OUT}"
cat > "$T10/clean.json" <<'EOF'
{"connections":[
 {"metadata":{"network":"tcp","host":"claude.ai","destinationPort":"443","process":"Google Chrome Helper (Aperitif)"},"rule":"DomainSuffix","chains":["🇺🇸 US-Static-2","Claude"]},
 {"metadata":{"network":"tcp","host":"www.google.com","destinationPort":"443","process":"Google Chrome Helper (Aperitif)"},"rule":"DomainSuffix","chains":["SG","Proxies","Google"]}]}
EOF
OUT=$(python3 "$LC" conns "$T10/clean.json" 2>&1); RC=$?
[ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q '检查了 1 条' && ok "正常连接不误报，且只统计 Claude 相关连接" || ng "正常连接被误报：${OUT}"
cat > "$T10/final.json" <<'EOF'
{"connections":[{"metadata":{"network":"tcp","sniffHost":"a.claude.ai","destinationPort":"443","process":""},"rule":"Match","chains":["JP","Final"]}]}
EOF
OUT=$(python3 "$LC" conns "$T10/final.json" 2>&1); RC=$?
[ "$RC" = "1" ] && ok "claude 域名走了 Final 兜底会报红（进程识别不出来时也能抓）" || ng "没发现走 Final 的 claude 连接：${OUT}"

echo "[12] probe.sh：socket 自动探测（Verge 2.5.8 起配置里写的路径是错的，必须以内核启动参数为准）"
CFG12="$SANDBOX/cfg12"; mkdir -p "$CFG12"
printf 'external-controller-unix: /var/folders/zz/T/verge-mihomo.sock\n' > "$CFG12/clash-verge.yaml"
PSARGS='/Library/Application Support/clash-verge-service/cores/verge-mihomo -d /x -f /x/config.yaml -ext-ctl-unix /var/run/clash-verge-service/users/501/verge-mihomo.sock'
C=$(CLAUDE_LANE_CFG="$CFG12" CLAUDE_LANE_PS_ARGS="$PSARGS" bash "$HERE/probe.sh" --candidates | tr '\n' '|')
[ "$C" = "/var/run/clash-verge-service/users/501/verge-mihomo.sock|/var/folders/zz/T/verge-mihomo.sock|/tmp/verge/verge-mihomo.sock|" ] \
  && ok "候选顺序：内核启动参数 > 生成配置 > 老位置 /tmp/verge" || ng "候选顺序不对：${C}"
C=$(CLAUDE_LANE_CFG="$SANDBOX/none" CLAUDE_LANE_PS_ARGS="" bash "$HERE/probe.sh" --candidates | tr '\n' '|')
[ "$C" = "/tmp/verge/verge-mihomo.sock|" ] && ok "没有内核进程、没有配置时只剩老位置" || ng "空环境候选不对：${C}"
C=$(CLAUDE_LANE_SOCK="$SANDBOX/x.sock" CLAUDE_LANE_PS_ARGS="$PSARGS" bash "$HERE/probe.sh" --candidates | tr '\n' '|')
[ "$C" = "$SANDBOX/x.sock|" ] && ok "设了 CLAUDE_LANE_SOCK 就只认它" || ng "CLAUDE_LANE_SOCK 没生效：${C}"
CLAUDE_LANE_SOCK="$SANDBOX/x.sock" bash "$HERE/probe.sh" --sock >/dev/null 2>&1
[ "$?" = "1" ] && ok "socket 不存在时 --sock 退出码 1" || ng "socket 不存在时 --sock 没返回 1"

echo "[13] verify.sh：API 不可达时干净地报红，不能崩出 Python traceback（v1.2.1 在 Verge 2.5.8 上就是这么崩的）"
CFG13="$SANDBOX/cfg13"; mkdir -p "$CFG13"
printf 'mixed-port: 1\n' > "$CFG13/clash-verge.yaml"   # 端口 1：出口双验立刻失败，不发真实网络请求
with_timeout 60 env CLAUDE_LANE_CFG="$CFG13" CLAUDE_LANE_SOCK="$SANDBOX/nope.sock" bash "$HERE/verify.sh" >"$SANDBOX/v13.log" 2>&1
RC=$?
[ "$RC" != "124" ] && ok "没卡死" || ng "verify.sh 超时卡死"
! grep -q 'Traceback' "$SANDBOX/v13.log" && ok "没有 Python traceback" || ng "崩出了 traceback：$(grep -m1 -A3 Traceback "$SANDBOX/v13.log")"
[ "$RC" != "0" ] && grep -q 'API 不可达' "$SANDBOX/v13.log" && ok "明确报出 API 不可达且整体判失败" || ng "没有正确报错（退出码 ${RC}）"

echo "[14] verify.sh 第 4 项：claude.ai 偶发失败会重试，连续 3 次失败才报红（2026-11-05 静态 IP 线路偶发断连误报）"
CFG14="$SANDBOX/cfg14"; BIN14="$SANDBOX/bin14"; mkdir -p "$CFG14" "$BIN14"
printf 'mixed-port: 7897\n' > "$CFG14/clash-verge.yaml"
printf '{"claude_exit_ip": "203.0.113.50"}\n' > "$CFG14/claude-lane-state.json"
cat > "$BIN14/curl" <<'FAKE'
#!/usr/bin/env bash
# 假 curl：claude.ai 前 $FAKE_FAILS 次失败，之后返回固定出口；ipify 返回普通出口；其余（unix socket 等）一律失败
cnt="$FAKE_DIR/claude.count"
case "$*" in
  *claude.ai/cdn-cgi/trace*)
    n=$(( $(cat "$cnt" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$cnt"
    [ "$n" -le "$FAKE_FAILS" ] && exit 35
    printf 'ip=203.0.113.50\nloc=US\n' ;;
  *api.ipify.org*) printf '198.51.100.20' ;;
  *) exit 7 ;;
esac
FAKE
chmod +x "$BIN14/curl"
run14() {  # $1 = 前几次失败
  rm -f "$SANDBOX/claude.count"
  with_timeout 90 env PATH="$BIN14:$PATH" FAKE_DIR="$SANDBOX" FAKE_FAILS="$1" \
    CLAUDE_LANE_CFG="$CFG14" CLAUDE_LANE_SOCK="$SANDBOX/nope.sock" bash "$HERE/verify.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}
OUT=$(run14 1); N=$(cat "$SANDBOX/claude.count" 2>/dev/null)
echo "$OUT" | grep -q '与基线一致' && echo "$OUT" | grep -q '第 2 次请求才成功' && [ "$N" = 2 ] \
  && ok "失败 1 次 → 第 2 次成功，判通过并提示线路不稳" || ng "偶发失败没有被重试兜住（请求了 ${N:-0} 次）：$(echo "$OUT" | grep -A1 '\[4/6\]' | tail -1)"
OUT=$(run14 9); N=$(cat "$SANDBOX/claude.count" 2>/dev/null)
echo "$OUT" | grep -q '请求失败（试了 3 次）' && [ "$N" = 3 ] \
  && ok "一直失败 → 试满 3 次后报红" || ng "一直失败时没有试满 3 次再报红（请求了 ${N:-0} 次）"

echo "[15] 按目的地拒绝发往 Claude 的 UDP（v1.2.3）：不管哪个程序、叫什么名字都拦住"
T15="$SANDBOX/t15"; mkdir -p "$T15"
OUT=$(python3 "$LC" rules "$T10/old-api.json" --ps "$T10/ps-aperitif.txt" 2>&1)
printf '%s' "$OUT" | grep -q '没有按目的地拒绝' && printf '%s' "$OUT" | grep -q '160.79.104.0/23' \
  && ok "只靠进程名拦截的旧规则（v1.2.2 及以前）会报红" || ng "缺按目的地拦截没被发现：${OUT}"
OUT=$(python3 "$LC" rules "$T10/paren.json" --ps "$T10/ps-gpu.txt" 2>&1)
printf '%s' "$OUT" | grep -q '^OK 发往 Claude 的 UDP' && printf '%s' "$OUT" | grep -q '^OK 无全局' \
  && ok "API 写法（DomainSuffix / IPCIDR）认得出，且不会被误判成全局 UDP 拦截" || ng "API 写法的按目的地拦截没认出来：${OUT}"
cat > "$T15/late.json" <<'EOF'
{"rules":[
 {"type":"DomainSuffix","payload":"claude.ai","proxy":"Claude"},
 {"type":"AND","payload":"((DomainSuffix,anthropic.com) && (Network,udp))","proxy":"REJECT"},
 {"type":"AND","payload":"((DomainSuffix,claude.ai) && (Network,udp))","proxy":"REJECT"},
 {"type":"AND","payload":"((DomainSuffix,claude.com) && (Network,udp))","proxy":"REJECT"},
 {"type":"AND","payload":"((DomainSuffix,claudeusercontent.com) && (Network,udp))","proxy":"REJECT"},
 {"type":"AND","payload":"((IPCIDR,160.79.104.0/23) && (Network,udp))","proxy":"REJECT"}]}
EOF
OUT=$(python3 "$LC" rules "$T15/late.json" --ps /dev/null 2>&1)
printf '%s' "$OUT" | grep -q '按目的地的 UDP 拒绝排在' && ok "按目的地拦截排在 Claude 导流后面会报红" || ng "没发现顺序错误：${OUT}"
cat > "$T15/port.json" <<'EOF'
{"rules":[
 {"type":"AND","payload":"((DomainSuffix,anthropic.com) && (Network,udp) && (DstPort,443))","proxy":"REJECT"},
 {"type":"AND","payload":"((DomainSuffix,claude.ai) && (Network,udp) && (DstPort,443))","proxy":"REJECT"},
 {"type":"AND","payload":"((DomainSuffix,claude.com) && (Network,udp) && (DstPort,443))","proxy":"REJECT"},
 {"type":"AND","payload":"((DomainSuffix,claudeusercontent.com) && (Network,udp) && (DstPort,443))","proxy":"REJECT"},
 {"type":"AND","payload":"((IPCIDR,160.79.104.0/23) && (Network,udp) && (DstPort,443))","proxy":"REJECT"}]}
EOF
OUT=$(python3 "$LC" rules "$T15/port.json" --ps /dev/null 2>&1)
printf '%s' "$OUT" | grep -q '没有按目的地拒绝' && ok "只拦 UDP/443 不算数（其他端口的 UDP 照样会直连）" || ng "带端口条件的拦截被误当成完整：${OUT}"
printf 'Microsoft Edge Helper\t/Applications/Microsoft Edge.app/x/Microsoft Edge Helper\n' > "$T15/ps-edge.txt"
OUT=$(python3 "$LC" rules "$T10/paren.json" --ps "$T15/ps-edge.txt" 2>&1)
! printf '%s' "$OUT" | grep -q '^WARN.*Edge' && ok "有按目的地拦截时，Edge 在跑不再误报" || ng "有按目的地拦截时 Edge 仍被提醒：${OUT}"
OUT=$(python3 "$LC" rules "$T10/old-api.json" --ps "$T15/ps-edge.txt" 2>&1)
printf '%s' "$OUT" | grep -q '^WARN.*Edge' && ok "没有按目的地拦截时，Edge 在跑会提醒" || ng "没有按目的地拦截时 Edge 没被提醒：${OUT}"
cat > "$T15/udp-leak.json" <<'EOF'
{"connections":[
 {"metadata":{"network":"udp","host":"claude.ai","destinationPort":"443","process":"com.apple.WebKit.Networking"},"rule":"","chains":["DIRECT"]},
 {"metadata":{"network":"udp","host":"","destinationIP":"160.79.104.10","destinationPort":"3478","process":"Some App"},"rule":"","chains":["DIRECT"]}]}
EOF
OUT=$(python3 "$LC" conns "$T15/udp-leak.json" 2>&1); RC=$?
[ "$RC" = "1" ] && [ "$(printf '%s\n' "$OUT" | grep -c '发往 Claude 的 UDP 没被拒绝')" = 2 ] \
  && ok "非 Chrome 程序（Safari 等）发往 Claude 的 UDP 漏流、只有 IP 没有域名的也能抓到" || ng "没抓到非 Chrome 的 UDP 漏流：${OUT}"

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m== 全部 %s 项通过 ==\033[0m\n' "$PASS"
else
  printf '\033[31m== %s 项通过，%s 项失败 ==\033[0m\n' "$PASS" "$FAIL"
fi
echo "（verify.sh 依赖真实网络和 Clash 内核，不在本烟雾测试范围内）"
exit "$FAIL"
