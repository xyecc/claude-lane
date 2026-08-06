# Windows 安装与恢复手册

Windows 启动器覆盖 Windows 10 1809+ 的 x64 与 ARM64，阶段顺序固定：

1. 从国内 OSS 下载并校验 Clash Verge Rev 与 `claude-lane`。
2. 安装 Clash Verge；没有远程订阅时保存 `WAITING_FOR_SUBSCRIPTION` 并正常暂停。
3. 用户只在 Clash Verge GUI 粘贴机场订阅，重新运行同一条安装命令。
4. 订阅检查点通过后，先下载并核对固定 SHA-256 的 Anthropic 小型版本元数据；失败时保存检查点，提示用户选择可用美国节点并开启 TUN 或系统代理。
5. 代理实测通过并保存 `PROXY_REACHABLE` 后，从 Anthropic 官方源下载固定版 Claude Code；后续 Agent 确认美国节点后才记录 `AIRPORT_VERIFIED`。
6. 强制核对 SHA-256、Authenticode 发布者和 `claude --version`。
7. 本地隐藏读取 DeepSeek API Key，启动临时隔离会话。

## 安全边界

- 不把机场订阅、DeepSeek Key 或 ISP 四元组发给 Agent。
- 不修改 PowerShell ExecutionPolicy；启动器使用当前进程内的脚本块继续执行。
- 不使用未知下载站、GitHub 反代、`latest` 路径或关闭 Windows 安全功能。
- 已安装的用户 Claude Code 与 Clash Verge 保留；固定 Claude Code 使用 `%LOCALAPPDATA%\claude-lane\tools` 隔离目录。
- DeepSeek Key 只进入 Claude Code 子进程环境，退出后释放并删除临时配置。

## 当前边界

Windows 的下载、校验、安装、订阅暂停恢复和 DeepSeek 启动链已实现。Claude 专线的 Clash 增强文件自动合并与六项出口验证仍以 macOS `RUNBOOK.md` 为权威实现；Windows 不得虚报该部分已经完成。需要在 Windows 上复刻专线路由时，按 [`porting.md`](porting.md) 的四项目标逐项验收。
