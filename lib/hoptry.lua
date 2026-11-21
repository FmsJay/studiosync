-- Try a plug-in you don't have (rt-hopvst). James: "VSTs actually loaded to another computer through our plug-in ... for testing and trying
-- instruments, changing VST settings: on a system without the VST they could experiment with it and change the actual VST and plug-in settings."
--  - You: browse the plug-ins a bandmate here has (their published list, lib/plugins.lua), pick one, and a StudioSync Hop goes at the end of the
--    selected track (lib/hops.lua hops.try). Your audio or MIDI goes through their copy live; its knobs show here as a plain list (names,
--    values as the plug-in writes them) and turning one turns theirs. Print records what comes back onto a new track, so the experiment
--    stays in the project even though you don't own the plug-in.
--  - Them: nothing loads until they say yes (their computer, their licence), for this Live sync session only (asked again next time). They see
--    who is trying which of their plug-ins and can stop it at any time. Its own window opens only on their computer, by them.
--  - Only audio, MIDI and knob values travel: never a plug-in's files or its licence.
-- The panel's side is Settings > Health (an ask's Allow, a try's Stop there) and the action "StudioSync - Try a bandmate's plug-in"; the web
-- UI's Try tab (lib/webui/tryfx.js) has all of it. GPL-3.0-or-later.
local band = require("band")
-- Knobs in pages (rt-p4, rt-hop2 item 4): a direct-link message caps at 64 KB, so the knob list goes PAGE at a time: page 0 as "params" (what
-- an older StudioSync shows: the first 256, as before), the others as "page" with their offset (an older one ignores those). At most
-- PAGES_EVERY pages a tick, up to PARAM_MAX knobs (a JUCE VST3's 2,048 MIDI-CC proxies after its own still fit).
local hoptry = { PARAM_MAX = 4096, PAGE = 256, PAGES_EVERY = 4, NAME_MAX = 48, VAL_MAX = 24, PARAMS_EVERY = 1, PARAMS_AGAIN = 5, MATCH_MAX = 60, ASK_FOR = 30,
  PRINT_LEAD = 2, PRINT_WARM = 1, PRINT_TAIL = 0.3, PRINT_MAX = 900, WANT_FOR = 30, BUILD_EVERY = 0.5, TOPIC = "tryfx",
  PREROLL = 41819 } -- (Pre-roll: Toggle pre-roll on record)
local function hops() return require("hops") end
local function S() return require("hops").S end

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
-- Text for a list or a message: no control characters, at most n bytes, never cut inside a UTF-8 character. Pure.
function hoptry.clip(s, n)
  s = tostring(s or ""):gsub("%c", " ")
  if #s <= n then return utf8.len(s) and s or "" end
  local cut = n
  while cut > 0 and not utf8.len(s:sub(1, cut)) do cut = cut - 1 end
  return s:sub(1, cut)
end
-- Which installed name to load for a published key: VST3, then CLAP, VST, AU, LV2, JS (as the band's FX folder ranks them); and whether
-- it's an instrument (VSTi, VST3i, CLAPi, AUi, LV2i). `installed`: { {name} } (plugins.installed). -> name, instrument; or nil. Pure.
local RANK = { VST3 = 1, VST3i = 1, CLAP = 2, CLAPi = 2, VST = 3, VSTi = 3, AU = 4, AUi = 4, LV2 = 5, LV2i = 5, JS = 6 }
function hoptry.best(installed, key, plugins)
  local best, br
  for _, p in ipairs(installed or {}) do
    local kind = plugins.kind(p.name) or ""
    if RANK[kind] and plugins.key(p.name) == key and (not best or RANK[kind] < br) then best, br = p.name, RANK[kind] end
  end
  return best, best ~= nil and (plugins.kind(best) or ""):match("i$") ~= nil
end
-- Plug-ins to try: of the published lists (`lists`: { {user, names} }), those of bandmates here (`here`: user -> true) that this computer
-- doesn't have (`mine`: key -> true), matching every word of `q`, by name then user; at most `max`. -> { {user, key} }, and how many matched. Pure.
function hoptry.search(lists, here, mine, q, max)
  local words = {}
  for w in tostring(q or ""):lower():gmatch("%S+") do words[#words + 1] = w end
  local out, n = {}, 0
  for _, l in ipairs(lists or {}) do
    if type(l) == "table" and here[l.user] then
      for _, k in ipairs(type(l.names) == "table" and l.names or {}) do
        local ok = type(k) == "string" and not mine[k]
        for _, w in ipairs(words) do ok = ok and k:find(w, 1, true) ~= nil end
        if ok then n = n + 1; out[#out + 1] = { user = l.user, key = k } end
      end
    end
  end
  table.sort(out, function(a, b) if a.key ~= b.key then return a.key < b.key end return a.user < b.user end)
  for i = #out, (max or hoptry.MATCH_MAX) + 1, -1 do out[i] = nil end
  return out, n
end
-- A page of knobs from the host's message, made safe to keep and show: at most PAGE entries with a whole index in its page (from `off`), a
-- name, a value 0..1 and its text. nil when it isn't a list. Pure.
function hoptry.clean_params(list, off)
  if type(list) ~= "table" then return nil end
  off = off or 0
  local out = {}
  for _, e in ipairs(list) do
    if #out >= hoptry.PAGE then break end
    local i, v = type(e) == "table" and math.tointeger(tonumber(e.i)), type(e) == "table" and tonumber(e.v)
    if i and i >= off and i < off + hoptry.PAGE and v and v == v then
      out[#out + 1] = { i = i, n = hoptry.clip(e.n, hoptry.NAME_MAX), v = math.max(0, math.min(1, v)), s = hoptry.clip(e.s, hoptry.VAL_MAX) }
    end
  end
  return out
end

-- ---- the owner's computer --------------------------------------------------------------------------------------------------------------
local function deny(cfg, token, why, song, room)
  require("direct").send_live(cfg, "hop", { op = "fail", token = token, why = why, denied = true, user = cfg.user }, song, room)
end
-- A bandmate's ask (hops.serve, d.try): the installed name to load once this computer's owner has said yes to that bandmate and plug-in this
-- session. -> name, nil, instrument; or nil and why (nil why: answered already, as a refusal).
function hoptry.host_check(cfg, d, token, song, room)
  local st, plugins = S(), require("plugins")
  local key = plugins.key(hoptry.clip(d.fx, 200))
  local user = hoptry.clip(d.user, 64)
  if key == "" or user == "" then return nil, "their StudioSync didn't understand the request" end
  if st.refused[token] then deny(cfg, token, st.refused[token], song, room); return nil end
  local name, inst = hoptry.best(plugins.installed(), key, plugins)
  if not name then return nil, key .. " isn't installed on their computer" end
  if st.allow[user .. "\0" .. key] then st.pending[token] = nil; return name, nil, inst end
  if not st.pending[token] then
    band.log(string.format("%s asks to try your %s on this computer. It's your licence, so only with your yes: Allow in Settings > Health or the web UI's Try tab", user, key))
  end
  st.pending[token] = { user = user, key = key, at = reaper.time_precise(), song = song, room = room }
  return nil, string.format("waiting for %s to say yes (their computer, their licence)", tostring(cfg.user))
end
-- Asks still being made (the bandmate asks again every few seconds; one that stopped asking goes): { {token, user, key} } by user, plug-in.
function hoptry.asks()
  local st, now, out = S(), reaper.time_precise(), {}
  for token, p in pairs(st.pending) do
    if now - p.at > hoptry.ASK_FOR then st.pending[token] = nil else out[#out + 1] = { token = token, user = p.user, key = p.key } end
  end
  table.sort(out, function(a, b) if a.user ~= b.user then return a.user < b.user end return a.key < b.key end)
  return out
end
-- Yes, for this session: that bandmate may try that plug-in here (again too) until Live sync stops. It loads at their next ask (a few s).
function hoptry.allow(token)
  local st = S()
  local p = st.pending[token]
  if not p then return "That ask has gone (they stopped asking)." end
  st.allow[p.user .. "\0" .. p.key], st.pending[token] = true, nil
  return string.format("%s may try your %s here until Live sync stops; it loads in a few seconds", p.user, p.key)
end
function hoptry.refuse(cfg, token)
  local st = S()
  local p = st.pending[token]
  if not p then return nil end
  st.refused[token], st.pending[token] = tostring(cfg.user) .. " said no", nil
  deny(cfg, token, st.refused[token], p.song, p.room)
  return string.format("told %s no: your %s stays yours", p.user, p.key)
end
-- The owner stops a try: the hidden track goes, the yes with it, and they're told.
function hoptry.end_use(proj, cfg, token)
  local st = S()
  local sv = st.serving[token]
  if not (sv and sv.try) then return nil end
  st.allow[tostring(sv.user) .. "\0" .. require("plugins").key(tostring(sv.fx))] = nil
  st.refused[token] = tostring(cfg.user) .. " stopped it"
  deny(cfg, token, st.refused[token], sv.song, sv.room)
  hops().drop_served(proj, token)
  local text = string.format("stopped %s trying your %s", tostring(sv.user), tostring(sv.fx))
  band.log(text)
  return text
end
-- Who is trying which of this computer's plug-ins now: { {token, user, key} }.
function hoptry.uses()
  local out = {}
  for token, sv in pairs(S().serving) do if sv.try then out[#out + 1] = { token = token, user = tostring(sv.user), key = tostring(sv.fx) } end end
  table.sort(out, function(a, b) return a.user .. a.key < b.user .. b.key end)
  return out
end
-- The requester stopped (their "stop"): an ask still waiting goes too.
function hoptry.gone(token) S().pending[token] = nil end
local function track_of(proj, guid)
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if reaper.GetTrackGUID(tr) == guid then return tr end
  end
end
-- The tried plug-in's knobs (FX 1 on the hidden track) to whoever tries it, a page at a time: a page goes when one of its values changed
-- (all values are read each second; names and value texts only for a page that goes), and each page in turn every PARAMS_AGAIN s or so
-- anyway; at most PAGES_EVERY pages a tick, the rest at the next.
function hoptry.host_params(cfg, token, sv, tr)
  local now = reaper.time_precise()
  if now - (sv.params_at or -math.huge) < hoptry.PARAMS_EVERY then return end
  sv.params_at = now
  local n = reaper.TrackFX_GetNumParams(tr, 1)
  local total, P = math.min(n, hoptry.PARAM_MAX), hoptry.PAGE
  local pages = math.max(1, (total + P - 1) // P)
  local st = S()
  if type(st.sent[token]) ~= "table" then st.sent[token] = {} end
  local sent = st.sent[token]
  sv.pv, sv.due, sv.full = sv.pv or {}, sv.due or {}, sv.full or {}
  sv.turn = ((sv.turn or -1) + 1) % pages
  for pg = 0, pages - 1 do
    local due = pg == sv.turn or sent[pg] == nil
    for p = pg * P, math.min(total, (pg + 1) * P) - 1 do
      local v = math.floor(reaper.TrackFX_GetParamNormalized(tr, 1, p) * 10000 + 0.5) / 10000
      if sv.pv[p] ~= v then sv.pv[p], due = v, true end
    end
    if due then sv.due[pg] = true end
  end
  local went = 0
  for pg = 0, pages - 1 do
    if sv.due[pg] and went < hoptry.PAGES_EVERY then
      sv.due[pg] = nil
      local list = {}
      for p = pg * P, math.min(total, (pg + 1) * P) - 1 do
        local _, name = reaper.TrackFX_GetParamName(tr, 1, p, "")
        local _, s = reaper.TrackFX_GetFormattedParamValue(tr, 1, p, "")
        list[#list + 1] = { i = p, n = hoptry.clip(name, hoptry.NAME_MAX), v = sv.pv[p], s = hoptry.clip(s, hoptry.VAL_MAX) }
      end
      local enc = band.json_encode(list)
      if sent[pg] ~= enc or now - (sv.full[pg] or -math.huge) >= hoptry.PARAMS_AGAIN then
        sent[pg], sv.full[pg], went = enc, now, went + 1
        sv.peer = sv.peer or hops().peers_by_user(cfg, sv.song, sv.room)[sv.user]
        require("direct").send_live(cfg, "hop", { op = pg == 0 and "params" or "page", off = pg * P, token = token, fx = sv.name, instrument = sv.instrument or nil,
          total = n, list = list, user = cfg.user }, sv.song, sv.room, nil, sv.peer and { sv.peer } or nil)
      end
    end
  end
end

-- ---- both: what comes over the link ----------------------------------------------------------------------------------------------------
-- "params" (to whoever tries it) and "set" (a knob turned there, to the owner's hidden copy: only that try's own requester's).
function hoptry.on_msg(proj, cfg, d, token)
  local st = S()
  if d.op == "params" or d.op == "page" then -- (a page of its knobs, merged by index: page 0 says how many there are)
    local off = d.op == "page" and math.tointeger(tonumber(d.off)) or 0
    if not off or off < 0 or off % hoptry.PAGE ~= 0 or off >= hoptry.PARAM_MAX then return end
    for _, rec in pairs(hops().records(proj)) do
      if rec.try and rec.token == token then
        local list = hoptry.clean_params(d.list, off)
        if list then
          local pm = st.params[token] or { pages = {} }
          pm.pages[off // hoptry.PAGE] = list
          pm.fx, pm.instrument, pm.at = hoptry.clip(d.fx, 200), d.instrument == true, reaper.time_precise()
          if off == 0 then pm.total = math.max(0, math.tointeger(tonumber(d.total)) or #list) end
          local n = math.min(pm.total or 0, hoptry.PARAM_MAX)
          pm.list = {}
          for pg = 0, (n + hoptry.PAGE - 1) // hoptry.PAGE - 1 do
            for _, e in ipairs(pm.pages[pg] or {}) do pm.list[#pm.list + 1] = e end
          end
          if off == 0 then -- (a page past its knobs: one it had before page 0 said fewer. Only then: a later page may come before page 0)
            for pg in pairs(pm.pages) do if pg > 0 and pg * hoptry.PAGE >= n then pm.pages[pg] = nil end end
          end
          st.params[token] = pm
        end
      end
    end
  elseif d.op == "set" then
    local sv = st.serving[token]
    if not (sv and sv.try and d.user == sv.user) then return end
    local tr = track_of(proj, sv.track)
    local p, v = math.tointeger(tonumber(d.p)), tonumber(d.v)
    if not (tr and p and v and v == v and p >= 0 and p < reaper.TrackFX_GetNumParams(tr, 1)) then return end
    reaper.TrackFX_SetParamNormalized(tr, 1, p, math.max(0, math.min(1, v)))
    sv.params_at = -math.huge -- (its new value, and the text the plug-in writes for it, go back on the next tick)
  end
end

-- ---- the computer trying it ------------------------------------------------------------------------------------------------------------
local function try_rec(proj, id)
  local rec = hops().records(proj)[tostring(math.tointeger(tonumber(id)) or "")]
  return rec and rec.try and rec or nil
end
-- Turn one of the tried plug-in's knobs (0..1, as REAPER's normalized value) on the owner's copy.
function hoptry.set_param(proj, cfg, id, p, v)
  local rec = try_rec(proj, id)
  p, v = math.tointeger(tonumber(p)), tonumber(v)
  if not (rec and p and p >= 0 and v and v == v) then return false end
  v = math.max(0, math.min(1, v))
  local have = S().params[rec.token]
  for _, e in ipairs(have and have.list or {}) do if e.i == p then e.v = v end end
  return require("direct").send_live(cfg, "hop", { op = "set", token = rec.token, p = p, v = v, user = cfg.user }, rec.song, rec.room, nil, { rec.peer })
end
-- Bandmates here with their published lists, for the search: user -> peer, and the lists.
local function lists_here(cfg, song, room)
  local plugins = require("plugins")
  local peer_of = hops().peers_by_user(cfg, song, room)
  local mine = {}
  for _, p in ipairs(plugins.installed()) do mine[plugins.key(p.name)] = true end
  return peer_of, plugins.lists(cfg), mine
end
-- Try `key` from `user`'s list on track `tr`. -> hop id, or nil and why.
function hoptry.start(proj, cfg, b, tr, user, key)
  if not tr then return nil, "select a track first (an instrument's MIDI or the audio to put through it)" end
  local peer = hops().peers_by_user(cfg, b.song, b.room)[user]
  if not peer then return nil, tostring(user) .. " isn't on the link now (Live sync on there too?)" end
  return hops().try(proj, cfg, tr, user, peer, key, b.song, b.room)
end

-- Print: what the tried plug-in plays here recorded onto a new track (named for it), over the time selection (or the track's items),
-- playing from PRINT_LEAD s before so the hop has started, through REAPER's time-selection auto-punch; the record mode, armed tracks and the
-- new track's master send are put back after. -> true, or nil and why.
local function items_span(tr)
  local a, z = math.huge, -math.huge
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    a, z = math.min(a, pos), math.max(z, pos + reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
  end
  return a < z and a or nil, z
end
function hoptry.print(proj, cfg, id)
  local st = S()
  if st.printing then return nil, "a print is running already" end
  local rec = try_rec(proj, id)
  if not rec then return nil, "that try has ended" end
  local tr = hops().track_by_oid(proj, rec.oid)
  if not tr then return nil, "its track is gone" end
  if (tonumber(reaper.GetPlayStateEx(proj)) or 0) ~= 0 then return nil, "stop playback first" end
  local ts, te = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  if not (ts and te and te > ts) then
    ts, te = items_span(tr)
    if not ts then return nil, "make a time selection first (the part to print)" end
    reaper.GetSet_LoopTimeRange2(proj, true, false, ts, te, false)
  end
  local pt = band.new_track(proj, hoptry.clip(rec.track or "Track", 60) .. " - " .. hoptry.clip(rec.fx, 60) .. " print")
  if not pt then return nil, "couldn't add a track (REAPER before 7.18 adds them only to the tab in front)" end
  reaper.CreateTrackSend(tr, pt)
  reaper.SetTrackSendInfo_Value(tr, 0, reaper.GetTrackNumSends(tr, 0) - 1, "I_SENDMODE", 3) -- (post-FX: the Hop's output, its fader not in it)
  local armed = {}
  for t = 0, reaper.CountTracks(proj) - 1 do
    local o = reaper.GetTrack(proj, t)
    if o ~= pt and reaper.GetMediaTrackInfo_Value(o, "I_RECARM") == 1 then armed[#armed + 1] = reaper.GetTrackGUID(o); reaper.SetMediaTrackInfo_Value(o, "I_RECARM", 0) end
  end
  reaper.SetMediaTrackInfo_Value(pt, "I_RECMODE", 3) -- (record: output, stereo, latency compensated)
  reaper.SetMediaTrackInfo_Value(pt, "I_RECMON", 0)
  reaper.SetMediaTrackInfo_Value(pt, "B_MAINSEND", 0) -- (not heard twice while it records)
  reaper.SetMediaTrackInfo_Value(pt, "I_RECARM", 1)
  local mode = 40252
  for _, m in ipairs({ 40076, 40253 }) do if reaper.GetToggleCommandState(m) == 1 then mode = m end end
  reaper.Main_OnCommand(40076, 0) -- Options: Record mode: time selection auto punch
  reaper.SetEditCurPos2(proj, math.max(0, ts - hoptry.PRINT_LEAD), false, false)
  -- (rt-hop2 item 2: a play start sends the Hop its whole latency at once, and the first half second or so can't be back in time, so it plays
  -- the dry input; the lead-in covers that, but from 0 there's none. So a selection without room for the lead-in records with REAPER's
  -- pre-roll on (it plays from before the edit cursor, before 0 at the project's start), put back after; print_tick watches whether
  -- playback really went far enough back, and says so if it didn't. docs/rt/rt-hop2.md round 2)
  local preroll = ts < hoptry.PRINT_LEAD and reaper.GetToggleCommandState(hoptry.PREROLL) ~= 1
  if preroll then reaper.Main_OnCommand(hoptry.PREROLL, 0) end
  st.printing = { proj = proj, id = rec.id, track = reaper.GetTrackGUID(pt), stop_at = te + hoptry.PRINT_TAIL, ends = reaper.time_precise() + (te - ts) + hoptry.PRINT_LEAD + 30,
    armed = armed, mode = mode, label = string.format("%s (via %s's computer)", hoptry.clip(rec.fx, 80), hoptry.clip(rec.user, 40)), started = false,
    preroll = preroll or nil, ts = ts, low = math.huge }
  reaper.Main_OnCommand(1013, 0) -- Transport: Record
  band.log(string.format("printing %s over the time selection onto a new track%s", tostring(rec.fx),
    ts < hoptry.PRINT_LEAD and " (with REAPER's pre-roll, so the hop has started before the selection)" or ""))
  return true
end
-- Each tick while printing: at the end (or when playback stopped some other way), stop, keep the recording, put things back.
function hoptry.print_tick(now)
  local st = S()
  local pr = st.printing
  if not pr then return end
  local proj = pr.proj
  if not reaper.ValidatePtr2(0, proj, "ReaProject*") then st.printing = nil; return end
  local ps = tonumber(reaper.GetPlayStateEx(proj)) or 0
  if ps & 4 == 4 then pr.started = true end
  if ps ~= 0 then pr.low = math.min(pr.low, tonumber(reaper.GetPlayPosition2Ex(proj)) or math.huge) end -- (how far back it played: the lead-in it had)
  local done = (pr.started and ps & 4 == 0) or (ps & 4 == 4 and reaper.GetPlayPosition2Ex(proj) >= pr.stop_at) or now > pr.ends
    or (not pr.started and now > pr.ends - 25) -- (recording never started: REAPER's audio isn't running?)
  if not done then return end
  st.printing = nil
  if ps ~= 0 then reaper.Main_OnCommand(40667, 0) end -- Transport: Stop (save all recorded media)
  reaper.Main_OnCommand(pr.mode, 0) -- (the record mode it had)
  if pr.preroll and reaper.GetToggleCommandState(hoptry.PREROLL) == 1 then reaper.Main_OnCommand(hoptry.PREROLL, 0) end -- (pre-roll off again, as it was)
  local pt = track_of(proj, pr.track)
  if pt then
    reaper.SetMediaTrackInfo_Value(pt, "I_RECARM", 0)
    reaper.SetMediaTrackInfo_Value(pt, "B_MAINSEND", 1)
    for i = 0, reaper.CountTrackMediaItems(pt) - 1 do
      local tk = reaper.GetActiveTake(reaper.GetTrackMediaItem(pt, i))
      if tk then reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", pr.label, true) end
    end
  end
  for _, g in ipairs(pr.armed) do local o = track_of(proj, g); if o then reaper.SetMediaTrackInfo_Value(o, "I_RECARM", 1) end end
  local got = pt and reaper.CountTrackMediaItems(pt) or 0
  band.log(got > 0 and ("printed " .. pr.label .. ": it's yours to keep on its own track") or "the print recorded nothing (was REAPER's audio running?)")
  if pr.started and pr.ts and pr.low > pr.ts - hoptry.PRINT_WARM then -- (seen every half second: a lead-in under that may be missed, and reads as none)
    band.log(string.format("the print's lead-in was only %.1f s (REAPER's pre-roll didn't play far enough before the selection at %.1f s): about the first half second of the print may be the dry track. Start the selection at %d s or later, or set a longer pre-roll (Options > Metronome/pre-roll settings), for a print that's wet throughout",
      math.max(0, pr.ts - pr.low), pr.ts, hoptry.PRINT_LEAD))
  end
end

-- ---- Health (the owner's asks, with Allow) ---------------------------------------------------------------------------------------------
function hoptry.health_rows(proj, cfg)
  local rows = {}
  for _, a in ipairs(hoptry.asks()) do
    local text = string.format("%s asks to try your %s on this computer (live, on a hidden track; only audio, MIDI and its settings travel)", a.user, a.key)
    rows[#rows + 1] = { "hop ask " .. a.token, false, "yellow", text, text,
      action = { "Allow for this session", function() band.log(hoptry.allow(a.token)) end, "Your computer and your licence: until Live sync stops. The web UI's Try tab can also say no." } }
  end
  return rows
end

-- ---- the web UI's Try tab --------------------------------------------------------------------------------------------------------------
local web = { want = -math.huge, q = "", at = -math.huge, kn = {} } -- (kn: try id -> the knob page shown and its filter)
-- The knobs a try's box shows, of all it has (`list`): those whose name has `q` in it (any case), or else page `page`; at most PAGE.
-- -> them, and how many matched. Pure.
function hoptry.knob_view(list, page, q)
  local out, n, lo = {}, 0, (page or 0) * hoptry.PAGE
  q = tostring(q or ""):lower()
  for _, e in ipairs(list or {}) do
    if q ~= "" and e.n:lower():find(q, 1, true) or q == "" and e.i >= lo and e.i < lo + hoptry.PAGE then
      n = n + 1
      if #out < hoptry.PAGE then out[#out + 1] = e end
    end
  end
  return out, n
end
-- -> what the page shows: your tries with their knobs and state, the search's matches, asks for and uses of your own plug-ins.
function hoptry.model(proj, cfg, b)
  local hp, st = hops(), S()
  local tries = {}
  for _, rec in pairs(hp.records(proj)) do
    if rec.try then
      local ok, text = hp.health_text(rec, hp.available() and band.json_decode(reaper.StudioSync_HopStatus(math.floor(rec.id))) or {})
      local pm = st.params[rec.token]
      local kv = web.kn[rec.id] or {}
      local q = kv.q or ""
      local pages = pm and math.max(1, (math.min(pm.total or 0, hoptry.PARAM_MAX) + hoptry.PAGE - 1) // hoptry.PAGE) or nil
      local page = math.min(kv.page or 0, (pages or 1) - 1)
      local params, matched = nil, nil
      if pm then params, matched = hoptry.knob_view(pm.list, page, q) end
      tries[#tries + 1] = { id = rec.id, fx = rec.fx, user = rec.user, track = rec.track, ok = ok, text = text, params = params,
        total = pm and pm.total or nil, name = pm and pm.fx or nil, instrument = pm and pm.instrument or nil, page = pm and page or nil, pages = pages,
        kq = q ~= "" and q or nil, matched = q ~= "" and matched or nil, printing = st.printing ~= nil and st.printing.id == rec.id or nil }
    end
  end
  table.sort(tries, function(a, z) return a.id < z.id end)
  local live = {}
  for _, t in ipairs(tries) do live[t.id] = true end
  for id in pairs(web.kn) do if not live[id] then web.kn[id] = nil end end -- (an ended try's page: a new one with its id starts at the top)
  local peer_of, lists, mine = lists_here(cfg, b.song, b.room)
  local here, people = {}, {}
  for u in pairs(peer_of) do here[u] = true; people[#people + 1] = u end
  table.sort(people)
  local matches, n = hoptry.search(lists, here, mine, web.q, hoptry.MATCH_MAX)
  local sel = reaper.GetSelectedTrack(proj, 0)
  local ended = {}
  for _, x in ipairs(st.back) do if reaper.time_precise() - x.at < hp.SAY_BACK then ended[#ended + 1] = x.text end end
  return { me = cfg.user, q = web.q, people = people, matches = matches, matched = n, tries = tries, asks = hoptry.asks(), uses = hoptry.uses(),
    sel = sel and select(2, reaper.GetTrackName(sel)) or nil, ended = ended, live = hp.available() }
end
function hoptry.web_tick(proj, cfg, b, publish, now)
  if now > web.want or now - web.at < hoptry.BUILD_EVERY then return end
  web.at = now
  local ok, m = pcall(hoptry.model, proj, cfg, b)
  publish(hoptry.TOPIC, ok and m or { error = tostring(m) })
end
-- What the page sends: {want}, {q}, {try = {user, key}}, {set = {id, p, v}}, {knobs = {id, page, q}}, {stop = id}, {print = id},
-- {allow = token}, {refuse = token}, {end_use = token}. -> a line for the log, or nil.
function hoptry.web_action(proj, cfg, b, a)
  local now = reaper.time_precise()
  web.want = now + hoptry.WANT_FOR
  web.at = -math.huge -- (what it asked for shows on the next tick)
  if type(a.q) == "string" then web.q = hoptry.clip(a.q, 80) end
  local token = math.tointeger(tonumber(a.allow or a.refuse or a.end_use))
  if a.allow and token then return hoptry.allow(token) end
  if a.refuse and token then return hoptry.refuse(cfg, token) end
  if a.end_use and token then return hoptry.end_use(proj, cfg, token) end
  if type(a.set) == "table" then hoptry.set_param(proj, cfg, a.set.id, a.set.p, a.set.v); return nil end
  if type(a.knobs) == "table" then -- (which page of a try's knobs the page shows, or its filter)
    local id = math.tointeger(tonumber(a.knobs.id))
    if not try_rec(proj, id) then return nil end
    local kv = web.kn[id] or {}
    local pg = math.tointeger(tonumber(a.knobs.page))
    if pg then kv.page = math.max(0, math.min(pg, hoptry.PARAM_MAX // hoptry.PAGE - 1)) end
    if type(a.knobs.q) == "string" then kv.q = hoptry.clip(a.knobs.q, 48) end
    web.kn[id] = kv
    return nil
  end
  if a.stop then
    local rec = try_rec(proj, a.stop)
    if rec and hops().stop(proj, cfg, rec.id) then return "stopped trying " .. tostring(rec.fx) end
    return nil
  end
  if a.print then
    local ok, why = hoptry.print(proj, cfg, a.print)
    return not ok and ("not printed: " .. tostring(why)) or nil
  end
  if type(a.try) == "table" and type(a.try.user) == "string" and type(a.try.key) == "string" then
    local id, why = hoptry.start(proj, cfg, b, reaper.GetSelectedTrack(proj, 0), a.try.user, hoptry.clip(a.try.key, 200))
    return not id and ("not tried: " .. tostring(why)) or nil
  end
end

return hoptry
