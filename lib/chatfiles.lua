-- Files dropped in the chat (rt-chat2): a file dragged onto a person or a conversation on the web page, or picked on a phone, reaches the
-- others as a chat message carrying `attach` = { name, size, sha (SHA-256, StudioSync_FileHash's), key, via }. The bytes go:
--  - over the direct link when it reaches them (lib/direct.lua stream_start: the extension's streams, chunked, resumed from what's already
--    there after a dropped connection, SHA-256 checked at the end; named "_chat/<key>" on the link, into <inbox>/.streams/_chat/ outside the
--    shared folder);
--  - and through the shared folder, <conversation>/files/<key>, which is the record. A DM whose members the link reaches right now goes over
--    the link only (it stays off the shared folder); if the link then fails, or doesn't finish in SEND_WAIT, the copy goes into the shared
--    folder after all.
-- The receiver sees it in the conversation and chooses: Save (to <home>/Received files), Save to the project's folder (audio only), or
-- Download on the page. Nothing opens or runs. Only the link's list of kinds goes (audio, MIDI, video, pictures, PDF, text, presets, zips),
-- and a file whose first bytes are a program's is refused whatever it's called, when it's sent and again when it's saved. (James: "Drag and
-- drop files to specific users or the whole group.") GPL-3.0-or-later.
local band = require("band")
local cf = { MAX = 150 * 1024 * 1024, LINK_SONG = "_chat", KEEP = 7 * 86400, SEND_WAIT = 600, NAME_MAX = 120 }
-- (MAX under the web server's 160 MB upload: extension/webui.cpp MAX_UPLOAD)
-- The kinds that may go: the direct link's own list (lib/direct.lua STREAM_EXT, extension/direct.cpp direct_stream_rel_ok; the test checks
-- they agree). Never anything that runs.
cf.EXTS = { "wav", "w64", "flac", "aif", "aiff", "ogg", "opus", "mp3", "mid", "mp4", "mov", "webm", "m4a", "m4v", "mkv", "avi", "gif", "pdf", "png", "jpg", "jpeg", "txt", "md",
  "fxp", "fxb", "vstpreset", "nam", "sfz", "als", "zip" }
local OK = {}
for _, e in ipairs(cf.EXTS) do OK[e] = true end
cf.AUDIO = { wav = true, w64 = true, flac = true, aif = true, aiff = true, ogg = true, opus = true, mp3 = true }

-- ---- pure ---------------------------------------------------------------------------------------------------------------------------------
function cf.ext(name) local e = tostring(name or ""):match("%.([%w]+)$"); return e and e:lower() end
-- A file's name as sent: -> it, or nil and why. A plain file name (no folders, nothing Windows refuses), one of the kinds above.
function cf.name_ok(name)
  if type(name) ~= "string" then return nil, "it has no name" end
  name = name:gsub("%c", ""):match("^%s*(.-)%s*$")
  if name == "" or #name > cf.NAME_MAX then return nil, "its name is empty or too long" end
  if name:sub(1, 1) == "." or name:find("[%. ]$") or name:find('[/\\:%*%?"<>|\127]') then return nil, "its name isn't a plain file name" end
  local base = name:match("^([^%.]+)") or ""
  if base:upper():match("^CON$") or base:upper():match("^PRN$") or base:upper():match("^AUX$") or base:upper():match("^NUL$")
    or base:upper():match("^COM%d$") or base:upper():match("^LPT%d$") then return nil, "its name is one Windows keeps for itself" end
  if not OK[cf.ext(name) or ""] then
    return nil, "only audio, MIDI, video, pictures, PDFs, text, presets and zips can be sent (never programs or scripts): ." .. tostring(cf.ext(name) or "?")
  end
  return name
end
-- Do these first bytes start a program (Windows, Linux, Mac) or a script? Pure.
function cf.runs_head(h)
  h = tostring(h or "")
  local four = h:sub(1, 4)
  return h:sub(1, 2) == "MZ" or four == "\127ELF" or h:sub(1, 2) == "#!"
    or four == "\254\237\250\206" or four == "\254\237\250\207" or four == "\206\250\237\254" or four == "\207\250\237\254" or four == "\202\254\186\190"
end
-- An attach table from a file or a message, checked: -> a clean copy, or nil. Pure.
function cf.check(a)
  if type(a) ~= "table" then return nil end
  local name = cf.name_ok(a.name)
  local size = math.tointeger(tonumber(a.size))
  if not name or name ~= a.name or not size or size < 0 or size > cf.MAX or type(a.sha) ~= "string" or not a.sha:match("^%x+$") or #a.sha ~= 64
    or type(a.key) ~= "string" or a.key ~= (a.key:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-[%w_]+%-%d+~") or "") .. name then return nil end
  return { name = name, size = size, sha = a.sha:lower(), key = a.key, via = a.via == "link" and "link" or "shared" }
end
-- What a page is shown of a file message (webui.chat_model): name, size, state ("ready", "coming", "waiting", "bad"), bytes so far, where it
-- was saved, a download id, and whether it's audio (Save to the project's folder). Pure.
function cf.model(a, st)
  a = cf.check(a)
  if not a then return nil end
  st = type(st) == "table" and st or {}
  return { name = a.name, size = a.size, via = a.via, audio = cf.AUDIO[cf.ext(a.name)] or nil, state = st.state or "waiting",
    bytes = tonumber(st.bytes), saved = type(st.saved) == "string" and st.saved or nil, dl = type(st.dl) == "string" and st.dl or nil }
end
-- An outgoing link copy as the extension reports it (direct.streams().out's entry, or nil): "going", "done", "failed" or "gone". Pure.
function cf.link_state(o)
  if type(o) ~= "table" then return "gone" end
  local any, all = false, true
  for _, p in pairs(type(o.peers) == "table" and o.peers or {}) do
    any = true
    if type(p) == "table" and (p.error or "") ~= "" then return "failed" end
    if not (type(p) == "table" and p.done == true) then all = false end
  end
  return any and all and "done" or "going"
end
-- name -> "name (2).ext" ... until one isn't taken (exists(path) -> bool).
function cf.free_name(dir, name, exists)
  local base, ext = name:match("^(.*)(%.[^%.]+)$")
  local p, i = dir .. "/" .. name, 2
  while exists(p) do p, i = dir .. "/" .. base .. " (" .. i .. ")" .. ext, i + 1 end
  return p
end

-- ---- on disk ------------------------------------------------------------------------------------------------------------------------------
function cf.rel(key) return cf.LINK_SONG .. "/" .. key end
local function out_dir(cfg) return band.home() .. "/chat files/" .. band.info(cfg.root).id end -- (outside the shared folder)
cf.out_dir = out_dir
local function head(path) local f = io.open(path, "rb"); if not f then return "" end local h = f:read(4) or ""; f:close(); return h end
local function copy(src, dst, size) if size > band.BIG then band.copy_background(src, dst) else band.copy_atomic(src, dst) end end
local function inn(cfg) local s = {}; for _, i in ipairs(require("direct").streams(cfg).inn) do s[i.rel] = i end return s end

-- The computers to send to now: those here (this project and room) that the link reaches, only `members`' when given (a DM). -> their
-- peers, and whether every member but you is among them.
function cf.reachable(cfg, b, members)
  if not (b and b.song) then return {}, false end
  local ok, by = pcall(require("hops").peers_by_user, cfg, b.song, b.room or "main")
  local ok2, reach = pcall(require("direct").reach, cfg, b.song, b.room or "main")
  by, reach = ok and by or {}, ok2 and reach or {}
  local to, all = {}, true
  if members then
    for _, u in ipairs(members) do
      if u ~= cfg.user then
        if by[u] and reach[u] and reach[u].ok then to[#to + 1] = by[u] else all = false end
      end
    end
  else
    for u, p in pairs(by) do if reach[u] and reach[u].ok then to[#to + 1] = p end end
    table.sort(to)
  end
  return to, all
end

local saved, offered = {}, {} -- key -> where it was saved here; key -> its download id
-- Where a file message's bytes are here, and how far: -> path (when ready), state, bytes so far.
function cf.where(cfg, m)
  local a, dir = m.attach, type(m.file) == "string" and m.file:match("^(.*)/msgs/[^/]+$")
  if not (a and dir) then return nil, "bad" end
  local shared = dir .. "/files/" .. a.key
  if reaper.file_exists(shared) then return shared, "ready" end -- (Syncthing puts a file in place only once it's whole)
  local i = inn(cfg)[cf.rel(a.key)]
  if i and i.done and i.ok ~= false then return require("direct").stream_path(cfg, cf.rel(a.key)), "ready" end
  if i and i.done then return nil, "bad" end
  if i then return nil, "coming", tonumber(i.bytes) end
  local mine = out_dir(cfg) .. "/" .. a.key -- (the sender's own copy of a DM's file that went over the link only)
  if reaper.file_exists(mine) then return mine, "ready" end
  return nil, "waiting"
end
function cf.status(cfg, m)
  local ok, _, state, bytes = pcall(cf.where, cfg, m)
  return { state = ok and state or "waiting", bytes = ok and bytes or nil, saved = saved[m.attach.key], dl = offered[m.attach.key] }
end

-- A page's upload (f = { id, name, size }) sent in the conversation whose folder is `dir`, under the message's own name `stamp`; `members`
-- for a DM. -> the message's attach table, or nil and why.
function cf.send(cfg, b, dir, f, stamp, members)
  local name, why = cf.name_ok(f.name)
  if not name then return nil, why end
  local size = math.tointeger(tonumber(f.size))
  if not size or size <= 0 or size > cf.MAX then return nil, string.format("files go up to %d MB", cf.MAX // 1048576) end
  if type(f.id) ~= "string" or not f.id:match("^%x+$") then return nil, "its upload has no id" end
  -- (the extension's receiving thread hashed the upload as it came in: nothing reads it whole here on REAPER's main thread. An older extension
  -- hashes the saved file instead. rt-p5; extension/webui.cpp)
  local sha = reaper.StudioSync_WebUIUploadHash and reaper.StudioSync_WebUIUploadHash(f.id)
  if type(sha) ~= "string" or #sha ~= 64 then sha = nil end
  if not (reaper.StudioSync_WebUISaveUpload and (sha or reaper.StudioSync_FileHash)) then return nil, "StudioSync's extension here is too old" end
  local key = stamp .. "~" .. name
  local to, all = cf.reachable(cfg, b, members)
  local link_only = members ~= nil and all and #to > 0
  local final = link_only and out_dir(cfg) .. "/" .. key or dir .. "/files/" .. key
  local folder = final:match("^(.*)/[^/]+$")
  reaper.RecursiveCreateDirectory(folder, 0)
  local tmp = folder .. "/.syncthing." .. key .. ".tmp" -- (a name Syncthing leaves alone until it's whole and renamed)
  local n = reaper.StudioSync_WebUISaveUpload(f.id, tmp)
  if n == 0 then return nil, "its upload isn't here any more (send it again)" end
  if n < 0 then os.remove(tmp); return nil, "it couldn't be written in " .. folder .. " (full, or not writable)" end
  local function refuse(w) os.remove(tmp); return nil, w end
  if n ~= size then return refuse("it didn't arrive whole from the page") end
  if cf.runs_head(head(tmp)) then return refuse("it's a program or a script, whatever its name says") end
  sha = sha or reaper.StudioSync_FileHash(tmp)
  if type(sha) ~= "string" or #sha ~= 64 then return refuse("its SHA-256 couldn't be worked out") end
  os.remove(final)
  if not os.rename(tmp, final) then return refuse("it couldn't be put in place in " .. folder) end
  local direct = require("direct")
  local rel = #to > 0 and direct.stream_start(cfg, final, cf.LINK_SONG, nil, 0, key, to) or nil
  if rel then direct.stream_end(cfg, rel) end -- (complete: begun and ended at once, so its length and SHA-256 follow straight away)
  if link_only then
    if rel then band.write_json(final .. ".json", { rel = rel, dir = dir, key = key, size = n, at = os.time(), state = "going" })
    else copy(final, dir .. "/files/" .. key, n); link_only = false end -- (the link didn't take it: the shared folder after all)
  end
  return { name = name, size = n, sha = sha:lower(), key = key, via = link_only and "link" or "shared" }
end

-- Save a file message's bytes here (how: "keep" to <home>/Received files, "project" (audio) to the project's own folder, "download" to offer it
-- to the page), only when they're whole and match the sender's SHA-256, and aren't a program. -> words for the log.
function cf.save(cfg, m, how)
  local a = m.attach
  local name, why = cf.name_ok(a.name)
  if not name then return "a file in the chat wasn't saved: " .. why end
  local src, state = cf.where(cfg, m)
  if state ~= "ready" then return name .. " isn't here yet" end
  if cf.runs_head(head(src)) then return name .. " wasn't saved: it's a program or a script, whatever its name says" end
  if not reaper.StudioSync_FileHash or reaper.StudioSync_FileHash(src):lower() ~= a.sha then return name .. " wasn't saved: it didn't arrive whole (its SHA-256 doesn't match the sender's)" end
  if how == "download" then
    local id = band.code_hash(a.key)
    if reaper.StudioSync_WebUIOffer and reaper.StudioSync_WebUIOffer(id, src) == 1 then offered[a.key] = id; return nil end
    return name .. " couldn't be offered to the page (StudioSync's extension too old, or 64 offered already)"
  end
  local to
  if how == "project" then
    if not cf.AUDIO[cf.ext(name)] then return name .. " isn't audio: only audio goes to the project's folder" end
    to = reaper.GetProjectPathEx(reaper.EnumProjects(-1), "")
    if to == "" then return name .. " wasn't saved: save the project first, so it has a folder" end
  else to = band.home() .. "/Received files" end
  reaper.RecursiveCreateDirectory(to, 0)
  local dest = cf.free_name(to, name, reaper.file_exists)
  local ok, e = pcall(copy, src, dest, a.size)
  if not ok then return name .. " wasn't saved: " .. tostring(e) end
  saved[a.key] = dest
  return "saved " .. name .. " from the chat to " .. dest
end

-- Every tick of Live sync's web UI: a DM's link-only copy that failed or stalled goes into the shared folder; finished ones and old received
-- copies are tidied. Cheap when nothing's on its way (one folder listing every 2 s).
local tick_at, prune_at = -math.huge, -math.huge
function cf.tick(cfg, now)
  if now - tick_at < 2 then return end
  tick_at = now
  local dir = out_dir(cfg)
  local outs
  for _, f in ipairs(band.files(dir, ".json")) do
    local p = dir .. "/" .. f
    local s = band.read_json(p)
    local file = p:sub(1, -6)
    if type(s) ~= "table" or type(s.key) ~= "string" or type(s.dir) ~= "string" then os.remove(p)
    elseif s.state == "going" then
      if not outs then outs = {}; for _, o in ipairs(require("direct").streams(cfg).out) do outs[o.rel] = o end end
      local st = cf.link_state(outs[s.rel])
      if st == "done" then s.state = "done"; band.write_json(p, s)
      elseif st ~= "going" or os.time() - (tonumber(s.at) or 0) > cf.SEND_WAIT then
        if reaper.file_exists(file) then copy(file, s.dir .. "/files/" .. s.key, tonumber(s.size) or 0) end
        s.state = "shared"; band.write_json(p, s)
        band.log("a direct message's file didn't get through the direct link (" .. st .. "): it goes through the shared folder")
      end
    elseif os.time() - (tonumber(s.at) or 0) > 86400 then os.remove(file); os.remove(p) end
  end
  if now - prune_at < 600 then return end
  prune_at = now
  local inbox = require("direct").inbox(cfg.root) .. "/.streams/" .. cf.LINK_SONG
  local before = os.date("!%Y%m%d-%H%M%S", os.time() - cf.KEEP) -- (a key starts with its message's UTC stamp)
  for _, f in ipairs(band.files(inbox)) do
    if f:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d") and f:sub(1, 15) < before then os.remove(inbox .. "/" .. f) end
  end
end

return cf
