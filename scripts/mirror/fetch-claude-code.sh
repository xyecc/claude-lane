#!/bin/bash

# Fetch an immutable Claude Code release from Anthropic's official bucket.
# Default is dry-run. Pass --execute to download and verify.

set -u
set -o pipefail
umask 077

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/common.sh"

usage() {
  cat <<'EOF'
usage: bash scripts/mirror/fetch-claude-code.sh [--version X.Y.Z] [--work-dir DIR] [--execute]

Default: print the fixed official URLs without downloading.
Publisher dependencies for --execute: curl, gpg, plutil, shasum, codesign.
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
PLATFORMS="darwin-arm64 darwin-x64"
PUBLISHER_ARCH=$(/usr/bin/uname -m)

mirror_say "Claude Code ${MIRROR_VERSION}"
mirror_say "official manifest: ${BASE_URL}/${MIRROR_VERSION}/manifest.json"
for platform in $PLATFORMS; do
  mirror_say "  ${platform}: ${BASE_URL}/${MIRROR_VERSION}/${platform}/claude"
done
[ "$MIRROR_EXECUTE" = "1" ] || { mirror_say "dry-run: no files downloaded"; exit 0; }

mirror_require /usr/bin/curl
mirror_require /usr/bin/plutil
mirror_require /usr/bin/codesign
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
printf 'product\tversion\tplatform\tfile\tsize\tsha256\tofficial_url\tsignature_status\n' >"$EVIDENCE"

for platform in $PLATFORMS; do
  checksum=$(/usr/bin/plutil -extract "platforms.${platform}.checksum" raw -o - "$MANIFEST" 2>/dev/null) ||
    mirror_die "manifest is missing ${platform}"
  size=$(/usr/bin/plutil -extract "platforms.${platform}.size" raw -o - "$MANIFEST" 2>/dev/null) ||
    mirror_die "manifest is missing ${platform} size"
  binary=$(/usr/bin/plutil -extract "platforms.${platform}.binary" raw -o - "$MANIFEST" 2>/dev/null) ||
    mirror_die "manifest is missing ${platform} binary"
  mirror_valid_sha256 "$checksum" || mirror_die "invalid ${platform} checksum"
  case "$platform" in
    darwin-arm64) local_name=claude-darwin-arm64 ;;
    darwin-x64) local_name=claude-darwin-x64 ;;
    *) mirror_die "unsupported platform" ;;
  esac
  official_url="$BASE_URL/$MIRROR_VERSION/$platform/$binary"
  target="$DEST/$local_name"
  mirror_download "$official_url" "$target" "$checksum" "Claude ${platform}"
  [ "$(mirror_size "$target")" = "$size" ] || mirror_die "size mismatch for ${platform}"
  signature_status="verified-codesign-version-pending-native-host"
  case "$platform" in
    darwin-*)
      /bin/chmod 755 "$target" || mirror_die "cannot make ${platform} executable"
      /usr/bin/codesign --verify --strict --verbose=2 "$target" >/dev/null 2>&1 || mirror_die "codesign failed for ${platform}"
      signature_info=$(/usr/bin/codesign -d --verbose=4 "$target" 2>&1) || mirror_die "cannot read ${platform} signing identity"
      printf '%s\n' "$signature_info" | /usr/bin/grep -Fqx 'Identifier=com.anthropic.claude-code' || mirror_die "unexpected Claude identifier"
      printf '%s\n' "$signature_info" | /usr/bin/grep -Fqx 'TeamIdentifier=Q6L2SF6YDW' || mirror_die "unexpected Claude Team ID"
      if { [ "$platform" = darwin-arm64 ] && [ "$PUBLISHER_ARCH" = arm64 ]; } ||
         { [ "$platform" = darwin-x64 ] && [ "$PUBLISHER_ARCH" = x86_64 ]; }; then
        "$target" --version 2>/dev/null | /usr/bin/head -n 1 | /usr/bin/grep -Fq "$MIRROR_VERSION" || mirror_die "Claude version check failed"
        signature_status="verified-codesign-and-native-version"
      else
        signature_status="verified-codesign-version-pending-native-host"
      fi
      ;;
  esac
  printf 'claude-code\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$MIRROR_VERSION" "$platform" "$local_name" "$size" "$checksum" "$official_url" "$signature_status" >>"$EVIDENCE"
done

mirror_say "verified Claude artifacts: $DEST"
