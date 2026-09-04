#!/bin/sh
# provision/steps/40-dashboard.sh — first-boot wizard Step 4: install the
# dashboard app-mode launcher (Chromium app-mode against the Control UI,
# http://127.0.0.1:18789; docs/specs/first-boot.md Step 4 and the WebKitGTK
# verdict; issue #14 refactor).
# Usage: 40-dashboard.sh [--dry-run]
#
# Idempotent step module: when chromium is present and the launcher desktop
# file exists, the step reports itself done and changes nothing. Normally
# invoked by provision/firstboot.sh (which runs each step in order and skips
# the ones already done); run this file directly to re-run or repair just
# this step.
set -e

_script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091 # lib.sh is linted directly by CI (provision/steps/*.sh)
. "$_script_dir/lib.sh"

# The launcher installer lives next to the provision/ directory this step
# module ships in (../install-dashboard-launcher.sh).
script_dir=$(CDPATH='' cd -- "$_script_dir/.." && pwd)
launcher="$script_dir/install-dashboard-launcher.sh"
desktop_file="$HOME/.local/share/applications/openclaw-dashboard.desktop"

# Invoked by name from the standalone main below and from firstboot.sh; the
# parse_flags dispatcher calls the usage function indirectly, which SC2317
# cannot see.
# shellcheck disable=SC2317
usage() {
    cat <<EOF
Usage: $0 [--dry-run]

Step 4 of the first-boot pairing wizard (provision/firstboot.sh): install the
"OpenClaw Dashboard" app-mode launcher (Chromium app-mode against the Control
UI at http://127.0.0.1:18789) via provision/install-dashboard-launcher.sh,
installing chromium first when it is missing. Idempotent: an installed
launcher with chromium present is reported done and left untouched.

Options:
  --dry-run   Print what this step would do; change nothing.
  -h, --help  Show this help and exit.
EOF
}

# Read-only: exit 0 when the step's outcome already exists (spec acceptance:
# launcher desktop file installed and its chromium runtime present).
step4_done() {
    command -v chromium >/dev/null 2>&1 || return 1
    [ -f "$desktop_file" ] || return 1
    return 0
}

# Invoked by name through run_step (dispatch by function name), which SC2317
# cannot see.
# shellcheck disable=SC2317
step4_attempt() {
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
    if step4_done; then
        printf '\n== %s ==\n' 'Step 4/5 — Install the dashboard app-mode launcher'
        printf '  already done — skipping.\n'
        return 0
    fi
    if [ "$DRY_RUN" -ne 1 ] && [ ! -f "$launcher" ]; then
        die "missing $launcher — run the wizard from the repo checkout (sh provision/firstboot.sh), or re-clone the repo."
    fi
    run_step 'Step 4/5 — Install the dashboard app-mode launcher' step4_attempt \
        'Step 4 OK: openclaw-dashboard launcher installed (Chromium app-mode).' \
        'Step 4 failed after 3 attempts. See docs/specs/first-boot.md Step 4 failure handling (re-run the installer; update-desktop-database ~/.local/share/applications), then re-run.'
}

# --- main ---------------------------------------------------------------------

parse_flags usage "$@"
step4
exit 0
