-- rt-answers, item 3 (James, 2026-11-21): a song's home is the member who added it, and the owner can hand it on. Before, the home was
-- session.json's host only while that person's own computer had written session.json last, so a bandmate's computer rewriting it set the
-- sharer aside and the home came and went (rt-hubfix part 2). Now the adder notes it once in their own hub file (`added`, lib/hub.lua
-- note_added; signed like every hub file, lib/signed.lua "hub"), and that counts when it's the person session.json names. An old song with no
-- adder kept keeps the rule before, and its sharer's own computer notes it the first time it looks. Hub ranking's rule stands: the home hosts
-- when it's here. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local ext, files = {}, {}
reaper = setmetatable({
  time_precise = function() return 1000 end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  EnumProjects = function() return "P" end,
}, { __index = function() return function() return "" end end })
local band = require("band")
band.info = function() return { id = "studio1", name = "Smiley" } end
band.log = function() end
band.read_json = function(p) local v = files[p]; if type(v) == "table" then return band.json_decode(band.json_encode(v)) end end
band.write_json = function(p, t) files[p] = band.json_decode(band.json_encode(t)); return true end
band.files = function(d)
  local out = {}
  for p in pairs(files) do local f = p:match("^" .. d:gsub("%p", "%%%0") .. "/([^/]+%.json)$"); if f then out[#out + 1] = f end end
  table.sort(out)
  return out
end
band.age = function() return 1e6 end
local roles = { Owner = "owner", Adm = "admin" }
package.loaded.groups = { trusted = function() return {} end, role = function(_, u) return roles[u] or "member" end }
local trust = require("trust")
-- whose computer wrote each file, as trust.own_file_ok says (Syncthing's writer, or a signature): every file its person's, unless set here
local written_by = {}
trust.own_file_ok = function(_, rel, user) local w = written_by[rel]; if w == nil then return true end; return w == user end
local hub = require("hub")

local SP = "R/Song/session.json"
band.session_path = function(_, s) return "R/" .. s .. "/session.json" end
local bo, desk, lap = { root = "R", user = "Bo" }, { root = "R", user = "Desk" }, { root = "R", user = "Lap" }

-- ---- a song added now: Bo shares it (StudioSync - Publish session.lua writes session.json, then notes the adder) ----
do
  files[SP] = { host = "Bo", song = "Song" }
  assert(hub.note_added(bo, "Song") and files["R/Song/hub/Bo.json"].added and type(files["R/Song/hub/Bo.json"].transfers) == "table",
    "the adder is noted in their own hub file (a hub file, so signed and over the link as every one is)")
  assert(not hub.note_added(bo, "Song"), "once")
  assert(hub.home(desk, "Song") == "Bo", "the adder is the song's home")
  -- a bandmate's computer writes session.json (an older build's timeline): before, Bo was set aside and the song had no home
  written_by["Song/session.json"] = "Desk"
  local h, moved, refused = hub.home(desk, "Song")
  assert(h == "Bo" and not moved and #refused == 0, "whoever last wrote session.json doesn't move the home, nor is Bo called forged (" .. tostring(h) .. ")")
  -- a member who writes `added` in their own file isn't the adder: session.json names Bo
  assert(hub.note_added(lap, "Song"))
  assert(hub.home(desk, "Song") == "Bo", "a member saying they added it doesn't take the home")
  -- an adder file that came from another computer than its person's isn't believed (and is said)
  written_by["Song/hub/Bo.json"] = "Mallory"
  h, _, refused = hub.home(desk, "Song")
  assert(h == nil and refused[1] == "Bo", "an adder file Bo's computer didn't write doesn't count, and session.json written by another stays aside too")
  written_by["Song/hub/Bo.json"] = nil
  -- handed on: by the adder, by the home now, by the owner; the adder's note is kept through each
  assert(not hub.hand_song(lap, "Song", "Lap"), "a member can't hand someone else's song on")
  assert(hub.hand_song(bo, "Song", "Desk") and hub.home(lap, "Song") == "Desk", "the adder hands it on")
  assert(files["R/Song/hub/Bo.json"].added and #files["R/Song/hub/Bo.json"].transfers == 1, "its handover beside its note")
  assert(hub.hand_song(desk, "Song", "Lap") and hub.home(bo, "Song") == "Lap", "the home now hands it on")
  assert(hub.hand_song({ root = "R", user = "Owner" }, "Song", "Bo") and hub.home(desk, "Song") == "Bo", "the owner hands it back")
  written_by["Song/session.json"] = nil
end

-- ---- an old song, shared before the adder was kept: the rule before, until its sharer's own computer looks ----
do
  files["R/Old/session.json"] = { host = "Bo", song = "Old" }
  assert(hub.home(desk, "Old") == "Bo", "session.json written by its sharer's computer: the sharer, as before")
  written_by["Old/session.json"] = "Desk"
  assert(hub.home(desk, "Old") == nil and files["R/Old/hub/Desk.json"] == nil, "written by another: no home, as before (and nobody else notes anything)")
  -- Bo's own computer looks (Live sync's hub tick, Settings): it notes Bo as the adder, once
  hub.home(bo, "Old")
  assert(files["R/Old/hub/Bo.json"] and files["R/Old/hub/Bo.json"].added, "the sharer's own computer notes its person as the adder")
  local at = files["R/Old/hub/Bo.json"].added
  hub.home(bo, "Old")
  assert(files["R/Old/hub/Bo.json"].added == at, "(once)")
  assert(hub.home(desk, "Old") == "Bo", "from then on its home stays, whoever writes session.json")
  written_by["Old/session.json"] = nil
end

-- ---- hub ranking's rule stands: the home hosts when it's here, whoever else is better reached or holds the role ----
do
  local T = 1000000
  local function c(user, since, t) t = t or {}; t.user, t.since, t.machine = user, since, "m-" .. user; return t end
  written_by["Song/session.json"] = "Desk"
  local home = hub.home(desk, "Song")
  local cands = { c("Bo", T - 100, { songs = { Song = {} }, miss = 1 }), c("Desk", T - 9000, { songs = { Song = { holds = true } }, link = true, miss = 0 }) }
  local u, why = hub.elect_song(cands, "Song", home, "Desk", T)
  assert(u == "Bo" and why == "home", "the adder's computer hosts when it's here (" .. tostring(u) .. ", " .. tostring(why) .. ")")
  u, why = hub.elect_song({ cands[2] }, "Song", home, "Desk", T)
  assert(u == "Desk" and why ~= "home", "away: the ranking below it, as before")
  written_by["Song/session.json"] = nil
end

-- the share path notes the adder
local src = (function() local fh = assert(io.open("StudioSync - Publish session.lua", "rb")); local s = fh:read("a"); fh:close(); return s end)()
assert(src:find('require("hub").note_added, cfg, song)', 1, true), "StudioSync - Publish session.lua notes who added the song")
print("ok rt-answers home")
