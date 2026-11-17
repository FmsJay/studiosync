-- 0.58.92 review fixes that are pure (lupa or Lua 5.4, from the repo root)
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
package.loaded.band = package.loaded.band or {}
local trim = require("trim")

-- the prints a change's state names, in one room or any
local state = 'TAKE\nNAME "wet"\n<SOURCE FLAC\nFILE "{media:main}/print-I-JAMES-1-34483a49-James.flac"\n>\n' ..
  'TAKE\n<SOURCE FLAC\nFILE "{media:side}/print-I-X-2-deadbeef-Laptop.flac"\n>\nFILE "{media:main}/guitar.wav"'
local main = trim.print_refs(state, "main")
assert(main["print-I-JAMES-1-34483a49-James"] and not main["print-I-X-2-deadbeef-Laptop"], "a room's own prints only")
local any = trim.print_refs(state, nil)
assert(any["print-I-JAMES-1-34483a49-James"] and any["print-I-X-2-deadbeef-Laptop"], "every room's, when asked for any")
local n = 0
for _ in pairs(any) do n = n + 1 end
assert(n == 2, "a recording isn't a print")
-- the same in a raw event file, where the quotes are escaped
local raw = '{"state":"FILE \\"{media:main}/print-I-A-3-0badf00d-James.flac\\"\\nTAKE"}'
assert(trim.print_refs(raw, nil)["print-I-A-3-0badf00d-James"], "read from a raw file too")

-- empty takes from an older version, any run of them (mirror's older_form pattern)
local function older(s) return (s:gsub("\nTAKE NULL%f[\n]", "\nTAKE")) end
assert(older("A\nTAKE NULL\nTAKE NULL\nTAKE NULL\nB") == "A\nTAKE\nTAKE\nTAKE\nB", "three in a row")
assert(older("A\nTAKE NULL SEL\nB") == "A\nTAKE NULL SEL\nB", "only a bare TAKE NULL line")

-- a print's FX hold and the timeline order: the newest map by time then id, ours included
local function newest(list, at)
  local id
  for _, ev in ipairs(list) do if ev.type == "timeline" and (ev.time .. ev.id) > at then id = ev.id end end
  return id
end
local pending = { { type = "timeline", time = "2026-11-17T12:00:05Z", id = "Laptop-a" }, { type = "timeline", time = "2026-11-17T12:00:10Z", id = "James-b" } }
assert(newest(pending, "") == "James-b", "the later map wins, whoever made it")
assert(newest({ pending[1] }, "2026-11-17T12:00:10ZJames-b") == nil, "an older map of theirs doesn't land over the newer one we have")
print("ok")
