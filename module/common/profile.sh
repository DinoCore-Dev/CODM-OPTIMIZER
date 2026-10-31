# shellcheck shell=sh
#
# CODM Optimizer - the actual tuning
#
# Every function:
#   * checks its own enable flag (all default to "off" or "auto"),
#   * probes the knob before writing,
#   * keeps the previous value via wr_sys() so restore_all() is exact.
#
# There is no "magic", no benchmark hidden in here, and nothing that
# touches the game's own files or memory.

APPLIED_COUNT=0

_applied() { APPLIED_COUNT=$((APPLIED_COUNT + 1)); }

# ------------------------------------------------------------------ cpu --
profile_apply_cpu() {
    [ "${CPU_TUNE:-0}" = 1 ] || return 0

    _policies=$(cpu_policies)
    [ -n "$_policies" ] || return 0

    for _p in $_policies; do
        _gov=$(read_file "$_p/scaling_governor" 2>/dev/null)

        if [ "${CPU_GOVERNOR:-auto}" != auto ] && [ -n "${CPU_GOVERNOR:-}" ]; then
            if read_file "$_p/scaling_available_governors" 2>/dev/null |
                tr ' ' '\n' | grep -qxF "$CPU_GOVERNOR"; then
                wr_sys "$_p/scaling_governor" "$CPU_GOVERNOR" "cpu governor" && _applied
                _gov=$CPU_GOVERNOR
            fi
        fi

        # schedutil ramp tuning: this is the knob that makes a game feel
        # responsive *before* the load is measured, not after.
        if [ "$_gov" = schedutil ]; then
            for _base in "$_p/schedutil" "$_p"; do
                [ -d "$_base" ] || continue
                if is_uint "${CPU_UP_RATE_US:-}" && [ "$CPU_UP_RATE_US" -gt 0 ]; then
                    wr_sys "$_base/up_rate_limit_us" "$CPU_UP_RATE_US" "cpu up_rate" && _applied
                    wr_sys "$_base/rate_limit_us" "$CPU_UP_RATE_US" "cpu rate_limit" && _applied
                fi
                if is_uint "${CPU_DOWN_RATE_US:-}" && [ "$CPU_DOWN_RATE_US" -gt 0 ]; then
                    wr_sys "$_base/down_rate_limit_us" "$CPU_DOWN_RATE_US" "cpu down_rate" && _applied
                fi
                break
            done
        fi

        # Optional floor on the minimum frequency, as a percentage of the
        # available range.  0 = leave the vendor's floor alone.
        if is_uint "${CPU_MIN_PCT:-0}" && [ "$CPU_MIN_PCT" -gt 0 ]; then
            _freqs=$(cpu_avail_freqs "$_p")
            if [ -n "$_freqs" ]; then
                # shellcheck disable=SC2086
                _target=$(pick_pct "$CPU_MIN_PCT" $_freqs)
                _max=$(read_file "$_p/scaling_max_freq" 2>/dev/null)
                if is_uint "$_target" && is_uint "$_max" && [ "$_target" -le "$_max" ]; then
                    wr_sys "$_p/scaling_min_freq" "$_target" "cpu min_freq" && _applied
                fi
            fi
        fi
    done
    unset _policies _p _gov _base _freqs _target _max
    return 0
}

# ------------------------------------------------------------------ gpu --
profile_apply_gpu() {
    [ "${GPU_TUNE:-0}" = 1 ] || return 0
    [ -n "$GPU_DIR" ] || { log_v "gpu: no controllable node on this device"; return 0; }

    if [ "${GPU_GOVERNOR:-auto}" != auto ] && [ -n "${GPU_GOVERNOR:-}" ]; then
        for _gp in "$GPU_DIR/devfreq" "$GPU_DIR"; do
            [ -w "$_gp/governor" ] || continue
            if read_file "$_gp/available_governors" 2>/dev/null |
                tr ' ' '\n' | grep -qxF "$GPU_GOVERNOR"; then
                wr_sys "$_gp/governor" "$GPU_GOVERNOR" "gpu governor" && _applied
                break
            fi
        done
    fi

    if is_uint "${GPU_MIN_PCT:-0}" && [ "$GPU_MIN_PCT" -gt 0 ]; then
        _freqs=$(gpu_avail_freqs)
        if [ -n "$_freqs" ]; then
            # shellcheck disable=SC2086
            _target=$(pick_pct "$GPU_MIN_PCT" $_freqs)
            _mp=$(gpu_min_path)
            _xp=$(gpu_max_path)
            _max=
            [ -n "$_xp" ] && _max=$(read_file "$_xp")
            if is_uint "$_target"; then
                if is_uint "$_max" && [ "$_target" -gt "$_max" ]; then
                    _target=$_max
                fi
                [ -n "$_mp" ] && wr_sys "$_mp" "$_target" "gpu min_freq" && _applied
            fi
        else
            log_v "gpu: frequency table not readable, skipping min_freq"
        fi
        unset _freqs _target _mp _xp _max
    fi
    unset _g _a
    return 0
}

