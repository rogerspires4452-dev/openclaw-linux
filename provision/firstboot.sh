#!/bin/sh
# provision/firstboot.sh — first-boot pairing wizard (issue #8), refactored
# into idempotent, individually callable step modules under provision/steps/
# (issue #14). This file is the thin orchestrator: it parses the shared flags,
# preflights the host, scrubs any automation key, then runs each step module
# in order. Each module verifies its own outcome first — a step whose work is
# already done reports itself done and exits 0 without touching anything, so
# re-running the wizard only performs work that is still pending. A step that
# still fails after its own retries aborts the wizard with the spec's
# diagnostic commands; fix and re-run — the wizard resumes at that step.
#
# Steps (docs/specs/first-boot.md), one module each under provision/steps/:
#   1. 10-gateway.sh     enable the gateway systemd user service
#                        (openclaw-gateway.service)
#   2. 20-model-key.sh   DeepSeek API key: masked secret-store entry +
#                        SecretRef config, default model deepseek/deepseek-v4-pro
#   3. 30-telegram.sh    Telegram pairing (dmPolicy=pairing) + owner allow
#   4. 40-dashboard.sh   install the dashboard app-mode launcher
#                        (Chromium, Control UI)
#   5. 50-channel.sh     set update.channel=dev
#
# Secrets rules (spec + AGENTS.md): values enter only through masked prompts
# or the OPENCLAW_DEEPSEEK_KEY env var (piped to the store over stdin, never
# argv), config holds SecretRefs, and nothing secret is echoed or logged by
# this script. Pairing codes are ephemeral (1-hour expiry) and may be shown.
# The wizard scrubs OPENCLAW_DEEPSEEK_KEY from its environment immediately
# and hands the value to the model-key step alone via a one-shot env prefix;
# that step re-scrubs before spawning any child process.
#
# --dry-run prints every action the wizard would take on this host (running
# only read-only checks to report what is already done) and changes nothing.
set -e

DRY_RUN=0

usage() {
    cat <<EOF
Usage: $0 [--dry-run]

First-boot pairing wizard for an OpenClaw appliance (Arch/Omarchy). Run it as
your desktop user in a terminal after OpenClaw is installed and onboarded
(openclaw onboard --mode local).

Steps (docs/specs/first-boot.md), run in order as provision/steps/*.sh:
  1. Enable the gateway systemd user service (openclaw-gateway.service),
     plus user lingering so it survives logout.
  2. Configure the DeepSeek provider: masked secret-store entry for
     DEEPSEEK_API_KEY, SecretRef config, default model
     deepseek/deepseek-v4-pro, live inference check.
     Unattended runs: export OPENCLAW_DEEPSEEK_KEY first; the value is piped
     to the store over stdin and never appears in argv or logs.
  3. Pair Telegram (dmPolicy=pairing): store TELEGRAM_BOT_TOKEN via a masked
     prompt, then DM the bot and approve the code it replies with.
  4. Install the dashboard app-mode launcher (provision/install-dashboard-
     launcher.sh; Chromium app-mode against http://127.0.0.1:18789).
  5. Set update.channel=dev (persisted; applies on the next update).

Idempotent: each step verifies its own outcome and skips itself when it is
already done, so re-running the wizard only performs pending work.

Options:
  --dry-run   Print what the wizard would do; change nothing.
  -h, --help  Show this help and exit.

Requires: openclaw CLI, a systemd user session, and (for the masked prompts
and pairing code) a terminal.
EOF
}

for _arg in "$@"; do
    case "$_arg" in
        --dry-run) DRY_RUN=1 ;;
        -h | --help) usage; exit 0 ;;
        *)
            printf '%s\n' "$0: unknown argument: $_arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

script_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
steps_dir="$script_dir/steps"
if [ ! -f "$steps_dir/lib.sh" ]; then
    printf '%s\n' "$0: missing $steps_dir/lib.sh — run the wizard from the repo checkout (sh provision/firstboot.sh), or re-clone the repo." >&2
    exit 1
fi
# shellcheck source=steps/lib.sh
# shellcheck disable=SC1091 # lib.sh is linted directly by CI (provision/steps/*.sh)
. "$steps_dir/lib.sh"

# Snapshot the automation key and scrub it from the environment so no child
# process ever sees it; it is only ever piped to the store over stdin.
snapshot_deepseek_key

printf '%s\n' 'OpenClaw first-boot wizard (provision/firstboot.sh)'
if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' 'Dry-run mode: printing actions only; nothing will be changed.'
else
    command -v openclaw >/dev/null 2>&1 || die 'openclaw CLI not found in PATH (install and onboard first: openclaw onboard --mode local).'
    command -v systemctl >/dev/null 2>&1 || die 'systemctl not found; a systemd system is required.'
    if ! systemctl --user show-environment >/dev/null 2>&1; then
        die 'no systemd user session — run as your desktop user in a normal terminal.'
    fi
fi

# Ordered step modules. Each runs as its own sh process: per-step retries and
# fail-help live inside the module, and a module whose outcome already exists
# reports itself done and exits 0, which is how the wizard skips finished
# steps. A module that still fails exits non-zero and aborts the wizard here.
set -- 10-gateway.sh 20-model-key.sh 30-telegram.sh 40-dashboard.sh 50-channel.sh

for _step; do
    [ -f "$steps_dir/$_step" ] || die "missing $steps_dir/$_step — run the wizard from the repo checkout (sh provision/firstboot.sh), or re-clone the repo."
done

for _step; do
    # The model-key step alone may receive the scrubbed automation key, as a
    # one-shot env prefix scoped to that child process; it re-scrubs the copy
    # before spawning anything itself.
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$_step" = '20-model-key.sh' ] && [ -n "$DS_KEY_FROM_ENV" ]; then
            DS_KEY_FROM_ENV=$DS_KEY_FROM_ENV sh "$steps_dir/$_step" --dry-run
        else
            sh "$steps_dir/$_step" --dry-run
        fi
    elif [ "$_step" = '20-model-key.sh' ] && [ -n "$DS_KEY_FROM_ENV" ]; then
        DS_KEY_FROM_ENV=$DS_KEY_FROM_ENV sh "$steps_dir/$_step"
    else
        sh "$steps_dir/$_step"
    fi
done

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' \
        '' \
        'Dry-run finished — no changes were made. Re-run without --dry-run to apply.'
else
    printf '%s\n' \
        '' \
        'First-boot provisioning complete.' \
        '  - Gateway service: enabled, active, user lingering on.' \
        '  - DeepSeek: DEEPSEEK_API_KEY SecretRef configured; default model' \
        '    deepseek/deepseek-v4-pro; inference verified.' \
        '  - Telegram: enabled, dmPolicy=pairing, owner allowlisted.' \
        '  - Dashboard launcher installed (Chromium app-mode, Control UI).' \
        '  - update.channel=dev.' \
        '' \
        'Notes:' \
        '  - Dev-track updates: back up first (provision/backup.sh), then' \
        '    provision/update.sh --yes (docs/runbooks/update-and-backup.md).' \
        '  - GUI behavior on the real desktop: check the dashboard window;' \
        '    headless render checks use the qemu VM (docs/runbooks/vm-test.md).'
fi
exit 0
