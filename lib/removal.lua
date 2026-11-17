-- Taking someone out of a group. A mark in the shared folder (_band/removed/<name>.json) says who; a minute later every computer in
-- the group stops syncing with theirs, each doing it itself, so nobody has to be online at the same moment. Their claims go free
-- and the driver's seat comes back, on the computer that removed them. What they made stays in the song and on Restore, and they
-- keep the copy they already have. Inviting them again and letting them in clears the mark. Which computer is whose: each computer
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
  if said_device(root, user) == id and not foreign and (not ts or had[ts[1]] == ts[2]) then return end -- (what's there, checked or not: one naming another computer is written over)
  local names = {}
  for k, v in pairs(had) do if type(k) == "string" and type(v) == "string" and k == keep then names[k] = v end end
  if ts then names[ts[1]] = ts[2] end
  reaper.RecursiveCreateDirectory(devices(root), 0)
  band.write_json(path, { user = user, device = id, ts = next(names) and names or nil })
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

local function all_marks(root)
  local list = {}
  for _, f in ipairs(band.files(marks(root), ".json")) do
    local m = band.read_json(marks(root) .. "/" .. f)
    -- (leaving is only yours to say: a "left" mark someone else wrote took anyone out, the host too. Review, 0.58.47)
    -- (and from the computer it says: the owner's or an admin's, or the leaver's own. lib/trust.lua, 0.58.69)
    if type(m) == "table" and m.user and ((m.left and m.by == m.user) or require("groups").may_remove(root, m.by, m.user))
      and require("trust").mark_ok(root, "_band/removed/" .. f, m) then list[#list + 1] = m end
  end
  return list
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
function removal.keep(root, user) os.remove(marks(root) .. "/" .. file_name(user)) end
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
function removal.add_invite(root, ends, by, now)
  now = now or os.time()
  reaper.RecursiveCreateDirectory(invites_dir(root), 0)
  band.write_json(invites_dir(root) .. "/" .. now .. "-" .. file_name(by), { made = now, ends = ends, by = by })
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
function removal.end_invite(root, made, ends)
  for _, f in ipairs(band.files(invites_dir(root), ".json")) do
    local v = band.read_json(invites_dir(root) .. "/" .. f)
    if type(v) == "table" and v.made == made then v.ends = ends; band.write_json(invites_dir(root) .. "/" .. f, v) end
  end
end
-- Guests whose time isn't up: { user, device, ends, invite }, soonest first.
function removal.guests(root, now)
  local out = {}
  for _, m in ipairs(all_marks(root)) do
    if m.guest and m.device and not removal.due(m, now) then out[#out + 1] = { user = m.user, device = m.device, ends = m.at + removal.GRACE, invite = m.invite } end
  end
  table.sort(out, function(a, b) return a.ends < b.ends end)
  return out
end
-- A guest's time moved: to now (ended: every computer stops syncing with theirs within a minute), or later.
function removal.guest_ends(root, device, ends)
  for _, f in ipairs(band.files(marks(root), ".json")) do
    local m = band.read_json(marks(root) .. "/" .. f)
    if type(m) == "table" and m.guest and m.device == device then
      m.at = ends - removal.GRACE
      band.write_json(marks(root) .. "/" .. f, m)
      if tonumber(m.invite) then removal.end_invite(root, m.invite, ends) end
    end
  end
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
function removal.who_was(root, device)
  for _, m in ipairs(all_marks(root)) do if m.device == device then return m.user end end
end
-- A computer let in again: whatever mark names it is over.
function removal.let_in(root, device)
  for _, m in ipairs(all_marks(root)) do if m.device == device then removal.keep(root, m.user) end end
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
    for _, g in ipairs(not met[d.id] and band.bands() or {}) do
      local who = not g.waiting and not require("groups").is_old(g.root) and removal.known(g.root, d.id, now)
      if who and not met[d.id] then
        met[d.id] = true
        local ok, why = services.add_device(d.id, who, g.id)
        band.log(ok and string.format("%s's computer (%s) is in %s: this one syncs with it directly now", who, d.id:sub(1, 7), g.name)
          or ("couldn't connect to " .. who .. "'s computer: " .. tostring(why)))
      end
    end
  end
end

-- Run every so often by Autostart and Live sync (at most every 30 s between them). The marks' work on this computer, once each.
function removal.tick(now)
  now = now or os.time()
  if now - (tonumber(reaper.GetExtState(band.SECTION, "removal look")) or 0) < 30 then return end
  reaper.SetExtState(band.SECTION, "removal look", tostring(now), false)
  local services = require("services")
  pcall(require("groups").tick, now)
  pcall(settle_peers, services, now)
  pcall(services.pin_tailnet, services.my_device_id()) -- (studios that sync only through their Tailscale network: from the names published below)
  local me, id = reaper.GetExtState(band.SECTION, "user"), services.my_device_id()
  local told = ""
  local ts -- (this computer's name on the Tailscale network it's on now: { suffix, name })
  do
    local ok, _, suffix = pcall(services.tailnet_now)
    local name = ok and suffix and services.my_tailscale_name()
    if name and name:sub(-#suffix - 1) == "." .. suffix then ts = { suffix, name } end
  end
  for _, g in ipairs(band.bands()) do
    if id and me ~= "" then
      local okn, net = pcall(function() return require("groups").tailnet(g.root) end)
      removal.publish(g.root, me, id, ts, okn and net and net.suffix or nil)
    end
    if me ~= "" and not require("groups").is_old(g.root) then pcall(require("localcopy").publish_holds, g.root, me) end
    for _, m in ipairs(all_marks(g.root)) do
      if m.user == me or (id and m.device == id) then
        if m.guest and removal.due(m, now) then told = string.format("Your time as a guest in %s is over: nothing syncs with the studio any more, and your copy stays here.", g.name)
        elseif not m.left and not m.guest then told = string.format("%s took you out of %s: nothing syncs with the studio any more, and your copy stays here. Ask to be invited again to come back.", tostring(m.by), g.name) end
      elseif removal.due(m, now) and m.device and (m.device == removal.device_of(g.root, m.user) or m.guest) then -- (only their own computer: a mark can name any; a guest's names it)
        local key = "removal done " .. g.id .. " " .. m.user .. " " .. tostring(m.at)
        if reaper.GetExtState(band.SECTION, key) == "" then
          local ok, why = services.unshare(g.id, m.device)
          if ok then
            -- (marked done only once their claims are free too: marked first, a free that failed was never tried again, and their tracks
            -- stayed locked for everyone. Review, 0.58.53)
            local freed, ferr = true, nil
            if m.by == me or (m.left and removal.frees(members(g.root), m.user, me, now - (tonumber(m.at) or now))) then
              freed, ferr = pcall(free, g.root, m.user, me)
              -- (and the live audio's password changes, once, on this one computer: what they knew of it stops working. 0.58.52)
              if freed then pcall(require("groups").new_sonobus_secret, g.root) end
              -- (and the phone alerts' channel: they could still read every line sent to it. Everyone left is told to subscribe again, groups.tick. 0.58.69)
              -- shortcut: like the SonoBus secret, the new one can still reach their computer through someone who hasn't stopped syncing with them yet (up to a minute).
              if freed and require("alerts").channel(g.root) then pcall(require("alerts").set, g.root, true) end
            end
            if freed then reaper.SetExtState(band.SECTION, key, "1", true)
            else band.log("couldn't free " .. m.user .. "'s claims yet (tried again in a minute): " .. tostring(ferr)) end
            band.log(m.user .. " is out of " .. g.name .. ": this computer no longer syncs with theirs")
          else band.log("couldn't stop syncing with " .. m.user .. ": " .. tostring(why)) end
        end
      end
    end
  end
  reaper.SetExtState(band.SECTION, "removed from", told, false)
end

return removal
