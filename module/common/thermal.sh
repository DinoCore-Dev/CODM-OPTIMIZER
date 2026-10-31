# shellcheck shell=sh
#
# CODM Optimizer - thermal policy
#
# Thermal handling is the part where gaming modules usually destroy
# phones, so the defaults here are conservative:
#
#   THERMAL_LIFT_C=0    -> we do not touch a single trip point (default)
#   THERMAL_LIFT_C=2..8 -> nudge only the *passive* trip points of CPU/
#                          GPU/SoC zones by that many degrees, never the
#                          critical ones, never the battery/charger ones
#
# Independently of that, the engine always watches the battery and SoC
# temperature and drops the whole gaming profile when TEMP_LIMIT_C is
# reached.  That guard can not be disabled from the config.

THERMAL_MAX_LIFT_C=8
THERMAL_HOT=0

_thermal_safe_zone() { # $1 = zone type
    case $1 in
        *batt*|*BATT*|*charg*|*CHARG*|*usb*|*USB*|*pmic*|*PMIC*) return 1 ;;
        *cpu*|*CPU*|*gpu*|*GPU*|*soc*|*SoC*|*ap*|*cluster*|*tsens*|*mtkts*|*big*|*little*|*silver*|*gold*|*modem*) return 0 ;;
    esac
    return 1
}

thermal_lift_apply() {
    is_uint "${THERMAL_LIFT_C:-0}" || return 0
    [ "${THERMAL_LIFT_C:-0}" -gt 0 ] 2>/dev/null || return 0

    _lift=$THERMAL_LIFT_C
    [ "$_lift" -gt "$THERMAL_MAX_LIFT_C" ] && _lift=$THERMAL_MAX_LIFT_C
    _lift_mc=$((_lift * 1000))

    _n=0
    while IFS='|' read -r _z _type _temp; do
        [ -n "$_z" ] || continue
        _thermal_safe_zone "$_type" || continue
        for _i in 0 1 2 3 4 5 6 7 8 9 10 11; do
            _tf=$_z/trip_point_${_i}_temp
            [ -r "$_tf" ] || continue
            _tt=$(read_file "$_z/trip_point_${_i}_type" 2>/dev/null)
            case $_tt in
                critical|critical_hot|*critical*) continue ;;
            esac
            _v=$(read_file "$_tf") || continue
            is_uint "$_v" || continue
            # Only sane, non-critical operating temperatures.
            in_range "$_v" 30000 105000 || continue
            _new=$((_v + _lift_mc))
            if wr_sys "$_tf" "$_new" "thermal trip ($_type)"; then
                _n=$((_n + 1))
                _applied
            fi
        done
    done <<EOF
$(thermal_zones)
EOF
    if [ "$_n" -gt 0 ]; then
        log_i "thermal: lifted $_n trip point(s) by ${_lift}C"
    else
        log_v "thermal: no writable trip points, lift not applied"
    fi
    unset _lift _lift_mc _z _type _temp _tf _tt _v _new _n _i
    return 0
}

thermal_lift_restore() {
    restore_matching 'sys:/sys/class/thermal/*'
}

# thermal_too_hot - 0 when the device must back off right now
thermal_too_hot() {
    _limit=${TEMP_LIMIT_C:-43}
    is_uint "$_limit" || _limit=43

    _bt=$(battery_temp_c)
    if is_uint "$_bt" && [ "$_bt" -ge "$_limit" ]; then
        THERMAL_HOT_TEMP=$_bt
        log_w "thermal guard: battery ${_bt}C >= ${_limit}C"
        unset _bt _limit
        return 0
    fi

    # SoC zones run hotter than the battery; give them a wider margin.
    _st=$(soc_temp_c)
    if is_uint "$_st" && [ "$_st" -ge $((_limit + 20)) ]; then
        THERMAL_HOT_TEMP=$_st
        log_w "thermal guard: soc ${_st}C >= $((_limit + 20))C"
        unset _bt _st _limit
        return 0
    fi

    unset _bt _st _limit
    return 1
}

# thermal_cooled_down - 0 when it is safe to re-apply the profile
thermal_cooled_down() {
    _limit=${TEMP_LIMIT_C:-43}
    _delta=${TEMP_RESUME_DELTA_C:-3}
    is_uint "$_limit" || _limit=43
    is_uint "$_delta" || _delta=3
    _target=$((_limit - _delta))

    _bt=$(battery_temp_c)
    is_uint "$_bt" || { unset _limit _delta _target _bt; return 0; }
    if [ "$_bt" -le "$_target" ]; then
        unset _limit _delta _target _bt
        return 0
    fi
    unset _limit _delta _target _bt
    return 1
}

report_thermal() {
    _bt=$(battery_temp_c)
    _st=$(soc_temp_c)
    printf 'battery=%sC soc=%sC limit=%sC guard=%s' \
        "${_bt:-?}" "${_st:-?}" "${TEMP_LIMIT_C:-43}" \
        "$([ "${THERMAL_HOT:-0}" = 1 ] && echo HOT || echo ok)"
    unset _bt _st
}
