#!/bin/bash

# Build commit-bound RC bootstrap entries. Production bootstrap sources remain
# pinned to released + manifests/stable.json; generated RC entries accept only
# candidate + manifests/candidates/<commit>.json.

set -u
set -o pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

CANDIDATE_ID=""

usage() {
  printf '%s\n' '用法：bash scripts/mirror/build-bootstrap-candidate.sh [--execute] [--work-dir <path>] [--candidate-id <git-id>]'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --execute) MIRROR_EXECUTE=1 ;;
    --work-dir) [ "$#" -ge 2 ] || mirror_die "--work-dir requires a value"; MIRROR_WORK_DIR=$2; shift ;;
    --candidate-id) [ "$#" -ge 2 ] || mirror_die "--candidate-id requires a value"; CANDIDATE_ID=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) mirror_die "unknown argument: $1" ;;
  esac
  shift
done

mirror_require git
mirror_require /usr/bin/plutil
mirror_require /usr/bin/shasum
mirror_require /usr/bin/sed

cd "$MIRROR_REPO_ROOT" || mirror_die "cannot enter repository"
HEAD_COMMIT=$(git rev-parse HEAD) || mirror_die "cannot resolve HEAD"
[ -n "$CANDIDATE_ID" ] || CANDIDATE_ID=$(git rev-parse --short=12 HEAD)
printf '%s' "$CANDIDATE_ID" | LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{7,40}$' || mirror_die "invalid candidate id"
case "$HEAD_COMMIT" in "$CANDIDATE_ID"*) ;; *) mirror_die "candidate id does not identify HEAD" ;; esac

CANDIDATE_ROOT="$MIRROR_WORK_DIR/candidates/$CANDIDATE_ID"
MANIFEST="$CANDIDATE_ROOT/manifests/stable.candidate.json"
OUTPUT_DIR="$CANDIDATE_ROOT/bootstrap"
MANIFEST_OBJECT="manifests/candidates/$CANDIDATE_ID.json"

mirror_say "candidate id: $CANDIDATE_ID"
mirror_say "candidate manifest: $MANIFEST"
mirror_say "candidate bootstrap: $OUTPUT_DIR"
[ "$MIRROR_EXECUTE" = 1 ] || { mirror_say "dry-run: no RC bootstrap entries built"; exit 0; }

[ -z "$(git status --porcelain)" ] || mirror_die "repository must be clean before building RC bootstrap entries"
[ -f "$MANIFEST" ] || mirror_die "candidate manifest not found"
[ "$(/usr/bin/plutil -extract release_status raw -o - "$MANIFEST" 2>/dev/null)" = candidate ] || mirror_die "manifest is not an RC candidate"
[ "$(/usr/bin/plutil -extract candidate_id raw -o - "$MANIFEST" 2>/dev/null)" = "$CANDIDATE_ID" ] || mirror_die "manifest candidate id mismatch"
MANIFEST_SHA=$(mirror_sha256 "$MANIFEST") || mirror_die "cannot hash candidate manifest"
mirror_valid_sha256 "$MANIFEST_SHA" || mirror_die "invalid candidate manifest digest"

/bin/mkdir -p "$OUTPUT_DIR" || mirror_die "cannot create candidate bootstrap directory"
[ ! -e "$OUTPUT_DIR/install.sh" ] && [ ! -e "$OUTPUT_DIR/install.ps1" ] && [ ! -e "$OUTPUT_DIR/evidence.txt" ] ||
  mirror_die "candidate bootstrap outputs already exist; immutable output will not be overwritten"

/usr/bin/sed \
  -e 's|^EXPECTED_RELEASE_STATUS="released"$|EXPECTED_RELEASE_STATUS="candidate"|' \
  -e 's|^RELEASE_CHANNEL="stable"$|RELEASE_CHANNEL="candidate"|' \
  -e "s|^STABLE_MANIFEST_PATH=.*$|STABLE_MANIFEST_PATH=\"$MANIFEST_OBJECT\"|" \
  -e "s|^STABLE_MANIFEST_SHA256=.*$|STABLE_MANIFEST_SHA256=\"$MANIFEST_SHA\"|" \
  "$MIRROR_REPO_ROOT/bootstrap.sh" >"$OUTPUT_DIR/install.sh" || mirror_die "cannot build macOS RC bootstrap"

/usr/bin/sed \
  -e 's|^\$ExpectedReleaseStatus = "released"$|\$ExpectedReleaseStatus = "candidate"|' \
  -e 's|^\$ReleaseChannel = "stable"$|\$ReleaseChannel = "candidate"|' \
  -e "s|^\$StableManifestPath = .*$|\$StableManifestPath = \"$MANIFEST_OBJECT\"|" \
  -e "s|^\$StableManifestSha256 = .*$|\$StableManifestSha256 = \"$MANIFEST_SHA\"|" \
  "$MIRROR_REPO_ROOT/bootstrap.ps1" >"$OUTPUT_DIR/install.ps1" || mirror_die "cannot build Windows RC bootstrap"

/bin/chmod 700 "$OUTPUT_DIR/install.sh"
/bin/chmod 600 "$OUTPUT_DIR/install.ps1"

/usr/bin/grep -Fqx 'EXPECTED_RELEASE_STATUS="candidate"' "$OUTPUT_DIR/install.sh" || mirror_die "macOS RC status pin missing"
/usr/bin/grep -Fqx 'RELEASE_CHANNEL="candidate"' "$OUTPUT_DIR/install.sh" || mirror_die "macOS RC channel pin missing"
/usr/bin/grep -Fqx "STABLE_MANIFEST_SHA256=\"$MANIFEST_SHA\"" "$OUTPUT_DIR/install.sh" || mirror_die "macOS RC manifest digest pin missing"
/usr/bin/grep -Fqx '$ExpectedReleaseStatus = "candidate"' "$OUTPUT_DIR/install.ps1" || mirror_die "Windows RC status pin missing"
/usr/bin/grep -Fqx '$ReleaseChannel = "candidate"' "$OUTPUT_DIR/install.ps1" || mirror_die "Windows RC channel pin missing"
/usr/bin/grep -Fqx "\$StableManifestSha256 = \"$MANIFEST_SHA\"" "$OUTPUT_DIR/install.ps1" || mirror_die "Windows RC manifest digest pin missing"

CL_BOOT_TEST_MODE=1 CL_BOOT_TEST_UNAME_S=Darwin CL_BOOT_TEST_UNAME_M=arm64 \
  CL_BOOT_TEST_MACOS_VERSION=14.0 CL_BOOT_TEST_FREE_MB=8192 \
  /bin/bash "$OUTPUT_DIR/install.sh" --dry-run --manifest-file "$MANIFEST" >/dev/null 2>&1 ||
  mirror_die "generated macOS RC bootstrap rejected its pinned candidate manifest"

printf 'candidate_id=%s\ncommit=%s\nmanifest_object=%s\nmanifest_sha256=%s\ninstall_sh_sha256=%s\ninstall_ps1_sha256=%s\n' \
  "$CANDIDATE_ID" "$HEAD_COMMIT" "$MANIFEST_OBJECT" "$MANIFEST_SHA" \
  "$(mirror_sha256 "$OUTPUT_DIR/install.sh")" "$(mirror_sha256 "$OUTPUT_DIR/install.ps1")" >"$OUTPUT_DIR/evidence.txt"
/bin/chmod 600 "$OUTPUT_DIR/evidence.txt"
mirror_say "built immutable RC bootstrap entries for $CANDIDATE_ID"
