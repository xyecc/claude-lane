#!/bin/bash

# Recalculate local artifact metadata into a candidate manifest. Never promotes stable.

set -u
set -o pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

OUTPUT=""
TEMPLATE="$MIRROR_REPO_ROOT/manifests/stable.json"
RELEASE_STATUS=blocked
CANDIDATE_ID=""

usage() {
  printf '%s\n' '用法：bash scripts/mirror/generate-manifest.sh [--execute] [--output <path>] [--work-dir <path>] [--status blocked|candidate] [--candidate-id <git-id>]'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --execute) MIRROR_EXECUTE=1 ;;
    --output) [ "$#" -ge 2 ] || mirror_die "--output requires a value"; OUTPUT=$2; shift ;;
    --work-dir) [ "$#" -ge 2 ] || mirror_die "--work-dir requires a value"; MIRROR_WORK_DIR=$2; shift ;;
    --status) [ "$#" -ge 2 ] || mirror_die "--status requires a value"; RELEASE_STATUS=$2; shift ;;
    --candidate-id) [ "$#" -ge 2 ] || mirror_die "--candidate-id requires a value"; CANDIDATE_ID=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) mirror_die "unknown argument: $1" ;;
  esac
  shift
done

[ "$RELEASE_STATUS" = blocked ] || [ "$RELEASE_STATUS" = candidate ] || mirror_die "status must be blocked or candidate"
if [ "$RELEASE_STATUS" = candidate ]; then
  printf '%s' "$CANDIDATE_ID" | LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{7,40}$' || mirror_die "candidate status requires a hexadecimal git candidate id"
elif [ -n "$CANDIDATE_ID" ]; then
  mirror_die "--candidate-id is only valid with --status candidate"
fi

# `--work-dir` 可能改变候选根目录，因此默认输出必须在参数解析完成后计算。
# 显式 `--output` 仍保持调用方指定的位置。
if [ -z "$OUTPUT" ]; then
  OUTPUT="$MIRROR_WORK_DIR/manifests/stable.candidate.json"
fi

mirror_require plutil
mirror_require osascript
[ -f "$TEMPLATE" ] || mirror_die "missing manifest template"

CLAUDE_VERSION=$(/usr/bin/plutil -extract claude_code.version raw -o - "$TEMPLATE") || mirror_die "missing Claude version"
CLASH_VERSION=$(/usr/bin/plutil -extract clash_verge.version raw -o - "$TEMPLATE") || mirror_die "missing Clash version"
LANE_VERSION=$(/usr/bin/plutil -extract claude_lane.version raw -o - "$TEMPLATE") || mirror_die "missing lane version"

CLAUDE_DIR="$MIRROR_WORK_DIR/claude-code/releases/$CLAUDE_VERSION"
CLASH_DIR="$MIRROR_WORK_DIR/clash-verge/releases/v$CLASH_VERSION"
LANE_DIR="$MIRROR_WORK_DIR/claude-lane/releases/v$LANE_VERSION"
MISSING=0

check_file() {
  if [ -f "$1" ]; then
    mirror_say "ready: $1"
  else
    mirror_warn "missing: $1"
    MISSING=$((MISSING + 1))
  fi
}

for required in \
  "$CLAUDE_DIR/manifest.json" "$CLAUDE_DIR/manifest.json.sig" \
  "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_aarch64.dmg" "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_x64.dmg" \
  "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_arm64-setup.exe" "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_arm64-setup.exe.sig" \
  "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_x64-setup.exe" "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_x64-setup.exe.sig" \
  "$CLASH_DIR/LICENSE" "$CLASH_DIR/SOURCE.txt"; do
  check_file "$required"
done
check_file "$LANE_DIR/claude-lane.tar.gz"
check_file "$LANE_DIR/claude-lane.zip"

if [ "$MIRROR_EXECUTE" != "1" ]; then
  mirror_say "dry-run: would write candidate manifest to $OUTPUT"
  [ "$MISSING" -eq 0 ] || mirror_say "dry-run: $MISSING required files are still missing"
  exit 0
fi

