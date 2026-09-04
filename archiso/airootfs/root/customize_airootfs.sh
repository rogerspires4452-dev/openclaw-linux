#!/bin/sh
# customize_airootfs.sh — build-time bake of the OpenClaw gateway (issue #21).
#
# archiso-standard build hook: mkarchiso copies this file (it lives in the
# profile's airootfs/ overlay, i.e. it is staged at /root/customize_airootfs.sh
# inside the build chroot) and executes it right after packages.x86_64 is
# installed, then deletes it again — so it never lands in the finished image
# (archiso mkarchiso, _make_customize_airootfs, verified against the v90
# source). Network is available here — the build host's — which is exactly
# why the *software* payload moves to build time: a baked appliance never
# needs internet for OpenClaw itself, only the first-boot wizard's config
# steps (API key, Telegram pairing) do, and those stay in /root/provision.
#
# Upstream note: mkarchiso prints "customize_airootfs.sh is deprecated!
# Support for it will be removed in a future archiso version." when running
# this hook. It is still the supported mechanism in archiso 90 and remains
# the only build-time hook that can install software into the image with
# network; if a future archiso removes it, the bake must move to the
# installer/first-boot path (which loses offline capability). See
# archiso/README.md.
#
# What this hook bakes (all offline afterwards):
#   * /opt/openclaw — the openclaw repo pinned to a stable tag, deps
#     installed with the workspace-pinned pnpm, dist/ built.
#   * /usr/local/bin/openclaw -> /opt/openclaw/openclaw.mjs (CLI on PATH).
#   * /etc/skel/.config/systemd/user/openclaw-gateway.service (+ the
#     default.target.wants symlink that pre-enables it) and
#     /etc/skel/.config/autostart/openclaw-dashboard.desktop — every desktop
#     user created after install (useradd -m copies /etc/skel) gets a
#     pre-enabled gateway user service and the Chromium dashboard autostart.
#     mkarchiso additionally copies /etc/skel into the homes of users listed
#     in airootfs/etc/passwd at build time, so this also composes with the
#     issue #20 desktop-user work automatically.
#
# POSIX sh, set -e, no bashisms (AGENTS.md conventions).
set -e

OPENCLAW_TAG="v2026.8.2"
OPENCLAW_REPO="https://github.com/openclaw/openclaw.git"
OPENCLAW_DIR="/opt/openclaw"

log() { printf '[customize_airootfs] %s\n' "$*"; }

# --- chroot DNS --------------------------------------------------------------
# mkarchiso runs this script in the airootfs chroot sharing the build host's
# network namespace, but it does not set up /etc/resolv.conf inside the
# chroot: the image's own resolv.conf is the stock Arch stub symlink, which
# points at nothing during the build. Probe for working resolution first and
# only override when it is missing; restore the stock state on exit so the
# finished image is not polluted with build-host resolver settings
# (NetworkManager rewrites resolv.conf at runtime anyway).
_resolv_overridden=0
_resolv_was_symlink=0
if ! getent hosts github.com >/dev/null 2>&1; then
    log "no working resolver inside the build chroot; using public DNS for the build phase"
    [ -L /etc/resolv.conf ] && _resolv_was_symlink=1
    rm -f /etc/resolv.conf
    printf '%s\n' 'nameserver 1.1.1.1' 'nameserver 8.8.8.8' > /etc/resolv.conf
    _resolv_overridden=1
fi

_restore_resolv() {
    [ "$_resolv_overridden" -eq 1 ] || return 0
    rm -f /etc/resolv.conf
    if [ "$_resolv_was_symlink" -eq 1 ]; then
        ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
}
trap _restore_resolv EXIT

# --- clone pinned stable release ---------------------------------------------
log "baking OpenClaw ${OPENCLAW_TAG} into ${OPENCLAW_DIR}"
git clone --quiet --depth 1 --branch "$OPENCLAW_TAG" "$OPENCLAW_REPO" "$OPENCLAW_DIR"
_commit=$(git -C "$OPENCLAW_DIR" rev-parse HEAD)
log "checked out ${OPENCLAW_TAG} at ${_commit}"

