-- The drawing layer (docs/realtime-roadmap.md "What the web UI makes possible": Drawing; rt-draw): the panel's Draw tool (StudioSync -
-- Draw.lua) and the web UI's (lib/webui/draw.js, over the Project and Mixer pages, the phone's Project view, and on the History page at the
-- time each was drawn) are one layer: each drawing is a file in rooms/<room>/drawings/ in the panel's own form, synced like chat as ever.
--   { user, time, kind, points = { { time, track oid, place down the track 0-1 } }, color = 0xRRGGBBAA, size, text }
-- A drawing over the Mixer page says view = "mixer", its points { place down the strip 0-1, the strip's track oid, place across it 0-1 }
-- (the panel shows only arrange-view ones). A file's name is its id. Live for everyone over the direct link: a drawing goes as a "draw"
-- message the moment it's made (and a removal too), shown at once until its file arrives (the file is the record, as chat's messages).
-- Anyone in the room draws; you remove your own, admins (groups.may_manage) any. (James, rt)
-- rt-draw2: the pages' Undo and Redo of your own drawings (webdraw.step); a note drawn on a screen share is kept as its author's own drawing,
-- from = "share" (lib/webui/call.js -> draw.js shareNote), and Clear share notes takes yours away.
local band = require("band")
local webdraw = {}
webdraw.KINDS = { pen = true, marker = true, line = true, arrow = true, box = true, circle = true, text = true }
webdraw.POINTS_MAX = 400       -- points in one drawing from a page or the link (draw.js thins a long stroke to fit)
webdraw.READ_POINTS_MAX = 5000 -- a file with more is skipped (the panel's pen adds a point a frame)
webdraw.TEXT_MAX = 200         -- characters of a text drawing
webdraw.ROOM_MAX = 2000        -- drawings in a room: a page's add past it is refused
webdraw.LIVE_MAX = 500         -- drawings from the link waiting for their files
webdraw.LIVE_FOR = 600         -- seconds a drawing or removal from the link waits for its file (or its file's deletion)
webdraw.TOPIC_MAX = 400        -- drawings the pages get (the newest)
webdraw.TOPIC_POINTS = 60000   -- points in all of them (a long stroke thinned for the page past its share)
webdraw.LIST_EVERY = 1         -- seconds between looks at the folder (and at once after a change here or from the link)
webdraw.STEPS_MAX = 50         -- things a page did that Undo remembers, for each room and view

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local function fin(x, lim) return type(x) == "number" and x == x and math.abs(x) <= lim end
function webdraw.id_ok(id)
  return type(id) == "string" and #id <= 120 and id:match("^[%w%-_]+%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+$") ~= nil
end
function webdraw.oid_ok(k) return type(k) == "string" and #k <= 80 and k:match("^[%w][%w%-_%.]*$") ~= nil end
-- A drawing as kept (a file, or one from the link): the panel's own check (each point a { number, name or false, number }: one bad file stopped
-- the drawings for everyone, Review 0.58.98) and the rest bounded. -> true or false.
function webdraw.valid(s)
  if type(s) ~= "table" or type(s.points) ~= "table" or #s.points < 1 or #s.points > webdraw.READ_POINTS_MAX then return false end
  if s.kind ~= nil and not webdraw.KINDS[s.kind] then return false end
  if s.view ~= nil and s.view ~= "mixer" then return false end
  if s.user ~= nil and (type(s.user) ~= "string" or #s.user > 64) then return false end
  if s.time ~= nil and type(s.time) ~= "string" then return false end
  if s.text ~= nil and (type(s.text) ~= "string" or #s.text > webdraw.TEXT_MAX * 4) then return false end
  if s.color ~= nil and not (fin(s.color, 0xFFFFFFFF) and s.color >= 0) then return false end
  if s.size ~= nil and not (fin(s.size, 64) and s.size > 0) then return false end
  for _, p in ipairs(s.points) do
    if not (type(p) == "table" and fin(p[1], 1e7) and (webdraw.oid_ok(p[2]) or p[2] == false) and fin(p[3], 1000)) then return false end
  end
  return true
end
-- "#rrggbb" -> 0xRRGGBBFF (the panel's form), or nil.
function webdraw.colour_in(c)
  local h = type(c) == "string" and c:match("^#(%x%x%x%x%x%x)$")
  return h and ((tonumber(h, 16) << 8) | 0xFF) or nil
end
local function r3(x) return math.floor(x * 1000 + 0.5) / 1000 end
local function clamp(x, a, z) return math.max(a, math.min(z, x)) end
-- A page's new drawing ({ kind, view, pts = { { t, oid, d } }, color = "#rrggbb", size, text }) -> the drawing to keep (no user or time yet),
-- or nil and why. An arrange-view point's place down its track is kept 0-1 (the panel's), a mixer one's both places.
function webdraw.clean(a)
  if type(a) ~= "table" or not webdraw.KINDS[a.kind] then return nil, "not a kind of drawing" end
  if a.view ~= nil and a.view ~= "mixer" then return nil, "not a view drawings go on" end
  local pts = type(a.pts) == "table" and a.pts or {}
  local n = #pts
  local want = a.kind == "text" and 1 or (a.kind == "pen" or a.kind == "marker") and 0 or 2
  if n < 1 or n > webdraw.POINTS_MAX or (want > 0 and n ~= want) or (want == 0 and n < 2) then return nil, "not a drawing's points" end
  local mixer = a.view == "mixer"
  local out = {}
  for i, p in ipairs(pts) do
    if not (type(p) == "table" and fin(p[1], 1e7) and webdraw.oid_ok(p[2]) and fin(p[3], 1000)) then return nil, "not a place on the song" end
    if mixer and not (p[1] >= -0.2 and p[1] <= 1.2 and p[3] >= -0.2 and p[3] <= 1.2) then return nil, "not a place on a strip" end
    out[i] = mixer and { r3(clamp(p[1], 0, 1)), p[2], r3(clamp(p[3], 0, 1)) } or { r3(p[1]), p[2], r3(clamp(p[3], 0, 1)) }
  end
  local s = { kind = a.kind, points = out, view = mixer and "mixer" or nil, color = webdraw.colour_in(a.color),
    size = (a.size == 2 or a.size == 4 or a.size == 8) and a.size or 4,
    from = (a.from == "share" and not mixer) and "share" or nil } -- (a note drawn on a screen share: Clear share notes takes these)
  if a.kind == "text" then
    local t = type(a.text) == "string" and a.text:gsub("%c", " "):match("^%s*(.-)%s*$") or ""
    if t == "" or not utf8.len(t) or utf8.len(t) > webdraw.TEXT_MAX then return nil, "no words, or too many" end
    s.text = t
  end
  return s
end
-- The pages' topic. list: read's drawings (each with id); tracks: { { oid, REAPER's track number, name } } as the Song page shows them;
-- colours: user -> 0xRRGGBB. -> { key, me, admin, tracks, list = { { id, u, t (UTC s), k, c ("#rrggbb"), w, x, v, o (oids), p (flat t, oid#, d) } } }
local function hex(rgb) return rgb and string.format("#%06x", rgb & 0xFFFFFF) or nil end
function webdraw.model(key, list, tracks, colours, me, admin)
  colours = colours or {}
  local sorted = {}
  for _, s in ipairs(list or {}) do sorted[#sorted + 1] = s end
  table.sort(sorted, function(a, z) return (tostring(a.time or "") .. a.id) > (tostring(z.time or "") .. z.id) end) -- (newest first, to cut)
  local epoch = require("webhistory").epoch
  local out, budget = {}, webdraw.TOPIC_POINTS
  for i = 1, math.min(#sorted, webdraw.TOPIC_MAX) do
    local s = sorted[i]
    local pts = s.points
    local share = math.max(2, math.floor(budget / math.max(1, math.min(#sorted, webdraw.TOPIC_MAX) - i + 1)))
    local step = #pts > share and #pts / share or 1
    local o, oix, p = {}, {}, {}
    local function put(q)
      local k = q[2]
      if k == false then return end
      if not oix[k] then o[#o + 1] = k; oix[k] = #o - 1 end
      p[#p + 1] = r3(q[1]); p[#p + 1] = oix[k]; p[#p + 1] = r3(q[3])
    end
    if step == 1 then for _, q in ipairs(pts) do put(q) end
    else
      local f = 1
      while f <= #pts do put(pts[math.floor(f)]); f = f + step end
      if math.floor(f - step) < #pts then put(pts[#pts]) end -- (a thinned stroke still ends where it ended)
    end
    budget = budget - #p // 3
    local c = math.tointeger(s.color)
    out[#out + 1] = { id = s.id, u = s.user, t = epoch(s.time), k = s.kind or "pen", c = c and hex(c >> 8) or hex(colours[s.user]),
      w = tonumber(s.size) or 3, x = s.kind == "text" and s.text or nil, v = s.view, o = o, p = p, live = s.live or nil,
      sh = s.from == "share" or nil }
  end
  return { key = key, me = me, admin = admin or nil, tracks = tracks or {}, list = out, more = #sorted > #out and #sorted - #out or nil }
end
-- A page's action ({ topic = "draw", ... }) -> { add = drawing } or { remove = { ids } } or { clear = "mine"|"all" (share: only your
-- notes from a screen share) } or { step = "undo"|"redo", view }, or nil and why.
function webdraw.parse(a)
  if type(a) ~= "table" then return nil end
  if a.add ~= nil then
    local s, why = webdraw.clean(a.add)
    if not s then return nil, why end
    return { add = s }
  end
  if a.remove ~= nil then
    local ids = type(a.remove) == "table" and a.remove or { a.remove }
    if #ids < 1 or #ids > 50 then return nil, "not drawings to remove" end
    for _, id in ipairs(ids) do if not webdraw.id_ok(id) then return nil, "not a drawing" end end
    return { remove = ids }
  end
  if a.share ~= nil then return (a.clear == "mine" and a.share == true) and { clear = "mine", share = true } or nil end
  if a.clear == "mine" or a.clear == "all" then return { clear = a.clear } end
  if a.undo == true or a.redo == true then
    if a.view ~= nil and a.view ~= "mixer" then return nil, "not a view drawings go on" end
    return { step = a.undo == true and "undo" or "redo", view = a.view }
  end
  return nil
end
-- May `by` remove a drawing `author` made? Their own, or anyone's when they may manage the studio.
function webdraw.may_remove(by, author, admin) return type(by) == "string" and (by == author or admin == true) end

-- ---- the folder, and drawings from the link before their files -------------------------------------------------------------------------
local live = {}  -- path -> { s, at }: drawings from the link whose files aren't here yet
local tombs = {} -- path -> { at, del }: removed (del: here, so its file goes when it arrives; else from the link: hidden until it's gone)
local files = {} -- path -> the drawing as read (files never change: a drawing is made once and only ever deleted)
local cache = { dir = nil, at = -math.huge, list = {} }
local dirty = true
function webdraw.dir(cfg, b) return band.song_dir(cfg, b.song) .. "/rooms/" .. (b.room or "main") .. "/drawings" end -- (sync.room_dir's, the panel's folder)
function webdraw.forget() cache.at, dirty = -math.huge, true end
-- Every drawing in the room now: its files, those from the link not here yet, less those removed. Each in the panel's form with `id`,
-- `file` (its path, there or to come) and `live` (from the link). Kept LIST_EVERY s.
function webdraw.read(cfg, b)
  local d = webdraw.dir(cfg, b)
  local now = reaper.time_precise()
  if d == cache.dir and not dirty and now - cache.at < webdraw.LIST_EVERY then return cache.list end
  cache.dir, cache.at, dirty = d, now, false
  local list, seen = {}, {}
  for path, t in pairs(tombs) do
    if now - t.at > webdraw.LIVE_FOR then
      -- (a removal from the link was checked when it came: if Syncthing's deletion still hasn't, the file goes here, or it would show again)
      if not t.del then pcall(os.remove, path) end
      tombs[path] = nil
    end
  end
  for _, f in ipairs(band.files(d, ".json")) do
    local path, id = d .. "/" .. f, f:sub(1, -6)
    seen[path] = true
    local t = tombs[path]
    if t and t.del then os.remove(path) -- (removed here before its file had come)
    elseif not t then
      local s = files[path]
      if s == nil then
        s = band.read_json(path)
        s = webdraw.valid(s) and s or false
        if s then s.id, s.file = id, path end
        files[path] = s
      end
      if s then list[#list + 1] = s end
    end
  end
  for path in pairs(files) do if not seen[path] then files[path] = nil end end
  for path, l in pairs(live) do
    if seen[path] or now - l.at > webdraw.LIVE_FOR then live[path] = nil
    elseif path:sub(1, #d + 1) == d .. "/" and not tombs[path] then list[#list + 1] = l.s end
  end
  table.sort(list, function(a, z) return (tostring(a.time or "") .. a.id) < (tostring(z.time or "") .. z.id) end)
  cache.list = list
  return list
end
local function admin_of(cfg, user)
  local ok, m = pcall(require("groups").may_manage, cfg.root, user)
  return ok and m == true
end
local function send(cfg, b, d, id)
  d.song, d.room = b.song, b.room or "main"
  return require("direct").send_live(cfg, "draw", d, b.song, b.room or "main", id)
end
-- A new drawing (a page's, or the panel's: s in the panel's form): its file, and to those here at once. -> its id.
-- (time: one Undo took away and Redo puts back keeps the time it was drawn, so History still shows it then.)
local made = 0
function webdraw.save(cfg, b, s, time)
  local d = webdraw.dir(cfg, b)
  reaper.RecursiveCreateDirectory(d, 0)
  made = made + 1
  s.user, s.time = cfg.user, time or os.date("!%Y-%m-%dT%H:%M:%SZ")
  -- (the panel's own name form; the number from this script's count and a random part, so the panel and Live sync never pick the same)
  local id = string.format("%s-%s-%d", (cfg.user:gsub("[^%w%-_]", "_")), os.date("!%Y%m%d-%H%M%S"), made * 1000000 + math.random(0, 999999))
  band.write_json(d .. "/" .. id .. ".json", s)
  webdraw.forget()
  local v = {}
  for k, x in pairs(s) do if k ~= "id" and k ~= "file" and k ~= "live" then v[k] = x end end
  send(cfg, b, { name = id, v = v }, id)
  return id
end
-- Remove drawings by id, as `by` (admin: may remove anyone's). -> how many went, how many were refused.
function webdraw.remove(cfg, b, ids, by, admin)
  local want = {}
  for _, id in ipairs(ids) do want[id] = true end
  local gone, refused = {}, 0
  for _, s in ipairs(webdraw.read(cfg, b)) do
    if want[s.id] then
      if webdraw.may_remove(by, s.user, admin) then
        if reaper.file_exists(s.file) then os.remove(s.file) else tombs[s.file] = { at = reaper.time_precise(), del = true } end
        live[s.file] = nil
        gone[#gone + 1] = s.id
      else refused = refused + 1 end
    end
  end
  if #gone > 0 then
    webdraw.forget()
    for i = 1, #gone, 500 do send(cfg, b, { gone = { table.unpack(gone, i, math.min(#gone, i + 499)) }, by = by }, "gone-" .. gone[i] .. "-" .. math.random(0, 999999)) end
  end
  return #gone, refused
end
-- A "draw" message from the link (Live sync's handlers, or the panel's own poll). -> true when it changed what shows.
function webdraw.from_msg(cfg, d)
  local direct = require("direct")
  if type(d) ~= "table" or not direct.plain(d.song) or not direct.plain(d.room) then return false end
  local dir = webdraw.dir(cfg, d)
  local now = reaper.time_precise()
  if d.v ~= nil then
    local s = d.v
    if not (webdraw.id_ok(d.name) and webdraw.valid(s) and type(s.user) == "string" and s.user ~= cfg.user and type(s.time) == "string") then return false end
    local path = dir .. "/" .. d.name .. ".json"
    if live[path] or tombs[path] or reaper.file_exists(path) then return false end
    local n = 0
    for _ in pairs(live) do n = n + 1 end
    if n >= webdraw.LIVE_MAX then return false end
    s.id, s.file, s.live = d.name, path, true
    live[path] = { s = s, at = now }
    webdraw.forget()
    return true
  end
  if type(d.gone) == "table" and type(d.by) == "string" and d.by ~= cfg.user and #d.gone <= 500 then
    -- (only what `by` may remove: their own, or anyone's when this studio's roles say they manage it)
    local admin, byid, changed = admin_of(cfg, d.by), {}, false
    for _, s in ipairs(webdraw.read(cfg, d)) do byid[s.id] = s end
    for _, id in ipairs(d.gone) do
      local s = webdraw.id_ok(id) and byid[id]
      if s and webdraw.may_remove(d.by, s.user, admin) then
        tombs[s.file] = { at = now, del = false }
        live[s.file] = nil
        changed = true
      end
    end
    if changed then webdraw.forget() end
    return changed
  end
  return false
end
-- The panel's Draw tool (another script): the link's drawings and removals, read from its own place in the extension's messages.
function webdraw.take_live(cfg, b)
  local direct = require("direct")
  local ok, msgs = pcall(direct.messages, cfg)
  if ok then direct.dispatch(msgs, b.song, b.room or "main", { draw = function(d) webdraw.from_msg(cfg, d) end }) end
end

-- ---- the pages' Undo and Redo (rt-draw2) -----------------------------------------------------------------------------------------------
-- What this computer's pages did in each room and view, newest last. A step is { ids } (drawings of yours that are there: taken back by
-- removing them) or { gone } (drawings of yours taken away with the Eraser: taken back by saving them again, as new files with the times
-- they were drawn). Taking a step back turns it into its opposite on the other pile. Only ever your own drawings: an admin's eraser on
-- someone else's, and Clear, aren't steps. Kept while Live sync runs.
local steps = {} -- the room's folder .. "|" .. view -> { undo = {}, redo = {} }
local function steps_of(cfg, b, view)
  local k = webdraw.dir(cfg, b) .. "|" .. (view or "")
  steps[k] = steps[k] or { undo = {}, redo = {} }
  return steps[k]
end
local function push(pile, e)
  pile[#pile + 1] = e
  if #pile > webdraw.STEPS_MAX then table.remove(pile, 1) end
end
local function did(cfg, b, view, e) -- a page did something new: Undo has it, and there's nothing to Redo any more
  local st = steps_of(cfg, b, view)
  push(st.undo, e)
  st.redo = {}
end
local renamed = {} -- a drawing put back is a new file: its old id -> its new one, so the steps before still find it
local function now_id(id)
  while renamed[id] do id = renamed[id] end
  return id
end
local function flip(cfg, b, e) -- -> the opposite step, or nil when nothing of it is left to take back
  if e.ids then
    local want, gone, ids = {}, {}, {}
    for _, id in ipairs(e.ids) do want[now_id(id)] = true end
    for _, s in ipairs(webdraw.read(cfg, b)) do if want[s.id] and s.user == cfg.user then gone[#gone + 1] = s; ids[#ids + 1] = s.id end end
    if #ids == 0 then return nil end
    webdraw.remove(cfg, b, ids, cfg.user, false)
    return { gone = gone }
  end
  local ids = {}
  for _, s in ipairs(e.gone) do
    if #webdraw.read(cfg, b) >= webdraw.ROOM_MAX then break end
    local v = {}
    for k, x in pairs(s) do if k ~= "id" and k ~= "file" and k ~= "live" then v[k] = x end end
    ids[#ids + 1] = webdraw.save(cfg, b, v, type(s.time) == "string" and s.time or nil)
    renamed[s.id] = ids[#ids]
  end
  return #ids > 0 and { ids = ids } or nil
end
-- Undo or Redo on one view (nil: the arrange view; "mixer"). Undo with nothing a page did here takes your newest drawing on that view, as
-- the panel's Undo does. -> true when something changed.
function webdraw.step(cfg, b, which, view)
  local st = steps_of(cfg, b, view)
  local from, to = st[which], st[which == "undo" and "redo" or "undo"]
  local e = table.remove(from)
  if not e and which == "undo" then
    for _, s in ipairs(webdraw.read(cfg, b)) do if s.user == cfg.user and s.view == view then e = { ids = { s.id } } end end -- (read's order: the newest last)
  end
  while e do
    local back = flip(cfg, b, e)
    if back then push(to, back); return true end
    e = table.remove(from) -- (its drawings went some other way: the step before it)
  end
  return false
end
-- For the pages' buttons: { Undo, Redo on the arrange view, Undo, Redo on the Mixer } (true: there's something to take).
function webdraw.can_step(cfg, b, list)
  local out = {}
  for i, view in ipairs({ false, "mixer" }) do
    local st = steps_of(cfg, b, view or nil)
    local mine = false
    for _, s in ipairs(list) do if s.user == cfg.user and s.view == (view or nil) then mine = true; break end end
    out[i * 2 - 1], out[i * 2] = mine or #st.undo > 0, #st.redo > 0
  end
  return out
end

-- ---- Live sync's tick and the pages' actions (through lib/webui.lua) -------------------------------------------------------------------
-- An action a page sent. -> words for the log, or nil.
function webdraw.action(_, cfg, b, a)
  local d, why = webdraw.parse(a)
  if not d then return why and ("the web page's drawing wasn't kept: " .. why) or nil end
  if d.add then
    if #webdraw.read(cfg, b) >= webdraw.ROOM_MAX then return "the web page's drawing wasn't kept: this room has " .. webdraw.ROOM_MAX .. " drawings (remove some first)" end
    did(cfg, b, d.add.view, { ids = { webdraw.save(cfg, b, d.add) } })
    return nil
  end
  if d.step then webdraw.step(cfg, b, d.step, d.view); return nil end
  local admin = admin_of(cfg, cfg.user)
  local ids = d.remove
  if d.clear then
    if d.clear == "all" and not admin then return "the web page's Clear all was refused: only the studio's owner and admins remove everyone's drawings" end
    ids = {}
    for _, s in ipairs(webdraw.read(cfg, b)) do
      if d.clear == "all" or (s.user == cfg.user and (not d.share or s.from == "share")) then ids[#ids + 1] = s.id end
    end
    -- (Clear can't be undone, and starts Undo afresh)
    if not d.share then for _, view in ipairs({ false, "mixer" }) do local st = steps_of(cfg, b, view or nil); st.undo, st.redo = {}, {} end end
  end
  local mine = {} -- (the Eraser on your own: a step Undo takes back, on the view each was on)
  if not d.clear then
    local want = {}
    for _, id in ipairs(ids) do want[id] = true end
    for _, s in ipairs(webdraw.read(cfg, b)) do
      if want[s.id] and s.user == cfg.user then local k = s.view or false; mine[k] = mine[k] or {}; mine[k][#mine[k] + 1] = s end
    end
  end
  local n, refused = webdraw.remove(cfg, b, ids, cfg.user, admin)
  for view, gone in pairs(mine) do did(cfg, b, view or nil, { gone = gone }) end
  if refused > 0 then return "the web page asked to remove " .. refused .. " drawing" .. (refused == 1 and "" or "s") .. " of someone else's: only your own, unless you're an admin" end
  if d.clear then return "cleared " .. n .. (d.share and " share note" or " drawing") .. (n == 1 and "" or "s") .. " from the web page" end
end
local S = { cc = nil, tracks = {} }
-- The tracks as the Song page shows them, in its order: { { oid, REAPER's track number, name, 8 characters of its GUID } } (the GUID's
-- start is screen share's own name for a track, lib/webcall.lua view_model: how a share's notes find their tracks. rt-draw2).
function webdraw.tracks(proj)
  local out, dawview, mirror = {}, require("dawview"), require("mirror")
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if dawview.shown(tr) then
      out[#out + 1] = { mirror.track_oid(tr), i, select(2, reaper.GetTrackName(tr)), (tostring(reaper.GetTrackGUID(tr) or ""):gsub("[{}%-]", ""):sub(1, 8)) }
    end
  end
  return out
end
-- Each tick in front while a page looks: the "draw" topic (publish sends only what changed).
function webdraw.tick(proj, cfg, b, publish, now)
  if not dirty and now - cache.at < webdraw.LIST_EVERY then return end
  local cc = reaper.GetProjectStateChangeCount(proj)
  if cc ~= S.cc then S.cc, S.tracks = cc, webdraw.tracks(proj) end
  local list = webdraw.read(cfg, b)
  local names, seen = { cfg.user }, {}
  for _, s in ipairs(list) do if type(s.user) == "string" and not seen[s.user] then seen[s.user] = true; names[#names + 1] = s.user end end
  local m = webdraw.model(b.song .. "/" .. (b.room or "main"), list, S.tracks, require("people").colours(cfg.root, names), cfg.user, admin_of(cfg, cfg.user))
  m.un = webdraw.can_step(cfg, b, list)
  publish("draw", m)
end

return webdraw
