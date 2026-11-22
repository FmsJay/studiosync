-- Taking someone out of a group. A mark in the shared folder (_band/removed/<name>.json) says who; a minute later every computer in
-- the group stops syncing with theirs, each doing it itself, so nobody has to be online at the same moment. Their claims go free
-- and the driver's seat comes back, on the computer that removed them. What they made stays in the song and on Restore, and they
-- keep the copy they already have. Inviting them again and letting them in clears the mark (a guest's too: removal.let_in). Which computer is whose: each computer
-- says so in _band/devices/<name>.json.
-- A mark is a file anyone in the group could write: it counts only from the owner's or an admin's computer (or, leaving, your own), as
-- Syncthing tells it (lib/trust.lua, 0.58.69).
local band = require("band")
local removal = { GRACE = 60 }

local function file_name(user) return (tostring(user):gsub("[^%w%-_ ]", "")) .. ".json" end
local function marks(root) return root .. "/_band/removed" end
local function devices(root) return root .. "/_band/devices" end

function removal.mark(root, user)
  local m = band.read_json(marks(root) .. "/" .. file_name(user))
  return type(m) == "table" and m.user and m or nil
end
local function said_device(root, user)
  local d = band.read_json(devices(root) .. "/" .. file_name(user))
  return type(d) == "table" and d.device or nil
end
-- (only a file the computer it names wrote itself: one naming someone else's computer had that one cut off in their place. lib/trust.lua,
-- Security review, 0.58.78. Syncthing not answering yet reads as not said yet)
function removal.device_of(root, user)
  local id = said_device(root, user)
  return id and require("trust").device_ok(root, user, id) == true and id or nil
end
-- `ts`: { suffix, name }, this computer's name on the Tailscale network it's on now (ts = { suffix = name }): services.pin_tailnet gives
-- Syncthing those names for it (0.58.80). Only the studio's own network's (`keep`, its suffix): every network this computer had been on went
-- into every studio's file, so one studio learned the names on another's, a personal network's too. Security review, 0.58.87.
function removal.publish(root, user, id, ts, keep)
  local path = devices(root) .. "/" .. file_name(user)
  local d = band.read_json(path)
  local had = (type(d) == "table" and d.device == id and type(d.ts) == "table") and d.ts or {}
  local foreign = false
  for k in pairs(had) do foreign = foreign or k ~= keep end
  if ts and ts[1] ~= keep then ts = nil end
  -- (the connection without Tailscale, lib/nat.lua: this computer's public key and whether it's on the studio's tailnet now; nil while the
  -- studio has it off. James, rt)
  local okn, n = pcall(function() return require("nat").entry(root, ts ~= nil) end)
  n = okn and n or nil
  local hn = type(d) == "table" and d.device == id and type(d.nat) == "table" and d.nat or nil
  local same_nat = (n == nil and hn == nil) or (n ~= nil and hn ~= nil and hn.pub == n.pub and hn.tailnet == n.tailnet and hn.relay == n.relay
    and hn.relay_reach == n.relay_reach and hn.cgnat == n.cgnat) -- (rt-p13: whether its relay was reached from outside, or is behind CGNAT)
  -- (and this computer's signing key, lib/signed.lua: what the others learn its signatures by once they believe this file. rt-linkfirst)
  local okk, key = pcall(function() return require("signed").key() end)
  key = okk and key or (type(d) == "table" and d.device == id and d.key) or nil
  local same_key = type(d) == "table" and d.key == key
  if said_device(root, user) == id and not foreign and (not ts or had[ts[1]] == ts[2]) and same_nat and same_key then return end -- (what's there, checked or not: one naming another computer is written over)
  local names = {}
  for k, v in pairs(had) do if type(k) == "string" and type(v) == "string" and k == keep then names[k] = v end end
  if ts then names[ts[1]] = ts[2] end
  reaper.RecursiveCreateDirectory(devices(root), 0)
  local out = { user = user, device = id, ts = next(names) and names or nil, nat = n, key = key }
  -- (fields this version doesn't know, from this computer's own earlier file: another StudioSync version on the same computer, in another
  -- studio, may write the file too; nothing it adds is stripped. rt-nat3)
  if type(d) == "table" and d.device == id then for k, v in pairs(d) do if out[k] == nil and k ~= "ts" and k ~= "nat" then out[k] = v end end end
  band.write_json(path, out)
end
-- This computer's entry in every studio's devices file, at most every 30 s, on a gate of its own (rt-nat3). It used to run inside
-- removal.tick behind "removal look", which an older StudioSync shares: a person in two studios on two versions (main's in one, this one in
-- the other) had the older code take that slot every time, and its publish has no `nat`, so this computer's key never reached its devices
-- file and nobody paired with it. Each version keeps its own slot now; the file still has one writer, this computer.
removal.PUBLISH_KEY = "devices publish rt"
function removal.publish_all(now)
  now = now or os.time()
  if now - (tonumber(reaper.GetExtState(band.SECTION, removal.PUBLISH_KEY)) or 0) < 30 then return end
  reaper.SetExtState(band.SECTION, removal.PUBLISH_KEY, tostring(now), false)
  local services = require("services")
  local me, id = reaper.GetExtState(band.SECTION, "user"), services.my_device_id()
  if not id or me == "" then return end
  local ts -- (this computer's name on the Tailscale network it's on now: { suffix, name })
  do
    local ok, _, suffix = pcall(services.tailnet_now)
    local name = ok and suffix and services.my_tailscale_name()
    if name and name:sub(-#suffix - 1) == "." .. suffix then ts = { suffix, name } end
  end
  for _, g in ipairs(band.bands()) do
    local okn, net = pcall(function() return require("groups").tailnet(g.root) end)
    pcall(removal.publish, g.root, me, id, ts, okn and net and net.suffix or nil)
  end
end

-- Whether the minute is up. Pure.
function removal.due(m, now) return now - (tonumber(m.at) or 0) >= removal.GRACE end
-- Who's out: names, from their marks. A new computer of theirs, let in since, isn't the one the mark names. Pure over the three lists.
function removal.out(list, device_of, now)
  local out = {}
  for _, m in ipairs(list) do
    local has = device_of(m.user)
    if removal.due(m, now) and (not has or not m.device or has == m.device) then out[m.user] = true end
  end
  return out
end

-- Marks this computer has accepted, kept in its own ExtState ("marks kept <folder>": { [file] = mark }), so one acts when due even after its file
-- went or was rewritten: a guest who deleted their mark was never unshared, and a member being taken out could undo it within the minute. A kept
-- mark goes only when Syncthing says the owner's or an admin's computer deleted its file (or anyone did, in a studio from before owners), or when
-- Let in or Keep ran here. Asked once per vanished file; costs nothing while the files are there. Round 1 review, 0.59.45.
local function kept_key(root) return "marks kept " .. (tostring(root):gsub("\\", "/"):gsub("/+$", ""):lower()) end
local function kept(root) local ok, t = pcall(band.ext_json, band.SECTION, kept_key(root)); return ok and type(t) == "table" and t or {} end
local function set_kept(root, t) pcall(band.set_ext_json, band.SECTION, kept_key(root), t, true) end
local vanished = {} -- (root .. file -> the answer, or when it was last asked: once a minute at most while there's none)
local function deleted_ok(root, f)
  local trust = require("trust")
  if not trust.pins(root) and not trust.held(root) then return true end
  local k = root .. "\0" .. f
  local v = vanished[k]
  if v == nil or (type(v) == "number" and os.time() - v >= 60) then
    local ok = trust.deleted_by_manager(root, "_band/removed/" .. f)
    if ok == nil then vanished[k] = os.time(); return false end
    vanished[k] = ok
  end
  return vanished[k] == true
end
-- -> the accepted marks, and { [mark] = its file }.
local function all_marks(root)
  local list, files, accepted = {}, {}, {}
  local listing = band.files(marks(root), ".json")
  for _, f in ipairs(listing) do
    local m = band.read_json(marks(root) .. "/" .. f)
    -- (leaving is only yours to say: a "left" mark someone else wrote took anyone out, the host too. Review, 0.58.47)
    -- (and from the computer it says: the owner's or an admin's, or the leaver's own. lib/trust.lua, 0.58.69)
    -- (a leaver's own only when the device it names is that person's own, as their devices file says and Syncthing confirms: a made-up device
    -- sharing the writer's first 7 characters passed. And a left mark is never a guest's. Round 1 review, 0.59.45)
    if type(m) == "table" and m.left then m.guest = nil end
    local own_left = type(m) == "table" and m.left and m.by == m.user and m.device ~= nil and removal.device_of(root, m.user) == m.device
    if type(m) == "table" and m.user and (own_left or (not m.left and require("groups").may_remove(root, m.by, m.user)))
      and require("trust").mark_ok(root, "_band/removed/" .. f, m) then list[#list + 1] = m; files[m] = f; accepted[f] = m end
  end
  local have, changed = kept(root), false
  local present = {}
  for _, f in ipairs(listing) do present[f] = true; vanished[root .. "\0" .. f] = nil end -- (there again: a later deletion is asked about afresh)
  for f, m in pairs(accepted) do
    if band.json_encode(have[f] or false) ~= band.json_encode(m) then have[f], changed = m, true end
  end
  for f, m in pairs(have) do
    if not accepted[f] then
      if not present[f] and deleted_ok(root, f) then have[f], changed = nil, true
      elseif type(m) == "table" and m.user then list[#list + 1] = m; files[m] = f end -- (gone or rewritten by someone else: as accepted)
    end
  end
  if changed then set_kept(root, have) end
  return list, files
end
-- Forget the kept marks naming a computer or a person here (Let in, Keep).
local function forget_kept(root, device, user)
  local have, changed = kept(root), false
  for f, m in pairs(have) do
    if type(m) ~= "table" or (device and m.device == device) or (user and m.user == user and not m.guest) then have[f], changed = nil, true end
  end
  if changed then set_kept(root, have) end
end
function removal.gone(root)
  return removal.out(all_marks(root), function(u) return removal.device_of(root, u) end, os.time())
end

function removal.remove(root, user, by)
  local id = removal.device_of(root, user)
  if not id then return nil, user .. "'s computer hasn't said which one it is yet: it does once it has StudioSync 0.46. Until then, remove it in Syncthing's own window." end
  reaper.RecursiveCreateDirectory(marks(root), 0)
  band.write_json(marks(root) .. "/" .. file_name(user), { user = user, device = id, by = by, at = os.time() })
  return true
end
-- Someone leaving by themselves: the same mark, so every computer stops syncing with theirs. Their claims go free on the next computer to look.
function removal.left(root, user, id)
  reaper.RecursiveCreateDirectory(marks(root), 0)
  band.write_json(marks(root) .. "/" .. file_name(user), { user = user, device = id, by = user, at = os.time(), left = true })
end
function removal.keep(root, user) band.remove(marks(root) .. "/" .. file_name(user)); forget_kept(root, nil, user) end
-- A guest: the same mark, dated so it falls due when their time is up, by their computer (their StudioSync name isn't known yet when
-- they're let in). A guest invitation's day was Tailscale's only: their computer kept the shared folder until someone took it out (review, 0.58.52).
-- How long is picked when inviting them (James, 0.58.82: "invite guest and set for when theirs expires"; it was always a day): the invitation
-- leaves a note in the studio (_band/guest-invites/<made>-<by>.json: { made, ends, by }), and whoever lets them in gives them that long.
-- `invite`: that note's `made`, kept in the mark, so ending them early ends what Tailscale let in too (services.old_guests).
removal.DAY = 86400
removal.GUEST_FOR = { { "1 day", 1 }, { "3 days", 3 }, { "1 week", 7 }, { "2 weeks", 14 }, { "1 month", 30 } }
removal.INVITE_KEEPS = 7 * 86400 -- an invitation lets someone in within a week of being made
function removal.guest(root, device, name, by, now, ends, invite)
  now = now or os.time()
  reaper.RecursiveCreateDirectory(marks(root), 0)
  band.write_json(marks(root) .. "/" .. file_name("guest " .. device:sub(1, 7)),
    { user = tostring(name or "a guest"), device = device, by = by, at = (ends or now + removal.DAY) - removal.GRACE, guest = true, invite = invite, since = now })
end
local function invites_dir(root) return root .. "/_band/guest-invites" end
function removal.add_invite(root, ends, by, now, songs) -- (`songs`: the projects they see, or nil for all of them: lib/access.lua)
  now = now or os.time()
  reaper.RecursiveCreateDirectory(invites_dir(root), 0)
  band.write_json(invites_dir(root) .. "/" .. now .. "-" .. file_name(by), { made = now, ends = ends, by = by, songs = songs })
  return now
end
-- (only from the owner's or an admin's computer, as Syncthing says, or this one's own not yet looked at: anyone could write a note giving a
-- guest a month. Security review, 0.58.87)
function removal.invites(root)
  local out, me = {}, reaper.GetExtState(band.SECTION, "user")
  for _, f in ipairs(band.files(invites_dir(root), ".json")) do
    local v = band.read_json(invites_dir(root) .. "/" .. f)
    if type(v) == "table" and tonumber(v.made) and tonumber(v.ends) then
      local okt, ok = pcall(require("trust").from_manager_file, root, "_band/guest-invites/" .. f)
      if not okt or ok == true or (ok == nil and v.by == me) then out[#out + 1] = v end
    end
  end
  return out
end
-- The invitation someone arriving now most likely came with: the newest made within INVITE_KEEPS, still running. -> it, or nil. Pure.
function removal.invite_for(list, now)
  local best
  for _, v in ipairs(list) do
    if now - v.made <= removal.INVITE_KEEPS and v.ends > now and (not best or v.made > best.made) then best = v end
  end
  return best
end
-- When an invitation made at `made` ends now (an early end moves it): rewritten in place. Its file is named by when and who.
-- (only a note that counts, as removal.invites reads them: rewritten from a manager's computer, a forged note became a trusted one. Round 1 review, 0.59.45)
function removal.end_invite(root, made, ends)
  for _, v in ipairs(removal.invites(root)) do
    if v.made == made then
      for _, f in ipairs(band.files(invites_dir(root), ".json")) do
        local w = band.read_json(invites_dir(root) .. "/" .. f)
        if type(w) == "table" and w.made == made and w.by == v.by then w.ends = ends; band.write_json(invites_dir(root) .. "/" .. f, w) end
      end
    end
  end
end
-- Guests whose time isn't up: { user, device, ends, invite }, soonest first.
function removal.guests(root, now)
  local out = {}
  for _, m in ipairs(all_marks(root)) do
    if m.guest and m.device and tonumber(m.at) and not removal.due(m, now) then out[#out + 1] = { user = m.user, device = m.device, ends = tonumber(m.at) + removal.GRACE, invite = m.invite } end
  end
  table.sort(out, function(a, b) return a.ends < b.ends end)
  return out
end
-- A guest's time moved: to now (ended: every computer stops syncing with theirs within a minute), or later.
-- (only a mark that counts, as all_marks reads them: rewritten from a manager's computer, a forged one became trusted. Round 1 review, 0.59.45)
function removal.guest_ends(root, device, ends)
  local list, files = all_marks(root)
  for _, m in ipairs(list) do
    if m.guest and m.device == device and files[m] then
      local w = {}
      for k, v in pairs(m) do w[k] = v end
      w.at = ends - removal.GRACE
      band.write_json(marks(root) .. "/" .. files[m], w)
      if tonumber(w.invite) then removal.end_invite(root, w.invite, ends) end
    end
  end
end
-- Is this computer a guest in the studio: a mark it accepted names its computer as a guest, running or over (an all-projects guest has no list,
-- and synced and ran the studio's copy of StudioSync: lib/songsync.lua, lib/fromfolder.lua). -> true/false. James's decision, Round 1 review, 0.59.45.
function removal.am_guest(root)
  local id = require("services").my_device_id()
  if not id then return false end
  for _, m in ipairs(all_marks(root)) do if m.guest and m.device == id then return true end end
  return false
end
-- Every name a guest goes by here, from the guest marks (the name they were let in with) and the devices files of their computers: { [name] = true }.
-- Delete my copy doesn't count a guest's copy as one that holds a project (lib/localcopy.lua). Round 1 review, 0.59.45.
function removal.guest_names(root)
  local out, devs = {}, {}
  for _, m in ipairs(all_marks(root)) do if m.guest then out[tostring(m.user)] = true; if m.device then devs[m.device] = true end end end
  for _, f in ipairs(next(devs) and band.files(devices(root), ".json") or {}) do
    local d = band.read_json(devices(root) .. "/" .. f)
    if type(d) == "table" and type(d.user) == "string" and devs[d.device] then out[d.user] = true end
  end
  return out
end
-- "Sat Nov 23" for a time; "today 18:00" / "tomorrow 18:00" when that close. Pure but for the clock's time zone.
function removal.when(t, now)
  local d, n = os.date("*t", t), os.date("*t", now)
  local function day(x) return os.time({ year = x.year, month = x.month, day = x.day, hour = 12 }) end
  local diff = math.floor((day(d) - day(n)) / 86400 + 0.5)
  if diff == 0 then return "today " .. os.date("%H:%M", t) end
  if diff == 1 then return "tomorrow " .. os.date("%H:%M", t) end
  return os.date("%a %b %d", t)
end
-- "YYYY-MM-DD" typed in -> that day's end (23:59 local), or nil when it isn't a date after `now`. Pure but for the time zone.
function removal.parse_day(text, now)
  local y, mo, d = tostring(text or ""):match("^%s*(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s*$")
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  if mo < 1 or mo > 12 or d < 1 or d > 31 then return nil end
  local t = os.time({ year = y, month = mo, day = d, hour = 23, min = 59, sec = 0 })
  if os.date("*t", t).day ~= d then return nil end -- (Feb 30 rolls over)
  return t > now and t or nil
end
-- Who a mark says this computer belongs to, if it's been taken out of the group. (Its Syncthing keeps asking: that isn't someone new.)
local marks_seen = {} -- root -> { at, list }: who_was is asked every frame a join request shows (review, 0.59.10)
function removal.who_was(root, device)
  local c = marks_seen[root]
  if not c or reaper.time_precise() - c.at > 5 then c = { at = reaper.time_precise(), list = all_marks(root) }; marks_seen[root] = c end
  for _, m in ipairs(c.list) do if m.device == device then return m.user end end
end
-- Whether a computer asking over the studio's Tailscale may be let in without a click: never someone taken out, and nobody while a guest
-- invitation is open (a guest is on the studio's Tailscale too). -> may, and who it was if taken out. Review, 0.58.92
function removal.may_auto_admit(root, device, now)
  now = now or os.time()
  -- (marks and invitations as written, checked or not: one still waiting for Syncthing's word counted as none, and in that window someone just
  -- taken out could come straight back. For letting in without a click, the careful reading. 0.58.93)
  for _, f in ipairs(band.files(marks(root), ".json")) do
    local m = band.read_json(marks(root) .. "/" .. f)
    if type(m) == "table" and m.device == device then return false, tostring(m.user or "someone") end
  end
  for _, f in ipairs(band.files(invites_dir(root), ".json")) do
    local v = band.read_json(invites_dir(root) .. "/" .. f)
    if type(v) == "table" and tonumber(v.made) and tonumber(v.ends) and removal.invite_for({ v }, now) then return false end
  end
  -- (nor while any guest's time is still running: an invitation counts as open for 7 days, but a guest can have two weeks or a month on the
  -- studio's Tailscale, and from day 8 a second computer of theirs came in as a full member. Those ask in the panel. Full review, 0.59.44)
  for _, f in ipairs(band.files(marks(root), ".json")) do
    local m = band.read_json(marks(root) .. "/" .. f)
    if type(m) == "table" and m.guest and tonumber(m.at) and not removal.due(m, now) then return false end
  end
  -- (and the marks kept here, whose files may be gone: a guest who deleted theirs no longer blocked it. Round 1 review, 0.59.45)
  for _, m in pairs(kept(root)) do
    if type(m) == "table" and m.device == device then return false, tostring(m.user or "someone") end
    if type(m) == "table" and m.guest and tonumber(m.at) and not removal.due(m, now) then return false end
  end
  return true
end
-- A computer let in again: whatever mark names it is over.
function removal.let_in(root, device)
  -- (by file: a guest's mark is named by their computer, so removal.keep(m.user) left it, and they stayed "taken out". Review, 0.58.96)
  for _, f in ipairs(band.files(marks(root), ".json")) do
    local m = band.read_json(marks(root) .. "/" .. f)
    if type(m) == "table" and m.device == device then band.remove(marks(root) .. "/" .. f) end
  end
  forget_kept(root, device) -- (and this computer's own memory of them: Round 1 review, 0.59.45)
end

-- A computer asking this one's Syncthing to connect that's already in the studio: its own devices file is there, written by itself (lib/trust.lua),
-- and no mark has taken it out (a guest's counts once their day is over). The joiner's introducer goes once they're let in (services.introducers_off),
-- so this is how someone let in after them is met: without it, the two only ever synced through a third computer. Security review, 0.58.78.
-- -> their name, or nil.
function removal.known(root, id, now)
  for _, m in ipairs(all_marks(root)) do
    if m.device == id and not (m.guest and not removal.due(m, now or os.time())) then return nil end
  end
  for _, f in ipairs(band.files(devices(root), ".json")) do
    local d = band.read_json(devices(root) .. "/" .. f)
    if type(d) == "table" and d.device == id and type(d.user) == "string" and file_name(d.user) == f and require("trust").device_ok(root, d.user, id) == true then return d.user end
  end
end

-- A computer let in with a signed invitation (lib/joins.lua): met without a click as known() is, from the invitation's record, which the
-- computer that let it in rewrote naming it (that reaches the others before the joiner's own devices file does). Never one a mark has taken
-- out. -> their name, or nil. (James, rt)
function removal.admitted(root, id, now)
  for _, m in ipairs(all_marks(root)) do
    if m.device == id and not (m.guest and not removal.due(m, now or os.time())) then return nil end
  end
  local ok, who = pcall(require("joins").admitted, root, id, now)
  return ok and who or nil
end
-- Taken out at or after `since` (an invitation made before that doesn't bring them back: lib/joins.lua). -> who, or nil.
function removal.out_since(root, id, since)
  for _, m in ipairs(all_marks(root)) do
    if m.device == id and not m.guest and not m.left and (tonumber(m.at) or 0) >= (tonumber(since) or 0) then return tostring(m.user or "someone") end
  end
end

-- Who frees a leaver's claims: one computer, not all of them at once (each wrote itself into the driver's seat, and their copies of
-- the claims crossed: review, 0.58.47). The first name among those whose computers have said which they are, but them; after an hour,
-- anyone, in case that one is away. Pure over its arguments.
function removal.frees(names, leaver, me, age)
  if age >= 3600 then return true end
  table.sort(names)
  for _, n in ipairs(names) do if n ~= leaver then return n == me end end
  return true
end
local function members(root)
  local t = {}
  for _, f in ipairs(band.files(devices(root), ".json")) do
    local d = band.read_json(devices(root) .. "/" .. f)
    if type(d) == "table" and type(d.user) == "string" then t[#t + 1] = d.user end
  end
  return t
end
-- Their claims free and, where they drove, you in the seat: every song and room in the group.
local function free(root, user, me)
  local sync, rooms = require("sync"), require("rooms")
  local cfg = { root = root, user = me }
  for _, song in ipairs(band.subdirs(root)) do
    if reaper.file_exists(root .. "/" .. song .. "/session.json") then
      for _, r in ipairs(rooms.list(cfg, song)) do
        sync.release_claims(cfg, song, r.name, user)
        local d = band.read_json(sync.room_dir(cfg, song, r.name) .. "/driver.json")
        if type(d) == "table" and d.driver == user then sync.set_driver(cfg, song, r.name, me) end
      end
    end
  end
end

-- Joined and let in: the introducer flags off (services.introducers_off), but not for the inviter of a studio still waiting to be let in, and not
-- at all while one waits whose inviter isn't known (joined before 0.58.78). Asked again only when which studios wait changes: each look is a few
-- Syncthing commands. And someone already in a studio, asking to connect, is met (removal.known). Security review, 0.58.78.
local intro_for, met = nil, {}
local function settle_peers(services, now)
  local keep, sig, unsure = {}, "", false
  for _, g in ipairs(band.bands()) do
    if g.waiting then
      sig = sig .. g.root .. "|"
      local inv = require("trust").inviter(g.root)
      if inv then keep[inv] = true else unsure = true end
    end
  end
  if not unsure and sig ~= intro_for and services.introducers_off(keep) then intro_for = sig end
  for _, d in ipairs(services.pending_devices()) do
    local due = met[d.id] == nil or (met[d.id] ~= true and now - met[d.id] > 120) -- (a failed add tried again in two minutes, not never. 0.58.93)
    for _, g in ipairs(due and band.bands() or {}) do
      local who = not g.waiting and not require("groups").is_old(g.root) and (removal.known(g.root, d.id, now) or removal.admitted(g.root, d.id, now))
      if who and due then
        due = false
        local ok, why = services.add_device(d.id, who, g.id)
        met[d.id] = ok and true or now
        band.log(ok and string.format("%s's computer (%s) is in %s: this one syncs with it directly now", who, d.id:sub(1, 7), g.name)
          or ("couldn't connect to " .. who .. "'s computer: " .. tostring(why)))
      end
    end
  end
end

-- The live audio's password changes, once, on this one computer: what they knew of it stops working (0.58.52). And the phone alerts' channel:
-- they could still read every line sent to it; everyone left is told to subscribe again, groups.tick (0.58.69). -> false when it was skipped
-- as nothing is verified here yet, to be tried again (the removal was marked done anyway, and the password never changed. Round 4 review, 0.59.49)
-- shortcut: like the SonoBus secret, the new one can still reach their computer through someone who hasn't stopped syncing with them yet (up to a minute).
local function rotate(root)
  local ok, made = pcall(require("groups").new_sonobus_secret, root)
  if ok and made == false then return false end
  if require("alerts").channel(root) then
    local oka, set = pcall(require("alerts").set, root, true, true)
    if oka and set == false then return false end
  end
  return true
end
removal.rotate = rotate -- (for tests)

-- Run every so often by Autostart and Live sync (at most every 30 s between them). The marks' work on this computer, once each.
function removal.tick(now)
  now = now or os.time()
  removal.publish_all(now) -- (its own gate: see there)
  if now - (tonumber(reaper.GetExtState(band.SECTION, "removal look")) or 0) < 30 then return end
  reaper.SetExtState(band.SECTION, "removal look", tostring(now), false)
  local services = require("services")
  pcall(require("groups").tick, now)
  pcall(settle_peers, services, now)
  pcall(services.pin_tailnet, services.my_device_id()) -- (studios that sync only through their Tailscale network: from the names published below)
  local me, id = reaper.GetExtState(band.SECTION, "user"), services.my_device_id()
  local told = ""
  for _, g in ipairs(band.bands()) do
    if me ~= "" and not require("groups").is_old(g.root) then pcall(require("localcopy").publish_holds, g.root, me) end
    for _, m in ipairs(all_marks(g.root)) do
      if m.user == me or (id and m.device == id) then
        if m.guest and removal.due(m, now) then told = string.format("Your time as a guest in %s is over: nothing syncs with the studio any more, and your copy stays here.", g.name)
        elseif not m.left and not m.guest then told = string.format("%s took you out of %s: nothing syncs with the studio any more, and your copy stays here. Ask to be invited again to come back.", tostring(m.by), g.name) end
      elseif removal.due(m, now) and m.device and (m.device == removal.device_of(g.root, m.user) or m.guest) then -- (only their own computer: a mark can name any; a guest's names it)
        local key = "removal done " .. g.id .. " " .. m.user .. " " .. tostring(m.at)
        local state = reaper.GetExtState(band.SECTION, key)
        if state == "rotate" then -- (out and freed: only the password and channel are still to change. Round 4 review, 0.59.49)
          if rotate(g.root) then
            reaper.SetExtState(band.SECTION, key, "1", true)
            band.log(g.name .. "'s live audio password and phone alerts channel changed now that " .. m.user .. " is out")
          end
        elseif state == "" then
          local ok, why = services.unshare(g.id, m.device)
          if ok then
            -- (marked done only once their claims are free too: marked first, a free that failed was never tried again, and their tracks
            -- stayed locked for everyone. Review, 0.58.53)
            local freed, ferr, rotated = true, nil, true
            if m.by == me or (m.left and removal.frees(members(g.root), m.user, me, now - (tonumber(m.at) or now))) then
              freed, ferr = pcall(free, g.root, m.user, me)
              if freed then rotated = rotate(g.root) end
            end
            if freed then reaper.SetExtState(band.SECTION, key, rotated and "1" or "rotate", true)
            else band.log("couldn't free " .. m.user .. "'s claims yet (tried again in a minute): " .. tostring(ferr)) end
            band.log(m.user .. " is out of " .. g.name .. ": this computer no longer syncs with theirs" ..
              (rotated and "" or " (the live audio password and alerts channel change once this computer has checked the studio's settings)"))
          else band.log("couldn't stop syncing with " .. m.user .. ": " .. tostring(why)) end
        end
      end
    end
  end
  reaper.SetExtState(band.SECTION, "removed from", told, false)
end

return removal
