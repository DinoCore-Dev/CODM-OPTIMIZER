#!/system/bin/sh
#
# CODM Optimizer - WebUI bridge
#
# KernelSU / APatch (and Magisk through a WebUI host such as MMRL) run
# webroot/index.html in a WebView and expose `ksu.exec(command)`.  Every
# button in the UI ends up here as one short command, and this script
# answers with a flat key=value stream the page parses:
#
#   ok=1
#   engine.state=active
#   row|cpu|policy0|schedutil|1200|300|1800
#
# Design rules:
#   * never trust the caller - every key and value is validated against a
#     whitelist before it reaches config_set or a shell binary;
#   * always exit 0 and report errors as ok=0, because a non-zero exit is
#     shown to the user as a wall of stack trace by some managers;
#   * keep `snapshot` cheap (it runs every few seconds): cached panel
#     refresh, cached package list, no dumpsys of the activity stack.

PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:$PATH
export PATH

MODDIR=${0%/*}
case $MODDIR in
    */webroot) MODDIR=${MODDIR%/webroot} ;;
esac

. "$MODDIR/common/const.sh"
. "$MODDIR/common/log.sh"
. "$MODDIR/common/util.sh"
. "$MODDIR/common/config.sh"
. "$MODDIR/common/control.sh"
. "$MODDIR/common/device.sh"
. "$MODDIR/common/game.sh"
. "$MODDIR/common/display.sh"
. "$MODDIR/common/gamemode.sh"
. "$MODDIR/common/thermal.sh"
. "$MODDIR/common/profile.sh"

# --------------------------------------------------------------- output ---
emit() { # emit <key> <value>
    _v=$(printf '%s' "${2:-}" | tr '\n\r' '  ' | cut -c1-300)
    printf '%s=%s\n' "$1" "$_v"
    unset _v
}

row() { # row <type> <field>...
    _t=$1
    shift
    printf 'row|%s|%s\n' "$_t" "$(printf '%s|' "$@" | cut -c1-500)"
    unset _t
}

fail_with() {
    emit ok 0
    emit msg "$*"
    exit 0
}

succeed() {
    emit ok 1
    [ -n "${1:-}" ] && emit msg "$1"
    exit 0
}

module_version() {
    sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -1
}

