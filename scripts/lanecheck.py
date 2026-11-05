#!/usr/bin/env python3
"""claude-lane 的规则覆盖 / 连接漏流判定（verify.sh 第 3、5 项调用；selftest 第 10、11 组离线测试）。

为什么单独成文件：这段"某个进程会不会被某条规则命中"的判断出过两次错，而且都是静默的——
  · 2026-07：Claude Code 的进程名是小写 claude，规则只写了 claude.exe，遥测漏了一段时间
  · 2026-11-02：Chrome 156 的网络进程改名为「Google Chrome Helper (Aperitif)」，
    精确名的 QUIC 拦截规则失效 → QUIC 不经规则直连（节点全是 udp:false）→ 国内 IP → claude.ai 报地区不可用；
    同一天还发现 Claude Code 原生安装版的进程名变成了版本号（如 2.1.316），进程规则同样失效
  · 所以 v1.2.3 起模板③最前面改为「按目的地」拒绝发往 Claude 的 UDP，不再只靠进程名；这里也核对它
这类坑只能靠"拿真实进程名/真实连接去对规则"来发现，所以逻辑放这里，能被测试覆盖。
各版本的进程名、路径差异记录在 docs/compatibility.md。

用法：
  python3 lanecheck.py rules <RULES> [--ps FILE]   规则完整性（RULES 可以是 mihomo /rules 的 JSON、
                                                    模板 yaml，或 - 表示从 stdin 读 JSON）
  python3 lanecheck.py conns <CONNS>               实时连接漏流扫描（mihomo /connections 的 JSON，或 -）

  --ps FILE：每行「进程名<TAB>完整路径」，用来代替读本机 ps（测试用）
输出每行以 OK / NG / WARN / NOTE 开头；有 NG 时退出码 1。
"""
import ipaddress
import json
import re
import subprocess
import sys

# 已知会联网的 Chrome 进程名。即使此刻 Chrome 没开，规则也必须覆盖它们（见 docs/compatibility.md）
KNOWN_CHROME = ["Google Chrome", "Google Chrome Helper", "Google Chrome Helper (Aperitif)"]
# Claude Code 原生安装版的可执行文件位置：进程名是版本号，只能按路径认
CC_PATH = re.compile(r"/\.local/share/claude/versions/[^/]+$")
CLAUDE_DOMAINS = ("anthropic.com", "claude.ai", "claude.com", "claudeusercontent.com")
TELEMETRY_HOST = "http-intake.logs.us5.datadoghq.com"
ANTHROPIC_CIDR = "160.79.104.0/23"
# 发往这些地址的 UDP 必须按目的地拒绝（模板③第 0 节）：Claude 专线不支持 UDP，不拒就会直连国内 IP
DEST_UDP = CLAUDE_DOMAINS + (ANTHROPIC_CIDR,)

ALIASES = {
    "processname": "PROCESS-NAME", "processnameregex": "PROCESS-NAME-REGEX",
    "processpath": "PROCESS-PATH", "processpathregex": "PROCESS-PATH-REGEX",
    "domainsuffix": "DOMAIN-SUFFIX", "domain": "DOMAIN", "domainkeyword": "DOMAIN-KEYWORD",
    "network": "NETWORK", "dstport": "DST-PORT", "ipcidr": "IP-CIDR",
}
PROC_KINDS = ("PROCESS-NAME", "PROCESS-NAME-REGEX", "PROCESS-PATH", "PROCESS-PATH-REGEX")


def norm(kind):
    k = kind.strip()
    return ALIASES.get(k.lower().replace("-", ""), k.upper())


# ── 规则解析：同时认 API 写法和配置写法 ────────────────────────────────

def groups(s):
    """最外层括号里的一级子组。进程名自带括号也不怕：
    '((ProcessName,Claude Helper (GPU)) && (Network,udp))' -> ['ProcessName,Claude Helper (GPU)', 'Network,udp']"""
    s = s.strip()
    if s.startswith("(") and s.endswith(")"):
        s = s[1:-1]
    out, depth, start = [], 0, None
    for i, ch in enumerate(s):
        if ch == "(":
            if depth == 0:
                start = i + 1
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0 and start is not None:
                out.append(s[start:i])
                start = None
    return out


