#!/bin/sh
# provision/update.sh — dev-track update: status check, detached apply, restart wait.
# Usage: update.sh [--yes]
#
# - Prints `openclaw update status` and reports how far behind the dev-track
#   git checkout is.
# - If behind > 0 and --yes is given: runs the update detached via systemd-run
#   (so a gateway restart cannot kill it), waits for the gateway to come back
#   active, then reports the new version.
#
# Encodes docs/runbooks/update-and-backup.md. No secrets are read or embedded.
# Logs land in ~/.openclaw/update-logs/. Override the wait with
# UPDATE_WAIT_SECONDS (default 900).
set -e

usage() {
    echo "Usage: $0 [--yes]"
    echo "  Reports how far behind the OpenClaw dev install is."
    echo "  --yes  apply the update when behind (detached, then wait for the gateway)."
}

yes_flag=0
for arg in "$@"; do
    case "$arg" in
        --yes) yes_flag=1 ;;
        -h | --help) usage; exit 0 ;;
        *)
            echo "$0: unknown argument: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! command -v openclaw >/dev/null 2>&1; then
    echo "update.sh: openclaw CLI not found in PATH" >&2
    exit 1
fi

echo "== Checking OpenClaw update status =="
if ! openclaw update status --timeout 120; then
    echo "update.sh: could not determine update status (see output above)" >&2
    exit 1
fi

# Machine-readable pass for the numbers behind the table above.
json=$(openclaw update status --json --timeout 120 2>/dev/null) || {
    echo "update.sh: could not determine update status (JSON pass failed)" >&2
    exit 1
}

install_kind=$(printf '%s' "$json" | sed -n 's/.*"installKind": *"\([^"]*\)".*/\1/p' | tail -n 1)
behind=$(printf '%s' "$json" | sed -n 's/.*"behind": *\([0-9][0-9]*\).*/\1/p' | tail -n 1)

if [ "$install_kind" != "git" ]; then
    echo "update.sh: install is not a dev-track git checkout (kind: ${install_kind:-unknown}); nothing to update here."
    exit 0
fi
if [ -z "$behind" ]; then
    echo "update.sh: could not determine how far behind the checkout is" >&2
    echo "          (check connectivity, then re-run: openclaw update status)" >&2
    exit 1
fi

if [ "$behind" -eq 0 ]; then
    echo "OpenClaw dev checkout is up to date."
    exit 0
fi

echo "OpenClaw dev checkout is $behind commit(s) behind."
if [ "$yes_flag" -ne 1 ]; then
    echo "Not updating (no --yes). Re-run with --yes to apply the update."
    exit 0
fi

echo "Tip: run provision/backup.sh first to snapshot state before updating."

if ! command -v systemd-run >/dev/null 2>&1; then
    echo "update.sh: systemd-run not found; cannot run the update detached" >&2
    exit 1
fi

log_dir="$HOME/.openclaw/update-logs"
mkdir -p "$log_dir"
log_file="$log_dir/update-$(date +%Y%m%d-%H%M%S).log"
unit="oc-update"
oc_bin=$(command -v openclaw)
gateway_unit="openclaw-gateway.service"
wait_seconds=${UPDATE_WAIT_SECONDS:-900}

# Body of the detached unit. Env (OC_BIN, LOG_FILE, GW_UNIT, WAIT_SECONDS,
# HOME, PATH, XDG_RUNTIME_DIR) is passed via --setenv by the caller.
inner=$(cat <<'EOF'
set -u
exec >"$LOG_FILE" 2>&1
echo "[oc-update] $(date -Is) update started (pid $$)"
echo "[oc-update] binary: $OC_BIN"
"$OC_BIN" update --yes
rc=$?
echo "[oc-update] update command exit code: $rc"
if [ "$rc" -ne 0 ]; then
    echo "[oc-update] update FAILED"
    exit "$rc"
fi
echo "[oc-update] update applied; waiting for $GW_UNIT to come back active"
deadline=$(( $(date +%s) + WAIT_SECONDS ))
active=0
while : ; do
    if systemctl --user is-active --quiet "$GW_UNIT" 2>/dev/null; then
        active=1
        break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
done
if [ "$active" -ne 1 ]; then
    echo "[oc-update] gateway did not come back active within ${WAIT_SECONDS}s"
    exit 1
fi
version=$("$OC_BIN" --version 2>/dev/null || echo "unknown")
echo "[oc-update] gateway active; version: $version"
exit 0
EOF
)

extra_env=""
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    extra_env="--setenv=SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
fi

# extra_env is intentionally word-split below to pass zero or one --setenv.
# shellcheck disable=SC2086
if ! systemd-run --user --collect --unit="$unit" \
    --description="OpenClaw dev-track update (launched by provision/update.sh)" \
    --setenv="OC_BIN=$oc_bin" \
    --setenv="LOG_FILE=$log_file" \
    --setenv="GW_UNIT=$gateway_unit" \
    --setenv="WAIT_SECONDS=$wait_seconds" \
    --setenv="HOME=$HOME" \
    --setenv="PATH=$PATH" \
    --setenv="XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    $extra_env \
    bash -c "$inner"; then
    echo "update.sh: failed to start detached update unit '$unit' (is an update already running?)" >&2
    exit 1
fi

echo "Update launched detached (systemd unit: $unit)."
echo "Log: $log_file"
echo "Waiting for the gateway to come back active..."

# Wait for the detached unit's result markers; fail fast on error markers.
deadline=$(( $(date +%s) + wait_seconds + 180 ))
result=timeout
while : ; do
    if grep -q "\[oc-update\] gateway active" "$log_file" 2>/dev/null; then
        result=ok
        break
    fi
    if grep -Eq "\[oc-update\] (update FAILED|gateway did not come back active)" "$log_file" 2>/dev/null; then
        result=failed
        break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
done

echo "--- update log (tail) ---"
tail -n 25 "$log_file" 2>/dev/null || true

case "$result" in
    ok)
        echo "Update complete."
        exit 0
        ;;
    failed)
        echo "update.sh: update failed (see log above)" >&2
        exit 1
        ;;
    *)
        echo "update.sh: timed out waiting for the gateway; update may still be running (see log above)" >&2
        exit 1
        ;;
esac
