# CLAUDE.md — Claude 专线配置执行手册（写给 agent）

你是新机器上的 Claude Code。本手册指导你把「只有 Claude 流量走 美国静态住宅 IP」的 Clash Verge Rev 配置部署到本机。**严格按阶段顺序执行（Phase -1 → Phase 6），每个阶段的 STOP 条件命中就停下来问用户，不要硬闯。**

打扰用户的原则：能自动的自动、能代劳的代劳。整个流程只在三种事上开口——要秘密（四元组、订阅链接）、要 GUI 操作（激活）、STOP 条件命中。其余一律"做完告知"，不要"做前请示"。

通用约定：

- Clash Verge Rev 配置目录：`$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev`（下文记作 `$CFG`）
- Mihomo 控制 API 走 unix socket：`curl --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/<endpoint>`（若 socket 不存在，读 `$CFG/clash-verge.yaml` 里的 `external-controller` 换 TCP 方式）
- 内核日志：`$CFG/logs/service/service_latest.log`
- 所有写文件操作前先备份为 `<原名>.bak-<月日时分>`
- 用户的凭证（静态IP四元组）只写进 `$CFG/profiles/` 下的本地文件，**绝不写进本仓库目录、绝不出现在 git 里**

---

## Phase -1：代理软件归一（只在必要时进入）

先探测本机代理软件：`ls /Applications | grep -iE 'clash|surge|shadowrocket|quantumult|sing-box|mihomo|flclash|v2ray|stash|loon'`，加上 `scutil --nc list` 看在跑的 VPN。

- **已装 Clash Verge Rev 且能正常上网** → 本阶段跳过，直接进 Phase 0。
- **用的是别的代理软件**（Surge / ClashX / Mihomo Party / sing-box 系等）：向用户说明本方案只在 Clash Verge Rev 上验证过，走迁移——机场订阅链接是通用的，导入 Verge 即可；原软件必须退出、建议卸载（两个代理抢路由是红线第 1 条）。用户执意不换软件 → 指给他 `docs/porting.md`（未验证的移植规格），本流程到此结束。
- **什么代理软件都没装**：照常走下面的安装。

安装与迁移：

1. 装 Verge：`brew install --cask clash-verge-rev`；没有 Homebrew 就把官方下载页给用户手动装：https://github.com/clash-verge-rev/clash-verge-rev/releases
2. 问用户要**机场订阅链接**（机场官网 / 订单邮件里有），让用户打开 Verge →「订阅」页 → 粘贴链接 → 导入。然后读 `$CFG/profiles.yaml` 确认出现了 `type: remote` 条目。
3. 让用户在 Verge 设置里开 **TUN 模式**、保持**规则模式**；同时退出旧代理软件。
4. 验证基础网络通：`curl -sS --max-time 15 https://api.ipify.org` 有返回才进 Phase 0。

STOP 条件：用户不肯退出旧代理软件；用户拿不到订阅链接。

## Phase 0：环境体检（只读，不改任何东西）

依次检查，汇总成一份体检报告给用户看，全部通过才进 Phase 1：

1. **Clash 在跑**：`pgrep -fl verge-mihomo` 有进程，且 `curl --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/version` 返回版本 JSON
2. **TUN + 规则模式**：`$CFG/clash-verge.yaml` 里 `tun:` 段 `enable: true`；`mode: rule`
3. **订阅已导入且含美国节点**：API `GET /proxies`，在节点名里搜（不区分大小写）「美国 | US | USA | America | United States | 🇺🇸 | Los Angeles | LA | San Jose | Seattle | Dallas | Phoenix | Ashburn | LAX | SJC」，把找到的美国节点名列出来（Phase 1 要用）。注意 `US` 会误匹配 `AUS`（澳洲）/`RUS`（俄罗斯），人工过一遍剔除。**一个都没搜到时不要直接 STOP**：先把订阅的完整节点名列表贴给用户人工指认（机场命名千奇百怪），用户确认确实没有美国节点才停
4. **排查其他 VPN（红线）**：`scutil --nc list`，除 Tailscale 外任何处于 `(Connected)` 的 VPN（尤其 Shadowrocket）都必须先让用户断开并建议卸载。**STOP：用户不处理就不继续**——这是实测导致整机断网的雷。
5. **当前出口基线**：`curl -sS --max-time 15 https://api.ipify.org?format=json` 记下当前机场出口 IP，后面对比用

