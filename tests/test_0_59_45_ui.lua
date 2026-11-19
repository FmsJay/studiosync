-- 0.59.45 (Round 1 review, UI and Live sync side): Sync and exit's words, who counts as having the project, the auto-save rule, driving by
-- mode, Linux call apps and terminals, the Mac's REAPER however its bundle is named. Pure parts only (lupa or any Lua 5.4, from the repo root).
package.path = "lib/?.lua;" .. package.path
reaper = setmetatable({ time_precise = function() return 0 end, GetExtState = function() return "" end, SetExtState = function() end,
  file_exists = function() return false end }, { __index = function() return function() return "" end end })
for _, m in ipairs({ "band", "leave", "live", "callapps", "pack", "startup" }) do package.loaded[m] = nil end
local leave, live = require("leave"), require("live")
local function has(lines, words) for _, l in ipairs(lines) do if l:find(words, 1, true) then return true end end end

-- Sync and exit's last words (leave.finish)
local lines, shut = leave.finish({ kept_held = true, holders = { "Bob" } })
assert(has(lines, "Everything else is with Bob."), "Keep holding: everything else is with them, not everything")
assert(shut == "Safe to shut down. What you're holding is saved in this project and goes out when you switch Hold my changes off.",
  "Keep holding alone is safe: leaving the computer on never sends held work. Got: " .. tostring(shut))
lines, shut = leave.finish({ holders = { "Bob", "Cal" } })
assert(has(lines, "Everything is with Bob, Cal.") and shut == "Safe to shut down.", "all out: safe, in those words")
lines, shut = leave.finish({ stopped = "send", words = "Sending your changes" })
assert(shut == "Keep this project open: your changes are still being sent.", "Stop waiting mid-send: quitting REAPER stops the sending")
lines, shut = leave.finish({ stopped = "send", sync_off = true })
assert(has(lines, "Live sync isn't running") and shut:find("^Not safe to shut down yet"), "Live sync off: not safe, and how to start it")
assert(not shut:find("press Start", 1, true), "no Start button to press: the pill")
lines, shut = leave.finish({ stopped = "syncthing", words = "Sending 2.0 MB to Bob" })
assert(shut == leave.NOT_SAFE, "Stop waiting while Syncthing hands over: leave the computer on")
lines, shut = leave.finish({ drove = true, drive_left = true, kept_held = true, drive = "Dropbox" })
assert(shut == leave.NOT_SAFE and has(lines, "Dropbox has some of it") and has(lines, "What you're holding is saved"), "cloud copy still going: not safe, held work said")
lines, shut = leave.finish({ drove = true, drive = "Dropbox" })
assert(shut == "Safe to shut down." and has(lines, "Dropbox has it"), "the service's own name, not Google Drive")
lines, shut = leave.finish({})
assert(shut == nil and has(lines, "has no cloud copy here"), "nobody online, no cloud copy: no safe line")
lines = leave.finish({ need = 3 * 1048576, holders = { "Bob" } })
assert(has(lines, "3.0 MB on its way to you"), "what's still coming in")

-- Who counts as having it (leave.holders): a fresh holds list that names the song
local age = function(t) return t == "fresh" and 10 or 10 * 86400 end
local lists = { { user = "bob", time = "fresh", songs = { Song = {} } }, { user = "Cal", time = "old", songs = { Song = {} } },
  { user = "Dee", time = "fresh", songs = { Other = {} } } }
