-- 0.59.50: the direct link's Lua side (lib/direct.lua): which paths go, who they go to, the studio's setting, Syncthing alone when the
-- extension is missing, and with a stand-in extension: started send-only until the firewall rule is there, offered to whoever's here,
-- what arrived listed and found, the inbox tidied, Health's line. The sockets themselves: tests/direct_test.cpp.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end }) -- (the extension's: absent)

local band = require("band")
local files = {} -- path -> true: what "exists"
reaper.file_exists = function(p) return files[p] == true end
local listings = {} -- dir -> names
band.files = function(d, e) local out = {}; for _, f in ipairs(listings[d] or {}) do if not e or f:sub(-#e) == e then out[#out + 1] = f end end; return out end
band.listing = function(d) listings[d] = listings[d] or {}; return listings[d] end
band.subdirs = function(d) return listings[d .. "/"] or {} end
band.home = function() return "H" end
band.info = function() return { id = "studiosync-smiley" } end
local hidden_out = nil -- what the background netsh check last said
package.loaded.services = { run_hidden = function(name) return name == "direct-fw" and hidden_out or nil end, TMP = "T",
  is_device_id = function(id) return type(id) == "string" and #id > 10 end, my_device_id = function() return "MEMEMEMEMEME" end }
local trusted, secret = {}, "s3cret"
package.loaded.groups = { trusted = function() return trusted end, tailnet = function() return { name = "x", suffix = "tail99.ts.net" } end,
  sonobus_secret = function() return secret end }
package.loaded.trust = { user_file = function(u) return u .. ".json" end, device_ok = function() return true end }
local here = { "James-Laptop" }
package.loaded.presence = { peers = function() local t = {}; for _, u in ipairs(here) do t[#t + 1] = { user = u } end; return t end }
package.loaded.access = { read = function() return nil end, shows = function(set, song) return not set or set[song] == true end }
local direct = require("direct")

-- Paths
local ok_rel = "Nostalgia/rooms/main/events/James-20261117-020433Z-00036-1979.json"
assert(direct.rel_ok(ok_rel) and direct.rel_ok("Cross Test/rooms/side 2/events/Chilio_Mac-20261117-020433Z-00001-0001.json"), "event paths pass")
for _, bad in ipairs({ "../rooms/main/events/a.json", "S/rooms/../events/a.json", "S/rooms/main/events/../a.json", "/S/rooms/main/events/a.json",
  "S/rooms/main/claims/a.json", "S/rooms/main/events/a b.json", ".x/rooms/main/events/a.json", "_band/band.json", "S./rooms/main/events/a.json",
  "S/rooms/ma:in/events/a.json", "S/rooms/main/events/sub/a.json", "", 5 }) do
  assert(not direct.rel_ok(bad), "refused: " .. tostring(bad))
end
assert(direct.rel_of("J:\\St\\Smiley\\", "J:/St/Smiley/" .. ok_rel) == ok_rel, "relative to the studio, either slash")
assert(direct.rel_of("J:/St/Smiley", "j:/st/smiley/" .. ok_rel) == ok_rel, "a drive letter's case doesn't matter")
assert(direct.rel_of("J:/St/Smiley", "J:/St/Other/" .. ok_rel) == nil and direct.rel_of("J:/St/Smiley", "J:/St/Smiley/_band/band.json") == nil, "outside, or not an event")

-- Who it goes to
local devs = {
  { user = "James", device = "MEMEMEMEMEME", ts = { ["tail99.ts.net"] = "james-main.tail99.ts.net" } },
  { user = "James-Laptop", device = "LAPLAPLAPLAP", ts = { ["tail99.ts.net"] = "james-laptop.tail99.ts.net" } },
  { user = "Chilio-Mac", device = "MACMACMACMAC", ts = { ["tail99.ts.net"] = "chilis-macbook-pro.tail99.ts.net" } },
  { user = "Old", device = "OLDOLDOLDOLD", ts = { ["tailother.ts.net"] = "old.tailother.ts.net" } },
  { user = "Evil", device = "EVILEVILEVIL", ts = { ["tail99.ts.net"] = "evil.example.com" } },
  { user = "Odd", device = "ODDODDODDODD", ts = { ["tail99.ts.net"] = "a b.tail99.ts.net" } },
  { user = "Dup", device = "DUPDUPDUPDUP", ts = { ["tail99.ts.net"] = "james-laptop.tail99.ts.net" } },
}
local p = direct.peers_from(devs, "tail99.ts.net", "MEMEMEMEMEME", 47281)
assert(table.concat(p, " ") == "chilis-macbook-pro.tail99.ts.net:47281 james-laptop.tail99.ts.net:47281",
  "the others on the studio's network, by name, not me, not another network, not a name off it, once each: " .. table.concat(p, " "))
p = direct.peers_from(devs, "tail99.ts.net", "MEMEMEMEMEME", 50000, { ["James-Laptop"] = true })
assert(table.concat(p, " ") == "james-laptop.tail99.ts.net:50000", "only whoever's here, at the port asked")
p = direct.peers_from(devs, "tail99.ts.net", "X", 47281, nil, function(d) return d.user ~= "Chilio-Mac" end)
assert(#p == 2 and not table.concat(p, " "):find("chilis"), "and only those ok() lets have it")

-- The setting: on unless false
assert(direct.enabled("R") == true, "on when band.json says nothing")
trusted = { direct = false }
assert(direct.enabled("R") == false, "off when the owner turned it off")
trusted = {}
package.loaded.groups.trusted = function() error("no") end
assert(direct.enabled("R") == true, "a settings read that fails leaves it on")
package.loaded.groups.trusted = function() return trusted end

-- Times from ids, the firewall rule's words
assert(direct.id_time("James-20261119-120000Z-00001-0001.json") == 1795089600, "an id's time is UTC: " .. tostring(direct.id_time("James-20261119-120000Z-00001-0001.json")))
assert(direct.id_time("notes.json") == nil, "no time in a name that isn't an id")
local cmd = direct.firewall_command("C:\\Program Files\\REAPER (x64)\\reaper.exe", 47281)
assert(cmd:find('program="C:\\Program Files\\REAPER (x64)\\reaper.exe"', 1, true) and cmd:find("remoteip=100.64.0.0/10", 1, true)
  and cmd:find("localport=47281", 1, true) and cmd:find("dir=in", 1, true), "the rule: reaper.exe, the port, Tailscale's addresses, inbound")
local shown = "Rule Name:      StudioSync direct link\r\nEnabled: Yes\r\nLocalPort: 47281\r\nRemoteIP: 100.64.0.0/10\r\nProgram: C:\\REAPER\\reaper.exe\r\n"
assert(direct.firewall_in(shown, "C:\\REAPER\\reaper.exe", 47281), "the rule is seen")
assert(not direct.firewall_in(shown, "D:\\REAPER\\reaper.exe", 47281), "not for another reaper.exe (a portable drive on another letter)")
assert(not direct.firewall_in(shown, "C:\\REAPER\\reaper.exe", 4728), "not for another port")
assert(not direct.firewall_in("No rules match the specified criteria.", "C:\\REAPER\\reaper.exe", 47281), "no rule")

-- No extension (or an older one): Syncthing alone, quietly
local cfg = { root = "J:/St/Smiley", user = "James" }
local edir = "J:/St/Smiley/Nostalgia/rooms/main/events"
listings[edir] = { "a.json" }
assert(direct.available() == false and direct.ensure(cfg) == false and direct.offer(cfg, "J:/St/Smiley/" .. ok_rel) == false, "nothing offered")
assert(direct.listing(cfg, edir) == listings[edir], "the shared listing itself, untouched")
assert(direct.tick(cfg) == 0 and direct.path(cfg, edir, "a.json") == edir .. "/a.json", "nothing ticks, paths are the shared folder's")
local okh, text = direct.health_line(cfg)
assert(okh == nil and text:find("1.0.8"), "Health says what's needed")

-- A stand-in extension
local calls, polled = {}, { "1\tstudiosync-smiley\t" .. ok_rel, "2\tstudiosync-smiley\t" .. ok_rel }
reaper.StudioSync_DirectStart = function(id, sec, inbox, port) calls[#calls + 1] = { "start", id, sec, inbox, port }; return port > 0 and 1 or 0 end
reaper.StudioSync_DirectStop = function(id) calls[#calls + 1] = { "stop", id } end
reaper.StudioSync_DirectSend = function(id, rel, path, peers) calls[#calls + 1] = { "send", id, rel, path, peers }; return 1 end
reaper.StudioSync_DirectPoll = function(after) for _, s in ipairs(polled) do if tonumber(s:match("^%d+")) > after then return s end end; return "" end
reaper.StudioSync_DirectMsg = function() return 1 end -- (1.0.8: the extension is mandatory, 0.60.0-rt)
reaper.StudioSync_DirectClock = function() return "{}" end
reaper.StudioSync_DirectStream = function() return 1 end
reaper.StudioSync_DirectStatus = function()
  return '{"listening":false,"bind":"","error":"","received":2,"rejected":1,"last_reject":"a bad signature","peers":{"james-laptop.tail99.ts.net:47281":{"ok":true,"ms":31.5,"at":1,"sent":4,"error":""}}}'
end
listings["J:/St/Smiley/_band/devices"] = { "James.json", "James-Laptop.json", "Chilio-Mac.json" }
local by_file = { ["James.json"] = devs[1], ["James-Laptop.json"] = devs[2], ["Chilio-Mac.json"] = devs[3] }
band.read_json = function(path) return by_file[path:match("[^/]+$")] end
assert(direct.ensure(cfg) == true, "started")
assert(calls[1][1] == "start" and calls[1][2] == "studiosync-smiley" and calls[1][3] == "s3cret" and calls[1][4] == "H/direct/studiosync-smiley" and calls[1][5] == -1,
  "with the studio's secret and an inbox outside the shared folder, send-only while Windows has no firewall rule")
assert(direct.ensure(cfg) == true and #calls == 1, "not started again within 10 s")
hidden_out = shown
clock = clock + 11
direct.ensure(cfg)
assert(calls[2][5] == 47281, "listening once the rule is there")
calls = {}
assert(direct.offer(cfg, "J:/St/Smiley/" .. ok_rel) == false and #calls == 0, "nobody to send to before the Live sync tick made the list (never asked at send time)")
direct.refresh_peers(cfg, "Nostalgia", "main")
assert(direct.offer(cfg, "J:\\St\\Smiley\\" .. ok_rel:gsub("/", "\\")) == true, "offered")
assert(calls[1][1] == "send" and calls[1][3] == ok_rel and calls[1][5] == "james-laptop.tail99.ts.net:47281", "to whoever's here only, by its path in the studio")
calls = {}
assert(direct.offer(cfg, "J:/St/Smiley/Nostalgia/rooms/main/claims/James.json") == false and #calls == 0, "never anything but an event file")
here = {}
clock = clock + 3
direct.refresh_peers(cfg, "Nostalgia", "main")
assert(direct.offer(cfg, "J:/St/Smiley/" .. ok_rel) == false and #calls == 0, "nobody here: nothing sent")
here = { "James-Laptop" }
secret = nil
clock = clock + 11
assert(direct.ensure(cfg) == false and calls[1][1] == "stop", "no secret: stopped, Syncthing alone")
secret = "s3cret"
clock = clock + 11

-- What arrived: listed, found, counted, tidied
local idir = "H/direct/studiosync-smiley/Nostalgia/rooms/main/events"
assert(direct.inbox_dir(cfg, edir) == idir and direct.inbox_dir(cfg, "J:/St/Smiley/_band") == nil, "a room's inbox")
listings[idir] = { "a.json", "b.json", "b.json.part12-1" }
local list, from = direct.listing(cfg, edir)
assert(#list == 2 and list[1] == "a.json" and list[2] == "b.json" and from and from["b.json"] == idir .. "/b.json" and not from["a.json"],
  "the names only in the inbox added, with their paths; not one Syncthing brought too, nor one being written")
assert(#listings[edir] == 1, "band.listing's shared table is never changed")
files[idir .. "/b.json"] = true
assert(direct.path(cfg, edir, "b.json") == idir .. "/b.json", "read from the inbox until the shared copy is there")
assert(direct.path(nil, edir, "b.json") == idir .. "/b.json", "found with only the folder at hand (mirror's plain_event), in a studio started here")
local raw = { "a.json", "c.txt" }
local merged, mfrom = direct.merge(cfg, edir, raw)
assert(#merged == 3 and merged[3] == "b.json" and mfrom["b.json"] and #raw == 2, "the cue watch's raw listing merged the same way, untouched")
files[edir .. "/b.json"] = true
assert(direct.path(cfg, edir, "b.json") == edir .. "/b.json", "then the shared folder's: it's the record")
assert(direct.tick(cfg) == 2 and direct.tick(cfg) == 0, "two arrived, counted once")
polled[3] = "3\tstudiosync-smiley\t" .. ok_rel
assert(direct.tick(cfg) == 1, "and the next")
listings["H/direct/studiosync-smiley/"] = { "Nostalgia" }
listings["H/direct/studiosync-smiley/Nostalgia/rooms/"] = { "main" }
listings[idir] = { "James-20261119-120000Z-00001-0001.json", "James-20200101-000000Z-00001-0001.json", "James-" .. os.date("!%Y%m%d-%H%M%S") .. "Z-00001-0002.json", "x.json.part1-1" }
files[edir .. "/James-20261119-120000Z-00001-0001.json"] = true
local removed, real_remove = {}, os.remove
os.remove = function(path) removed[#removed + 1] = path:match("[^/]+$"); return true end
local n = direct.prune(cfg)
os.remove = real_remove
table.sort(removed)
assert(n == 2 and removed[1] == "James-20200101-000000Z-00001-0001.json" and removed[2] == "James-20261119-120000Z-00001-0001.json",
  "the inbox loses what Syncthing brought and what's over a day old; a new one and one being written stay: " .. table.concat(removed, " "))

-- Health
local okl, line = direct.health_line(cfg)
assert(okl == false and line:find("sending only") and line:find("james%-laptop %(32 ms%)") and line:find("refused 1"), "Health's line: " .. line)
local st = direct.status(cfg)
assert(st.available and st.firewall and st.peers[1].peer == "james-laptop.tail99.ts.net:47281" and st.peers[1].ms == 31.5, "status per computer")
print("ok")
