-- The web UI's Session tab (docs/rt/ui-web-plan.md Phase 6, 2.1-2.3; rt-ui6): Who can edit (the room's mode, Take control, hand over,
-- Always follow the driver), Claims (claim what's selected, release, the driver's Release for someone away), How I hear (Local mixing), the
-- person menu (Give them control of, Make admin / member / owner, Remove from the studio, Keep them) and Live ideas. Nothing here is a rule
-- of its own: each action goes through the panel's own calls (lib/sync.lua, lib/groups.lua, lib/grants.lua, lib/removal.lua, lib/mirror.lua,
-- lib/tools.lua) and is refused where the panel would refuse it (the panel greys or hides it): the mode and Give them control of only for the
-- studio's owner and admins, roles only for the owner, hand over only by whoever is in control, Remove by groups.may_remove. Changing roles and
-- removing someone are also refused from another device (decision 4: no studio settings from a phone). The "session" topic is built once a
-- second while any page looks (the strip's "View only: Bo is in control", James's decision 6, reads it on every tab) and only sent when it
-- changed. Rooms ride on this topic's actions (lib/webrooms.lua). (James, rt-ui6)
local band = require("band")
local websession = {}
websession.EVERY = 1     -- seconds between builds while a page looks
websession.NAME_MAX = 64 -- bytes in a name from a page

local S = { at = -math.huge, n = 0 }
local function name_ok(u) return type(u) == "string" and u ~= "" and #u <= websession.NAME_MAX and not u:find("%c") end
local function iso() return os.date("!%Y-%m-%dT%H:%M:%SZ") end

-- ---- pure -------------------------------------------------------------------------------------------------------------------------------
-- The panel's banner (StudioSync - Panel.lua), as a key: "driver" (View only: <driver> is in control), "admins" (View only: admins only here) or
-- nil. Only while the one in control is someone else who's here and you're not alone; in Admins only, not for the owner and admins, someone an
-- admin let edit here, or anyone holding a claim they were given.
function websession.view_only(o)
  if not o.driver or o.driver == o.me or not o.driver_here or o.alone then return nil end
  if o.mode == "driver" then return "driver" end
  if o.mode == "admins" and not o.may_manage and not o.granted and (o.mine or 0) == 0 then return "admins" end
