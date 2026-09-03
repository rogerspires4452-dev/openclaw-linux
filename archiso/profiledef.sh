#!/usr/bin/env bash
# shellcheck disable=SC2034

# OpenClaw Linux archiso profile definition (releng-style, skeleton state).
#
# NOTE: this profile is NOT buildable yet. mkarchiso also needs bootloader
# config (grub/, syslinux/ and/or efiboot/ directories) before the bootmodes
# below can be enabled — that is tracked in archiso/README.md as a TODO.
#
# Keep this file sourced by mkarchiso (bash), not executed directly.

set -e

# Name and versioning
iso_name="openclaw-linux"
iso_label="OPENCLAW_$(date +%Y%m)"
iso_publisher="OpenClaw Linux <https://github.com/rogerspires4452-dev/openclaw-linux>"
iso_application="OpenClaw Linux appliance - live/install media"
iso_version="$(date +%Y.%m.%d)"
install_dir="openclaw"
arch="x86_64"

# What mkarchiso produces: a single hybrid ISO. Bootloader config dirs are a
# TODO, so bootmodes stay commented out until grub/efiboot are added.
buildmodes=('iso')
# bootmodes=('bios.syslinux.mbr' 'bios.syslinux.eltorito'
#            'uefi-x64.systemd-boot.esp' 'uefi-x64.systemd-boot.eltorito')

# Build-time config
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')

# Files in airootfs/ that need explicit modes beyond the default.
file_permissions=(
  ["/root/customize_airootfs.sh"]="0:0:755"
)
