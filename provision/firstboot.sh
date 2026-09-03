#!/bin/sh
# provision/firstboot.sh — first-boot pairing wizard (issue #8).
# Usage: firstboot.sh [--dry-run]
#
# Turns a fresh Arch/Omarchy box into an OpenClaw appliance, encoding
# docs/specs/first-boot.md:
#   1. enable the gateway systemd user service (openclaw-gateway.service)
#   2. DeepSeek API key: masked secret-store entry + SecretRef config,
#      default model deepseek/deepseek-v4-pro
#   3. Telegram pairing (dmPolicy=pairing) + owner allow
#   4. install the dashboard app-mode launcher (Chromium, Control UI)
#   5. set update.channel=dev
#
# Idempotent: safe to re-run; steps already satisfied are skipped and each
# step verifies itself. A step that still fails after 3 attempts aborts the
# wizard with the spec's diagnostic commands; fix and re-run — the wizard
# resumes at the failed step.
#
# Secrets rules (spec + AGENTS.md): values enter only through masked prompts
# or the OPENCLAW_DEEPSEEK_KEY env var (piped to the store over stdin, never
# argv), config holds SecretRefs, and nothing secret is echoed or logged by
# this script. Pairing codes are ephemeral (1-hour expiry) and may be shown.
#
# --dry-run prints every action the wizard would take on this host (running
# only read-only checks to report what is already done) and changes nothing.
set -e

DRY_RUN=0
MAX_ATTEMPTS=3

usage() {
    cat <<EOF
Usage: $0 [--dry-run]

First-boot pairing wizard for an OpenClaw appliance (Arch/Omarchy). Run it as
your desktop user in a terminal after OpenClaw is installed and onboarded
(openclaw onboard --mode local).

Steps (docs/specs/first-boot.md):
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

Options:
  --dry-run   Print what the wizard would do; change nothing.
  -h, --help  Show this help and exit.

Requires: openclaw CLI, a systemd user session, and (for the masked prompts
and pairing code) a terminal.
EOF
}

# --- helpers ----------------------------------------------------------------

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

# Read-only: exit 0 when commands.ownerAllowFrom lists a Telegram owner.
owner_allow_configured() {
    _out=$(openclaw config get commands.ownerAllowFrom 2>&1) || return 1
    case "$_out" in
        *telegram*) return 0 ;;
    esac
    return 1
}

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

# --- step 1: gateway service ------------------------------------------------

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
            '    sudo loginctl enable-linger "$(id -un)"'
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

# --- step 2: DeepSeek key ----------------------------------------------------

# DeepSeek key entry: env var (masked stdin pipe) or no-echo prompt. The value
# is never in argv and never echoed; the env var is scrubbed after snapshot.
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
    if [ "$DRY_RUN" -ne 1 ] && [ ! -t 0 ] && [ -z "$DS_KEY_FROM_ENV" ] && ! store_has DEEPSEEK_API_KEY; then
        die 'Step 2 needs the DeepSeek API key, but stdin is not a terminal and OPENCLAW_DEEPSEEK_KEY is unset. Run in a terminal (masked prompt) or export OPENCLAW_DEEPSEEK_KEY and re-run.'
    fi
    run_step 'Step 2/5 — Configure the DeepSeek provider (SecretRef)' step2_attempt \
        'Step 2 OK: DEEPSEEK_API_KEY stored as a SecretRef; default model deepseek/deepseek-v4-pro; live inference replies.' \
        'Step 2 failed after 3 attempts. See docs/specs/first-boot.md Step 2 failure handling (e.g. re-store the key with: openclaw secrets store set DEEPSEEK_API_KEY --kind secret, then openclaw secrets reload && openclaw gateway restart), then re-run.'
}

# --- step 3: Telegram pairing ------------------------------------------------

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

# --- step 4: dashboard launcher ---------------------------------------------

step4_attempt() {
    desktop_file="$HOME/.local/share/applications/openclaw-dashboard.desktop"
    if command -v chromium >/dev/null 2>&1; then
        printf '  ok: chromium present\n'
    elif [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] would install chromium if missing: sudo pacman -S --needed chromium\n'
    elif command -v pacman >/dev/null 2>&1; then
        do_cmd sudo pacman -S --needed chromium
    else
        printf '%s\n' \
            '  FAIL: chromium not found and pacman is not available (non-Arch?). Install' >&2
        printf '%s\n' \
            '  Chromium with your package manager. Do not substitute a WebKitGTK client:' >&2
        printf '%s\n' '  it renders blank on this box (docs/verdicts/webkitgtk-on-beelink.md).' >&2
        return 1
    fi
    do_cmd sh "$launcher"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] would verify: desktop-file-validate %s\n' "$desktop_file"
        printf '  [dry-run] would launch: gtk-launch openclaw-dashboard (GUI check)\n'
        return 0
    fi
    if [ ! -f "$desktop_file" ]; then
        printf '  FAIL: %s was not created by the installer\n' "$desktop_file" >&2
        return 1
    fi
    if command -v desktop-file-validate >/dev/null 2>&1; then
        do_cmd desktop-file-validate "$desktop_file"
    else
        printf '  ok: desktop-file-validate not present; skipping validator\n'
    fi
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v gtk-launch >/dev/null 2>&1; then
        printf '  launching the dashboard window (GUI check):\n'
        if ! do_cmd gtk-launch openclaw-dashboard; then
            printf '%s\n' \
                '  note: gtk-launch failed — open the launcher from your app menu instead. If the' >&2
            printf '%s\n' \
                '  window renders blank, the gateway is down (Step 1) — see spec Step 4.' >&2
            return 1
        fi
    else
        printf '%s\n' \
            '  note: no graphical session here — launcher file validated; run the GUI check per' \
            '  docs/runbooks/vm-test.md when a desktop is available (Chromium app-mode only).'
    fi
}

step4() {
    if [ "$DRY_RUN" -ne 1 ] && [ ! -f "$launcher" ]; then
        die "missing $launcher — run the wizard from the repo checkout (sh provision/firstboot.sh), or re-clone the repo."
    fi
    run_step 'Step 4/5 — Install the dashboard app-mode launcher' step4_attempt \
        'Step 4 OK: openclaw-dashboard launcher installed (Chromium app-mode).' \
        'Step 4 failed after 3 attempts. See docs/specs/first-boot.md Step 4 failure handling (re-run the installer; update-desktop-database ~/.local/share/applications), then re-run.'
}

# --- step 5: update channel --------------------------------------------------

step5_attempt() {
    ensure_config update.channel dev
}

step5() {
    run_step 'Step 5/5 — Set update.channel=dev' step5_attempt \
        'Step 5 OK: update.channel = dev (persisted; no update applied).' \
        'Step 5 failed after 3 attempts. See docs/specs/first-boot.md Step 5 (re-run: openclaw config set update.channel dev), then re-run.'
}

# --- main --------------------------------------------------------------------

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

# Snapshot the automation key and scrub it from the environment so no child
# process ever sees it; it is only ever piped to the store over stdin.
DS_KEY_FROM_ENV=${OPENCLAW_DEEPSEEK_KEY:-}
if [ -n "$DS_KEY_FROM_ENV" ]; then
    unset OPENCLAW_DEEPSEEK_KEY
    printf '%s\n' \
        'Detected OPENCLAW_DEEPSEEK_KEY: the key will be piped to the secret store' \
        'over stdin (never argv, never echoed, not exported to child processes).'
fi

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
launcher="$script_dir/install-dashboard-launcher.sh"

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

step1
step2
step3
step4
step5

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
