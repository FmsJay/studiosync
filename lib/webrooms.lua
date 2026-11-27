-- The web UI's Session > Rooms (docs/rt/ui-web-plan.md Phase 6; the panel's Rooms page, lib/page_rooms.lua; rt-ui6): this project's rooms as
-- cards (who's in each, where it came from), Go (the Studio tab's Open: lib/webhome.lua, so a side room opens as Open session opens it), Create
-- a room, Fork, Come see!, Archive / Bring back, and from a side room Send selected to / Bring into / Adopt as its parent. Each through the
-- panel's own calls (lib/rooms.lua, lib/forks.lua, lib/mirror.lua) with its rules: Bring into and Adopt only by whoever is in control of the
-- parent (forks.adopt checks it again), what goes in only where the parent's claims let you (mirror.allowed_into), Archive only a side room
-- nobody has open. The page confirms in itself where the panel asks. The "rooms" topic: the list only while a page shows Rooms (it says so
-- every 10 s), the come-and-see asks every few seconds while any page looks (Session shows them too). Its actions ride on the "session" topic
-- ({ topic = "session", rooms = { ... } }), so lib/webui.lua dispatches one topic for both. (James, rt-ui6)
local band = require("band")
local webrooms = {}
webrooms.WANT_FOR = 30      -- seconds a page counts as showing Rooms after it last said so
webrooms.EVERY = 2          -- seconds between list builds while shown
webrooms.INVITES_EVERY = 3  -- seconds between reading the come-and-see asks while any page looks

local S = { want = -math.huge, at = -math.huge, n = 0 }
local function scripts_dir() return debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\][^/\\]+$") or "." end

