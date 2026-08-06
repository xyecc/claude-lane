#!/bin/bash

# Compatibility stub. The former 239MB+ hand-carried bundle is intentionally
# retired. Windows validation now downloads immutable candidate objects from
# domestic OSS and downloads Claude Code from Anthropic only after Clash works.

set -u
set -o pipefail

case "${1:-}" in
  -h|--help|"")
    printf '%s\n' 'retired: no Windows validation bundle is created'
    printf '%s\n' 'use the versioned OSS bootstrap candidate on each Windows test host'
    exit 0
    ;;
  --execute)
    printf '%s\n' 'error: portable Windows validation bundles are retired; refusing to recreate the large package' >&2
    exit 1
    ;;
  *)
    printf '%s\n' "error: unknown argument: $1" >&2
    exit 2
    ;;
esac
