# install — guided install-to-disk flow (issue #22)

`install-openclaw.sh` is the guided installer baked into the OpenClaw Linux
install media as `/root/install-openclaw.sh` (staged copy under
`archiso/airootfs/root/` — keep it byte-identical to this file; see
[`archiso/README.md`](../archiso/README.md) for the sync command). Booting
the stick and running it installs OpenClaw Linux to a PC with a few prompts:

1. **Disk pick.** Every real disk is listed with size/model and a read-only
   probe result: blank, "partitions exist but no OS markers", or "existing
   OS detected" (os-release read via read-only mounts, Windows markers, and
   UEFI boot entries whose device path references the disk's partition
   GUIDs — this is what catches an existing Omarchy/dual-boot install on
   the same NVMe). The install media's own disk is excluded.
2. **Erase gate.** The chosen disk is only touched after the user types the
   exact device path, and a disk that is not blank additionally requires a
   literal `ERASE`. Nothing is ever wiped by default or by accident.
3. **Identity prompts.** Hostname, username, and password (masked, no echo,
   minimum 8 chars, typed twice). The root account is left locked; the
   created user gets sudo (wheel + a sudoers.d rule, via archinstall).
4. **Scripted archinstall.** The installer generates archinstall JSON and
   runs it non-interactively (details below), then verifies the result,
   stages the appliance first-boot payload
   (`/root/provision/` + `openclaw-firstboot.service`) into the installed
   system and enables the unit.
5. **Summary + reboot hint.**

Run `install-openclaw.sh --check` anywhere for a read-only system check
(firmware mode, tool availability, networking, disk inventory with the
existing-OS probe results). The installer itself must run as root from the
install media and currently supports **UEFI targets only**; BIOS/legacy
machines should use the interactive `archinstall` that the media also ships.

## Which install path this uses, and why

**Path chosen: archinstall scripted mode** (`archinstall --config
user_configuration.json --creds user_credentials.json --silent`), for a
full-disk install onto a wiped disk. Researched against archinstall **4.4**
(the version in Arch `extra` as of 2026-09-04; source + examples read, and
the generated JSON validated with a real `archinstall --dry-run` against a
scratch loop device — `--dry-run` returns before any disk operation).

The generated `disk_config` mirrors archinstall's own single-disk default
layout (see `archinstall/lib/disk/disk_menu.py`,
`suggest_single_disk_layout()`): fresh GPT, 1 GiB FAT32 ESP flagged
`boot`+`esp` mounted at `/boot`, and the remainder btrfs with the default
`@`/`@home`/`@log`/`@pkg` subvolume layout. Bootloader: grub (UEFI,
`--bootloader-id=GRUB`). NetworkManager is enabled as a service, swap is
zram (`zram-generator` is installed by archinstall when the `swap` config is
set), locale is `en_US.UTF-8` with a `us` keyboard, timezone `UTC`, NTP on.
Passwords go to archinstall through its `--creds` file using the legacy
plaintext keys (`!users`/`!password`) that archinstall 4.4 still parses and
hashes internally; the credentials file is written mode 0600 into a private
tmpdir that is deleted on exit (including on failure), and passwords never
reach argv or logs. The package list mirrors `archiso/packages.x86_64`
minus the live-media-only entries; microcode is added automatically by
archinstall from the running CPU.

**Deliberately not automated: dual-boot / free-space installs.** archinstall
scripted mode has no JSON-level "install into the free space of an existing
disk" mode: `wipe: true` erases the whole device, and `wipe: false` with
`existing`/`modify` partition entries requires enumerating every current
partition with exact offsets and statuses — effectively reimplementing a
partition editor blind. Automating that safely is not possible without
hardware testing, so instead of shipping an untested dual-boot partitioner
the installer **detects an existing OS and refuses to wipe it** without a
typed `ERASE` on top of the exact-device-path confirmation, and points the
user at the interactive `archinstall` (also on the media) for genuine
dual-boot setups. This satisfies the issue's hard requirement — handle
full-disk installs and warn about/avoid clobbering an existing OS — without
a path that could silently destroy the reference host's Omarchy install.

## Schema pinning and upgrades

The JSON schema is validated against archinstall 4.4-1. Two defenses keep
future archinstall updates honest:

- the installer always runs `archinstall --silent --dry-run` on its own
  generated files before the real run and aborts if archinstall rejects
  them, and
- `install-openclaw.sh`'s header documents the provenance and the exact
  re-validation command.

If archinstall ever drops the legacy `!users`/`!password` credentials keys,
that dry-run fails loudly before anything is touched.

## Composing with #20 (desktop) and #21 (baked gateway)

The installed system ships the current media package set (Hyprland-family
desktop stack, Chromium UI runtime, OpenClaw gateway runtime deps) and the
staged first-boot payload, with `openclaw-firstboot.service` enabled in the
target chroot per the archiso wiring documented in
[`archiso/README.md`](../archiso/README.md). The wizard itself needs the
openclaw CLI and a logged-in desktop session, so until #21 bakes the CLI
into the image the first-boot unit fails fast and retries, and the human
runs `sh /root/provision/firstboot.sh` after first login — the payload
README and the installer summary both say so. Desktop login-manager wiring
lands with #20.

## Needs a live hardware test

Reviewed and validated without a live run: `sh -n`, shellcheck
(`shellcheck -s sh`, clean), generated JSON parses, archinstall
`--dry-run` accepts the generated config+creds against real loop-device
geometry (exit 0; negative test with overlapping partitions exits 1), and
the `--check` mode's existing-OS detection was exercised on the reference
dual-boot host (NVMe with ESP + LUKS root + UEFI boot entries correctly
reported). What still needs a real machine:

- one full install onto spare hardware or a VM booted from a built ISO
  (partitioning, pacstrap, grub + EFI entry, first boot), and
- a dual-boot-host run of the erase gate (detection wording, ERASE flow)
  on a machine you are willing to wipe, to confirm the prompts read
  correctly end to end.
