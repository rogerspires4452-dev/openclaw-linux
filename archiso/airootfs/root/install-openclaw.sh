#!/bin/sh
# install/install-openclaw.sh — guided install-to-disk flow for the OpenClaw
# Linux install media (issue #22).
#
# Baked into the ISO as /root/install-openclaw.sh (see archiso/README.md and
# the staged copy under archiso/airootfs/root/). Booting the stick and running
# this script installs OpenClaw Linux onto a PC with a handful of prompts —
# no manual archinstall session needed.
#
# WHAT IT DOES
#   1. Preflight: root, firmware (UEFI), required tools, live networking.
#   2. Disk pick: lists real disks (never the stick itself), runs a read-only
#      existing-OS probe per disk (partition layout, OS markers read via
#      read-only mounts, UEFI boot entries referencing the disk's partitions)
#      and requires an explicit erase confirmation that names the exact
#      device. A disk that appears to hold an existing OS needs an extra
#      typed ERASE gate — wiping it is never the default.
#   3. Identity: prompts for hostname, username and password (masked; the
#      root account is left locked; the created user gets sudo via
#      archinstall's wheel + sudoers.d handling).
#   4. Install: generates archinstall JSON (config + credentials) and drives
#      archinstall 4.4 in SCRIPTED mode (--config/--creds --silent). Full
#      disk erase + fresh GPT: 1 GiB FAT32 ESP mounted at /boot, rest btrfs
#      with the default @/@home/@log/@pkg subvolume layout, grub bootloader,
#      NetworkManager service, zram swap, locale/timezone/UTC defaults.
#      See install/README.md for why scripted archinstall is used for
#      full-disk installs and why free-space dual-boot is deliberately NOT
#      automated.
#   5. Post-install: verifies the result, stages the appliance first-boot
#      payload (/root/provision + openclaw-firstboot.service) into the
#      installed system and enables the unit, then prints a summary and a
#      reboot hint.
#
# SAFETY
#   * Nothing is written until the disk is explicitly confirmed (typed device
#     path, plus a typed ERASE word when the disk is not blank).
#   * --check runs read-only diagnostics and exits without prompting.
#   * The only destructive action is the archinstall invocation itself, and
#     it targets exactly the confirmed disk.
#
# SHELL CONVENTIONS: POSIX sh, set -e, no bashisms (AGENTS.md). Secrets
# (passwords) are read masked, written only to a 0600 credentials JSON in a
# private tmpdir that is deleted on exit, and never appear in argv, logs, or
# echoed output. The credentials JSON uses archinstall's legacy plaintext
# keys (!users/!password), which archinstall 4.4 still parses; archinstall
# hashes them internally. If a future archinstall drops those keys the
# --dry-run validation step fails loudly before anything is touched.
#
# ARCHINSTALL VERSION PINNING
#   Schema validated against archinstall 4.4-1 (Arch extra, 2026-09-04) with
#   an actual `archinstall --dry-run` against a scratch loop device (dry-run
#   returns before any disk operation). Re-validate after any archinstall
#   update: archinstall --config ... --creds ... --silent --dry-run must
#   exit 0 before a real run is attempted (the installer does this itself).

set -e

# ---- tunables (documented; edit only with care) ----------------------------

# Installed-system package seed: mirror of archiso/packages.x86_64 minus the
# live-media-only entries (syslinux, mkinitcpio-archiso, dosfstools,
# archinstall, arch-install-scripts). Microcode is added automatically by
# archinstall from the running CPU. Desktop/UI additions beyond the stock
# profile land with issues #20/#21.
PACKAGES_OPENCLAW='base linux linux-firmware networkmanager openssh sudo btrfs-progs grub efibootmgr hyprland foot waybar xdg-desktop-portal-hyprland brightnessctl wl-clipboard xorg-xwayland polkit xdg-utils pipewire pipewire-pulse wireplumber noto-fonts chromium git nodejs pnpm base-devel'

DEFAULT_HOSTNAME='openclaw-linux'
KB_LAYOUT='us'          # console/keyboard layout (sane default; no prompt)
SYS_LANG='en_US'        # locale language (sane default)
SYS_ENC='UTF-8'         # locale encoding (sane default)
TIMEZONE='UTC'          # sane default; change later with timedatectl
ESP_SIZE_MIB=1024       # ESP size (1 GiB, archinstall default)
MIN_DISK_MIB=8192       # refuse disks smaller than 8 GiB
WARN_DISK_MIB=32768     # warn below 32 GiB (desktop + chromium is roomy)

