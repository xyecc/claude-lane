#!/usr/bin/env ruby
# macOS: locally enter a second SOCKS5 endpoint without exposing credentials in chat.
#
# 写入方式：在原文件里【插入几行文本】，不整份 YAML.dump 重写。
# 旧版整份重写会抹掉所有注释，包括 `# claude-lane managed start/end` 标记，
# 之后 set-credentials.sh 找不到托管块、只能报冲突（2026-09 实际发生过）。
require 'yaml'
require 'json'
require 'io/console'
require 'open3'
require 'tempfile'

# 可以原样打印给用户的错误（不含凭证）
class SafeError < StandardError; end

# JSON 字符串同时是合法的 YAML 双引号标量（set-credentials.sh 同一做法）
def yaml_q(s)
  s.to_s.to_json
end

def node_lines(node, indent)
  [
    "#{indent}- name: #{yaml_q(node.fetch('name'))}",
    "#{indent}  type: socks5",
    "#{indent}  server: #{yaml_q(node.fetch('server'))}",
    "#{indent}  port: #{Integer(node.fetch('port'))}",
    "#{indent}  username: #{yaml_q(node.fetch('username'))}",
    "#{indent}  password: #{yaml_q(node.fetch('password'))}",
    "#{indent}  udp: false",
    "#{indent}  dialer-proxy: \"US-Chain\""
  ].map { |l| l + "\n" }
end

def blank_or_comment?(line)
  line.strip.empty? || line.strip.start_with?('#')
end

