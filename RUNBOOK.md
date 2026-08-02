# claude-lane 部署执行手册

你是本机环境配置执行 Agent。本手册指导你在 macOS 上部署「只有 Claude 流量走美国静态住宅 IP」的 Clash Verge Rev 配置。**严格按 Phase -1 → Phase 6 的顺序执行；命中 STOP 条件就停止，不得硬闯。**

`RUNBOOK.md` 是唯一权威执行手册。`CLAUDE.md`、`AGENTS.md` 和 `QWEN.md` 只是不同 Agent 的入口，冲突时以本文件为准。

打扰用户只限三类情况：需要用户在本地隐藏输入秘密、需要 GUI 或 macOS 授权、命中 STOP 条件。其余步骤在授权范围内完成后告知。

## 安全与隐私边界

- Phase 6 完成前，bootstrap 启动的 Claude Code 只能把模型请求发给 DeepSeek。不得登录 Anthropic，不得改写 DeepSeek 临时环境，也不得把临时配置持久化到 Shell 启动文件或用户级 Claude Code 配置。Phase 5 中 `verify.sh` 对 Claude 站点做匿名出口探测不等于模型登录。
- **不得索要、接收、读取或回显机场订阅链接。** 用户只能在 Clash Verge GUI 的「订阅」页直接粘贴。检查 `profiles.yaml` 时只输出必要字段，并先遮盖 `url:` 等订阅字段；禁止把文件全文送进 Agent 上下文。
- **不得索要、接收、读取或回显静态住宅 IP 四元组。** host、port、username、password 只能由用户运行 `scripts/set-credentials.sh` 在本地隐藏输入。Agent 只接收脚本明确标为可分享的打码状态，不读取 proxies 文件中的凭证块。
- **不得索要、读取或回显 DeepSeek API Key。** 不运行可能泄露它的 `env`、`printenv`、`set -x`、`ps e` 等命令，不把它写进命令参数、URL、日志、仓库或配置文件。
- 不上传 Clash 配置、日志、订阅、IP 或任何 Key 到 Issue、聊天、外部服务或 Git。需要展示诊断信息时先打码。
- 不使用 `--dangerously-skip-permissions`。只能执行仓库内已校验并处于启动器权限白名单中的脚本；管理员权限、网络扩展和 GUI 操作交给用户确认。

## 通用约定

- Clash Verge Rev 配置目录：`$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev`（下文记作 `$CFG`）。
- Mihomo 控制 API：`curl --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/<endpoint>`。若 socket 不存在，只读取 `$CFG/clash-verge.yaml` 的 `external-controller` 值并改走 TCP。
- 内核日志：`$CFG/logs/service/service_latest.log`。
- bootstrap 必须在启动 Agent 前生成并传入一次 deployment id；人工恢复流程则在进入 Phase 1 前生成：

  ```bash
  export CLAUDE_LANE_DEPLOY_ID=$(date +%Y%m%d-%H%M%S)
  ```

  后续每次调用 `scripts/backup.sh` 都必须沿用它。把 id 告诉用户；出事时用 `bash scripts/rollback.sh <id>` 精确回滚。用户运行 `set-credentials.sh` 时也必须在同一条命令中传入该 id。
- 备份清单必须覆盖 `$CFG/profiles.yaml` 和四个增强文件；不存在的目标也要传给 `backup.sh`，让它记为 `created`，回滚时删除。
- 检查配置只用定向查询，避免输出整份 `profiles.yaml`、`clash-verge.yaml` 或 proxies 增强文件。

---

## Phase -1：代理软件归一

bootstrap 正常路径负责确定性下载、校验并安装固定版 Claude Code、仓库包和 Clash Verge Rev。Agent 不临时搜索下载站，也不自行改用 GitHub、Homebrew、npm 或未知镜像。

先探测本机代理软件与 VPN：

```bash
ls /Applications | grep -iE 'clash|surge|shadowrocket|quantumult|sing-box|mihomo|flclash|v2ray|stash|loon'
scutil --nc list
```

