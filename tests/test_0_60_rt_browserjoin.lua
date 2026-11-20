-- A guest who joins from a browser (lib/guestweb.lua; rt-browserjoin): the guest link, what a host page and a guest may send, the guest link's
-- lifecycle through a stand-in extension (owner/admin only, rate limits, single list without codes, run out, gone after a REAPER restart,
-- kicked, left), each guest's topic and the host's, and a guest's take through a stand-in REAPER: their own track made, placed by the play
-- readings at the link-clock moment they heard, once only, refused for another guest's upload, another project in front, the room's rules.
-- Plus a link check of the pages. The server's half (sessions, the WebSocket bridge, uploads, the event stream): tests/webui_test.cpp.
package.path = "lib/?.lua;" .. package.path
local clock, link = 1000, 1.7e9
local ext, guests_set, gains = {}, {}, {}
local tracks = { { guid = "{AAAA-1}", name = "Vox", items = {} } }
local saved, written = {}, nil
local TMP = (os.getenv("TEMP") or "/tmp"):gsub("\\", "/")
local ext_status = { guests = {} }
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  genGuid = function() return string.format("{%08X-1234-5678-9ABC-%012X}", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff)) end,
  CountTracks = function() return #tracks end,
  GetTrack = function(_, i) return tracks[i + 1] end,
  GetTrackGUID = function(tr) return tr.guid end,
  GetTrackName = function(tr) return true, tr.name end,
  InsertTrackAtIndex = function(i) table.insert(tracks, i + 1, { guid = "{NEW-" .. (#tracks + 1) .. "}", name = "", items = {} }) end,
  GetSetMediaTrackInfo_String = function(tr, k, v, set) if set and k == "P_NAME" then tr.name = v end; return true, tr.name end,
  GetCursorPositionEx = function() return 8 end,
  GetPlayStateEx = function() return 1 end,
  GetPlayPositionEx = function() return 8 end,
  Master_GetPlayRate = function() return 1 end,
  GetOutputLatency = function() return 0.0123 end,
  GetAudioDeviceInfo = function(k) if k == "SRATE" then return true, "48000" end; return false, "" end,
  format_timestr_pos = function(p) return string.format("%d.1.00", math.floor(p / 2) + 1) end,
  GetProjectPathEx = function() return TMP end,
  RecursiveCreateDirectory = function() return 1 end,
  StudioSync_DirectNow = function() return link end,
  StudioSync_WebUIGuest = function(gid, code, cs, ss) guests_set[#guests_set + 1] = { gid = gid, code = code, cs = cs, ss = ss }; return 1 end,
  StudioSync_WebUIGuestGain = function(gid, v) gains[gid] = v; return 1 end,
  StudioSync_WebUIStatus = function() return "" end,
  StudioSync_WebUISaveUpload = function(id, path)
    if not saved[id] then return 0 end
    local f = io.open(path, "wb"); f:write(saved[id]); f:close()
    written = path
    local n = #saved[id]
    saved[id] = nil
    return n
  end,
  PCM_Source_CreateFromFile = function(p) return { file = p, len = 30 } end,
  GetMediaSourceLength = function(src) return src.len end,
  GetMediaSourceSampleRate = function() return 48000 end,
  PCM_Source_Destroy = function() end,
  Undo_BeginBlock2 = function() end, Undo_EndBlock2 = function() end, UpdateArrange = function() end,
  AddMediaItemToTrack = function(tr) local it = { guid = "{IT-" .. (#tr.items + 1) .. "}", info = {}, takes = {}, tr = tr }; tr.items[#tr.items + 1] = it; return it end,
  AddTakeToMediaItem = function(it) local tk = { info = {}, name = "" }; it.takes[#it.takes + 1] = tk; return tk end,
  SetMediaItemTake_Source = function(tk, src) tk.src = src end,
  SetMediaItemInfo_Value = function(it, k, v) it.info[k] = v end,
  GetMediaItemInfo_Value = function(it, k) return it.info[k] or 0 end,
  SetMediaItemTakeInfo_Value = function(tk, k, v) tk.info[k] = v end,
  GetMediaItemTakeInfo_Value = function(tk, k) return tk.info[k] or 0 end,
  GetSetMediaItemTakeInfo_String = function(tk, k, v, set) if set then tk.name = v end; return true, tk.name end,
  GetSetMediaItemInfo_String = function(it) return true, it.guid end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, j) return tr.items[j + 1] end,
  CountTakes = function(it) return #it.takes end,
  GetTake = function(it, k) return it.takes[k + 1] end,
  GetActiveTake = function(it) return it.takes[1] end,
  EnumProjectMarkers3 = function() return 0 end,
}, { __index = function() return function() return "" end end })

local band = require("band")
local logged = {}
band.log = function(s) logged[#logged + 1] = s end
band.session_path = function() return TMP .. "/no-such-session.json" end
local real_time, toff = os.time, 0
os.time = function(t) if t then return real_time(t) end return real_time() + toff end
local manage, refuse_track = true, {}
package.loaded.groups = { may_manage = function() return manage end, smart_take_names = function() return false end, smart_lane_names = function() return false end }
package.loaded.sync = { authority = function()
  return function(user, track) return not refuse_track[track] end, { mode = "claims", driver = "James", owner_of = function() return nil end }
end }
local tsname = "james-main.tail99.ts.net."
package.loaded.services = { my_tailscale_name = function() return tsname end, tailscale_exe = function() return nil end }
package.loaded.direct = { port = function() return 47281 end }
package.loaded.webui = { status = function() return ext_status end }
package.loaded.recap = { names_on = function() return false end, section_at = function() return nil end, smart_name = function(_, s) return s end, next_n = function() return 1 end }
local gw = require("guestweb")
local pr = require("phonerec")

-- ---- pure ----
assert(gw.link("pc.tail9.ts.net.", "0a1b2c", 8443) == "https://pc.tail9.ts.net:8443/guest.html?g=0a1b2c", "the guest link: the secure address, the trailing dot gone")
assert(gw.link(nil, "ab") == nil and gw.link("a b", "ab") == nil and gw.link("x/y", "ab") == nil and gw.link("pc", "zz") == nil and gw.link("pc", "") == nil,
  "no link from a bad name or code")
local h = gw.parse_host({ make = { name = " <b>Bo</b> ", minutes = 99999 }, kick = "0123456789abcdef", gain = { gid = "0123456789abcdef", v = 9 } })
assert(h.make.name == "bBob" and h.make.minutes == nil and h.kick == "0123456789abcdef" and h.gain == nil, "a host's action: the name cleaned, out-of-range times and levels dropped")
assert(gw.parse_host({ make = { name = "" } }) == nil and gw.parse_host({ kick = "../x" }) == nil and gw.parse_host("x") == nil, "nothing usable: nothing")
local G = "0123456789abcdef"
local g1 = gw.parse_guest(G, { take = { id = G .. "00112233aabbccdd", t0 = link, len = 12.5, err = 7.6, cid = "ab12", title = "Lead" } })
assert(g1 and g1.take.len == 12.5 and g1.take.err == 8 and g1.take.cid == "ab12" and g1.take.title == "Lead", "a guest's take, checked")
for _, bad in ipairs({ { id = "ffffffffffffffff00112233aabbccdd", t0 = link, len = 1 }, { id = G, t0 = link, len = 1 }, { id = G .. "00112233aabbccdd", t0 = 0 / 0, len = 1 },
  { id = G .. "00112233aabbccdd", t0 = link, len = 0 }, { id = G .. "00112233aabbccdd", t0 = link, len = 99999 }, { id = G .. "00112233aabbccdZ", t0 = link, len = 1 } }) do
  assert(gw.parse_guest(G, { take = bad }) == nil, "refused: another guest's upload, a short id, a bad time or length")
end
assert(gw.parse_guest("nothex", { leave = true }) == nil and gw.parse_guest(G, { make = { name = "x" }, kick = G }) == nil and gw.parse_guest(G, { leave = true }).leave,
  "a guest can leave; a host's words from a guest are nothing")
assert(#gw.alive({ { gid = G, ends = 50 }, { gid = "x", ends = 500 }, { gid = "fedcba9876543210", ends = 500 } }, 100, nil) == 1, "run out and malformed left out")
assert(#gw.alive({ { gid = G, ends = 500 } }, 100, {}) == 0 and #gw.alive({ { gid = G, ends = 500 } }, 100, { [G] = {} }) == 1, "gone from the extension: left out")
assert(gw.may_make({}, gw.MAX, 0) == false and select(2, gw.may_make({ 100 }, 0, 102)):find("every") and gw.may_make({ 100 }, 0, 106), "the gap and the most guests")
local many = {}
for i = 1, gw.MAKE_HOUR do many[i] = 100 + i * 10 end
assert(gw.may_make(many, 0, 100 + gw.MAKE_HOUR * 10 + 10) == false, "links an hour")

-- ---- the lifecycle ----
local cfg, b = { user = "James", root = TMP }, { song = "Song", room = "main" }
local pub = {}
local function publish(topic, t) pub[topic] = t end
manage = false
assert(gw.action("P", cfg, b, { make = { name = "Bo" } }):find("owner or an admin") and #guests_set == 0, "a member can't make a guest link")
manage = true
local said = gw.action("P", cfg, b, { make = { name = "Bo", minutes = 60 } })
assert(said:find("Bo %(Song, main%)") and #guests_set == 1, "the owner makes one: " .. tostring(said))
local gs = guests_set[1]
assert(#gs.gid == 16 and gs.gid:match("^%x+$") and #gs.code == 24 and gs.code:match("^%x+$") and gs.cs == gw.CODE_LIFE and gs.ss == 3600,
  "the extension gets a gid, a 96-bit code, its 30 minutes and the session's hour")
local kept = reaper.GetExtState(band.SECTION, gw.KEY)
assert(kept:find(gs.gid) and not kept:find(gs.code) and kept:find('"song":"Song"'), "the guest kept (never the code)")
assert(gw.action("P", cfg, b, { make = { name = "Cy" } }):find("every 5 s") and #guests_set == 1, "another within 5 s: refused")
ext_status = { guests = { [gs.gid] = { redeemed = false, on = true } } }
clock = clock + 1
gw.tick("P", cfg, b, publish, clock)
local host = pub.guestweb
assert(host.may and #host.guests == 1 and host.guests[1].name == "Bo" and host.guests[1].link == "https://james-main.tail99.ts.net:8443/guest.html?g=" .. gs.code and
  not host.guests[1].joined, "the host's topic: the guest and their link, waiting")
local gt = pub["guest-" .. gs.gid]
assert(gt and gt.name == "Bo" and gt.song == "Song" and gt.here and gt.playing and gt.pos == 8 and gt.at == link and gt.outlat == 0.0123 and gt.srate == 48000 and gt.host == "James",
  "the guest's topic: their name, where the song is on the link clock, REAPER's output latency and rate")
local allowed = { name = 1, song = 1, room = 1, here = 1, host = 1, ends = 1, playing = 1, rec = 1, pos = 1, at = 1, rate = 1, bar = 1, outlat = 1, srate = 1, said = 1, said_at = 1 }
for k in pairs(gt) do assert(allowed[k], "the guest's topic carries nothing else: " .. k) end
ext_status = { guests = { [gs.gid] = { redeemed = true, on = true, live = true, peak = 0.5 } } }
clock = clock + 1
gw.tick("P", cfg, b, publish, clock)
assert(pub.guestweb.guests[1].joined and pub.guestweb.guests[1].live and pub.guestweb.guests[1].peak == 0.5 and pub.guestweb.guests[1].link == nil,
  "used: live, their level, and the link isn't shown again")
gw.action("P", cfg, b, { gain = { gid = gs.gid, v = 0.5 } })
assert(gains[gs.gid] == 0.5 and reaper.GetExtState(band.SECTION, gw.KEY):find('"gain":0.5'), "the host's volume for them")

-- ---- a take ----
-- the session plays from 8 s, readings every 30 ms (the guest is live)
for i = 0, 300 do
  link = 1.7e9 + i * 0.03
  reaper.GetPlayPositionEx = function() return 8 + i * 0.03 end
  clock = clock + 0.03
  gw.tick("P", cfg, b, publish, clock)
end
local id = gs.gid .. "00112233aabbccdd"
saved[id] = "RIFF\0\0\0\0WAVE" .. ("\0"):rep(400)
said = gw.action("P", cfg, b, { topic = "guestweb", gid = gs.gid, a = { take = { id = id, t0 = 1.7e9 - 1, len = 5, err = 8, cid = "c1" } } })
local gtrack = tracks[2]
assert(gtrack and gtrack.name == "Bo (guest)", "their own track made: " .. tostring(said))
local it = gtrack.items[1]
assert(it and math.abs(it.info.D_POSITION - 8) < 0.002 and math.abs(it.takes[1].info.D_STARTOFFS - 1) < 0.002, "placed where the song was when they heard it: " .. tostring(said))
assert(said:find("guest") and not said:find("phone's") and pub["guest-" .. gs.gid] and logged, "said in the log")
clock = clock + 0.2
gw.tick("P", cfg, b, publish, clock)
assert(pub["guest-" .. gs.gid].said:find("on Bo %(guest%)"), "and told to the guest: " .. tostring(pub["guest-" .. gs.gid].said))
os.remove(written); os.remove((written:gsub("%.wav$", ".json")))
clock = clock + 5
assert(gw.action("P", cfg, b, { gid = gs.gid, a = { take = { id = id, t0 = 1.7e9, len = 5, cid = "c1" } } }):find("already in") and #gtrack.items == 1, "the same take again: once only")
assert(gw.action("P", cfg, b, { gid = gs.gid, a = { take = { id = "ffffffffffffffff00112233aabbccdd", t0 = 1.7e9, len = 5 } } }) == nil, "another guest's upload id: nothing")
clock = clock + 5
saved[gs.gid .. "11112233aabbccdd"] = "RIFF\0\0\0\0WAVE" .. ("\0"):rep(400)
gw.action("P", cfg, b, { gid = gs.gid, a = { take = { id = gs.gid .. "11112233aabbccdd", t0 = 1.7e9, len = 5, cid = "c2" } } })
assert(tostring(gw.action("P", cfg, b, { gid = gs.gid, a = { take = { id = gs.gid .. "11112233aabbccdd", t0 = 1.7e9, len = 5, cid = "c3" } } })):find("one take every"),
  "takes paced: one every few seconds per guest")
clock = clock + 5
local b2 = { song = "Other", room = "main" }
gw.action("P", cfg, b2, { gid = gs.gid, a = { take = { id = gs.gid .. "22112233aabbccdd", t0 = 1.7e9, len = 5, cid = "c4" } } })
gw.tick("P", cfg, b2, publish, clock + 1)
assert(pub["guest-" .. gs.gid].said:find("another project"), "another project in front: the take waits, said to the guest")
assert(not pub["guest-" .. gs.gid].here and pub["guest-" .. gs.gid].pos == nil, "and the guest isn't told where another project is")
clock = clock + 5
refuse_track["Cy (guest)"] = true
toff = toff + 10
assert(gw.action("P", cfg, b, { make = { name = "Cy" } }), "a second guest")
local cy = guests_set[#guests_set].gid
ext_status = { guests = { [gs.gid] = { redeemed = true, on = true, live = true }, [cy] = { redeemed = true, on = true } } }
saved[cy .. "00112233aabbccdd"] = "RIFF\0\0\0\0WAVE"
gw.action("P", cfg, b, { gid = cy, a = { take = { id = cy .. "00112233aabbccdd", t0 = 1.7e9, len = 5 } } })
gw.tick("P", cfg, b, publish, clock + 1)
assert(pub["guest-" .. cy].said:find("room's rules") and #tracks == 2, "the room's rules keep this user from adding their track: refused, no track made")
-- a guest's words can't make, kick or level anyone
local n = #guests_set
gw.action("P", cfg, b, { gid = cy, a = { make = { name = "Evil" }, kick = gs.gid, gain = { gid = gs.gid, v = 4 } } })
assert(#guests_set == n and gains[gs.gid] == 0.5, "a guest's action can't make, end or level guests")

-- ---- ending ----
said = gw.action("P", cfg, b, { gid = cy, a = { leave = true } })
assert(said:find("Cy left") and guests_set[#guests_set].gid == cy and guests_set[#guests_set].code == "", "a guest leaves: the extension forgets them")
said = gw.action("P", cfg, b, { kick = gs.gid })
assert(said:find("Bo ended by James") and guests_set[#guests_set].code == "" and #(band.ext_json(band.SECTION, gw.KEY) or {}) == 0, "kicked by the host: gone")
toff = toff + 10
gw.action("P", cfg, b, { make = { name = "Di", minutes = 10 } })
local di = guests_set[#guests_set].gid
ext_status = { guests = {} } -- (REAPER restarted: the extension doesn't know them)
clock = clock + 2
gw.tick("P", cfg, b, publish, clock)
assert(guests_set[#guests_set].gid == di and guests_set[#guests_set].code == "" and #pub.guestweb.guests == 0, "a guest the extension forgot: ended here too")
toff = toff + 10
gw.action("P", cfg, b, { make = { name = "Ed", minutes = 10 } })
local ed = guests_set[#guests_set].gid
ext_status = { guests = { [ed] = { redeemed = true, on = true } } }
toff = toff + 11 * 60
clock = clock + 1
gw.tick("P", cfg, b, publish, clock)
assert(guests_set[#guests_set].gid == ed and guests_set[#guests_set].code == "", "run out: ended")
assert(#logged > 0 and logged[#logged]:find("ran out"), "said in the log")

-- ---- wiring ----
package.loaded.webui = nil
local okw, webui = pcall(require, "webui")
assert(okw and webui.ACTIONS.guestweb and webui.parse_action('{"topic":"guestweb","gid":"' .. G .. '","a":{"leave":true}}') == "guestweb", "lib/webui.lua takes the topic")
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local wsrc = read("lib/webui.lua")
assert(wsrc:find('require%("guestweb"%)%.action') and wsrc:find('require%("guestweb"%)%.tick'), "and hands it on, and ticks it")
local html = read("lib/webui/guest.html")
for src in html:gmatch('src="([^"]+)"') do assert(src == "phonefile.js" or src == "guest.js", "guest.html loads only its own scripts: " .. src) end
for href in html:gmatch('href="([^"]+)"') do assert(href == "style.css" or href == "guest.css" or href == "data:,", "and its own styles (no icon to fetch): " .. href) end
assert(not html:find("<script>") and not html:find("style="), "no inline script or style (the CSP)")
local js = read("lib/webui/guest.js")
assert(not js:find("innerHTML") and not js:find("eval%(") and not js:find("https?://[%w%[]"), "guest.js: no HTML from strings, no eval, no other addresses")
for p in js:gmatch("'(api/[^']*)'") do assert(p:find("^api/guest/"), "guest.js uses only the guest API: " .. p) end
assert(js:find("echoCancellation: false") and js:find("noiseSuppression: false") and js:find("autoGainControl: false"), "the raw input asked for")
assert(read("lib/webui/guestworklet.js"):find("registerProcessor%('ss%-guest'"), "the worklet")
local idx = read("lib/webui/index.html")
assert(idx:find('guesthost.js') and idx:find('tabs.js') < idx:find('guesthost.js'), "index.html: the host's box after tabs.js")
assert(not read("lib/webui/guesthost.js"):find("innerHTML"), "guesthost.js: text only")
print("ok browserjoin")
