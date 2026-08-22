#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-workspace.sh
#
# Initialises the Volla Quintus (algiz) kernel workspace using `repo`.
#
# Base manifest : https://android.googlesource.com/kernel/manifest -b common-android15-6.6
# Local manifest: local_manifests/algiz.xml (vendored copy of
#                 HelloVolla/android_kernel_manifest @ volla-16.0-algiz)
#
# Usage: scripts/setup-workspace.sh <workspace-dir> <path-to-algiz.xml>
# ---------------------------------------------------------------------------
set -euo pipefail

WORKSPACE="${1:?usage: setup-workspace.sh <workspace-dir> <algiz.xml>}"
LOCAL_MANIFEST="${2:?usage: setup-workspace.sh <workspace-dir> <algiz.xml>}"

MANIFEST_URL="${MANIFEST_URL:-https://android.googlesource.com/kernel/manifest}"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-common-android15-6.6}"
SYNC_JOBS="${SYNC_JOBS:-$(nproc)}"
# Shallow by default: the five Volla trees plus the AOSP prebuilts are ~5 GB of
# working tree; full history would be several times that and CI disk is tight.
DEPTH_ARGS="${DEPTH_ARGS:---depth=1}"

LOCAL_MANIFEST="$(readlink -f "$LOCAL_MANIFEST")"
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

if ! command -v repo >/dev/null 2>&1; then
  echo "==> Installing the repo launcher into ~/.bin"
  mkdir -p "$HOME/.bin"
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
    -o "$HOME/.bin/repo"
  chmod a+x "$HOME/.bin/repo"
  export PATH="$HOME/.bin:$PATH"
fi

git config --global --get user.email >/dev/null 2>&1 || \
  git config --global user.email "kernel-ci@localhost"
git config --global --get user.name >/dev/null 2>&1 || \
  git config --global user.name "kernel-ci"
git config --global advice.detachedHead false

echo "==> repo init ($MANIFEST_BRANCH)"
# --no-use-superproject: the AOSP manifest declares <superproject>, which does
# not compose with the <remove-project> entries in the local manifest.
repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" \
  --no-use-superproject --no-clone-bundle --no-tags $DEPTH_ARGS

echo "==> Installing local manifest"
mkdir -p .repo/local_manifests
cp "$LOCAL_MANIFEST" .repo/local_manifests/algiz.xml

echo "==> repo sync (-j$SYNC_JOBS)"
repo sync -c -j"$SYNC_JOBS" --no-tags --no-clone-bundle \
  --optimized-fetch --prune --force-sync --fail-fast

echo "==> Verifying expected project layout"
fail=0
for p in build/kernel build/bazel_mgk_rules kernel-6.6 \
         kernel_device_modules-6.6 vendor/mediatek/kernel_modules \
         prebuilts/clang/host/linux-x86 prebuilts/build-tools \
         prebuilts/jdk/jdk11 tools/mkbootimg; do
  if [ -d "$p" ]; then
    echo "  ok      $p"
  else
    echo "  MISSING $p"
    fail=1
  fi
done
for l in tools/bazel WORKSPACE build.config; do
  if [ -e "$l" ]; then
    echo "  ok      $l -> $(readlink -f "$l" 2>/dev/null || echo '?')"
  else
    echo "  MISSING $l (manifest linkfile)"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || { echo "ERROR: workspace layout incomplete"; exit 1; }

echo "==> Kernel version: $(sed -n 's/^VERSION = //p;' kernel-6.6/Makefile | head -1).$(sed -n 's/^PATCHLEVEL = //p' kernel-6.6/Makefile | head -1).$(sed -n 's/^SUBLEVEL = //p' kernel-6.6/Makefile | head -1)"
echo "==> Workspace ready: $(pwd)"