# ---- helpers ----------------------------------------------------------------

warn() { printf '%s\n' "WARNING: $*" >&2; }
die() { printf '%s\n' "ERROR: $*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
    cat <<'EOF'
Usage: install-openclaw.sh [--check] [-h|--help]

Guided installer for OpenClaw Linux (issue #22). Run as root from the
install media. Prompts for the target disk, hostname, username and password,
then drives archinstall in scripted mode to install to that disk.

Options:
  --check    Read-only system check: report firmware mode, tool availability,
             networking state and the disk inventory with the existing-OS
             probe results, then exit without changing anything.
  -h, --help Show this help and exit.

The installer never touches a disk without an explicit typed confirmation,
and refuses to wipe a disk that looks like it holds an existing OS unless
you type ERASE as well. The root account is left locked; the created user
gets sudo.
EOF
}

# Read one line from stdin into $_reply. Never aborts the script on EOF;
# callers decide (EOF -> user closed stdin -> abort).
read_line() {
    set +e
    IFS= read -r _reply
    _read_rc=$?
    set -e
    return "$_read_rc"
}

# Masked secret prompt; result in $SECRET_REPLY. stty errors are ignored so
# piped stdin (testing) still works.
read_secret() {  # read_secret <prompt>
    printf '%s' "$1" >&2
    _echo_off=1
    stty -echo 2>/dev/null || true
    set +e
    IFS= read -r SECRET_REPLY
    _read_rc=$?
    set -e
    stty echo 2>/dev/null || true
    _echo_off=0
    printf '\n' >&2
    return "$_read_rc"
}

TMP_DIR=''
_echo_off=0
_RUN_PID=''   # archinstall child, killed on abort so an interrupted run cannot continue unattended
# shellcheck disable=SC2329 # cleanup is invoked via trap EXIT/INT, not by name
cleanup() {
    if [ "$_echo_off" -eq 1 ]; then stty echo 2>/dev/null || true; fi
    if [ -n "$_RUN_PID" ]; then kill "$_RUN_PID" 2>/dev/null || true; fi
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT

need_root() { [ "$(id -u)" -eq 0 ] || die 'must run as root (the install media logs you in as root).'; }

need_cmds() {  # need_cmds cmd cmd ...
    for _cmd in "$@"; do
        command -v "$_cmd" >/dev/null 2>&1 || die "required tool not found: $_cmd (is this the OpenClaw Linux install media?)"
    done
}

# ---- read-only environment probes -------------------------------------------

boot_mode() {
    if [ -d /sys/firmware/efi ]; then
        printf '%s\n' 'uefi'
    else
        printf '%s\n' 'bios'
    fi
}

# Whole disk the live media itself lives on (excluded from targets).
live_disk() {
    _src=''
    if [ -d /run/archiso/bootmnt ]; then
        _src=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)
    fi
    case "$_src" in
        /dev/*) ;;
        *)
            # Not on archiso media (e.g. repo checkout): fall back to the
            # device backing the root mount, if that is a real block device.
            _src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
            ;;
    esac
    case "$_src" in
        /dev/*)
            _resolved=$(readlink -f "$_src" 2>/dev/null || printf '%s' "$_src")
            if [ -b "$_resolved" ]; then
                lsblk -n -o PKNAME "$_resolved" 2>/dev/null || true
            fi
            ;;
    esac
}

start_live_networking() {
    if systemctl -q is-active NetworkManager 2>/dev/null; then
        return 0
    fi
    info 'Starting NetworkManager for the live session (needed to fetch packages)...'
    systemctl start NetworkManager 2>/dev/null || warn 'could not start NetworkManager — the install will fail without network.'
    # Give DHCP a moment; do not hard-fail here, archinstall reports its own
    # network errors with better context.
    _n=0
    while [ "$_n" -lt 15 ]; do
        if nmcli -t -f STATE g 2>/dev/null | grep -q 'connected'; then
            break
        fi
        _n=$((_n + 1))
        sleep 1
    done
}

# ---- existing-OS detection (read-only) --------------------------------------

# Read-only probe: try to identify an OS on a single partition by mounting it
# read-only and looking for os-release / Windows markers. Prints a one-line
# human description; prints nothing when nothing is found.
probe_partition() {  # probe_partition <block-device>
    _part=$1
    _fstype=$(lsblk -dn -o FSTYPE "$_part" 2>/dev/null || true)
    case "$_fstype" in
        ext4 | ext3 | ext2 | xfs | btrfs) ;;
        vfat | ntfs)
            # Windows system partitions: check the partition label instead of
            # mounting (ntfs3 reads are fine, but labels are cheaper).
            _label=$(lsblk -n -o PARTLABEL "$_part" 2>/dev/null || true)
            case "$_label" in
                *[Ww]indows* | *[Rr]ecovery* | *[Ss]ystem* | *[Mm]icrosoft*)
                    printf '%s' "Windows-like partition (label: $_label)"
                    ;;
            esac
            return 0
            ;;
        *) return 0 ;;
    esac

    _mnt="$TMP_DIR/probe-$(basename "$_part")"
    mkdir -p "$_mnt"
    if mount -o ro "$_part" "$_mnt" 2>/dev/null; then
        for _f in etc/os-release usr/lib/os-release @/etc/os-release @/usr/lib/os-release; do
            if [ -f "$_mnt/$_f" ]; then
                _name=$(sed -n 's/^PRETTY_NAME="\?\([^"]*\)"\?$/\1/p' "$_mnt/$_f" 2>/dev/null | head -n 1)
                [ -n "$_name" ] || _name=$(sed -n 's/^NAME="\?\([^"]*\)"\?$/\1/p' "$_mnt/$_f" 2>/dev/null | head -n 1)
                [ -n "$_name" ] && printf '%s' "$_name"
                umount "$_mnt" 2>/dev/null || true
                rmdir "$_mnt" 2>/dev/null || true
                return 0
            fi
        done
        if [ -d "$_mnt/Windows" ] || [ -d "$_mnt/'Program Files'" ]; then
            printf '%s' 'Windows'
            umount "$_mnt" 2>/dev/null || true
            rmdir "$_mnt" 2>/dev/null || true
            return 0
        fi
        umount "$_mnt" 2>/dev/null || true
    fi
    rmdir "$_mnt" 2>/dev/null || true
    return 0
}

# UEFI boot entries whose device path references one of this disk's
# partition GUIDs (i.e. the disk participates in the current boot setup).
efi_entries_for_disk() {  # efi_entries_for_disk <disk> ; prints matching Boot#### lines
    [ -d /sys/firmware/efi ] || return 0
    command -v efibootmgr >/dev/null 2>&1 || return 0
    _entries=$(efibootmgr -v 2>/dev/null || true)
    [ -n "$_entries" ] || return 0
    lsblk -n -l -o PARTUUID "$1" 2>/dev/null | while IFS= read -r _guid; do
        [ -n "$_guid" ] || continue
        printf '%s\n' "$_entries" | while IFS= read -r _line; do
            case "$_line" in
                Boot*)
                    if printf '%s\n' "$_line" | grep -qi "$_guid"; then
                        printf '%s\n' "$_line" | sed 's/\t.*//'
                    fi
                    ;;
            esac
        done
    done | sort -u
}

# Direct partition block devices of a disk (flat listing, no lsblk tree
# glyphs, no nested dm/luks children). Prints full /dev paths.
disk_children() {  # disk_children <disk>
    _base=$(basename "$1")
    lsblk -n -l -o NAME "$1" 2>/dev/null | sed -n '2,$p' | while IFS= read -r _c; do
        case "$_c" in
            "$_base")
                # The disk itself (not a partition) — skip.
                ;;
            "$_base"*)
                if [ -b "/dev/$_c" ]; then
                    printf '/dev/%s\n' "$_c"
                fi
                ;;
        esac
    done
}

