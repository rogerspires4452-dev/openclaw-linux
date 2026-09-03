# archiso — OpenClaw Linux install-media profile

Draft profile (Phase 2 of the repo vision) for building a bootable Arch-based
media that installs — and, eventually, self-provisions — an OpenClaw appliance
desktop. This is a **skeleton**: the layout, package seed, and build docs are
in place, but no bootloader config, installer flow, or first-boot provisioning
exists yet, and **no ISO build has been attempted**.

Tracked by [issue #3](https://github.com/rogerspires4452-dev/openclaw-linux/issues/3).

## Layout (releng-style archiso profile)

```
archiso/
├── README.md                 ← this file
├── profiledef.sh             ← profile metadata mkarchiso sources (name, arch, modes…)
├── pacman.conf               ← pacman config used inside the mkarchiso build chroot
├── packages.x86_64           ← package seed list, grouped by purpose
└── airootfs/                 ← copied verbatim into the live root filesystem
    └── root/
        └── customize_airootfs.sh   ← first-boot hook placeholder (runs when media boots)
```

Missing until a real build is attempted (TODO): bootloader config directories
(`grub/`, `syslinux/`, `efiboot/`) — `profiledef.sh` has `bootmodes` commented
out until they exist.

## How archiso builds it

`archiso` is the official Arch tooling for building live/install media. The
profile directory above is its input; the build host must be an Arch machine
with the `archiso` package installed.

```sh
# from the repo root, or with the profile path swapped in
sudo mkarchiso -v -w /tmp/openclaw-work -o /tmp/openclaw-out archiso/
```

What `mkarchiso` does with this profile, roughly in order:

1. Reads `profiledef.sh` for name/arch/version and the build modes.
2. Creates an x86_64 build chroot and `pacstrap`s it using `packages.x86_64`
   resolved through this profile's `pacman.conf` (mirrorlist comes from the
   build host, via `Include = /etc/pacman.d/mirrorlist`).
3. Overlays `airootfs/` onto that chroot — files land verbatim in the live
   root, so `airootfs/root/customize_airootfs.sh` becomes `/root/…` on the
   media.
4. Squashes the result (`airootfs_image_type="squashfs"` in `profiledef.sh`)
   and assembles the bootable image.

Output (once bootmodes are enabled) would be
`openclaw-linux-<version>-x86_64.iso` in the output directory. The first real
build should be smoke-tested in the qemu VM — see
[`docs/runbooks/vm-test.md`](../docs/runbooks/vm-test.md).

## What the profile does

The seed list in `packages.x86_64` builds an OpenClaw appliance desktop:

- **Base system** — `base`, kernel, firmware, `sudo`, `networkmanager`,
  `openssh`.
- **Hyprland-family desktop** — `hyprland` + `waybar` + `foot`, the same
  window-manager family as the reference Omarchy/beelink box, kept minimal.
- **UI runtime** — `chromium` only. WebKitGTK (`webkit2gtk-4.1`) is
  deliberately excluded: it renders blank on the reference hardware
  ([`docs/verdicts/webkitgtk-on-beelink.md`](../docs/verdicts/webkitgtk-on-beelink.md)),
  so the dashboard/pairing UI runs as a Chromium app-mode window
  (cf. `provision/install-dashboard-launcher.sh`).
- **OpenClaw runtime** — `git`, `nodejs`, `pnpm`.
- Plumbing — audio (PipeWire), fonts, EFI boot packages.

Each group carries an inline comment in the file itself.

## How `provision/` hooks in at first boot — TODO, NOT integrated

The repo root's [`provision/`](../provision/) scripts (e.g.
`install-dashboard-launcher.sh`) know how to turn a running Arch/Omarchy box
into an OpenClaw appliance. The end state for this profile is that a fresh
install boots, runs provisioning once, and lands on the dashboard — but that
wiring does **not exist yet**. The planned hook points are:

1. `airootfs/root/customize_airootfs.sh` — the archiso-standard hook that runs
   when the **media** boots (releng convention). It currently contains only a
   placeholder body explaining the intended integration.
2. Installed-system first boot — a design TODO: stage the `provision/` payload
   into the installed root (e.g. `/opt/openclaw/provision/`) and run it via a
   one-shot service (e.g. `openclaw-firstboot.service`) exactly once.

Concretely outstanding before any of this works:

- [ ] bootloader config dirs + `bootmodes` in `profiledef.sh`
- [ ] install-to-disk flow (archinstall/calamares/scripted) for the ISO
- [ ] provision payload staging + first-boot service design
- [ ] first real build, then a qemu VM smoke test
- [ ] re-verify the package seed against current Arch repos at build time
