#!/bin/bash

# Recalculate local artifact metadata into a candidate/released manifest.
# Never promotes stable. --status released requires five non-secret evidence files.

set -u
set -o pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

OUTPUT=""
TEMPLATE="$MIRROR_REPO_ROOT/manifests/stable.json"
RELEASE_STATUS=blocked
CANDIDATE_ID=""
EVIDENCE_DIR=""

usage() {
  printf '%s\n' '用法：bash scripts/mirror/generate-manifest.sh [--execute] [--output <path>] [--work-dir <path>] [--status blocked|candidate|released] [--candidate-id <git-id>] [--evidence-dir <dir>]'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --execute) MIRROR_EXECUTE=1 ;;
    --output) [ "$#" -ge 2 ] || mirror_die "--output requires a value"; OUTPUT=$2; shift ;;
    --work-dir) [ "$#" -ge 2 ] || mirror_die "--work-dir requires a value"; MIRROR_WORK_DIR=$2; shift ;;
    --status) [ "$#" -ge 2 ] || mirror_die "--status requires a value"; RELEASE_STATUS=$2; shift ;;
    --candidate-id) [ "$#" -ge 2 ] || mirror_die "--candidate-id requires a value"; CANDIDATE_ID=$2; shift ;;
    --evidence-dir) [ "$#" -ge 2 ] || mirror_die "--evidence-dir requires a value"; EVIDENCE_DIR=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) mirror_die "unknown argument: $1" ;;
  esac
  shift
done

[ "$RELEASE_STATUS" = blocked ] || [ "$RELEASE_STATUS" = candidate ] || [ "$RELEASE_STATUS" = released ] ||
  mirror_die "status must be blocked, candidate, or released"

if [ "$RELEASE_STATUS" = candidate ] || [ "$RELEASE_STATUS" = released ]; then
  printf '%s' "$CANDIDATE_ID" | LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{7,40}$' ||
    mirror_die "$RELEASE_STATUS status requires a hexadecimal git candidate id"
else
  [ -z "$CANDIDATE_ID" ] || mirror_die "--candidate-id is only valid with --status candidate or released"
fi

if [ "$RELEASE_STATUS" = released ]; then
  [ -n "$EVIDENCE_DIR" ] || mirror_die "released status requires --evidence-dir"
  [ -d "$EVIDENCE_DIR" ] || mirror_die "evidence directory not found: $EVIDENCE_DIR"
elif [ -n "$EVIDENCE_DIR" ]; then
  mirror_die "--evidence-dir is only valid with --status released"
fi

# `--work-dir` 可能改变候选根目录，因此默认输出必须在参数解析完成后计算。
# 显式 `--output` 仍保持调用方指定的位置。
if [ -z "$OUTPUT" ]; then
  if [ "$RELEASE_STATUS" = released ]; then
    OUTPUT="$MIRROR_WORK_DIR/manifests/stable.released.json"
  else
    OUTPUT="$MIRROR_WORK_DIR/manifests/stable.candidate.json"
  fi
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

