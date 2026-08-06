# 更新日志

版本号只用来让你知道"自己手里这份是哪一版"。**每次这里出现新版本，都建议在你的每台机器上重跑一遍部署**——增强文件是写在本机的，仓库更新不会自动同步过去（见排障手册第 10 条）。

查自己是哪一版：看 README 顶部的版本号，或 `git log -1`。

---

## v1.3.0 — 2026-08-01

**启动链路（框架已落地，分发尚未发布）**

- 新增可暂停、可恢复的安装状态机和订阅检查点：Clash Verge 安装后若没有远程订阅，保存 `WAITING_FOR_SUBSCRIPTION` 并正常结束；重新运行后校验现有组件并续跑，订阅通过前不读取 DeepSeek Key、不启动 Agent
- 安装顺序调整为“国内源安装 Clash → 等待订阅 → 代理可用后从 Anthropic 官方源安装固定版 Claude Code”；不公开镜像 Claude Code，也不再生成 239MB Windows 搬运包
- macOS 与 Windows 状态文件只保存固定枚举和原因码；订阅 URL 仍只允许在 Clash Verge GUI 本地输入，不进入状态、日志或模型上下文
- 新增 Windows 10 1809+ 的 `bootstrap.ps1`，覆盖 x64 / ARM64 原生 Claude Code 与 Clash Verge Rev 正式安装器；强制固定版本、主备国内源、SHA-256、Authenticode、版本检查和不覆盖现有安装
- Windows 增加 `WAITING_FOR_ENHANCEMENT_FILES`、`WAITING_FOR_ISP`、`WAITING_FOR_ACTIVATION` 固定暂停点，以及本地隐藏输入 ISP、四类增强配置原子写入、当前用户 ACL 备份、按 deployment id 回滚和六项验证；双架构真机证据齐全前保持候选状态
- 镜像矩阵固定为 Claude Code `2.1.220` 与 Clash Verge Rev `2.5.2`；新增 Windows 双架构摘要、Tauri `.sig`、GPL 许可证和官方源码元数据。Windows 真机 Authenticode 仍是 stable 阻断项
- 新增 `scripts/mirror/` 发布工具：默认 dry-run 的官方抓取、GPG / codesign / Gatekeeper / minisign 验证、候选清单生成、OSS 不覆盖上传和显式 stable 晋级
- 新增 `scripts/bootstrap-windows-selftest.ps1` 与 `scripts/mirror/selftest.sh`；macOS 启动器也会验证 Windows 双架构字段和签名证据，防止发布不完整矩阵
- 新增双架构 Windows 真机验证包、统一 PowerShell 入口和非秘密审计 JSON；修正 ARM64 Windows 上 x64 兼容 PowerShell 的架构识别
- 新增验证包内的 Windows 离线 RC 试装入口：固定制品验签后安装 Claude Code 与 claude-lane，并启动 Clash Verge Rev 安装器；不下载、不登录、不修改路由
- Windows 离线 RC 现在会安装可复用的 DeepSeek 临时启动器：SecureString 隐藏输入 Key、子进程环境注入、固定模型文本握手、隔离配置与 MCP、禁用 Bash 工具，并在退出或失败时清理临时状态
- 新增 Bash 3.2 兼容的 `bootstrap.sh`、`manifests/stable.json` 和 `scripts/bootstrap-selftest.sh`：manifest 固定版本、相对路径与 SHA-256，启动器发布块固化国内主备源和 manifest 自身摘要；目标机不依赖 Git、Homebrew、Node.js、Python 3 或 `jq`
- 所有下载字段执行失败关闭：示例域名、`TBD`、空值、非 64 位 SHA-256、下载失败或校验失败都会在修改系统前停止，不会降级到未知版本或第三方镜像
- DeepSeek 安装 Key 从终端隐藏读取，只传给临时 Claude Code 子进程；模型固定为 `deepseek-v4-flash`、推理强度 `max`，并由 `trap` 负责退出清理
- 阿里云 OSS 主源已完成 public-read 对象上传与匿名回下载，Clash 四个平台制品已正式同步；备用源按维护者决定暂缓。lane 归档、全部真机证据和无代理干净 Mac 端到端验收仍未完成，因此没有发布 stable 一条命令入口

