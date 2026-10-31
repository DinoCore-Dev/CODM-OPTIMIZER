#!/system/bin/sh
#
# CODM Optimizer - uninstall
#
# Order matters: stop the engine, put back every knob it saved, remove
# the Game Mode overrides, and only then delete the data directory.

MODDIR=${0%/*}
DATA_DIR=/data/adb/codm-optimizer

. "$MODDIR/common/const.sh"
. "$MODDIR/common/log.sh"
. "$MODDIR/common/util.sh"
. "$MODDIR/common/game.sh"
. "$MODDIR/common/gamemode.sh"

# 1. stop the engine so it can not write anything after we restore
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        kill -TERM "$pid" 2>/dev/null
        i=0
        while [ "$i" -lt 20 ] && [ -d "/proc/$pid" ]; do
            sleep 0.2 2>/dev/null || sleep 1
            i=$((i + 1))
        done
        [ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null
    fi
fi

# 2. exactly restore what the module changed
log_i "uninstall: restoring saved knobs"
restore_all
gamemode_restore

# 3. drop runtime state
rm -rf "$DATA_DIR/run" "$DATA_DIR/state" 2>/dev/null

# 4. remove everything else.  The log is left in place only if the user
#    asked for it via KEEP_LOG=1 in the config.
keep_log=0
[ -f "$DATA_DIR/config.conf" ] &&
    grep -qs '^KEEP_LOG=1' "$DATA_DIR/config.conf" && keep_log=1
if [ "$keep_log" = 1 ]; then
    mv -f "$DATA_DIR/logs/module.log" /sdcard/Download/codm-optimizer.log 2>/dev/null
fi

rm -rf "$DATA_DIR" 2>/dev/null

exit 0
