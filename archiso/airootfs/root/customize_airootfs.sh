#!/bin/sh
# customize_airootfs.sh — placeholder first-boot hook (archiso/releng style).
#
# archiso executes this script on every boot of the produced live media,
# after the airootfs (the ISO's root filesystem, built from this directory)
# has been set up. It is the canonical hook point for one-shot customization.
#
# Skeleton state: this is a placeholder only. The real integration — running
# the repo's provision/ scripts (see README.md at the repo root) so a booted
# appliance self-provisions its OpenClaw gateway, dashboard launcher, and
# first-boot pairing flow — is NOT wired up yet. See archiso/README.md, TODO.
set -e

# TODO(issue #3 follow-up): provision/ integration.
# Intended shape, once designed:
#   1. Stage the provision payload (repo provision/*.sh) somewhere stable
#      inside the live root, e.g. /opt/openclaw/provision/.
#   2. For an install-to-disk flow, copy that payload into the installed
#      root and arm a first-boot oneshot (e.g. openclaw-firstboot.service)
#      so provisioning runs once on the installed appliance, not the ISO.
# Nothing below does that yet — this script must stay safe to run as-is.

echo "openclaw-linux: customize_airootfs.sh placeholder ran (provision integration is a TODO)."
