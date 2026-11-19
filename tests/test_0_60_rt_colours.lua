-- rt (James, 2026-11-19: "everyone should share the same colors for tracks and everything"): Colour parity. The studio switch (on unless
-- band.json says false); the colour preferences and the theme's colour settings in force only with it on, the theme's only on the same theme;
-- no who's-working paint with it on; each person's default colour kept in the studio and never moved by a name only one computer knows; a
-- marker reset to the default colour reaching everyone; ruler lane and master colours in the travelling byte order; Health's comparison.
package.path = "lib/?.lua;" .. package.path
for _, m in ipairs({ "band", "groups", "mirror", "sharedprefs", "sync", "trust", "people", "colours" }) do package.loaded[m] = nil end
local gext, clock = {}, 1000
local gcfg = {} -- global prefs: name -> { kind, value }
local stub = {
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  time_precise = function() return clock end,
  GetOS = function() return "OSX64" end,
  SNM_GetIntConfigVar = function(k, err) local c = gcfg[k]; return c and c[1] == "i" and c[2] or err end,
  SNM_GetDoubleConfigVar = function(k, err) local c = gcfg[k]; return c and c[1] == "d" and c[2] or err end,
  SNM_SetIntConfigVar = function(k, v) local c = gcfg[k]; if c and c[1] == "i" then c[2] = v; return true end return false end,
  SNM_SetDoubleConfigVar = function(k, v) local c = gcfg[k]; if c and c[1] == "d" then c[2] = v; return true end return false end,
  -- a Mac's native colour is 0xRRGGBB: the travelling one (Windows') is 0xBBGGRR
  ColorToNative = function(r, g, b) return (r << 16) | (g << 8) | b end,
  ColorFromNative = function(c) return (c >> 16) & 255, (c >> 8) & 255, c & 255 end,
}
reaper = setmetatable(stub, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
package.loaded.trust = { pins = function() return nil end, from_manager_file = function() return nil end, inviter = function() return nil end,
  roles = function() return nil, {} end, held = function() return false end, pin = function() end, managers = function() return nil end,
  roles_of = function() return {} end }
local files = {}
band.read_json = function(path) return files[path] end
band.info = function(root) return { name = root, id = "id-" .. root } end

-- ---- 1. the studio switch ------------------------------------------------------------------------------------------------------------
local groups = require("groups")
files["R/_band/band.json"] = { colour_parity = false, theme_colours = { theme = "T", params = { tcp_tint_strength = 50 } } }
files["S/_band/band.json"] = {}
assert(groups.colour_parity("S") == true, "on by default")
assert(groups.colour_parity("R") == false, "off when band.json says false")
assert(groups.trusted("R").theme_colours.params.tcp_tint_strength == 50, "the theme's colour settings come through the trusted settings")
local wrote
band.write_json = function(path, j) if path:find("band.json", 1, true) then wrote = j end end
groups.set_colour_parity("S", false)
assert(wrote and wrote.colour_parity == false, "only off is written")
groups.set_colour_parity("S", true)
assert(wrote and wrote.colour_parity == nil, "on again: the key goes")
groups.set_theme_colours("S", { theme = "J:/Themes/Reapertips Theme.ReaperThemeZip", params = { tcp_tint_strength = 70, tcpBgColR = 9, ["bad name"] = 1, tint_label = "x" } })
assert(wrote.theme_colours.theme == "reapertips theme" and wrote.theme_colours.params.tcp_tint_strength == 70 and wrote.theme_colours.params.tcpBgColR == nil
  and wrote.theme_colours.params["bad name"] == nil and wrote.theme_colours.params.tint_label == nil, "only whole-number colour settings, by theme name")

-- ---- 2. the colour preferences and the theme's colour settings -----------------------------------------------------------------------
local sp = require("sharedprefs")
assert(sp.theme_name("C:\\REAPER\\ColorThemes\\Default_7.0.ReaperTheme") == "default_7.0" and sp.theme_name("/x/Default_7.0.ReaperThemeZip") == "default_7.0",
  "a theme is its file's name, zipped or not")
assert(sp.theme_colour_param("tcp_tint_strength", "TCP: Tint panel") and sp.theme_colour_param("colorTrackLabels", "Custom Color Track Labels")
  and sp.theme_colour_param("colored_track_name", "") and not sp.theme_colour_param("tcpBgColR", "TCP background colour")
  and not sp.theme_colour_param("tcp_send_section_width", "Sends width"), "tints and coloured names, not the panels' own colours")
local colourkeys = {}
for _, x in ipairs(sp.PREFS) do
  assert(not sp.never(x[1]), "a key on the list isn't a never-shared one: " .. x[1])
  if x.group == "colour" then colourkeys[#colourkeys + 1] = x[1]; assert(x.differs, "Health has words for " .. x[1]) end
end
assert(#colourkeys >= 3, "the colour group is on the list")
local studios = {}
groups.trusted = function(root) return studios[root] or {} end
local theme_path, tparams, set_calls = "/t/Reapertips Theme.ReaperThemeZip", { { "tcp_tint_strength", "TCP: Tint panel", 100 }, { "tcpBgColR", "TCP background colour", 129 } }, {}
stub.GetLastColorThemeFile = function() return theme_path end
stub.ThemeLayout_GetParameter = function(i) local p = tparams[i + 1]; if p then return p[1], p[2], p[3] end end
stub.ThemeLayout_SetParameter = function(i, v, persist) set_calls[#set_calls + 1] = { i, v, persist }; tparams[i + 1][3] = v; return true end
gcfg = { deffadelen = { "d", 0.01 }, tinttcp = { "i", 298 }, selitem_tintalpha = { "i", 2 } }
studios.A = { shared_prefs = { deffadelen = 0.05, tinttcp = 299, selitem_tintalpha = 4 }, theme_colours = { theme = "reapertips theme", params = { tcp_tint_strength = 40, tint_label = 1 } } }
studios.B = { colour_parity = false, shared_prefs = { deffadelen = 0.05, tinttcp = 299 }, theme_colours = studios.A.theme_colours }
local w = sp.studio("A")
assert(w.deffadelen == 0.05 and w.tinttcp == 299 and w.selitem_tintalpha == 4 and w["theme:tcp_tint_strength"] == 40, "parity on: colour prefs and the theme's in force")
assert(w["theme:tint_label"] == nil, "a theme setting this theme doesn't have is left out")
w = sp.studio("B")
assert(w.deffadelen == 0.05 and w.tinttcp == nil and w["theme:tcp_tint_strength"] == nil, "parity off: only the recording and editing ones")
assert(sp.chosen("B").tinttcp == 299, "but what the owner chose stays (the settings page shows and saves it)")
sp.tick("A", true)
assert(gcfg.tinttcp[2] == 299 and gcfg.selitem_tintalpha[2] == 4 and tparams[1][3] == 40, "the studio's colours are in")
assert(set_calls[1][3] == false, "theme settings are set without persisting: reaper-themeconfig.ini keeps the person's own")
assert(sp.mine("tinttcp") == 298 and sp.mine("theme:tcp_tint_strength") == 100, "this computer's own saved")
assert(reaper.GetExtState(band.SECTION, sp.HELD):find(";theme:tcp_tint_strength;", 1, true), "held list names the theme setting too")
sp.tick(nil, true)
assert(gcfg.tinttcp[2] == 298 and gcfg.selitem_tintalpha[2] == 2 and tparams[1][3] == 100, "no studio song in front: all put back")
theme_path = "/t/Default_7.0.ReaperThemeZip"
clock = clock + 10 -- (the theme's parameters are looked up again)
sp.tick("A", true)
assert(gcfg.tinttcp[2] == 299 and tparams[1][3] == 100, "another theme: the studio's colour prefs, never its theme settings")
sp.tick(nil, true)
theme_path = "/t/Reapertips Theme.ReaperThemeZip"
clock = clock + 10

-- ---- 3. each person's colour: chosen once, kept in the studio ------------------------------------------------------------------------
local people = require("people")
local P = people.PALETTE
local a = people.assign({}, { "Bee", "Dan" }, { "Carl" })
local b = people.assign({}, { "Bee", "Dan" }, {})
assert(a.Bee == b.Bee and a.Dan == b.Dan and a.Bee == P[1] and a.Dan == P[2] and a.Carl == P[3], "a name only one computer knows never moves a member's colour")
assert(people.assign({}, { "Mac", "James", "Laptop" }).James == P[1], "two arguments as before")
local listing = { ["S/_band/colours"] = {}, ["S/plugins"] = { "Bee.json", "Dan.json" } }
files["S/plugins/Bee.json"], files["S/plugins/Dan.json"] = { user = "Bee" }, { user = "Dan" }
band.files = function(dir) return listing[dir] or {} end
band.bands = function() return { { root = "S" } } end
band.write_json = function(path, j)
  files[path] = j
  local dir, f = path:match("^(.*)/([^/]+)$")
  listing[dir] = listing[dir] or {}
  local there = false
  for _, x in ipairs(listing[dir]) do there = there or x == f end
  if not there then listing[dir][#listing[dir] + 1] = f end
end
gext[band.SECTION .. "\0user"] = "Dan"
local c = people.mine({ root = "S", user = "Dan" })
assert(c == P[2] and files["S/_band/colours/Dan.json"] and files["S/_band/colours/Dan.json"].auto == true and files["S/_band/colours/Dan.json"].colour == P[2],
  "no pick: today's default is written to Dan's own file, once")
listing["S/plugins"][#listing["S/plugins"] + 1] = "Cy.json"; files["S/plugins/Cy.json"] = { user = "Cy" } -- (Cy joins: in name order before Dan)
clock = clock + 20
assert(people.colours("S", {}).Dan == P[2], "someone joining later doesn't move Dan's kept colour")
assert(people.colours("S", {}).Cy ~= P[2], "and doesn't take it")
assert(people.newest_pick({ "S" }, "Dan") == nil, "a kept default isn't a pick: it doesn't travel to Dan's other studios")
people.pick({ root = "S", user = "Dan" }, 0x123456)
clock = clock + 20
assert(people.colours("S", {}).Dan == 0x123456 and not files["S/_band/colours/Dan.json"].auto, "Dan can change it any time")

-- ---- 4. no who's-working paint with parity on ----------------------------------------------------------------------------------------
local tracks = { { ext = { band_colour = tostring(0x1000000 | 0x112233) }, colour = 0x1000000 | 0xFF0000 }, { ext = {}, colour = 0x1000000 | 0x00FF00 } }
stub.CountTracks = function() return #tracks end
stub.GetTrack = function(_, i) return tracks[i + 1] end
stub.GetSetMediaTrackInfo_String = function(tr, k, v, set)
  local key = k:gsub("^P_EXT:", "")
  if set then tr.ext[key] = v end
  return true, tr.ext[key] or ""
end
stub.GetMediaTrackInfo_Value = function(tr, k) if k == "I_CUSTOMCOLOR" then return tr.colour end return 0 end
stub.SetMediaTrackInfo_Value = function(tr, k, v) if k == "I_CUSTOMCOLOR" then tr.colour = v end end
studios.S = {}
gext[band.SECTION .. "\0new held S1/main"] = "3"
local wrote = people.paint("proj", { root = "S", user = "Dan" }, { { user = "Bee", editing = { "T-1" } } }, {}, "S1/main")
assert(tracks[1].colour == 0x1000000 | 0x112233 and tracks[1].ext.band_colour == "", "a who's-working colour left from before goes back to the band's")
assert(tracks[2].colour == 0x1000000 | 0x00FF00, "the others keep theirs")
assert(people.held("S1/main") == 0, "nothing held for 'Since you were last here'")
-- (and says it wrote, once: Live sync redraws only after a pass that changed something. James, rt)
assert(wrote == true and people.paint("proj", { root = "S", user = "Dan" }, {}, {}, "S1/main") == false, "paint says when it changed a colour")

-- ---- 5. markers put back to the default colour, ruler lanes and the master in one byte order --------------------------------------
local marks = { { rgn = false, pos = 1, rend = 1, name = "Verse", num = 1, color = 0x1000000 | 0xFF0000 } }
stub.CountProjectMarkers = function() return #marks end
stub.EnumProjectMarkers3 = function(_, i) local m = marks[i + 1]; if not m then return 0 end return 1, m.rgn, m.pos, m.rend, m.name, m.num, m.color end
stub.SetProjectMarker4 = function(_, num, rgn, pos, rend, name, color) for _, m in ipairs(marks) do if m.num == num and color ~= 0 then m.color = color end end end
stub.GetNumRegionsOrMarkers = function() return #marks end
stub.GetRegionOrMarker = function(_, i) return marks[i + 1] end
stub.SetRegionOrMarkerInfo_Value = function(_, m, k, v) if k == "I_CUSTOMCOLOR" then m.color = v end end
band.apply_markers("proj", { { region = false, pos = 1, ["end"] = 1, name = "Verse", color = 0 } })
assert(marks[1].color == 0, "a marker put back to the default colour reaches everyone (SetProjectMarker4's 0 means 'leave it')")
local master = { ext = {}, colour = 0x1000000 | 0x0000FF } -- (a Mac's blue)
stub.GetMasterTrack = function() return master end
stub.GetSetProjectInfo_String = function() return false, "" end
stub.GetSetProjectInfo = function() return 0 end
local s = band.capture_settings("proj")
assert(s.master_colour == (0x1000000 | 0xFF0000), "the master's colour travels in Windows' order (blue is 0xFF0000 there)")
master.colour = 0
band.apply_settings("proj", s)
assert(master.colour == 0x1000000 | 0x0000FF, "and lands as this computer's native blue")
local lanes = { COLOR = 0x1000000 | 0x0000FF }
stub.GetSetProjectInfo = function(_, k, v, set)
  if k == "RULER_LANE_COUNT" then return 1 end
  local key = k:match("^RULER_LANE_(%u+):0$")
  if key == "COLOR" then if set then lanes.COLOR = v end return lanes.COLOR end
  return 0
end
stub.SNM_GetIntConfigVarEx = function(_, _, e) return e end
stub.SNM_GetDoubleConfigVarEx = function(_, _, e) return e end
local p = band.capture_project("proj")
assert(p.lanes[1].COLOR == (0x1000000 | 0xFF0000), "a ruler lane's colour travels in Windows' order")
lanes.COLOR = 0
band.apply_project("proj", { lanes = p.lanes })
assert(lanes.COLOR == 0x1000000 | 0x0000FF, "and lands native")

-- ---- 6. Health's comparison --------------------------------------------------------------------------------------------------------
local colours = require("colours")
assert(colours.fingerprint({ "T a 1", "I b 2" }) == colours.fingerprint({ "I b 2", "T a 1" }), "the same colours in another order are the same")
assert(colours.fingerprint({ "T a 1" }) ~= colours.fingerprint({ "T a 2" }), "another colour isn't")
local mine = { fp = 1, theme = "reapertips theme", prefs = { tinttcp = 298, specpeak_huel = 1.5, specpeak_hueh = 0.5 }, tparams = { tcp_tint_strength = 100 } }
assert(#colours.parity_problems(mine, { { user = "Mac", look = mine }, { user = "Dan", look = { fp = 9 } } }, "Dan") == 0, "all alike (and yourself never counts)")
local probs = colours.parity_problems(mine, { { user = "Mac", look = { fp = 2, theme = "reapertips theme", prefs = { tinttcp = 299, specpeak_huel = 1, specpeak_hueh = 1 },
  tparams = { tcp_tint_strength = 50 } } }, { user = "Old" } }, "Dan")
local text = {}
for _, x in ipairs(probs) do text[#text + 1] = x[1] end
text = table.concat(text, " | ")
assert(text:find("Mac's project colours differ", 1, true) and probs[1].fp and probs[1].user == "Mac", "the project's colours, marked for the grace period")
assert(text:find("Mac tints track panels and items differently", 1, true), "a colour preference, named: " .. text)
assert(select(2, text:gsub("spectral peaks", "")) == 1, "two keys with the same words said once")
assert(text:find("theme's colour settings differently", 1, true), "the theme's settings, on the same theme")
assert(not text:find("Old", 1, true), "an older version with no look says nothing")
probs = colours.parity_problems({ fp = 1, theme = "a", overlay = true }, { { user = "Mac", look = { fp = 1, theme = "b" } } }, "Dan")
assert(#probs == 2 and probs[1][1]:find("tracks here show", 1, true) and probs[2][1]:find("Mac uses another theme (b)", 1, true), "an overlay here; another theme there")
print("ok")
