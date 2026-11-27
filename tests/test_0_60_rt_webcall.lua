-- Video calls and screen share's signalling relay (lib/webcall.lua): what a page may send, what a bandmate's computer may send (checked
-- again: for this computer, from a computer in the room, sizes), routing to the right peer only, "here" to everyone and not too often,
-- what the pages see (who's open, the newest messages, ageing out), and a link check of the call page's files (lib/webui/call.js,
-- call.css: there, linked from index.html, wired to app.js's snapshot, the message kinds lib/webcall.lua takes). (James, rt)
package.path = "lib/?.lua;" .. package.path
reaper = setmetatable({ time_precise = function() return 1000 end, GetOS = function() return "Win64" end },
  { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local function dev(c) return (c:rep(7) .. "-"):rep(7) .. c:rep(7) end
local ME, CHI, AND, OUT = dev("A"), dev("B"), dev("C"), dev("D")
package.loaded.services = { is_device_id = function(id) return type(id) == "string" and id:match("^" .. ("[%u%d]"):rep(7) .. ("%-" .. ("[%u%d]"):rep(7)):rep(7) .. "$") ~= nil end,
  my_device_id = function() return ME end }
local sent, peers, ok_send = {}, { "andie-mbp.tail9.ts.net:47281", "chilio-pc.tail9.ts.net:47281" }, true
local dev_of = { ["chilio-pc.tail9.ts.net:47281"] = CHI, ["andie-mbp.tail9.ts.net:47281"] = AND }
package.loaded.direct = {
  peers = function() return peers, dev_of end,
  send_live = function(_, kind, d, song, room, id, to) sent[#sent + 1] = { kind = kind, d = d, song = song, room = room, id = id, to = to }; return ok_send end,
}
local band = require("band")
local webcall = require("webcall")
local me = { user = "James", dev = ME }
local SDP = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\n"
local CALL = "0123456789abcdef0123456789abcdef"

-- What a page may send
local m = webcall.from_page({ t = "here", junk = 1 }, me)
assert(m.t == "here" and m.user == "James" and m.dev == ME and m.junk == nil, "here: as this computer, nothing else carried")
m = webcall.from_page({ topic = "rtc", t = "offer", to = CHI, call = CALL, kind = "screen", audio = true, sdp = SDP, extra = "x" }, me)
assert(m.t == "offer" and m.to == CHI and m.call == CALL and m.kind == "screen" and m.audio == true and m.sdp == SDP and m.user == "James" and m.dev == ME
  and m.extra == nil and m.topic == nil, "an offer: only its own fields")
assert(webcall.from_page({ t = "offer", to = CHI, call = CALL, kind = "call", audio = "yes", sdp = "v=0\n" }, me).audio == nil, "audio only when true")
assert(webcall.from_page({ t = "answer", to = CHI, call = CALL, sdp = SDP }, me).sdp == SDP, "an answer")
local bye = webcall.from_page({ t = "bye", to = CHI, call = CALL, sdp = SDP }, me)
assert(bye.t == "bye" and bye.sdp == nil, "bye carries no SDP")
assert(webcall.from_page({ t = "busy", to = CHI, call = CALL }, me).t == "busy", "busy (declined)")
local bad = {
  { "unknown kind", { t = "exec", to = CHI, call = CALL } },
  { "no kind", { to = CHI, call = CALL } },
  { "error is the relay's own", { t = "error", to = CHI, call = CALL } },
  { "to nobody", { t = "bye", call = CALL } },
  { "to a name", { t = "bye", to = "chilio", call = CALL } },
  { "to this computer", { t = "bye", to = ME, call = CALL } },
  { "no call id", { t = "bye", to = CHI } },
  { "short call id", { t = "bye", to = CHI, call = "abc" } },
  { "long call id", { t = "bye", to = CHI, call = ("a"):rep(65) } },
  { "call id with odd characters", { t = "bye", to = CHI, call = "0123456789/../x" } },
  { "offer of neither kind", { t = "offer", to = CHI, call = CALL, kind = "control", sdp = SDP } },
  { "offer without SDP", { t = "offer", to = CHI, call = CALL, kind = "call" } },
  { "answer without SDP", { t = "answer", to = CHI, call = CALL } },
  { "SDP that isn't", { t = "answer", to = CHI, call = CALL, sdp = "<script>" } },
  { "SDP too big", { t = "answer", to = CHI, call = CALL, sdp = SDP .. ("a=x\r\n"):rep(3000) } },
  { "not a table", "offer" },
}
for _, c in ipairs(bad) do assert(webcall.from_page(c[2], me) == nil, "refused: " .. c[1]) end
assert(webcall.from_page({ t = "here" }, { user = "James" }) == nil and webcall.from_page({ t = "here" }, { user = "", dev = ME }) == nil
  and webcall.from_page({ t = "here" }, { user = "a\nb", dev = ME }) == nil, "no message without a good name and device here")
assert(#SDP + #("a=x\r\n"):rep(2300) <= webcall.SDP_MAX and webcall.from_page({ t = "answer", to = CHI, call = CALL, sdp = SDP .. ("a=x\r\n"):rep(2300) }, me),
  "an SDP up to SDP_MAX goes")

-- What a bandmate's computer may send
local known = webcall.known(peers, dev_of)
assert(known[CHI] == "chilio-pc.tail9.ts.net:47281" and known[AND] == "andie-mbp.tail9.ts.net:47281" and known[ME] == nil, "device -> peer")
local function from(who, t) local d = { user = who == CHI and "chilio" or "x", dev = who }; for k, v in pairs(t) do d[k] = v end; return d end
assert(webcall.from_link(from(CHI, { t = "offer", to = ME, call = CALL, kind = "call", sdp = SDP }), me, known).user == "chilio", "an offer to this computer")
assert(webcall.from_link(from(CHI, { t = "here" }), me, known).t == "here", "here, for everyone")
assert(webcall.from_link(from(CHI, { t = "offer", to = AND, call = CALL, kind = "call", sdp = SDP }), me, known) == nil, "for another computer: not shown here")
assert(webcall.from_link(from(OUT, { t = "offer", to = ME, call = CALL, kind = "call", sdp = SDP }), me, known) == nil, "from a computer not in the room: nothing")
assert(webcall.from_link(from(ME, { t = "here" }), me, known) == nil, "from this computer's own id: nothing")
assert(webcall.from_link(from(CHI, { t = "offer", to = ME, call = CALL, kind = "control", sdp = SDP }), me, known) == nil, "checked as a page's would be")
assert(webcall.from_link({ t = "here", user = ("x"):rep(65), dev = CHI }, me, known) == nil, "a name too long")
assert(webcall.from_link({ t = "here", user = "chilio", dev = CHI }, me, nil) == nil and webcall.from_link("x", me, known) == nil, "no room, or not a table")

-- A page's message, sent on
local cfg, b = { user = "James", root = "R" }, { song = "Song", room = "main" }
webcall.reset()
assert(webcall.page(cfg, b, { t = "here" }, 100) == true and #sent == 1 and sent[1].kind == "rtc" and sent[1].to == nil and sent[1].d.t == "here"
  and sent[1].song == "Song" and sent[1].room == "main", "here: to everyone in the room")
assert(webcall.page(cfg, b, { t = "here" }, 102) == false and #sent == 1, "not again within HERE_EVERY (several pages here each say it)")
assert(webcall.page(cfg, b, { t = "here" }, 105) == true and #sent == 2, "and again after")
assert(webcall.page(cfg, b, { t = "offer", to = CHI, call = CALL, kind = "call", sdp = SDP }, 106) == true, "an offer sent")
assert(#sent[3].to == 1 and sent[3].to[1] == "chilio-pc.tail9.ts.net:47281" and sent[3].d.sdp == SDP, "to that one computer only")
local mod = webcall.model(webcall.me(cfg), 106)
assert(#mod.msgs == 1 and mod.msgs[1].out and mod.msgs[1].t == "offer" and mod.msgs[1].call == CALL and mod.msgs[1].sdp == nil,
  "the other pages here see it went (no SDP)")
assert(webcall.page(cfg, b, { t = "offer", to = OUT, call = CALL, kind = "call", sdp = SDP }, 107) == false and #sent == 3, "a computer not in the room: not sent")
mod = webcall.model(webcall.me(cfg), 107)
assert(mod.msgs[2].t == "error" and mod.msgs[2].call == CALL and mod.msgs[2].why:find("isn't reachable"), "and the page is told why")
ok_send = false
assert(webcall.page(cfg, b, { t = "bye", to = AND, call = CALL }, 108) == false, "the link didn't take it")
assert(webcall.model(webcall.me(cfg), 108).msgs[3].why:find("didn't take"), "told")
-- call audio: unticked by itself while live audio runs here, ticked otherwise; a hand's choice stays (Fewer things to press, James)
assert(webcall.model(webcall.me(cfg), 108, true).live == true and webcall.model(webcall.me(cfg), 108).live == nil, "live audio here: said")
ok_send = true
assert(webcall.page(cfg, b, { t = "offer", to = CHI, call = CALL, kind = "call" }, 109) == false and #sent == 4, "a bad message: nothing sent")

-- A bandmate's message, for the pages
webcall.reset()
assert(webcall.dirty(), "a fresh queue is shown once")
webcall.model(me, 200)
assert(not webcall.dirty(), "then not until something changes")
assert(webcall.link(cfg, b, from(CHI, { t = "here" }), 200) == true and webcall.dirty(), "chilio's page is open: shown")
mod = webcall.model(me, 200)
assert(#mod.open == 1 and mod.open[1].user == "chilio" and mod.open[1].dev == CHI and mod.open[1].host == "chilio-pc" and #mod.msgs == 0, "who's open, with the computer's name")
assert(webcall.link(cfg, b, from(CHI, { t = "here" }), 210) == true and not webcall.dirty(), "another here changes nothing shown")
assert(webcall.link(cfg, b, { t = "here", user = "Andie", dev = AND }, 215) == true, "Andie's too")
mod = webcall.model(me, 220)
assert(#mod.open == 2 and mod.open[1].user == "Andie" and mod.open[2].user == "chilio", "by name")
assert(#webcall.model(me, 210 + webcall.OPEN_FOR).open == 1, "chilio's page ages out OPEN_FOR s after its last word")
assert(webcall.link(cfg, b, from(CHI, { t = "offer", to = ME, call = CALL, kind = "screen", sdp = SDP }), 240) == true, "an offer for me")
mod = webcall.model(me, 240)
assert(#mod.msgs == 1 and mod.msgs[1].t == "offer" and mod.msgs[1].sdp == SDP and mod.msgs[1].user == "chilio" and mod.msgs[1].dev == CHI and mod.msgs[1].seq == 1
  and mod.boot == webcall.boot and mod.me.dev == ME, "shown with its number")
assert(#mod.open == 1 and mod.open[1].user == "chilio", "and chilio counts as open again (Andie aged out)")
assert(webcall.link(cfg, b, from(OUT, { t = "offer", to = ME, call = CALL, kind = "call", sdp = SDP }), 241) == false, "a stranger's: dropped")
for i = 1, webcall.KEEP + 4 do webcall.link(cfg, b, from(CHI, { t = "bye", to = ME, call = CALL }), 241) end
mod = webcall.model(me, 241)
assert(#mod.msgs == webcall.KEEP and mod.msgs[#mod.msgs].seq == webcall.KEEP + 5 and mod.msgs[1].seq == 6, "the newest KEEP, oldest first, numbered in order")
assert(#webcall.model(me, 241 + webcall.KEEP_FOR).msgs == 0, "gone KEEP_FOR s later")
assert(#band.json_encode(mod) < 1024 * 1024, "the topic stays under the server's 1 MB")

-- The call page's files
local function read(p) local f = assert(io.open(p, "rb"), p); local s = f:read("a"); f:close(); return s end
local html, app, js, css = read("lib/webui/index.html"), read("lib/webui/app.js"), read("lib/webui/call.js"), read("lib/webui/call.css")
assert(html:find('<link rel="stylesheet" href="call.css">', 1, true) and html:find('<script src="call.js" defer></script>', 1, true), "linked from the page")
assert(html:find('<div id="sharebar" role="status" hidden></div>', 1, true) and html:find('<section id="call" aria-labelledby="call-h" hidden></section>', 1, true),
  "the sharing bar and the call section, hidden until there's something to show")
assert(js:find("getElementById('call')", 1, true) and js:find("getElementById('sharebar')", 1, true) and js:find("h.id = 'call-h'", 1, true), "call.js fills them")
assert(js:find("audioBox.checked = !model.live", 1, true) and js:find("audioSet = true", 1, true), "call audio follows live audio until ticked by hand")
assert(app:find("dispatchEvent(new CustomEvent('ss-state'", 1, true) and js:find("addEventListener('ss-state'", 1, true) and js:find("topics.rtc", 1, true),
  "call.js reads app.js's snapshot, the rtc topic")
for _, t in ipairs({ "here", "offer", "answer", "bye", "busy" }) do assert(js:find("t: '" .. t .. "'", 1, true), "call.js sends " .. t) end
assert(js:find("topic: 'rtc'", 1, true) and js:find("'X-StudioSync': '1'", 1, true), "as an rtc action, with the server's header")
assert(js:find("iceServers: model && Array.isArray(model.ice) ? model.ice : []", 1, true), "no STUN or TURN but the model's (only with the connection without Tailscale on, rt-p13): nothing outside over Tailscale")
assert(js:find("getDisplayMedia", 1, true) and js:find("audio: sys ?", 1, true), "the screen's own audio only when System audio is picked (rt-share)")
assert(not js:find("innerHTML", 1, true) and not js:find("insertAdjacentHTML", 1, true), "bandmates' names go in as text")
assert(js:find("You’re sharing your screen", 1, true) and js:find("'Stop', stopSharing", 1, true), "the sharing bar says so, with Stop")
-- (rt-share: keys are taken only by a watched share's tile, with the focus, while you control the sharer's window; otherwise app.js passes
-- them to REAPER in the docked view)
local _, nkeys = js:gsub("addEventListener%('keydown'", "")
assert(nkeys == 1 and js:find("f.addEventListener('keydown', key(true))", 1, true) and js:find("if (!youCtl(s) || ev.isComposing) return;", 1, true),
  "no keys taken but while in control")
assert(css:find("#sharebar", 1, true) and css:find(".board", 1, true), "the bar and the pointer's layer styled")
print("ok")
