#!/usr/bin/env bash
#
# CODM Optimizer - module builder
#
#   ./build.sh              lint, test and build dist/codm-optimizer-<ver>.zip
#   ./build.sh --fast       build only
#
# The zip contains the contents of module/ at its root, which is what
# Magisk, KernelSU and APatch expect.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
MODULE_DIR=$ROOT/module
DIST_DIR=$ROOT/dist
FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

version=$(sed -n 's/^version=//p' "$MODULE_DIR/module.prop" | head -1)
version_code=$(sed -n 's/^versionCode=//p' "$MODULE_DIR/module.prop" | head -1)
: "${version:=v0.0.0}"
: "${version_code:=0}"

name="codm-optimizer-${version}.zip"

if [ "$FAST" = 0 ]; then
    echo "==> lint"
    "$ROOT/tools/lint.sh"
    echo "==> tests"
    "$ROOT/tools/test.sh"
fi

echo "==> building $name"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -a "$MODULE_DIR"/. "$tmp"/

# never ship editor and VCS leftovers
find "$tmp" -name '.DS_Store' -o -name '*~' -o -name '*.bak' -o -name '*.orig' |
    while IFS= read -r f; do rm -f "$f"; done

# normalise line endings (Magisk parses module.prop strictly)
find "$tmp" -type f \( -name '*.sh' -o -name 'module.prop' -o -name '*.conf' \
    -o -name 'codm-optimizer' -o -name 'updater-script' -o -name 'update-binary' \) |
    while IFS= read -r f; do
        sed -i 's/\r$//' "$f"
    done

# permissions that survive the zip
find "$tmp" -type f -name '*.sh' -exec chmod 0755 {} +
chmod 0755 "$tmp/META-INF/com/google/android/update-binary"
chmod 0755 "$tmp/system/bin/codm-optimizer"
find "$tmp" -type f ! -perm -u+x -exec chmod 0644 {} +

(cd "$tmp" && zip -r -X -q "$DIST_DIR/$name" . -x '.*')

cat >"$DIST_DIR/$name.sha256" <<EOF
$(cd "$DIST_DIR" && sha256sum "$name" | cut -d' ' -f1)  $name
EOF

echo
echo "  file        dist/$name"
echo "  version     $version (versionCode $version_code)"
echo "  size        $(du -h "$DIST_DIR/$name" | cut -f1)"
echo "  sha256      $(cut -d' ' -f1 "$DIST_DIR/$name.sha256")"
echo
echo "  install:    Magisk app -> Modules -> Install from storage"
echo "              or: adb push dist/$name /sdcard/Download/ &&"
echo "                  adb shell su -c 'magisk --install-module /sdcard/Download/$name'"