# Validate one schema-2 evidence file. Failure-closed: any mismatch dies.
validate_evidence_file() {
  evidence_name=$1
  expected_platform=$2
  evidence_path="$EVIDENCE_DIR/$evidence_name"
  [ -f "$evidence_path" ] || mirror_die "missing release evidence: $evidence_name"
  /usr/bin/plutil -convert xml1 -o /dev/null -- "$evidence_path" >/dev/null 2>&1 ||
    mirror_die "evidence is not valid JSON: $evidence_name"

  schema_value=$(/usr/bin/plutil -extract schema raw -o - "$evidence_path" 2>/dev/null) ||
    mirror_die "evidence missing schema: $evidence_name"
  [ "$schema_value" = "2" ] || mirror_die "evidence schema must be 2: $evidence_name"

  platform_value=$(/usr/bin/plutil -extract platform raw -o - "$evidence_path" 2>/dev/null) ||
    mirror_die "evidence missing platform: $evidence_name"
  [ "$platform_value" = "$expected_platform" ] ||
    mirror_die "evidence platform mismatch in $evidence_name (want $expected_platform)"

  candidate_value=$(/usr/bin/plutil -extract rc.candidate_id raw -o - "$evidence_path" 2>/dev/null) ||
    mirror_die "evidence missing rc.candidate_id: $evidence_name"
  [ "$candidate_value" = "$CANDIDATE_ID" ] ||
    mirror_die "evidence candidate_id mismatch in $evidence_name"

  case "$expected_platform" in
    win32-x64|win32-arm64)
      routing_state=$(/usr/bin/plutil -extract routing_validation.state raw -o - "$evidence_path" 2>/dev/null) ||
        mirror_die "evidence missing routing_validation.state: $evidence_name"
      [ "$routing_state" = "VALIDATION_PASSED" ] ||
        mirror_die "evidence routing_validation not passed: $evidence_name"
      runtime_passed=$(/usr/bin/plutil -extract runtime_selftest.passed raw -o - "$evidence_path" 2>/dev/null) ||
        mirror_die "evidence missing runtime_selftest.passed: $evidence_name"
      [ "$runtime_passed" = "true" ] ||
        mirror_die "evidence runtime_selftest not passed: $evidence_name"
      if [ "$expected_platform" = "win32-arm64" ]; then
        native_arch=$(/usr/bin/plutil -extract host.native_arch raw -o - "$evidence_path" 2>/dev/null) ||
          mirror_die "evidence missing host.native_arch: $evidence_name"
        [ "$native_arch" = "ARM64" ] ||
          mirror_die "win32-arm64 evidence requires host.native_arch=ARM64"
      fi
      ;;
    darwin-arm64|darwin-x64)
      validation_state=$(/usr/bin/plutil -extract validation.state raw -o - "$evidence_path" 2>/dev/null) ||
        mirror_die "evidence missing validation.state: $evidence_name"
      [ "$validation_state" = "VALIDATION_PASSED" ] ||
        mirror_die "evidence validation not passed: $evidence_name"
      if [ "$expected_platform" = "darwin-x64" ]; then
        host_arch=$(/usr/bin/plutil -extract host.arch raw -o - "$evidence_path" 2>/dev/null) ||
          mirror_die "evidence missing host.arch: $evidence_name"
        [ "$host_arch" = "x86_64" ] ||
          mirror_die "darwin-x64 evidence requires host.arch=x86_64"
      fi
      ;;
    clean-mac)
      validation_state=$(/usr/bin/plutil -extract validation.state raw -o - "$evidence_path" 2>/dev/null) ||
        mirror_die "evidence missing validation.state: $evidence_name"
      [ "$validation_state" = "VALIDATION_PASSED" ] ||
        mirror_die "evidence validation not passed: $evidence_name"
      clean_host=$(/usr/bin/plutil -extract clean_host raw -o - "$evidence_path" 2>/dev/null) ||
        mirror_die "clean-mac evidence missing clean_host"
      [ "$clean_host" = "true" ] || mirror_die "clean-mac evidence requires clean_host=true"
      for cleanup_key in success failure interrupt; do
        cleanup_value=$(/usr/bin/plutil -extract "deepseek_cleanup.$cleanup_key" raw -o - "$evidence_path" 2>/dev/null) ||
          mirror_die "clean-mac evidence missing deepseek_cleanup.$cleanup_key"
        [ "$cleanup_value" = "true" ] ||
          mirror_die "clean-mac evidence requires deepseek_cleanup.$cleanup_key=true"
      done
      ;;
    *)
      mirror_die "internal error: unknown evidence platform $expected_platform"
      ;;
  esac
}

if [ "$RELEASE_STATUS" = released ]; then
  validate_evidence_file "win32-x64.json" "win32-x64"
  validate_evidence_file "win32-arm64.json" "win32-arm64"
  validate_evidence_file "darwin-arm64.json" "darwin-arm64"
  validate_evidence_file "darwin-x64.json" "darwin-x64"
  validate_evidence_file "clean-mac.json" "clean-mac"
  mirror_say "all five release evidence files passed gates for candidate $CANDIDATE_ID"
fi

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
  mirror_say "dry-run: would write $RELEASE_STATUS manifest to $OUTPUT"
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
elif [ "$RELEASE_STATUS" = released ]; then
  # Keep candidate_id for audit traceability to the RC that produced the evidence.
  /usr/bin/plutil -insert candidate_id -string "$CANDIDATE_ID" "$TMP_OUTPUT" 2>/dev/null ||
    /usr/bin/plutil -replace candidate_id -string "$CANDIDATE_ID" "$TMP_OUTPUT" || mirror_die "cannot record candidate id"
  /usr/bin/plutil -replace release_blockers -json '[]' "$TMP_OUTPUT" || mirror_die "cannot clear release blockers"
  /usr/bin/plutil -replace claude_lane.path -string "claude-lane/releases/v$LANE_VERSION/claude-lane.tar.gz" "$TMP_OUTPUT" || mirror_die "cannot pin released lane tar path"
  /usr/bin/plutil -replace claude_lane.windows_path -string "claude-lane/releases/v$LANE_VERSION/claude-lane.zip" "$TMP_OUTPUT" || mirror_die "cannot pin released lane zip path"

  evidence_json='{'
  first_evidence=1
  for evidence_name in win32-x64.json win32-arm64.json darwin-arm64.json darwin-x64.json clean-mac.json; do
    evidence_path="$EVIDENCE_DIR/$evidence_name"
    evidence_platform=$(/usr/bin/plutil -extract platform raw -o - "$evidence_path") ||
      mirror_die "cannot re-read evidence platform: $evidence_name"
    evidence_sha=$(mirror_sha256 "$evidence_path") || mirror_die "cannot hash evidence: $evidence_name"
    if [ "$first_evidence" -eq 1 ]; then
      first_evidence=0
    else
      evidence_json="${evidence_json},"
    fi
    evidence_key=${evidence_name%.json}
    evidence_json="${evidence_json}\"${evidence_key}\":{\"file\":\"${evidence_name}\",\"platform\":\"${evidence_platform}\",\"sha256\":\"${evidence_sha}\"}"
  done
  evidence_json="${evidence_json}}"
  /usr/bin/plutil -replace release_evidence -json "$evidence_json" "$TMP_OUTPUT" ||
    mirror_die "cannot record release_evidence"
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
