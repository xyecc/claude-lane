# 帮别人装机：协助者手册

> 给**协助者**（维护者本人或任何帮朋友搭线的人）看的。目标只有一个：**把你在线陪跑的时间压到 20 分钟**——其余全变成对方自己能异步做完、并且能自己验证做对了的事。
>
> 依据：2026-08 一次远程装机总耗时约 2 小时，其中一个多小时耗在依赖和选 agent 上；另一次 4 小时的大头是「边买边装、买错重买」「截图来回、说不清点哪里」「手机那一串（美国 Apple ID / 礼品卡 / 小火箭）」。这些没有一样是「配置」本身。

## 一、流程：先让他能翻墙，其余都在这之后

**所有采购、注册、下载都要先能翻墙**，所以第一件事永远是「装 Clash + 有个能用的订阅」。不会翻墙的人，先给他一个临时订阅顶上，跑通了再换成你推荐的机场。

```
提前 1-3 天   ① 一条命令装 Clash（从国内 OSS 下载，不用翻墙）
（对方自己） ② 导订阅：会翻墙 → 直接买【推荐机场】；不会 → 先导你给的临时订阅，跑通后再买、再换
             ③ 开 TUN + 服务模式 → 验收：api.ipify.org 显示国外 IP      ← 从这一刻他能上外网
             ④ 买静态 IP（美国·静态·SOCKS5）→ ipinfo 验证 ASN=ISP → 存好四元组
             ⑤ 手机：美区 Apple ID + 礼品卡 + 买小火箭（iPhone 才需要）
当天 ≈20 分钟 ⑥ 配专线：Mac 用 agent 或（将来）一条命令；Windows 远程走 /remote-setup（scripts/windows/），手工版见 windows-setup.md
（你在线）      凭证他自己粘 → 点一下订阅卡片 → 浏览器两条验收
之后          ⑦ 注册 Claude（最后才注册）；手机照 iphone-notes.md 5 分钟
```

**门槛规则**：③ 和 ④ 的验收截图没发来，不约 ⑥ 的时间。

**临时订阅怎么给**：别直接发你自己的订阅链接（设备数、流量都记在你头上，泄露了只能重置自己的）。单独买一份最便宜的套餐当"借用订阅"，用完在机场后台重置链接。订阅链接国内打不开的话，改发配置文件（Verge 支持导入本地文件）。

### 一条命令装 Clash（Clash Verge Rev 2.5.2，来自本项目的阿里云 OSS，匿名可下）

Windows（按 Win 键搜 PowerShell 打开，整段粘进去回车；下载约 47 MB，装完出现安装向导照点）：

```powershell
$ProgressPreference='SilentlyContinue'; iwr https://claude-lane-release-prod-20260802-k7m3q9.oss-cn-beijing.aliyuncs.com/clash-verge/releases/v2.5.2/Clash.Verge_2.5.2_x64-setup.exe -OutFile "$env:USERPROFILE\Downloads\ClashVerge-setup.exe"; & "$env:USERPROFILE\Downloads\ClashVerge-setup.exe"
```

Mac（Apple Silicon；Intel 把 `aarch64` 换成 `x64`。打开镜像后把图标拖进「应用程序」）：

```bash
curl -fL https://claude-lane-release-prod-20260802-k7m3q9.oss-cn-beijing.aliyuncs.com/clash-verge/releases/v2.5.2/Clash.Verge_2.5.2_aarch64.dmg -o ~/Downloads/ClashVerge.dmg && open ~/Downloads/ClashVerge.dmg
```

Mac 打开时若提示「已损坏 / 无法打开」（安装包没签名），跑一次 `xattr -cr "/Applications/Clash Verge.app"` 再开。

> ⚠️ Windows 这条命令还没在真机上跑过（09-06 只验证了下载地址返回 200），第一次用时盯一下。

## 二、发给对方的消息（复制即用，`【】` 里的自己填）

