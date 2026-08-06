// macOS 自带 JXA 辅助工具：为 Bash 3.2 提供 JSON 解析/写入和安全字符串转义。
// 仅通过 /usr/bin/osascript -l JavaScript 调用，不依赖 Python、jq 或 Homebrew。
ObjC.import("Foundation");

function readStdin() {
  var data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
  var text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
  return text ? ObjC.unwrap(text) : "";
}

function readFile(path, missingOK) {
  var manager = $.NSFileManager.defaultManager;
  if (!manager.fileExistsAtPath($(path))) {
    if (missingOK) return "";
    throw new Error("找不到文件：" + path);
  }
  var data = manager.contentsAtPath($(path));
  var text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
  if (!text) throw new Error("文件不是有效 UTF-8：" + path);
  return ObjC.unwrap(text);
}

function fileExists(path) {
  return $.NSFileManager.defaultManager.fileExistsAtPath($(path));
}

function writeFileAtomic(path, text) {
  var data = $(text).dataUsingEncoding($.NSUTF8StringEncoding);
  if (!data.writeToFileAtomically($(path), true)) {
    throw new Error("写入失败：" + path);
  }
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function parseJSON(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error((label || "输入") + "不是有效 JSON");
  }
}

function own(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key);
}

// API 返回的节点名和本机进程名最终会进入终端。保留正常 Unicode，
// 但把控制字符转成可见文本并限制长度，避免擦屏、伪造状态或破坏 TSV 边界。
function displayText(value) {
  var text = String(value === undefined || value === null ? "" : value);
  text = text.replace(/[\u0000-\u001f\u007f-\u009f]/g, function (character) {
    var hex = character.charCodeAt(0).toString(16);
    while (hex.length < 4) hex = "0" + hex;
    return "\\u" + hex;
  });
  return text.length > 160 ? text.slice(0, 157) + "..." : text;
}

function markerMatches(text, marker) {
  var pattern = new RegExp("^[ \\t]*" + escapeRegExp(marker) + "[ \\t]*$", "gm");
  var matches = [];
  var match;
  while ((match = pattern.exec(text)) !== null) {
    matches.push({index: match.index, end: pattern.lastIndex});
    if (match.index === pattern.lastIndex) pattern.lastIndex += 1;
  }
  return matches;
}

function validProfileUid(value) {
  return /^[A-Za-z0-9]{1,128}$/.test(value);
}

function profileProxies(path) {
  var document = parseProfilesDocument(readFile(path, false));
  if (document.currentItem.type !== "remote") return "";
  var uid = document.currentItem.options.proxies || "";
  // 与 summary/register 共用严格解析器：重复 current/uid、flow YAML、歧义 option
  // 一律失败关闭，避免凭证被写进错误的增强文件。
  return /^p[A-Za-z0-9]{11}$/.test(uid) ? uid : "";
}

