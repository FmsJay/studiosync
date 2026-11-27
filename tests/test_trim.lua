-- trim.plan is pure (lupa or Lua 5.4, from the repo root)
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
package.loaded.band = package.loaded.band or {}
local trim = require("trim")
local function ev(id, oid, rev, time, typ) return { id = id, oid = oid, rev = rev, time = time, type = typ or "obj" } end
local evs = {
  ev("a1", "I-A", 1, "2026-01-01T00:00:00Z"), ev("a2", "I-A", 2, "2026-01-05T00:00:00Z"), ev("a3", "I-A", 3, "2026-01-20T00:00:00Z"),
  ev("b1", "I-B", 1, "2026-01-02T00:00:00Z"), ev("b2", "I-B", 2, "2026-01-03T00:00:00Z"),
  ev("t1", nil, nil, "2026-01-01T00:00:00Z", "timeline"), ev("t2", nil, nil, "2026-01-04T00:00:00Z", "timeline"),
  ev("d1", nil, nil, "2026-01-01T00:00:00Z", "driver"), ev("n1", nil, nil, "2026-01-01T00:00:00Z", "note"),
  ev("s1", nil, nil, "2026-01-01T00:00:00Z", "start"),
  ev("new", "I-A", 4, "2026-03-01T00:00:00Z"), -- (within the last 30 days of the cutoff below: never trimmed)
}
local points = {
  { time = "2026-01-06T00:00:00Z", keep = true, label = "end of session" }, -- major: needs a2, b2, t2
  { time = "2026-01-02T12:00:00Z", label = "before Laptop took over from James" }, -- minor: needs nothing kept
}
local gone = {}
for _, id in ipairs(trim.plan(evs, points, "2026-02-15T00:00:00Z")) do gone[id] = true end
assert(not gone.new and not gone.b2, "each object's newest change stays (I-A's 'new', I-B's b2)")
assert(not gone.a2 and not gone.t2, "what the end-of-session point stands on stays (a2, t2)")
assert(gone.a1 and gone.a3 and gone.b1 and gone.t1, "older changes nothing needs go (a1, a3, b1, t1)")
assert(not gone.d1 and not gone.n1, "handovers and notes stay")
assert(gone.s1, "an old play/stop goes")
assert(trim.major({ keep = true, label = "x" }) and trim.major({ label = "chorus with double guitars" }), "kept and hand-saved points are major")
assert(not trim.major({ label = "before James took over from Laptop" }), "a handover snapshot is minor")
-- nothing older than the cutoff: nothing goes
assert(#trim.plan(evs, points, "2025-12-01T00:00:00Z") == 0, "nothing old enough")
-- a merged version is rebuilt from its two changes and their base: all three stay, and what a base names as a merge
do
  local base = { id = "m1", oid = "I-M", rev = 1, time = "2026-01-01T00:00:00Z", type = "obj", base_ev = "m0" }
  local m0 = { id = "m0", oid = "I-M", rev = 0, time = "2025-12-31T00:00:00Z", type = "obj" }
  local w = { id = "w", oid = "I-M", rev = 3, base = 1, base_ev = "m1", time = "2026-01-02T00:00:00Z", type = "obj" }
  local l = { id = "l", oid = "I-M", rev = 2, base = 1, base_ev = "m1", time = "2026-01-03T00:00:00Z", type = "obj" }
  local after = { id = "x", oid = "I-N", rev = 5, base = 4, base_ev = "m(p&q)", time = "2026-01-04T00:00:00Z", type = "obj" }
  local p = { id = "p", oid = "I-N", rev = 4, time = "2026-01-01T00:00:00Z", type = "obj" }
  local q = { id = "q", oid = "I-N", rev = 3, time = "2026-01-01T00:00:00Z", type = "obj" }
  local g = {}
  for _, id in ipairs(trim.plan({ m0, base, w, l, after, p, q }, {}, "2026-02-15T00:00:00Z")) do g[id] = true end
  assert(not g.w and not g.l and not g.m1, "the newest, the change made apart from it, and their base")
  assert(g.m0, "but not the base's own base: nothing rebuilds from it")
  assert(not g.p and not g.q, "both changes a merged base was made from")
end
-- (rt-sync2b) the judge's support stays: a deletion that beat a newer edit made without seeing it (both leaves of the object) is kept, or the
-- edit came back everywhere 60 days on; and a leaf that is a deletion with nothing racing it is the newest anyway
do
  local v1 = { id = "v1", oid = "I-D", rev = 1, time = "2026-01-01T00:00:00Z", type = "obj" }
  local gd = { id = "gd", oid = "I-D", rev = 2, base = 1, base_ev = "v1", gone = true, time = "2026-01-02T00:00:00Z", type = "obj" }
  local ed = { id = "ed", oid = "I-D", rev = 3, base = 1, base_ev = "v1", time = "2026-01-03T00:00:00Z", type = "obj" }
  local g = {}
  for _, id in ipairs(trim.plan({ v1, gd, ed }, {}, "2026-02-15T00:00:00Z")) do g[id] = true end
  assert(not g.gd and not g.ed, "the deletion and the edit it beat both stay (the judge weighs the two)")
  assert(not g.v1, "and their base")
end
-- (0.58.54) a change with no time is never taken for old, and what a kept point stands on stays even when everything is past the cutoff
do
  local e = { ev("x40", "I-X", 1, "2026-01-01T00:00:00Z"), ev("x35", "I-X", 2, "2026-01-06T00:00:00Z"), ev("x31", "I-X", 3, "2026-01-10T00:00:00Z"),
    { id = "notime", oid = "I-Y", rev = 1, type = "obj" }, ev("y2", "I-Y", 2, "2026-01-02T00:00:00Z") }
  local g = {}
  for _, id in ipairs(trim.plan(e, { { time = "2026-01-08T00:00:00Z", keep = true, label = "end of session" } }, "2026-02-15T00:00:00Z")) do g[id] = true end
  assert(not g.x35, "the newest at or before the kept point stays")
  assert(g.x40, "older than that goes")
  assert(not g.x31, "the newest stays")
  assert(not g.notime, "a change with no time stays")
end
-- (rt-p2) a room with many saved versions: the same ids as a loop over the changes for every point (the old way), in far fewer comparisons.
-- 2,500 changes and ~180 saved versions were 80-200 ms on REAPER's thread in the cloud copy's sweep.
do
  local mirror = require("mirror")
  local real_newer, calls = mirror.newer, 0
  mirror.newer = function(a, b) calls = calls + 1; return real_newer(a, b) end
  math.randomseed(7)
  local e, pts = {}, {}
  local function t(day, sec) return string.format("2026-%02d-%02dT%02d:%02d:%02dZ", 1 + day // 28, 1 + day % 28, sec // 3600 % 24, sec // 60 % 60, sec % 60) end
  for i = 1, 2500 do
    local day = math.random(0, 200)
    e[i] = { id = string.format("e%05d", i), oid = "I-" .. math.random(1, 300), rev = math.random(1, 9), time = t(day, math.random(0, 86399)),
      type = (i % 50 == 0) and "timeline" or "obj", order = (i % 50 == 0) and t(day, i) or nil, user = (i % 3 == 0) and "Bo" or "James" }
    if e[i].type == "timeline" then e[i].oid = nil end
  end
  for i = 1, 180 do pts[i] = { time = t(math.random(0, 200), math.random(0, 86399)), keep = (i % 4 ~= 0) or nil, label = (i % 4 == 0) and "hub snapshot" or "end of session" } end
  local function old_points(evs, points) -- (the old loop, for the points' part only: what each major point stands on)
    local function later(a, b)
      if a.type ~= "obj" and b.type ~= "obj" then return (a.order or ((a.time or "") .. (a.id or ""))) > (b.order or ((b.time or "") .. (b.id or ""))) end
      local x, y = { rev = a.rev, time = mirror.order_of(a) }, { rev = b.rev, time = mirror.order_of(b) }
      if real_newer(x, y) ~= real_newer(y, x) then return real_newer(x, y) end
      return (a.id or "") > (b.id or "")
    end
    local keep = {}
    for _, p in ipairs(points) do
      if trim.major(p) and p.time then
        local at = {}
        for _, ev in ipairs(evs) do
          local k = ev.type == "obj" and ev.oid or ev.type == "timeline" and "\0timeline" or nil
          if k and (ev.time or "") <= p.time and (not at[k] or later(ev, at[k])) then at[k] = ev end
        end
        for _, ev in pairs(at) do keep[ev.id] = true end
      end
    end
    return keep
  end
  local cutoff = "2026-12-31T00:00:00Z"
  calls = 0
  local gone = {}
  for _, id in ipairs(trim.plan(e, pts, cutoff)) do gone[id] = true end
  local new_calls = calls
  local base = {}
  for _, id in ipairs(trim.plan(e, {}, cutoff)) do base[id] = true end -- (without points: what the points keep is the difference)
  local want, kept = old_points(e, pts), 0
  for _, ev in ipairs(e) do
    if base[ev.id] then
      assert((not gone[ev.id]) == (want[ev.id] == true), "the same ids kept for the saved versions as the old loop: " .. ev.id)
      if not gone[ev.id] then kept = kept + 1 end
    end
  end
  assert(kept > 100, "the saved versions keep changes here: " .. kept)
  assert(new_calls < 20 * #e, "far fewer comparisons than a loop over every change for every point: " .. new_calls)
  mirror.newer = real_newer
end
print("ok")
