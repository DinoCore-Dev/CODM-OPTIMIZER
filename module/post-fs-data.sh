#!/system/bin/sh
#
# CODM Optimizer - post-fs-data
#
# This stage blocks the boot, so it does exactly one cheap thing:
# clear the runtime directory of the previous boot.  Without this a
# recycled PID could make the engine believe it is already running.
#
# No props, no mounts, no waiting: nothing here can bootloop the phone.

MODDIR=${0%/*}
DATA_DIR=/data/adb/codm-optimizer

rm -rf "$DATA_DIR/run" 2>/dev/null
mkdir -p "$DATA_DIR/run" "$DATA_DIR/logs" "$DATA_DIR/state" "$DATA_DIR/sessions" 2>/dev/null
chmod 0755 "$DATA_DIR" "$DATA_DIR/run" 2>/dev/null
[ -f "$DATA_DIR/config.conf" ] && chmod 0644 "$DATA_DIR/config.conf" 2>/dev/null

exit 0
