#!/bin/sh
# provision/steps/10-gateway.sh — first-boot wizard Step 1: enable the gateway
# systemd user service (openclaw-gateway.service), plus user lingering so it
# survives logout (docs/specs/first-boot.md Step 1; issue #14 refactor).
# Usage: 10-gateway.sh [--dry-run]
#
# Idempotent step module: when the service is already enabled and active the
# step reports itself done and changes nothing. Normally invoked by
# provision/firstboot.sh (which runs each step in order and skips the ones
# already done); run this file directly to re-run or repair just this step.
set -e

_script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091 # lib.sh is linted directly by CI (provision/steps/*.sh)
. "$_script_dir/lib.sh"

# Invoked by name from firstboot.sh and from the standalone main below; the
# run_attempt/parse_flags dispatchers call functions indirectly, which SC2317
# cannot see.
# shellcheck disable=SC2317
usage() {
    cat <<EOF
Usage: $0 [--dry-run]

Step 1 of the first-boot pairing wizard (provision/firstboot.sh): enable and
start the gateway systemd user service (openclaw-gateway.service) and enable
user lingering so the service survives logout. Idempotent: a service that is
already enabled and active is reported done and left untouched.

Options:
  --dry-run   Print what this step would do; change nothing.
  -h, --help  Show this help and exit.
EOF
}

# Read-only: exit 0 when the step's outcome already exists (spec acceptance:
# the service is enabled and active).
step1_done() {
    [ "$(systemctl --user is-enabled openclaw-gateway.service 2>/dev/null)" = enabled ] || return 1
    [ "$(systemctl --user is-active openclaw-gateway.service 2>/dev/null)" = active ] || return 1
    return 0
}

# Invoked by name through run_step (dispatch by function name), which SC2317
# cannot see.
# shellcheck disable=SC2317
step1_attempt() {
    do_cmd openclaw gateway install
    do_cmd systemctl --user daemon-reload
    do_cmd systemctl --user enable --now openclaw-gateway.service
    # Linger keeps the user service alive without a logged-in desktop session.
    _linger=$(loginctl show-user "$(id -un)" -p Linger 2>/dev/null) || _linger=''
    if [ "$_linger" = 'Linger=yes' ]; then
        printf '  ok: user lingering already enabled\n'
    elif [ "$DRY_RUN" -eq 1 ]; then
        do_cmd sudo loginctl enable-linger "$(id -un)"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        do_cmd sudo loginctl enable-linger "$(id -un)"
    else
        printf '%s\n' \
            '  note: skipping lingering (needs passwordless sudo). Run once if the box' \
            '  will ever run without a logged-in desktop session:' \
            "    sudo loginctl enable-linger \"\$(id -un)\""
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] would verify: systemctl --user is-enabled openclaw-gateway.service = enabled\n'
        printf '  [dry-run] would verify: systemctl --user is-active openclaw-gateway.service = active\n'
        printf '  [dry-run] would verify: openclaw gateway status\n'
        return 0
    fi
    _enabled=$(systemctl --user is-enabled openclaw-gateway.service 2>/dev/null) || _enabled=''
    _active=$(systemctl --user is-active openclaw-gateway.service 2>/dev/null) || _active=''
    if [ "$_enabled" != enabled ]; then
        printf '  FAIL: service is-enabled = %s (expected enabled)\n' "${_enabled:-unknown}" >&2
        return 1
    fi
    if [ "$_active" != active ]; then
        printf '  FAIL: service is-active = %s (expected active)\n' "${_active:-unknown}" >&2
        return 1
    fi
    printf '  ok: openclaw-gateway.service enabled and active\n'
    do_cmd openclaw gateway status
}

step1() {
    _title='Step 1/5 — Enable the gateway systemd user service'
    if step1_done; then
        printf '\n== %s ==\n' "$_title"
        printf '  already done — skipping.\n'
        return 0
    fi
    printf '\n== %s ==\n' "$_title"
    if [ "$DRY_RUN" -eq 1 ]; then
        run_attempt step1_attempt
        printf 'Step 1 would: enable and start openclaw-gateway.service (plus lingering).\n'
        return 0
    fi
    _n=0
    while :; do
        _n=$((_n + 1))
        run_attempt step1_attempt && {
            printf 'Step 1 OK: gateway service enabled and active.\n'
            return 0
        }
        [ "$_n" -lt "$MAX_ATTEMPTS" ] || break
        printf '  Step 1 failed (attempt %s/%s); retrying...\n' "$_n" "$MAX_ATTEMPTS" >&2
    done
    printf '%s\n' '--- journalctl --user -u openclaw-gateway.service (tail) ---' >&2
    journalctl --user -u openclaw-gateway.service -n 50 2>/dev/null | tail -n 50 || true
    die "Step 1 failed after $MAX_ATTEMPTS attempts. Fix what the journal above reports (see docs/specs/first-boot.md, Step 1 failure handling), then re-run; the wizard resumes at this step."
}

# --- main ---------------------------------------------------------------------

parse_flags usage "$@"
step1
exit 0