**执行手册与隐私**

- 新增 Agent 无关的唯一权威手册 `RUNBOOK.md`；`CLAUDE.md` 精简为默认入口，新增 `AGENTS.md` 与 `QWEN.md` 兼容入口
- 机场订阅链接改为只能由用户直接粘贴到 Clash Verge GUI；静态 IP 四元组继续只走本地隐藏输入；Agent 不得主动读取、回显或要求把秘密贴进对话
- Phase 6 增加 DeepSeek 子进程退出、启动器清理临时环境 / 配置 / 会话 / 日志，以及用户最后才进入正常 Claude 登录流程的门禁
- 新增 `docs/bootstrap.md`，记录 manifest、签名、国内对象存储、离线包和发布门禁

**移除 Python 隐藏依赖**

- 新增 `scripts/macos-json.js`，使用 macOS 自带 JXA 处理 JSON、YAML 标量转义、profiles 定位和状态基线
- `set-credentials.sh` 与 `verify.sh` 不再依赖 Python 3；静态四元组通过 stdin 传给辅助程序，不进入命令参数或环境变量
- `selftest.sh` 当前 82/82 通过；`bootstrap-selftest.sh` 当前覆盖 51 项，`mirror/selftest.sh` 覆盖 24 项，包括严格 profiles 解析、订阅检查点、非秘密状态持久化、发布门禁、Bash 3.2、Key argv 隔离、Claude codesign 身份、settings/MCP 隔离、权限确认、子进程环境剥离、归档逃逸、原子安装、包内容门禁、干净正常登录、Phase 6 双重完成判据和 Windows 验证包默认失败关闭

## v1.2.1 — 2026-07-26

**修复 `rollback.sh` 的回滚快照（撤销回滚在 v1.2.0 是坏的）**

- **快照记录的是「回滚前的当前状态」，不再照抄原清单的 kind**：当前文件存在 → 记 `file` 并存副本；当前文件不存在 → 记 `created`。旧逻辑照抄原清单，导致**部署时新建的文件在快照里被记成 `created`**，撤销回滚时不但不恢复、反而又删一次
- **快照目录名改用 `mktemp` 生成唯一后缀**。旧的秒级时间戳在「回滚完立刻撤销回滚」时会和被回滚的目标目录**同名**，于是变成边读 `manifest.tsv` 边往同一个文件追加 → **无限循环卡死**
- 回滚结束时直接打印撤销命令（`bash scripts/rollback.sh <快照id>`）
- 不带 id 时默认回滚**最近一次部署**，不会误选回滚快照；`--list` 把回滚快照单独标注

**测试**
- `selftest.sh` 新增第 7 组：部署前一存在一不存在 → 模拟部署 → 回滚 → **不加任何 sleep 立刻撤销回滚** → 验证被改文件和新建文件都完整恢复 → 再撤销一次验证状态自洽；全部带 20 秒超时守护（macOS 无 `timeout`，脚本内自实现），死循环会被判定失败而不是把测试挂住
- `selftest.sh` 新增第 8 组**静态检查**：扫描所有脚本里 `$VAR` 紧跟非 ASCII 字符的写法（bash 会把标点首字节吃进变量名，`set -u` 下崩溃）。写本次测试时又踩了 6 处，已全部改成 `${VAR}` —— 这类 bug 靠人眼防不住，现在由测试兜底
- 用例数 20 → **31**

## v1.2.0 — 2026-07-26

**版本管理**
- 新增根目录 `VERSION` 作为版本号唯一来源；`verify.sh` 读它写进 `claude-lane-state.json`（此前脚本里写死 `1.1.0`，v1.1.1 发布后就对不上了）
- `verify.sh` 新增 **版本漂移检查**：对比本机部署时记录的模板版本与仓库当前版本，落后就提示重新对齐——把排障手册第 10 条那个"隔两个月忘了哪台刷过"的坑变成自动检测（黄色提示，不计入六项红绿）
- 历史版本补齐 git tag 与 GitHub Release：`v1.0.0` / `v1.0.1` / `v1.1.0` / `v1.1.1` / `v1.2.0`

