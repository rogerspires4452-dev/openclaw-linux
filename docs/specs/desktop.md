# Spec: Omarchy-style desktop (SDDM → uwsm → Hyprland)

Turns the OpenClaw appliance from a headless root console into a desktop that
mirrors the reference host's Omarchy session model:

```text
SDDM autologin (user: openclaw) → uwsm → Hyprland → waybar (stopgap bar)
                                                    + fuzzel (stopgap launcher)
                                                    + OpenClaw dashboard autostart
```

Implements issue #20 (Desktop experience: Omarchy-style shell, user setup,
SDDM autologin). This document records the research behind the change, what
is staged in the ISO profile versus what must happen at install time, and the
deliberate approximations.

## Research summary (2026-09-04)

### How Omarchy provisions a system

Source: `github.com/omacom/omarchy` (HEAD `f99d33a`, version `4.0.0.alpha`),
plus the reference host (Omarchy 4.0.2, beelink), plus `omacom/omarchy-pkgs`
(the package build repo).

- Two Arch packages are built from the omarchy repo (per `docs/file-layout.md`):
  - **`omarchy`** (4.0.2-1) — runtime: `bin/`, install/finalize scripts,
    migrations, themes, and the Quickshell desktop under `/usr/share/omarchy/shell`.
    Depends on `omarchy-keyring`, `omarchy-settings=4.0.2`, `limine`,
    `limine-mkinitcpio-hook`, `limine-snapper-sync`, `snapper`, `hyprland`,
    `quickshell`, `uwsm`, `sddm`, `xdg-desktop-portal-hyprland`, `wireplumber`,
    `pipewire`, `gnome-keyring`, `gum`, `jq`, `git`, `perl`, `fakeroot`,
    `pacman-contrib`, `ttf-jetbrains-mono-nerd-basic`.
  - **`omarchy-settings`** (4.0.2-1) — everything needed before the meta
    installs: `/etc/skel/**`, `/etc/` drop-ins (systemd, sysctl, sudoers,
    logind, `sddm.conf.d`), the SDDM theme (`/usr/share/sddm/themes/omarchy`),
    the SDDM greeter compositor config (`/usr/share/sddm/hyprland.lua`),
    the wayland session entry (`omarchy.desktop`), plymouth theme, fonts,
    limine/snapper trees.
- The omarchy desktop session entry (`/usr/share/omarchy/default/wayland-sessions/omarchy.desktop`):
  `Exec=uwsm start -g -1 -e -D Hyprland hyprland.desktop`. SDDM autologin on
  the reference host (`/etc/sddm.conf.d/autologin.conf`) is
  `User=roger` + `Session=omarchy.desktop`; no special group is required.
- The SDDM **greeter itself runs Hyprland** (`/etc/sddm.conf.d/10-wayland.conf`:
  `DisplayServer=wayland`, `CompositorCommand=start-hyprland -- --config
  /usr/share/sddm/hyprland.lua`). `start-hyprland` is owned by the **hyprland**
  package, so no omarchy dependency is needed to reproduce this.
- Hyprland autostart launches the desktop shell on the `hyprland.start` event
  (`/usr/share/omarchy/default/hypr/autostart.lua`):
  `omarchy-launch-shell` → `quickshell -n -p /usr/share/omarchy/shell`
  (observed running on the reference host). App-level autostarts can also go
  through `~/.config/autostart`: **uwsm natively processes XDG autostart**
  entries (`wayland-session-xdg-autostart@.target` bound to
  `xdg-desktop-autostart.target`).
- `quickshell` (0.3.1-1) is now in the **official extra repo**; the omarchy
  repo additionally carries `quickshell-git` (provides/conflicts `quickshell`).
  However, the Omarchy shell itself (bar, panels, plugins, IPC) ships only
  inside the `omarchy` package — there is no standalone "omarchy-shell" package.
- `[omarchy]` repo facts (`https://pkgs.omarchy.org/stable/x86_64`):
  - Repo db `omarchy.db` is served **unsigned** (no `.db.sig`); global
    `SigLevel = Required DatabaseOptional` therefore accepts the db but still
    requires **signed packages** from a trusted key.
  - Packages are signed by key `40DFB630FF42BCFFB047046CF0134EE680CAC571`;
    trust is bootstrapped out-of-band (keyserver receive + local sign), then
    `omarchy-keyring` (ships `/usr/share/pacman/keyrings/omarchy.gpg` +
    `omarchy-trusted`) is installed and its `.INSTALL` runs
    `pacman-key --populate omarchy`. Omarchy's own migration
    (`migrations/1787589206.sh`) confirms the modern intent: **no per-repo
    `SigLevel` override**; signed packages under the global default.
  - Omarchy's own install (`install/post-install/pacman.sh`) copies a canned
    `/etc/pacman.conf` (their `default/pacman/pacman-stable.conf`, which is the
    stock conf plus `[omarchy]` after `[multilib]`) at **install time**.