local h = leave.holders({ "Bob", "Cal", "Dee", "Eve" }, lists, "Song", 3 * 86400, age)
assert(#h == 1 and h[1] == "Bob", "only Bob: Cal's list is stale, Dee's doesn't name it, Eve has none (got " .. table.concat(h, ",") .. ")")

-- Auto-save after 100 received changes (leave.autosave): only when nothing unsaved was yours before the batch
local st = {}
assert(not leave.autosave(st, 60, false, true) and not leave.autosave(st, 50, true, true), "no save while it's coming in")
assert(not leave.autosave(st, 0, false, false), "not while playing")
assert(leave.autosave(st, 0, false, true), "a clean project before the batch: saved once it's over")
assert(not leave.autosave(st, 0, false, true), "once")
st = {}
leave.autosave(st, 120, true, true)
assert(not leave.autosave(st, 0, false, true), "unsaved work of yours before the batch: never saved for you")
leave.autosave(st, 120, false, true)
st.clean = false -- (Live sync: something of yours went out meanwhile)
assert(not leave.autosave(st, 0, false, true), "your own change during the batch: not saved")
st = {}
leave.autosave(st, 40, false, true)
assert(not leave.autosave(st, 0, false, true), "under 100: no save")

-- Driving, said by mode (live.DRIVING), for every mode Who controls offers
for _, m in ipairs(live.MODE_INFO) do
  local d = live.DRIVING[m[1]]
  assert(d and d.take and d.away and d.lost, "what driving means in " .. m[1])
  assert(d.away:match("^[,:] "), "the away words follow \"X is driving but isn't here\": " .. m[1])
end
assert(not live.driving("open").away:find("claimed", 1, true), "the default mode doesn't say only claimed tracks can change")
assert(live.driving("nonsense") == live.DRIVING.open, "an unknown mode reads as the default")
for k, v in pairs(live.PLACES) do assert(type(v) == "string" and v ~= "", "a place: " .. k) end
assert(not live.PLACES.cant_hear:find("Advanced", 1, true), "Can't hear each other? is under Health")

-- Linux: call apps by their own process names, and REAPER on ALSA holds the card
local callapps = require("callapps")
local found = callapps.in_list("\nbash\nzoom\nteams-for-linux\nskypeforlinux\n", false, true)
assert(table.concat(found, ",") == "Skype,Teams,Zoom", "Linux's names: " .. table.concat(found, ","))
assert(#callapps.in_list("\nzoom\n", false, false) == 0, "a Mac's Zoom is zoom.us")
assert(callapps.holds_device("ALSA", false, false, true) and not callapps.holds_device("JACK", false, false, true)
  and not callapps.holds_device("PulseAudio", false, false, true), "ALSA holds the card; JACK and PulseAudio share")

-- Linux terminals: the first one that's there, ptyxis and kgx included
local pack = require("pack")
assert(pack.terminal(function(n) return n == "kgx" or n == "xterm" end, "'s'") == "kgx -- bash 's'", "kgx before xterm")
assert(pack.terminal(function(n) return n == "ptyxis" end, "'s'") == "ptyxis -- bash 's'", "ptyxis")
assert(pack.terminal(function() return false end, "'s'") == nil, "none: nil, so it says so")

-- The Mac's REAPER, however the bundle is named (startup.reaper_exe), and the hand-over using it
local startup = require("startup")
local files = { ["/Applications/REAPER 7.app/Contents/MacOS/REAPER"] = true }
local exists = function(p) return files[p] == true end
local subdirs = function() return { "Mail.app", "REAPER 7.app" } end
assert(startup.reaper_exe("OSX64", "/Applications", exists, subdirs) == "/Applications/REAPER 7.app/Contents/MacOS/REAPER", "a renamed bundle")
files = { ["/Applications/REAPER64.app/Contents/MacOS/REAPER"] = true }
assert(startup.reaper_exe("macOS-arm64", "/Applications/", exists, subdirs) == "/Applications/REAPER64.app/Contents/MacOS/REAPER", "REAPER64.app")
assert(startup.reaper_exe("OSX64", "/Applications", function() return false end, subdirs) == nil, "none: nil, so the 20 s wait is skipped")
assert(startup.hand_over("OSX64", "/Applications", "/a.rpp", "/X/REAPER") == '"/X/REAPER" -nonewinst -ignoreerrors "/a.rpp"', "the one found")
print("ok")