**新增说明：设备侧地区**
- `docs/account-safety.md` 新增第三节：建议把 macOS **地区设成美国**（界面语言保持中文即可，代价接近零）；**时区不强制改**并说明取舍；提醒别用浏览器时区伪装扩展（会引入更强的指纹信号）
- agent 收尾阶段（Phase 6）自动检查 `AppleLocale` 并提醒；README 增加对应 FAQ

## v1.1.1 — 2026-07-25（修 v1.1.0 的四个真 bug，建议立刻更新）

四个问题都在沙箱里复现过，修完用新增的 `scripts/selftest.sh` 固化成用例（20 项全过）。

- **首次配置凭证会静默退出**：`set-credentials.sh` 在空的 proxies 文件里找不到旧节点名时，`grep` 返回 1，配合 `set -euo pipefail` 直接退出，**全新用户必然踩中**（老用户文件里有旧节点名反而不触发）。已加 `|| true`
- **回滚做到一半崩溃**：`"$SAFETY，"` 这类写法里，bash 会把中文标点的首字节吃进变量名，`set -u` 下报 unbound variable——文件已还原但"接下来要重新激活"的提示没打印。全仓库同类写法共 **5 处**（`rollback.sh` 2、`set-credentials.sh` 2、`verify.sh` 1），已全部改为 `${VAR}`
- **出口基线死锁**：首次没有基线时仍要求"真实出口 == 配置里的服务器地址"，而服务商入口地址常常不等于住宅出口 IP → 报红 → 不写基线 → 永远建不了基线。首次改为只验：出口拿得到、国家是 US、且与普通流量出口不同；普通流量也改为与**真实 Claude 出口**比对（不再与服务器地址比）
- **特殊字符写坏 YAML**：用户名/密码含 `"` 或 `\` 时字符串拼接会生成非法 YAML（实测 `u"ser` / `p"ass\word` 直接写坏配置）。改为一律 `json.dumps()` 转义；写完还会尝试解析校验

**同时改进**
- 一次部署共用 `CLAUDE_LANE_DEPLOY_ID`，凭证写入 / Phase 2 / Phase 3 的改动都进同一个备份点，`rollback.sh <id>` 一次性回滚整次部署
- 备份清单纳入 `profiles.yaml`；**本次新建的文件记为 `created`，回滚时删除**（以前会留下孤儿文件）
- 新增 `scripts/selftest.sh` 烟雾测试；脚本支持 `CLAUDE_LANE_CFG` 覆盖配置路径，测试全程不碰真实配置

## v1.1.0 — 2026-07-25

**安全**
- 新增 `scripts/set-credentials.sh`：静态 IP 的四元组由用户在本地终端隐藏输入、直接写进 Clash 配置，**不再经过 AI 对话**（贴进对话等于发到模型服务端并留在本机会话记录里）。文件权限设为 600；`agent` 只看到打码后的确认信息
- 模板①加入 `# claude-lane managed start/end` 标记，改凭证/升级时只替换标记之间的内容，不碰用户自己加的节点；文件里有用户自有内容且无标记时，脚本拒绝改动并提示走人工合并

**可靠性**
- 新增 `scripts/backup.sh` / `scripts/rollback.sh`：每次部署备份到独立时间戳目录（含清单和 Clash 版本），`rollback.sh` 默认回滚**最近一次**部署。修掉旧文档里"取时间最早的 .bak 回滚"的缺陷——部署过几次之后，最早那份可能是几个月前的状态，会恢复过头。回滚前还会把当前状态另存一份，回滚本身也可后悔
- `verify.sh` 出口校验改为**真实出口基线**：`--save-baseline` 把实测到的出口 IP / 国家写入 `$CFG/claude-lane-state.json`（仅在全绿时写），日常验证与基线比对，能发现"出口悄悄换了"；服务商入口地址不等于最终住宅出口 IP，旧的比对方式可能误判
- `verify.sh` 新增出口国家检查（不是 US 直接报红）

