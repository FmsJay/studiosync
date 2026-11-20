-- Record from a phone (lib/phonerec.lua): the secure link and its setup, what a page may send, the play readings and where a take goes
-- (placement maths), the item's trim and the nudge, the take's name (recap's naming), and a take put in through a stand-in REAPER: placed
-- and named, refused on someone else's track, a bad upload refused, nudged. The server's half (upload, clock, proxy): tests/webui_test.cpp.
package.path = "lib/?.lua;" .. package.path
local clock, link = 1000, 1.7e9
local ext = {}
local tracks = { { guid = "{AAAA-1}", name = "Vox", items = {} }, { guid = "{BBBB-2}", name = "Gtr", items = {} } }
local saved, written = {}, nil
local TMP = (os.getenv("TEMP") or "/tmp"):gsub("\\", "/")
local function item_guid(it) return it.guid end
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return TMP end,
  CountTracks = function() return #tracks end,
  GetTrack = function(_, i) return tracks[i + 1] end,
  GetTrackGUID = function(tr) return tr.guid end,
  GetTrackName = function(tr) return true, tr.name end,
  GetCursorPositionEx = function() return 10 end,
  GetPlayStateEx = function() return 1 end,
  GetPlayPositionEx = function() return 0 end,
  Master_GetPlayRate = function() return 1 end,
  format_timestr_pos = function(p) return string.format("%d.1.00", math.floor(p / 2) + 1) end,
  GetProjectPathEx = function() return TMP end,
  RecursiveCreateDirectory = function() return 1 end,
  StudioSync_DirectNow = function() return link end,
  StudioSync_WebUISaveUpload = function(id, path)
    if not saved[id] then return 0 end
    local f = io.open(path, "wb"); f:write(saved[id]); f:close()
    written = path
    local n = #saved[id]
    saved[id] = nil -- (let go once saved, as the extension does)
    return n
  end,
  PCM_Source_CreateFromFile = function(p) return { file = p, len = 30 } end,
  GetMediaSourceLength = function(src) return src.len end,
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
  GetSetMediaItemInfo_String = function(it, k) return true, item_guid(it) end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, j) return tr.items[j + 1] end,
  CountTakes = function(it) return #it.takes end,
  GetTake = function(it, k) return it.takes[k + 1] end,
  GetActiveTake = function(it) return it.takes[1] end,
  GetRegionOrMarkerInfo_Value = function() return -1 end,
  EnumProjectMarkers3 = function(_, i)
    local m = ({ { true, 0, 8, "Verse" }, { true, 8, 16, "Chorus" } })[i + 1]
    if not m then return 0 end
    return i + 1, m[1], m[2], m[3], m[4], i, 0
  end,
}, { __index = function() return function() return "" end end })

