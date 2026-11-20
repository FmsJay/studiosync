-- The web UI's Health and Play together pages (docs/realtime-roadmap.md "Web UI: what remains"; the pages are lib/webui/health.js and
-- play.js, the server extension/webui.cpp, the tick lib/webui.lua). No panel rule is written again here: Health's rows are lib/page_health.lua's
-- own build, given what the panel would hand it; Play together sets the same project settings as the panel's Play/Jam page, starts through
-- together.start, and who may press Play, Record or Stop together is dawview.transport_refusal's rule (a page acts as this computer's user,
-- and a phone with the studio's token is one). Each topic is built only while a page shows it (it says so every 10 s, as the Song page does)
-- and published only when it changed. (James, rt)
local band = require("band")
local webpages = {}
webpages.WANT_FOR = 30    -- seconds a page counts as showing Health or Play together after it last said so
webpages.HEALTH_EVERY = 2 -- seconds between Health builds (page_health keeps the slow part, Syncthing and the shared files, 10 s)
webpages.PLAY_EVERY = 0.5 -- seconds between Play together builds (the count-down to a start shows)
webpages.MAX_BARS = 16    -- count-in, bars behind and bars later a page may ask for

local S = { want = {}, at = {} }
local function scripts_dir() return (debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\][^/\\]+$")) end

-- ---- what the pages show (pure) ---------------------------------------------------------------------------------------------------------
-- rows: page_health's ({ id, ok, colour, text when ok, text when not, link = { label, url }, copy = text }); gone: its dismissed set.
-- -> { ver, ext, worst, hidden, rows = { { id, ok, level, text, link, copy } } }: what needs you first, as the panel lists them; a yellow one
-- dismissed in the panel left out (counted in hidden); level "red", "yellow" or "grey" when not ok; worst as the panel's sidebar dot.
-- (A row's buttons stay on the panel: the page only shows. A link opens only when it's a web address.)
function webpages.health_model(rows, gone, ver, ext)
  local out, hidden, worst = {}, 0, nil
  for pass = 1, 2 do
    for _, r in ipairs(rows or {}) do
      local ok = type(r) == "table" and r[2] and true or false
      if type(r) == "table" and (pass == 1) == not ok then
        if not ok and r[3] == "yellow" and gone and gone[r[1]] then hidden = hidden + 1
        else
          local link = type(r.link) == "table" and type(r.link[2]) == "string" and r.link[2]:match("^https?://") and { label = tostring(r.link[1]), url = r.link[2] } or nil
          out[#out + 1] = { id = tostring(r[1]), ok = ok or nil, level = not ok and tostring(r[3]) or nil, text = tostring((ok and r[4] or r[5]) or ""),
            link = not ok and link or nil, copy = not ok and type(r.copy) == "string" and r.copy or nil }
          if not ok and r[3] == "red" then worst = "red" elseif not ok and r[3] == "yellow" and not worst then worst = "yellow" end
        end
      end
    end
  end
  return { ver = ver, ext = ext ~= "" and ext or nil, worst = worst, hidden = hidden, rows = out }
