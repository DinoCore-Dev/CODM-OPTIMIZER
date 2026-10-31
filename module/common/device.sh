# shellcheck shell=sh
#
# CODM Optimizer - device + capability discovery
#
# Nothing here assumes a specific SoC.  Every knob is probed first and a
# missing knob simply means "this device does not expose it", never an
# error.  The report built here is what `codm-optimizer doctor` prints.

DEV_PROBED=0

# Defaults so that a caller which has not run dev_probe() yet (or a kernel
# that exposes nothing) never trips over an unset variable under `set -u`.
DEV_BRAND=
DEV_MODEL=
DEV_BOARD=
DEV_SOC=
DEV_SOC_MFG=
DEV_RELEASE=
DEV_SDK=
DEV_KERNEL=
DEV_PLATFORM=unknown
ROOT_IMPL=unknown
ROOT_VER=
SELINUX=
GPU_DRIVER=none
GPU_DIR=
GPU_FREQ_KIND=

dev_probe() {
    [ "$DEV_PROBED" = 1 ] && return 0

    DEV_BRAND=$(getprop ro.product.brand 2>/dev/null)
    DEV_MODEL=$(getprop ro.product.model 2>/dev/null)
    DEV_BOARD=$(getprop ro.board.platform 2>/dev/null)
    DEV_SOC=$(getprop ro.soc.model 2>/dev/null)
    [ -n "$DEV_SOC" ] || DEV_SOC=$DEV_BOARD
    DEV_SOC_MFG=$(getprop ro.soc.manufacturer 2>/dev/null)
    DEV_RELEASE=$(getprop ro.build.version.release 2>/dev/null)
    DEV_SDK=$(api_level)
    DEV_KERNEL=$(uname -r 2>/dev/null)

    case $DEV_SOC in
        *mt[0-9]*|*MT[0-9]*) DEV_PLATFORM=mediatek ;;
        *exynos*|*Exynos*)    DEV_PLATFORM=samsung ;;
        *tensor*|*gs[0-9]*)   DEV_PLATFORM=google ;;
        *kona*|*lahaina*|*taro*|*kalama*|*crow*|*pineapple*|*sun*|*sm[0-9]*) DEV_PLATFORM=qualcomm ;;
        *) DEV_PLATFORM=unknown ;;
    esac

    dev_probe_root
    gpu_probe
    DEV_PROBED=1
    return 0
}

# ------------------------------------------------------------ root impl --
dev_probe_root() {
    ROOT_IMPL=unknown
    if [ -d /data/adb/magisk ] || command -v magisk >/dev/null 2>&1; then
        ROOT_IMPL=magisk
    elif [ -d /data/adb/ksu ] || [ -n "${KSU:-}" ]; then
        ROOT_IMPL=kernelsu
    elif [ -d /data/adb/ap ] || [ -n "${APATCH:-}" ]; then
        ROOT_IMPL=apatch
    fi
    ROOT_VER=
    if [ "$ROOT_IMPL" = magisk ]; then
        ROOT_VER=$(magisk -V 2>/dev/null)
    fi
    SELINUX=$(getenforce 2>/dev/null)
}

# ------------------------------------------------------------------ cpu --
# Print the cpufreq policy directories of the device, one per line.
cpu_policies() {
    _found=0
    for _d in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$_d" ] || continue
        printf '%s\n' "$_d"
        _found=1
    done
    [ "$_found" = 1 ] && { unset _found _d; return 0; }
    for _d in /sys/devices/system/cpu/cpu*/cpufreq; do
        [ -d "$_d" ] || continue
        [ -f "$_d/scaling_governor" ] || continue
        printf '%s\n' "$_d"
        _found=1
    done
    unset _found _d
    return 0
}

# cpu_avail_freqs <policy dir> -> ascending list, space separated
cpu_avail_freqs() {
    _l=
    for _k in scaling_available_frequencies available_frequencies; do
        [ -r "$1/$_k" ] || continue
        _l=$(read_file "$1/$_k")
        [ -n "$_l" ] && break
    done
    [ -n "$_l" ] || { unset _l _k; return 1; }
    printf '%s' "$(printf '%s\n' $_l | sort -n | uniq | tr '\n' ' ')" |
        sed 's/^ *//; s/ *$//'
    unset _l _k
}

