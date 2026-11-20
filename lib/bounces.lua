-- Distributed bounces (roadmap "New features the extension makes possible"; James, rt): Render stems (each track or each folder, the whole
-- project or the time selection) split across the computers in the room that are idle, and Render mix on the hub.
-- This computer saves one copy of the project set up for the render (24-bit WAV at the project's rate as Export stems, every stem from the
-- same start; your local tracks muted as Final mix does), then splits the stems by how heavy each is (its length and plug-ins) across itself
-- and every bandmate on the link who can: not a guest, not recording, under hops.BUSY, able to render in the background there (status `bnc`),
-- with every plug-in of the stem's tracks (prints.has) and every sound their samplers play (lib/libraries.lua; a stem with an opaque sampler
-- stays here). The copy goes to them over the link (one file); each renders its share from it in the hidden background REAPER prints use
-- (lib/bgrender.lua), never in the person's working session, puts the files in its own <Song>/stems/<date>/ (Syncthing carries them from
-- there: the durable path) and sends them back over the link (fast). The same copy and settings everywhere, only which tracks are selected
-- differs, so a share comes out byte for byte as it would here. A share whose computer says it failed, starts recording, has an audio dropout
-- or goes STALL s without news is redone by another that can, else here. Progress per computer: Health and the panel's Mixes page.
local band = require("band")
local bounces = {}

bounces.KIND = "bounce"
bounces.NEWS, bounces.STALL, bounces.SYNC_WAIT, bounces.KEEP_SAYING, bounces.EVERY = 5, 30, 300, 60, 0.5
bounces.START = 20 -- what starting elsewhere costs, in the split's units (seconds of audio x plug-ins): sending the copy, a REAPER starting
local R -- this computer's bounce (one at a time)
local H = {} -- shares this computer renders for bandmates, by bounce id
local tick_at = -math.huge

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local function norm(p) return (tostring(p or ""):gsub("\\", "/"):gsub("/+$", "")) end
local function plain(s) return type(s) == "string" and #s > 0 and #s <= 200 and s:sub(1, 1) ~= "." and not s:find("[%. ]$") and not s:find('[%c/\\:%*%?"<>|\127]') end
-- Where a share's files go, under the song's folder: "mixes" or "stems/<one plain folder>". Anything else is refused (it comes over the link).
function bounces.dest_ok(dest)
  return dest == "mixes" or (type(dest) == "string" and dest:sub(1, 6) == "stems/" and plain(dest:sub(7)))
