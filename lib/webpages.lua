-- The web UI's Health and Play together pages (docs/realtime-roadmap.md "Web UI: what remains"; the pages are lib/webui/health.js and
-- play.js, the server extension/webui.cpp, the tick lib/webui.lua). No panel rule is written again here: Health's rows are lib/page_health.lua's
-- own build, given what the panel would hand it; Play together sets the same project settings as the panel's Play/Jam page, starts through
-- together.start, and who may press Play, Record or Stop together is dawview.transport_refusal's rule (a page acts as this computer's user,
-- and a phone with the studio's token is one). Each topic is built only while a page shows it (it says so every 10 s, as the Song page does)
-- and published only when it changed. (James, rt)
-- rt-ui4 (docs/rt/ui-web-plan.md Phase 4, 2.8): Health's rows carry hidden (the panel's dismissed) and other (lib/compat.lua's: other scripts)
-- for the page's Show hidden and "Show messages about other scripts"; a row's button runs here through page_health.web_act (a phone only the
-- safe ones); Hide / Show again, Send feedback (lib/feedback.lua's save), and the Log (lib/weblog.lua) come on the health topic too. Health is
-- also built every HEALTH_IDLE s while any page looks, so the env topic's Health dot is there without the Health page open.
local band = require("band")
local webpages = {}
webpages.WANT_FOR = 30    -- seconds a page counts as showing Health or Play together after it last said so
webpages.HEALTH_EVERY = 2 -- seconds between Health builds (page_health keeps the slow part, Syncthing and the shared files, 10 s)
webpages.HEALTH_IDLE = 10 -- seconds between Health builds while a page looks but none shows Health (the env topic's dot)
webpages.HIDE_MAX = 200   -- rows hidden at most (the panel's "dismissed" ExtState)
webpages.SUBJECT_MAX, webpages.BODY_MAX = 200, 8000 -- a page's feedback: characters of subject and body
webpages.PLAY_EVERY = 0.5 -- seconds between Play together builds (the count-down to a start shows)
webpages.MAX_BARS = 16    -- count-in, bars behind and bars later a page may ask for

local S = { want = {}, at = {} }
local function scripts_dir() return (debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\][^/\\]+$")) end

-- ---- what the pages show (pure) ---------------------------------------------------------------------------------------------------------
-- Whether the page shows a row of the health topic: a hidden one only with Show hidden; another script's (other) only with "Show messages
-- about other scripts" on, or when it's red (always shown). Pure: health.js has the same rule.
function webpages.health_shows(r, show_hidden, show_other)
  if r.hidden then return show_hidden == true end
  if r.other and not show_other and r.level ~= "red" then return false end
  return true
end
-- rows: page_health's ({ id, ok, colour, text when ok, text when not, link = { label, url }, copy = text, action, ok_action, other }); gone: its
-- dismissed set. o: { other_off (the switch is off), button (row -> its button's label: page_health.web_button), remote (ids a phone may
-- press: page_health.WEB_REMOTE), builtin (the studio's own live audio runs here: Can't hear? leaves SonoBus out), said (the last action's
-- words), said_n (counts them: the same words twice still show) }.
-- -> { ver, ext, worst, hidden, other, show_other, builtin, said, rows = { { id, ok, level, text, link, copy, act, here, hidden, other } } }:
-- what needs you first, as the panel lists them; level "red", "yellow" or "grey" when not ok; a yellow one dismissed is hidden (counted in
-- hidden); act: its button, here: only this computer's page may press it; other: counted when the switch hides it; worst as the panel's
-- sidebar dot, without what the page hides. A link opens only when it's a web address.
function webpages.health_model(rows, gone, ver, ext, o)
  o = o or {}
  local out, hidden, other, worst = {}, 0, 0, nil
  for pass = 1, 2 do
    for _, r in ipairs(rows or {}) do
      local ok = type(r) == "table" and r[2] and true or false
      if type(r) == "table" and (pass == 1) == not ok then
        local link = type(r.link) == "table" and type(r.link[2]) == "string" and r.link[2]:match("^https?://") and { label = tostring(r.link[1]), url = r.link[2] } or nil
        local act = o.button and o.button(r) or nil
        local row = { id = tostring(r[1]), ok = ok or nil, level = not ok and tostring(r[3]) or nil, text = tostring((ok and r[4] or r[5]) or ""),
          link = not ok and link or nil, copy = not ok and type(r.copy) == "string" and r.copy or nil, act = act and tostring(act) or nil,
          hidden = not ok and r[3] == "yellow" and gone and gone[r[1]] and true or nil, other = r.other and true or nil }
        row.here = row.act and not (o.remote and o.remote[row.id]) or nil
        out[#out + 1] = row
        if row.hidden then hidden = hidden + 1
        elseif not webpages.health_shows(row, false, not o.other_off) then other = other + 1
        elseif not ok and r[3] == "red" then worst = "red" elseif not ok and r[3] == "yellow" and not worst then worst = "yellow" end
      end
    end
  end
  return { ver = ver, ext = ext ~= "" and ext or nil, worst = worst, hidden = hidden, other = other, show_other = not o.other_off,
    builtin = o.builtin and true or nil, said = o.said, said_n = o.said_n, rows = out }
end
-- The panel's dismissed list with id hidden (on) or shown again (off; id true: all). -> the new ExtState value, or nil when id isn't one. Pure.
function webpages.dismissed_with(cur, id, on)
  if id == true and not on then return "" end
  if type(id) ~= "string" or id == "" or #id > 200 or id:find("|", 1, true) then return nil end
  local list, seen = {}, false
  for x in (cur or ""):gmatch("[^|]+") do
    if x == id then seen = true end
    if x ~= id or on then list[#list + 1] = x end
  end
  if on and not seen then
    if #list >= webpages.HIDE_MAX then return nil end
    list[#list + 1] = id
  end
  return table.concat(list, "|")
end
-- A page's feedback: { kind = "bug" | "feedback" | "feature", subject, body, log }. -> kind, title, body, or nil and why. Pure.
function webpages.feedback_of(f)
  if type(f) ~= "table" then return nil, "not a report" end
  local kind = (f.kind == "bug" or f.kind == "feedback" or f.kind == "feature") and f.kind or nil
  local subject, body = type(f.subject) == "string" and f.subject or "", type(f.body) == "string" and f.body or ""
  if not kind then return nil, "not a kind of report" end
  if #subject > webpages.SUBJECT_MAX * 4 or #body > webpages.BODY_MAX * 4 or not utf8.len(subject) or not utf8.len(body)
    or utf8.len(subject) > webpages.SUBJECT_MAX or utf8.len(body) > webpages.BODY_MAX then return nil, "too long" end
  local title, text = require("feedback").compose(kind, (subject:gsub("%c", " ")), (body:gsub("\r\n?", "\n"):gsub("[\0-\8\11-\31\127]", "")))
  if not title then return nil, text end
  return kind, title, text
end
-- st: { side (ProjExtState "side": "" off, else bars behind), rt (Real time mode on), refusal (why this user may not start or stop, or nil),
-- cursor (the edit cursor's bar), regions = { { name, bar } }, due (seconds to a start, or nil), last (the last start or stop, in words),
-- ninjam, sonobus, liveaudio (the studio's own live audio runs here), mate (the bandmate this tab follows, "" nobody), paused (following them is paused), seen (what you see of them),
-- choice (the one Follow: "" nobody, "*" everyone, "@driver", a person's key), people ({ { key, users, active } }: lib/follow.lua people), pinned (the
-- computer you picked of theirs, "" their active one), state (follow state: "waiting" | "live" | "paused" | "slow" | ""), norec (play along when they record),
-- line (what following is, in words: follow.words) }.
-- -> the Play topic: from = start-from labels (1: the edit cursor, then each region), as the panel's. (rt-follow: the page shows only Follow now;
-- from, due and the rest stay for an older page.)
function webpages.play_model(st)
  local from = { "the edit cursor (bar " .. tostring(st.cursor) .. ")" }
  for _, r in ipairs(st.regions or {}) do from[#from + 1] = tostring(r.name) .. " (bar " .. tostring(r.bar) .. ")" end
  local on = type(st.side) == "string" and st.side ~= ""
  return { follow = on, bars = on and tonumber(st.side) or nil, rt = st.rt and true or nil, may = not st.refusal, why = st.refusal, from = from,
    due = st.due and st.due > 0 and math.floor(st.due * 10 + 0.5) / 10 or nil, last = st.last ~= "" and st.last or nil,
    ninjam = st.ninjam and true or nil, sonobus = st.sonobus and true or nil, liveaudio = st.liveaudio and true or nil,
    mate = (st.mate or "") ~= "" and st.mate or nil, paused = st.paused and true or nil, seen = (st.seen or "") ~= "" and st.seen or nil,
    choice = st.choice or "", people = st.people or {}, pinned = (st.pinned or "") ~= "" and st.pinned or nil, state = (st.state or "") ~= "" and st.state or nil,
    norec = st.norec and true or nil, line = st.line }
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
local function health_env(proj, cfg, b) -- (-> page_health, set up for the tab in front: its rows and its web_act)
  local H = require("page_health")
  if not cur then
    cur = {}
    H.init({ b = function() return cur.b end, cfg = function() return cur.cfg end, proj = function() return cur.proj end,
      view = function() return cur.view end, wide = function() return false end, dir = scripts_dir(),
      ui = { play_shown = function() return reaper.GetExtState(band.SECTION, "show play") == "1" end } }) -- (the panel's ui.play_shown: its setting)
  end
  cur.b, cur.cfg, cur.proj, cur.view = b, cfg, proj, require("status").gather(cfg, b, proj)
  return H
end
local function health_rows(proj, cfg, b) return health_env(proj, cfg, b).maint_rows() end
local function play_state(proj, cfg, b, who)
  local together, live = require("together"), require("live")
  local regions = {}
  for i, r in ipairs(together.regions(proj)) do regions[i] = { name = r.name, bar = together.bar_of(r.pos) } end
  local due = tonumber(reaper.GetExtState(band.SECTION, "together_at " .. tostring(proj)))
  local follow, key = require("follow"), tostring(proj)
  local choice, computer = follow.choice_of(proj)
  local people = follow.people(require("presence").peers(cfg, b.song, b.room), cfg.user, computer, follow.fold(cfg))
  local multi, label = false, nil
  for _, p in ipairs(people) do if p.key == choice then multi, label = #p.users > 1, p.label end end
  local side, state, seen = select(2, reaper.GetProjExtState(proj, band.SECTION, "side")), reaper.GetExtState(band.SECTION, "follow state " .. key), reaper.GetExtState(band.SECTION, "follow seen " .. key)
  return { side = side, rt = live.realtime_on(proj),
    refusal = require("dawview").transport_refusal(cfg, b, who), cursor = together.bar_of(reaper.GetCursorPositionEx(proj)), regions = regions,
    due = due and due - together.now() or nil, last = reaper.GetExtState(band.SECTION, "together " .. tostring(proj)),
    ninjam = live.fx(proj, false) ~= nil, sonobus = live.fx(proj, false, live.SONOBUS) ~= nil, liveaudio = live.builtin_audio(cfg.root),
    mate = reaper.GetExtState(band.SECTION, "follow " .. tostring(proj)), seen = reaper.GetExtState(band.SECTION, "follow seen " .. tostring(proj)),
    paused = reaper.GetExtState(band.SECTION, "follow paused " .. tostring(proj)) ~= "",
    choice = choice, people = people, pinned = reaper.GetExtState(band.SECTION, "follow pinned " .. key), state = state, norec = not follow.records_along(),
    line = follow.words({ choice = choice, state = state, seen = seen, computer = computer, multi = multi, label = label, rt = live.realtime_on(proj), bars = tonumber(side) }) }
end

-- ---- what the pages send ---------------------------------------------------------------------------------------------------------------
-- a: { topic = "health", want } or { topic = "play", want, follow (on/off), bars (behind), go = "play" | "record" | "stop", from (0: the edit
-- cursor, n: the nth region), countin, click, lag (bars later for listeners: Time-sync), mate (follow this bandmate, "" nobody), resume,
-- choice (the one Follow, lib/follow.lua set_choice) with computer (one of theirs, or "" their active one), norec }. mate, follow and go are an
-- older page's: still taken. Health's (rt-ui4): act (a row's button or "@setup" / "@update" / "@update reaper": page_health.web_act), hide
-- (a row's id), show (a row's id, or true: all), other (the switch, on/off), feedback ({ kind, subject, body, log }), log ("want" | "files":
-- lib/weblog.lua). -> words for the log, or nil.
function webpages.action(proj, cfg, b, a)
  local now = reaper.time_precise()
  if a.want then S.want[a.topic], S.at[a.topic] = now + webpages.WANT_FOR, -math.huge end
  if a.topic == "health" and a.compat == true then -- (the page's Check other scripts now: a look only, at most every 10 s, by Live sync. lib/compat.lua)
    reaper.SetExtState(band.SECTION, "compat check now", "1", false)
    S.at.health = -math.huge
    return "checking other scripts and extensions, from the web page"
  end
  if a.topic == "health" then
    -- (the extension's word on the action just polled: a page on this computer, not a phone or another device)
    local here = reaper.StudioSync_WebUIPollHere ~= nil and reaper.StudioSync_WebUIPollHere() == 1
    local function said(t) S.said, S.said_n, S.at.health = t, (S.said_n or 0) + 1, -math.huge; return t end
    if a.log ~= nil then return require("weblog").action(a.log, here, now) end
    if a.act ~= nil then
      local ok, words, why = pcall(function() return health_env(proj, cfg, b).web_act(a.act, here) end)
      if not ok then return said("the web page's Health button failed: " .. tostring(words)) end
      return said(words and (tostring(words) .. ", from the web page") or ("the web page's Health button was refused: " .. tostring(why)))
    end
    if a.hide ~= nil or a.show ~= nil then
      local v = webpages.dismissed_with(reaper.GetExtState(band.SECTION, "dismissed"), a.hide ~= nil and a.hide or a.show, a.hide ~= nil)
      if not v then return end
      if v == "" then reaper.DeleteExtState(band.SECTION, "dismissed", true) else reaper.SetExtState(band.SECTION, "dismissed", v, true) end
      S.at.health = -math.huge
      return
    end
    if a.other ~= nil then
      reaper.SetExtState(band.SECTION, "health other off", a.other == false and "1" or "", true)
      S.at.health = -math.huge
      return
    end
    if a.feedback ~= nil then -- (this computer's page only: a report goes out under this computer's name. lib/feedback.lua)
      if not here then return said("the web page's feedback was refused: only from this computer's own page") end
      local kind, title, body = webpages.feedback_of(a.feedback)
      if not kind then return said("the feedback wasn't saved: " .. tostring(title)) end
      local extra = ""
      if a.feedback.log == true then
        local lines = {}
        for i, l in ipairs(band.activity()) do if i > 25 then break end; lines[#lines + 1] = "    " .. l end
        extra = "## This computer\n\n" .. require("feedback").system(proj) .. "\n\n## Activity (newest first)\n\n" .. table.concat(lines, "\n")
      end
      local path, why = require("feedback").save(cfg, kind, title, body, extra)
      return said(path and ("feedback saved in " .. ((cfg and cfg.root or "") ~= "" and "the studio's feedback folder" or path) .. ", from the web page")
        or ("the feedback wasn't saved: " .. tostring(why)))
    end
    return
  end
  if a.topic ~= "play" then return end
  if a.norec ~= nil then -- (following someone who records: play along instead of recording on your armed tracks. lib/follow.lua, rt-follow)
    reaper.SetExtState(band.SECTION, "follow no rec", a.norec == true and "1" or "", true)
    S.at.play = -math.huge
    if a.choice == nil then return a.norec == true and "following: you play along when they record (web page)" or "following: you record with them on your armed tracks (web page)" end
  end
  -- (the one Follow: a person (their active computer, or one picked), everyone, the driver, or nobody. Only someone this room has. An older
  -- page's "mate" (a computer's name, "" nobody) goes the same way. lib/follow.lua set_choice, rt-follow)
  local choice = type(a.choice) == "string" and a.choice or type(a.mate) == "string" and a.mate or nil
  if choice then
    S.at.play = -math.huge
    local said, why = require("follow").set_choice(proj, cfg, require("presence").peers(cfg, b.song, b.room), choice,
      type(a.computer) == "string" and a.computer ~= "" and a.computer or nil, webpages.bars(a.bars))
    return said and (said .. ", from the web page") or ("the web page's Follow was left as it is: " .. tostring(why))
  end
  if a.resume then S.at.play = -math.huge; reaper.DeleteExtState(band.SECTION, "follow paused " .. tostring(proj), false); return end
  if a.follow ~= nil or a.bars ~= nil then
    -- (Real time mode is following at 0 bars: changed here, it would quietly switch Real time off. As the panel's, greyed out then)
    if require("live").realtime_on(proj) then return "the web page's Play and stop together was left as it is: Real time mode is on (Home)" end
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
      a.click ~= false, webpages.bars(a.lag) or 0, a.skip == true) -- (skip: the page's "skip the time selection", lib/together.lua)
    return what .. " together, from the web page"
  end
end

-- Each tick in front, while a page looks (lib/webui.lua). publish(topic, table) sends only what changed; who: sync.authority's second answer
-- from webui's presence build.
function webpages.tick(proj, cfg, b, publish, who, now)
  local every = (S.want.health or -math.huge) > now and webpages.HEALTH_EVERY or webpages.HEALTH_IDLE
  if now - (S.at.health or -math.huge) >= every then
    S.at.health = now
    local ok, rows = pcall(health_rows, proj, cfg, b)
    local H = require("page_health")
    local okb, builtin = pcall(function() return require("live").builtin_audio(cfg.root) end)
    publish("health", ok and webpages.health_model(rows, H.dismissed_set(), band.VERSION, reaper.GetExtState(band.SECTION, "menu extension"),
        { other_off = reaper.GetExtState(band.SECTION, "health other off") == "1", button = H.web_button, remote = H.WEB_REMOTE,
          builtin = okb and builtin, said = S.said, said_n = S.said_n })
      or { ver = band.VERSION, error = tostring(rows) })
  end
  require("weblog").tick(publish, now) -- (Health > Log, while a page shows it)
  if (S.want.play or -math.huge) > now and now - (S.at.play or -math.huge) >= webpages.PLAY_EVERY then
    S.at.play = now
    publish("play", webpages.play_model(play_state(proj, cfg, b, who)))
  end
end

return webpages
