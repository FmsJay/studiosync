-- Claims mode (lib/claimask.lua, rt-claims): three modes and the two removed ones read as the nearest; what you edit becomes yours (a track,
-- or a stretch of time across tracks), lapsing after AUTO_IDLE or when you leave; an edit to someone else's claim asks them: Release (the
-- claim moves, the held edit may go), Keep and no answer (put back), and someone away or out of reach (put back, saying so); the panel's
-- answer path; mirror.watch's W.refuse holding or putting back by what the ask says. Two computers in one Lua: James and Chilio, the
-- direct link a queue delivered by hand, the shared folder a table. (James, 2026-11-20)
package.path = "lib/?.lua;" .. package.path
local ext, clock, T = {}, 1000, 1800000000
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return T end
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetOS = function() return "Win64" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
local files, logged = {}, {}
band.read_json = function(path) return files[path] end
band.write_json = function(path, v) files[path] = v end
band.log = function(s) logged[#logged + 1] = s end
local function list(dir) local out = {}; for p in pairs(files) do local f = p:match("^" .. dir:gsub("%p", "%%%0") .. "/([^/]+%.json)$"); if f then out[#out + 1] = f end end; table.sort(out); return out end
band.files, band.listing = list, function(dir) return list(dir) end
local alerts = {}
package.loaded.alerts = { send = function(_, kind, title, msg) alerts[#alerts + 1] = { kind = kind, title = title, msg = msg }; return true end }
local link_ok, wire = true, {}
package.loaded.direct = { send_live = function(cfg, kind, d) if not link_ok then return false end; wire[#wire + 1] = { kind = kind, d = d, from = cfg.user }; return true end }
local sync = require("sync")
local mirror = require("mirror")
local claimask = require("claimask")
local J, C = { root = "R", user = "James" }, { root = "R", user = "Chilio" }
local B = { song = "S", room = "main" }
local R = "R/S/rooms/main"
local session = { host = "James", markers = { { region = true, name = "Verse", pos = 10, ["end"] = 30 } } }
local here = { James = true, Chilio = true }
claimask.present = function(_, _, u) return here[u] == true end
local users = { James = J, Chilio = C }
local function deliver() -- the link: each message to whoever it's for (claims to everyone)
  while #wire > 0 do
    local m = table.remove(wire, 1)
    if m.kind == "claim" then sync.live_claim("S", "main", m.d)
    elseif m.kind == "claim_ask" then claimask.on_ask(users[m.d.to], B, m.d)
    elseif m.kind == "claim_answer" then claimask.on_answer(users[m.d.to], B, m.d) end
  end
end
local function who() return select(2, sync.authority(J, "S", "main", session)) end
local function can(u, name, pos) return (sync.authority(J, "S", "main", session))(u, name, pos) end
local function claims_of(u) return files[R .. "/claims/" .. u .. ".json"] or {} end
local function has(l, n) for _, x in ipairs(l or {}) do if x == n then return true end end return false end
local function sent(name, pos, len) claimask.on_sent({ kind = "item", state = "<ITEM\nPOSITION " .. pos .. "\nLENGTH " .. len .. "\n>\n" }, name, { pos = pos }) end

-- ---- three modes; the removed two read as the nearest, said once each --------------------------------------------------------------------
assert(#require("live").MODE_INFO == 3 and require("live").MODE_INFO[1][2] == "Claims", "three modes, Claims first")
for _, m in ipairs(require("live").MODE_INFO) do assert(sync.MODES[m[1]], "a mode on disk: " .. m[1]) end
files[R .. "/mode.json"] = { mode = "claims" }
assert(sync.mode(J, "S", "main") == "driver" and logged[#logged]:find("Driver %+ claims") and logged[#logged]:find("Driver only"), "Driver + claims -> Driver only, said")
local n = #logged
files[R .. "/mode.json"] = { mode = "everyone" }
assert(sync.mode(J, "S", "main") == "open" and #logged == n + 1 and logged[#logged]:find("Anyone %(claims ignored%)"), "Anyone (claims ignored) -> Claims, said")
sync.mode(J, "S", "main"); sync.mode(J, "S", "main")
assert(#logged == n + 1, "once a session")
files[R .. "/mode.json"] = { mode = "open" }

-- ---- auto-claims ----------------------------------------------------------------------------------------------------------------------------
-- a track: one edit on Keys, someone here
sent("Keys", 1, 2)
assert(claimask.flush(J, B, who(), false) == 1, "claimed")
local c = claims_of("James")
assert(has(c.tracks, "Keys") and c.auto and c.auto["tracks:keys"] == os.date("!%Y-%m-%dT%H:%M:%SZ", T), "Keys is James's, marked as an auto-claim with its time")
assert(wire[#wire] and wire[#wire].kind == "claim" and wire[#wire].d.auto["tracks:keys"], "and over the link at once")
deliver()
local w = who()
assert(w.tracks.keys.user == "James" and w.tracks.keys.auto and not can("Chilio", "Keys", 1), "everyone sees it, and it holds")
assert(logged[#logged]:find("claimed Keys for you") and logged[#logged]:find("10 minutes"), "said, with how long it lasts")
-- alone, a print, and someone else's: none claimed
sent("Organ", 1, 1)
assert(claimask.flush(J, B, who(), true) == 0 and not has(claims_of("James").tracks, "Organ"), "alone: nobody to keep out, nothing claimed")
claimask.on_sent({ kind = "item", state = "" }, "Organ", { pos = 1, auto = true })
assert(claimask.flush(J, B, who(), false) == 0, "StudioSync's own print: not an edit")
sync.set_claims(C, "S", "main", { tracks = { "Bass" } }); deliver()
sent("Bass", 4, 1)
assert(claimask.flush(J, B, who(), false) == 0 and not has(claims_of("James").tracks, "Bass"), "Chilio's Bass: not taken")
files[R .. "/mode.json"] = { mode = "driver" }
sent("Organ", 1, 1)
assert(claimask.flush(J, B, who(), false) == 0, "Driver only: no auto-claims")
files[R .. "/mode.json"] = { mode = "open" }
-- a stretch of time: items on three tracks or more in one look
sent("Drums", 40, 2); sent("Pad", 41, 1); sent("Lead", 42, 3)
assert(claimask.flush(J, B, who(), false) == 1, "one claim")
c = claims_of("James")
local t = c.times and c.times[1]
assert(t and t.from == 40 and t.to == 45 and t.auto and not has(c.tracks, "Pad"), "the time they cover, not each track")
deliver()
assert(who().owner_of("Strings", 43) == "James" and who().times[1].auto and not can("Chilio", "Strings", 43), "it holds for what starts in it")
-- touched again (at most once a minute), then idle: lapses on every computer, and James's own tick drops it
T = T + 120
sent("Keys", 1, 2); claimask.flush(J, B, who(), false)
assert(claims_of("James").auto["tracks:keys"] == os.date("!%Y-%m-%dT%H:%M:%SZ", T), "an edit to it touches it again")
T = T + sync.AUTO_IDLE - 60
assert(who().tracks.keys and not who().times[1], "Keys still counts (touched 9 minutes ago); the time claim lapsed (untouched 11 minutes)")
T = T + 120
deliver()
assert(not who().tracks.keys and can("Chilio", "Keys", 1), "10 minutes without an edit: it stops counting, on every computer")
claimask.tick("PJ", J, B)
assert(not has(claims_of("James").tracks, "Keys") and #(claims_of("James").times or {}) == 0 and logged[#logged]:find("let go of"), "and James's Live sync drops it from the file")
-- claimed by hand: lasting; leaving the room lets the auto ones go and keeps that one
c = claims_of("James")
claimask.add(c, { kind = "tracks", name = "Keys" }, true, os.date("!%Y-%m-%dT%H:%M:%SZ", T))
claimask.add(c, { kind = "tracks", name = "Organ" }, true, os.date("!%Y-%m-%dT%H:%M:%SZ", T))
assert(claimask.add(c, { kind = "tracks", name = "Organ" }, false) and not c.auto["tracks:organ"], "Claim on an auto-claim: lasting")
sync.set_claims(J, "S", "main", c)
assert(claimask.leave(J, B) == 1, "leaving: one auto-claim let go")
assert(has(claims_of("James").tracks, "Organ") and not has(claims_of("James").tracks, "Keys"), "the lasting one stays")
deliver()

-- ---- asking ---------------------------------------------------------------------------------------------------------------------------------
-- Chilio away: their claim stands, and says so
here.Chilio = false
local r = claimask.hold(J, B, who(), "Bass", 4)
assert(type(r) == "string" and r:find("Chilio has claimed Bass and isn't here") and #wire == 0, "away: put back, no ask: " .. tostring(r))
assert(claimask.askable(J, B, who(), "Bass", 4) == nil, "and the web pages refuse it")
here.Chilio = true
link_ok = false
r = claimask.hold(J, B, who(), "Bass", 4)
assert(type(r) == "string" and r:find("can't reach them"), "the link can't reach them: put back, saying so")
link_ok = true
assert(claimask.hold(J, B, who(), "Keys", 1) == nil and claimask.hold(J, B, who(), "Organ", 1) == nil, "nobody's, or James's own: not asked about")
-- Release: the claim moves, the held edit may go
assert(claimask.askable(J, B, who(), "Bass", 4) == "Chilio", "the web pages would ask")
mirror.unsettled = false
assert(claimask.hold(J, B, who(), "Bass", 4) == true and mirror.unsettled, "held, and Live sync looks again soon")
assert(wire[1].kind == "claim_ask" and wire[1].d.to == "Chilio" and wire[1].d.thing.name == "Bass", "Chilio asked over the link")
assert(claimask.model(B).waiting[1].to == "Chilio" and claimask.model(B).waiting[1].what == "Bass", "James sees it waiting")
assert(claimask.hold(J, B, who(), "Bass", 5) == true and #wire == 1, "another edit to it: held too, one ask")
deliver()
local q = claimask.model(B).incoming[1]
assert(q and q.from == "James" and q.what == "Bass" and q.till > T, "Chilio sees James wants to edit Bass")
assert(alerts[#alerts].kind == "claim ask" and alerts[#alerts].msg:find("James wants to edit Bass"), "and the phone alert")
assert(claimask.answer(C, B, q.id, true):find("released Bass to James"), "Chilio releases")
assert(not has(claims_of("Chilio").tracks, "Bass"), "out of Chilio's file")
deliver()
assert(has(claims_of("James").tracks, "Bass") and not (claims_of("James").auto or {})["tracks:bass"], "into James's, lasting as Chilio's was")
assert(can("James", "Bass", 4) and not can("Chilio", "Bass", 4) and claimask.hold(J, B, who(), "Bass", 4) == nil, "James's now: the held edit goes on the next look")
assert(logged[#logged]:find("your edit goes to everyone"), "said")
-- Keep: put back, and not asked again for a minute
sync.set_claims(C, "S", "main", { tracks = { "Drums" } }); deliver()
assert(claimask.hold(J, B, who(), "Drums", 1) == true, "held")
deliver()
claimask.answer(C, B, claimask.model(B).incoming[1].id, false)
deliver()
r = claimask.hold(J, B, who(), "Drums", 1)
assert(type(r) == "string" and r:find("Chilio kept Drums") and has(claims_of("Chilio").tracks, "Drums"), "kept: put back: " .. tostring(r))
clock = clock + 10
r = claimask.hold(J, B, who(), "Drums", 2)
assert(type(r) == "string" and #wire == 0 and claimask.askable(J, B, who(), "Drums", 2) == nil, "another edit within the minute: put back, nobody asked again")
clock = clock + claimask.COOLDOWN
assert(claimask.hold(J, B, who(), "Drums", 2) == true and #wire == 1, "a minute on: asked again")
deliver()
-- no answer: put back after ASK_WAIT, and the ask goes from Chilio's list
clock = clock + claimask.ASK_WAIT + 1
r = claimask.hold(J, B, who(), "Drums", 2)
assert(type(r) == "string" and r:find("didn't answer about Drums in 30 s"), "no answer: put back: " .. tostring(r))
claimask.tick("PC", C, B)
assert(#claimask.model(B).incoming == 0, "and gone from Chilio's list")
-- an auto-claim moves as one; a region claim moves as a region claim
clock = clock + claimask.COOLDOWN + 1
sent("Vox", 50, 1); claimask.flush(C, B, who(), false); deliver()
assert(who().tracks.vox.user == "Chilio" and who().tracks.vox.auto, "Chilio's Vox, auto")
assert(claimask.hold(J, B, who(), "Vox", 50) == true); deliver()
claimask.answer(C, B, claimask.model(B).incoming[1].id, true); deliver()
assert(has(claims_of("James").tracks, "Vox") and claims_of("James").auto["tracks:vox"], "James takes it as an auto-claim")
sync.set_claims(C, "S", "main", { tracks = { "Drums" }, regions = { "Verse" } }); deliver()
assert(claimask.which(who(), "Strings", 12).kind == "regions", "an item in Chilio's Verse: the region claim decides")
assert(claimask.hold(J, B, who(), "Strings", 12) == true and wire[1].d.thing.kind == "regions", "asked for the region"); deliver()
assert(claimask.model(B).incoming[1].what == "the region Verse", "named as a region")
claimask.answer(C, B, claimask.model(B).incoming[1].id, true); deliver()
assert(has(claims_of("James").regions, "Verse") and not has(claims_of("Chilio").regions, "Verse") and who().owner_of("Strings", 12) == "James", "the region moved")
-- the panel's Release / Keep: through ExtState to Live sync's tick
sync.set_claims(C, "S", "main", { tracks = { "Drums", "Lead" } }); deliver()
assert(claimask.hold(J, B, who(), "Lead", 1) == true); deliver()
claimask.tick("PC", C, B)
local m = band.json_decode(ext[band.SECTION .. "/claim asks PC"])
assert(m and m.incoming[1].from == "James", "the panel reads the asks")
ext[band.SECTION .. "/claim answer PC"] = band.json_encode({ id = m.incoming[1].id, yes = true })
claimask.tick("PC", C, B); deliver()
assert(has(claims_of("James").tracks, "Lead") and ext[band.SECTION .. "/claim answer PC"] == nil, "the panel's Release went through")
-- the web page's answer, and what's refused from the link
sync.set_claims(C, "S", "main", { tracks = { "Drums", "Pad" } }); deliver()
assert(claimask.hold(J, B, who(), "Pad", 1) == true); deliver()
assert(claimask.web_action(C, B, { id = claimask.model(B).incoming[1].id, answer = "keep" }):find("kept Pad"), "the web page's Keep")
assert(claimask.web_action(C, B, { id = "nope", answer = "release" }):find("run out"), "an ask that's gone")
assert(claimask.web_action(C, B, { id = "x", answer = "maybe" }) == nil, "only Release or Keep")
deliver()
assert(not claimask.on_ask(C, B, { id = "x 1", from = "James", to = "Chilio", thing = { kind = "tracks", name = "Pad" } }), "an id with a space")
assert(not claimask.on_ask(C, B, { id = "x-1", from = "James", to = "Chilio", thing = { kind = "files", name = "Pad" } }), "not a kind of claim")
assert(not claimask.on_ask(C, B, { id = "x-1", from = "James", to = "Chilio", thing = { kind = "times", from = 5, to = 2 } }), "time running backwards")
assert(not claimask.on_ask(C, B, { id = "x-1", from = "James", to = "Andie", thing = { kind = "tracks", name = "Pad" } }), "not for Chilio")
assert(not claimask.on_answer(J, B, { id = "x-1", from = "Chilio", to = "James", answer = "release" }), "an answer to nothing James asked")
claimask.on_ask(C, B, { id = "x-2", from = "James", to = "Chilio", thing = { kind = "tracks", name = "Nothing" } })
assert(wire[1].kind == "claim_answer" and wire[1].d.answer == "release" and #claimask.model(B).incoming == 0, "not Chilio's (any more): Release at once, nothing to ask")
wire = {}
for i = 1, claimask.MAX_IN + 1 do claimask.on_ask(C, B, { id = "f-" .. i, from = "James", to = "Chilio", thing = { kind = "tracks", name = "Drums" .. (i == 1 and "" or "") } }) end
-- (one per asker and thing: the same thing asked again replaces the last)
assert(#claimask.model(B).incoming == 1, "the same thing asked again: one ask")
claimask._reset()
wire = {}

-- ---- mirror.watch's W.refuse holds or puts back by what the ask says ------------------------------------------------------------------
local backs, asked_with = {}, nil
local function refuse(answer)
  backs = {}
  mirror.unsent = {}
  local w = { band = band, sync = sync, proj = "PW", cfg = J, song = "S", room = "main", me = "James", room_dir = "RW", media = "RW/media",
    opts = { mode = "open", ask = function(name, pos) asked_with = { name, pos }; return answer end },
    owner_of = function() return "Chilio" end, is_claimed = function() return true end,
    put_back = function(o, rev, evid, why) backs[#backs + 1] = why end, propose = function() return false end, say_once = function() end }
  mirror.W.refuse(w, { kind = "item", oid = "I-X", state = "<ITEM\nPOSITION 4\n>\n", pos = 4, track = "T-1" }, "PWI-X", 2, "Chilio-1", "", { name = "Bass", pos = 4, state = "<ITEM\nPOSITION 3\n>\n" }, "Bass", false)
end
refuse(true)
assert(#backs == 0 and mirror.unsent["PWI-X"] and asked_with[1] == "Bass", "asked: held, nothing put back, the band's change to it waits")
refuse("Not sent: Chilio kept Bass. Your edit is put back")
assert(#backs == 1 and backs[1].text:find("Chilio kept Bass") and backs[1].copy, "kept: put back with why, an item's copy kept")
refuse(nil)
assert(#backs == 1 and backs[1].text:find("claimed by Chilio"), "not an ask: refused as before")
local src = io.open("lib/mirror.lua", "rb"); local ms = src:read("a"); src:close()
assert(ms:find("if opts.sent then pcall(opts.sent, o, name, ev) end", 1, true), "W.send reports what went (auto-claims)")
src = io.open("StudioSync - Live sync.lua", "rb"); local ls = src:read("a"); src:close()
for _, want in ipairs({ 'claim_ask = function(d) require("claimask").on_ask(cfg, b, d) end', 'claim_answer = function(d) require("claimask").on_answer(cfg, b, d) end',
    'ask = function(name, pos) return require("claimask").hold(cfg, b, who, name, pos) end, sent = require("claimask").on_sent', 'require("claimask").flush, cfg, b, who, alone',
    'require("claimask").tick, proj, cfg, b', 'require("claimask").leave, cfg, b' }) do
  assert(ls:find(want, 1, true), "Live sync wires " .. want)
end
src = io.open("lib/webui/app.js", "rb"); local js = src:read("a"); src:close()
assert(js:find("topic: 'claimask', id: q.id, answer", 1, true) and js:find("asks(p.asks || {})", 1, true), "the web page shows asks and answers them")
print("ok")
