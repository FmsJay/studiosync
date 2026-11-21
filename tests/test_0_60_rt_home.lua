-- The web UI's Home page (lib/webhome.lua) and profiles (lib/profile.lua): pictures checked byte by byte (PNG/JPEG only, whole, within the
-- limits; no SVG, nothing else), names and colours from a page, writing only your own profile, reading a bandmate's only when its file speaks
-- for its own name; Home's parts (who changed each project last and what, who's online where, new takes, mixes and stems, mentions and to-dos
-- for you), opening a project the panel's way, building only while a page shows Home; then the page files. (James, rt)
package.path = "lib/?.lua;" .. package.path
local clock, ext, projext, logged, ran = 1000, {}, {}, {}, {}
local projects, front = {}, nil -- (stand-in REAPER tabs: { p, file, binding })
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetProjExtState = function(p, s, k)
    for _, t in ipairs(projects) do if t.p == p then return 1, t.binding[k] or "" end end
    return 0, ""
  end,
  EnumProjects = function(i)
    if i == -1 then return front end
    local t = projects[i + 1]
    if t then return t.p, t.file end
  end,
  SelectProjectInstance = function(p) front = p; ran[#ran + 1] = "select " .. tostring(p) end,
  AddRemoveReaScript = function(add, sec, path) ran[#ran + 1] = "register " .. path; return 4242 end,
  Main_OnCommand = function(id) ran[#ran + 1] = "run " .. id end,
  RecursiveCreateDirectory = function() return 1 end,
  file_exists = function(p) return FS and FS[p] ~= nil end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })

-- ---- a stand-in shared folder: path -> the file's bytes ---------------------------------------------------------------------------------
FS = {}
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end
local function children(dir, want_dirs)
  local out, seen, pre = {}, {}, dir .. "/"
  for path in pairs(FS) do
    if path:sub(1, #pre) == pre then
      local rest = path:sub(#pre + 1)
      local first, more = rest:match("^([^/]+)(/?)")
      if first and ((more == "/") == want_dirs) and not seen[first] then seen[first] = true; out[#out + 1] = first end
    end
  end
  table.sort(out)
  return out
end
band.read = function(p) return FS[p] end
band.size = function(p) return FS[p] and #FS[p] or nil end
band.read_json = function(p) local s = FS[p]; local v = s and band.json_decode(s); return type(v) == "table" and v or nil end
band.write_atomic = function(p, s) FS[p] = s end
band.write_json = function(p, t) FS[p] = band.json_encode(t) end
band.remove = function(p) FS[p] = nil; return true end
band.files = function(dir, e) local o = {}; for _, f in ipairs(children(dir, false)) do if not e or f:sub(-#e) == e then o[#o + 1] = f end end return o end
band.listing = function(dir, e) return band.files(dir, e) end
band.subdirs = function(dir) return children(dir, true) end
os.remove = function(p) FS[p] = nil; return true end
package.loaded.access = { mine = function() return nil end }
package.loaded.sync = { room_dir = function(cfg, song, room) return cfg.root .. "/" .. song .. "/rooms/" .. room end, id_user = function(u) return (u:gsub("[^%w%-_]", "_")) end,
  base_name = function(n) return n end }
package.loaded.mirror = { PART = { fx = "the plug-ins" } }

local profile, webhome = require("profile"), require("webhome")

-- ---- pictures: only whole PNG or JPEG files within the limits ----------------------------------------------------------------------------
local function be32(n) return string.char((n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255) end
local function png(w, h) return "\137PNG\r\n\26\n" .. "\0\0\0\13IHDR" .. be32(w) .. be32(h) .. "\8\2\0\0\0" .. "CRC!" .. "\0\0\0\0IEND\174\66\96\130" end
local function jpeg(w, h, data)
  return "\255\216" .. "\255\224\0\16JFIF\0\1\1\0\0\1\0\1\0\0"
    .. "\255\192\0\17\8" .. string.char(h >> 8, h & 255, w >> 8, w & 255) .. "\3\1\34\0\2\17\1\3\17\1"
    .. "\255\218\0\8\1\1\0\0\63\0" .. (data or "pixels") .. "\255\217"
end
local m, w, h = profile.image_info(png(96, 96))
assert(m == "image/png" and w == 96 and h == 96, "a PNG: its type and size from its own header")
m, w, h = profile.image_info(jpeg(96, 80))
assert(m == "image/jpeg" and w == 96 and h == 80, "a JPEG: its size from its frame header")
local svg = '<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"><rect width="10" height="10"/></svg>'
for what, bytes in pairs({ svg = svg, gif = "GIF89a" .. string.rep("\0", 40), html = "<html><script>alert(1)</script></html>" .. string.rep(" ", 20),
  exe = "MZ" .. string.rep("\0", 60), short = "\137PNG", cut_png = png(96, 96):sub(1, -5), cut_jpeg = jpeg(96, 96):sub(1, -3),
  big_png = png(4000, 10), big_jpeg = jpeg(10, 300), zero = png(0, 10), nosof = "\255\216\255\218\0\8\1\1\0\0\63\0" .. string.rep("x", 20) .. "\255\217",
  huge = jpeg(96, 96, string.rep("x", profile.PIC_MAX)), badlen = "\255\216\255\224\255\255" .. string.rep("x", 30) .. "\255\217" }) do
  assert(profile.image_info(bytes) == nil, what .. ": refused")
end
assert(select(2, profile.image_info(svg)):find("PNG or JPEG"), "says why: PNG or JPEG only")
-- base64 both ways, strictly
local j = jpeg(64, 64)
assert(require("fxfiles").unbase64(profile.base64(j)) == j and profile.base64("ab") == "YWI=" and profile.base64("abc") == "YWJj", "base64")
assert(profile.unbase64("data:image/jpeg;base64," .. profile.base64(j)) == j, "a data: URL's base64 taken")
assert(profile.unbase64("YWJj!!!!") == nil and profile.unbase64("YWJ") == nil and profile.unbase64("") == nil and profile.unbase64(5) == nil, "not base64: refused")
assert(profile.unbase64(string.rep("A", math.ceil(profile.PIC_MAX / 3) * 4 + 4)) == nil, "more than a picture's worth: refused before decoding")
assert(profile.unbase64("data:text/html;base64," .. profile.base64("hi!")) == nil, "another data: type isn't stripped, so it's refused")
-- names and colours
assert(profile.clean_name("  Bee\n Smith ") == "Bee  Smith" and profile.clean_name("") == nil and profile.clean_name(7) == nil, "names: cleaned")
local long = profile.clean_name(string.rep("é", 30))
assert(#long <= profile.NAME_MAX and utf8.len(long) == 20, "a long name cut on a character")
assert(profile.colour_of("#00ff7F") == 0x00FF7F and profile.colour_of("") == false and profile.colour_of("red") == nil and profile.colour_of("#12345") == nil, "colours")
assert(profile.hex(0xd9822b) == "#d9822b" and profile.hex(nil) == nil, "hex")

-- ---- writing your own profile, reading everyone's ------------------------------------------------------------------------------------------
local cfg, b = { root = "R", user = "James Bond" }, { song = "Sunset", room = "main" }
local reply, said = profile.action(cfg, { id = "p1", name = "Jimmy", pic = profile.base64(jpeg(96, 96)) })
assert(reply.ok and reply.id == "p1" and said, "saved")
local mine = band.read_json("R/_band/profiles/James_Bond.json")
assert(mine.user == "James Bond" and mine.name == "Jimmy" and mine.pic == "jpg" and FS["R/_band/profiles/James_Bond.jpg"] == jpeg(96, 96), "the profile and its picture, one file each")
reply = profile.action(cfg, { id = "p2", pic = profile.base64(svg) })
assert(not reply.ok and reply.why and FS["R/_band/profiles/James_Bond.jpg"] == jpeg(96, 96), "an SVG: refused, the old picture kept")
reply = profile.action(cfg, { id = "p3", pic = profile.base64(png(48, 48)) })
assert(reply.ok and FS["R/_band/profiles/James_Bond.png"] and not FS["R/_band/profiles/James_Bond.jpg"] and band.read_json("R/_band/profiles/James_Bond.json").pic == "png", "a PNG replaces the JPEG")
local picked
require("people").pick = function(c, rgb) picked = { c.user, rgb } end
reply = profile.action(cfg, { colour = "#112233" })
assert(reply.ok and picked[2] == 0x112233, "a colour goes to people.pick (every studio you're in)")
profile.action(cfg, { colour = "" })
assert(picked[2] == nil, "back to the default colour")
assert(not profile.action(cfg, { colour = "javascript:" }).ok, "not a colour: refused")
-- bandmates' files
FS["R/_band/profiles/Bee.json"] = band.json_encode({ user = "Bee", name = "Bee <b>", pic = "jpg", time = "t1" })
FS["R/_band/profiles/Bee.jpg"] = jpeg(80, 80)
FS["R/_band/profiles/Mallory.json"] = band.json_encode({ user = "Bee", name = "Not Bee", time = "t1" }) -- (speaks for someone else's name)
FS["R/_band/profiles/Cy.json"] = band.json_encode({ user = "Cy", pic = "png", time = "t1" })
FS["R/_band/profiles/Cy.png"] = svg .. string.rep(" ", 30) -- (an SVG named .png)
FS["R/_band/profiles/Di.json"] = band.json_encode({ user = "Di", pic = "jpg", time = "t1" })
FS["R/_band/profiles/Di.jpg"] = jpeg(96, 96, string.rep("x", profile.PIC_MAX + 10)) -- (too big: never read whole)
FS["R/_band/colours/Bee.json"] = band.json_encode({ user = "Bee", colour = 0x4CC2FF })
profile.forget("R")
local all = profile.all("R")
assert(all.Bee.name == "Bee <b>" and all.Bee.pic:find("^data:image/jpeg;base64,") and all.Bee.colour == "#4cc2ff", "Bee: name, picture as a data: JPEG, colour")
assert(all.Cy and all.Cy.pic == nil and all.Di.pic == nil, "an SVG named .png and an oversized picture: no picture")
assert(all["James Bond"].pic:find("^data:image/png;base64,") and all["James Bond"].name == "Jimmy", "yours")
local n = 0
for u in pairs(all) do n = n + 1; assert(u ~= "Mallory") end
assert(all.Bee.name ~= "Not Bee", "a file speaking for someone else's name is ignored")
assert(profile.model(cfg).me == "James Bond", "the topic says who you are")

-- ---- Home: the pure parts ------------------------------------------------------------------------------------------------------------------
assert(webhome.stamp_of("James-20261120-101500Z-00001-1234.json") == "20261120-101500", "the stamp, from fixed places")
assert(webhome.stamp_of("James-20261120-101500Z-123456-1234.json") == "20261120-101500", "a long sequence number: the pattern")
assert(webhome.stamp_of("junk.json") == nil and webhome.stamp_of("a-b-c.json") == nil, "no stamp")
assert(webhome.iso("20261120-101500") == "2026-11-20T10:15:00Z" and webhome.iso("x") == nil, "iso")
local top = webhome.newest({ "a3", "a1", "b9", "a2", "x" }, 2, function(f) return f:match("%d") end)
assert(#top == 2 and top[1].f == "b9" and top[2].f == "a3", "the newest k, newest first")
local real_chat = require("page_chat")
local mx = webhome.mix_of("Sunset 2026-11-20 101500 Bee.wav")
assert(mx and mx.user == "Bee" and mx.time:match("^2026%-11%-%d%dT%d%d:%d%d:%d%dZ$"), "a mix's name: who and when (local time to UTC)")
-- rt-p5: a mix's time is the file's own modified time when it's known (one clock for everyone), the name's (the renderer's local clock) otherwise
local mt = webhome.mix_of("Sunset 2026-11-20 101500 Bee.wav", "2026-11-20 14:00:00")
assert(mt.time == os.date("!%Y-%m-%dT%H:%M:%SZ", os.time({ year = 2026, month = 11, day = 20, hour = 14, min = 0, sec = 0 })) and mt.user == "Bee",
  "a mix's time from the file's modified time, not its name: " .. tostring(mt.time))
assert(webhome.mix_of("Sunset 2026-11-20 101500 Bee.wav", "1601-01-01 00:00:00").time == mx.time and webhome.mix_of("Sunset 2026-11-20 101500 Bee.wav", "junk").time == mx.time
  and webhome.stat_utc(nil) == nil, "a zeroed or unreadable modified time: the name's")
assert(webhome.stems_of("2026-11-20 1015 Bee", "2026-11-20 16:30:00").time == os.date("!%Y-%m-%dT%H:%M:%SZ", os.time({ year = 2026, month = 11, day = 20, hour = 16, min = 30, sec = 0 })), "a stems folder's too")
assert(webhome.mix_of("notes.txt") == nil and webhome.mix_of("Sunset final.wav") == nil and webhome.mix_of(".Sunset 2026-11-20 101500 Bee.wav") == nil, "not a mix")
local st = webhome.stems_of("2026-11-20 1015 Bee")
assert(st and st.user == "Bee" and st.time, "a stems folder")
assert(webhome.mentions("hey @james, look", { "James" }) and webhome.mentions("@Jimmy!", { "James", "Jimmy" }) and not webhome.mentions("@jameson", { "James" })
  and not webhome.mentions("james", { "James" }) and webhome.mentions("ok @James Bond", { "James Bond" }) and webhome.mentions("@everyone in", webhome.EVERYONE), "mentions")
local now = os.time()
local function iso_ago(s) return os.date("!%Y-%m-%dT%H:%M:%SZ", now - s) end
local cm = webhome.chat_model({
  msgs = { { user = "Bee", text = "old @James", time = iso_ago(30 * 86400), file = "x/m0.json" }, { user = "Bee", text = "hi @James", time = iso_ago(60), file = "x/m1.json", where = "Sunset" },
    { user = "James", text = "@James me", time = iso_ago(50), file = "x/m2.json" }, { user = "Cy", text = "plain", time = iso_ago(40), file = "x/m3.json" } },
  todo = { { user = "Bee", text = "retrack @James", file = "x/t1.json" }, { user = "Bee", text = "@James done", done = true, file = "x/t2.json" },
    { user = "Cy", text = "bass", ["for"] = "James", file = "x/t3.json" }, { user = "Cy", text = "drums", file = "x/t4.json" } } }, "James", { "James" }, now)
assert(#cm.mentions == 1 and cm.mentions[1].id == "m1" and cm.mentions[1].where == "Sunset", "mentions: recent, not yours, not 30 days old")
assert(#cm.recent == 3 and cm.recent[1].id == "m3", "recent messages, newest first, not yours")
assert(#cm.todos == 2 and cm.todos[1].id == "t3" and cm.todos[2].id == "t1", "to-dos for you: named or given to you, not done")
assert(webhome.chat_model(nil, "James", {}, now).mentions[1] == nil, "no chat: empty")
local take = webhome.take_of({ kind = "obj", obj = "item", rev = 1, user = "Bee", name = "Guitar" }, function() return "Chorus - Bee - take 2" end)
assert(take and take.user == "Bee" and take.track == "Guitar", "a smart-named new item: a take")
assert(webhome.take_of({ kind = "obj", obj = "item", rev = 1, user = "Bee", name = "Gtr" }, function() return "03-Gtr-261120.flac", "C:/x/03-Gtr-261120.flac" end), "REAPER's own name: a take")
assert(not webhome.take_of({ kind = "obj", obj = "item", rev = 2, user = "Bee" }, function() return "Chorus - Bee - take 2" end)
  and not webhome.take_of({ kind = "obj", obj = "item", rev = 1, user = "Bee" }, function() return "my edit", "C:/x/a.wav" end)
  and not webhome.take_of({ kind = "obj", obj = "track", rev = 1 }, function() end), "an edit, a renamed item, a track: not takes")

-- ---- Home: built from a stand-in studio ---------------------------------------------------------------------------------------------------
local function put(path, t) FS[path] = band.json_encode(t) end
put("R/Sunset/session.json", { host = "James Bond", published = "2026-11-01T10:00:00Z" })
put("R/Moonrise/session.json", { host = "Bee", published = "2026-11-02T10:00:00Z" })
put("R/Quiet/session.json", { host = "Cy", published = "2026-10-01T10:00:00Z" })
put("R/Sunset/chat/stage.json", { stage = "Mixing" })
local t1, t2 = os.date("!%Y%m%d-%H%M%S", now - 3600), os.date("!%Y%m%d-%H%M%S", now - 60)
put("R/Sunset/rooms/main/events/Bee-" .. t1 .. "Z-00001-1111.json", { id = "e1", time = webhome.iso(t1), type = "obj", obj = "item", rev = 1, user = "Bee", name = "Guitar",
  state = '<ITEM\nNAME "Chorus - Bee - take 1"\n>' })
put("R/Sunset/rooms/main/events/Cy-" .. t2 .. "Z-00002-2222.json", { id = "e2", time = webhome.iso(t2), type = "obj", obj = "item", rev = 3, user = "Cy", name = "Bass", pos = 12 })
put("R/Moonrise/rooms/main/events/Bee-" .. os.date("!%Y%m%d-%H%M%S", now - 7200) .. "Z-00001-1111.json", { id = "e3", time = iso_ago(7200), type = "note", user = "Bee", text = "nice", pos = 3 })
put("R/Moonrise/rooms/idea/events/Di-" .. os.date("!%Y%m%d-%H%M%S", now - 120) .. "Z-00001-1111.json", { id = "e4", time = iso_ago(120), type = "obj", obj = "track", rev = 1, user = "Di", name = "Synth", auto = true })
put("R/Sunset/rooms/main/status/Bee.json", { user = "Bee", time = iso_ago(5), recording = true })
put("R/Moonrise/rooms/idea/status/Cy.json", { user = "Cy", time = iso_ago(10), front = false })
put("R/Moonrise/rooms/main/status/Di.json", { user = "Di", time = iso_ago(600) }) -- (gone)
FS["R/Sunset/mixes/Sunset 2026-11-19 210000 Bee.wav"] = "RIFF"
FS["R/Sunset/stems/2026-11-20 0900 Cy/Bass.wav"] = "RIFF"
projects = { { p = "P1", file = "C:/x/Sunset.rpp", binding = { song = "Sunset", room = "main" } } }
front = "P1"
local chat_calls = {}
package.loaded.page_chat = {
  -- (the cheap read of the newest, as Home asks for it: rt-p5; the chat's own mention rule and names)
  newest = function(_, _, sc, k, kt) chat_calls[#chat_calls + 1] = { sc, k, kt }; return { msgs = { { user = "Bee", text = "@Jimmy listen", time = iso_ago(30), file = "c/m9.json", where = "Moonrise" } }, todo = {} } end,
  names_of = function(c) return { c.user, "Jimmy", "everyone", "all" } end,
  mentions = real_chat.mentions,
  unread = function() return 3 end,
}
local H = webhome.build("P1", cfg, b, clock)
assert(H.me == "James Bond" and H.song == "Sunset" and H.room == nil, "who and where")
local names = {}
for i, p in ipairs(H.projects) do names[i] = p.name end
assert(table.concat(names, ",") == "Sunset,Moonrise,Quiet", "projects by their last change: " .. table.concat(names, ","))
local sun, moon, quiet = H.projects[1], H.projects[2], H.projects[3]
assert(sun.current and sun.open and sun.stage == "Mixing" and sun.rooms == 1, "this project: open here, its stage")
assert(sun.last.user == "Cy" and sun.last.what:find("Bass") and sun.last.time == webhome.iso(t2), "who changed it last, what and when: " .. tostring(sun.last.what))
assert(moon.last.user == "Bee" and moon.last.what:find("note"), "an automatic change doesn't count as working on it")
assert(quiet.last.what == "published it" and quiet.last.user == "Cy", "never changed: its publish")
assert(#sun.online == 1 and sun.online[1].user == "Bee" and sun.online[1].rec, "online in Sunset: Bee, recording")
assert(#moon.online == 1 and moon.online[1].user == "Cy" and moon.online[1].room == "idea" and moon.online[1].away, "Cy in a side room, another tab in front; Di gone")
local me_on
for _, x in ipairs(H.online) do if x.me then me_on = x end end
assert(me_on and me_on.song == "Sunset" and not me_on.away and #H.online == 3, "you, where your tabs are")
assert(#H.takes == 1 and H.takes[1].user == "Bee" and H.takes[1].track == "Guitar" and H.takes[1].song == "Sunset", "the new take")
assert(#H.bounces == 2 and H.bounces[1].kind == "stems" and H.bounces[2].kind == "mix" and H.bounces[2].user == "Bee", "mixes and stems, newest first")
assert(#H.mentions == 1 and H.mentions[1].id == "m9" and H.unread == 3 and chat_calls[1][1] == "band", "a mention by your display name; this project's unread count; the studio's chat read")
assert(chat_calls[1][2] == webhome.CHAT_MSGS and chat_calls[1][3] == webhome.CHAT_TODOS and webhome.CHAT_MSGS < 500, "the newest only, not the whole chat (rt-p5)")
assert(H.projects[1].since == nil and H.opened == nil, "no stamp from the page: nothing 'since'; nothing opened")
-- with the chat's own index (rt-chat2's unread_summary): every conversation's count
package.loaded.page_chat.unread_summary = function() return { total = 5, mentions = 1, by = { song = { n = 2, name = "This project", kind = "here" }, ["ch:abc"] = { n = 3, name = "mixing", kind = "ch" }, band = { n = 0, name = "Studio" } } } end
clock = clock + 100
webhome._reset()
H = webhome.build("P1", cfg, b, clock)
assert(H.unread == 5 and H.unread_at == 1 and #H.unread_by == 2 and H.unread_by[1].name == "mixing", "unread by conversation, most first")

-- rt-p5: the mix's time from the file's modified time when JS_File_Stat is there (the renderer's clock isn't ours), cached per file
local stat_calls = 0
reaper.JS_File_Stat = function(path)
  stat_calls = stat_calls + 1
  if path:find("210000 Bee.wav", 1, true) then return 0, 4, "", "2026-11-21 20:00:00" end
  return -1
end
webhome._reset()
H = webhome.build("P1", cfg, b, clock + 200)
assert(H.bounces[1].kind == "mix" and H.bounces[1].time == os.date("!%Y-%m-%dT%H:%M:%SZ", os.time({ year = 2026, month = 11, day = 21, hour = 20, min = 0, sec = 0 })),
  "the mix is newest by its file's own time (the stems folder's can't be read: its name's)")
local calls0 = stat_calls
H = webhome.build("P1", cfg, b, clock + 400)
assert(stat_calls == calls0, "a file's modified time is read once")
reaper.JS_File_Stat = nil
-- since you were last here: others' changes newer than the stamp the page sent (a bad stamp ignored; yours and automatic ones not counted)
webhome._reset()
webhome.action("P1", cfg, b, { topic = "home", want = true, since = { Sunset = iso_ago(1800), Moonrise = iso_ago(3 * 3600), Quiet = "yesterday", [("x"):rep(200)] = iso_ago(5), ["Nope"] = 7 } })
H = webhome.build("P1", cfg, b, clock + 600)
local by_name = {}
for _, p in ipairs(H.projects) do by_name[p.name] = p end
assert(by_name.Sunset.since == 1 and by_name.Moonrise.since == 1 and by_name.Quiet.since == nil and by_name.Sunset.since_at, "since: Cy's change after 30 minutes ago (Bee's, an hour ago, is older), Bee's note 2 h ago; Di's automatic one isn't counted")
webhome.action("P1", cfg, b, { topic = "home", want = true, since = { Sunset = iso_ago(10) } })
H = webhome.build("P1", cfg, b, clock + 700)
assert(H.projects[1].since == nil and H.projects[1].name == "Sunset", "stamped after the last change: nothing since")
webhome.action("P1", cfg, b, { topic = "home", want = true })
H = webhome.build("P1", cfg, b, clock + 800)
assert(H.projects[1].since == nil, "a want with no map keeps the last one: still nothing since")

-- ---- opening a project: the panel's way --------------------------------------------------------------------------------------------------
ran = {}
assert(webhome.open(cfg, { song = "Nowhere" }):find("doesn't have") and #ran == 0, "a project this studio doesn't have: nothing run")
assert(webhome.open(cfg, { song = "Moonrise", room = "../x" }):find("room") and #ran == 0, "a room it doesn't have")
assert(webhome.open(cfg, { song = "Sunset" }):find("switched") and ran[1] == "select P1", "open here already: its tab to the front")
ran = {}
said = webhome.open(cfg, { song = "Moonrise", room = "idea" })
assert(said:find("opening") and ext[band.SECTION .. "/open project"] == "Moonrise|idea" and ran[1]:find("StudioSync %- Open session%.lua$") and ran[2] == "run 4242", "else Open session, told which")
-- rt-p5: run quietly (its boxes go to the page, not onto a screen nobody's at), and the page is told what the script said
local quiet_during
reaper.Main_OnCommand = function(id) ran[#ran + 1] = "run " .. id; quiet_during = ext[band.SECTION .. "/open quiet"]; ext[band.SECTION .. "/open said"] = "Couldn't read 'Moonrise' yet: it may still be arriving." end
ran = {}
said = webhome.open(cfg, { song = "Moonrise", room = "idea" })
assert(quiet_during == "1" and ext[band.SECTION .. "/open quiet"] == nil and ext[band.SECTION .. "/open said"] == nil, "the script runs with the quiet flag; both are gone after")
assert(said:find("still be arriving"), "the log says what the script said: " .. said)
webhome._reset()
webhome.open(cfg, { song = "Moonrise", room = "idea" })
webhome.action("P1", cfg, b, { topic = "home", want = true })
H = webhome.build("P1", cfg, b, clock + 900)
assert(H.opened and H.opened.song == "Moonrise" and H.opened.room == "idea" and H.opened.said:find("still be arriving"), "and the page is told")
H = webhome.build("P1", cfg, b, clock + 900 + 100)
assert(H.opened and os.time() - H.opened.at < 60, "(for a minute)")
reaper.Main_OnCommand = function(id) ran[#ran + 1] = "run " .. id end
assert(webhome.open(cfg, 7) == nil and webhome.open(cfg, { song = 5 }) == nil, "junk: nothing")

-- ---- the tick: Home only while a page shows it, profiles while any page looks ---------------------------------------------------------------
webhome._reset()
local pub = {}
local function publish(t, v) pub[t] = v end
webhome.tick("P1", cfg, b, publish, clock)
assert(pub.profiles and pub.profiles.people.Bee and not pub.home, "profiles go; Home not until a page shows it")
webhome.action("P1", cfg, b, { topic = "home", want = true })
webhome.tick("P1", cfg, b, publish, clock)
assert(pub.home and pub.home.projects, "Home built once a page shows it")
pub.home = nil
clock = clock + 5
webhome.tick("P1", cfg, b, publish, clock)
assert(not pub.home, "not again within EVERY s")
clock = clock + webhome.WANT_FOR + 1
webhome.tick("P1", cfg, b, publish, clock)
assert(not pub.home, "nobody showing it any more: not built")
said = webhome.action("P1", cfg, b, { topic = "profile", id = "x9", name = "J" })
webhome.tick("P1", cfg, b, publish, clock)
assert(pub.profiles.reply.id == "x9" and pub.profiles.reply.ok and pub.profiles.people["James Bond"].name == "J", "a profile change: its answer and the new profile at once")
-- rt-p5: a status line: yours only, cleaned, cut, cleared, stale after a day
said = webhome.action("P1", cfg, b, { topic = "profile", id = "st1", status = "back at 8" })
webhome.tick("P1", cfg, b, publish, clock + 1000)
assert(pub.profiles.reply.ok and pub.profiles.people["James Bond"].status == "back at 8" and pub.profiles.people["James Bond"].status_at, "a status line: saved, shown at once")
webhome.action("P1", cfg, b, { topic = "profile", id = "st2", status = ("mixing tonight, don't call "):rep(10) })
webhome.tick("P1", cfg, b, publish, clock + 1000)
assert(#pub.profiles.people["James Bond"].status <= profile.STATUS_MAX and pub.profiles.people["James Bond"].status:find("^mixing"), "cut to STATUS_MAX")
webhome.action("P1", cfg, b, { topic = "profile", id = "st3", status = 5 })
webhome.tick("P1", cfg, b, publish, clock + 1000)
assert(pub.profiles.reply.why and pub.profiles.reply.id == "st3", "not a status: refused")
assert(pub.profiles.people["James Bond"].name == "J", "and the name stays")
webhome.action("P1", cfg, b, { topic = "profile", id = "st4", status = "" })
webhome.tick("P1", cfg, b, publish, clock + 1000)
assert(pub.profiles.reply.ok and pub.profiles.people["James Bond"].status == nil, "an empty one clears it")
local pf = profile.dir("R") .. "/James_Bond.json"
FS[pf] = band.json_encode({ user = "James Bond", name = "J", status = "old news", status_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 25 * 3600) })
profile.forget("R")
assert(profile.all("R")["James Bond"].status == nil, "a day old: no longer shown")
FS[pf] = band.json_encode({ user = "James Bond", name = "J", status = "<b>hi</b>\nthere", status_at = os.date("!%Y-%m-%dT%H:%M:%SZ") })
profile.forget("R")
assert(profile.all("R")["James Bond"].status == "<b>hi</b> there", "a bandmate's file is cleaned on reading too (control characters; the page shows text only)")
band.write_atomic = function() error("disk full") end
said = webhome.action("P1", cfg, b, { topic = "profile", id = "x10", pic = profile.base64(jpeg(10, 10)) })
webhome.tick("P1", cfg, b, publish, clock)
assert(said:find("couldn't be saved") and pub.profiles.reply.id == "x10" and pub.profiles.reply.why, "a write that fails: said, not raised")
local webui = require("webui")
assert(webui.ACTIONS.home and webui.ACTIONS.profile, "topics the pages may send")
local open_session = io.open("StudioSync - Open session.lua", "rb"):read("a")
assert(open_session:find('"open quiet"', 1, true) and open_session:find('"open said"', 1, true), "Open session says its boxes to the log and the page when a page asked (rt-p5)")

-- ---- the page files -------------------------------------------------------------------------------------------------------------------------
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s end
local index = read("lib/webui/index.html")
for _, f in ipairs({ "home.js", "profile.js", "home.css" }) do
  assert(index:find('"' .. f .. '"', 1, true), "index.html links " .. f)
  local s = read("lib/webui/" .. f)
  assert(not s:find("innerHTML%s*=%s*[^%s'\"]") and not s:find("eval%(") and not s:find("https?://[%w]"), f .. ": no HTML from data, no eval, nothing fetched from elsewhere")
end
assert(index:find('"tabs.js"', 1, true) < index:find('"profile.js"', 1, true) and index:find('"profile.js"', 1, true) < index:find('"home.js"', 1, true), "after tabs.js, profile.js before home.js")
assert(read("lib/webui/home.js"):find("ssTabs.act('home'", 1, true) and read("lib/webui/profile.js"):find("ssTabs.act('profile'", 1, true), "each sends on its own topic")
assert(read("lib/webui/profile.js"):find("data:image\\/(png|jpeg);base64", 1, true), "only a data: PNG or JPEG becomes a picture")
-- rt-p5: the page's side of the status line, "since you were last here", the banner over a link without notifications, the to-do assignee
local hjs, cjs = read("lib/webui/home.js"), read("lib/webui/chat.js")
assert(hjs:find("status: t", 1, true) and hjs:find("since: sinceMap", 1, true) and hjs:find("isSecureContext", 1, true) and hjs:find("hbanner", 1, true) and hjs:find("h.opened", 1, true),
  "home.js: status line, since map, a banner where browsers won't notify, what Open said")
assert(cjs:find("todofor", 1, true) and cjs:find("'everyone', 'all'", 1, true), "chat.js: a to-do's assignee, mentions of several names")
assert(read("lib/webui/app.js"):find("li.dataset.avUser = x.user", 1, true), "Who's here rows carry who, for their picture")
print("ok")