# ---------------------------------------------------------------- gpu ----
# Sets GPU_DRIVER, GPU_DIR, GPU_FREQ_KIND (devfreq|sysfs).
gpu_probe() {
    GPU_DRIVER=none
    GPU_DIR=
    GPU_FREQ_KIND=

    for _d in \
        /sys/class/kgsl/kgsl-3d0/devfreq \
        /sys/class/kgsl/kgsl-3d0 \
        /sys/class/devfreq/*kgsl* \
        /sys/class/devfreq/*mali* \
        /sys/class/devfreq/*gpu* \
        /sys/class/devfreq/*gpufreq* ; do
        [ -d "$_d" ] || continue
        if [ -f "$_d/min_freq" ] && [ -f "$_d/max_freq" ]; then
            GPU_DIR=$_d
            GPU_FREQ_KIND=devfreq
            break
        fi
    done

    if [ -n "$GPU_DIR" ]; then
        case $GPU_DIR in
            *kgsl*)  GPU_DRIVER=adreno ;;
            *mali*)  GPU_DRIVER=mali ;;
            *gpu*)   GPU_DRIVER=mali ;;
            *)       GPU_DRIVER=devfreq ;;
        esac
    elif [ -f /sys/kernel/gpu/gpu_min_clock ] && [ -f /sys/kernel/gpu/gpu_max_clock ]; then
        GPU_DIR=/sys/kernel/gpu
        GPU_DRIVER=mali
        GPU_FREQ_KIND=sysfs
    fi
    unset _d
}

# gpu_avail_freqs -> ascending, space separated (empty when unknown)
gpu_avail_freqs() {
    [ -n "$GPU_DIR" ] || return 1
    _list=
    for _f in available_frequencies gpu_available_frequencies freq_table; do
        [ -r "$GPU_DIR/$_f" ] || continue
        _list=$(read_file "$GPU_DIR/$_f")
        [ -n "$_list" ] && break
    done
    [ -n "$_list" ] || { unset _list _f; return 1; }
    # Some drivers pad the list with zeros or trailing junk.
    _out=
    for _x in $_list; do
        is_uint "$_x" || continue
        [ "$_x" -gt 0 ] || continue
        _out="$_out $_x"
    done
    [ -n "$_out" ] || { unset _list _f _out _x; return 1; }
    printf '%s' "$(printf '%s\n' $_out | sort -n | uniq | tr '\n' ' ')" |
        sed 's/^ *//; s/ *$//'
    unset _list _f _out _x
}

gpu_cur_freq() {
    [ -n "$GPU_DIR" ] || return 1
    for _f in cur_freq gpu_cur_clock cur_clock; do
        [ -r "$GPU_DIR/$_f" ] || continue
        _v=$(read_file "$GPU_DIR/$_f")
        [ -n "$_v" ] && { printf '%s' "$_v"; unset _f _v; return 0; }
    done
    unset _f _v
    return 1
}

gpu_min_path() {
    case $GPU_FREQ_KIND in
        devfreq) printf '%s' "$GPU_DIR/min_freq" ;;
        sysfs)   printf '%s' "$GPU_DIR/gpu_min_clock" ;;
    esac
}

gpu_max_path() {
    case $GPU_FREQ_KIND in
        devfreq) printf '%s' "$GPU_DIR/max_freq" ;;
        sysfs)   printf '%s' "$GPU_DIR/gpu_max_clock" ;;
    esac
}

# -------------------------------------------------------------- thermal --
# thermal_zones - print "zone_path|type|temp_millic" for every readable zone
thermal_zones() {
    for _z in "$THERMAL_DIR"/thermal_zone*; do
        [ -d "$_z" ] || continue
        _t=$(read_file "$_z/type" 2>/dev/null) || continue
        _v=$(read_file "$_z/temp" 2>/dev/null) || continue
        is_uint "$_v" || continue
        printf '%s|%s|%s\n' "$_z" "$_t" "$_v"
    done
    unset _z _t _v
}

