-- Minimal Hyprland config for the SDDM Wayland greeter.
-- SDDM starts the greeter itself after the compositor is ready.
--
-- Derived from Omarchy's /usr/share/sddm/hyprland.lua
-- (github.com/omacom/omarchy, MIT) which runs the identical hyprland
-- release on the reference host; kept byte-equivalent in behavior.
hl.config({
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
  },

  animations = {
    enabled = false,
  },
})