// Clash Verge profiles.yaml 的窄格式解析器。它只识别注册增强文件所需字段；
// flow YAML、重复字段或歧义结构一律失败关闭，绝不输出 name/url 原文。
function parseProfilesDocument(text) {
  var lines = text.split(/\r?\n/);
  var currentMatches = [];
  var itemStarts = [];
  var seenUids = {};
  var i;

  for (i = 0; i < lines.length; i += 1) {
    var currentMatch = lines[i].match(/^current:\s*([A-Za-z0-9]{1,128})\s*$/);
    if (currentMatch) currentMatches.push(currentMatch[1]);
    var itemMatch = lines[i].match(/^([ ]*)-\s*uid:\s*([A-Za-z0-9]{1,128})\s*$/);
    if (itemMatch) itemStarts.push({start: i, indent: itemMatch[1], uid: itemMatch[2]});
  }
  if (currentMatches.length !== 1) throw new Error("profiles.yaml 的 current 格式不唯一或不受支持");
  var currentUid = currentMatches[0];
  var items = [];

  itemStarts.forEach(function (start, index) {
    if (seenUids[start.uid]) throw new Error("profiles.yaml 存在重复 uid");
    seenUids[start.uid] = true;
    var end = index + 1 < itemStarts.length ? itemStarts[index + 1].start : lines.length;
    var propertyIndent = start.indent + "  ";
    var type = "";
    var file = "";
    var optionLine = -1;
    var options = {};
    var urlPresent = false;
    var urlReady = false;
    for (var j = start.start + 1; j < end; j += 1) {
      var typeMatch = lines[j].match(new RegExp("^" + escapeRegExp(propertyIndent) + "type:\\s*([A-Za-z]+)\\s*$"));
      if (typeMatch) {
        if (type) throw new Error("profile item 的 type 重复");
        type = typeMatch[1];
      }
      var fileMatch = lines[j].match(new RegExp("^" + escapeRegExp(propertyIndent) + "file:\\s*([A-Za-z0-9]+\\.yaml)\\s*$"));
      if (fileMatch) file = fileMatch[1];
      var urlMatch = lines[j].match(new RegExp("^" + escapeRegExp(propertyIndent) + "url:\\s*(\\S+)\\s*$"));
      if (new RegExp("^" + escapeRegExp(propertyIndent) + "url:").test(lines[j])) {
        if (urlPresent) throw new Error("profile item 的 url 重复");
        urlPresent = true;
      }
      if (urlMatch && !/^(null|[\"']{2})$/i.test(urlMatch[1])) urlReady = true;
      if (new RegExp("^" + escapeRegExp(propertyIndent) + "option:").test(lines[j])) {
        if (lines[j] !== propertyIndent + "option:" || optionLine !== -1) {
          throw new Error("option 使用了不受支持的 flow/重复格式");
        }
        optionLine = j;
      }
    }
    if (!type) throw new Error("profile item 缺少 type");
    if (optionLine !== -1) {
      var childIndent = propertyIndent + "  ";
      for (var k = optionLine + 1; k < end; k += 1) {
        if (!lines[k].replace(/^\s+|\s+$/g, "")) continue;
        if (lines[k].indexOf(childIndent) !== 0) break;
        var optionMatch = lines[k].match(new RegExp("^" + escapeRegExp(childIndent) +
          "(proxies|groups|rules|merge):\\s*([A-Za-z0-9]{12})\\s*$"));
        if (!optionMatch) continue;
        if (own(options, optionMatch[1])) throw new Error("option 字段重复");
        options[optionMatch[1]] = optionMatch[2];
      }
    }
    items.push({
      start: start.start,
      end: end,
      indent: start.indent,
      propertyIndent: propertyIndent,
      uid: start.uid,
      type: type,
      file: file,
      optionLine: optionLine,
      options: options,
      urlPresent: urlPresent,
      urlReady: urlReady
    });
  });

  var currentItems = items.filter(function (item) { return item.uid === currentUid; });
  if (currentItems.length !== 1) throw new Error("current 没有唯一对应 item");
  return {lines: lines, currentUid: currentUid, currentItem: currentItems[0], items: items};
}

function profileSummary(path) {
  var document = parseProfilesDocument(readFile(path, false));
  var kinds = ["proxies", "groups", "rules", "merge"];
  var options = {};
  var missing = [];
  kinds.forEach(function (kind) {
    var value = document.currentItem.options[kind] || "";
    if (value && !new RegExp("^" + kind.charAt(0) + "[A-Za-z0-9]{11}$").test(value)) {
      throw new Error(kind + " uid 格式异常");
    }
    options[kind] = value;
    if (!value) missing.push(kind);
  });
  return JSON.stringify({
    schema: 1,
    current_uid: document.currentUid,
    current_type: document.currentItem.type,
    options: options,
    missing: missing,
    remote_count: document.items.filter(function (item) { return item.type === "remote"; }).length,
    url_present: document.currentItem.urlPresent,
    url_ready: document.currentItem.urlReady
  });
}

function profileRegister(argv) {
  if (argv.length !== 4) throw new Error("profile-register 参数错误");
  var path = argv[0];
  var kind = argv[1];
  var uid = argv[2];
  var updated = argv[3];
  var prefixes = {proxies: "p", groups: "g", rules: "r", merge: "m"};
  if (!own(prefixes, kind)) throw new Error("增强类型不受支持");
  if (!new RegExp("^" + prefixes[kind] + "[A-Za-z0-9]{11}$").test(uid)) throw new Error("增强 uid 格式错误");
  if (!/^[0-9]{9,12}$/.test(updated)) throw new Error("updated 时间戳格式错误");

  var original = readFile(path, false);
  var document = parseProfilesDocument(original);
  if (document.currentItem.type !== "remote") throw new Error("当前 profile 不是 remote，拒绝登记增强文件");
  var existingOption = document.currentItem.options[kind] || "";
  var existingItems = document.items.filter(function (item) { return item.uid === uid; });
  if (existingOption) {
    if (existingOption === uid && existingItems.length === 1 && existingItems[0].type === kind &&
        existingItems[0].file === uid + ".yaml") {
      return JSON.stringify({schema: 1, status: "unchanged", type: kind, uid: uid});
    }
    throw new Error("该增强类型已有不同 uid，拒绝覆盖");
  }
  if (existingItems.length) throw new Error("待注册 uid 已存在，拒绝重复");

  var lines = document.lines.slice();
  var current = document.currentItem;
  var optionInsert;
  if (current.optionLine === -1) {
    optionInsert = current.end;
    while (optionInsert > current.start + 1 && !lines[optionInsert - 1].replace(/^\s+|\s+$/g, "")) optionInsert -= 1;
    lines.splice(optionInsert, 0, current.propertyIndent + "option:",
      current.propertyIndent + "  " + kind + ": " + uid);
  } else {
    optionInsert = current.optionLine + 1;
    while (optionInsert < current.end) {
      var line = lines[optionInsert];
      if (!line.replace(/^\s+|\s+$/g, "")) {
        optionInsert += 1;
        continue;
      }
      if (line.indexOf(current.propertyIndent + "  ") !== 0) break;
      optionInsert += 1;
    }
    lines.splice(optionInsert, 0, current.propertyIndent + "  " + kind + ": " + uid);
  }

  var withOption = lines.join("\n");
  var updatedDocument = parseProfilesDocument(withOption);
  var itemInsert = updatedDocument.currentItem.start;
  var itemIndent = updatedDocument.currentItem.indent;
  var propertyIndent = itemIndent + "  ";
  lines = updatedDocument.lines;
  lines.splice(itemInsert, 0,
    itemIndent + "- uid: " + uid,
    propertyIndent + "type: " + kind,
    propertyIndent + "name: null",
    propertyIndent + "file: " + uid + ".yaml",
    propertyIndent + "updated: " + updated);

  var output = lines.join("\n");
  if (output.charAt(output.length - 1) !== "\n") output += "\n";
  if (readFile(path, false) !== original) throw new Error("profiles.yaml 在写入前发生变化，请重试");
  writeFileAtomic(path, output);
  return JSON.stringify({schema: 1, status: "registered", type: kind, uid: uid});
}

function staticServer(path) {
  var text = readFile(path, true);
  var match = text.match(/name:\s*"?[^"\n]*US-Static[^"\n]*"?[\s\S]{0,200}?server:\s*"?([A-Za-z0-9_.:\[\]-]+)"?/);
  return match ? match[1] : "";
}

function credentialsWrite(argv) {
  if (argv.length !== 4) throw new Error("credentials-write 参数错误");
  var path = argv[0];
  var node = argv[1];
  var start = argv[2];
  var end = argv[3];
  var fields = readStdin().split("\0");
  if (fields.length && fields[fields.length - 1] === "") fields.pop();
  if (fields.length !== 4) throw new Error("四元组输入格式错误");
  var host = fields[0];
  var port = fields[1];
  var username = fields[2];
  var password = fields[3];
  if (!host || !port || !username || !password) throw new Error("四项都不能为空");
  if (!/^[0-9]+$/.test(port)) throw new Error("端口必须是数字");
  var portNumber = Number(port);
  if (portNumber < 1 || portNumber > 65535 || Math.floor(portNumber) !== portNumber) {
    throw new Error("端口必须在 1..65535 之间");
  }
  port = String(portNumber);

  var block = [
    "  " + start,
    "  - name: " + JSON.stringify(node),
    "    type: socks5                      # 必须 socks5",
    "    server: " + JSON.stringify(host),
    "    port: " + port,
    "    username: " + JSON.stringify(username),
    "    password: " + JSON.stringify(password),
    "    udp: false                        # 必须 false：防 QUIC 漏流的一环",
    "    dialer-proxy: \"US-Chain\"          # 必须：先走机场美国节点再连静态 IP",
    "  " + end
  ].join("\n");
  var old = readFile(path, true);
  var output;
  var mode;
  var starts = markerMatches(old, start);
  var ends = markerMatches(old, end);
  if (starts.length || ends.length) {
    if (starts.length !== 1 || ends.length !== 1 || starts[0].index >= ends[0].index) {
      throw new Error("托管标记不完整、重复或顺序错误，拒绝修改");
    }
    var managed = new RegExp("^[ \\t]*" + escapeRegExp(start) + "[ \\t]*$[\\s\\S]*?" +
      "^[ \\t]*" + escapeRegExp(end) + "[ \\t]*$", "m");
    output = old.replace(managed, block);
    mode = "replace";
  } else {
    var meaningful = old.split(/\r?\n/).filter(function (line) {
      var value = line.replace(/^\s+|\s+$/g, "");
      return value && value.charAt(0) !== "#" &&
        ["prepend: []", "append: []", "delete: []", "prepend:", "append:", "delete:"].indexOf(value) === -1;
    });
    if (meaningful.length) return "MODE=conflict";
    output = "# 由 claude-lane 的 set-credentials.sh 写入；凭证只存在本机，切勿提交进任何 git 仓库\n" +
      "prepend: []\n\nappend:\n" + block + "\n\ndelete: []\n";
    mode = "create";
  }
  if (output.charAt(output.length - 1) !== "\n") output += "\n";
  writeFileAtomic(path, output);
  return "MODE=" + mode;
}

function validateManaged(path, node, start, end) {
  var text = readFile(path, false);
  var starts = markerMatches(text, start);
  var ends = markerMatches(text, end);
  if (starts.length !== 1 || ends.length !== 1 || starts[0].index >= ends[0].index) {
    throw new Error("托管标记不完整、重复或顺序错误");
  }
  var block = text.slice(starts[0].index, ends[0].end);
  var required = [
    /^\s*type:\s*socks5(?:\s|#|$)/m,
    /^\s*udp:\s*false(?:\s|#|$)/m,
    /^\s*dialer-proxy:\s*"US-Chain"(?:\s|#|$)/m
  ];
  for (var i = 0; i < required.length; i += 1) {
    if (!required[i].test(block)) throw new Error("托管块缺少必需字段");
  }
  ["name", "server", "username", "password"].forEach(function (key) {
    var prefix = key === "name" ? "(?:-\\s*)?" : "";
    var match = block.match(new RegExp("^\\s*" + prefix + key + ":\\s*(.+)$", "m"));
    if (!match) throw new Error("托管块缺少 " + key);
    parseJSON(match[1].replace(/^\s+|\s+$/g, ""), key);
  });
  var name = block.match(/^\s*(?:-\s*)?name:\s*(.+)$/m);
  if (!name || parseJSON(name[1].replace(/^\s+|\s+$/g, ""), "name") !== node) {
    throw new Error("节点名校验失败");
  }
  if (!/^\s*port:\s*[0-9]+\s*$/m.test(block)) throw new Error("端口校验失败");
  return "OK";
}

function managedName(path, start, end) {
  var text = readFile(path, true);
  if (!text) return "";
  var starts = markerMatches(text, start);
  var ends = markerMatches(text, end);
  if (!starts.length && !ends.length) return "";
  if (starts.length !== 1 || ends.length !== 1 || starts[0].index >= ends[0].index) {
    throw new Error("托管标记不完整、重复或顺序错误");
  }
  var block = text.slice(starts[0].index, ends[0].end);
  var name = block.match(/^\s*(?:-\s*)?name:\s*(.+)$/m);
  if (!name) throw new Error("托管块缺少 name");
  return parseJSON(name[1].replace(/^\s+|\s+$/g, ""), "name");
}

function jsonGet(path, key) {
  if (!fileExists(path)) return "";
  var text = readFile(path, false);
  if (!text) return "";
  var object;
  try {
    object = JSON.parse(text);
  } catch (error) {
    throw new Error("状态文件不是有效 JSON");
  }
  if (!object || typeof object !== "object" || Array.isArray(object)) {
    throw new Error("状态文件顶层必须是 JSON object");
  }
  var value = object;
  key.split(".").forEach(function (part) {
    value = value !== null && typeof value === "object" && own(value, part) ? value[part] : undefined;
  });
  if (value === undefined || value === null) return "";
  if (typeof value === "object") throw new Error("json-get 只允许读取标量字段");
  return String(value);
}

function stateUpdate(argv) {
  if (argv.length !== 1) throw new Error("state-update 参数错误");
  var path = argv[0];
  var fields = readStdin().split("\0");
  if (fields.length && fields[fields.length - 1] === "") fields.pop();
  if (fields.length !== 5) throw new Error("state-update 输入格式错误");
  var text = readFile(path, true);
  var state = {};
  if (text) {
    try {
      state = JSON.parse(text);
      if (!state || typeof state !== "object" || Array.isArray(state)) {
        throw new Error("已有状态文件顶层不是 JSON object");
      }
    } catch (error) {
      throw new Error("已有状态文件不是有效 JSON，拒绝覆盖");
    }
  }
  state.claude_exit_ip = fields[0];
  state.country = fields[1];
  state.clash_verge = fields[2];
  state.baseline_saved_at = fields[3];
  state.template_version = fields[4];
  if (!own(state, "installed_at")) state.installed_at = fields[3];
  writeFileAtomic(path, JSON.stringify(state, null, 2) + "\n");
  return "OK";
}

function verifyProxies() {
  var records = [];
  var root;
  try {
    root = JSON.parse(readStdin());
  } catch (error) {
    return "FAIL\tmihomo /proxies 返回无效 JSON（内核 API 异常）";
  }
  var data = root && root.proxies && typeof root.proxies === "object" ? root.proxies : {};
  var claude = data.Claude || {};
  if (String(claude.now || "").indexOf("US-Static") !== -1) {
    records.push("OK\tClaude 组 → " + displayText(claude.now));
  } else {
    records.push("FAIL\tClaude 组指向 " + displayText(claude.now || "undefined") + "（应指向静态节点）");
  }
  var chain = data["US-Chain"] || {};
  if (chain.now) records.push("OK\tUS-Chain 组 → " + displayText(chain.now));
  else records.push("FAIL\tUS-Chain 组不存在或未选节点");
  var wrong = [];
  Object.keys(data).forEach(function (name) {
    var proxy = data[name] || {};
    if (name !== "Claude" && String(proxy.now || "").indexOf("US-Static") !== -1) {
      wrong.push(displayText(name));
    }
  });
  if (wrong.length) records.push("FAIL\t这些组误选了静态节点（普通流量会走静态IP）: " + wrong.join(", "));
  else records.push("OK\t无其他组误用静态节点");
  return records.join("\n");
}

function proxyNames() {
  var root = parseJSON(readStdin(), "mihomo /proxies 响应");
  var proxies = root && root.proxies && typeof root.proxies === "object" ? root.proxies : {};
  return Object.keys(proxies).sort().map(displayText).join("\n");
}

function maskValue() {
  var value = readStdin();
  if (!value) return "";
  var safe = displayText(value);
  return safe.length <= 3 ? "***" : safe.slice(0, 3) + "***";
}


function displayValue() {
  return displayText(readStdin());
}

function validIpv4(value) {
  if (!/^[0-9]+(?:\.[0-9]+){3}$/.test(value)) return false;
  var parts = value.split(".");
  for (var i = 0; i < parts.length; i += 1) {
    if (parts[i].length > 3 || Number(parts[i]) > 255) return false;
  }
  return true;
}

function ipv6GroupCount(part) {
  if (!part) return 0;
  var groups = part.split(":");
  var count = 0;
  for (var i = 0; i < groups.length; i += 1) {
    if (!groups[i]) return -1;
    if (groups[i].indexOf(".") !== -1) {
      if (i !== groups.length - 1 || !validIpv4(groups[i])) return -1;
      count += 2;
    } else {
      if (!/^[0-9A-Fa-f]{1,4}$/.test(groups[i])) return -1;
      count += 1;
    }
  }
  return count;
}

function validIpv6(value) {
  if (!value || value.length > 45 || !/^[0-9A-Fa-f:.]+$/.test(value)) return false;
  var firstCompression = value.indexOf("::");
  if (firstCompression !== -1 && value.indexOf("::", firstCompression + 2) !== -1) return false;
  if (firstCompression === -1) return ipv6GroupCount(value) === 8;
  var left = ipv6GroupCount(value.slice(0, firstCompression));
  var right = ipv6GroupCount(value.slice(firstCompression + 2));
  return left >= 0 && right >= 0 && left + right < 8;
}

function validIpValue() {
  var value = readStdin().replace(/^\s+|\s+$/g, "");
  return validIpv4(value) || validIpv6(value) ? "YES" : "NO";
}

function verifyGeneratedConfig(path) {
  var text = readFile(path, false);
  var records = [];
  var mode = /^mode:\s*rule(?:\s*(?:#.*)?)?$/m.test(text);
  records.push(mode ? "OK\tClash 处于规则模式" : "FAIL\t生成配置不是 rule 模式");

  var lines = text.split(/\r?\n/);
  var tunEnabled = false;
  for (var i = 0; i < lines.length; i += 1) {
    if (!/^tun:\s*(?:#.*)?$/.test(lines[i])) continue;
    for (var j = i + 1; j < lines.length; j += 1) {
      if (/^[^ \t#][^:]*:/.test(lines[j])) break;
      if (/^[ \t]+enable:\s*true(?:\s*(?:#.*)?)?$/.test(lines[j])) tunEnabled = true;
    }
    break;
  }
  records.push(tunEnabled ? "OK\tTUN 已启用" : "FAIL\t生成配置没有启用 TUN");
  return records.join("\n");
}

function normalizedPayload(value) {
  return String(value || "").toLowerCase().replace(/\s+/g, "");
}

function payloadHasProcess(payload, processName) {
  var compact = normalizedPayload(payload);
  var name = processName.toLowerCase().replace(/\s+/g, "");
  return compact.indexOf("processname," + name + ")") !== -1 ||
    compact.indexOf("process-name," + name + ")") !== -1;
}

function isChromeQuicReject(rule, processName) {
  var payload = normalizedPayload(rule.payload);
  var udp = payload.indexOf("network,udp") !== -1;
  var port443 = payload.indexOf("dstport,443") !== -1 ||
    payload.indexOf("dst-port,443") !== -1;
  return rule.proxy === "REJECT" && payloadHasProcess(rule.payload, processName) && udp && port443;
}

function isProcessUdpReject(rule, processName) {
  var payload = normalizedPayload(rule.payload);
  return rule.proxy === "REJECT" && payloadHasProcess(rule.payload, processName) &&
    payload.indexOf("network,udp") !== -1;
}

function verifyRules() {
  var input = readStdin();
  var separator = input.indexOf("\0");
  var jsonText = separator < 0 ? input : input.slice(0, separator);
  var processText = separator < 0 ? "" : input.slice(separator + 1);
  var root;
  try {
    root = JSON.parse(jsonText);
  } catch (error) {
    return "FAIL\tmihomo /rules 返回无效 JSON（内核 API 异常）";
  }
  var rules = root && Array.isArray(root.rules) ? root.rules : [];
  var records = [];
  var head = rules.slice(0, 2);
  var chrome = head.some(function (rule) { return isChromeQuicReject(rule, "Google Chrome"); });
  var chromeHelper = head.some(function (rule) { return isChromeQuicReject(rule, "Google Chrome Helper"); });
  var chromeComplete = chrome && chromeHelper;
  records.push((chromeComplete ? "OK\t" : "FAIL\t") +
    (chromeComplete ? "Chrome / Helper QUIC 拦截在规则最前" :
      "规则前两条必须是 Chrome 与 Chrome Helper 的 UDP/443 拦截（漏流风险，检查模板③顺序）"));
  var globalReject = rules.some(function (rule) {
    var payload = normalizedPayload(rule.payload);
    var hasProcess = payload.indexOf("processname,") !== -1 || payload.indexOf("process-name,") !== -1;
    return rule.proxy === "REJECT" && payload.indexOf("udp") !== -1 &&
      payload.indexOf("443") !== -1 && !hasProcess;
  });
  records.push((globalReject ? "FAIL\t存在全局 UDP/443 REJECT（误伤全机 HTTP/3，应删除）" :
    "OK\t无全局 UDP/443 拦截"));
  var requiredDomains = ["anthropic.com", "claude.com", "claude.ai", "claudeusercontent.com"];
  var missingDomains = requiredDomains.filter(function (domain) {
    return !rules.some(function (rule) {
      return rule.type === "DomainSuffix" && rule.payload === domain && rule.proxy === "Claude";
    });
  });
  records.push(!missingDomains.length ? "OK\tClaude 核心域名规则完整且目标组正确" :
    "FAIL\t缺少指向 Claude 组的核心域名规则: " + missingDomains.join(", "));
  var telemetry = rules.some(function (rule) {
    return rule.type === "DomainSuffix" &&
      rule.payload === "http-intake.logs.us5.datadoghq.com" && rule.proxy === "Claude";
  });
  records.push(telemetry ? "OK\t遥测域名规则存在" :
    "FAIL\t缺遥测域名规则（DOMAIN-SUFFIX,http-intake.logs.us5.datadoghq.com,Claude）——进程规则抓不到它，会漏到默认节点，见排障手册第 9 条");

  var cidr = rules.some(function (rule) {
    var type = String(rule.type || "").toLowerCase().replace(/-/g, "");
    return type === "ipcidr" && rule.payload === "160.79.104.0/23" && rule.proxy === "Claude";
  });
  records.push(cidr ? "OK\tAnthropic IP 段兜底规则存在" :
    "FAIL\t缺 IP-CIDR,160.79.104.0/23,Claude 兜底规则");

  var runningMap = {};
  processText.split(/\r?\n/).forEach(function (line) {
    var parts = line.split("/");
    var name = parts[parts.length - 1].replace(/^\s+|\s+$/g, "");
    if (name.toLowerCase().indexOf("claude") !== -1) runningMap[name] = true;
  });
  var running = Object.keys(runningMap).sort();
  var ruled = {};
  rules.forEach(function (rule) {
    if (rule.type === "ProcessName" && rule.proxy === "Claude") ruled[String(rule.payload || "")] = true;
  });
  var missing = running.filter(function (name) { return !ruled[name]; });
  var requiredProcesses = [
    "Claude", "Claude Helper", "Claude Helper (GPU)", "Claude Helper (Renderer)",
    "Claude Helper (Plugin)", "claude", "claude.exe"
  ];
  var missingConfigured = requiredProcesses.filter(function (name) { return !ruled[name]; });
  if (missingConfigured.length) {
    records.push("FAIL\t缺少指向 Claude 组的进程规则: " + missingConfigured.join(", "));
  } else {
    records.push("OK\t桌面版与 Claude Code 进程规则完整");
  }
  var missingUdpRejects = requiredProcesses.filter(function (name) {
    return !rules.some(function (rule) { return isProcessUdpReject(rule, name); });
  });
  if (missingUdpRejects.length) {
    records.push("FAIL\t缺少 Claude 进程 UDP 拦截: " + missingUdpRejects.join(", "));
  } else {
    records.push("OK\tClaude 全家 UDP 拦截规则完整");
  }
  if (!running.length) {
    records.push("WARN\t当前没有 Claude 进程在跑，跳过进程规则核对（开着 Claude 再跑一次更准）");
  } else if (missing.length) {
    records.push("FAIL\t这些正在运行的 Claude 进程没有指向 Claude 组的规则（遥测会漏到默认节点）: " +
      missing.map(displayText).join(", "));
  } else {
    records.push("OK\t在跑的 Claude 进程都有对应规则（" + running.map(displayText).join(", ") + "）");
  }
  return records.join("\n");
}

function assertJSONScalars(path, keys) {
  var expected = readStdin().split("\0");
  if (expected.length && expected[expected.length - 1] === "") expected.pop();
  if (expected.length !== keys.length) throw new Error("期望值数量不匹配");
  var text = readFile(path, false);
  keys.forEach(function (key, index) {
    var match = text.match(new RegExp("^\\s*" + escapeRegExp(key) + ":\\s*(.+)$", "m"));
    if (!match) throw new Error("找不到字段：" + key);
    var actual = parseJSON(match[1].replace(/^\s+|\s+$/g, ""), key);
    if (actual !== expected[index]) throw new Error("字段值不一致：" + key);
  });
  return "OK";
}

function run(argv) {
  if (!argv.length) throw new Error("缺少子命令");
  var command = argv.shift();
  switch (command) {
    case "profile-proxies": return profileProxies(argv[0]);
    case "profile-summary": return profileSummary(argv[0]);
    case "profile-register": return profileRegister(argv);
    case "static-server": return staticServer(argv[0]);
    case "credentials-write": return credentialsWrite(argv);
    case "validate-managed": return validateManaged(argv[0], argv[1], argv[2], argv[3]);
    case "managed-name": return managedName(argv[0], argv[1], argv[2]);
    case "json-get": return jsonGet(argv[0], argv[1]);
    case "state-update": return stateUpdate(argv);
    case "verify-proxies": return verifyProxies();
    case "proxy-names": return proxyNames();
    case "verify-rules": return verifyRules();
    case "mask-value": return maskValue();
    case "display-value": return displayValue();
    case "valid-ip": return validIpValue();
    case "verify-config": return verifyGeneratedConfig(argv[0]);
    case "assert-json-scalars": return assertJSONScalars(argv.shift(), argv);
    default: throw new Error("未知子命令：" + command);
  }
}
