#!/usr/bin/env bash
# shellcheck disable=SC2034

# OpenClaw Linux archiso profile definition (releng-style; bootmode names per
# archiso 90). This file is sourced by mkarchiso (bash), not executed
# directly; variables here are consumed by mkarchiso's build pipeline.

# Name and versioning (SOURCE_DATE_EPOCH-aware so rebuilds are reproducible).
iso_name="openclaw-linux"
iso_label="OPENCLAW_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="OpenClaw Linux <https://github.com/rogerspires4452-dev/openclaw-linux>"
iso_application="OpenClaw Linux appliance - live/install media"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="openclaw"
arch="x86_64"

# What mkarchiso produces: a single hybrid ISO bootable on BIOS (syslinux)
# and UEFI (systemd-boot). Bootloader configs live in syslinux/, efiboot/;
# grub/loopback.cfg additionally lets the ISO boot from an existing GRUB.
buildmodes=('iso')
bootmodes=('bios.syslinux'
           'uefi.systemd-boot')

# Build-time config
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15')

# Files in airootfs/ that need explicit modes beyond the default. mkarchiso
# copies the airootfs overlay with --no-preserve=mode, so this list is the
# only thing that keeps executables executable inside the image.
file_permissions=(
  ["/root"]="0:0:750"
  ["/root/install-openclaw.sh"]="0:0:755"
  ["/root/provision"]="0:0:750"
  ["/root/provision/backup.sh"]="0:0:755"
  ["/root/provision/firstboot.sh"]="0:0:755"
  ["/root/provision/install-dashboard-launcher.sh"]="0:0:755"
  ["/root/provision/update.sh"]="0:0:755"
  ["/root/provision/steps/10-gateway.sh"]="0:0:755"
  ["/root/provision/steps/20-model-key.sh"]="0:0:755"
  ["/root/provision/steps/30-telegram.sh"]="0:0:755"
  ["/root/provision/steps/40-dashboard.sh"]="0:0:755"
  ["/root/provision/steps/50-channel.sh"]="0:0:755"
)
