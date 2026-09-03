#!/bin/sh
# provision/steps/20-model-key.sh — first-boot wizard Step 2: configure the
# DeepSeek provider. Masked secret-store entry for DEEPSEEK_API_KEY (or the
# OPENCLAW_DEEPSEEK_KEY env var, piped over stdin), SecretRef config, default
# model deepseek/deepseek-v4-pro, live inference check (docs/specs/first-boot.md
# Step 2; issue #14 refactor).
# Usage: 20-model-key.sh [--dry-run]
#
# Idempotent step module: when the key is stored, the apiKey SecretRef is
# authored, and the default model is set, the step reports itself done and
# changes nothing. Normally invoked by provision/firstboot.sh (which runs each
# step in order and skips the ones already done); run this file directly to
# re-run or repair just this step.
#
# Secrets rules: the key is only ever piped to the secret store over stdin —
# never in argv, never echoed, never exported to child processes. When this
# file runs under firstboot.sh the wizard has already scrubbed
# OPENCLAW_DEEPSEEK_KEY and passes the value in DS_KEY_FROM_ENV for this
# process only; when run standalone this step snapshots and scrubs the env
# var itself. In both cases DS_KEY_FROM_ENV is re-created as an unexported
# variable below before any child process is spawned.
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

Step 2 of the first-boot pairing wizard (provision/firstboot.sh): store the
DeepSeek API key as a secret-store entry (masked prompt, or
OPENCLAW_DEEPSEEK_KEY exported for unattended runs), wire
models.providers.deepseek.apiKey to it as a SecretRef, set the default model
to deepseek/deepseek-v4-pro, and run a live inference smoke test. Idempotent:
a fully configured provider is reported done and left untouched.

Options:
  --dry-run   Print what this step would do; change nothing.
  -h, --help  Show this help and exit.
EOF
}

# Read-only: exit 0 when the step's outcome already exists (spec acceptance:
# key stored as a SecretRef and the default model set).
step2_done() {
    store_has DEEPSEEK_API_KEY || return 1
    config_is_unset models.providers.deepseek.apiKey && return 1
    config_equals agents.defaults.model.primary deepseek/deepseek-v4-pro
}

# DeepSeek key entry: env var (masked stdin pipe) or no-echo prompt. The value
# is never in argv and never echoed; the env var is scrubbed after snapshot.
# Invoked by name through run_step and enter_deepseek_key (dispatch by
# function name), which SC2317 cannot see.
# shellcheck disable=SC2317
enter_deepseek_key() {
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -n "$DS_KEY_FROM_ENV" ]; then
            printf '%s\n' \
                '  [dry-run] would store DEEPSEEK_API_KEY (secret) from OPENCLAW_DEEPSEEK_KEY' \
                '  via a masked stdin pipe (no argv, no echo).'
        else
            printf '%s\n' \
                '  [dry-run] would prompt (no-echo) to store DEEPSEEK_API_KEY (secret).'
        fi
        return 0
    fi
    if [ -n "$DS_KEY_FROM_ENV" ]; then
        printf '%s\n' \
            '  Storing DEEPSEEK_API_KEY from OPENCLAW_DEEPSEEK_KEY (stdin pipe;' \
            '  not echoed, not in argv).'
        printf '%s\n' "$DS_KEY_FROM_ENV" | openclaw secrets store set DEEPSEEK_API_KEY --kind secret
        return 0
    fi
    printf '%s\n' '  Enter the DeepSeek API key at the masked prompt below (no echo):'
    do_cmd openclaw secrets store set DEEPSEEK_API_KEY --kind secret
}

# Invoked by name through run_step (dispatch by function name), which SC2317
# cannot see.
# shellcheck disable=SC2317
step2_attempt() {
    if store_has DEEPSEEK_API_KEY; then
        printf '  ok: DEEPSEEK_API_KEY already in the secret store\n'
    else
        enter_deepseek_key
    fi
    ensure_ref_config models.providers.deepseek.apiKey DEEPSEEK_API_KEY
    do_cmd openclaw secrets reload
    ensure_config agents.defaults.model.primary deepseek/deepseek-v4-pro
    do_cmd openclaw gateway restart
    [ "$DRY_RUN" -eq 1 ] || sleep 3
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] would verify: openclaw models list --provider deepseek\n'
        printf '  [dry-run] would smoke-test: openclaw infer model run --prompt "reply with exactly: pong"\n'
        return 0
    fi
    if openclaw models list --provider deepseek 2>/dev/null | grep -q 'deepseek/'; then
        printf '  ok: deepseek provider catalog present\n'
    else
        printf '  FAIL: no deepseek models listed (try: openclaw plugins install @openclaw/deepseek-provider)\n' >&2
        return 1
    fi
    printf '  live inference smoke test (expect a pong reply):\n'
    openclaw infer model run --prompt 'reply with exactly: pong'
}

step2() {
    if step2_done; then
        printf '\n== %s ==\n' 'Step 2/5 — Configure the DeepSeek provider (SecretRef)'
        printf '  already done — skipping.\n'
        return 0
    fi
    if [ "$DRY_RUN" -ne 1 ] && [ ! -t 0 ] && [ -z "$DS_KEY_FROM_ENV" ] && ! store_has DEEPSEEK_API_KEY; then
        die 'Step 2 needs the DeepSeek API key, but stdin is not a terminal and OPENCLAW_DEEPSEEK_KEY is unset. Run in a terminal (masked prompt) or export OPENCLAW_DEEPSEEK_KEY and re-run.'
    fi
    run_step 'Step 2/5 — Configure the DeepSeek provider (SecretRef)' step2_attempt \
        'Step 2 OK: DEEPSEEK_API_KEY stored as a SecretRef; default model deepseek/deepseek-v4-pro; live inference replies.' \
        'Step 2 failed after 3 attempts. See docs/specs/first-boot.md Step 2 failure handling (e.g. re-store the key with: openclaw secrets store set DEEPSEEK_API_KEY --kind secret, then openclaw secrets reload && openclaw gateway restart), then re-run.'
}

# --- main ---------------------------------------------------------------------

parse_flags usage "$@"
snapshot_deepseek_key
# Under firstboot.sh the (already scrubbed) automation key arrives in
# DS_KEY_FROM_ENV via a one-shot env prefix on this process. Re-create it as
# an unexported variable so no child process of this step inherits the key.
if [ -n "${DS_KEY_FROM_ENV:-}" ]; then
    _ds_key=$DS_KEY_FROM_ENV
    unset DS_KEY_FROM_ENV
    DS_KEY_FROM_ENV=$_ds_key
    unset _ds_key
fi
step2
exit 0
