# archiso — OpenClaw Linux appliance install-media profile

Releng-style [archiso](https://gitlab.archlinux.org/archlinux/archiso)
profile for building bootable media for the OpenClaw appliance: a minimal
Arch base with the Hyprland-family desktop, Chromium app-mode UI, and the
staged first-boot provisioning payload. The reference hardware is the
Omarchy/beelink box (Alder Lake-N, Intel), and the profile targets the same
software stack — minus anything that depends on WebKitGTK, which renders
blank there ([`docs/verdicts/webkitgtk-on-beelink.md`](../docs/verdicts/webkitgtk-on-beelink.md)).

**Status: buildable skeleton with a complete install flow.** Every file is
syntactically validated and every package name is verified against the
official Arch repos, but no ISO has been built from this profile yet — the
maintainer builds and iterates (`mkarchiso` needs root and a long runtime).
The profile mirrors the `releng` layout shipped with archiso 90 (bootmode
names `bios.syslinux` / `uefi.systemd-boot`, plain `initramfs-linux.img`
with the archiso hooks). Since 2026-09-04 the media also ships a guided
installer at `/root/install-openclaw.sh` (issue #22) — boot the stick and
run it to install OpenClaw Linux onto a PC; see
[`install/`](../install/README.md) for the design and the archinstall
version pinning.

## Layout

```text
archiso/
├── README.md                   ← this file
├── profiledef.sh               ← profile metadata mkarchiso sources (name, arch, bootmodes…)
├── pacman.conf                 ← pacman config for the build chroot (multilib on; omarchy commented)
├── packages.x86_64             ← package seed list, grouped by purpose (all verified)
├── airootfs/                   ← copied verbatim into the image root
│   ├── etc/
│   │   ├── issue               ← live-console banner: how to run the guided installer
│   │   ├── mkinitcpio.conf.d/archiso.conf   ← archiso initramfs hooks (boot chain)
│   │   ├── mkinitcpio.d/linux.preset        ← build only the archiso initramfs
│   │   └── systemd/system/
│   │       └── openclaw-firstboot.service   ← first-boot wizard hook (enabled at install time)
│   └── root/
│       ├── install-openclaw.sh ← guided installer (staged copy of install/)
│       └── provision/          ← staged copy of the repo's provision/ payload (+ README)
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
- Booting the media lands on a root console (autologin on tty1). The console
  banner (`airootfs/etc/issue`) points at the guided installer:
  `sh /root/install-openclaw.sh` (`--check` runs a read-only probe of the
  machine first).

## Guided install-to-disk (issue #22)

`install/install-openclaw.sh` (repo) is staged as
`archiso/airootfs/root/install-openclaw.sh`, so a built ISO carries it at
`/root/install-openclaw.sh` (mode 755 via `profiledef.sh`
`file_permissions`). It prompts for the target disk (with existing-OS
detection + erase confirmation), hostname/user/passwords, then drives
archinstall in scripted mode for a full-disk UEFI install (ESP + btrfs
`@` layout, grub, NetworkManager, zram) and stages/enables the first-boot
payload in the installed system. Read
[`install/README.md`](../install/README.md) first — it documents the
archinstall path choice, the schema pinning, and what still needs a live
hardware test.

Sync rule: the staged copy must stay **byte-identical** to
`install/install-openclaw.sh` (same convention as `provision/`):

```sh
cp install/install-openclaw.sh archiso/airootfs/root/install-openclaw.sh
```

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

  The guided installer ([`install/install-openclaw.sh`](../install/install-openclaw.sh))
  performs that step automatically at the end of a scripted install: it
  copies the staged wizard payload into the target and enables the unit
  (manual installs can still run the command above after `arch-chroot`).

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

`install/install-openclaw.sh` embeds its own **target** package list for
installed systems: the same seed minus the live-media-only entries
(syslinux, mkinitcpio-archiso, dosfstools, archinstall,
arch-install-scripts); CPU microcode is added by archinstall at install
time. Keep the two lists in sync when the seed changes.

## TODOs

- Bundle the openclaw CLI/gateway into the image (clone or AUR-style) so a
  fresh install only runs the wizard — needs the repo's blessed install
  path; tracked against the first-boot spec (issue #21).
- First real `mkarchiso` build, then a qemu smoke test (above), then
  re-verify the package seed against current repos at build time.
- One full install-to-disk run from a built ISO on spare hardware (see
  `install/README.md`, "Needs a live hardware test").
