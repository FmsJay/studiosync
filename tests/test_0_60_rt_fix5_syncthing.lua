-- rt-fix5 item 4 (2026-11-21): LinuxBox's Live sync said "Syncthing didn't answer (is it running, with a folder called ...)" at every start
-- (124 times on 11-20) and "couldn't stop syncing with ...": every waited `syncthing cli` went to REAPER's ExecProcess as
-- `"/usr/bin/syncthing" cli ...`, and none answered, while the same command answered in a shell (with REAPER's own environment, checked over
-- SSH) and through StudioSync's background script (the computer's ID). Outside Windows a waited command now goes through a script file
-- run by /bin/sh, as the background, Tailscale and REST calls already did (lib/services.lua via_sh), with paths in the shell's single quotes.
-- The lookup itself is offline here: no Syncthing, no shell. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local gext, exists, calls, scripts = {}, { ["/usr/bin/syncthing"] = true }, {}, {}
reaper = setmetatable({
  GetOS = function() return "Other" end, -- (REAPER's word on Linux)
  time_precise = function() return 100 end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  file_exists = function(p) return exists[p] == true end,
  GetResourcePath = function() return "/home/studio/REAPER" end,
}, { __index = function() return function() end end })
local band = require("band")
assert(band.LINUX, "(the test runs as Linux)")
band.write_atomic = function(path, text) scripts[path] = text; return true end
band.bands = function() return {} end
band.log = function() end
local services = require("services")
local ask = services.TMP .. "/bandsync-ask.sh"
local answers = { ["fswatcher-enabled get"] = "true", ["fswatcher-delays get"] = "1", ["fswatcher-timeouts get"] = "2", ["versioning type get"] = "staggered",
  ["label get"] = "StudioSync Smiley Studios" }
reaper.ExecProcess = function(cmd)
  calls[#calls + 1] = { cmd = cmd, script = scripts[ask] }
  local body = scripts[ask] or ""
  for k, v in pairs(answers) do if body:find(" " .. k .. "\n", 1, true) then return "0\n" .. v .. "\n" end end
  return "0\n"
end

-- the lookup: the absolute path, wherever REAPER's PATH points (nothing set in ExtState)
assert(services.find_syncthing() == "/usr/bin/syncthing", "Syncthing found at its absolute path: " .. tostring(services.find_syncthing()))
exists["/usr/bin/syncthing"], exists[(os.getenv("HOME") or "~") .. "/.local/bin/syncthing"] = nil, true
assert(services.find_syncthing() == (os.getenv("HOME") or "~") .. "/.local/bin/syncthing", "or the installer's own copy in ~/.local/bin")
exists = { ["/usr/bin/syncthing"] = true }

-- the folder tuned: every Syncthing call through /bin/sh and a script, never REAPER's own command line parsing
local set, err = services.tune_band_folder("studiosync-smiley-studios-a963")
assert(set, "tuned (it said: " .. tostring(err) .. ")")
assert(#set == 0, "everything already as wanted: nothing set")
assert(#calls >= 4, "the watcher settings, versioning, devices and label asked")
for _, c in ipairs(calls) do
  assert(c.cmd == "/bin/sh '" .. ask .. "'", "a waited command goes through /bin/sh and a script file: " .. c.cmd)
  assert(c.script:find("\n'/usr/bin/syncthing' cli config ", 1, true), "the script runs Syncthing at its absolute path, in single quotes: " .. c.script)
end
assert(calls[1].script:find('^rm %-f "%$0"\n'), "the script deletes itself once read")
-- a settings folder with a quote in its path (the installer's --home): still one argument for the shell
gext["BandSync\0syncthing_home"] = "/home/o'brien/st"
calls = {}
services.tune_band_folder("studiosync-smiley-studios-a963")
assert(calls[1].script:find("'/usr/bin/syncthing' cli --home '/home/o'\\''brien/st' config", 1, true), "a quote in a path is the shell's '\\'': " .. calls[1].script)

print("ok rt-fix5 Syncthing's command line on Linux")
