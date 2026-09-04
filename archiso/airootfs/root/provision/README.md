# /root/provision — OpenClaw appliance first-boot payload

This directory is a **staged copy** of the repo's `provision/` scripts,
baked into the install media at ISO build time (the archiso profile overlays
`archiso/airootfs/` onto the image root). The repo's `provision/` directory
is the source of truth — re-sync before every ISO build:

```sh
# from the repo root:
cp -a provision/firstboot.sh provision/backup.sh provision/update.sh \
      provision/install-dashboard-launcher.sh archiso/airootfs/root/provision/
cp -a provision/steps/ archiso/airootfs/root/provision/
```

Contents (same set the repo root ships):

- `firstboot.sh` — the first-boot pairing wizard (interactive; runs the
  step modules below). `--dry-run` prints a full guidance pass and changes
  nothing.
- `backup.sh`, `update.sh` — pre-update backup and dev-track update helpers
  (see `docs/runbooks/update-and-backup.md` in the repo).
- `install-dashboard-launcher.sh` — Chromium app-mode launcher for the
  Control UI. WebKitGTK is banned on the reference hardware
  (`docs/verdicts/webkitgtk-on-beelink.md`); Chromium is the UI.
- `steps/` — the wizard's idempotent step modules
  (`docs/specs/first-boot.md` in the repo): gateway service, DeepSeek key,
  Telegram pairing, dashboard launcher, update channel.

## First-boot enablement (archiso practice)

The image also ships `etc/systemd/system/openclaw-firstboot.service` — a
oneshot that runs this wizard and then disarms itself. Like all units under
that path in an archiso profile it is **disabled in the image**: enablement
belongs to the *installed* system. The future scripted installer (tracked
in the repo's `archiso/README.md`) enables it in the target chroot; for a
manual install the same step is:

```sh
# inside the installed system's chroot (e.g. after arch-chroot):
systemctl enable openclaw-firstboot.service
```

Caveats, so nobody mistakes this for a headless provisioner:

- The wizard is **interactive** (masked secret prompts, an ephemeral
  Telegram pairing code) and its steps drive the *desktop user's* systemd
  session. The intended appliance UX is: first boot lands on the desktop,
  the human opens a terminal and runs `sh /root/provision/firstboot.sh`
  (or the installer hands it off to the desktop session). Run
  `sh /root/provision/firstboot.sh --dry-run` first for a no-change
  guidance pass.
- The wizard requires the **openclaw CLI, installed and onboarded**
  (`openclaw onboard --mode local`). Since issue #21 the CLI ships **baked
  into the image**: `customize_airootfs.sh` (the archiso build-time hook)
  clones the pinned stable release to `/opt/openclaw`, builds it, and puts
  `openclaw` on PATH, so the wizard runs fully offline for the software and
  only needs network for the config steps (API key catalog, Telegram). The
  gateway user unit is also pre-staged via `/etc/skel`; step 1's
  `openclaw gateway install` regenerates it tuned to the machine.
- The `openclaw-firstboot.service` unit exists as the archiso-standard hook
  point and self-disarming guard: enabled at install time it runs the
  wizard at first boot and, if the interactive prerequisites are not met,
  fails fast with the wizard's own diagnostics and retries next boot.
