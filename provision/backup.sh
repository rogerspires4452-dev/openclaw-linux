#!/bin/sh
# provision/backup.sh — pre-update backup with verification and checksum.
# Usage: backup.sh [TARGET_DIR]      (default: ~/Backups)
#
# Runs `openclaw backup create --verify` into TARGET_DIR, then prints the
# archive path and its sha256 checksum. Exits non-zero if anything fails.
# Encodes docs/runbooks/update-and-backup.md. No secrets are read or embedded.
set -e

if ! command -v openclaw >/dev/null 2>&1; then
    echo "backup.sh: openclaw CLI not found in PATH" >&2
    exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
    echo "backup.sh: sha256sum not found in PATH" >&2
    exit 1
fi

target=${1:-"$HOME/Backups"}
mkdir -p "$target"
# Resolve to an absolute path so the printed path and checksum are unambiguous.
# The empty CDPATH assignment keeps a relative target from resolving through
# CDPATH (which would echo the resolved dir into the captured path).
# shellcheck disable=SC1007
target=$(CDPATH= cd -- "$target" && pwd)

echo "Creating verified OpenClaw backup in: $target"
openclaw backup create --output "$target" --verify

# Archives are timestamped <iso8601>-openclaw-backup.tar.gz and existing files
# are never overwritten, so the newest match is the archive we just created.
# The glob already constrains matches to our own archive names.
# shellcheck disable=SC2012
archive=$(ls -t "$target"/*-openclaw-backup.tar.gz 2>/dev/null | head -n 1 || true)
if [ -z "$archive" ] || [ ! -f "$archive" ]; then
    echo "backup.sh: backup succeeded but no archive was found in $target" >&2
    exit 1
fi

checksum=$(sha256sum "$archive" | awk '{print $1}')
if [ -z "$checksum" ]; then
    echo "backup.sh: failed to compute sha256 checksum for $archive" >&2
    exit 1
fi

echo
echo "Backup archive: $archive"
echo "SHA256: $checksum"
