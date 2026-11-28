-- Claims mode (lib/claimask.lua, rt-claims): four modes (Open is claims off), Driver + claims reads as Driver only; what you edit becomes yours (a track,
-- or a stretch of time across tracks), lapsing after AUTO_IDLE or when you leave; an edit to someone else's claim asks them: Release (the
-- claim moves, the held edit may go), Keep and no answer (put back), and someone away or out of reach (put back, saying so); the panel's
-- answer path; mirror.watch's W.refuse holding or putting back by what the ask says; Admins only's grants (lib/grants.lua). Two computers in one Lua: James and Chilio, the
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
local admins = { James = true } -- (the studio's owner and admins, as groups.may_manage says)
package.loaded.groups = { may_manage = function(_, u) return admins[u] == true end }
local trusted = true -- (Syncthing says the file's own `by` wrote it: trust.claim_ok)
package.loaded.trust = { claim_ok = function() return trusted end }
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

-- ---- four modes; Driver + claims reads as Driver only, said once ------------------------------------------------------------------------
local MI = require("live").MODE_INFO
assert(#MI == 4 and MI[1][2] == "Claims" and MI[2][1] == "everyone" and MI[2][2] == "Open", "four modes: Claims first, then Open (claims off)")
for _, m in ipairs(require("live").MODE_INFO) do assert(sync.MODES[m[1]], "a mode on disk: " .. m[1]) end
files[R .. "/mode.json"] = { mode = "claims" }
assert(sync.mode(J, "S", "main") == "driver" and logged[#logged]:find("Driver %+ claims") and logged[#logged]:find("Driver only"), "Driver + claims -> Driver only, said")
local n = #logged
sync.mode(J, "S", "main"); sync.mode(J, "S", "main")
assert(#logged == n, "once a session")
files[R .. "/mode.json"] = { mode = "everyone" }
assert(sync.mode(J, "S", "main") == "everyone" and #logged == n, "Open (\"everyone\" on disk) is a mode of its own, nothing said")
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

-- ---- Open: claims off, no auto-claims, no asks ------------------------------------------------------------------------------------------
files[R .. "/mode.json"] = { mode = "everyone" }
deliver()
assert(has(claims_of("Chilio").tracks, "Drums") and can("James", "Drums", 1) and can("Andie", "Drums", 1) and can("Andie", nil, nil), "Open: anyone changes anything, claimed or not")
assert(claimask.hold(J, B, who(), "Drums", 1) == nil and claimask.askable(J, B, who(), "Drums", 1) == nil and #wire == 0, "nothing asked")
sent("Strings", 60, 1)
assert(claimask.flush(J, B, who(), false) == 0 and not has(claims_of("James").tracks, "Strings"), "nothing claimed by itself")
files[R .. "/mode.json"] = { mode = "open" }
assert(not can("James", "Drums", 1), "back in Claims, Chilio's claim holds again")

-- ---- Admins only: an admin lets a guest or a member edit in this room (lib/grants.lua) -------------------------------------------------
local grants = require("grants")
files[R .. "/mode.json"] = { mode = "admins" }
local G = { root = "R", user = "Guest Kim" }
assert(not can("Guest Kim", "Keys", 1) and not can("Chilio", "Keys", 1) and can("James", "Keys", 1), "Admins only: only admins edit what nobody claimed")
local said, why = grants.set(C, "S", "main", "Guest Kim", true)
assert(not said and why:find("owner or an admin") and files[R .. "/grants/Chilio.json"] == nil, "a member can't grant")
said = grants.set(J, "S", "main", "Guest Kim", true)
assert(said and said:find("let Guest Kim edit in 'main'") and logged[#logged] == said, "an admin grants, logged")
assert(can("Guest Kim", "Keys", 1) and can("Guest Kim", nil, nil) and who().granted["Guest Kim"].by == "James", "the guest edits as an admin would, the timeline too")
assert(not can("Guest Kim", "Drums", 1), "but not what someone claimed (as for an admin)")
assert(not grants.set(J, "S", "main", "James", true), "an admin needs no grant")
files["R/S/rooms/side/mode.json"] = { mode = "admins" }
local other = sync.authority(J, "S", "side", session)
assert(not other("Guest Kim", "Keys", 1), "the grant doesn't reach another room")
grants.set(J, "S", "main", "Chilio", true)
assert(can("Chilio", "Keys", 1) and grants.health_words(J, B):find("Chilio, Guest Kim edit here too"), "a member too; Health says who")
-- a file that doesn't count: named for someone else, from someone no longer an admin, or not written by its `by`'s computer
files[R .. "/grants/Andie.json"] = { by = "Andie", users = { Andie = { on = true, at = "2099-01-01T00:00:00Z" } } }
assert(not can("Andie", "Keys", 1), "Andie (not an admin) granting herself: doesn't count")
files[R .. "/grants/Mallory.json"] = { by = "James", users = { Andie = { on = true, at = "2099-01-01T00:00:00Z" } } }
assert(not can("Andie", "Keys", 1), "a file named for someone else than its by: doesn't count")
trusted = false
assert(not can("Guest Kim", "Keys", 1), "not written by the admin's own computer: doesn't count")
trusted = true
-- revoke: the newest word wins, across admins' files
admins.Chilio = true
assert(grants.set(C, "S", "main", "Guest Kim", false):find("took back Guest Kim's editing"), "another admin revokes, logged")
assert(not can("Guest Kim", "Keys", 1) and can("Chilio", "Keys", 1), "revoked; the other grant stays")
T = T + 1
local n_log = #logged
assert(grants.web_action(J, B, { user = "Guest Kim", on = true }) == nil and #logged == n_log + 1 and logged[#logged]:find("James let Guest Kim edit"),
  "the web page's Let edit: in the log once (grants.set's line; webui logs only what web_action returns)")
assert(can("Guest Kim", "Keys", 1), "granted again")
assert(grants.web_action(C, B, { user = "x\ny", on = true }):find("not a name"), "names are plain")
admins.Chilio = nil
files[R .. "/mode.json"] = { mode = "driver" }
assert(not can("Guest Kim", "Keys", 1) and grants.health_words(J, B) == nil, "a grant counts only in Admins only")
files[R .. "/mode.json"] = { mode = "open" }
local wm = require("webui").presence_model("S", "main", { user = "James" }, {}, (function() files[R .. "/mode.json"] = { mode = "admins" }; return who() end)())
assert(wm.mode == "admins" and table.concat(wm.granted, ",") == "Chilio,Guest Kim", "Who's here on the web lists who may edit here")
files[R .. "/mode.json"] = { mode = "open" }

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
assert(ms:find("if opts.sent and w.edited ~= false then pcall(opts.sent, o, name, ev) end", 1, true), "W.send reports what went (auto-claims), but not with no edit of yours (rt-fix6a); a move only the tempo map made sends nothing to report (rt-edits round 7, rt-sync2f)")
src = io.open("StudioSync - Live sync.lua", "rb"); local ls = src:read("a"); src:close()
for _, want in ipairs({ 'claim_ask = function(d) require("claimask").on_ask(cfg, b, d) end', 'claim_answer = function(d) require("claimask").on_answer(cfg, b, d) end',
    'ask = function(name, pos) return require("claimask").hold(cfg, b, who, name, pos) end, sent = require("claimask").on_sent', 'require("claimask").flush, cfg, b, who, alone',
    'require("claimask").tick, proj, cfg, b', 'require("claimask").leave, cfg, b' }) do
  assert(ls:find(want, 1, true), "Live sync wires " .. want)
end
src = io.open("lib/webui/play.js", "rb"); local js = src:read("a"); src:close() -- (Who's here is Session's since rt-ui6)
assert(js:find("topic: 'claimask', id: q.id, answer", 1, true) and js:find("asks(p.asks || {})", 1, true), "the web page shows asks and answers them")
assert(js:find("topic: 'grants', user: x.user, on: !granted", 1, true) and require("webui").ACTIONS.grants, "the web page's Let edit / Revoke reach grants.web_action")

-- ---- a track's rename and the claim on it, through whole looks (REAPER check, 0.59.49.73) ----------------------------------------------
-- The desktop held an auto-claim on XT Drums A; the laptop renamed it XT Drums A2, nobody was asked, the laptop auto-claimed the new name
-- and the desktop's claim stayed on the old one. Two computers in the chunk-faithful stand-in REAPER (tests/fixtures/editreaper.lua), each
-- look wired as Live sync wires it: the real sync.authority, claimask's soft, hold, on_sent and flush, sync.receive and sync.follow_claims.
do
  package.path = "tests/fixtures/?.lua;" .. package.path
  local E = require("editreaper")
  local real_date = os.date
  os.date = function(fmt, t) return real_date(fmt, t or T) end -- (one clock for the events and the claims)
  band.read_json = function(path) local v = files[path]; if type(v) == "table" then return band.json_decode(band.json_encode(v)) end end
  band.write_json = function(path, v) files[path] = band.json_decode(band.json_encode(v)); return true end
  package.loaded.direct = nil -- (the real one from here, its messages onto the same wire: a look lists the link's inbox too)
  require("direct").send_live = function(cfg, kind, d) wire[#wire + 1] = { kind = kind, d = d, from = cfg.user }; return true end
  require("prints").choose = function() end
  package.loaded.groups.takes_to_lanes = function() return false end
  claimask._reset()
  sync.live_claims, wire, logged = {}, {}, {}
  local SONG, sess = "Ren", { host = "James", markers = {} }
  local b = { song = SONG, room = "main" }
  local RD = "R/Ren/rooms/main"
  local function computer(user, path)
    local c = { F = E.new(path), cfg = { user = user, root = "R" } }
    c.F.reaper.MB = function() return 6 end
    c.F.reaper.GetMousePosition = function() return 0, 0 end
    c.F.reaper.file_exists = function(p) return not p:find("%.json$") or files[p] ~= nil end -- (a claims file that isn't there isn't "busy")
    return c
  end
  local A, L = computer("James", "C:/A/Ren.rpp"), computer("Bee", "C:/B/Ren.rpp")
  local by_user = { James = A, Bee = L }
  here = { James = true, Bee = true }
  local function as(c) reaper = c.F.reaper end
  local function link() -- the direct link: claims to everyone, an ask and its answer to whoever it's for
    while #wire > 0 do
      local m = table.remove(wire, 1)
      if m.kind == "claim" then sync.live_claim(SONG, "main", m.d)
      elseif m.kind == "claim_ask" then as(by_user[m.d.to]); claimask.on_ask(by_user[m.d.to].cfg, b, m.d)
      elseif m.kind == "claim_answer" then as(by_user[m.d.to]); claimask.on_answer(by_user[m.d.to].cfg, b, m.d) end
    end
  end
  local seen = {}
  local function new_events()
    local out = {}
    for p, v in pairs(files) do
      if not seen[p] then
        seen[p] = true
        if p:find("/events/", 1, true) and type(v) == "table" and v.oid then out[v.oid] = v end
      end
    end
    return out
  end
  local function look(c)
    as(c)
    c.F.clock = c.F.clock + 1
    local may, w = sync.authority(c.cfg, SONG, "main", sess)
    sync.driver_name, sync.room_mode = w.driver, w.mode
    mirror.watch(c.F.proj, c.cfg, SONG, "main", { can = may, owner_can = may, mode = w.mode, is_claimed = w.is_claimed, owner_of = w.owner_of, quick = true,
      soft = function(name, pos) return claimask.soft(w, name, pos, c.cfg.user) end,
      ask = function(name, pos) return claimask.hold(c.cfg, b, w, name, pos) end, sent = claimask.on_sent })
    claimask.flush(c.cfg, b, w, false)
    link()
    as(c)
    return new_events()
  end
  local function settle(c)
    for _ = 1, 20 do
      if next(look(c)) == nil and not mirror.more and not mirror.unsettled then return end
      mirror.unsettled = nil
    end
    error("never settled")
  end
  local function recv(c)
    as(c)
    for _ = 1, 20 do
      c.F.clock = c.F.clock + 1
      local may, w = sync.authority(c.cfg, SONG, "main", sess)
      sync.soft = { room = "main", fn = function(name, pos, user) return claimask.soft(w, name, pos, user) end }
      local got = sync.receive(c.F.proj, c.cfg, SONG, "main", may)
      if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
    end
    sync.follow_claims(c.F.proj, c.cfg, SONG, "main") -- (Live sync's, every few seconds: your claim goes with its track's new name)
    link()
    settle(c)
  end
  local function mine(c) return files[RD .. "/claims/" .. c.cfg.user .. ".json"] or {} end
  local function auth() return select(2, sync.authority(A.cfg, SONG, "main", sess)) end
  local function told(pattern) for _, l in ipairs(logged) do if l:find(pattern) then return l end end end
  local function name_of(c, t) as(c); return select(2, reaper.GetTrackName(t)) end
  local function rename(c, t, to) as(c); reaper.GetSetMediaTrackInfo_String(t, "P_NAME", to, true) end

  -- the song, shared; then long enough that sharing it is nobody's work in progress
  local drums = A.F.add_track("Drums")
  A.F.add_track("Bass")
  settle(A); A.F.clock = A.F.clock + 70; settle(A)
  recv(L); L.F.clock = L.F.clock + 70; settle(L)
  T = T + sync.AUTO_IDLE + 120
  local oid = drums.ext.band_oid
  as(L)
  local ldrums = mirror.find(L.F.proj, "track", oid)
  assert(oid and ldrums and name_of(L, ldrums) == "Drums" and not auth().tracks.drums, "the song is on both, and nothing is claimed any more")
  -- the desktop turns Drums down: its auto-claim
  as(A); reaper.SetMediaTrackInfo_Value(drums, "D_VOL", 0.5)
  T = T + 2; settle(A); T = T + 2; recv(L)
  assert(auth().tracks.drums.user == "James" and auth().tracks.drums.auto, "Drums is James's auto-claim")
  -- 1. the laptop renames it: held and asked for, not sent, nothing claimed for the renamer
  logged = {}
  rename(L, ldrums, "Drums 2")
  T = T + 2
  local out = look(L)
  assert(not out[oid], "a rename of a bandmate's auto-claimed track: not sent\n" .. table.concat(logged, "\n"))
  assert(told("^asked James to release Drums") and name_of(L, ldrums) == "Drums 2", "James is asked for Drums (the claim on its old name), the rename held here")
  local q = claimask.model(b).incoming[1]
  assert(q and q.from == "Bee" and q.what == "Drums", "James sees Bee wants to edit Drums")
  assert(not auth().tracks["drums 2"] and #(mine(L).tracks or {}) == 0, "the new name isn't claimed for the renamer")
  -- Keep: the name goes back
  as(A); claimask.answer(A.cfg, b, q.id, false); link()
  out = look(L)
  assert(not out[oid] and name_of(L, ldrums) == "Drums" and told("James kept Drums"), "kept: the track is Drums again here, nothing sent")
  assert(auth().tracks.drums.user == "James" and name_of(A, drums) == "Drums", "James's claim and track as they were")
  settle(L)
  -- Release: the rename goes to everyone, and the claim goes to the renamer under the new name
  L.F.clock = L.F.clock + claimask.COOLDOWN + 1
  rename(L, ldrums, "Drums 2")
  T = T + 2
  look(L)
  q = claimask.model(b).incoming[1]
  assert(q and q.what == "Drums", "asked again")
  as(A); claimask.answer(A.cfg, b, q.id, true); link()
  out = look(L)
  assert(out[oid] and out[oid].state.name == "Drums 2", "released: the rename goes out")
  settle(L)
  local c = mine(L)
  assert(#c.tracks == 1 and c.tracks[1] == "Drums 2" and c.auto["tracks:drums 2"] and not c.auto["tracks:drums"], "the claim is Bee's, under the new name, still an auto-claim")
  assert(not has(mine(A).tracks, "Drums") and not has(mine(A).tracks, "Drums 2"), "and out of James's file")
  T = T + 2; recv(A)
  assert(name_of(A, drums) == "Drums 2" and auth().tracks["drums 2"].user == "Bee" and not auth().tracks.drums, "everyone has the new name, claimed by Bee; the old name is nobody's")
  -- 2. the claimer renames their own: the claim, its date, its auto mark and its track id follow, and no id is left under the old name
  as(L); sync.follow_claims(L.F.proj, L.cfg, SONG, "main")
  c = mine(L)
  local since = c.since["tracks:drums 2"]
  assert(c.oids["drums 2"] == oid and since, "the claim knows its track")
  rename(L, ldrums, "Kit")
  T = T + 2
  out = look(L)
  assert(out[oid] and out[oid].state.name == "Kit", "the claimer's own rename goes out, nobody asked")
  settle(L)
  c = mine(L)
  assert(#c.tracks == 1 and c.tracks[1] == "Kit" and c.since["tracks:kit"] == since and c.auto["tracks:kit"], "the claim follows, dated as it was")
  assert(c.oids.kit == oid and c.oids["drums 2"] == nil and c.since["tracks:drums 2"] == nil, "no id or date left under the old name")
  T = T + 2; recv(A)
  assert(auth().tracks.kit.user == "Bee" and not auth().tracks["drums 2"], "on the desktop too")
  -- 3. Open: anyone renames it, nobody is asked, nothing is claimed; the claim (kept, not holding) goes with its track
  files[RD .. "/mode.json"] = { mode = "everyone" }
  logged = {}
  rename(A, drums, "Perc")
  T = T + 2
  out = look(A)
  assert(out[oid] and out[oid].state.name == "Perc" and #claimask.model(b).incoming == 0 and not told("asked"), "Open: the rename goes straight out")
  settle(A)
  assert(not has(mine(A).tracks, "Perc") and not has(mine(A).tracks, "Kit"), "and claims nothing")
  T = T + 2; recv(L)
  c = mine(L)
  assert(name_of(L, ldrums) == "Perc" and c.tracks[1] == "Perc" and c.oids.perc == oid and c.oids.kit == nil and c.auto["tracks:perc"], "Bee's claim went with the track (sync.follow_claims), its mark and id too")
  as(A)
  assert(sync.live_claims["Ren/main"].Bee.tracks[1] == "Perc", "and over the link at once")
  os.date = real_date
end
print("ok")
