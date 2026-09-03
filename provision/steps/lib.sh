# provision/steps/lib.sh — shared helpers for the first-boot wizard and its
# step modules (issue #14). Sourced by provision/firstboot.sh and by every
# script in this directory. Contains no top-level logic beyond the
# MAX_ATTEMPTS constant, so sourcing it only defines helpers.
#
# Conventions shared by every caller:
#   * POSIX sh; the top-level script runs with `set -e`.
#   * DRY_RUN is per-script state set by parse_flags, never initialized here.
#   * Secrets rules (spec + AGENTS.md): values enter only through masked
#     prompts or the OPENCLAW_DEEPSEEK_KEY env var (piped to the store over
#     stdin, never argv), config holds SecretRefs, and nothing secret is
#     echoed or logged. Helpers never take secret arguments.

MAX_ATTEMPTS=3

# --- output helpers ----------------------------------------------------------

# Print to stdout / stderr.
info() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }

# Run a wizard command (never pass secret material to this helper). With
# --dry-run it only prints what would run.
do_cmd() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] would run: %s\n' "$*"
        return 0
    fi
    printf '  running: %s\n' "$*"
    "$@"
}

# Run one step attempt in a subshell with errexit enabled, so the first
# failing command aborts just that attempt. The caller captures the status;
# errexit is toggled around the call because a plain failing subshell would
# otherwise kill the whole script before we can look at $?.
run_attempt() {  # run_attempt <attempt-fn> ; returns the attempt status
    set +e
    ( set -e; "$1" )
    _attempt_rc=$?
    set -e
    return "$_attempt_rc"
}

# --- read-only state probes --------------------------------------------------

# Read-only: exit 0 when the named store entry exists (metadata only).
store_has() {
    openclaw secrets store list --plain 2>/dev/null | grep -qw "$1"
}

# Read-only: exit 0 when the config path has no authored value.
config_is_unset() {
    _out=$(openclaw config get "$1" 2>&1) || return 0
    case "$_out" in
        *unset* | *'Unknown config path'*) return 0 ;;
    esac
    return 1
}

# Read-only: exit 0 when the config path currently equals the expected value.
config_equals() {  # config_equals <path> <expected>
    _out=$(openclaw config get "$1" 2>&1) || return 1
    case "$_out" in
        *unset* | *'Unknown config path'*) return 1 ;;
    esac
    [ "$(printf '%s\n' "$_out" | tail -n 1)" = "$2" ]
}

# Read-only: exit 0 when commands.ownerAllowFrom lists a Telegram owner.
owner_allow_configured() {
    _out=$(openclaw config get commands.ownerAllowFrom 2>&1) || return 1
    case "$_out" in
        *telegram*) return 0 ;;
    esac
    return 1
}

# --- config writers -----------------------------------------------------------

# Ensure a plain scalar config value; sets it only when it differs, then
# reports the verified state.
ensure_config() {  # ensure_config <path> <expected>
    _path=$1
    _expected=$2
    _got=$(openclaw config get "$_path" 2>&1) || _got=''
    case "$_got" in
        *unset* | *'Unknown config path'*) _got='' ;;
    esac
    _got=$(printf '%s\n' "$_got" | tail -n 1)
    if [ "$_got" = "$_expected" ]; then
        printf '  ok: %s = %s\n' "$_path" "$_got"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] would run: openclaw config set %s %s\n' "$_path" "$_expected"
        return 0
    fi
    printf '  running: openclaw config set %s %s\n' "$_path" "$_expected"
    openclaw config set "$_path" "$_expected"
}

# Ensure a config path references a secret-store entry (SecretRef builder
# mode: never a literal value).
ensure_ref_config() {  # ensure_ref_config <path> <store-ref-id>
    _path=$1
    _id=$2
    if ! config_is_unset "$_path"; then
        printf '  ok (already authored): %s references store entry %s\n' "$_path" "$_id"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] would run: openclaw config set %s --ref-provider default --ref-source store --ref-id %s\n' "$_path" "$_id"
        return 0
    fi
    printf '  running: openclaw config set %s --ref-provider default --ref-source store --ref-id %s\n' "$_path" "$_id"
    openclaw config set "$_path" --ref-provider default --ref-source store --ref-id "$_id"
}

# --- step runner --------------------------------------------------------------

# Run a step: header, attempt with retries (one pass under --dry-run).
run_step() {  # run_step <title> <attempt-fn> <ok-text> <fail-help>
    _title=$1
    _attempt=$2
    _ok=$3
    _help=$4
    printf '\n== %s ==\n' "$_title"
    if [ "$DRY_RUN" -eq 1 ]; then
        run_attempt "$_attempt"
        printf '%s\n' "$_ok"
        return 0
    fi
    _n=0
    while :; do
        _n=$((_n + 1))
        run_attempt "$_attempt" && {
            printf '%s\n' "$_ok"
            return 0
        }
        [ "$_n" -lt "$MAX_ATTEMPTS" ] || break
        printf '  %s failed (attempt %s/%s); retrying...\n' "$_title" "$_n" "$MAX_ATTEMPTS" >&2
    done
    die "$_help"
}

# --- argument parsing and key handling ----------------------------------------

# Parse the shared flags (--dry-run, -h/--help). Sets DRY_RUN; -h/--help
# prints the caller's usage and exits 0, an unknown argument prints the usage
# to stderr and exits 2. <usage-fn> prints the script's own usage text.
parse_flags() {  # parse_flags <usage-fn> [arg...]
    _usage_fn=$1
    shift
    DRY_RUN=0
    for _arg in "$@"; do
        case "$_arg" in
            --dry-run) DRY_RUN=1 ;;
            -h | --help) "$_usage_fn"; exit 0 ;;
            *)
                printf '%s: unknown argument: %s\n' "$0" "$_arg" >&2
                "$_usage_fn" >&2
                exit 2
                ;;
        esac
    done
}

# Snapshot the automation key (OPENCLAW_DEEPSEEK_KEY) into the unexported
# DS_KEY_FROM_ENV variable and scrub it from the environment so no child
# process ever sees it. The key is only ever piped to the store over stdin.
snapshot_deepseek_key() {
    if [ -n "${OPENCLAW_DEEPSEEK_KEY:-}" ]; then
        unset DS_KEY_FROM_ENV
        # Read by provision/steps/20-model-key.sh, which sources this library.
        # shellcheck disable=SC2034
        DS_KEY_FROM_ENV=$OPENCLAW_DEEPSEEK_KEY
        unset OPENCLAW_DEEPSEEK_KEY
        printf '%s\n' \
            'Detected OPENCLAW_DEEPSEEK_KEY: the key will be piped to the secret store' \
            'over stdin (never argv, never echoed, not exported to child processes).'
    fi
}
