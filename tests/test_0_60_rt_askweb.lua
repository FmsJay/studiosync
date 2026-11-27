-- The local asks on the web page (lib/claimask.lua local_asks / web_local, lib/webui.lua, lib/webui/play.js; rt-askweb): the big deletion's ask and
-- StudioSync's Undo ask reach the web view's presence topic, and its Yes / No go to the same ExtState answers the panel's bar writes: Yes, No,
-- a phone refused, an ask that ran out or another id ignored, the first answer standing, and Live sync's tick carrying it out.
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
  GetMousePosition = function() return 0, 0 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
local files, logged = {}, {}
band.read_json = function(path) return files[path] end
band.write_json = function(path, v) files[path] = v end
band.log = function(s) logged[#logged + 1] = s end
band.files, band.listing = function() return {} end, function() return {} end
package.loaded.alerts = { send = function() return true end }
local claimask, undo = require("claimask"), require("undo")
local J, B, P = { root = "R", user = "James" }, { song = "S", room = "main" }, "PC"
local function K(name) return band.SECTION .. "/" .. name .. " " .. P end

assert(#claimask.local_asks(P) == 0, "nothing asked: an empty list")

-- ---- the big deletion's ask, and Undo's, in the list -------------------------------------------------------------------------------------
assert(claimask.big_delete(P, 2, 3, "a,b") == nil, "the deletion asks and waits")
local list = claimask.local_asks(P)
assert(#list == 1 and list[1].kind == "delete" and list[1].text == "Delete 2 of the song's 3 tracks for everyone?" and list[1].till == T + claimask.BIG_WAIT
  and list[1].id:find("^big%-"), "the delete ask: kind, words, until when, an id")
undo.ask(P, 77, false, "Undo: Bee's Keys? It goes to everyone.")
list = claimask.local_asks(P)
assert(#list == 2 and list[2].kind == "undo" and list[2].id == "77" and list[2].text:find("Undo: Bee", 1, true), "and Undo's beside it")
local did, uid = list[1].id, list[2].id

-- ---- a phone (or any page not on this computer) gets the words, not the answer ------------------------------------------------------------
assert(claimask.web_action(J, B, { topic = "claimask", ask = "delete", id = did, yes = true }, P, false):find("on the computer itself", 1, true), "from a phone: refused, saying where")
assert(claimask.web_action(J, B, { topic = "claimask", ask = "undo", id = uid, yes = true }, P, false):find("on the computer itself", 1, true), "Undo's, too")
assert(claimask.web_action(J, B, { topic = "claimask", ask = "undo", id = uid, yes = true }, P, nil):find("on the computer itself", 1, true), "no way to tell where it came from: refused")
assert(ext[K("delete answer")] == nil and ext[K("undo answer")] == nil and undo.pending(P) and claimask.big_pending(P), "nothing was answered, both still ask")

-- ---- not an ask here: another id, a kind that isn't one -----------------------------------------------------------------------------------
assert(claimask.web_action(J, B, { ask = "delete", id = "big-999", yes = true }, P, true):find("run out", 1, true), "another id: ignored")
assert(claimask.web_action(J, B, { ask = "undo", id = "1", yes = true }, P, true):find("run out", 1, true), "Undo's, another id")
assert(claimask.web_action(J, B, { ask = "format", id = did, yes = true }, P, true) == nil, "a kind that isn't one")
assert(claimask.web_action(J, B, { ask = "delete", id = 5, yes = true }, P, true) == nil, "an id that isn't text")
assert(claimask.web_action(J, B, { ask = "delete", id = did, yes = "true" }, P, true):find("answered No", 1, true), "anything but true is No, never Yes")
assert(ext[K("delete answer")] and band.json_decode(ext[K("delete answer")]).yes == false, "(a text 'true' was No)")
ext[K("delete answer")] = nil

-- ---- Yes to the deletion: the panel's ExtState answer, carried out by Live sync's tick; the first answer stands --------------------------------
local said = claimask.web_action(J, B, { ask = "delete", id = did, yes = true }, P, true)
assert(said:find("answered Yes", 1, true) and said:find("Delete 2 of the song's 3", 1, true), "Yes from this computer's page: " .. tostring(said))
local ans = band.json_decode(ext[K("delete answer")])
assert(ans.id == did and ans.yes == true, "the same answer the bar writes")
assert(claimask.web_action(J, B, { ask = "delete", id = did, yes = false }, P, true):find("already", 1, true) and band.json_decode(ext[K("delete answer")]).yes == true,
  "a second answer (the bar's No, a double click) doesn't replace it")
claimask.tick(P, J, B)
assert(ext[K("delete answer")] == nil and claimask.big_delete(P, 2, 3, "a,b") == true, "Live sync's tick took it: the look is told Yes")
assert(claimask.big_pending(P) == nil and #claimask.local_asks(P) == 1, "and the delete ask is gone from the list")

-- ---- No to the deletion -------------------------------------------------------------------------------------------------------------------
assert(claimask.big_delete(P, 3, 4, "c,d,e") == nil)
local did2 = claimask.local_asks(P)[1].id
assert(claimask.web_action(J, B, { ask = "delete", id = did2, yes = false }, P, true):find("answered No", 1, true), "No from the page")
claimask.tick(P, J, B)
assert(claimask.big_delete(P, 3, 4, "c,d,e") == false, "No: the look puts the tracks back")

-- ---- Undo: Yes is Live sync's answer, No ends the ask ---------------------------------------------------------------------------------------
assert(claimask.web_action(J, B, { ask = "undo", id = uid, yes = true }, P, true):find("answered Yes", 1, true), "Yes to Undo")
ans = band.json_decode(ext[K("undo answer")])
assert(ans.id == uid and ans.yes == true and undo.pending(P), "the bar's answer, written; the ask stays for Live sync to carry out")
ext[K("undo answer")] = nil
assert(claimask.web_action(J, B, { ask = "undo", id = uid, yes = false }, P, true):find("answered No", 1, true), "No to Undo")
assert(undo.pending(P) == nil and ext[K("undo answer")] == nil and #claimask.local_asks(P) == 0, "No: the ask is cleared, nothing is asked of Live sync, the list is empty")

-- ---- an ask that ran out is ignored -----------------------------------------------------------------------------------------------------------
undo.ask(P, 78, true, "Redo: Bee's Keys? It goes to everyone.")
assert(claimask.big_delete(P, 2, 3, "x,y") == nil)
local old = claimask.local_asks(P)
assert(#old == 2, "both asking")
T = T + 31
assert(#claimask.local_asks(P) == 0, "past their time they leave the list")
for _, q in ipairs(old) do
  assert(claimask.web_action(J, B, { ask = q.kind, id = q.id, yes = true }, P, true):find("run out", 1, true), "an answer to the " .. q.kind .. " ask after its time: ignored")
end
assert(ext[K("undo answer")] == nil and ext[K("delete answer")] == nil, "and no answer written")

-- ---- wired: the page's action, the presence topic, the page code -------------------------------------------------------------------------------
local function slurp(f) local h = assert(io.open(f, "rb")); local t = h:read("a"); h:close(); return t end
local w, js = slurp("lib/webui.lua"), slurp("lib/webui/play.js")
assert(w:find('require("claimask").web_action(cfg, b, a, proj, reaper.StudioSync_WebUIPollHere ~= nil and reaper.StudioSync_WebUIPollHere() == 1)', 1, true),
  "the action carries the tab and whether the page is on this computer")
assert(w:find('pm.asks.local_asks = require("claimask").local_asks(proj)', 1, true), "the presence topic carries the list")
assert(js:find("a.local_asks || []", 1, true) and js:find("topic: 'claimask', ask: q.kind, id: q.id, yes", 1, true) and js:find("ssEnv.where === 'remote'", 1, true),
  "the page lists them, answers through the claimask topic, and leaves the buttons off a remote page")
print("ok: the local asks on the web page")
