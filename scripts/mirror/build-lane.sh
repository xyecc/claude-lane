#!/bin/bash

# Build reproducible-ish repository archives from a clean, reviewed Git commit.
# Default is dry-run; --execute refuses dirty or untracked release inputs.

set -u
set -o pipefail
umask 077

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/common.sh"

mirror_parse_common_args "$@"
parse_status=$?
if [ "$parse_status" = "2" ]; then
  printf '%s\n' 'usage: bash scripts/mirror/build-lane.sh [--version X.Y.Z] [--work-dir DIR] [--execute]'
  exit 0
fi
if [ -z "$MIRROR_VERSION" ]; then
  MIRROR_VERSION=$(/usr/bin/tr -d '\r\n ' <"$MIRROR_REPO_ROOT/VERSION")
fi
mirror_valid_version "$MIRROR_VERSION" || mirror_die "invalid claude-lane version"
DEST="$MIRROR_WORK_DIR/claude-lane/releases/v$MIRROR_VERSION"
mirror_say "lane tar: $DEST/claude-lane.tar.gz"
[ "$MIRROR_EXECUTE" = "1" ] || { mirror_say "dry-run: no archives built"; exit 0; }

mirror_require git
mirror_require /usr/bin/tar
cd "$MIRROR_REPO_ROOT" || mirror_die "cannot enter repository"
git diff --quiet -- . || mirror_die "working tree has tracked changes; commit/review before building release archives"
git diff --cached --quiet -- . || mirror_die "index has staged changes; commit/review before building release archives"
[ -z "$(git ls-files --others --exclude-standard)" ] || mirror_die "working tree has untracked release inputs; commit/review before building"
head_version=$(git show HEAD:VERSION 2>/dev/null | /usr/bin/tr -d '\r\n ') || mirror_die "HEAD has no VERSION"
[ "$head_version" = "$MIRROR_VERSION" ] || mirror_die "HEAD VERSION does not match requested release"
/bin/mkdir -p "$DEST" || mirror_die "cannot create lane artifact directory"
[ ! -e "$DEST/claude-lane.tar.gz" ] || mirror_die "lane archive already exists; immutable output will not be overwritten"
HEAD_TREE=$(git rev-parse 'HEAD^{tree}') || mirror_die "cannot resolve release tree"
# Only runtime files enter the target machine. Excluding bootstrap.sh,
# manifests/stable.json and publisher tooling also avoids a circular digest:
# the outer bootstrap pins the manifest, while the manifest pins this archive.
# Archiving the tree object (not the commit) avoids Git embedding a commit ID
# in the PAX header, so manifest-only commits do not perturb runtime bytes.
git archive --format=tar --mtime='1970-01-01T00:00:00Z' \
  --prefix="claude-lane-$MIRROR_VERSION/" "$HEAD_TREE" -- \
  VERSION LICENSE README.md RUNBOOK.md CLAUDE.md AGENTS.md QWEN.md \
  docs/account-safety.md docs/iphone-notes.md docs/manual-setup.md \
  docs/porting.md docs/troubleshooting.md \
  scripts/backup.sh scripts/bootstrap-complete.sh scripts/macos-json.js \
  scripts/profile-config.sh scripts/rollback.sh scripts/selftest.sh \
  scripts/set-credentials.sh scripts/verify.sh templates |
  /usr/bin/gzip -n >"$DEST/claude-lane.tar.gz" || mirror_die "cannot build lane tarball"
printf 'commit=%s\ntree=%s\ntar_sha256=%s\n' \
  "$(git rev-parse HEAD)" "$HEAD_TREE" "$(mirror_sha256 "$DEST/claude-lane.tar.gz")" >"$DEST/evidence.txt"
mirror_say "built immutable lane archives from commit $(git rev-parse --short HEAD)"
