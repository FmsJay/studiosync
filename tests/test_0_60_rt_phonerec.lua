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
-- (the phone app's mixes: one song, two renders and a note in its mixes folder; the newest is offered)
local MIXDIR = TMP .. "/ss_phonerec_song/mixes"
if package.config:sub(1, 1) == "\\" then os.execute('mkdir "' .. MIXDIR:gsub("/", "\\") .. '" 2>nul') else os.execute("mkdir -p '" .. MIXDIR .. "'") end
do local f = assert(io.open(MIXDIR .. "/2026-11-19 mix.wav", "wb")); f:write(("x"):rep(1234)); f:close() end
band.songs = function() return { "Song" } end
band.song_dir = function(_, song) return TMP .. "/ss_phonerec_" .. song:lower() end
local mix_files = { "2026-11-18 mix.wav", "2026-11-19 mix.wav", "notes.txt" }
reaper.EnumerateFiles = function(dir, i) if dir == MIXDIR then return mix_files[i + 1] end end
local offers = {}
reaper.StudioSync_WebUIOffer = function(id, path) offers[id] = path ~= "" and path or nil; return 1 end
local owner = { Gtr = "Bo" }
package.loaded.sync = { authority = function()
  return function(user, track) return owner[track] == nil or owner[track] == user end, { mode = "claims", driver = "James", owner_of = function(t) return owner[t] end }
end }
package.loaded.groups = { smart_take_names = function() return true end, may_manage = function() return false end, smart_lane_names = function() return false end }
package.loaded.services = { my_tailscale_name = function() return "james-main.tail99.ts.net" end, ts_exec = function(args) return "0\n" .. args end }
local served = {} -- (the secure link set up by itself: Fewer things to press, James)
package.loaded.services.tailscale_exe = function() return "C:/Program Files/Tailscale/tailscale.exe" end
package.loaded.services.tailscale_certs_on = function() return true end
package.loaded.services.run_hidden = function(name, cmd) served[#served + 1] = name .. " " .. cmd end
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
assert(#served == 1 and served[1]:find('phone-serve "C:/Program Files/Tailscale/tailscale.exe" serve --bg --https=8443 http://127.0.0.1:47281', 1, true),
  "a Record page open: the secure link set up by itself, once a session, in the background: " .. tostring(served[1]))
assert(pr.auto_on()); reaper.SetExtState(band.SECTION, pr.AUTO_KEY, "0"); assert(not pr.auto_on(), "Settings > Advanced turns it off")
reaper.DeleteExtState(band.SECTION, pr.AUTO_KEY)
assert(s and s.me == "James" and s.playing and #s.tracks == 2 and s.tracks[1].may and not s.tracks[2].may and s.tracks[2].why == "Bo's"
  and s.secure == "https://james-main.tail99.ts.net:8443/record.html?t=abc123" and math.abs(s.at - link) < 0.6, "the page's state: tracks with who may, the secure link")
assert(s.mixes and #s.mixes == 1 and s.mixes[1].song == "Song" and s.mixes[1].file == "2026-11-19 mix.wav" and s.mixes[1].bytes == 1234
  and offers[s.mixes[1].id] == MIXDIR .. "/2026-11-19 mix.wav", "each song's newest mix, offered by its id")
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

-- The phone app: a mix's id, a MIDI take's file, the WAV's BWF stamp, and what a phone-placed take may say
local id1 = pr.mix_id("Song", "a.wav", 10)
assert(#id1 == 16 and id1:match("^%x+$") and id1 == pr.mix_id("Song", "a.wav", 10) and pr.mix_id("Song", "a.wav", 11) ~= id1, "a mix's id: the same render, the same id; a new one, new")
local function vlq(n) local o = string.char(n & 127); n = n >> 7; while n > 0 do o = string.char(128 | (n & 127)) .. o; n = n >> 7 end; return o end
local function smf(events, div, tempo) -- { { delta ticks, bytes } }, as record.js writes one
  local tr = vlq(0) .. "\255\81\3" .. string.pack(">I3", tempo or 500000)
  for _, e in ipairs(events) do tr = tr .. vlq(e[1]) .. e[2] end
  tr = tr .. vlq(0) .. "\255\47\0"
  return "MThd" .. string.pack(">I4I2I2I2", 6, 0, 1, div or 960) .. "MTrk" .. string.pack(">I4", #tr) .. tr
end
local mid = smf({ { 0, "\144\60\100" }, { 1920, "\128\60\0" }, { 0, "\144\64\90" }, { 960, "\64\0" }, { 0, "\176\64\127" }, { 200, "\192\5" } })
local ev = pr.smf_events(mid)
assert(ev and #ev == 6 and ev[1].t == 0 and ev[1].msg == "\144\60\100" and math.abs(ev[2].t - 1) < 1e-9 and ev[4].msg == "\144\64\0" and math.abs(ev[4].t - 1.5) < 1e-9
  and ev[5].msg == "\176\64\127" and ev[6].msg == "\192\5", "a MIDI take's events in seconds (running status kept)")
assert(math.abs(pr.smf_events(smf({ { 960, "\144\60\100" } }, 480, 1000000))[1].t - 2) < 1e-9, "its tempo and division followed")
assert(pr.smf_events("MThd") == nil and pr.smf_events(("x"):rep(30)) == nil and pr.smf_events(mid:sub(1, 8) .. string.pack(">I2", 1) .. mid:sub(11)) == nil,
  "not a phone's MIDI file: nothing")
assert(#pr.smf_events(mid:sub(1, 40)) < 6, "a cut one: what's there")
local function bwf_wav(path) -- (the layout record.js writes: RIFF, bext, fmt, data)
  local f = assert(io.open(path, "wb"))
  f:write("RIFF", string.pack("<I4", 4 + 610 + 24 + 12), "WAVE", "bext", string.pack("<I4", 602), ("\0"):rep(602),
    "fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 3, 1, 48000, 192000, 4, 32), "data", string.pack("<I4", 4), "\0\0\0\0")
  f:close()
end
local function slurp(p) local f = assert(io.open(p, "rb")); local x = f:read("a"); f:close(); return x end
local wpath = TMP .. "/ss_phonerec_stamp.wav"
bwf_wav(wpath)
assert(pr.stamp(wpath, 48000, 2.5) and string.unpack("<I8", slurp(wpath), 359) == 120000 and #slurp(wpath) == 12 + 610 + 24 + 12, "the BWF time reference: the take's first sample, nothing else moved")
assert(pr.stamp(wpath, 48000, -1) and string.unpack("<I8", slurp(wpath), 359) == 0, "never before the start")
do local f = assert(io.open(wpath, "wb")); f:write("RIFF\0\0\0\0WAVEfmt "); f:close() end
assert(not pr.stamp(wpath, 48000, 1) and slurp(wpath) == "RIFF\0\0\0\0WAVEfmt ", "a WAV without the phone's bext: left alone")
os.remove(wpath)
d = pr.parse({ take = { id = "aa", track = "{A}", pos = 12.5, t0 = link, len = 3, kind = "mid", cid = "c0ffee", song = "Song", tname = "Vox", title = " Late night ",
  when = "2026-11-19T21:04:05.123Z" } })
assert(d.take.pos == 12.5 and d.take.t0 == nil and d.take.kind == "mid" and d.take.cid == "c0ffee" and d.take.song == "Song" and d.take.tname == "Vox"
  and d.take.title == "Late night" and d.take.when == "2026-11-19T21:04:05.123Z", "a take the phone placed itself, checked")
assert(pr.parse({ take = { id = "aa", track = "{A}", pos = 1 / 0, len = 3, kind = "wav" } }).take == nil, "no place at all: refused")
d = pr.parse({ take = { id = "aa", track = "{A}", pos = -2, len = 3, kind = "wav", cid = "xyz", song = "a\nb", when = "yesterday" } })
assert(d.take and d.take.pos == -2 and d.take.cid == nil and d.take.song == nil and d.take.when == nil, "bad extras dropped")

-- A take the phone placed (it played the mix): in at its own place, stamped, noted, once; the page hears how each went
reaper.GetMediaSourceSampleRate = function() return 48000 end
bwf_wav(wpath)
saved.ee55 = slurp(wpath)
os.remove(wpath)
said = pr.action("P", cfg, b, { take = { id = "ee55", track = "{AAAA-1}", pos = 12, len = 4, kind = "wav", name = "Bo", cid = "c1", song = "Song", title = "Late" } })
local it2 = tracks[1].items[2]
assert(it2 and it2.info.D_POSITION == 12 and it2.takes[1].info.D_STARTOFFS == 0 and it2.info.D_LENGTH == 30 and it2.takes[1].name == "Late - Bo",
  "placed where the phone says, named as the singer named it: " .. tostring(said))
assert(string.unpack("<I8", slurp(written), 359) == 12 * 48000, "its WAV stamped where it went")
local note = band.read((written:gsub("%.wav$", ".json")))
assert(note and note:find('"project":"Song"') and note:find('"by":"Bo"') and note:find('"take":"Late %- Bo"') and note:find('"track":"Vox"'), "its note beside it: " .. tostring(note))
os.remove((written:gsub("%.wav$", ".json"))); os.remove(written)
assert(pr.action("P", cfg, b, { take = { id = "ee55", track = "{AAAA-1}", pos = 12, len = 4, kind = "wav", cid = "c1" } }):find("already in") and #tracks[1].items == 2,
  "sent twice (the phone didn't hear back): in once")
saved.ff66 = "RIFF\0\0\0\0WAVE"
assert(pr.action("P", cfg, b, { take = { id = "ff66", track = "{AAAA-1}", pos = 1, len = 4, kind = "wav", cid = "c2", song = "Other" } }):find("open that project in front")
  and saved.ff66 and #tracks[1].items == 2, "another project's take waits (its upload kept)")
saved.ab77 = slurp((function() bwf_wav(wpath); return wpath end)())
said = pr.action("P", cfg, b, { take = { id = "ab77", track = "{FFFF-9}", tname = "Vox", pos = -1, len = 4, kind = "wav", cid = "c3" } })
local it3 = tracks[1].items[3]
assert(it3 and it3.info.D_POSITION == 0 and it3.takes[1].info.D_STARTOFFS == 1 and it3.info.D_LENGTH == 29, "its track found by name; started before the song: from the start: " .. said)
os.remove((written:gsub("%.wav$", ".json"))); os.remove(written); os.remove(wpath)
reaper.CreateNewMIDIItemInProj = function(tr, a, z)
  local mi = reaper.AddMediaItemToTrack(tr)
  mi.info.D_POSITION, mi.info.D_LENGTH = a, z - a
  reaper.AddTakeToMediaItem(mi).evts = {}
  return mi
end
reaper.MIDI_GetPPQPosFromProjTime = function(_, t) return t * 1920 end
reaper.MIDI_InsertEvt = function(tk, _, _, ppq, msg) tk.evts[#tk.evts + 1] = { ppq = ppq, msg = msg }; return true end
reaper.MIDI_Sort = function(tk) tk.sorted = true end
saved.cd88 = mid
said = pr.action("P", cfg, b, { take = { id = "cd88", track = "{AAAA-1}", pos = 4, len = 1.2, kind = "mid", name = "Bo", cid = "c4" } })
local mi = tracks[1].items[4]
assert(mi and mi.info.D_POSITION == 4 and math.abs(mi.info.D_LENGTH - 1.2) < 1e-9 and #mi.takes[1].evts == 3 and mi.takes[1].evts[1].ppq == 4 * 1920
  and mi.takes[1].evts[2].ppq == 5 * 1920 and mi.takes[1].evts[2].msg == "\128\60\0" and mi.takes[1].sorted and said:find("on Vox"),
  "a MIDI take: a MIDI item, its events at their song times, those past its end left out: " .. said)
assert(written:find("%.mid$"), "its file kept beside the project's recordings")
os.remove((written:gsub("%.mid$", ".json"))); os.remove(written)
clock = clock + 1
pr.tick("P", cfg, b, publish, clock)
local dn = pub.phonerec.done
assert(dn and dn.c1.ok and dn.c3.ok and dn.c4.ok and not dn.c2.ok and dn.c2.said:find("Other"), "the page hears how each take went")

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
