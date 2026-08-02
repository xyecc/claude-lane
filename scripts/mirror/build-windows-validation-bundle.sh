#!/bin/bash

# Build a portable real-host validation bundle containing only the fixed
# Windows artifacts and scripts required by scripts/windows-validation.ps1.
# Default is dry-run; --execute creates an immutable ZIP and SHA-256 sidecar.

set -u
set -o pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

OUTPUT=""
STAGE_PARENT=""

usage() {
  printf '%s\n' '用法：bash scripts/mirror/build-windows-validation-bundle.sh [--execute] [--work-dir <path>] [--output <zip>]'
}

cleanup() {
  case "$STAGE_PARENT" in
    "$MIRROR_WORK_DIR"/validation/stage.*) /bin/rm -rf -- "$STAGE_PARENT" ;;
    "") ;;
    *) mirror_warn "refusing to remove unexpected staging path: $STAGE_PARENT" ;;
  esac
}
trap cleanup EXIT INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --execute) MIRROR_EXECUTE=1 ;;
    --work-dir) [ "$#" -ge 2 ] || mirror_die "--work-dir requires a value"; MIRROR_WORK_DIR=$2; shift ;;
    --output) [ "$#" -ge 2 ] || mirror_die "--output requires a value"; OUTPUT=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) mirror_die "unknown argument: $1" ;;
  esac
  shift
done

[ -n "$OUTPUT" ] || OUTPUT="$MIRROR_WORK_DIR/validation/claude-lane-windows-validation.zip"

MANIFEST="$MIRROR_REPO_ROOT/manifests/stable.json"
mirror_require /usr/bin/plutil
mirror_require /usr/bin/zip
[ -f "$MANIFEST" ] || mirror_die "missing stable manifest"

CLAUDE_VERSION=$(/usr/bin/plutil -extract claude_code.version raw -o - "$MANIFEST") || mirror_die "missing Claude version"
CLASH_VERSION=$(/usr/bin/plutil -extract clash_verge.version raw -o - "$MANIFEST") || mirror_die "missing Clash version"
CLAUDE_DIR="$MIRROR_WORK_DIR/claude-code/releases/$CLAUDE_VERSION"
CLASH_DIR="$MIRROR_WORK_DIR/clash-verge/releases/v$CLASH_VERSION"
LANE_VERSION=$(/usr/bin/plutil -extract claude_lane.version raw -o - "$MANIFEST") || mirror_die "missing lane version"
LANE_DIR="$MIRROR_WORK_DIR/claude-lane/releases/v$LANE_VERSION"

verify_fixed_file() {
  source_file=$1
  manifest_key=$2
  expected=$(/usr/bin/plutil -extract "$manifest_key.sha256" raw -o - "$MANIFEST") || mirror_die "missing $manifest_key.sha256"
  mirror_valid_sha256 "$expected" || mirror_die "invalid $manifest_key.sha256"
  verify_expected_file "$source_file" "$expected" "$manifest_key"
}

verify_expected_file() {
  source_file=$1
  expected=$2
  label=$3
  mirror_valid_sha256 "$expected" || mirror_die "invalid SHA-256 for $label"
  [ -f "$source_file" ] && [ ! -L "$source_file" ] || mirror_die "missing or unsafe validation input: $source_file"
  [ "$(mirror_sha256 "$source_file")" = "$expected" ] || mirror_die "SHA-256 mismatch for $label"
}

WIN_CLAUDE_ARM64="$CLAUDE_DIR/claude-win32-arm64.exe"
WIN_CLAUDE_X64="$CLAUDE_DIR/claude-win32-x64.exe"
WIN_CLASH_ARM64="$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_arm64-setup.exe"
WIN_CLASH_X64="$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_x64-setup.exe"
WIN_LANE="$LANE_DIR/claude-lane.zip"

mirror_say "Windows validation bundle: $OUTPUT"
mirror_say "includes both x64 and ARM64 fixed artifacts; each host validates only its native architecture"
[ "$MIRROR_EXECUTE" = "1" ] || { mirror_say "dry-run: no bundle created"; exit 0; }

case "$OUTPUT" in *.zip) ;; *) mirror_die "output must end in .zip" ;; esac
[ ! -e "$OUTPUT" ] && [ ! -e "$OUTPUT.sha256" ] || mirror_die "validation bundle output already exists; refusing overwrite"

verify_fixed_file "$WIN_CLAUDE_ARM64" claude_code.win32_arm64
verify_fixed_file "$WIN_CLAUDE_X64" claude_code.win32_x64
verify_fixed_file "$WIN_CLASH_ARM64" clash_verge.win32_arm64
verify_fixed_file "$WIN_CLASH_X64" clash_verge.win32_x64
LANE_SHA=$(/usr/bin/plutil -extract claude_lane.windows_sha256 raw -o - "$MANIFEST") || mirror_die "missing claude_lane.windows_sha256"
verify_expected_file "$WIN_LANE" "$LANE_SHA" claude_lane.windows_sha256

