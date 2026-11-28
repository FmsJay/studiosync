-- rt-sync2i (docs/rt/rt-sync2i.md): Undo from ancestry, docs/rt/rt-sync2.md 5a. lib/undo.lua's pure half: which act to undo (your own acts
-- by your own clock), which your Undos took back (an Undo names them and wasn't redone), and what an Undo writes per object (built on what's
-- held, the act's change reversed by the three-way merge). Redo is the same rule applied to the Undo act.
--   1. The act is chosen by your own clock (hlc), not History's rows; an act is its `act`, across seconds and kinds; a Restore and
--      StudioSync's own refreshes aren't acts; a bandmate's change isn't yours.
--   2. Undone and redone: an Undo names the act; a Redo of that Undo makes it count again; a change since ends Redo; an older build's Undo
--      that didn't name the act's timeline change still undoes the act.
--   3. What it writes: a creation goes, a deletion's version before comes back (with its rank), a version built on a deletion goes, a
--      trimmed base plans nothing, and an edit a deletion beat stays beaten.
--   4. An edit undone after a bandmate's change: theirs stays where it's theirs alone (the three-way merge); where both changed one thing,
--      going back wins; a merge of two versions made apart is what's built on.
--   5. Who else changed it since (the ask): their later versions and versions made apart and merged in, never you, nobody when nothing since.
--   6. Redo is Undo applied to the Undo act: Undo then Redo puts back exactly what was held, a bandmate's change included.
package.path = "lib/?.lua;" .. package.path
local mirror = require("mirror")
local undo = require("undo")

local USER, n = "James", 0
local function ev(t)
  n = n + 1
  t.kind, t.type = t.kind or "obj", t.kind or "obj"
  t.obj = t.obj or (t.kind == "obj" and "item" or nil)
  t.user = t.user or USER
  t.id = t.id or string.format("%s-20261128-1000%02dZ-%05d-0001", t.user, n % 60, n)
  t.time = t.time or string.format("2026-11-28T10:00:%02dZ", n % 60)
  t.mg = mirror.MG
  return t
end
local function reader(list)
  local by = {}
  for _, e in ipairs(list) do by[e.id] = e end
  return function(id) return by[id] end, by
end
local function ids(entries, g)
  local out = {}
  for _, j in ipairs(g and g.rows or {}) do out[#out + 1] = entries[j].id end
  table.sort(out)
  return table.concat(out, " ")
end

-- ---- 1. which act ------------------------------------------------------------------------------------------------------------------------
do
  -- my clock went back between two acts (History's rows sort by each computer's clock: the second act's row sits first), and a bandmate
  -- changed something after both
  local E = {
    ev{ id = "a2", oid = "I-2", rev = 1, base = 0, hlc = 2000, act = "act-B", time = "2026-11-28T09:00:00Z" },
    ev{ id = "a1", oid = "I-1", rev = 1, base = 0, hlc = 1000, act = "act-A", time = "2026-11-28T10:00:00Z" },
    ev{ id = "b1", oid = "I-1", rev = 2, base = 1, base_ev = "a1", hlc = 3000, user = "Bee", act = "act-C" },
  }
  local g = undo.last_mine(E, USER)
  assert(g and E[g.top].id == "a2", "the newest act by my own clock, not by History's rows (" .. tostring(g and E[g.top].id) .. ")")
  -- one act across seconds and kinds: a track and its item sent by one look, a second apart, with its timeline change
  local F = {
    ev{ id = "t1", obj = "track", oid = "T-1", rev = 1, base = 0, hlc = 1000, act = "x", state = { name = "Keys" }, time = "2026-11-28T10:00:00Z" },
    ev{ id = "i1", oid = "I-1", rev = 1, base = 0, hlc = 1500, act = "x", track = "T-1", time = "2026-11-28T10:00:01Z" },
    ev{ kind = "timeline", id = "tl1", hlc = 1600, act = "x", tempo = { { time = 0, bpm = 100 } } },
    ev{ id = "i0", oid = "I-0", rev = 1, base = 0, hlc = 500, act = "w" },
  }
  g = undo.last_mine(F, USER)
  assert(ids(F, g) == "i1 t1 tl1" and F[g.top].id == "tl1", "the whole act, its timeline change too (" .. ids(F, g) .. ")")
  -- a Restore (restored, its deletions too) and a print StudioSync refreshed aren't acts: Undo reaches past them
  F[#F + 1] = ev{ id = "r1", oid = "I-1", rev = 2, base = 1, base_ev = "i1", hlc = 2000, act = "rs", restored = "i1" }
  F[#F + 1] = ev{ id = "r2", oid = "I-0", rev = 2, base = 1, base_ev = "i0", hlc = 2001, act = "rs", gone = true }
  F[#F + 1] = ev{ id = "p1", oid = "I-9", rev = 2, base = 1, hlc = 2500, auto = true }
  g = undo.last_mine(F, USER)
  assert(ids(F, g) == "i1 t1 tl1", "a Restore and an automatic refresh are passed over (" .. ids(F, g) .. ")")
  assert(select(2, undo.acts(F, USER)) == "p1", "(my newest change, for 'undo nothing': the refresh)")
  print("rt-sync2i 1: the act is chosen by my own clock; an act is its act, across seconds and kinds; a Restore isn't one")
end

-- ---- 2. undone and redone -------------------------------------------------------------------------------------------------------------------
do
  local E = {
    ev{ id = "c1", oid = "I-1", rev = 1, base = 0, hlc = 1000, act = "A" },
    ev{ id = "b1", oid = "I-9", rev = 1, base = 0, hlc = 1500, act = "Q", user = "Bee" },
    ev{ id = "c2", oid = "I-2", rev = 1, base = 0, hlc = 2000, act = "B" },
    ev{ id = "c3", oid = "I-3", rev = 1, base = 0, hlc = 2001, act = "B" },
  }
  assert(ids(E, undo.last_mine(E, USER)) == "c2 c3", "Undo: my newest act")
  assert(undo.last_undo(E, USER) == nil, "nothing to redo yet")
  E[#E + 1] = ev{ id = "u1", oid = "I-2", rev = 2, base = 1, base_ev = "c2", gone = true, hlc = 3000, act = "U1", undoes = "c3", undoes_all = { "c2", "c3" } }
  E[#E + 1] = ev{ id = "u2", oid = "I-3", rev = 2, base = 1, base_ev = "c3", gone = true, hlc = 3001, act = "U1", undoes = "c3", undoes_all = { "c2", "c3" } }
  assert(ids(E, undo.last_mine(E, USER)) == "c1", "Undo again: the act before, not the same act again")
  local r = undo.last_undo(E, USER)
  assert(r and r.kind == "undo" and ids(E, r) == "u1 u2", "Redo: my newest Undo")
  E[#E + 1] = ev{ id = "r1", oid = "I-2", rev = 3, base = 2, base_ev = "u1", hlc = 4000, act = "R1", redoes = "u2", redoes_all = { "u1", "u2" }, restored = "c2" }
  assert(ids(E, undo.last_mine(E, USER)) == "c2 c3", "after the Redo, the act counts again")
  assert(undo.last_undo(E, USER) == nil, "redone: nothing left to redo")
  E[#E + 1] = ev{ id = "c4", oid = "I-4", rev = 1, base = 0, hlc = 5000, act = "C" }
  assert(undo.last_undo(E, USER) == nil and ids(E, undo.last_mine(E, USER)) == "c4", "a new change ends Redo")
  -- two Undos, then two Redos: the second Redo reaches the earlier Undo
  local F = {
    ev{ id = "a", oid = "I-A", rev = 1, base = 0, hlc = 100, act = "a" },
    ev{ id = "b", oid = "I-B", rev = 1, base = 0, hlc = 200, act = "b" },
    ev{ id = "ub", oid = "I-B", rev = 2, base = 1, base_ev = "b", gone = true, hlc = 300, act = "ub", undoes = "b" },
    ev{ id = "ua", oid = "I-A", rev = 2, base = 1, base_ev = "a", gone = true, hlc = 400, act = "ua", undoes = "a" },
    ev{ id = "ra", oid = "I-A", rev = 3, base = 2, base_ev = "ua", hlc = 500, act = "ra", redoes = "ua", restored = "a" },
  }
  r = undo.last_undo(F, USER)
  assert(r and ids(F, r) == "ub", "the second Redo reaches the earlier Undo")
  -- an older build's Undo of an act with a timeline change named only the act's items: the act still counts as undone
  local G = {
    ev{ id = "g0", oid = "I-0", rev = 1, base = 0, hlc = 50, act = "g0" },
    ev{ id = "gi", oid = "I-1", rev = 1, base = 0, hlc = 100, act = "g" },
    ev{ kind = "timeline", id = "gt", hlc = 101, act = "g", tempo = { { time = 0, bpm = 90 } } },
    ev{ id = "gu", oid = "I-1", rev = 2, base = 1, base_ev = "gi", gone = true, hlc = 200, act = "gu", undoes = "gi" },
    ev{ kind = "timeline", id = "gut", hlc = 199, undoes = "gi", tempo = { { time = 0, bpm = 120 } } },
  }
  assert(ids(G, undo.last_mine(G, USER)) == "g0", "an act whose items are all undone is undone, its timeline change with them (" .. ids(G, undo.last_mine(G, USER)) .. ")")
  -- a timeline change passed over (a bandmate changed the map since): its act is skipped
  local H = { ev{ id = "h0", oid = "I-0", rev = 1, base = 0, hlc = 50, act = "h0" }, ev{ kind = "timeline", id = "ht", hlc = 100, act = "h", tempo = {} } }
  assert(ids(H, undo.last_mine(H, USER, { ht = true })) == "h0", "a passed-over timeline change: the act before")
  -- a deletion on another lane than the act's newest is left for the next press (a pass and its copies in a comp: Mac 0.42.10)
  local function on(lane) return "<ITEM\nBANDLANE " .. lane .. "\n" end
  local L = {
    ev{ id = "p", oid = "I-P", rev = 1, base = 0, hlc = 10, act = "m", state = on(3) },
    ev{ id = "c", oid = "I-C", rev = 1, base = 0, hlc = 11, act = "m", state = on(0) },
    ev{ id = "gp", oid = "I-P", rev = 2, base = 1, base_ev = "p", gone = true, hlc = 100, act = "d" },
    ev{ id = "gc", oid = "I-C", rev = 2, base = 1, base_ev = "c", gone = true, hlc = 101, act = "d" },
  }
  assert(ids(L, undo.last_mine(L, USER)) == "gc", "the comp's deletion alone (" .. ids(L, undo.last_mine(L, USER)) .. ")")
  print("rt-sync2i 2: an Undo names what it took back, a Redo makes it count again, a change since ends Redo")
end

-- ---- 3. what it writes ---------------------------------------------------------------------------------------------------------------------
do
  local held = {}
  local function h(oid) return held[oid] end
  local E = {
    ev{ id = "t1", obj = "track", oid = "T-1", rev = 1, base = 0, hlc = 10, act = "a", state = { name = "Keys", rank = "m" } },
    ev{ id = "i1", oid = "I-1", rev = 1, base = 0, hlc = 11, act = "a", track = "T-1", state = "<ITEM\nPOSITION 1\nLENGTH 2\n>\n" },
    ev{ id = "tg", obj = "track", oid = "T-1", rev = 2, base = 1, base_ev = "t1", gone = true, hlc = 20, act = "d" },
    ev{ id = "x2", oid = "I-X", rev = 2, base = 1, base_ev = "trimmed-away", hlc = 30, act = "x", state = "<ITEM\nPOSITION 3\n>\n" },
    ev{ id = "r1", oid = "I-R", rev = 3, base = 2, base_ev = "rg", hlc = 40, act = "r", state = "<ITEM\nPOSITION 4\n>\n", restored = "r0", undoes = "rg" },
    ev{ id = "rg", oid = "I-R", rev = 2, base = 1, base_ev = "r0", gone = true, hlc = 35, act = "q" },
    ev{ id = "r0", oid = "I-R", rev = 1, base = 0, hlc = 34, act = "q0", state = "<ITEM\nPOSITION 4\n>\n" },
  }
  local read = reader(E)
  local plan = undo.plan(E, { 1, 2 }, read, h)
  assert(plan["T-1"] == false and plan["I-1"] == false, "a creation's reverse is a deletion")
  held["T-1"] = E[3]
  plan = undo.plan(E, { 3 }, read, h)
  assert(plan["T-1"] and plan["T-1"].id == "t1" and plan["T-1"].state.rank == "m", "a deletion's reverse is the version it was built on, at its rank")
  held["T-1"] = ev{ id = "t3", obj = "track", oid = "T-1", rev = 3, base = 2, base_ev = "tg", hlc = 25, user = "Bee", state = { name = "Keys" } }
  assert(undo.plan(E, { 3 }, read, h)["T-1"] == nil, "a deletion already undone by someone else: nothing to bring back")
  assert(next((undo.plan(E, { 4 }, read, h))) == nil, "what it was built on was trimmed away: nothing planned")
  plan = undo.plan(E, { 5 }, read, h)
  assert(plan["I-R"] == false, "a version built on a deletion (an Undo of one): its reverse is the deletion")
  -- an edit a deletion beat stays beaten, whoever's the deletion
  local F = {
    ev{ id = "e1", oid = "I-E", rev = 1, base = 0, hlc = 10, act = "a", state = "<ITEM\nPOSITION 1\n>\n" },
    ev{ id = "e2", oid = "I-E", rev = 2, base = 1, base_ev = "e1", hlc = 20, act = "b", state = "<ITEM\nPOSITION 2\n>\n" },
  }
  held["I-E"] = ev{ id = "eg", oid = "I-E", rev = 2, base = 1, base_ev = "e1", gone = true, hlc = 15, user = "Bee" }
  plan = undo.plan(F, { 2 }, reader(F), h)
  assert(plan["I-E"] and plan["I-E"].beaten and plan["I-E"].id == "e1", "an edit a deletion beat is planned beaten (mirror.revert leaves it)")
  print("rt-sync2i 3: a creation goes, a deletion comes back at its rank, a restore goes, a trimmed base plans nothing, a beaten edit stays beaten")
end

-- ---- 4. an edit undone after a bandmate's change ---------------------------------------------------------------------------------------------
do
  local function st(pos, mute) return string.format("<ITEM\nPOSITION %d\nLENGTH 2\nMUTE %d 0\n>\n", pos, mute) end
  local E = {
    ev{ id = "v0", oid = "I-1", rev = 1, base = 0, hlc = 10, act = "a", state = st(1, 0) },
    ev{ id = "v1", oid = "I-1", rev = 2, base = 1, base_ev = "v0", hlc = 20, act = "b", state = st(5, 0) }, -- (my move)
  }
  local bee = ev{ id = "v2", oid = "I-1", rev = 3, base = 2, base_ev = "v1", hlc = 30, user = "Bee", act = "c", state = st(5, 1) } -- (her mute)
  local read = reader({ E[1], E[2], bee })
  local plan, who = undo.plan(E, { 2 }, read, function() return bee end)
  assert(plan["I-1"].state == st(1, 1), "my move goes back, her mute stays (" .. plan["I-1"].state .. ")")
  assert(plan["I-1"].id == "v0", "(as the version it was built on)")
  assert(table.concat(who, ",") == "Bee", "and she's named in the ask")
  -- where both changed one thing (she moved it too), going back wins
  local bee2 = ev{ id = "v3", oid = "I-1", rev = 3, base = 2, base_ev = "v1", hlc = 30, user = "Bee", act = "c", state = st(8, 0) }
  plan = undo.plan(E, { 2 }, reader({ E[1], E[2], bee2 }), function() return bee2 end)
  assert(plan["I-1"].state == st(1, 0), "both moved it: going back wins")
  -- built on a merge: her mute made apart from my move (both on v0), merged; Undo of my move keeps the merge's mute
  local apart = ev{ id = "w1", oid = "I-1", rev = 2, base = 1, base_ev = "v0", hlc = 21, user = "Bee", act = "d", state = st(1, 1) }
  local merged = { id = "m(v1&w1)", oid = "I-1", obj = "item", rev = 2, base_ev = "v0", state = st(5, 1), mg = mirror.MG, user = USER }
  local rd = reader({ E[1], E[2], apart, merged })
  plan, who = undo.plan(E, { 2 }, rd, function() return merged end)
  assert(plan["I-1"].state == st(1, 1), "a merge of two made apart is what's built on: her mute stays")
  assert(table.concat(who, ",") == "Bee", "she's named: her change was made apart and merged in")
  print("rt-sync2i 4: Undo of an edit keeps a bandmate's change where it's theirs alone, and goes back where both changed it")
end

-- ---- 5. who else changed it since ----------------------------------------------------------------------------------------------------------
do
  local a = ev{ id = "s1", oid = "I-1", rev = 2, base_ev = "s0", hlc = 10, state = "x" }
  local s0 = ev{ id = "s0", oid = "I-1", rev = 1, base = 0, hlc = 5, user = "Old", state = "w" }
  local c = ev{ id = "s2", oid = "I-1", rev = 3, base_ev = "s1", hlc = 20, user = "Cee", state = "y" }
  local mine = ev{ id = "s3", oid = "I-1", rev = 4, base_ev = "s2", hlc = 30, state = "z" }
  local read = reader({ a, s0, c, mine })
  assert(table.concat(undo.since(read, a, mine, USER), ",") == "Cee", "Cee's later version, not mine, not the one before mine")
  assert(#undo.since(read, a, a, USER) == 0 and #undo.since(read, a, nil, USER) == 0, "nothing since: nobody")
  local auto = ev{ id = "s4", oid = "I-1", rev = 5, base_ev = "s1", hlc = 40, user = "Dee", auto = true, state = "a" }
  assert(#undo.since(reader({ a, s0, auto }), a, auto, USER) == 0, "StudioSync's own refresh is nobody's change")
  print("rt-sync2i 5: the ask names who changed it since, from what's held")
end

-- ---- 6. Redo is Undo applied to the Undo act --------------------------------------------------------------------------------------------------
do
  local function st(pos, mute) return string.format("<ITEM\nPOSITION %d\nLENGTH 2\nMUTE %d 0\n>\n", pos, mute) end
  local v0 = ev{ id = "v0", oid = "I-1", rev = 1, base = 0, hlc = 10, act = "a", state = st(1, 0) }
  local v1 = ev{ id = "v1", oid = "I-1", rev = 2, base = 1, base_ev = "v0", hlc = 20, act = "b", state = st(5, 0) }
  local v2 = ev{ id = "v2", oid = "I-1", rev = 3, base = 2, base_ev = "v1", hlc = 30, user = "Bee", act = "c", state = st(5, 1) }
  local E = { v0, v1, v2 }
  local read = reader(E)
  local plan = undo.plan(E, { 2 }, read, function() return v2 end)
  -- the Undo writes its version on what was held (v2), as mirror.revert does
  local u = ev{ id = "u1", oid = "I-1", rev = 4, base = 3, base_ev = "v2", hlc = 40, act = "U", undoes = "v1", restored = "v0", state = plan["I-1"].state }
  E[#E + 1] = u
  local r = undo.last_undo(E, USER)
  assert(r and E[r.top].id == "u1", "Redo finds the Undo")
  plan = undo.plan(E, r.rows, reader(E), function() return u end)
  assert(plan["I-1"].id == "v2" and plan["I-1"].state == st(5, 1), "Undo then Redo: exactly what was held, her mute included")
  -- an Undo of a creation, redone: it comes back; an Undo of a deletion, redone: it goes again
  local c = ev{ id = "k1", oid = "I-K", rev = 1, base = 0, hlc = 50, act = "k", state = st(2, 0) }
  local cu = ev{ id = "k2", oid = "I-K", rev = 2, base = 1, base_ev = "k1", gone = true, hlc = 60, act = "KU", undoes = "k1" }
  local F = { c, cu }
  plan = undo.plan(F, { 2 }, reader(F), function() return cu end)
  assert(plan["I-K"] and plan["I-K"].id == "k1", "Redo of an Undo of a creation brings it back")
  local d = ev{ id = "d1", oid = "I-D", rev = 2, base = 1, base_ev = "d0", gone = true, hlc = 70, act = "D" }
  local d0 = ev{ id = "d0", oid = "I-D", rev = 1, base = 0, hlc = 65, act = "D0", state = st(3, 0) }
  local du = ev{ id = "d2", oid = "I-D", rev = 3, base = 2, base_ev = "d1", hlc = 80, act = "DU", undoes = "d1", restored = "d0", state = st(3, 0) }
  local G = { d0, d, du }
  plan = undo.plan(G, { 3 }, reader(G), function() return du end)
  assert(plan["I-D"] == false, "Redo of an Undo of a deletion deletes it again")
  print("rt-sync2i 6: Redo is Undo applied to the Undo act; Undo then Redo puts back what was held")
end

print("ok")
