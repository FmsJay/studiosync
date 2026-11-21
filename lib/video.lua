-- REAPER's video in a shared project (James, rt-video2: "Support for reapers video functions as well"). Most of it needed nothing new: a
-- video item is an item whose take plays a <SOURCE VIDEO> (REAPER's decoder also plays .m4a that way), its file goes through the same paths
-- as audio (mirror.share_media copies it into the room's media, lib/streams.lua sends it over the link, Syncthing behind), and the Video
-- processor is a block in the FX chain (<VIDEO_EFFECT ...> with its code in <CODE> as "|" lines), which travels with the chain as any
-- plug-in's state does. What's here:
--   - the Video processor counts as built in (every REAPER has it, on every system): it's on nobody's published plug-in list, so a track
--     with one read as "a plug-in someone lacks" and printed its parts for nothing (lib/prints.lua, lib/plugins.lua call video.builtin_fx);
--   - the Project page's thumbnails: a video or picture item says which file it plays (an id the page asks the web server for: offered by
--     StudioSync_WebUIOffer, only files in the studio's shared folder), where in the file it starts and how fast it plays; the page reads
--     frames itself (lib/webui/video.js, a <video> element: the server answers byte ranges, extension 1.0.25).
-- The video window is each computer's own (reaper.ini [reaper_video], never in the project); the background renderer's REAPER keeps it shut
-- (lib/bgrender.lua profile_ini). The project's video settings (size, fit) travel with the other project settings (band.PROJECT_CFG).
-- GPL-3.0-or-later.
local band = require("band")
local video = { MAX_OFFERS = 40 } -- (the web server takes 64 offers in all, shared with the phone's mixes and chat downloads; 16 left items 17+ of a big song with no frames)

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
-- What a browser can draw frames from: "v" a video, "i" a still picture (REAPER shows pictures on the timeline as video too), nil anything
-- else (an .m4a REAPER plays through its video decoder is audio: its waveform is drawn as ever).
local KIND = { mp4 = "v", m4v = "v", mov = "v", webm = "v", mkv = "v", png = "i", jpg = "i", jpeg = "i", gif = "i" }
function video.kind(path) local e = tostring(path or ""):match("%.(%w+)$"); return e and KIND[e:lower()] or nil end
-- Is this FX REAPER's own Video processor? By its type (TrackFX_GetNamedConfigParm "fx_type") or its original name: an instance shows its
-- preset's name, so the name REAPER lists it under is what's asked. Pure.
function video.builtin_fx(name, kind)
  if type(kind) == "string" and kind:lower():find("video", 1, true) then return true end
  local n = tostring(name or ""):lower():gsub("^%w+:%s*", "")
  return n:sub(1, 15) == "video processor"
end
-- A file the pages may ask for: inside the studio's shared folder (`root`), no ".." anywhere. Only the band's media is ever offered, never a
-- file elsewhere on this computer (an item of yours not shared yet shows no thumbnails). Pure.
function video.offerable(path, root)
  if type(path) ~= "string" or type(root) ~= "string" or root == "" then return false end
  local p, r = band.norm(path):lower(), band.norm(root):lower() .. "/"
  return p:sub(1, #r) == r and not ("/" .. p .. "/"):find("/%.%./") and video.kind(p) ~= nil
end
-- Its id on the web server: 32 lower-case hex characters from the path (two FNV-1a 64s, the path forwards and backwards). Pure.
function video.id(path)
  local p = band.norm(path):lower()
  return band.code_hash(p) .. band.code_hash(p:reverse())
end
-- What the page gets for an item (dawview's item_out): { id, k = kind, o = where in the file it starts (s), r = playrate }. Pure.
function video.info(path, root, offs, rate)
  if not video.offerable(path, root) then return nil end
  return { id = video.id(path), k = video.kind(path), o = math.floor((tonumber(offs) or 0) * 1000 + 0.5) / 1000, r = tonumber(rate) or 1 }
end
-- Keeping at most MAX_OFFERS: the ones looked at last stay. offers: id -> { path, at }. -> the ids to withdraw (oldest first). Pure.
function video.evict(offers, max)
  local list = {}
  for id, o in pairs(offers) do list[#list + 1] = { id = id, at = o.at } end
  table.sort(list, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.id < b.id end)
  local out = {}
  for i = 1, #list - (max or video.MAX_OFFERS) do out[#out + 1] = list[i].id end
  return out
end

-- ---- REAPER ----------------------------------------------------------------------------------------------------------------------------
video.root = nil -- the studio's shared folder, set by dawview.tick (its read has no cfg)
local offers = {} -- id -> { path, at }
-- A take's thumbnail info, offering its file to the web server if it's one the page may have. -> video.info's, or nil.
function video.take(take, now)
  if not (video.root and reaper.StudioSync_WebUIOffer) then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if src and reaper.GetMediaSourceType(src, "") == "SECTION" then src = reaper.GetMediaSourceParent(src) end
  if not src or reaper.GetMediaSourceType(src, "") ~= "VIDEO" then return nil end
  local path = reaper.GetMediaSourceFileName(src, "")
  local v = video.info(path, video.root, reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"), reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"))
  if not v then return nil end
  now = now or reaper.time_precise()
  if offers[v.id] then offers[v.id].at = now; return v end
  if reaper.StudioSync_WebUIOffer(v.id, path) ~= 1 then return nil end -- (64 offered already: no thumbnails this time)
  offers[v.id] = { path = path, at = now }
  for _, id in ipairs(video.evict(offers)) do reaper.StudioSync_WebUIOffer(id, ""); offers[id] = nil end
  return offers[v.id] and v or nil
end

return video
