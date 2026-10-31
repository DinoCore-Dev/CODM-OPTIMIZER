#!/usr/bin/env bash
#
# CODM Optimizer - offline tests
#
# The module is a pile of shell scripts that write to /sys, so the tests
# do not need a phone: every path used by the safety-critical part
# (writing a knob, remembering its old value, putting it back) can be
# pointed at a temporary directory.
#
# `doctor` and `status` are executed here too, against stub Android
# binaries, so a broken report never reaches a user.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODULE_DIR=$ROOT/module
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS_FILE=$TMP/.pass
FAIL_FILE=$TMP/.fail
: >"$PASS_FILE"
: >"$FAIL_FILE"

# counters live in files because most tests run inside subshells
ok() { printf 'x\n' >>"$PASS_FILE"; printf '  \033[32m ok \033[0m %s\n' "$*"; }
no() { printf 'x\n' >>"$FAIL_FILE"; printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
eq() { # eq <expected> <actual> <label>
    if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (expected '$1', got '$2')"; fi
}
contains() { # contains <haystack> <needle> <label>
    case $1 in *"$2"*) ok "$3" ;; *) no "$3 (missing '$2')" ;; esac
}

# ------------------------------------------------------------- stubs ------
mkdir -p "$TMP/bin"
stub() { # stub <name> <body>
    printf '#!/bin/sh\n%s\n' "$2" >"$TMP/bin/$1"
    chmod +x "$TMP/bin/$1"
}
stub getprop 'case "$1" in
  ro.build.version.sdk) echo "${FAKE_SDK:-34}" ;;
  ro.product.brand) echo "TestBrand" ;;
  ro.product.model) echo "TestModel" ;;
  ro.soc.model) echo "SM-TEST" ;;
  ro.soc.manufacturer) echo "Qualcomm" ;;
  ro.build.version.release) echo "14" ;;
  sys.boot_completed) echo 1 ;;
  *) echo "" ;;
esac'
stub pidof 'echo "${FAKE_PID:-}"'
stub dumpsys 'case "$*" in
  *"activity activities"*) echo "    topResumedActivity=ActivityRecord{1 u0 ${FAKE_PKG:-com.activision.callofduty.shooter}/.Main t1}" ;;
  *"power"*) echo "  mWakefulness=${FAKE_WAKE:-Awake}" ;;
  *"display"*) echo "  mode fps=120.000004" ;;
  *) echo "" ;;
esac'
stub settings 'case "$1" in
  get) eval "echo \"\${FAKE_SET_${3:-x}:-null}\"" ;;
  *) exit 0 ;;
esac'
stub pm 'echo "package:com.activision.callofduty.shooter"; echo "package:com.garena.game.codm"'
stub cmd 'echo "$*" >>"${FAKE_CMD_LOG:-/dev/null}"
case "$*" in
  *"game list-modes"*) echo "com.activision.callofduty.shooter current mode: standard, available game modes: [standard,performance]" ;;
  *"game list-configs"*) echo "no interventions" ;;
  *) exit 0 ;;
