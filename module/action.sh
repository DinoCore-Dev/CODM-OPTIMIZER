#!/system/bin/sh
#
# CODM Optimizer - action button
#
# Magisk runs this when the module's action button is tapped.  It is not
# interactive, so it prints a snapshot instead of showing a menu.

MODDIR=${0%/*}

. "$MODDIR/common/const.sh"
. "$MODDIR/common/log.sh"
. "$MODDIR/common/util.sh"
. "$MODDIR/common/config.sh"
. "$MODDIR/common/device.sh"
. "$MODDIR/common/game.sh"
. "$MODDIR/common/display.sh"
. "$MODDIR/common/gamemode.sh"
. "$MODDIR/common/thermal.sh"
. "$MODDIR/common/profile.sh"
. "$MODDIR/common/status.sh"

config_load
status_report
printf '\n'
printf 'run "su -c codm-optimizer doctor" for the full check\n'
