-- A quieter shared folder (James, rt; docs/realtime-roadmap.md "Things that can go, or shrink"): while the direct link reaches everyone here,
-- the status goes over the link and its file is written every presence.FILE_QUIET s; anyone the link doesn't reach (or no link) gets today's
-- pace. A stand-in Live sync (10 minutes: idle, editing, playing, recording) counts the status file writes per minute both ways. Also: a link
-- that drops writes the file at once, someone here the link doesn't reach keeps today's pace, someone newly reached gets the whole status at
-- once, a hub change still writes at once, the scripts that take no messages read Live sync's live statuses, a heartbeat vouches for nothing
-- in Status, and live MIDI's files count everyone here, not just the link's list.
package.path = "lib/?.lua;" .. package.path
local clock, gext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetAppVersion = function() return "7.86/win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })

local band = require("band")
local files, writes, file_times = {}, 0, {}
band.read_json = function(path) local v = files[path]; return type(v) == "table" and v or nil end
band.files = function(dir, ext)
  local t = {}
  for path in pairs(files) do
    local d, f = path:match("^(.*)/([^/]+)$")
    if d == dir and (not ext or f:sub(-#ext) == ext) then t[#t + 1] = f end
  end
  table.sort(t)
  return t
end
band.listing = band.files
band.write_json = function(path, t)
  if path:find("/status/James.json$") then writes = writes + 1; file_times[#file_times + 1] = clock end
  files[path] = t
end
band.info = function() return { id = "studio1" } end
band.session_path = function() return "R/Song/session.json" end

local link = { up = true, reach = {}, peers = { "bee.ts.net:47281" } }
local sends = 0
package.loaded.direct = {
  available = function() return link.up end, live_available = function() return link.up end, ensure = function() return link.up end,
  reach = function() return link.up and link.reach or {} end,
  peers = function() return link.up and link.peers or {} end,
  send_live = function(_, kind) if kind == "presence" then sends = sends + 1 end end,
}
package.loaded.rthealth = { free_mb = function() return 1000 end }
package.loaded.colours = { look = function() return nil end }
package.loaded.removal = { gone = function() return {} end }
local sync = require("sync")
sync.room_dir = function(_, song, room) return "R/" .. song .. "/rooms/" .. room end
sync.machine = function() return "desk" end
sync.put_back = function() end
sync.driver = function() return "James" end
local presence = require("presence")
local cfg = { root = "R", user = "James" }
local SDIR = "R/Song/rooms/main/status"
local function now_iso() return os.date("!%Y-%m-%dT%H:%M:%SZ") end
files[SDIR .. "/Bee.json"] = { user = "Bee", time = now_iso(), pending = 0 }
local writer = function(info, link_only) sync.write_status("P", cfg, "Song", "main", info, link_only) end

-- ---- the stand-in: 10 minutes of Live sync's status writes -------------------------------------------------------------------------------
-- idle 3 min (a pass every 2 s, cpu moving every 20 s), editing 4 min (a pass a second, each one changing the status: the mirror root and what
-- you edit), playing 2 min (every 2 s, a change every 10 s), recording 1 min (no passes: the start's write, then the heartbeat while it waits).
local function stand_in(up)
  link.up = up
  link.reach = { Bee = { ok = true, at = 0 } }
  writes, sends, file_times = 0, 0, {}
  local s, next_pass, recording = { fp = "", at = 0 }, 0, false
  for step = 0, 1199 do
    local ts = step * 0.5
    clock = 1000 + ts
    files[SDIR .. "/Bee.json"].time = now_iso() -- (Bee stays here)
    local phase = ts < 180 and "idle" or ts < 420 and "edit" or ts < 540 and "play" or "rec"
    if phase ~= "rec" then
      if ts >= next_pass then
        next_pass = ts + (phase == "edit" and 1 or 2)
        local info = { cpu = math.floor(ts / (phase == "idle" and 20 or 10)), mirror = phase == "edit" and ts or 0, playing = phase == "play" or nil, hub = { since = 1 } }
        presence.put_status(cfg, "Song", "main", s, info, band.json_encode(info), clock, writer)
      end
    else
      if not recording then -- (as tick_body's take start)
        recording = true
        local si = s.info
        si.playing, si.recording = true, true
        presence.put_status(cfg, "Song", "main", s, si, band.json_encode(si), clock, writer)
        s.fp = nil
      end
      if clock - s.at > 15 then -- (together.heartbeat_due)
        local okw, what = pcall(presence.put_status, cfg, "Song", "main", s, s.info, s.fp, clock, writer)
        if not (okw and what) then s.at = clock end
      end
    end
  end
  local gap = 0
  for i = 2, #file_times do gap = math.max(gap, file_times[i] - file_times[i - 1]) end
  return writes / 10, sends / 10, gap, file_times[#file_times]
end
local before, before_sends, before_gap = stand_in(false)
local after, after_sends, after_gap, after_last = stand_in(true)
assert(before > 25, "today's pace while editing: a file each change (" .. before .. "/min)")
assert(after <= 2.5 and after < before / 10, "the link reaching everyone: about one file every 30 s (" .. after .. "/min)")
assert(after_gap <= presence.FILE_QUIET + 2 and after_gap < 45, "never longer between files than readers' 45 s window (" .. after_gap .. " s)")
assert(1000 + 600 - after_last <= presence.FILE_QUIET + 2, "and still written while recording")
assert(after_sends >= before_sends * 0.9, "everything still goes over the link (" .. after_sends .. " vs " .. before_sends .. " a minute)")

-- ---- falling back ----------------------------------------------------------------------------------------------------------------------
link.up, link.reach = true, { Bee = { ok = true, at = 0 } }
local s = { fp = "", at = 0 }
clock = 5000
local function pass(info) return presence.put_status(cfg, "Song", "main", s, info, band.json_encode(info), clock, writer) end
assert(pass({ n = 1 }) == "file", "the first: the file")
clock = clock + 2
assert(pass({ n = 2 }) == "link", "a change with everyone reached: the link alone")
clock = clock + 2
assert(pass({ n = 2 }) == nil, "nothing new: nothing")
link.reach.Bee.ok = false
clock = clock + 2
assert(pass({ n = 2 }) == "file", "the link loses Bee: the file at once, though nothing changed since the last message")
clock = clock + 2
assert(pass({ n = 3 }) == "file", "and every change while it can't reach her")
link.reach.Bee.ok = true
clock = clock + 2
assert(pass({ n = 4 }) == "link", "back: the link alone again")
-- someone here the link doesn't reach: today's pace
files[SDIR .. "/Chilio.json"] = { user = "Chilio", time = now_iso() }
clock = clock + 2
assert(pass({ n = 5 }) == "file", "Chilio here, not reached (no Tailscale name): every change in the file")
clock = clock + 2
assert(pass({ n = 5 }) == nil, "nothing new: nothing (today's rule)")
clock = clock + presence.HEARTBEAT + 1
assert(pass({ n = 5 }) == "file", "and every 15 s")
-- someone newly reached gets the whole status at once
link.reach.Chilio = { ok = true, at = 0 }
clock = clock + 2
assert(pass({ n = 5 }) == "link", "Chilio reached: the whole status to her now, nothing changed")
clock = clock + 2
assert(pass({ n = 5 }) == nil, "then quiet")
clock = clock + presence.HEARTBEAT + 1
assert(pass({ n = 5 }) == "link", "the whole status again every 15 s over the link")
-- a hub change writes the file at once (other songs elect from the files alone)
clock = clock + 2
assert(pass({ n = 5, hub = { studio = true } }) == "file", "a hub role taken: the file at once")
-- no link at all: today's pace
link.up = false
clock = clock + 2
assert(pass({ n = 6, hub = { studio = true } }) == "file", "no link: every change in the file")
files[SDIR .. "/Chilio.json"] = nil
link.up = true

-- ---- the scripts that take no messages read Live sync's --------------------------------------------------------------------------------
local old = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 20)
files[SDIR .. "/Bee.json"] = { user = "Bee", time = old, pending = 0, cpu = 9 }
local fresh = now_iso()
assert(presence.from_msg(cfg, "Song", "main", { user = "Bee", time = fresh, room = "main", pending = 0, cpu = 2 }, "presence"), "Bee's live status taken")
clock = clock + 2
local function cpu_of(list) for _, st in ipairs(list) do if st.user == "Bee" then return st.cpu end end end
assert(cpu_of(presence.peers(cfg, "Song", "main")) == 2, "Live sync: the link's cpu, not the file's")
package.loaded.presence = nil
local panel = require("presence") -- (another script: takes no messages)
assert(cpu_of(panel.peers(cfg, "Song", "main")) == 2, "the panel: Live sync's live status from ExtState")
package.loaded.presence = presence
-- a heartbeat moves the time on, not what's vouched for
local ev = "R/Song/rooms/main/events/Al-" .. os.date("!%Y%m%d-%H%M%SZ", os.time() + 2) .. "-0001.json" -- (a change after Bee's status, before the heartbeat)
files[ev] = {}
local later = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 5)
assert(presence.from_msg(cfg, "Song", "main", { user = "Bee", time = later, room = "main" }, "heartbeat"), "a heartbeat")
local bee = presence.live(cfg, "Song", "main").Bee
assert(bee.time == later and bee.said == fresh and bee.cpu == 2, "its time moves on; said stays at the last real status")
local status = require("status")
local row = status.gather(cfg, { song = "Song", room = "main" }, "P").rows[1]
assert(row.name == "Bee" and row.behind == true, "Status: Bee is still behind the newest change until a real status says otherwise")
local later2 = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 6)
assert(presence.from_msg(cfg, "Song", "main", { user = "Bee", time = later2, room = "main", pending = 0 }, "presence"), "Bee's next real status")
row = status.gather(cfg, { song = "Song", room = "main" }, "P").rows[1]
assert(row.behind == false and row.state == "synced", "caught up by the live status, not the 20 s old file")
files[ev] = nil

-- ---- live MIDI's files: everyone here, not only the link's list -----------------------------------------------------------------------
-- (direct.reaches_all over the real direct.lua, with presence stubbed to one here the link can't count)
package.loaded.direct = nil
local direct = require("direct")
reaper.StudioSync_DirectMsg, reaper.StudioSync_DirectClock, reaper.StudioSync_DirectStream = function() end, function() return "{}" end, function() end
local carries = false
package.loaded.presence = { link_carries = function() return carries end }
direct.peers = function() return { "bee.ts.net:47281" } end
clock = clock + 5
assert(direct.reaches_all(cfg, "Song", "main") == false, "someone here the link can't count: live MIDI files go on")
carries, clock = true, clock + 2
assert(direct.reaches_all(cfg, "Song", "main") == true, "everyone here reached: link only")
package.loaded.presence = presence

print(string.format("ok (stand-in, status file writes per minute: before %.1f, after %.1f; presence messages %.1f -> %.1f a minute; longest between files %d s)",
  before, after, before_sends, after_sends, after_gap))