# Classify a disk. Prints one of:
#   blank          no partitions
#   used           partitions exist but no OS markers / boot references found
#   os             an existing OS was detected (os-release/Windows/EFI refs)
classify_disk() {  # classify_disk <disk>
    _disk=$1
    _parts=0
    for _part in $(disk_children "$_disk"); do
        _parts=$((_parts + 1))
        if [ -n "$(probe_partition "$_part")" ]; then
            printf '%s\n' 'os'
            return 0
        fi
        case "$(lsblk -dn -o FSTYPE "$_part" 2>/dev/null || true)" in
            vfat | ntfs | crypto_LUKS)
                printf '%s\n' 'os'
                return 0
                ;;
        esac
    done
    if [ "$_parts" -eq 0 ]; then
        printf '%s\n' 'blank'
    elif [ -n "$(efi_entries_for_disk "$_disk")" ]; then
        printf '%s\n' 'os'
    else
        printf '%s\n' 'used'
    fi
}

# Full human-readable report for one disk (used in the picker and in the
# erase warning).
disk_report() {  # disk_report <disk>
    _disk=$1
    printf '    %s  %s  %s\n' "$(lsblk -dn -o SIZE "$_disk" 2>/dev/null)" "$(lsblk -dn -o MODEL "$_disk" 2>/dev/null)" "$_disk"
    _parts=0
    for _part in $(disk_children "$_disk"); do
        _parts=$((_parts + 1))
        _fs=$(lsblk -dn -o FSTYPE "$_part" 2>/dev/null || printf '?')
        _sz=$(lsblk -dn -o SIZE "$_part" 2>/dev/null || printf '?')
        _mp=$(lsblk -dn -o MOUNTPOINTS "$_part" 2>/dev/null | head -n 1 || true)
        [ -n "$_mp" ] || _mp='-'
        printf '      partition %-22s %-12s %-12s mounted: %s\n' "$_part" "$_fs" "$_sz" "$_mp"
        _os=$(probe_partition "$_part")
        if [ -n "$_os" ]; then
            printf '        -> contains: %s\n' "$_os"
        elif [ "$_fs" = 'crypto_LUKS' ]; then
            printf '        -> encrypted (LUKS) — contents cannot be inspected from the media\n'
        fi
    done
    [ "$_parts" -eq 0 ] && printf '      (no partitions — blank disk)\n'
    _refs=$(efi_entries_for_disk "$_disk")
    if [ -n "$_refs" ]; then
        printf '      UEFI boot entries referencing this disk:\n'
        printf '%s\n' "$_refs" | sed 's/^/        /'
    fi
}

