-- rt-setup (findings 2026-11-27, "switching studio without a project open"): the panel's Studios and Projects pages drawn in an empty REAPER
-- (one untitled tab, nothing shared), on a stand-in ImGui that clicks a button by its label. Open on another studio's card switches to it and
-- shows its projects; the Projects page with no project open always has a way back to Your studios (the studio pill at the top is hidden when the
-- studio you were in was left or closed, and the page had no other way back); a studio that's gone says so there.
package.path = "lib/?.lua;" .. package.path
local ext, FS, clock = {}, {}, 1000
local PROJ = { "empty tab" }
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  file_exists = function(p) return FS[p] ~= nil end,
  RecursiveCreateDirectory = function() return 1 end,
  EnumProjects = function(i) if i == -1 or i == 0 then return PROJ, "" end end,
  GetProjectName = function() return "" end,
  GetProjExtState = function() return 0, "" end,
  CountTracks = function() return 0 end,
  EnumerateFiles = function() return nil end,
  EnumerateSubdirectories = function() return nil end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function() end
band.read = function(p) return FS[p] end
band.read_json = function(p) local s = FS[p]; local v = s and band.json_decode(s); return type(v) == "table" and v or nil end
band.files = function() return {} end
band.subdirs = function() return {} end
band.songs = function() return {} end
local A, B = "/s/StudioSync Smiley", "/s/StudioSync Chilio"
local bands = { { root = A, id = "studiosync-smiley", name = "Smiley" }, { root = B, id = "studiosync-chilio", name = "Chilio" } }
band.bands = function() return bands end
band.info = function(root) for _, x in ipairs(bands) do if x.root == root then return { id = x.id, name = x.name } end end return { id = "", name = "?" } end
band.binding = function() return nil end -- (nothing in the empty tab is shared)
ext["BandSync/user"], ext["BandSync/sync_root"] = "James", A
FS[A .. "/_band/band.json"], FS[B .. "/_band/band.json"] = "{}", "{}"
local old = {}
package.loaded.groups = { role = function() return "member" end, is_old = function(r) return old[r] == true end, closed_ok = function() return false end,
  old = function() return {} end, may_manage = function() return false end, QUIET_DAYS = 30 }
package.loaded.chooser = { songs = function() return {} end, match = function() return true end }
package.loaded.theme = { GREEN = 1, YELLOW = 2, RED = 3, TEXT = 4, MUTED = 5, ACCENT = 6 }
package.loaded.services = { syncthing_peers_now = function() return 1, 1 end, days_quiet = function() return nil end, my_device_id = function() return "X" end }
package.loaded.songsync = { keep_all = function() return false end, is_here = function() return false end, apply = function() end }
package.loaded.extras = { templates = function() return {} end, stage = function() return nil end }
package.loaded.localcopy = { read_holds = function() return {} end }
package.loaded.joins = { state = function() return nil end }
package.loaded.tools = { INVITE_TIP = "", guest_invite_button = function() end, invite = function() end }
package.loaded.live = { PLACES = { health = "Health" } }
-- ImGui: every widget there, nothing clicked except a button whose label (before ##) is `click`; labels drawn are noted.
local click, seen = nil, {}
local function label(s) return (tostring(s or ""):gsub("##.*$", "")) end
local function pressed(s) seen[#seen + 1] = label(s); return label(s) == click end
local ImGui = setmetatable({
  SmallButton = function(_, s) return pressed(s) end, Button = function(_, s) return pressed(s) end,
  Checkbox = function(_, s, v) seen[#seen + 1] = label(s); return false, v end,
  InputTextWithHint = function(_, _, _, v) return false, v end, BeginCombo = function() return false end, BeginPopup = function() return false end,
  BeginPopupContextItem = function() return false end, BeginDragDropTarget = function() return false end, BeginDragDropSource = function() return false end,
  TreeNodeEx = function() return false end, Selectable = function() return false end, IsPopupOpen = function() return false end,
  GetContentRegionAvail = function() return 800, 600 end, CalcTextSize = function(_, s) return #tostring(s) * 7, 14 end,
  GetCursorScreenPos = function() return 0, 0 end, GetCursorPosY = function() return 0 end, GetTextLineHeightWithSpacing = function() return 18 end,
  IsMouseDoubleClicked = function() return false end, IsMouseReleased = function() return false end, IsItemHovered = function() return false end,
  TextDisabled = function(_, s) seen[#seen + 1] = tostring(s) end, TextColored = function(_, _, s) seen[#seen + 1] = tostring(s) end,
  Text = function(_, s) seen[#seen + 1] = tostring(s) end, TextWrapped = function(_, s) seen[#seen + 1] = tostring(s) end,
  PopupFlags_AnyPopup = 0, InputTextFlags_EnterReturnsTrue = 0, TreeNodeFlags_SpanAvailWidth = 0, SelectableFlags_AllowDoubleClick = 0,
}, { __index = function() return function() end end })
local page = "Groups"
local env = { ctx = {}, ImGui = ImGui, card = function() return true end, card_end = function() end, heading = function(t) seen[#seen + 1] = t end,
  action = function() end, go = function(p) page = p end, project = function() return nil end, wide = function() return false end,
  cfg = function() return band.settings() end, reload_cfg = function() end }
local pg = require("page_groups")
local function draw(fn, c) click, seen = c, {}; fn(env); return table.concat(seen, "\n") end

-- Your studios in an empty REAPER: both cards, and Open on the other one switches to it and shows its projects
local text = draw(pg.draw_groups)
assert(text:find("Smiley", 1, true) and text:find("Chilio", 1, true), "both studios listed with no project open")
-- (each card has its own Open: the stand-in clicks every one labelled Open, so the last card's wins, as a click on Chilio's would)
draw(pg.draw_groups, "Open")
assert(ext["BandSync/sync_root"] == B and pg.root == B and page == "Projects", "Open on Chilio's card switches to it, with no project open")
-- The Projects page with no project open: a way back to every studio, whatever the pill at the top does
page = "Projects"
text = draw(pg.draw_projects)
assert(text:find("Projects in Chilio", 1, true), "Chilio's projects shown")
draw(pg.draw_projects, "Your studios")
assert(page == "Groups" and pg.root == nil, "Your studios goes back to the list, with no project open")
-- The studio you were working in was left (the pill at the top is hidden for it): the page says so, and the way back is there
old[B], pg.root = true, nil
text = draw(pg.draw_projects)
assert(text:find("You've left Chilio", 1, true) and text:find("Your studios", 1, true), "a left studio says so, with the way back")
print("ok")