# -------------------------------------------------------------- snapshot --
cmd_snapshot() {
    dev_probe
    config_ensure
    config_load

    emit ok 1
    row ts "$(now_epoch)"
    emit module.version "$(module_version)"
    emit module.id "$MODID"

    emit device.model "$DEV_BRAND $DEV_MODEL"
    emit device.soc "$DEV_SOC"
    emit device.android "$DEV_RELEASE"
    emit device.api "$DEV_SDK"
    emit root.impl "$ROOT_IMPL"
    emit root.version "$ROOT_VER"
    emit root.selinux "$SELINUX"

    _pid=$(engine_pid) || _pid=
    emit engine.running "$([ -n "$_pid" ] && echo 1 || echo 0)"
    emit engine.pid "$_pid"
    emit engine.state "$(engine_state)"
    emit engine.enabled "$ENGINE_ENABLED"
    emit cfg.engine_enabled "$ENGINE_ENABLED"

    emit cfg.profile "$PROFILE"
    emit cfg.refresh_lock "$REFRESH_LOCK"
    emit cfg.refresh_hz "$REFRESH_HZ"
    emit cfg.game_mode "$GAME_MODE"
    emit cfg.game_mode_fps "$GAME_MODE_FPS"
    emit cfg.game_mode_downscale "$GAME_MODE_DOWNSCALE"
    emit cfg.temp_limit "$TEMP_LIMIT_C"
    emit cfg.thermal_lift "$THERMAL_LIFT_C"
    emit cfg.verbose_log "$VERBOSE_LOG"
    emit cfg.adaptive "$ADAPTIVE"
    emit cfg.adapt_gpu_cool "$ADAPT_GPU_COOL"
    emit cfg.adapt_gpu_warm "$ADAPT_GPU_WARM"
    emit cfg.adapt_gpu_hot "$ADAPT_GPU_HOT"
    emit cfg.adapt_hz_cool "$ADAPT_HZ_COOL"
    emit cfg.adapt_hz_warm "$ADAPT_HZ_WARM"
    emit cfg.adapt_hz_hot "$ADAPT_HZ_HOT"
    emit cfg.poll_game "$POLL_GAME_SEC"
    emit cfg.reapply "$REAPPLY_SEC"

    emit game.installed "$(game_installed_packages | tr '\n' ' ')"
    emit game.state "$(game_state)"

    _bt=$(battery_temp_c)
    _st=$(soc_temp_c)
    emit thermal.battery "${_bt:-}"
    emit thermal.soc "${_st:-}"
    emit thermal.limit "$TEMP_LIMIT_C"
    emit thermal.level "$(adaptive_level)"
    emit thermal.guard "$([ "${THERMAL_HOT:-0}" = 1 ] && echo hot || echo ok)"

    emit display.max "$(display_max_hz_cached)"
    emit display.min_setting "$(settings get system min_refresh_rate 2>/dev/null)"
    emit display.peak_setting "$(settings get system peak_refresh_rate 2>/dev/null)"
    emit gamemode.report "$(report_gamemode)"

    # capabilities, so the UI can explain what this phone supports
    _cap_gpu=0
    [ -n "$GPU_DIR" ] && [ -n "$(gpu_min_path)" ] && [ -w "$(gpu_min_path)" ] && _cap_gpu=1
    emit cap.gpu "$_cap_gpu"
    emit cap.gpu_driver "$GPU_DRIVER"
    _gc=$(gpu_cur_freq 2>/dev/null)
    _gmin=$(read_file "$(gpu_min_path)" 2>/dev/null)
    _gmax=$(read_file "$(gpu_max_path)" 2>/dev/null)
    emit gpu.cur "$((${_gc:-0} / 1000000))"
    emit gpu.min "$((${_gmin:-0} / 1000000))"
    emit gpu.max "$((${_gmax:-0} / 1000000))"
    emit cap.cpu "$([ -n "$(cpu_policies)" ] && echo 1 || echo 0)"
    emit cap.uclamp "$([ -e /dev/cpuset/top-app/uclamp.min ] || [ -e /sys/fs/cgroup/top-app/cpu.uclamp.min ] && echo 1 || echo 0)"
    emit cap.denylist "$(command -v magisk >/dev/null 2>&1 && echo 1 || echo 0)"
    emit cap.topapp "$([ -n "$(_topapp_file 2>/dev/null)" ] && echo 1 || echo 0)"

    # per-cluster cpu rows: name|governor|cur_mhz|min_mhz|max_mhz
    for _p in $(cpu_policies); do
        row cpu "${_p##*/}" \
            "$(read_file "$_p/scaling_governor" 2>/dev/null)" \
            "$(( $(read_file "$_p/scaling_cur_freq" 2>/dev/null || echo 0) / 1000 ))" \
            "$(( $(read_file "$_p/scaling_min_freq" 2>/dev/null || echo 0) / 1000 ))" \
            "$(( $(read_file "$_p/scaling_max_freq" 2>/dev/null || echo 0) / 1000 ))"
    done

    # last session + a few recent ones
    if [ -f "$SESSION_FILE" ]; then
        _last=$(tail -1 "$SESSION_FILE" 2>/dev/null)
        if [ -n "$_last" ]; then
            emit session.last "$(printf '%s' "$_last" | tr '\t' ' ')"
        fi
        tail -n 4 "$SESSION_FILE" 2>/dev/null | while IFS='	' read -r _s _d _pr _mx _en; do
            is_uint "$_s" || continue
            row session "$_s" "$_d" "${_pr:--}" "${_mx:--}" "${_en:--}"
        done
    fi

    emit log.lines "$(wc -l <"$LOG_FILE" 2>/dev/null | tr -d ' ')"
    if [ -n "$_pid" ]; then
        emit engine.uptime "$(ps -o etime= -p "$_pid" 2>/dev/null | tr -d ' ')"
    fi
    exit 0
}

# ------------------------------------------------------------------ set ---
_v_bool() { case $1 in 0|1) return 0 ;; *) return 1 ;; esac; }
_v_num() { # value min max
    is_uint "$1" && [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null
}

cmd_set() {
    _k=${1:-}
    _v=${2:-}
    [ -n "$_k" ] || fail_with "missing key"

    case $_k in
        PROFILE)
            case $_v in
                adaptive|balanced|performance|extreme|battery) ;;
                *) fail_with "unknown profile '$_v'" ;;
            esac
            ;;
        ENGINE_ENABLED|REFRESH_LOCK|GAME_MODE|VERBOSE_LOG)
            _v_bool "$_v" || fail_with "$_k must be 0 or 1"
            ;;
        REFRESH_HZ)
            case $_v in
                auto) ;;
                *) _v_num "$_v" 60 240 || fail_with "REFRESH_HZ must be auto or 60-240" ;;
            esac
            ;;
        GAME_MODE_FPS)
            _v_num "$_v" 0 240 || fail_with "GAME_MODE_FPS must be 0-240"
            ;;
        GAME_MODE_DOWNSCALE)
            case $_v in
                off|0.5|0.6|0.7|0.8|0.9|1|1.0) ;;
                *) fail_with "GAME_MODE_DOWNSCALE must be off or 0.5-1.0" ;;
            esac
            ;;
        TEMP_LIMIT_C)
            _v_num "$_v" 35 50 || fail_with "TEMP_LIMIT_C must be 35-50"
            ;;
        THERMAL_LIFT_C)
            _v_num "$_v" 0 8 || fail_with "THERMAL_LIFT_C must be 0-8"
            ;;
        ADAPT_GPU_COOL|ADAPT_GPU_WARM|ADAPT_GPU_HOT)
            _v_num "$_v" 0 100 || fail_with "$_k must be 0-100"
            ;;
        ADAPT_HZ_COOL|ADAPT_HZ_WARM)
            case $_v in
                auto) ;;
                *) _v_num "$_v" 60 240 || fail_with "$_k must be auto or 60-240" ;;
            esac
            ;;
        ADAPT_HZ_HOT)
            _v_num "$_v" 60 240 || fail_with "$_k must be 60-240"
            ;;
        POLL_GAME_SEC)
            _v_num "$_v" 3 60 || fail_with "$_k must be 3-60"
            ;;
        REAPPLY_SEC)
            _v_num "$_v" 15 600 || fail_with "$_k must be 15-600"
            ;;
        *)
            fail_with "unknown key '$_k'"
            ;;
    esac

    config_set "$_k" "$_v" || fail_with "could not write config"
    config_load
    log_i "webui: $_k=$_v"

    # Engine picks this up on its next tick; nudge it so a toggle feels
    # immediate when a game is running.
    engine_nudge

    succeed "$_k set to $_v"
}