local band = require("band")
band.session_path = function() return TMP .. "/no-such-session.json" end
local owner = { Gtr = "Bo" }
package.loaded.sync = { authority = function()
  return function(user, track) return owner[track] == nil or owner[track] == user end, { mode = "claims", driver = "James", owner_of = function(t) return owner[t] end }
end }
package.loaded.groups = { smart_take_names = function() return true end, may_manage = function() return false end, smart_lane_names = function() return false end }
package.loaded.services = { my_tailscale_name = function() return "james-main.tail99.ts.net" end, ts_exec = function(args) return "0\n" .. args end }
package.loaded.direct = { port = function() return 47281 end }
package.loaded.webui = { status = function() return { token = "abc123" } end }
local gone = {}
package.loaded.together = { now = function() return os.time() end, bars_before = function() return 2 end, go = function(_, _, _, ev) gone[#gone + 1] = ev end }
package.loaded.dawview = { may_transport = function(mode, user, driver) return user == driver end }
local pr = require("phonerec")

-- The secure link, and its setup
assert(pr.secure_url("james-main.tail99.ts.net", "0a1b", 8443) == "https://james-main.tail99.ts.net:8443/record.html?t=0a1b", "the https Record page")
for _, bad in ipairs({ { nil, "ab" }, { "a b", "ab" }, { "x/y", "ab" }, { "pc.ts.net", "" }, { "pc.ts.net", "zz" } }) do
  assert(pr.secure_url(bad[1], bad[2]) == nil, "no link from a bad name or token")
end
assert(pr.serve_args(47281, 8443) == "serve --bg --https=8443 http://127.0.0.1:47281", "tailscale serve: its own port, to the loopback server")

-- What a page may send
assert(pr.clean_name("  Bo \t Diddley ") == "Bo Diddley" and pr.clean_name("Zoë") == "Zoë" and pr.clean_name("O'Neil-2") == "O'Neil-2", "names kept")
assert(pr.clean_name("<b>x</b>") == "bxb" and pr.clean_name("a\1b") == "ab", "markup and control characters dropped")
assert(pr.clean_name("") == nil and pr.clean_name("   ") == nil and pr.clean_name(("x"):rep(33)) == nil and pr.clean_name("\255") == nil and pr.clean_name(5) == nil,
  "empty, too long, not UTF-8: nothing")
assert(pr.magic_ok("wav", "RIFF\0\0\0\0WAVE") and not pr.magic_ok("wav", "RIFF\0\0\0\0AVI ") and pr.magic_ok("webm", "\26\69\223\163xx")
  and pr.magic_ok("ogg", "OggS") and pr.magic_ok("mp4", "\0\0\0\24ftypM4A ") and not pr.magic_ok("exe", "MZ"), "a file is what it says")
local d = pr.parse({ want = true, start = { track = "{AAAA-1}", bars = 9 }, nudge = 5,
  take = { id = "00ff", track = "{AAAA-1}", t0 = link, len = 12.5, kind = "wav", name = " Bo ", err = 17.4 } })
assert(d.want and d.start.bars == 4 and d.nudge == 5 and d.take.name == "Bo" and d.take.err == 17 and d.take.kind == "wav", "an action, checked (count-in at most 4 bars)")
for _, bad in ipairs({ { id = "zz", track = "{A}", t0 = 1, len = 1, kind = "wav" }, { id = "aa", track = "Vox", t0 = 1, len = 1, kind = "wav" },
  { id = "aa", track = "{A}", t0 = 1, len = 1, kind = "exe" }, { id = "aa", track = "{A}", t0 = 0 / 0, len = 1, kind = "wav" },
  { id = "aa", track = "{A}", t0 = 1, len = -1, kind = "wav" }, { id = ("a"):rep(33), track = "{A}", t0 = 1, len = 1, kind = "wav" } }) do
  assert(pr.parse({ take = bad }).take == nil, "a bad take refused")
end
assert(pr.parse({ nudge = 9999 }).nudge == nil and pr.parse({ nudge = 0 }).nudge == nil and pr.parse({ start = { track = "../x" } }).start == nil and pr.parse("x") == nil,
  "nudges too big, nothing, bad tracks: refused")

-- Play readings: stretches
local L = {}
pr.add_reading(L, 100, 5, 1, true); pr.add_reading(L, 100.03, 5.03, 1, true); pr.add_reading(L, 100.06, 5.06, 1, true)
assert(#L == 3 and L[1].seg == 1 and L[3].seg == 1, "one stretch while it plays on")
pr.add_reading(L, 100.09, 20, 1, true)
assert(L[4].seg == 2, "a jump starts another")
pr.add_reading(L, 100.12, 20.03, 1, false); pr.add_reading(L, 101, 20.03, 1, true)
assert(#L == 5 and L[5].seg == 3, "stopped and started again: another (the stopped reading kept nothing)")
pr.add_reading(L, 101.03, 20.06, 1.5, true)
assert(L[6].seg == 4, "another rate: another")
pr.prune(L, 101.03, 0.5)
assert(#L == 2 and L[1].t == 101 and L[2] == L[#L], "older readings let go")

-- Where a take goes: the song plays from 8 s (link time 200) with 30 ms ticks, a little jitter, one late tick
L = {}
for i = 0, 400 do
  local t = 200 + i * 0.03
  local jitter = (i % 3 - 1) * 0.004
  pr.add_reading(L, t + jitter, 8 + i * 0.03, 1, true)
end
L[50].pos = L[50].pos - 0.05 -- (a reading taken late in its tick: within JUMP, the same stretch)
local p = pr.place(L, 198.5, 14) -- (the phone started 1.5 s before the song)
assert(p and math.abs(p.at - 6.5) < 0.002 and p.from == 8 and math.abs(p.to - 20) < 1e-9, "the song's position at the first sample, by the median: " .. tostring(p and p.at))
local plan = pr.item_plan(p, 14)
assert(math.abs(plan.pos - 8) < 1e-9 and math.abs(plan.offs - 1.5) < 0.002 and math.abs(plan.len - 12) < 0.002, "the item: from where the song started, the pre-roll inside it")
p = pr.place(L, 205, 30)
plan = pr.item_plan(p, 30)
assert(math.abs(plan.pos - 13) < 0.002 and plan.offs < 0.002 and math.abs(plan.len - 7) < 0.002, "a take that outlasts the song: the item ends where it stopped")
assert(pr.place(L, 300, 5) == nil and select(2, pr.place(L, 300, 5)):find("wasn't playing"), "nothing played while it recorded: nowhere, and why")
local early = {}
for i = 0, 50 do pr.add_reading(early, 50 + i * 0.03, i * 0.03, 1, true) end
plan = pr.item_plan(pr.place(early, 49, 3), 3)
assert(plan.pos == 0 and math.abs(plan.offs - 1) < 0.002, "never before the song's start")
assert(pr.item_plan({ at = 0, from = 5, to = 6 }, 2) == nil, "a take that missed the stretch: no item")

-- The nudge
local np, no, nl = pr.nudge(8, 1.5, 12, 20)
assert(np == 8 and math.abs(no - 1.48) < 1e-9 and nl == 12, "later: the audio moves, the item stays")
np, no, nl = pr.nudge(8, 0.01, 12, 30)
assert(math.abs(np - 8.02) < 1e-9 and no == 0 and math.abs(nl - 11.98) < 1e-9, "later past its start: the item starts where its audio does")
np, no = pr.nudge(8, 0, 12, -10)
assert(np == 8 and math.abs(no - 0.01) < 1e-9, "earlier")

-- The take's name (recap's own naming, read only)
local marks = { { region = true, pos = 0, ["end"] = 8, name = "Verse" }, { region = true, pos = 8, ["end"] = 16, name = "Chorus" } }
assert(pr.take_name(marks, 8, "Bo", { "Chorus - Bo - take 1", "Chorus - James - take 4" }, true) == "Chorus - Bo - take 2", "smart: section, singer, the next number")
assert(pr.take_name(marks, 20, "Bo", {}, true) == "Bo - take 1" and pr.take_name(marks, 8, "Bo", {}, false) == "Bo - phone take", "no section; smart names off")

-- Through a stand-in REAPER
local cfg, b = { user = "James", root = TMP }, { song = "Song", room = "main" }
local pub = {}
local function publish(topic, t) pub[topic] = t end
assert(pr.action("P", cfg, b, { want = true }) == nil, "a Record page open")
for i = 0, 300 do -- this computer plays from 8 s
  link = 1.7e9 + i * 0.03
  reaper.GetPlayPositionEx = function() return 8 + i * 0.03 end
  clock = clock + 0.03
  pr.tick("P", cfg, b, publish, clock)
end
local s = pub.phonerec
assert(s and s.me == "James" and s.playing and #s.tracks == 2 and s.tracks[1].may and not s.tracks[2].may and s.tracks[2].why == "Bo's"
  and s.secure == "https://james-main.tail99.ts.net:8443/record.html?t=abc123" and math.abs(s.at - link) < 0.6, "the page's state: tracks with who may, the secure link")
saved.aa11 = "RIFF\0\0\0\0WAVEfmt "
local said = pr.action("P", cfg, b, { take = { id = "aa11", track = "{AAAA-1}", t0 = 1.7e9 - 1, len = 5, kind = "wav", name = "Bo", err = 15 } })
local it = tracks[1].items[1]
assert(it and math.abs(it.info.D_POSITION - 8) < 0.002 and math.abs(it.takes[1].info.D_STARTOFFS - 1) < 0.002 and math.abs(it.info.D_LENGTH - 9) < 0.002,
  "the take placed: at the song's start here, its pre-roll inside, to where the song stopped (the file's own 30 s, not the page's word): " .. tostring(said))
assert(it.takes[1].name == "Chorus - Bo - take 1" and said:find("Chorus %- Bo %- take 1: on Vox at bar 5") and said:find("about 15 ms"), "named and said: " .. said)
assert(written and written:find("Song phone Bo ") and written:find("%.wav$"), "saved beside the project's recordings")
os.remove(written)
assert(pr.action("P", cfg, b, { take = { id = "aa11", track = "{AAAA-1}", t0 = 1.7e9, len = 5, kind = "wav" } }):find("isn't here any more"), "an upload used once")
saved.bb22 = "RIFF\0\0\0\0WAVE"
assert(pr.action("P", cfg, b, { take = { id = "bb22", track = "{BBBB-2}", t0 = 1.7e9, len = 5, kind = "wav" } }):find("Gtr is Bo's") and #tracks[2].items == 0,
  "someone else's track: not put in")
saved.cc33 = "MZ\144\0not a wav"
written = nil
assert(pr.action("P", cfg, b, { take = { id = "cc33", track = "{AAAA-1}", t0 = 1.7e9, len = 5, kind = "wav" } }):find("wasn't a wav") and #tracks[1].items == 1,
  "an upload that isn't what it says: refused")
local f = io.open(written, "rb"); assert(f == nil, "and its file removed"); if f then f:close() end
said = pr.action("P", cfg, b, { nudge = 20 })
assert(math.abs(it.takes[1].info.D_STARTOFFS - 0.98) < 0.002 and said:find("%+20 ms"), "nudged later: " .. said)
assert(pr.action("P", cfg, b, { nudge = -5 }):find("%+15 ms in all"), "and back a little")

-- Starting and stopping: James drives, so it's Play together; the phone's stop stops only a start it made
reaper.GetPlayStateEx = function() return 0 end
said = pr.action("P", cfg, b, { start = { track = "{AAAA-1}", bars = 1 } })
assert(gone[1] and gone[1].type == "start" and gone[1].pos == 10 and gone[1].countin == 2 and gone[1].click and said:find("Play together"), "Play together with a count-in")
assert(pr.action("P", cfg, b, { stop = true }) and gone[2].type == "stop", "its stop: Stop together")
assert(pr.action("P", cfg, b, { stop = true }) == nil and #gone == 2, "a stop with nothing it started: nothing")
cfg.user = "Bo" -- (not the driver: this computer alone)
said = pr.action("P", cfg, b, { start = { track = "{AAAA-1}", bars = 1 } })
assert(#gone == 2 and ext[band.SECTION .. "/transport P"]:find('"type":"start"') and said:find("here only"), "not the driver: played here only")
ext[band.SECTION .. "/together_at P"] = tostring(os.time() + 3)
assert(pr.action("P", cfg, b, { start = { track = "{AAAA-1}", bars = 1 } }):find("joining"), "a start already coming: joined")
assert(pr.action("P", cfg, b, { setup = true }):find("set up"), "the secure link's setup")
reaper.StudioSync_WebUISaveUpload = nil
setmetatable(reaper, nil) -- (no stand-in for what isn't there)
assert(pr.action("P", cfg, b, { take = { id = "dd", track = "{AAAA-1}", t0 = 1, len = 1, kind = "wav" } }):find("older"), "an older extension: says so")
print("ok phonerec")