- 已装 Clash Verge Rev 且能正常上网：跳到 Phase 0。
- 使用其他代理软件：说明本方案只在 Clash Verge Rev 上验证过。要求退出旧软件并迁移；两个代理同时抢路由是红线。用户执意保留原软件时，指向 `docs/porting.md`，本流程结束。
- Clash Verge 未安装：正常 bootstrap 应在启动 Agent 前完成安装。若是绕过 bootstrap 的人工恢复会话，停止并让用户回到经过校验的启动器或官方手动安装流程；不得临场找第三方下载源。

迁移或首次导入订阅时：

1. 让用户在 Clash Verge GUI 打开「订阅」页，**直接在 GUI 粘贴链接**并导入；不要让用户把链接发给 Agent。
2. 用 `bash scripts/profile-config.sh summary` 确认当前项是 `remote`；不要直接输出 `profiles.yaml`。
3. 让用户打开 TUN 模式、保持规则模式，并退出旧代理软件。
4. `curl -sS --max-time 15 https://api.ipify.org | /usr/bin/osascript -l JavaScript scripts/macos-json.js mask-value >/dev/null` 成功后才进入 Phase 0。

STOP：用户不退出旧代理软件；用户无法在 GUI 导入订阅；bootstrap 安装或签名校验失败。

## Phase 0：环境体检（只读）

依次检查并汇总一份不含秘密的体检报告，全部通过才进入 Phase 1：

1. **Clash 在运行**：`pgrep -fl verge-mihomo` 有进程，且版本 API 返回 JSON。
2. **TUN + 规则模式**：定向检查 `$CFG/clash-verge.yaml` 中 `tun.enable: true` 和 `mode: rule`，不要输出整份配置。
3. **订阅含美国节点**：调用 `GET /proxies`，按不区分大小写的「美国、US、USA、America、United States、🇺🇸、Los Angeles、LA、San Jose、Seattle、Dallas、Phoenix、Ashburn、LAX、SJC」找候选节点。人工剔除 `AUS`、`RUS` 等误匹配。一个都没找到时，列出**节点名而不是订阅信息**供用户指认；用户确认确实没有美国节点才停止。
4. **其他 VPN**：`scutil --nc list`。除 Tailscale 外，任何 `(Connected)` 的 VPN 都必须先断开并建议卸载。用户不处理则 STOP。
5. **当前出口基线**：把 `curl -sS --max-time 15 https://api.ipify.org` 的结果直接管道交给 `scripts/macos-json.js mask-value`；只输出打码结果，不让完整 IP 进入 Agent 上下文。
6. **平台与运行依赖**：`uname -s` 必须是 `Darwin`；Windows/Linux 指向 `docs/porting.md` 后停止。`curl` 必须存在。仓库脚本和 bootstrap 不得假设目标机有 Git、Homebrew、Node.js、Python 3 或 `jq`。

STOP：Clash 没装或没运行；订阅确认没有美国节点；平台不是 macOS；必需的系统组件缺失且启动器无法恢复。

## Phase 1：本地输入凭证

1. 先运行 `bash scripts/profile-config.sh summary`。proxies uid 已存在时，凭证必须由用户自己写入；告诉用户在一个本地终端、仓库目录中运行：

   ```bash
   export CLAUDE_LANE_DEPLOY_ID=<本次部署id> && bash scripts/set-credentials.sh
   ```

   脚本隐藏输入并直接写入本机 Clash 配置。明确提醒：**不要把四元组贴进对话。** Agent 只接收脚本给出的安全、打码状态。

   - proxies uid 缺失时，本阶段只记录“凭证待输入”，不运行凭证脚本；按顺序完成 Phase 2 创建后，在 Phase 3 写其他配置之前执行上面的命令一次。
   - 返回 `MODE=conflict`：保留用户自有内容，按模板的 managed 标记块合并骨架；仍不得询问或查看凭证。必要时让用户在本地手工填入骨架。
   - 从国内直连静态 IP 超时或被拒通常正常，因为它一般只接受美国来源；不用额外直连测试。
2. **美国节点不用询问选择**：默认把 Phase 0 找到的全部真实美国节点放进 US-Chain，低延迟优先。只告知节点数量；用户主动提出偏好时再调整。

## Phase 2：定位或创建增强文件

