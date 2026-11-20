-- The web UI's Lua side (lib/webui.lua): its addresses, what the pages are shown (who's here, claims, chat), what a page may send, and
-- Live sync's tick against a stand-in extension: started, published only on change and only from the tab in front, a chat send applied
-- through the Chat page's own store, the link's chat messages handed to it. The server itself: tests/webui_test.cpp.
package.path = "lib/?.lua;" .. package.path
local clock, ext, front = 1000, {}, "P1"
local pub, actions, started = {}, {}, 0
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  EnumProjects = function() return front end,
  GetPlayStateEx = function() return 5 end, -- playing and recording
  CountTracks = function() return 2 end,
  GetTrack = function(_, i) return i end,
  GetTrackName = function(tr) return true, tr == 0 and "Gtr" or "Vox" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
local webui = require("webui")
assert(not webui.available(), "an older extension: nothing")
assert(webui.tick("P1", {}, { song = "S", room = "main" }, {}) == nil, "and the tick does nothing")

-- Addresses
assert(webui.local_url(47281) == "http://127.0.0.1:47281/" and webui.local_url(nil) == "http://127.0.0.1:47281/", "this computer's")
assert(webui.phone_url("james-main.tail99.ts.net", 47281, "0123abcd") == "http://james-main.tail99.ts.net:47281/?t=0123abcd", "a phone's")
for _, bad in ipairs({ { nil, "ab" }, { "a b.ts.net", "ab" }, { "x/y", "ab" }, { "-x", "ab" }, { "pc.ts.net", "" }, { "pc.ts.net", "zz" }, { "pc.ts.net", nil } }) do
  assert(webui.phone_url(bad[1], 47281, bad[2]) == nil, "no link from a bad name or token: " .. tostring(bad[1]) .. " " .. tostring(bad[2]))
end

-- Who's here
local me = { user = "James", playing = true, recording = false, armed = { "Gtr", 5 } }
local peers = { { user = "chilio", playing = true, armed = { "Bass" }, live = "rt", call = "x" }, { user = "James" }, { user = "Andie", recording = true }, { nope = 1 } }
local who = { driver = "Andie", mode = "claims", tracks = { gtr = { user = "James", name = "Gtr" } }, regions = { chorus = { user = "Andie", name = "Chorus" } },
  times = { { user = "chilio", from = 10, to = 20 }, { user = "x", from = "a" } }, owner = function() end }
