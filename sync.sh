#!/usr/bin/env sh
# Sync your custom firmware branch with upstream and push to your fork.
#
# Model:
#   origin (joeycastillo/second-movement) = upstream truth
#   fork   (h6y3/second-movement)        = where your work is pushed
#   branch custom-firmware-pro-custom    = upstream main + your 3-file patch,
#                                          kept linear via rebase.
#
# Usage: ./sync.sh [branch]    (default branch: custom-firmware-pro-custom)
set -e

BRANCH="${1:-custom-firmware-pro-custom}"
UPSTREAM_REMOTE="origin"
FORK_REMOTE="fork"

# Resolve repo root (script may be run from anywhere).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "sync.sh: not inside a git repository" >&2
  exit 1
}
cd "$REPO_ROOT"

# Sanity: remotes exist.
git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 || {
  echo "sync.sh: remote '$UPSTREAM_REMOTE' not found" >&2
  exit 1
}
git remote get-url "$FORK_REMOTE" >/dev/null 2>&1 || {
  echo "sync.sh: remote '$FORK_REMOTE' not found (expected: git@github.com:h6y3/second-movement.git)" >&2
  exit 1
}

echo "==> fetching upstream ($UPSTREAM_REMOTE)"
git fetch "$UPSTREAM_REMOTE"

echo "==> checking out $BRANCH"
git checkout "$BRANCH"

echo "==> rebasing onto $UPSTREAM_REMOTE/main"
if git rebase "$UPSTREAM_REMOTE/main"; then
  echo "==> rebase clean; pushing to $FORK_REMOTE (force-with-lease, branch is rebased)"
  git push "$FORK_REMOTE" "$BRANCH" --force-with-lease
  echo "==> done. firmware branch is now upstream main + your patch."
  echo "    build: make BOARD=sensorwatch_pro DISPLAY=custom"
else
  cat >&2 <<EOF

==> rebase stopped (conflict or pause).

Resolve the conflicted files, then:
  git add <files>
  git rebase --continue

To abort and return to the pre-rebase state:
  git rebase --abort

Your patch touches: Makefile, movement_config.h, watch-faces/complication/timer_face.c
Conflicts there are usually small (array line, presets line, Makefile tail).
EOF
  exit 1
fi