STOP 条件：Clash 没装/没跑 → 回 Phase -1 处理；订阅里没有美国节点 → 让用户换含美国节点的套餐。

## Phase 1：收集输入（问用户）

1. **静态IP SOCKS5 四元组**：host、port、username、password。拿到后先做一次**预期失败测试**并向用户解释：从国内直连静态 IP 通常超时或被拒（`curl --max-time 15 --socks5-hostname 'user:pass@host:port' https://api.ipify.org` 失败**是正常的**，静态IP 常只接受美国来源，这正是要链式代理的原因）。如果直连反而成功且返回静态 IP，也记录下来。
2. **美国节点不用问**：默认把 Phase 0 找到的全部美国节点放进 US-Chain（延迟低的排前面），告知一句「US-Chain 里放了这 N 个美国节点」即可继续，不要等确认；用户主动提了要求才按要求调整。

## Phase 2：定位增强文件

读 `$CFG/profiles.yaml`：

1. 顶部 `current:` 是激活订阅的 uid
2. 找到该订阅条目的 `option:` 段，记下 `proxies` / `groups` / `rules` / `merge` 四个 uid，对应文件在 `$CFG/profiles/<uid>.yaml`

**如果 option 里缺某个 uid（增强文件还没创建过）**：先尝试自动创建——模仿 GUI 的行为，格式已对照真机 Verge 2.x 的 `profiles.yaml` 核实（2026-07）：

1. 备份账本：`cp "$CFG/profiles.yaml" "$CFG/profiles.yaml.bak-$(date +%m%d%H%M)"`
2. 生成 uid：**类型首字母 + 11 位随机字母数字**（proxies→`p`、groups→`g`、rules→`r`、merge→`m`，如 `p7QFkwh6ExbW`）：
   `python3 -c 'import random,string;print("p"+"".join(random.choices(string.ascii_letters+string.digits,k=11)))'`
3. 直接创建 `$CFG/profiles/<uid>.yaml` 并写入模板内容（不必先建空文件再写）
4. 登记两处：`items:` 列表里**照抄本机已有条目的格式**追加一条 `{uid, type: <类型>, name: null, file: <uid>.yaml, updated: <date +%s>}`；当前订阅条目的 `option:` 段里加 `<类型>: <uid>`
5. **激活后必须验证挂载生效**（Phase 4 之后检查生成的 `clash-verge.yaml` 里出现了我们的静态节点和 Claude 规则）。没生效 → 用备份还原 `profiles.yaml`、删掉自建的 uid 文件，退回 GUI 方式：让用户在「订阅」页右键当前订阅 → 分别点「编辑节点 / 编辑分组 / 编辑规则 / 编辑 Merge」→ 什么都不改直接保存退出（让 GUI 自己生成空文件）→ 重新读 `profiles.yaml` 拿 uid。

## Phase 3：写入配置（模板填空）

按 `templates/` 下四个模板，把内容写进对应 uid 文件（先备份原文件；若原文件已有用户自己的增强内容，合并而不是覆盖，冲突处问用户）：

