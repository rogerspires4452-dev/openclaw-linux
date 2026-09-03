#!/bin/sh
# provision/steps/30-telegram.sh — first-boot wizard Step 3: pair Telegram
# (dmPolicy=pairing) and allowlist a command owner. Token via masked prompt
# (never argv/echo), channels.telegram.* config, DM pairing approval
# (docs/specs/first-boot.md Step 3; issue #14 refactor).
# Usage: 30-telegram.sh [--dry-run]
#
# Idempotent step module: when the token is stored, the botToken SecretRef is
# authored, the channel is enabled with dmPolicy=pairing, and an owner is
# allowlisted, the step reports itself done and changes nothing. Normally
# invoked by provision/firstboot.sh (which runs each step in order and skips
# the ones already done); run this file directly to re-run or repair just
# this step.
#
# Secrets rules: the bot token is only ever entered through the masked prompt
# (never argv, never echoed); config holds a SecretRef. Pairing codes are
# ephemeral (1-hour expiry) and may be shown.
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

Step 3 of the first-boot pairing wizard (provision/firstboot.sh): store the
Telegram bot token as a secret-store entry (masked prompt), wire
channels.telegram.botToken to it as a SecretRef, enable the channel with
dmPolicy=pairing, and approve the DM pairing code so the owner is
allowlisted. Idempotent: a fully paired channel is reported done and left
untouched.

Options:
  --dry-run   Print what this step would do; change nothing.
  -h, --help  Show this help and exit.
EOF
}

# Read-only: exit 0 when the step's outcome already exists (spec acceptance:
# token stored as a SecretRef, channel enabled with dmPolicy=pairing, owner
# allowlisted).
step3_done() {
    store_has TELEGRAM_BOT_TOKEN || return 1
    config_is_unset channels.telegram.botToken && return 1
    config_equals channels.telegram.enabled true || return 1
    config_equals channels.telegram.dmPolicy pairing || return 1
    owner_allow_configured
}

# Invoked by name from step3_attempt (dispatch by function name), which
# SC2317 cannot see.
# shellcheck disable=SC2317
enter_telegram_token() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' \
            '  [dry-run] would show @BotFather instructions and prompt (no-echo) to store' \
            '  TELEGRAM_BOT_TOKEN (secret), then wire channels.telegram.botToken to it.'
        return 0
    fi
    printf '%s\n' \
        '  Create the bot token first: in Telegram, chat with @BotFather, run /newbot,' \
        '  and copy the token. Enter it at the masked prompt below (no echo):'
    do_cmd openclaw secrets store set TELEGRAM_BOT_TOKEN --kind secret
}

# Invoked by name from step3_attempt (dispatch by function name), which
# SC2317 cannot see.
# shellcheck disable=SC2317
pair_telegram_dm() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' \
            '  [dry-run] would print pairing instructions (DM the bot from Telegram, note' \
            '  the 8-character code), show the pending request with:' \
            '  openclaw pairing list telegram' \
            '  and approve the pasted code with: openclaw pairing approve telegram <CODE>.'
        return 0
    fi
    printf '%s\n' \
        '  Pair your Telegram account:' \
        '    1. In Telegram, DM your bot (the one @BotFather created).' \
        '    2. The bot answers with an 8-character code (expires after 1 hour).' \
        '    3. Pending requests are shown below.'
    do_cmd openclaw pairing list telegram
    printf '  Paste the code the bot sent (or press Enter to finish manually): '
    if ! read -r code; then
        printf '\n'
        printf '%s\n' \
            '  No input available. Approve manually, then re-run the wizard:' \
            '    openclaw pairing list telegram' \
            '    openclaw pairing approve telegram <CODE>'
        return 1
    fi
    if [ -z "$code" ]; then
        printf '%s\n' \
            '  No code entered. Approve manually, then re-run the wizard:' \
            '    openclaw pairing list telegram' \
            '    openclaw pairing approve telegram <CODE>'
        return 1
    fi
    do_cmd openclaw pairing approve telegram "$code"
    if owner_allow_configured; then
        printf '  ok: pairing approved; commands.ownerAllowFrom lists a Telegram owner.\n'
        return 0
    fi
    printf '%s\n' \
        '  commands.ownerAllowFrom is still empty (an owner may already exist from another' \
        '  channel). Set it from the numeric id in the pairing request metadata or gateway' \
        '  logs, then re-run:' >&2
    printf '%s\n' "    openclaw config set commands.ownerAllowFrom '[\"telegram:<numeric id>\"]' --strict-json" >&2
    printf '%s\n' '    openclaw gateway restart' >&2
    return 1
}

# Invoked by name through run_step (dispatch by function name), which SC2317
# cannot see.
# shellcheck disable=SC2317
step3_attempt() {
    if store_has TELEGRAM_BOT_TOKEN; then
        printf '  ok: TELEGRAM_BOT_TOKEN already in the secret store\n'
    else
        enter_telegram_token
    fi
    ensure_ref_config channels.telegram.botToken TELEGRAM_BOT_TOKEN
    ensure_config channels.telegram.enabled true
    ensure_config channels.telegram.dmPolicy pairing
    do_cmd openclaw secrets reload
    do_cmd openclaw gateway restart
    [ "$DRY_RUN" -eq 1 ] || sleep 3
    if owner_allow_configured; then
        printf '  ok: commands.ownerAllowFrom already lists a Telegram owner\n'
    else
        pair_telegram_dm
    fi
}

step3() {
    if step3_done; then
        printf '\n== %s ==\n' 'Step 3/5 — Pair Telegram (dmPolicy=pairing, owner allow)'
        printf '  already done — skipping.\n'
        return 0
    fi
    if [ "$DRY_RUN" -ne 1 ]; then
        if [ ! -t 0 ] && ! store_has TELEGRAM_BOT_TOKEN; then
            die 'Step 3 needs a terminal: the Telegram bot token is entered via a masked prompt. Run in a terminal, or store it first (openclaw secrets store set TELEGRAM_BOT_TOKEN --kind secret) and re-run.'
        fi
        if [ ! -t 0 ] && ! owner_allow_configured; then
            die 'Step 3 needs a terminal to approve the Telegram pairing (DM your bot first). Run in a terminal, or approve manually (openclaw pairing list telegram, then openclaw pairing approve telegram <CODE>) and re-run.'
        fi
    fi
    run_step 'Step 3/5 — Pair Telegram (dmPolicy=pairing, owner allow)' step3_attempt \
        'Step 3 OK: Telegram enabled with dmPolicy=pairing; owner allowlisted.' \
        'Step 3 failed after 3 attempts. See docs/specs/first-boot.md Step 3 failure handling (token via @BotFather; re-DM the bot for a fresh code if one expired), then re-run.'
}

# --- main ---------------------------------------------------------------------

parse_flags usage "$@"
step3
exit 0
