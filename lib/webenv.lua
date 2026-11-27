-- The web UI's "env" topic: what this computer's REAPER has open and is doing, so a page shows only what makes sense where it runs
-- (docs/rt/ui-web-plan.md 3.2-3.3; James, findings 2026-11-27 item 1: "it already knows if you have reaper and if you do what your reaper is
-- doing/has open"). Built by Live sync's tab in front (lib/webui.lua's tick), at most once a second and published only when it changed; while
-- its tab is loading (lib/loadguard.lua holds it) Live sync publishes it with front.loading set, so the page greys its actions (item 14).
-- Also the "nav" topic: a REAPER action (or a page on this computer: Open in REAPER) asks the docked view to show a tab. (rt-ui1)
local band = require("band")
local webenv = { EVERY = 1, STUDIOS_EVERY = 10, TABS_MAX = 32, NAME_MAX = 200, NAV_FRESH = 5 }
-- (the nine tabs: lib/webui/tabs.js has the same names; a nav naming another is dropped)
webenv.PAGES = { studio = true, session = true, project = true, chat = true, history = true, plugins = true, ai = true, health = true, settings = true }

local function str(s, max)
  if type(s) ~= "string" or s == "" then return nil end
  return #s > (max or webenv.NAME_MAX) and s:sub(1, max or webenv.NAME_MAX) or s
end
local function flag(v) return v and true or nil end

-- raw: what build gathered (or a test's table). -> the env topic: only known fields, strings capped, flags true or left out. Pure.
function webenv.model(raw)
  raw = type(raw) == "table" and raw or {}
  local out = { v = 1, ver = str(raw.ver, 40), ext = str(raw.ext, 40), computer = str(raw.computer, 64), user = str(raw.user, 64),
    person = str(raw.person, 64), studio = str(raw.studio), ai = flag(raw.ai), health = (raw.health == "red" or raw.health == "yellow") and raw.health or nil }
  local f = type(raw.front) == "table" and raw.front or nil
  if f then
    out.front = { name = str(f.name), studio = str(f.studio), project = str(f.project), room = str(f.room, 64), shared = flag(f.shared),
      loading = flag(f.loading), live = flag(f.live), tracks = tonumber(f.tracks) and math.floor(f.tracks) or nil }
  end
  out.tabs = {}
  for _, t in ipairs(type(raw.tabs) == "table" and raw.tabs or {}) do
    if #out.tabs >= webenv.TABS_MAX then break end
    if type(t) == "table" then out.tabs[#out.tabs + 1] = { name = str(t.name) or "(unsaved)", live = flag(t.live), front = flag(t.front) } end
  end
  local tr = type(raw.transport) == "table" and raw.transport or nil
  if tr then
    out.transport = { playing = flag(tr.playing), recording = flag(tr.recording), paused = flag(tr.paused),
      pos = tonumber(tr.pos) and math.floor(tr.pos * 10 + 0.5) / 10 or nil }
  end
  out.studios = {}
  for _, s in ipairs(type(raw.studios) == "table" and raw.studios or {}) do
    if type(s) == "table" and str(s.name) then out.studios[#out.studios + 1] = { name = str(s.name), role = str(s.role, 16) } end
  end
  return out
end

-- ---- gathering it (REAPER) ------------------------------------------------------------------------------------------------------------
local S = { at = -math.huge, studios = nil, studios_at = -math.huge }
local function studios(now, user)
  if S.studios and now - S.studios_at < webenv.STUDIOS_EVERY then return S.studios end
  local list, groups = {}, require("groups")
  local ok, bands = pcall(band.bands)
  for _, g in ipairs(ok and bands or {}) do
    local okr, role = pcall(groups.role, g.root, user)
    list[#list + 1] = { name = g.name, role = okr and role or nil }
  end
  S.studios, S.studios_at = list, now
  return list
end
-- opts: { loading = true } while Live sync's loadguard holds the tab; health: the last Health topic's worst (lib/webpages.lua) or nil.
function webenv.build(proj, cfg, b, opts, health)
  opts = opts or {}
  local now = reaper.time_precise()
  local tabs, i = {}, 0
  while i < webenv.TABS_MAX do
    local p = reaper.EnumProjects(i)
    if not p then break end
    tabs[#tabs + 1] = { name = reaper.GetProjectName(p), live = band.live_here(p), front = p == proj or nil }
    i = i + 1
  end
  local ps = reaper.GetPlayStateEx(proj)
  local playing = ps & 1 == 1 or ps & 4 == 4
  local studio = band.info(cfg.root).name
  local okp, person = pcall(require("persons").of, cfg.root, cfg.user)
  local loading = opts.loading or require("loadguard").busy()
  return webenv.model({ ver = band.VERSION, ext = reaper.GetExtState(band.SECTION, "menu extension"), computer = cfg.user, user = cfg.user,
    person = okp and person or nil, studio = studio, ai = select(2, pcall(require("groups").ai, cfg.root)) == true,
    -- (a sync problem lights REAPER's toolbar button amber: red here too, Health or not)
    health = reaper.GetExtState(band.SECTION, "sync problem") ~= "" and "red" or health,
    front = { name = reaper.GetProjectName(proj), studio = studio, project = b.song, room = b.room, shared = true, loading = loading, live = true,
      tracks = reaper.CountTracks(proj) },
    tabs = tabs,
    transport = { playing = ps & 1 == 1, recording = ps & 4 == 4, paused = ps & 2 == 2,
      pos = playing and reaper.GetPlayPositionEx(proj) or reaper.GetCursorPositionEx(proj) },
    studios = studios(now, cfg.user) })
end
-- At most once a second, loading or not; publish(topic, t) sends only what changed.
function webenv.tick(proj, cfg, b, publish, now, opts, health)
  if now - S.at < webenv.EVERY then return end
  S.at = now
  publish("env", webenv.build(proj, cfg, b, opts, health))
end

-- ---- nav: "show this tab" ------------------------------------------------------------------------------------------------------------
-- -> "page" or "page/sub", or nil when page isn't one of the nine or sub isn't a plain short word. Pure.
function webenv.route(page, sub)
  if type(page) ~= "string" or not webenv.PAGES[page] then return nil end
  if sub == nil or sub == "" then return page end
  if type(sub) ~= "string" or not sub:match("^%a+$") or #sub > 16 then return nil end
  return page .. "/" .. sub
end
-- A REAPER action asks the web view to show a page (wake: and bring it back from the strip or button, Phase 8). -> true when asked.
function webenv.nav_request(page, sub, wake)
  if not webenv.route(page, sub) then return false end
  local t = { page = page, sub = sub ~= "" and sub or nil, at = os.time(), id = string.format("%x%04x", os.time(), math.random(0, 0xffff)), wake = flag(wake) }
  reaper.SetExtState(band.SECTION, "web nav", band.json_encode(t), false)
  return true
end
-- s: the "web nav" ExtState. -> the nav topic, or nil when there's none or it isn't one. Pure.
function webenv.nav_model(s)
  local t = type(s) == "string" and s ~= "" and band.json_decode(s)
  if type(t) ~= "table" or not webenv.route(t.page, t.sub) or not tonumber(t.at) or type(t.id) ~= "string" or #t.id > 32 then return nil end
  return { page = t.page, sub = t.sub, at = math.floor(t.at), id = t.id, wake = flag(t.wake) }
end
function webenv.nav_topic() return webenv.nav_model(reaper.GetExtState(band.SECTION, "web nav")) end
-- A page's { topic = "nav", to = "reaper" | "browser", page, sub }: Open in REAPER (the docked view, at that page) from this computer's
-- browser, or Open in the browser from the docked view. here: a page on this computer sent it (StudioSync_WebUIPollHere); a page on another
-- device never opens a window here. url: this computer's own address (webui.local_url). -> what to log, or nil.
function webenv.nav_action(a, here, url)
  local r = webenv.route(a.page, a.sub)
  if not r then return nil end
  if not here then return "a page on another device asked to open StudioSync on this computer: left alone" end
  if a.to == "reaper" then
    webenv.nav_request(a.page, a.sub, true)
    if reaper.StudioSync_WebUIDock then reaper.StudioSync_WebUIDock(1) end
  elseif a.to == "browser" then
    band.open_url(url .. "#" .. r)
  end
  return nil
end

return webenv
