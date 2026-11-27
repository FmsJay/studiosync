-- rt-sync2 phase 2 (docs/rt/rt-sync2b.md): the judge (lib/judge.lua), what one object is from its own versions. Property tests over random
-- histories of one object (forks, merges named as bases, deletions, restores built on them), each fed in many arrival orders:
--   1. every order gives the same answer, and the same merged state;
--   2. the same versions twice change nothing;
--   3. a leaf that isn't a deletion and doesn't build on every deletion here is never the answer (one rule for every kind);
--   4. an incomplete answer never returns a version, and names what's missing; once that arrives the answer is complete;
--   5. a version a walk needs that is older than MERGE_DAYS counts as trimmed, not as on its way;
-- and the cases the design names: a restore beats an edit made apart from it when the edit didn't see the deletion; a fork of two edits is
-- one merge whose name is the same on every computer; more than MAX_LEAVES leaves goes to the newest unmerged. Lua 5.4, from the repo root.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local judge = require("judge")

local seed = 20261127
local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return n and (seed % n) + 1 or seed / 2147483648 end
local USERS = { "James", "Bee", "Cee" }

-- An id dated `t` seconds after 2026-11-22 12:00 UTC, as sync.post makes them.
local function stamp(t) -- (t under an hour: the same day)
  return string.format("20261122-12%02d%02dZ", t // 60, t % 60)
end

-- A random history: each version an edit (a set of tokens), a deletion, or a restore (built on a deletion), built on one earlier version or
-- on a merge of two leaves. Its `read` rebuilds merges as every computer would: the union of both sides' tokens, under the merge's own id.
local function history(n)
  local vs, by, t, clock = {}, {}, 0, 0
  local function add(v) vs[#vs + 1] = v; by[v.id] = v; return v end
  local function state_of(id)
    local w, l = judge.split_merge(id)
    if w then
      local a, b = state_of(w), state_of(l)
      if not (a and b) then return nil end
      local set, out = {}, {}
      for x in (a .. " " .. b):gmatch("%S+") do if not set[x] then set[x] = true; out[#out + 1] = x end end
      table.sort(out)
      return table.concat(out, " ")
    end
    local v = by[id]
    return v and (v.state or "")
  end
  local root = add({ id = "James-" .. stamp(0) .. "-0", rev = 1, hlc = 1000, user = "James", state = "a" })
  for i = 1, n do
    t, clock = t + rnd(20), clock + rnd(900)
    local user = USERS[rnd(3)]
    local on = vs[rnd(#vs)]
    local base_ev = on.id
    if rnd(6) == 1 and #vs > 2 then -- built on a merge of two versions (what a computer held after merging them)
      local other = vs[rnd(#vs)]
      if other.id ~= on.id then base_ev = judge.merge_id(on.id, other.id) end
    end
    local kind = rnd(10)
    local v = { id = string.format("%s-%s-%d", user, stamp(t), i), user = user, base_ev = base_ev, rev = (on.rev or 0) + rnd(2) - 1, hlc = 1000 + clock }
    if kind == 1 then v.gone = true
    elseif kind == 2 and on.gone then v.state = "restored" .. i -- a restore: an Undo of the deletion, built on it
    else v.state = (state_of(on.id) or "") .. " t" .. i end
    add(v)
  end
  local function read(id)
    local w = judge.split_merge(id)
    if not w then return by[id] end
    local st = state_of(id)
    if not st then return nil, true end
    return { id = id, state = st, rev = 1, hlc = 0 }
  end
  return vs, read, by
end
local function mergeable(x) return not x.gone and type(x.state) == "string" end
local function shuffled(t)
  local out = {}
  for i, x in ipairs(t) do out[i] = x end
  for i = #out, 2, -1 do local j = rnd(i); out[i], out[j] = out[j], out[i] end
  return out
end
local function answer(s) return s.v and (s.v.id .. "\0" .. tostring(s.v.state) .. "\0" .. tostring(s.gone)) or ("none " .. tostring(s.complete)) end

-- 1, 2, 3: arrival order, duplicates, deletions
local merges, gones, restores = 0, 0, 0
for case = 1, 300 do
  local vs, read, by = history(3 + rnd(14))
  local opt = { mergeable = mergeable }
  local s = judge.settled(vs, read, opt)
  assert(s.complete, "case " .. case .. ": everything is here, so the answer is complete")
  assert(s.v, "case " .. case .. ": an answer")
  local want = answer(s)
  for k = 1, 30 do
    local order = shuffled(vs)
    if k % 5 == 0 then for _, x in ipairs(shuffled(vs)) do order[#order + 1] = x end end -- (each version twice)
    local s2 = judge.settled(order, read, opt)
    assert(answer(s2) == want, "case " .. case .. ": another arrival order gave " .. answer(s2) .. " not " .. want)
  end
  -- (3) the answer, if it isn't gone, builds on every deletion here; and nothing beaten is in it
  if not s.gone then
    for _, v in ipairs(vs) do
      if v.gone then
        local leaf_ids = {}
        local w = judge.split_merge(s.v.id)
        local sides = w and {} or { s.v }
        if w then for id in s.v.id:gmatch("[^()&]+") do if id ~= "m" and by[id] then sides[#sides + 1] = by[id] end end end
        for _, side in ipairs(sides) do
          assert(judge.descends(read, side, v.id, v.hlc) ~= false, "case " .. case .. ": " .. side.id .. " is in the answer but never saw the deletion " .. v.id)
        end
      end
    end
  else gones = gones + 1 end
  if judge.split_merge(s.v.id) then merges = merges + 1 end
  for _, v in ipairs(vs) do if v.state and v.state:find("^restored") and s.v.id == v.id then restores = restores + 1 end end
end
assert(merges > 20 and gones > 10, "the histories exercised merges (" .. merges .. ") and deletions (" .. gones .. ")")

-- 4, 5: missing versions
local incompletes = 0
for case = 1, 300 do
  local vs, read, by = history(4 + rnd(12))
  local full = judge.settled(vs, read, { mergeable = mergeable })
  -- take away one version that isn't a leaf (on its way: not in vs, and not readable)
  local inner = {}
  for _, v in ipairs(vs) do
    local named = false
    for _, x in ipairs(vs) do if x.base_ev and x.base_ev:find(v.id, 1, true) then named = true end end
    if named and v ~= vs[1] then inner[#inner + 1] = v end
  end
  if #inner > 0 then
    local gone = inner[rnd(#inner)]
    local rest = {}
    for _, v in ipairs(vs) do if v ~= gone then rest[#rest + 1] = v end end
    local function read2(id) if id == gone.id then return nil end; if id:find(gone.id, 1, true) then return nil, true end; return read(id) end
    local s = judge.settled(rest, read2, { mergeable = mergeable })
    if not s.complete then
      incompletes = incompletes + 1
      assert(s.v == nil, "case " .. case .. ": an incomplete answer returned a version")
      local named = false
      for _, id in ipairs(s.missing) do if id:find(gone.id, 1, true) then named = true end end -- (or a merge named as a base, with it inside)
      assert(named or #s.missing == 0, "case " .. case .. ": the missing list doesn't name " .. gone.id)
    end
    -- given up on (or once it's older than MERGE_DAYS), it's complete
    local s3 = judge.settled(rest, read2, { mergeable = mergeable, give_up = true })
    assert(s3.complete and s3.v, "case " .. case .. ": given up on, the answer is complete")
    -- and once it arrives, the answer is the full one
    local s4 = judge.settled(shuffled(vs), read, { mergeable = mergeable })
    assert(answer(s4) == answer(full), "case " .. case .. ": once everything is here, the full answer")
  end
end
assert(incompletes > 10, "missing versions made answers incomplete (" .. incompletes .. ")")

-- The cases by hand.
local function ev(id, base, extra) local v = { id = id, base_ev = base, rev = 1, user = id:match("^(%a+)"), state = id }; for k, x in pairs(extra or {}) do v[k] = x end; return v end
local A = ev("James-20261122-120000Z-1", nil, { hlc = 1000 })
local G = ev("James-20261122-120100Z-2", A.id, { hlc = 2000, rev = 2, gone = true, state = nil })
local R = ev("James-20261122-120200Z-3", G.id, { hlc = 3000, rev = 3 }) -- James's Undo of his deletion
local E = ev("Bee-20261122-120201Z-4", A.id, { hlc = 3001, rev = 5 })    -- Bee's edit, made before the deletion reached her (a higher rev)
local by = { [A.id] = A, [G.id] = G, [R.id] = R, [E.id] = E }
local function rd(id) return by[id] end
-- the restore race (5057, 9029, 9058): any order, the restore; the edit is beaten, whatever its rev or clock
for _, order in ipairs({ { A, G, R, E }, { E, R, G, A }, { R, E }, { E, G, R } }) do
  local s = judge.settled(order, rd, { mergeable = mergeable })
  if #order == 2 then -- (without the deletion here, the edit isn't known to be beaten: both are edits, made apart)
    assert(s.complete, "two edits, everything they build on readable")
  else
    assert(s.v == R and not s.gone, "the restore stands, not " .. tostring(s.v and s.v.id))
    assert(s.beaten[1] == E.id, "Bee's edit is beaten by the deletion")
  end
end
-- without the restore, the deletion beats the edit (a deletion beats what didn't see it, for every kind: an fx chain here)
local s = judge.settled({ A, G, ev("Bee-20261122-120201Z-4", A.id, { hlc = 3001, rev = 9, obj = "fx" }) }, rd, {})
assert(s.gone and s.v.id == G.id, "the deletion stands over a newer edit made without seeing it")
-- two edits apart: one merge, the same name in either order
local B1 = ev("Bee-20261122-120300Z-5", A.id, { hlc = 4000, rev = 2 })
local C1 = ev("Cee-20261122-120301Z-6", A.id, { hlc = 4001, rev = 2 })
by[B1.id], by[C1.id] = B1, C1
local seen_id
local function rd2(id) if judge.split_merge(id) then seen_id = id; return { id = id, state = "merged", rev = 2 } end; return by[id] end
local s1 = judge.settled({ A, B1, C1 }, rd2, { mergeable = mergeable })
local s2 = judge.settled({ C1, A, B1 }, rd2, { mergeable = mergeable })
assert(s1.v.id == s2.v.id and s1.v.id == judge.merge_id(C1.id, B1.id), "one merge, the newer one winning: " .. tostring(s1.v.id))
-- not mergeable (a chain from before mg = 1): the newest leaf
s = judge.settled({ A, B1, C1 }, rd2, {})
assert(s.v == C1, "unmergeable: the newest leaf")
-- a merge whose shared base isn't here yet: incomplete, and complete once given up on
local function rd3(id) if judge.split_merge(id) then return nil, true end; return by[id] end
s = judge.settled({ B1, C1 }, rd3, { mergeable = mergeable })
assert(not s.complete and s.v == nil, "the base they share is on its way: incomplete")
s = judge.settled({ B1, C1 }, rd3, { mergeable = mergeable, give_up = true })
assert(s.complete and s.v == C1, "given up on: the newest")
-- an edit built on a version that isn't here, apart from another leaf: can't tell, so incomplete, naming it
local X = ev("Bee-20261122-120400Z-7", "Bee-20261122-120350Z-99", { hlc = 5000, rev = 3 })
s = judge.settled({ A, B1, X }, rd, { mergeable = mergeable })
assert(not s.complete and s.missing[1] == "Bee-20261122-120350Z-99", "the version on its way is named")
-- ... unless it dates more than MERGE_DAYS before the newest (trimmed)
local Y = ev("Bee-20261230-120400Z-8", "Bee-20261122-110000Z-98", { hlc = 6000, rev = 3 })
s = judge.settled({ B1, Y }, rd, { mergeable = mergeable })
assert(s.complete, "a missing version over MERGE_DAYS older than the newest counts as trimmed")
-- a flood of leaves: the newest, unmerged
local flood = { A }
for i = 1, judge.MAX_LEAVES + 1 do flood[#flood + 1] = ev(string.format("Bee-20261122-13%02d00Z-%d", i % 60, i), A.id, { hlc = 9000 + i, rev = 2 }) end
s = judge.settled(flood, rd, { mergeable = mergeable })
assert(s.v == flood[#flood] and not judge.split_merge(s.v.id), "past MAX_LEAVES leaves: the newest, unmerged")
-- the support keeps the leaves and, with a race, the deletions
local sup = judge.support({ A, G, R, E }, judge.settled({ A, G, R, E }, rd, {}))
local want = { E.id, G.id, R.id }
table.sort(want)
assert(table.concat(sup, ",") == table.concat(want, ","), "support: the leaves and the deletion: " .. table.concat(sup, ","))

-- An item's track is merged as an attribute (lib/mirror.lua event_file, judge step 5): Bee moved the item to another track while James nudged
-- it with a newer rev. Copied from the winner, the move was lost everywhere and each log said "both changes are kept" (item-track-merge).
do
  reaper = reaper or {}
  local files = {}
  local band = require("band")
  local proxy = setmetatable({}, { __index = band })
  proxy.read_json = function(path) local v = files[path]; if type(v) == "table" then return band.json_decode(band.json_encode(v)) end end
  package.loaded.band = proxy
  package.loaded.direct = package.loaded.direct or { path = function(_, dir, f) return dir .. "/" .. f end }
  local mirror = require("mirror")
  local RD = "C:/fake/Song/rooms/main"
  local function item(pos) return "<ITEM\nPOSITION " .. pos .. "\nSNAPOFFS 0\nLENGTH 2\nLOOP 1\nNAME \"Bass 1\"\n<SOURCE WAVE\nFILE \"{media}/b.flac\"\n>\n>\n" end
  local function put(v) v.type, v.obj, v.oid = "obj", "item", "I-B-1"; files[RD .. "/events/" .. v.id .. ".json"] = v; return v end
  local base = put({ id = "James-20261122-120000Z-1", rev = 1, hlc = 1000, user = "James", track = "T-BASS", state = item(10) })
  local moved = put({ id = "Bee-20261122-120100Z-2", rev = 2, hlc = 2000, user = "Bee", track = "T-GTR", state = item(10), base_ev = base.id, base = 1 })
  local nudged = put({ id = "James-20261122-120130Z-3", rev = 3, hlc = 2500, user = "James", track = "T-BASS", state = item(33.25), base_ev = base.id, base = 1 })
  local m = mirror.event_file(RD, mirror.merge_id(nudged.id, moved.id))
  assert(m, "the two merge")
  assert(m.track == "T-GTR", "the merge sits on the track Bee moved it to, not " .. tostring(m.track))
  assert(m.state:find("POSITION 33.25", 1, true), "and has James's nudge")
  assert(#(m.clashed or {}) == 0, "nothing clashed: both changes are really kept")
  -- both moved it, each to another track: the winner's track, and a clash said
  local other = put({ id = "James-20261122-120140Z-4", rev = 3, hlc = 2600, user = "James", track = "T-KEYS", state = item(10), base_ev = base.id, base = 1 })
  local m2 = mirror.event_file(RD, mirror.merge_id(other.id, moved.id))
  assert(m2.track == "T-KEYS" and m2.clashed[#m2.clashed] == "\0track", "both moved it: the winner's track, a clash")
  -- through the judge: the same merge, in any order
  local s = judge.settled({ nudged, base, moved }, mirror.reader(RD), { mergeable = mirror.mergeable })
  assert(s.v and s.v.track == "T-GTR", "the judge's answer is that merge")
  -- three edit leaves that all saw a deletion (a restore and two edits on it): the merge of two of them rests on the deletion itself, so it
  -- can't be built, and that's no merge, not one on its way. Taken for missing, the answer stayed incomplete and a late joiner never had the
  -- item (the soak's seed 5009). The newest leaf stands.
  local gone = put({ id = "James-20261122-120200Z-5", rev = 4, hlc = 3000, user = "James", track = "T-BASS", gone = true, base_ev = nudged.id, base = 3 })
  local restore = put({ id = "James-20261122-120210Z-6", rev = 5, hlc = 3100, user = "James", track = "T-BASS", state = item(33.25), base_ev = gone.id, base = 4 })
  local on_r1 = put({ id = "Bee-20261122-120220Z-7", rev = 6, hlc = 3200, user = "Bee", track = "T-BASS", state = item(20), base_ev = gone.id, base = 4 })
  local on_r2 = put({ id = "Cee-20261122-120221Z-8", rev = 6, hlc = 3300, user = "Cee", track = "T-BASS", state = item(21), base_ev = gone.id, base = 4 })
  local s2 = judge.settled({ base, moved, nudged, gone, restore, on_r1, on_r2 }, mirror.reader(RD), { mergeable = mirror.mergeable })
  assert(s2.complete, "a merge that can't be built isn't one on its way: complete")
  assert(s2.v == on_r2, "the newest leaf stands: " .. tostring(s2.v and s2.v.id))
  -- Restore and History playback go by the judge (mirror.plan_restore): at the row after the move and the nudge, the merge; after a deletion
  -- and a newer edit that didn't see it, the deletion (false), whatever the revs. By rev alone it was the nudge, then the edit.
  local function row(v) local e = {}; for k, x in pairs(v) do e[k] = x end; e.kind = "obj"; e.path_ = RD .. "/events/" .. v.id .. ".json"; return e end
  local plan = mirror.plan_restore({ row(base), row(moved), row(nudged) }, 3)
  assert(plan["I-B-1"] and plan["I-B-1"].track == "T-GTR" and plan["I-B-1"].state:find("POSITION 33.25", 1, true), "restore to after both: the merge")
  assert(mirror.plan_restore({ row(base), row(moved), row(nudged) }, 2)["I-B-1"].id == moved.id, "restore to before the nudge: the move")
  local late = put({ id = "Bee-20261122-120205Z-9", rev = 9, hlc = 3050, user = "Bee", track = "T-BASS", state = item(40), base_ev = nudged.id, base = 3 })
  assert(mirror.plan_restore({ row(base), row(moved), row(nudged), row(gone), row(late) }, 5)["I-B-1"] == false, "after a deletion and a newer edit that didn't see it: gone")
end

-- A tempo map never moves an item to another track (lib/mirror.lua only_map_moved): an item moved to another track with its position
-- unchanged, in the seconds after a tempo change, read as the map's move, was recorded as it was and never sent, so it sat on another track
-- on that computer alone (the soak's oracle hashes an item's text, not its track; rt-sync2b's track check found it in seeds 5000, 9001,
-- 9002, 9006). The same item moved by the map alone on its own track still reads as the map's.
do
  local mirror = require("mirror")
  local real_tp = reaper.time_precise
  reaper.time_precise = function() return 100 end
  mirror.tempo_until["PMAP"] = 1e9 -- (a tempo change in the last seconds)
  local st = "<ITEM\nPOSITION 4\nLENGTH 2\n>\n"
  local last = { state = st, track = "T-KEYS" }
  assert(mirror.only_map_moved("PMAP", { kind = "item", state = st, track = "T-KEYS" }, last), "on its own track: the map's move (as before)")
  assert(not mirror.only_map_moved("PMAP", { kind = "item", state = st, track = "T-GTR" }, last), "on another track: a hand's move, sent")
  mirror.tempo_until["PMAP"], reaper.time_precise = nil, real_tp
end

print("ok judge: " .. merges .. " merges, " .. gones .. " gone, " .. restores .. " restores, " .. incompletes .. " incomplete")
