-- Flux window and keybinding for Omarchy. Copy these lines into
-- ~/.config/hypr/hyprland.lua, or load this file from it.
-- flux-gui has the app id "flux". The omarchy-shell plugin window has the
-- Quickshell app id and the title "Flux".
o.window("^flux$", { float = true, center = true, size = { 1180, 760 } })
o.window({ class = "^org\\.quickshell$", title = "^Flux$" }, { float = true, center = true, size = { 1180, 760 } })
-- The phone screen mirror window has the app id "flux-screen".
o.window("^flux-screen$", { float = true, center = true })
o.bind("SUPER + ALT + P", "Flux", { launch = "flux open" })
