# Bootstrap 与国内分发规范

## 当前状态

`bootstrap.sh` 与 `bootstrap.ps1` 是 manifest 驱动、可暂停恢复的确定性启动器。当前已固定 Claude Code `2.1.220` 和 Clash Verge Rev `2.5.2` 的 macOS / Windows 双架构摘要。Clash 原始制品已上传阿里云 OSS 并完成匿名回下载校验；Claude Code 只在订阅代理可用后从 Anthropic 官方固定版本地址下载。备用源暂缓，lane 归档与全部真机证据未齐，因此 `manifests/stable.json` 继续处于门禁状态。

启动器发现示例域名、`TBD`、空值、非 64 位 SHA-256、下载失败或哈希不一致时，必须在修改系统前停止。现在没有公开的 `curl | bash` 地址，也没有已经验收的离线包。不要删除校验、填写随意哈希或临时改用第三方镜像绕过门禁。

## 目标边界

macOS bootstrap 负责可确定、可验证的完整启动步骤：

1. 检查 macOS、CPU 架构、磁盘和现有代理；
2. 从版本化 manifest 取得固定产物路径，并与启动器发布块中固化的主备地址组合；
3. 从国内源下载并校验 claude-lane 包和 Clash Verge Rev；
4. 校验 Clash 代码签名并安装；
5. 检查 Clash Verge 当前远程订阅；没有订阅时保存状态并正常暂停，重新运行后续跑；
6. 代理可用后从 Anthropic 官方固定版本地址下载 Claude Code，校验 SHA-256、代码签名和版本；
7. 从本地终端隐藏读取安装专用 DeepSeek Key；
8. 用固定模型做文本响应和只读工具自检；
9. 启动 Claude Code 完整执行 `RUNBOOK.md`；
10. 要求 Phase 6 非秘密完成标记，再由父启动器在干净环境独立执行六项验证并清理临时状态。

Agent 不决定下载版本或来源，也不临时搜索镜像。启动阶段不依赖 Git、Homebrew、Node.js、Python 3 或 `jq`，只使用 macOS 自带组件。

Windows `bootstrap.ps1` 支持 Windows 10 1809+ 的 x64 / ARM64，只负责固定清单下载、主备切换、SHA-256、签名策略、版本校验、不覆盖现有安装，以及订阅检查点。Claude Code 强制 Authenticode；Clash Verge Rev 强制上游 Tauri minisign、固定 SHA-256，并在真机记录 Authenticode 实际状态。没有订阅时保存 `WAITING_FOR_SUBSCRIPTION` 后正常结束，不启动 Agent。它不扩张 macOS 专线 `RUNBOOK.md` 的 Phase -1～6；Windows 分流仍按 `docs/porting.md` 人工处理。启动期间设置 `DISABLE_UPDATES=1` 与 `DISABLE_AUTOUPDATER=1`，不使用执行策略绕过或关闭系统安全。

Windows 不再使用含大体积安装包的搬运验证包。正式候选直接走同一条 OSS 启动链：国内下载 Clash 与 lane，订阅检查点后再从 Anthropic 官方地址取得 Claude Code，并调用 `windows-deepseek.ps1` 启动隔离会话。该链路不代表 Windows 专线路由已经自动化。

## Manifest 语义

根目录 `manifests/stable.json` 是当前 schema 样例。字段如下：

| JSON 路径 | 含义与门禁 |
|---|---|
| `schema` | 必须为启动器明确支持的整数版本，当前为 `1` |
| `release_status` | 发布状态；未达到可发布值时停止 |
| `minimum_macos` | 启动器允许的最低 macOS 版本 |
| `minimum_windows` | Windows 启动器允许的最低版本，当前为 Windows 10 1809 |
| `required_free_mb` | 开始下载 / 安装前要求的最小可用磁盘空间（MiB） |
| `claude_lane.version` | 必须与根目录 `VERSION` 及归档内版本一致 |
| `claude_lane.path` | 版本化 tarball 的相对对象路径，不能用 `latest` |
| `claude_lane.archive_root` | 解压后预期的唯一顶层目录，用于拒绝错误包结构 |
| `claude_lane.sha256` | tarball 的 64 位十六进制 SHA-256 |
| `claude_lane.windows_path` / `.windows_sha256` | Windows ZIP 的不可变路径与摘要 |
| `claude_code.version` | 固定 Claude Code 版本，不能用稳定通道别名 |
| `claude_code.manifest_gpg_fingerprint` | 发布维护者离线审计官方 manifest 时记录的预期 GPG 指纹；bootstrap 运行时只做固定值比对，不执行 GPG 验签 |
| `claude_code.distribution` | 必须为 `anthropic-official-after-proxy`，禁止把 Claude 二进制指向公开 OSS |
| `claude_code.darwin_arm64` / `.darwin_x86_64` | Anthropic 官方固定 URL、摘要及运行时 codesign 状态 |
| `claude_code.win32_arm64` / `.win32_x64` | Anthropic 官方固定 URL、摘要及运行时 Authenticode 状态 |
| `clash_verge.version` | 固定正式版 Clash Verge Rev 版本 |
| `clash_verge.arm64.path` / `.sha256` | Apple Silicon DMG 路径与官方核对摘要 |
| `clash_verge.x86_64.path` / `.sha256` | Intel DMG 路径与官方核对摘要 |
| `clash_verge.win32_arm64` / `.win32_x64` | Windows 正式安装器、Tauri 签名和 Authenticode 验证状态 |

