# shellcheck shell=sh
#
# CODM Optimizer - configuration loading
#
# config.conf is a plain KEY=VALUE file.  It is parsed, never executed,
# so a typo cannot break the engine and a stray command in the file does
# nothing.  User values win over profile values.

# _load_kv <file> - export every KEY=VALUE line of a file
_load_kv() {
    [ -r "$1" ] || return 1
    _line=
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line=$(printf '%s' "$_line" | sed 's/\r$//')
        case $_line in
            ''|\#*) continue ;;
        esac
        _key=${_line%%=*}
        [ "$_key" = "$_line" ] && continue
        _val=${_line#*=}
        # drop trailing "  # comment" (values never contain a spaced hash)
        _val=$(printf '%s' "$_val" | sed 's/[[:space:]]#.*$//')
        _val=$(trim "$_val")
        # Strip one layer of matching quotes.
        case $_val in
            \"*\") _val=${_val#\"}; _val=${_val%\"} ;;
            \'*\') _val=${_val#\'}; _val=${_val%\'} ;;
        esac
        case $_key in
            [A-Za-z_]*) ;;
            *) continue ;;
        esac
        case $_key in
            *[!A-Za-z0-9_]*) continue ;;
        esac
        export "$_key=$_val"
    done <"$1"
    unset _line _key _val
    return 0
}

config_ensure() {
    [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR" 2>/dev/null || return 1
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null
    [ -d "$RUN_DIR" ] || mkdir -p "$RUN_DIR" 2>/dev/null
    [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
    [ -d "$SESSION_DIR" ] || mkdir -p "$SESSION_DIR" 2>/dev/null
    if [ ! -f "$CONF" ]; then
        if [ -r "$MODDIR/config/default.conf" ]; then
            cp -f "$MODDIR/config/default.conf" "$CONF" 2>/dev/null
        else
            : >"$CONF"
        fi
        chmod 0644 "$CONF" 2>/dev/null
    fi
    return 0
}

# config_load - defaults, then user config, then profile, then user again
config_load() {
    _load_kv "$MODDIR/config/default.conf"

    # First pass gives us PROFILE.
    _load_kv "$CONF"
    PROFILE=$(printf '%s' "${PROFILE:-balanced}" | tr 'A-Z' 'a-z')
    case $PROFILE in
        balanced|performance|extreme|battery) ;;
        *) PROFILE=balanced ;;
    esac

    # Profile supplies the kernel knobs...
    if [ -r "$MODDIR/profiles/$PROFILE.conf" ]; then
        _load_kv "$MODDIR/profiles/$PROFILE.conf"
    fi
    # ...and the user config wins over the profile defaults.
    _load_kv "$CONF"

    PROFILE=$(printf '%s' "${PROFILE:-balanced}" | tr 'A-Z' 'a-z')
    case $PROFILE in
        balanced|performance|extreme|battery) ;;
        *) PROFILE=balanced ;;
    esac
    _validate_config
    return 0
}

# _num_or <key> <default> <min> <max> - keep a numeric key sane.
# A typo in config.conf must not turn into a busy loop or a 0 C thermal
# limit, so every number the engine acts on is validated here.
_num_or() { # <key> <current value> <default> <min> <max>
    _k=$1
    _v=$2
    _def=$3
    _min=$4
    _max=$5
    if ! is_uint "$_v"; then
        _v=$_def
    fi
    [ "$_v" -lt "$_min" ] 2>/dev/null && _v=$_min
    [ "$_v" -gt "$_max" ] 2>/dev/null && _v=$_max
    export "$_k=$_v"
    unset _k _def _min _max _v
}

_validate_config() {
    _num_or POLL_GAME_SEC "${POLL_GAME_SEC:-}" 5 3 60
    _num_or POLL_IDLE_SEC "${POLL_IDLE_SEC:-}" 15 5 300
    _num_or REAPPLY_SEC "${REAPPLY_SEC:-}" 60 15 3600
    _num_or GUARD_INTERVAL_SEC "${GUARD_INTERVAL_SEC:-}" 20 5 300
    _num_or TEMP_LIMIT_C "${TEMP_LIMIT_C:-}" 43 35 60
    _num_or TEMP_RESUME_DELTA_C "${TEMP_RESUME_DELTA_C:-}" 3 1 10
    _num_or THERMAL_LIFT_C "${THERMAL_LIFT_C:-}" 0 0 8
    _num_or GAME_MODE_FPS "${GAME_MODE_FPS:-}" 0 0 240
    _num_or ENGINE_ENABLED "${ENGINE_ENABLED:-}" 1 0 1
    case ${GAME_MODE:-1} in
        0) GAME_MODE=0 ;;
        *) GAME_MODE=1 ;;
    esac
    case ${REFRESH_LOCK:-1} in
        0) REFRESH_LOCK=0 ;;
        *) REFRESH_LOCK=1 ;;
    esac
    case ${VERBOSE_LOG:-0} in
        1) VERBOSE_LOG=1 ;;
        *) VERBOSE_LOG=0 ;;
    esac
    case ${REFRESH_HZ:-auto} in
        auto|'') REFRESH_HZ=auto ;;
        *)
            is_uint "$REFRESH_HZ" || REFRESH_HZ=auto
            ;;
    esac
}

config_set() { # config_set <key> <value> - rewrite one line, keep comments
    _k=$1
    _v=$2
    [ -f "$CONF" ] || config_ensure
    _tmp=$CONF.tmp.$$
    if grep -q "^${_k}=" "$CONF" 2>/dev/null; then
        while IFS= read -r _l || [ -n "$_l" ]; do
            case $_l in
                "${_k}="*) printf '%s=%s\n' "$_k" "$_v" ;;
                *) printf '%s\n' "$_l" ;;
            esac
        done <"$CONF" >"$_tmp"
    else
        cp -f "$CONF" "$_tmp" 2>/dev/null
        printf '\n%s=%s\n' "$_k" "$_v" >>"$_tmp"
    fi
    mv -f "$_tmp" "$CONF" 2>/dev/null
    _rc=$?
    rm -f "$_tmp" 2>/dev/null
    unset _k _v _l _tmp
    return $_rc
}