def parse_rule(r):
    """统一成 (kind, [(条件类型, 值)...], 目标)。
    API：{"type": "AND", "payload": "((ProcessName,X) && (Network,udp))", "proxy": "REJECT"}
    配置："AND,((PROCESS-NAME,X),(NETWORK,UDP)),REJECT"  /  "PROCESS-NAME,X,Claude" """
    if isinstance(r, dict):
        kind, payload, target = r.get("type", ""), r.get("payload", ""), r.get("proxy", "")
    else:
        kind, _, rest = r.strip().partition(",")
        if kind.upper() in ("AND", "OR", "NOT"):
            depth, end = 0, len(rest)
            for i, ch in enumerate(rest):
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0:
                        end = i + 1
                        break
            payload, target = rest[:end], rest[end + 1:].split(",")[0]
        else:
            parts = rest.split(",")
            payload, target = parts[0], (parts[1] if len(parts) > 1 else "")
    kind = norm(kind)
    if kind in ("AND", "OR", "NOT"):
        conds = []
        for g in groups(payload):
            k, _, v = g.partition(",")
            conds.append((norm(k), v.strip()))
        return kind, conds, target.strip()
    return kind, [(kind, payload.strip())], target.strip()


def load_rules(src):
    if src == "-":
        return [parse_rule(r) for r in json.load(sys.stdin)["rules"]]
    if src.endswith((".yaml", ".yml")):
        # 模板/增强文件：只取引号包起来的列表项（我们的模板全是这种写法）
        rules = []
        for line in open(src, encoding="utf-8"):
            m = re.match(r"""^\s*-\s*(["'])(.*?)\1\s*(#.*)?$""", line)
            if m and "," in m.group(2):
                rules.append(parse_rule(m.group(2)))
        return rules
    return [parse_rule(r) for r in json.load(open(src, encoding="utf-8"))["rules"]]


# ── 进程匹配 ─────────────────────────────────────────────────────────

def cond_matches(cond, name, path):
    k, v = cond
    try:
        if k == "PROCESS-NAME":
            return v == name
        if k == "PROCESS-NAME-REGEX":
            return re.search(v, name) is not None
        if k == "PROCESS-PATH":
            return v == path
        if k == "PROCESS-PATH-REGEX":
            return re.search(v, path or "") is not None
    except re.error:
        return False
    return False


def blocks_udp443(rule, name, path):
    """这条规则会不会把该进程发往 443 的 UDP（QUIC）拒掉"""
    kind, conds, target = rule
    if kind != "AND" or target.upper() != "REJECT":
        return False
    procs = [c for c in conds if c[0] in PROC_KINDS]
    nets = [c for c in conds if c[0] == "NETWORK"]
    ports = [c for c in conds if c[0] == "DST-PORT"]
    others = [c for c in conds if c[0] not in PROC_KINDS + ("NETWORK", "DST-PORT")]
    if not procs or not nets or others:
        return False
    if not all(n[1].lower() == "udp" for n in nets):
        return False
    if ports and not all(p[1] == "443" for p in ports):
        return False
    return all(cond_matches(p, name, path) for p in procs)


def rejects_udp_to(rule, dest):
    """这条规则是不是「发往 dest 的 UDP 一律拒绝」，不带任何进程 / 端口条件"""
    kind, conds, target = rule
    if kind != "AND" or target.upper() != "REJECT":
        return False
    nets = [c for c in conds if c[0] == "NETWORK"]
    dsts = [c for c in conds if c[0] in ("DOMAIN-SUFFIX", "DOMAIN", "IP-CIDR")]
    if len(dsts) != 1 or not nets or len(nets) + len(dsts) != len(conds):
        return False
    if not all(n[1].lower() == "udp" for n in nets):
        return False
    return dsts[0][1].split(",")[0].strip() == dest   # 配置写法带 ",no-resolve"，API 写法不带


def routes_to_claude(rule, name, path):
    kind, conds, target = rule
    return target == "Claude" and kind in PROC_KINDS and cond_matches(conds[0], name, path)


def first_index(rules, pred):
    return next((i for i, r in enumerate(rules) if pred(r)), None)


# ── 进程分类 ─────────────────────────────────────────────────────────

def browser_of(name):
    if name.startswith("Google Chrome"):
        return "Chrome"
    if name.startswith("Microsoft Edge"):
        return "Edge"
    if name.startswith("Brave Browser"):
        return "Brave"
    if name == "Arc" or name.startswith("Arc Helper"):
        return "Arc"
    return None


def is_claude_proc(name, path):
    return (name.startswith("Claude") or name in ("claude", "claude.exe")
            or bool(CC_PATH.search(path or "")))