# -------------------------------------------------------------- uclamp ---
profile_apply_uclamp() {
    is_uint "${UCLAMP_TOPAPP_MIN:-0}" || return 0
    [ "$UCLAMP_TOPAPP_MIN" -gt 0 ] || return 0

    for _d in /dev/cpuset/top-app /sys/fs/cgroup/top-app; do
        [ -d "$_d" ] || continue
        for _f in uclamp.min cpu.uclamp.min; do
            [ -e "$_d/$_f" ] || continue
            wr_sys "$_d/$_f" "$UCLAMP_TOPAPP_MIN" "top-app uclamp.min" && _applied
        done
    done
    unset _d _f
    return 0
}

# --------------------------------------------------------------- stune ---
profile_apply_stune() {
    is_uint "${STUNE_BOOST:--1}" || return 0
    [ "$STUNE_BOOST" -ge 0 ] || return 0

    for _d in /dev/stune/top-app /sys/fs/cgroup/stune/top-app; do
        [ -e "$_d/schedtune.boost" ] || continue
        wr_sys "$_d/schedtune.boost" "$STUNE_BOOST" "top-app schedtune.boost" && _applied
    done
    unset _d
    return 0
}

# ------------------------------------------------------------------ io ---
profile_apply_io() {
    [ "${IO_SCHED:-auto}" != auto ] && [ -n "${IO_SCHED:-}" ] || return 0
    for _q in /sys/block/*/queue/scheduler; do
        [ -r "$_q" ] || continue
        case $_q in
            */loop*|*/ram*|*/zram*) continue ;;
        esac
        # The file lists "[mq-deadline] none kyber"; only write when the
        # scheduler is actually offered.
        if read_file "$_q" 2>/dev/null | tr ' ' '\n' | tr -d '[]' |
            grep -qxF "$IO_SCHED"; then
            wr_sys "$_q" "$IO_SCHED" "io scheduler" && _applied
        fi
    done
    unset _q
    return 0
}

# -------------------------------------------------------------- cpusets --
profile_apply_cpus() {
    [ "${TOPAPP_CPUS:-auto}" != auto ] && [ -n "${TOPAPP_CPUS:-}" ] || return 0
    for _d in /dev/cpuset/top-app /sys/fs/cgroup/top-app; do
        [ -e "$_d/cpus" ] || continue
        wr_sys "$_d/cpus" "$TOPAPP_CPUS" "top-app cpus" && _applied
    done
    unset _d
    return 0
}

# -------------------------------------------------------------- network --
profile_apply_net() {
    [ "${TCP_TWEAK:-0}" = 1 ] || return 0

    # Keep congestion state warm: after a short stall (menu, loading) TCP
    # otherwise restarts from a small window and the first seconds of a
    # match feel laggy.
    wr_sys /proc/sys/net/ipv4/tcp_slow_start_after_idle 0 "tcp slow_start_after_idle" && _applied
    wr_sys /proc/sys/net/ipv4/tcp_no_metrics_save 1 "tcp no_metrics_save" && _applied

    if [ "${TCP_CC:-auto}" != auto ] && [ -n "${TCP_CC:-}" ] && [ -r /proc/sys/net/ipv4/tcp_allowed_congestion_control ]; then
        if read_file /proc/sys/net/ipv4/tcp_allowed_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qxF "$TCP_CC"; then
            wr_sys /proc/sys/net/ipv4/tcp_congestion_control "$TCP_CC" "tcp congestion control" && _applied
        fi
    fi

    # Android's Wi-Fi power save adds tens of ms to the first packet after
    # idle; the command does not exist on every ROM, hence the guard.
    if [ "${WIFI_POWER_SAVE:-0}" = 1 ] && _have cmd; then
        cmd wifi force-low-power-mode disable >/dev/null 2>&1 && _applied
    fi
    return 0
}

# --------------------------------------------------------------- driver --
profile_apply_all() {
    APPLIED_COUNT=0
    dev_probe
    profile_apply_cpu
    profile_apply_gpu
    profile_apply_uclamp
    profile_apply_stune
    profile_apply_io
    profile_apply_cpus
    profile_apply_net
    gamemode_apply
    display_apply
    thermal_lift_apply
    log_i "profile '$PROFILE' applied: $APPLIED_COUNT knob(s)"
    return 0
}

profile_restore_all() {
    restore_all
    gamemode_restore
    display_restore
    thermal_lift_restore
    APPLIED_COUNT=0
    log_i "profile '$PROFILE' released"
    return 0
}
