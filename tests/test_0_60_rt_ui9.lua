-- rt-ui9 (docs/rt/ui-web-plan.md Phase 9: Chat and pop-outs, web side): the room's notes and likes for the web chat's All (lib/page_chat.lua's
-- "chat_notes" topic, asked for by a page and published only while asked), live audio's Mute and Deafen from the top bar (lib/webcall.lua's
-- local "la" message, this computer only, and the model's la), and a link check of the page files (chat.js: read once per newest message,
-- All with notes and likes; call.js: the top bar, the channel, ?pop=call, Pop out once REAPER's window opens pop-outs). Lua 5.4, from the
-- repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function() end

-- ---- the notes model (pure) -------------------------------------------------------------------------------------------------------------------
local chat = require("page_chat")
local m = chat.notes_model("Song", nil, {
  { id = "n1", type = "note", user = "chilio", text = "Louder vox", track = "Vox", pos = 83.4, time = "2026-11-27T10:00:00Z", take = "t", path_ = "R/x.json" },
  { id = "l1", type = "like", user = "Bo", text = "ignored", track = "Bass", time = "2026-11-27T09:00:00Z" },
  { id = "e1", type = "edit", user = "Bo", time = "2026-11-27T08:00:00Z" },
  "junk",
  { type = "note", user = 7, text = ("x"):rep(3000), track = 5, pos = "nope" },
})
assert(m.song == "Song" and m.room == "main" and #m.notes == 3, "notes and likes only, the room main when none is named")
local n1, l1, odd = m.notes[1], m.notes[2], m.notes[3]
assert(n1.id == "n1" and n1.type == "note" and n1.text == "Louder vox" and n1.track == "Vox" and n1.pos == 83.4 and n1.user == "chilio" and n1.time == "2026-11-27T10:00:00Z", "a note: its words, track, place and time")
assert(n1.take == nil and n1.path_ == nil, "nothing the page doesn't need (no take ids, no file paths)")
assert(l1.type == "like" and l1.text == nil and l1.track == "Bass", "a like: no words of its own")
assert(odd.user == "7" and #odd.text == chat.NOTE_TEXT_MAX and odd.track == nil and odd.pos == nil and odd.id == nil, "odd fields: made safe, words capped")
local many = {}
for i = 1, chat.NOTES_MAX + 20 do many[i] = { id = "n" .. i, type = "note", user = "u", text = "t" } end
assert(#chat.notes_model("S", "r", many).notes == chat.NOTES_MAX, "at most NOTES_MAX")
assert(#chat.notes_model("S", "r", nil).notes == 0, "nothing read yet: none")

-- ---- asked for by a page; published while asked, only while a page looks ---------------------------------------------------------------------
local warmed, notes_of = 0, { { id = "n1", type = "note", user = "chilio", text = "Louder vox", time = "2026-11-27T10:00:00Z" } }
package.loaded.recall = { warm = function(_, song, room, secs, idle) warmed = warmed + 1; assert(song == "Song" and room == "main" and secs <= 0.01 and idle == false) return true end,
  notes = function(_, song, room) assert(song == "Song" and room == "main") return notes_of end }
package.loaded.chatfiles = { tick = function() end }
chat.index_model = function() return { convs = {} } end
local cfg, b = { user = "James", root = "R" }, { song = "Song", room = "main" }
local pubs = {}
local function publish(topic, v) pubs[#pubs + 1] = { topic, v } end
local function topics() local t = {} for _, p in ipairs(pubs) do t[p[1]] = (t[p[1]] or 0) + 1 end return t end
chat.web_tick(cfg, b, publish, clock, true)
assert(topics().chat_index == 1 and not topics().chat_notes and warmed == 0, "nobody asked: the index only, nothing read for notes")
pubs = {}
assert(chat.web_action(cfg, b, { notes = true, scope = "song" }) == nil, "a page's ask for the notes says nothing back")
chat.web_tick(cfg, b, publish, clock, true)
assert(topics().chat_notes == 1 and warmed == 1, "asked: the room's notes read a little and published")
local got
for _, p in ipairs(pubs) do if p[1] == "chat_notes" then got = p[2] end end
assert(got.song == "Song" and got.room == "main" and got.notes[1].text == "Louder vox", "the model's")
pubs = {}
clock = clock + 1
chat.web_tick(cfg, b, publish, clock, false)
assert(#pubs == 0, "nobody looking: nothing published")
clock = clock + 31
chat.web_tick(cfg, b, publish, clock, true)
assert(topics().chat_index == 1 and not topics().chat_notes, "30 s without the ask again: no more notes")
pubs = {}
chat.web_action(cfg, b, { notes = true, scope = "song" })
chat.web_tick(cfg, nil, publish, clock, true)
assert(not topics().chat_notes, "no project open: no notes")

-- ---- live audio's Mute and Deafen from the top bar (lib/webcall.lua) ---------------------------------------------------------------------------
local set_calls, me_state, available = {}, { mute = false, deaf = true, ptt = false }, true
package.loaded.liveaudio = { available = function() return available end, set = function(k, on) set_calls[#set_calls + 1] = { k, on } end,
  me = function() return me_state end, apply = function() end }
package.loaded.services = { is_device_id = function(id) return type(id) == "string" and #id == 63 end, my_device_id = function() return ("A"):rep(63) end }
local sent = {}
package.loaded.direct = { peers = function() return {}, {} end, send_live = function(_, kind, d) sent[#sent + 1] = d; return true end }
local webcall = require("webcall")
webcall.reset()
assert(webcall.page(cfg, b, { t = "la", k = "mute", on = true }, 100) == false and #set_calls == 0, "not from a phone or another device's page")
local here = 1
reaper.StudioSync_WebUIPollHere = function() return here end
webcall.page(cfg, b, { t = "la", k = "mute", on = true }, 100)
assert(#set_calls == 1 and set_calls[1][1] == "mute" and set_calls[1][2] == true and #sent == 0, "from this computer: Mute, and nothing over the link")
webcall.page(cfg, b, { t = "la", k = "deaf", on = false }, 100)
assert(#set_calls == 2 and set_calls[2][1] == "deaf" and set_calls[2][2] == false, "Deafen off")
for _, bad in ipairs({ { t = "la", k = "ptt", on = true }, { t = "la", k = "mute", on = "yes" }, { t = "la", k = "mute" }, { t = "la", k = { 1 }, on = true } }) do
  webcall.page(cfg, b, bad, 100)
end
assert(#set_calls == 2, "only mute or deaf, only on or off")
available = false
webcall.page(cfg, b, { t = "la", k = "mute", on = false }, 100)
assert(#set_calls == 2, "no live audio here: nothing")
local me = webcall.me(cfg)
local mm = webcall.model(me, 100, true)
assert(mm.la and mm.la.deaf == true and mm.la.mute == nil and mm.la.ptt == nil, "live audio running: the model says Mute and Deafen (flags true or absent)")
assert(webcall.model(me, 100, false).la == nil and webcall.model(me, 100).la == nil, "not running: no la")
package.loaded.liveaudio.me = function() error("no extension") end
assert(webcall.model(me, 100, true).la == nil, "live audio's state unreadable: no la, the model still goes")

-- ---- the page files -------------------------------------------------------------------------------------------------------------------------
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local cj, ca, ch, css = read("lib/webui/call.js"), read("lib/webui/chat.js"), read("lib/webui/chat.css"), read("lib/webui/call.css")
assert(ca:find("lastSeen[sc] = newest", 1, true), "chat.js: read said once per newest message (it was sent on every draw)")
assert(ca:find("{ notes: true, scope }", 1, true) and ca:find("ssTabs.topics.chat_notes", 1, true) and ca:find("const NOTED = ['room', 'song']", 1, true), "chat.js: All asks for the room's notes and likes, for This room and This project")
assert(ca:find("noteWords(e)", 1, true) and not ca:find("innerHTML", 1, true), "chat.js: notes as text")
assert(cj:find("new BroadcastChannel('studiosync-call-' + dev", 1, true), "call.js: one channel per computer (named for its device id)")
assert(cj:find("function holder()", 1, true) and cj:find("p.pop === 'call'", 1, true), "call.js: the page holding a call, else the call's window, else the main window")
assert(cj:find("?pop=call", 1, true) and cj:find("ss-pop-call", 1, true) and css:find("html.ss-pop-call", 1, true), "call.js and call.css: the call's own window")
assert(cj:find("window.ssEnv.winPop", 1, true) and cj:find("if (canPop()) bar2.append(button('Pop out'", 1, true), "call.js: Pop out in REAPER once its window opens pop-outs (rt-ui8)")
assert(cj:find("t: 'la', k:", 1, true) and cj:find("getElementById('sspill')", 1, true) and css:find(".sscall", 1, true), "call.js: the top bar's live audio buttons, after the status pill")
assert(cj:find("if (qs.get('pop') === 'share')", 1, true), "call.js: rt-share's ?pop=share kept")
assert(ch ~= "", "chat.css there")
print("ok")