# ---- disk inventory ----------------------------------------------------------

# List candidate target disks (whole disks only, live media excluded) into
# $DISK_LIST_FILE, one device path per line.
DISK_LIST_FILE=''
collect_disks() {
    DISK_LIST_FILE="$TMP_DIR/disks"
    _live=$(live_disk)
    lsblk -d -n -o NAME,TYPE 2>/dev/null | while IFS=' ' read -r _name _type; do
        [ "$_type" = 'disk' ] || continue
        [ "$_name" = "$_live" ] && continue
        # Skip pseudo disks that report TYPE=disk (zram swap) and other
        # non-target block devices.
        case "$_name" in
            zram* | loop* | md* | dm-* | ram* | fd*) continue ;;
        esac
        printf '/dev/%s\n' "$_name"
    done > "$DISK_LIST_FILE"
}

# ---- interactive prompts ------------------------------------------------------

pick_disk() {
    [ -s "$DISK_LIST_FILE" ] || die 'no installable disks found (is the USB stick the only disk?).'
    info ''
    info 'Available disks:'
    info ''
    _i=0
    while IFS= read -r _d; do
        _i=$((_i + 1))
        info "  [$((_i))] $(lsblk -dn -o SIZE,MODEL "$_d" 2>/dev/null)"
    done < "$DISK_LIST_FILE"
    info ''
    while :; do
        printf 'Select the disk to install to [1-%s]: ' "$_i"
        if ! read_line; then die 'no input (EOF).'; fi
        case "$_reply" in
            '' | *[!0-9]*) continue ;;
        esac
        if [ "$_reply" -ge 1 ] 2>/dev/null && [ "$_reply" -le "$_i" ] 2>/dev/null; then
            break
        fi
    done
    TARGET_DISK=$(sed -n "${_reply}p" "$DISK_LIST_FILE")
    [ -b "$TARGET_DISK" ] || die "selected disk $TARGET_DISK is not a block device."
}

