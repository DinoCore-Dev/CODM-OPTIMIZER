#!/system/bin/sh
#
# CODM Optimizer - engine
#
# A single long lived shell loop.  It decides whether the game is in the
# foreground, applies the selected profile, and - most importantly -
# always releases every knob again when the game goes away, the screen
# turns off, the phone gets hot, or the module is disabled.
#
# State machine:
#
#   idle ──game visible──▶ active ──gone 45s / hot / screen off──▶ idle
#     ▲                      │
#     └──── disabled ────────┘
#
# Everything is in one process on purpose: no wakelocks, no busybox
# daemons, no cron.  Idle cost is one pidof every POLL_IDLE_SEC seconds.

MODDIR=${0%/*}
case $MODDIR in
    */common) MODDIR=${MODDIR%/common} ;;
esac

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

STATE_FILE=$RUN_DIR/state
IDLE_GRACE_SEC=45
IDLE_SINCE=0

STATE=idle
APPLIED_PROFILE=
LAST_APPLY=0
LAST_GUARD=0
SESSION_START=0
SESSION_MAX_TEMP=
HOT_SINCE=0
CFG_STAMP=
CFG_LAST_CHECK=0

write_state() {
    printf '%s\n' "$1" >"$STATE_FILE" 2>/dev/null
}

session_begin() {
    SESSION_START=$(now_epoch)
    SESSION_MAX_TEMP=
    log_i "session start (profile $PROFILE)"
}

session_end() {
    _end=$(now_epoch)
    _dur=$((_end - SESSION_START))
    [ "$SESSION_START" -gt 0 ] 2>/dev/null || _dur=0
    [ "$_dur" -lt 0 ] && _dur=0
    mkdir -p "$SESSION_DIR" 2>/dev/null
    if [ -z "$SESSION_MAX_TEMP" ]; then
        SESSION_MAX_TEMP=$(battery_temp_c)
        [ -n "$SESSION_MAX_TEMP" ] || SESSION_MAX_TEMP=?
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$SESSION_START" "$_dur" "$APPLIED_PROFILE" "${SESSION_MAX_TEMP:-?}" \
        "${1:-normal}" >>"$SESSION_FILE" 2>/dev/null
    # keep the log file from growing forever
    if [ -f "$SESSION_FILE" ]; then
        _lines=$(wc -l <"$SESSION_FILE" 2>/dev/null | tr -d ' ')
        if is_uint "$_lines" && [ "$_lines" -gt 200 ]; then
            tail -n 100 "$SESSION_FILE" >"$SESSION_FILE.tmp" 2>/dev/null &&
                mv -f "$SESSION_FILE.tmp" "$SESSION_FILE" 2>/dev/null
        fi
    fi
    log_i "session end after ${_dur}s (max ${SESSION_MAX_TEMP:-?}C, ${1:-normal})"
    SESSION_START=0
    unset _end _dur _lines
}

activate() {
    [ "$STATE" = active ] && return 0
    log_i "game detected in foreground -> activating profile '$PROFILE'"
    session_begin
    STATE=active
    apply_now
    write_state active
}

apply_now() {
    APPLIED_PROFILE=$PROFILE
    LAST_APPLY=$(now_epoch)
    profile_apply_all
}

deactivate() { # deactivate <reason>
    if [ "$STATE" = idle ] || [ "$STATE" = disabled ]; then
        restore_all
        STATE=idle
        write_state idle
        return 0
    fi
    log_i "releasing profile ($1)"
    profile_restore_all
    STATE=idle
    write_state idle
    session_end "$1"
    APPLIED_PROFILE=
    IDLE_SINCE=0
}

on_signal() {
    log_i "signal received, shutting down"
    # de activate records the session and reverts every knob
    deactivate "engine stopped"
    rm -f "$PID_FILE" 2>/dev/null
    write_state stopped
    lock_release engine
    exit 0
}

