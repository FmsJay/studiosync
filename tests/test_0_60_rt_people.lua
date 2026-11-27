-- rt-people (James's findings 2026-11-27): messages unread after being read, asking someone to join a project they're already in, Online now's
-- duplicates and stale entries, and a person's computers folded into one (lib/persons.lua). Over a stand-in shared folder; each part failed on
-- the code before it. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  RecursiveCreateDirectory = function() return 1 end,
  EnumProjects = function(i) if i == -1 then return "P1" end return nil end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function() end

-- ---- a stand-in shared folder ---------------------------------------------------------------------------------------------------------------
local fs = {}
local function copyv(v) return type(v) == "table" and band.json_decode(band.json_encode(v)) or v end
band.write_json = function(path, t) fs[path] = copyv(t) end
band.read_json = function(path) return type(fs[path]) == "table" and copyv(fs[path]) or nil end
band.read = function(path) return type(fs[path]) == "table" and band.json_encode(fs[path]) or nil end
band.files = function(dir, ext_)
  local out = {}
  for path in pairs(fs) do local d, f = path:match("^(.*)/([^/]+)$"); if d == dir and (not ext_ or f:sub(-#ext_) == ext_) then out[#out + 1] = f end end
  table.sort(out)
  return out
end
band.subdirs = function(dir)
  local seen, out = {}, {}
  for path in pairs(fs) do local s = path:sub(1, #dir + 1) == dir .. "/" and path:sub(#dir + 2):match("^([^/]+)/"); if s and not seen[s] then seen[s] = true; out[#out + 1] = s end end
  table.sort(out)
  return out
end
band.listing = function() return {} end
band.songs = function() return { "S", "T" } end
band.home = function() return "H" end
band.info = function() return { id = "studio1", name = "Smiley" } end
reaper.file_exists = function(p) return fs[p] ~= nil end
local function now_iso(ago) return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - (ago or 0)) end
local function id_of(c) return (c):rep(7) .. ("-" .. (c):rep(7)):rep(7) end
local DEV = { ["James-Laptop"] = id_of("L"), ["James-Main"] = id_of("M"), Bo = id_of("B"), Cy = id_of("C") }

local direct_real = require("direct")
local sent = {}
package.loaded.direct = { plain = direct_real.plain, send_live = function(_, kind, d, song, room, id, to) sent[#sent + 1] = { kind = kind, d = d } end,
  messages = function() return {} end, dispatch = function() end, port = function() return 47281 end }
package.loaded.alerts = { send = function() end }
package.loaded.api = { event = function() end }
package.loaded.groups = { may_manage = function() return false end, tailnet = function() return nil end }
local refused = {} -- (users whose devices file a forger wrote: trust.device_ok says no)
package.loaded.trust = { device_ok = function(_, u) return not refused[u] end, own_file_ok = function() return true end, user_file = function(u) return u .. ".json" end }
local ID = "^" .. ("[%u%d]"):rep(7) .. ("%-" .. ("[%u%d]"):rep(7)):rep(7) .. "$"
package.loaded.services = { is_device_id = function(s) return type(s) == "string" and s:match(ID) ~= nil end, my_device_id = function() return DEV["James-Laptop"] end }
package.loaded.sync = { room_dir = function(cfg, song, room) return band.song_dir(cfg, song) .. "/rooms/" .. room end }
package.loaded.removal = { PUBLISH_KEY = "devices publish rt" }

local persons = require("persons")
local chat = require("page_chat")
local cfg = { root = "R", user = "James-Laptop" }
local b = { song = "S", room = "main" }
local function devfile(u, same)
  local list
  if same then list = {}; for _, x in ipairs(same) do list[#list + 1] = DEV[x] end end
  fs["R/_band/devices/" .. u .. ".json"] = { user = u, device = DEV[u], same = list }
end
for _, u in ipairs({ "James-Laptop", "James-Main", "Bo", "Cy" }) do devfile(u) end

-- ---- 1. read stays read ---------------------------------------------------------------------------------------------------------------------
-- a message in the room's chat, one in the project's, one in the studio's
fs["R/S/rooms/main/chat/msgs/20261127-100100-Bo-2.json"] = { text = "room one", user = "Bo", time = "2026-11-27T10:01:00Z", room = "main" }
fs["R/S/chat/msgs/20261127-100000-Bo-1.json"] = { text = "project one", user = "Bo", time = "2026-11-27T10:00:00Z", room = "main" }
fs["R/_band/chat/msgs/20261127-100200-Cy-3.json"] = { text = "studio one", user = "Cy", time = "2026-11-27T10:02:00Z" }
assert(chat.count_unread(cfg, b) == 3, "three unread to start with: " .. chat.count_unread(cfg, b))
-- This project (where Chat starts) shows the room's message too: reading it reads that one
chat.web_action(cfg, b, { topic = "chat", scope = "song", seen = true })
assert(chat.count_unread(cfg, b) == 1, "This project read: the room's message it showed is read too (was 2): " .. chat.count_unread(cfg, b))
assert(chat.unread_summary(cfg, b).by.room.n == 0, "Home and the phone agree")
chat.web_action(cfg, b, { topic = "chat", scope = "band", seen = true })
assert(chat.count_unread(cfg, b) == 0, "Studio read: everything it showed")
assert(ext[band.SECTION .. "/chat seen song T"] == "20261127-100200", "Studio's view covers every project")
-- read with the newest by name, not by the time a bandmate's clock wrote in it
fs["R/S/chat/msgs/20261127-110000-Bo-4.json"] = { text = "late clock", user = "Bo", time = "2026-11-27T09:00:00Z", room = "main" }
clock = clock + 10
chat.web_action(cfg, b, { topic = "chat", scope = "song", seen = true })
assert(chat.count_unread(cfg, b) == 0, "a message whose writer's clock ran behind: read once shown")
-- Home's count goes again at once after a read here
local gen = chat.seen_gen
fs["R/S/chat/msgs/20261127-120000-Bo-5.json"] = { text = "new", user = "Bo", time = "2026-11-27T12:00:00Z", room = "main" }
clock = clock + 10
chat.web_action(cfg, b, { topic = "chat", scope = "song", seen = true })
assert(chat.seen_gen > gen, "Home is told")
-- the page always says it read the newest (it skipped saying so while the conversation list still showed 0, and the message stayed unread)
local js = io.open("lib/webui/chat.js"):read("a")
assert(not js:find("if (!cv || cv.n) ssTabs.act('chat', { seen: true", 1, true), "chat.js marks seen whatever the list's count says")

-- ---- 9. a person's computers folded together --------------------------------------------------------------------------------------------------
-- pure: both must say so
local function g(list) return persons.groups(list) end
local L, M, B, C = DEV["James-Laptop"], DEV["James-Main"], DEV.Bo, DEV.Cy
local one = g({ { user = "James-Laptop", device = L, same = { M } }, { user = "James-Main", device = M } })
assert(next(one) == nil, "one side saying so folds nobody")
local two = g({ { user = "James-Laptop", device = L, same = { M } }, { user = "James-Main", device = M, same = { L } }, { user = "Bo", device = B, same = { L } } })
assert(two["James-Laptop"].key == "James-Laptop" and two["James-Main"].key == "James-Laptop" and #two["James-Main"].users == 2 and not two.Bo,
  "both ways: one person; Bo naming James's computer gains nothing")
local three = g({ { user = "A", device = L, same = { M } }, { user = "B", device = M, same = { L, B } }, { user = "C", device = B, same = { M } } })
assert(three.C.key == "A" and #three.A.users == 3, "a third computer linked to either joins the person")
assert(#persons.same_of({ same = { "x", L, 5 } }) == 1, "only device ids")
assert(persons.name_of({ "James-Laptop", "James-Main" }, {}) == "James", "what the names share before a dash")
assert(persons.name_of({ "James-Laptop", "James-Main" }, { ["James-Main"] = { name = "Jimmy" } }) == "Jimmy", "a display name first")
assert(persons.name_of({ "Al", "Bo" }, {}) == "Al", "else the first name")
-- over the folder: this computer says James-Main is its, then James-Main says the same
fs["R/_band/profiles/James-Laptop.json"] = nil
assert(persons.set("R", "James-Main", true):find("one of your computers"), "Mine too")
assert(persons.same_for("R")[1] == M, "the devices file will say so")
assert(not persons.same("R", "James-Laptop", "James-Main"), "not yet: James-Main hasn't said so")
local cs = persons.computers("R", "James-Laptop")
local st = {}
for _, c in ipairs(cs) do st[c.user] = c.state end
assert(st["James-Laptop"] == "this" and st["James-Main"] == "waiting" and st.Bo == "other", "Your computers: waiting")
devfile("James-Laptop", { "James-Main" })
devfile("James-Main", { "James-Laptop" })
persons.forget()
assert(persons.same("R", "James-Laptop", "James-Main") and persons.label("R", "James-Main") == "James (James-Main)"
  and persons.label("R", "James-Main", "James-Laptop") == "you, on James-Main" and persons.label("R", "Bo") == "Bo", "folded, and labelled")
-- a forged file (its computer didn't write it) folds nobody
refused["James-Main"] = true
persons.forget()
assert(not persons.same("R", "James-Laptop", "James-Main"), "a devices file its own computer didn't write counts for nothing")
refused["James-Main"] = nil
persons.forget()
-- the profiles topic: one name and picture for the person
local prof = require("profile")
local folded = prof.fold({ ["James-Laptop"] = { colour = "#ff0000", pic = "data:image/png;base64,AA==" }, ["James-Main"] = { colour = "#00ff00" } }, persons.map("R"))
assert(folded["James-Main"].name == "James" and folded["James-Main"].pic == "data:image/png;base64,AA==" and folded["James-Main"].colour == "#ff0000"
  and folded["James-Main"].person == "James-Laptop", "James-Main reads as James, with James's picture and colour")
-- Who's here: one entry for the person
local pp = persons.fold_people({ { user = "James-Laptop", me = true, armed = { "Gtr" } }, { user = "Bo" }, { user = "James-Main", playing = true, armed = { "Vox" } } },
  function(u) return persons.of("R", u) end)
assert(#pp == 2 and pp[1].me and pp[1].playing and #pp[1].devices == 2 and #pp[1].armed == 2 and pp[2].user == "Bo" and not pp[2].devices, "Who's here: you and your other computer as one")
-- read on James-Main counts as read on James-Laptop, and James's own messages from James-Main aren't unread here
fs["R/S/chat/msgs/20261127-130000-Bo-6.json"] = { text = "after", user = "Bo", time = "2026-11-27T13:00:00Z", room = "main" }
fs["R/S/chat/msgs/20261127-130100-James_Main-7.json"] = { text = "from my other computer", user = "James-Main", time = "2026-11-27T13:01:00Z", room = "main" }
clock = clock + 20
assert(chat.unread_in(cfg, b, "song") == 1, "James-Main's own message isn't unread to James: " .. chat.unread_in(cfg, b, "song"))
fs["R/_band/seen/James-Main.json"] = { user = "James-Main", at = os.time(), seen = { ["chat seen song S"] = "20261127-130100" } }
clock = clock + 20
assert(chat.unread_in(cfg, b, "song") == 0, "read on James-Main: read here too")
-- and this computer writes its own for James-Main
fs["R/S/chat/msgs/20261127-140000-Bo-8.json"] = { text = "later", user = "Bo", time = "2026-11-27T14:00:00Z", room = "main" }
clock = clock + 20
chat.web_action(cfg, b, { topic = "chat", scope = "song", seen = true })
assert(fs["R/_band/seen/James-Laptop.json"].seen["chat seen song S"] == "20261127-140000" and fs["R/_band/seen/James-Laptop.json"].user == "James-Laptop", "what I read goes to my other computers")
-- "@James" mentions both
assert(chat.has(chat.names_of(cfg), "James"), "the person's name mentions you")

-- ---- 3. Online now: one entry a person, gone after the normal time -----------------------------------------------------------------------------
local webhome = require("webhome")
-- pure
local f = webhome.fold({ { user = "Bo", song = "S" }, { user = "Bo", song = "T", play = true }, { user = "Cy", song = "S" } }, function(u) return u end, "S")
assert(#f == 2 and f[1].user == "Bo" and f[1].song == "T" and f[1].play and #f[1].devices == 2 and not f[2].devices, "Bo once, where he's playing first, the other place under him")
assert(webhome.fresh({ at = 0, changed = false }, -500, 10) and not webhome.fresh({ at = 0, changed = false }, -500, 50),
  "a clock running ahead: gone FRESH s after its stamp last changed here, not when its clock says")
assert(webhome.fresh({ at = 0, changed = true }, 120, 10) and not webhome.fresh({ at = 0, changed = false }, 120, 10), "a clock running behind, still writing: here")
-- the whole build: Bo has two projects open, James-Main is in T
package.loaded.extras = { stage = function() return nil end }
package.loaded.recall = { event = function() return nil end }
package.loaded.recap = { last = function() return nil end }
local function status(song, room, user, ago, extra)
  local s = { user = user, time = now_iso(ago), room = room }
  for k, v in pairs(extra or {}) do s[k] = v end
  fs["R/" .. song .. "/rooms/" .. room .. "/status/" .. user .. ".json"] = s
end
status("S", "main", "Bo", 2)
status("T", "main", "Bo", 3, { playing = true })
status("T", "main", "James-Main", 2)
status("T", "main", "Cy", 300) -- (closed it five minutes ago)
local h = webhome.build("P1", cfg, b, clock)
local names = {}
for _, x in ipairs(h.online) do names[#names + 1] = x.user .. (x.me and "*" or "") end
assert(#h.online == 2, "Online now: Bo once and James's other computer as you, Cy gone: " .. table.concat(names, ","))
local bo
for _, x in ipairs(h.online) do if x.user == "Bo" then bo = x end end
assert(bo and bo.play and #bo.devices == 2, "Bo: playing in T, and in S too")
assert(h.online[2].me and h.online[2].user == "James-Main", "James-Main is you (last, as your own entries are)")
local tf = 0
for _, p in ipairs(h.projects) do if p.name == "T" then tf = #p.online end end
assert(tf == 2, "T's faces: Bo and James, once each")
-- a clock ahead: Bo's status in S says it's a minute from now, and never changes again
status("S", "main", "Bo", -60)
status("T", "main", "Bo", -60, { playing = true })
clock = clock + 1
webhome.build("P1", cfg, b, clock)
clock = clock + webhome.FRESH + 1
status("T", "main", "James-Main", 1)
h = webhome.build("P1", cfg, b, clock)
for _, x in ipairs(h.online) do assert(x.user ~= "Bo", "Bo closed both an age ago by our clock: gone though his clock is ahead") end
assert(h.computers and #h.computers == 4, "Your computers on Home")

-- ---- 2. asking someone to join a project they're in -------------------------------------------------------------------------------------------
local invite = require("invite")
status("S", "main", "Bo", 1)
local ok, why = invite.ask(cfg, b, "Bo", "S", "main")
assert(not ok and why:find("already"), "Bo is in S already: not asked: " .. tostring(why))
ok, why = invite.ask(cfg, b, "James-Main", "S", "main")
assert(not ok and why:find("your own"), "your own other computer: not asked")
ok = invite.ask(cfg, b, "Cy", "S", "main")
assert(ok, "Cy isn't in S: asked")
local m = invite.model(cfg, b, os.time())
local inside, people = {}, {}
for _, u in ipairs(m.inside) do inside[u] = true end
for _, u in ipairs(m.people) do people[u] = true end
assert(inside.Bo and not inside.Cy and not people["James-Main"] and people.Bo, "the page offers no Ask to join on Bo, nor on your own computer")
-- a request for a project you're in already (on another of your computers): not offered
local dm = "dm:" .. chat.dm_id({ "Bo", "James-Laptop" })
fs["R/_band/dm/" .. dm:sub(4) .. "/members.json"] = { members = { "Bo", "James-Laptop" } }
local t1 = os.date("!%Y%m%d-%H%M%S")
fs["R/_band/dm/" .. dm:sub(4) .. "/msgs/" .. t1 .. "-Bo-1.json"] = { text = "asks you to join T", user = "Bo", time = now_iso(5), join = { song = "T", room = "main" } }
clock = clock + 10
assert(#invite.pending(cfg, os.time()) == 0, "James-Main is in T: Bo's ask to join T isn't offered here")
status("T", "main", "James-Main", 600)
clock = clock + 10
assert(#invite.pending(cfg, os.time()) == 1, "once James-Main left T, it is")
local ij = io.open("lib/webui/invite.js"):read("a")
assert(ij:find("t.inside", 1, true) and ij:find("j.inside", 1, true), "invite.js offers neither")

print("ok rt-people: unread, join asks, Online now, a person's computers")
