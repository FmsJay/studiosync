-- rt-ui6 (docs/rt/ui-web-plan.md Phase 6, the Session tab): lib/websession.lua's pure parts (the strip's View only, your claims and who's away,
-- the person menu's rights), its topic built from a stand-in REAPER and studio, every action and each refusal the panel makes (the mode and Give
-- them control of for the owner and admins only, hand over only by whoever is in control, roles for the owner and from this computer only,
-- Remove by groups.may_remove), Take control without its boxes, Local mixing's named choices, claims from REAPER's selection, Live ideas;
-- lib/webrooms.lua's model, actions and tick (the list only while Rooms shows, the asks always); the hooks in webui.lua, index.html, shell.js,
-- app.js and the page files. The pages themselves run in tests/rt_ui6_browser.mjs. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext, pext, logs = 1000, {}, {}, {}
local sel_tracks, regions, loop = {}, {}, { 0, 0 }
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(s, k) return ext[k] or "" end,
  SetExtState = function(s, k, v) ext[k] = v end,
  DeleteExtState = function(s, k) ext[k] = nil end,
  GetProjExtState = function(_, _, k) return 1, pext[k] or "" end,
  SetProjExtState = function(_, _, k, v) pext[k] = v end,
  CountSelectedTracks = function() return #sel_tracks end,
  GetSelectedTrack = function(_, i) return sel_tracks[i + 1] end,
  GetTrackName = function(tr) return true, tr.name end,
  GetSetMediaTrackInfo_String = function(tr, k) return true, tr[k] or "" end,
  GetRegionOrMarkerInfo_Value = function(_, m, k) if k == "B_ISREGION" then return 1 end return m.sel and 1 or 0 end,
  GetNumRegionsOrMarkers = function() return #regions end,
  GetRegionOrMarker = function(_, i) return regions[i + 1] end,
  GetSetRegionOrMarkerInfo_String = function(_, m) return true, m.name end,
  GetSet_LoopTimeRange2 = function() return loop[1], loop[2] end,
  file_exists = function() return false end,
  RecursiveCreateDirectory = function() return 1 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function(t) logs[#logs + 1] = t end
band.read_json = function() return { host = "James-Main" } end
local calls = {}
local function rec(name) return function(...) calls[#calls + 1] = { name, ... }; return true end end
local function called(name) for i = #calls, 1, -1 do if calls[i][1] == name then return calls[i] end end end
local driver, mode, myclaims, here_now = "Bo", "driver", { tracks = { "Keys" }, regions = {}, times = { { from = 4, to = 8 } }, prints = { "x" } }, { "Bo", "Cy" }
local roles = { ["James-Main"] = "owner", Bo = "admin", Cy = "member" }
package.loaded.sync = { DEFAULT_MODE = "open", MODES = { driver = true, open = true, everyone = true, admins = true },
  base_name = function(n) return (n:gsub(" %(studio%)$", "")) end,
  authority = function() return function() return true end, { mode = mode, driver = driver, tracks = {}, regions = {}, times = {} } end,
  driver = function() return driver end, mode = function() return mode end,
  set_mode = rec("set_mode"), set_driver = function(_, _, _, u) calls[#calls + 1] = { "set_driver", u }; driver = u end, post = rec("post"),
  hand_over = rec("hand_over"), give_claims = rec("give_claims"), release_claims = rec("release_claims"),
  my_claims = function() return myclaims end, set_claims = function(_, _, _, c) calls[#calls + 1] = { "set_claims", c }; myclaims = c end,
  claim_key = function(kind, n) return kind .. ":" .. (type(n) == "table" and (n.from .. "|" .. n.to) or n:lower()) end,
  room_dir = function(_, s, r) return "S/" .. s .. "/rooms/" .. r end }
package.loaded.groups = { role = function(_, u) return roles[u] or "member" end, may_manage = function(_, u) return (roles[u] or "member") ~= "member" end,
  may_remove = function(_, by, t) if by == t then return false end local r, x = roles[by] or "member", roles[t] or "member"; return r == "owner" or (r == "admin" and x == "member") end,
  set_admin = function(_, actor, t, on) if roles[actor] ~= "owner" then return nil, "Only the owner can do that." end calls[#calls + 1] = { "set_admin", t, on }; return true end,
  hand_over = function(_, actor, t) if roles[actor] ~= "owner" then return nil, "Only the owner can do that." end calls[#calls + 1] = { "group_owner", t }; return true end }
package.loaded.presence = { here = function() return here_now end }
local marks = {}
package.loaded.removal = { mark = function(_, u) return marks[u] end, remove = function(_, u, by) calls[#calls + 1] = { "remove", u, by }; marks[u] = { at = 1 }; return true end,
  keep = function(_, u) calls[#calls + 1] = { "keep", u }; marks[u] = nil end }
package.loaded.persons = { of = function(_, u) return u == "Bo-Laptop" and "Bo" or u end }
local ideas = { Bo = 2 }
package.loaded.tools = { ideas = function() return ideas end, keep_ideas = function() calls[#calls + 1] = { "keep_ideas" }; return 3 end,
  dismiss_ideas = function(_, w) calls[#calls + 1] = { "dismiss_ideas", w or "*" }; return 2 end, guest_until = function(_, u) return u == "Gus" and "2026-12-01" or nil end }
package.loaded.mirror = { begin_local_mix = rec("begin_local_mix"), end_local_mix = function(_, _, _, _, adopt) calls[#calls + 1] = { "end_local_mix", adopt } end }
package.loaded.recall = { save = rec("recall_save") }
local problems = {}
package.loaded.status = { handover_check = function() return { problems = problems, offline = {} } end }
local websession = require("websession")
local cfg, b, P = { root = "C:/Chilio", user = "James-Main" }, { song = "Cross Test", room = "main" }, "P1"

-- ---- pure: View only, claims, rights ------------------------------------------------------------------------------------------------------
do
  local vo = websession.view_only
  assert(vo({ mode = "driver", driver = "Bo", me = "Me", driver_here = true }) == "driver", "Driver only, Bo in control and here: view only")
  assert(vo({ mode = "driver", driver = "Me", me = "Me", driver_here = true }) == nil, "not when you're in control")
  assert(vo({ mode = "driver", driver = "Bo", me = "Me", driver_here = false }) == nil, "not while they're away (Take control instead)")
  assert(vo({ mode = "driver", driver = "Bo", me = "Me", driver_here = true, alone = true }) == nil, "not when you're alone")
  assert(vo({ mode = "open", driver = "Bo", me = "Me", driver_here = true }) == nil, "Claims: everyone edits")
  assert(vo({ mode = "admins", driver = "Bo", me = "Me", driver_here = true }) == "admins", "Admins only, a member: view only")
  assert(vo({ mode = "admins", driver = "Bo", me = "Me", driver_here = true, may_manage = true }) == nil, "not an admin")
  assert(vo({ mode = "admins", driver = "Bo", me = "Me", driver_here = true, granted = true }) == nil, "not someone an admin let edit here")
  assert(vo({ mode = "admins", driver = "Bo", me = "Me", driver_here = true, mine = 1 }) == nil, "not someone given a claim")
  local mine, away = websession.claims_of({ tracks = { keys = { user = "Me", name = "Keys" }, bass = { user = "Bo", name = "Bass" }, gtr = { user = "Al", name = "Gtr", auto = true } },
    regions = { verse = { user = "Me", name = "Verse", auto = true } }, times = { { user = "Me", from = 8, to = 4 + 8 }, { user = "Zed", from = 1, to = 2 }, { user = "Me", from = "x" } } }, "Me", { Bo = true })
  assert(#mine == 3 and mine[1].kind == "regions" and mine[1].auto and mine[2].kind == "times" and mine[2].from == 8 and mine[3].name == "Keys", "yours, sorted, a bad time left out")
  assert(#away == 2 and away[1] == "Al" and away[2] == "Zed", "who holds claims and isn't here")
  local g = package.loaded.groups
  local r = websession.rights(g, "R", "James-Main", "Cy", { driving = true, here = true })
  assert(r.admin == "admin" and r.owner and r.handover and r.give and r.remove and not r.keep, "the owner, in control: everything")
  assert(websession.rights(g, "R", "James-Main", "Bo", { here = true }).admin == "member", "an admin is made a member")
  r = websession.rights(g, "R", "Bo", "Cy", { here = true })
  assert(not r.admin and not r.owner and not r.handover and r.give and r.remove, "an admin: give and remove a member, no roles, no hand over")
  assert(not websession.rights(g, "R", "Bo", "James-Main", { here = true }).remove, "an admin can't remove the owner")
  r = websession.rights(g, "R", "Cy", "Bo", { here = true, driving = true })
  assert(not r.give and not r.remove and not r.admin and r.handover, "a member in control: only hand over")
  r = websession.rights(g, "R", "James-Main", "Cy", { here = true, marked = true })
  assert(r.keep and not r.remove, "someone leaving: Keep them")
  assert(next(websession.rights(g, "R", "Me", "Me", {})) == nil, "nothing about yourself")
end

-- ---- the topic --------------------------------------------------------------------------------------------------------------------------
do
  sel_tracks = { { name = "Keys (studio)" }, { name = "Bass", ["P_EXT:band_midi_track"] = "Bass MIDI" } }
  regions = { { name = "Verse", sel = true }, { name = "[claimed: Bo]", sel = true }, { name = "Chorus" } }
  loop = { 2, 6 }
  ext["alone P1"], ext["follow driver"], pext.local_mix = "", "1", "1"
  local m = websession.build(P, cfg, b, { mode = "driver", driver = "Bo", tracks = { keys = { user = "James-Main", name = "Keys" }, gtr = { user = "Al", name = "Gtr" } }, regions = {}, times = {} })
  assert(m.me == "James-Main" and m.role == "owner" and m.mode == "driver" and m.may_set and m.driver == "Bo" and not m.driving, "who, the mode, who's in control")
  assert(m.viewonly == "driver", "Driver only and Bo is here: View only (the strip's words)")
  assert(#m.modes == 4 and m.modes[1].id == "open" and m.modes[1].name == "Claims" and m.take:find("only your changes"), "the four modes in the panel's words, and what taking control means")
  assert(m.followdriver and m.localmix and not m.alone, "the switches")
  assert(#m.claims == 1 and m.claims[1].name == "Keys" and not m.release and not m.locked, "your claims; Release for someone away only for whoever is in control")
  assert(m.sel.tracks[1] == "Keys" and m.sel.tracks[2] == "Bass MIDI" and #m.sel.regions == 1 and m.sel.regions[1] == "Verse" and m.sel.time.from == 2, "REAPER's selection, as the panel names parts")
  assert(m.people.Bo.role == "admin" and m.people.Bo.can.admin == "member" and m.people.Cy.can.remove and m.people.Cy.key == "Cy" and not m.people["James-Main"], "the person menu's rights, not about you")
  assert(m.ideas[1].who == "Bo" and m.ideas[1].n == 2, "Live ideas")
  driver = "James-Main"
  m = websession.build(P, cfg, b, { mode = "admins", driver = "James-Main", tracks = { gtr = { user = "Al", name = "Gtr" } }, regions = {}, times = {} })
  assert(m.driving and not m.viewonly and m.release[1] == "Al" and m.people.Cy.can.handover, "in control: Release Al's claims, hand over")
  roles["James-Main"] = "member"
  m = websession.build(P, cfg, b, { mode = "admins", driver = "Bo", tracks = {}, regions = {}, times = {} })
  assert(m.locked and not m.may_set and m.viewonly == "admins" and not m.people.Cy.can.give, "a member in Admins only: locked, view only, nothing to give")
  m = websession.build(P, cfg, b, { mode = "admins", driver = "Bo", tracks = {}, regions = {}, times = {}, granted = { ["James-Main"] = { by = "Bo" } } })
  assert(not m.viewonly, "unless an admin let them edit here")
  roles["James-Main"], driver = "owner", "Bo"
end

-- ---- actions ----------------------------------------------------------------------------------------------------------------------------
local function act(a, here) calls = {}; return websession.action(P, cfg, b, a, here ~= false) end
local function last_said() return websession.build(P, cfg, b).said end
do
  -- Who can edit
  roles["James-Main"] = "member"
  assert(act({ mode = "everyone" }):find("refused") and not called("set_mode"), "a member can't change Who can edit")
  roles["James-Main"] = "admin"
  assert(act({ mode = "nope" }):find("not a mode") and not called("set_mode"), "only a real mode")
  assert(act({ mode = "everyone" }):find("now Open") and called("set_mode")[5] == "everyone", "an admin picks Open")
  assert(last_said().ok and last_said().text:find("Open"), "the page is told")
  roles["James-Main"] = "owner"
  -- Take control: no boxes; not in sync -> said, with "anyway"
  problems = { "Bo hasn't got every take yet" }
  assert(act({ take = true }):find("not everyone is in sync") and not called("set_driver"), "not in sync: not taken")
  assert(last_said().take and not last_said().ok, "the page offers Take control anyway")
  act({ take = true, anyway = true })
  assert(called("recall_save") and called("set_driver")[2] == "James-Main" and called("post")[5].driver == "James-Main", "anyway: a recall point, then in control, posted")
  assert(act({ take = true }):find("already in control") and not called("set_driver"), "twice is once")
  problems = {}
  -- hand over: only whoever is in control, only to someone here
  driver = "Bo"
  assert(act({ handover = "Cy" }):find("refused") and not called("hand_over"), "not in control: no hand over")
  driver = "James-Main"
  assert(act({ handover = "Zed" }):find("isn't here") and not called("hand_over"), "only to someone here")
  assert(act({ handover = "Cy" }) and called("hand_over")[6] == "Cy", "handed over")
  assert(act({ handover = 5 }):find("not someone") and act({ handover = string.rep("x", 65) }):find("not someone"), "a name, checked")
  -- Always follow whoever is in control
  act({ followdriver = true }); assert(ext["follow driver"] == "1", "on")
  ext["follow P1"] = "Bo"; act({ followdriver = true }); assert(ext["follow P1"] == nil, "and following a person stops, as the panel's")
  act({ followdriver = false }); assert(ext["follow driver"] == "", "off")
  -- Local mixing: on; off only with whose mix
  pext.local_mix = ""
  act({ localmix = true }); assert(pext.local_mix == "1" and called("begin_local_mix"), "on")
  assert(act({ localmix = false }):find("whose mix") and pext.local_mix == "1" and not called("end_local_mix"), "off without saying whose mix: nothing")
  act({ localmix = false, keep = "theirs" }); assert(pext.local_mix == "" and called("end_local_mix")[2] == true, "off: the studio's mix")
  pext.local_mix = "1"; act({ localmix = false, keep = "mine" }); assert(called("end_local_mix")[2] == false, "off: mine to everyone")
end
do
  -- Claims from REAPER's selection
  myclaims = { tracks = { "Keys" }, regions = {}, times = {}, auto = { ["tracks:bass midi"] = 1 } }
  sel_tracks = { { name = "keys" }, { name = "Bass", ["P_EXT:band_midi_track"] = "Bass MIDI" } }
  mode = "open" -- ("keys": Keys already, any case)
  assert(act({ claim = "tracks" }):find("claimed keys, Bass MIDI"), "claimed what's selected")
  assert(#myclaims.tracks == 2 and myclaims.tracks[2] == "Bass MIDI" and myclaims.auto["tracks:bass midi"] == nil, "no repeats; claimed by hand isn't an auto-claim")
  act({ claim = "regions" }); assert(myclaims.regions[1] == "Verse", "the selected region, not a claimed-marker")
  act({ claim = "time" }); assert(myclaims.times[1].from == 2 and myclaims.times[1].to == 6 and myclaims.times[1].at, "the time selection, its own date")
  sel_tracks = {}
  assert(act({ claim = "tracks" }):find("select the tracks first") and not called("set_claims"), "nothing selected: said")
  mode, roles["James-Main"] = "admins", "member"
  sel_tracks = { { name = "Keys" } }
  assert(act({ claim = "tracks" }):find("refused") and not called("set_claims"), "Admins only, a member: no claims (an admin gives them)")
  mode, roles["James-Main"] = "driver", "owner"
  -- release one, all
  myclaims = { tracks = { "Keys", "Bass" }, regions = {}, times = { { from = 4, to = 8 } }, prints = { "Drums" } }
  assert(act({ release = { kind = "tracks", name = "keys" } }):find("released") and #myclaims.tracks == 1 and myclaims.tracks[1] == "Bass" and myclaims.let_go["tracks:keys"], "one track let go")
  act({ release = { kind = "times", from = 4, to = 8 } }); assert(#myclaims.times == 0, "a stretch of time let go")
  assert(act({ release = { kind = "tracks" } }):find("not a claim") and act({ release = { kind = "x", name = "a" } }):find("not a claim"), "a claim, checked")
  act({ release = "all" }); assert(#myclaims.tracks == 0 and myclaims.prints[1] == "Drums", "all, printing duties kept")
  -- someone away's claims: whoever is in control, and only for someone not here
  driver = "Bo"
  assert(act({ release_for = "Al" }):find("refused") and not called("release_claims"), "not in control: refused")
  driver = "James-Main"
  assert(act({ release_for = "Cy" }):find("is here") and not called("release_claims"), "they're here: they release their own")
  act({ release_for = "Al" }); assert(called("release_claims")[5] == "Al", "released Al's")
  -- Give them control of: the owner and admins only, what's selected
  roles["James-Main"] = "member"
  assert(act({ give = { user = "Cy", what = "tracks" } }):find("refused") and not called("give_claims"), "a member can't give")
  roles["James-Main"] = "admin"
  sel_tracks = { { name = "Keys" } }
  act({ give = { user = "Cy", what = "tracks" } })
  local g = called("give_claims")
  assert(g and g[5] == "Cy" and g[6][1] == "Keys" and #g[7] == 0 and #g[8] == 0, "an admin gives Cy the selected track")
  act({ give = { user = "Cy", what = "time" } }); assert(called("give_claims")[8][1].from == 2, "or the time selection")
  sel_tracks = {}
  assert(act({ give = { user = "Cy", what = "tracks" } }):find("select what to give") and not called("give_claims"), "nothing selected: said")
  assert(act({ give = { user = "James-Main", what = "tracks" } }):find("not someone"), "not to yourself")
  roles["James-Main"] = "owner"
end
do
  -- roles and removal: the owner (or groups' rule), this computer's page only
  assert(act({ admin = { user = "Cy", on = true } }, false):find("only from this computer") and not called("set_admin"), "another device: refused")
  roles["James-Main"] = "admin"
  assert(act({ admin = { user = "Cy", on = true } }):find("Only the owner") and not called("set_admin"), "an admin: refused (groups' own rule)")
  assert(act({ owner = "Cy" }):find("Only the owner") and not called("group_owner"), "Make owner too")
  roles["James-Main"] = "owner"
  act({ admin = { user = "Cy", on = true } }); assert(called("set_admin")[2] == "Cy" and called("set_admin")[3] == true, "the owner makes Cy an admin")
  act({ owner = "Bo" }); assert(called("group_owner")[2] == "Bo", "and Bo the owner")
  roles["James-Main"] = "admin"
  assert(act({ remove = "Bo" }):find("refused") and not called("remove"), "an admin can't remove an admin")
  act({ remove = "Cy" }); assert(called("remove")[2] == "Cy" and called("remove")[3] == "James-Main", "but a member, yes")
  assert(act({ remove = "Cy" }):find("already leaving"), "once")
  assert(act({ remove = "Cy" }, false):find("only from this computer"), "never from another device")
  act({ keep = "Cy" }); assert(called("keep")[2] == "Cy", "Keep them")
  assert(act({ keep = "Cy" }):find("isn't leaving"), "only someone leaving")
  roles["James-Main"] = "member"
  marks.Cy = { at = 1 }
  assert(act({ keep = "Cy" }):find("refused") and not called("keep"), "a member can't keep them")
  marks.Cy, roles["James-Main"] = nil, "owner"
  -- Live ideas
  act({ ideas = "keep" }); assert(called("keep_ideas"), "kept")
  act({ ideas = "dismiss", who = "Bo" }); assert(called("dismiss_ideas")[2] == "Bo", "Bo's dismissed")
  act({ ideas = "dismiss" }); assert(called("dismiss_ideas")[2] == "*", "everyone's")
  assert(act({}) == nil and websession.action(P, cfg, b, "x") == nil, "nothing asked: nothing done")
end

-- ---- Rooms (lib/webrooms.lua) -------------------------------------------------------------------------------------------------------------
local roomlist = { { name = "main", time = "" }, { name = "chorus", parent = "main", time = "1" }, { name = "alt", parent = "main", fork = { from = "main" }, time = "2" },
  { name = "old", parent = "main", binned = "Bo", time = "0" } }
local inroom = { main = { { user = "James-Main", here = true, me = true }, { user = "Bo", here = true } }, chorus = {}, alt = { { user = "Cy" } } }
local invites, metas, opened, started = { { from = "Bo", room = "chorus", time = "t1" }, { from = "Cy", room = "main", time = "t2" } }, { chorus = { parent = "main", time = "T" } }, nil, 0
package.loaded.rooms = { list = function() return roomlist end, people = function(_, _, r) return inroom[r] or {} end, invites = function() return invites end,
  meta = function(_, _, r) return metas[r] end, bin = function(_, _, r, who) calls[#calls + 1] = { "bin", r, who or "-" } end, invite = rec("invite"),
  create = function(_, _, _, n) if n == "bad/" then return nil, "Room names: up to 30 letters" end calls[#calls + 1] = { "create", n }; return "P2" end,
  tab = function() return nil end }
package.loaded.forks = { origin_words = function(r) return "fork of " .. r.parent end, create = function(_, _, _, n) calls[#calls + 1] = { "fork", n }; return "P3" end,
  theirs = function() return {} end, by_track = function(bring) local rows = {}; for i = 1, #bring do rows[i] = { name = "T" .. i, fork = 1, both = 0, theirs = 0 } end; return rows end,
  pick = function(bring) return bring end, adopt = function() calls[#calls + 1] = { "adopt" }; return "main before alt", "done" end }
package.loaded.webhome = { open = function(_, o) opened = o; return "opening '" .. o.song .. "', from the web page" end }
band.start_live = function() started = started + 1; return true end
local mirror = package.loaded.mirror
mirror.selected = function() return { { oid = "a", name = "Keys" }, { oid = "b", name = "Bass" } } end
mirror.allowed_into = function(_, _, _, list) return { list[1] }, #list - 1 end
mirror.post_into = function(_, _, from, to, list) calls[#calls + 1] = { "post_into", from, to, #list }; return #list end
mirror.bring_plan = function() return { { oid = "a", name = "Keys" }, { oid = "b", name = "Bass" } }, { { oid = "c" } } end
mirror.room_newest = function() return {} end
local webrooms = require("webrooms")
do
  local m = webrooms.model({ room = "main", me = "James-Main", list = roomlist, people = inroom, invites = invites, meta = nil, full = true })
  assert(#m.rooms == 3 and m.rooms[1].main and m.rooms[1].here and m.rooms[1].came == "main room" and #m.rooms[1].people == 2, "main first, this tab, who's in it")
  assert(m.rooms[2].came == "side room of main" and m.rooms[3].came == "fork of main", "where each came from")
  assert(#m.archived == 1 and m.archived[1].by == "Bo", "archived ones apart")
  assert(#m.invites == 1 and m.invites[1].from == "Bo" and m.invites[1].room == "chorus", "asks to come and see, not to the room you're in")
  assert(not m.parent and not m.may_bring, "the main room: nothing to bring back")
  m = webrooms.model({ room = "chorus", me = "James-Main", list = roomlist, meta = { parent = "main" }, parent_driver = "Bo", full = true })
  assert(m.parent == "main" and m.parent_driver == "Bo" and not m.may_bring, "a side room: whoever is in control of main brings it in")
  m = webrooms.model({ room = "chorus", invites = invites, meta = { parent = "main" } })
  assert(not m.rooms and #m.invites == 1 and m.invites[1].from == "Cy" and m.parent == "main", "not shown: only the asks (not to the room you're in)")
  -- actions (through the session topic)
  local function ract(r) calls = {}; return websession.action(P, cfg, b, { rooms = r }, true) end
  assert(ract({ go = "nowhere" }):find("isn't one of") and not opened, "Go: only one of this project's rooms")
  ract({ go = "chorus" }); assert(opened.song == "Cross Test" and opened.room == "chorus", "Go: the Studio tab's Open (Open session opens a side room)")
  assert(ract({ create = "bad/" }):find("Room names") and started == 0, "a bad name: said")
  ract({ create = "bridge" }); assert(called("create")[2] == "bridge" and started == 1, "a side room, Live sync started for it")
  ract({ create = "take 2", fork = true }); assert(called("fork")[2] == "take 2" and started == 2, "a fork")
  ract({ comesee = true }); assert(called("invite"), "come and see")
  assert(ract({ archive = "main" }):find("only a side room") and not called("bin"), "the main room isn't archived")
  assert(ract({ archive = "alt" }):find("someone has") and not called("bin"), "not while someone has it open")
  ract({ archive = "chorus" }); assert(called("bin")[2] == "chorus" and called("bin")[3] == "James-Main", "archived")
  ract({ unarchive = "old" }); assert(called("bin")[2] == "old" and called("bin")[3] == "-", "brought back")
  assert(ract({ send = true }):find("main room"), "from the main room there's nowhere to send")
  b.room = "chorus"
  ract({ send = true }); local pi = called("post_into"); assert(pi and pi[2] == "chorus" and pi[3] == "main" and pi[4] == 1, "Send selected: only what the claims there allow")
  ract({ look = true })
  driver = "Bo"
  assert(ract({ bring = true }):find("refused") and not called("post_into"), "Bring into: only whoever is in control of main")
  driver = "James-Main"
  ract({ bring = true }); assert(called("post_into")[4] == 1, "brought in, what the claims allow")
  assert(ract({ adopt = true }):find("only a fork") and not called("adopt"), "Adopt: only a fork")
  metas.chorus.fork = { from = "main" }
  ract({ adopt = true }); assert(called("adopt"), "a fork adopted")
  b.room = "main"
  -- the tick: the list only while Rooms shows; the asks always
  local pubs = {}
  local function publish(t, v) pubs[#pubs + 1] = { t, v } end
  webrooms._reset(); websession._reset()
  clock = 2000
  websession.tick(P, cfg, b, publish, nil, clock)
  local function lastof(t) for i = #pubs, 1, -1 do if pubs[i][1] == t then return pubs[i][2] end end end
  assert(lastof("session") and lastof("session").me == "James-Main", "session published")
  assert(lastof("rooms") and not lastof("rooms").rooms and #lastof("rooms").invites == 1, "rooms: only the asks while nobody shows Rooms")
  pubs = {}
  websession.tick(P, cfg, b, publish, nil, clock + 0.5)
  assert(not lastof("session") and not lastof("rooms"), "at most once a second, and the asks every few")
  websession.action(P, cfg, b, { rooms = { want = true } }, true)
  websession.tick(P, cfg, b, publish, nil, clock + 1.1)
  assert(lastof("session") and lastof("rooms").rooms and #lastof("rooms").rooms == 3, "shown: the list too")
end

-- ---- the hooks ----------------------------------------------------------------------------------------------------------------------------
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"):gsub("\r\n", "\n"); f:close(); return s end
do
  local w = read("lib/webui.lua")
  assert(require("webui").ACTIONS.session, "the pages may send on the session topic")
  assert(w:find('if topic == "session" then', 1, true) and w:find('require("websession").action(proj, cfg, b, a, reaper.StudioSync_WebUIPollHere ~= nil and reaper.StudioSync_WebUIPollHere() == 1)', 1, true),
    "webui dispatches it, saying whether this computer's page sent it")
  assert(w:find('require("websession").tick(proj, cfg, b, publish, last_who, now)', 1, true), "and ticks it while a page looks")
  local html = read("lib/webui/index.html")
  local at = function(s) return assert(html:find(s, 1, true), s) end
  assert(at('src="play.js"') < at('src="rooms.js"') and at('src="rooms.js"') < at('src="home.js"'), "rooms.js after play.js, before home.js")
  local shell = read("lib/webui/shell.js")
  assert(shell:find("(T.session || {}).viewonly", 1, true) and shell:find("'View only: ' + nameOf(", 1, true), "the strip says View only (decision 6)")
  local app = read("lib/webui/app.js")
  assert(not app:find("function presence(p)", 1, true) and not app:find("presence(t.presence)", 1, true), "app.js no longer draws Who's here")
  local play = read("lib/webui/play.js")
  for _, s in ipairs({ "function presence(p)", "function personMenu(x, btn)", "ssSession({ handover:", "ssSession({ give:", "ssSession({ admin:", "ssSession({ owner:",
      "ssSession({ remove:", "ssSession({ mode:", "ssSession({ take: true, anyway: true })", "ssSession({ claim: 'tracks' })", "ssSession({ release: 'all' })",
      "ssSession({ localmix: false, keep: 'theirs' })", "ssSession({ ideas: 'keep' })", "ssEnv.where !== 'remote'" }) do
    assert(play:find(s, 1, true), "play.js: " .. s)
  end
  local rooms = read("lib/webui/rooms.js")
  assert(rooms:find("ssTabs.sub('session', 'rooms'", 1, true) and rooms:find("ssTabs.act('session', { rooms: o })", 1, true), "rooms.js is Session > Rooms, on the session topic")
end
print("ok rt-ui6: Session (who can edit, claims, the person menu, local mixing, live ideas, View only) and Rooms")