# Erase gate. Prints the red warning with the detection report; requires the
# user to type the exact device path, plus a literal ERASE when the disk is
# not blank.
confirm_erase() {  # confirm_erase <disk> <class>
    _disk=$1
    _class=$2
    info ''
    info '******************************************************************'
    info '***  WARNING: THE SELECTED DISK WILL BE PERMANENTLY ERASED.   ***'
    info "***  Target: $_disk"
    info '******************************************************************'
    info ''
    disk_report "$_disk"
    info ''
    case "$_class" in
        os)
            info '>>> DETECTED: this disk looks like it holds an EXISTING OS.'
            info '>>> Installing will DESTROY it and its boot entries.'
            info '>>> If you wanted to dual-boot (e.g. keep Omarchy/Windows and'
            info '>>> add OpenClaw Linux), this guided flow cannot do that safely'
            info '>>> (see install/README.md). Abort and run the interactive'
            info '>>> archinstall instead:  archinstall'
            info '>>> Or pick a different disk / use a spare machine.'
            ;;
        used)
            info '>>> NOTE: this disk is not blank (partitions exist), though no'
            info '>>> OS markers were found. Everything on it will be destroyed.'
            ;;
        blank)
            info '>>> This disk is blank (no partitions found).'
            ;;
    esac
    info ''
    case "$_class" in
        os | used)
            printf 'Type ERASE to wipe %s anyway: ' "$_disk"
            if ! read_line; then die 'no input (EOF).'; fi
            [ "$_reply" = 'ERASE' ] || die 'aborted (did not type ERASE).'
            ;;
    esac
    printf 'Type the exact device path to confirm (%s): ' "$_disk"
    if ! read_line; then die 'no input (EOF).'; fi
    [ "$_reply" = "$_disk" ] || die "aborted (typed '$_reply', expected '$_disk')."
    info ''
    printf 'Last chance. Install to %s and erase it now? [y/N]: ' "$_disk"
    if ! read_line; then die 'no input (EOF).'; fi
    case "$_reply" in
        y | Y | yes | YES) ;;
        *) die 'aborted.' ;;
    esac
}

prompt_hostname() {
    while :; do
        printf 'Hostname [%s]: ' "$DEFAULT_HOSTNAME"
        if ! read_line; then die 'no input (EOF).'; fi
        _reply=${_reply:-$DEFAULT_HOSTNAME}
        case "$_reply" in
            '' | *[!A-Za-z0-9-]* | -* | *-) warn 'invalid hostname (letters, digits, dashes; not starting/ending with -).' ;;
            *)
                [ "${#_reply}" -le 63 ] || { warn 'hostname too long (max 63).'; continue; }
                TARGET_HOSTNAME=$_reply
                return 0
                ;;
        esac
    done
}

prompt_username() {
    while :; do
        printf 'Username for the desktop user (gets sudo): '
        if ! read_line; then die 'no input (EOF).'; fi
        case "$_reply" in
            '' | *[!A-Za-z0-9_-]* | [0-9]* | -*)
                warn 'invalid username (start with a letter or _; letters, digits, _ and - only).'
                ;;
            root)
                warn 'pick a regular username, not root.'
                ;;
            *)
                [ "${#_reply}" -le 32 ] || { warn 'username too long (max 32).'; continue; }
                TARGET_USERNAME=$_reply
                return 0
                ;;
        esac
    done
}

prompt_passwords() {
    while :; do
        printf 'Password for %s (8+ chars, masked): ' "$TARGET_USERNAME"
        if ! read_secret ''; then die 'no input (EOF).'; fi
        _pw1=$SECRET_REPLY
        printf 'Repeat password (masked): '
        if ! read_secret ''; then die 'no input (EOF).'; fi
        _pw2=$SECRET_REPLY
        if [ "$_pw1" != "$_pw2" ]; then
            warn 'passwords do not match — try again.'
        elif [ "${#_pw1}" -lt 8 ]; then
            warn 'password too short (minimum 8 characters).'
        else
            TARGET_PASSWORD=$_pw1
            _pw1=''
            _pw2=''
            return 0
        fi
        _pw1=''
        _pw2=''
    done
}

# ---- JSON generation ----------------------------------------------------------

disk_size_mib() {  # disk_size_mib <disk> ; prints whole-MiB size
    _bytes=$(lsblk -bnd -o SIZE "$1" 2>/dev/null || die "cannot read size of $1")
    printf '%s\n' "$((_bytes / 1048576))"
}

