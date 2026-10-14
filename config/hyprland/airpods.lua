-- AirPods (LibrePods) for Hyprland ≥ 0.55 (Lua config).
-- Save as ~/.config/hypr/conf/airpods.lua and add  require("conf.airpods")
-- to hyprland.lua — or paste the parts you want into your own files.

local pods = os.getenv("HOME") .. "/.local/bin/librepods ctl "

-- ── Autostart ───────────────────────────────────────────────────────────────
-- A systemd user service (restarts if it crashes). It needs the Wayland
-- session's environment, which is why the compositor starts it.
hl.on("hyprland.start", function()
    hl.exec_cmd("systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE"
        .. " && systemctl --user restart librepods.service")
end)

-- ── Keybinds ────────────────────────────────────────────────────────────────
local exec = hl.dsp.exec_cmd
hl.bind("SUPER + ALT + A",         exec(pods .. "mode next"),        { description = "AirPods: next listening mode" })
hl.bind("SUPER + ALT + SHIFT + A", exec(pods .. "toggle"),           { description = "AirPods: connect / disconnect" })
hl.bind("SUPER + ALT + C",         exec(pods .. "ca toggle"),        { description = "AirPods: Conversation Awareness on / off" })
hl.bind("SUPER + ALT + P",         exec(pods .. "popup"),            { description = "AirPods: show battery card" })
hl.bind("SUPER + CTRL + A",        exec(pods .. "open"),             { description = "AirPods settings" })
hl.bind("SUPER + ALT + B",         exec(pods .. "bluetooth toggle"), { description = "Bluetooth on / off" })

-- ── Rules ───────────────────────────────────────────────────────────────────
-- settings window floats like a macOS System Settings pane
hl.window_rule({
    name   = "librepods-window",
    match  = { class = "^(librepods|LibrePods|me\\.kavishdevar\\.librepods)$" },
    float  = true,
    center = true,
    size   = { "monitor_w*0.55", "monitor_h*0.75" },
})
-- frosted glass behind the bar dropdown and the case card (they animate themselves)
hl.layer_rule({ name = "librepods-menu", match = { namespace = "^(librepods-menu)$" },  blur = true, ignore_alpha = 0.3, no_anim = true })
hl.layer_rule({ name = "librepods-card", match = { namespace = "^(librepods-popup)$" }, blur = true, ignore_alpha = 0.3, no_anim = true })
