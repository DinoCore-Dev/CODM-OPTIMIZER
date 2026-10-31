# shellcheck shell=sh
#
# CODM Optimizer - low level helpers
#
# Two rules are enforced here, because they are what makes a tweak module
# safe instead of a bootloop generator:
#
#   1. Never write to a knob that does not exist or is not writable.
#   2. Always store the value that was there before writing it, so that
#      restore_all() can put the device back exactly as it was found.

# ---------------------------------------------------------------- basics --
is_uint() { case ${1:-} in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

read_file() { # read_file <path> -> value without trailing newlines
    [ -r "$1" ] || return 1
    _v=$(cat "$1" 2>/dev/null) || return 1
    printf '%s' "$_v"
    unset _v
}

int_of() { # "120.0" -> 120, "" -> ""
    case ${1:-} in
        *.*) printf '%s' "${1%%.*}" ;;
        *)   printf '%s' "${1:-}" ;;
    esac
}

# in_range <value> <min> <max>
in_range() { is_uint "$1" && [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null; }

api_level() {
    _a=$(getprop ro.build.version.sdk 2>/dev/null)
    is_uint "$_a" || _a=0
    printf '%s' "$_a"
    unset _a
}

# ------------------------------------------------------------ originals --
_orig_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

orig_dir_init() { [ -d "$ORIG_DIR" ] || mkdir -p "$ORIG_DIR" 2>/dev/null; }

# save_original <key> <value> - idempotent, keeps the first value seen
save_original() {
    orig_dir_init || return 1
    _f=$ORIG_DIR/$(_orig_name "$1")
    [ -f "$_f" ] && { unset _f; return 0; }
    { printf '%s\n' "$1"; printf '%s\n' "${2:-}"; } >"$_f" 2>/dev/null
    _rc=$?
    unset _f
    return $_rc
}

# Restore one saved entry. Understands two key schemes:
#   sys:/path/to/knob                 -> write the value back
#   settings:<namespace>:<key>        -> settings put/delete
_restore_entry() {
    _key=$1
    _val=$2
    case $_key in
        sys:*)
            _p=${_key#sys:}
            if [ -e "$_p" ] && [ -w "$_p" ]; then
                printf '%s\n' "$_val" >"$_p" 2>/dev/null &&
                    log_v "restored $_p = $_val" ||
                    log_w "could not restore $_p"
            fi
            ;;
        settings:*)
            _rest=${_key#settings:}
            _ns=${_rest%%:*}
            _k=${_rest#*:}
            if _have_android_settings; then
                if [ -z "$_val" ] || [ "$_val" = null ]; then
                    settings delete "$_ns" "$_k" >/dev/null 2>&1
                else
                    settings put "$_ns" "$_k" "$_val" >/dev/null 2>&1
                fi
            fi
            ;;
    esac
    unset _key _val _p _rest _ns _k
}

_have_android_settings() { _have settings; }

# restore_all - put every saved knob back, then drop the saved copies.
# Safe to call twice, and safe to call on a device where nothing was applied.
restore_all() {
    [ -d "$ORIG_DIR" ] || return 0
    _n=0
    for _f in "$ORIG_DIR"/*; do
        [ -f "$_f" ] || continue
        _key=
        _val=
        { IFS= read -r _key; IFS= read -r _val; } <"$_f" 2>/dev/null
        [ -n "$_key" ] || continue
        _restore_entry "$_key" "$_val"
        rm -f "$_f" 2>/dev/null
        _n=$((_n + 1))
    done
    unset _f _key _val
    if [ "${_n:-0}" -gt 0 ]; then
        log_i "restore_all: $_n knob(s) reverted"
    fi
    unset _n
    return 0
}

# restore_matching <glob> - revert only the saved keys matching a pattern.
# Used by the thermal guard, which must drop trip-point edits immediately
# without touching the rest of the gaming profile.
restore_matching() {
    [ -d "$ORIG_DIR" ] || return 0
    _pat=$1
    _n=0
    for _f in "$ORIG_DIR"/*; do
        [ -f "$_f" ] || continue
        _key=
        _val=
        { IFS= read -r _key; IFS= read -r _val; } <"$_f" 2>/dev/null
        [ -n "$_key" ] || continue
        case $_key in
            $_pat)
                _restore_entry "$_key" "$_val"
                rm -f "$_f" 2>/dev/null
                _n=$((_n + 1))
                ;;
        esac
    done
    unset _f _key _val _pat
    [ "$_n" -gt 0 ] && log_i "restore_matching: $_n knob(s) reverted"
    unset _n
    return 0
}

# ---------------------------------------------------------------- writes --
# wr_sys <path> <value> [label]
# Returns 0 only when the value really changed on disk.
wr_sys() {
    _p=$1
    _v=$2
    _label=${3:-$_p}
    if [ ! -e "$_p" ]; then
        log_v "skip $_label: no such knob ($_p)"
        return 1
    fi
    if [ ! -w "$_p" ]; then
        log_v "skip $_label: not writable ($_p)"
        return 1
    fi
    _old=$(read_file "$_p") || _old=
    if [ "$_old" = "$_v" ]; then
        log_v "$_label already $_v"
        unset _p _v _label _old
        return 0
    fi
    save_original "sys:$_p" "$_old"
    printf '%s\n' "$_v" >"$_p" 2>/dev/null
    _rc=$?
    _new=$(read_file "$_p") || _new=
    if [ $_rc -ne 0 ] || [ "$_new" != "$_v" ]; then
        # Accept a write that changed the value even if it was normalised
        # (e.g. "25" -> "25.00" on uclamp files).
        if [ $_rc -eq 0 ] && [ -n "$_new" ] && [ "$_new" != "$_old" ]; then
            log_v "$_label set to $_new (asked $_v)"
            unset _p _v _label _old _new _rc
            return 0
        fi
        log_w "$_label: write failed (wanted '$_v', got '$_new')"
        unset _p _v _label _old _new _rc
        return 1
    fi
    log_v "$_label = $_v"
    unset _p _v _label _old _new _rc
    return 0
}

# set_setting <namespace> <key> <value>
set_setting() {
    _have settings || return 1
    _ns=$1
    _k=$2
    _v=$3
    _old=$(settings get "$_ns" "$_k" 2>/dev/null) || _old=null
    if [ "$_old" = "$_v" ]; then
        unset _ns _k _v _old
        return 0
    fi
    save_original "settings:$_ns:$_k" "$_old"
    settings put "$_ns" "$_k" "$_v" >/dev/null 2>&1
    _rc=$?
    log_v "settings $_ns/$_k = $_v (was $_old)"
    unset _ns _k _v _old
    return $_rc
}

# --------------------------------------------------------------- helpers --
# Pick a value from a sorted list by percentage of the range.
# pick_pct <pct 0-100> <list ascending>
pick_pct() {
    _pct=$1
    shift
    _count=$#
    [ "$_count" -gt 0 ] || { unset _pct _count; return 1; }
    _idx=$(((_count - 1) * _pct / 100))
    _i=0
    for _x in "$@"; do
        if [ "$_i" -eq "$_idx" ]; then
            printf '%s' "$_x"
            unset _pct _count _idx _i _x
            return 0
        fi
        _i=$((_i + 1))
    done
    unset _pct _count _idx _i _x
    return 1
}

# asc <list> - sort numerically ascending, one per line
asc() { tr ' ' '\n' | sort -n 2>/dev/null; }

# now_epoch
now_epoch() { date +%s 2>/dev/null || printf '0'; }

# pid_is_alive <pid>
pid_is_alive() {
    is_uint "${1:-}" || return 1
    [ -d "/proc/$1" ] || return 1
    return 0
}

# single_instance <lockname> - mkdir based lock, no flock dependency
lock_acquire() {
    [ -d "$RUN_DIR" ] || mkdir -p "$RUN_DIR" 2>/dev/null || return 1
    _d=$RUN_DIR/$1.lock
    if mkdir "$_d" 2>/dev/null; then
        printf '%s' "$$" >"$_d/pid" 2>/dev/null
        unset _d
        return 0
    fi
    _owner=$(read_file "$_d/pid") || _owner=
    if pid_is_alive "$_owner"; then
        unset _d _owner
        return 1
    fi
    rm -rf "$_d" 2>/dev/null
    mkdir "$_d" 2>/dev/null || { unset _d _owner; return 1; }
    printf '%s' "$$" >"$_d/pid" 2>/dev/null
    unset _d _owner
    return 0
}

lock_release() {
    [ -n "${1:-}" ] || return 0
    rm -rf "$RUN_DIR/$1.lock" 2>/dev/null
    return 0
}

trim() {
    _t=$*
    _t=${_t#"${_t%%[![:space:]]*}"}
    _t=${_t%"${_t##*[![:space:]]}"}
    printf '%s' "$_t"
    unset _t
}
