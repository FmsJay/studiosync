-- StudioSync on the phone, stage 2 (lib/phonedaw.lua, lib/webui/phonedaw.js): what a phone may send, the lanes and takes it's shown (the same
-- shown tracks and items as the Project page, each lane's GUID and oid), picking an item's active take under the room's rules (the real
-- sync.authority over a stand-in shared folder) in one undo point, refusals that change nothing, the answer published for the phone, the topic
-- built only while a phone looks, and a link check of the phone page's hooks. (James, rt)
package.path = "lib/?.lua;" .. package.path
local ext, logged = {}, {}
reaper = setmetatable({
  time_precise = function() return 1000 end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end

-- ---- a stand-in shared folder, read by the real sync.authority -----------------------------------------------------------------------
local files = {}
band.read_json = function(path) return files[path] end
local function list(dir) local out = {}; for p in pairs(files) do local f = p:match("^" .. dir:gsub("%p", "%%%0") .. "/([^/]+%.json)$"); if f then out[#out + 1] = f end end; table.sort(out); return out end
band.files, band.listing = list, function(dir) return list(dir) end
local R = "R/S/rooms/main"
files["R/S/session.json"] = { host = "James" }
local function room(mode, claims)
  for p in pairs(files) do if p:find("^" .. R) then files[p] = nil end end
  files[R .. "/mode.json"] = { mode = mode }
  for user, c in pairs(claims or {}) do c.user, c.time = user, "2026-11-20T10:00:00Z"; files[R .. "/claims/" .. user .. ".json"] = c end
end
package.loaded.groups = { may_manage = function(_, user) return user == "Admin" end }
package.loaded.mirror = {
  local_track = function(tr) return tr.t["local"] == true end,
  track_oid = function(tr) return (tr.t.oid or ""):upper() end,
  item_oid = function(it) return (it.oid or ""):upper() end,
  is_creator = function(oid, user) return (oid or ""):match("^%a%-(.-)%-") == user:upper() end,
}
local peers = {}
local presence = require("presence")
presence.peers = function() return peers end
local phonedaw = require("phonedaw")

-- ---- parse ------------------------------------------------------------------------------------------------------------------------------
local d = phonedaw.parse({ id = "p1", take = { lane = 2, idx = 0, p = 4, l = 2, k = 1 } })
assert(d and d.id == "p1" and d.take.lane == 2 and d.take.k == 1, "a take pick")
assert(phonedaw.parse({ want = true }).want and not phonedaw.parse({ want = true }).take, "a want alone")
for n, bad in ipairs({ { take = { lane = 0, idx = 0, p = 0, l = 1 } }, { take = { lane = -1, idx = 0, p = 0, l = 1, k = 0 } },
  { take = { lane = 0, idx = 0.5, p = 0, l = 1, k = 0 } }, { take = { lane = 0, idx = 0, p = 0 / 0, l = 1, k = 0 } }, { take = "x" }, "nope" }) do
  assert(phonedaw.parse(bad) == nil, "refused: #" .. n)
end
local _, why, id = phonedaw.parse({ id = "p9", take = { lane = 0 } })
assert(why and id == "p9", "a refusal keeps its id, so the phone hears why")
assert(select(3, phonedaw.parse({ id = "<img>", take = {} })) == nil, "ids are plain")

-- ---- a stand-in REAPER ------------------------------------------------------------------------------------------------------------------
local undo, fake, cc = {}, nil, 1
local function setup(f)
  fake = f
  for _, t in ipairs(f.tracks) do t.ptr = { t = t }; for _, it in ipairs(t.items) do it.active = it.active or (it.takes or {})[1] end end
end
reaper.CountTracks = function() return #fake.tracks end
reaper.GetTrack = function(_, i) return fake.tracks[i + 1].ptr end
reaper.GetTrackGUID = function(tr) return tr.t.guid end
reaper.GetMediaTrackInfo_Value = function(tr, k) if k == "B_SHOWINTCP" then return tr.t.hidden and 0 or 1 end return 0 end
reaper.GetSetMediaTrackInfo_String = function(tr, k) if k == "P_NAME" then return true, tr.t.name end return true, "" end
reaper.CountTrackMediaItems = function(tr) return #tr.t.items end
reaper.GetTrackMediaItem = function(tr, j) return tr.t.items[j + 1] end
local IV = { D_POSITION = "pos", D_LENGTH = "len" }
reaper.GetMediaItemInfo_Value = function(it, k) return it[IV[k]] or 0 end
reaper.CountTakes = function(it) return #(it.takes or {}) end
reaper.GetTake = function(it, k) return it.takes[k + 1] end
reaper.GetActiveTake = function(it) return it.active end
reaper.GetTakeName = function(tk) return tk.name end
reaper.SetActiveTake = function(tk) for _, t in ipairs(fake.tracks) do for _, it in ipairs(t.items) do for _, x in ipairs(it.takes or {}) do if x == tk then it.active = tk end end end end end
reaper.Undo_BeginBlock2 = function() undo[#undo + 1] = { open = true } end
reaper.Undo_EndBlock2 = function(_, label) undo[#undo].open, undo[#undo].label = false, label end
reaper.GetProjectStateChangeCount = function() return cc end

local function song()
  local vox = { pos = 4, len = 2, oid = "I-JAMES-1", takes = { { name = "Vox take 1" }, { name = "Vox take 2" }, { name = ("x"):rep(60) } } }
  setup({ tracks = {
    { name = "Drums", oid = "T-JAMES-1", guid = "{D}", items = { { pos = 0, len = 4, oid = "I-JAMES-2", takes = { { name = "kit" } } } } },
    { name = "Mine", ["local"] = true, guid = "{M}", items = {} },
    { name = "Hidden", oid = "T-JAMES-5", guid = "{H}", hidden = true, items = {} },
    { name = "Vox", oid = "T-CHILIO-2", guid = "{V}", items = { vox } },
  } })
  undo = {}
  return vox
end
local b = { song = "S", room = "main" }
local function as(user) return { root = "R", user = user } end
local pub = {}
local function publish(topic, t) pub[topic] = t end
local function tick(now) phonedaw.tick("P", as("James"), b, publish, now or 1000) end

-- ---- the topic: only while a phone looks; the same lanes as the Project page, takes only where there's a choice ------------------------
local vox = song()
room("open")
tick()
assert(pub.phonedaw == nil, "nobody looking: nothing built")
phonedaw.action("P", as("James"), b, { want = true })
tick()
local t = pub.phonedaw
assert(t and t.key == "S/main" and #t.lanes == 2, "the shown tracks only (not this computer's own, not hidden)")
assert(t.lanes[1].g == "{D}" and t.lanes[1].o == "T-JAMES-1" and t.lanes[2].g == "{V}" and t.lanes[2].o == "T-CHILIO-2", "each lane's GUID and oid")
assert(t.takes and t.takes["1:0"] and not t.takes["0:0"], "takes listed only for an item with more than one")
assert(t.takes["1:0"].a == 0 and #t.takes["1:0"].n == 3 and t.takes["1:0"].n[2] == "Vox take 2" and #t.takes["1:0"].n[3] == phonedaw.NAME_MAX, "the active one and the names, cut short")
pub = {}
tick(1000.1)
assert(pub.phonedaw == nil, "looked again only after LOOK_EVERY")
tick(1001)
assert(pub.phonedaw == nil, "and only when REAPER's change count moved (or FLOOR passed)")
cc = 2
tick(1001.1)
assert(pub.phonedaw, "the change count moved: looked again")
pub = {}
phonedaw.tick("P", as("James"), { song = "T", room = "main" }, publish, 1001.7)
assert(pub.phonedaw and pub.phonedaw.key == "T/main", "another project in front: looked at at once")
-- (the phone's want for the daw topic says nothing of history, so a computer's Song page showing history keeps it: lib/dawview.lua)
local dawview = require("dawview")
assert(not dawview.parse({ want = true }).nohistory and dawview.parse({ want = true, history = false }).nohistory, "only the Song page turns history off")

-- ---- picking a take: the room's rules, as an item edit on the Project page ---------------------------------------------------------------
local function pick(user, k, p)
  pub = {}
  local said = phonedaw.action("P", as(user), b, { id = "q" .. k, take = { lane = 1, idx = 0, p = p or 4, l = 2, k = k } })
  tick(1020) -- (inside the want's 30 s; the pick itself makes the next tick look again)
  return said, pub.phonedaw and pub.phonedaw.reply
end
room("open", { Chilio = { tracks = { "Vox" } } })
local said, r = pick("James", 1)
assert(r and r.id == "q1" and r.why and r.why:find("Chilio has claimed Vox") and vox.active == vox.takes[1] and #undo == 0, "someone else's claimed track: refused, nothing changed: " .. tostring(r and r.why))
assert(said:find("wasn't made"), "and the log says so")
said, r = pick("Chilio", 1)
assert(r.ok and vox.active == vox.takes[2] and #undo == 1 and not undo[1].open and undo[1].label == "StudioSync phone: pick take", "its claimant picks take 2, in one undo point")
assert(pub.phonedaw.takes["1:0"].a == 1, "and the phone sees it at once")
r = select(2, pick("Chilio", 1, 5))
assert(r.why:find("changed meanwhile"), "the phone's view is stale: refused")
r = select(2, pick("Chilio", 7))
assert(r.why:find("isn't there"), "a take that isn't there")
peers = { { user = "James", editing = { "I-JAMES-1" } } }
r = select(2, pick("Chilio", 1))
assert(r.ok and vox.active == vox.takes[2], "a bandmate editing it too: not refused, no hold (rt-merge): " .. tostring(r.why))
peers = {}
room("driver")
r = select(2, pick("Chilio", 0))
assert(r.why:find("only the driver") and vox.active == vox.takes[2], "Driver only: refused")
r = select(2, pick("James", 0))
assert(r.ok and vox.active == vox.takes[1], "the driver may")
phonedaw.action("P", as("James"), b, { id = "z", take = { lane = 9 } })
tick(1025)
assert(pub.phonedaw.reply.id == "z" and pub.phonedaw.reply.why, "a bad action still answers with why")
pub = {}
tick(1031)
assert(pub.phonedaw == nil, "the want ran out: nothing built")

-- ---- the phone page's hooks (lib/webui/*: a link check, not a browser test) ---------------------------------------------------------------
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local html, rec, js, sw, pf, webui = read("lib/webui/record.html"), read("lib/webui/record.js"), read("lib/webui/phonedaw.js"), read("lib/webui/phone-sw.js"),
  read("lib/webui/phonefile.js"), read("lib/webui.lua")
assert(html:find('src="phonedaw.js"', 1, true) and html:find('href="phonedaw.css"', 1, true) and html:find('href="sheet.css"', 1, true), "the page loads the stage 2 files")
for _, f in ipairs({ "phonedaw.js", "phonedaw.css", "sheet.css" }) do assert(sw:find("'" .. f .. "'", 1, true), "kept on the phone for offline: " .. f) end
assert(rec:find("ss-state", 1, true) and rec:find("ssPhoneOut", 1, true), "record.js hands the topics over and routes the mix through the headphone chain")
assert(pf:find("'views'", 1, true), "the phone keeps each project's view for offline")
assert(js:find("topic: 'phonedaw'", 1, true) or js:find("act('phonedaw'", 1, true), "the page asks for phonedaw")
assert(js:find("'mixer'", 1, true), "track volume and mute go through the Mixer's checked moves")
assert(webui:find("ACTIONS.phonedaw", 1, true) and webui:find('require("phonedaw").tick', 1, true), "Live sync takes its actions and ticks it")
print("ok")