end
-- who: sync.authority's second answer. -> your claims ({ kind = "tracks" | "regions" | "times", name | from, to, auto }) sorted, and who else
-- holds claims but isn't here (here: name -> true), sorted: the panel's "Release <name>'s claims" for whoever is in control.
function websession.claims_of(who, me, here)
  local mine, away, seen = {}, {}, {}
  local function other(u) if u ~= me and not here[u] and not seen[u] then seen[u] = true; away[#away + 1] = u end end
  for kind, list in pairs({ tracks = who.tracks, regions = who.regions }) do
    for key, c in pairs(type(list) == "table" and list or {}) do
      if type(c) == "table" and type(c.user) == "string" then
        if c.user == me then mine[#mine + 1] = { kind = kind, name = tostring(c.name or key), auto = c.auto and true or nil } else other(c.user) end
      end
    end
  end
  for _, t in ipairs(type(who.times) == "table" and who.times or {}) do
    if type(t) == "table" and type(t.user) == "string" and tonumber(t.from) and tonumber(t.to) then
      if t.user == me then mine[#mine + 1] = { kind = "times", from = tonumber(t.from), to = tonumber(t.to), auto = t.auto and true or nil } else other(t.user) end
    end
  end
  table.sort(mine, function(a, z)
    if a.kind ~= z.kind then return a.kind < z.kind end
    return (a.name or string.format("%012.3f", a.from)) < (z.name or string.format("%012.3f", z.from))
  end)
  table.sort(away)
  return mine, away
end
-- What `me` may do about `user` from the person menu, the panel's rules (ui.person_menu). g: lib/groups.lua (or a stand-in); o: { driving,
-- here (they're here now), marked (already leaving) }. -> { admin = "admin" | "member" (what Make ... makes them), owner, handover, give, remove,
-- keep } (true or nil each).
function websession.rights(g, root, me, user, o)
  if user == me then return {} end
  local mine, manage = g.role(root, me), g.may_manage(root, me)
  return { admin = mine == "owner" and (g.role(root, user) == "admin" and "member" or "admin") or nil, owner = mine == "owner" or nil,
    handover = o.driving and o.here or nil, give = manage or nil, remove = not o.marked and g.may_remove(root, me, user) or nil,
    keep = o.marked and manage or nil }
end

-- ---- reading REAPER ---------------------------------------------------------------------------------------------------------------------
-- What a track is called for a claim (the panel's part_name): a "(MIDI)" copy and a "(studio)" mirror belong to their part.
local function part_name(tr)
  local m = band.track_ext(tr, "band_midi_track")
  return m ~= "" and m or require("sync").base_name(select(2, reaper.GetTrackName(tr)))
end
-- What's selected in REAPER now: track names, region names (the panel's ui.selected_regions) and the time selection (nil under 10 ms).
local function selection(proj)
  local tracks, regions = {}, {}
  for i = 0, reaper.CountSelectedTracks(proj) - 1 do tracks[#tracks + 1] = part_name(reaper.GetSelectedTrack(proj, i)) end
  if reaper.GetRegionOrMarkerInfo_Value and reaper.GetNumRegionsOrMarkers then
    for i = 0, reaper.GetNumRegionsOrMarkers(proj) - 1 do
      local m = reaper.GetRegionOrMarker(proj, i, "")
      if reaper.GetRegionOrMarkerInfo_Value(proj, m, "B_ISREGION") == 1 and reaper.GetRegionOrMarkerInfo_Value(proj, m, "B_UISEL") == 1 then
        local _, name = reaper.GetSetRegionOrMarkerInfo_String(proj, m, "P_NAME", "", false)
        if name ~= "" and not name:find("^%[claimed") then regions[#regions + 1] = name end
      end
    end
  else
    local _, ri = reaper.GetLastMarkerAndCurRegion(proj, reaper.GetCursorPositionEx(proj))
    local _, isrgn, _, _, name = reaper.EnumProjectMarkers3(proj, ri)
    if ri >= 0 and isrgn and name ~= "" then regions[1] = name end
  end
  local from, to = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  return tracks, regions, to - from >= 0.01 and { from = from, to = to } or nil
end

local function take_words(mode) return require("live").driving(mode).take end -- (what taking control means in this mode, the panel's tooltip)
-- The topic. who: sync.authority's second answer from webui's presence build (nil before the first).
function websession.build(proj, cfg, b, who)
  local sync, groups = require("sync"), require("groups")
  who = type(who) == "table" and who or select(2, sync.authority(cfg, b.song, b.room))
  local me, key = cfg.user, tostring(proj)
  local here_list = require("presence").here(cfg, b.song, b.room, 45)
  local here = { [me] = true }
  for _, u in ipairs(here_list) do here[u] = true end
  local mode, driver = who.mode or sync.DEFAULT_MODE, who.driver
  local manage = groups.may_manage(cfg.root, me)
  local mine, away = websession.claims_of(who, me, here)
  local granted = mode == "admins" and type(who.granted) == "table" and who.granted[me] ~= nil
  local alone = reaper.GetExtState(band.SECTION, "alone " .. key) ~= ""
  local tracks, regions, time = selection(proj)
  local removal = require("removal")
  local people = {}
  for _, u in ipairs(here_list) do
    if u ~= me then
      local okr, mark = pcall(removal.mark, cfg.root, u)
      local role = groups.role(cfg.root, u)
      local okk, k = pcall(require("persons").of, cfg.root, u) -- (whose person: the play topic's Follow key)
      people[u] = { role = require("tools").guest_until(cfg.root, u) and "guest" or role, key = okk and k or u,
        can = websession.rights(groups, cfg.root, me, u, { driving = driver == me, here = true, marked = okr and mark and true or false }) }
    end
  end
  local modes = {}
  for _, m in ipairs(require("live").MODE_INFO) do modes[#modes + 1] = { id = m[1], name = m[2], tip = m[3] } end
  local ideas = {}
  for w, n in pairs(require("tools").ideas(proj)) do ideas[#ideas + 1] = { who = w, n = n } end
  table.sort(ideas, function(a, z) return a.who < z.who end)
  local away_d = reaper.GetExtState(band.SECTION, "driver_away " .. key)
  return { me = me, role = groups.role(cfg.root, me), mode = mode, modes = modes, may_set = manage or nil, driver = driver,
    driving = driver == me or nil, away = away_d ~= "" and driver ~= me and away_d or nil, alone = alone or nil,
    take = take_words(mode),
    viewonly = websession.view_only({ mode = mode, driver = driver, me = me, driver_here = driver and here[driver], alone = alone,
      may_manage = manage, granted = granted, mine = #mine }),
    followdriver = reaper.GetExtState(band.SECTION, "follow driver") ~= "" or nil,
    localmix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" or nil,
    claims = mine, locked = mode == "admins" and not manage or nil, release = driver == me and #away > 0 and away or nil,
    sel = { tracks = tracks, regions = regions, time = time }, people = people, ideas = ideas, said = S.said }
end
-- ---- what the page sends ----------------------------------------------------------------------------------------------------------------
local function said(text, ok, extra)
  S.n = S.n + 1
  S.said, S.at = { text = text, ok = ok ~= false or nil, n = S.n }, -math.huge
  for k, v in pairs(extra or {}) do S.said[k] = v end
  return text
end
-- Add tracks, regions or a stretch of time to your own claims (the panel's claim(): no repeats, claimed by hand so not an auto-claim).
local function claim(cfg, b, tracks, regions, time)
  local sync = require("sync")
  local c, why = sync.my_claims(cfg, b.song, b.room)
  if not c then return nil, why end
  c.tracks, c.regions = c.tracks or {}, c.regions or {}
  local function add(list, kind, name)
    for _, n in ipairs(list) do if n:lower() == name:lower() then return end end
    list[#list + 1] = name
    if c.auto then c.auto[kind .. ":" .. name:lower()] = nil end
  end
  for _, n in ipairs(tracks) do add(c.tracks, "tracks", n) end
  for _, n in ipairs(regions) do add(c.regions, "regions", n) end
  if time then c.times = c.times or {}; c.times[#c.times + 1] = { from = time.from, to = time.to, at = iso() } end
  sync.set_claims(cfg, b.song, b.room, c)
  return true
end
-- Let go of one of your claims (the panel's chip x): r = { kind, name } or { kind = "times", from, to }.
local function release_one(cfg, b, r)
  local sync = require("sync")
  if type(r) ~= "table" or not (r.kind == "tracks" or r.kind == "regions" or r.kind == "times") then return nil, "not a claim" end
  if r.kind ~= "times" and not name_ok(r.name) then return nil, "not a claim" end
  if r.kind == "times" and not (tonumber(r.from) and tonumber(r.to)) then return nil, "not a claim" end
  local c, why = sync.my_claims(cfg, b.song, b.room)
  if not c then return nil, why end
  local keep, n = {}, 0
  for _, x in ipairs(c[r.kind] or {}) do
    local same = r.kind == "times" and type(x) == "table" and math.abs((tonumber(x.from) or 0) - r.from) < 1e-3 and math.abs((tonumber(x.to) or 0) - r.to) < 1e-3
      or r.kind ~= "times" and type(x) == "string" and x:lower() == r.name:lower()
    if same then n = n + 1 else keep[#keep + 1] = x end
  end
  c[r.kind] = keep
  c.let_go = { [sync.claim_key(r.kind, r.kind == "times" and { from = r.from, to = r.to } or r.name) or ""] = true } -- (a given one only the link brought: let go too)
  sync.set_claims(cfg, b.song, b.room, c)
  return n
end

-- a: { topic = "session", ... } one of: mode (an id), take (with anyway: past "not everyone is in sync"), handover (a name), followdriver
-- (bool), localmix (true; or false with keep = "theirs" | "mine": whose faders after), claim ("tracks" | "regions" | "time"), release
-- ({ kind, name | from, to } or "all"), release_for (a name: whoever is in control, for someone away), give ({ user, what = "tracks" |
-- "regions" | "time" }), admin ({ user, on }), owner (a name), remove (a name), keep (a name), ideas ("keep" | "dismiss", with who), rooms
-- (lib/webrooms.lua's). here: the extension says a page on this computer sent it. -> words for the log, or nil.
function websession.action(proj, cfg, b, a, here)
  if type(a) ~= "table" then return nil end
  local sync, groups = require("sync"), require("groups")
  local me = cfg.user
  if type(a.rooms) == "table" then return require("webrooms").action(proj, cfg, b, a.rooms, here) end
  local function no(why) return said("the web page's " .. why, false) end
  if a.mode ~= nil then
    if not groups.may_manage(cfg.root, me) then return no("Who can edit was refused: the studio's owner or an admin picks it") end
    if type(a.mode) ~= "string" or not sync.MODES[a.mode] then return no("Who can edit: not a mode") end
    local name = a.mode
    for _, m in ipairs(require("live").MODE_INFO) do if m[1] == a.mode then name = m[2] end end
    sync.set_mode(cfg, b.song, b.room, a.mode, me)
    return said("editing in '" .. b.room .. "' is now " .. name .. ", from the web page")
  end
  if a.take then
    local s = band.read_json(band.session_path(cfg, b.song))
    local was = sync.driver(cfg, b.song, b.room, s)
    if was == me then return said("you're already in control of '" .. b.song .. "'") end
    if not a.anyway then
      local c = require("status").handover_check(cfg, b, proj)
      if #c.problems > 0 then return said("not everyone is in sync yet: " .. table.concat(c.problems, "; "), false, { take = true }) end
    end
    -- (Take control's own steps, without its boxes: a box from a phone's press would sit on REAPER's window. A recall point first, as ever)
    require("recall").save(proj, cfg, b.song, b.room, "before " .. me .. " took over from " .. tostring(was))
    sync.set_driver(cfg, b.song, b.room, me)
    sync.post(cfg, b.song, b.room, { type = "driver", from = was, driver = me })
    return said("you're in control of '" .. b.song .. "' now (" .. take_words(sync.mode(cfg, b.song, b.room)) .. "), from the web page")
  end
  if a.handover ~= nil then
    if not name_ok(a.handover) or a.handover == me then return no("hand over: not someone") end
    local s = band.read_json(band.session_path(cfg, b.song))
    if sync.driver(cfg, b.song, b.room, s) ~= me then return no("hand over was refused: only whoever is in control hands over") end
    local ok = false
    for _, u in ipairs(require("presence").here(cfg, b.song, b.room, 45)) do ok = ok or u == a.handover end
    if not ok then return no("hand over was refused: " .. a.handover .. " isn't here") end
    sync.hand_over(proj, cfg, b.song, b.room, a.handover)
    return said(a.handover .. " is in control now, from the web page")
  end
  if a.followdriver ~= nil then
    reaper.SetExtState(band.SECTION, "follow driver", a.followdriver == true and "1" or "", true)
    if a.followdriver == true then reaper.DeleteExtState(band.SECTION, "follow " .. tostring(proj), false) end
    return said(a.followdriver == true and "you always follow whoever is in control now" or "you don't always follow whoever is in control any more")
  end
  if a.localmix ~= nil then
    local mirror = require("mirror")
    if a.localmix == true then
      reaper.SetProjExtState(proj, band.SECTION, "local_mix", "1")
      mirror.begin_local_mix(proj)
      return said("Local mixing is on: your faders and pan stay yours (web page)")
    end
    if a.keep ~= "theirs" and a.keep ~= "mine" then return no("Local mixing off: whose mix wasn't said") end
    mirror.end_local_mix(proj, cfg, b.song, b.room, a.keep == "theirs")
    reaper.SetProjExtState(proj, band.SECTION, "local_mix", "")
    return said(a.keep == "theirs" and "Local mixing is off: your faders and pan follow the studio's again (web page)"
      or "Local mixing is off: your faders and pan go to everyone (the tracks you may change) (web page)")
  end
  if a.claim ~= nil then
    if sync.mode(cfg, b.song, b.room) == "admins" and not groups.may_manage(cfg.root, me) then return no("claim was refused: admins only here (an admin can give you tracks)") end
    local tracks, regions, time = selection(proj)
    local t, r, tm = a.claim == "tracks" and tracks or {}, a.claim == "regions" and regions or {}, a.claim == "time" and time or nil
    if #t == 0 and #r == 0 and not tm then
      return no(a.claim == "tracks" and "claim: select the tracks first" or a.claim == "regions" and "claim: click a named region in the ruler first" or "claim: drag across the ruler first")
    end
    local ok, why = claim(cfg, b, t, r, tm)
    if not ok then return no("claim: " .. tostring(why)) end
    return said("claimed " .. (#t > 0 and table.concat(t, ", ") or #r > 0 and ("the region " .. table.concat(r, ", ")) or "the time selection") .. ", from the web page")
  end
  if a.release == "all" then
    local c = sync.my_claims(cfg, b.song, b.room) or {} -- (printing duties stay, as the panel's Release all claims)
    sync.set_claims(cfg, b.song, b.room, { tracks = {}, regions = {}, times = {}, prints = c.prints })
    return said("released all your claims, from the web page")
  end
  if a.release ~= nil then
    local n, why = release_one(cfg, b, a.release)
    if not n then return no("release: " .. tostring(why)) end
    return said(n > 0 and "released it, from the web page" or "that wasn't one of your claims any more")
  end
  if a.release_for ~= nil then
    if not name_ok(a.release_for) or a.release_for == me then return no("release: not someone") end
    local s = band.read_json(band.session_path(cfg, b.song))
    if sync.driver(cfg, b.song, b.room, s) ~= me then return no("release was refused: only whoever is in control releases someone else's claims") end
    for _, u in ipairs(require("presence").here(cfg, b.song, b.room, 45)) do
      if u == a.release_for then return no("release was refused: " .. u .. " is here (they release their own)") end
    end
    sync.release_claims(cfg, b.song, b.room, a.release_for)
    return said("released " .. a.release_for .. "'s claims: what they had follows whoever is in control now")
  end
  if a.give ~= nil then
    local g = a.give
    if type(g) ~= "table" or not name_ok(g.user) or g.user == me then return no("give: not someone") end
    if not groups.may_manage(cfg.root, me) then return no("give was refused: only the studio's owner or an admin gives control") end
    local tracks, regions, time = selection(proj)
    local t, r, tm = g.what == "tracks" and tracks or {}, g.what == "regions" and regions or {}, g.what == "time" and time and { time } or {}
    if #t == 0 and #r == 0 and #tm == 0 then return no("give: select what to give first (tracks, a region or a time selection, in REAPER)") end
    sync.give_claims(cfg, b.song, b.room, g.user, t, r, tm)
    return said("gave " .. g.user .. " " .. (#t > 0 and table.concat(t, ", ") or #r > 0 and ("the region " .. table.concat(r, ", ")) or "the time selection") .. ", from the web page")
  end
  -- (roles and removal change the studio: the owner's or an admin's own computer only, never from another device. Decision 4)
  if a.admin ~= nil or a.owner ~= nil or a.remove ~= nil or a.keep ~= nil then
    if not here then return no("change to the studio's people was refused: only from this computer's own page") end
    local removal = require("removal")
    if type(a.admin) == "table" then
      if not name_ok(a.admin.user) or a.admin.user == me then return no("Make admin: not someone") end
      local ok, why = groups.set_admin(cfg.root, me, a.admin.user, a.admin.on == true)
      if not ok then return no("Make admin was refused: " .. tostring(why)) end
      return said(a.admin.user .. (a.admin.on == true and " is an admin now: they can let people in, rename the studio, remove members and give claims" or " is a member again") .. " (web page)")
    end
    if a.owner ~= nil then
      if not name_ok(a.owner) or a.owner == me then return no("Make owner: not someone") end
      local ok, why = groups.hand_over(cfg.root, me, a.owner)
      if not ok then return no("Make owner was refused: " .. tostring(why)) end
      return said(a.owner .. " owns the studio now, and you're an admin (web page)")
    end
    if a.remove ~= nil then
      if not name_ok(a.remove) or not groups.may_remove(cfg.root, me, a.remove) then return no("Remove from the studio was refused: the owner removes anyone, an admin only members") end
      if removal.mark(cfg.root, a.remove) then return no("Remove: " .. a.remove .. " is already leaving") end
      local ok, why = removal.remove(cfg.root, a.remove, me)
      if not ok then return no("Remove: " .. tostring(why)) end
      return said(a.remove .. " leaves the studio in a minute: Keep them stops it (web page)")
    end
    if not name_ok(a.keep) or not groups.may_manage(cfg.root, me) then return no("Keep them was refused: the owner or an admin keeps someone") end
    if not removal.mark(cfg.root, a.keep) then return no("Keep them: " .. a.keep .. " isn't leaving") end
    removal.keep(cfg.root, a.keep)
    return said(a.keep .. " stays in the studio (web page)")
  end
  if a.ideas == "keep" then return said(require("tools").keep_ideas(proj) .. " idea(s) kept as your own items, from the web page") end
  if a.ideas == "dismiss" then
    local w = a.who
    if w ~= nil and not name_ok(w) then return no("dismiss: not someone") end
    return said(require("tools").dismiss_ideas(proj, w) .. " idea(s) dismissed, from the web page")
  end
end

-- Each tick in front, while a page looks (lib/webui.lua). who: sync.authority's second answer from webui's presence build.
function websession.tick(proj, cfg, b, publish, who, now)
  if now - S.at >= websession.EVERY then
    S.at = now
    local ok, m = pcall(websession.build, proj, cfg, b, who)
    publish("session", ok and m or { error = tostring(m) })
  end
  require("webrooms").tick(proj, cfg, b, publish, now)
end
function websession._reset() S = { at = -math.huge, n = 0 } end -- (tests)

return websession