# --- pnpm: honor the workspace's pinned version ------------------------------
# The repo pins pnpm via the packageManager field (and uses pnpm-12-era
# pnpm-workspace.yaml settings such as allowBuilds, which older pnpm
# ignores — silently leaving dependency postinstalls unrun). Install the
# pinned release as @pnpm/exe (pnpm's official prebuilt static binary):
# pnpm >= 10 builds its launcher in a postinstall, and both corepack and
# npm's script blocking (npm >= 11 blocks pnpm's postinstall) leave a
# corrupted shim behind in the archiso chroot (observed 2026-09-04 twice:
# "/usr/bin/pnpm: line 4: syntax error" with the blocked-scripts message
# text embedded in the bin). @pnpm/exe needs no postinstall.
_pinned_pnpm=$(grep -E '"packageManager": "pnpm@' "$OPENCLAW_DIR/package.json" \
    | head -n 1 \
    | sed 's/.*pnpm@\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/')
[ -n "$_pinned_pnpm" ] || _pinned_pnpm='12.1.0'
log "installing pinned pnpm@${_pinned_pnpm} via @pnpm/exe (install.js fetches the native binary)"
# npm >= 12 gates install scripts behind per-package approval; without it the
# @pnpm/exe preinstall never runs and the shipped placeholder stays behind
# (a broken text file masquerading as the pnpm bin). Approve, then install.
npm install-scripts approve @pnpm/exe >/dev/null 2>&1 || true
npm install -g "@pnpm/exe@${_pinned_pnpm}" --force
pnpm --version

# --- install deps + build -----------------------------------------------------
cd "$OPENCLAW_DIR"
log "installing workspace dependencies (frozen lockfile)"
# Store/caches live under /var/tmp and /root and are removed afterwards so the
# image does not carry pnpm's download cache in /root.
pnpm install --frozen-lockfile --store-dir /var/tmp/pnpm-store
log "building dist/ (pnpm build)"
pnpm build
# The pre-staged user unit (and the reference host's `openclaw gateway
# install`) execs node on dist/index.js; fail loudly if the build output is
# not what the unit expects.
if [ ! -f dist/index.js ]; then
    printf '%s\n' "[customize_airootfs] ERROR: pnpm build produced no dist/index.js; the staged" \
        'openclaw-gateway.service unit cannot run. Check the build output above.' >&2
    exit 1
fi

# --- CLI on PATH --------------------------------------------------------------
ln -s "$OPENCLAW_DIR/openclaw.mjs" /usr/local/bin/openclaw

# --- offline smoke check ------------------------------------------------------
# Verify the baked CLI reports the pinned version without network (isolate
# HOME so no config dir is created in the image's /root).
_expect=$(grep -E '"version": "' "$OPENCLAW_DIR/package.json" | head -n 1 \
    | sed 's/.*"version": *"\([^"]*\)".*/\1/')
_check_home=/var/tmp/openclaw-version-check
mkdir -p "$_check_home"
if HOME="$_check_home" /usr/local/bin/openclaw --version 2>/dev/null \
    | grep -q "OpenClaw ${_expect}"; then
    log "smoke check ok: openclaw --version reports ${_expect}"
else
    printf '%s\n' "[customize_airootfs] ERROR: baked openclaw --version did not report" \
        "OpenClaw ${_expect}; see the version output above." >&2
    exit 1
fi

# --- build-time hygiene --------------------------------------------------------
rm -rf "$_check_home" /var/tmp/pnpm-store /tmp/node-compile-cache \
    /root/.npm /root/.cache/pnpm /root/.cache/node-gyp
log "OpenClaw ${_expect} (${OPENCLAW_TAG}, ${_commit}) baked into ${OPENCLAW_DIR}; image build continues"
