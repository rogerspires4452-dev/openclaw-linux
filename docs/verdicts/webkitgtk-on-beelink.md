# Verdict: WebKitGTK does not paint on beelink (2026-09-03)

Tested: companion AppImage, extracted binary, native cargo build of apps/linux,
webkit 2.52.6 / 2.52.5 / 2.50.6, real GPU and llvmpipe, X11 and Wayland.
Result: every WebKitGTK webview renders blank. Distro MiniBrowser is blank too.
GTK window chrome renders fine; web *content* never paints. Chromium works
(own engine). Ubuntu VM renders the same app perfectly.

Conclusion: system-level Arch webkit2gtk-4.1 userland defect on this box, not
app or hardware. Do NOT build UI on WebKitGTK here. Use Chromium app-mode or
native GTK/Qt clients.