end
-- st: { side (ProjExtState "side": "" off, else bars behind), rt (Real time mode on), refusal (why this user may not start or stop, or nil),
-- cursor (the edit cursor's bar), regions = { { name, bar } }, due (seconds to a start, or nil), last (the last start or stop, in words),
-- ninjam, sonobus }. -> the Play together topic: from = start-from labels (1: the edit cursor, then each region), as the panel's.
function webpages.play_model(st)
  local from = { "the edit cursor (bar " .. tostring(st.cursor) .. ")" }
  for _, r in ipairs(st.regions or {}) do from[#from + 1] = tostring(r.name) .. " (bar " .. tostring(r.bar) .. ")" end
  local on = type(st.side) == "string" and st.side ~= ""
  return { follow = on, bars = on and tonumber(st.side) or nil, rt = st.rt and true or nil, may = not st.refusal, why = st.refusal, from = from,
    due = st.due and st.due > 0 and math.floor(st.due * 10 + 0.5) / 10 or nil, last = st.last ~= "" and st.last or nil,
    ninjam = st.ninjam and true or nil, sonobus = st.sonobus and true or nil }
end
-- A number of bars from a page: whole, 0..MAX_BARS; nil when it isn't one.
function webpages.bars(v)
  local n = tonumber(v)
  if not n or n ~= n then return nil end
  return math.max(0, math.min(webpages.MAX_BARS, math.floor(n)))
end

-- ---- reading REAPER --------------------------------------------------------------------------------------------------------------------
-- Health's rows: page_health's build (its 1 s and 10 s caches hold), given what the panel hands it. Live sync is another script, so this is
-- its own copy of the module, set up once with the tab in front's song asked for at each build.
local cur
local function health_rows(proj, cfg, b)
  local H = require("page_health")
  if not cur then
    cur = {}
    H.init({ b = function() return cur.b end, cfg = function() return cur.cfg end, proj = function() return cur.proj end,
      view = function() return cur.view end, wide = function() return false end, dir = scripts_dir(),
      ui = { play_shown = function() return reaper.GetExtState(band.SECTION, "show play") == "1" end } }) -- (the panel's ui.play_shown: its setting)
  end
  cur.b, cur.cfg, cur.proj, cur.view = b, cfg, proj, require("status").gather(cfg, b, proj)
  return H.maint_rows()
end
local function play_state(proj, cfg, b, who)
  local together, live = require("together"), require("live")
  local regions = {}
  for i, r in ipairs(together.regions(proj)) do regions[i] = { name = r.name, bar = together.bar_of(r.pos) } end
  local due = tonumber(reaper.GetExtState(band.SECTION, "together_at " .. tostring(proj)))
  return { side = select(2, reaper.GetProjExtState(proj, band.SECTION, "side")), rt = live.realtime_on(proj),
    refusal = require("dawview").transport_refusal(cfg, b, who), cursor = together.bar_of(reaper.GetCursorPositionEx(proj)), regions = regions,
    due = due and due - together.now() or nil, last = reaper.GetExtState(band.SECTION, "together " .. tostring(proj)),
    ninjam = live.fx(proj, false) ~= nil, sonobus = live.fx(proj, false, live.SONOBUS) ~= nil }
end

-- ---- what the pages send ---------------------------------------------------------------------------------------------------------------
-- a: { topic = "health", want } or { topic = "play", want, follow (on/off), bars (behind), go = "play" | "record" | "stop", from (0: the edit
-- cursor, n: the nth region), countin, click, lag (bars later for listeners: Time-sync) }. -> words for the log, or nil.
function webpages.action(proj, cfg, b, a)
  local now = reaper.time_precise()
  if a.want then S.want[a.topic], S.at[a.topic] = now + webpages.WANT_FOR, -math.huge end
  if a.topic ~= "play" then return end
  if a.follow ~= nil or a.bars ~= nil then
    -- (Real time mode is following at 0 bars: changed here, it would quietly switch Real time off. As the panel's, greyed out then)
    if require("live").realtime_on(proj) then return "the web page's Follow each other was left as it is: Real time mode is on (Home)" end
    local side = select(2, reaper.GetProjExtState(proj, band.SECTION, "side"))
    local on = a.follow == true or (a.follow == nil and side ~= "")
    reaper.SetProjExtState(proj, band.SECTION, "side", on and tostring(webpages.bars(a.bars) or tonumber(side) or 2) or "")
    S.at.play = -math.huge
  end
  if a.go == "play" or a.go == "record" or a.go == "stop" then
    local what = a.go == "record" and "Record" or a.go == "stop" and "Stop" or "Play"
    local why = require("dawview").transport_refusal(cfg, b)
    if why then return "the web page's " .. what .. " together was refused: " .. why .. " in this room" end
    local together = require("together")
    S.at.play = -math.huge
    if a.go == "stop" then together.go(proj, cfg, b, { type = "stop" }); return "Stop together, from the web page" end
    local rg = together.regions(proj)
    local k = math.floor(tonumber(a.from) or 0)
    together.start(proj, cfg, b, rg[k] and rg[k].pos or reaper.GetCursorPositionEx(proj), a.go == "record", webpages.bars(a.countin) or 1,
      a.click ~= false, webpages.bars(a.lag) or 0)
    return what .. " together, from the web page"
  end
end

-- Each tick in front, while a page looks (lib/webui.lua). publish(topic, table) sends only what changed; who: sync.authority's second answer
-- from webui's presence build.
function webpages.tick(proj, cfg, b, publish, who, now)
  if (S.want.health or -math.huge) > now and now - (S.at.health or -math.huge) >= webpages.HEALTH_EVERY then
    S.at.health = now
    local ok, rows = pcall(health_rows, proj, cfg, b)
    publish("health", ok and webpages.health_model(rows, require("page_health").dismissed_set(), band.VERSION, reaper.GetExtState(band.SECTION, "menu extension"))
      or { ver = band.VERSION, error = tostring(rows) })
  end
  if (S.want.play or -math.huge) > now and now - (S.at.play or -math.huge) >= webpages.PLAY_EVERY then
    S.at.play = now
    publish("play", webpages.play_model(play_state(proj, cfg, b, who)))
  end
end

return webpages
