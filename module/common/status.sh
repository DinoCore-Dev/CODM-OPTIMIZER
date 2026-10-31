# shellcheck shell=sh
#
# CODM Optimizer - status / doctor reports
#
# Shared by `codm-optimizer status`, `codm-optimizer doctor` and the
# module's action button so all three print the same thing.

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    C_RST=$(printf '\033[0m')
    C_DIM=$(printf '\033[2m')
    C_B=$(printf '\033[1m')
    C_G=$(printf '\033[32m')
    C_Y=$(printf '\033[33m')
    C_R=$(printf '\033[31m')
    C_C=$(printf '\033[36m')
else
    C_RST=; C_DIM=; C_B=; C_G=; C_Y=; C_R=; C_C=
fi

_row() { # label value
    printf '%s%s%s %s\n' "$C_DIM" "$(printf '%-10s' "$1")" "$C_RST" "$2"
}

_sec() { printf '%s%s== %s ==%s\n' "$C_B" "$C_C" "$1" "$C_RST"; }

_yes() { printf '%syes%s' "$C_G" "$C_RST"; }
_no() { printf '%sno%s' "$C_R" "$C_RST"; }
_warn_s() { printf '%swarn%s' "$C_Y" "$C_RST"; }

_MOD_VER=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -1)

engine_pid() {
    _p=$(read_file "$PID_FILE" 2>/dev/null)
    if pid_is_alive "$_p"; then
        printf '%s' "$_p"
        unset _p
        return 0
    fi
    unset _p
    return 1
}

engine_state() {
    _s=$(read_file "$RUN_DIR/state" 2>/dev/null)
    printf '%s' "${_s:-unknown}"
    unset _s
}

session_summary() {
    [ -f "$SESSION_FILE" ] || return 1
    _l=$(tail -1 "$SESSION_FILE" 2>/dev/null)
    [ -n "$_l" ] || { unset _l; return 1; }
    _start=$(printf '%s' "$_l" | cut -f1)
    _dur=$(printf '%s' "$_l" | cut -f2)
    _prof=$(printf '%s' "$_l" | cut -f3)
    _maxt=$(printf '%s' "$_l" | cut -f4)
    _end=$(printf '%s' "$_l" | cut -f5)
    if is_uint "$_start" && is_uint "$_dur"; then
        printf 'last session: %dm%02ds on %s, max %sC, ended (%s)' \
            $((_dur / 60)) $((_dur % 60)) "${_prof:--}" "${_maxt:--}" "${_end:--}"
    fi
    unset _l _start _dur _prof _maxt _end
    return 0
}

_cpu_line() {
    _any=0
    for _p in $(cpu_policies); do
        _gov=$(read_file "$_p/scaling_governor" 2>/dev/null)
        _min=$(read_file "$_p/scaling_min_freq" 2>/dev/null)
        _max=$(read_file "$_p/scaling_max_freq" 2>/dev/null)
        _cur=$(read_file "$_p/scaling_cur_freq" 2>/dev/null)
        _up=$(read_file "$_p/schedutil/up_rate_limit_us" 2>/dev/null)
        printf '%s%s%s %s/%s/%s MHz gov=%s' "$C_DIM" "${_p##*/}" "$C_RST" \
            "$((${_cur:-0} / 1000))" "$((${_min:-0} / 1000))" "$((${_max:-0} / 1000))" \
            "${_gov:-?}"
        [ -n "$_up" ] && printf ' up_rate=%sus' "$_up"
        printf '\n'
        _any=1
    done
    [ "$_any" = 1 ] || printf '  (no cpufreq interface)\n'
    unset _p _gov _min _max _cur _up _any
}

_gpu_line() {
    if [ "$GPU_DRIVER" = none ] || [ -z "$GPU_DIR" ]; then
        printf '  no controllable GPU node found (safe: GPU left alone)\n'
        return 0
    fi
    _cur=$(gpu_cur_freq 2>/dev/null)
    _min=$(read_file "$(gpu_min_path)" 2>/dev/null)
    _max=$(read_file "$(gpu_max_path)" 2>/dev/null)
    printf '  %s (%s) cur=%s min=%s max=%s MHz\n' "$GPU_DRIVER" "$GPU_DIR" \
        "$((${_cur:-0} / 1000000))" "$((${_min:-0} / 1000000))" "$((${_max:-0} / 1000000))"
    unset _cur _min _max
}

