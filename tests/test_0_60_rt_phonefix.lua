-- The phone app's Project view against Live sync's real tick (rt-phonefix): record.html's own actions, as its scripts send them, through the
-- real lib/webui.lua tick, lib/dawview.lua and lib/phonedaw.lua, into a stand-in extension that keeps topics as the server does; then what
-- lib/webui/phonedaw.js needs before it draws anything (its liveView: the daw header for the song the phonerec topic names, every chunk the
-- header counts, the phonedaw lanes beside them). The stand-in REAPER answers GetMediaItemTake_Peaks as REAPER 7.86 does inside a coroutine
-- (nothing, and a buffer of junk): the look runs in one, failed at the first audio item, and the Project view said "Asking the computer for
-- the project..." for ever on the real computer while every stand-in test passed. (James, rt)
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function() end

-- ---- a stand-in project: a MIDI track and an audio track with two takes on its item ------------------------------------------------------
local tracks = {
  { name = "Keys", guid = "{G-KEYS}", items = { { pos = 2, len = 4, takes = { { name = "chords", midi = true } } } } },
  { name = "Vox", guid = "{G-VOX}", items = { { pos = 3, len = 19, takes = { { name = "take 1" }, { name = "take 2" } } } } },
}
for _, t in ipairs(tracks) do for _, it in ipairs(t.items) do it.track = t; for _, tk in ipairs(it.takes) do tk.item = it end; it.active = it.takes[#it.takes] end end
reaper.EnumProjects = function() return "P1" end
reaper.GetProjectStateChangeCount = function() return 7 end
reaper.GetProjectLength = function() return 30 end
reaper.CountTracks = function() return #tracks end
reaper.GetTrack = function(_, i) return tracks[i + 1] end
reaper.GetTrackGUID = function(tr) return tr.guid end
reaper.GetMediaTrackInfo_Value = function(_, k) return k == "B_SHOWINTCP" and 1 or 0 end
reaper.GetSetMediaTrackInfo_String = function(tr, k) return true, k == "P_NAME" and tr.name or "" end
reaper.CountTrackMediaItems = function(tr) return #tr.items end
reaper.GetTrackMediaItem = function(tr, j) return tr.items[j + 1] end
reaper.GetMediaItemInfo_Value = function(it, k) return k == "D_POSITION" and it.pos or k == "D_LENGTH" and it.len or 0 end
reaper.CountTakes = function(it) return #it.takes end
reaper.GetTake = function(it, k) return it.takes[k + 1] end
reaper.GetActiveTake = function(it) return it.active end
reaper.GetTakeName = function(tk) return tk.name end
reaper.TakeIsMIDI = function(tk) return tk.midi == true end
reaper.GetMediaItemTakeInfo_Value = function(_, k) return k == "D_PLAYRATE" and 1 or 0 end
reaper.GetMediaItemTake_Source = function(tk) return tk end
reaper.GetMediaSourceFileName = function(src) return "J:/S/" .. src.name .. ".flac" end
reaper.MIDI_GetHash = function() return true, "h" end
reaper.MIDI_CountEvts = function() return 1, 0, 0, 0 end
reaper.new_array = function(n) local a = { d = {} }; a.table = function() local t = {}; for i = 1, n do t[i] = a.d[i] or 0 end; return t end; return a end
local peaks_in_co = 0
reaper.GetMediaItemTake_Peaks = function(_, _, _, _, n, _, buf)
  if select(2, coroutine.running()) == false then peaks_in_co = peaks_in_co + 1; for i = 1, n * 2 do buf.d[i] = 9e281 end return end -- (REAPER 7.86, measured)
  for i = 1, n do buf.d[i] = 0.5; buf.d[n + i] = -0.5 end
  return n
end
reaper.EnumProjectMarkers3 = function() return 0 end
reaper.TimeMap_GetMeasureInfo = function(_, m) return m * 2, 0, 0, 4, 4 end
reaper.CountTempoTimeSigMarkers = function() return 0 end
reaper.TimeMap_GetTimeSigAtTime = function() return 4, 4, 120 end
reaper.GetSetProjectGrid = function() return 0, 0.25 end
reaper.GetPlayStateEx = function() return 0 end
reaper.GetCursorPositionEx = function() return 0 end
reaper.GetSet_ArrangeView2 = function() return 0, 40 end
reaper.Master_GetPlayRate = function() return 1 end

-- ---- a stand-in extension: topics kept as the server keeps them, the page's actions queued, a page's event stream open ----------------
local topics, actions = {}, {}
reaper.StudioSync_WebUIStart = function() return 1 end
reaper.StudioSync_WebUIPublish = function(topic, json) topics[topic] = band.json_decode(json) end
reaper.StudioSync_WebUIPoll = function() return table.remove(actions, 1) or "" end
reaper.StudioSync_WebUIStatus = function() return '{"listening":true,"port":47281,"token":"ab","clients":1,"served":3}' end

-- ---- what isn't the Project view's: stand-ins (each module's own tests cover it) --------------------------------------------------------
local function quiet(t) return setmetatable(t or {}, { __index = function() return function() end end }) end
for _, m in ipairs({ "page_chat", "webcall", "ai", "livekeys", "webpages", "songsheet", "webmixer", "webhistory", "webhome", "invite", "dawmidi",
  "video", "follow", "live", "webdraw" }) do package.loaded[m] = quiet() end -- (webdraw: the drawing layer, tests/test_0_60_rt_draw.lua)
package.loaded.page_chat.read = function() return {} end
package.loaded.webcall.model = function() return {} end
package.loaded.follow.words_by_user = function() return {} end
package.loaded.groups = quiet({ sonobus_secret = function() return "sek" end, may_manage = function() return false end })
package.loaded.direct = { port = function() return 47281 end }
package.loaded.presence = quiet({ peers = function() return {} end })
package.loaded.people = { colours = function() return {} end }
package.loaded.sync = { authority = function() return function() end, { mode = "open", driver = "James", tracks = {}, regions = {}, times = {} } end }
package.loaded.mirror = quiet({ local_track = function() return false end, track_oid = function(tr) return "T-" .. tr.name end, item_oid = function() return "" end })
local rec_want = -math.huge -- (the Record page's own topic, as lib/phonerec.lua publishes it: song = b.song, while a Record page is open)
package.loaded.phonerec = quiet({
  action = function(_, _, _, a) if a.want then rec_want = clock + 30 end end,
  tick = function(_, cfg, b, publish, now) if now < rec_want then publish("phonerec", { me = cfg.user, song = b.song, pos = 0 }) end end,
})
local webui = require("webui")

-- record.html's actions, word for word as record.js and phonedaw.js send them
local js, rjs = band.read("lib/webui/phonedaw.js"), band.read("lib/webui/record.js")
assert(js:find("act('daw', { want: true })", 1, true) and js:find("act('phonedaw', { want: true })", 1, true) and rjs:find("post({ want: true })", 1, true),
  "the page still asks with these")
assert(js:find("!v || !v.head", 1, true), "and still waits for the daw header")
local cfg, b = { root = "R", user = "James" }, { song = "Cross Test", room = "main" }
local function phone_asks() for _, a in ipairs({ '{"topic":"phonerec","want":true}', '{"topic":"daw","want":true}', '{"topic":"phonedaw","want":true}' }) do actions[#actions + 1] = a end end

-- What phonedaw.js's liveView makes of the topics (the same tests, in Lua): the view it draws, or nil while it says "Asking the computer..."
local function keySong(k) return type(k) == "string" and k:find("/", 1, true) and k:match("^(.*)/[^/]*$") or nil end
local function live_view()
  local song = topics.phonerec and topics.phonerec.song -- (front(): online and the phonerec topic's song)
  if not song then return nil, "no phonerec topic" end
  local head = topics.daw and keySong(topics.daw.key) == song and topics.daw or nil
  if not head then return nil, "no daw header for " .. song end
  local chunks = {}
  for k = 0, (head.chunks or 0) - 1 do
    local c = topics["dawc" .. k]
    if not (c and c.key == head.key and not c.gone) then return nil, "chunk " .. k .. " missing" end
    chunks[#chunks + 1] = c
  end
  local pd = topics.phonedaw and keySong(topics.phonedaw.key) == song and topics.phonedaw or nil
  return { head = head, chunks = chunks, pd = pd }
end

phone_asks()
webui.tick("P1", cfg, b, {})
for _ = 1, 3 do clock = clock + 0.5; webui.tick("P1", cfg, b, {}) end
local v, why = live_view()
assert(v, "the Project view has its project after a couple of seconds: " .. tostring(why))
assert(peaks_in_co == 0, "no peaks asked for inside the look's coroutine")
assert(#v.head.tracks == 2 and v.head.tracks[2].n == "Vox", "both tracks in the header")
local vox = v.chunks[1].tr[2][1]
assert(type(vox.k) == "string" and #vox.k > 0 and not vox.k:find("_", 1, true), "the audio item's waveform is REAPER's peaks: " .. tostring(vox.k))
assert(v.chunks[1].tr[1][1].x == 1, "the MIDI item drawn as MIDI")
assert(v.pd and #v.pd.lanes == #v.head.tracks and v.pd.lanes[2].g == "{G-VOX}", "phonedaw's lanes beside the daw tracks, in order")
assert(v.pd.takes and v.pd.takes["1:0"] and v.pd.takes["1:0"].a == 1 and #v.pd.takes["1:0"].n == 2, "the two-take item's takes, the second playing")

-- Every 10 s the page says it's still looking; the view stays, and the header follows a new project in front
for _ = 1, 4 do clock = clock + 10; phone_asks(); webui.tick("P1", cfg, b, {}) end
assert(live_view(), "still there after 40 s of asking")
b = { song = "Other", room = "main" }
phone_asks()
for _ = 1, 3 do clock = clock + 0.5; webui.tick("P1", cfg, b, {}) end
v, why = live_view()
assert(v and v.head.key == "Other/main" and v.pd.key == "Other/main", "another song in front: its own header and lanes: " .. tostring(why))
print("ok")