-- ---- pure -------------------------------------------------------------------------------------------------------------------------------
-- o: { room (this tab's), list (rooms.list), people (name -> rooms.people), invites (rooms.invites), meta (this room's room.json), me,
-- parent_driver, merge, said, full (the list was built) }. -> the topic.
function webrooms.model(o)
  local meta = type(o.meta) == "table" and o.meta or {}
  local out = { room = o.room, parent = meta.parent, fork = meta.fork and true or nil, invites = {}, said = o.said }
  for _, v in ipairs(o.invites or {}) do
    if type(v) == "table" and v.room ~= o.room then out.invites[#out.invites + 1] = { from = v.from, room = v.room, time = v.time } end
  end
  if not o.full then return out end
  out.rooms, out.archived = {}, {}
  for _, r in ipairs(o.list or {}) do
    if r.binned and r.name ~= o.room then out.archived[#out.archived + 1] = { name = r.name, by = tostring(r.binned) }
    else
      local came = r.fork and require("forks").origin_words(r) or r.parent and ("side room of " .. r.parent) or "main room"
      local people = {}
      for _, p in ipairs((o.people or {})[r.name] or {}) do people[#people + 1] = { user = p.user, here = p.here or nil, me = p.me or nil } end
      out.rooms[#out.rooms + 1] = { name = r.name, here = r.name == o.room or nil, main = not r.parent or nil, came = came, people = people }
    end
  end
  if meta.parent then
    out.parent_driver = o.parent_driver
    out.may_bring = o.parent_driver == o.me or nil
    out.merge = o.merge
  end
  return out
end

-- ---- what the page sends ----------------------------------------------------------------------------------------------------------------
local function said(text, ok)
  S.n = S.n + 1
  S.said, S.at, S.inv_at = { text = text, ok = ok ~= false or nil, n = S.n }, -math.huge, -math.huge
  return text
end
local function session_of(cfg, b) return band.read_json(band.session_path(cfg, b.song)) end
local function known_room(cfg, b, name)
  if type(name) ~= "string" or name == "" or #name > 64 then return nil end
  for _, r in ipairs(require("rooms").list(cfg, b.song)) do if r.name == name then return r end end
end
-- r: { want, go = <room>, create = <name> with fork = bool, comesee, archive = <room>, unarchive = <room>, send, look, bring, adopt }.
function webrooms.action(proj, cfg, b, r, here)
  local rooms, sync = require("rooms"), require("sync")
  if r.want then S.want, S.at = reaper.time_precise() + webrooms.WANT_FOR, -math.huge end
  local function no(why) return said("the web page's " .. why, false) end
  if r.go ~= nil then
    if not known_room(cfg, b, r.go) then return no("Go: '" .. tostring(r.go) .. "' isn't one of this project's rooms") end
    return said(require("webhome").open(cfg, { song = b.song, room = r.go }) or "")
  end
  if r.create ~= nil then
    if type(r.create) ~= "string" or #r.create > 64 then return no("new room: not a name") end
    local p, why
    if r.fork then p, why = require("forks").create(proj, cfg, b, r.create) else p, why = rooms.create(proj, cfg, b, r.create) end
    if not p then return no((r.fork and "fork: " or "new room: ") .. tostring(why)) end
    local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(p)))
    if not (beat and reaper.time_precise() - beat < 5) then band.start_live(scripts_dir()) end -- (runs for the tab in front: the new room's)
    return said("made the " .. (r.fork and "fork" or "side room") .. " '" .. r.create:match("^%s*(.-)%s*$") .. "' from '" .. b.room .. "' (you're in control of it), from the web page")
  end
  if r.comesee then
    rooms.invite(cfg, b.song, b.room)
    return said("asked everyone to come and see '" .. b.room .. "', from the web page")
  end
  if r.archive ~= nil or r.unarchive ~= nil then
    local name = r.archive or r.unarchive
    local room = known_room(cfg, b, name)
    if not room or not room.parent then return no("Archive: only a side room or fork of this project") end
    if r.archive ~= nil then
      if name == b.room then return no("Archive: not the room you're in") end
      if #rooms.people(cfg, b.song, name) > 0 then return no("Archive: someone has '" .. name .. "' open; it can be archived once its tabs are closed") end
      rooms.bin(cfg, b.song, name, cfg.user)
      return said("archived the room '" .. name .. "' for everyone (nothing deleted), from the web page")
    end
    rooms.bin(cfg, b.song, name, nil)
    return said("brought the room '" .. name .. "' back, from the web page")
  end
  -- (from a side room to the room it came from)
  if r.send or r.look or r.bring or r.adopt then
    local meta = rooms.meta(cfg, b.song, b.room)
    local parent = type(meta) == "table" and meta.parent
    if not parent then return no("that is for a side room: this is the main room") end
    local mirror, s = require("mirror"), session_of(cfg, b)
    if r.send then
      local list = mirror.selected(proj, cfg, b.song, b.room, parent)
      if #list == 0 then return no("Send selected: select the items to send first") end
      local keep, refused = mirror.allowed_into(cfg, b.song, parent, list, s)
      if #keep == 0 then return no("Send selected: none of those are yours to change in '" .. parent .. "' (claimed, or its driver's)") end
      local n = mirror.post_into(cfg, b.song, b.room, parent, keep, rooms.tab(b.song, parent))
      return said(string.format("sent %d change(s) from '%s' to '%s'%s, from the web page", n, b.room, parent,
        refused > 0 and string.format(" (%d not yours to change there, left out)", refused) or ""))
    end
    if r.look or r.bring then
      local pdir = sync.room_dir(cfg, b.song, parent)
      local bring, clash = mirror.bring_plan(sync.room_dir(cfg, b.song, b.room), pdir, b.room)
      local forks = require("forks")
      local theirs = meta.time and forks.theirs(mirror.room_newest(pdir, meta.time), b.room) or {}
      local rows = forks.by_track(bring, clash, theirs)
      for i = #rows, 41, -1 do rows[i] = nil end -- (the first 40 tracks: the page lists them)
      S.merge = { parent = parent, room = b.room, bring = #bring, clash = #clash, tracks = rows }
      if r.look then return said("compared '" .. b.room .. "' with '" .. parent .. "'") end
      if sync.driver(cfg, b.song, parent, s) ~= cfg.user then return no("Bring into was refused: whoever is in control of '" .. parent .. "' brings it in") end
      local chosen, has = {}, {}
      for _, ev in ipairs(bring) do chosen[ev.oid] = true end
      for oid, ev in pairs(mirror.room_newest(pdir)) do if not ev.gone then has[oid] = true end end
      local picked = forks.pick(bring, chosen, has)
      if #picked == 0 then return no("Bring into: no new changes here for '" .. parent .. "'") end
      local list, refused = mirror.allowed_into(cfg, b.song, parent, picked, s)
      local ok, n = pcall(mirror.post_into, cfg, b.song, b.room, parent, list, rooms.tab(b.song, parent))
      S.merge = nil
      if not ok then return no("Bring into failed: " .. tostring(n)) end
      return said(string.format("brought %d change(s) from '%s' into '%s'%s, from the web page", n, b.room, parent,
        refused > 0 and string.format(" (%d not yours to change there, left out)", refused) or ""))
    end
    if not meta.fork then return no("Adopt: only a fork is adopted") end
    local kept, words = require("forks").adopt(proj, cfg, b, s)
    if not kept then return no("Adopt: " .. tostring(words)) end
    S.merge = nil
    return said("adopted '" .. b.room .. "' as '" .. parent .. "' (the old one kept as the fork '" .. kept .. "'): " .. tostring(words))
  end
end

-- Each tick in front, while a page looks (from lib/websession.lua's).
function webrooms.tick(proj, cfg, b, publish, now)
  local full = S.want > now
  if now - S.at < (full and webrooms.EVERY or webrooms.INVITES_EVERY) then return end
  S.at = now
  local ok, m = pcall(function()
    local rooms = require("rooms")
    local o = { room = b.room, me = cfg.user, invites = rooms.invites(cfg, b.song), meta = rooms.meta(cfg, b.song, b.room), said = S.said, full = full }
    if full then
      o.list, o.people = rooms.list(cfg, b.song), {}
      for _, r in ipairs(o.list) do if not r.binned or r.name == b.room then o.people[r.name] = rooms.people(cfg, b.song, r.name) end end
      if type(o.meta) == "table" and o.meta.parent then o.parent_driver = require("sync").driver(cfg, b.song, o.meta.parent, session_of(cfg, b)) end
      o.merge = S.merge and S.merge.room == b.room and S.merge or nil
    end
    return webrooms.model(o)
  end)
  publish("rooms", ok and m or { error = tostring(m) })
end
function webrooms._reset() S = { want = -math.huge, at = -math.huge, n = 0 } end -- (tests)

return webrooms
