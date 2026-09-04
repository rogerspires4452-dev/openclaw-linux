# archiso — OpenClaw Linux appliance install-media profile

Releng-style [archiso](https://gitlab.archlinux.org/archlinux/archiso)
profile for building bootable media for the OpenClaw appliance: a minimal
Arch base with the Hyprland-family desktop, Chromium app-mode UI, and the
staged first-boot provisioning payload. The reference hardware is the
Omarchy/beelink box (Alder Lake-N, Intel), and the profile targets the same
software stack — minus anything that depends on WebKitGTK, which renders
blank there ([`docs/verdicts/webkitgtk-on-beelink.md`](../docs/verdicts/webkitgtk-on-beelink.md)).

**Status: buildable skeleton.** Every file is syntactically validated and
every package name is verified against the official Arch repos, but no ISO
has been built from this profile yet — the maintainer builds and iterates
(`mkarchiso` needs root and a long runtime). The profile mirrors the
`releng` layout shipped with archiso 90 (bootmode names `bios.syslinux` /
`uefi.systemd-boot`, plain `initramfs-linux.img` with the archiso hooks).

## Layout

```text
archiso/
├── README.md                   ← this file
├── profiledef.sh               ← profile metadata mkarchiso sources (name, arch, bootmodes…)
├── pacman.conf                 ← pacman config for the build chroot (multilib + [omarchy] on)
├── packages.x86_64             ← package seed list, grouped by purpose (all verified)
├── airootfs/                   ← copied verbatim into the image root
│   ├── etc/
│   │   ├── mkinitcpio.conf.d/archiso.conf   ← archiso initramfs hooks (boot chain)
│   │   ├── mkinitcpio.d/linux.preset        ← build only the archiso initramfs
│   │   ├── sddm.conf.d/                     ← SDDM greeter + autologin (installed system)
│   │   ├── skel/.config/{hypr,waybar}/      ← desktop-user session skeleton
│   │   └── systemd/system/
│   │       └── openclaw-firstboot.service   ← first-boot wizard hook (enabled at install time)
│   ├── usr/
│   │   ├── local/bin/openclaw-dashboard-autostart   ← dashboard app-mode wrapper
│   │   └── share/sddm/hyprland.lua                  ← greeter compositor config
│   └── root/provision/         ← staged copy of the repo's provision/ payload (+ README)
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
- No bootloader/installer flow exists yet (see TODOs): booting the media
  today gives a live appliance root with the staged payload at
  `/root/provision/`.

## Desktop session wiring (installed system)

The profile stages the Omarchy-style desktop chain
(`docs/specs/desktop.md`), but it takes effect on the **installed** system,
not the live root — the live media keeps the root TTY autologin (below) and
does not enable a display manager:

- `etc/sddm.conf.d/10-wayland.conf` — SDDM greeter on Hyprland (mirrors the
  reference host; `start-hyprland` ships with the `hyprland` package).
- `etc/sddm.conf.d/autologin.conf` — autologin `User=openclaw` into
  `Session=hyprland-uwsm.desktop` (the uwsm-managed Hyprland entry shipped by
  the `hyprland` package). **`openclaw` must be created at install time**
  (the future installer does `useradd -m -G wheel openclaw`; update `User=`
  here if a different name is chosen). No extra group is required for SDDM
  autologin.
- `usr/share/sddm/hyprland.lua` — minimal greeter compositor config.
- `etc/skel/.config/hypr/hyprland.conf` — desktop-user Hyprland skeleton
  (classic config): `SUPER+Return` foot, `SUPER+D` fuzzel, window binds, and
  `exec-once` waybar + the dashboard wrapper. Seeded to new users via
  `/etc/skel` at `useradd -m`.
- `etc/skel/.config/waybar/{config.jsonc,style.css}` — stopgap top bar
  (waybar ships no default config).
- `usr/local/bin/openclaw-dashboard-autostart` — waits (bounded, 60s) for
  `http://127.0.0.1:18789/healthz`, then opens the Control UI in Chromium
  app-mode (WebKitGTK never:
  `docs/verdicts/webkitgtk-on-beelink.md`).

These are **templates the installer copies onto the target**: none collide
with a package-owned path, so they survive the image build, and they only
become live when an installed system overlays them and enables SDDM
(`systemctl enable sddm`). Full steps in `docs/specs/desktop.md`,
"Install-time provisioning".

## First-boot provisioning wiring

The repo's [`provision/`](../provision/) scripts turn a running box into an
OpenClaw appliance (gateway service, DeepSeek key, Telegram pairing,
dashboard launcher — see [`docs/specs/first-boot.md`](../docs/specs/first-boot.md)).
The profile stages them:

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
  README spells out the caveats.

Why no `customize_airootfs.sh`? The repo skeleton carried one, but current
archiso (90 / mkinitcpio-archiso 73) no longer runs it at live boot and
deprecates its build-time chroot execution; the modern releng pattern is
systemd units staged in `airootfs/etc/systemd/system/`, which is what this
profile uses.

## Package seed

`packages.x86_64` is grouped by purpose: base + kernel, Hyprland-family
desktop, Chromium UI runtime, OpenClaw gateway runtime, boot/install
plumbing. Every name was verified against the official Arch repos on
2026-09-03 via `archlinux.org/packages/search/json` (see file header);
`syslinux` and `mkinitcpio-archiso` are required by mkarchiso's bootmode
validation/boot chain. `webkit2gtk-4.1` is deliberately absent.

## TODOs

- Scripted install-to-disk flow (archinstall/calamares/scripted) that, at
  install time, copies the airootfs overlay to the target and enables
  `openclaw-firstboot.service`.
- Bundle the openclaw CLI/gateway into the image (clone or AUR-style) so a
  fresh install only runs the wizard — needs the repo's blessed install
  path; tracked against the first-boot spec.
- First real `mkarchiso` build, then a qemu smoke test (above), then
  re-verify the package seed against current repos at build time.
