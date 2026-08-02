#!/bin/bash

# Publisher-side verification for official manifests, hashes, Tauri signatures,
# macOS code signatures and Gatekeeper. Windows Authenticode is verified by the
# sibling PowerShell script on a real Windows host.

set -u
set -o pipefail
umask 077

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/common.sh"

usage() {
  cat <<'EOF'
usage: bash scripts/mirror/verify-artifacts.sh [--work-dir DIR]

Dependencies: gpg, minisign, macOS codesign/spctl/hdiutil/osascript.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --work-dir) [ "$#" -ge 2 ] || mirror_die "--work-dir requires a value"; MIRROR_WORK_DIR=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) mirror_die "unknown argument: $1" ;;
  esac
  shift
done

mirror_require gpg
mirror_require minisign
mirror_require /usr/bin/codesign
mirror_require /usr/sbin/spctl
mirror_require /usr/bin/hdiutil
mirror_require /usr/bin/osascript

CLAUDE_VERSION=$(/usr/bin/plutil -extract claude_code.version raw -o - "$MIRROR_REPO_ROOT/manifests/stable.json") || mirror_die "missing Claude version"
CLASH_VERSION=$(/usr/bin/plutil -extract clash_verge.version raw -o - "$MIRROR_REPO_ROOT/manifests/stable.json") || mirror_die "missing Clash version"
CLAUDE_DIR="$MIRROR_WORK_DIR/claude-code/releases/$CLAUDE_VERSION"
CLASH_DIR="$MIRROR_WORK_DIR/clash-verge/releases/v$CLASH_VERSION"
PUBLISHER_ARCH=$(/usr/bin/uname -m)
MANIFEST="$CLAUDE_DIR/manifest.json"
MANIFEST_SIG="$CLAUDE_DIR/manifest.json.sig"
PUBLIC_KEY="$CLAUDE_DIR/audit/claude-code.asc"

for required_file in "$MANIFEST" "$MANIFEST_SIG" "$PUBLIC_KEY"; do
  [ -f "$required_file" ] || mirror_die "missing verification input: $required_file"
done
GNUPG_HOME="$CLAUDE_DIR/audit/verify-gnupg"
/bin/mkdir -p "$GNUPG_HOME" || mirror_die "cannot create GPG verification home"
/bin/chmod 700 "$GNUPG_HOME" || mirror_die "cannot protect GPG verification home"
GNUPGHOME="$GNUPG_HOME" gpg --batch --import "$PUBLIC_KEY" >/dev/null 2>&1 || true
fingerprint=$(GNUPGHOME="$GNUPG_HOME" gpg --batch --with-colons --fingerprint security@anthropic.com |
  /usr/bin/awk -F: '$1=="fpr"{print $10; exit}')
[ "$fingerprint" = "31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE" ] || mirror_die "Claude key fingerprint mismatch"
GNUPGHOME="$GNUPG_HOME" gpg --batch --verify "$MANIFEST_SIG" "$MANIFEST" >"$CLAUDE_DIR/audit/manifest-gpg-recheck.txt" 2>&1 ||
  mirror_die "Claude manifest signature failed"

for platform in darwin-arm64 darwin-x64 win32-arm64 win32-x64; do
  checksum=$(/usr/bin/plutil -extract "platforms.${platform}.checksum" raw -o - "$MANIFEST") || mirror_die "manifest missing $platform"
  size=$(/usr/bin/plutil -extract "platforms.${platform}.size" raw -o - "$MANIFEST") || mirror_die "manifest missing size"
  case "$platform" in
    darwin-arm64) file="$CLAUDE_DIR/claude-darwin-arm64" ;;
    darwin-x64) file="$CLAUDE_DIR/claude-darwin-x64" ;;
    win32-arm64) file="$CLAUDE_DIR/claude-win32-arm64.exe" ;;
    win32-x64) file="$CLAUDE_DIR/claude-win32-x64.exe" ;;
  esac
  [ -f "$file" ] || mirror_die "missing Claude artifact: $file"
  [ "$(mirror_sha256 "$file")" = "$checksum" ] || mirror_die "Claude hash mismatch: $platform"
  [ "$(mirror_size "$file")" = "$size" ] || mirror_die "Claude size mismatch: $platform"
  case "$platform" in
    darwin-*)
      /usr/bin/codesign --verify --strict --verbose=2 "$file" >/dev/null 2>&1 || mirror_die "Claude codesign failed: $platform"
      signature_info=$(/usr/bin/codesign -d --verbose=4 "$file" 2>&1) || mirror_die "cannot read Claude identity"
      printf '%s\n' "$signature_info" >"$CLAUDE_DIR/audit/codesign-${platform}.txt"
      printf '%s\n' "$signature_info" | /usr/bin/grep -Fqx 'Identifier=com.anthropic.claude-code' || mirror_die "Claude identifier mismatch"
      printf '%s\n' "$signature_info" | /usr/bin/grep -Fqx 'TeamIdentifier=Q6L2SF6YDW' || mirror_die "Claude Team ID mismatch"
      /usr/sbin/spctl --assess --type execute --verbose=4 "$file" >"$CLAUDE_DIR/audit/spctl-${platform}.txt" 2>&1 || true
      if { [ "$platform" = darwin-arm64 ] && [ "$PUBLISHER_ARCH" = arm64 ]; } ||
         { [ "$platform" = darwin-x64 ] && [ "$PUBLISHER_ARCH" = x86_64 ]; }; then
        "$file" --version 2>/dev/null | /usr/bin/head -n 1 | /usr/bin/grep -Fq "$CLAUDE_VERSION" || mirror_die "Claude version mismatch"
      else
        mirror_say "pending native-host version execution: Claude $platform"
      fi
      ;;
  esac
  mirror_say "verified Claude $platform: $checksum"
