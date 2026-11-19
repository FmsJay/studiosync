-- 0.59.14 review, less work for the same answers: the shared folder listing (band.listing), the newest event's stamp worked out once per name
-- (status.newest_event) and saved versions read once each (recall.rows). Lupa or any Lua 5.4, from the repo root.
local folder, reads, clock = {}, 0, 0
reaper = setmetatable({
  time_precise = function() return clock end,
  EnumerateFiles = function(dir, i) if i == -1 then reads = reads + 1; return nil end; return folder[i + 1] end,
}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local band = require("band")

-- band.listing: the same names as band.files, sorted or in the folder's order, shared for LISTING_SECS
folder = { "B-20261027-010100Z-2.json", "a.txt", "A-20261027-010000Z-1.json", "A-20261027-010000Z-1 (1).json", "C-20261027-010200Z-3.JSON" }
local want = band.files("ev", ".json")
reads = 0
local sorted = band.listing("ev", ".json", true)
assert(table.concat(sorted, ",") == table.concat(want, ","), "sorted: as band.files: " .. table.concat(sorted, ","))
local loose = band.listing("ev", ".json")
assert(#loose == #want and loose[1] == "B-20261027-010100Z-2.json", "unsorted: the same names, in the folder's order")
assert(reads == 1, "one read of the folder for both: " .. reads)
assert(band.listing("ev", ".json", true) == sorted, "asked again within LISTING_SECS: the same table")
assert(#band.raw_listing("ev") == 5, "raw: every name, unfiltered")
folder[#folder + 1] = "D-20261027-010300Z-4.json"
clock = 0.1
assert(#band.listing("ev", ".json") == 3, "within 0.2 s: the shared listing")
clock = 0.35
assert(#band.listing("ev", ".json") == 4, "older than 0.2 s: read again")
folder[#folder + 1] = "E-20261027-010400Z-5.json"
assert(#band.raw_listing("ev", true) == 7, "fresh: read now")
assert(#band.listing("ev", ".json") == 5, "and everyone shares that read")
folder[#folder + 1] = "F-20261027-010500Z-6.json"
band.remove("nowhere/none.json") -- (Round 3 review, 0.59.48: a removal or write elsewhere leaves this folder's listing alone)
assert(#band.listing("ev", ".json") == 5, "a removal in another folder: the shared listing still")
band.remove("ev\\none.json") -- (a removal, or a write, in this folder, in either spelling: nothing listed before it is trusted)
assert(#band.listing("ev", ".json") == 6, "after a removal here: read again")

-- status.newest_event: the newest stamp in the names, each name worked out once
package.loaded.sync = {}
local status = require("status")
assert(status.newest_event({}) == "", "no events: none")
local names = { "B-20261027-010100Z-00002-1.json", "A-20261028-000000Z-00001-1.json", "odd.json" }
assert(status.newest_event(names) == "2026-10-28T00:00:00Z", "the newest, not the last by name")
local real_match, matched = string.match, 0
string.match = function(...) matched = matched + 1; return real_match(...) end -- (the string metatable's __index is the string table)
local more = { names[1], names[2], names[3], "C-20261029-120000Z-00001-1.json" }
assert(status.newest_event(more) == "2026-10-29T12:00:00Z", "a new name that's newer")
assert(matched == 1, "only the new name is worked out: " .. matched)
string.match = real_match
assert(status.newest_event({ names[1] }) == "2026-10-27T01:01:00Z", "names gone don't count")

-- recall.rows: newest first, each file read once, gone ones dropped, unread ones tried again
package.loaded.band, package.loaded.sync = { files = function() return {} end }, {}
package.loaded.recall = nil
local recall = require("recall")
local disk = { ["1.json"] = { label = "one", by = "A", takes = { x = {}, y = {} } }, ["2.json"] = { label = "two", keep = true } }
local read_n = 0
local function read(f) read_n = read_n + 1; return disk[f] end
local rows, had = recall.rows({ "1.json", "2.json", "3.json" }, {}, read)
assert(#rows == 2 and rows[1].file == "2.json" and rows[1].keep and rows[2].takes == 2 and rows[2].by == "A", "newest first, as recall.list gave")
assert(read_n == 3, "each read once")
disk["3.json"] = { label = "three" }
rows, had = recall.rows({ "1.json", "2.json", "3.json", "4.json" }, had, read)
assert(read_n == 5 and #rows == 3 and rows[1].label == "three", "only the new and the unread: " .. read_n)
rows, had = recall.rows({ "2.json", "3.json" }, had, read)
assert(read_n == 5 and #rows == 2 and had["1.json"] == nil, "a file gone drops out, nothing read")
print("ok")