OUTPUT_DIR=$(dirname "$OUTPUT")
/bin/mkdir -p "$OUTPUT_DIR" || mirror_die "cannot create validation output directory"
/bin/mkdir -p "$MIRROR_WORK_DIR/validation" || mirror_die "cannot create validation staging directory"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd) || mirror_die "cannot resolve validation output directory"
OUTPUT="$OUTPUT_DIR/$(basename "$OUTPUT")"
STAGE_PARENT=$(/usr/bin/mktemp -d "$MIRROR_WORK_DIR/validation/stage.XXXXXX") || mirror_die "cannot create validation staging directory"
BUNDLE_ROOT="$STAGE_PARENT/claude-lane-windows-validation"

/bin/mkdir -p \
  "$BUNDLE_ROOT/manifests" "$BUNDLE_ROOT/scripts/mirror" \
  "$BUNDLE_ROOT/.mirror-work/claude-code/releases/$CLAUDE_VERSION" \
  "$BUNDLE_ROOT/.mirror-work/clash-verge/releases/v$CLASH_VERSION" \
  "$BUNDLE_ROOT/.mirror-work/claude-lane/releases/v$LANE_VERSION" || mirror_die "cannot create bundle layout"

/bin/cp "$MANIFEST" "$BUNDLE_ROOT/manifests/stable.json" || mirror_die "cannot stage manifest"
/bin/cp "$MIRROR_REPO_ROOT/bootstrap.ps1" "$BUNDLE_ROOT/bootstrap.ps1" || mirror_die "cannot stage Windows bootstrap"
/bin/cp "$MIRROR_REPO_ROOT/scripts/bootstrap-windows-selftest.ps1" "$BUNDLE_ROOT/scripts/bootstrap-windows-selftest.ps1" || mirror_die "cannot stage bootstrap self-test"
/bin/cp "$MIRROR_REPO_ROOT/scripts/windows-validation.ps1" "$BUNDLE_ROOT/scripts/windows-validation.ps1" || mirror_die "cannot stage validation entrypoint"
/bin/cp "$MIRROR_REPO_ROOT/scripts/windows-local-rc.ps1" "$BUNDLE_ROOT/scripts/windows-local-rc.ps1" || mirror_die "cannot stage local RC installer"
/bin/cp "$MIRROR_REPO_ROOT/scripts/mirror/verify-artifacts.ps1" "$BUNDLE_ROOT/scripts/mirror/verify-artifacts.ps1" || mirror_die "cannot stage artifact verifier"
/bin/cp "$MIRROR_REPO_ROOT/docs/validation-playbook.md" "$BUNDLE_ROOT/VALIDATION.md" || mirror_die "cannot stage validation guide"

/bin/ln "$WIN_CLAUDE_ARM64" "$BUNDLE_ROOT/.mirror-work/claude-code/releases/$CLAUDE_VERSION/claude-win32-arm64.exe" || mirror_die "cannot stage Claude ARM64"
/bin/ln "$WIN_CLAUDE_X64" "$BUNDLE_ROOT/.mirror-work/claude-code/releases/$CLAUDE_VERSION/claude-win32-x64.exe" || mirror_die "cannot stage Claude x64"
/bin/ln "$WIN_CLASH_ARM64" "$BUNDLE_ROOT/.mirror-work/clash-verge/releases/v$CLASH_VERSION/Clash.Verge_${CLASH_VERSION}_arm64-setup.exe" || mirror_die "cannot stage Clash ARM64"
/bin/ln "$WIN_CLASH_X64" "$BUNDLE_ROOT/.mirror-work/clash-verge/releases/v$CLASH_VERSION/Clash.Verge_${CLASH_VERSION}_x64-setup.exe" || mirror_die "cannot stage Clash x64"
/bin/ln "$WIN_LANE" "$BUNDLE_ROOT/.mirror-work/claude-lane/releases/v$LANE_VERSION/claude-lane.zip" || mirror_die "cannot stage claude-lane ZIP"

(cd "$STAGE_PARENT" && /usr/bin/zip -q -r -X "$OUTPUT" claude-lane-windows-validation) || mirror_die "cannot build Windows validation ZIP"
printf '%s  %s\n' "$(mirror_sha256 "$OUTPUT")" "$(basename "$OUTPUT")" >"$OUTPUT.sha256" || mirror_die "cannot write validation bundle digest"
mirror_say "built: $OUTPUT"
mirror_say "sha256: $(mirror_sha256 "$OUTPUT")"