# config reload, throttled: stat is cheap, parsing is not
maybe_reload_config() {
    _now=$(now_epoch)
    [ $((_now - CFG_LAST_CHECK)) -lt 15 ] && { unset _now; return 0; }
    CFG_LAST_CHECK=$_now
    _stamp=$(stat -c '%Y' "$CONF" 2>/dev/null || printf '%s' "$_now")
    unset _now
    if [ "$_stamp" != "$CFG_STAMP" ]; then
        CFG_STAMP=$_stamp
        config_load
        log_v "config reloaded (profile=$PROFILE engine=$ENGINE_ENABLED)"
        # A profile switch while the game is running must take effect.
        if [ "$STATE" = active ] && [ "$PROFILE" != "$APPLIED_PROFILE" ]; then
            log_i "profile changed $APPLIED_PROFILE -> $PROFILE, re-applying"
            profile_restore_all
            apply_now
        fi
    fi
    unset _stamp
    return 0
}

guard_check() {
    _now=$(now_epoch)
    [ $((_now - LAST_GUARD)) -lt "${GUARD_INTERVAL_SEC:-20}" ] && { unset _now; return 0; }
    LAST_GUARD=$_now
    unset _now

    _t=$(battery_temp_c)
    if is_uint "$_t"; then
        if [ -z "$SESSION_MAX_TEMP" ] || { is_uint "$SESSION_MAX_TEMP" && [ "$_t" -gt "$SESSION_MAX_TEMP" ]; }; then
            SESSION_MAX_TEMP=$_t
        fi
    fi
    unset _t

    if [ "$STATE" = active ] && thermal_too_hot; then
        log_w "thermal guard triggered, dropping to stock until it cools"
        deactivate "thermal limit"
        STATE=hot
        HOT_SINCE=$(now_epoch)
        write_state hot
        return 0
    fi

    if [ "$STATE" = hot ] && thermal_cooled_down; then
        log_i "temperature back to normal, profile may resume"
        THERMAL_HOT=0
        STATE=idle
        write_state idle
        if [ "$(game_state)" = foreground ]; then
            activate
        fi
    fi
    return 0
}

main_loop() {
    while :; do
        maybe_reload_config

        if [ "${ENGINE_ENABLED:-1}" != 1 ]; then
            [ "$STATE" = active ] && deactivate "engine disabled"
            if [ "$STATE" != disabled ]; then
                STATE=disabled
                write_state disabled
                log_i "engine paused by config"
            fi
            sleep "${POLL_IDLE_SEC:-15}"
            continue
        fi

        [ "$STATE" = disabled ] && { STATE=idle; write_state idle; }

        _gs=$(game_state)
        case $_gs in
            foreground)
                IDLE_SINCE=0
                if screen_on; then
                    if [ "$STATE" != hot ]; then
                        activate
                        _now=$(now_epoch)
                        if [ $((_now - LAST_APPLY)) -ge "${REAPPLY_SEC:-60}" ]; then
                            log_v "periodic re-apply (the ROM may have reset knobs)"
                            apply_now
                        fi
                        unset _now
                    fi
                else
                    [ "$STATE" = active ] && deactivate "screen off"
                fi
                ;;
            *)
                if [ "$STATE" = active ] || [ "$STATE" = hot ]; then
                    _now=$(now_epoch)
                    [ "$IDLE_SINCE" = 0 ] && IDLE_SINCE=$_now
                    if [ $((_now - IDLE_SINCE)) -ge "$IDLE_GRACE_SEC" ]; then
                        deactivate "game not visible"
                    fi
                    unset _now
                fi
                ;;
        esac

        guard_check

        if [ "$_gs" = foreground ]; then
            sleep "${POLL_GAME_SEC:-5}"
        else
            sleep "${POLL_IDLE_SEC:-15}"
        fi
    done
}

# ------------------------------------------------------------------ boot --
config_ensure
config_load
log_init

if ! lock_acquire engine; then
    _other=$(read_file "$PID_FILE")
    log_w "engine already running (pid ${_other:-?}), exiting"
    exit 0
fi
printf '%s' "$$" >"$PID_FILE" 2>/dev/null

trap on_signal INT TERM HUP

dev_probe
# Recover from a previous run that ended badly (reboot mid-match, crash).
if [ -d "$ORIG_DIR" ] && [ -n "$(ls -A "$ORIG_DIR" 2>/dev/null)" ]; then
    log_w "found leftover knobs from a previous session, restoring first"
    restore_all
    gamemode_restore
fi

log_i "engine started (pid $$, profile $PROFILE, android $(api_level), root $ROOT_IMPL)"
write_state idle
main_loop
