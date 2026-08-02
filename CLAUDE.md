# claude-lane Bootstrap Instructions

本仓库用于在尚未配置 Claude 使用环境的 macOS 上部署 Claude 专线。

执行任何操作前，必须完整读取根目录 `RUNBOOK.md`。它是唯一权威执行手册。

- 当前 Claude Code 由启动器临时连接到 DeepSeek；Phase 6 完成前不得登录 Anthropic，也不得把模型请求发往 Anthropic。
- 严格按照阶段顺序执行，命中 STOP 条件必须停止。
- 不得要求用户把机场订阅链接、静态 IP 凭证或 DeepSeek API Key 贴进对话，也不得主动读取或回显这些秘密。
- 只能执行仓库内经过校验并在权限白名单中的脚本。
- 六项验证没有全部通过，不得宣布完成。
