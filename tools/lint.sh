#!/usr/bin/env bash
#
# CODM Optimizer - static checks
#
# Runs without a phone.  Catches the mistakes that actually break Magisk
# modules: CRLF line endings, a malformed module.prop, a non-executable
# boot script, bashisms that busybox ash cannot parse.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODULE_DIR=$ROOT/module
fails=0

fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }
ok()   { printf '  \033[32m ok \033[0m %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }

# shell parser: prefer busybox ash (what Magisk actually uses)
if command -v busybox >/dev/null 2>&1 && busybox sh -c 'true' 2>/dev/null; then
    SH_CHECK="busybox sh"
else
    SH_CHECK="sh"
fi

echo "shell syntax ($SH_CHECK)"

files=(
    "$MODULE_DIR/customize.sh"
    "$MODULE_DIR/post-fs-data.sh"
    "$MODULE_DIR/service.sh"
    "$MODULE_DIR/uninstall.sh"
    "$MODULE_DIR/action.sh"
    "$MODULE_DIR/system/bin/codm-optimizer"
)
while IFS= read -r f; do files+=("$f"); done < <(find "$MODULE_DIR/common" -name '*.sh' | sort)

for f in "${files[@]}"; do
    [ -f "$f" ] || { fail "missing $f"; continue; }
    if $SH_CHECK -n "$f" 2>/dev/null; then
        :
    else
        fail "syntax error in ${f#"$ROOT"/}"
        $SH_CHECK -n "$f" || true
    fi
done
[ "$fails" -eq 0 ] && ok "${#files[@]} scripts parse"

echo "line endings"
if grep -rlI $'\r' "$MODULE_DIR" >/dev/null 2>&1; then
    fail "CRLF found in:"
    grep -rlI $'\r' "$MODULE_DIR" | sed 's/^/        /'
else
    ok "all files are LF"
fi

echo "module.prop"
prop=$MODULE_DIR/module.prop
if [ ! -f "$prop" ]; then
    fail "module.prop missing"
else
    id=$(sed -n 's/^id=//p' "$prop")
    if printf '%s' "$id" | grep -Eq '^[a-zA-Z][a-zA-Z0-9._-]+$'; then
        ok "id=$id"
    else
        fail "invalid id '$id' (must match ^[a-zA-Z][a-zA-Z0-9._-]+\$)"
    fi
    for key in name version versionCode author description; do
        if ! grep -q "^${key}=." "$prop"; then
            fail "module.prop: $key is empty or missing"
        fi
    done
    vc=$(sed -n 's/^versionCode=//p' "$prop")
    if printf '%s' "$vc" | grep -Eq '^[0-9]+$'; then
        ok "versionCode=$vc"
    else
        fail "versionCode must be an integer (got '$vc')"
    fi
    if grep -q '^updateJson=' "$prop"; then
        warn "updateJson is set - make sure the URL serves the correct JSON"
    fi
fi

echo "boot scripts"
for s in customize.sh post-fs-data.sh service.sh uninstall.sh action.sh; do
    if [ -x "$MODULE_DIR/$s" ]; then
        ok "$s is executable"
    else
        fail "$s is not executable"
    fi
done
if [ -f "$MODULE_DIR/skip_mount" ]; then
    fail "skip_mount exists but the module ships files under system/"
fi

echo "installer wrapper"
for f in META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script; do
    [ -f "$MODULE_DIR/$f" ] && ok "$f" || fail "$f missing"
done
grep -qx '#MAGISK' "$MODULE_DIR/META-INF/com/google/android/updater-script" ||
    fail "updater-script must contain exactly #MAGISK"

echo "portability"
# busybox ash has no [[ ]], no 'local' guarantee, no arrays, no ==
if grep -rnI -E '^\s*\[\[|^\s*function [a-z_]+\(\)|declare -|local ' "$MODULE_DIR" \
    --include='*.sh' | grep -v '^Binary' ; then
    fail "bashisms found (see above)"
else
    ok "no bashisms"
fi
if grep -rnI '\bread -[a-z]*p\b' "$MODULE_DIR" --include='*.sh'; then
    warn "'read -p' is not portable, use printf+read"
fi

echo "dangerous patterns"
# config files are user editable, so no script may eval them
if grep -rnI '\beval\b' "$MODULE_DIR" --include='*.sh' \
    --include='codm-optimizer' ; then
    fail "eval is forbidden (config files must be parsed, not executed)"
else
    ok "no eval"
fi
# a bare 'exit' in customize.sh cancels the installer's finalisation
if grep -nE '^\s*exit [0-9]+' "$MODULE_DIR/customize.sh"; then
    fail "customize.sh must not call exit"
else
    ok "customize.sh does not exit"
fi
# writing to /system directly instead of the module's own tree
if grep -rnI -E '>\s*/system/|>\s*/vendor/' "$MODULE_DIR" --include='*.sh'; then
    fail "direct writes to /system or /vendor are forbidden"
else
    ok "no direct /system writes"
fi
if grep -rnI -E 'rm -rf\s+/(\s|$|system|data(\s|$))' "$MODULE_DIR" --include='*.sh'; then
    fail "suspicious rm -rf / target"
else
    ok "no suspicious rm -rf targets"
fi

echo
if [ "$fails" -gt 0 ]; then
    printf '\033[31m%s check(s) failed\033[0m\n' "$fails"
    exit 1
fi
printf '\033[32mall checks passed\033[0m\n'