local m = webui.presence_model("Song", "main", me, peers, who)
assert(m.song == "Song" and m.room == "main" and m.driver == "Andie" and m.mode == "claims", "song, room, driver, mode")
local names = {}
for _, p in ipairs(m.people) do names[#names + 1] = p.user end
assert(table.concat(names, ",") == "James,Andie,chilio", "me first, then the others by name (me once): " .. table.concat(names, ","))
assert(m.people[1].me and m.people[1].playing and not m.people[1].recording and #m.people[1].armed == 1, "my state, armed names only")
assert(m.people[2].recording and not m.people[2].me and m.people[3].live == "rt" and m.people[3].call == true and m.people[3].armed[1] == "Bass", "theirs")
assert(#m.claims == 3 and m.claims[1].user == "Andie" and m.claims[1].kind == "region" and m.claims[1].name == "Chorus"
  and m.claims[2].user == "James" and m.claims[2].kind == "track" and m.claims[3].kind == "time" and m.claims[3].from == 10, "claims, a bad one left out")
assert(band.json_encode(webui.presence_model("S", "r", { user = "J" }, nil, nil)):find('"claims":%[%]'), "nobody and no claims: empty lists")

-- Chat
local msgs = {}
for i = 1, 105 do msgs[i] = { user = "u" .. i, text = "t" .. i, time = "2026-11-19T10:00:00Z", where = i == 105 and "main" or nil } end
msgs[104] = { user = "x" } -- (no text: left out)
msgs[105].file = "R/S/chat/msgs/20261119-100000-u105-1234.json"
local c = webui.chat_model({ msgs = msgs }, function(w) return w and ("room " .. w) or nil end)
assert(c.scope == "song" and #c.msgs == 99 and c.msgs[1].text == "t6" and c.msgs[#c.msgs].text == "t105" and c.msgs[#c.msgs].where == "room main", "the newest 100, oldest first")
assert(c.msgs[#c.msgs].id == "20261119-100000-u105-1234" and c.msgs[1].id == nil, "a message's id: its file's name")
assert(#webui.chat_model(nil).msgs == 0 and #webui.chat_model({}).todo == 0, "no messages")
-- to-dos and links, and the other scopes
c = webui.chat_model({ todo = { { user = "u", text = "retrack", done = true, done_by = "chilio", file = "x/todo/a-1.json" }, { user = "u", text = "bridge", done = false, done_by = "x" }, { text = 5 } },
  links = { { user = "u", title = "", url = "https://x.test", file = "x/links/l-2.json" }, { user = "u", title = "Chart", url = "C:/a.pdf" }, { title = "no url" } } }, nil, nil, "band")
assert(c.scope == "band" and #c.todo == 2 and c.todo[1].done and c.todo[1].by == "chilio" and c.todo[1].id == "a-1" and not c.todo[2].done and c.todo[2].by == nil, "to-dos: done and by whom")
assert(#c.links == 2 and c.links[1].url == "https://x.test" and c.links[1].title == nil and c.links[1].id == "l-2" and c.links[2].title == "Chart", "links (one without a url left out)")
assert(webui.CHAT_TOPICS.song == "chat" and webui.CHAT_TOPICS.room == "chat_room" and webui.CHAT_TOPICS.band == "chat_band", "a topic per scope")

-- What a page may send
assert(webui.clean_text("  hi\tthere\n ") == "hi there", "control characters become spaces, ends trimmed")
assert(webui.clean_text("") == nil and webui.clean_text("   ") == nil and webui.clean_text(5) == nil and webui.clean_text(("x"):rep(2001)) == nil
  and webui.clean_text("\255\254") == nil, "empty, not text, too long or not UTF-8: nothing")
assert(webui.clean_text("héllo") == "héllo", "UTF-8 kept")
local t, a = webui.parse_action('{"topic":"chat","text":"yo"}')
assert(t == "chat" and a.text == "yo", "a chat action")
for _, bad in ipairs({ "", "nope", '{"topic":"exec","cmd":"x"}', '{"text":"x"}', "[1]", nil }) do assert(webui.parse_action(bad) == nil, "refused: " .. tostring(bad)) end

-- Live sync's tick, with a stand-in extension
reaper.StudioSync_WebUIStart = function(folder, secret, port) started = started + 1; assert(folder:find("lib/webui$") and secret == "sek" and port == 47281); return 1 end
reaper.StudioSync_WebUIPublish = function(topic, json) pub[#pub + 1] = { topic, json } end
reaper.StudioSync_WebUIPoll = function() return table.remove(actions, 1) or "" end
reaper.StudioSync_WebUIStatus = function() return '{"listening":true,"port":47281,"token":"abc123"}' end
package.loaded.groups = { sonobus_secret = function() return "sek" end }
package.loaded.direct = { port = function() return 47281 end }
package.loaded.live = { armed = function(tr) return tr == 1 end }
package.loaded.presence = { peers = function() return { { user = "chilio" } } end }
package.loaded.sync = { authority = function() return function() end, { driver = "James", tracks = {}, regions = {}, times = {} } end }
local posted, from_msg = {}, {}
-- (video calls' own checks are tests/test_0_60_rt_webcall.lua: here a stand-in whose topic never changes, published once per front tab)
local rtc_pages = {}
package.loaded.webcall = { dirty = function() return false end, me = function() return {} end, model = function() return { boot = "1" } end,
  page = function(_, _, a) rtc_pages[#rtc_pages + 1] = a end, link = function() end, view_tick = function() end } -- (view_tick: a share's arrange view, rt-share)
package.loaded.webhome = { tick = function() end, action = function() end } -- (Home and profiles: tests/test_0_60_rt_home.lua)
package.loaded.webdraw = { tick = function() end, action = function() end, from_msg = function() end } -- (the drawing layer: tests/test_0_60_rt_draw.lua)
package.loaded.invite = { web_tick = function() end, action = function() end, chat_model = function() end } -- (Ask to join: tests/test_0_60_rt_invite.lua)
local chat_reads = {}
package.loaded.page_chat = { -- (its web_action's own checks: tests/test_0_60_rt_webpages.lua)
  web_action = function(_, b, a) posted[#posted + 1] = { b.song, a.text, a.scope } end,
  read = function(_, _, sc) chat_reads[#chat_reads + 1] = sc; return { msgs = { { user = "chilio", text = "hey", time = "2026-11-19T10:00:00Z" } } } end,
  where_label = function() return nil end,
  from_msg = function(_, d) from_msg[#from_msg + 1] = d end,
  web_tick = function() end, -- (DMs, channels and files: tests/test_0_60_rt_chat2.lua)
}
assert(webui.available(), "the extension has it")
local cfg, b, handlers = { root = "R", user = "James" }, { song = "S", room = "main" }, {}
actions = { '{"topic":"chat","text":" from my phone ","scope":"room"}', '{"topic":"rtc","t":"here"}', '{"topic":"rm","path":"x"}' }
webui.tick("P1", cfg, b, handlers)
assert(started == 1, "started")
assert(#posted == 1 and posted[1][1] == "S" and posted[1][2] == " from my phone " and posted[1][3] == "room", "a chat action handed to the Chat page's store; junk dropped")
assert(table.concat(chat_reads, ",") == "song", "only This project's chat built while no page shows another scope")
assert(#pub == 3 and pub[1][1] == "presence" and pub[2][1] == "chat" and pub[3][1] == "rtc", "presence, chat and the calls' topic published")
assert(#rtc_pages == 1 and rtc_pages[1].t == "here" and type(handlers.rtc) == "function", "a call message goes to lib/webcall.lua, and the link's to it too")
local pj = band.json_decode(pub[1][2])
assert(pj.driver == "James" and pj.people[1].user == "James" and pj.people[1].recording and pj.people[1].armed[1] == "Vox" and pj.people[2].user == "chilio", "presence: " .. pub[1][2])
assert(band.json_decode(pub[2][2]).msgs[1].text == "hey", "chat: " .. pub[2][2])
assert(type(handlers.chat) == "function", "the link's chat messages go to the Chat page's store")
handlers.chat({ x = 1 })
assert(from_msg[1].x == 1, "handed over")
clock = clock + 5
webui.tick("P1", cfg, b, handlers)
assert(#pub == 3 and started == 1, "nothing changed: nothing published, not started again within 10 s")
front = "P2"
clock = clock + 5
webui.tick("P1", cfg, b, handlers)
assert(#pub == 3, "a tab behind publishes nothing")
front = "P1"
webui.tick("P1", cfg, b, handlers)
assert(#pub == 6 and started == 2, "back in front: everything again (another tab's was showing)")
local url, why = webui.phone_link(cfg)
assert(url == nil and why:find("direct link"), "no phone link while the link isn't listening: " .. tostring(why))
reaper.StudioSync_DirectStatus = function() return '{"listening":true}' end
package.loaded.services = { my_tailscale_name = function() return "james-main.tail99.ts.net" end }
assert(webui.phone_link(cfg) == "http://james-main.tail99.ts.net:47281/?t=abc123", "the phone link")

-- Nobody looking (no open stream, no request for LOOK_GRACE s): nothing built. A page arriving gets everything on its first tick.
local st = { clients = 0, served = 7 }
reaper.StudioSync_WebUIStatus = function() return ('{"listening":true,"port":47281,"token":"abc123","clients":%d,"served":%d,"refused":0}'):format(st.clients, st.served) end
local reads = 0
package.loaded.sync.authority = function() reads = reads + 1; return function() end, { driver = "James", tracks = {}, regions = {}, times = {} } end
webui.tick("P1", cfg, b, handlers) -- (served moved from the old stand-in's none: a request, so still looking)
local r0 = reads
clock = clock + 31
for _ = 1, 5 do clock = clock + 2; webui.tick("P1", cfg, b, handlers) end
assert(reads == r0, "nobody looking: no presence built (claims not read)")
local n = #pub
package.loaded.page_chat.read = function() return { msgs = { { user = "chilio", text = "while you were away" } } } end
st.clients = 1
webui.tick("P1", cfg, b, handlers)
assert(reads == r0 + 1 and #pub == n + 1 and pub[#pub][1] == "chat" and pub[#pub][2]:find("while you were away"), "a page opens: built at once, the new chat published")
st.clients, st.served = 0, 8 -- (a polling page: no open connection, the served count moves)
clock = clock + 31
webui.tick("P1", cfg, b, handlers)
assert(reads == r0 + 2, "a page polling /api/state counts as looking")
clock = clock + 31
webui.tick("P1", cfg, b, handlers)
assert(reads == r0 + 2, "and stops counting LOOK_GRACE s after its last request")

-- Another chat scope: built (its own topic) only while a page says it shows it
st.clients = 1
package.loaded.page_chat.read = function(_, _, sc) chat_reads[#chat_reads + 1] = sc; return { msgs = { { user = "chilio", text = "in " .. sc } } } end
chat_reads, n = {}, #pub
actions = { '{"topic":"chat","want":"band","scope":"band"}' }
webui.tick("P1", cfg, b, handlers)
table.sort(chat_reads)
assert(table.concat(chat_reads, ",") == "band,song", "Studio asked for: read with This project: " .. table.concat(chat_reads, ","))
local band_pub
for i = n + 1, #pub do if pub[i][1] == "chat_band" then band_pub = band.json_decode(pub[i][2]) end end
assert(band_pub and band_pub.scope == "band" and band_pub.msgs[1].text == "in band", "published as chat_band")
chat_reads = {}
clock = clock + webui.LOOK_GRACE + 1
webui.tick("P1", cfg, b, handlers)
assert(table.concat(chat_reads, ",") == "song", "no longer asked for: not read")
print("ok")
