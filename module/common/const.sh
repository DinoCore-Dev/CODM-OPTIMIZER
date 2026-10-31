# shellcheck shell=sh
#
# CODM Optimizer - shared constants
#
# Sourced by every other script in the module.  Nothing here executes
# anything, it only defines paths, package names and defaults.
#
# Paths are deliberately stored under /data/adb/<id> (NOT under the module
# directory) so that a module update never wipes user configuration,
# logs or saved originals.

MODID=codm-optimizer
MODNAME="CODM Optimizer"

# Resolve the module directory from the calling script ($0 = .../common/x.sh)
# unless it was already provided by the caller.
if [ -z "${MODDIR:-}" ]; then
    _self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
    MODDIR=$(cd "$_self_dir/.." 2>/dev/null && pwd)
    unset _self_dir
fi

# Every path can be pre-set by the caller.  The test suite uses that to
# run the whole module against a throw-away directory; on a phone these
# are always the defaults.
: "${DATA_DIR:=/data/adb/$MODID}"
: "${CONF:=$DATA_DIR/config.conf}"
: "${LOG_DIR:=$DATA_DIR/logs}"
: "${LOG_FILE:=$LOG_DIR/module.log}"
: "${LOG_MAX_BYTES:=524288}"
: "${RUN_DIR:=$DATA_DIR/run}"
: "${PID_FILE:=$RUN_DIR/engine.pid}"
: "${STATE_DIR:=$DATA_DIR/state}"
: "${ORIG_DIR:=$STATE_DIR/originals}"
: "${SESSION_DIR:=$DATA_DIR/sessions}"
: "${SESSION_FILE:=$SESSION_DIR/sessions.tsv}"
GM_MARKER=$STATE_DIR/gamemode.applied
GM_OVERLAY=$STATE_DIR/gamemode.overlay

# --- CODM packages -------------------------------------------------------
# Global (Activision), SEA (Garena), Vietnam (VNG), China & Korea (Tencent).
# Users can add more with EXTRA_PACKAGES= in config.conf.
CODM_PACKAGES="
com.activision.callofduty.shooter
com.garena.game.codm
com.vng.codmvn
com.tencent.tmgp.cod
com.tencent.tmgp.codm
com.tencent.tmgp.codk
"

# --- Defaults (overridden by config.conf) --------------------------------
: "${PROFILE:=balanced}"
: "${ENGINE_ENABLED:=1}"
: "${POLL_IDLE_SEC:=15}"
: "${POLL_GAME_SEC:=5}"
: "${REAPPLY_SEC:=60}"
: "${VERBOSE_LOG:=0}"
: "${TEMP_LIMIT_C:=43}"
: "${TEMP_RESUME_DELTA_C:=3}"
: "${GUARD_INTERVAL_SEC:=20}"
: "${EXTRA_PACKAGES:=}"

# Sensor trees.  Overridable so the offline test suite can use fixtures.
: "${PSU_DIR:=/sys/class/power_supply}"
: "${THERMAL_DIR:=/sys/class/thermal}"
