#!/system/bin/sh
#
# CODM Optimizer - late_start service
#
# Starts the engine once, after boot has settled and /data is readable.
# Everything else (profile decisions, thermal guard, restoring) happens
# inside engine.sh.

MODDIR=${0%/*}
DATA_DIR=/data/adb/codm-optimizer

# Wait for boot_completed, but never longer than a minute: some devices
# set it late and we would rather start with a partial boot than hang.
i=0
while [ "$i" -lt 60 ]; do
    [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] && break
    sleep 1
    i=$((i + 1))
done

# Give the launcher and the vendor's own "game booster" a moment to
# settle so we are the last writer, not the first.
sleep 5

[ -f "$MODDIR/common/engine.sh" ] || exit 0

# Do not start a second engine.
if [ -f "$DATA_DIR/run/engine.pid" ]; then
    pid=$(cat "$DATA_DIR/run/engine.pid" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        exit 0
    fi
fi

# Respect the user's on/off switch before starting anything.
enabled=1
if [ -f "$DATA_DIR/config.conf" ]; then
    enabled=$(sed -n 's/^ENGINE_ENABLED=//p' "$DATA_DIR/config.conf" 2>/dev/null | tail -1)
    case $enabled in
        0|no|false) enabled=0 ;;
        *) enabled=1 ;;
    esac
fi
[ "$enabled" = 1 ] || exit 0

mkdir -p "$DATA_DIR/logs" "$DATA_DIR/run" 2>/dev/null
printf '%s start requested by service.sh\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
    >>"$DATA_DIR/logs/module.log" 2>/dev/null

if command -v setsid >/dev/null 2>&1; then
    setsid sh "$MODDIR/common/engine.sh" </dev/null >/dev/null 2>&1 &
else
    sh "$MODDIR/common/engine.sh" </dev/null >/dev/null 2>&1 &
fi

exit 0
