# shellcheck shell=sh
#
# CODM Optimizer - finding the game
#
# Detection is deliberately boring and cheap because the engine runs it
# every few seconds for the whole life of the phone:
#   * package list from config + built-in CODM variants
#   * "is it running"  -> pidof (falls back to a /proc scan)
#   * "is it visible"  -> is one of those pids in the top-app cpuset?
#                         (falls back to dumpsys on ROMs without cpusets)

# game_pkg_list - every package name we care about, space separated
game_pkg_list() {
    printf '%s' "$(printf '%s\n' $CODM_PACKAGES $EXTRA_PACKAGES | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
}

# game_installed_packages - subset actually installed, one per line
game_installed_packages() {
    _pm_list=
    if _have pm; then
        _pm_list=$(pm list packages 2>/dev/null | sed 's/^package://')
    fi
    if [ -z "$_pm_list" ]; then
        # Fallback for weird environments: look for the data directory.
        for _p in $(game_pkg_list); do
            [ -d "/data/data/$_p" ] && printf '%s\n' "$_p"
        done
        unset _pm_list _p
        return 0
    fi
    for _p in $(game_pkg_list); do
        printf '%s\n' "$_pm_list" | grep -qxF "$_p" && printf '%s\n' "$_p"
    done
    unset _pm_list _p
    return 0
}

# game_primary_pkg - first installed package, used for `cmd game` calls
game_primary_pkg() {
    [ -n "${GAME_PKG_CACHE:-}" ] && { printf '%s' "$GAME_PKG_CACHE"; return 0; }
    _p=$(game_installed_packages | head -1)
    if [ -z "$_p" ]; then
        # Not installed (or pm unavailable): still allow the global package
        # so that the user can pre-configure before installing the game.
        _p=com.activision.callofduty.shooter
    fi
    GAME_PKG_CACHE=$_p
    printf '%s' "$_p"
    unset _p
}

# game_running_pids - one pid per line, empty when the game is not running
game_running_pids() {
    _any=0
    for _p in $(game_pkg_list); do
        if _have pidof; then
            for _pid in $(pidof "$_p" 2>/dev/null); do
                is_uint "$_pid" && { printf '%s\n' "$_pid"; _any=1; }
            done
        else
            for _d in /proc/[0-9]*; do
                [ -r "$_d/cmdline" ] || continue
                _c=$(tr '\000' '\n' <"$_d/cmdline" 2>/dev/null | head -1)
                [ "$_c" = "$_p" ] && { printf '%s\n' "${_d#/proc/}"; _any=1; }
            done
        fi
    done
    unset _p _pid _d _c _any
    return 0
}

# _topapp_file - path of the file that lists pids in the top-app cpuset
_topapp_file() {
    # test hook: lets the offline suite point this at a fixture
    if [ -n "${CODM_TOPAPP_FILE:-}" ]; then
        printf '%s' "$CODM_TOPAPP_FILE"
        return 0
    fi
    for _f in /dev/cpuset/top-app/cgroup \
              /sys/fs/cgroup/top-app/cgroup.procs \
              /sys/fs/cgroup/top-app/cgroup \
              /dev/cpuset/top-app/cgroup.procs ; do
        [ -r "$_f" ] && { printf '%s' "$_f"; unset _f; return 0; }
    done
    unset _f
    return 1
}

# _resumed_line - the "topResumedActivity" line from ActivityManager
_resumed_line() {
    _have dumpsys || return 1
    dumpsys activity activities 2>/dev/null |
        grep -m1 -E 'topResumedActivity|mResumedActivity|ResumedActivity'
}

game_in_top_app() { # [pid list]
    _tf=$(_topapp_file) || return 1
    _pids=${1:-$(game_running_pids)}
    _hit=1
    for _pid in $_pids; do
        if grep -qx -- "$_pid" "$_tf" 2>/dev/null; then
            _hit=0
            break
        fi
    done
    unset _tf _pid _pids
    return $_hit
}

game_resumed() {
    _line=$(_resumed_line) || return 1
    [ -n "$_line" ] || { unset _line; return 1; }
    _hit=1
    for _p in $(game_pkg_list); do
        case $_line in
            *"$_p"*) _hit=0; break ;;
        esac
    done
    unset _line _p
    return $_hit
}

# game_state - none | background | foreground
# The pid list is collected once and handed to both checks.
game_state() {
    GAME_PIDS=$(game_running_pids)
    if [ -z "$GAME_PIDS" ]; then
        printf '%s' none
        return 0
    fi
    if game_in_top_app "$GAME_PIDS"; then
        printf '%s' foreground
        return 0
    fi
    if game_resumed; then
        printf '%s' foreground
        return 0
    fi
    printf '%s' background
}

# screen_on - 0 when the display is interactive
screen_on() {
    if _have dumpsys; then
        _w=$(dumpsys power 2>/dev/null |
            grep -m1 -o 'mWakefulness=[A-Za-z]*' |
            sed 's/^mWakefulness=//')
        case $_w in
            Awake) unset _w; return 0 ;;
            '')    : ;;
            *)     unset _w; return 1 ;;
        esac
        unset _w
    fi
    # Fallback: some ROMs report screen state in sysfs.
    for _f in /sys/class/display/panel0/state /sys/class/graphics/fb0/blank ; do
        [ -r "$_f" ] || continue
        _v=$(read_file "$_f")
        case $_v in
            0|on|ON) unset _f _v; return 0 ;;
            *)       unset _f _v; return 1 ;;
        esac
    done
    unset _f _v
    return 0
}
