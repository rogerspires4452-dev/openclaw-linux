#!/bin/sh
# provision/steps/50-channel.sh — first-boot wizard Step 5: set
# update.channel=dev (persisted; applies on the next update).
# docs/specs/first-boot.md Step 5; issue #14 refactor.
# Usage: 50-channel.sh [--dry-run]
#
# Idempotent step module: when update.channel is already dev the step reports
# itself done and changes nothing. Normally invoked by provision/firstboot.sh
# (which runs each step in order and skips the ones already done); run this
# file directly to re-run or repair just this step.
set -e

_script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091 # lib.sh is linted directly by CI (provision/steps/*.sh)
. "$_script_dir/lib.sh"

# Invoked by name from the standalone main below and from firstboot.sh; the
# parse_flags dispatcher calls the usage function indirectly, which SC2317
# cannot see.
# shellcheck disable=SC2317
usage() {
    cat <<EOF
Usage: $0 [--dry-run]

Step 5 of the first-boot pairing wizard (provision/firstboot.sh): set
update.channel=dev. This persists the channel choice only; it does not update
anything yet. Idempotent: a channel already set to dev is reported done and
left untouched.

Options:
  --dry-run   Print what this step would do; change nothing.
  -h, --help  Show this help and exit.
EOF
}

# Read-only: exit 0 when the step's outcome already exists (spec acceptance:
# update.channel = dev).
step5_done() {
    config_equals update.channel dev
}

# Invoked by name through run_step (dispatch by function name), which SC2317
# cannot see.
# shellcheck disable=SC2317
step5_attempt() {
    ensure_config update.channel dev
}

step5() {
    if step5_done; then
        printf '\n== %s ==\n' 'Step 5/5 — Set update.channel=dev'
        printf '  already done — skipping.\n'
        return 0
    fi
    run_step 'Step 5/5 — Set update.channel=dev' step5_attempt \
        'Step 5 OK: update.channel = dev (persisted; no update applied).' \
        'Step 5 failed after 3 attempts. See docs/specs/first-boot.md Step 5 (re-run: openclaw config set update.channel dev), then re-run.'
}

# --- main ---------------------------------------------------------------------

parse_flags usage "$@"
step5
exit 0
