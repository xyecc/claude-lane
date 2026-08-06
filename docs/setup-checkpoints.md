# 安装检查点与续跑规范

claude-lane 不要求一次跑完。安装器只自动完成确定性步骤；遇到必须由用户处理的订阅、付费、凭证和系统授权时，保存非秘密状态后正常暂停。

## 状态机

```text
NOT_STARTED
  → CLASH_INSTALLED
  → WAITING_FOR_SUBSCRIPTION
  → SUBSCRIPTION_IMPORTED
  → PROXY_REACHABLE
  → AIRPORT_VERIFIED
  → WAITING_FOR_ISP
  → ROUTING_CONFIGURED
  → VALIDATION_PASSED
  → COMPLETED
```

`WAITING_*` 是正常检查点，不是失败。重新运行同一启动入口时，必须先校验已安装组件和状态文件，再从当前检查点继续，不重复覆盖安装。

## 订阅检查点

Clash Verge 安装并打开后：

1. 安装器只判断当前 profile 是否为带非空 URL 的 `remote`；
2. 没有订阅时写入 `WAITING_FOR_SUBSCRIPTION`，提示用户在 Clash Verge GUI 本地导入，然后退出 0；
3. 已导入时写入 `SUBSCRIPTION_IMPORTED`，下载并核对固定 SHA-256 的 Anthropic 小型版本元数据；
4. 实际访问成功后写入 `PROXY_REACHABLE`，再下载 Claude Code；后续 Agent 通过 Clash API 确认美国节点和 TUN 后才写入 `AIRPORT_VERIFIED`；
5. 订阅链接不得进入命令参数、状态文件、日志或 Agent 上下文。

macOS 状态文件：

```text
~/Library/Application Support/claude-lane/setup-progress.json
```

Windows 状态文件：

```text
%LOCALAPPDATA%\claude-lane\setup-progress.json
```

状态文件只包含 schema、固定状态枚举、平台、固定原因码和更新时间。

## 用户与自动化边界

用户负责：

- 获取机场订阅，或接收服务方分配的独立/可撤销订阅；
- 在 Clash Verge GUI 本地粘贴订阅并更新；
- 完成机场、ISP、应用商店和模型服务的付款；
- 在本机隐藏输入 ISP 四元组、模型 Key，并确认管理员权限；
- 最终登录自己的模型服务账号。

自动化负责：

- 检测系统、CPU、组件版本和签名；
- 安装 Clash Verge、claude-lane 与受控 CLI；
- 保存和恢复非秘密安装进度；
- 在不输出 URL 的前提下检查订阅是否已经导入；
- 备份、生成路由、验证、回滚和输出打码诊断。

Agent 不负责购买机场，也不能在没有基础代理时反过来配置基础代理。Agent 只在订阅检查点通过后启动。

## 失败与暂停

- 没有 `profiles.yaml`：`WAITING_FOR_SUBSCRIPTION`。
- 当前 profile 不是远程订阅或 URL 为空：`WAITING_FOR_SUBSCRIPTION`。
- 订阅存在但 Anthropic 固定元数据不可达：保持 `SUBSCRIPTION_IMPORTED`，提示选择可用美国节点并开启 TUN 或系统代理，然后重跑同一入口。
- `profiles.yaml` 结构歧义、重复 `current` 或文件类型异常：失败关闭，不当成“尚未导入”。
- 订阅已导入但拉取失败、没有美国节点或基础网络不通：停在机场验证阶段，不进入 ISP 配置。
- 任一秘密只能由用户在本机输入；远程协助者只看固定状态和打码结果。