# Write user_configuration.json (contains no secrets) into $TMP_DIR.
write_config_json() {  # write_config_json <disk> <size-mib>
    _disk=$1
    _size_mib=$2
    _root_len=$((_size_mib - ESP_SIZE_MIB - 2))   # gpt area ends 1 MiB before disk end; ESP starts at 1 MiB
    _root_start=$((1 + ESP_SIZE_MIB))
    [ "$_root_len" -ge 2048 ] || die "disk too small (need at least $((ESP_SIZE_MIB + 2050)) MiB)."
    _packages_json=$(printf '%s' "$PACKAGES_OPENCLAW" | sed 's/^/["/; s/ /", "/g; s/$/"]/')
    _obj_esp=$(uuidgen 2>/dev/null || printf 'openclaw-esp-%s' "$$")
    _obj_root=$(uuidgen 2>/dev/null || printf 'openclaw-root-%s' "$$")
    _size_sector='"sector_size": { "value": 512, "unit": "B" }'
    cat > "$TMP_DIR/user_configuration.json" <<EOF
{
  "archinstall-language": "English",
  "script": "guided",
  "locale_config": {
    "kb_layout": "$KB_LAYOUT",
    "sys_lang": "$SYS_LANG",
    "sys_enc": "$SYS_ENC",
    "console_font": "default8x16"
  },
  "disk_config": {
    "config_type": "default_layout",
    "device_modifications": [
      {
        "device": "$_disk",
        "wipe": true,
        "partitions": [
          {
            "obj_id": "$_obj_esp",
            "status": "create",
            "type": "primary",
            "start": { "value": 1, "unit": "MiB", $_size_sector },
            "size": { "value": $ESP_SIZE_MIB, "unit": "MiB", $_size_sector },
            "fs_type": "fat32",
            "mountpoint": "/boot",
            "mount_options": [],
            "flags": ["boot", "esp"],
            "dev_path": null,
            "btrfs": []
          },
          {
            "obj_id": "$_obj_root",
            "status": "create",
            "type": "primary",
            "start": { "value": $_root_start, "unit": "MiB", $_size_sector },
            "size": { "value": $_root_len, "unit": "MiB", $_size_sector },
            "fs_type": "btrfs",
            "mountpoint": null,
            "mount_options": [],
            "flags": [],
            "dev_path": null,
            "btrfs": [
              { "name": "@", "mountpoint": "/" },
              { "name": "@home", "mountpoint": "/home" },
              { "name": "@log", "mountpoint": "/var/log" },
              { "name": "@pkg", "mountpoint": "/var/cache/pacman/pkg" }
            ]
          }
        ]
      }
    ]
  },
  "bootloader_config": {
    "bootloader": "Grub",
    "uki": false,
    "removable": false
  },
  "hostname": "$TARGET_HOSTNAME",
  "kernels": ["linux"],
  "ntp": true,
  "timezone": "$TIMEZONE",
  "packages": $_packages_json,
  "services": ["NetworkManager"],
  "swap": { "enabled": true, "algorithm": "zstd" }
}
EOF
}

