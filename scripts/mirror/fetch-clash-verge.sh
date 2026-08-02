#!/bin/bash

# Fetch an immutable stable Clash Verge Rev release from the official GitHub repo.
# Default is dry-run. Pass --execute to download and verify official digests.

set -u
set -o pipefail
umask 077

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/common.sh"

usage() {
  cat <<'EOF'
usage: bash scripts/mirror/fetch-clash-verge.sh [--version X.Y.Z] [--work-dir DIR] [--execute]

Default: print the fixed official release without downloading.
The normal Windows installers are mirrored; fixed-WebView2 builds are excluded.
EOF
}

mirror_parse_common_args "$@"
parse_status=$?
[ "$parse_status" != "2" ] || { usage; exit 0; }
if [ -z "$MIRROR_VERSION" ]; then
  MIRROR_VERSION=$(/usr/bin/plutil -extract clash_verge.version raw -o - \
    "$MIRROR_REPO_ROOT/manifests/stable.json" 2>/dev/null) || mirror_die "cannot read fixed Clash version"
fi
mirror_valid_version "$MIRROR_VERSION" || mirror_die "invalid Clash Verge version"

TAG="v$MIRROR_VERSION"
REPO="clash-verge-rev/clash-verge-rev"
RELEASE_API="https://api.github.com/repos/$REPO/releases/tags/$TAG"
DEST="$MIRROR_WORK_DIR/clash-verge/releases/$TAG"
ASSETS="Clash.Verge_${MIRROR_VERSION}_aarch64.dmg Clash.Verge_${MIRROR_VERSION}_x64.dmg Clash.Verge_${MIRROR_VERSION}_arm64-setup.exe Clash.Verge_${MIRROR_VERSION}_arm64-setup.exe.sig Clash.Verge_${MIRROR_VERSION}_x64-setup.exe Clash.Verge_${MIRROR_VERSION}_x64-setup.exe.sig"

mirror_say "Clash Verge Rev ${TAG}"
mirror_say "official release: https://github.com/$REPO/releases/tag/$TAG"
for asset in $ASSETS; do
  mirror_say "  https://github.com/$REPO/releases/download/$TAG/$asset"
done
[ "$MIRROR_EXECUTE" = "1" ] || { mirror_say "dry-run: no files downloaded"; exit 0; }

mirror_require /usr/bin/curl
mirror_require /usr/bin/osascript
/bin/mkdir -p "$DEST/audit" || mirror_die "cannot create Clash staging directory"
RELEASE_JSON="$DEST/audit/release.json"
mirror_download "$RELEASE_API" "$RELEASE_JSON" "" "Clash release metadata"

release_line=$(/usr/bin/osascript -l JavaScript "$HERE/mirror-json.js" github-release "$RELEASE_JSON") ||
  mirror_die "cannot parse Clash release metadata"
old_ifs=$IFS
IFS=$(printf '\t')
set -- $release_line
IFS=$old_ifs
[ "$1" = "$TAG" ] || mirror_die "Clash tag mismatch"
[ "$2" = "false" ] || mirror_die "draft Clash release is forbidden"
[ "$3" = "false" ] || mirror_die "prerelease Clash release is forbidden"
published_at=$4

EVIDENCE="$DEST/audit/evidence.tsv"
printf 'product\tversion\tplatform\tfile\tsize\tsha256\tofficial_url\tsignature_status\tpublished_at\n' >"$EVIDENCE"
for asset in $ASSETS; do
  asset_line=$(/usr/bin/osascript -l JavaScript "$HERE/mirror-json.js" github-asset "$RELEASE_JSON" "$asset") ||
    mirror_die "cannot find trusted metadata for $asset"
  old_ifs=$IFS
  IFS=$(printf '\t')
  set -- $asset_line
  IFS=$old_ifs
  asset_name=$1
  asset_size=$2
  asset_sha=$3
  asset_url=$4
  mirror_download "$asset_url" "$DEST/$asset_name" "$asset_sha" "$asset_name"
  [ "$(mirror_size "$DEST/$asset_name")" = "$asset_size" ] || mirror_die "size mismatch for $asset_name"
  case "$asset_name" in
    *.dmg) platform=darwin; signature_status=pending-codesign ;;
    *_arm64-setup.exe) platform=win32-arm64; signature_status=pending-authenticode ;;
    *_x64-setup.exe) platform=win32-x64; signature_status=pending-authenticode ;;
    *.sig) platform=signature; signature_status=official-tauri-signature ;;
    *) mirror_die "unexpected Clash asset" ;;
  esac
  printf 'clash-verge-rev\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$MIRROR_VERSION" "$platform" "$asset_name" "$asset_size" "$asset_sha" "$asset_url" "$signature_status" "$published_at" >>"$EVIDENCE"
done

LICENSE_URL="https://raw.githubusercontent.com/$REPO/$TAG/LICENSE"
mirror_download "$LICENSE_URL" "$DEST/LICENSE" "" "Clash GPL license"
printf '%s\n' "source=https://github.com/$REPO/tree/$TAG" "license=$LICENSE_URL" >"$DEST/SOURCE.txt"
mirror_say "downloaded digest-verified Clash artifacts: $DEST"
mirror_say "macOS codesign/spctl and Windows Authenticode remain for verify-artifacts scripts."