**变更**
- **支付规则默认关闭**：从模板③移出到 `templates/optional-payment-rules.yaml`。副作用是任何网站的 Stripe / Google Pay 付款都会走静态 IP，会稀释"这个 IP 只访问 Anthropic"的画像；且 Claude 订阅**中国大陆发行的卡全部不可用**，多数人加了也没用

## v1.0.1 — 2026-07-25（重要修复，建议每台机器都重新对齐）

**修复：Claude Code 遥测流量漏到默认节点**（实机排查，作者自己的机器就在漏）

- 模板③新增 `DOMAIN-SUFFIX,http-intake.logs.us5.datadoghq.com,Claude`。根因有两层：① macOS 上 mihomo 匹配的进程名是 `ps comm` 看到的小写 `claude`，不是磁盘文件名 `claude.exe`；② **即使补上进程规则也不够**——实测这条连接在 mihomo 的 `/connections` 里 `process` 字段为空（识别不出进程），任何 `PROCESS-NAME` 规则都无从匹配，只能靠域名规则。详见排障手册第 9 条（已重写）
- 模板③进程规则同时覆盖 `claude` 与 `claude.exe`
- `verify.sh` 第 3 项改为核对**当前真实在跑**的 Claude 进程是否都有规则（旧版只查规则存不存在，所以这个漏点一直是绿的）；新增遥测域名规则检查；第 5 项漏流扫描纳入 `datadoghq` / `statsig`

**文档**
- 支付规则补充说明：Claude 订阅**中国大陆发行的卡全部不可用**，需海外信用卡/虚拟卡，因此这组规则对多数人无意义
- 仓库转为公开，措辞相应调整（不再指向"分享人"、不再自称"请勿传播"、不推荐具体服务商）

## v1.0.0 — 2026-07-25

首个可分享版本。

**新增**
- 面向人的完整文档：原理 3 分钟版、`docs/manual-setup.md`（人肉版部署手册）、日常使用、FAQ
- `docs/account-safety.md`：账号安全清单（遥测环境变量的真实语义 + 网页版侧 5 条习惯）
- `docs/porting.md`：非 Clash Verge 客户端的移植规格（未验证）
- Phase -1：没装 Clash Verge 时 agent 帮装并迁移订阅；用别的代理软件的走迁移流程
- README：使用情况说明（约一年、跨 Mac/Windows/iPhone、账号零异常）、平台支持表（区分「方案可用性」与「本仓库自动化」，含 Windows 手动配置要点）、适合谁/不适合谁、静态 IP 具体要求表、agent 流程图、`verify.sh` 示例输出
- `LICENSE`（MIT）、本更新日志

**改进（更少的手工操作）**
- 美国节点不再逐个问用户确认，默认全用
- 增强文件缺失时 agent 尝试自动创建（带备份和失败退回 GUI）
- 重启 Chrome / Claude 桌面版改由 agent 代劳
- `verify.sh` 增加依赖自检（python3 / curl）

**说明**
- 多浏览器：QUIC 拦截规则只覆盖 Google Chrome，Edge / Arc / Brave 需自行照抄替换进程名（模板③注释里有对照表）
- Stripe 规则的副作用（所有网站的 Stripe 付款都会走静态 IP）已在模板里注明

## 更早（2026-04 ~ 2026-07，无版本号阶段）

- 2026-07-24 排障手册第 10 坑：多机配置漂移（模板升级后旧机器需重新对齐）
- 2026-07-13 回滚章节、美国节点关键词扩展、`verify.sh` 端口自动发现
- 2026-07-10 修 Claude Code 的链式代理覆盖（`claude.exe` 进程规则）
- 2026-07-07 重构为 agent 可复刻手册：七阶段流程 + 模板 + `verify.sh` + 排障手册
- 2026-04-14 最初版本：Claude 桌面版强制走静态 IP 的配置笔记