# Write user_credentials.json (SECRET) into $TMP_DIR with mode 0600. The
# password is piped to a python3 helper over stdin — never argv, never
# echoed, never logged. json.dumps provides correct escaping.
write_creds_json() {  # write_creds_json <username>
    cat > "$TMP_DIR/mkcreds.py" <<'PY'
import json, os, sys

creds_path = sys.argv[1]
username = sys.stdin.readline().rstrip('\n')
password = sys.stdin.readline().rstrip('\n')

creds = {
    # archinstall 4.4 legacy-but-supported plaintext keys; archinstall hashes
    # internally. Root stays locked (no root_enc_password / !root-password).
    "!users": [
        {
            "username": username,
            "!password": password,
            "sudo": True,
            "groups": [],
        }
    ],
}
fd = os.open(creds_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(creds, f, indent=2)
    f.write("\n")
PY
    printf '%s\n%s\n' "$1" "$TARGET_PASSWORD" | python3 "$TMP_DIR/mkcreds.py" "$TMP_DIR/user_credentials.json"
    # Scrub the shell's copy of the password immediately.
    TARGET_PASSWORD=''
    chmod 600 "$TMP_DIR/user_credentials.json" 2>/dev/null || true
}

# ---- archinstall run ----------------------------------------------------------

run_archinstall() {  # runs with --dry-run first (validation), then for real
    info ''
    info "Validating the generated configuration (archinstall --dry-run — touches nothing)..."
    set +e
    ( set -e
      archinstall --config "$TMP_DIR/user_configuration.json" \
                  --creds "$TMP_DIR/user_credentials.json" \
                  --silent --dry-run
    ) > "$TMP_DIR/dryrun.log" 2>&1
    _rc=$?
    set -e
    if [ "$_rc" -ne 0 ]; then
        tail -n 30 "$TMP_DIR/dryrun.log" >&2
        die "archinstall rejected the configuration (exit $_rc). Nothing was touched. This can happen if the disk geometry changed or an archinstall update altered the JSON schema — see the log above."
    fi

    info ''
    info "Installing OpenClaw Linux to $TARGET_DISK ..."
    info '  (this takes several minutes; archinstall output follows)'
    # Run in the background with a live tail so the user sees progress and we
    # still capture the full log for diagnostics.
    archinstall --config "$TMP_DIR/user_configuration.json" \
                --creds "$TMP_DIR/user_credentials.json" \
                --silent > "$TMP_DIR/install.log" 2>&1 &
    _pid=$!
    _RUN_PID=$_pid   # cleanup kills this if the user aborts (Ctrl+C)
    tail -n +1 -f "$TMP_DIR/install.log" &
    _tail_pid=$!
    set +e
    wait "$_pid"
    _rc=$?
    set -e
    _RUN_PID=''
    kill "$_tail_pid" 2>/dev/null || true
    wait "$_tail_pid" 2>/dev/null || true
    if [ "$_rc" -ne 0 ]; then
        info ''
        info 'Installation failed. Last archinstall output:'
        tail -n 60 "$TMP_DIR/install.log" >&2
        # Preserve the log outside the tmpdir (cleanup removes the tmpdir).
        cp "$TMP_DIR/install.log" /root/install-openclaw-archinstall.log 2>/dev/null || true
        die "archinstall exited with $_rc. Full log saved to /root/install-openclaw-archinstall.log."
    fi
    if ! findmnt -n /mnt >/dev/null 2>&1; then
        die 'archinstall reported success but /mnt is not mounted — cannot verify or stage the result. Do not reboot; inspect the state manually.'
    fi
    [ -f /mnt/etc/os-release ] || die 'archinstall finished but /mnt/etc/os-release is missing — the install did not land. Do not reboot.'
}

# ---- post-install: firstboot staging + verification ----------------------------

stage_firstboot() {
    info ''
    info 'Staging the appliance first-boot payload into the installed system...'
    _staged=0
    if [ -d /root/provision ] && [ -f /etc/systemd/system/openclaw-firstboot.service ]; then
        cp -a /root/provision /mnt/root/provision
        install -m 644 /etc/systemd/system/openclaw-firstboot.service \
            /mnt/etc/systemd/system/openclaw-firstboot.service
        if arch-chroot /mnt systemctl enable openclaw-firstboot.service >/dev/null 2>&1; then
            _staged=1
        else
            warn 'could not enable openclaw-firstboot.service in the installed system (staged files remain; enable manually: arch-chroot /mnt systemctl enable openclaw-firstboot.service).'
        fi
    else
        warn 'first-boot payload not found on this media (/root/provision or the unit file are missing) — skipping staging. The installed system still boots; run the wizard later from a repo checkout (provision/firstboot.sh).'
    fi

    # Verify the headline outcomes; each check fails loudly instead of
    # declaring a false success.
    [ -f /mnt/etc/os-release ] || die 'post-install verification failed: os-release missing.'
    arch-chroot /mnt id -u "$TARGET_USERNAME" >/dev/null 2>&1 \
        || die "post-install verification failed: user '$TARGET_USERNAME' was not created."
    if [ "$_staged" -eq 1 ]; then
        arch-chroot /mnt systemctl is-enabled openclaw-firstboot.service >/dev/null 2>&1 \
            || warn 'verification: openclaw-firstboot.service is not enabled (enable manually after reboot).'
    fi
    info 'Post-install verification passed (os-release present, user created).'
}

summary() {
    info ''
    info '=============================================================='
    info '  Installation complete.'
    info '=============================================================='
    info ''
    info "  Disk:      $TARGET_DISK (erased, fresh GPT: ESP + btrfs @ layout)"
    info "  Hostname:  $TARGET_HOSTNAME"
    info "  User:      $TARGET_USERNAME (sudo; root account locked)"
    info "  Locale:    $SYS_LANG.$SYS_ENC, kb $KB_LAYOUT, timezone $TIMEZONE"
    info "  Desktop:   Hyprland-family stack from the media package set"
    info "  Boot:      grub (UEFI) + efibootmgr entry"
    info '  First boot: the appliance wizard hook (openclaw-firstboot.'
    info '              service) is enabled; it needs the openclaw CLI and a'
    info '              logged-in desktop session, so run it by hand after'
    info '              first login if it did not run:'
    info '                sh /root/provision/firstboot.sh'
    info ''
    info '  Next steps: remove the install media, reboot, log in as'
    info "              '$TARGET_USERNAME'."
    info ''
    if [ -d /mnt/boot/grub ]; then
        info '  grub files verified on the installed system.'
    fi
}

# ---- --check mode (read-only) --------------------------------------------------

run_check() {
    info 'OpenClaw Linux installer — read-only system check'
    info ''
    info "Firmware mode : $(boot_mode)"
    if [ "$(boot_mode)" = 'bios' ]; then
        warn 'the guided installer supports UEFI targets only (BIOS/legacy installs: use interactive archinstall).'
    fi
    for _c in archinstall arch-chroot lsblk findmnt python3 systemctl; do
        if command -v "$_c" >/dev/null 2>&1; then
            info "Tool $_c      : present"
        else
            warn "Tool $_c      : MISSING"
        fi
    done
    if command -v archinstall >/dev/null 2>&1; then
        info "archinstall   : $(archinstall --version 2>/dev/null)"
    fi
    info ''
    if systemctl -q is-active NetworkManager 2>/dev/null; then
        _st=$(nmcli -t -f STATE g 2>/dev/null | head -n 1 || true)
        info "Networking    : NetworkManager active ($_st)"
    else
        warn 'Networking    : NetworkManager not running — the installer will start it.'
    fi
    _live=$(live_disk)
    if [ -n "$_live" ]; then
        info "Live media    : $_live (excluded from the target list)"
    fi
    info ''
    info 'Disk inventory (read-only probe; nothing mounted is modified):'
    collect_disks
    if [ ! -s "$DISK_LIST_FILE" ]; then
        info '  (no candidate disks found)'
    fi
    while IFS= read -r _d; do
        _class=$(classify_disk "$_d")
        case "$_class" in
            blank) _tag='blank' ;;
            used) _tag='partitions, no OS markers' ;;
            os) _tag='EXISTING OS DETECTED' ;;
        esac
        info ''
        info "  $_d — $_tag"
        disk_report "$_d"
    done < "$DISK_LIST_FILE"
    info ''
    info 'Check finished. Nothing was changed.'
}

