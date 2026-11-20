-- rt-prune (docs/rt/rt-audit.md's five clear wins, James 2026-11-20: "things we don't need any more go"). With a stand-in REAPER:
-- 1. the studio's own live audio on hides every SonoBus path (Home's My time / Their time, Chat > Call's SonoBus call, Health's row, Set up
--    everything, Prepare) and shows them when it's off; SonoBus still on beside it is said once, with a way off.
-- 2. Home's in-time way is the built-in "In time (NINJAM style)": on, off and a reopened project.
-- 3. the old words (web Play page, call-app help, project-open log line).
-- 4. "While you were away" and the credits count takes from item events, as the session recap does; old take manifests still count.
-- 5. "Render prints in the background" is gone: the per-computer default rules, a saved choice is dropped silently.
package.path = "lib/?.lua;" .. package.path
local gext, pext, deleted, ext_ok = {}, {}, {}, true
local os_name = "Win64"
local function audio_api(on)
  for _, f in ipairs({ "Start", "Stop", "Peers", "Status", "PeerSet" }) do reaper["StudioSync_LiveAudio" .. f] = on and function() end or nil end
end
reaper = setmetatable({
  time_precise = function() return 1000 end,
  GetOS = function() return os_name end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k, persist) gext[s .. "\0" .. k] = nil; deleted[#deleted + 1] = { k, persist } end,
  GetProjExtState = function(_, _, k) return 1, pext[k] or "" end,
  SetProjExtState = function(_, _, k, v) pext[k] = v end,
  file_exists = function() return false end,
  GetExePath = function() return "C:/REAPER" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
local logged = {}
band.log = function(t) logged[#logged + 1] = t end
local live_on = { on = true, off = false }
package.loaded.groups = { live_audio = function(root) return live_on[root] end }
local live = require("live")
local S = band.SECTION
local function src(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return (s:gsub("\r\n", "\n")) end

-- ---- 1. built-in live audio here, or not ----
audio_api(true)
assert(live.builtin_audio("on") == true, "on for the studio, the extension has it: built in")
assert(not live.builtin_audio("off"), "off for the studio: SonoBus as before")
assert(not live.builtin_audio(nil), "no studio: not built in")
audio_api(false)
assert(not live.builtin_audio("on"), "an extension without live audio: SonoBus stays offered, or there'd be nothing")
audio_api(true)

-- Home's ways
local KINDS = { { "my", sonobus = true }, { "their", sonobus = true }, { "intime" } }
local function ids(list) local t = {}; for i, k in ipairs(list) do t[i] = k[1] end; return table.concat(t, ",") end
assert(ids(live.offered(KINDS, true, nil)) == "intime", "live audio on: only In time")
assert(ids(live.offered(KINDS, false, nil)) == "my,their,intime", "live audio off: all three, as before")
assert(ids(live.offered(KINDS, true, "their")) == "their,intime", "Their time still on: shown, so it can be turned off")
local panel = src("StudioSync - Panel.lua")
assert(panel:find('{ "my", "My time", [^\n]*sonobus = true }') and panel:find('{ "their", "Their time", [^\n]*sonobus = true }'), "the panel marks SonoBus's ways")
assert(panel:find("ipairs(live.offered(RT_KINDS, builtin, kind))", 1, true), "Home lists the offered ways")
assert(not panel:find('"Time-sync (recommended)"', 1, true) and panel:find('"In time (NINJAM style)", "Recommended.', 1, true), "Home recommends the built-in In time")
assert(panel:find("Show the Play/Jam tab (outside NINJAM server)", 1, true), "the outside path stays under Settings, labelled")
-- Chat > Call: SonoBus's Join the call (and its Pop out, its mic and volumes, all under it) only without live audio or while it's on
assert(panel:find("local sb_call = on or not live.builtin_audio(cfg.root)", 1, true), "the call's SonoBus switch guarded")
local call_tab = panel:match("function ui%.call_tab%(%)(.-)\nend\n")
assert(call_tab and call_tab:find("if sb_call then\n  ImGui.BeginDisabled", 1, true) and call_tab:find("elseif sb_call then", 1, true), "Join the call and its words hidden with live audio")
assert(panel:find("function ui.settings_buffer()\n  if live.builtin_audio(cfg.root) then return end", 1, true), "SonoBus's buffer card hidden with live audio")

-- twice: said once, with a way off
assert(live.twice_note("P", false, true) == nil and live.twice_note("P", true, false) == nil, "only both at once")
local n0 = #logged
local t = live.twice_note("P", true, true)
assert(t and t:find("hears you twice"), "both on: said")
assert(live.twice_note("P", true, true) == t and #logged == n0 + 1 and logged[#logged]:find("Turn SonoBus off"), "logged once per tab")
assert(panel:find('ImGui.SmallButton(ctx, "Turn SonoBus off##sbtwice")', 1, true), "Home offers to turn SonoBus off")

-- Set up everything I can
package.loaded.services = { ensure_syncthing = function() return true end }
package.loaded.setup = nil
local setup = require("setup")
local added = 0
setup.sonobus = function() added = added + 1; return "sonobus://x" end
local st = { folder = true, sync = true, sonobus = false }
local notes = setup.all({ root = "on" }, {}, "P", st, function() end, false)
assert(added == 0 and #notes == 0, "live audio on: SonoBus isn't added")
notes = setup.all({ root = "off" }, {}, "P", st, function() end, false)
assert(added == 1 and notes[1]:find("SonoBus added"), "live audio off: added, as before")
-- Health's row and the button's words, Prepare's checklist
local health = src("lib/page_health.lua")
assert(not health:find('    { "sonobus", s.sonobus', 1, true), "not in the fixed rows")
assert(health:find('if not require("live").builtin_audio(cfg.root) then -- (SonoBus: only for studios whose own live audio is off. rt-audit §1)\n    rows[#rows + 1] = { "sonobus"', 1, true), "Health's SonoBus row only without live audio")
assert(health:find('builtin_audio(cfg.root) and "Starts Syncthing and Live sync. The rest needs you."', 1, true), "Set up everything doesn't promise SonoBus")
assert(src("lib/prep.lua"):find('b.role ~= "solo" and not live.builtin_audio(cfg and cfg.root) and not live.fx(proj, false, live.SONOBUS)', 1, true), "Prepare: no SonoBus with live audio")

-- ---- 2. In time, built in ----
package.loaded.direct = package.loaded.direct or {}
local streams = require("streams")
live.ninjam_master = function() return false end
pext.side = "3"
assert(not streams.in_time_on("P"), "off to start")
streams.set_in_time("P", true)
assert(gext[S .. "\0stream listen"] == "in_time" and pext.side == "1" and pext["side before timesync"] == "3", "on: in-time listening, following at its bars, the old bars kept")
assert(streams.in_time_on("P"), "on")
live.ninjam_master = function() return true end
assert(not streams.in_time_on("P"), "ReaNINJAM on the master: that's Time-sync, not In time")
live.ninjam_master = function() return false end
streams.set_in_time("P", false)
assert(pext.side == "3" and pext["side before timesync"] == "" and not streams.in_time_on("P"), "off: the bars behind as they were")
pext.side = ""
streams.set_in_time("P", true)
assert(pext["side before timesync"] == "none", "following nobody before: none")
streams.set_in_time("P", false)
assert(pext.side == "", "off: not following again")
assert(src("StudioSync - Live sync.lua"):find('or (require("streams").in_time_on(proj) and "ts")', 1, true), "the clock icon for bandmates")

-- ---- 3. the old words ----
local play = src("lib/webui/play.js")
assert(not play:find("connect on the panel’s Play/Jam page", 1, true) and play:find("s.liveaudio ?", 1, true), "web Play: the studio's live audio")
local webpages = require("webpages")
assert(webpages.play_model({ side = "", cursor = "1", liveaudio = true }).liveaudio == true, "the play topic says so")
assert(webpages.play_model({ side = "", cursor = "1" }).liveaudio == nil, "and not when off")
local sync_src = src("StudioSync - Live sync.lua")
assert(not sync_src:find("live audio starts off when a project opens", 1, true) and sync_src:find("SonoBus and ReaNINJAM start off when a project opens", 1, true), "project-open log line")
package.loaded.services = { background = function() return "" end }
local callapps = require("callapps")
local shown
local ImGui = setmetatable({ TextWrapped = function(_, s) shown[#shown + 1] = s end, SmallButton = function(_, s) shown[#shown + 1] = "[" .. s .. "]"; return false end },
  { __index = function() return function() end end })
shown = {}
callapps.card({}, ImGui, function() end, function() end)
local all = table.concat(shown, "\n")
assert(all:find("Chat > Call", 1, true) and all:find("[Go to Chat > Call]", 1, true) and not all:find("Real time mode", 1, true), "call apps, live audio on: built-in Talk")
shown = {}
callapps.card({}, ImGui, function() end, nil)
all = table.concat(shown, "\n")
assert(all:find("Real time mode's Talk", 1, true) and all:find("[Go to Real time mode]", 1, true), "call apps, live audio off: as before")

-- ---- 4. takes counted from item events ----
local recap = require("recap")
local extras = require("extras")
local function item(user, name, time, track, extra)
  local e = { type = "obj", obj = "item", user = user, time = time, rev = 1, name = track or "Gtr",
    state = '<ITEM\nPOSITION 1\nNAME "' .. name .. '"\n<SOURCE FLAC\nFILE "media/' .. (extra or name) .. '.flac"\n>\n>' }
  return e
end
local since = "2026-11-20T10:00:00Z"
local evs = {
  item("Bo", "Verse - Bo - take 1", "2026-11-20T11:00:00Z"), -- a smart name
  item("Bo", "Verse - Bo - take 1", "2026-11-20T11:00:01Z"), -- a lanes split's copy: counted once
  item("Al", "03-Bass-261120_1100", "2026-11-20T11:01:00Z", "Bass"), -- REAPER's own name for the recording
  item("Al", "my renamed clip", "2026-11-20T11:02:00Z", "Bass", "other"), -- typed by someone: not a take
  item("Me", "Verse - Me - take 2", "2026-11-20T11:03:00Z"), -- mine
  item("Bo", "Verse - Bo - take 0", "2026-11-20T09:00:00Z"), -- before I left
}
evs[#evs + 1] = { type = "obj", obj = "item", user = "Bo", time = "2026-11-20T11:04:00Z", rev = 2, name = "Gtr", state = evs[1].state } -- an edit, not a new take
local parts = extras.away_counts(evs, { { user = "Old", sent = "2026-11-20T11:05:00Z" } }, {}, since, "Me")
local line = table.concat(parts, "; ")
assert(line:find("Bo: 3 changes, 1 take", 1, true), line)
assert(line:find("Al: 2 changes, 1 take", 1, true), line)
assert(line:find("Old: 1 take", 1, true), "an old song's manifest still counts: " .. line)
assert(not line:find("Me", 1, true), "mine aren't news")
local r = recap.build(evs, { take_name = recap.state_take })
assert(#r.takes == 4, "the recap counts the same way (old one before Me left included): " .. #r.takes)
-- the credits, from the song's event files and old manifests
local files = { ["S/rooms/main/events"] = { "a.json", "b.json", "c.json" }, ["S/rooms/main/takes"] = { "m.json" } }
local json = { ["S/rooms/main/events/a.json"] = evs[1], ["S/rooms/main/events/b.json"] = evs[2], ["S/rooms/main/events/c.json"] = evs[3],
  ["S/rooms/main/takes/m.json"] = { user = "Old" } }
band.song_dir = function() return "S" end
band.subdirs = function() return { "main" } end
band.files = function(d) return files[d] or {} end
band.read_json = function(p) return json[p] end
band.takes_dir = function() return "S/rooms/main/takes" end
local written
band.write_atomic = function(_, text) written = text end
extras.credits({ root = "R" }, { song = "Song" })
assert(written:find("\nAl%s+0%s+1%s+1") and written:find("\nBo%s+0%s+1%s+2") and written:find("\nOld%s+0%s+1%s+0"), written)

-- ---- 5. background renders: no checkbox, the computer's own default ----
package.loaded.bgrender = nil
gext[S .. "\0bg render"] = "off" -- someone's old choice, saved
deleted = {}
local bg = require("bgrender")
assert(bg.on() == true and gext[S .. "\0bg render"] == nil and deleted[1][1] == "bg render" and deleted[1][2] == true, "Windows: on; the saved choice dropped")
assert(bg.on() == true and #deleted == 1, "dropped once")
gext[S .. "\0bg render test"] = "off"
assert(bg.on() == false, "the in-REAPER tests' own switch still prints in front")
gext[S .. "\0bg render test"] = nil
os_name = "OSX64"
package.loaded.bgrender = nil
gext[S .. "\0bg render"] = "on"
bg = require("bgrender")
assert(bg.on() == false and gext[S .. "\0bg render"] == nil, "a Mac without the helpers: off, whatever was saved")
os_name = "Win64"
assert(not src("lib/prints.lua"):find("Render prints in the background##bgrender", 1, true), "the checkbox is gone")
print("ok")
