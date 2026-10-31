# shellcheck shell=sh
#
# CODM Optimizer - Android Game Mode integration
#
# This is the one CODM-specific feature that is *not* a sysfs hack: it
# uses the platform's own Game Mode API, the same mechanism the Android
# game dashboard uses.  Availability differs per Android version, so the
# code walks down from newest to oldest and stops at the first one the
# device accepts:
#
#   Android 14+ : cmd game set [--fps N] [--downscale R] <pkg>  (+ mode custom)
#   Android 13  : device_config put game_overlay <pkg> mode=2,... + cmd game mode 2
#   Android 12  : cmd game mode 2 <pkg>
#
# No game file is touched and no frame limit is faked - if the platform
# refuses, we say so in the log and move on.

_gm_modes_line() {
    cmd game list-modes "$1" 2>/dev/null | head -1
}

_gm_current_mode() {
    _gm_modes_line "$1" | sed -n 's/.*current mode: \([a-z]*\).*/\1/p'
}

_game_ok() {
    case "$1" in
        *'available game modes'*) return 0 ;;
    esac
    return 1
}

gamemode_apply() {
    [ "${GAME_MODE:-0}" = 1 ] || return 0
    _have cmd || { log_v "gamemode: no cmd binary"; return 0; }

    _api=$(api_level)
    if [ "$_api" -lt 31 ] 2>/dev/null; then
        log_v "gamemode: needs Android 12+ (have API $_api)"
        unset _api
        return 0
    fi

    _pkg=$(game_primary_pkg)
    _modes=$(_gm_modes_line "$_pkg")
    if ! _game_ok "$_modes"; then
        log_v "gamemode: platform does not treat $_pkg as a game (got: ${_modes:-nothing})"
        unset _api _pkg _modes
        return 0
    fi

    if [ ! -f "$GM_MARKER" ]; then
        : >"$GM_MARKER" 2>/dev/null
        device_config get game_overlay "$_pkg" >"$GM_OVERLAY" 2>/dev/null
        log_v "gamemode: original state saved (modes: $_modes)"
    fi

    _fps=${GAME_MODE_FPS:-0}
    is_uint "$_fps" || _fps=0
    _ds=${GAME_MODE_DOWNSCALE:-off}
    case $_ds in
        off|0) _ds=off ;;
    esac

    _done=0

    # --- Android 14+: custom intervention (fps and/or downscale) ---------
    if [ "$_api" -ge 34 ] && { [ "$_fps" -gt 0 ] || [ "$_ds" != off ]; }; then
        if [ "$_fps" -gt 0 ] && [ "$_ds" != off ]; then
            cmd game set --fps "$_fps" --downscale "$_ds" "$_pkg" >/dev/null 2>&1 && _done=1
        elif [ "$_fps" -gt 0 ]; then
            cmd game set --fps "$_fps" "$_pkg" >/dev/null 2>&1 && _done=1
        else
            cmd game set --downscale "$_ds" "$_pkg" >/dev/null 2>&1 && _done=1
        fi
        if [ "$_done" = 1 ]; then
            cmd game mode custom "$_pkg" >/dev/null 2>&1
            log_v "gamemode: custom intervention fps=${_fps} downscale=${_ds}"
        fi
    fi

    # --- Android 13: overlay entry + performance mode ---------------------
    if [ "$_done" = 0 ] && [ "$_api" -eq 33 ] && { [ "$_fps" -gt 0 ] || [ "$_ds" != off ]; }; then
        _conf="mode=2"
        [ "$_fps" -gt 0 ] && _conf="$_conf,fps=$_fps"
        [ "$_ds" != off ] && _conf="$_conf,downscaleFactor=$_ds"
        if device_config put game_overlay "$_pkg" "$_conf" >/dev/null 2>&1; then
            cmd game mode 2 "$_pkg" >/dev/null 2>&1 && _done=1
            log_v "gamemode: overlay '$_conf'"
        fi
    fi

    # --- Android 12/13: plain performance mode ---------------------------
    if [ "$_done" = 0 ]; then
        if cmd game mode performance "$_pkg" >/dev/null 2>&1; then
            _done=1
            log_v "gamemode: performance mode"
        elif cmd game mode 2 "$_pkg" >/dev/null 2>&1; then
            _done=1
            log_v "gamemode: performance mode (numeric)"
        fi
    fi

    if [ "$_done" = 1 ]; then
        _applied
        _mode=$(_gm_current_mode "$_pkg")
        case $_mode in
            standard|unsupported|'')
                log_w "gamemode: asked for performance but the platform reports '${_mode:-unknown}' - the ROM may ignore interventions"
                ;;
            *)
                log_i "gamemode: now '$_mode' for $_pkg (API $_api)"
                ;;
        esac
    else
        log_w "gamemode: device refused every game mode call for $_pkg"
    fi

    unset _api _pkg _modes _fps _ds _conf _done _mode
    return 0
}

gamemode_restore() {
    [ -f "$GM_MARKER" ] || return 0
    _have cmd || return 0
    _pkg=$(game_primary_pkg)

    # reset removes the custom intervention on 13+, standard is the
    # fallback for older builds.
    cmd game reset "$_pkg" >/dev/null 2>&1 ||
        cmd game mode standard "$_pkg" >/dev/null 2>&1 ||
        cmd game mode 1 "$_pkg" >/dev/null 2>&1

    # Put back (or delete) a device_config overlay we may have written.
    _orig=$(read_file "$GM_OVERLAY" 2>/dev/null)
    if [ -n "$_orig" ] && [ "$_orig" != null ]; then
        device_config put game_overlay "$_pkg" "$_orig" >/dev/null 2>&1
    else
        device_config delete game_overlay "$_pkg" >/dev/null 2>&1
    fi

    rm -f "$GM_MARKER" "$GM_OVERLAY" 2>/dev/null
    log_i "gamemode: released $_pkg"
    unset _pkg _orig
    return 0
}

# report_gamemode - one line for status/doctor
report_gamemode() {
    _pkg=$(game_primary_pkg)
    if ! _have cmd; then
        printf 'unsupported (no cmd binary)'
        unset _pkg
        return 0
    fi
    _line=$(_gm_modes_line "$_pkg")
    if [ -z "$_line" ]; then
        printf 'unsupported (no game mode service)'
    else
        printf '%s' "$_line"
    fi
    unset _pkg _line
}
