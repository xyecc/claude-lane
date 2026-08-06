#!/bin/bash

# Immutable public-release Alibaba OSS uploader. Dry-run by default;
# credentials never appear in argv/output and each new object is public-read.

set -u
set -o pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

PROFILE=primary
ENV_FILE="$MIRROR_REPO_ROOT/.env"
SINGLE_FILE=""
SINGLE_KEY=""
UPLOAD_SCOPE=all
CANDIDATE_ID=""
CANDIDATE_DIR=""
OSS_ACCESS_KEY_ID=""
OSS_ACCESS_KEY_SECRET=""
OSS_BUCKET=""
OSS_ENDPOINT=""
TMP=""
REQUEST_ID=0
HTTP_STATUS=""

usage() {
  printf '%s\n' '用法：bash scripts/mirror/upload.sh [--execute] [--profile primary|backup] [--scope all|upstream|lane|bootstrap|candidate] [--candidate-id <git-id>] [--candidate-dir <path>] [--env-file <path>] [--file <path> --key <object>]'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --execute) MIRROR_EXECUTE=1 ;;
    --profile) [ "$#" -ge 2 ] || mirror_die "--profile requires a value"; PROFILE=$2; shift ;;
    --env-file) [ "$#" -ge 2 ] || mirror_die "--env-file requires a value"; ENV_FILE=$2; shift ;;
    --file) [ "$#" -ge 2 ] || mirror_die "--file requires a value"; SINGLE_FILE=$2; shift ;;
    --key) [ "$#" -ge 2 ] || mirror_die "--key requires a value"; SINGLE_KEY=$2; shift ;;
    --scope) [ "$#" -ge 2 ] || mirror_die "--scope requires a value"; UPLOAD_SCOPE=$2; shift ;;
    --candidate-id) [ "$#" -ge 2 ] || mirror_die "--candidate-id requires a value"; CANDIDATE_ID=$2; shift ;;
    --candidate-dir) [ "$#" -ge 2 ] || mirror_die "--candidate-dir requires a value"; CANDIDATE_DIR=$2; shift ;;
    --work-dir) [ "$#" -ge 2 ] || mirror_die "--work-dir requires a value"; MIRROR_WORK_DIR=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) mirror_die "unknown argument: $1" ;;
  esac
  shift
done
[ "$PROFILE" = primary ] || [ "$PROFILE" = backup ] || mirror_die "profile must be primary or backup"
[ "$UPLOAD_SCOPE" = all ] || [ "$UPLOAD_SCOPE" = upstream ] || [ "$UPLOAD_SCOPE" = lane ] || [ "$UPLOAD_SCOPE" = bootstrap ] || [ "$UPLOAD_SCOPE" = candidate ] || mirror_die "scope must be all, upstream, lane, bootstrap, or candidate"
if [ "$UPLOAD_SCOPE" = candidate ]; then
  printf '%s' "$CANDIDATE_ID" | LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{7,40}$' || mirror_die "candidate scope requires --candidate-id"
  [ -n "$CANDIDATE_DIR" ] || CANDIDATE_DIR="$MIRROR_WORK_DIR/candidates/$CANDIDATE_ID"
fi
if [ -n "$SINGLE_FILE$SINGLE_KEY" ]; then [ -n "$SINGLE_FILE" ] && [ -n "$SINGLE_KEY" ] || mirror_die "--file and --key must be used together"; fi

valid_key() {
  printf '%s' "$1" | LC_ALL=C /usr/bin/grep -Eq '^(claude-lane|claude-code|clash-verge)/releases/[A-Za-z0-9._/-]+$|^claude-lane/candidates/[A-Za-z0-9._/-]+$|^manifests/[A-Za-z0-9._/-]+$' || return 1
  printf '%s' "$1" | LC_ALL=C /usr/bin/grep -Eq '(^|/)\.\.(/|$)' && return 1
  return 0
}

if [ "$MIRROR_EXECUTE" != "1" ]; then
  mirror_say "dry-run: immutable upload to $PROFILE storage; existing keys will not be overwritten"
  [ -z "$SINGLE_KEY" ] || { valid_key "$SINGLE_KEY" || mirror_die "invalid object key"; mirror_say "would upload $SINGLE_FILE -> $SINGLE_KEY"; }
  exit 0
fi

mirror_require curl
mirror_require perl
[ -f "$ENV_FILE" ] || mirror_die "credential file missing: $ENV_FILE"
[ "$(/usr/bin/stat -f '%Lp' "$ENV_FILE" 2>/dev/null)" = 600 ] || mirror_die "credential file permissions must be 600"

