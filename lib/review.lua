-- Versioned notes and client review links (James, rt: "versioned, timestamped comments with a resolved state across mix versions; client
-- listen links to the latest bounce").
-- Notes stay what they were: "note" events in the room's history (sync.post), ticked off in <Song>/chat/resolved (the Chat page's Notes tab).
-- Here they gain the version they were made on (`ver`: the room's newest saved version then, lib/recall.lua) and the region they sit in, so
-- a later look says "made on version N" and whether that spot has changed since.
-- A client link is a folder in the studio's cloud copy (lib/drive.lua) holding a mix from <Song>/mixes, the studio's notes on it
-- (studio-notes.txt, written by StudioSync) and comments.txt for the client. Whoever made it shares that one folder from the cloud service
-- ("anyone with the link"); the client plays the mix there and adds lines to comments.txt; the maker's StudioSync reads them in as notes, with
-- the client's name and the version the link was made from. No server of ours, no account for the client beyond the cloud service's link.
--   <cloud copy>/_Client review/<Song> - <mix>/{<mix file>, comments.txt, studio-notes.txt}
--   <Song>/clients/<Song> - <mix>.json   { name, mix, room, ver, by, time, seen = { line key -> true } }  (only its maker writes it)
-- The web UI (another branch) can serve the same thing as a page: review.data is its hook (docs/realtime-roadmap.md).
local review = {}

review.FOLDER = "_Client review" -- (the underscore: no song is called that, as with _band)
review.WINDOW = 30 -- seconds: an item starting this far before a note's spot and changed later counts as changing that spot

-- ---- versioned notes ----------------------------------------------------------------------------------------------------------------

-- Which saved version a note was made on, counted from 1 (the oldest kept); 0 for before the first. `versions`: recall.list's rows,
-- newest first. A note naming its version finds it; an older note, or one whose version was trimmed, goes by time. Pure.
function review.version_n(versions, note)
  if note.ver then
    for i, v in ipairs(versions) do if v.file == note.ver then return #versions - i + 1 end end
  end
  local n = 0
  for _, v in ipairs(versions) do if (v.time or "") <= (note.time or "") then n = n + 1 end end
  return n
end

-- Whether what a note points at changed after it was made: its item changed (a note on a part); else, on its track (or any, for a note at
-- the cursor), an item there or starting up to WINDOW seconds before its stretch, or the track's own sound (plug-ins, sends); or the tempo map
-- or an insert of time moved the bars under it. `events`: the room's changes (recall's). Pure.
-- shortcut: an item longer than WINDOW that starts well before the note isn't seen; reading each candidate's length needs its state file.
function review.spot_changed(note, events)
  local t = note.time or ""
  local p0 = tonumber(note.pos)
  local p1 = p0 and p0 + (tonumber(note.len) or 0)
  for _, e in ipairs(events) do
    local kind = e.type or e.kind
    if (e.time or "") > t and e.id ~= note.id then
      if kind == "timeline" or kind == "shift" then return true end
      if note.take and e.take == note.take then return true end -- (takes before mirror sync: edit, delete, midi)
      if kind == "obj" then
        if note.item then
          if e.oid == note.item then return true end
        elseif not note.track or e.name == note.track then
          if e.obj ~= "item" then
            if note.track then return true end
          else
            local pos = tonumber(e.pos)
            if not p0 or not pos or (pos <= p1 and pos >= p0 - review.WINDOW) then return true end
          end
        end
      end
    end
  end
  return false
end

-- The words after a note: "made on version 3; that spot changed since". `changed`: review.spot_changed's answer. Pure.
function review.words(n, changed)
  local made = n == 0 and "made before the first saved version" or ("made on version " .. n)
  return made .. (changed and "; that spot changed since" or "; unchanged since")
end

-- For the notes on show (no more than `max`, the newest first as recall.notes gives them): { [note id] = words }. Pure.
function review.marks(notes, versions, events, max)
  local out, n = {}, 0
  for _, e in ipairs(notes) do
    if e.type == "note" then
      n = n + 1
      if n > (max or 30) then break end
      out[e.id] = review.words(review.version_n(versions, e), review.spot_changed(e, events))
    end
  end
  return out
end

