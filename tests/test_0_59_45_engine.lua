-- 0.59.45 (Round 1 review, sync engine): two people's merges agree everywhere, heal and trim keep three-way merges, saved versions restore
-- by their own map, an undo of a multi-object act counts all of it, what waits to go out, Hold holds the timeline, paths a band's version put
-- here are never copied, and a track's parts are keyed before its items.
package.path = "lib/?.lua;" .. package.path
local exts, gext, clock = {}, {}, 1000
local function sec_of(p, sec) exts[p] = exts[p] or {}; exts[p][sec] = exts[p][sec] or {}; return exts[p][sec] end
local items, tracks = {}, {}
reaper = setmetatable({
  GetProjExtState = function(p, sec, k) local v = sec_of(p, sec)[k] or ""; return v ~= "" and 1 or 0, v end,
  SetProjExtState = function(p, sec, k, v) sec_of(p, sec)[k] = v end,
  EnumProjExtState = function(p, sec, i)
    local keys = {}
    for k in pairs(sec_of(p, sec)) do keys[#keys + 1] = k end
    table.sort(keys)
    local k = keys[i + 1]
    if k then return true, k, sec_of(p, sec)[k] end
    return false
  end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  time_precise = function() return clock end,
  EnumProjects = function() return nil end,
  -- items for mirror.find: { oid, guid, tr }; tracks: { local = true }
  CountMediaItems = function() return #items end,
  GetMediaItem = function(_, i) return items[i + 1] end,
  GetMediaItem_Track = function(it) return it.tr end,
  GetSetMediaItemInfo_String = function(it, k, v, set)
    if k == "P_EXT:band_oid" then if set then it.oid = v end; return true, it.oid or "" end
    if k == "GUID" then return true, it.guid or "" end
    return true, ""
  end,
  GetSetMediaTrackInfo_String = function(tr, k) return true, (k == "P_EXT:band_local" and tr["local"]) and "yours" or "" end,
  ValidatePtr2 = function() return true end,
}, { __index = function() return function() end end })

local store = {}
local band = require("band")
local real_read = band.read_json
package.loaded.band = setmetatable({ read_json = function(path)
  local id = path:match("/events/(.+)%.json$")
  if id then return store[id] end
  return real_read(path)
end }, { __index = band })
local mirror = require("mirror")
local R = "ROOM"

-- S1: two people, one item. Al moves it, then sets a fade in the same edit (same rev); Bo, having seen neither, moves it elsewhere. Every
-- computer ends on the same version, whatever order the events reached it in (the judge, mirror.judge, since rt-sync2b: merge_for's path)
local function st(pos, fade, vol) return "<ITEM\nPOSITION " .. pos .. "\nLENGTH 2\nFADEIN " .. fade .. "\nVOLPAN " .. vol .. " 0 1 -1\n>\n" end
local function ev(id, t) t.id, t.obj, t.oid, t.type = id, t.obj or "item", t.oid or "I-X", "obj"; store[id] = t; return t end
local V0 = ev("Zed-20261118-090000Z-00001-0001", { rev = 1, base = 0, state = st(0, 0, 1), user = "Zed", hlc = 100 })
local function recv(P, e)
  local js = mirror.judge(P, e.oid, R, { e })
  assert(js.complete, "nothing on its way")
  if mirror.lands(P, js) then mirror.remember(P, e.oid, js.v.rev, "h", js.v.id, mirror.order_of(js.v)) end
end
for _, P in ipairs({ "A", "B", "C" }) do mirror.remember(P, "I-X", 1, "h", V0.id, mirror.order_of(V0)) end
local A1 = ev("Al-20261118-100001Z-00001-0001", { rev = 2, base = 1, base_ev = V0.id, state = st(5, 0, 1), user = "Al", hlc = 200 })
mirror.remember("A", "I-X", 2, "h", A1.id, mirror.order_of(A1))
local B1 = ev("Bo-20261118-100002Z-00002-0001", { rev = 2, base = 1, base_ev = V0.id, state = st(9, 0, 1), user = "Bo", hlc = 250 })
mirror.remember("B", "I-X", 2, "h", B1.id, mirror.order_of(B1))
local A2 = ev("Al-20261118-100003Z-00003-0001", { rev = 2, base = 2, base_ev = A1.id, state = st(5, 1, 1), user = "Al", hlc = 300 })
mirror.remember("A", "I-X", 2, "h", A2.id, mirror.order_of(A2))
recv("B", A1); recv("B", A2)
recv("A", B1)
recv("C", B1); recv("C", A2)
local held = {}
for _, P in ipairs({ "A", "B", "C" }) do
  local _, _, kev = mirror.known(P, "I-X")
  local e = mirror.event_file(R, kev)
  held[P] = e and e.state
end
assert(held.A and held.A == held.B and held.B == held.C, "two people's edits end the same on every computer:\nA " .. tostring(held.A) .. "\nB " .. tostring(held.B))

-- S2: three people change one item apart; every computer agrees on the three-way merge, and heal (mirror.settled) keeps it, not newest + one
local T0 = ev("Zed-20261118-080000Z-00001-0002", { oid = "I-T", rev = 1, base = 0, state = st(0, 0, 1), user = "Zed", hlc = 1000 })
local TA = ev("Al-20261118-081000Z-00001-0002", { oid = "I-T", rev = 2, base = 1, base_ev = T0.id, state = st(5, 0, 1), user = "Al", hlc = 2000 })
local TB = ev("Bo-20261118-081100Z-00001-0002", { oid = "I-T", rev = 2, base = 1, base_ev = T0.id, state = st(0, 1, 1), user = "Bo", hlc = 2500 })
local TC = ev("Cy-20261118-081200Z-00001-0002", { oid = "I-T", rev = 2, base = 1, base_ev = T0.id, state = st(0, 0, 0.5), user = "Cy", hlc = 3000 })
local s = mirror.settled(R, TC, { T0, TA, TB, TC })
assert(s.state:find("POSITION 5", 1, true) and s.state:find("FADEIN 1", 1, true) and s.state:find("VOLPAN 0.5", 1, true),
  "heal settles on all three changes, not the newest and one rival: " .. tostring(s.state))

-- S2: trim keeps every change made apart that nothing builds on (all three leaves), so the merge can still be rebuilt after 60 days
local trim = require("trim")
local old = "2026-01-01T00:00:00Z"
local function tev(id, rev, base_ev, hlc) return { id = id, type = "obj", oid = "I-T", rev = rev, base_ev = base_ev, time = old, hlc = hlc, user = id:match("^(%a+)") } end
local evs = { tev("Zed-1", 1, nil, 1), tev("Al-1", 2, "Zed-1", 2), tev("Bo-1", 2, "Zed-1", 3), tev("Cy-1", 2, "Zed-1", 4) }
local gone = {}
for _, id in ipairs(trim.plan(evs, {}, "2026-06-01T00:00:00Z")) do gone[id] = true end
assert(not gone["Al-1"] and not gone["Bo-1"] and not gone["Cy-1"], "all three leaves of a three-way merge stay")
assert(not gone["Zed-1"], "and their base")
-- and a change something builds on still goes (a losing branch doesn't keep history growing)
evs[#evs + 1] = tev("Al-2", 2, "Al-1", 5)
gone = {}
for _, id in ipairs(trim.plan(evs, {}, "2026-06-01T00:00:00Z")) do gone[id] = true end
assert(not gone["Al-2"] and not gone["Bo-1"], "the leaves stay")

-- D4: a saved version's own map: trim keeps what it names, and restoring builds the plan from it
local mevs = { { id = "Me-1", type = "obj", oid = "I-Y", rev = 1, time = old }, { id = "Me-2", type = "obj", oid = "I-Y", rev = 2, base_ev = "Me-1", time = old } }
gone = {}
for _, id in ipairs(trim.plan(mevs, { { time = "2000-01-01T00:00:00Z", keep = true, label = "x", known = { ["I-Y"] = "Me-1" } } }, "2026-06-01T00:00:00Z")) do gone[id] = true end
assert(not gone["Me-1"], "a version a kept point's map names stays")
local entries = {
  { kind = "obj", id = "Me-1", oid = "I-Y", rev = 1, base = 0, time = "2026-11-18T10:00:00Z", user = "Me", state = "a" },
  { kind = "obj", id = "Bo-1", oid = "I-Y", rev = 2, base = 1, base_ev = "Me-1", time = "2026-11-18T09:00:00Z", user = "Bo", state = "b" }, -- (clock behind)
  { kind = "obj", id = "Bo-2", oid = "I-Z", rev = 1, base = 0, time = "2026-11-18T09:00:00Z", user = "Bo", state = "z" }, -- (made alone, clock behind)
}
local by = {}
for _, e in ipairs(entries) do by[e.id] = e end
local plan = mirror.plan_known(entries, { ["I-Y"] = "Me-1" }, function(id) return by[id] end)
assert(plan["I-Y"] and plan["I-Y"].id == "Me-1" and plan["I-Z"] == false, "exactly what the project held: Bo's late edit and new item aren't taken in")
local P9 = "P9"
mirror.remember(P9, "I-K", 3, "abc", "Me-7", "1|Me")
mirror.remember(P9, "I-G", 4, "", "Me-8", "1|Me")
local km = mirror.known_map(P9)
assert(km["I-K"] == "Me-7" and km["I-G"] == nil, "the map holds what's here, not what's gone")

-- S11: three items deleted at once, then undone: every one of them counts as undone, so the next press undoes the change before
local E = {}
local function add(e) e.kind = "obj"; e.obj = e.obj or "item"; e.user = e.user or "Me"; e.name = e.name or "Keys"; E[#E + 1] = e; return e end
local ist = "<ITEM\nPOSITION 1\n>\n"
add{ id = "Me-1", oid = "I-A", rev = 1, base = 0, time = "2026-11-18T10:00:00Z", state = ist, track = "T-K" }
add{ id = "Me-2", oid = "I-B", rev = 1, base = 0, time = "2026-11-18T10:00:00Z", state = ist, track = "T-K" }
add{ id = "Me-3", oid = "I-C", rev = 1, base = 0, time = "2026-11-18T10:00:00Z", state = ist, track = "T-K" }
add{ id = "Me-4", oid = "I-D", rev = 1, base = 0, time = "2026-11-18T10:00:01Z", state = ist, track = "T-K" }
add{ id = "Me-5", oid = "I-D", rev = 2, base = 1, base_ev = "Me-4", time = "2026-11-18T10:01:00Z", state = ist, track = "T-K" }
add{ id = "Me-6", oid = "I-A", rev = 2, base = 1, base_ev = "Me-1", time = "2026-11-18T10:02:00Z", gone = true, track = "T-K", act = "D" }
add{ id = "Me-7", oid = "I-B", rev = 2, base = 1, base_ev = "Me-2", time = "2026-11-18T10:02:00Z", gone = true, track = "T-K", act = "D" }
add{ id = "Me-8", oid = "I-C", rev = 2, base = 1, base_ev = "Me-3", time = "2026-11-18T10:02:00Z", gone = true, track = "T-K", act = "D" }
-- (lib/undo.lua since rt-sync2i: the act by its `act`, the plan from what each version was built on)
local undo = require("undo")
local function rd(list) local by = {}; for _, e in ipairs(list) do by[e.id] = e end; return function(id) return by[id] end end
local g = undo.last_mine(E, "Me")
local p1, _, ids = undo.plan(E, g.rows, rd(E), function() end)
assert(p1["I-A"] and p1["I-B"] and p1["I-C"] and #ids == 3, "the act's three ids come with its plan")
for _, oid in ipairs({ "I-A", "I-B", "I-C" }) do
  add{ id = "Me-r" .. oid, oid = oid, rev = 3, time = "2026-11-18T10:03:00Z", state = ist, restored = p1[oid].id, undoes = E[g.top].id, undoes_all = ids, track = "T-K", act = "U" }
end
assert(E[undo.last_mine(E, "Me").top].id == "Me-5", "the next undo is the change before the act, not the same restore again")

-- S5: a track deleted with its items in one act (items on two lanes): undoing it brings the track and all its items
local F = {}
local function addf(e) e.kind = "obj"; e.user = "Me"; e.name = "Keys"; F[#F + 1] = e; return e end
addf{ id = "Me-t1", obj = "track", oid = "T-K", rev = 1, base = 0, time = "2026-11-18T09:00:00Z", state = { name = "Keys" } }
addf{ id = "Me-i1", obj = "item", oid = "I-A", rev = 1, base = 0, time = "2026-11-18T09:00:01Z", state = "<ITEM\n>\nBANDLANE 0\n", track = "T-K" }
addf{ id = "Me-i2", obj = "item", oid = "I-B", rev = 1, base = 0, time = "2026-11-18T09:00:01Z", state = "<ITEM\n>\nBANDLANE 1\n", track = "T-K" }
addf{ id = "Me-g1", obj = "item", oid = "I-A", rev = 2, base = 1, base_ev = "Me-i1", time = "2026-11-18T10:00:00Z", gone = true, track = "T-K", act = "D" }
addf{ id = "Me-g2", obj = "item", oid = "I-B", rev = 2, base = 1, base_ev = "Me-i2", time = "2026-11-18T10:00:00Z", gone = true, track = "T-K", act = "D" }
addf{ id = "Me-gt", obj = "track", oid = "T-K", rev = 2, base = 1, base_ev = "Me-t1", time = "2026-11-18T10:00:00Z", gone = true, act = "D" }
local p5 = undo.plan(F, undo.moment(F, 4), rd(F), function() end) -- (History's "Undo this change" on the first item's row)
assert(p5["T-K"] and p5["T-K"].id == "Me-t1", "undoing the items brings their track deleted with them")
assert(p5["I-B"] and p5["I-B"].id == "Me-i2", "and its items on its other lanes")

-- C3, C2: what waits to go out (Sync and exit), and stale flags swept
mirror.more = false
mirror.held_back.P1 = { ["I-1"] = true }
assert(mirror.waiting("P1"), "an item held back (a failed copy, missing audio) counts")
mirror.held_back.P1 = nil
mirror.unsent["P1I-2"] = true
assert(mirror.waiting("P1"), "an unsent change counts (Hold my changes, which kept them out of it, is gone: rt-nohold)")
mirror.unsent["P1I-2"] = nil
assert(mirror.waiting("P1") == nil, "nothing waiting: nil")
mirror.unsent["P1I-9"] = true -- (flagged before it ever went out, then deleted)
mirror.unsent["P1I-8"] = true -- (known to the band: a held delete)
mirror.unsent["P1I-7"] = true -- (still here)
mirror.remember("P1", "I-8", 2, "h8", "Me-x", "1|Me")
mirror.sweep_unsent("P1", { ["I-7"] = true })
assert(not mirror.unsent["P1I-9"] and mirror.unsent["P1I-8"] and mirror.unsent["P1I-7"], "only a flag on something neither here nor known goes")

-- D3: an unsent flag counts as an edit here (revert and heal leave it); a gone record isn't one
mirror.unsent["P1F-5"] = true
assert(mirror.edited_here("P1", "F-5", "h") and not mirror.edited_here("P1", "F-6", ""), "revert and heal leave what hasn't gone out")
mirror.unsent["P1F-5"] = nil

-- S3: two items carry one id, the copy on a track of your own after the studio's in project order: find takes the studio's
local band_tr, own_tr = {}, { ["local"] = true }
local orig = { oid = "I-DUP", guid = "{G1}", tr = band_tr }
local copy = { oid = "I-DUP", guid = "{G2}", tr = own_tr }
items = { orig, copy }
reaper.SetProjExtState("PF", mirror.GSEC, "I-DUP", "{G1}")
assert(mirror.find("PF", "item", "I-DUP") == orig, "the studio's item, by its recorded GUID, not the last copy")
mirror.index_for("PF")
assert(mirror.find("PF", "item", "I-DUP") == orig, "through the receive index too")
mirror.index_for(nil)
reaper.SetProjExtState("PF", mirror.GSEC, "I-DUP", "")
assert(mirror.find("PF", "item", "I-DUP") == orig, "no GUID recorded: the one on a studio track")
reaper.SetProjExtState("PF", mirror.GSEC, "I-DUP", "{G1}")
items = { copy } -- the original deleted, the copy left
local is_it, stray = mirror.local_copy_is_it("PF", "I-DUP")
assert(not is_it and stray == copy, "a copy that kept the id isn't the studio's item still here: the delete goes out")
items = {}

-- H6: sync.authority hands back this room's claims, so callers needn't read the module's last ones
local sync = require("sync")
package.loaded.band.files = function() return {} end
local _, who = sync.authority({ root = "root", user = "Me" }, "S", "main", { host = "Me" })
assert(type(who.is_claimed) == "function" and who.owner_of == who.owner, "who.is_claimed and who.owner_of")
package.loaded.band.files = nil

-- owner step: an owner's change (claimed by them, or they drive and it's unclaimed)
assert(mirror.owned({ mode = "claims", can = function() return true end }, "Me", "Keys", nil, function(n) return n == "Keys" end), "a claimant's change is owned")
assert(not mirror.owned({ mode = "everyone", can = function() return true end }, "Me", "Keys", nil, function() return true end), "not in Everyone")

-- S7 (Hold my changes is gone, rt-nohold): the band's timeline lands whatever this project's own timeline was
local applied = 0
band.capture_tempo = function() return { { time = 0, bpm = 140 } } end -- (here: changed on Hold)
band.capture_markers = function() return {} end
band.capture_project = function() return {} end
band.apply_tempo = function() applied = applied + 1 end
band.apply_project, band.apply_markers = function() end, function() end
sync.audio_follow_tempo, sync.resnap = function() end, function() end
local PT = "PT"
reaper.SetProjExtState(PT, band.SECTION, "timeline", band.json_encode({ { { time = 0, bpm = 120 } }, {}, {}, 2 })) -- (the band's last, seen)
local tl = { type = "timeline", tempo = { { time = 0, bpm = 100 } }, markers = {} }
assert(sync.apply(PT, tl, "R", function() return true end, "Me") == true and applied == 1, "it lands")

-- X2, X12, CP2: a path a band's chain put on this track is never copied out; nor a hidden file's name or REAPER's own folder written to
local fxfiles = require("fxfiles")
local copied = {}
band.copy_atomic = function(from, to) copied[#copied + 1] = { from = from, to = to } end
band.size = function() return 10 end
reaper.file_exists = function(p) return not p:find("plugin files", 1, true) and not p:find("Samples/new", 1, true) end
local chain = "<FXCHAIN\nsample D:/Private/Docs/taxes.wav\n>\n"
fxfiles.share(chain, "M", nil, nil, { [fxfiles.key("D:\\Private\\Docs\\taxes.wav")] = true })
assert(#copied == 0, "a path the band's chain put here isn't copied, however its slashes read")
fxfiles.share(chain, "M", "<FXCHAIN\nsample D:\\Private\\Docs\\taxes.wav\n>\n", nil)
assert(#copied == 0, "nor one in the band's last version written with the other slash")
fxfiles.share(chain, "M", nil, nil)
assert(#copied == 1, "your own sample still goes")
reaper.GetResourcePath = function() return "C:\\REAPER" end
assert(not fxfiles.safe({ path = "D:/Samples/.hidden.wav", copy = "plugin files/x.wav" }), "a hidden file's name is refused")
assert(not fxfiles.safe({ path = "C:/REAPER/Effects/x.wav", copy = "plugin files/x.wav" }), "and REAPER's own folder")
assert(fxfiles.safe({ path = "D:/Samples/kick.wav", copy = "plugin files/x.wav" }), "a plain sample path is fine")
copied = {}
band.WIN = true
reaper.EnumerateSubdirectories = function() return "x" end
reaper.file_exists = function(p) return p:find("plugin files", 1, true) ~= nil end -- (the shared copy is here, the sample isn't)
fxfiles.fetch({ { path = "D:\\Samples\\new\\kick.wav", copy = "plugin files/k.wav" } }, "M", "Keys")
assert(copied[1] and not copied[1].to:find("\\", 1, true), "a Windows path is put back with '/' for copy_atomic")
-- an item's paths outside the studio's media (what apply records as the band's)
local ip = mirror.item_paths('<ITEM\n<SOURCE WAVE\nFILE "{media:main}/a.wav"\n>\n<SOURCE WAVE\nFILE "C:/x/y.wav"\n>\n>\n')
assert(#ip == 1 and ip[1] == "C:/x/y.wav", "only paths outside the studio's media")
-- (they're kept in one P_EXT line: a line break in it broke the item's chunk, and it no longer read back as sent: take_comps)
local ext_v = "c:/a.wav|d:/b.wav"
local was_get = reaper.GetSetMediaItemInfo_String
reaper.GetSetMediaItemInfo_String = function(_, k) return true, k == mirror.THEIRS and ext_v or "" end
local got = mirror.theirs({})
assert(got["c:/a.wav"] and got["d:/b.wav"], "paths kept on one line, read back as a set")
reaper.GetSetMediaItemInfo_String = was_get

-- P2: a track's parts worked out from its chunk up to its first item are the same as from the whole chunk (nothing of the track's follows)
local full = table.concat({ "<TRACK", 'NAME "Keys"', "VOLPAN 1 0 -1 -1 1", "<FXCHAIN", "SHOW 0", 'BYPASS 0 0 0', '<JS "JS: tone" ""', "1 2 3", ">",
  "FLOATPOS 0 0 0 0", "FXID {X}", "WAK 0 0", ">", "<VOLENV2", "ACT 1 -1", "PT 0 1 0", ">", "AUXRECV 0 0 1 0 0 0 0 0 0 -1:U 0 -1 ''",
  "<ITEM", "POSITION 0", "LENGTH 1", "<SOURCE MIDI", "E 0 90 3c 60", ">", ">", "<ITEM", "POSITION 2", ">", ">" }, "\n") .. "\n"
local head = mirror.track_head(full)
assert(#head < #full and not head:find("<ITEM", 1, true), "cut before its first item")
local frozen = full:gsub("<VOLENV2", "<FREEZE 1\n<ITEM\nPOSITION 0\n>\n>\n<VOLENV2", 1)
assert(mirror.track_head(frozen) == frozen, "a frozen track's chunk isn't cut inside its <FREEZE block, which holds items")
local a, b = mirror.track_head_parts(full, "", function() return "T-0" end), mirror.track_head_parts(head, "", function() return "T-0" end)
for _, k in ipairs({ "fx", "fxh", "env", "recv", "misc" }) do assert(a[k] == b[k], "the parts' " .. k .. " are the same without the items") end
assert(a.fx:find("JS: tone", 1, true) and a.env ~= "", "and they're really there")
print("ok")