# battery_temp_c - rounded battery temperature in Celsius, empty if unknown
battery_temp_c() {
    for _p in "$PSU_DIR/battery/temp" \
              "$PSU_DIR/bms/temp" \
              "$PSU_DIR"/*/temp ; do
        [ -r "$_p" ] || continue
        _v=$(read_file "$_p")
        is_uint "$_v" || continue
        # Android reports tenths of a degree (400 -> 40.0C). Some report
        # millidegrees; anything above 1000 would be absurd for tenths.
        if [ "$_v" -gt 1000 ]; then
            printf '%s' $((_v / 1000))
        else
            printf '%s' $((_v / 10))
        fi
        unset _p _v
        return 0
    done
    unset _p _v
    return 1
}

# soc_temp_c - hottest CPU/GPU/SoC zone in Celsius, empty if unknown
soc_temp_c() {
    _max=0
    while IFS='|' read -r _z _t _v; do
        [ -n "$_z" ] || continue
        case $_t in
            *cpu*|*CPU*|*gpu*|*GPU*|*soc*|*SoC*|*ap*|*cluster*|*big*|*little*|*tsens*|*mtkts*|*silver*|*gold*) ;;
            *) continue ;;
        esac
        # keep it in a sane range, some zones report garbage before init
        if in_range "$_v" 1000 200000 && [ "$_v" -gt "$_max" ]; then
            _max=$_v
        fi
    done <<EOF
$(thermal_zones)
EOF
    [ "$_max" -gt 0 ] || { unset _max _z _t _v; return 1; }
    if [ "$_max" -gt 1000 ]; then
        printf '%s' $((_max / 1000))
    else
        printf '%s' $((_max / 10))
    fi
    unset _max _z _t _v
}

# --------------------------------------------------------------- display --
# display_max_hz - highest refresh rate the panel advertises
display_max_hz() {
    _hz=
    if _have dumpsys; then
        _hz=$(dumpsys display 2>/dev/null |
            sed -n 's/.*fps=\([0-9][0-9]*\)\(\.[0-9]*\)\?.*/\1/p' |
            sort -n | tail -1)
    fi
    [ -n "$_hz" ] || _hz=$(read_file /sys/class/graphics/fb0/mode 2>/dev/null |
        sed -n 's/.*@\([0-9][0-9]*\).*/\1/p')
    printf '%s' "${_hz:-}"
    unset _hz
}

# display_max_hz_cached - same value, cached for an hour.
# `dumpsys display` is not expensive but the WebUI asks for it every few
# seconds, and the answer never really changes on a given device.
display_max_hz_cached() {
    _c=$STATE_DIR/panel_max_hz
    [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
    if [ -f "$_c" ]; then
        _m=$(stat -c '%Y' "$_c" 2>/dev/null || printf '0')
        _n=$(now_epoch)
        if [ $((_n - _m)) -lt 3600 ] 2>/dev/null; then
            printf '%s' "$(read_file "$_c")"
            unset _c _m _n
            return 0
        fi
    fi
    _hz=$(display_max_hz)
    if [ -n "$_hz" ]; then
        printf '%s' "$_hz" >"$_c" 2>/dev/null
        printf '%s' "$_hz"
    fi
    unset _c _m _n _hz
    return 0
}

# current_refresh_hz - what the panel is measured at right now, if the
# kernel exposes it.  Reporting only: nothing is written here.
current_refresh_hz() {
    for _f in /sys/class/graphics/fb0/measured_fps \
              /sys/class/graphics/fb1/measured_fps \
              /sys/class/drm/card0-DSI-1/measured_fps ; do
        [ -r "$_f" ] || continue
        _v=$(read_file "$_f")
        _v=$(int_of "$_v")
        if is_uint "$_v" && [ "$_v" -gt 0 ] && [ "$_v" -le 240 ]; then
            printf '%s' "$_v"
            unset _f _v
            return 0
        fi
    done
    unset _f _v
    return 1
}

# --------------------------------------------------------------- storage --
storage_free_mb() { # storage_free_mb <mount>
    _k=$(df -k "$1" 2>/dev/null | awk 'NR==2{print $4}')
    is_uint "$_k" || { unset _k; return 1; }
    printf '%s' $((_k / 1024))
    unset _k
}
