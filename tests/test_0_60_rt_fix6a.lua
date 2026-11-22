-- rt-fix6a (docs/rt/rt-fix6a.md): the sync-core bugs the REAPER re-check rt-r1 found. Lua 5.4, from the repo root.
--  1. The claim judgement (mirror.clashes, as mirror.watch's soft path and sync.receive's soft_ok use it) pairs a moved MIDI note as the merge
--     does: a transposition of a note a bandmate just moved isn't a clash (P1-8).
--  2. A bandmate's deletion older than this computer's own auto-claim lands at once (sync.receive), and an edit of the band's item on a deleted
--     track isn't kept as "(yours, not sent)" (mirror.apply): rt-linkmove round 5 C.
--  3. Auto-claims only come from an edit of this person's (mirror.watch's w.edited; LinuxBox2 claimed XT Rec A 21 s after opening).
--  4. A claimer the direct link can't reach (claimask.hold): an auto-claim lets the edit go out and says so; a lasting one puts it back at once.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local ext, clock, T = {}, 1000, 1800000000
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return T end
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetOS = function() return "Win64" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
local files, logged = {}, {}
band.read_json = function(path) return files[path] end
band.write_json = function(path, v) files[path] = v end
band.log = function(s) logged[#logged + 1] = s end
local function list(dir) local out = {}; for p in pairs(files) do local f = p:match("^" .. dir:gsub("%p", "%%%0") .. "/([^/]+%.json)$"); if f then out[#out + 1] = f end end; table.sort(out); return out end
band.files, band.listing = list, function(dir) return list(dir) end
package.loaded.alerts = { send = function() return true end }
package.loaded.groups = { may_manage = function() return false end, takes_to_lanes = function() return false end }
package.loaded.trust = { claim_ok = function() return true end }
local link_ok, reach, wire = true, nil, {}
package.loaded.direct = {
  path = function(_, dir, f) return dir .. "/" .. f end,
  send_live = function(cfg, kind, d) if not link_ok then return false end; wire[#wire + 1] = { kind = kind, d = d, from = cfg.user }; return true end,
  live_available = function() return reach ~= nil end,
  reach = function() return reach or {} end,
}
local mirror = require("mirror")
local sync = require("sync")
local claimask = require("claimask")
local R = "R/S/rooms/main"
local function put(ev) files[R .. "/events/" .. ev.id .. ".json"] = ev; return ev end
local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end

-- ---- 1. a note moved by the claimer, transposed by the editor: no clash (P1-8) --------------------------------------------------------------
do
  local function item(...) -- notes { tick, pitch, len } -> an item's state with one MIDI take
    local evs = {}
    for _, n in ipairs({ ... }) do
      evs[#evs + 1] = { n[1], string.format("90 %02x 60", n[2]) }
      evs[#evs + 1] = { n[1] + n[3], string.format("80 %02x 00", n[2]) }
    end
    table.sort(evs, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
    local lines, last = {}, 0
    for _, e in ipairs(evs) do lines[#lines + 1] = string.format("E %d %s", e[1] - last, e[2]); last = e[1] end
    lines[#lines + 1] = string.format("E %d b0 7b 00", 3840 - last)
    return "<ITEM\nPOSITION 0\nLENGTH 4\nTAKE\nNAME \"k\"\n<SOURCE MIDI\nHASDATA 1 960 QN\n" .. table.concat(lines, "\n") .. "\n>\n>\n"
  end
  local hlc = math.floor(T * 1000)
  local function ev(id, user, state, base) return put({ id = id, user = user, obj = "item", oid = "I1", state = state, base_ev = base, hlc = hlc, time = iso(T) }) end
  ev("Laptop-20261121-120000Z-00001-0001", "James-Laptop", item({ 0, 48, 960 }, { 1920, 55, 960 }))
  local moved = ev("James-20261121-120001Z-00001-0002", "James", item({ 960, 48, 960 }, { 1920, 55, 960 }), "Laptop-20261121-120000Z-00001-0001")
  -- the editor's version, made from James's move
  local transposed = item({ 960, 50, 960 }, { 1920, 55, 960 })
  assert(mirror.clashes(R, "item", transposed, moved, "James") == false, "a transposition of the note James moved: no clash, as the merge keeps both")
  assert(mirror.clashes(R, "item", item({ 1440, 48, 960 }, { 1920, 55, 960 }), moved, "James") == true, "moved again: the same part (its start), a clash")
  assert(mirror.clashes(R, "item", item({ 1920, 55, 960 }), moved, "James") == true, "the note James moved taken away: a clash")
  assert(mirror.clashes(R, "item", item({ 960, 48, 960 }, { 1920, 57, 960 }), moved, "James") == false, "another note changed: no clash, as before")
  -- James transposed; the editor moves it in time: no clash either way round
  local up = ev("James-20261121-120002Z-00002-0003", "James", item({ 0, 52, 960 }, { 1920, 55, 960 }), "Laptop-20261121-120000Z-00001-0001")
  assert(mirror.clashes(R, "item", item({ 480, 52, 960 }, { 1920, 55, 960 }), up, "James") == false, "James's transposition, moved in time: no clash")
  assert(mirror.clashes(R, "item", item({ 0, 53, 960 }, { 1920, 55, 960 }), up, "James") == true, "transposed again: the same part (its pitch), a clash")
  -- note_changes itself: the pair and what changed
  local n = 0
  for k, nc in pairs(mirror.note_changes(moved.state, transposed)) do
    n = n + 1
    assert(k:find("N 0 50 960#1", 1, true) and nc.from:find("N 0 48 960#1", 1, true) and nc.fields.pitch and not nc.fields.start, "the pair: pitch only")
  end
  assert(n == 1, "one note changed")
  print("rt-fix6a 1: a transposition of a note the claimer moved isn't a clash; the same part changed by both still is")
end

-- ---- pure parts of 2, 3 and 4 ---------------------------------------------------------------------------------------------------------------
do
  local cfg = { root = "R", user = "Bee" }
  local cl = R .. "/claims/Bee.json"
  files[cl] = { user = "Bee", time = iso(T), tracks = { "Take" }, since = { ["tracks:take"] = iso(T) }, auto = { ["tracks:take"] = iso(T) } }
  assert(sync.gone_before_claim(cfg, "S", "main", { gone = true, name = "Take", time = iso(T - 60) }), "a deletion made before my auto-claim: it lands")
  assert(not sync.gone_before_claim(cfg, "S", "main", { gone = true, name = "Take", time = iso(T + 5) }), "one made after it: it waits its minute, as before")
  files[cl].auto = nil
  assert(not sync.gone_before_claim(cfg, "S", "main", { gone = true, name = "Take", time = iso(T - 60) }), "a lasting claim: as before")
  files[cl] = nil
  -- 3: an edit of this person's behind a look
  mirror.edit_seen = {}
  assert(mirror.user_edited("P", 5, 10, "") == false, "the first look: Live sync's first tick took the project's count as a change, not an edit")
  assert(mirror.user_edited("P", 5, 40, "") == false, "nothing since")
  assert(mirror.user_edited("P", 41, 42, "") == true and mirror.user_edited("P", 41, 41 + mirror.EDIT_SECS + 1, "") == false, "an edit, for EDIT_SECS")
  assert(mirror.user_edited("P", 41, 200, "Move items") == true, "a new undo point of someone's: an edit (a web page's isn't in Live sync's count)")
  assert(mirror.user_edited("P", 41, 201, "Move items") == false, "the same one still on top: not again")
  assert(mirror.user_edited("P", 41, 202, "StudioSync: changes from the others") == false and mirror.user_edited("P", 41, 203, "Colour tracks") == false,
    "StudioSync's own points aren't edits")
  assert(mirror.user_edited("P", 41, 204, "StudioSync web page: move an item") == true, "a web page's edit is")
  assert(mirror.user_edited("Q", nil, 10, "") == true, "a caller that doesn't keep the time: as before")
  -- 4: can the link reach them
  local b = { song = "S", room = "main" }
  reach = nil
  assert(claimask.reachable(cfg, b, "Chilio") == nil, "no link here: can't tell (the ask is tried)")
  reach = { Chilio = { ok = true } }
  assert(claimask.reachable(cfg, b, "Chilio") == true, "reached")
  reach = { Chilio = { ok = false } }
  assert(claimask.reachable(cfg, b, "Chilio") == false and claimask.reachable(cfg, b, "LinuxBox2") == false, "not answering, or not on the link at all")
  reach = nil
  print("rt-fix6a 2-4: the pure parts")
end

-- ---- 2, 3 and 4 in two computers (the chunk-faithful stand-in REAPER, each look wired as Live sync wires it) ----------------------------------
do
  local E = require("editreaper")
  local real_date = os.date
  os.date = function(fmt, t) return real_date(fmt, t or T) end -- (one clock for the events and the claims)
  band.read_json = function(path) local v = files[path]; if type(v) == "table" then return band.json_decode(band.json_encode(v)) end end
  band.write_json = function(path, v) files[path] = band.json_decode(band.json_encode(v)); return true end
  package.loaded.direct = nil -- (the real one from here, its messages onto the same wire: a look lists the link's inbox too)
  require("direct").send_live = function(cfg, kind, d) wire[#wire + 1] = { kind = kind, d = d, from = cfg.user }; return true end
  require("prints").choose = function() end
  claimask._reset()
  sync.live_claims, wire, logged = {}, {}, {}
  local SONG, sess = "Six", { host = "James", markers = {} }
  local b = { song = SONG, room = "main" }
  local RD = "R/Six/rooms/main"
  local here = { James = true, Bee = true }
  claimask.present = function(_, _, u) return here[u] == true end
  local reachable = nil
  claimask.reachable = function() return reachable end
  local function computer(user, path)
    local c = { F = E.new(path), cfg = { user = user, root = "R" } }
    c.F.reaper.MB = function() return 6 end
    c.F.reaper.GetMousePosition = function() return 0, 0 end
    c.F.reaper.file_exists = function(p) return not p:find("%.json$") or files[p] ~= nil end
    c.F.reaper.SetExtState(band.SECTION, "user", user, false) -- (who this computer's person is, as Live sync has it: mirror.just_made_here)
    c.edited = -1 -- (Live sync's first tick: its count taken as a change. c.edited = c.F.clock below: the person edits)
    return c
  end
  local A, L = computer("James", "C:/A/Six.rpp"), computer("Bee", "C:/B/Six.rpp")
  local by_user = { James = A, Bee = L }
  local function as(c) reaper = c.F.reaper end
  local function link()
    while #wire > 0 do
      local m = table.remove(wire, 1)
      if m.kind == "claim" then sync.live_claim(SONG, "main", m.d)
      elseif m.kind == "claim_ask" then as(by_user[m.d.to]); claimask.on_ask(by_user[m.d.to].cfg, b, m.d)
      elseif m.kind == "claim_answer" then as(by_user[m.d.to]); claimask.on_answer(by_user[m.d.to].cfg, b, m.d) end
    end
  end
  local seen = {}
  local function new_events()
    local out = {}
    for p, v in pairs(files) do
      if not seen[p] then
        seen[p] = true
        if p:find("/events/", 1, true) and type(v) == "table" and v.oid then out[v.oid] = v end
      end
    end
    return out
  end
  local function look(c)
    as(c)
    c.F.clock = c.F.clock + 1
    local may, w = sync.authority(c.cfg, SONG, "main", sess)
    sync.driver_name, sync.room_mode = w.driver, w.mode
    mirror.watch(c.F.proj, c.cfg, SONG, "main", { can = may, owner_can = may, mode = w.mode, is_claimed = w.is_claimed, owner_of = w.owner_of, quick = true,
      edited_at = c.edited, soft = function(name, pos) return claimask.soft(w, name, pos, c.cfg.user) end,
      ask = function(name, pos) return claimask.hold(c.cfg, b, w, name, pos) end, sent = claimask.on_sent })
    claimask.flush(c.cfg, b, w, false)
    link()
    as(c)
    return new_events()
  end
  local function settle(c)
    for _ = 1, 20 do
      if next(look(c)) == nil and not mirror.more and not mirror.unsettled then return end
      mirror.unsettled = nil
    end
    error("never settled")
  end
  local function recv(c, passes)
    as(c)
    for _ = 1, passes or 20 do
      c.F.clock = c.F.clock + 1
      local may, w = sync.authority(c.cfg, SONG, "main", sess)
      sync.soft = { room = "main", fn = function(name, pos, user) return claimask.soft(w, name, pos, user) end }
      local got = sync.receive(c.F.proj, c.cfg, SONG, "main", may)
      if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
    end
    link()
    settle(c)
  end
  local function mine(c) return files[RD .. "/claims/" .. c.cfg.user .. ".json"] or {} end
  local function auth() return select(2, sync.authority(A.cfg, SONG, "main", sess)) end
  local function told(pattern) for _, l in ipairs(logged) do if l:find(pattern) then return l end end end
  local function track_named(c, name) as(c); for _, t in ipairs(c.F.tracks) do if select(2, reaper.GetTrackName(t)) == name then return t end end end
  local function midi(pos, name)
    return table.concat({ "<ITEM", "POSITION " .. pos, "LENGTH 2", "LOOP 0", 'NAME "' .. name .. '"', "TAKE", 'NAME "' .. name .. '"',
      "<SOURCE MIDI", "HASDATA 1 960 QN", "E 0 90 3c 60", "E 480 80 3c 00", "E 1440 b0 7b 00", ">", ">" }, "\n") .. "\n"
  end

  -- the song, shared by the desktop; long enough ago that sharing it is nobody's work in progress
  local take = A.F.add_track("Take")
  A.F.add_item(take, midi(1, "T"))
  local keys = A.F.add_track("Keys")
  A.F.add_item(keys, midi(4, "K"))
  local rec = A.F.add_track("Rec")
  A.edited = A.F.clock
  settle(A); A.F.clock = A.F.clock + 70; settle(A)
  recv(L); L.F.clock = L.F.clock + 70; settle(L)
  T = T + sync.AUTO_IDLE + 120
  assert(track_named(L, "Take") and track_named(L, "Rec") and not auth().tracks.take, "the song is on both, nothing claimed")

  -- 3. nobody edits on the laptop; its REAPER reads Rec's setting its own way (a fresh REAPER's lane names): it goes out, and claims nothing
  as(L); reaper.SetMediaTrackInfo_Value(track_named(L, "Rec"), "D_VOL", 0.9)
  T = T + 2
  local out = look(L)
  assert(next(out) ~= nil, "the read-back goes out as before")
  assert(not auth().tracks.rec and #(mine(L).tracks or {}) == 0, "and claims nothing: nobody edited (LinuxBox2's XT Rec A)")
  settle(L); T = T + 2; recv(A)
  -- a new undo point of the person's own (a web page's edit isn't in Live sync's count): that claims
  as(L); reaper.SetMediaTrackInfo_Value(track_named(L, "Rec"), "D_VOL", 0.8); L.F.undo = "StudioSync web page: volume"
  T = T + 2
  look(L)
  assert(auth().tracks.rec and auth().tracks.rec.user == "Bee", "an undo point of the person's: claimed")
  settle(L); T = T + 2; recv(A)
  print("rt-fix6a 3: a look that sends what nobody edited claims nothing; an edit, or a person's undo point, does")

  -- 2. the desktop deletes Take while the laptop's Live sync is off; the laptop moves Take's item, then starts: its move goes out at once and
  -- auto-claims Take; the deletion, older than that claim, lands on the next receive, and the moved item goes with the track
  T = T + sync.AUTO_IDLE + 120
  as(A); reaper.DeleteTrack(take); A.edited = A.F.clock
  T = T + 2
  out = look(A)
  local gone_oid
  for oid, ev in pairs(out) do if ev.gone and ev.obj == "track" then gone_oid = oid end end
  assert(gone_oid, "the desktop's deletion of Take went out")
  settle(A)
  T = T + 60
  local ltake = track_named(L, "Take")
  -- (moved and muted: a move alone reads here as REAPER re-timing it (mirror.only_retimed); LinuxBox's REAPER writes the desktop's take its own
  -- way, so its move wasn't one)
  as(L); reaper.SetMediaItemInfo_Value(ltake.items[1], "D_POSITION", 1.5); reaper.SetMediaItemInfo_Value(ltake.items[1], "B_MUTE", 1); L.edited = L.F.clock
  T = T + 2
  logged = {}
  out = look(L)
  assert(next(out) ~= nil and auth().tracks.take and auth().tracks.take.user == "Bee", "the laptop's move went out and auto-claimed Take")
  recv(L, 3) -- (three passes: 3 s, well inside the minute a refused change waits)
  assert(not track_named(L, "Take"), "the deletion landed at once, not a minute later\n" .. table.concat(logged, "\n"))
  assert(not track_named(L, "Take (yours, not sent)"), "and the laptop's move of the desktop's item went with it: no '(yours, not sent)' track")
  assert(told("deleted a track on Take") or true)
  -- a take recorded here just now (new work of ours) is still kept when a deletion takes its track
  T = T + 2
  local lkeys = track_named(L, "Keys")
  as(L); L.F.add_item(lkeys, midi(8, "New")); L.edited = L.F.clock
  T = T + 2; settle(L)
  T = T + 2
  as(A); reaper.DeleteTrack(keys); A.edited = A.F.clock
  T = T + 2; look(A)
  local q = claimask.model(b).incoming[1] -- (Keys is Bee's auto-claim now: James asks, Bee releases it)
  assert(q and q.what == "Keys", "James asks Bee for Keys")
  as(L); claimask.answer(L.cfg, b, q.id, true); link()
  mirror.unsettled = nil
  settle(A)
  recv(L, 3)
  local kept = track_named(L, "Keys (yours, not sent)")
  assert(not track_named(L, "Keys"), "Keys deleted on the laptop too")
  as(L)
  assert(kept and #kept.items == 1, "but its new take, made here a moment ago, is kept on 'Keys (yours, not sent)'")
  print("rt-fix6a 2: a deletion older than this computer's auto-claim lands at once; an edit of the band's item goes with the track, a new take is kept")

  -- 4. the laptop auto-claims Rec2's item by moving it; the desktop moves it too (a clash) while the link can't reach the laptop
  local rec2 = A.F.add_track("Rec2")
  A.F.add_item(rec2, midi(2, "R"))
  A.F.add_item(rec2, midi(6, "R2"))
  A.edited = A.F.clock
  T = T + 2; settle(A); recv(L)
  T = T + sync.AUTO_IDLE + 120
  local lrec2 = track_named(L, "Rec2")
  as(L); reaper.SetMediaItemInfo_Value(lrec2.items[1], "D_POSITION", 2.5); L.edited = L.F.clock
  T = T + 2; settle(L); T = T + 2; recv(A)
  assert(auth().tracks.rec2 and auth().tracks.rec2.user == "Bee" and auth().tracks.rec2.auto, "Rec2 is Bee's auto-claim")
  local oid = rec2.items[1] and rec2.items[1].ext.band_oid
  reachable = false
  logged, wire = {}, {}
  as(A); reaper.SetMediaItemInfo_Value(rec2.items[1], "D_POSITION", 3); A.edited = A.F.clock
  T = T + 2
  out = look(A)
  assert(oid and out[oid], "the link can't reach Bee: the desktop's edit on Bee's auto-claim goes out, nobody asked\n" .. table.concat(logged, "\n"))
  assert(told("can't reach them to ask") and told("your edit went out"), "and says so")
  for _, m in ipairs(wire) do assert(m.kind ~= "claim_ask", "no ask sent") end
  as(A); assert(math.abs(reaper.GetMediaItemInfo_Value(rec2.items[1], "D_POSITION") - 3) < 1e-9, "not put back")
  settle(A)
  -- a deletion on it too: it goes
  local oid2 = rec2.items[2].ext.band_oid
  as(A); reaper.DeleteTrackMediaItem(rec2, rec2.items[2]); A.edited = A.F.clock
  T = T + 2
  out = look(A)
  as(A)
  assert(out[oid2] and out[oid2].gone and #rec2.items == 1, "a deletion on the auto-claim of someone the link can't reach goes out too")
  settle(A)
  -- a lasting claim: put back at once, saying why, not after 30 s
  as(L)
  local c = mine(L)
  claimask.add(c, { kind = "tracks", name = "Rec2" }, false)
  sync.set_claims(L.cfg, SONG, "main", c)
  link()
  T = T + 2; recv(A)
  logged = {}
  as(A); reaper.SetMediaItemInfo_Value(rec2.items[1], "D_POSITION", 3.5); A.edited = A.F.clock
  T = T + 2
  out = look(A)
  as(A)
  assert(not out[oid] and math.abs(reaper.GetMediaItemInfo_Value(rec2.items[1], "D_POSITION") - 3.5) > 1e-6, "a lasting claim the ask can't reach: put back at once")
  assert(told("can't reach them to ask") and told("put back"), "saying why")
  reachable = nil
  os.date = real_date
  print("rt-fix6a 4: a claimer the link can't reach: an auto-claim's edit goes out and says so; a lasting one's is put back at once")
end

print("ok rt-fix6a")