[ "$MISSING" -eq 0 ] || mirror_die "cannot generate a release candidate with missing artifacts"
/bin/mkdir -p "$(dirname "$OUTPUT")" || mirror_die "cannot create output directory"
TMP_OUTPUT="${OUTPUT}.tmp.$$"
/bin/cp "$TEMPLATE" "$TMP_OUTPUT" || mirror_die "cannot copy manifest template"
/usr/bin/plutil -replace release_status -string "$RELEASE_STATUS" "$TMP_OUTPUT" || mirror_die "cannot update release status"
if [ "$RELEASE_STATUS" = candidate ]; then
  /usr/bin/plutil -insert candidate_id -string "$CANDIDATE_ID" "$TMP_OUTPUT" 2>/dev/null ||
    /usr/bin/plutil -replace candidate_id -string "$CANDIDATE_ID" "$TMP_OUTPUT" || mirror_die "cannot record candidate id"
  /usr/bin/plutil -replace claude_lane.path -string "claude-lane/releases/candidates/$CANDIDATE_ID/claude-lane.tar.gz" "$TMP_OUTPUT" || mirror_die "cannot pin candidate lane tar path"
  /usr/bin/plutil -replace claude_lane.windows_path -string "claude-lane/releases/candidates/$CANDIDATE_ID/claude-lane.zip" "$TMP_OUTPUT" || mirror_die "cannot pin candidate lane zip path"
else
  /usr/bin/plutil -remove candidate_id "$TMP_OUTPUT" >/dev/null 2>&1 || true
fi

replace_file_metadata() {
  key=$1
  file=$2
  /usr/bin/plutil -replace "$key.size" -integer "$(mirror_size "$file")" "$TMP_OUTPUT" || mirror_die "cannot update $key.size"
  /usr/bin/plutil -replace "$key.sha256" -string "$(mirror_sha256 "$file")" "$TMP_OUTPUT" || mirror_die "cannot update $key.sha256"
}

replace_file_metadata claude_code.manifest "$CLAUDE_DIR/manifest.json"
/usr/bin/plutil -replace claude_code.manifest.signature_size -integer "$(mirror_size "$CLAUDE_DIR/manifest.json.sig")" "$TMP_OUTPUT"
/usr/bin/plutil -replace claude_code.manifest.signature_sha256 -string "$(mirror_sha256 "$CLAUDE_DIR/manifest.json.sig")" "$TMP_OUTPUT"
replace_file_metadata clash_verge.arm64 "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_aarch64.dmg"
replace_file_metadata clash_verge.x86_64 "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_x64.dmg"
replace_file_metadata clash_verge.win32_arm64 "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_arm64-setup.exe"
/usr/bin/plutil -replace clash_verge.win32_arm64.signature_size -integer "$(mirror_size "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_arm64-setup.exe.sig")" "$TMP_OUTPUT"
/usr/bin/plutil -replace clash_verge.win32_arm64.signature_sha256 -string "$(mirror_sha256 "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_arm64-setup.exe.sig")" "$TMP_OUTPUT"
replace_file_metadata clash_verge.win32_x64 "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_x64-setup.exe"
/usr/bin/plutil -replace clash_verge.win32_x64.signature_size -integer "$(mirror_size "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_x64-setup.exe.sig")" "$TMP_OUTPUT"
/usr/bin/plutil -replace clash_verge.win32_x64.signature_sha256 -string "$(mirror_sha256 "$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_x64-setup.exe.sig")" "$TMP_OUTPUT"
/usr/bin/plutil -replace claude_lane.sha256 -string "$(mirror_sha256 "$LANE_DIR/claude-lane.tar.gz")" "$TMP_OUTPUT"
/usr/bin/plutil -replace claude_lane.windows_sha256 -string "$(mirror_sha256 "$LANE_DIR/claude-lane.zip")" "$TMP_OUTPUT"
/usr/bin/plutil -replace distribution.synchronized_at -string "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$TMP_OUTPUT"

/usr/bin/plutil -convert json -o "$TMP_OUTPUT.json" "$TMP_OUTPUT" || mirror_die "candidate is not valid JSON"
/bin/mv "$TMP_OUTPUT.json" "$OUTPUT" || mirror_die "cannot finalize candidate"
/bin/rm -f "$TMP_OUTPUT"
mirror_say "manifest generated with status $RELEASE_STATUS: $OUTPUT"
