# claude-lane Bootstrap Agent Instructions

本仓库用于在尚未配置 Claude 使用环境的 macOS 上部署 Claude 专线。

执行任何操作前，必须完整读取根目录 `RUNBOOK.md`。它是唯一权威执行手册。

- 当前 Agent 就是手册中的执行器；本文件仅用于人工恢复或兼容，不参与默认 bootstrap。
- Phase 6 完成前不得登录 Anthropic，也不得把模型请求发往 Anthropic。
- 严格按照阶段顺序执行，命中 STOP 条件必须停止。
- 不得要求用户把机场订阅链接、静态 IP 凭证或模型 API Key 贴进对话，也不得主动读取或回显这些秘密。
- 不得跳过权限确认。
- 六项验证没有全部通过，不得宣布完成。
