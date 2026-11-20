-- sync.authority: owner by claim > region > driver; a take's author may change it where nobody has claimed (lupa or Lua 5.4)
as_if = { mode = "open" }
local claims = { ["claims/Laptop.json"] = { user = "Laptop", time = "2026-10-28T03:28:00Z", tracks = { "Guitar" } } }
local function with(list) -- swap in another set of claim files
  claims = list
  local names = {}
  for k in pairs(list) do names[#names + 1] = k:match("[^/]+$") end
  package.loaded.band.files = function(dir) return dir:match("claims$") and names or {} end
end
package.loaded.band = {
  files = function(dir) return dir:match("claims$") and { "Laptop.json" } or {} end,
  read_json = function(path)
    for k, v in pairs(claims) do if path:sub(-#k) == k then return v end end
    if path:match("mode%.json$") then return as_if end -- (Claims below, until the default is tested)
  end,
  song_dir = function(_, song) return "root/" .. song end,
}
package.path = "lib/?.lua;" .. package.path
local sync = require("sync")
local s = { host = "James", markers = { { region = true, name = "Verse", pos = 10, ["end"] = 30 } } }
local can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(can("James", "Keys", 0) and can("Laptop", "Keys", 0) and who.owner("Keys", 0) == "James", "what nobody claimed: anyone's, owned by the driver")
assert(can("Laptop", "Guitar", 12) and who.owner("Guitar", 12) == "Laptop", "a track claim beats the driver as its owner")
assert(not can("James", "Guitar", 12), "and holds against the driver too (Claims)")
assert(can("Laptop", "Pad", 0, "Laptop-20261028-032939Z-1"), "the author may change their own take on an unclaimed track")
assert(not can("Sam", "Guitar", 12, "Sam-20261028-040000Z-1"), "a claim beats authorship")
-- time selections: newer than a region claim, older than any track claim
with({
  ["claims/Laptop.json"] = { user = "Laptop", time = "2026-10-28T03:28:00Z", tracks = { "Guitar" }, regions = { "Verse" } },
  ["claims/James.json"] = { user = "James", time = "2026-10-28T03:30:00Z", times = { { from = 20, to = 25 } } },
})
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(#who.times == 1 and who.times[1].user == "James", "time claim read")
assert(can("James", "Keys", 21) and not can("Laptop", "Keys", 21), "a time claim beats a region claim")
assert(can("Laptop", "Keys", 12) and who.owner("Keys", 12) == "Laptop", "outside the time claim the region claim holds")
assert(can("Laptop", "Guitar", 21) and who.owner("Guitar", 21) == "Laptop", "a track claim beats a time claim")
assert(not can("Laptop", "Pad", 22, "Laptop-20261028-032939Z-1"), "the author can't change their take inside someone's time claim")
-- claims made in the same second: the later name wins, whatever order the folder lists the files in
for _, order in ipairs({ { "claims/James.json", "claims/Laptop.json" }, { "claims/Laptop.json", "claims/James.json" } }) do
  local list = {
    ["claims/James.json"] = { user = "James", time = "2026-10-28T11:12:00Z", tracks = { "Pad" }, times = { { from = 0, to = 5 } } },
    ["claims/Laptop.json"] = { user = "Laptop", time = "2026-10-28T11:12:00Z", tracks = { "Pad" }, times = { { from = 0, to = 5 } } },
  }
  claims = list
  package.loaded.band.files = function(dir) return dir:match("claims$") and { order[1]:match("[^/]+$"), order[2]:match("[^/]+$") } or {} end
  can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
  assert(who.owner("Pad", 0) == "Laptop", "a same-second track claim tie is decided by name")
  assert(who.owner("Keys", 1) == "Laptop", "a same-second time claim tie is decided by name")
end
-- the room's editing mode (mode.json, set by the driver)
with({ ["claims/Laptop.json"] = { user = "Laptop", time = "2026-10-28T03:28:00Z", tracks = { "Guitar" } } })
as_if = nil
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(who.mode == "open", "Claims (open) by default (0.58.82)")
claims["mode.json"] = { mode = "open" }
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(who.mode == "open" and can("Laptop", "Keys", 0), "open: anyone changes what nobody claimed")
assert(not can("James", "Guitar", 12), "open: a claim still holds")
assert(can("Laptop", nil, nil), "open: anyone changes the tempo map and markers too")
claims["mode.json"] = { mode = "driver" }
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(can("James", "Guitar", 12) and not can("Laptop", "Guitar", 12), "driver only: claims don't count")
assert(not can("Laptop", "Pad", 0, "Laptop-20261028-032939Z-1"), "driver only: not even your own take")
claims["mode.json"] = { mode = "nonsense" }
assert(select(2, sync.authority({ root = "root" }, "Saltmarsh", "main", s)).mode == "open", "an unknown mode reads as the default")
-- Open ("everyone" on disk): claims off. Driver + claims, removed in rt, reads as Driver only, said once a session in the log (James, 2026-11-20)
local said = {}
package.loaded.band.log = function(t) said[#said + 1] = t end
claims["mode.json"] = { mode = "everyone" }
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(who.mode == "everyone" and can("James", "Guitar", 12) and can("Sam", "Guitar", 12) and can("Sam", nil, nil) and #said == 0, "Open: claims don't hold, nothing said")
claims["mode.json"] = { mode = "claims" }
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(who.mode == "driver" and can("James", "Guitar", 12) and not can("Laptop", "Guitar", 12) and not can("Sam", "Keys", 0), "Driver + claims works as Driver only")
assert(#said == 1 and said[1]:find("Driver %+ claims") and said[1]:find("Driver only"), "and says so")
sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(#said == 1, "once")
assert(not sync.MODES.claims and sync.MODES.everyone and sync.MODES.open and sync.MODES.driver and sync.MODES.admins, "four modes")
package.loaded.band.log = nil
-- the driver released Laptop's claims while Laptop was away: those don't count; a claim made after still does
claims["mode.json"] = { mode = "open" }
claims["released.json"] = { Laptop = "2026-10-29T00:00:00Z" }
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(can("James", "Guitar", 12) and can("Sam", "Guitar", 12) and not who.is_claimed("Guitar", 12) and who.owner("Guitar", 12) == "James", "a released claim is free again")
claims["claims/Laptop.json"] = { user = "Laptop", time = "2026-10-30T09:00:00Z", tracks = { "Guitar" }, since = { ["tracks:guitar"] = "2026-10-30T09:00:00Z" } }
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(can("Laptop", "Guitar", 12) and who.owner("Guitar", 12) == "Laptop", "claimed again after the release: theirs")

-- the band's changes wait until a look has seen your last edit (0.58.53: sync.seen_mine, Live sync's receive guard)
assert(sync.seen_mine(7, 7, 100, 95), "nothing changed here since the look: theirs may come in")
assert(not sync.seen_mine(8, 7, 100, 95), "you edited after the look: theirs waits, or it lands over yours unseen")
assert(not sync.seen_mine(8, 7, 125, 95), "still waiting at 30 s")
assert(sync.seen_mine(8, 7, 126, 95), "but never longer than 30 s")
assert(sync.seen_mine(8, -1, 0, -math.huge), "before the first look ever, nothing holds them up")
-- whose change an id is: the name, then the date (0.58.82: "James" took "James-Laptop"'s for its own and said you'd both changed it)
assert(sync.is_mine("James-20261116-180000Z-00001-0001", "James") and not sync.is_mine("James-Laptop-20261116-180000Z-00001-0001", "James"), "James isn't James-Laptop")
assert(sync.is_mine("James-Laptop-20261116-180000Z-00001-0001", "James-Laptop"), "James-Laptop is")
print("ok")