esac'
stub device_config 'echo "device_config $*" >>"${FAKE_CMD_LOG:-/dev/null}"
case "$1" in get) echo null ;; *) exit 0 ;; esac'
stub magisk 'case "$1" in -V) echo 27000 ;; esac; exit 0'
# logcat stub records its arguments so we can assert on them
cat >"$TMP/bin/log" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/logcat.txt"
EOF
chmod +x "$TMP/bin/log"
stub date 'command /bin/date "$@" 2>/dev/null || echo 1700000000'
stub ip 'exit 0'
REAL_ID=$(command -v id)
stub id '[ "$1" = "-u" ] && { echo 0; exit 0; }; exec '"$REAL_ID"' "$@"'
chmod +x "$TMP/bin"/*

export PATH="$TMP/bin:$PATH"
export DATA_DIR="$TMP/data"
export CONF="$DATA_DIR/config.conf"
export MODDIR="$MODULE_DIR"
export NO_COLOR=1

mkdir -p "$DATA_DIR" "$DATA_DIR/logs" "$DATA_DIR/state/originals" "$DATA_DIR/run"

# a helper that loads the module the same way the engine does
load_all() {
    # shellcheck disable=SC1090
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
}

echo "== helpers =="
(
    load_all
    eq "$(int_of 120.000004)" "120" "int_of trims decimals"
    eq "$(int_of 7)" "7" "int_of keeps integers"
    is_uint 42 && ok "is_uint accepts digits" || no "is_uint rejects digits"
    is_uint "" && no "is_uint accepts empty" || ok "is_uint rejects empty"
    is_uint 4x && no "is_uint accepts 4x" || ok "is_uint rejects 4x"
    in_range 50 10 100 && ok "in_range inside" || no "in_range inside"
    in_range 5 10 100 && no "in_range below accepted" || ok "in_range below rejected"
    eq "$(trim '  hello world  ')" "hello world" "trim strips padding"
    # shellcheck disable=SC2086
    eq "$(pick_pct 0 100 200 300)" "100" "pick_pct 0% is the lowest"
    # shellcheck disable=SC2086
    eq "$(pick_pct 100 100 200 300)" "300" "pick_pct 100% is the highest"
    # shellcheck disable=SC2086
    eq "$(pick_pct 50 100 200 300)" "200" "pick_pct 50% is the middle"
)

echo "== logging =="
(
    load_all
    log_init
    : >"$LOG_FILE"
    : >"$TMP/logcat.txt"
    log_w "hello warning"
    log_i "quiet info"
    grep -q '\[W\] hello warning' "$LOG_FILE" && ok "warning written to the module log" || no "warning written to the module log"
    grep -q 'hello warning' "$TMP/logcat.txt" && ok "warning mirrored to logcat" || no "warning mirrored to logcat"
    grep -q 'quiet info' "$TMP/logcat.txt" && no "info lines must not spam logcat" || ok "info lines stay out of logcat"
    if grep -q '\[-t\]' "$LOG_FILE"; then
        no "log() must not shadow Android's log binary (recursion)"
    else
        ok "no recursion through the log binary"
    fi
    VERBOSE_LOG=0
    log_v "should not appear"
    grep -q 'should not appear' "$LOG_FILE" && no "verbose is silent when VERBOSE_LOG=0" || ok "verbose is silent when VERBOSE_LOG=0"
    VERBOSE_LOG=1
    log_v "should appear"
    grep -q 'should appear' "$LOG_FILE" && ok "verbose logs when VERBOSE_LOG=1" || no "verbose logs when VERBOSE_LOG=1"
)

echo "== original value round trip =="
(
    load_all
    mkdir -p "$TMP/sys"
    printf '300000\n' >"$TMP/sys/min_freq"
    printf 'schedutil\n' >"$TMP/sys/governor"

    wr_sys "$TMP/sys/min_freq" 900000 "test min_freq"
    eq "$(cat "$TMP/sys/min_freq")" "900000" "wr_sys writes the new value"
    wr_sys "$TMP/sys/governor" performance "test governor"
    eq "$(cat "$TMP/sys/governor")" "performance" "wr_sys writes the governor"

    _n=$(ls "$ORIG_DIR" | wc -l | tr -d ' ')
    eq "$_n" "2" "two originals saved"

    restore_all
    eq "$(cat "$TMP/sys/min_freq")" "300000" "restore_all puts min_freq back"
    eq "$(cat "$TMP/sys/governor")" "schedutil" "restore_all puts governor back"
    _n=$(ls "$ORIG_DIR" 2>/dev/null | wc -l | tr -d ' ')
    eq "$_n" "0" "originals cleared after restore"

    # write to a missing / read-only knob must not create state
    wr_sys "$TMP/sys/does_not_exist" 1 "missing" && no "wr_sys wrote a missing knob" || ok "wr_sys refuses a missing knob"
    _n=$(ls "$ORIG_DIR" 2>/dev/null | wc -l | tr -d ' ')
    eq "$_n" "0" "no state for refused write"
)

echo "== selective restore =="
(
    load_all
    mkdir -p "$TMP/sys2"
    printf '55000\n' >"$TMP/sys2/trip"
    printf '10\n' >"$TMP/sys2/boost"
    wr_sys "$TMP/sys2/trip" 59000 "trip"
    wr_sys "$TMP/sys2/boost" 20 "boost"
    restore_matching "sys:$TMP/sys2/trip"
    eq "$(cat "$TMP/sys2/trip")" "55000" "targeted restore reverts the trip"
    eq "$(cat "$TMP/sys2/boost")" "20" "targeted restore leaves the boost"
    restore_all
    eq "$(cat "$TMP/sys2/boost")" "10" "full restore cleans up the rest"
)

echo "== config parser =="
(
    load_all
    cat >"$CONF" <<'EOF'
# comment line
PROFILE=performance

CPU_UP_RATE_US=1234
EXTRA_PACKAGES="com.example.one com.example.two"
QUOTED='single value'
WITH_COMMENT=55 # trailing comment
not a valid line at all
rm -rf /this/should/never/run
EMPTY=
EOF
    config_load
    eq "$PROFILE" "performance" "profile read from config"
    eq "$CPU_UP_RATE_US" "1234" "user value overrides the profile"
    eq "$EXTRA_PACKAGES" "com.example.one com.example.two" "quoted value keeps spaces"
    eq "$QUOTED" "single value" "single quotes stripped"
    eq "$WITH_COMMENT" "55" "trailing comment stripped"
    eq "$EMPTY" "" "empty value allowed"
    eq "${not+x}" "" "invalid lines are ignored"
)

echo "== config validation =="
(
    load_all
    cat >"$CONF" <<'EOF'
POLL_GAME_SEC=banana
POLL_IDLE_SEC=0
TEMP_LIMIT_C=999
TEMP_RESUME_DELTA_C=99
THERMAL_LIFT_C=50
REAPPLY_SEC=$(touch /tmp/codm-injection-marker)
ENGINE_ENABLED=2
GAME_MODE=maybe
REFRESH_HZ=fast
EOF
    rm -f /tmp/codm-injection-marker
    config_load
    eq "$POLL_GAME_SEC" "5" "non-numeric poll interval falls back"
    eq "$POLL_IDLE_SEC" "5" "zero poll interval is clamped up"
    eq "$TEMP_LIMIT_C" "60" "absurd thermal limit is clamped"
    eq "$TEMP_RESUME_DELTA_C" "10" "hysteresis is clamped"
    eq "$THERMAL_LIFT_C" "8" "thermal lift is capped at 8C"
    eq "$REAPPLY_SEC" "60" "command substitution in config is not executed"
    eq "$ENGINE_ENABLED" "1" "weird enabled flag becomes 1"
    eq "$GAME_MODE" "1" "weird game mode flag becomes 1"
    eq "$REFRESH_HZ" "auto" "weird refresh hz becomes auto"
    if [ -e /tmp/codm-injection-marker ]; then
        no "config file must never be executed"
        rm -f /tmp/codm-injection-marker
    else
        ok "config file is parsed, never executed"
    fi
)

echo "== config precedence =="
(
    load_all
    printf 'PROFILE=balanced\n' >"$CONF"
    config_load
    eq "$PROFILE" "balanced" "profile from config"
    eq "$CPU_UP_RATE_US" "2000" "balanced profile value"

    printf 'PROFILE=extreme\n' >"$CONF"
    config_load
    eq "$CPU_UP_RATE_US" "500" "extreme profile value"

    printf 'PROFILE=extreme\nCPU_UP_RATE_US=900\n' >"$CONF"
    config_load
    eq "$CPU_UP_RATE_US" "900" "config wins over profile"

    printf 'PROFILE=rubbish\n' >"$CONF"
    config_load
    eq "$PROFILE" "balanced" "unknown profile falls back to balanced"
)

echo "== game detection =="
(
    load_all
    export FAKE_PKG=com.garena.game.codm
    export CODM_TOPAPP_FILE="$TMP/topapp"
    printf '# cgroup.procs\n4242\n' >"$TMP/topapp"
    export FAKE_PID=4242

    eq "$(game_state)" "foreground" "pid in top-app cpuset is foreground"

    printf '# cgroup.procs\n1\n2\n' >"$TMP/topapp"
    export FAKE_PKG=com.garena.game.codm
    eq "$(game_state)" "foreground" "falls back to the resumed activity"

    export FAKE_PKG=com.other.app
    eq "$(game_state)" "background" "running but not visible is background"

    export FAKE_PID=
    eq "$(game_state)" "none" "no pid means not running"

    _pkgs=$(game_installed_packages | tr '\n' ' ')
    contains "$_pkgs" "com.activision.callofduty.shooter" "global package found"
    contains "$_pkgs" "com.garena.game.codm" "garena package found"
)

echo "== screen state =="
(
    load_all
    export FAKE_WAKE=Awake
    screen_on && ok "dumpsys Awake is screen on" || no "dumpsys Awake is screen on"
    export FAKE_WAKE=Asleep
    screen_on && no "dumpsys Asleep is screen off" || ok "dumpsys Asleep is screen off"
)

echo "== game mode per API level =="
(
    load_all
    export FAKE_CMD_LOG="$TMP/cmd.log"
    : >"$FAKE_CMD_LOG"

    export FAKE_SDK=34
    GAME_MODE=1 GAME_MODE_FPS=120 GAME_MODE_DOWNSCALE=0.8
    gamemode_apply
    grep -q "game set --fps 120 --downscale 0.8" "$FAKE_CMD_LOG" &&
        ok "API 34 uses cmd game set with fps and downscale" ||
        no "API 34 uses cmd game set with fps and downscale"
    grep -q "game mode custom" "$FAKE_CMD_LOG" &&
        ok "API 34 selects custom mode" || no "API 34 selects custom mode"
    gamemode_restore
    grep -q "game reset" "$FAKE_CMD_LOG" && ok "restore uses cmd game reset" || no "restore uses cmd game reset"

    : >"$FAKE_CMD_LOG"
    export FAKE_SDK=33
    GAME_MODE=1 GAME_MODE_FPS=90 GAME_MODE_DOWNSCALE=off
    gamemode_apply
    grep -q "device_config put game_overlay" "$FAKE_CMD_LOG" &&
        ok "API 33 uses the game_overlay config" || no "API 33 uses the game_overlay config"
    grep -q "game mode 2" "$FAKE_CMD_LOG" && ok "API 33 selects performance mode" || no "API 33 selects performance mode"

    : >"$FAKE_CMD_LOG"
    export FAKE_SDK=31
    GAME_MODE=1 GAME_MODE_FPS=0 GAME_MODE_DOWNSCALE=off
    gamemode_apply
    grep -q "game mode performance" "$FAKE_CMD_LOG" &&
        ok "API 31 uses performance mode" || no "API 31 uses performance mode"

    : >"$FAKE_CMD_LOG"
    export FAKE_SDK=29
    gamemode_apply
    [ -s "$FAKE_CMD_LOG" ] && no "API 29 must not call cmd game" || ok "API 29 is skipped"
)

echo "== thermal parsing =="
(
    export PSU_DIR="$TMP/psu"
    export THERMAL_DIR="$TMP/thermal"
    load_all
    mkdir -p "$TMP/psu/battery" "$TMP/thermal"
    # Android reports tenths of a degree
    printf '385\n' >"$TMP/psu/battery/temp"
    eq "$(battery_temp_c)" "38" "battery temp tenths converted"
    printf '38500\n' >"$TMP/psu/battery/temp"
    eq "$(battery_temp_c)" "38" "battery temp millidegrees converted"

    # thermal zones: hottest cpu zone wins, battery/charger zones ignored
    mkdir -p "$TMP/thermal/thermal_zone0" "$TMP/thermal/thermal_zone1" "$TMP/thermal/thermal_zone2"
    printf 'cpu-0-0\n' >"$TMP/thermal/thermal_zone0/type"
    printf '48500\n' >"$TMP/thermal/thermal_zone0/temp"
    printf 'gpu\n' >"$TMP/thermal/thermal_zone1/type"
    printf '52000\n' >"$TMP/thermal/thermal_zone1/temp"
    printf 'battery\n' >"$TMP/thermal/thermal_zone2/type"
    printf '99000\n' >"$TMP/thermal/thermal_zone2/temp"
    eq "$(soc_temp_c)" "52" "soc temp picks the hottest cpu/gpu zone"
    eq "$(thermal_zones | wc -l | tr -d ' ')" "3" "thermal_zones lists every zone"

    TEMP_LIMIT_C=43
    printf '440\n' >"$TMP/psu/battery/temp"
    thermal_too_hot && ok "guard trips at the limit" || no "guard trips at the limit"
    printf '380\n' >"$TMP/psu/battery/temp"
    thermal_too_hot && no "guard stays quiet below the limit" || ok "guard stays quiet below the limit"
    thermal_cooled_down && ok "cooled_down is true at 38C" || no "cooled_down is true at 38C"
    printf '415\n' >"$TMP/psu/battery/temp"
    thermal_cooled_down && no "hysteresis blocks resuming at 41.5C" || ok "hysteresis blocks resuming at 41.5C"
)

echo "== adaptive ladder =="
(
    export PSU_DIR="$TMP/psu2"
    mkdir -p "$TMP/psu2/battery"
    load_all
    config_ensure
    printf 'PROFILE=adaptive\nTEMP_LIMIT_C=43\n' >"$CONF"
    config_load
    eq "$PROFILE" "adaptive" "adaptive profile loads"
    eq "$ADAPTIVE" "1" "adaptive profile enables the ladder"
    eq "$ADAPT_GPU_COOL" "40" "cool GPU floor from the profile"
    eq "$ADAPT_GPU_WARM" "28" "warm GPU floor from the profile"
    eq "$ADAPT_GPU_HOT" "15" "hot GPU floor from the profile"

    printf '350\n' >"$TMP/psu2/battery/temp"
    eq "$(adaptive_level)" "cool" "35C is the cool step"
    printf '390\n' >"$TMP/psu2/battery/temp"
    eq "$(adaptive_level)" "warm" "39C is the warm step"
    printf '420\n' >"$TMP/psu2/battery/temp"
    eq "$(adaptive_level)" "hot" "42C is the hot step"

    # a level change must be picked up exactly once
    ADAPTIVE_APPLIED=
    adaptive_apply
    eq "$ADAPTIVE_APPLIED" "hot" "adaptive_apply records the level"
    eq "$GPU_MIN_PCT" "15" "hot step lowers the GPU floor to 15%"
    eq "$REFRESH_HZ" "90" "hot step caps refresh at 90Hz"
    printf '360\n' >"$TMP/psu2/battery/temp"
    adaptive_apply
    eq "$ADAPTIVE_APPLIED" "cool" "cooling down moves back to the cool step"
    eq "$GPU_MIN_PCT" "40" "cool step restores the GPU floor"

    # fixed profiles must not run the ladder
    printf 'PROFILE=balanced\n' >"$CONF"
    config_load
    eq "$ADAPTIVE" "0" "balanced is a fixed profile"
)

echo "== webui bridge =="
(
    # actions.sh resolves its module dir from its own path, so run it live
    export FAKE_CMD_LOG="$TMP/webcmd.log"
    : >"$FAKE_CMD_LOG"
    OUT=$(sh "$MODULE_DIR/webroot/actions.sh" snapshot 2>&1)
    contains "$OUT" "ok=1" "snapshot succeeds"
    contains "$OUT" "module.version=" "snapshot reports the module version"
    contains "$OUT" "engine.running=" "snapshot reports the engine"
    contains "$OUT" "cfg.profile=" "snapshot reports the profile"
    contains "$OUT" "thermal.limit=" "snapshot reports the thermal limit"
    contains "$OUT" "cap.cpu=" "snapshot reports capabilities"

    # settings are validated, everything else is refused
    for bad in "set FOO 1" "set TEMP_LIMIT_C 999" "set TEMP_LIMIT_C 20" \
               "set PROFILE evil" "set GAME_MODE_DOWNSCALE 0.1" \
               "set THERMAL_LIFT_C 12" "set REFRESH_HZ 20" \
               "set TEMP_LIMIT_C 43;reboot"; do
        # shellcheck disable=SC2086
        R=$(sh "$MODULE_DIR/webroot/actions.sh" $bad 2>&1)
        case $R in
            *"ok=0"*) ok "rejects: $bad" ;;
            *) no "should reject: $bad (got: $R)" ;;
        esac
    done

    R=$(sh "$MODULE_DIR/webroot/actions.sh" set TEMP_LIMIT_C 42 2>&1)
    contains "$R" "ok=1" "accepts a valid temperature"
    grep -q '^TEMP_LIMIT_C=42$' "$CONF" && ok "bridge wrote the config" || no "bridge wrote the config"

    R=$(sh "$MODULE_DIR/webroot/actions.sh" profile adaptive 2>&1)
    contains "$R" "ok=1" "accepts a valid profile"
    grep -q '^PROFILE=adaptive$' "$CONF" && ok "profile written to config" || no "profile written to config"

    R=$(sh "$MODULE_DIR/webroot/actions.sh" nope 2>&1)
    contains "$R" "ok=0" "unknown command is refused"

    # the page and the bridge must agree on the flat format
    case $OUT in
        *"row|"*) ok "snapshot emits row lines" ;;
        *) no "snapshot should emit row lines" ;;
    esac
)

echo "== reports =="
(
    load_all
    config_ensure
    printf 'PROFILE=performance\n' >"$CONF"
    config_load
    out=$(status_report 2>&1)
    contains "$out" "CODM Optimizer" "status prints the module name"
    contains "$out" "profile" "status prints the profile section"
    contains "$out" "performance" "status shows the active profile"

    out=$(doctor_report 2>&1)
    contains "$out" "doctor" "doctor prints a header"
    contains "$out" "PASS" "doctor prints at least one PASS"

    out=$(CODM_MODDIR="$MODULE_DIR" sh "$MODULE_DIR/system/bin/codm-optimizer" help 2>&1)
    contains "$out" "profile" "CLI help mentions profiles"
)

PASS=$(wc -l <"$PASS_FILE" | tr -d ' ')
FAIL=$(wc -l <"$FAIL_FILE" | tr -d ' ')
echo
if [ "$FAIL" -gt 0 ]; then
    printf '\033[31m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
printf '\033[32m%s tests passed\033[0m\n' "$PASS"