只通过 `bash scripts/profile-config.sh summary` 取得：

1. 顶部 `current:` 对应的激活订阅 uid。
2. 当前订阅 `option:` 下 `proxies`、`groups`、`rules`、`merge` 四个 uid；文件路径为 `$CFG/profiles/<uid>.yaml`。

如果缺 uid，先模仿 Clash Verge Rev 2.x 的格式自动创建：

1. 对每个缺失类型执行 `CLAUDE_LANE_DEPLOY_ID="$CLAUDE_LANE_DEPLOY_ID" bash scripts/profile-config.sh register <类型>`；脚本生成合规 uid、用同一个 deployment id 备份、创建 skeleton 并登记 `profiles.yaml`。
2. 每次登记后重跑 summary；只接受脚本返回的 uid 和目标路径，不打开原始 `profiles.yaml`。
3. Phase 4 激活后，必须确认生成的 `clash-verge.yaml` 含本项目静态节点和 Claude 规则。没挂载成功时，用本次 deployment id 回滚，不手工找 `.bak`；再让用户在 GUI 右键当前订阅，依次打开「编辑节点 / 编辑分组 / 编辑规则 / 编辑 Merge」并原样保存，由 GUI 生成文件，然后重新定位 uid。

## Phase 3：写入配置

再次用同一个 deployment id 调用备份；脚本会跳过本次部署中已经记录过的目标：

```bash
CLAUDE_LANE_DEPLOY_ID="$CLAUDE_LANE_DEPLOY_ID" bash scripts/backup.sh "$CFG/profiles.yaml" \
  "$CFG/profiles/<proxies uid>.yaml" "$CFG/profiles/<groups uid>.yaml" \
  "$CFG/profiles/<rules uid>.yaml" "$CFG/profiles/<merge uid>.yaml"
```

按 `templates/` 写入。若文件已有用户增强内容，合并而不是覆盖；项目维护内容尽量放在 `# claude-lane managed start/end` 之间，冲突时停止并说明。

若 Phase 1 因缺 proxies uid 暂缓了凭证输入，现在先让用户用同一个 deployment id 运行 `scripts/set-credentials.sh`，再继续下面四项。

1. `templates/1-proxies.yaml` → proxies：由用户运行 `scripts/set-credentials.sh` 写入。Agent 不打开凭证块，只用不会输出值的定向检查确认 `US-Static`、`type: socks5`、`udp: false`、`dialer-proxy: "US-Chain"` 四项都存在。
2. `templates/2-groups.yaml` → groups：US-Chain 中的节点名必须与订阅逐字一致，包括 emoji 和空格。
3. `templates/3-rules.yaml` → rules：整体照抄，顺序不能动；QUIC 拦截在最前，并覆盖 `Claude`、`Claude Helper`、`claude` 和 `claude.exe` 等桌面版 / Claude Code 进程。
4. `templates/4-merge.yaml` → merge：保留用户已有顶层配置，再追加模板中的 sniffer 段。

默认不启用 `templates/optional-payment-rules.yaml`。它会让任意网站的 Stripe / Google Pay 流量走静态 IP；只有用户主动要求时才说明副作用并添加。

## Phase 4：激活

首选让用户在 Clash Verge GUI 左侧「订阅」页点一下当前订阅卡片，触发重新合并和内核加载。

只有直接改过生成文件、且用户不在 GUI 旁时，才考虑：

```bash
curl -X PUT --unix-socket /tmp/verge/verge-mihomo.sock \
  "http://localhost/configs?force=true" \
  -H "Content-Type: application/json" \
  -d "{\"path\":\"$CFG/clash-verge.yaml\"}"
```

热重载不会重新合并增强文件，不能代替正常激活。

激活后检查：

```bash
tail -20 "$CFG/logs/service/service_latest.log" | grep -i "Start TUN listening error"
```

出现 `add route: ... file exists` 说明其他 VPN 占用路由。按 `docs/troubleshooting.md` 第 1 条处理，不要反复重启内核。

## Phase 5：六项验证

```bash
bash scripts/verify.sh --save-baseline
```