国内主、备 HTTPS 基址和 **stable manifest 自身的固定 SHA-256** 位于 `bootstrap.sh` 的发布块，不由远端 manifest 自行决定。启动器先从固化的主源、备用源下载 manifest 并核对该摘要，再解析其中的相对 `path`；这样被替换的远端清单不能把下载重定向到新域名。

启动器按 `uname -m` 只选择当前架构条目。主源失败或产物校验不通过时可以尝试备用源，但备用源仍必须命中**同一个固定 SHA-256**；两个源都失败就停止，不得改用搜索结果或 `latest`。

`manifests/stable.json` 只保存公开的版本、相对路径、摘要和发布元数据，不保存 DeepSeek Key、机场订阅、静态 IP 四元组或对象存储密钥。

### 启动参数

| 参数 | 用途 |
|---|---|
| `--dry-run` | 只做环境与 manifest 门禁检查，不执行安装 |
| `--help` | 显示参数与当前发布状态 |
| `--manifest-file <path>` | 仅专项测试注入；必须同时设置 `CL_BOOT_TEST_MODE=1`，不是用户入口 |

正式运行不接受任意 manifest URL、镜像 URL 或哈希覆盖参数。测试注入门禁不得用于现场安装，也不得写进 README 的用户命令。

## 版本与供应链

### Claude Code

