-- extras: lining a guest's file up by cross-correlation, and what happened while you were away (pure parts)
package.path = "lib/?.lua;" .. package.path
local extras = require("extras")

-- a click pattern, and the same pattern 7 steps later: found at 7, within ±10
local a, b = {}, {}
for i = 1, 200 do a[i] = (i % 23 == 0 or i % 37 == 0) and 1 or 0 end
for i = 1, 210 do b[i] = a[i - 7] or 0 end
assert(extras.best_lag(a, b, 10) == 7, "found the shift: " .. extras.best_lag(a, b, 10))
assert(extras.best_lag(a, a, 10) == 0, "no shift: 0")
assert(extras.best_lag(b, a, 10) == -7, "the other way: -7")

-- away: the others' changes and takes since then, new messages, open comments; not your own, not StudioSync's own reprints
local since = "2026-11-10T10:00:00Z"
local events = {
  { type = "obj", user = "Sam", time = "2026-11-10T11:00:00Z" }, { type = "obj", user = "Sam", time = "2026-11-10T12:00:00Z" },
  { type = "obj", user = "Bee", time = "2026-11-09T12:00:00Z" }, -- (before: not counted)
  { type = "obj", user = "James", time = "2026-11-10T12:00:00Z" }, -- (mine)
  { type = "obj", user = "Bee", time = "2026-11-10T12:30:00Z", auto = true }, -- (a print refreshed by itself)
}
local takes = { { user = "Bee", sent = "2026-11-10T11:30:00Z" } }
local msgs = { { user = "Sam", time = "2026-11-10T11:00:00Z" }, { user = "James", time = "2026-11-10T11:00:00Z" } }
events[#events + 1] = { type = "note", user = "Sam", time = "2026-11-10T11:10:00Z" }
local parts = extras.away_counts(events, takes, msgs, since, "James")
local text = table.concat(parts, " | ")
assert(text == "Bee: 1 take | Sam: 2 changes | 1 new message | 1 new note", text)
assert(#extras.away_counts({}, {}, {}, since, "James") == 0, "nothing happened: nothing said")
print("ok")
