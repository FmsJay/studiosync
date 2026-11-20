-- Ask to join and invite links (lib/invite.lua, lib/urlhandler.lua; rt-invite): the link parser against malformed, hostile and oversized
-- input; asking a bandmate over a stand-in link (a DM with `join`, the alert, rate limits), their Join and Decline (once, not after it runs out,
-- never your own); links clicked (a member's opens the project, someone new's asks first and exchanges its code); codes on the inviter's
-- computer (single use, run out, revoked, outside the studio's network, too many refused); the joiner's answer; the launcher's file; and the
-- URL handler put in and taken away per system on a stand-in file layer (nothing touches the registry or a real home folder). (James, rt)
package.path = "lib/?.lua;" .. package.path
local clock, ext, logged = 1000, {}, {}
local msgs_out, alerts_out, opened, said, dmsgs, starts = {}, {}, {}, {}, {}, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  RecursiveCreateDirectory = function() return 1 end,
  file_exists = function(p) return FS[p] ~= nil end,
  genGuid = function() return string.format("{%08X-1234-5678-9ABC-%012X}", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff)) end,
  StudioSync_DirectStart = function(ch, secret, inbox, port) starts[#starts + 1] = { ch = ch, secret = secret, port = port }; return 1 end,
  StudioSync_DirectMsg = function(ch, kind, data, to) dmsgs[#dmsgs + 1] = { ch = ch, kind = kind, data = data, to = to }; return 1 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })

FS = {}
local real_time, toff = os.time, 0 -- (asks are limited on the wall clock: moved on by hand)
os.time = function(t) if t then return real_time(t) end return real_time() + toff end
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end
band.msg = function(s) said[#said + 1] = s end
local function children(dir, want_dirs)
  local out, seen, pre = {}, {}, dir .. "/"
  for path in pairs(FS) do
    if path:sub(1, #pre) == pre then
      local first, more = path:sub(#pre + 1):match("^([^/]+)(/?)")
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
band.subdirs = function(dir) return children(dir, true) end
band.home = function() return "H" end
os.remove = function(p) FS[p] = nil; return true end
local ROOT, SID = "S", "studiosync-abc123"
band.info = function() return { id = SID, name = "Chilio" } end
band.bands = function() return { { root = ROOT, id = SID, name = "Chilio" } } end
band.songs = function() return { "Sunset Drive", "Blue" } end
band.settings = function() return { root = ROOT, user = ext["BandSync/user"] } end
band.use_band = function(r) ext["BandSync/sync_root"] = r end
local SEC = band.SECTION

package.loaded.chatfiles = { reachable = function() return { "bob.tail9.ts.net:47281" } end, check = function(x) return x end, status = function() end }
package.loaded.alerts = { send = function(cfg, kind, title, text) alerts_out[#alerts_out + 1] = { kind = kind, title = title, text = text }; return true end }
package.loaded.api = { event = function() end }
package.loaded.webhome = { open = function(cfg, o) opened[#opened + 1] = o; return "opening '" .. o.song .. "'" end }
local manage, tail = true, { suffix = "tail9.ts.net" }
package.loaded.groups = { may_manage = function() return manage end, tailnet = function() return tail end, trusted = function() return {} end }
local MYDEV = "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
local joined = {}
package.loaded.services = {
  is_device_id = function(id) return type(id) == "string" and id:match("^" .. ("[%u%d]"):rep(7) .. ("%-" .. ("[%u%d]"):rep(7)):rep(7) .. "$") ~= nil end,
  my_device_id = function() return MYDEV end,
  my_tailscale_name = function() return "carol.tail9.ts.net." end,
  parse_join = function(text) local inv = require("joins").parse(text); return inv and { id = inv.device, band = inv.studio, name = inv.name, invite = inv } end,
  join_band = function(cfg, code) joined[#joined + 1] = code; return "S2" end,
}
local direct = require("direct")
direct.send_live = function(cfg, kind, d, song, room, id, to) msgs_out[#msgs_out + 1] = { kind = kind, d = d, to = to } end
direct.firewall_ok = function() return true end
local joins = require("joins")
local requested = {}
joins.request = function(root, tok) requested[#requested + 1] = tok; return true end
local chat = require("page_chat")
local invite = require("invite")
local function users(...) return ... end

-- ---- the link parser --------------------------------------------------------------------------------------------------------------------
local t = invite.parse_link("studiosync://join?s=" .. SID .. "&p=Sunset%20Drive&r=Bridge%20take")
assert(t and t.kind == "member" and t.studio == SID and t.song == "Sunset Drive" and t.room == "Bridge take", "a member's link")
t = invite.parse_link("  STUDIOSYNC:join/?s=" .. SID .. "&p=Blue  ")
assert(t and t.song == "Blue" and t.room == "main", "studiosync:join/?..., any case, trimmed, room main by default")
t = invite.parse_link("http://127.0.0.1:47281/join.html?s=" .. SID .. "&p=Blue#x")
assert(t and t.song == "Blue", "the web UI's own join.html, a fragment ignored")
assert(invite.parse_link(invite.member_link(SID, "Caf\195\169 (v2)!", "Room 1")).song == "Caf\195\169 (v2)!", "built and read back, UTF-8 and brackets")
-- (what join.html's encodeURIComponent makes of a name with brackets, an apostrophe and an accent)
assert(invite.parse_link("studiosync://join?s=" .. SID .. "&p=It's%20(live)%20%C3%A9").song == "It's (live) \195\169", "a browser's encoding")
local code = string.rep("a1", 12)
t = invite.parse_link(invite.code_link(SID, "Chilio band", "alice.tail9.ts.net", code))
assert(t and t.kind == "code" and t.code == code and t.host == "alice.tail9.ts.net" and t.name == "Chilio band", "someone new's link")
local bad = {
  "", "studiosync://join", "studiosync://join?", "https://evil.example/join.html?s=" .. SID .. "&p=Blue", "javascript:alert(1)",
  "studiosync://other?s=" .. SID .. "&p=Blue", "studiosync://join?s=default&p=Blue", "studiosync://join?s=" .. SID,
  "studiosync://join?s=" .. SID .. "&p=Blue&p=Red", "studiosync://join?s=" .. SID .. "&p=Blue&x=1", "studiosync://join?s=" .. SID .. "&p=Blue&token=abc",
  "studiosync://join?s=" .. SID .. "&p=%zz", "studiosync://join?s=" .. SID .. "&p=Blue%", "studiosync://join?s=" .. SID .. "&p=Blue%4",
  "studiosync://join?s=" .. SID .. "&p=Bl%00ue", "studiosync://join?s=" .. SID .. "&p=Bl%0Aue", "studiosync://join?s=" .. SID .. "&p=Blue Drive",
  "studiosync://join?s=" .. SID .. "&p=Bl\195\169", "studiosync://join?s=" .. SID .. "&p=..", "studiosync://join?s=" .. SID .. "&p=%2E%2E%2Fetc",
  "studiosync://join?s=" .. SID .. "&p=a%2Fb", "studiosync://join?s=" .. SID .. "&p=a%5Cb", "studiosync://join?s=" .. SID .. "&p=CON%3A",
  "studiosync://join?s=" .. SID .. "&p=Blue&r=..%2F..", "studiosync://join?s=" .. SID .. "&p=Blue&n=x", "studiosync://join?s=" .. SID .. "&p=%FF%FE",
  "studiosync://join?s=" .. SID .. "&c=" .. code, "studiosync://join?s=" .. SID .. "&h=alice.tail9.ts.net&c=abc",
  "studiosync://join?s=" .. SID .. "&h=alice..ts.net&c=" .. code, "studiosync://join?s=" .. SID .. "&h=alice&c=" .. code,
  "studiosync://join?s=" .. SID .. "&h=alice.tail9.ts.net&c=" .. code .. "&p=Blue", "studiosync://join?s=" .. SID .. "&h=a%20b.ts.net&c=" .. code,
  "studiosync://join?s=" .. SID .. "&h=alice.tail9.ts.net&c=" .. code:gsub("a", "g"),
  "studiosync://join?s=" .. SID .. "&p=" .. string.rep("x", 700), "studiosync://join?s=" .. SID .. "&p=" .. string.rep("x", 250),
  "studiosync://join?s=" .. string.rep("studiosync-", 10) .. "&p=Blue", "studiosync://join?=Blue", "studiosync://join?ss=x",
  "studiosync://join?s=" .. SID .. "&p=Blue\r\nX: y",
}
for _, x in ipairs(bad) do assert(invite.parse_link(x) == nil, "refused: " .. x:sub(1, 80)) end
assert(invite.parse_link(nil) == nil and invite.parse_link({}) == nil and invite.parse_link(42) == nil, "not a string: refused")
t = invite.parse_link("studiosync://join?s=" .. SID .. "&n=%3Cscript%3E%24(x)&h=alice.tail9.ts.net&c=" .. code)
assert(t and not t.name:find("[<>%$%(%)]"), "a name keeps only plain characters")
assert(invite.web_link(invite.member_link(SID, "Blue"), 47281) == "http://127.0.0.1:47281/join.html?s=" .. SID .. "&p=Blue", "the fallback page's address")

-- ---- pure checks ------------------------------------------------------------------------------------------------------------------------
assert(invite.join_ok({ song = "Blue" }).room == "main" and not invite.join_ok({ song = "../x" }) and not invite.join_ok({ song = "Blue", room = "a/b" })
  and not invite.join_ok("Blue") and not invite.join_ok({ song = 5 }), "a message's join part")
assert(invite.rate_ok({}, "bob", 0) and not invite.rate_ok({ { to = "bob", at = 100 } }, "bob", 130) and invite.rate_ok({ { to = "bob", at = 100 } }, "bob", 161)
  and invite.rate_ok({ { to = "bob", at = 100 } }, "dan", 130), "one ask a minute to each person")
local full = {}
for i = 1, invite.ASK_MAX do full[i] = { to = "p" .. i, at = 100 + i } end
assert(not invite.rate_ok(full, "dan", 200) and invite.rate_ok(full, "dan", 100 + invite.ASK_WINDOW + 2), "ASK_MAX an hour")
assert(not invite.code_check(nil, MYDEV, 0) and not invite.code_check({ token = "x", ends = 10 }, MYDEV, 10)
  and not invite.code_check({ token = "x", ends = 99, used_by = "OTHER" }, MYDEV, 10), "unknown, run out, used by another")
local ok, why = invite.code_check({ token = "x", ends = 99, used_by = MYDEV }, MYDEV, 10)
assert(ok and why == "again", "the same computer again (its answer was lost)")

-- ---- asking a bandmate, over a stand-in link ---------------------------------------------------------------------------------------------
local A_EXT, B_EXT = {}, {}
local function as(who) ext = who == "alice" and A_EXT or B_EXT; ext[SEC .. "/user"] = who; return { root = ROOT, user = who } end
FS[ROOT .. "/_band/devices/a.json"] = band.json_encode({ user = "alice" })
FS[ROOT .. "/_band/devices/b.json"] = band.json_encode({ user = "bob" })
FS[ROOT .. "/Blue/rooms/Bridge/x.txt"] = "x"
local cfgA = as("alice")
local b = { song = "Blue", room = "main" }
assert(not invite.ask(cfgA, b, "mallory", "Blue", "main"), "only someone in the studio")
assert(not invite.ask(cfgA, b, "alice", "Blue", "main"), "not yourself")
assert(not invite.ask(cfgA, b, "bob", "Nope", "main") and not invite.ask(cfgA, b, "bob", "Blue", "Nowhere"), "a project and room that are here")
local okA, words = invite.ask(cfgA, b, "bob", "Blue", "Bridge")
assert(okA and words:find("^asked bob") and words:find("Bridge"), "asked")
local dm = chat.dm_id({ "alice", "bob" })
local files = band.files(ROOT .. "/_band/dm/" .. dm .. "/msgs", ".json")
assert(#files == 1, "the request is a DM file in the shared folder (the fallback)")
local req = band.read_json(ROOT .. "/_band/dm/" .. dm .. "/msgs/" .. files[1])
assert(req.join.song == "Blue" and req.join.room == "Bridge" and req.user == "alice", "it carries join")
assert(#msgs_out == 1 and msgs_out[1].d.v.join.song == "Blue" and msgs_out[1].to[1] == "bob.tail9.ts.net:47281", "and over the link to bob's computer only")
assert(#alerts_out == 1 and alerts_out[1].kind == "join" and alerts_out[1].text == "alice asks bob to join", "a phone alert, names only")
local again, gap = invite.ask(cfgA, b, "bob", "Blue", "main")
assert(not again and gap:find("moment"), "rate-limited: not twice a minute")
-- bob's computer: the link's copy first (chat.from_msg keeps join), then the file
local cfgB = as("bob")
local live = msgs_out[1].d
assert(chat.from_msg(cfgB, { sc = live.sc, song = live.song, room = live.room, name = live.name .. "x", v = live.v, members = live.members }) ~= nil, "taken from the link")
local list = invite.pending(cfgB, os.time())
assert(#list == 1 and list[1].user == "alice" and list[1].song == "Blue" and list[1].room == "Bridge", "a join request waiting for bob")
assert(invite.count(cfgB) == 1, "the panel's count")
local m = chat.find(cfgB, {}, "dm:" .. dm, "msgs", list[1].id)
local jm = invite.chat_model(m)
assert(jm and jm.song == "Blue" and not jm.mine and not jm.answered and not jm.expired, "chat: Join and Decline shown")
-- alice can't answer her own
ext = A_EXT
assert(invite.answer(cfgA, {}, "dm:" .. dm, list[1].id, true):find("no such"), "the asker can't answer it")
assert(#opened == 0, "nothing opened")
ext = B_EXT
assert(invite.answer(cfgB, {}, "song", list[1].id, true):find("direct message"), "only in its DM")
assert(invite.answer(cfgB, {}, "dm:" .. dm, "../../x", true):find("no such"), "a made-up id")
local r = invite.answer(cfgB, {}, "dm:" .. dm, list[1].id, true)
assert(r:find("opening") and opened[1].song == "Blue" and opened[1].room == "Bridge", "Join opens it the Home page's way")
assert(invite.answer(cfgB, {}, "dm:" .. dm, list[1].id, true):find("already"), "once")
assert(#opened == 1, "opened once")
clock = clock + 10
assert(#invite.pending(cfgB, os.time()) == 0, "answered: not waiting any more")
assert(invite.chat_model(chat.find(cfgB, {}, "dm:" .. dm, "msgs", list[1].id)).answered, "chat: answered")
local replies = 0
for _, f in ipairs(band.files(ROOT .. "/_band/dm/" .. dm .. "/msgs", ".json")) do
  local v = band.read_json(ROOT .. "/_band/dm/" .. dm .. "/msgs/" .. f)
  if v.join_answer then replies = replies + 1; assert(v.join_answer.go == true and v.user == "bob" and v.join_answer.id == list[1].id, "bob's answer") end
end
assert(replies == 1, "alice is told in the DM")
-- a decline, and one that ran out
local f2 = os.date("!%Y%m%d-%H%M%S") .. "-alice-1111"
FS[ROOT .. "/_band/dm/" .. dm .. "/msgs/" .. f2 .. ".json"] = band.json_encode({ text = "asks you to join Sunset Drive", user = "alice", time = os.date("!%Y-%m-%dT%H:%M:%SZ"), join = { song = "Sunset Drive" } })
clock = clock + 10
assert(invite.answer(cfgB, {}, "dm:" .. dm, f2, false):find("declined") and #opened == 1, "Decline opens nothing")
local f3 = os.date("!%Y%m%d-%H%M%S", os.time() - 3600) .. "-alice-2222"
FS[ROOT .. "/_band/dm/" .. dm .. "/msgs/" .. f3 .. ".json"] = band.json_encode({ text = "asks you to join Blue", user = "alice", time = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 3600), join = { song = "Blue" } })
clock = clock + 10
assert(#invite.pending(cfgB, os.time()) == 0, "an hour-old request isn't waiting")
assert(invite.answer(cfgB, {}, "dm:" .. dm, f3, true):find("run out") and #opened == 1, "nor can it be answered")
assert(invite.chat_model(chat.find(cfgB, {}, "dm:" .. dm, "msgs", f3)).expired, "chat: run out")
-- a forged join in someone else's DM file isn't bob's to see
local dm2 = chat.dm_id({ "alice", "eve" })
FS[ROOT .. "/_band/dm/" .. dm2 .. "/members.json"] = band.json_encode({ members = { "alice", "eve" } })
FS[ROOT .. "/_band/dm/" .. dm2 .. "/msgs/" .. os.date("!%Y%m%d-%H%M%S") .. "-eve-3.json"] = band.json_encode({ text = "x", user = "eve", time = os.date("!%Y-%m-%dT%H:%M:%SZ"), join = { song = "Blue" } })
clock = clock + 10
assert(#invite.pending(cfgB, os.time()) == 0, "a DM bob isn't in shows him nothing")
-- the web UI's actions
ext = A_EXT
clock, toff = clock + 120, toff + 120
assert(invite.action(nil, cfgA, b, { ask = { to = "bob", song = "Sunset Drive" } }):find("^asked"), "Ask from a page")
local pub = {}
invite.web_tick(nil, cfgA, b, function(topic, v) pub[topic] = v end, clock + 10)
assert(pub.invite and pub.invite.studio == SID and pub.invite.last.ok and pub.invite.people[1] == "bob", "the page's topic")
assert(invite.action(nil, cfgA, b, { ask = { to = "bob", song = "Sunset Drive" } }):find("moment"), "a page's second ask is limited too")

-- ---- links clicked ----------------------------------------------------------------------------------------------------------------------
ext = B_EXT
clock = clock + 10
local okl = invite.handle_link("studiosync://join?s=" .. SID .. "&p=Sunset%20Drive")
assert(okl and opened[#opened].song == "Sunset Drive" and opened[#opened].room == "main", "a member's link opens the project")
assert(not invite.handle_link("studiosync://join?s=" .. SID .. "&p=Blue"), "a second link a moment later waits")
clock = clock + 5
assert(not invite.handle_link("studiosync://join?s=studiosync-other&p=Blue") and said[#said]:find("isn't in"), "another studio's: said, nothing opened")
clock = clock + 5
assert(not invite.handle_link("studiosync://join?s=" .. SID .. "&c=" .. code .. "&h=alice.tail9.ts.net") and said[#said]:find("already in"), "a code for a studio you're in")
clock = clock + 5
local n_open = #opened
assert(not invite.handle_link("studiosync://evil?s=x") and logged[#logged]:find("refused"), "a bad link: refused in the log")
assert(#opened == n_open, "and nothing opened")
-- someone new: asked first, then the code goes to the inviter's computer
local OTHER = "studiosync-newband"
local asked_q
invite.confirm = function(q) asked_q = q; return false end
clock = clock + 5
assert(not invite.handle_link(invite.code_link(OTHER, "New band", "alice.tail9.ts.net", code)) and asked_q:find("New band") and #dmsgs == 0, "No: nothing sent")
invite.confirm = function() return true end
clock = clock + 5
assert(invite.handle_link(invite.code_link(OTHER, "New band", "alice.tail9.ts.net", code)), "Yes: asked")
local sent = dmsgs[#dmsgs]
assert(sent.ch == joins.CHANNEL and sent.kind == "redeem" and sent.to == "alice.tail9.ts.net:47281", "a redeem on the join channel to the host")
local sd = band.json_decode(sent.data)
assert(sd.code == code and sd.device == MYDEV and sd.reply == "carol.tail9.ts.net", "with the code, this computer, its Tailscale name")
local h = band.code_hash(code)
assert(starts[#starts].ch == "joinlink-" .. h and starts[#starts].secret:find(code, 1, true), "listening for the answer keyed with the code")
assert(not sent.data:find("tskey") and not sent.to:find(code), "the code never in an address")
-- resent every RESEND s, given up after REDEEM_FOR s
local n = #dmsgs
clock = clock + invite.RESEND + 1
invite.tick(os.time())
assert(#dmsgs == n + 1, "asked again")

-- ---- codes: the inviter's computer --------------------------------------------------------------------------------------------------------
ext = A_EXT
local A_DEV = "ZZZZZZZ-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
local tokt = { studio = SID, id = string.rep("ab", 16), role = "member", ends = os.time() + 2 * 86400, host = "alice.tail9.ts.net", device = A_DEV, name = "Chilio",
  sig = string.rep("cd", 64) }
joins.make = function() return joins.encode(tokt), tokt end
FS[ROOT .. "/_band/joins/" .. tokt.id .. ".json"] = band.json_encode({ id = tokt.id })
local link = invite.make_code(ROOT, "member")
local lt = invite.parse_link(link)
assert(lt and lt.kind == "code" and lt.host == "alice.tail9.ts.net" and not link:find(tokt.sig, 1, true) and not link:find(tokt.id, 1, true), "the link holds the code, not the invitation")
local store = band.json_decode(A_EXT[SEC .. "/invite links"])
assert(store[lt.code] and store[lt.code].ends <= os.time() + invite.CODE_LIFE, "kept on this computer, a day at most")
local function redeem(dev, reply, c)
  dmsgs = {}
  return invite.on_redeem({ code = c or lt.code, device = dev, name = "carol", reply = reply or "carol.tail9.ts.net" }, os.time())
end
local nlog = #logged
assert(not redeem(MYDEV, "carol.other.ts.net"), "from outside the studio's Tailscale network: refused")
assert(logged[#logged]:find("refused") and logged[#logged]:find("outside") and not logged[#logged]:find(lt.code, 1, true), "said in the log, never the code")
clock = clock + 11
assert(not redeem(MYDEV, nil, string.rep("0", 24)) and #dmsgs == 0, "an unknown code: nothing sent")
assert(redeem(MYDEV), "the right computer: answered")
local ans = dmsgs[1]
assert(ans.kind == "token" and ans.ch == "joinlink-" .. band.code_hash(lt.code) and ans.to == "carol.tail9.ts.net:47281", "on the code's own channel, to the asker")
assert(band.json_decode(ans.data).token == joins.encode(tokt), "the invitation")
assert(redeem(MYDEV), "the same computer again (a lost answer): answered again")
assert(not redeem(A_DEV:gsub("^Z", "Y")) and #dmsgs == 0, "single use: another computer refused")
-- revoked, run out, not in charge any more
local link2 = invite.parse_link(invite.make_code(ROOT, "member"))
FS[ROOT .. "/_band/joins/" .. tokt.id .. ".json"] = nil
assert(not redeem(MYDEV, nil, link2.code), "its invitation revoked: refused")
FS[ROOT .. "/_band/joins/" .. tokt.id .. ".json"] = band.json_encode({ id = tokt.id })
manage = false
assert(not redeem(MYDEV, nil, link2.code), "no longer owner or admin: refused")
manage = true
local saved_time = os.time
os.time = function(t) if t then return saved_time(t) end return saved_time() + invite.CODE_LIFE + 5 end
assert(not redeem(MYDEV, nil, link2.code), "run out: refused")
os.time = saved_time
assert(not band.json_decode(A_EXT[SEC .. "/invite links"])[link2.code] or true, "run-out codes pruned")
-- too many refused asks: this computer stops listening to them for a while
for i = 1, invite.FAIL_MAX do redeem(MYDEV, nil, string.format("%024x", i)) end
local link3 = invite.parse_link(invite.make_code(ROOT, "member"))
local okp, whyp = redeem(MYDEV, nil, link3.code)
assert(not okp and whyp:find("too many"), "paused after FAIL_MAX refused asks")

-- ---- the joiner's answer --------------------------------------------------------------------------------------------------------------
ext = B_EXT
local bad_tok = { studio = "studiosync-elsewhere", id = tokt.id, role = "member", ends = tokt.ends, host = "alice.tail9.ts.net", device = A_DEV, name = "X", sig = tokt.sig }
assert(not invite.on_token("0000000000000000", { token = joins.encode(tokt) }), "an answer nobody's waiting for")
assert(not invite.on_token(h, { token = string.rep("x", 2000) }), "an oversized answer")
assert(not invite.on_token(h, { token = joins.encode(bad_tok) }) and #joined == 0, "an invitation to another studio than the link named: ignored")
local newtok = { studio = OTHER, id = tokt.id, role = "member", ends = tokt.ends, host = "alice.tail9.ts.net", device = A_DEV, name = "New band", sig = tokt.sig }
assert(invite.on_token(h, { token = joins.encode(newtok) }), "the right one")
assert(#joined == 1 and joined[1].band == OTHER and joined[1].id == A_DEV and #requested == 1 and requested[1].id == tokt.id, "joined as Paste join code does, then asked")
assert(not invite.on_token(h, { token = joins.encode(newtok) }), "once")
-- given up after REDEEM_FOR s
B_EXT[SEC .. "/invite redeem"] = band.json_encode({ ["1111111111111111"] = { code = code, studio = OTHER, name = "N", host = "alice.tail9.ts.net", ends = os.time() - 1 } })
clock = clock + 2
invite.tick(os.time())
assert(logged[#logged]:find("no answer") and band.json_decode(B_EXT[SEC .. "/invite redeem"])["1111111111111111"] == nil, "given up, said")

-- ---- the launcher's file ----------------------------------------------------------------------------------------------------------------
FS["H/link/pending.txt"] = string.rep("x", invite.LINK_MAX * 4 + 1)
assert(invite.take_pending() == "" and FS["H/link/pending.txt"] == nil, "an oversized file: read as nothing, gone")
FS["H/link/pending.txt"] = "studiosync://join?s=" .. SID .. "&p=Blue"
n_open = #opened
clock = clock + 5
invite.tick(os.time())
assert(#opened == n_open + 1 and opened[#opened].song == "Blue" and FS["H/link/pending.txt"] == nil, "a clicked link: read, gone, opened")

-- ---- the URL handler, per system, on a stand-in file layer ------------------------------------------------------------------------------
local uh = require("urlhandler")
local function fake(reg_out)
  local f = { files = {}, runs = {}, dirs = {} }
  f.io = {
    mkdir = function(d) f.dirs[d] = true end,
    write = function(p, s) f.files[p] = s; return true end,
    remove = function(p) f.files[p] = nil end,
    run = function(c) f.runs[#f.runs + 1] = c; if c:find("reg.exe query", 1, true) then return reg_out or "1\nnot found" end return "0\n" end,
    read = function(p) return f.files[p] end,
    exists = function(p) return f.files[p] ~= nil end,
  }
  return f
end
local TMP = "C:/tmp/ssinv test"
local win_o = { os = "win", home = TMP .. "/home", scripts = TMP .. "/Scripts/StudioSync", exe = "C:/Program Files/REAPER (x64)/reaper.exe", system_root = "C:\\Windows" }
local fw = fake()
assert(uh.install(win_o, fw.io), "Windows: put in")
local js = fw.files[TMP .. "/home/link/studiosync-link.js"]
assert(js and js:find('"C:\\\\tmp\\\\ssinv test\\\\home\\\\link\\\\pending.txt"', 1, true), "the launcher names the pending file, escaped")
assert(js:find("FolderExists(SCRIPTS)", 1, true) and js:find("reg.exe delete", 1, true), "and takes the handler away once StudioSync is gone")
assert(not js:find("Run(url", 1, true) and not js:find("+ url", 1, true), "the link is never part of a command")
local cmdline
for _, c in ipairs(fw.runs) do if c:find("shell\\open\\command", 1, true) then cmdline = c end end
assert(cmdline and cmdline:find('HKCU\\Software\\Classes\\studiosync', 1, true) and cmdline:find('\\"%1\\"', 1, true) and cmdline:find("wscript.exe", 1, true), "HKCU only, the link as one quoted argument")
for _, c in ipairs(fw.runs) do assert(not c:find("HKLM", 1, true) and not c:find("HKEY_LOCAL", 1, true), "nothing machine-wide") end
assert(not uh.installed(win_o, fw.io), "installed? asks the registry (the stand-in says no)")
local fw2 = fake("0\n    (Default)    REG_SZ    \"C:\\Windows\\System32\\wscript.exe\" //B //Nologo \"C:\\tmp\\ssinv test\\home\\link\\studiosync-link.js\" \"%1\"")
assert(uh.installed(win_o, fw2.io), "installed when the registry names our launcher")
fw2.files[TMP .. "/home/link/studiosync-link.js"] = "x"
assert(uh.uninstall(win_o, fw2.io) and fw2.files[TMP .. "/home/link/studiosync-link.js"] == nil, "taken away")
local deleted = false
for _, c in ipairs(fw2.runs) do deleted = deleted or c:find("reg.exe delete", 1, true) ~= nil end
assert(deleted, "the key deleted when it's ours")
local fw3 = fake("0\n    (Default)    REG_SZ    \"C:\\Other\\app.exe\" \"%1\"")
uh.uninstall(win_o, fw3.io)
for _, c in ipairs(fw3.runs) do assert(not c:find("reg.exe delete", 1, true), "someone else's studiosync handler is left alone") end
-- macOS
local mac_o = { os = "mac", home = "/Users/o'neil/Library/Application Support/REAPER/StudioSync", scripts = "/Users/o'neil/Library/Application Support/REAPER/Scripts/StudioSync",
  exe = "/Applications/REAPER.app", user_home = "/Users/o'neil" }
local fm = fake()
assert(uh.install(mac_o, fm.io), "macOS: put in")
local src = fm.files[mac_o.home .. "/link/StudioSync Link.applescript"]
assert(src and src:find("on open location theURL", 1, true) and src:find("quoted form of theURL", 1, true), "the applet writes the link through quoted form of")
assert(fm.runs[1] == "/bin/sh '" .. mac_o.home:gsub("'", "'\\''") .. "/link/install.sh'", "runs its install script, quoted")
assert(fm.files[mac_o.home .. "/link/install.sh"] == nil, "and removes it")
local fm_s = uh.mac_script(uh.paths(mac_o))
assert(fm_s:find("CFBundleURLSchemes:0 string studiosync", 1, true) and fm_s:find("lsregister -f '/Users/o'\\''neil/Applications/StudioSync Link.app'", 1, true), "URL type and LaunchServices, an apostrophe quoted")
assert(uh.uninstall(mac_o, fm.io) and fm.files[mac_o.home .. "/link/StudioSync Link.applescript"] == nil, "macOS: taken away")
assert(uh.mac_unscript(uh.paths(mac_o)):find("rm -rf '/Users/o'\\''neil/Applications/StudioSync Link.app'", 1, true), "only its own app")
-- Linux
local lin_o = { os = "linux", home = "/home/j$x/.config/REAPER/StudioSync", scripts = "/home/j$x/.config/REAPER/Scripts/StudioSync", exe = "/opt/REAPER/reaper", user_home = "/home/j$x" }
local fl = fake()
assert(uh.install(lin_o, fl.io), "Linux: put in")
local desk = fl.files["/home/j$x/.local/share/applications/studiosync-link.desktop"]
assert(desk and desk:find("MimeType=x-scheme-handler/studiosync;", 1, true) and desk:find('Exec=/bin/sh "/home/j\\$x/.config/REAPER/StudioSync/link/studiosync-link.sh" %u', 1, true), "the .desktop file, $ escaped")
local sh = fl.files["/home/j$x/.config/REAPER/StudioSync/link/studiosync-link.sh"]
assert(sh:find("printf '%s' \"$1\"", 1, true) and sh:find("PENDING='/home/j$x/", 1, true) and not sh:find("eval", 1, true), "the launcher: printf, single-quoted paths, no eval")
assert(uh.installed(lin_o, fl.io), "installed")
assert(uh.uninstall(lin_o, fl.io) and fl.files["/home/j$x/.local/share/applications/studiosync-link.desktop"] == nil, "Linux: taken away")
local fl2 = fake()
fl2.files["/home/j$x/.local/share/applications/studiosync-link.desktop"] = "[Desktop Entry]\nExec=someone-else %u\n"
uh.uninstall(lin_o, fl2.io)
assert(fl2.files["/home/j$x/.local/share/applications/studiosync-link.desktop"], "a .desktop file that isn't ours stays")
-- refusals and a failing step
assert(not uh.install_steps({ os = "win", home = "a\nb", scripts = "s", exe = "e" }), "a control character in a path: nothing")
assert(not uh.install_steps({ os = "beos", home = "a", scripts = "s", exe = "e" }), "an unknown system: nothing")
assert(not uh.install_steps({ os = "mac", home = "a", scripts = "s", exe = "e" }), "no home folder: nothing")
local ff = fake()
ff.io.run = function() return "1\nAccess is denied." end
local okf, whyf = uh.install(win_o, ff.io)
assert(not okf and whyf:find("Access is denied"), "a step that fails stops it, said")
assert(uh.sh_q("it's") == "'it'\\''s'" and uh.js_str('a\\"b') == '"a\\\\\\"b"' and uh.desktop_q("a b%") == '"a b%%"', "quoting")

-- ---- the page files ----------------------------------------------------------------------------------------------------------------------
local function read(f) local h = assert(io.open(f, "rb")); local x = h:read("a"); h:close(); return x end
local index = read("lib/webui/index.html")
assert(index:find('"invite.js"', 1, true) and index:find('"invite.js"', 1, true) < index:find('"chat.js"', 1, true), "invite.js before chat.js")
for _, f in ipairs({ "lib/webui/invite.js", "lib/webui/join.js" }) do
  local js = read(f)
  assert(not js:find("innerHTML", 1, true) and not js:find("eval(", 1, true) and not js:find("insertAdjacentHTML", 1, true), f .. ": no HTML from data, no eval")
  for u in js:gmatch("https?://[%w%.:]+") do assert(u:find("^http://127%.0%.0%.1"), f .. ": nothing remote (" .. u .. ")") end
end
assert(read("lib/webui/join.js"):find("addEventListener('click'", 1, true), "join.html sends nothing without a press")
assert(read("lib/webui/chat.js"):find("ssInvite.joinBox(m, scope, mine)", 1, true), "chat.js puts Join / Decline on a request")

print("ok - invite links, ask to join and the URL handler")
