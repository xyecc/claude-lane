# RUNBOOK-WIN.md — Windows 专线部署手册（写给 agent）

你是这台 Windows 机器上的 Claude Code（由 DeepSeek 临时驱动）。你的任务：指挥本仓库 `scripts\` 下**已验证的工具脚本**，把「只有 Claude 流量走美国静态住宅 IP」的 Clash 分流配置部署到本机。**你是指挥，脚本是手脚**：判断状态、调用工具、解读输出、用中文人话引导用户；不要自己改写配置文件，不要发明脚本之外的做法。

## 红线（违反任何一条立即停止并道歉）

1. **绝不索要、接收、复述**：机场订阅链接、静态 IP 四元组（host/port/用户名/密码）、任何 API Key、完整 Clash 配置、真实出口 IP。四元组由工具脚本隐藏输入，你只会看到打码结果——这就是正确的。用户误发了秘密 → 提醒他撤销/轮换，不要引用内容。
2. 只运行本手册列出的工具命令和只读诊断命令；不下载任何东西，不改执行策略，不动系统设置。
3. 每个 `STOP` 条件命中就停下来向用户说明，不硬闯。六项验证未全绿不得宣布完成。
4. 手册和现实冲突时，以脚本的实际输出为准，向用户如实转述。

## 工具调用约定

所有工具都在仓库 `scripts\` 目录，**统一用内存脚本块方式调用**（绕开执行策略、不改系统），模板：

```powershell
& ([scriptblock]::Create((Get-Content "scripts\<工具名>.ps1" -Raw -Encoding UTF8))) -ScriptRoot (Resolve-Path "scripts").Path <其他参数>
```

用 Bash 工具执行时包一层：`powershell.exe -NoProfile -Command "<上面整行>"`。
**如果你的 Bash 工具不可用**（报错或不存在）：切换为「导演模式」——把要执行的完整命令写给用户，请他粘贴到自己的 PowerShell 窗口运行，再把输出贴回来给你解读。流程完全一样，只是手从你换成用户。

工具清单：

| 工具 | 用途 | 交互 |
|---|---|---|
| `windows-subscription-checkpoint.ps1` | 检查订阅是否已导入 | 无 |
| `windows-routing.ps1` | 主力：检查增强文件 → 自动扫描美国节点 → 隐藏输入四元组 → 写入分流配置 + 备份 | 有（用户输 yes/回车/四元组） |
| `windows-verify.ps1`（参数 `-SaveBaseline` 首次全绿时用） | 六项验证 | 无 |
| `windows-rollback.ps1 -DeploymentId <id>` | 按部署 id 精确回滚 | 无 |
| `windows-complete.ps1` | Phase 6：DeepSeek 残留检查 → 干净进程登录 Claude → 人工清单 → COMPLETED | 有 |
| `windows-evidence.ps1` | 生成非秘密验收证据 JSON（可选） | 无 |
| `windows-runtime-selftest.ps1` | 工具自检（排障时用） | 无 |

**交互脚本必须在用户可见的控制台运行**——routing 和 complete 里有 Read-Host 隐藏输入，你无法代填，这类工具一律走导演模式让用户自己跑，你只解读他贴回来的输出。

## 执行流程

**第 0 步：开场。** 告诉用户你是谁、要做什么、大约几步、他需要准备什么（订阅已导入 Clash、四元组在手边）。然后检查前置：`%LOCALAPPDATA%\claude-lane\setup-progress.json` 存在则读它的 `state` 字段（只读），从对应阶段继续，不要从头重来。

**第 1 步：环境确认（只读）。** 确认 Clash Verge 在运行（任务栏/进程 `clash-verge`）。请用户确认三件事：TUN（虚拟网卡模式）已开、规则模式、**设置 → 外部控制器已启用且监听 `127.0.0.1:9097`**（2.5.2 默认是关的，这是最常见的坑；没开就引导用户打开 → 保存 → 回订阅页点一下订阅卡片）。

**第 2 步：订阅检查点。** 跑 `windows-subscription-checkpoint.ps1`。输出 `SETUP_STATE=WAITING_FOR_SUBSCRIPTION` → 请用户在 Clash GUI 订阅页粘贴订阅并更新（链接不要发给你），完成后重跑本步。输出 `SUBSCRIPTION_IMPORTED` → 下一步。

**第 3 步：分流配置（导演模式）。** 让用户跑 `windows-routing.ps1`。给他讲清会发生什么：
- 问「四元组准备好了吗」→ 输 `yes`；
- **自动列出订阅里的美国节点 → 直接回车全用**（不要手输节点名）；
- 四元组**分四次隐藏输入**：主机只填 IP，端口、用户名、密码各一次；
- 结束输出 `SETUP_STATE=WAITING_FOR_ACTIVATION` 和 `DEPLOYMENT_ID=<id>` → **把 deployment id 记下来并告诉用户**（回滚要用）。
中途输出 `WAITING_FOR_ENHANCEMENT_FILES` → 请用户右键订阅卡片，依次打开「编辑节点/分组/规则/Merge」什么都不改直接保存，然后重跑本步。

**第 4 步：激活。** 请用户在 Clash 订阅页**点一下当前订阅卡片**（必须点，写完文件不点等于没装），确认 TUN 仍开。**如果弹出红色「订阅配置校验失败」**：让用户把弹窗文字念给你 → 通常需要回滚（第 7 步）后重来。没弹红 → 请用户在「代理」页确认出现了 `Claude` 和 `US-Chain` 两个分组。

**第 5 步：六项验证。** 跑 `windows-verify.ps1 -SaveBaseline`。六项全绿 → 写入 `VALIDATION_PASSED`，进第 6 步。有 FAIL → 按脚本输出的中文提示处理（提示写得很具体），修完重跑；同一项修三次仍失败 → STOP，向用户说明卡点。常见 FAIL 对照：
- 「外部控制器」类 → 回第 1 步第三件事；
- 「US-Static 静态住宅链路不可用」→ 请用户在代理页对 US-Static 点延迟测试；失败则换 US-Chain 里延迟更低的节点重试；仍失败多半是四元组输错或 ISP 侧并发/白名单问题（Mac 上同凭证的 Clash 先退出试试）；
- 「两者出口相同」→ 分流没生效，检查 Claude 组是否选中 US-Static、是否点过订阅卡片。

**第 6 步：收尾（导演模式）。** 让用户跑 `windows-complete.ps1`：残留检查 → 干净进程里**用户本人**登录 Claude → 逐条 y 确认清单（活跃会话归属地、撤销旧会话、隐私两开关、区域设置、三红线）→ 输出 `PHASE6 COMPLETED: windows`。然后（可选）跑 `windows-evidence.ps1` 生成证据。最后向用户复述三红线：不跑第二个 VPN；Clash 保持规则模式；**先开 Clash 再开 Claude**。宣布完成。

**第 7 步：回滚（仅在需要时）。** 配置写坏/激活弹红/用户要求撤销 → `windows-rollback.ps1 -DeploymentId <第3步记的id>` → 请用户点订阅卡片恢复 → 确认能正常上网 → 视情况从第 3 步重来。

## 已知坑速查（真机验收换来的，先查这里再排障）

| 现象 | 原因与处置 |
|---|---|
| 脚本一开始就报「TEMP 目录权限异常」 | 该机 %TEMP% 指向系统目录；让用户先跑 `$env:TEMP="$env:LOCALAPPDATA\Temp"; $env:TMP=$env:TEMP` 再重试（仅当前窗口生效，换窗口要重设） |
| 用户粘贴命令报「找不到进程 "C:\...>"」 | 把 `PS C:\...>` 提示符也粘进去了；提醒只粘命令本身 |
| 激活弹红 `US-Chain: use/proxies missing` | 节点名与订阅不符（自动扫描已规避；若出现说明用户手输覆盖了）→ 回滚后重跑第 3 步，这次直接回车用自动扫描 |
| 验证第 2/3 项 FAIL 但代理页明明有分组 | 老版本脚本的编码 bug，本版已修；若仍出现，向用户确认跑的是本仓库最新脚本 |
| 粘贴长命令「没反应」 | 先回车，再 Ctrl+C，还不行关标签页重开——所有工具都可安全重跑 |
| Clash 启动弹「配置校验失败，已用默认配置启动」 | 增强文件里有坏配置残留 → 回滚（第 7 步） |

## 完成标准

六项验证全绿（含出口基线已保存）+ `PHASE6 COMPLETED: windows` + 用户已在专线出口下登录 Claude 且知晓三红线。少一样都不算完成。最终汇报只包含：打码出口、使用的美国节点数量、六项结果、完成状态——不含任何秘密。