def running_procs(ps_file=None):
    """[(进程名, 完整路径)]，取法与 mihomo 一致：proc_pidpath 拿到【解析过符号链接】的可执行文件路径，
    进程名 = 路径最后一段。⚠️ 不能用 ps comm：Claude Code 经 ~/.local/bin/claude 符号链接启动时，
    ps 显示 claude，mihomo 看到的却是 versions/2.1.316（2026-11-02 实测），按 ps 判断会漏报。"""
    if ps_file:
        lines = open(ps_file, encoding="utf-8").read().splitlines()
        return sorted({tuple(l.split("\t", 1)) for l in lines if "\t" in l})
    out = subprocess.run(["ps", "-axww", "-o", "pid=,comm="], capture_output=True, text=True).stdout
    try:
        import ctypes
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        buf = ctypes.create_string_buffer(4096)
    except OSError:
        lib = None
    procs = set()
    for line in out.splitlines():
        pid, _, comm = line.strip().partition(" ")
        path = comm.strip()
        if lib is not None and pid.isdigit() and lib.proc_pidpath(int(pid), buf, 4096) > 0:
            path = buf.value.decode("utf-8", "replace")
        if path:
            procs.add((path.rsplit("/", 1)[-1], path))
    return sorted(procs)


# ── 子命令：rules ────────────────────────────────────────────────────

def check_rules(rules, procs):
    ng = 0

    def say(tag, msg):
        nonlocal ng
        ng += tag == "NG"
        print(tag, msg)

    first_claude = first_index(rules, lambda r: r[2] == "Claude")
    limit = len(rules) if first_claude is None else first_claude

    def quic_status(name, path):
        i = first_index(rules, lambda r: blocks_udp443(r, name, path))
        if i is None:
            return "missing"
        return "ok" if i < limit else "late"

    # ⓪ 按目的地拦截 UDP（最根本的一道：跟程序叫什么无关）
    miss, late = [], []
    for d in DEST_UDP:
        i = first_index(rules, lambda r: rejects_udp_to(r, d))
        if i is None:
            miss.append(d)
        elif i >= limit:
            late.append(d)
    if miss:
        say("NG", "发往这些 Claude 地址的 UDP 没有按目的地拒绝（换个浏览器、程序一改名就会从国内 IP 直连）: %s"
            " —— 用模板③第 0 节" % miss)
    if late:
        say("NG", "这些按目的地的 UDP 拒绝排在 Claude 分流规则后面（必须在最前）: %s" % late)
    dest_ok = not miss and not late
    if dest_ok:
        say("OK", "发往 Claude 的 UDP 不论哪个程序发都会被拒绝（按目的地拦截）")

    # ① 浏览器 QUIC 拦截：已知的 Chrome 进程名 + 此刻真实在跑的浏览器进程，逐个对规则
    browsers = {}
    for n in KNOWN_CHROME:
        browsers[n] = ("", "Chrome")
    for n, p in procs:
        b = browser_of(n)
        if b:
            browsers[n] = (p, b)
    bad_chrome, late_chrome, bad_other = [], [], []
    for n, (p, b) in sorted(browsers.items()):
        st = quic_status(n, p)
        if st == "ok":
            continue
        if b == "Chrome":
            (late_chrome if st == "late" else bad_chrome).append(n)
        else:
            bad_other.append("%s(%s)" % (n, b))
    if bad_chrome:
        say("NG", "这些 Chrome 进程的 QUIC 没被拦截（会绕过规则直连，claude.ai 报地区不可用或显示日本）: %s"
            " —— 用模板③的 PROCESS-NAME-REGEX 那条，见排障手册第 2 条" % bad_chrome)
    if late_chrome:
        say("NG", "这些 Chrome 进程的 QUIC 拦截排在 Claude 分流规则后面（必须在最前）: %s" % late_chrome)
    if not bad_chrome and not late_chrome:
        running = sorted(n for n, (p, b) in browsers.items() if b == "Chrome" and p)
        say("OK", "Chrome QUIC 拦截覆盖所有已知/在跑的 Chrome 进程%s"
            % ("（在跑: %s）" % ", ".join(running) if running else ""))
    if bad_other and not dest_ok:
        say("WARN", "这些在跑的浏览器没有 QUIC 拦截，用它们开 claude.ai 会漏: %s —— 照模板③注释里的对照表补一条" % bad_other)

    # ② 不能有全局 UDP/443 拦截（误伤全机 HTTP/3）：只有协议/端口条件、没有限定程序或目的地的才算全局
    glb = [r for r in rules if r[0] == "AND" and r[2].upper() == "REJECT"
           and any(c[0] == "NETWORK" and c[1].lower() == "udp" for c in r[1])
           and all(c[0] in ("NETWORK", "DST-PORT") for c in r[1])]
    if glb:
        say("NG", "存在全局 UDP/443 REJECT（误伤全机 HTTP/3，应删除）")
    else:
        say("OK", "无全局 UDP/443 拦截")

    # ③ 关键域名规则
    def has_domain(host):
        return any(r[0] in ("DOMAIN-SUFFIX", "DOMAIN") and r[1][0][1] == host and r[2] == "Claude" for r in rules)
    if has_domain("claude.com"):
        say("OK", "claude.com 域名规则存在")
    else:
        say("NG", "缺 DOMAIN-SUFFIX,claude.com,Claude 规则")
    if has_domain(TELEMETRY_HOST):
        say("OK", "遥测域名规则存在")
    else:
        say("NG", "缺遥测域名规则（DOMAIN-SUFFIX,%s,Claude）——进程规则抓不到它，见排障手册第 9 条" % TELEMETRY_HOST)

    # ④ 真实在跑的 Claude 进程：必须被进程规则导进 Claude 组，且 UDP 被拒
    claude = [(n, p) for n, p in procs if is_claude_proc(n, p)]
    if not claude:
        say("WARN", "当前没有 Claude 进程在跑，跳过进程规则核对（开着 Claude 桌面版 / Claude Code 再跑一次更准）")
    else:
        unrouted = [n for n, p in claude
                    if first_index(rules, lambda r: routes_to_claude(r, n, p)) is None]
        noquic = [n for n, p in claude if quic_status(n, p) != "ok"]
        if unrouted:
            say("NG", "这些在跑的 Claude 进程没有进程规则（非 Anthropic 域名的请求会漏到默认节点）: %s"
                " —— Claude Code 原生安装版进程名是版本号，要用模板③的 PROCESS-PATH-REGEX" % unrouted)
        if noquic:
            say("NG", "这些在跑的 Claude 进程的 UDP 没被拒绝（排在导流规则前）: %s" % noquic)
        if not unrouted and not noquic:
            say("OK", "在跑的 Claude 进程都有规则（%s）" % ", ".join(sorted({n for n, p in claude})))
    return ng