1. `templates/1-proxies.yaml` → proxies 文件：填 静态IP四元组。**type 必须是 socks5、udp: false、dialer-proxy: "US-Chain" 一个都不能少**
2. `templates/2-groups.yaml` → groups 文件：US-Chain 里填 Phase 1 确认的真实美国节点名（**必须和订阅里的名字逐字一致，含 emoji 和空格**）
3. `templates/3-rules.yaml` → rules 文件：整体照抄，**规则顺序不能动**（QUIC 拦截必须在最前）；同时覆盖桌面版的 `Claude` / `Claude Helper` 与 Claude Code 的 `claude.exe`
4. `templates/4-merge.yaml` → merge 文件：sniffer 段照抄（若用户 merge 文件里已有其他顶层配置，保留并追加 sniffer 段）

## Phase 4：激活

**首选（最稳）**：让用户在 Clash Verge GUI 左侧「订阅」页**点一下当前订阅卡片**（触发重新合并 + 内核加载）。

备选（用户不在 GUI 旁）：`curl -X PUT --unix-socket /tmp/verge/verge-mihomo.sock "http://localhost/configs?force=true" -H "Content-Type: application/json" -d "{\"path\":\"$CFG/clash-verge.yaml\"}"`——注意热重载**不会**重新合并增强文件，只适用于你直接改过生成文件的场景；正常流程用 GUI 激活。

激活后**必查**（真机部署时踩过的坑）：

```bash
tail -20 "$CFG/logs/service/service_latest.log" | grep -i "Start TUN listening error"
```

出现 `add route: ... file exists` → 有别的 VPN 占着路由，转 `docs/troubleshooting.md` 第 1 条处理，**不要重复重启内核硬试**。

## Phase 5：验证

```bash
bash scripts/verify.sh
```

六项全绿才算部署完成。任何一项红 → 按脚本输出的提示对照 `docs/troubleshooting.md`，修完重跑。**禁止在验证不过的情况下宣布完成。**

## Phase 6：客户端收尾

1. **重启客户端由你代劳**（QUIC 会话和连接池有缓存，必须完全退出，关窗口没用）：先 `pgrep` 确认哪些在跑，告知用户一句「要重启 Chrome / Claude 桌面版了，网页里没保存的内容会丢」，然后对在跑的执行：
   ```bash
   osascript -e 'quit app "Google Chrome"'; osascript -e 'quit app "Claude"'
   sleep 3
   open -a "Google Chrome"; open -a "Claude"
   ```
   没在跑的应用不要动。
2. 交代用户：打开 claude.ai → 设置 → 帐户 → **活跃会话**：把归属地不是静态 IP 所在地的旧会话全部撤销，重新登录（这步在网页账户里，你代劳不了）
3. 刷新后检查：当前会话的归属地应该显示静态 IP 的地区（美国住宅 IP 常显示为弗吉尼亚州阿什本等）
4. 向用户复述三条红线：不装第二个 VPN、不切全局模式、以后订阅自动更新后增强文件仍然生效但如遇异常先跑 verify.sh

## 回滚（任一阶段失败且当场修不好时）

Phase 3 起所有被改过的文件都有同目录备份 `<原名>.bak-<月日时分>`，恢复到部署前只要两步：

1. 把备份复制回原文件名（同一文件有多份备份时，取**时间最早**的那份 = 部署前原状）：

```bash
ls -lt "$CFG/profiles/"*.bak-*
cp "$CFG/profiles/<uid>.yaml.bak-<最早时间>" "$CFG/profiles/<uid>.yaml"
```

2. 让用户在 GUI「订阅」页点一下当前订阅卡片重新激活，然后确认两件事：内核正常（`curl --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/version` 有返回）、正常上网没坏（随便 curl 一个网站）。

回滚完成后，如实告诉用户卡在哪个阶段、日志里的相关报错行，由用户决定重试还是先排障，**不要回滚完立刻自动重试**。

## 完成标准

- `scripts/verify.sh` 六项全绿
- 用户在 claude.ai 会话列表看到当前会话归属地 = 静态 IP 地区
- 用户知道三条红线

把最终状态（静态 IP、走了哪个美国节点、验证结果）汇总成几句话报告给用户，收工。
