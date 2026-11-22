-- Shared controllers (docs/realtime-roadmap.md More big ideas 5): a fader, pan or mute moved here, or a plug-in knob, from anything (the mouse, a
-- control surface, a MIDI-learned controller, OSC), moves on everyone's REAPER within ~50 ms over the direct link's small messages, before the
-- normal sync carries the finished change. The stream is only a preview: the mirror's change is the record and confirms it. (James, rt)
--   sending   the tab in front reads every mirrored track's volume, pan and mute each tick, and the plug-in knob REAPER says was last touched (and
--             any touched in the last WATCH s); a change from the last reading is yours, as Live sync's tick takes in what StudioSync itself
--             wrote (controllers.settle, like its took_in). Only what you may change goes (sync.authority's rule and the maker's, as mirror.watch
--             judges), never your faders and pan with Local mixing on (they don't go out). At most one move a
--             control every RATE s, the last value always; LET_GO s after it last moved, "let go".
--   showing   a move is shown only if the sender may change that track here too, the track isn't writing automation here (Touch, Latch or
--             Write: nothing a stream sets ever lands in an envelope), you have no unsent change of it, and not your faders or pan with Local
--             mixing on. While shown and until the band's change for it lands, mirror.watch leaves that track (or its plug-ins) alone
--             (mirror.previewing): neither sent as yours nor put back. No change in CONFIRM s and nothing from the band since: the value before it
--             comes back.
--   holding   whoever started moving a control first holds it till they let go (HELD s without a move if the let-go is lost); a move of yours
--             on it meanwhile goes back to theirs, said once. Two starting together: the earlier start on the shared clock, then the name,
--             the same on every computer.
-- Solo isn't streamed (each person's own: mirror.track_line), nor the master (its fader is each person's listening level), take FX or
-- plug-ins inside a container. Off for the studio (Settings > Studio > Direct link, owner and admins): nothing is read or sent.
local band = require("band")
local controllers = {}
controllers.RATE = 0.05    -- seconds between moves of one control sent (20 a second)
controllers.LET_GO = 0.5   -- seconds after a control last moved here that it's let go
controllers.HELD = 1.5     -- seconds a bandmate's hold counts after their last move (their let-go lost)
controllers.CONFIRM = 60   -- seconds a shown move waits for the band's change (a control surface's may wait for the 10 s look)
-- (60, not 20: the change for a shown move can come by Syncthing alone when the link's copy is lost, tens of seconds; at 20 the fader went
-- back and then forward again when it landed. rt-r5's 27 s itself was mirror.receive holding the change behind the preview's own value, fixed
-- there: rt-fix9)
controllers.WATCH = 3      -- seconds a touched plug-in knob is still read after it last moved
controllers.MAX = 64       -- moves in one message
controllers.pass = nil     -- (Live sync's last pass: can, my_can, who, hold; set in its P.who)

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local LIMITS = { v = { 0, 16 }, p = { -1, 1 }, m = { 0, 1 }, x = { 0, 1 } } -- (volume up to +24 dB)
local function int_in(x, hi) return math.type(x) == "integer" and x >= 0 and x <= hi end
-- A ctl message from the link (a trust boundary: anyone in the studio can send one): { user, m = { { o, k, v, s, f?, n?, g?, a?, q? } } }
-- (q: the move's number in its hold, 1, 2, ...: an older one never lands after a newer).
-- -> a clean copy, or nil.
function controllers.clean(d, me)
  if type(d) ~= "table" or type(d.user) ~= "string" or #d.user == 0 or #d.user > 64 or d.user == me or type(d.m) ~= "table" then return nil end
  local out = {}
  for i, m in ipairs(d.m) do
    if i > controllers.MAX then return nil end
    local lim = type(m) == "table" and LIMITS[m.k]
    local v, s = lim and tonumber(m.v), lim and tonumber(m.s)
    if not (v and s and v == v and v >= lim[1] and v <= lim[2] and type(m.o) == "string" and m.o:match("^T%-[%w%-_]+$") and #m.o <= 80) then return nil end
    if m.k == "x" and not (int_in(m.f, 1023) and int_in(m.n, 65535)) then return nil end
    out[i] = { o = m.o, k = m.k, v = v, s = s, f = m.k == "x" and m.f or nil, n = m.k == "x" and m.n or nil, g = m.g == 1, a = m.a == 1,
      q = int_in(m.q, math.maxinteger) and m.q or nil }
  end
  return #out > 0 and { user = d.user, m = out } or nil
end
-- One control's name across computers: "T-x|v", "T-x|p", "T-x|m", "T-x|x<band fx>:<param>".
function controllers.key(m) return m.o .. "|" .. m.k .. (m.k == "x" and (m.f .. ":" .. m.n) or "") end
-- The mirror object a move changes: the track, or its plug-ins (F-x).
function controllers.object(m) return m.k == "x" and ("F" .. m.o:sub(2)) or m.o end
-- Does hold x ({ user, s }) beat hold y? The earlier start, then the earlier name: every computer decides the same.
function controllers.wins(x, y) if x.s ~= y.s then return x.s < y.s end return x.user < y.user end
-- A plug-in's place in the band's chain from its place here, and back: this computer's own (translations, drum maps, live hops: their ids
-- in the track's band_local_fx as "<id>for=...", as mirror.track_head_parts reads them) don't count. guids: the chain's FX ids in order; lfx:
-- band_local_fx. -> a 0-based index, or nil (one of yours).
local function own_set(lfx)
  local set = {}
  for g in (lfx or ""):gmatch("({[^}]+})for=") do set[g] = true end
  return set
end
function controllers.band_fx(guids, lfx, i)
  local own = own_set(lfx)
  if not guids[i + 1] or own[guids[i + 1]] then return nil end
  local n = 0
  for k = 1, i do if not own[guids[k]] then n = n + 1 end end
  return n
end
function controllers.here_fx(guids, lfx, bi)
  local own, n = own_set(lfx), -1
  for k, g in ipairs(guids) do
    if not own[g] then n = n + 1; if n == bi then return k - 1 end end
  end
end
-- Words for a control: "Bass volume", "Bass ReaEQ knob 3".
function controllers.words(name, k, fx_name, n)
  if k == "x" then return name .. " " .. (fx_name or "plug-in") .. " knob " .. (n + 1) end
  return name .. " " .. ({ v = "volume", p = "pan", m = "mute" })[k]
end

-- ---- reading and writing REAPER ----------------------------------------------------------------------------------------------------------
local function now() return reaper.time_precise() end
local function tname(tr) return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)) end
local function writing(tr) -- Touch, Write or Latch here (the global override first)
  local g = reaper.GetGlobalAutomationOverride()
  local m = g >= 0 and g or reaper.GetTrackAutomationMode(tr)
  return m >= 2 and m <= 4
end
local function guids(tr)
  local out = {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do out[#out + 1] = reaper.TrackFX_GetFXGUID(tr, i) end
  return out
end
local PARM = { v = "D_VOL", p = "D_PAN", m = "B_MUTE" }

-- ---- state (one Live sync tab per script) ----------------------------------------------------------------------------------------------
-- info: track -> { oid, here (one of this computer's own) }; seen: track -> { v, p, m } as last read or written; knobs: key -> { tr, fx, bf, n, v,
-- at }; mine: key -> { s, at, sent, due, v, tr, word } (moving here); theirs: key -> { user, s, at, g, v, word }; shown: object -> { keys, rev0,
-- rev, at }; was: key -> { tr, fx, n, k, v (before), set (last shown) }; last: key -> { user, s, q } (the newest move come in).
local S = { info = {}, seen = {}, knobs = {}, mine = {}, theirs = {}, shown = {}, was = {}, by_oid = {}, last = {}, info_at = -math.huge, touched = nil,
  said = {}, n_sent = 0, n_shown = 0, n_refused = 0, pub = nil, pub_at = -math.huge, looked = false }
controllers.state = S -- (tests)

function controllers.on(root)
  local ok, t = pcall(function() return require("groups").trusted(root) end)
  return not (ok and type(t) == "table" and t.shared_controllers == false)
end

local function info_of(tr)
  local i = S.info[tr]
  if not i then
    local mirror = require("mirror")
    i = { oid = mirror.track_oid(tr) }
    i.here = i.oid == "" or mirror.local_track(tr)
    if i.oid ~= "" then S.info[tr] = i end -- (a new track has its oid from the next look: asked again till then)
  end
  return i
end
local function read(tr) return { v = reaper.GetMediaTrackInfo_Value(tr, "D_VOL"), p = reaper.GetMediaTrackInfo_Value(tr, "D_PAN"), m = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") } end
-- Set one control, and note it as read, so it never goes back out as yours (no echo).
local function set_value(proj, tr, k, v, fx, n, key)
  if k == "x" then
    reaper.TrackFX_SetParamNormalized(tr, fx, n, v)
    local kn = S.knobs[key]
    local got = reaper.TrackFX_GetParamNormalized(tr, fx, n)
    if kn then kn.v = got end
    S.wrote = S.wrote or {}
    S.wrote[key] = got
    return got
  end
  reaper.SetMediaTrackInfo_Value(tr, PARM[k], v)
  local s = S.seen[tr]
  local got = reaper.GetMediaTrackInfo_Value(tr, PARM[k])
  if s then s[k] = got end
  return got
end
local function value_of(tr, k, fx, n)
  if k == "x" then return reaper.TrackFX_GetParamNormalized(tr, fx, n) end
  return reaper.GetMediaTrackInfo_Value(tr, PARM[k])
end
local function say_once(k, text) if not S.said[k] then S.said[k] = true; band.log(text) end end
local function may(t, user, oid, name, sending)
  if (sending and t.my_can or t.can)(user, name, nil) then return true end
  return require("sync").maker_may(oid, user, name, nil, t.who and t.who.mode, nil, t.who and t.who.is_claimed) == true
end
local function local_mix(proj) return select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" end

-- A change of yours to one control: held by a bandmate (yours goes back), not yours to change (nothing), else it goes out.
local function moved(proj, cfg, tr, oid, k, v, key, fx, bf, n, t, clock)
  local th = S.theirs[key]
  if th and not th.g and clock - th.at < controllers.HELD and not S.mine[key] then
    set_value(proj, tr, k, th.v, fx, n, key)
    say_once("lost " .. key .. th.user .. th.s, th.user .. " has " .. th.word .. ": yours went back (theirs until they let go)")
    return
  end
  local name = tname(tr)
  if not (t and may(t, cfg.user, oid, name, true)) then return end -- (mirror.watch puts it back or holds it)
  if k ~= "m" and k ~= "x" and local_mix(proj) then return end -- (Local mixing: your faders and pan don't go out)
  local m = S.mine[key]
  if not m then
    m = { s = require("direct").shared_now() or os.time(), sent = -math.huge, tr = tr, o = oid, k = k, f = bf, n = n }
    S.mine[key] = m
  end
  m.at, m.v, m.due = clock, v, true
end

-- A fader, pan or mute moved on the web UI's Mixer page (lib/webmixer.lua, which checked who may): a bandmate moving it now keeps it (-> "Bo
-- has Bass volume", nothing set), else it's set here and goes out as a move of yours would (the rate, the let-go and Local mixing as
-- moved() has them). Set from Live sync's tick after controllers.tick, so settle reads it as seen: this is what sends it.
function controllers.web_move(proj, cfg, tr, k, v)
  local inf, clock = info_of(tr), now()
  local key = inf.oid .. "|" .. k
  local th = S.theirs[key]
  if th and not th.g and clock - th.at < controllers.HELD then return th.user .. " has " .. th.word end
  local got = set_value(proj, tr, k, v, nil, nil, key)
  if not inf.here then moved(proj, cfg, tr, inf.oid, k, got, key, nil, nil, nil, controllers.pass, clock) end
end

-- Live sync's tick, after the link's messages: what you moved goes out, holds and shown moves are kept up.
function controllers.tick(proj, cfg, b)
  local clock = now()
  S.looked = false
  controllers.keep(proj, clock) -- (shown moves end even if the studio turned it off meanwhile)
  -- (a mixer, a surface and the last-touched knob act on the tab in front; nothing read otherwise, and a fresh first reading when it's back,
  -- so what the band changed meanwhile isn't taken for moves of yours)
  if not (controllers.on(cfg.root) and require("direct").live_available() and reaper.EnumProjects(-1) == proj
      and #require("direct").peers(cfg, b.song, b.room) > 0) then S.seen, S.knobs, S.mine = {}, {}, {}; return end
  local t = controllers.pass
  if clock - S.info_at > 10 then S.info, S.by_oid, S.info_at = {}, {}, clock end -- (new tracks, a copy given its own oid)
  -- the faders, pans and mutes
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local inf = info_of(tr)
    if not inf.here then
      S.by_oid[inf.oid] = tr
      local now_v, was = read(tr), S.seen[tr]
      S.seen[tr] = now_v
      if was then
        for _, k in ipairs({ "v", "p", "m" }) do
          if now_v[k] ~= was[k] and not (k == "m" and band.track_ext(tr, "band_quiet") ~= "") then -- (quiet only here: lib/producer.lua)
            moved(proj, cfg, tr, inf.oid, k, now_v[k], inf.oid .. "|" .. k, nil, nil, nil, t, clock)
          end
        end
      end
    end
  end
  -- the plug-in knob last touched (any source REAPER counts), and those touched lately
  if reaper.GetTouchedOrFocusedFX then
    local ok, ti, ii, _, fi, pn = reaper.GetTouchedOrFocusedFX(0)
    local tk = ok and table.concat({ ti, ii, fi, pn }, ":") or ""
    if S.touched == nil then S.touched = tk -- (touched before Live sync looked: not a move)
    elseif tk ~= S.touched then
      S.touched = tk
      local tr = ok and ti >= 0 and ii < 0 and fi < 0x1000000 and reaper.GetTrack(proj, ti)
      local inf = tr and info_of(tr)
      local bf = inf and not inf.here and controllers.band_fx(guids(tr), band.track_ext(tr, "band_local_fx"), fi)
      local playing = reaper.GetPlayStateEx(proj) & 1 == 1
      -- (not one an envelope plays or a modulator moves: those move by themselves)
      if bf and not (playing and reaper.GetFXEnvelope(tr, fi, pn, false)) and select(2, reaper.TrackFX_GetNamedConfigParm(tr, fi, "param." .. pn .. ".mod.active")) ~= "1" then
        local key = inf.oid .. "|x" .. bf .. ":" .. pn
        local v = reaper.TrackFX_GetParamNormalized(tr, fi, pn)
        local fresh = not S.knobs[key]
        S.knobs[key] = { tr = tr, fx = fi, bf = bf, n = pn, v = v, at = clock, oid = inf.oid }
        -- (just touched: it moved, unless it's the value this computer just set from a bandmate's move)
        if fresh and not (S.wrote and S.wrote[key] == v) then moved(proj, cfg, tr, inf.oid, "x", v, key, fi, bf, pn, t, clock) end
      end
    end
  end
  for key, kn in pairs(S.knobs) do
    if not reaper.ValidatePtr2(proj, kn.tr, "MediaTrack*") or clock - kn.at > controllers.WATCH then S.knobs[key] = nil
    else
      local v = reaper.TrackFX_GetParamNormalized(kn.tr, kn.fx, kn.n)
      if v ~= kn.v then kn.v, kn.at = v, clock; moved(proj, cfg, kn.tr, kn.oid, "x", v, key, kn.fx, kn.bf, kn.n, t, clock) end
    end
  end
  -- what goes: each moving control's latest value, at most every RATE s; let go after LET_GO s still. Nothing while the link is behind on a
  -- peer (its window of unanswered messages full): the latest values stay due and go once it's caught up, never a queue of old ones
  local out = {}
  local behind = next(S.mine) ~= nil and require("direct").behind()
  for key, m in pairs(S.mine) do
    if behind or #out >= controllers.MAX then break end
    local go = m.due and clock - m.sent >= controllers.RATE
    local gone = not m.due and clock - m.at >= controllers.LET_GO
    if go or gone then
      local tr_ok = reaper.ValidatePtr2(proj, m.tr, "MediaTrack*")
      m.q = (m.q or 0) + 1
      out[#out + 1] = { o = m.o, k = m.k, v = m.v, s = m.s, q = m.q, f = m.f, n = m.n, g = gone and 1 or nil,
        a = tr_ok and writing(m.tr) and reaper.GetPlayStateEx(proj) & 1 == 1 and 1 or nil }
      m.sent, m.due = clock, false
      if gone then S.mine[key] = nil end
    end
  end
  if #out > 0 then
    S.n_sent = S.n_sent + #out
    require("direct").send_live(cfg, "ctl", { user = cfg.user, m = out }, b.song, b.room)
  end
  S.looked = true
end

-- Live sync's tick, at its end: what StudioSync itself wrote this tick (a received change, a put-back, a mix given back) read as it is now, so
-- it isn't taken for a move of yours. Every tick it read: not all of those writes move the project's change count.
function controllers.settle(proj)
  if not S.looked then return end
  for tr in pairs(S.seen) do
    if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then S.seen[tr] = read(tr) else S.seen[tr] = nil end
  end
  for key, kn in pairs(S.knobs) do
    if reaper.ValidatePtr2(proj, kn.tr, "MediaTrack*") then kn.v = reaper.TrackFX_GetParamNormalized(kn.tr, kn.fx, kn.n) else S.knobs[key] = nil end
  end
end

-- A bandmate's moves (Live sync's live_handlers.ctl).
function controllers.on_msg(proj, cfg, b, d)
  local c = controllers.clean(d, cfg.user)
  local t = controllers.pass
  if not c or not t or not controllers.on(cfg.root) then return end
  local mirror, clock = require("mirror"), now()
  for _, m in ipairs(c.m) do
    local key, obj = controllers.key(m), controllers.object(m)
    -- (an older move of this hold than one already come in: never applied after it)
    local last = S.last[key]
    local stale = m.q and last and last.user == c.user and last.s == m.s and m.q <= last.q
    if m.q and not stale then S.last[key] = { user = c.user, s = m.s, q = m.q } end
    local tr = not stale and S.by_oid[m.o] or nil -- (stale: no track, so nothing below shows it)
    if not stale and not (tr and reaper.ValidatePtr2(proj, tr, "MediaTrack*")) then tr = mirror.find(proj, "track", m.o); S.by_oid[m.o] = tr end
    local inf = tr and info_of(tr)
    local name = tr and tname(tr)
    local fx = tr and m.k == "x" and controllers.here_fx(guids(tr), band.track_ext(tr, "band_local_fx"), m.f)
    local ok = inf and not inf.here and (m.k ~= "x" or (fx and m.n < reaper.TrackFX_GetNumParams(tr, fx)))
    if ok and not may(t, c.user, m.o, name, false) then
      ok = false
      S.n_refused = S.n_refused + 1
      say_once("refused " .. c.user .. m.o, c.user .. "'s moves on " .. name .. " aren't shown here: it isn't theirs to change")
    end
    -- (not into an envelope, not over an unsent change of yours, not your own faders and pan under Local mixing)
    ok = ok and not writing(tr) and not mirror.unsent[tostring(proj) .. obj] and not (m.k ~= "m" and m.k ~= "x" and local_mix(proj))
    local hold = { user = c.user, s = m.s }
    local mine, th = S.mine[key], S.theirs[key]
    if ok and mine and controllers.wins({ user = cfg.user, s = mine.s }, hold) then ok = false end -- (yours: theirs goes back on their side)
    if ok and th and th.user ~= c.user and not th.g and clock - th.at < controllers.HELD and controllers.wins(th, hold) then ok = false end
    if ok then
      S.mine[key] = nil -- (theirs from now on: a move of yours goes back to it)
      local word = th and th.user == c.user and th.word or controllers.words(name, m.k, fx and select(2, reaper.TrackFX_GetFXName(tr, fx, "")), m.n)
      S.theirs[key] = { user = c.user, s = m.s, at = clock, g = m.g, v = m.v, word = word, a = m.a }
      S.was[key] = S.was[key] or { tr = tr, k = m.k, fx = fx, n = m.n, v = value_of(tr, m.k, fx, m.n) }
      S.was[key].set = set_value(proj, tr, m.k, m.v, fx, m.n, key)
      local rev = mirror.known(proj, obj)
      local sh = S.shown[obj] or { keys = {}, rev0 = rev }
      sh.keys[key], sh.rev, sh.at = true, rev, clock
      S.shown[obj] = sh
      mirror.previewing[tostring(proj) .. obj] = true
      S.n_shown = S.n_shown + 1
    end
  end
end

-- Holds and shown moves, each tick: a bandmate's hold ends at their let-go or HELD s; a shown move ends when the band's change for it lands
-- (its revision moved since the last move shown), or after CONFIRM s with nothing from the band (the value before it back).
function controllers.keep(proj, clock)
  local mirror = require("mirror")
  for key, th in pairs(S.theirs) do if th.g or clock - th.at >= controllers.HELD then S.theirs[key] = nil end end
  for obj, sh in pairs(S.shown) do
    local active = false
    for key in pairs(sh.keys) do active = active or S.theirs[key] ~= nil end
    local rev = mirror.known(proj, obj)
    local done = not active and (rev ~= sh.rev or clock - sh.at > controllers.CONFIRM)
    if done then
      if rev == sh.rev0 then -- (nothing from the band at all: what it was comes back, unless something else changed it since)
        for key in pairs(sh.keys) do
          local w = S.was[key]
          if w and reaper.ValidatePtr2(proj, w.tr, "MediaTrack*") and value_of(w.tr, w.k, w.fx, w.n) == w.set then set_value(proj, w.tr, w.k, w.v, w.fx, w.n, key) end
        end
        band.log("a bandmate's live move wasn't followed by their change: put back as it was")
      end
      for key in pairs(sh.keys) do S.was[key] = nil end
      S.shown[obj] = nil
      mirror.previewing[tostring(proj) .. obj] = nil
    end
  end
  -- (for Health in the panel: who's moving what, once a second at most and when it changed)
  if clock - S.pub_at >= 1 then
    S.pub_at = clock
    local held = {}
    for _, th in pairs(S.theirs) do held[#held + 1] = th.user .. (th.a and " writing automation on " or " moving ") .. th.word end
    table.sort(held)
    local v = band.json_encode({ held = held, sent = S.n_sent, shown = S.n_shown, refused = S.n_refused })
    if v ~= S.pub then S.pub = v; reaper.SetExtState(band.SECTION, "live controls", v, false) end
  end
end

-- ---- Health and Settings (the panel) ---------------------------------------------------------------------------------------------------
function controllers.health_row(cfg)
  if not controllers.on(cfg.root) then return { "controllers", true, "grey", "Shared controllers: off for this studio.", "" } end
  local st = band.json_decode(reaper.GetExtState(band.SECTION, "live controls"))
  if type(st) ~= "table" then return { "controllers", true, "grey", "Shared controllers: on (faders, pan, mute and plug-in knobs move live for everyone here while Live sync runs).", "" } end
  local parts = { "Shared controllers: " .. (#(st.held or {}) > 0 and table.concat(st.held, "; ") or "on") }
  parts[#parts + 1] = string.format("%d moves sent, %d shown", tonumber(st.sent) or 0, tonumber(st.shown) or 0)
  if (tonumber(st.refused) or 0) > 0 then parts[#parts + 1] = st.refused .. " refused (not theirs to change)" end
  local text = table.concat(parts, "; ")
  return { "controllers", (tonumber(st.refused) or 0) == 0, "yellow", text, text }
end
function controllers.studio_ui(ctx, ImGui, cfg, may_set)
  local on = controllers.on(cfg.root)
  if may_set then
    local ch, v = ImGui.Checkbox(ctx, "Shared controllers##studioctl", on)
    if ch then
      require("groups").edit(cfg.root, function(j) if v then j.shared_controllers = nil else j.shared_controllers = false end end)
      band.log(v and "shared controllers are on for the studio" or "shared controllers are off for the studio: faders and knobs reach the others with the normal sync")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. A fader, pan, mute or plug-in knob moved on any computer (mouse, control surface, MIDI controller) " ..
      "moves on everyone's within ~50 ms; the normal sync still records it. Only what that person may change.")
  else
    ImGui.TextDisabled(ctx, "Shared controllers: " .. (on and "on" or "off") .. " (owner and admins)")
  end
end

return controllers