- The full `omarchy` metapackage drags in the **limine bootloader + snapper
  rollback** stack (`limine-mkinitcpio-hook`, `limine-snapper-sync`,
  `snapper`) — a boot-architecture change that conflicts with this profile's
  systemd-boot/syslinux install story. Full metapackage integration is
  therefore an **install-time, opt-in** step (below), not an image default.

### Why the ISO profile stages what it stages

Mechanics verified against `mkarchiso` (archiso 89, the version on the
reference host):

- The profile `airootfs/` overlay is copied into the build root **before**
  `pacstrap` installs the package list. Any overlay path a package also owns
  is overwritten by the package (e.g. `/etc/pacman.conf` from the `pacman`
  package). So the image's own `/etc/pacman.conf` is stock Arch; giving an
  **installed** system the `[omarchy]` stanza is an install-time step — the
  same model Omarchy uses (their `post-install/pacman.sh`).
- The build-time `pacman.conf` decides which repositories the package seed
  resolves against, so enabling `[omarchy]` there is what lets a future
  package-seed entry pull an omarchy-repo package at build time. Nothing in
  the current seed needs it; it is enabled (and documented) so the repo stanza
  is real, tested syntax, and the image build stays plain-Arch for now.
- `mkarchiso` strips comments from `packages.x86_64` lines, so grouped
  comments are safe. It performs no `pacman-key` setup in the chroot, so a
  future build-time omarchy-repo package would need chroot keyring handling
  first (tracked in Approximations).

## Staged files (archiso/airootfs)

