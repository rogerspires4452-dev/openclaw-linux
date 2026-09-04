#!/bin/sh
# Installs the "OpenClaw Dashboard" app-mode launcher (tested on Omarchy/Arch 2026-09-03).
set -e
mkdir -p "${HOME}/.local/share/applications"
cat > "${HOME}/.local/share/applications/openclaw-dashboard.desktop" << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=OpenClaw Dashboard
Comment=Control UI in lightweight app mode (no tabs)
Exec=/usr/bin/chromium --app=http://127.0.0.1:18789 --class=openclaw-dash
Icon=chromium
Terminal=false
Categories=Network;
StartupWMClass=openclaw-dash
DESKTOP
chmod +x "${HOME}/.local/share/applications/openclaw-dashboard.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "${HOME}/.local/share/applications"
echo "Installed OpenClaw Dashboard launcher."