end
function bounces.file_ok(f) return plain(f) and f:lower():match("%.wav$") ~= nil end
-- A rendered file's name on the link (the extension's rule: one plain name with an audio extension), and the copy's.
-- Each share has its own (k), so a share redone by another computer never lands on the same name in the inbox.
function bounces.link_name(id, k, file) return "~stem~" .. id .. "-" .. k .. "~" .. file end
function bounces.copy_name(id, k) return "~bounce~" .. id .. "-" .. k .. ".txt" end -- (.txt: an .rpp isn't on the link's list; it's only ever read as text)

-- The copy as one share renders it: each track's SEL as `sel` says (a set of upper-case GUIDs; nil: as it is), and every FILE under the
-- sender's studio folder `from` moved to this computer's `to` (each has its own copy of the shared folder). -> the text, and its media paths
-- after the move: those a render can hear (a muted track's aren't, unless it has a mute envelope: the copy mutes your local tracks, whose
-- files may be outside the shared folder). Pure.
function bounces.prepare(text, sel, from, to)
  from, to = norm(from), norm(to)
  local low, out, media, depth, guid, muted = from:lower() .. "/", {}, {}, 0, nil, false
  for raw in tostring(text):gmatch("[^\n]*\n?") do
    if raw == "" then break end
    local line, s = raw, raw:match("^%s*(.-)%s*$")
    if depth == 1 and s:sub(1, 1) == "<" then guid, muted = s:match("^<TRACK%s+(%b{})"), false end
    if depth == 2 and guid then
      if s:match("^MUTESOLO 1") then muted = true elseif s:match("^<MUTEENV") then muted = false end -- (MUTESOLO comes first, envelopes before items)
    end
    if sel and depth == 2 and guid then line = line:gsub("^(%s*SEL )%d+", function(p) return p .. (sel[guid:upper()] and "1" or "0") end) end
    local pre, rest = line:match("^(%s*FILE )(.-)\r?\n?$")
    if pre and depth >= 2 then
      local q, path, tail = rest:sub(1, 1), nil, nil
      if q == '"' or q == "'" or q == "`" then path, tail = rest:match("^.(.-)" .. q .. "(.*)$") else path, tail = rest:match("^(%S+)(.*)$") end
      if path and path ~= "" then
        local p = norm(path)
        if p:lower():sub(1, #low) == low then p = to .. "/" .. p:sub(#low + 1) end
        if not muted then media[#media + 1] = p end
        line = pre .. '"' .. p .. '"' .. tail .. (raw:match("\r?\n$") or "")
      end
    end
    out[#out + 1] = line
    if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
    if depth == 1 and s == ">" then guid = nil end
  end
  return table.concat(out), media
end
-- Media a copy needs that isn't here: a path not found, or (`root` given: a bandmate's copy) one outside this computer's studio folder, so a
-- copy can't render a file of yours the band doesn't share. -> the first one's name, or nil. exists(path) -> bool.
function bounces.missing(media, root, exists)
  local low = root and (norm(root):lower() .. "/")
  for _, p in ipairs(media) do
    if (low and p:lower():sub(1, #low) ~= low) or not exists(p) then return p:match("[^/]+$") or p end
  end
end

-- The render settings the copy is saved with: Export stems' format (extras.STANDARD: `std`), each selected track a stem (3) or the master
-- mix (0, with the safety limiter as Final mix), from t0 to t1 on every computer alike (custom bounds, so a copy a moment behind can't end
-- elsewhere). Pure.
function bounces.settings(std, mix, name, t0, t1, limit)
  local s = {}
  for k, v in pairs(std) do s[k] = v end
  -- (a FLAC beside each WAV, left behind: the background's pass script renders again until two passes' FLACs are about the same size, so a
  -- sampler still loading its sounds isn't printed half silent. A WAV's size is its length alone, so with WAVs only it stopped after two)
  s.RENDER_FORMAT2 = band.FLAC
  s.RENDER_PATTERN = mix and name or "$track"
  s.RENDER_SETTINGS = mix and 0 or 3 -- (3, not 2: 2 rendered the master. FINDINGS F-0036, as extras.stems)
  s.RENDER_BOUNDSFLAG, s.RENDER_STARTPOS, s.RENDER_ENDPOS = 0, t0, t1
  s.RENDER_ADDTOPROJ = mix and 0 or 2 -- (&2: silent stems skipped)
  if mix then for k, v in pairs(limit or {}) do s[k] = v end end
  return s
end

-- Who can help, of those here on the link (peer_of: user -> peer): a status saying how busy (`cpu`) and that it renders in the background
-- (`bnc`), not recording, not a guest, at most `busy`. -> { { u, peer, cpu } } by name, and why the others can't (a guest isn't named). Pure.
function bounces.workers(peer_of, status_of, guests, busy)
  local ok, why = {}, {}
  for u, peer in pairs(peer_of) do
    local st = status_of[u]
    local cpu = type(st) == "table" and tonumber(st.cpu)
    if guests[u] then -- (a guest's computer isn't the band's to use)
    elseif not (cpu and st.bnc) then why[#why + 1] = u .. " can't render in the background (an older StudioSync, or no hidden REAPER there)"
    elseif st.recording then why[#why + 1] = u .. " is recording"
    elseif cpu > busy then why[#why + 1] = string.format("%s's computer is busy (%d%%)", u, cpu)
    else ok[#ok + 1] = { u = u, peer = peer, cpu = cpu } end
  end
  table.sort(ok, function(a, b) return a.u < b.u end)
  table.sort(why)
  return ok, why
end
-- Stems shared out: the heaviest first, each to whoever would finish it soonest (what it has already, plus this one, slowed by how busy it
-- is, plus START for a computer other than `me` that has nothing yet), among those who can (can(u, stem)). stems: { { guid, cost } };
-- workers: { { u, cpu } }. Stems with the same `group` (their file name) go together: REAPER names same-named files apart only within one
-- render, and two shares' "Bass.wav" would meet in one folder, one taken for the other. -> { [u] = { guids } }; a stem nobody can is left
-- out. Pure.
function bounces.split(stems, workers, can, me)
  local list, by, load, out = {}, {}, {}, {}
  for _, s in ipairs(stems) do
    local u = s.group and by[s.group]
    if u then u.cost, u.parts[#u.parts + 1] = u.cost + s.cost, s
    else
      u = { guid = s.guid, cost = s.cost, parts = { s } }
      list[#list + 1] = u
      if s.group then by[s.group] = u end
    end
  end
  table.sort(list, function(a, b) if a.cost ~= b.cost then return a.cost > b.cost end return a.guid < b.guid end)
  for _, s in ipairs(list) do
    local best, bt
    for _, w in ipairs(workers) do
      local all = true
      for _, p in ipairs(s.parts) do if not can(w.u, p) then all = false; break end end
      if all then
        local t = ((load[w.u] or 0) + s.cost) * (1 + (tonumber(w.cpu) or 0) / 100) + ((w.u ~= me and not load[w.u]) and bounces.START or 0)
        if not bt or t < bt or (t == bt and w.u < best) then best, bt = w.u, t end
      end
    end
    if best then
      load[best] = (load[best] or 0) + s.cost
      out[best] = out[best] or {}
      for _, p in ipairs(s.parts) do table.insert(out[best], p.guid) end
    end
  end
  return out
end
-- A stem's file name as a group key: REAPER's $track, with the characters a file name can't hold made the same. Pure.
function bounces.group_of(name) return (tostring(name or ""):lower():gsub('[%c/\\:%*%?"<>|]', "_"):gsub("^%s+", ""):gsub("[%s%.]+$", "")) end
-- Why a bandmate's share has to be redone, or nil while it's fine. st: their presence status (nil: gone). Pure.
function bounces.overdue(sh, st, now)
  if type(st) == "table" and st.recording then return sh.user .. " started recording" end
  local wait = sh.state == "sent" and bounces.SYNC_WAIT or bounces.STALL -- (sent: Syncthing still brings the files if the link doesn't)
  if now - sh.at > wait then return st and (sh.user .. "'s computer stopped answering") or (sh.user .. "'s computer went away") end
end
local WORDS = { asked = "asked", getting = "getting the project", rendering = "rendering", sent = "sending", done = "done", failed = "redone elsewhere" }
-- One line for Health and the panel: who renders how many, and how far each is. Pure.
function bounces.summary(job, me)
  local parts = {}
  for _, sh in ipairs(job.shares) do
    local w = WORDS[sh.state] or sh.state
    if sh.state == "sent" then w = string.format("sending %d/%d", sh.got or 0, #(sh.files or {})) end
    parts[#parts + 1] = string.format("%s %d %s", sh.user == me and "you" or sh.user, #sh.guids, w)
  end
  local what = job.mix and "Mix" or string.format("Stems (%d %s%s)", job.count, job.folders and "folder" or "track", job.count == 1 and "" or "s")
  local text = what .. ": " .. table.concat(parts, "; ")
  if #job.redone > 0 then text = text .. ". " .. table.concat(job.redone, ". ") end
  return text
end

-- ---- REAPER, files and the link -----------------------------------------------------------------------------------------------------------
local function now() return reaper.time_precise() end
local function bg() return require("bgrender") end
local function any_tab(bit) -- (1 playing, 4 recording)
  for i = 0, 99 do
    local p = reaper.EnumProjects(i)
    if not p then return false end
    if reaper.GetPlayStateEx(p) & bit == bit then return true end
  end
  return false
end
local function recording() return any_tab(4) end
local function xruns() return (reaper.GetUnderrunTime()) or 0 end
-- A dropout the person here could hear: while REAPER plays (stopped, it's silence, and the share renders on). rec.xruns is kept up to date.
local function dropout(rec)
  local x = xruns()
  local hit = x ~= rec.xruns and any_tab(1)
  rec.xruns = x
  return hit
end
local function publish(cfg, t)
  local st = band.ext_json(band.SECTION, "bounces " .. cfg.root) or {}
  for k, v in pairs(t) do st[k] = v end
  st.at = os.time()
  band.set_ext_json(band.SECTION, "bounces " .. cfg.root, st, false)
end
local function inbox(cfg) -- rel -> the extension's record of what arrived
  local out = {}
  for _, i in ipairs(require("direct").streams(cfg).inn) do out[i.rel] = i end
  return out
end
local function arrived(i) return i ~= nil and i.done == true and i.ok ~= false end
local function users_peers(cfg, b) return require("hops").peers_by_user(cfg, b.song, b.room) end
local function statuses(cfg, b)
  local out = {}
  for _, st in ipairs(require("presence").peers(cfg, b.song, b.room) or {}) do out[st.user] = st end
  return out
end
local function say(cfg, b, d, peer) return require("direct").send_live(cfg, bounces.KIND, d, b.song, b.room, nil, { peer }) end
-- Does this computer render bandmates' shares? (its status's `bnc`: the hidden background REAPER, and the link's streams)
function bounces.can_help() return bg().on() and require("direct").live_available() end

-- The track at i and, a folder, everything in it.
local function family(proj, i)
  local out, depth = {}, 0
  for j = i, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, j)
    out[#out + 1] = tr
    depth = depth + reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    if depth <= 0 then break end
  end
  return out
end
-- Every track a stem hears: its own (and a folder's), and whatever sends into them, theirs, and so on.
local function heard(proj, trs)
  local out, seen, k = {}, {}, 1
  local function add(tr) if tr and not seen[tr] then seen[tr] = true; out[#out + 1] = tr end end
  for _, tr in ipairs(trs) do add(tr) end
  while out[k] do
    local tr = out[k]
    for r = 0, reaper.GetTrackNumSends(tr, -1) - 1 do
      local src = reaper.GetTrackSendInfo_Value(tr, -1, r, "P_SRCTRACK")
      local n = src and math.floor(reaper.GetMediaTrackInfo_Value(src, "IP_TRACKNUMBER")) or 0
      if n > 0 then for _, t in ipairs(family(proj, n - 1)) do add(t) end end
    end
    k = k + 1
  end
  return out
end
-- What a stem needs: its tracks' plug-in keys (prints.track_keys: routed instruments too), the sounds their samplers play and the files their
-- plug-ins load (IRs, captures: ids, as lib/libraries.lua publishes who has them; presets aren't needed, the state carries the sound), whether
-- a sampler there is opaque (it can't say), and how many plug-ins (its weight).
local function needs(trs)
  local prints, libraries, content, keys, ids, opaque, fx = require("prints"), require("libraries"), require("content"), {}, {}, false, 0
  for _, tr in ipairs(trs) do
    for _, k in ipairs(prints.track_keys(tr)) do keys[#keys + 1] = k end
    for _, i in ipairs(prints.fx_all(tr)) do
      fx = fx + 1
      local sounds, files = libraries.fx_refs(tr, i)
      if sounds == false then opaque = true end
      for _, p in ipairs(sounds or {}) do ids[#ids + 1] = libraries.id(p) end
      for _, p in ipairs(files or {}) do if content.kind(p) == "file" then ids[#ids + 1] = content.id(p) end end
    end
  end
  return { keys = keys, ids = ids, opaque = opaque, fx = fx }
end
-- fn() with this computer's own tracks muted (Final mix's rule: StudioSync's helpers and tracks kept as yours aren't the band's), put back
-- after in the same call, so no look sends the mutes.
local function local_muted(proj, fn)
  local mirror, muted = require("mirror"), {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if mirror.local_track(tr) and reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") == 0 then reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1); muted[#muted + 1] = tr end
  end
  local ok, e = pcall(fn)
  for _, tr in ipairs(muted) do reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0) end
  if not ok then error(e, 0) end
end
-- One share's copy into its own job folder and the hidden REAPER started on it. -> the job { dir, started, limit }.
local function launch(dir, text, secs, n)
  reaper.RecursiveCreateDirectory(dir, 0)
  for _, f in ipairs(band.files(dir)) do os.remove(dir .. "/" .. f) end
  band.write_atomic(dir .. "/job.rpp", text)
  local limit = bg().time_limit((tonumber(secs) or 0) * math.max(1, n), 1)
  bg().launch_job(dir, math.min(limit + 180, 32767))
  return { dir = dir, started = now(), limit = limit }
end
-- A job's outcome: "done" and its WAVs (the pass script's passes.txt: its files are in place), "failed" and why, or nil while it runs.
-- (two passes for a WAV: the pass script compares FLAC sizes, so a second render always follows the first, as a sampler still loading needs)
local function poll(j)
  local d = j.dir
  if reaper.file_exists(d .. "/passes.txt") then
    bg().end_job(d) -- (done: a question stopping it from quitting mustn't keep it on, unseen)
    local files = {}
    for _, f in ipairs(band.files(d)) do if f:lower():match("%.wav$") then files[#files + 1] = f end end
    return "done", files
  end
  if (band.read(d .. "/pid.txt") or ""):match("^failed") then return "failed", "the background REAPER didn't start" end
  if reaper.file_exists(d .. "/done.txt") then return "failed", "the background REAPER quit without rendering" end
  if now() - j.started > j.limit then bg().end_job(d); return "failed", "it took too long (a plug-in may be waiting on a window nobody can see)" end
end
local function tidy(dir)
  if not dir then return end
  for _, f in ipairs(band.files(dir)) do os.remove(dir .. "/" .. f) end
  os.remove(dir)
end
-- `src` into dest/f (moved, else copied safely); one already there (Syncthing's, or the same share made twice) stands. -> true when it's there.
local function place(src, dest, f)
  local to = dest .. "/" .. f
  if reaper.file_exists(to) then os.remove(src); return true end
  reaper.RecursiveCreateDirectory(dest, 0)
  if os.rename(src, to) then return true end
  local ok = pcall(band.copy_atomic, src, to)
  if ok then os.remove(src) end
  return ok and reaper.file_exists(to)
end
-- A share's files, silent stems dropped (extras.silent: REAPER's skip-silent misses an empty MIDI part), into the song's dest folder.
-- -> { { name, size } } of those placed.
local function deliver_files(cfg, song, job, files, mix, dest)
  local out, folder = {}, band.song_dir(cfg, song) .. "/" .. dest
  for _, f in ipairs(files) do
    local src = job.dir .. "/" .. f
    if not mix and require("extras").silent(src) then os.remove(src)
    elseif bounces.file_ok(f) then
      local size = band.size(src)
      if place(src, folder, f) then out[#out + 1] = { name = f, size = size } end
    end
  end
  pcall(function() require("services").rescan(band.info(cfg.root).id, song .. "/" .. dest) end)
  return out
end

-- ---- asking (the panel, Live sync) ----------------------------------------------------------------------------------------------------------
-- The panel's buttons: what = "track" | "folder" | "mix"; sel: the time selection only. Live sync starts it at its next tick.
function bounces.ask(proj, what, sel)
  reaper.SetExtState(band.SECTION, "bounce ask " .. tostring(proj), band.json_encode({ what = what, sel = sel or nil }), false)
end
local function new_share(user, peer, guids)
  R.shares[#R.shares + 1] = { k = #R.shares + 1, user = user, peer = peer, guids = guids, state = "asked", at = now(), started = now(), placed = {}, got = 0 }
  return R.shares[#R.shares]
end
local function ask_share(cfg, b, sh)
  local rel = require("direct").stream_start(cfg, R.copy, b.song, b.room, 0, bounces.copy_name(R.id, sh.k), { sh.peer })
  if not rel then return false end
  require("direct").stream_end(cfg, rel) -- (complete: begun and ended at once, so its length and SHA-256 follow straight away)
  return say(cfg, b, { t = "ask", id = R.id, k = sh.k, from = cfg.user, guids = sh.guids, mix = R.mix or nil, dest = R.dest, root = cfg.root,
    secs = R.t1 - R.t0 }, sh.peer)
end
-- Stems (guids) shared out among the computers that can now: bandmates not tried for this bounce and not busy with a share of it, and this
-- computer unless it failed it. -> how many shares, or nil when nobody can.
local function share_out(proj, cfg, b, guids)
  local status_of, busy = statuses(cfg, b), {}
  for _, sh in ipairs(R.shares) do if sh.state ~= "done" and sh.state ~= "failed" then busy[sh.user] = true end end
  local okg, guests = pcall(require("removal").guest_names, cfg.root)
  local ws, why = bounces.workers(users_peers(cfg, b), status_of, okg and guests or {}, require("hops").BUSY)
  local list, peer_of = {}, {}
  for _, w in ipairs(ws) do
    if not R.tried[w.u] and not busy[w.u] and (not R.mix or w.u == R.hub) then list[#list + 1] = w; peer_of[w.u] = w.peer end
  end
  if not R.tried[cfg.user] then list[#list + 1] = { u = cfg.user, cpu = require("hops").cpu_now() or 50 } end
  local _, haves = require("libraries").studio(cfg)
  local prints = require("prints")
  local function can(u, s)
    if u == cfg.user then return true end
    if s.opaque or not prints.has(cfg, u, s.keys) then return false end
    for _, id in ipairs(s.ids) do if not (haves and haves[u] and haves[u][id]) then return false end end
    return true
  end
  local stems = {}
  for _, g in ipairs(guids) do stems[#stems + 1] = R.stems[g] end
  local plan = R.mix and #list > 0 and can(list[1].u, stems[1]) and { [list[1].u] = guids } or bounces.split(stems, list, can, cfg.user)
  if R.mix and #R.shares == 0 and R.hub and R.hub ~= cfg.user and not plan[R.hub] then
    R.redone[#R.redone + 1] = "Rendered here: the song's hub (" .. R.hub .. ") can't now" .. (#why > 0 and (" (" .. table.concat(why, "; ") .. ")") or "")
  end
  local users, n = {}, 0
  for u in pairs(plan) do users[#users + 1] = u end
  table.sort(users)
  for _, u in ipairs(users) do
    local sh = new_share(u, peer_of[u], plan[u])
    n = n + 1
    if u ~= cfg.user and not ask_share(cfg, b, sh) then sh.state, sh.why = "failed", "the link couldn't send " .. u .. " the project" end
  end
  return n > 0 and n or nil
end

-- Start one (Live sync, from the panel's ask). -> true, or nil and why.
function bounces.start(proj, cfg, b, req)
  if R and R.active then return nil, "A bounce is already going: wait for it to finish." end
  if reaper.GetPlayStateEx(proj) & 4 == 4 then return nil, "Stop recording first." end
  local mix, folders = req.what == "mix", req.what == "folder"
  local t0, t1 = 0, reaper.GetProjectLength(proj)
  if req.sel then
    t0, t1 = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
    if t1 <= t0 then return nil, "There's no time selection: make one, or render the whole project." end
  end
  if t1 <= t0 then return nil, "The project is empty." end
  local mirror, stems, order = require("mirror"), {}, {}
  if mix then
    local all = { reaper.GetMasterTrack(proj) }
    for i = 0, reaper.CountTracks(proj) - 1 do local tr = reaper.GetTrack(proj, i); if not mirror.local_track(tr) then all[#all + 1] = tr end end
    local n = needs(all)
    stems.MIX = { guid = "MIX", name = b.song, cost = (t1 - t0) * (1 + n.fx), keys = n.keys, ids = n.ids, opaque = n.opaque }
    order[1] = "MIX"
  else
    for i = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, i)
      if not mirror.local_track(tr) and (not folders or reaper.GetParentTrack(tr) == nil) then
        local g, n = reaper.GetTrackGUID(tr):upper(), needs(heard(proj, family(proj, i)))
        stems[g] = { guid = g, name = select(2, reaper.GetTrackName(tr)), cost = (t1 - t0) * (1 + n.fx), keys = n.keys, ids = n.ids, opaque = n.opaque,
          group = bounces.group_of(select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false))) }
        order[#order + 1] = g
      end
    end
    if #order == 0 then return nil, "There are no shared tracks to render." end
  end
  local id = os.date("!%Y%m%d%H%M%S") .. "-" .. string.format("%04x", math.random(0, 0xffff))
  local name = mix and band.clean(string.format("%s %s %s", b.song, os.date("%Y-%m-%d %H%M%S"), cfg.user)) or nil
  local dir = bg().TMP .. "/bounce-" .. id
  reaper.RecursiveCreateDirectory(dir, 0)
  local extras = require("extras")
  local set = bounces.settings(extras.STANDARD(proj), mix, name, t0, t1, band.LIMIT)
  local copy = dir .. "/copy.rpp"
  local saved = extras.save_render(proj)
  local ok, e = pcall(local_muted, proj, function() extras.set_render(proj, set); band.save_copy(proj, copy) end)
  extras.set_render(proj, saved)
  if not ok or not reaper.file_exists(copy) then tidy(dir); return nil, "The project's copy couldn't be saved: " .. tostring(e or "no file") end
  local _, media = bounces.prepare(band.read(copy) or "", nil, cfg.root, cfg.root)
  local gone = bounces.missing(media, nil, reaper.file_exists)
  if gone then tidy(dir); return nil, "A file the project plays isn't on this computer (" .. gone .. "): wait for it to arrive, then try again." end
  local v = mix and require("hub").view(cfg, b.song)
  R = { id = id, active = true, proj = proj, mix = mix, folders = folders, count = #order, stems = stems, order = order, t0 = t0, t1 = t1,
    dest = mix and "mixes" or ("stems/" .. os.date("%Y-%m-%d %H%M") .. " " .. band.clean(cfg.user)), name = name, dir = dir, copy = copy,
    settings = set, front = not bg().on(), shares = {}, tried = {}, redone = {}, started = now(), hub = v and v.hub or nil }
  if not share_out(proj, cfg, b, order) then R.active = false; tidy(dir); return nil, "Nobody can render it, not even this computer." end
  band.log(bounces.summary(R, cfg.user))
  return true
end

-- In front, when this computer has no hidden REAPER (Linux by default, a Mac without the helpers): your own ask, so it holds REAPER a moment
-- as Export stems does. The same settings, the share's tracks selected; your selection and render settings put back.
local function render_front(proj, sh, dir)
  if reaper.EnumProjects(-1) ~= proj then return "failed", "bring the song's tab to the front: it renders in front on this computer" end
  local extras, sel, was = require("extras"), {}, {}
  for _, g in ipairs(sh.guids) do sel[g] = true end
  reaper.RecursiveCreateDirectory(dir, 0)
  local saved = extras.save_render(proj)
  local ok, e = pcall(local_muted, proj, function()
    for i = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, i)
      was[tr] = reaper.IsTrackSelected(tr)
      reaper.SetTrackSelected(tr, sel[reaper.GetTrackGUID(tr):upper()] == true)
    end
    extras.set_render(proj, R.settings)
    reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", dir, true)
    reaper.Main_OnCommand(42230, 0) -- File: Render project, most recent settings, auto-close dialog
  end)
  extras.set_render(proj, saved)
  for tr, s in pairs(was) do if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then reaper.SetTrackSelected(tr, s) end end
  if not ok then return "failed", tostring(e) end
  local files = {}
  for _, f in ipairs(band.files(dir)) do if f:lower():match("%.wav$") then files[#files + 1] = f end end
  return "done", files
end
local function local_tick(proj, cfg, b, sh)
  local st, x
  if not sh.job then
    local dir = R.dir .. "-" .. sh.k
    if R.front then sh.job = { dir = dir }; st, x = render_front(proj, sh, dir)
    else
      local sel = {}
      for _, g in ipairs(sh.guids) do sel[g] = true end
      sh.job = launch(dir, (bounces.prepare(band.read(R.copy) or "", not R.mix and sel or nil, cfg.root, cfg.root)), R.t1 - R.t0, #sh.guids)
      sh.xruns, sh.state = xruns(), "rendering"
      return
    end
  elseif recording() then st, x = "failed", "you started recording"
  elseif dropout(sh) then st, x = "failed", "your REAPER had an audio dropout"
  else st, x = poll(sh.job) end
  if st == "failed" then if not R.front then bg().end_job(sh.job.dir) end; sh.state, sh.why = "failed", x end
  if st == "done" then
    local placed = deliver_files(cfg, b.song, sh.job, x, R.mix, R.dest)
    sh.files, sh.got, sh.state, sh.at = placed, #placed, "done", now()
  end
  if st then tidy(sh.job.dir) end
end
-- A bandmate's files once they say they're sent: from the link's inbox, or already in the folder (Syncthing got there first).
local function collect(cfg, b, sh)
  local dest, inn, all = band.song_dir(cfg, b.song) .. "/" .. R.dest, nil, true
  for _, f in ipairs(sh.files or {}) do
    if not sh.placed[f.name] then
      if band.size(dest .. "/" .. f.name) == f.size then sh.placed[f.name] = true
      else
        inn = inn or inbox(cfg)
        local rel = b.song .. "/" .. bounces.link_name(R.id, sh.k, f.name)
        if arrived(inn[rel]) and place(require("direct").stream_path(cfg, rel), dest, f.name) then sh.placed[f.name] = true; sh.at = now()
        else all = false end
      end
      if sh.placed[f.name] then sh.got = sh.got + 1 end
    end
  end
  if all then
    sh.state = "done"
    pcall(function() require("services").rescan(band.info(cfg.root).id, b.song .. "/" .. R.dest) end)
  end
end
local function finish(cfg, b)
  R.active = false
  local n, who = 0, {}
  for _, sh in ipairs(R.shares) do
    if sh.state == "done" then n = n + #(sh.files or {}); who[sh.user == cfg.user and "you" or sh.user] = true end
  end
  local names = {}
  for u in pairs(who) do names[#names + 1] = u end
  table.sort(names)
  local folder = b.song .. "/" .. R.dest
  local text = R.mix and string.format("Mix rendered by %s: %s.wav in %s", table.concat(names, ", "), R.name, folder)
    or string.format("%d stem%s in %s, rendered by %s in %d s", n, n == 1 and "" or "s", folder, table.concat(names, ", "), math.floor(now() - R.started + 0.5))
  band.log(text)
  publish(cfg, { text = text, active = false })
  pcall(function() require("page_chat").post(cfg, b, (R.mix and "New mix: " or "Stems for whoever mixes: ") .. text) end)
  tidy(R.dir)
end
-- This computer's bounce ends before it's done: the helpers still at it told, its own renders ended.
local function stop(cfg, b, text)
  for _, sh in ipairs(R.shares) do
    if sh.state ~= "done" and sh.state ~= "failed" then
      if sh.user ~= cfg.user then say(cfg, b, { t = "cancel", id = R.id, k = sh.k }, sh.peer)
      elseif sh.job and sh.job.started then bg().end_job(sh.job.dir); tidy(sh.job.dir) end
    end
  end
  R.active = false
  publish(cfg, { text = text, active = false })
  band.log("bounce: " .. text)
  tidy(R.dir)
end
local function requester_tick(proj, cfg, b)
  local t, status_of = now(), nil
  for _, sh in ipairs(R.shares) do
    if sh.state ~= "done" and sh.state ~= "failed" then
      if sh.user == cfg.user then local_tick(proj, cfg, b, sh)
      else
        if sh.state == "sent" then collect(cfg, b, sh) end
        status_of = status_of or statuses(cfg, b)
        local why = sh.state ~= "done" and bounces.overdue(sh, status_of[sh.user], t)
        if why then sh.state, sh.why = "failed", why end
      end
    end
  end
  for _, sh in ipairs(R.shares) do
    if sh.state == "failed" and not sh.redone then
      sh.redone, R.tried[sh.user] = true, true
      if sh.user ~= cfg.user then say(cfg, b, { t = "cancel", id = R.id, k = sh.k }, sh.peer) end
      local n = share_out(proj, cfg, b, sh.guids)
      local by = {}
      for i = #R.shares - (n or 0) + 1, #R.shares do by[#by + 1] = R.shares[i].user == cfg.user and "you" or R.shares[i].user end
      R.redone[#R.redone + 1] = string.format("%s: %s; %s", sh.user == cfg.user and "Yours" or (sh.user .. "'s"), sh.why or "failed",
        n and ("redone by " .. table.concat(by, ", ")) or "nobody can redo it")
      band.log("bounce: " .. R.redone[#R.redone])
      if not n then return stop(cfg, b, bounces.summary(R, cfg.user) .. ". Stopped: try again, or Export stems renders it all here.") end
    end
  end
  local left = false
  for _, sh in ipairs(R.shares) do if sh.state ~= "done" and sh.state ~= "failed" then left = true end end
  if left then publish(cfg, { text = bounces.summary(R, cfg.user), active = true }) else finish(cfg, b) end
end

-- ---- helping (a bandmate's share) ------------------------------------------------------------------------------------------------------------
local function tell(cfg, b, h)
  h.said = now()
  say(cfg, b, { t = "state", id = h.id, k = h.k, user = cfg.user, state = h.state, why = h.why, files = h.files }, h.peer)
end
local function refuse(cfg, b, d, peer, why)
  say(cfg, b, { t = "state", id = d.id, k = d.k, user = cfg.user, state = "failed", why = why }, peer)
end
local function helper_ask(cfg, b, d)
  if type(d.from) ~= "string" or type(d.guids) ~= "table" or type(d.root) ~= "string" or not bounces.dest_ok(d.dest) or not plain(d.id) then return end
  for _, g in ipairs(d.guids) do if type(g) ~= "string" or not g:match("^[%x{}%-MIX]+$") then return end end
  local peer = users_peers(cfg, b)[d.from]
  local okg, guests = pcall(require("removal").guest_names, cfg.root)
  if not peer or (okg and guests[d.from]) then return end -- (only a bandmate here on the link, never a guest, can use this computer)
  local busy = false
  for _, h in pairs(H) do if h.state ~= "sent" then busy = true end end
  local why = busy and (cfg.user .. "'s computer is rendering another share") or recording() and (cfg.user .. " is recording")
    or not bounces.can_help() and (cfg.user .. "'s computer can't render in the background")
    or (require("hops").cpu_now() or 50) > require("hops").BUSY and (cfg.user .. "'s computer is busy")
  if why then return refuse(cfg, b, d, peer, why) end
  local k = math.floor(tonumber(d.k) or 0)
  H[d.id .. "-" .. k] = { id = d.id, k = k, from = d.from, peer = peer, guids = d.guids, mix = d.mix == true, dest = d.dest, root = d.root,
    secs = tonumber(d.secs) or 0, state = "getting", started = now() }
  tell(cfg, b, H[d.id .. "-" .. k])
end
local function helper_start(cfg, h, path)
  local sel = {}
  for _, g in ipairs(h.guids) do sel[g:upper()] = true end
  local text, media = bounces.prepare(band.read(path) or "", not h.mix and sel or nil, h.root, cfg.root)
  os.remove(path)
  local gone = bounces.missing(media, cfg.root, reaper.file_exists)
  if gone then return "a file the project plays isn't on " .. cfg.user .. "'s computer yet (" .. gone .. ")" end
  h.job = launch(bg().TMP .. "/bounce-" .. h.id .. "-" .. h.k, text, h.secs, #h.guids)
  h.state, h.xruns = "rendering", xruns()
end
local function helper_tick(proj, cfg, b)
  local t = now()
  for key, h in pairs(H) do
    local why
    if h.state == "getting" then
      local rel = b.song .. "/" .. bounces.copy_name(h.id, h.k)
      if arrived(inbox(cfg)[rel]) then why = helper_start(cfg, h, require("direct").stream_path(cfg, rel))
      elseif t - h.started > 2 * bounces.STALL then why = "the project's copy didn't arrive on " .. cfg.user .. "'s computer" end
    elseif h.state == "rendering" then
      -- (the person here comes first: their recording or a dropout in their session ends the share at once, and it's redone elsewhere)
      if recording() then why = cfg.user .. " started recording"
      elseif dropout(h) then why = cfg.user .. "'s REAPER had an audio dropout" end
      if why then bg().end_job(h.job.dir)
      else
        local st, x = poll(h.job)
        if st == "failed" then why = x .. " on " .. cfg.user .. "'s computer"
        elseif st == "done" then
          h.files = deliver_files(cfg, b.song, h.job, x, h.mix, h.dest)
          local folder = band.song_dir(cfg, b.song) .. "/" .. h.dest
          for _, f in ipairs(h.files) do
            local rel = require("direct").stream_start(cfg, folder .. "/" .. f.name, b.song, b.room, 0, bounces.link_name(h.id, h.k, f.name), { h.peer })
            if rel then require("direct").stream_end(cfg, rel) end
          end
          h.state, h.sent_at, h.said = "sent", t, nil
          tidy(h.job.dir)
        end
      end
    end
    if why then
      h.state, h.why, h.said = "failed", why, nil -- (said at once)
      if h.job then tidy(h.job.dir) end
      band.log("bounce for " .. h.from .. ": " .. why)
    end
    if not h.said or t - h.said >= bounces.NEWS then tell(cfg, b, h) end
    if h.state == "failed" or (h.state == "sent" and t - h.sent_at > bounces.KEEP_SAYING) then H[key] = nil end
  end
  local n, from = 0, nil
  for _, h in pairs(H) do if h.state ~= "sent" then n, from = n + #h.guids, h.from end end
  publish(cfg, { helping = from and string.format("Rendering %d of %s's %s here, in the background", n, from, n == 1 and "stem" or "stems") or false })
end

-- ---- Live sync ---------------------------------------------------------------------------------------------------------------------------
-- A "bounce" message: an ask or a cancel for this computer, or how a share of this computer's bounce is going.
function bounces.on_msg(proj, cfg, b, d)
  if type(d) ~= "table" or type(d.id) ~= "string" then return end
  if d.t == "ask" then helper_ask(cfg, b, d)
  elseif d.t == "cancel" then
    local key = d.id .. "-" .. math.floor(tonumber(d.k) or 0)
    local h = H[key]
    if h then if h.job then bg().end_job(h.job.dir); tidy(h.job.dir) end; H[key] = nil end
  elseif d.t == "state" and R and R.active and R.id == d.id then
    local sh = R.shares[tonumber(d.k) or 0]
    if not (sh and sh.user == d.user) or sh.state == "done" or sh.state == "failed" then return end
    sh.at = now()
    if d.state == "failed" then sh.state, sh.why = "failed", type(d.why) == "string" and d.why or "it failed"
    elseif d.state == "getting" or d.state == "rendering" then sh.state = d.state
    elseif d.state == "sent" and type(d.files) == "table" then
      local files = {}
      for _, f in ipairs(d.files) do
        if type(f) == "table" and bounces.file_ok(f.name) and tonumber(f.size) then files[#files + 1] = { name = f.name, size = tonumber(f.size) } end
      end
      sh.state, sh.files = "sent", files
    end
  end
end
-- Each Live sync tick: a new ask from the panel, this computer's bounce, and the shares it renders for bandmates.
function bounces.tick(proj, cfg, b)
  local key = "bounce ask " .. tostring(proj)
  local ask = reaper.GetExtState(band.SECTION, key)
  if ask ~= "" then
    reaper.DeleteExtState(band.SECTION, key, false)
    local req = band.json_decode(ask)
    local ok, why = bounces.start(proj, cfg, b, type(req) == "table" and req or {})
    if not ok then band.log("bounce: " .. tostring(why)); publish(cfg, { text = why, active = false }) end
    tick_at = -math.huge
  end
  if now() - tick_at < bounces.EVERY then return end
  tick_at = now()
  if R and R.active and R.proj == proj then requester_tick(proj, cfg, b) end
  if next(H) then helper_tick(proj, cfg, b) end
end
-- Live sync stopping: the shares rendered here end and say so (redone elsewhere), and this computer's bounce tells its helpers.
function bounces.on_exit(cfg, b)
  for _, h in pairs(H) do
    if h.job then bg().end_job(h.job.dir); tidy(h.job.dir) end
    if h.state ~= "sent" then h.state, h.why = "failed", cfg.user .. "'s Live sync stopped"; tell(cfg, b, h) end
  end
  H = {}
  if R and R.active then stop(cfg, b, "The bounce stopped with Live sync.") end
end
-- Health's row: this computer's bounce as it goes (or how the last one ended, for 10 minutes), and the shares it renders for bandmates.
function bounces.health_row(cfg)
  local st = band.ext_json(band.SECTION, "bounces " .. cfg.root)
  if type(st) ~= "table" or os.time() - (tonumber(st.at) or 0) > (st.active and 120 or 600) then return nil end
  local text = table.concat((function()
    local t = {}
    if type(st.text) == "string" then t[#t + 1] = st.text end
    if type(st.helping) == "string" then t[#t + 1] = st.helping end
    return t
  end)(), ". ")
  if text == "" then return nil end
  return { "bounces", true, "grey", text, text }
end
function bounces.panel_line(cfg) local r = bounces.health_row(cfg); return r and r[4] end

-- (tests: the state, to look at and to start clean)
function bounces._state() return R, H end
function bounces._reset() R, H, tick_at = nil, {}, -math.huge end

return bounces