| Path | Purpose |
| --- | --- |
| `etc/sddm.conf.d/10-wayland.conf` | Run the SDDM greeter on Hyprland (mirrors reference `10-wayland.conf`). |
| `etc/sddm.conf.d/autologin.conf` | Autologin to the appliance user (`openclaw`) with the `hyprland-uwsm.desktop` session (uwsm-managed Hyprland, the reference model minus omarchy's wrapper session). |
| `usr/share/sddm/hyprland.lua` | Minimal Hyprland config for the greeter compositor (derived from Omarchy's, MIT). |
| `usr/local/bin/openclaw-dashboard-autostart` | Waits for the gateway (`http://127.0.0.1:18789/healthz`, bounded) then execs `chromium --app=http://127.0.0.1:18789 --class=openclaw-dash` — Chromium app-mode only, never WebKitGTK (`docs/verdicts/webkitgtk-on-beelink.md`). |
| `etc/skel/.config/hypr/hyprland.conf` | Desktop-user Hyprland skeleton: monitor/input defaults, `SUPER+Return` foot, `SUPER+D` fuzzel, window-close/fullscreen binds, autostart of waybar + the dashboard wrapper. |
| `etc/skel/.config/waybar/config.jsonc` + `style.css` | Stopgap top bar (the `waybar` package ships no default config, so a bare install would run nothing). |

`/etc/skel` content reaches the desktop user at account creation
(`useradd -m`), exactly how `omarchy-settings` seeds new users. Files under
`/etc/sddm.conf.d/`, `/usr/share/sddm/`, and `/usr/local/bin/` do not collide
with any package-owned path, so they survive the image build and are picked
up by the future scripted installer's airootfs overlay (same mechanism as the
existing staged first-boot payload under `root/provision/`).

## Install-time provisioning (not yet scripted)

Until the repo's scripted installer lands (archiso/README.md TODO), a manual
`archinstall`-based install must do the following on the installed system
(target chroot at `/mnt` in the examples). A future installer should perform
these automatically:

1. **Install the desktop packages** (archinstall package list, or in the
   installed chroot): `sddm uwsm hyprland waybar foot fuzzel chromium curl`
   plus the existing seed's desktop set. This matches the image seed
   (packages.x86_64) so installed == image.
2. **Overlay the staged files** from the live media onto the target:
   `/etc/sddm.conf.d/`, `/usr/share/sddm/hyprland.lua`,
   `/usr/local/bin/openclaw-dashboard-autostart` (chmod 755), and
   `/etc/skel/.config/{hypr,waybar}`. The future installer does this by
   copying the airootfs overlay onto the target after the base install.
3. **Create the desktop user** and match the autologin stanza:
   `useradd -m -G wheel openclaw` (adjust `User=` in
   `/etc/sddm.conf.d/autologin.conf` if a different name is chosen) and set a
   password.
4. **Enable the display manager**: `systemctl enable sddm` in the target
   chroot.
5. **Drop the root console autologin** that the live media carries
   (`/etc/systemd/system/getty@tty1.service.d/autologin.conf`) so the desktop
   appliance does not also sit on a passwordless root TTY.
6. **Populate the omarchy keyring** (only when the repo will be used — the
   stanza is inert until then):

   ```sh
   sudo pacman-key --recv-keys 40DFB630FF42BCFFB047046CF0134EE680CAC571 --keyserver keys.openpgp.org
   sudo pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571
   sudo pacman -Sy
   sudo pacman -S --needed omarchy-keyring   # .INSTALL runs `pacman-key --populate omarchy`
   ```

   Then append the repo stanza to the installed `/etc/pacman.conf` (the
   canonical copy is `archiso/pacman.conf` in this repo):

   ```ini
   [omarchy]
   Server = https://pkgs.omarchy.org/stable/$arch
   ```

   No per-repo `SigLevel` override: global `Required DatabaseOptional` plus the
   populated keyring is the supported configuration.
7. **Full Omarchy (opt-in, replaces the stopgap bar/launcher)**: installing
   the `omarchy` + `omarchy-settings` metapackages brings the real Quickshell
   shell, themes, and SDDM theme — but also the limine/snapper boot stack and
   gnome-keyring. That is a deliberate install-time decision (migrate the
   bootloader, then select the `omarchy.desktop` session in the autologin
   stanza); it is out of scope for the appliance image itself.

After install, first boot lands on the Hyprland desktop: waybar top bar,
`SUPER+D` fuzzel launcher, and — once the gateway user service reports
healthy — the OpenClaw dashboard in Chromium app-mode.

## Approximations (deliberate, one-pass scope)

- **Bar/launcher**: waybar + fuzzel are a stopgap for the real Omarchy
  Quickshell shell, whose QML ships only inside the `omarchy` package.
- **Hyprland config format**: the skeleton uses the classic `hyprland.conf`
  (still supported by hyprland 0.56 alongside `.lua`), not Omarchy's Lua
  config, which requires their `bootstrap.lua`/helpers. Syntax is plain and
  long-stable; the reference Lua layout can be adopted when the full omarchy
  layer lands.
- **SDDM theme**: stock theme (autologin skips the greeter anyway); Omarchy's
  `omarchy` SDDM theme comes with `omarchy-settings`.
- **No GUI polkit agent / screen locker** in the skeleton; terminal `sudo`
  covers admin actions, matching the current minimal profile. Add
  `hyprlock`/`hypridle` + a polkit agent with the full-omarchy follow-up.
- **`[omarchy]` repo at build time is enabled but unused**: no seed package
  resolves from it yet, so no chroot keyring handling is needed. A future
  seed entry from the omarchy repo requires populating the build chroot
  keyring first (mkarchiso does not do this automatically).
- **Dashboard autostart timing**: the wrapper polls `:18789/healthz` for up to
  60s so the gateway (a systemd user service) is up before Chromium launches;
  if it never becomes healthy it exits quietly and the installed app launcher
  (provision step 4) remains the manual fallback.

## Validation performed (2026-09-04)

- Package names/versions resolved against the reference host's synced pacman
  databases: `sddm 0.21.0-7`, `uwsm 0.26.7-1`, `fuzzel 1.14.1-2` from
  **extra**; `quickshell 0.3.1-1` from extra (not needed this pass);
  `walker` is omarchy-repo-only. `curl` from extra.
- Reference host configs read live and mirrored: sddm autologin/wayland
  greeter stanzas, `/usr/share/sddm/hyprland.lua`, uwsm session entry.
- `[omarchy]` repo probed directly (`omarchy.db` served; unsigned db;
  omarchy-keyring trust files inspected in `omacom/omarchy-pkgs`).
- `sh -n` on the autostart wrapper; waybar config validated as strict JSON;
  mkarchiso behaviors (overlay ordering, package-list comment stripping, no
  chroot keyring setup) verified from archiso 89 source.
