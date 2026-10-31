# shellcheck shell=sh
#
# CODM Optimizer - display refresh handling
#
# Two separate things live here:
#
#   REFRESH_LOCK=1  keeps the panel at its highest rate while the game is
#                   in front.  Several ROMs drop to 60 Hz when it thinks
#                   nothing "needs" the higher rate, which caps CODM even
#                   when the game offers 90/120 in its own menu.
#
# Nothing here overrides the game's own frame limiter or DRM refresh
# policy, and everything is reverted when the game goes away.

display_apply() {
    [ "${REFRESH_LOCK:-0}" = 1 ] || return 0
    _have settings || return 0

    _max=$(display_max_hz_cached)
    if ! is_uint "$_max" || [ "$_max" -lt 60 ] 2>/dev/null; then
        log_v "display: cannot determine max refresh rate, skipping"
        unset _max
        return 0
    fi

    # A phone panel above 240 Hz does not exist; anything higher is a
    # parsing accident in dumpsys, not a mode we should pin.
    [ "$_max" -gt 240 ] && _max=240

    _hz=${REFRESH_HZ:-auto}
    case $_hz in
        auto|'') _hz=$_max ;;
    esac
    is_uint "$_hz" || _hz=$_max
    [ "$_hz" -gt "$_max" ] && _hz=$_max
    [ "$_hz" -lt 60 ] && _hz=60

    if set_setting system min_refresh_rate "$_hz"; then
        _applied
    fi
    if set_setting system peak_refresh_rate "$_hz"; then
        _applied
    fi
    log_v "display: refresh locked at ${_hz}Hz (panel max ${_max}Hz)"
    unset _max _hz
    return 0
}

# Restoring is done by restore_all() through the saved settings keys.
display_restore() { return 0; }

# report_refresh - one line for status/doctor
report_refresh() {
    _min=$(settings get system min_refresh_rate 2>/dev/null)
    _peak=$(settings get system peak_refresh_rate 2>/dev/null)
    _max=$(display_max_hz_cached)
    printf 'panel max=%sHz  min_refresh_rate=%s  peak_refresh_rate=%s' \
        "${_max:-?}" "${_min:-?}" "${_peak:-?}"
    unset _min _peak _max
}