1. 发布维护者选择稳定通道中的明确版本。
2. 从 Anthropic 官方来源取得该版本的签名 manifest。
3. **发布到国内存储前**核验 manifest 的 GPG 签名，再从已验签 manifest 读取 Apple Silicon 与 Intel 二进制 SHA-256。
4. 国内公开存储不缓存 Claude Code 二进制；仓库 manifest 中的摘要必须与已验签官方 manifest 一致。
5. 订阅代理可用后，目标机从 Anthropic 官方固定版本 URL 下载并校验 SHA-256、代码签名、发布者和版本。任一步失败即停止。
6. Anthropic 官方安装文档明确提到组织可以“通过自己的渠道分发”固定版本，但 Claude Code 的使用仍受对应商业或消费者条款约束；该说明不能自动视为对任意公共镜像的普遍再分发授权。未建立本次公开发布授权前，只使用私有 OSS / 受控缓存，不把二进制附进公开 Release。参考：[安装与更新](https://code.claude.com/docs/en/installation)、[法律与合规](https://code.claude.com/docs/en/legal-and-compliance)。

Windows 二进制还必须分别在真实 x64 与 ARM64 Windows 上运行 `scripts/mirror/verify-artifacts.ps1`，由 `Get-AuthenticodeSignature` 核对有效签名和发布者，并执行 `claude.exe --version`。macOS 不能替代这项证据。

CDN 返回的 `ETag`、`Content-MD5` 或旁路哈希不能替代官方签名 manifest。

### Clash Verge Rev

1. 只选择官方稳定 Release 的明确版本，同时取得 arm64 / x86_64 DMG 和 Windows ARM64 / x64 正式安装器；排除 prerelease、nightly、AutoBuild 和 fixed-WebView2 变体。
2. 发布维护者对照官方提供的摘要；若官方没有可信摘要，不得自行把未知下载结果当作官方基线。
3. 缓存前后执行 SHA-256 对比；安装前运行 `codesign --verify`，安装后对 App 运行 `spctl --assess`。
4. 不修改 DMG，不使用 `xattr -cr`、关闭 Gatekeeper 或其他方式掩盖签名失败。
5. 同步 GPL-3.0 许可证并记录对应源码仓库和版本。
6. Windows 安装器先核对 GitHub Release 摘要与官方 Tauri minisign，再在对应真实 Windows 架构记录 Authenticode。若上游制品为 `NotSigned`，必须与固定清单状态一致；摘要、Tauri minisign、版本或清单状态任一不符都停止。

### claude-lane 包

- 从已审阅的 tag / commit 生成版本化 tarball；
- 只包含 RUNBOOK、运行期脚本、模板和必要文档；不包含外层 bootstrap、stable manifest 或发布者工具，避免 tarball 与 manifest 摘要形成循环依赖；
- 包内 `VERSION` 必须与 manifest 一致；
- 归档不得包含本地配置、备份、日志、Key 或未跟踪的秘密文件；
- 上传后从主、备源各下载一次并核对同一 SHA-256。

## 国内对象存储

主源与备用源从阿里云 OSS、腾讯云 COS、火山引擎 TOS 等国内对象存储中选择两个独立故障域。对象路径必须带完整版本且发布后不可覆盖，例如：

```text
/claude-lane/releases/bootstrap/v1/install.sh
/claude-lane/releases/bootstrap/v1/install.ps1
/claude-lane/releases/v1.3.0/claude-lane.tar.gz
/clash-verge/releases/<version>/Clash.Verge_<version>_aarch64.dmg
/clash-verge/releases/<version>/Clash.Verge_<version>_x64.dmg
/clash-verge/releases/<version>/Clash.Verge_<version>_arm64-setup.exe
/clash-verge/releases/<version>/Clash.Verge_<version>_x64-setup.exe
/manifests/stable.json
/licenses/clash-verge-rev-GPL-3.0.txt
```

要求：

- 只用 HTTPS；证书、域名和 CDN 均由发布方控制；
- 对象开启不可变或版本保留策略；更新 stable 时创建新版本对象，不能覆盖旧对象；
- 主备源的字节内容和 SHA-256 完全一致；
- bootstrap 自身采用版本化路径，stable 入口只在验收通过后更新；
- 不使用未知运营方的 GitHub 反代或临时下载站。

## `curl | bash` 与交互输入

管道启动时，Shell 的 stdin 是 `curl` 输出，不是用户终端。所有秘密输入和确认都必须显式从 `/dev/tty` 读取，例如：

```bash
[ -r /dev/tty ] && [ -w /dev/tty ] || {
  printf '需要交互式终端，无法从 /dev/tty 读取输入\n' >&2
  exit 1
}

printf '请输入安装专用 DeepSeek API Key: ' >/dev/tty
IFS= read -r -s DEPLOY_DEEPSEEK_KEY </dev/tty
printf '\n' >/dev/tty
```

无法访问 `/dev/tty` 时必须停止，不能退回普通 stdin、命令行参数、URL 参数或环境提示。Key 通过匿名文件描述符送入受控子 shell，再由该 shell 导出给单次 Claude Code 进程；不得作为 `env NAME=value` 参数，不得写入 Shell 历史、`~/.zshrc`、用户级 Claude 设置、manifest、临时日志或进程参数。`EXIT`、`INT`、`TERM` 的 `trap` 都要覆盖清理。

最终公开命令只有在下文发布门禁全部通过后才可以写进 README。发布前建议用户先下载并审阅版本化 `bootstrap.sh`；直接管道执行不降低任何签名和哈希要求。

## 不再提供大体积搬运包

本链路不生成包含 Claude Code 或多架构 Clash 安装包的 239MB 验证 ZIP。macOS 与 Windows 都按当前架构从 OSS 下载 Clash；代理可用后再从 Anthropic 官方源下载 Claude Code。任何离线介质都不得预置 DeepSeek Key、机场订阅或静态 IP 凭证。

## 发布门禁

更新 stable 前必须全部完成：

1. 固定 Claude Code、Clash Verge Rev 和 claude-lane 三个版本；
2. 核验 Claude Code 官方 manifest 的 GPG 签名及双架构哈希；
3. 核验 Clash 官方摘要、DMG / App 代码签名及 GPL 材料；
4. 上传主源不可变对象并回下载验证；备用源启用后再按同一 SHA-256 验收；
5. `bash scripts/selftest.sh` 全绿；
6. `bash scripts/bootstrap-selftest.sh` 全绿；
7. Apple Silicon 与 Intel 至少各完成一轮规定测试；
8. 在无代理、无 Git、无 Node.js、无 Homebrew、无 Python 3、无 Claude Code 的干净 Mac 上完成端到端验收；
9. 验证成功、失败和 Ctrl+C 都不会残留 DeepSeek Key或临时 Claude 配置；
10. 验证普通 `claude` 不再指向 DeepSeek，再更新 stable 入口和 README 命令。
11. Windows x64 与 ARM64 分别完成 `scripts/mirror/verify-artifacts.ps1`，并运行 `scripts/bootstrap-windows-selftest.ps1`。
仓库当前未满足第 1～4、7～10 项中的分发与真机条件，所以保持失败关闭是正确状态，不是安装故障。