# -------------------------------------------------------------- actions ---
cmd_engine() {
    case ${1:-} in
        on)
            config_set ENGINE_ENABLED 1
            config_load
            engine_start >/dev/null 2>&1
            succeed "engine started"
            ;;
        off)
            config_set ENGINE_ENABLED 0
            config_load
            engine_stop >/dev/null 2>&1
            succeed "engine stopped, all knobs restored"
            ;;
        restart)
            config_load
            engine_restart >/dev/null 2>&1
            succeed "engine restarted"
            ;;
        *)
            fail_with "usage: engine on|off|restart"
            ;;
    esac
}

cmd_profile() {
    case ${1:-} in
        adaptive|balanced|performance|extreme|battery) ;;
        *) fail_with "unknown profile" ;;
    esac
    config_set PROFILE "$1"
    config_load
    log_i "webui: profile=$1"
    engine_nudge
    succeed "profile set to $1"
}

cmd_apply() {
    config_load
    profile_apply_all
    succeed "profile applied ($APPLIED_COUNT knobs)"
}

cmd_release() {
    config_load
    profile_restore_all
    succeed "everything restored to stock"
}

cmd_reset() {
    config_load
    profile_restore_all
    restore_all
    gamemode_restore
    [ -f "$MODDIR/config/default.conf" ] && cp -f "$MODDIR/config/default.conf" "$CONF" 2>/dev/null
    config_load
    succeed "reset to defaults"
}

cmd_denylist() {
    command -v magisk >/dev/null 2>&1 || fail_with "DenyList is a Magisk feature"
    _pkg=$(game_primary_pkg)
    case ${1:-} in
        on)
            magisk --denylist add "$_pkg" >/dev/null 2>&1
            succeed "$_pkg added to DenyList (reboot for a clean state)"
            ;;
        off)
            magisk --denylist rm "$_pkg" >/dev/null 2>&1
            succeed "$_pkg removed from DenyList"
            ;;
        *)
            magisk --denylist ls 2>/dev/null | grep -qF "$_pkg" &&
                emit denylist.state on || emit denylist.state off
            emit ok 1
            exit 0
            ;;
    esac
}

cmd_log() {
    emit ok 1
    _n=${1:-120}
    is_uint "$_n" || _n=120
    [ "$_n" -gt 400 ] && _n=400
    if [ -f "$LOG_FILE" ]; then
        tail -n "$_n" "$LOG_FILE" 2>/dev/null | while IFS= read -r _line; do
            row log "$_line"
        done
    fi
    exit 0
}

cmd_clear_log() {
    : >"$LOG_FILE" 2>/dev/null
    succeed "log cleared"
}

cmd_sessions() {
    emit ok 1
    [ -f "$SESSION_FILE" ] || exit 0
    tail -n 30 "$SESSION_FILE" 2>/dev/null | while IFS='	' read -r _s _d _pr _mx _en; do
        is_uint "$_s" || continue
        row session "$_s" "$_d" "${_pr:--}" "${_mx:--}" "${_en:--}"
    done
    exit 0
}

# ------------------------------------------------------------------ main --
CMD=${1:-snapshot}
[ $# -gt 0 ] && shift

case $CMD in
    snapshot)   cmd_snapshot ;;
    set)        cmd_set "$@" ;;
    engine)     cmd_engine "$@" ;;
    profile)    cmd_profile "$@" ;;
    apply)      cmd_apply ;;
    release)    cmd_release ;;
    reset)      cmd_reset ;;
    denylist)   cmd_denylist "$@" ;;
    log)        cmd_log "$@" ;;
    clear_log)  cmd_clear_log ;;
    sessions)   cmd_sessions ;;
    *)          fail_with "unknown command '$CMD'" ;;
esac