done

TAURI_PUBLIC_B64='dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IEQyOEMyRjBCQkVGOUJEREYKUldUZnZmbStDeStNMHU5Mmo1N24xQXZwSVRYbXA2NUpzZE5oVzlqeS9Bc0t6RVV4MmtwVjBZaHgK'
TAURI_PUBLIC="$CLASH_DIR/audit/tauri-minisign.pub"
printf '%s' "$TAURI_PUBLIC_B64" | /usr/bin/base64 -D >"$TAURI_PUBLIC" || mirror_die "cannot decode Tauri public key"
for arch in arm64 x64; do
  installer="$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_${arch}-setup.exe"
  signature_b64="${installer}.sig"
  signature="$CLASH_DIR/audit/Clash.Verge_${CLASH_VERSION}_${arch}-setup.exe.minisig"
  [ -f "$installer" ] && [ -f "$signature_b64" ] || mirror_die "missing Windows Clash installer/signature"
  /usr/bin/base64 -D -i "$signature_b64" -o "$signature" || mirror_die "cannot decode Tauri signature"
  minisign -Vm "$installer" -p "$TAURI_PUBLIC" -x "$signature" >/dev/null 2>&1 || mirror_die "Tauri minisign verification failed: $arch"
  mirror_say "verified Clash Tauri signature: win32-$arch"
done

MOUNT_POINT=""
cleanup_mount() {
  if [ -n "$MOUNT_POINT" ]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
    MOUNT_POINT=""
  fi
}
trap cleanup_mount EXIT INT TERM HUP

for arch in aarch64 x64; do
  dmg="$CLASH_DIR/Clash.Verge_${CLASH_VERSION}_${arch}.dmg"
  [ -f "$dmg" ] || mirror_die "missing Clash DMG: $dmg"
  attach_plist="$CLASH_DIR/audit/hdiutil-${arch}.plist"
  /usr/bin/hdiutil attach "$dmg" -nobrowse -readonly -plist >"$attach_plist" || mirror_die "cannot mount Clash DMG: $arch"
  MOUNT_POINT=$(/usr/bin/osascript -l JavaScript - "$attach_plist" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  var value = $.NSDictionary.dictionaryWithContentsOfFile(argv[0]);
  var entities = value && value.objectForKey('system-entities');
  if (!entities) throw new Error('missing entities');
  for (var i = 0; i < entities.count; i += 1) {
    var point = entities.objectAtIndex(i).objectForKey('mount-point');
    if (point) return ObjC.unwrap(point);
  }
  throw new Error('missing mount point');
}
JXA
  ) || mirror_die "cannot determine Clash mount point"
  app="$MOUNT_POINT/Clash Verge.app"
  [ -d "$app" ] || mirror_die "Clash Verge.app missing from DMG"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >"$CLASH_DIR/audit/codesign-verify-${arch}.txt" 2>&1 || mirror_die "Clash codesign failed: $arch"
  /usr/bin/codesign -d --verbose=4 "$app" >"$CLASH_DIR/audit/codesign-identity-${arch}.txt" 2>&1 || mirror_die "cannot read Clash signing identity: $arch"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$app" >"$CLASH_DIR/audit/spctl-${arch}.txt" 2>&1 || mirror_die "Clash Gatekeeper failed: $arch"
  app_version=$(/usr/bin/defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null) || mirror_die "cannot read Clash version"
  [ "$app_version" = "$CLASH_VERSION" ] || mirror_die "Clash version mismatch: $arch"
  /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || mirror_die "cannot detach Clash DMG"
  MOUNT_POINT=""
  mirror_say "verified Clash macOS $arch: codesign + spctl"
done

[ -f "$CLASH_DIR/LICENSE" ] && /usr/bin/grep -Fq 'GNU GENERAL PUBLIC LICENSE' "$CLASH_DIR/LICENSE" || mirror_die "Clash GPL license missing"
[ -f "$CLASH_DIR/SOURCE.txt" ] && /usr/bin/grep -Fq "tree/v$CLASH_VERSION" "$CLASH_DIR/SOURCE.txt" || mirror_die "Clash source metadata missing"
mirror_say "macOS and upstream signature verification complete"
mirror_say "pending: run verify-artifacts.ps1 on real Windows x64 and ARM64 hosts"
