-- rt-sync2 phase 1 (docs/rt/rt-sync2a.md): property tests of the pure merges in lib/mirror_merge.lua. Random versions of each kind (an audio
-- item, a MIDI item, automation, a track's settings, a plug-in chain), each edited apart from one base by two people, and what every merge
-- must do whatever the edits are:
--   1. merging a version with itself gives it back, and so does merging it with an unchanged other side (either way round), with no clash;
--   2. a piece (mirror.pieces: a line, a setting, a point, a plug-in) only one side changed comes out as that side has it, one neither
--      changed as the base has it, and one both changed alike as both have it; pieces neither side had appear only with a clash;
--   3. the same merge twice, or a track's settings built in another order, comes out the same;
--   4. mirror.lua's names are mirror_merge's (callers unchanged), and merge_state picks the same merge.
-- A fixed pseudo-random sequence, 200 cases a kind. Lua 5.4, from the repo root.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
reaper = reaper or {}
local M = require("mirror_merge")
local mirror = require("mirror")

local seed = 20261127
local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return n and (seed % n) + 1 or seed / 2147483648 end
local function pick(t) return t[rnd(#t)] end
local function copy(t) local o = {}; for k, v in pairs(t) do o[k] = type(v) == "table" and copy(v) or v end; return o end
local CASES = 200

-- ---- the properties, for any kind: f(base, winner, loser) -> merged, clashes; pieces(state) -> key -> text ----
local function same(a, b) if type(a) == "table" then for k, v in pairs(a) do if b[k] ~= v then return false end end; for k in pairs(b) do if a[k] == nil then return false end end; return true end; return a == b end
local function show(v) return (tostring(v):gsub("%z", "|")) end -- (a piece's key has NULs in it: an error message stops at the first)
local function check(kind, f, b, w, l, label, pieces_ok)
  for _, x in ipairs({ w, l }) do
    local m, both = f(b, x, x)
    assert(same(m, x) and #both == 0, kind .. " " .. label .. ": a version merged with itself isn't itself\n" .. tostring(m) .. "\n--\n" .. tostring(x))
    m, both = f(b, x, b)
    assert(same(m, x) and #both == 0, kind .. " " .. label .. ": the winner's change alone isn't the winner's\n" .. tostring(m) .. "\n--\n" .. tostring(x))
    m, both = f(b, b, x)
    assert(same(m, x) and #both == 0, kind .. " " .. label .. ": the loser's change alone isn't the loser's\n" .. tostring(m) .. "\n--\n" .. tostring(x))
  end
  local m, both = f(b, w, l)
  local m2 = f(copy({ b })[1], copy({ w })[1], copy({ l })[1])
  assert(same(m, m2), kind .. " " .. label .. ": the same merge twice came out differently")
  if not pieces_ok or (type(pieces_ok) == "function" and not pieces_ok(both)) then return m, both end
  local P = function(s) return M.pieces(kind, s) end
  local pb, pw, pl, pm = P(b), P(w), P(l), P(m)
  assert(pm, kind .. " " .. label .. ": the merge can't be cut into pieces\n" .. tostring(m))
  local keys = {}
  for _, p in ipairs({ pb, pw, pl }) do for k in pairs(p) do keys[k] = true end end
  for k in pairs(keys) do
    local cw, cl = pw[k] ~= pb[k], pl[k] ~= pb[k]
    local want = (not cw and not cl and pb[k]) or (cw and not cl and pw[k]) or (cl and not cw and pl[k]) or (pw[k] == pl[k] and pw[k]) or nil
    -- (a chain's order is the plug-ins it holds: a plug-in removed by one and changed by the other stays, a clash, and the order with it)
    if not (cw and cl and pw[k] ~= pl[k]) and not (k == "\0order" and #both > 0) then
      assert(pm[k] == want, kind .. " " .. label .. ": piece " .. show(k) .. " is " .. show(pm[k]) .. ", not " .. show(want) ..
        " (changed by the winner " .. tostring(cw) .. ", the loser " .. tostring(cl) .. ")\n" .. tostring(m))
    end
  end
  for k in pairs(pm) do
    assert(keys[k] or #both > 0, kind .. " " .. label .. ": piece " .. show(k) .. " came from nowhere, with no clash\n" .. tostring(m))
  end
  return m, both
end

-- ---- an audio item: lines in two takes, its timing as one thing ----
local function item_text(x)
  local L = { "<ITEM", "<EXTI", "band_oid I-T-1", ">" } -- (an item's P_EXT, as REAPER writes it: tests/fixtures/editreaper.lua writes <EXT)
  for _, w in ipairs({ "POSITION", "SNAPOFFS", "LENGTH", "LOOP", "ALLTAKES", "FADEIN", "FADEOUT", "MUTE" }) do L[#L + 1] = w .. " " .. x[w] end
  for t, take in ipairs(x.takes) do
    if t > 1 then L[#L + 1] = "TAKE" end
    for _, w in ipairs({ "NAME", "VOLPAN", "SOFFS", "PLAYRATE", "CHANMODE" }) do L[#L + 1] = w .. " " .. take[w] end
    L[#L + 1] = "<SOURCE WAVE"; L[#L + 1] = 'FILE "' .. take.file .. '"'; L[#L + 1] = ">"
  end
  L[#L + 1] = ">"
  return table.concat(L, "\n") .. "\n"
end
local function num(lo, hi) return string.format("%.4f", lo + rnd() * (hi - lo)):gsub("0+$", ""):gsub("%.$", "") end
local function a_take(n) return { NAME = '"take ' .. n .. '"', VOLPAN = "1 0 1 -1", SOFFS = "0", PLAYRATE = "1 1 0 -1 0 0.0025", CHANMODE = "0", file = "f" .. n .. ".flac" } end
local function new_item()
  local x = { POSITION = num(0, 60), SNAPOFFS = "0", LENGTH = num(0.5, 8), LOOP = "1", ALLTAKES = "0", FADEIN = "1 0.01 0 1 0 0 0", FADEOUT = "1 0.01 0 1 0 0 0",
    MUTE = "0 0", takes = { a_take(1) } }
  if rnd(2) == 1 then x.takes[2] = a_take(2) end
  return x
end
local ITEM_EDITS = {
  function(x) x.POSITION = num(0, 60) end, function(x) x.LENGTH = num(0.5, 8) end, function(x) x.SNAPOFFS = num(0, 1) end,
  function(x) x.FADEIN = "1 " .. num(0, 2) .. " 0 1 0 0 0" end, function(x) x.FADEOUT = "1 " .. num(0, 2) .. " 0 1 0 0 0" end,
  function(x) x.MUTE = x.MUTE == "0 0" and "1 0" or "0 0" end,
  function(x) local t = pick(x.takes); t.NAME = '"' .. pick({ "a", "b", "c", "d" }) .. rnd(99) .. '"' end,
  function(x) local t = pick(x.takes); t.VOLPAN = num(0, 2) .. " 0 1 -1" end,
  function(x) local t = pick(x.takes); t.SOFFS = num(0, 3) end,
  function(x) local t = pick(x.takes); t.file = "rec" .. rnd(9999) .. ".flac" end, -- (recorded again)
}
local function edited(x, list) local y = copy(x); for _ = 1, rnd(3) do pick(list)(y) end; return y end
-- (a take both recorded again keeps the loser's as one more take, whose lines join the pieces (its timing joins the item's): property 2 is
-- asked where that didn't happen)
local function no_take_added(both) for _, k in ipairs(both) do if k:find("<SOURCE", 1, true) then return false end end; return true end
for c = 1, CASES do
  local b = new_item()
  check("item", M.merge_item, item_text(b), item_text(edited(b, ITEM_EDITS)), item_text(edited(b, ITEM_EDITS)), "audio case " .. c, no_take_added)
end
print("rt-sync2a props: audio items (" .. CASES .. " cases)")

-- ---- a MIDI item: notes, controllers, the end event ----
local function midi_text(x)
  local ev = {}
  for _, n in ipairs(x.notes) do
    ev[#ev + 1] = { n[1], 2, string.format("90 %02x %02x", n[3], n[4]) }
    ev[#ev + 1] = { n[1] + n[2], 0, string.format("80 %02x 00", n[3]) }
  end
  for _, cc in ipairs(x.ccs) do ev[#ev + 1] = { cc[1], 1, string.format("b0 %02x %02x", cc[2], cc[3]) } end
  table.sort(ev, function(p, q) if p[1] ~= q[1] then return p[1] < q[1] end; if p[2] ~= q[2] then return p[2] < q[2] end; return p[3] < q[3] end)
  local L, last, top = { "<ITEM", "POSITION " .. x.pos, "LENGTH 4", "MUTE 0 0", 'NAME "keys"', "<SOURCE MIDI", "HASDATA 1 960 QN", "CCINTERP 32" }, 0, 3840
  for _, e in ipairs(ev) do L[#L + 1] = "E " .. (e[1] - last) .. " " .. e[3]; last = e[1]; top = math.max(top, e[1]) end
  L[#L + 1] = "E " .. (top - last) .. " b0 7b 00"
  L[#L + 1] = "IGNTEMPO 0 120 4 4"; L[#L + 1] = ">"; L[#L + 1] = ">"
  return table.concat(L, "\n") .. "\n"
end
local function overlaps(x, k, s, len)
  for _, n in ipairs(x.notes) do if n[3] == k and n ~= x.self and s < n[1] + n[2] and n[1] < s + len then return true end end
end
local function new_midi()
  local x = { pos = num(0, 30), notes = {}, ccs = {} }
  for _ = 1, rnd(5) do
    local s, len, k = (rnd(16) - 1) * 240, rnd(4) * 120, 47 + rnd(24)
    if not overlaps(x, k, s, len) then x.notes[#x.notes + 1] = { s, len, k, 40 + rnd(80) } end
  end
  for _ = 1, rnd(3) - 1 do x.ccs[#x.ccs + 1] = { (rnd(16) - 1) * 240 + 7, 1, rnd(127) } end
  return x
end
local function note_edit(x, fn) -- (a note's change, kept off another note of its pitch)
  if #x.notes == 0 then return end
  local n = pick(x.notes)
  local s, len, k = fn(n)
  x.self = n
  if not overlaps(x, k, s, len) then n[1], n[2], n[3] = s, len, k end
  x.self = nil
end
local MIDI_EDITS = {
  function(x) local s, len, k = (rnd(16) - 1) * 240, rnd(4) * 120, 47 + rnd(24); if not overlaps(x, k, s, len) then x.notes[#x.notes + 1] = { s, len, k, 40 + rnd(80) } end end,
  function(x) if #x.notes > 0 then table.remove(x.notes, rnd(#x.notes)) end end,
  function(x) note_edit(x, function(n) return n[1], n[2], 47 + rnd(24) end) end, -- transposed
  function(x) note_edit(x, function(n) return (rnd(16) - 1) * 240, n[2], n[3] end) end, -- moved
  function(x) note_edit(x, function(n) return n[1], rnd(4) * 120, n[3] end) end, -- resized
  function(x) if #x.notes > 0 then pick(x.notes)[4] = 40 + rnd(80) end end, -- velocity
  function(x) x.ccs[#x.ccs + 1] = { (rnd(16) - 1) * 240 + 7, 1, rnd(127) } end,
  function(x) if #x.ccs > 0 then pick(x.ccs)[3] = rnd(127) end end,
}
for c = 1, CASES do
  local b = new_midi()
  local w, l = midi_text(edited(b, MIDI_EDITS)), midi_text(edited(b, MIDI_EDITS))
  local m = check("item", M.merge_item, midi_text(b), w, l, "MIDI case " .. c, false)
  -- (notes are paired across moves, so a note can come out made of both sides' changes: property 2 isn't asked; what is: the merge reads as
  -- notes again, and merging it with either side as the newer changes nothing more of that side's)
  local src = m:match("\n(<SOURCE MIDI.-\n>)\n>")
  assert(src and M.merge_midi(src, src, src) == src, "MIDI case " .. c .. ": the merge doesn't read back as notes\n" .. m)
end
print("rt-sync2a props: MIDI items (" .. CASES .. " cases)")

-- ---- automation: two envelopes, points by time ----
local function env_text(x)
  local out = {}
  for _, e in ipairs(x) do
    local L = { "<" .. e.tag, "ACT " .. e.act .. " -1", "DEFSHAPE 0 -1 -1" }
    table.sort(e.pts, function(p, q) return p[1] < q[1] end)
    for _, p in ipairs(e.pts) do L[#L + 1] = "PT " .. p[1] .. " " .. p[2] .. " 0" end
    L[#L + 1] = ">"
    out[#out + 1] = table.concat(L, "\n")
  end
  return table.concat(out, "\n") .. "\n"
end
local function free_time(e) for _ = 1, 20 do local t = rnd(64) - 1; local taken = false; for _, p in ipairs(e.pts) do if p[1] == t then taken = true end end; if not taken then return t end end end
local function new_env()
  local x = { { tag = "VOLENV2", act = "1", pts = {} } }
  if rnd(2) == 1 then x[2] = { tag = "PANENV2", act = "1", pts = {} } end
  for _, e in ipairs(x) do for _ = 1, rnd(5) do local t = free_time(e); if t then e.pts[#e.pts + 1] = { t, num(0, 1) } end end end
  return x
end
local ENV_EDITS = {
  function(x) local e = pick(x); if #e.pts > 0 then pick(e.pts)[2] = num(0, 1) end end, -- a point's value
  function(x) local e = pick(x); local t = free_time(e); if t then e.pts[#e.pts + 1] = { t, num(0, 1) } end end, -- added
  function(x) local e = pick(x); if #e.pts > 1 then table.remove(e.pts, rnd(#e.pts)) end end, -- taken out
  function(x) local e = pick(x); local t = free_time(e); if t and #e.pts > 0 then pick(e.pts)[1] = t end end, -- moved in time
  function(x) local e = pick(x); e.act = e.act == "1" and "0" or "1" end, -- bypassed
}
for c = 1, CASES do
  local b = new_env()
  -- (a point the loser moved that the winner changed too is one point, the winner's, and the loser's moved copy is left out with a clash:
  -- property 2's "only the loser changed it" doesn't hold for that copy, so it's asked only where no clash was reported)
  local w, l = env_text(edited(b, ENV_EDITS)), env_text(edited(b, ENV_EDITS))
  local m, both = M.merge_env(env_text(b), w, l)
  check("env", M.merge_env, env_text(b), w, l, "case " .. c, #both == 0)
end
print("rt-sync2a props: automation (" .. CASES .. " cases)")

-- ---- a track's settings ----
local SETTINGS = { name = { "Drums", "Bass", "Keys", "Lead", "T1" }, vol = { "1", "0.5", "0.25", "1.5" }, pan = { "0", "-0.5", "0.5" }, mute = { 0, 1 },
  color = { 0, 16777471, 33488896 }, phase = { 0, 1 }, automode = { 0, 1, 2 }, freemode = { 0, 2 }, lanes = { 0, 2, 3 }, plays = { "", "1", "1 2" },
  lanenames = { "", "a|b" } }
local KEYS = {}
for k in pairs(SETTINGS) do KEYS[#KEYS + 1] = k end
table.sort(KEYS)
local function new_track() local t = {}; for _, k in ipairs(KEYS) do t[k] = pick(SETTINGS[k]) end; return t end
local function edit_track(t) local y = copy(t); for _ = 1, rnd(3) do local k = pick(KEYS); y[k] = pick(SETTINGS[k]) end; return y end
local function reordered(t) local y, ks = {}, {}; for _, k in ipairs(KEYS) do ks[#ks + 1] = k end; for i = #ks, 1, -1 do y[ks[i]] = t[ks[i]] end; return y end
for c = 1, CASES do
  local b = new_track()
  local w, l = edit_track(b), edit_track(b)
  local m = check("track", M.merge_track, b, w, l, "case " .. c, true)
  assert(same(M.merge_track(reordered(b), reordered(w), reordered(l)), m), "track case " .. c .. ": settings built in another order merge differently")
end
print("rt-sync2a props: track settings (" .. CASES .. " cases)")

-- ---- a plug-in chain ----
local PLUGS = { -- (each its own kind: two of one kind added apart are told apart by test_0_60_rt_merge_p1, not here)
  EQ = '<VST "VST: ReaEQ (Cockos)" reaeq.dll 0 "" 1919247729<56535472656571726561657100000000> ""', COMP = '<VST "VST: ReaComp (Cockos)" reacomp.dll 0 "" 1919247213<56535472636D70726561636F6D7000> ""',
  DLY = '<VST "VST: ReaDelay (Cockos)" readelay.dll 0 "" 1919247468<5653547265646C72656164656C617900> ""', VOL = '<JS utility/volume ""', GATE = '<JS utility/gate ""', PAN = '<JS utility/pan ""' }
local function chain_text(x)
  if #x == 0 then return "" end
  local L = { "<FXCHAIN", "SHOW 0", "LASTSEL 0", "DOCKED 0" }
  for _, p in ipairs(x) do L[#L + 1] = "BYPASS " .. p.bypass .. " 0 0"; L[#L + 1] = PLUGS[p.kind]; L[#L + 1] = "QUFB" .. p.knob .. "AAAA"; L[#L + 1] = ">"; L[#L + 1] = "WAK 0 0" end
  L[#L + 1] = ">"
  return table.concat(L, "\n") .. "\n"
end
local function has(x, kind) for _, p in ipairs(x) do if p.kind == kind then return true end end end
local function new_chain() local x = {}; for _, k in ipairs({ "EQ", "COMP", "VOL" }) do if rnd(3) > 1 then x[#x + 1] = { kind = k, bypass = 0, knob = rnd(999) } end end; return x end
local function chain_edits(pool) -- (each side adds only from its own pool: see PLUGS)
  return {
    function(x) local k = pick(pool); if not has(x, k) then table.insert(x, rnd(#x + 1), { kind = k, bypass = 0, knob = rnd(999) }) end end,
    function(x) if #x > 0 then table.remove(x, rnd(#x)) end end,
    function(x) if #x > 0 then pick(x).knob = rnd(999) end end,
    function(x) if #x > 0 then local p = pick(x); p.bypass = 1 - p.bypass end end,
    function(x) if #x > 1 then local p = table.remove(x, rnd(#x)); table.insert(x, rnd(#x + 1), p) end end,
  }
end
local W_EDITS, L_EDITS = chain_edits({ "DLY", "GATE" }), chain_edits({ "PAN" })
for c = 1, CASES do
  local b = new_chain()
  local w, l = chain_text(edited(b, W_EDITS)), chain_text(edited(b, L_EDITS))
  check("fx", M.merge_fx, chain_text(b), w, l, "case " .. c, true)
end
print("rt-sync2a props: plug-in chains (" .. CASES .. " cases)")

-- ---- mirror.lua's names are these, and merge_state picks the same merge ----
for _, k in ipairs({ "merge_item", "side3", "note_changes", "merge_midi", "merge_env", "merge_track", "merge_fx", "pieces", "pieces_changed" }) do
  assert(mirror[k] == M[k], "mirror." .. k .. " isn't mirror_merge's")
end
do
  local b = new_track()
  local w, l = edit_track(b), edit_track(b)
  assert(same(mirror.merge_state("track", b, w, l), M.merge_track(b, w, l)), "merge_state(track) is merge_track")
  local e = new_env()
  local we, le = env_text(edited(e, ENV_EDITS)), env_text(edited(e, ENV_EDITS))
  assert(mirror.merge_state("env", env_text(e), we, le) == M.merge_env(env_text(e), we, le), "merge_state(env) is merge_env")
end
print("ok rt-sync2a: merge properties (self, one side, pieces from their side, the same twice) for items, MIDI, automation, tracks, plug-ins")