-- What a new note is stamped with: the room's newest saved version, and the region its spot sits in (REAPER's own regions).
function review.stamp(proj, ev, versions)
  ev.ver = versions[1] and versions[1].file or nil
  if ev.pos and reaper.GetLastMarkerAndCurRegion then
    local _, ri = reaper.GetLastMarkerAndCurRegion(proj, ev.pos)
    if ri and ri >= 0 then
      local _, isrgn, _, _, name = reaper.EnumProjectMarkers3(proj, ri)
      if isrgn and (name or "") ~= "" then ev.region = name end
    end
  end
  return ev
end

-- ---- client links -----------------------------------------------------------------------------------------------------------------

-- The link's folder name: "<Song> - <mix without its extension>", without what Windows or a cloud service refuses in a name (%w would
-- depend on the locale, and cut a letter like an accented e in half). Pure.
function review.link_name(song, mix)
  local s = (song .. " - " .. mix:gsub("%.[^.]+$", "")):gsub('[%c/\\:%*%?"<>|]', ""):gsub("%s+", " ")
  return (s:sub(1, 80):gsub("^%s+", ""):gsub("[%s%.]+$", ""))
end

function review.mmss(secs)
  secs = math.floor((tonumber(secs) or 0) + 0.5)
  return string.format("%d:%02d", secs // 60, secs % 60)
end

-- What comments.txt starts as: how to add a comment, in the file itself. Pure.
function review.template(song, mix)
  return table.concat({
    "# Comments on " .. song .. " (" .. mix .. ")",
    "# Put your name on the Name line, then one comment per line, starting with the time in the mix (minutes:seconds) or a bar:",
    "#   1:32 the vocal is a bit quiet here",
    "#   bar 17 love this guitar",
    "#   the whole mix feels a little dark  (no time: a comment on all of it)",
    "# In Google Drive: download this file, add your lines, and upload it back into this folder (Keep both is fine).",
    "# In OneDrive or Dropbox you can edit it in the browser. Lines starting with # are left alone.",
    "# The band's own notes are in studio-notes.txt.",
    "Name: ",
    "",
  }, "\n")
end

-- A client's file read: their name (the Name line, else `fallback`) and their comments { at = seconds | nil, bar = n | nil, text }. Pure.
function review.parse(text, fallback)
  local who, out = nil, {}
  for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    line = line:gsub("^\239\187\191", ""):match("^%s*(.-)%s*$") -- (a byte-order mark that Notepad puts first)
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local name = line:match("^[Nn]ame%s*:%s*(.-)$")
      if name then
        if name ~= "" then who = name:sub(1, 40) end
      else
        local h, m, s, rest = line:match("^(%d+):(%d%d):(%d%d)%s*[%-:]?%s*(.*)$")
        if not h then m, s, rest = line:match("^(%d+):(%d%d)%s*[%-:]?%s*(.*)$") end
        local bar, brest = line:match("^[Bb]ar%s*(%d+)%s*[%-:]?%s*(.*)$")
        if m and rest ~= "" then out[#out + 1] = { at = (tonumber(h) or 0) * 3600 + tonumber(m) * 60 + tonumber(s), text = rest:sub(1, 500) }
        elseif bar and brest ~= "" then out[#out + 1] = { bar = tonumber(bar), text = brest:sub(1, 500) }
        else out[#out + 1] = { text = line:sub(1, 500) } end
      end
    end
  end
  return who or fallback or "client", out
end

-- One comment's key: brought in once, however often the file is read. Pure.
function review.key(file, who, c) return table.concat({ file, who, tostring(c.at or ""), tostring(c.bar or ""), c.text }, "|") end

-- studio-notes.txt: the band's notes on the room, newest first, each where it sits and which version it was made on. `where(note)` -> words
-- for its spot ("bar 5, 0:12"). Pure.
function review.notes_text(song, mix, notes, versions, where, resolved)
  local h = { "StudioSync notes on " .. song .. " (this folder's mix: " .. mix .. "). Written by StudioSync: changes here are replaced.", "" }
  local n = 0
  for _, e in ipairs(notes) do
    if e.type == "note" then
      n = n + 1
      local who = e.client and (e.client .. " (client)") or tostring(e.user)
      h[#h + 1] = string.format("%s%s  %s: %s  (%s)", (resolved or {})[e.id] and "[done] " or "", where(e), who, tostring(e.text),
        (review.version_n(versions, e) == 0 and "before the first saved version" or ("version " .. review.version_n(versions, e))))
    end
  end
  if n == 0 then h[#h + 1] = "No notes yet." end
  return table.concat(h, "\n") .. "\n"
end

-- A song's client links, newest first.
function review.links(cfg, song)
  local band = require("band")
  local dir, out = band.song_dir(cfg, song) .. "/clients", {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local l = band.read_json(dir .. "/" .. f)
    if type(l) == "table" and type(l.name) == "string" and type(l.mix) == "string" then out[#out + 1] = l end
  end
  table.sort(out, function(a, z) return tostring(a.time) > tostring(z.time) end)
  return out
end

-- Where a link's folder is here (the cloud copy), or nil.
function review.folder(cfg, link)
  local droot = require("drive").root(cfg)
  return droot and (droot .. "/" .. review.FOLDER .. "/" .. link.name) or nil
end

-- Make a client link for `mix` (a file in <Song>/mixes) from the room in front. -> its folder and the link, or nil + why.
function review.make(cfg, b, mix)
  local band = require("band")
  local drive = require("drive")
  if not drive.root(cfg) then return nil, "A client link lives in the studio's cloud folder, and this computer has none (Settings > Options)." end
  local src = band.song_dir(cfg, b.song) .. "/mixes/" .. mix
  if not reaper.file_exists(src) then return nil, "That mix isn't in the project's mixes folder any more." end
  local newest = require("recall").list(cfg, b.song, b.room)[1]
  local link = { name = review.link_name(b.song, mix), mix = mix, room = b.room, ver = newest and newest.file, by = cfg.user,
    time = os.date("!%Y-%m-%dT%H:%M:%SZ"), seen = {} }
  local dir = review.folder(cfg, link)
  reaper.RecursiveCreateDirectory(dir, 0)
  local ok, why = pcall(band.copy_atomic, src, dir .. "/" .. mix)
  if not ok then return nil, "Couldn't copy the mix to " .. drive.name(cfg) .. ": " .. tostring(why) end
  if not reaper.file_exists(dir .. "/comments.txt") then band.write_atomic(dir .. "/comments.txt", review.template(b.song, mix)) end
  local ldir = band.song_dir(cfg, b.song) .. "/clients"
  reaper.RecursiveCreateDirectory(ldir, 0)
  local old = band.read_json(ldir .. "/" .. link.name .. ".json")
  if type(old) == "table" and type(old.seen) == "table" then link.seen = old.seen end -- (the same mix again: what came in stays in)
  band.write_json(ldir .. "/" .. link.name .. ".json", link)
  return dir, link
end

-- The hook for a page about a link (the web UI): its mix's path, the client's comments as read, and the studio's notes. -> table, or nil.
function review.data(cfg, song, link)
  local band = require("band")
  local dir = review.folder(cfg, link)
  if not dir then return nil end
  local comments = {}
  for _, f in ipairs(band.files(dir, ".txt")) do
    if f ~= "studio-notes.txt" then
      local who, list = review.parse(band.read(dir .. "/" .. f), nil)
      for _, c in ipairs(list) do c.who, c.file = who, f; comments[#comments + 1] = c end
    end
  end
  return { folder = dir, mix = dir .. "/" .. link.mix, comments = comments, notes = require("recall").notes(cfg, song, link.room) }
end

-- Read a link's client comments in as notes (only its maker does, so each comes in once) and write the studio's notes beside the mix.
-- `proj`: the tab in front, for bars. -> how many came in, or nil + why.
function review.check(cfg, b, proj, link)
  local band, sync = require("band"), require("sync")
  if link.by ~= cfg.user then return nil, tostring(link.by) .. " made this link: their StudioSync brings its comments in." end
  local d = review.data(cfg, b.song, link)
  if not d then return nil, "There's no cloud folder on this computer." end
  link.seen = type(link.seen) == "table" and link.seen or {}
  local n = 0
  for _, c in ipairs(d.comments) do
    local k = review.key(c.file, c.who, c)
    if not link.seen[k] then
      local pos = c.at or (c.bar and reaper.TimeMap2_beatsToTime(proj, 0, c.bar - 1)) or nil -- shortcut: the mix is taken to start at the song's start, as Render current mix does
      sync.post(cfg, b.song, link.room, { type = "note", text = c.text, client = c.who, pos = pos, ver = link.ver, mix = link.mix })
      link.seen[k] = true
      n = n + 1
    end
  end
  if n > 0 then band.write_json(band.song_dir(cfg, b.song) .. "/clients/" .. link.name .. ".json", link) end
  if link.room == b.room then
    local resolved = {}
    for _, f in ipairs(band.files(band.song_dir(cfg, b.song) .. "/chat/resolved", ".json")) do resolved[f:sub(1, -6)] = true end
    local function where(e)
      if not e.pos then return "(the whole mix)" end
      local _, measures = reaper.TimeMap2_timeToBeats(proj, e.pos)
      return string.format("bar %d, %s%s", math.floor((measures or 0) + 1), review.mmss(e.pos), e.region and (" (" .. e.region .. ")") or "")
    end
    local text = review.notes_text(b.song, link.mix, d.notes, require("recall").list(cfg, b.song, link.room), where, resolved)
    if band.read(d.folder .. "/studio-notes.txt") ~= text then band.write_atomic(d.folder .. "/studio-notes.txt", text) end
  end
  return n
end

-- ---- the Mixes page's part ------------------------------------------------------------------------------------------------------------
local links_at, links, checked_at = -math.huge, {}, -math.huge
function review.section(ctx, ImGui, cfg, b, proj)
  local band = require("band")
  ImGui.SeparatorText(ctx, "Client review links")
  if ImGui.SmallButton(ctx, "Make a client link...") then
    local dir, files = band.song_dir(cfg, b.song) .. "/mixes", {}
    for _, f in ipairs(band.files(dir)) do
      if require("listen").AUDIO[(f:match("%.([^.]+)$") or ""):lower()] and not f:find("^%.") then files[#files + 1] = f end
    end
    table.sort(files, function(a, z) return a > z end)
    if #files == 0 then band.msg("No mixes yet: Render current mix first (above). For an older version: open it in a side room (Restore), render there, then make the link.")
    else
      table.insert(files, 1, "#Which mix should the client hear?")
      local mix = band.pick(files)
      if mix and mix:sub(1, 1) ~= "#" then
        local folder, link = review.make(cfg, b, mix)
        if not folder then band.msg(link) else
          links_at = -math.huge
          band.log("client link folder made: " .. folder)
          band.msg("The client's folder is ready in " .. require("drive").name(cfg) .. ":\n" .. folder .. "\n\nShare that one folder there as " ..
            "'anyone with the link' (Editor, so they can add to comments.txt; a link that expires or has a password, where your plan offers one), and send " ..
            "the client the link. They play the mix and add their comments; StudioSync brings them into Notes, with their name and this version.")
          band.open_url(folder)
        end
      end
    end
  end
  ImGui.SetItemTooltip(ctx, "A folder in the studio's cloud copy with a mix, the band's notes and a comments file, for someone outside the studio to " ..
    "listen and comment. You share that folder from the cloud service; their comments come into Notes here.")
  if reaper.time_precise() - links_at > 10 then links_at, links = reaper.time_precise(), review.links(cfg, b.song) end
  local auto = reaper.time_precise() - checked_at > 60
  if auto then checked_at = reaper.time_precise() end
  local versions = require("recall").list(cfg, b.song, b.room)
  for i, l in ipairs(links) do
    ImGui.PushID(ctx, "client" .. i)
    local mine = l.by == cfg.user
    if mine and auto then
      local ok, n = pcall(review.check, cfg, b, proj, l)
      if ok and (n or 0) > 0 then band.log(string.format("%d client comment(s) on %s came into Notes", n, l.mix)) end
    end
    if ImGui.SmallButton(ctx, "Open folder") then
      local f = review.folder(cfg, l)
      if f then band.open_url(f) else band.msg("There's no cloud folder on this computer.") end
    end
    ImGui.SameLine(ctx)
    ImGui.BeginDisabled(ctx, not mine)
    if ImGui.SmallButton(ctx, "Look for comments") then
      local n, why = review.check(cfg, b, proj, l)
      band.log(n and string.format("%d new client comment(s) on %s", n, l.mix) or tostring(why))
    end
    ImGui.EndDisabled(ctx)
    if not mine then ImGui.SetItemTooltip(ctx, tostring(l.by) .. " made this link: their StudioSync brings its comments in.") end
    ImGui.SameLine(ctx)
    local n = l.room == b.room and review.version_n(versions, { ver = l.ver, time = l.time }) or nil
    ImGui.TextDisabled(ctx, string.format("%s, by %s%s", l.mix, tostring(l.by), n and (n == 0 and ", before the first saved version" or (", version " .. n)) or (", from " .. tostring(l.room))))
    ImGui.PopID(ctx)
  end
  if #links == 0 then ImGui.TextDisabled(ctx, "None yet.") end
end

return review