六项全绿才算配置完成。任一项失败，就按脚本提示和 `docs/troubleshooting.md` 修复后重跑；禁止在验证失败时宣布完成，也不要把包含未打码 IP 或配置的原始输出贴进对话。

`--save-baseline` 只在全绿时把实测出口写入 `$CFG/claude-lane-state.json`。日常运行 `bash scripts/verify.sh` 会与该基线比较，从而发现出口变化。

## Phase 6：退出临时执行模式并收尾

**只有 Phase 5 六项全绿后才能进入。**

1. 重启运行中的 Chrome / Claude 桌面版前，先告知用户未保存网页内容会丢失。先记录哪些应用在运行，只退出和重新打开这些应用：

   ```bash
   osascript -e 'quit app "Google Chrome"'
   osascript -e 'quit app "Claude"'
   sleep 3
   open -a "Google Chrome"
   open -a "Claude"
   ```

2. 只读检查 `defaults read -g AppleLocale`。地区不是 `US` 时建议在「系统设置 → 通用 → 语言与地区」改为美国；界面语言不用改，时区不强制改，详见 `docs/account-safety.md`。
3. 复述三条红线：不运行第二个 VPN；Clash 保持规则模式；订阅更新后增强文件通常仍生效，异常先跑 `scripts/verify.sh`。
4. 若当前会话由 bootstrap 启动（存在 `CLAUDE_LANE_COMPLETION_FILE`），完成前述收尾后最后执行 `/bin/bash scripts/bootstrap-complete.sh` 写入本次 deployment id 的非秘密完成标记，然后结束当前 DeepSeek 模式的 Claude Code 子进程；人工恢复流程不创建该标记。该标记不能代替 Phase 5，启动器还会独立重跑六项验证。子进程不能清除父进程环境；由启动器的 `trap` 清除 `ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_MODEL`、三个 `ANTHROPIC_DEFAULT_*_MODEL`、`CLAUDE_CODE_SUBAGENT_MODEL`、`CLAUDE_CODE_EFFORT_LEVEL`、`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`、`CLAUDE_CODE_SKIP_PROMPT_HISTORY`、`DISABLE_LOGIN_COMMAND`、`DISABLE_AUTOUPDATER`、`CLAUDE_CONFIG_DIR`、临时 Key，以及本次临时配置、会话和日志。不得声称清理完成，直到启动器实际验证这些状态已消失。
5. 启动器保留经过校验的 Claude Code 程序，但普通 `claude` 不得继续指向 DeepSeek。用不带临时变量的新进程确认进入正常 Claude 登录流程；**用户到这时才登录 Anthropic。**
6. 用户在 claude.ai → 设置 → 帐户 → 活跃会话中撤销归属地不符的旧会话并重新登录。刷新后确认当前会话归属地与静态出口地区一致。

## 回滚

任一阶段失败且当场无法修复时，用本次 deployment id 回滚：

```bash
bash scripts/rollback.sh --list
bash scripts/rollback.sh <deployment id>
```

不传 id 会回滚最近一次部署，但已知 id 时必须显式传入。脚本会先列出将还原和删除的文件，并在回滚前保存当前状态。不要用「复制最早的 `.bak`」替代。

回滚后让用户在 GUI 重新点一次订阅卡片，然后确认 Mihomo API 可达且普通网络正常。说明失败阶段和经过打码的相关日志，由用户决定重试或排障；不要自动重试。

## 脚本测试

改动 `scripts/` 后先运行：

```bash
bash scripts/selftest.sh
```

改动 bootstrap 后还要运行：

```bash
bash scripts/bootstrap-selftest.sh
```

测试必须使用临时目录，不触碰真实 Clash 配置。

## 完成标准

- `scripts/verify.sh --save-baseline` 六项全绿。
- bootstrap 已实际清除 DeepSeek 临时凭证、环境、配置、会话和日志；普通 `claude` 不再指向 DeepSeek。
- 用户完成正常 Claude 登录，并在活跃会话中看到当前归属地与静态出口地区一致。
- 用户知道三条红线。

最终只汇总打码后的静态出口、实际使用的美国节点、六项验证、DeepSeek 清理和登录状态；不得包含订阅链接、四元组或 Key。
