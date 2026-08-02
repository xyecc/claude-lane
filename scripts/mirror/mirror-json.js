// macOS JXA helper for publisher-side GitHub metadata. No Node/Python needed.
ObjC.import("Foundation");

function readFile(path) {
  var data = $.NSFileManager.defaultManager.contentsAtPath($(path));
  if (!data) throw new Error("file not found: " + path);
  var text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
  if (!text) throw new Error("invalid UTF-8: " + path);
  return ObjC.unwrap(text);
}

function safeField(value) {
  var text = String(value === undefined || value === null ? "" : value);
  if (/[\u0000-\u001f\u007f\t\r\n]/.test(text)) throw new Error("unsafe metadata field");
  return text;
}

function githubRelease(path) {
  var release = JSON.parse(readFile(path));
  return [
    safeField(release.tag_name),
    release.draft ? "true" : "false",
    release.prerelease ? "true" : "false",
    safeField(release.published_at),
    safeField(release.html_url)
  ].join("\t");
}

function githubAsset(path, name) {
  var release = JSON.parse(readFile(path));
  var matches = (release.assets || []).filter(function (asset) { return asset.name === name; });
  if (matches.length !== 1) throw new Error("asset is missing or ambiguous: " + name);
  var asset = matches[0];
  var digest = safeField(asset.digest);
  if (!/^sha256:[0-9a-f]{64}$/.test(digest)) throw new Error("asset has no trusted SHA-256 digest: " + name);
  return [
    safeField(asset.name),
    String(asset.size),
    digest.slice(7),
    safeField(asset.browser_download_url),
    safeField(asset.created_at),
    safeField(asset.updated_at)
  ].join("\t");
}

function run(argv) {
  var command = argv.shift();
  if (command === "github-release") return githubRelease(argv[0]);
  if (command === "github-asset") return githubAsset(argv[0], argv[1]);
  throw new Error("unknown command");
}
