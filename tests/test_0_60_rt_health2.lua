-- rt-sync2j: phase 8 of rt-sync2 (docs/rt/rt-sync2.md 5b timers into facts, 5c Health compares contents), and History's Restore count.
-- Lua 5.4, from the repo root. Each part fails without its commit (docs/rt/rt-sync2j.md's knock-out table):
--  1. Asked by id: a version the judge needs and lacks is asked of every bandmate here at once; once each says it hasn't it, the answer is
--     complete at once (it waited WAIT_MISSING's two minutes). A bandmate asked answers with the ids it hasn't. A file that doesn't read is
--     asked likewise and skipped once every bandmate says it hasn't it (it waited UNREADABLE_SECS' ten minutes).
--  2. The content code and its 16 bucket codes: equal on two computers holding the same song; a change that never landed on one (skipped)
--     makes them differ in that object's bucket alone, and heal is due at once, for that bucket, once per difference (it waited a minute,
--     then at most every 5 minutes); healed, the codes agree.
--  3. "Same changes, different song": the same versions held, another content code (a merge put together differently): noted for Health
--     with the merged object, logged once, and nothing healed.
--  4. Drift here: REAPER reads as the record says but the version held holds something else (the test-only fault: a held version swapped):
--     the look puts the studio's version back, nothing is sent, and it's said once.
--  5. A Restore's slices say how many changes they really bring back, not every object in the plan.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local T = 1800000000
local real_time, real_date = os.time, os.date
os.time = function(t) if t then return real_time(t) end return T end
os.date = function(fmt, t) return real_date(fmt, t or T) end
local E = require("editreaper")
local F0 = E.new("C:/A/Song.rpp")
reaper = F0.reaper
local band = require("band")
local files, logged = {}, {}
band.read_json = function(path) local v = files[path]; if type(v) == "table" then return band.json_decode(band.json_encode(v)) end end
band.write_json = function(path, v) files[path] = band.json_decode(band.json_encode(v)); return true end
band.log = function(s) logged[#logged + 1] = s end
local function list(dir) local out = {}; for p in pairs(files) do local f = p:match("^" .. dir:gsub("%p", "%%%0") .. "/([^/]+%.json)$"); if f then out[#out + 1] = f end end; table.sort(out); return out end
band.files, band.listing = list, function(dir) return list(dir) end
package.loaded.trust = { claim_ok = function() return true end }
local mirror = require("mirror")
local sync = require("sync")
local needlist = require("needlist")
require("prints").choose = function() end
local function told(pattern) local n = 0; for _, l in ipairs(logged) do if l:find(pattern) then n = n + 1 end end; return n end

-- ---- computers (as tests/test_0_60_rt_reopen.lua) --------------------------------------------------------------------------------------------
local claimask = require("claimask")
local wire = {}
require("direct").send_live = function(cfg, kind, d, _, _, _, to) wire[#wire + 1] = { kind = kind, d = d, from = cfg.user, to = to and to[1] }; return true end
claimask.reachable = function() return nil end
claimask.present = function() return false end
local function studio(song)
  local S = { song = song, dir = "R/" .. song .. "/rooms/main", sess = { host = "James", markers = {} }, b = { song = song, room = "main" } }
  files[S.dir .. "/mode.json"] = { mode = "everyone", by = "James" }
  local function as(c) reaper = c.F.reaper end
  S.as = as
  function S.computer(user)
    local c = { F = E.new("C:/" .. user .. "/" .. song .. ".rpp"), cfg = { user = user, root = "R" }, user = user }
    c.F.reaper.GetMousePosition = function() return 0, 0 end
    c.F.reaper.file_exists = function(p) return not p:find("%.json$") or files[p] ~= nil end
    c.F.reaper.SetExtState(band.SECTION, "user", user, false)
    c.edited = -1
    return c
  end
  function S.look(c)
    as(c)
    c.F.clock = c.F.clock + 1
    local may, w = sync.authority(c.cfg, song, "main", S.sess)
    sync.driver_name, sync.room_mode = w.driver, w.mode
    mirror.watch(c.F.proj, c.cfg, song, "main", { can = may, owner_can = may, mode = w.mode, is_claimed = w.is_claimed, owner_of = w.owner_of, quick = true,
      edited_at = c.edited, soft = function(name, pos) return claimask.soft(w, name, pos, c.cfg.user) end,
      ask = function(name, pos) return claimask.hold(c.cfg, S.b, w, name, pos) end, sent = claimask.on_sent })
    claimask.flush(c.cfg, S.b, w, false)
    wire = {}
    as(c)
  end
  function S.settle(c)
    for _ = 1, 20 do
      local n = 0
      for _ in pairs(files) do n = n + 1 end
      S.look(c)
      local m = 0
      for _ in pairs(files) do m = m + 1 end
      if m == n and not mirror.more and not mirror.unsettled then return end
      mirror.unsettled = nil
    end
    error("never settled")
  end
  function S.edit(c, fn) as(c); c.F.clock = c.F.clock + 1; fn(c.F); c.edited = c.F.clock; S.settle(c) end
  function S.recv(c, no_look)
    as(c)
    sync.ev_cache = {}
    for _ = 1, 20 do
      c.F.clock = c.F.clock + 1
      local may, w = sync.authority(c.cfg, song, "main", S.sess)
      sync.room_mode = w.mode
      local got = sync.receive(c.F.proj, c.cfg, song, "main", may)
      if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
    end
    if not no_look then S.settle(c) end
  end
  function S.track(c, name) for _, t in ipairs(c.F.tracks) do if t.name == name then return t end end end
  function S.events(pred) local out = {}; for p, v in pairs(files) do if p:find(S.dir .. "/events/", 1, true) and type(v) == "table" and pred(v) then out[#out + 1] = v end end; return out end
  -- what this computer says in its status (Live sync's P.status): for the others' heal
  function S.status(c)
    as(c)
    local code, bk = mirror.contents(c.F.proj, S.dir)
    local st = { user = c.user, pending = sync.pending_events(c.F.proj, c.cfg, song, "main"), mirror = mirror.root(c.F.proj), content = code, bk = bk }
    as(c)
    return st
  end
  return S
end
local function midi(pos, len, name)
  return table.concat({ "<ITEM", "POSITION " .. pos, "SNAPOFFS 0", "LENGTH " .. len, "LOOP 0", 'NAME "' .. (name or "K") .. '"', "SOFFS 0",
    "PLAYRATE 1 1 0 -1 0 0.0025", "<SOURCE MIDI", "HASDATA 1 960 QN", "E 0 90 3c 60", "E 480 80 3c 00", "E 960 b0 7b 00", ">", ">" }, "\n") .. "\n"
end
local function item_pos(c, track)
  for _, tr in ipairs(c.F.tracks) do
    if tr.name == track then local it = tr.items[1]; return it and tonumber(it.text:match("\nPOSITION ([%d%.]+)")) end
  end
end
local function oid_of(it) return it.ext and it.ext.band_oid end
-- the song both have: Drums, Keys with an item at 4 s
local function song(name)
  local S = studio(name)
  local A, B = S.computer("James"), S.computer("Bee")
  S.edit(A, function(F) F.add_track("Drums"); F.add_item(F.add_track("Keys"), midi(4, 2)) end)
  A.F.clock = A.F.clock + 70
  S.settle(A)
  S.recv(B)
  assert(item_pos(B, "Keys") == 4, "the song on Bee's: Keys' item at " .. tostring(item_pos(B, "Keys")))
  return S, A, B
end

-- ---- 1. asked by id ----------------------------------------------------------------------------------------------------------------------------
do
  local S = studio("Ask")
  local A = S.computer("James")
  S.as(A)
  local services, direct = require("services"), require("direct")
  services.my_device_id = function() return "DEV-A" end
  services.is_device_id = function(d) return type(d) == "string" and d:match("^DEV%-") ~= nil end
  direct.peers = function() return { "Bee", "Cee" }, { Bee = "DEV-B", Cee = "DEV-C" } end
  local function put(v) v.type, v.obj, v.oid = "obj", "item", "I-ASK-1"; files[S.dir .. "/events/" .. v.id .. ".json"] = v; return v end
  local base = "James-20261128-095900Z-00001-0001" -- (on its way: in no folder here)
  local a1 = put({ id = "Bee-20261128-100000Z-00001-0001", rev = 2, base = 1, base_ev = base, hlc = 2000, user = "Bee", track = "T-X", state = midi(5, 2) })
  local c1 = put({ id = "Cee-20261128-100001Z-00001-0001", rev = 2, base = 1, base_ev = base, hlc = 2100, user = "Cee", track = "T-X", state = midi(4, 3) })
  local js = mirror.judge(nil, "I-ASK-1", S.dir, { a1, c1 })
  assert(not js.complete and js.missing[1] == base, "two edits of a version not here: incomplete, naming it (" .. tostring(js.missing[1]) .. ")")
  wire = {}
  needlist.ask_by_id(A.cfg, S.b, { "Bee", "Cee" }, { Bee = "DEV-B", Cee = "DEV-C" }, "DEV-A")
  local asked = {}
  for _, m in ipairs(wire) do if m.kind == "need_ask" and m.d.want and m.d.want.ids[1] == base then asked[#asked + 1] = m.to end end
  table.sort(asked)
  assert(table.concat(asked, ",") == "Bee,Cee", "asked of both bandmates at once, by id: " .. table.concat(asked, ","))
  wire = {}
  needlist.ask_by_id(A.cfg, S.b, { "Bee", "Cee" }, { Bee = "DEV-B", Cee = "DEV-C" }, "DEV-A")
  assert(#wire == 0, "and not again of the same bandmates")
  needlist.on_list(A.cfg, S.b, { dev = "DEV-B", room = "main", none = { base } })
  js = mirror.judge(nil, "I-ASK-1", S.dir, { a1, c1 })
  assert(not js.complete, "Bee hasn't it, Cee hasn't answered: still waiting")
  assert(needlist.on_list(A.cfg, S.b, { dev = "DEV-X", room = "main", none = { base } }) == false, "a computer that isn't here isn't counted")
  needlist.on_list(A.cfg, S.b, { dev = "DEV-C", room = "main", none = { base } })
  js = mirror.judge(nil, "I-ASK-1", S.dir, { a1, c1 })
  assert(js.complete and js.v, "neither has it: it counts as trimmed at once, well inside WAIT_MISSING (was: two minutes)")
  -- the bandmate's side: what it has goes over the link, and it says which it hasn't
  band.info = function() return { id = "STUDIO-1" } end
  rawset(reaper, "StudioSync_DirectSend", function() return 1 end)
  direct.ensure = function() return true end
  wire = {}
  needlist.on_ask(A.cfg, S.b, { dev = "DEV-B", user = "Bee", want = { room = "main", ids = { a1.id, "Nobody-20261128-100002Z-00001-0001" } } })
  local none
  for _, m in ipairs(wire) do if m.kind == "need_list" and m.d.none then none = m end end
  assert(none and none.to == "Bee" and #none.d.none == 1 and none.d.none[1] == "Nobody-20261128-100002Z-00001-0001", "it answers which ids it hasn't")
  -- a file that doesn't read: asked by id too, and skipped once every bandmate says it hasn't it
  local bad = "Nobody-20261128-100003Z-00001-0001"
  files[S.dir .. "/events/" .. bad .. ".json"] = { id = "not its name" }
  S.recv(A, true)
  assert(sync.unreadable[bad] and needlist.by_id[S.dir .. "\0" .. bad], "a file that doesn't read is noted and wanted by id")
  needlist.ask_by_id(A.cfg, S.b, { "Bee", "Cee" }, { Bee = "DEV-B", Cee = "DEV-C" }, "DEV-A")
  needlist.on_list(A.cfg, S.b, { dev = "DEV-B", room = "main", none = { bad } })
  needlist.on_list(A.cfg, S.b, { dev = "DEV-C", room = "main", none = { bad } })
  S.recv(A, true)
  local skipped = false
  for _, x in ipairs(sync.skipped(A.F.proj)) do if x.id == bad then skipped = true end end
  assert(skipped, "nobody has it: skipped at once (was: after ten minutes)")
  print("rt-sync2j 1: what the judge lacks, and a file that doesn't read, are asked of the bandmates by id; once none has it, no waiting")
end
print("ok")
