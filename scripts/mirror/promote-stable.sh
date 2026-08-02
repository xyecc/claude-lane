#!/bin/bash

# Explicit, failure-closed stable promotion. No implicit release or overwrite.

set -u
set -o pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

CANDIDATE="$MIRROR_WORK_DIR/manifests/stable.candidate.json"
PROFILE=primary

usage() { printf '%s\n' '用法：bash scripts/mirror/promote-stable.sh [--execute] [--candidate <path>] [--profile primary|backup]'; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --execute) MIRROR_EXECUTE=1 ;;
    --candidate) [ "$#" -ge 2 ] || mirror_die "--candidate requires a value"; CANDIDATE=$2; shift ;;
    --profile) [ "$#" -ge 2 ] || mirror_die "--profile requires a value"; PROFILE=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) mirror_die "unknown argument: $1" ;;
  esac
  shift
done

[ -f "$CANDIDATE" ] || mirror_die "candidate manifest not found"
/usr/bin/plutil -convert xml1 -o /dev/null "$CANDIDATE" >/dev/null 2>&1 || mirror_die "candidate is not valid JSON"
status=$(/usr/bin/plutil -extract release_status raw -o - "$CANDIDATE") || mirror_die "candidate has no release status"
[ "$status" = released ] || mirror_die "candidate remains blocked; promotion refused"
blocker_count=$(/usr/bin/plutil -extract release_blockers xml1 -o - "$CANDIDATE" 2>/dev/null | /usr/bin/grep -c '<string>' || true)
[ "$blocker_count" = 0 ] || mirror_die "candidate still contains release blockers"
for key in distribution.primary.base_url distribution.backup.base_url; do
  value=$(/usr/bin/plutil -extract "$key" raw -o - "$CANDIDATE" 2>/dev/null || true)
  case "$value" in https://*) ;; *) mirror_die "$key is not a released HTTPS gateway" ;; esac
done
for key in claude_code.win32_arm64.signature_status claude_code.win32_x64.signature_status clash_verge.win32_arm64.signature_status clash_verge.win32_x64.signature_status; do
  [ "$(/usr/bin/plutil -extract "$key" raw -o - "$CANDIDATE" 2>/dev/null)" = verified-authenticode ] || mirror_die "$key is not verified"
done
[ -z "$(/usr/bin/git -C "$MIRROR_REPO_ROOT" status --porcelain 2>/dev/null)" ] || mirror_die "repository must be clean before stable promotion"

if [ "$MIRROR_EXECUTE" != 1 ]; then
  mirror_say "dry-run: all promotion gates passed; would upload immutable manifests/stable.json"
  exit 0
fi
exec /bin/bash "$SCRIPT_DIR/upload.sh" --execute --profile "$PROFILE" --file "$CANDIDATE" --key manifests/stable.json
