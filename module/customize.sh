# shellcheck shell=sh
#
# CODM Optimizer - installer customisation
#
# Sourced by the Magisk / KernelSU / APatch installer after the zip has
# been extracted.  Keep it free of blocking calls: no `exit`, no waiting
# on the network, no interactive prompts.

if ! command -v ui_print >/dev/null 2>&1; then
    ui_print() { printf '%s\n' "$*"; }
fi
if ! command -v abort >/dev/null 2>&1; then
    abort() { printf '%s\n' "$*" >&2; exit 1; }
fi

ui_print " "
ui_print "********************************************"
ui_print "  CODM Optimizer  -  Magisk / KernelSU"
ui_print "********************************************"
ui_print " "

# ---------------------------------------------------------------- checks --
API=${API:-$(getprop ro.build.version.sdk 2>/dev/null)}
case $API in
    ''|*[!0-9]*) API=0 ;;
esac
if [ "$API" -lt 26 ]; then
    ui_print "! Android 8.0 (API 26) or newer is required, found API $API"
    abort "! Aborting installation"
fi
ui_print "- Android API $API detected"

case ${ARCH:-} in
    arm64|arm) ;;
    x86|x86_64)
        ui_print "! CODM does not run on x86 devices, but the module itself is"
        ui_print "  architecture neutral and will install anyway."
        ;;
esac

# The module only needs a shell and root; there are no native binaries,
# so 32/64 bit does not matter.

# ------------------------------------------------------------ data folder --
DATA_DIR=/data/adb/codm-optimizer
ui_print "- Preparing $DATA_DIR"
mkdir -p "$DATA_DIR/logs" "$DATA_DIR/run" "$DATA_DIR/state" "$DATA_DIR/sessions" 2>/dev/null

if [ -f "$DATA_DIR/config.conf" ]; then
    ui_print "- Keeping your existing configuration"
else
    cp -f "$MODPATH/config/default.conf" "$DATA_DIR/config.conf" 2>/dev/null
    ui_print "- Default configuration written"
fi
chmod 0644 "$DATA_DIR/config.conf" 2>/dev/null

# --------------------------------------------------------------- the game --
GAME_FOUND=
if command -v pm >/dev/null 2>&1; then
    _pkgs=$(pm list packages 2>/dev/null)
    for _p in com.activision.callofduty.shooter com.garena.game.codm \
              com.vng.codmvn com.tencent.tmgp.cod com.tencent.tmgp.codk; do
        printf '%s\n' "$_pkgs" | grep -qxF "package:$_p" && GAME_FOUND="$GAME_FOUND $_p"
    done
fi
if [ -n "$GAME_FOUND" ]; then
    ui_print "- Call of Duty: Mobile found:$GAME_FOUND"
else
    ui_print "- CODM not detected right now."
    ui_print "  The module still installs and will arm itself when the game"
    ui_print "  shows up. Add unusual package names in EXTRA_PACKAGES."
fi

# ------------------------------------------------------------- permissions --
if command -v set_perm_recursive >/dev/null 2>&1; then
    set_perm_recursive "$MODPATH" 0 0 0755 0644
    set_perm_recursive "$MODPATH/common" 0 0 0755 0755
    set_perm "$MODPATH/common/engine.sh" 0 0 0755
    for _s in customize.sh post-fs-data.sh service.sh uninstall.sh action.sh; do
        [ -f "$MODPATH/$_s" ] && set_perm "$MODPATH/$_s" 0 0 0755
    done
    set_perm "$MODPATH/system/bin/codm-optimizer" 0 0 0755
else
    # Installer without Magisk helpers (rare); plain chmod is enough.
    find "$MODPATH" -name '*.sh' -exec chmod 0755 {} + 2>/dev/null
    chmod 0755 "$MODPATH/system/bin/codm-optimizer" 2>/dev/null
fi

ui_print " "
ui_print "- Profile: adaptive (default). It eases the GPU floor and refresh"
ui_print "  rate down before the thermal limit instead of dropping everything."
ui_print " "
ui_print "- Reboot, then open CODM. The profile is applied only while"
ui_print "  the game is in the foreground and released when you leave."
ui_print " "
ui_print "- Configure it with the web interface, no terminal needed:"
ui_print "    KernelSU / APatch : Modules -> CODM Optimizer -> Web UI"
ui_print "    Magisk            : tap the module's action button, or use a"
ui_print "                        WebUI host such as MMRL"
ui_print "  A command line is also available (su -c codm-optimizer) but it is"
ui_print "  optional."
ui_print " "
