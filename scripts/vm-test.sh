#!/bin/sh
# scripts/vm-test.sh -- VM integration test for the repo's provisioner scripts.
#
# Boots the qemu Ubuntu VM described in docs/runbooks/vm-test.md (VM dir
# ~/vm-test; SSH ubuntu@localhost:2222 with ~/.ssh/oc-vm-key) and exercises
# every provision/*.sh script SAFELY:
#
#   * syntax: sh -n on every provisioner, including provision/steps/*.sh;
#   * update.sh --help           -> exit 0, prints usage;
#   * update.sh (no args)        -> status-only path: exit 0, never updates;
#   * backup.sh <tmp target dir> -> exit 0, prints archive path + SHA256,
#                                   archive confined to the throwaway dir;
#   * firstboot.sh --dry-run     -> exit 0 once that script exists in the
#                                   repo (currently a documented SKIP).
#
# Safety model: a fake `openclaw` shim is placed first on the VM's PATH. It
# appends every invocation to a log and fakes the status/backup responses, so
# the real provisioner control flow runs end to end without a real OpenClaw
# install being present or reachable -- a real gateway update or a real backup
# is structurally impossible. After the runs the shim log is asserted: no
# `update --yes` was ever requested and `backup create` only targeted the temp
# dir.
#
# provision/install-dashboard-launcher.sh is copied and parse-checked but not
# executed: it has no --help/--dry-run path and performs a real (VM-local)
# install, which is out of scope for this dry-run harness.
#
# Exit status: 0 = every check passed; non-zero = a check failed or the test
# environment is broken. Run from anywhere; reads only the repo and the
# vm-test environment.
#
# Env overrides: VM_TEST_DIR, VM_TEST_SSH_KEY, VM_TEST_SSH_PORT,
# VM_TEST_SSH_USER, VM_TEST_SSH_HOST, VM_TEST_BOOT_WAIT.
set -e

