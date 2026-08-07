# v1.4 Windows Agent 版真机测试手册（agent-orchestrator 分支）

目标机前提（那台已跑过 v1.3 验收的 Win11 x64 正好全部满足）：Clash Verge 2.5.2 已装、订阅已导入、TUN 开、外部控制器 127.0.0.1:9097 已启用、固定版 Claude Code 2.1.220 已在 `%LOCALAPPDATA%\claude-lane\tools\`。另备：额度受限可撤销的 DeepSeek API Key。

## 第 0 步：拉取本分支（走已配好的代理）

```powershell
$env:TEMP = "$env:LOCALAPPDATA\Temp"; $env:TMP = $env:TEMP   # 该机 TEMP 特例
Invoke-WebRequest "https://codeload.github.com/maien210/claude-lane/zip/refs/heads/agent-orchestrator" -OutFile "$env:TEMP\lane14.zip"
Expand-Archive -LiteralPath "$env:TEMP\lane14.zip" -DestinationPath "$env:USERPROFILE\claude-lane-14" -Force
Set-Location "$env:USERPROFILE\claude-lane-14\claude-lane-agent-orchestrator"
```

## 第 1 步：Parser 预检（新脚本第一次上真机，先过语法关）

```powershell
$errs = 0
foreach ($f in (Get-ChildItem "scripts\*.ps1")) {
  $t = $null; $e = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
  if ($e.Count -gt 0) { $errs++; "PARSE FAIL $($f.Name): $($e[0].Message)" }
}
"parser errors: $errs"
```

`parser errors: 0` 才继续；否则把输出发回修码。

## 第 2 步：启动 Agent 会话

```powershell
& ([scriptblock]::Create((Get-Content "scripts\windows-agent-session.ps1" -Raw -Encoding UTF8))) -ScriptRoot (Resolve-Path "scripts").Path
```

预期：验固定版 Claude Code → 隐藏输入 DeepSeek Key → 握手通过 → 进入交互会话，Agent 自我介绍并开始按 RUNBOOK-WIN.md 走。

## 观察点（测试的实际考题）

1. Agent 是否主动读完 RUNBOOK-WIN.md 再动手；
2. Agent 的 Bash 工具在该机是否可用；不可用时是否正确切到「导演模式」（给命令让人粘贴）；
3. 每条命令是否都弹权限确认（应该弹；绝不出现自动放行）；
4. 该机已有配置（状态 ROUTING_CONFIGURED），Agent 应识别断点直接跳到验证，而不是重问四元组；
5. 六项验证全绿后是否正确走 complete 收尾、绝不索要秘密；
6. 退出会话后终端提示「Key 与临时配置已清理」。

任何一步偏离：直接 `/quit` 退出会话（清理自动执行），把现场发回。DeepSeek 不听话属于预期内风险，手册措辞会按实测迭代。