while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in ''|'#'*) continue ;; *=*) ;; *) mirror_die "credential file contains an invalid line" ;; esac
  key=${line%%=*}; value=${line#*=}
  case "$value" in \"*\") value=${value#\"}; value=${value%\"} ;; \'*\') value=${value#\'}; value=${value%\'} ;; esac
  case "$key" in
    CLAUDE_LANE_OSS_ACCESS_KEY_ID) [ "$PROFILE" = primary ] && OSS_ACCESS_KEY_ID=$value ;;
    CLAUDE_LANE_OSS_ACCESS_KEY_SECRET) [ "$PROFILE" = primary ] && OSS_ACCESS_KEY_SECRET=$value ;;
    CLAUDE_LANE_OSS_BUCKET) [ "$PROFILE" = primary ] && OSS_BUCKET=$value ;;
    CLAUDE_LANE_OSS_ENDPOINT) [ "$PROFILE" = primary ] && OSS_ENDPOINT=$value ;;
    CLAUDE_LANE_BACKUP_OSS_ACCESS_KEY_ID) [ "$PROFILE" = backup ] && OSS_ACCESS_KEY_ID=$value ;;
    CLAUDE_LANE_BACKUP_OSS_ACCESS_KEY_SECRET) [ "$PROFILE" = backup ] && OSS_ACCESS_KEY_SECRET=$value ;;
    CLAUDE_LANE_BACKUP_OSS_BUCKET) [ "$PROFILE" = backup ] && OSS_BUCKET=$value ;;
    CLAUDE_LANE_BACKUP_OSS_ENDPOINT) [ "$PROFILE" = backup ] && OSS_ENDPOINT=$value ;;
    CLAUDE_LANE_OSS_REGION|CLAUDE_LANE_BACKUP_OSS_REGION) ;;
    *) mirror_die "credential file contains an unsupported variable" ;;
  esac
done < "$ENV_FILE"
[ -n "$OSS_ACCESS_KEY_ID" ] && [ -n "$OSS_ACCESS_KEY_SECRET" ] && [ -n "$OSS_BUCKET" ] && [ -n "$OSS_ENDPOINT" ] || mirror_die "$PROFILE storage credentials are incomplete"
case "$OSS_ENDPOINT" in https://*.*) ;; *) mirror_die "OSS endpoint must use HTTPS" ;; esac

TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/claude-lane-upload.XXXXXX") || mirror_die "cannot create upload temp directory"
cleanup_upload() { [ -z "$TMP" ] || /bin/rm -rf -- "$TMP" 2>/dev/null || true; OSS_ACCESS_KEY_SECRET=""; }
trap cleanup_upload EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

sign_v1() {
  method=$1; content_type=$2; date_value=$3; expected_sha=$4; canonical_resource=$5
  if [ "$method" = PUT ]; then
    printf '%s\n\n%s\n%s\nx-oss-forbid-overwrite:true\nx-oss-meta-sha256:%s\nx-oss-object-acl:public-read\n%s' "$method" "$content_type" "$date_value" "$expected_sha" "$canonical_resource"
  else
    printf '%s\n\n%s\n%s\n%s' "$method" "$content_type" "$date_value" "$canonical_resource"
  fi |
    OSS_SIGNING_SECRET="$OSS_ACCESS_KEY_SECRET" /usr/bin/perl -MDigest::SHA=hmac_sha1_base64 -0777 -ne 'print hmac_sha1_base64($_, $ENV{"OSS_SIGNING_SECRET"}), "="'
}

oss_request() {
  method=$1; object_key=$2; input_file=$3; output_file=$4; expected_sha=${5:-}
  REQUEST_ID=$((REQUEST_ID + 1))
  date_value=$(LC_ALL=C /bin/date -u '+%a, %d %b %Y %H:%M:%S GMT')
  content_type=""
  if [ "$method" = PUT ]; then
    content_type=application/octet-stream
  fi
  signature=$(sign_v1 "$method" "$content_type" "$date_value" "$expected_sha" "/$OSS_BUCKET/$object_key") || return 1
  endpoint_host=${OSS_ENDPOINT#https://}; endpoint_host=${endpoint_host%/}
  config="$TMP/request-$REQUEST_ID.conf"
  {
    printf '%s\n' 'silent' 'show-error' 'proto = "=https"' 'tlsv1.2' 'connect-timeout = 10' 'max-time = 1800'
    printf 'request = "%s"\nurl = "https://%s.%s/%s"\noutput = "%s"\nwrite-out = "%%{http_code}"\n' "$method" "$OSS_BUCKET" "$endpoint_host" "$object_key" "$output_file"
    printf 'header = "Date: %s"\nheader = "Authorization: OSS %s:%s"\n' "$date_value" "$OSS_ACCESS_KEY_ID" "$signature"
    if [ "$method" = PUT ]; then
      printf 'header = "Content-Type: %s"\nheader = "x-oss-forbid-overwrite: true"\nheader = "x-oss-meta-sha256: %s"\nheader = "x-oss-object-acl: public-read"\ndata-binary = "@%s"\n' "$content_type" "$expected_sha" "$input_file"
    fi
  } > "$config"
  /bin/chmod 600 "$config"
  HTTP_STATUS=$(/usr/bin/curl -q --config "$config" 2>"$TMP/curl-$REQUEST_ID.err") || HTTP_STATUS=network-error
}

upload_one() {
  local_file=$1; object_key=$2
  [ -f "$local_file" ] || mirror_die "missing upload file: $local_file"
  valid_key "$object_key" || mirror_die "invalid object key: $object_key"
  sha=$(mirror_sha256 "$local_file") || mirror_die "cannot hash upload file"
  existing="$TMP/existing-$REQUEST_ID"
  oss_request GET "$object_key" "" "$existing" || true
  case "$HTTP_STATUS" in
    200)
      [ "$(mirror_sha256 "$existing")" = "$sha" ] || mirror_die "immutable key already exists with different content: $object_key"
      mirror_say "reuse identical immutable object: $object_key"
      return 0
      ;;
    404) ;;
    *) mirror_die "cannot determine whether object exists (HTTP $HTTP_STATUS): $object_key" ;;
  esac
  oss_request PUT "$object_key" "$local_file" "$TMP/put-$REQUEST_ID.xml" "$sha" || true
  [ "$HTTP_STATUS" = 200 ] || mirror_die "upload failed (HTTP $HTTP_STATUS): $object_key"
  mirror_say "uploaded immutable object: $object_key"
}