# ---- main ----------------------------------------------------------------------

main() {
    case "${1:-}" in
        --check)
            TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/openclaw-install.XXXXXX") || die 'cannot create tmpdir.'
            chmod 700 "$TMP_DIR"
            need_root
            need_cmds lsblk findmnt sed grep tail head python3
            run_check
            exit 0
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        '')
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac

    need_root
    need_cmds archinstall arch-chroot lsblk findmnt uuidgen python3 systemctl tail sed grep

    if [ "$(boot_mode)" != 'uefi' ]; then
        die 'this guided installer supports UEFI targets only. For BIOS/legacy machines run the interactive installer: archinstall (the media ships it).'
    fi

    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/openclaw-install.XXXXXX") || die 'cannot create tmpdir.'
    chmod 700 "$TMP_DIR"

    info '=============================================================='
    info '  OpenClaw Linux — guided install-to-disk (issue #22)'
    info '=============================================================='
    info ''
    info "Firmware mode: $(boot_mode) (UEFI install; grub bootloader)"
    info ''

    start_live_networking

    info 'Scanning disks (the install media itself is excluded)...'
    collect_disks

    pick_disk
    _class=$(classify_disk "$TARGET_DISK")
    _size_mib=$(disk_size_mib "$TARGET_DISK")
    if [ "$_size_mib" -lt "$MIN_DISK_MIB" ]; then
        die "$TARGET_DISK is only ${_size_mib} MiB — the installer refuses disks under $MIN_DISK_MIB MiB."
    fi
    if [ "$_size_mib" -lt "$WARN_DISK_MIB" ]; then
        warn "disk is ${_size_mib} MiB — small for a desktop appliance (recommended >= $WARN_DISK_MIB MiB)."
    fi
    confirm_erase "$TARGET_DISK" "$_class"

    info ''
    info 'System identity'
    info '---------------'
    prompt_hostname
    prompt_username
    prompt_passwords

    info ''
    info 'Preparing archinstall configuration...'
    write_config_json "$TARGET_DISK" "$_size_mib"
    write_creds_json "$TARGET_USERNAME"
    if ! python3 -m json.tool "$TMP_DIR/user_configuration.json" >/dev/null 2>&1; then
        die 'internal error: generated configuration JSON is invalid.'
    fi
    if ! python3 -m json.tool "$TMP_DIR/user_credentials.json" >/dev/null 2>&1; then
        die 'internal error: generated credentials JSON is invalid.'
    fi

    run_archinstall
    stage_firstboot
    summary

    info ''
    printf 'Remove the install media now, then press Enter to reboot (or Ctrl+C to stay here): '
    if read_line; then
        info 'Rebooting...'
        systemctl reboot
    fi
    info 'Not rebooting. When ready: remove the media and run: systemctl reboot'
    exit 0
}

main "$@"
