#!/usr/bin/env sh
# Build the hardware firmware via GitHub Actions CI (Linux) and download the
# flashable .uf2. Use this INSTEAD of building locally on macOS — local macOS
# hardware builds produce a binary that boots but does not drive the LCD.
#
# What it does:
#   1. Ensures you're on custom-firmware-pro-custom (the firmware branch).
#   2. Commits any uncommitted config changes (so CI builds current state).
#   3. Pushes to the fork (triggers the Build workflow on push).
#   4. Waits for the sensorwatch_pro + custom job to finish.
#   5. Downloads the artifact to firmware-prebuilt/ci/firmware.uf2.
#
# Then: double-tap reset to mount WATCHBOOT, drag firmware-prebuilt/ci/firmware.uf2
# onto it.
#
# Prereqs: gh CLI authed; Actions enabled on the fork (one-time, via the Actions
# tab "I understand my workflows, go ahead and enable them").
set -e

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT"

BRANCH="custom-firmware-pro-custom"
FORK_REMOTE="fork"
ARTIFACT_NAME="sensorwatch_pro-display-custom-movement.uf2"
OUT_DIR="firmware-prebuilt/ci"
OUT_FILE="$OUT_DIR/firmware.uf2"
REPO="h6y3/second-movement"

# Sanity: remotes.
git remote get-url "$FORK_REMOTE" >/dev/null 2>&1 || {
  echo "build-via-ci.sh: remote '$FORK_REMOTE' not found (expected h6y3/second-movement)" >&2
  exit 1
}

echo "==> ensuring branch $BRANCH"
git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"

# Commit any uncommitted config changes (exclude the gossamer submodule).
if ! git diff --quiet --ignore-submodules || ! git diff --cached --quiet --ignore-submodules; then
  echo "==> uncommitted changes present; committing (excluding gossamer submodule)"
  git add -u -- . ':!gossamer'
  git commit -m "Update firmware config (CI build trigger)" >/dev/null
else
  echo "==> working tree clean (ignoring gossamer submodule)"
fi

echo "==> pushing to $FORK_REMOTE (triggers Build workflow)"
PUSH_OUTPUT=$(git push "$FORK_REMOTE" "$BRANCH" 2>&1) || true
echo "$PUSH_OUTPUT"
PUSHED_NEW=$(echo "$PUSH_OUTPUT" | grep -E "^[[:space:]]*[a-f0-9]{7,}\.\." | head -1)

echo "==> finding the latest Build run for $BRANCH"
RUN_ID=$(gh api "repos/$REPO/actions/runs?per_page=10&branch=$BRANCH" \
  --jq '.workflow_runs[] | select(.name=="Build") | .id' | head -1)
if [ -z "$RUN_ID" ]; then
  echo "build-via-ci.sh: no Build run found for branch $BRANCH." >&2
  echo "If push said 'Everything up-to-date' and no run exists, make an empty commit to trigger one:" >&2
  echo "  git commit --allow-empty -m 'trigger CI' && git push $FORK_REMOTE $BRANCH" >&2
  exit 1
fi
echo "==> watching run $RUN_ID (this takes a few minutes)"
gh run watch "$RUN_ID" --repo "$REPO" --exit-status >/dev/null

echo "==> checking run conclusion"
CONCLUSION=$(gh api "repos/$REPO/actions/runs/$RUN_ID" --jq '.conclusion')
if [ "$CONCLUSION" != "success" ]; then
  echo "build-via-ci.sh: Build run $RUN_ID concluded '$CONCLUSION' (not success)." >&2
  echo "Inspect: gh run view $RUN_ID --repo $REPO --log-failed" >&2
  exit 1
fi

echo "==> downloading artifact '$ARTIFACT_NAME'"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$ARTIFACT_NAME" "$OUT_FILE"
gh run download "$RUN_ID" --repo "$REPO" --name "$ARTIFACT_NAME" --dir "$OUT_DIR"

# The artifact is a zip containing firmware.uf2; gh run download unzips it.
if [ -f "$OUT_DIR/firmware.uf2" ]; then
  echo "==> done. Flash file: $OUT_FILE"
  echo "    size: $(stat -f '%z' "$OUT_FILE" 2>/dev/null || stat -c '%s' "$OUT_FILE") bytes"
  echo "    sha256: $(shasum -a 256 "$OUT_FILE" | cut -d' ' -f1)"
  echo "==> next: double-tap reset to mount WATCHBOOT, then:"
  echo "    cp $OUT_FILE /Volumes/WATCHBOOT/"
else
  echo "build-via-ci.sh: artifact downloaded but firmware.uf2 not found in $OUT_DIR" >&2
  ls -la "$OUT_DIR" >&2
  exit 1
fi