status_report() {
    dev_probe
    config_ensure
    config_load

    printf '%s%s%s %s\n' "$C_B" "$MODNAME" "$C_RST" "${_MOD_VER:-?}"
    printf '%s\n' "$C_DIM──────────────────────────────────────────────$C_RST"

    _row device "$DEV_BRAND $DEV_MODEL ($DEV_SOC, Android $DEV_RELEASE / API $DEV_SDK)"
    _row root "${ROOT_IMPL}${ROOT_VER:+ $ROOT_VER} / selinux ${SELINUX:-?}"

    _pid=$(engine_pid) || _pid=
    if [ -n "$_pid" ]; then
        _row engine "running (pid $_pid), state=$(engine_state)"
    else
        _row engine "not running"
    fi
    _row profile "$PROFILE  (enabled=$ENGINE_ENABLED refresh_lock=$REFRESH_LOCK game_mode=$GAME_MODE)"

    _installed=$(game_installed_packages | tr '\n' ' ')
    _gs=$(game_state)
    _row game "${_installed:-not installed} [$_gs]"

    _sec cpu
    _cpu_line
    _sec gpu
    _gpu_line
    _sec thermal
    printf '  %s\n' "$(report_thermal)"
    _sec display
    printf '  %s\n' "$(report_refresh)"
    _sec game mode api
    printf '  %s\n' "$(report_gamemode)"
    _sec session
    _ss=$(session_summary) && printf '  %s\n' "$_ss" || printf '  no session recorded yet\n'

    printf '\n%sconfig%s %s\n' "$C_DIM" "$C_RST" "$CONF"
    printf '%slog%s    %s\n' "$C_DIM" "$C_RST" "$LOG_FILE"
    unset _pid _installed _gs _ss
}

# ------------------------------------------------------------------ doctor --
D_PASS=0
D_WARN=0
D_FAIL=0

_dr() { # status label detail
    case $1 in
        PASS) printf '  %sPASS%s %-26s %s\n' "$C_G" "$C_RST" "$2" "$3"; D_PASS=$((D_PASS + 1)) ;;
        WARN) printf '  %sWARN%s %-26s %s\n' "$C_Y" "$C_RST" "$2" "$3"; D_WARN=$((D_WARN + 1)) ;;
        FAIL) printf '  %sFAIL%s %-26s %s\n' "$C_R" "$C_RST" "$2" "$3"; D_FAIL=$((D_FAIL + 1)) ;;
    esac
}

