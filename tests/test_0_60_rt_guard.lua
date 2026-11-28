-- rt-guard (docs/rt/rt-guard.md): no deletion goes out without a deletion of this person's behind it (W.gone), and moving windows isn't
-- "editing" (lib/follow.lua). From James's findings 2026-11-27 and docs/rt/rt-reopen.md (Cross Test's 3 tracks and 10 items, 11-23). Lua 5.4,
-- from the repo root. Parts 1 and 2 fail on 3ffc001 (W.gone sent every record whose object a look didn't see), and 7 (claim_of); 3 to 5 pin
-- what must keep working.
--  1. A project read with its records and none of its tracks (mid-close or mid-load, the edit count moved): nothing sent; left alone for
--     EMPTY_SECS, then the studio's tracks and items are back. rt-reopen's candidate A.
--  2. REAPER started on an older file whose records name tracks it doesn't hold: nothing sent, they're back from the studio, and a later look
--     with no edit sends nothing either. A file opened again in the same tab: the same. rt-reopen's candidate B.
--  3. A real deletion still goes: a track deleted by hand, every track deleted with REAPER's own undo point on top, a deletion made while the
--     project's tab is behind another.
--  4. REAPER's own Undo of a track deletion still brings it back for everyone (rt-converge 14 checks it in full; here with the guard's marks).
--  5. A deletion held for a claimer's answer goes on Release though nobody edited since (each absence is judged once).
--  6. (soak) tools/soak's "reopen" edit: a file without some of its tracks opened in the tab; no deletion may go out from that computer until
--     its next edit (node.lua checks in sync.post). Seeds 3 and 4 of --quick fail on 3ffc001: tests/run.py's soak step.
--  7. follow.lua: a window moved or a plug-in window opened isn't "is editing"; a drag begun on the arrange or a track's panel is.
--  8. (pure) mirror.wanted_order: a new track named under a track deleted since lands where that one sat (the soak's reopen found it).
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
require("prints").choose = function() end
local function midi(pos, len)
  return table.concat({ "<ITEM", "POSITION " .. pos, "SNAPOFFS 0", "LENGTH " .. len, "LOOP 0", "FADEIN 1 0 0 1 0 0 0", "FADEOUT 1 0 0 1 0 0 0", 'NAME "K"',
    "SOFFS 0", "PLAYRATE 1 1 0 -1 0 0.0025", "<SOURCE MIDI", "HASDATA 1 960 QN", "E 0 90 3c 60\nE 480 80 3c 00", "E 960 b0 7b 00", ">", ">" }, "\n") .. "\n"
end
local function told(pattern) for _, l in ipairs(logged) do if l:find(pattern) then return l end end end

-- ---- computers: the stand-in REAPER, each look and receive wired as Live sync wires them (as tests/test_0_60_rt_converge.lua) ---------------
local claimask = require("claimask")
local wire = {}
require("direct").send_live = function(cfg, kind, d) wire[#wire + 1] = { kind = kind, d = d, from = cfg.user }; return true end
claimask.reachable = function() return nil end
local here_now = {}
claimask.present = function(_, _, u) return here_now[u] == true end
local function studio(song, mode)
  local S = { song = song, dir = "R/" .. song .. "/rooms/main", sess = { host = "James", markers = {} }, b = { song = song, room = "main" } }
  files[S.dir .. "/mode.json"] = { mode = mode, by = "James" }
  local function as(c) reaper = c.F.reaper end
  S.as = as
  local function wire_up(c, user)
    c.F.reaper.GetMousePosition = function() return 0, 0 end
    c.F.reaper.file_exists = function(p) return not p:find("%.json$") or files[p] ~= nil end
    c.F.reaper.SetExtState(band.SECTION, "user", user, false)
  end
  function S.computer(user)
    local c = { F = E.new("C:/" .. user .. "/" .. song .. ".rpp"), cfg = { user = user, root = "R" }, user = user }
    require("undo").confirm = function() return true end
    wire_up(c, user)
    c.edited = -1
    return c
  end
  -- REAPER started again on a file: a new project, as the file had it (E.open). Live sync's count starts there: nothing edited yet.
  function S.open(c, snap) c.F = E.open(c.F.path, snap); wire_up(c, c.user); c.F.clock = 5000; c.edited = c.F.clock end
  local function link()
    while #wire > 0 do
      local m = table.remove(wire, 1)
      if m.kind == "claim" then sync.live_claim(song, "main", m.d) end
    end
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
    link()
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
      sync.soft = { room = "main", fn = function(name, pos, user) return claimask.soft(w, name, pos, user) end }
      local got = sync.receive(c.F.proj, c.cfg, song, "main", may)
      if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
    end
    link()
    if not no_look then S.settle(c) end
  end
  function S.names(c) local t = {}; for _, tr in ipairs(c.F.tracks) do t[#t + 1] = tr.name end; return table.concat(t, ", ") end
  function S.track(c, name) for _, t in ipairs(c.F.tracks) do if t.name == name then return t end end end
  function S.items(c, name) local t = S.track(c, name); return t and #t.items or -1 end
  function S.gone_by(user) local n = 0; for p, v in pairs(files) do if p:find(S.dir .. "/events/", 1, true) and type(v) == "table" and v.gone and v.user == user then n = n + 1 end end; return n end
  return S
end
-- the song both computers have: Drums (1 item), Keys (2), Gtr (1)
local function song(name, mode)
  local S = studio(name, mode or "everyone")
  local A, B = S.computer("James"), S.computer("Bee")
  S.edit(A, function(F)
    F.add_item(F.add_track("Drums"), midi(1, 2))
    local k = F.add_track("Keys"); F.add_item(k, midi(1, 2)); F.add_item(k, midi(4, 2))
    F.add_item(F.add_track("Gtr"), midi(2, 2))
  end)
  S.recv(B)
  assert(S.names(B) == "Drums, Keys, Gtr" and S.items(B, "Keys") == 2, "the song on both (" .. S.names(B) .. ")")
  return S, A, B
end

-- ---- 1. a project read with its records and none of its tracks (rt-reopen's candidate A) ---------------------------------------------------
do
  local S, A, B = song("Guard1")
  T = T + 600
  A.F.clock = A.F.clock + 600
  logged = {}
  -- REAPER closing (or loading) the project in the tab Live sync runs in: the tracks go, the records stay, and the edit count moved
  S.as(A)
  for i = #A.F.tracks, 1, -1 do A.F.tracks[i] = nil end
  A.F.changed()
  A.edited = A.F.clock
  S.look(A)
  assert(S.gone_by("James") == 0, "nothing goes out for a project read with no tracks (was: its 3 tracks and 4 items sent as deleted): " .. S.gone_by("James"))
  assert(#A.F.tracks == 0, "and nothing is put in it yet: it may be closing")
  assert(told("no tracks but still holds the studio's"), "said once")
  S.recv(B)
  assert(S.names(B) == "Drums, Keys, Gtr" and S.items(B, "Keys") == 2, "Bee keeps the song (" .. S.names(B) .. ")")
  -- still empty after EMPTY_SECS: the studio's tracks are put back, still nothing sent
  A.F.clock = A.F.clock + mirror.EMPTY_SECS + 1
  S.settle(A)
  assert(S.gone_by("James") == 0, "still nothing sent")
  assert(S.names(A) == "Drums, Keys, Gtr" and S.items(A, "Keys") == 2 and S.items(A, "Drums") == 1, "the studio's tracks and items are back: " .. S.names(A))
  print("rt-guard 1: a project read with its records and no tracks sends nothing, and gets the studio's song back")
end

-- ---- 2. REAPER started on an older file whose records name tracks it doesn't hold (rt-reopen's candidate B) ---------------------------------
do
  local S, A, B = song("Guard2")
  S.as(A)
  local snap = A.F.save()
  for i = #snap.tracks, 1, -1 do if snap.tracks[i].name ~= "Drums" then table.remove(snap.tracks, i) end end -- (the file: Drums only, every record)
  T = T + 600
  logged = {}
  S.open(A, snap)
  S.settle(A)
  assert(S.gone_by("James") == 0, "nothing goes out for what the file lacks (was: Keys, Gtr and their items sent as deleted): " .. S.gone_by("James"))
  -- (where they land is the order heal's to put right, as for any put-back: mirror.order_heal on opening)
  assert(S.track(A, "Keys") and S.track(A, "Gtr") and S.items(A, "Keys") == 2 and S.items(A, "Gtr") == 1, "they're back from the studio: " .. S.names(A))
  assert(told("weren't in this project, with no deletion of yours"), "and it's said")
  -- a later look, nobody editing: nothing either
  A.F.clock = A.F.clock + 40
  S.settle(A)
  assert(S.gone_by("James") == 0, "a later look with no edit: nothing")
  S.recv(B)
  assert(S.names(B) == "Drums, Keys, Gtr", "Bee keeps the song")
  -- a file opened again in the same tab (REAPER gives it a new master track; here mirror.opened forgets it), the edit count moved by the load
  S.as(A)
  local snap2 = A.F.save()
  for i = #snap2.tracks, 1, -1 do if snap2.tracks[i].name == "Gtr" then table.remove(snap2.tracks, i) end end
  A.F.clock = A.F.clock + 5
  A.F.load(snap2)
  mirror.opened[tostring(A.F.proj)] = nil
  A.edited = A.F.clock
  S.settle(A)
  assert(S.gone_by("James") == 0, "the same file opened again in its tab: nothing sent (" .. S.gone_by("James") .. ")")
  assert(S.track(A, "Gtr") and S.items(A, "Gtr") == 1, "Gtr is back: " .. S.names(A))
  -- and once the person edits, a real deletion of theirs goes (the opening's marks don't hold it back)
  A.F.clock = A.F.clock + 40
  S.edit(A, function() reaper.DeleteTrack(S.track(A, "Gtr")) end)
  assert(S.gone_by("James") >= 1, "a track deleted by hand after the opening goes out")
  S.recv(B)
  assert(not S.track(B, "Gtr"), "and Bee's Gtr goes: " .. S.names(B))
  print("rt-guard 2: an older file (REAPER restarted, or opened again in its tab) sends nothing for what it lacks; a later real deletion goes")
end

-- ---- 3. real deletions still go: by hand, every track with REAPER's undo point, and with the tab behind ------------------------------------
do
  local S, A, B = song("Guard3")
  T = T + 2
  S.edit(A, function() reaper.DeleteTrack(S.track(A, "Keys")) end)
  assert(S.gone_by("James") == 3, "Keys and its two items go out as deleted (" .. S.gone_by("James") .. ")")
  S.recv(B)
  assert(S.names(B) == "Drums, Gtr", "gone on Bee's: " .. S.names(B))
  -- an item deleted while another project's tab is in front (Live sync looks at its own project behind)
  S.as(A)
  local enum = A.F.reaper.EnumProjects
  rawset(A.F.reaper, "EnumProjects", function(i) if i == -1 then return "another tab", "C:/x.rpp" end; return enum(i) end)
  T = T + 2
  S.edit(A, function() local t = S.track(A, "Gtr"); A.F.remove_item(t.items[1]) end)
  rawset(A.F.reaper, "EnumProjects", enum)
  S.recv(B)
  assert(S.items(B, "Gtr") == 0, "a deletion made with the tab behind goes out (Bee's Gtr: " .. S.items(B, "Gtr") .. " items)")
  -- every track deleted, REAPER's own undo point on top: a person's delete-all goes (cross test step 1)
  T = T + 2
  S.as(A)
  A.F.clock = A.F.clock + 1
  for i = #A.F.tracks, 1, -1 do reaper.DeleteTrack(A.F.tracks[i]) end
  A.F.undo = "Remove tracks"
  A.edited = A.F.clock
  S.settle(A)
  S.recv(B)
  assert(#B.F.tracks == 0, "every track deleted with REAPER's undo point on top goes to Bee: " .. S.names(B))
  assert(#A.F.tracks == 0, "and stays deleted here: " .. S.names(A))
  print("rt-guard 3: a track deleted by hand, an item deleted with the tab behind, and a delete-all with its undo point all go out")
end

-- ---- 4. REAPER's own Undo of a track deletion brings it back for everyone (rt-converge 14, with the guard's marks set) ----------------------
do
  local S, A, B = song("Guard4")
  local gtr = S.track(A, "Gtr")
  local guid, body, item_guid, item_text = gtr.guid, gtr.body, gtr.items[1].guid, gtr.items[1].text
  T = T + 2
  S.edit(A, function() reaper.DeleteTrack(gtr) end)
  S.recv(B)
  assert(not S.track(B, "Gtr"), "deleted on both")
  T = T + 2
  S.edit(A, function(F)
    local t = F.add_track("Gtr", 3, body)
    t.guid, t.ext = guid, {}
    local it = F.add_item(t, item_text)
    it.guid, it.ext = item_guid, {}
  end)
  assert(S.track(A, "Gtr") and S.items(A, "Gtr") == 1, "Ctrl+Z: back on James's")
  S.recv(B)
  assert(S.track(B, "Gtr") and S.items(B, "Gtr") == 1, "and on Bee's")
  -- deleted again: it goes again (the mark of the first deletion went when the track came back)
  T = T + 2
  S.edit(A, function() reaper.DeleteTrack(S.track(A, "Gtr")) end)
  S.recv(B)
  assert(not S.track(B, "Gtr"), "a second deletion goes too: " .. S.names(B))
  print("rt-guard 4: REAPER's Undo of a track deletion sends it back; deleting it again goes again")
end

-- ---- 5. a deletion held for a claimer's answer goes on Release, with no edit of the deleter's since ----------------------------------------
do
  local S, A, B = song("Guard5", "open")
  here_now = { James = true, Bee = true }
  -- Bee edits Keys: hers while she edits (an auto-claim)
  T = T + sync.AUTO_IDLE + 120
  S.recv(B)
  S.edit(B, function() reaper.SetMediaTrackInfo_Value(S.track(B, "Keys"), "D_VOL", 0.5) end)
  S.recv(A)
  -- James deletes Keys: held for Bee's answer
  T = T + 2
  S.as(A)
  A.F.clock = A.F.clock + 1
  reaper.DeleteTrack(S.track(A, "Keys"))
  A.edited = A.F.clock
  S.look(A)
  mirror.unsettled = nil
  local held = S.gone_by("James") == 0 and not S.track(A, "Keys")
  -- Bee lets go of Keys; James's next looks come 40 s later, nobody edited since
  local c = sync.my_claims(B.cfg, "Guard5", "main")
  S.as(B)
  if c then c.tracks, c.auto = {}, {}; sync.set_claims(B.cfg, "Guard5", "main", c) end
  for _, f in ipairs(band.files(S.dir .. "/claims")) do local v = files[S.dir .. "/claims/" .. f]; if v and v.user == "Bee" then files[S.dir .. "/claims/" .. f] = nil end end
  sync.live_claim("Guard5", "main", { user = "Bee", tracks = {}, time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
  A.F.clock = A.F.clock + 40
  T = T + 40
  S.settle(A)
  if held then
    assert(S.gone_by("James") >= 1, "the held deletion goes once Keys is free, though James didn't edit since (was it judged afresh, it came back)")
    print("rt-guard 5: a deletion held for a claimer goes when it's released, with no edit since")
  else
    -- (the room let the deletion go at once: nothing was held, which the guard must not stop either)
    assert(S.gone_by("James") >= 1, "James's deletion of Keys went out")
    print("rt-guard 5: (not held in this room) James's deletion of Keys went out")
  end
end

-- ---- 7. follow.lua: what counts as "is editing" ---------------------------------------------------------------------------------------------
do
  local follow = require("follow")
  assert(follow.drag_spot("arrange") and follow.drag_spot("tcp") and follow.drag_spot("tcp.mute") and follow.drag_spot("mcp.volume"),
    "a press on the arrange or a track's panel starts a drag of what's selected")
  for _, x in ipairs({ "", "fx_chain", "fx_0", "spacer_0", "ruler", nil, 5 }) do
    assert(not follow.drag_spot(x), "a press anywhere else isn't editing: " .. tostring(x))
  end
  local base = { editor = { o = "I9", w = "plug-in ReaEQ on Bass" }, editor_age = 0, changed_ago = 999, held = 0, items = {}, tracks = { "T1" } }
  assert(follow.claim_of(base) == nil, "a plug-in window just opened (or moved about), no change: not editing (was: 'is editing' for two minutes)")
  base.changed_ago = 5
  assert(follow.claim_of(base) == "editor", "a change of yours while it's open: editing")
  -- where the press was: a window's title bar (another program, or REAPER's own edge) isn't on the project
  local saved = reaper
  reaper = { GetMousePosition = function() return 10, 10 end, GetThingFromPoint = function() return nil, "" end }
  assert(follow.down_on_project() == false, "pressed on a window's title bar: not a drag")
  reaper.GetThingFromPoint = function() return nil, "arrange" end
  assert(follow.down_on_project() == true, "pressed on the arrange: a drag")
  reaper = { GetMousePosition = function() return 10, 10 end }
  assert(follow.down_on_project() == false, "a REAPER that can't say where: not counted")
  reaper = saved
  print("rt-guard 7: moving or resizing a window, or opening a plug-in window, isn't editing; a drag on the arrange is")
end

-- ---- 8. (pure) a new track named under a track deleted since lands where that one sat, not at the end (the soak's reopen, seed 37) ------
do
  local function w(list, here, after) return table.concat(mirror.wanted_order(list, here, after), ",") end
  assert(w({ "A", "B", "C" }, { "B", "C", "N" }, { N = "A" }) == "N,B,C", "under the deleted top track: at the top, as every computer had it (was: at the end)")
  assert(w({ "A", "B", "C" }, { "A", "C", "N" }, { N = "B" }) == "A,N,C", "under a deleted middle track: where it sat")
  assert(w({ "A", "B" }, { "A", "B", "N" }, { N = "Z" }) == "A,B,N", "under a track nobody listed: at the end, as before")
  print("rt-guard 8: a new track under a deleted one lands where that one sat")
end

-- ---- 9. a delete-all right after another deletion, both REAPER's "Remove tracks" (rt-live bug 1, sync2c c1.4b; c1.4c is part 3) ----------
-- Fails on 52ce885: the undo point was told by its name, so the second "Remove tracks" wasn't a new point; the emptied project waited, then
-- the studio's tracks came back with nothing sent.
do
  local S, A, B = song("Guard9")
  T = T + 2
  S.as(A)
  A.F.clock = A.F.clock + 1
  reaper.DeleteTrack(S.track(A, "Keys"))
  A.F.undo, A.F.undo_n = "Remove tracks", 1
  A.edited = A.F.clock
  S.settle(A)
  assert(S.gone_by("James") == 3, "Keys and its two items go (" .. S.gone_by("James") .. ")")
  T = T + 17
  A.F.clock = A.F.clock + 17
  for i = #A.F.tracks, 1, -1 do reaper.DeleteTrack(A.F.tracks[i]) end
  A.F.undo, A.F.undo_n = "Remove tracks", 2
  A.edited = A.F.clock
  S.settle(A)
  A.F.clock = A.F.clock + mirror.EMPTY_SECS + 1
  S.settle(A)
  assert(#A.F.tracks == 0, "the delete-all stays deleted here (was: put back after EMPTY_SECS): " .. S.names(A))
  S.recv(B)
  assert(#B.F.tracks == 0, "and goes to Bee: " .. S.names(B))
  print("rt-guard 9: a delete-all right after another deletion (two \"Remove tracks\" in a row) goes")
end

-- ---- 10. an older file opened in the same tab: REAPER keeps the master track; Live sync's load guard settles again (rt-live bugs 2, 3) --------
-- Fails on 52ce885: the reopen wasn't seen (mirror.on_open went by the master track; sync2c c3).
do
  local S, A, B = song("Guard10")
  local guard = require("loadguard")
  S.as(A)
  local old = A.F.save() -- (the file: Drums, Keys, Gtr)
  T = T + 5
  S.edit(B, function(F) F.add_track("Bass") end)
  S.recv(A)
  assert(S.track(A, "Bass"), "Bee's Bass on James's: " .. S.names(A))
  -- a save: the load guard settles again, the tracks stay. Not an opening: a deletion made just before it still goes
  T = T + 5
  S.as(A)
  A.F.clock = A.F.clock + 1
  reaper.DeleteTrack(S.track(A, "Gtr"))
  A.edited = A.F.clock
  local pk = tostring(A.F.proj)
  guard.loads[pk] = (guard.loads[pk] or 1) + 1
  S.settle(A)
  assert(S.gone_by("James") == 2, "a deletion saved before the look still goes (" .. S.gone_by("James") .. ")")
  S.recv(B)
  assert(not S.track(B, "Gtr"), "Gtr gone on Bee's: " .. S.names(B))
  -- File > Open of the older file in the same tab: the same master track, new tracks; the guard settles again, the load moved the count
  T = T + 5
  S.as(A)
  A.F.clock = A.F.clock + 1
  local master = reaper.GetMasterTrack(A.F.proj)
  A.F.load(old)
  assert(reaper.GetMasterTrack(A.F.proj) == master, "(the stand-in keeps the master track, as REAPER does)")
  guard.loads[pk] = guard.loads[pk] + 1
  A.edited = A.F.clock
  local gone_before, opening = S.gone_by("James"), mirror.opened[pk]
  S.settle(A)
  assert(mirror.opened[pk] ~= opening, "a new opening (was: the same master track, so not one)")
  S.recv(A)
  assert(S.gone_by("James") == gone_before, "nothing sent for what the older file lacks")
  print("rt-guard 10: an older file opened in the same tab is a new opening; a save isn't one")
end

print("ok rt-guard")
