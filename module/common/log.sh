# shellcheck shell=sh
#
# CODM Optimizer - logging helpers
#
# Everything goes to $LOG_FILE (rotated once at 512 KiB), warnings and
# errors also go to logcat so they show up in `logcat -s CODM-OPT`.

_LOG_TAG=CODM-OPT

# _have <cmd> - true when the command exists in PATH
_have() { command -v "$1" >/dev/null 2>&1; }

log_init() {
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null
    if [ -f "$LOG_FILE" ]; then
        _sz=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')
        if [ -n "$_sz" ] && [ "$_sz" -gt "$LOG_MAX_BYTES" ] 2>/dev/null; then
            mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
        fi
        unset _sz
    fi
}

_logcat() {
    # severity: one of v,d,i,w,e
    # NOTE: "command log" is Android's logcat front end.  Without the
    # "command" prefix this would resolve to _log_emit() below and loop.
    if _have log; then
        command log -t "$_LOG_TAG" -p "$1" "$2" 2>/dev/null
    fi
}

_log_emit() {
    _lvl=$1
    shift
    _line="$(date '+%Y-%m-%d %H:%M:%S') [$_lvl] $*"
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null
    printf '%s\n' "$_line" >>"$LOG_FILE" 2>/dev/null
    case $_lvl in
        E) _logcat e "$*" ;;
        W) _logcat w "$*" ;;
    esac
    unset _lvl _line
    return 0
}

log_v() { # verbose: only when VERBOSE_LOG=1
    [ "${VERBOSE_LOG:-0}" = 1 ] || return 0
    _log_emit D "$@"
}

log_i() { _log_emit I "$@"; }
log_w() { _log_emit W "$@"; }
log_e() { _log_emit E "$@"; }

# Pretty console output (CLI / action.sh / installer). No-op safe when
# stdout is not a terminal.
say() { printf '%s\n' "$*"; }
