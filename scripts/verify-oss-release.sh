#!/bin/bash
# Validate the private Alibaba Cloud OSS release lane without printing credentials.
#
# Default: read ../.env and run a live least-privilege check.
#   bash scripts/verify-oss-release.sh
#
# Offline implementation check (does not read .env or access the network):
#   bash scripts/verify-oss-release.sh --self-test

set -u
set -o pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

OSS_ACCESS_KEY_ID=""
OSS_ACCESS_KEY_SECRET=""
OSS_BUCKET=""
OSS_REGION=""
OSS_ENDPOINT=""
CONFIG_ERROR=""
FAIL=0

ok()   { printf '  \033[32m✅ %s\033[0m\n' "$1"; }
bad()  { printf '  \033[31m❌ %s\033[0m\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '     %s\n' "$1"; }

usage() {
  printf '%s\n' '用法：'
  printf '%s\n' '  bash scripts/verify-oss-release.sh'
  printf '%s\n' '  bash scripts/verify-oss-release.sh --self-test'
}

strip_optional_quotes() {
  local value="$1" first last length
  length=${#value}
  if [ "$length" -ge 2 ]; then
    first=${value%"${value#?}"}
    last=${value#"${value%?}"}
    if { [ "$first" = '"' ] && [ "$last" = '"' ]; } ||
       { [ "$first" = "'" ] && [ "$last" = "'" ]; }; then
      value=${value#?}
      value=${value%?}
    fi
  fi
  printf '%s' "$value"
}

load_config() {
  local file="$1" line key value seen_id=0 seen_secret=0 seen_bucket=0 seen_region=0 seen_endpoint=0
  CONFIG_ERROR=""
  OSS_ACCESS_KEY_ID=""
  OSS_ACCESS_KEY_SECRET=""
  OSS_BUCKET=""
  OSS_REGION=""
  OSS_ENDPOINT=""

  if [ ! -f "$file" ]; then
    CONFIG_ERROR="找不到本地凭据文件 .env"
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) CONFIG_ERROR=".env 含无法识别的行"; return 1 ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    value=$(strip_optional_quotes "$value")
    case "$key" in
      CLAUDE_LANE_OSS_ACCESS_KEY_ID)
        [ "$seen_id" -eq 0 ] || { CONFIG_ERROR=".env 重复定义 AccessKey ID"; return 1; }
        OSS_ACCESS_KEY_ID=$value; seen_id=1 ;;
      CLAUDE_LANE_OSS_ACCESS_KEY_SECRET)
        [ "$seen_secret" -eq 0 ] || { CONFIG_ERROR=".env 重复定义 AccessKey Secret"; return 1; }
        OSS_ACCESS_KEY_SECRET=$value; seen_secret=1 ;;
      CLAUDE_LANE_OSS_BUCKET)
        [ "$seen_bucket" -eq 0 ] || { CONFIG_ERROR=".env 重复定义 Bucket"; return 1; }
        OSS_BUCKET=$value; seen_bucket=1 ;;
      CLAUDE_LANE_OSS_REGION)
        [ "$seen_region" -eq 0 ] || { CONFIG_ERROR=".env 重复定义 Region"; return 1; }
        OSS_REGION=$value; seen_region=1 ;;
      CLAUDE_LANE_OSS_ENDPOINT)
        [ "$seen_endpoint" -eq 0 ] || { CONFIG_ERROR=".env 重复定义 Endpoint"; return 1; }
        OSS_ENDPOINT=$value; seen_endpoint=1 ;;
      CLAUDE_LANE_BACKUP_OSS_ACCESS_KEY_ID|CLAUDE_LANE_BACKUP_OSS_ACCESS_KEY_SECRET|CLAUDE_LANE_BACKUP_OSS_BUCKET|CLAUDE_LANE_BACKUP_OSS_REGION|CLAUDE_LANE_BACKUP_OSS_ENDPOINT)
        # Backup credentials are consumed only by scripts/mirror/upload.sh.
        # Accept the known names without loading their values in this primary check.
        ;;
      *) CONFIG_ERROR=".env 含不受支持的变量：$key"; return 1 ;;
    esac
  done < "$file"

  [ -n "$OSS_ACCESS_KEY_ID" ] || { CONFIG_ERROR="AccessKey ID 尚未填写"; return 1; }
  [ -n "$OSS_ACCESS_KEY_SECRET" ] || { CONFIG_ERROR="AccessKey Secret 尚未填写"; return 1; }
  [ -n "$OSS_BUCKET" ] || { CONFIG_ERROR="Bucket 尚未填写"; return 1; }
  [ -n "$OSS_REGION" ] || { CONFIG_ERROR="Region 尚未填写"; return 1; }
  [ -n "$OSS_ENDPOINT" ] || { CONFIG_ERROR="Endpoint 尚未填写"; return 1; }

  case "$OSS_ACCESS_KEY_ID$OSS_ACCESS_KEY_SECRET" in
    *[[:space:]]*) CONFIG_ERROR="AccessKey 含空白字符，请检查复制结果"; return 1 ;;
  esac
  printf '%s' "$OSS_BUCKET" | grep -Eq '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' || {
    CONFIG_ERROR="Bucket 名称格式无效"; return 1;
  }
  case "$OSS_REGION" in
    oss-[a-z0-9-]*) ;;
    *) CONFIG_ERROR="Region 格式无效"; return 1 ;;
  esac
  case "$OSS_ENDPOINT" in
    https://*.*) ;;
    *) CONFIG_ERROR="Endpoint 必须是 HTTPS OSS 域名"; return 1 ;;
  esac
  case "${OSS_ENDPOINT#https://}" in
    */*) CONFIG_ERROR="Endpoint 不应包含路径"; return 1 ;;
  esac
  return 0
}

sign_v1() {
  local method="$1" content_type="$2" date_value="$3" canonical_resource="$4" string_to_sign
  string_to_sign=$(printf '%s\n\n%s\n%s\n%s' \
    "$method" "$content_type" "$date_value" "$canonical_resource")
  printf '%s' "$string_to_sign" |
    OSS_SIGNING_SECRET="$OSS_ACCESS_KEY_SECRET" \
    /usr/bin/perl -MDigest::SHA=hmac_sha1_base64 -0777 -ne \
      'print hmac_sha1_base64($_, $ENV{"OSS_SIGNING_SECRET"}), "="'
}

extract_error_code() {
  local response_file="$1"
  sed -n 's:.*<Code>\([^<]*\)</Code>.*:\1:p' "$response_file" 2>/dev/null | head -1
}

REQUEST_COUNT=0
HTTP_STATUS=""
OSS_ERROR_CODE=""
request_oss() {
  local method="$1" object_key="$2" content_type="$3" body_file="$4" response_file="$5"
  local date_value canonical_resource signature endpoint_host url config_file curl_error
  REQUEST_COUNT=$((REQUEST_COUNT + 1))
  date_value=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')
  canonical_resource="/$OSS_BUCKET/$object_key"
  signature=$(sign_v1 "$method" "$content_type" "$date_value" "$canonical_resource") || return 1
  endpoint_host=${OSS_ENDPOINT#https://}
  endpoint_host=${endpoint_host%/}
  url="https://$OSS_BUCKET.$endpoint_host/$object_key"
  config_file="$TMP/request-$REQUEST_COUNT.conf"
  curl_error="$TMP/request-$REQUEST_COUNT.stderr"

  {
    printf 'silent\n'
    printf 'show-error\n'
    printf 'connect-timeout = 10\n'
    printf 'max-time = 30\n'
    printf 'request = "%s"\n' "$method"
    printf 'url = "%s"\n' "$url"
    printf 'output = "%s"\n' "$response_file"
    printf 'write-out = "%%{http_code}"\n'
    printf 'header = "Date: %s"\n' "$date_value"
    printf 'header = "Authorization: OSS %s:%s"\n' "$OSS_ACCESS_KEY_ID" "$signature"
    if [ -n "$content_type" ]; then
      printf 'header = "Content-Type: %s"\n' "$content_type"
    fi
    if [ -n "$body_file" ]; then
      printf 'data-binary = "@%s"\n' "$body_file"
    fi
  } > "$config_file"

  HTTP_STATUS=$(curl --config "$config_file" 2>"$curl_error")
  if [ "$?" -ne 0 ]; then
    HTTP_STATUS="network-error"
    OSS_ERROR_CODE=""
    return 1
  fi
  OSS_ERROR_CODE=$(extract_error_code "$response_file")
  return 0
}

self_test() {
  local test_signature test_env
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  OSS_ACCESS_KEY_SECRET="Jefe"
  test_signature=$(printf '%s' 'what do ya want for nothing?' |
    OSS_SIGNING_SECRET="$OSS_ACCESS_KEY_SECRET" \
    /usr/bin/perl -MDigest::SHA=hmac_sha1_base64 -0777 -ne \
      'print hmac_sha1_base64($_, $ENV{"OSS_SIGNING_SECRET"}), "="')
  if [ "$test_signature" = '7/zfauXrL6LSdBbV8YTfnCWafHk=' ]; then
    ok "HMAC-SHA1 签名实现通过标准向量"
  else
    bad "HMAC-SHA1 签名实现不正确"
  fi

  test_env="$TMP/test.env"
  {
    printf '%s\n' 'CLAUDE_LANE_OSS_ACCESS_KEY_ID=test-id'
    printf '%s\n' 'CLAUDE_LANE_OSS_ACCESS_KEY_SECRET=test-secret'
    printf '%s\n' 'CLAUDE_LANE_OSS_BUCKET=test-release-bucket'
    printf '%s\n' 'CLAUDE_LANE_OSS_REGION=oss-cn-beijing'
    printf '%s\n' 'CLAUDE_LANE_OSS_ENDPOINT=https://oss-cn-beijing.aliyuncs.com'
  } > "$test_env"
  if load_config "$test_env" &&
     [ "$OSS_BUCKET" = "test-release-bucket" ] &&
     [ "$OSS_REGION" = "oss-cn-beijing" ]; then
    ok "dotenv 严格解析通过"
  else
    bad "dotenv 严格解析失败"
  fi

  if printf '%s\n' 'UNEXPECTED_KEY=value' >> "$test_env" && load_config "$test_env"; then
    bad "dotenv 未拒绝未知变量"
  else
    ok "dotenv 对未知变量失败关闭"
  fi

  if [ "$FAIL" -eq 0 ]; then
    printf '\n\033[32m离线自测通过。\033[0m\n'
    return 0
  fi
  printf '\n\033[31m离线自测失败：%s 项。\033[0m\n' "$FAIL"
  return 1
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
  printf '\033[31m本脚本当前只在 macOS 上验证。\033[0m\n'
  exit 1
fi
for required in curl grep cmp sed /usr/bin/perl; do
  if ! command -v "$required" >/dev/null 2>&1; then
    printf '\033[31m缺少运行依赖：%s\033[0m\n' "$required"
    exit 1
  fi
done
if ! /usr/bin/perl -MDigest::SHA=hmac_sha1_base64 -e 'exit 0' 2>/dev/null; then
  printf '\033[31m系统 Perl 缺少 Digest::SHA，无法安全签名 OSS 请求。\033[0m\n'
  exit 1
fi

ENV_MODE=$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || true)
if [ "$ENV_MODE" != "600" ]; then
  printf '\033[31m.env 权限必须是 600；先执行 chmod 600 .env。\033[0m\n'
  exit 1
fi
if ! load_config "$ENV_FILE"; then
  printf '\033[31mOSS 配置无效：%s。\033[0m\n' "$CONFIG_ERROR"
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PAYLOAD="$TMP/payload.txt"
GET_BODY="$TMP/get-body.txt"
VALIDATION_KEY="claude-lane/releases/_validation/oss-access-check.txt"
FORBIDDEN_KEY="outside-allowed-prefix/oss-access-check.txt"
printf '%s\n' 'claude-lane OSS permission validation' > "$PAYLOAD"

printf '== 私有 OSS 最小权限验证 ==\n'
printf '   Bucket、Region、Endpoint 已从本地 .env 载入；凭据不会输出。\n\n'

if request_oss PUT "$VALIDATION_KEY" text/plain "$PAYLOAD" "$TMP/put.xml" &&
   [ "$HTTP_STATUS" = "200" ]; then
  ok "允许目录上传成功"
else
  bad "允许目录上传失败（HTTP $HTTP_STATUS${OSS_ERROR_CODE:+, $OSS_ERROR_CODE}）"
fi

if request_oss GET "$VALIDATION_KEY" "" "" "$GET_BODY" &&
   [ "$HTTP_STATUS" = "200" ] && cmp -s "$PAYLOAD" "$GET_BODY"; then
  ok "允许目录读取与内容校验成功"
else
  bad "允许目录读取失败或内容不一致（HTTP $HTTP_STATUS${OSS_ERROR_CODE:+, $OSS_ERROR_CODE}）"
fi

if request_oss PUT "$FORBIDDEN_KEY" text/plain "$PAYLOAD" "$TMP/forbidden-put.xml" &&
   [ "$HTTP_STATUS" = "403" ]; then
  ok "目录外上传被拒绝"
else
  bad "目录外上传没有按预期拒绝（HTTP $HTTP_STATUS${OSS_ERROR_CODE:+, $OSS_ERROR_CODE}）"
fi

if request_oss DELETE "$VALIDATION_KEY" "" "" "$TMP/delete.xml" &&
   [ "$HTTP_STATUS" = "403" ]; then
  ok "删除操作被拒绝"
else
  bad "删除操作没有按预期拒绝（HTTP $HTTP_STATUS${OSS_ERROR_CODE:+, $OSS_ERROR_CODE}）"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mOSS 最小权限验证通过：上传/读取可用，越权上传/删除均被拒绝。\033[0m\n'
  note "保留的固定验证对象：$VALIDATION_KEY"
  exit 0
fi
printf '\033[31mOSS 最小权限验证失败：%s 项。未修改 manifest 或正式制品。\033[0m\n' "$FAIL"
exit 1
