# archiso — OpenClaw Linux appliance install-media profile

Releng-style [archiso](https://gitlab.archlinux.org/archlinux/archiso)
profile for building bootable media for the OpenClaw appliance: a minimal
Arch base with the Hyprland-family desktop, Chromium app-mode UI, the OpenClaw
gateway **baked in at build time** (offline-capable), and the staged first-boot
provisioning payload for the config pass (API key, Telegram pairing). The
reference hardware is the Omarchy/beelink box (Alder Lake-N, Intel), and the
profile targets the same software stack — minus anything that depends on
WebKitGTK, which renders blank there
([`docs/verdicts/webkitgtk-on-beelink.md`](../docs/verdicts/webkitgtk-on-beelink.md)).

**Status: buildable skeleton.** Every file is syntactically validated and
every package name is verified against the official Arch repos, but no ISO
has been built from this profile yet — the maintainer builds and iterates
(`mkarchiso` needs root and a long runtime). The profile mirrors the
`releng` layout shipped with archiso 90 (bootmode names `bios.syslinux` /
`uefi.systemd-boot`, plain `initramfs-linux.img` with the archiso hooks).
The build-time bake (below) is validated for syntax, tag existence, and
layout only — the first real `mkarchiso` run is a live test on the
maintainer's box.

## Layout

```text
archiso/
├── README.md                   ← this file
├── profiledef.sh               ← profile metadata mkarchiso sources (name, arch, bootmodes…)
├── pacman.conf                 ← pacman config for the build chroot (multilib on; omarchy commented)
├── packages.x86_64             ← package seed list, grouped by purpose (all verified)
├── airootfs/                   ← copied verbatim into the image root
│   ├── etc/
│   │   ├── mkinitcpio.conf.d/archiso.conf   ← archiso initramfs hooks (boot chain)
│   │   ├── mkinitcpio.d/linux.preset        ← build only the archiso initramfs
│   │   ├── skel/                             ← desktop-user skeleton (copied to every new home)
│   │   │   └── .config/
│   │   │       ├── autostart/openclaw-dashboard.desktop  ← dashboard on login (Chromium app-mode)
│   │   │       └── systemd/user/
│   │   │           ├── openclaw-gateway.service          ← gateway user unit
│   │   │           └── default.target.wants/             ← pre-enables the unit (symlink)
│   │   └── systemd/system/
│   │       └── openclaw-firstboot.service   ← first-boot wizard hook (enabled at install time)
│   ├── root/
│   │   ├── customize_airootfs.sh            ← BUILD-TIME bake hook (issue #21; see below)
│   │   └── provision/         ← staged copy of the repo's provision/ payload (+ README)
├── efiboot/loader/             ← systemd-boot config (UEFI bootmode)
├── grub/loopback.cfg           ← lets an existing GRUB boot the ISO directly
└── syslinux/                   ← syslinux config (BIOS bootmode)
```

## Build (run on an Arch machine)

The build host needs the `archiso` package (its dependencies cover the
bootloader/host tooling, e.g. syslinux, mtools, dosfstools).

```sh
pacman -S archiso
# from this directory:
sudo mkarchiso -v -w /tmp/archiso-tmp -o out .
```

Output: `out/openclaw-linux-<version>-x86_64.iso` (hybrid ISO; BIOS via
syslinux, UEFI via systemd-boot).

### Build-time network requirement

The bake hook runs inside the build chroot with the **build host's network**
(mkarchiso shares the host's network namespace and runs the hook right after
the package seed is installed). A build therefore needs:

- the usual Arch mirror access (pacstrap), plus
- `github.com` reachability (clone of the pinned openclaw tag), and
- the npm registry (pnpm install of the workspace dependencies).

If the chroot lacks working DNS (stock archiso chroots usually do — the
image's own `/etc/resolv.conf` stub points at nothing during the build), the
hook installs a throwaway public-resolver `/etc/resolv.conf`
(1.1.1.1/8.8.8.8) for the network phase and restores the stock state before
the image is finalized. Build hosts whose network blocks public DNS egress
can edit the fallback in `airootfs/root/customize_airootfs.sh`.

### Image-size expectation

The bake adds the openclaw source checkout (pinned tag, shallow clone), its
`node_modules` (~4 GB — the reference host's full dev checkout carries
3.9 GB), and the built `dist/` (~250 MB) to the airootfs — roughly **5–7 GB
uncompressed** before squashfs. `zstd -15` (the profile's squashfs setting)
compresses JS/source well, so the *ISO* is expected to grow by roughly
**2–3 GB** (first full build likely lands in the 3–4 GB range). Exact
numbers belong in the first real build's notes; the reference checkout
breakdown (beelink, 2026-09) that informs this estimate: `node_modules`
3.9 GB, full `.git` 3.6 GB (a depth-1 tag clone is far smaller), `apps/`
1.7 GB (not a pnpm workspace member — still cloned as source), `dist/`
249 MB, `dist-runtime/` 26 MB.

## VM smoke test

```sh
qemu-system-x86_64 -enable-kvm -m 4096 -cdrom out/openclaw-linux-<version>-x86_64.iso
```

Notes:

- Add `-boot d` if the VM tries the disk first, and `-smp 4` to match the
  reference box. For a UEFI-boot smoke test use an OVMF firmware image
  (e.g. `-bios /usr/share/edk2/x64/OVMF_CODE.fd`, from `edk2-ovmf`).
- Interactive GUI checks belong on a desktop-capable VM; headless render
  checks follow [`docs/runbooks/vm-test.md`](../docs/runbooks/vm-test.md).

## What boots

- **BIOS (syslinux)** and **UEFI (systemd-boot)** load
  `/<install_dir>/boot/x86_64/vmlinuz-linux` +
  `initramfs-linux.img`. The initramfs carries the archiso hooks
  (via `airootfs/etc/mkinitcpio.conf.d/archiso.conf` + the
  `airootfs/etc/mkinitcpio.d/linux.preset` override, which replace the stock
  preset so the image built in the chroot is the archiso one).
- The kernel command line (`archisobasedir=openclaw
  archisosearchuuid=<uuid>`) makes the hooks find and mount
  `/<install_dir>/x86_64/airootfs.sfs` (squashfs), then switch into the live
  root.
- The **live** media boots to the archiso root console (autologin) with the
  staged payload at `/root/provision/` and the baked OpenClaw at
  `/opt/openclaw` (`openclaw` is on PATH for diagnostics).
- The **installed** system (archinstall; desktop-user work tracked in issue
  #20 — SDDM autologin → desktop session) is the appliance: at the desktop
  user's login the pre-enabled user service starts the gateway and the
  Chromium app-mode dashboard opens on the Control UI — the
  **boot → gateway on <http://127.0.0.1:18789> → dashboard** story, fully
  offline (see "Build-time bake" below). Config (API key, Telegram pairing)
  is still a first-boot wizard pass — that part needs network.

## Build-time bake (issue #21): the gateway ships in the image

`archiso/airootfs/root/customize_airootfs.sh` is the archiso-standard
build-time hook: mkarchiso stages it into the chroot (`/root/`), runs it
there **after** `packages.x86_64` is installed, and deletes it again, so it
never appears in the finished image. It performs the software install that
the first-boot provisioner used to do at runtime (which failed offline):

1. `git clone --depth 1 --branch <tag>` of openclaw into `/opt/openclaw`,
   pinned to the newest stable release (**v2026.8.2** at the time of
   writing; bump `OPENCLAW_TAG` in the hook to track newer stable tags —
   releases at <https://github.com/openclaw/openclaw/releases>).
2. Installs dependencies with the workspace's **pinned pnpm** (the repo
   pins `packageManager` in `package.json` and uses pnpm-12-era
   `pnpm-workspace.yaml` settings; when the distro pnpm is an older major
   the hook bootstraps the pin via `npm install -g pnpm@<pin>` — `npm` is in
   `packages.x86_64` for that), then `pnpm build` → `/opt/openclaw/dist/`.
3. Symlinks `/usr/local/bin/openclaw` → `/opt/openclaw/openclaw.mjs` so the
   CLI is on every user's PATH, and smoke-checks
   `openclaw --version` offline (isolated HOME, no config written into the
   image's `/root`).
4. Stages the desktop-session wiring under `/etc/skel` (unit + autostart,
   see next section) and cleans its build caches out of the image.

Upstream note: mkarchiso prints *"customize_airootfs.sh is deprecated!
Support for it will be removed in a future archiso version"* when it runs the
hook. It is still executed and is the only build-time, network-capable hook
archiso 90 offers (verified against the v90 `mkarchiso` source,
`_make_customize_airootfs`); the releng profile simply no longer ships one.
If a future archiso removes support, the bake must move to the
installer/first-boot path — which would trade away the offline capability
this issue exists to provide — so the archiso version is effectively pinned
by this hook.

### Why the gateway is a *user* unit staged via `/etc/skel`

The reference deployment runs OpenClaw as a **user** service in the desktop
user's systemd session (`~/.config/systemd/user/openclaw-gateway.service`,
generated by `openclaw gateway install`), serving the Control UI on
<http://127.0.0.1:18789>; its config, secret store and SecretRefs live in the
user's `~/.openclaw`. A system-level unit cannot mirror that, and no desktop
user exists at image build time (issue #20 adds SDDM + a default desktop
user as parallel work). So the profile ships, under `etc/skel/`:

- `.config/systemd/user/openclaw-gateway.service` — the unit, mirroring
  `openclaw gateway install` output for the baked `/opt/openclaw` install
  (`/usr/bin/node /opt/openclaw/dist/index.js gateway --port 18789`);
- `.config/systemd/user/default.target.wants/openclaw-gateway.service` — a
  relative symlink that **pre-enables** the unit, so it starts at the first
  login without any manual `systemctl --user enable`;
- `.config/autostart/openclaw-dashboard.desktop` — XDG autostart (systemd's
  xdg-autostart-generator) launching Chromium app-mode at the Control UI,
  matching `provision/install-dashboard-launcher.sh`'s `Exec`.

`useradd -m` copies `/etc/skel` into every new user's home, and mkarchiso
itself copies `/etc/skel` into the homes of users listed in
`airootfs/etc/passwd` at build time — so whether issue #20's desktop user is
created at build time or at install time, both wiring paths are covered.
The first-boot wizard (step 1) re-runs `openclaw gateway install`, which
regenerates the unit tuned to the machine (e.g. node heap from RAM);
because the staged unit already mirrors that output, the regeneration is
idempotent.

## First-boot provisioning wiring (the CONFIG pass)

The repo's [`provision/`](../provision/) scripts configure a running box
into an OpenClaw appliance (DeepSeek key, Telegram pairing, dashboard
launcher, update channel — see
[`docs/specs/first-boot.md`](../docs/specs/first-boot.md)). Since the
software payload now ships in the image (bake above), the wizard is a
pure config pass:

- `archiso/airootfs/root/provision/` holds a **frozen copy** of the payload
  (scripts + step modules + a README). Re-sync it from `provision/` before
  each build — the copy step is in the payload README and the staged copies
  are byte-identical to the repo sources.
- `archiso/airootfs/etc/systemd/system/openclaw-firstboot.service` is the
  archiso-standard hook: a self-disarming oneshot that runs the staged
  wizard. Like every unit an archiso profile ships under `etc/systemd/system/`,
  it is **disabled in the image**; enablement happens at **install time**
  inside the installed system's chroot:

  ```sh
  systemctl enable openclaw-firstboot.service   # in the installed chroot
  ```

  The scripted installer (TODO below) performs that step; manual installs
  can run it after `arch-chroot`.

- The wizard is interactive (masked secret prompts, ephemeral pairing
  code) and drives the desktop user's systemd session, so the first-boot UX
  on a real appliance is the human running
  `sh /root/provision/firstboot.sh` from their desktop terminal
  (`--dry-run` prints a no-change guidance pass first). The unit is the
  documented hook point and guard, not a headless provisioner — the payload
  README spells out the caveats. Step 1 (`openclaw gateway install`) now
  works offline because the CLI is baked; steps 2–3 (API key, Telegram)
  need network; steps 4–5 do not.

## Package seed

`packages.x86_64` is grouped by purpose: base + kernel, Hyprland-family
desktop, Chromium UI runtime, OpenClaw gateway runtime, boot/install
plumbing, and build-time tooling (`npm` — bootstraps the workspace-pinned
pnpm for the bake hook). Every name was verified against the official Arch
repos via `archlinux.org/packages/search/json` (seed 2026-09-03; `npm`
re-verified 2026-09-04); `syslinux` and `mkinitcpio-archiso` are required by
mkarchiso's bootmode validation/boot chain. `webkit2gtk-4.1` is deliberately
absent.

## TODOs

- Scripted install-to-disk flow (archinstall/calamares/scripted) that, at
  install time, copies the airootfs overlay to the target and enables
  `openclaw-firstboot.service`.
- First real `mkarchiso` build, then a qemu smoke test (above), then
  re-verify the package seed against current repos at build time. The bake
  makes this the critical live-test milestone — items to verify on the real
  build:
  - the hook's DNS fallback fires/does not fire as expected on the build
    host, and the chroot resolver actually reaches github + the npm registry;
  - `pnpm install --frozen-lockfile` + `pnpm build` complete against the
    pinned tag (dist naming, native deps) and `openclaw --version` matches
    the tag;
  - on an installed system with a desktop user (issue #20), the gateway
    starts unconfigured from the first login (or fails gracefully until
    `openclaw onboard --mode local` + the wizard run) and the dashboard
    autostart reliably finds the Control UI (chromium-vs-gateway startup
    race; add a wait helper only if the real hardware loses it);
  - image size lands in the expected range (above).
- Installed-appliance update story: the baked checkout is a stable tag, so
  `openclaw update` dev-track semantics do not apply; appliances update by
  re-image (or a root-run `git fetch` + `pnpm install`/build in
  `/opt/openclaw`). The wizard still sets `update.channel=dev` for the
  reference-host workflow — document the appliance path when the installer
  flow lands.
