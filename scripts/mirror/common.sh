#!/bin/bash

# Shared publisher-side helpers. Keep compatible with macOS Bash 3.2.

set -u
set -o pipefail
umask 077

MIRROR_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MIRROR_REPO_ROOT=$(cd "$MIRROR_SCRIPT_DIR/../.." && pwd)
MIRROR_WORK_DIR=${CLAUDE_LANE_MIRROR_WORK_DIR:-$MIRROR_REPO_ROOT/.mirror-work}
MIRROR_EXECUTE=0

mirror_say() {
  printf '%s\n' "$*"
}

mirror_warn() {
  printf 'warning: %s\n' "$*" >&2
}

mirror_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

mirror_require() {
  command -v "$1" >/dev/null 2>&1 || mirror_die "missing publisher dependency: $1"
}

mirror_sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

mirror_size() {
  /usr/bin/stat -f '%z' "$1"
}

mirror_valid_version() {
  printf '%s' "$1" | LC_ALL=C /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

mirror_valid_sha256() {
  printf '%s' "$1" | LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{64}$'
}

mirror_download() {
  mirror_url=$1
  mirror_dest=$2
  mirror_expected_sha=${3:-}
  mirror_label=${4:-artifact}
  mirror_part="${mirror_dest}.part.$$"

  if [ -f "$mirror_dest" ]; then
    if [ -z "$mirror_expected_sha" ]; then
      mirror_say "reuse existing ${mirror_label}; downstream verification is still required: ${mirror_dest}"
      return 0
    fi
    if [ -n "$mirror_expected_sha" ] &&
       [ "$(mirror_sha256 "$mirror_dest")" = "$mirror_expected_sha" ]; then
      mirror_say "reuse verified ${mirror_label}: ${mirror_dest}"
      return 0
    fi
    mirror_die "existing ${mirror_label} does not match the fixed digest: ${mirror_dest}"
  fi

  /bin/mkdir -p "$(dirname "$mirror_dest")" || mirror_die "cannot create artifact directory"
  /bin/rm -f -- "$mirror_part" 2>/dev/null || true
  if ! /usr/bin/curl -q --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
      --connect-timeout 10 --max-time 1200 --retry 2 --retry-delay 2 \
      --output "$mirror_part" "$mirror_url"; then
    /bin/rm -f -- "$mirror_part" 2>/dev/null || true
    mirror_die "download failed for ${mirror_label}"
  fi
  if [ -n "$mirror_expected_sha" ]; then
    mirror_actual_sha=$(mirror_sha256 "$mirror_part") || mirror_die "cannot hash ${mirror_label}"
    [ "$mirror_actual_sha" = "$mirror_expected_sha" ] || {
      /bin/rm -f -- "$mirror_part" 2>/dev/null || true
      mirror_die "SHA-256 mismatch for ${mirror_label}"
    }
  fi
  /bin/mv -- "$mirror_part" "$mirror_dest" || mirror_die "cannot finalize ${mirror_label}"
}

mirror_parse_common_args() {
  MIRROR_VERSION=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --execute) MIRROR_EXECUTE=1 ;;
      --version)
        [ "$#" -ge 2 ] || mirror_die "--version requires a value"
        MIRROR_VERSION=$2
        shift
        ;;
      --work-dir)
        [ "$#" -ge 2 ] || mirror_die "--work-dir requires a value"
        MIRROR_WORK_DIR=$2
        shift
        ;;
      -h|--help) return 2 ;;
      *) mirror_die "unknown argument: $1" ;;
    esac
    shift
  done
}