usage() {
    cat <<'EOF'
Usage: vm-test.sh [-h|--help]

Boots the qemu Ubuntu VM (docs/runbooks/vm-test.md) and exercises the
provision/*.sh scripts in dry-run/safe mode (see header comment), asserting
exit 0 and sane output. Never triggers a real gateway update or writes real
backups: a fake `openclaw` shim answers the scripts inside the VM.

Env overrides: VM_TEST_DIR, VM_TEST_SSH_KEY, VM_TEST_SSH_PORT,
VM_TEST_SSH_USER, VM_TEST_SSH_HOST, VM_TEST_BOOT_WAIT.
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h | --help) usage; exit 0 ;;
        *) printf '%s: unknown argument: %s\n' "$0" "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

# --- configuration (paths from docs/runbooks/vm-test.md) ---
VM_TEST_DIR=${VM_TEST_DIR:-"$HOME/vm-test"}
VM_TEST_SSH_KEY=${VM_TEST_SSH_KEY:-"$HOME/.ssh/oc-vm-key"}
VM_TEST_SSH_PORT=${VM_TEST_SSH_PORT:-2222}
VM_TEST_SSH_USER=${VM_TEST_SSH_USER:-ubuntu}
VM_TEST_SSH_HOST=${VM_TEST_SSH_HOST:-localhost}
VM_TEST_BOOT_WAIT=${VM_TEST_BOOT_WAIT:-180}
overlay_img=overlay.qcow2
seed_img=seed.img
pidfile=vm.pid
ssh_user_host="$VM_TEST_SSH_USER@$VM_TEST_SSH_HOST"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
provision_dir="$repo_root/provision"

pass_count=0
fail_count=0
skip_count=0
started_vm=0
finished=0
vm_work=
tmpdir=

# --- helpers ---
pass() { pass_count=$((pass_count + 1)); printf '[PASS] %s\n' "$1"; }
fail() { fail_count=$((fail_count + 1)); printf '[FAIL] %s\n' "$1"; }
skip() { skip_count=$((skip_count + 1)); printf '[SKIP] %s\n' "$1"; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

show_out() {
    # Indent captured command output so PASS/FAIL lines stay greppable.
    printf '%s\n' "$1" | sed 's/^/       | /'
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# --- VM lifecycle ---
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/vm-test.XXXXXX") || die "cannot create temp dir"

cleanup() {
    trap - EXIT INT TERM
    if [ "$started_vm" = 1 ]; then
        shutdown_vm >/dev/null 2>&1 || true
    fi
    if [ -n "$tmpdir" ]; then rm -rf -- "$tmpdir"; fi
    if [ "$finished" != 1 ]; then
        printf '[FAIL] vm-test.sh aborted before completing all checks (see error above)\n' >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# shellcheck disable=SC2086 # intentional word-splitting of ssh options
vm_ssh() {
    ssh -i "$VM_TEST_SSH_KEY" -p "$VM_TEST_SSH_PORT" \
        -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$tmpdir/known_hosts" \
        -o LogLevel=ERROR "$ssh_user_host" "$@"
}

vm_still_running() {
    _vm_pid=$(cat "$VM_TEST_DIR/$pidfile" 2>/dev/null) || true
    [ -n "$_vm_pid" ] && kill -0 "$_vm_pid" 2>/dev/null
}

wait_for_ssh() {
    _waited=0
    while [ "$_waited" -lt "$VM_TEST_BOOT_WAIT" ]; do
        if vm_ssh true >/dev/null 2>&1; then
            printf '\n[INFO] SSH up (waited %ss)\n' "$_waited"
            return 0
        fi
        sleep 5
        _waited=$((_waited + 5))
        printf '.'
    done
    printf '\n'
    return 1
}

shutdown_vm() {
    printf '[INFO] shutting down the VM...\n'
    if vm_ssh true >/dev/null 2>&1; then
        vm_ssh "sudo -n poweroff" >/dev/null 2>&1 || true
        _n=0
        while vm_still_running && [ "$_n" -lt 12 ]; do sleep 5; _n=$((_n + 1)); done
    fi
    if vm_still_running; then
        printf '[WARN] graceful poweroff did not stop the VM; sending SIGTERM\n'
        _vm_pid=$(cat "$VM_TEST_DIR/$pidfile" 2>/dev/null) || true
        [ -n "$_vm_pid" ] && kill -TERM "$_vm_pid" 2>/dev/null || true
        _n=0
        while vm_still_running && [ "$_n" -lt 6 ]; do sleep 2; _n=$((_n + 1)); done
    fi
    if vm_still_running; then
        printf '[WARN] VM still running; sending SIGKILL\n'
        _vm_pid=$(cat "$VM_TEST_DIR/$pidfile" 2>/dev/null) || true
        [ -n "$_vm_pid" ] && kill -KILL "$_vm_pid" 2>/dev/null || true
        sleep 2
    fi
    if vm_still_running; then
        printf '[FAIL] could not stop the VM\n' >&2
        return 1
    fi
    printf '[INFO] VM stopped.\n'
    return 0
}

# --- check helpers ---
# run_case NAME COMMAND... : runs a remote command via ssh; PASS on exit 0.
# Captured output is left in $last_out and always shown.
run_case() {
    _case_name=$1
    shift
    if last_out=$(vm_ssh "$@" 2>&1); then
        pass "$_case_name"
    else
        _rc=$?
        fail "$_case_name (exit $_rc)"
    fi
    if [ -n "$last_out" ]; then show_out "$last_out"; fi
}

# assert_out_has NAME PATTERN : PASS if $last_out contains PATTERN (fixed).
assert_out_has() {
    if printf '%s\n' "$last_out" | grep -qF -- "$2"; then
        pass "$1"
    else
        fail "$1 (output missing: $2)"
        show_out "$last_out"
    fi
}

# assert_empty NAME VALUE : PASS if VALUE is empty, else FAIL and show it.
assert_empty() {
    if [ -z "$2" ]; then
        pass "$1"
    else
        fail "$1"
        show_out "$2"
    fi
}

# --- preflight on the host ---
need qemu-system-x86_64
need ssh
need tar
need mktemp
need sed
need grep
need basename

[ -d "$VM_TEST_DIR" ] || die "VM dir not found: $VM_TEST_DIR (see docs/runbooks/vm-test.md)"
[ -f "$VM_TEST_DIR/$overlay_img" ] || die "VM disk not found: $VM_TEST_DIR/$overlay_img (see docs/runbooks/vm-test.md)"
[ -f "$VM_TEST_DIR/$seed_img" ] || die "cloud-init seed not found: $VM_TEST_DIR/$seed_img (see docs/runbooks/vm-test.md)"
[ -f "$VM_TEST_SSH_KEY" ] || die "VM ssh key not found: $VM_TEST_SSH_KEY (see docs/runbooks/vm-test.md)"
[ -r "$VM_TEST_SSH_KEY" ] || die "VM ssh key not readable: $VM_TEST_SSH_KEY"
[ -d "$provision_dir" ] || die "no provision/ dir in repo: $provision_dir"

_script_count=0
for _f in "$provision_dir"/*.sh; do
    [ -e "$_f" ] && _script_count=$((_script_count + 1))
done
if [ "$_script_count" -eq 0 ]; then
    die "no provision/*.sh scripts found in $provision_dir"
fi

printf '[INFO] vm-test.sh: repo %s\n' "$repo_root"
printf '[INFO] provisioners under test:\n'
for _f in "$provision_dir"/*.sh; do
    printf '       %s\n' "$(basename -- "$_f")"
done
printf '[INFO] test VM: %s (ssh %s, key %s)\n' "$VM_TEST_DIR" "$ssh_user_host" "$VM_TEST_SSH_KEY"

# --- boot (or reuse) the VM ---
if vm_ssh true >/dev/null 2>&1; then
    printf '[INFO] VM already reachable on port %s; reusing it (not booted, not shut down here).\n' \
        "$VM_TEST_SSH_PORT"
elif [ -f "$VM_TEST_DIR/$pidfile" ] && vm_still_running; then
    printf '[INFO] VM process alive but SSH not up yet; waiting up to %ss...\n' "$VM_TEST_BOOT_WAIT"
    if ! wait_for_ssh; then
        die "VM process is running but SSH never came up within ${VM_TEST_BOOT_WAIT}s"
    fi
else
    printf '[INFO] booting the VM (runbook command, docs/runbooks/vm-test.md):\n'
    printf '       qemu-system-x86_64 -enable-kvm -m 4096 -smp 4'
    printf ' -drive file=%s,if=virtio -drive file=%s,if=virtio,format=raw' \
        "$overlay_img" "$seed_img"
    printf ' -netdev user,id=n1,hostfwd=tcp::%s-:22 -device virtio-net-pci,netdev=n1' \
        "$VM_TEST_SSH_PORT"
    printf ' -display none -daemonize -pidfile %s\n' "$pidfile"
    if ! (cd "$VM_TEST_DIR" && qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 \
        -drive "file=$overlay_img,if=virtio" \
        -drive "file=$seed_img,if=virtio,format=raw" \
        -netdev user,id=n1,"hostfwd=tcp::$VM_TEST_SSH_PORT-:22" \
        -device virtio-net-pci,netdev=n1 \
        -display none -daemonize -pidfile "$pidfile"); then
        die "qemu failed to start (see output above)"
    fi
    started_vm=1
    printf '[INFO] waiting for SSH on %s:%s' "$VM_TEST_SSH_HOST" "$VM_TEST_SSH_PORT"
    if ! wait_for_ssh; then
        die "VM did not become reachable within ${VM_TEST_BOOT_WAIT}s; boot it manually from $VM_TEST_DIR"
    fi
fi

# --- stage the test on the VM ---
vm_work="/tmp/openclaw-vm-test-$$"
if ! vm_ssh "rm -rf -- '$vm_work' && mkdir -p -- '$vm_work'"; then
    die "could not prepare remote work dir $vm_work"
fi

# Copy every provision/*.sh and provision/steps/*.sh into the VM.
if ! (cd "$provision_dir" && tar -cf - ./*.sh ./steps/*.sh) | vm_ssh "tar -xf - -C '$vm_work'"; then
    die "could not copy provision scripts into the VM"
fi

# Fake openclaw shim: written locally, pushed into $vm_work/bin. It logs every
# invocation to OPENCLAW_SHIM_LOG and answers the status/backup calls the
# provisioners make, so their real control flow runs without any real
# OpenClaw install being touched.
mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/openclaw" <<'SHIM'
#!/bin/sh
# vm-test shim for the `openclaw` CLI. Never touches a real OpenClaw install.
# Logs every invocation, fakes update-status and backup-create responses.
log=${OPENCLAW_SHIM_LOG:?openclaw shim: OPENCLAW_SHIM_LOG not set}
printf '%s\n' "$*" >> "$log"

case " $* " in
    *" update status "*)
        if printf '%s' "$*" | grep -qF -- "--json"; then
            printf '%s\n' '{"installKind":"git","behind":0}'
        else
            printf '%s\n' "openclaw update status: dev-track git checkout is up to date (shim)"
        fi
        exit 0
        ;;
    *" secrets store list "*)
        # Read-only probe (firstboot steps): empty store, so keys read as
        # missing and the steps stay pending in dry-run.
        exit 0
        ;;
    *" config get "*)
        # Read-only probe (firstboot steps): every path reads as unset, so
        # steps stay pending in dry-run.
        printf '%s\n' 'unset'
        exit 0
        ;;
    *" backup create "*)
        out_dir=
        prev=
        for a in "$@"; do
            if [ "$prev" = "--output" ]; then out_dir=$a; fi
            prev=$a
        done
        if [ -z "$out_dir" ]; then
            echo "shim: backup create without --output" >&2
            exit 1
        fi
        if [ ! -d "$out_dir" ]; then
            echo "shim: backup create --output dir missing: $out_dir" >&2
            exit 1
        fi
        name=$(date -u +%Y%m%dT%H%M%SZ)-openclaw-backup.tar.gz
        : > "$out_dir/$name" || exit 1
        echo "shim: fake backup archive written: $out_dir/$name"
        exit 0
        ;;
    *)
        echo "shim: unexpected openclaw invocation: $*" >&2
        exit 1
        ;;
esac
SHIM
chmod 755 "$tmpdir/bin/openclaw"

if ! (cd "$tmpdir" && tar -cf - bin) | vm_ssh "tar -xf - -C '$vm_work'"; then
    die "could not stage the openclaw shim in the VM"
fi
vm_ssh "chmod +x '$vm_work/bin/openclaw'" >/dev/null 2>&1 || true

# Env prefix for every provisioner run: shim first on PATH, shim log location.
vm_env="PATH='$vm_work/bin:/usr/bin:/bin' OPENCLAW_SHIM_LOG='$vm_work/shim.log'"

# --- checks ---
# 1. Every provisioner parses (POSIX sh -n), including the step modules.
for _f in "$provision_dir"/*.sh "$provision_dir"/steps/*.sh; do
    _rel=${_f#"$provision_dir/"}
    if last_out=$(vm_ssh "sh -n '$vm_work/$_rel'" 2>&1); then
        pass "syntax: $_rel parses (sh -n)"
    else
        fail "syntax: $_rel fails sh -n"
        show_out "$last_out"
    fi
done

# 2. update.sh --help: exits 0 and prints usage without touching openclaw.
run_case "update.sh --help exits 0" "$vm_env sh '$vm_work/update.sh' --help"
assert_out_has "update.sh --help prints usage" "Usage:"

# 3. update.sh status-only (no args): reports status, never applies an update.
run_case "update.sh status-only exits 0" "$vm_env sh '$vm_work/update.sh'"
assert_out_has "update.sh status-only reports up to date" "up to date"

# 4. backup.sh with a throwaway target dir: real logic, archive stays in temp.
backup_target="$vm_work/backup-target"
run_case "backup.sh <temp target dir> exits 0" \
    "$vm_env sh '$vm_work/backup.sh' '$backup_target'"
assert_out_has "backup.sh prints the archive path" "Backup archive:"
assert_out_has "backup.sh prints a SHA256 checksum" "SHA256:"
run_case "backup archive exists inside the temp target" \
    "ls '$backup_target'/"'*'"-openclaw-backup.tar.gz"

# 5. firstboot.sh --dry-run: the wizard runs every step module in
#    provision/steps/ in dry-run mode against the read-only shim answers.
if [ -f "$provision_dir/firstboot.sh" ]; then
    run_case "firstboot.sh --dry-run exits 0" \
        "$vm_env sh '$vm_work/firstboot.sh' --dry-run"
    assert_out_has "firstboot.sh --dry-run finishes all steps" "Dry-run finished"
else
    skip "firstboot.sh --dry-run (provision/firstboot.sh not present in repo yet)"
fi

# --- safety assertions on the shim call log ---
shim_log=$(vm_ssh "cat '$vm_work/shim.log' 2>/dev/null" || true)
if [ -n "$shim_log" ]; then
    printf '[INFO] openclaw shim call log (evidence):\n'
    show_out "$shim_log"
fi

_unexpected=$(printf '%s\n' "$shim_log" | grep -vE '^(update status|backup create|secrets store list|config get)' || true)
if [ -n "$_unexpected" ]; then
    fail "shim log shows unexpected openclaw invocations"
    show_out "$_unexpected"
else
    pass "shim log only shows the expected status/backup calls"
fi

_update_yes=$(printf '%s\n' "$shim_log" | grep -F 'update --yes' || true)
assert_empty "no real gateway update was ever requested (no 'update --yes')" "$_update_yes"

_off_target=$(printf '%s\n' "$shim_log" | grep '^backup create' | grep -vF "$backup_target" || true)
assert_empty "no backup was targeted outside the temp dir" "$_off_target"

_status_calls=$(printf '%s\n' "$shim_log" | grep -c '^update status' || true)
_backup_calls=$(printf '%s\n' "$shim_log" | grep -c '^backup create' || true)
_status_calls=${_status_calls:-0}
_backup_calls=${_backup_calls:-0}
if [ "$_status_calls" -ge 1 ] && [ "$_backup_calls" -ge 1 ]; then
    pass "provisioners reached openclaw via the shim (status x$_status_calls, backup x$_backup_calls)"
else
    fail "expected >=1 status and >=1 backup call (got status x$_status_calls, backup x$_backup_calls)"
fi

printf '[INFO] install-dashboard-launcher.sh: copied and parse-checked above;\n'
printf '[INFO] not executed (no --help/--dry-run path; it performs a real install).\n'

# --- teardown ---
vm_ssh "rm -rf -- '$vm_work'" >/dev/null 2>&1 || true
if [ "$started_vm" = 1 ]; then
    if shutdown_vm; then
        started_vm=0
    else
        fail "VM did not shut down cleanly"
    fi
fi

# --- summary ---
printf '\n== summary ==\n'
printf '[PASS] %d  [FAIL] %d  [SKIP] %d\n' "$pass_count" "$fail_count" "$skip_count"
if [ "$fail_count" -eq 0 ]; then
    printf '[PASS] vm-test.sh: all checks passed\n'
    finished=1
    exit 0
fi
printf '[FAIL] vm-test.sh: %d check(s) failed\n' "$fail_count"
finished=1
exit 1
