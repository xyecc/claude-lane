#!/bin/bash

# Fetch and verify Claude Code release metadata from Anthropic's official
# bucket. Claude binaries are intentionally not mirrored: clients download the
# pinned binary from Anthropic only after Clash is usable.

set -u
set -o pipefail
umask 077

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/common.sh"

usage() {
  cat <<'EOF'
usage: bash scripts/mirror/fetch-claude-code.sh [--version X.Y.Z] [--work-dir DIR] [--execute]

Default: print the fixed official URLs without downloading.
Publisher dependencies for --execute: curl, gpg, plutil, shasum.
Only the signed manifest, detached signature, key and audit evidence are saved.
EOF
}

mirror_parse_common_args "$@"
parse_status=$?
[ "$parse_status" != "2" ] || { usage; exit 0; }

if [ -z "$MIRROR_VERSION" ]; then
  MIRROR_VERSION=$(/usr/bin/plutil -extract claude_code.version raw -o - \
    "$MIRROR_REPO_ROOT/manifests/stable.json" 2>/dev/null) || mirror_die "cannot read fixed Claude version"
fi
mirror_valid_version "$MIRROR_VERSION" || mirror_die "invalid Claude Code version"

BASE_URL="https://downloads.claude.ai/claude-code-releases"
DEST="$MIRROR_WORK_DIR/claude-code/releases/$MIRROR_VERSION"
EXPECTED_FINGERPRINT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
PLATFORMS="darwin-arm64 darwin-x64 win32-arm64 win32-x64"

mirror_say "Claude Code ${MIRROR_VERSION}"
mirror_say "official manifest: ${BASE_URL}/${MIRROR_VERSION}/manifest.json"
for platform in $PLATFORMS; do
  case "$platform" in
    win32-*) binary=claude.exe ;;
    *) binary=claude ;;
  esac
  mirror_say "  ${platform}: ${BASE_URL}/${MIRROR_VERSION}/${platform}/${binary}"
done
[ "$MIRROR_EXECUTE" = "1" ] || { mirror_say "dry-run: no files downloaded"; exit 0; }

mirror_require /usr/bin/curl
mirror_require /usr/bin/plutil
mirror_require gpg
/bin/mkdir -p "$DEST/audit" || mirror_die "cannot create Claude staging directory"

MANIFEST="$DEST/manifest.json"
SIGNATURE="$DEST/manifest.json.sig"
PUBLIC_KEY="$DEST/audit/claude-code.asc"
mirror_download "$BASE_URL/$MIRROR_VERSION/manifest.json" "$MANIFEST" "" "Claude manifest"
mirror_download "$BASE_URL/$MIRROR_VERSION/manifest.json.sig" "$SIGNATURE" "" "Claude manifest signature"
mirror_download "https://downloads.claude.ai/keys/claude-code.asc" "$PUBLIC_KEY" "" "Claude release key"

manifest_version=$(/usr/bin/plutil -extract version raw -o - "$MANIFEST" 2>/dev/null) || mirror_die "manifest has no version"
[ "$manifest_version" = "$MIRROR_VERSION" ] || mirror_die "manifest version mismatch"

GNUPG_HOME="$DEST/audit/gnupg"
/bin/mkdir -p "$GNUPG_HOME" || mirror_die "cannot create isolated GPG home"
/bin/chmod 700 "$GNUPG_HOME" || mirror_die "cannot protect isolated GPG home"
# GnuPG 2.5 on a brand-new keyring can return non-zero after creating and
# importing the key. The exact fingerprint and detached signature below are
# the authoritative gates, so do not trust the import exit code alone.
GNUPGHOME="$GNUPG_HOME" gpg --batch --import "$PUBLIC_KEY" >/dev/null 2>&1 || true
fingerprint=$(GNUPGHOME="$GNUPG_HOME" gpg --batch --with-colons --fingerprint security@anthropic.com |
  /usr/bin/awk -F: '$1=="fpr"{print $10; exit}')
[ "$fingerprint" = "$EXPECTED_FINGERPRINT" ] || mirror_die "Anthropic release key fingerprint mismatch"
GNUPGHOME="$GNUPG_HOME" gpg --batch --verify "$SIGNATURE" "$MANIFEST" >"$DEST/audit/manifest-gpg.txt" 2>&1 ||
  mirror_die "Claude manifest signature verification failed"

EVIDENCE="$DEST/audit/evidence.tsv"
printf 'product\tversion\tplatform\tsize\tsha256\tofficial_url\tsignature_status\n' >"$EVIDENCE"

for platform in $PLATFORMS; do
  checksum=$(/usr/bin/plutil -extract "platforms.${platform}.checksum" raw -o - "$MANIFEST" 2>/dev/null) ||
    mirror_die "manifest is missing ${platform}"
  size=$(/usr/bin/plutil -extract "platforms.${platform}.size" raw -o - "$MANIFEST" 2>/dev/null) ||
    mirror_die "manifest is missing ${platform} size"
  binary=$(/usr/bin/plutil -extract "platforms.${platform}.binary" raw -o - "$MANIFEST" 2>/dev/null) ||
    mirror_die "manifest is missing ${platform} binary"
  mirror_valid_sha256 "$checksum" || mirror_die "invalid ${platform} checksum"
  official_url="$BASE_URL/$MIRROR_VERSION/$platform/$binary"
  printf 'claude-code\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$MIRROR_VERSION" "$platform" "$size" "$checksum" "$official_url" "verified-signed-manifest-runtime-platform-signature" >>"$EVIDENCE"
done

mirror_say "verified Claude signed release metadata: $DEST"
mirror_say "no Claude binary was downloaded or staged for OSS upload"