```
明天帮你把 Claude 专线搭起来。今晚请按下面的顺序先做几步，每做完一步发我一张截图。顺序不能换——后面买东西、注册账号都得先能上外网。

—— 第 1 步：装 Clash（一条命令，不用翻墙）——
按 Win 键，搜「PowerShell」打开，把下面整段粘进去回车，等安装向导弹出来照着点完：
$ProgressPreference='SilentlyContinue'; iwr https://claude-lane-release-prod-20260802-k7m3q9.oss-cn-beijing.aliyuncs.com/clash-verge/releases/v2.5.2/Clash.Verge_2.5.2_x64-setup.exe -OutFile "$env:USERPROFILE\Downloads\ClashVerge-setup.exe"; & "$env:USERPROFILE\Downloads\ClashVerge-setup.exe"
（Windows 弹「已保护你的电脑」→ 点「更多信息」→「仍要运行」）

—— 第 2 步：导入订阅 ——
你现在能翻墙的话：去【推荐机场 + 套餐】买好，复制「订阅链接」。
不能的话：先用我发你的这个临时链接：【临时订阅链接】，跑通了明天再换。
打开 Clash Verge →「订阅」页 → 粘贴链接 →「导入」→ 点一下出现的卡片。

—— 第 3 步：开 TUN ——
「设置」里打开「服务模式」（会弹管理员确认，点是）和「TUN 模式」；「代理」页上面选「规则」。
✅ 验收：浏览器打开 https://api.ipify.org ，显示一个国外 IP 就对了，截图发我。
到这里你已经能上外网了，后面的步骤才能做。

—— 第 4 步：买静态 IP ——
【服务商，如 IPRoyal】→ 选「Static Residential / ISP」→ 国家 United States → 协议 SOCKS5 → 最低档、买 1 个。
⚠️ 别买成 Rotating（轮换）IP。
买完会拿到 4 样：主机、端口、用户名、密码——存进备忘录，不用发给我。
✅ 验收：打开 https://ipinfo.io ，把「主机」那个 IP 填进搜索框，截图 ASN type（要是 ISP）和 Privacy 一栏（要全是 false）发我。买错了今晚就能退。

—— 手机（iPhone）——
需要一个美区 Apple ID 和一张美区礼品卡（$5 够）来买 Shadowrocket（$2.99）。这步比较绕，明天一起做；有现成美区 ID 的直接告诉我。

—— 先别做 ——
• 先别注册 / 购买 Claude 账号，线搭好之后再弄（账号从第一天起就该只见过一个 IP）。
• 电脑上别装别的 VPN / 代理软件，已经装了的明天告诉我。

—— 明天远程时 ——
• 远程软件里把「剪贴板同步」关掉。
• 截图前把静态 IP 服务商后台、机场订阅页这些带账号信息的页面先关掉。
• 静态 IP 的密码全程你自己输，我不需要看到。
```

## 三、协助时的规矩（每次都要）

1. **泄密**：先关远程软件的剪贴板同步；对方截图前切走 ISP 后台 / 订阅页 / IP 查询页；密码只由对方自己输入（Mac 用 `set-credentials.sh` 隐藏输入，Windows 在 Verge 编辑器里自己粘）。已经泄露就去服务商后台轮换。
2. **命令**：一次只给一条；相邻两条长得像的要合成一条，或明确写「这条和上一条不一样」（复盘里因此白折腾过一轮）。
3. **顺序**：先铺平依赖再动配置（干净 Mac 见排障第 11 条）；换 agent 解决不了环境问题。
4. **账号**：Claude 账号最后买、最后登；已有账号的配完去撤销归属地不对的旧会话。
5. **每一步截图**：协助的过程本身就是物料——脱敏后填进 `windows-setup.md` / `iphone-notes.md` 的 📷 占位，下一次就不用陪跑了。

## 四、按系统怎么走

| 系统 | 配置阶段怎么做 | 参考 |
|---|---|---|
| macOS | 对方装好 Claude Code 后，agent 照 `CLAUDE.md` 全自动；干净 Mac 先按排障第 11 条铺依赖 | README |
| Windows | 装 Clash 一条命令（见上）；配置不用脚本：Verge GUI 四个编辑器粘模板 + 点卡片 + 浏览器验收 | `windows-setup.md` |
| iPhone | 先有美区 Apple ID + 小火箭，再照配方 5 分钟 | `iphone-notes.md` |

## 五、时间账（用来判断下次改什么）

每次协助完，记一下三段各花了多久、卡在哪一步。连续两次卡在同一处，就把那一步做成截图或脚本。