doctor_report() {
    D_PASS=0
    D_WARN=0
    D_FAIL=0
    dev_probe
    config_ensure
    config_load

    printf '%s%s doctor%s\n' "$C_B" "$MODNAME" "$C_RST"
    printf '%s\n' "$C_DIM──────────────────────────────────────────────$C_RST"

    # root -----------------------------------------------------------------
    if [ "$(id -u 2>/dev/null)" = 0 ]; then
        _dr PASS "root shell" "uid 0"
    else
        _dr FAIL "root shell" "not running as root"
    fi

    # module dir -----------------------------------------------------------
    if [ -f "$MODDIR/module.prop" ]; then
        _dr PASS "module files" "$MODDIR"
    else
        _dr FAIL "module files" "module.prop missing in $MODDIR"
    fi

    # writable state dir ---------------------------------------------------
    if mkdir -p "$DATA_DIR" 2>/dev/null && touch "$DATA_DIR/.wtest" 2>/dev/null; then
        rm -f "$DATA_DIR/.wtest" 2>/dev/null
        _dr PASS "state directory" "$DATA_DIR"
    else
        _dr FAIL "state directory" "$DATA_DIR is not writable"
    fi

    # config ---------------------------------------------------------------
    if [ -f "$CONF" ]; then
        _dr PASS "config" "$CONF (profile=$PROFILE)"
    else
        _dr WARN "config" "not created yet, run: codm-optimizer start"
    fi

    # engine ---------------------------------------------------------------
    if _p=$(engine_pid); then
        _dr PASS "engine" "running (pid $_p), state=$(engine_state)"
    else
        _dr FAIL "engine" "not running - run: codm-optimizer start"
    fi

    # game -----------------------------------------------------------------
    _inst=$(game_installed_packages | tr '\n' ' ')
    if [ -n "$_inst" ]; then
        _dr PASS "game installed" "$_inst"
    else
        _dr WARN "game installed" "no CODM package found (add one with EXTRA_PACKAGES=)"
    fi

    # cpu control ----------------------------------------------------------
    _policies=$(cpu_policies)
    if [ -n "$_policies" ]; then
        _w=0
        for _p in $_policies; do [ -w "$_p/scaling_min_freq" ] || _w=1; done
        if [ "$_w" = 0 ]; then
            _dr PASS "cpu frequency control" "$(printf '%s\n' $_policies | wc -l | tr -d ' ') policies writable"
        else
            _dr WARN "cpu frequency control" "some policies are read-only on this kernel"
        fi
    else
        _dr FAIL "cpu frequency control" "no cpufreq interface"
    fi
    unset _policies _p _w

    # schedutil ------------------------------------------------------------
    _has_su=0
    for _p in $(cpu_policies); do
        [ -e "$_p/schedutil/up_rate_limit_us" ] && _has_su=1
    done
    if [ "$_has_su" = 1 ]; then
        _dr PASS "schedutil ramp knobs" "up_rate_limit_us writable"
    else
        _dr WARN "schedutil ramp knobs" "governor does not expose schedutil tunables, CPU ramp tuning skipped"
    fi
    unset _has_su _p

    # gpu ------------------------------------------------------------------
    if [ -n "$GPU_DIR" ] && [ -w "$(gpu_min_path)" ]; then
        _dr PASS "gpu frequency control" "$GPU_DRIVER via $GPU_DIR"
    elif [ -n "$GPU_DIR" ]; then
        _dr WARN "gpu frequency control" "node found but read-only"
    else
        _dr WARN "gpu frequency control" "no devfreq/sysfs GPU node, GPU left untouched"
    fi

    # thermal --------------------------------------------------------------
    _z=$(thermal_zones | wc -l | tr -d ' ')
    if is_uint "$_z" && [ "$_z" -gt 0 ]; then
        _dr PASS "thermal sensors" "$_z zones readable"
    else
        _dr WARN "thermal sensors" "none readable, the temperature guard cannot work"
    fi
    if [ -n "$(battery_temp_c)" ]; then
        _dr PASS "battery temperature" "$(battery_temp_c)C"
    else
        _dr WARN "battery temperature" "not readable, SoC guard only"
    fi

    # uclamp ---------------------------------------------------------------
    if [ -e /dev/cpuset/top-app/uclamp.min ] || [ -e /sys/fs/cgroup/top-app/cpu.uclamp.min ]; then
        _dr PASS "uclamp (top-app)" "available"
    else
        _dr WARN "uclamp (top-app)" "not exposed by this kernel, skipped"
    fi

    # display --------------------------------------------------------------
    _mhz=$(display_max_hz)
    if is_uint "$_mhz" && [ "$_mhz" -ge 60 ] 2>/dev/null; then
        _dr PASS "display modes" "panel advertises up to ${_mhz}Hz"
    else
        _dr WARN "display modes" "could not read panel modes, REFRESH_LOCK may do nothing"
    fi
    if [ "$(settings get system peak_refresh_rate 2>/dev/null)" != null ] ||
        [ "$(settings get system min_refresh_rate 2>/dev/null)" != null ]; then
        _dr PASS "refresh rate settings" "key present"
    else
        _dr WARN "refresh rate settings" "ROM ignores min/peak_refresh_rate"
    fi
        
    # game mode ------------------------------------------------------------
    _gm=$(report_gamemode)
    case $_gm in
        *'current mode'*) _dr PASS "android game mode" "$_gm" ;;
        unsupported*)     _dr WARN "android game mode" "$_gm" ;;
        *)                _dr WARN "android game mode" "$_gm" ;;
    esac

    # detection ------------------------------------------------------------
    _tf=$(_topapp_file 2>/dev/null) || _tf=
    if [ -n "$_tf" ]; then
        _dr PASS "foreground detection" "top-app cpuset ($_tf)"
    else
        _dr WARN "foreground detection" "no cpuset file, falling back to dumpsys"
    fi

    printf '\n'
    if [ "$D_FAIL" -gt 0 ]; then
        printf '%s%d problem(s), %d warning(s)%s - see docs/TROUBLESHOOTING.md\n' \
            "$C_R" "$D_FAIL" "$D_WARN" "$C_RST"
    elif [ "$D_WARN" -gt 0 ]; then
        printf '%s%d warning(s)%s - the module works, some knobs are just not exposed here\n' \
            "$C_Y" "$D_WARN" "$C_RST"
    else
        printf '%sall checks passed%s\n' "$C_G" "$C_RST"
    fi
    unset _p _inst _z _mhz _gm _tf
    return 0
}
