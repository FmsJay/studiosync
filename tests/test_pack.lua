-- 0.59.22 (lupa or Lua 5.4, from the repo root): the plug-in pack's matching, and the scripts Get writes, per system.
package.path = "lib/?.lua;" .. package.path
local os_name, res = "Win64", "C:/Users/Bob's PC/AppData/Roaming/REAPER 100%"
reaper = { GetOS = function() return os_name end, GetExtState = function() return "" end, GetResourcePath = function() return res end }
for _, m in ipairs({ "band", "plugins", "pack" }) do package.loaded[m] = nil end
local band = require("band")
local pack = require("pack")
local function item(n) for _, it in ipairs(pack.ITEMS) do if it[1] == n then return it end end end
-- the names REAPER's plug-in lists really have (published lists from the studio)
local keys = { ["surge xt (surge synth team)"] = true, ["surge xt effects (surge synth team)"] = true, ["dragonfly hall reverb (michael willis and rob vd berg)"] = true,
  ["jexed fm synth (dexed port) by chmaha"] = true, ["odin2 (thewavewarden)"] = true }
assert(pack.has(keys, item("Surge XT")), "Surge XT")
assert(pack.has(keys, item("Dragonfly Reverb")), "Dragonfly, by any of its reverbs")
assert(pack.has(keys, item("Odin 2")), "Odin 2")
assert(not pack.has(keys, item("Dexed")), "chmaha's Jexed isn't Dexed")
assert(not pack.has(keys, item("OB-Xf")), "nor anything missing")
local n_pack, n_extra = 0, 0
for _, it in ipairs(pack.ITEMS) do if it[4] then n_extra = n_extra + 1 else n_pack = n_pack + 1 end end
assert(n_pack == 11 and n_extra == 8, "11 in the pack, 8 extras: " .. n_pack .. " " .. n_extra)
-- Windows: a .cmd that runs this release's installer, plug-ins only, for this REAPER (its ' and % kept as they are)
band.VERSION = "9.9.9"
local name, text = pack.script(true, true)
assert(name == "Get plug-ins.cmd", name)
assert(text:find("/v9.9.9/installer/install_windows.ps1", 1, true), "this release's installer")
assert(text:find("-PluginsOnly -ResPath 'C:\\Users\\Bob''s PC\\AppData\\Roaming\\REAPER 100%%' -Extras yes -NoApps", 1, true), "its folder, quoted for PowerShell and cmd")
assert(text:find("\r\n", 1, true) and text:find("chcp 65001", 1, true), "a .cmd, UTF-8")
local _, plain = pack.script(false)
assert(plain:find("-Extras no\"", 1, true), "the pack alone, no test switch")
-- Mac: a .command piping this release's Mac installer into bash, plug-ins only
os_name = "OSX64"
for _, m in ipairs({ "band", "plugins", "pack" }) do package.loaded[m] = nil end
band = require("band"); band.VERSION = "9.9.9"; pack = require("pack")
name, text = pack.script(true)
assert(name == "Get plug-ins.command", name)
assert(text:find("^#!/bin/bash\n") and text:find("'https://raw.githubusercontent.com/FmsJay/studiosync/v9.9.9/installer/install_mac.sh' | BS_PLUGINS_ONLY=1 BS_EXTRAS=y bash", 1, true), text)
-- Linux
os_name = "Other"
for _, m in ipairs({ "band", "plugins", "pack" }) do package.loaded[m] = nil end
band = require("band"); band.VERSION = "9.9.9"; pack = require("pack")
name, text = pack.script(false)
assert(name == "get-plugins.sh" and text:find("install_linux.sh' | BS_PLUGINS_ONLY=1 BS_EXTRAS=n bash", 1, true), text)
print("ok")