# 在顶层序列 key（prepend/append）末尾追加一项；兼容「  - 」缩进和 YAML.dump 的「- 」顶格写法
def append_top_level_item(text, key, node)
  lines = text.lines
  lines[-1] += "\n" if lines.any? && !lines[-1].end_with?("\n")
  idx = lines.index { |l| l =~ /\A#{key}:\s*(\[\s*\])?\s*(#.*)?\z/ }
  if idx.nil?
    lines << "#{key}:\n"
    return (lines + node_lines(node, '  ')).join
  end
  if lines[idx] =~ /\[\s*\]/
    lines[idx] = "#{key}:\n"
    lines.insert(idx + 1, *node_lines(node, '  '))
    return lines.join
  end
  first = lines[(idx + 1)..-1].find { |l| !blank_or_comment?(l) }
  indent = first && first =~ /\A(\s*)- / ? Regexp.last_match(1) : '  '
  stop = ((idx + 1)...lines.size).find { |i| lines[i] =~ /\A[^\s#-]/ } || lines.size
  stop -= 1 while stop - 1 > idx && lines[stop - 1].strip.empty?
  lines.insert(stop, *node_lines(node, indent))
  lines.join
end

# 往名为 group 的分组的 proxies 列表末尾加一个名字
def append_to_group(text, group, name)
  lines = text.lines
  lines[-1] += "\n" if lines.any? && !lines[-1].end_with?("\n")
  g = lines.index { |l| l =~ /\A(\s*)- name:\s*["']?#{Regexp.escape(group)}["']?\s*\z/ }
  raise SafeError, "分组文件里找不到 #{group} 分组" unless g
  g_indent = lines[g][/\A\s*/].size
  g_end = ((g + 1)...lines.size).find do |i|
    l = lines[i]
    !blank_or_comment?(l) && (l =~ /\A[^\s#-]/ || (l =~ /\A(\s*)- / && Regexp.last_match(1).size <= g_indent))
  end || lines.size
  p = ((g + 1)...g_end).find { |i| lines[i] =~ /\A\s*proxies:/ }
  raise SafeError, "#{group} 分组里找不到 proxies 列表" unless p
  if lines[p] =~ /\A(\s*)proxies:\s*(\[.*\])\s*\z/
    list = YAML.safe_load(Regexp.last_match(2)) << name
    lines[p] = "#{Regexp.last_match(1)}proxies: #{list.to_json}\n"
    return lines.join
  end
  p_indent = lines[p][/\A\s*/].size
  items = ((p + 1)...g_end).select { |i| lines[i] =~ /\A(\s*)- / && Regexp.last_match(1).size >= p_indent }
  raise SafeError, "#{group} 分组的 proxies 列表是空的" if items.empty?
  item_indent = lines[items.first][/\A\s*/]
  last = items.select { |i| lines[i][/\A\s*/] == item_indent }.last
  lines.insert(last + 1, "#{item_indent}- #{yaml_q(name)}\n")
  lines.join
end

# 写之前自证：新文本解析出来必须正好等于「旧内容 + 预期改动」，且旧文件的每一行注释都还在
def verify_edit!(old_text, new_text, expected)
  got = YAML.safe_load(new_text)
  raise SafeError, '插入后的内容和预期不一致，原配置未改动' unless got == expected
  missing = old_text.lines.map(&:rstrip).select { |l| l.strip.start_with?('#') } - new_text.lines.map(&:rstrip)
  raise SafeError, '插入会丢失原文件里的注释，原配置未改动' unless missing.empty?
end

def second_static_changes(cfg, node)
  registry = YAML.load_file(File.join(cfg, 'profiles.yaml'))
  current = registry.fetch('items').find { |i| i['uid'] == registry['current'] }
  raise SafeError, '找不到当前订阅' unless current
  files = %w[proxies groups].map do |kind|
    uid = current.fetch('option').fetch(kind)
    item = registry.fetch('items').find { |i| i['uid'] == uid }
    File.join(cfg, 'profiles', item ? item.fetch('file') : "#{uid}.yaml")
  end
  texts = files.map { |path| File.read(path, encoding: 'UTF-8') }
  proxies, groups = texts.map { |t| YAML.safe_load(t) || {} }
  existing = %w[prepend append].flat_map { |k| proxies[k] || [] }
  runtime = YAML.load_file(File.join(cfg, 'clash-verge.yaml'))
  names = (existing + runtime.fetch('proxies', []) + runtime.fetch('proxy-groups', [])).map { |x| x['name'] }
  raise SafeError, '第二条专线已存在，请直接在 Claude 分组切换；本脚本不会覆盖它。' if names.include?(node.fetch('name'))
  claude = %w[prepend append].flat_map { |k| groups[k] || [] }.find { |g| g['name'] == 'Claude' }
  raise SafeError, '找不到 Claude 手动选择分组' unless claude && claude['type'] == 'select'
  raise SafeError, '找不到 US-Chain 前置分组' unless runtime.fetch('proxy-groups', []).any? { |g| g['name'] == 'US-Chain' }

  exp_proxies = Marshal.load(Marshal.dump(proxies))
  exp_proxies['append'] = (exp_proxies['append'] || []) + [node]
  exp_groups = Marshal.load(Marshal.dump(groups))
  %w[prepend append].flat_map { |k| exp_groups[k] || [] }.find { |g| g['name'] == 'Claude' }['proxies'] << node.fetch('name')

  new_proxies = append_top_level_item(texts[0], 'append', node)
  new_groups  = append_to_group(texts[1], 'Claude', node.fetch('name'))
  verify_edit!(texts[0], new_proxies, exp_proxies)
  verify_edit!(texts[1], new_groups, exp_groups)

  # 用完整的本地配置给内核做一次语法检查（不激活）
  runtime.fetch('proxies') << node
  runtime.fetch('proxy-groups').find { |g| g['name'] == 'Claude' }.fetch('proxies') << node.fetch('name')
  [{ files[0] => new_proxies, files[1] => new_groups }, runtime]
end

def write_private(path, contents)
  Tempfile.create(['.claude-static-', '.yaml'], File.dirname(path)) do |f|
    f.chmod(0600)
    f.write(contents)
    f.flush
    f.fsync
    File.rename(f.path, path)
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    File.umask(0077)
    cfg = ENV.fetch('CLAUDE_LANE_CFG', File.expand_path('~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev'))
    console = IO.console
    abort '请在自己的终端运行，勿在聊天中输入凭证。' unless console
    puts '新增第二条 SOCKS5 专线，保留原节点。凭证只写入本机 Clash 配置。'
    console.print '粘贴四元组（主机:端口:用户名:密码，输入不显示），然后按回车：'
    raw = console.noecho(&:gets)
    console.puts
    abort '已取消' unless raw
    host, port, username, password = raw.chomp.split(':', 4)
    abort '格式错误：需要主机:端口:用户名:密码（IPv4 或域名）。' unless [host, port, username, password].all? { |v| v && !v.empty? }
    abort '端口必须在 1–65535 之间' unless port.match?(/\A[0-9]+\z/) && (1..65535).cover?(port.to_i)
    abort '主机格式错误' unless host.match?(/\A[a-zA-Z0-9.-]+\z/)
    node = { 'name' => '🇺🇸 US-Static-2', 'type' => 'socks5', 'server' => host,
             'port' => port.to_i, 'username' => username, 'password' => password,
             'udp' => false, 'dialer-proxy' => 'US-Chain' }
    changes, runtime = second_static_changes(cfg, node)
    core = '/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo'
    Tempfile.create(['.claude-static-check-', '.yaml'], cfg) do |f|
      f.chmod(0600)
      f.write(YAML.dump(runtime))
      f.flush
      _, status = Open3.capture2e(core, '-t', '-d', cfg, '-f', f.path)
      abort '内核配置检查失败，原配置未改动。' unless status.success?
    end
    id = Time.now.strftime('%Y%m%d-%H%M%S') + '-add-second-ip'
    backup_script = File.expand_path('backup.sh', __dir__)
    _, status = Open3.capture2e({ 'CLAUDE_LANE_CFG' => cfg, 'CLAUDE_LANE_DEPLOY_ID' => id },
                             'bash', backup_script, *changes.keys)
    abort '备份失败，原配置未改动。' unless status.success?
    originals = changes.keys.to_h { |path| [path, File.binread(path)] }
    begin
      changes.each { |path, text| write_private(path, text) }
    rescue StandardError
      originals.each { |path, content| write_private(path, content) }
      raise SafeError, '写入失败，已恢复原文件。'
    end
    puts "已添加：#{node['name']}；原节点保留，当前出口尚未切换。"
    puts "备份：#{File.join(cfg, 'claude-lane-backups', id)}"
    puts '下一步：Clash Verge → 订阅 → 点击当前订阅卡片重新加载。'
    puts '然后：代理 → Claude 分组 → 选择 US-Static-2；选回原节点即可恢复原出口。'
    puts '切换不会自动迁移旧连接；待当前任务结束，完全退出并重新打开相关 Claude 客户端。'
  rescue Interrupt
    warn "\n已取消。"
    exit 1
  rescue SafeError => e
    warn "操作未完成：#{e.message}"
    exit 1
  rescue StandardError
    # Avoid printing parser/OS exception details which may contain credentials.
    warn '操作未完成。请检查配置结构及文件权限；凭证未回显。'
    exit 1
  end
end
