-- REAPER's video in a shared project (lib/video.lua, rt-video2): a real 3 s H.264 clip (tests/fixtures/tiny.mp4, 96x54, a test pattern and a
-- tone made by ffmpeg) through the paths audio takes: mirror.share_media's copy into the room's media, the normalized item, the media message
-- over the link and the receiver putting it in place, catch-up; the Video processor's block in a chain; it counting as built in for prints;
-- the project's video settings; the background renderer keeping the video window shut; the Project page's thumbnail info and offers.
package.path = "lib/?.lua;" .. package.path
local clock, gext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
band.home = function() return "H" end
band.info = function() return { id = "studio1" } end
band.log = function() end
local video = require("video")
local CLIP = "tests/fixtures/tiny.mp4"
local fh = assert(io.open(CLIP, "rb"))
local clip = fh:read("a")
fh:close()
assert(#clip > 1000 and clip:sub(5, 8) == "ftyp", "the fixture is an MP4")

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
assert(video.kind("a/b/Clip.MP4") == "v" and video.kind("x.mov") == "v" and video.kind("x.webm") == "v" and video.kind("x.mkv") == "v", "videos")
assert(video.kind("logo.PNG") == "i" and video.kind("x.gif") == "i", "pictures")
assert(video.kind("x.m4a") == nil and video.kind("x.wav") == nil and video.kind("x") == nil and video.kind(nil) == nil, "audio, nothing: no frames")
assert(video.builtin_fx("Video processor") and video.builtin_fx("video processor (cockos)") and video.builtin_fx("Title overlay", "Video"), "the Video processor, by name or type")
assert(not video.builtin_fx("VST3: ReaEQ (Cockos)", "VST3") and not video.builtin_fx("JS: video thing", "JS") and not video.builtin_fx(nil), "nothing else")
local R = "J:/Studio/Band"
assert(video.offerable(R .. "/Song/rooms/main/media/ab-clip.mp4", R) and video.offerable("j:\\studio\\band\\Song\\rooms\\main\\media\\x.mov", "J:/Studio/Band/"), "the studio's media, any case or slash")
for _, bad in ipairs({ "C:/Users/me/secret.mp4", R .. "/../other/x.mp4", R .. "/Song/../../x.mp4", R .. "x/y.mp4", R .. "/Song/rooms/main/media/x.wav", R .. "/Song/x.exe" }) do
  assert(not video.offerable(bad, R), "never offered: " .. bad)
end
assert(not video.offerable(R .. "/a.mp4", nil) and not video.offerable(R .. "/a.mp4", "") and not video.offerable(nil, R), "no studio, no path: never")
local id = video.id(R .. "/Song/rooms/main/media/ab-clip.mp4")
assert(#id == 32 and id:match("^[0-9a-f]+$") and id == video.id("j:\\studio\\band\\Song\\rooms\\main\\media\\ab-clip.mp4"), "32 hex, the same for any spelling")
assert(id ~= video.id(R .. "/Song/rooms/main/media/ab-clip2.mp4"), "another file, another id")
local inf = video.info(R .. "/Song/rooms/main/media/ab-clip.mp4", R, 1.23456, 2)
assert(inf.id == id and inf.k == "v" and inf.o == 1.235 and inf.r == 2, "what the page gets")
assert(video.info("C:/x.mp4", R, 0, 1) == nil, "nothing for a file outside the studio")
local ev = video.evict({ a = { at = 3 }, b = { at = 1 }, c = { at = 2 } }, 1)
assert(#ev == 2 and ev[1] == "b" and ev[2] == "c", "the oldest go first")
assert(#video.evict({ a = { at = 1 } }, 4) == 0, "under the cap: none")

-- ---- the clip through mirror.share_media: copied into the room's media, the item pointing at the copy ----------------------------------
local mirror = require("mirror")
local files = { [CLIP] = true }
reaper.file_exists = function(p) return files[p] == true end
reaper.RecursiveCreateDirectory = function() return 1 end
local copied, bg = {}, {}
band.copy_atomic = function(a, z) copied[#copied + 1] = { a, z }; files[z] = true end
band.copy_background = function(a, z) bg[#bg + 1] = { a, z } end
local chunk = '<ITEM\nPOSITION 2\nLENGTH 3\n<SOURCE VIDEO\nFILE "' .. CLIP .. '"\n>\n>\n'
mirror.copy_failed, mirror.copy_pending = nil, nil
local shared = mirror.share_media(chunk, "R/Song/rooms/main/media", nil, nil)
local copy = shared:match('FILE "{media:main}/([^"]+)"')
assert(copy and copy:match("^%x+%-tiny%.mp4$"), "a video item's file becomes the room's copy: " .. shared)
assert(#copied == 1 and copied[1][1] == CLIP and copied[1][2] == "R/Song/rooms/main/media/" .. copy and #bg == 0, "a small clip copied at once")
assert(shared:find("<SOURCE VIDEO", 1, true) and not mirror.copy_failed, "still a video source")
assert(mirror.media_from[band.norm("R/Song/rooms/main/media/" .. copy):lower()] == band.norm(CLIP), "the copy remembered (a streamed take needn't go twice)")
-- a big one (a music video): copied in the background, its item waiting till it's there
local real_size = band.size
local BIGV = [[D:\Shoot\Video.mov]]
band.size = function(p) return p == BIGV and 3 * 2 ^ 30 or real_size(p) end
files[BIGV] = true
mirror.copy_failed, mirror.copy_pending = nil, nil
local big = mirror.share_media('<ITEM\n<SOURCE VIDEO\nFILE "D:\\Shoot\\Video.mov"\n>\n>\n', "R/Song/rooms/main/media", nil, nil)
assert(#bg == 1 and bg[1][1] == "D:\\Shoot\\Video.mov" and mirror.copy_pending and big:find('FILE "D:\\Shoot\\Video.mov"', 1, true), "3 GB: in the background, the item held till it's there")
band.size = real_size
-- normalized, the item is the same text on every computer, its source and file kept
local norm = mirror.normalize_item('<ITEM\n  POSITION 2\n  SEL 1\n  <SOURCE VIDEO\n    FLIP 0 1\n    FILE "{media:main}/' .. copy .. '"\n  >\n>\n')
assert(norm:find('<SOURCE VIDEO\nFLIP 0 1\nFILE "{media:main}/' .. copy .. '"\n>', 1, true) and not norm:find("SEL 1", 1, true), "normalized: " .. norm)

-- ---- over the link: what the change names, its name on the link, the message, catch-up -------------------------------------------------
local streams = require("streams")
local direct = require("direct")
local new = streams.media_new(shared, nil)
assert(#new == 1 and new[1].room == "main" and new[1].file == copy, "the new item names its copy")
for _, f in ipairs({ "x.mp4", "x.mov", "x.webm", "x.m4a", "x.m4v", "x.mkv", "x.avi", "x.gif", "X.MP4" }) do
  assert(direct.stream_ext(f) and streams.media_name("main", "ab-" .. f), "the link takes " .. f)
end
for _, f in ipairs({ "x.exe", "x.js", "x.lua", "x.html", "x.svg", "x.wmv" }) do assert(not direct.stream_ext(f), "never " .. f) end
local d = { id = "Bo-20261120-120000Z-11234", user = "Bo", room = "main", file = copy, size = 5 * 2 ^ 30 }
local e = streams.valid_media(d, "Song", "James", clock)
assert(e and e.size == 5 * 2 ^ 30 and e.rel == "Song/~media~main~" .. copy, "a 5 GB video is a media file like any other (16 GB the cap)")
d.size = 17 * 2 ^ 30
assert(streams.valid_media(d, "Song", "James", clock) == nil, "over 16 GB: refused, as any file")
local wants = streams.catchup_wants({ queued = { { name = "Song/rooms/main/media/" .. copy, size = #clip }, { name = "Song/rooms/main/media/zz.mov", size = 9 },
  { name = "Song/rooms/main/media/x.exe", size = 1 } } }, "Song")
assert(#wants == 2 and wants[1].file == "zz.mov" and wants[2].file == copy, "catch-up asks for videos too (smallest first), never a program")
-- the sender: the fresh copy goes as media, begun and ended at once
local started, msgs = {}, {}
direct.live_available = function() return true end
direct.stream_start = function(cfg, path, song, room, ms, name) started[#started + 1] = { path = path, name = name }; return direct.stream_rel(song, name) end
direct.stream_end = function() return true end
direct.send_live = function(cfg, kind, dd) msgs[#msgs + 1] = { kind = kind, d = dd } end
direct.streams = function() return { out = {}, inn = {} } end
reaper.StudioSync_DirectFileTime = function() return os.time() end
local sizes = { ["R/Song/rooms/main/media/" .. copy] = #clip }
band.size = function(p) return sizes[p] end
assert(streams.offer_media({ user = "James", root = "R" }, "Song", "main", "R/Song/rooms/main/media", { state = shared }, nil) == 1, "it went")
assert(started[1].name == "~media~main~" .. copy and msgs[1].kind == "media" and msgs[1].d.size == #clip and msgs[1].d.file == copy, "named on the link, its size said")
-- the receiver: put in place once it's whole and checked
local disk = {}
band.size = function(p) return disk[p] end
band.subdirs = function(dir) return dir == "R/Song/rooms/main" and { "events" } or {} end
band.files = function() return {} end
reaper.file_exists = function(p) return disk[p] ~= nil end
local real_rename = os.rename
os.rename = function(a, z) if disk[a] == nil or disk[z] ~= nil then return nil end; disk[z], disk[a] = disk[a], nil; return true end
local cfg, b = { user = "James", root = "R" }, { song = "Song", room = "main" }
d.size, d.user = #clip, "Bo"
assert(streams.on_media(cfg, b, d), "taken")
local en = streams.media["Song/~media~main~" .. copy]
local inn = { { rel = en.rel, bytes = 4096, total = -1, done = false, ok = false, at = os.time() } }
direct.streams = function() return { out = {}, inn = inn } end
disk[en.inbox] = 4096
clock = clock + 1
assert(streams.media_tick(cfg, b) == 0, "still arriving")
-- Health says how far a big file has got
local text = streams.health_text({ out = {}, inn = inn }, { [en.rel] = #clip })
assert(text:find("in media " .. copy .. ": 0.00 MB of 0.01 MB (29%)", 1, true), text)
assert(streams.health_text({ out = {}, inn = { { rel = "S/~media~main~v.mp4", bytes = 3 * 2 ^ 29, done = false } } }, { ["S/~media~main~v.mp4"] = 2 ^ 31 })
  :find("1536.00 MB of 2048.00 MB (75%)", 1, true), "a 2 GB video three quarters in")
inn[1] = { rel = en.rel, bytes = #clip, total = #clip, done = true, ok = true, at = os.time() }
disk[en.inbox] = #clip
clock = clock + 1
assert(streams.media_tick(cfg, b) == 1 and disk["R/Song/rooms/main/media/" .. copy] == #clip and disk[en.inbox] == nil, "in place, where Syncthing would put it")
os.rename = real_rename
band.size = real_size

-- ---- the Video processor in a chain: its code travels as it is ---------------------------------------------------------------------------
local track = table.concat({ "<TRACK", "  NAME Video", "  <FXCHAIN", "    WNDRECT 1 2 3 4", "    SHOW 0", "    LASTSEL 0", "    DOCKED 0", "    BYPASS 0 0 0",
  '    <VIDEO_EFFECT "Video processor" ""', "      <CODE", '        |// Title text overlay', '        |#text="Take <1>"; // a > and a < in it',
  "        |", "        |//@param1:size 'text height' 0.05 0.01 0.2 0.1 0.001", "        |  gfx_blit(0, 1);", "      >",
  "      CODEPARM 0.05 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "    >", "    FLOATPOS 10 20 300 200", "    FXID {11111111-2222-3333-4444-555555555555}",
  "    WAK 0 0", "  >", ">" }, "\n")
local chain = mirror.fxchain(track)
assert(chain:find('<VIDEO_EFFECT "Video processor" ""\n<CODE\n|// Title text overlay\n|#text="Take <1>"; // a > and a < in it\n|\n', 1, true), chain)
assert(chain:find("|  gfx_blit(0, 1);\n>\nCODEPARM 0.05", 1, true), "the code's own indent kept, only REAPER's taken off")
assert(not chain:find("FLOATPOS", 1, true) and not chain:find("WNDRECT", 1, true), "its window, as any plug-in's, stays this computer's")
local lines = {}
for l in chain:gmatch("[^\n]+") do lines[#lines + 1] = l end
local blocks = mirror.plugin_blocks(lines)
assert(#blocks == 1 and blocks[1].key == "Video processor" and blocks[1].text:find("CODEPARM", 1, true), "one plug-in block, its code inside it")
local again = mirror.fxchain("<TRACK\n" .. chain .. ">")
assert(again == chain, "normalized twice: the same text (no endless resend)")

-- ---- prints: the Video processor is everyone's -------------------------------------------------------------------------------------------
local prints = require("prints")
local lists = { { user = "James", os = "Win64", names = { "reaeq (cockos)" } }, { user = "Bo", os = "OSX64", names = { "reaeq (cockos)" } } }
local lacks = prints.who_lacks({ "Video processor", "VST: ReaEQ (Cockos)", "VST3: Serum (Xfer)" }, lists)
assert(#lacks == 1 and lacks[1].fx == "Serum (Xfer)", "nobody lacks the Video processor")
band.files = function() return { "Bo.json" } end
band.read_json = function() return { user = "Bo", names = { "reaeq (cockos)" } } end
assert(prints.has({ root = "R" }, "Bo", { "reaeq (cockos)", "video processor" }), "Bo can print a track with one")
assert(not prints.has({ root = "R" }, "Bo", { "serum (xfer)", "video processor" }), "but not one with a plug-in he lacks")

-- ---- the project's video settings travel with the others ---------------------------------------------------------------------------------
local have = {}
for _, c in ipairs(band.PROJECT_CFG) do have[c[1]] = c[2] end
assert(have.projvidw == "i" and have.projvidh == "i" and have.projvidflags == "i", "VIDEO_CONFIG's three numbers")
assert(require("sync").TIMELINE_FORMAT >= 5, "a new format: the first look after updating isn't an edit")

-- ---- the background renderer's REAPER keeps the video window shut -------------------------------------------------------------------------
local bgr = require("bgrender")
local ini = bgr.profile_ini("[reaper]\nsplash=1\nvisible=1\n[reaper_video]\nrefresh_ms=default\nvisible=1\nfullscreen=1\nleft=10\n[other]\nvisible=1\n")
assert(ini:find("[reaper_video]\nrefresh_ms=default\nvisible=0\nfullscreen=0\nleft=10\n", 1, true), ini)
assert(ini:find("[reaper]\naudiocloseinactive=1\nrenderclosewhendone=4\nsplash=0\nvisible=1\n", 1, true) and ini:find("[other]\nvisible=1\n", 1, true), "other sections' visible left alone")

-- ---- the Project page: a video item's frames info, offered only from the studio's media ---------------------------------------------------
local offered = {}
reaper.StudioSync_WebUIOffer = function(i, p) if p == "" then offered[i] = nil else offered[i] = p end; return 1 end
local SRC = {}
reaper.GetMediaItemTake_Source = function(t) return t.src end
reaper.GetMediaSourceType = function(s) return s.type end
reaper.GetMediaSourceParent = function(s) return s.parent end
reaper.GetMediaSourceFileName = function(s) return s.file end
reaper.GetMediaItemTakeInfo_Value = function(t, k) return k == "D_STARTOFFS" and 1.5 or k == "D_PLAYRATE" and 1 or 0 end
video.root = "R"
local take = { src = { type = "VIDEO", file = "R/Song/rooms/main/media/" .. copy } }
local v = video.take(take, 1)
assert(v and v.k == "v" and v.o == 1.5 and v.r == 1 and offered[v.id] == "R/Song/rooms/main/media/" .. copy, "offered by its id")
assert(video.take({ src = { type = "SECTION", parent = take.src } }, 2).id == v.id, "a section of it: its parent's file")
assert(video.take({ src = { type = "VIDEO", file = "C:/Users/me/home video.mp4" } }, 3) == nil, "a file outside the studio: no frames, nothing offered")
assert(video.take({ src = { type = "VIDEO", file = "R/Song/rooms/main/media/song.m4a" } }, 3) == nil, "an m4a (audio through the video decoder): its waveform as ever")
assert(video.take({ src = { type = "WAVE", file = "R/Song/rooms/main/media/a.mp4" } }, 3) == nil, "not a video source")
-- rt-p6 (1.28): a song with 30 video files on screen: every one stays offered (16 left items 17+ with no frames)
for k = 1, 30 do video.take({ src = { type = "VIDEO", file = "R/S/rooms/main/media/big" .. k .. ".mp4" } }, 4 + k / 100) end
for k = 1, 30 do assert(offered[video.id("R/S/rooms/main/media/big" .. k .. ".mp4")], "30 files at once: big" .. k .. " offered") end
for k = 1, video.MAX_OFFERS + 3 do video.take({ src = { type = "VIDEO", file = "R/S/rooms/main/media/c" .. k .. ".mp4" } }, 10 + k) end
local n = 0
for _ in pairs(offered) do n = n + 1 end
assert(n == video.MAX_OFFERS and not offered[v.id] and offered[video.id("R/S/rooms/main/media/c" .. (video.MAX_OFFERS + 3) .. ".mp4")], "at most MAX_OFFERS offered, the oldest withdrawn")
video.root = nil
assert(video.take(take, 50) == nil, "before Live sync names the studio: nothing")
-- dawview carries it to the page, and a changed one sends its chunk again
local dawview = require("dawview")
local raw = { key = "Song/main", len = 10, tracks = { { name = "Video", depth = 0, items = { { pos = 2, len = 3, name = "clip", vid = v } } } } }
local _, chunks = dawview.build(raw)
local it = chunks[1].t.tr[1][1]
assert(it.v and it.v.id == v.id and it.v.o == 1.5, "the item says which file and where")
raw.tracks[1].items[1].vid = { id = v.id, k = "v", o = 2, r = 1 }
local _, chunks2 = dawview.build(raw)
assert(chunks2[1].sig ~= chunks[1].sig, "trimmed: its chunk goes again")
-- the pages load video.js before the views that draw it
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local idx, rec, sw = read("lib/webui/index.html"), read("lib/webui/record.html"), read("lib/webui/phone-sw.js")
assert(idx:find('src="video.js"', 1, true) and idx:find('src="video.js"', 1, true) < idx:find('src="daw.js"', 1, true), "the Project page")
assert(rec:find('src="video.js"', 1, true) and rec:find('src="video.js"', 1, true) < rec:find('src="phonedaw.js"', 1, true), "the phone's")
assert(sw:find("'video.js'", 1, true), "and the phone keeps it for offline")
print("ok")
