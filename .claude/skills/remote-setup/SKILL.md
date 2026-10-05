---
name: remote-setup
description: 远程帮别人（Windows）部署 claude-lane 专线——agent 留在协助者本机写脚本、对方电脑只开远程终端（网易 UU / ToDesk 等），对方零依赖、不装任何 AI 工具。用户说「远程装机」「帮朋友配专线」「远程给 Windows 配 Clash」时使用。
---

# 远程装机（Windows）

**分工**：我（agent）在协助者 Mac 上当大脑——出脚本、读结果、下判断；协助者当手——传文件、在远程终端粘一行命令、截图回来。对方电脑上什么都不用装。

脚本都在 `scripts/windows/`（UTF-8 带 BOM，Windows PowerShell 5.1 要靠 BOM 认中文/emoji；改完必须保持 BOM，用 python `encoding='utf-8-sig'` 写回）：

| 脚本 | 作用 |
|---|---|
| `lane-probe.ps1` | 只读体检：别家 VPN、Clash 状态、当前订阅、四个增强文件是否为空、美国节点、出口 IP |
| `lane-config.ps1` | 自动定位当前订阅的增强文件 → 识别美国节点并测延迟排序 → 凭证（沿用 / 隐藏粘贴整串 `主机:端口:用户名:密码`，粘两次核对）→ 备份 → 写入四个文件 |
| `lane-verify.ps1` | 7 项验收，全 PASS 才算完成 |
| `lane-diag.ps1` | verify 有 FAIL 时用：curl 直连静态 IP vs 链式 delay 对比，最后一行给出是「配置 / 凭证 / 静态IP或机场」哪层坏 |

## 铁律

1. **每条要粘的命令都 `pbcopy` 进剪贴板**，并在回复里**按顺序一次给全**——协助者最烦往上翻找命令。
2. **远程终端只粘单行**：UU 终端多行粘贴会乱序丢字。长内容一律做成文件传过去。
3. **凭证不进对话**：只在对方电脑上隐藏输入。协助者要发四元组过来就劝住（会进模型服务端和本机会话记录）；已经泄露了就提醒配完去服务商后台重置密码。
4. **结论要有证据**：别凭截图里的 Timeout 就断言「机场垃圾 / IP 坏了」，跑 `lane-diag` 让它分层判断。
5. 写新的 PowerShell 函数**别用单字母名**（`R` = Invoke-History 等内置别名会盖掉函数）。

## 流程

### 0. 前提（不满足先按 `docs/helping-others.md` 让对方自己做完）
对方已装 Clash Verge Rev、导入含美国节点的订阅并点卡片激活；静态 IP（美国 · ISP/静态住宅 · SOCKS5）已买好。

### 1. 一次性传文件
`open scripts/windows`，让协助者把 4 个 `.ps1` 一起传到对方**桌面**。然后 pbcopy 这条（Windows 遇同名会改成 `xxx (2).ps1`，这条按修改时间取最新的改回原名）：

```powershell
$d=[Environment]::GetFolderPath('Desktop'); foreach($n in 'lane-probe','lane-config','lane-verify','lane-diag'){ $f=@(gci $d -Filter "$n*.ps1" | sort LastWriteTime -Descending); if($f.Count){ $t=Join-Path $d "$n.ps1"; if($f[0].FullName -ne $t){ Move-Item $f[0].FullName $t -Force }; $f | select -Skip 1 | ? { $_.FullName -ne $t } | Remove-Item } }; gci $d lane-*.ps1 | select Name,LastWriteTime
```

### 2. 体检
```powershell
powershell -ep bypass -f "$([Environment]::GetFolderPath('Desktop'))\lane-probe.ps1"
```
（必须带 `-ep bypass`：Windows 默认禁止运行脚本，直接敲路径会报 UnauthorizedAccess。这只对这一次生效，不改对方系统设置。）

输出太长就让协助者把桌面 `lane-probe.txt` 传回；它是 UTF-16，用 `iconv -f UTF-16LE -t UTF-8 <file>` 读。

**STOP 条件**：有 clash-verge / verge-mihomo 以外的代理或 VPN 进程 → 先让对方退出；没有美国节点 → 换机场；增强文件「有对方自己的内容」→ 先和协助者商量怎么合并，别覆盖。

### 3. 开 TUN（GUI，协助者「进入桌面」操作）
Clash Verge「设置」→ 打开 **TUN 模式**（提示装服务就点安装、UAC 点是）；「代理」页保持**规则**模式。

### 4. 写配置
```powershell
powershell -ep bypass -f "$([Environment]::GetFolderPath('Desktop'))\lane-config.ps1"
```
看回显：端口对、用户名长度和密码长度**都大于 1**（等于 1 说明整串被当成单段粘错了地方）；US-Chain 首选是延迟最低的美国节点。

### 5. 激活（GUI）
订阅页**点一下当前订阅卡片**——让增强文件合并进内核，不点不生效。

### 6. 验收
```powershell
powershell -ep bypass -f "$([Environment]::GetFolderPath('Desktop'))\lane-verify.ps1"
```
7 项全 PASS 才算完成。有 FAIL → 第 7 步。

### 7. 诊断（仅 verify 有 FAIL 时）
```powershell
powershell -ep bypass -f "$([Environment]::GetFolderPath('Desktop'))\lane-diag.ps1"
```

| curl 直连静态 IP | 链式 delay | 结论 → 怎么办 |
|---|---|---|
| 通 | 不通 | 配置层：GUI 里给 US-Chain 换节点再测；不行就看日志行 |
| 认证失败 | — | 凭证错 / 服务商开了 IP 白名单 → 后台核对或重置密码，重跑 config 选 n |
| 连不上 | — | 静态 IP 过期/未激活/端口错，或机场封端口 → 先看服务商后台，正常就换机场 |

### 8. 收尾（告诉协助者，一次说全）
1. 托盘右键**完全退出** Chrome / Edge / Claude 再打开（QUIC 和连接池有缓存，关窗口没用）。
2. Clash「连接」页搜 `cla`：应该全是 `Claude / US-Static`；还有 `DIRECT` 的点开看进程名和入站类型，发回来查。
3. claude.ai → 设置 → 账户 → 活跃会话：撤销旧会话、重新登录；还没账号的现在才注册。
4. 系统地区改美国（设置 → 时间和语言 → 区域），界面语言不用动。
5. 清理对方桌面（`%APPDATA%\...\claude-lane-backup\` 里的备份**别删**，回滚靠它）：
```powershell
$d=[Environment]::GetFolderPath('Desktop'); gci $d lane-* | Remove-Item -Verbose
```

**回滚**：把 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\claude-lane-backup\<时间>\` 里的文件复制回去（`profiles.yaml` 回配置目录，其余回 `profiles\`），再点一下订阅卡片。最早那个时间戳是对方最原始的状态。

## 改了脚本之后

本机没有 Windows，用便携版 PowerShell 在假配置上跑（不装进系统）：从 GitHub Releases 下 `powershell-<ver>-osx-arm64.tar.gz` 解压到 scratchpad；`APPDATA=<假目录> HOME=<假家目录> pwsh -NoProfile -File lane-config.ps1`。注意 macOS 上 `Read-Host -AsSecureString` 读不了管道输入，测整串路径时用一份把它替换成普通 `Read-Host` 的副本。至少覆盖：沿用旧凭证、整串含 `: ' " \`、两次不一致、少一段、端口非数字、增强文件有别人内容时拒绝、verify 失败计数。