if [ -n "$SINGLE_FILE" ]; then
  upload_one "$SINGLE_FILE" "$SINGLE_KEY"
  exit 0
fi

if [ "$UPLOAD_SCOPE" = candidate ]; then
  upload_one "$CANDIDATE_DIR/manifests/stable.candidate.json" "manifests/candidates/$CANDIDATE_ID.json"
  upload_one "$CANDIDATE_DIR/claude-lane/releases/v1.3.0/claude-lane.tar.gz" "claude-lane/candidates/$CANDIDATE_ID/claude-lane.tar.gz"
  upload_one "$CANDIDATE_DIR/claude-lane/releases/v1.3.0/claude-lane.zip" "claude-lane/candidates/$CANDIDATE_ID/claude-lane.zip"
  upload_one "$CANDIDATE_DIR/bootstrap/install.sh" "claude-lane/candidates/$CANDIDATE_ID/install.sh"
  upload_one "$CANDIDATE_DIR/bootstrap/install.ps1" "claude-lane/candidates/$CANDIDATE_ID/install.ps1"
  upload_one "$CANDIDATE_DIR/bootstrap/evidence.txt" "claude-lane/candidates/$CANDIDATE_ID/evidence.txt"
  mirror_say "candidate upload complete; stable objects were not touched"
  exit 0
fi

MANIFEST="$MIRROR_REPO_ROOT/manifests/stable.json"
CLASH_VERSION=$(/usr/bin/plutil -extract clash_verge.version raw -o - "$MANIFEST")
CLASH_DIR="$MIRROR_WORK_DIR/clash-verge/releases/v$CLASH_VERSION"
if [ "$UPLOAD_SCOPE" = all ] || [ "$UPLOAD_SCOPE" = upstream ]; then
for name in "Clash.Verge_${CLASH_VERSION}_aarch64.dmg" "Clash.Verge_${CLASH_VERSION}_x64.dmg" "Clash.Verge_${CLASH_VERSION}_arm64-setup.exe" "Clash.Verge_${CLASH_VERSION}_arm64-setup.exe.sig" "Clash.Verge_${CLASH_VERSION}_x64-setup.exe" "Clash.Verge_${CLASH_VERSION}_x64-setup.exe.sig" LICENSE SOURCE.txt; do
  upload_one "$CLASH_DIR/$name" "clash-verge/releases/v$CLASH_VERSION/$name"
done
fi
if [ "$UPLOAD_SCOPE" = all ] || [ "$UPLOAD_SCOPE" = lane ]; then
  LANE_VERSION=$(/usr/bin/plutil -extract claude_lane.version raw -o - "$MANIFEST")
  LANE_DIR="$MIRROR_WORK_DIR/claude-lane/releases/v$LANE_VERSION"
  upload_one "$LANE_DIR/claude-lane.tar.gz" "claude-lane/releases/v$LANE_VERSION/claude-lane.tar.gz"
  upload_one "$LANE_DIR/claude-lane.zip" "claude-lane/releases/v$LANE_VERSION/claude-lane.zip"
fi
if [ "$UPLOAD_SCOPE" = all ] || [ "$UPLOAD_SCOPE" = bootstrap ]; then
  upload_one "$MIRROR_REPO_ROOT/bootstrap.sh" "claude-lane/releases/bootstrap/v1/install.sh"
  upload_one "$MIRROR_REPO_ROOT/bootstrap.ps1" "claude-lane/releases/bootstrap/v1/install.ps1"
fi
mirror_say "artifact upload complete; stable manifest was not uploaded"
