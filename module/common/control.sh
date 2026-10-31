# shellcheck shell=sh
#
# CODM Optimizer - engine control
#
# Starting and stopping the engine is needed by the CLI, the WebUI bridge
# and the boot service, so it lives in one place.
#
# The engine is started detached (double fork + setsid when available) so
# it survives the terminal session or the WebUI request that spawned it.

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

engine_start() {
    if _pid=$(engine_pid); then
        log_v "engine_start: already running (pid $_pid)"
        ENGINE_PID=$_pid
        unset _pid
        return 0
    fi
    config_ensure
    config_load
    log_init
    log_i "engine start requested"

    if command -v setsid >/dev/null 2>&1; then
        ( setsid sh "$MODDIR/common/engine.sh" </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
    else
        ( sh "$MODDIR/common/engine.sh" </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi

    _i=0
    while [ "$_i" -lt 25 ]; do
        if _pid=$(engine_pid); then
            ENGINE_PID=$_pid
            unset _pid _i
            return 0
        fi
        sleep 0.2 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    unset _i
    log_w "engine_start: no pid reported, see $LOG_FILE"
    return 1
}

engine_stop() {
    if ! _pid=$(engine_pid); then
        log_v "engine_stop: not running"
        return 0
    fi
    log_i "engine stop requested"
    kill -TERM "$_pid" 2>/dev/null
    _i=0
    while [ "$_i" -lt 25 ]; do
        pid_is_alive "$_pid" || break
        sleep 0.2 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    pid_is_alive "$_pid" && kill -9 "$_pid" 2>/dev/null
    rm -f "$PID_FILE" 2>/dev/null
    unset _pid _i
    return 0
}

engine_restart() {
    engine_stop
    sleep 1
    engine_start
}

# Ask the running engine to re-apply the profile on its next tick.
# Used by the WebUI so a toggle takes effect immediately instead of
# waiting for the 60 s re-apply cycle.
engine_nudge() {
    mkdir -p "$RUN_DIR" 2>/dev/null
    : >"$RUN_DIR/reapply" 2>/dev/null
}