# ── 子命令：conns ────────────────────────────────────────────────────

def is_claude_host(host):
    h = (host or "").lower().rstrip(".")
    try:   # 只有 IP、没有域名的连接（浏览器自己解析了 DNS 时会这样）按 Anthropic IP 段认
        in_cidr = ipaddress.ip_address(h) in ipaddress.ip_network(ANTHROPIC_CIDR)
    except ValueError:
        in_cidr = False
    return (any(h == d or h.endswith("." + d) for d in CLAUDE_DOMAINS)
            or "anthropic" in h or h == TELEMETRY_HOST or in_cidr)


def check_conns(data):
    conns = data.get("connections") or []
    leaks, seen, relevant = [], set(), 0
    for c in conns:
        m = c.get("metadata", {})
        host = m.get("host") or m.get("sniffHost") or m.get("destinationIP") or "?"
        name, path = m.get("process") or "", m.get("processPath") or ""
        net, port = (m.get("network") or "").lower(), str(m.get("destinationPort") or "")
        chains = c.get("chains") or []
        why = None
        if net == "udp" and port == "443" and browser_of(name) == "Chrome":
            why = "Chrome 的 QUIC 没被拦截"
        elif net == "udp" and is_claude_host(host):
            why = "发往 Claude 的 UDP 没被拒绝"
        elif net == "udp" and is_claude_proc(name, path):
            why = "Claude 进程的 UDP 没被拒绝"
        elif is_claude_host(host) or is_claude_proc(name, path):
            relevant += 1
            if "Claude" not in chains:
                why = "Claude 流量没走 Claude 组"
        if why:
            key = (why, host, name, tuple(chains))
            if key not in seen:
                seen.add(key)
                leaks.append("%s：%s %s:%s ← %s，规则=%s，走了 %s" % (
                    why, net, host, port, name or "进程未知",
                    c.get("rule") or "（空：规则全被跳过，直连了）", " < ".join(chains) or "?"))
    for l in leaks[:8]:
        print("NG", l)
    if len(leaks) > 8:
        print("NG", "……另有 %d 条" % (len(leaks) - 8))
    if not leaks:
        print("OK", "实时连接里没有漏流（检查了 %d 条 Claude 相关连接）" % relevant)
    if relevant == 0:
        print("NOTE", "此刻没有 Claude 相关连接可查——开着 claude.ai 网页 / Claude 桌面版再跑一次更准")
    return len(leaks)


def main(argv):
    if len(argv) < 2 or argv[0] not in ("rules", "conns"):
        print(__doc__)
        return 2
    if argv[0] == "rules":
        ps_file = argv[argv.index("--ps") + 1] if "--ps" in argv else None
        return 1 if check_rules(load_rules(argv[1]), running_procs(ps_file)) else 0
    data = json.load(sys.stdin) if argv[1] == "-" else json.load(open(argv[1], encoding="utf-8"))
    return 1 if check_conns(data) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
