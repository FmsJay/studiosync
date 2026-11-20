-- live.ini_set / parse_log are pure: run with lupa or any Lua 5.4 from the repo root
package.loaded.band = {}
package.path = "lib/?.lua;" .. package.path
local live = require("live")

local ini = "[other]\nhost=keep\n[ninjam]\nhost=old.server:2049\nmastervol=0.8\n"
local out = live.ini_set(ini, "ninjam", { host = "100.1.2.3:2049", user = "James" })
assert(out:find("%[other%]\nhost=keep"), "other sections untouched")
assert(out:find("host=100.1.2.3:2049", 1, true) and not out:find("old.server", 1, true), "key replaced")
assert(out:find("mastervol=0.8", 1, true), "unrelated key kept")
assert(out:find("user=James", 1, true), "new key added to the section")
local fresh = live.ini_set("", "ninjam", { host = "h" })
assert(fresh == "[ninjam]\nhost=h\n", "section created: " .. fresh)

local log = 'user {A} "x" 0 "y"\nsessionlog 0123ABCD "Laptop@100.1.2.4" 0 "Laptop" 12.5000000000 2.2500000000\nlocal xyz 0\n'
local c = live.parse_log(log)
assert(#c == 1 and c[1].guid == "0123ABCD" and c[1].user == "Laptop@100.1.2.4" and c[1].st == 12.5 and c[1].len == 2.25, "sessionlog parsed")
-- session folder names are the listener's local time; stamps are UTC, comparable with take ids
local st = live.session_stamp("C:/x/bandsync_live/20261026_2345.ninjam")
assert(st:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ$"), "stamp format: " .. st)
assert(st == os.date("!%Y%m%d-%H%M%SZ", os.time({ year = 2026, month = 10, day = 26, hour = 23, min = 45, sec = 0 })), "local -> UTC")
assert(live.session_stamp("C:/x/20261026_2345_1.ninjam") == st, "suffixed session folder")
-- only the same person's takes recorded after the session started replace its placeholders
assert(live.replaces("James-20261027-055000Z-1", "James", "20261027-054500Z"), "later take replaces")
assert(not live.replaces("James-20261027-032717Z-1", "James", "20261027-054500Z"), "earlier take doesn't")
assert(not live.replaces("Laptop-20261027-055000Z-1", "James", "20261027-054500Z"), "someone else's doesn't")
assert(live.replaces("Mary_Jo-20261027-055000Z-1", "Mary Jo", "20261027-054500Z"), "spaces vs underscores")
assert(not live.replaces("James-20261027-055000Z-1", "James", ""), "unknown session time: never")
-- with the clip's arrival time: only a take that was recording then (2026-10-28 test: C1 takes, sent 00:40:37,
-- 26 s long, must not retire clips heard at 00:42:30-00:43:04; C2 takes sent 00:43:05 must)
local S = "20261028-003100Z"
assert(not live.replaces("Laptop-20261028-004037Z-1", "Laptop", S, "20261028-004235Z", 26), "earlier take, later clip")
assert(live.replaces("Laptop-20261028-004305Z-1", "Laptop", S, "20261028-004250Z", 26), "recorded while heard")
assert(live.replaces("Laptop-20261028-004305Z-1", "Laptop", S, "20261028-004303Z", 26), "last clip, just before stop")
assert(not live.replaces("Laptop-20261028-004305Z-1", "Laptop", S, "20261028-003510Z", 26), "take long after the clip")

-- SonoBus: one group for the band, made once and then kept; the join link is what SonoBus's paste parser reads
reaper = { time_precise = function() return 1.5 end }
package.loaded.band.secret = function(n) return ("0123456789abcdef"):rep(4):sub(1, n) end -- (band.secret: REAPER's GUIDs, 0.58.98)
local data = {}
local g, p = live.sonobus_group(data)
assert(g:match("^StudioSync %w%w%w%w%w%w$") and #p == 12 and data.group == g and data.password == p, g .. " / " .. p)
assert(select(2, live.sonobus_group(data)) == p, "kept once made")
-- with the studio's secret: the same group name as from its ID alone, a password nobody can work out from the ID (0.58.52)
local g0, p0 = live.sonobus_group({}, "bandsync-ab12")
local g1, p1 = live.sonobus_group({}, "bandsync-ab12", "secret-one")
local g2, p2 = live.sonobus_group({}, "bandsync-ab12", "secret-two")
assert(g1 == g0 and g2 == g0, "the group's name stays the ID's: " .. g0 .. " / " .. g1)
assert(p1 ~= p0 and p2 ~= p1 and #p1 == 14, "the password follows the secret: " .. p0 .. " " .. p1 .. " " .. p2)
assert(select(2, live.sonobus_group({}, "bandsync-ab12", "secret-one")) == p1, "the same secret, the same password everywhere")
assert(select(2, live.sonobus_group({ group = "old", password = "kept" }, "bandsync-ab12", "secret-one")) == p1, "a secret overrides an old kept password")
assert(live.sonobus_link("StudioSync My Song", "ab&c") ==
  "http://go.sonobus.net/sblaunch?s=aoo.sonobus.net&g=StudioSync%20My%20Song&p=ab%26c", live.sonobus_link("StudioSync My Song", "ab&c"))
assert(live.sonobus_link("G", "p", "pc.tail1.ts.net:10999"):find("s=pc.tail1.ts.net%3A10999&", 1, true), "the studio's own server, when it has one")
-- mirror sync items carry an oid, not a take id: live MIDI parts go with them, each with its own track's take (desktop + laptop, rt)
assert(live.oid_take_id("I-JAMES-20261120024310-32070") == "JAMES-20261120-024310Z", tostring(live.oid_take_id("I-JAMES-20261120024310-32070")))
assert(live.oid_take_id("T-JAMES-1") == nil and live.oid_take_id(nil) == nil and live.oid_take_id("") == nil, "only an item's oid")
assert(live.replaces(live.oid_take_id("I-JAMES-20261120024310-32070"), "James", "20261120-024254Z", "", 4), "sent after the part began: replaces it")
assert(not live.replaces(live.oid_take_id("I-JAMES-20261120024210-1"), "James", "20261120-024254Z", "", 4), "made before it began: doesn't")
assert(not live.replaces(live.oid_take_id("I-BO-20261120024310-2"), "James", "20261120-024254Z", "", 4), "someone else's: doesn't")
assert(live.part_track("midi:20261120-024254Z:XT Midi K") == "XT Midi K" and live.part_track("midi:x:Synth (4)") == "Synth", "a MIDI part's track")
assert(live.part_track("{GUID}") == nil and live.part_track(nil) == nil, "a NINJAM clip: any track")
print("ok")
