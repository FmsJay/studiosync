-- Live keys (docs/rt/rt-vmidi.md): a phone's or browser's on-screen keys, drum pads or plugged-in MIDI controller playing a track's instrument
-- in this REAPER in real time, through the web UI (the phone app's Play view, lib/webui/vkeys.js and phonedaw.js). The page sends the notes as
-- they're played ({ topic = "phonedaw", keys = { track, sid, on, ev = { { status, data1, data2, seq } }, panic } }), and here they go into
-- REAPER's virtual MIDI keyboard queue (StuffMIDIMessage mode 0), which REAPER plays on armed, monitored tracks whose input is the virtual
-- keyboard. So while a page plays a track, that track is armed with monitoring on and its input set to the virtual keyboard (all channels):
-- the way REAPER plays its own on-screen keyboard, in real time (a track that isn't armed is rendered ahead, up to the render-ahead time
-- late). Arm, input and monitoring are this computer's own (mirror doesn't send them), and they're put back as they were when the page stops,
-- goes quiet, picks another track, loses the room's say-so or Live sync stops, unless someone changed them here meanwhile.
--   Who may: the track's rule, as the Mixer page asks it (lib/dawedit.lua item_refusal: the room's for the track's name, its maker's while
--   nobody has claimed it); this computer's own tracks (the Real time track, live views) never.
--   Stuck notes: every note held is remembered here; all notes off (each held note's off, sustain up, CC 123) when the page says so (it hides,
--   the link drops on its side), when it's quiet for GRACE s with notes held, on a refusal, a track change and at Live sync's exit.
--   Order: a page sends each touch at once, so two can overtake each other on the way (several connections): each event carries the page's
--   sequence number and one older than the last applied for the same note or controller is dropped (an off that overtook its on stays off).
--   Latency: the topic phonekeys says the last sequence number applied, so the page times the round trip and shows it.
--   Channels: each page playing gets a MIDI channel of its own on the virtual keyboard (1-16; the pads' channel 10 where it's free), the track's
--   input is "virtual keyboard, that channel", and its notes go in on that channel whatever channel the page played them on: so two phones play
--   two tracks at once, and neither hears the other. A page that plays a track another page holds takes it, and the other stops. (rt-p5)
--   Program changes go through, on the page's channel (a controller's; nothing sets one from the screen).
-- shortcut: tracks armed on "All MIDI inputs" (or the virtual keyboard on any channel they share) still hear a page's notes: that's REAPER's
-- own routing, said on the page ("also"). (James, rt)
local livekeys = {}
livekeys.GRACE = 3       -- seconds without a word from the page, with notes held, before all notes off
livekeys.IDLE = 30       -- seconds without a word before the track is put back as it was
livekeys.AUTH_EVERY = 1  -- seconds between asking again who may play the track
livekeys.EV_MAX = 64     -- events in one action
livekeys.VKB = 62        -- REAPER's virtual MIDI keyboard, as a MIDI input device
livekeys.INPUT = 4096 + (livekeys.VKB << 5) -- I_RECINPUT: MIDI, the virtual keyboard, all channels
livekeys.STOPPED_KEEP = 60 -- seconds a page that stopped is still told why
-- I_RECINPUT for the virtual keyboard on channel ch (1-16; 0: all). Pure.
function livekeys.input(ch) return livekeys.INPUT + (math.floor(tonumber(ch) or 0) & 31) end
-- Which channel a page gets: the pads' channel 10 where it's free (General MIDI drums), else the first free one; nil when all 16 are taken.
-- used: { [ch] = true }. Pure.
function livekeys.pick_channel(used, pads)
  if pads and not used[10] then return 10 end
  for _, c in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 10 }) do if not used[c] then return c end end
end

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local KINDS = { [0x80] = true, [0x90] = true, [0xA0] = true, [0xB0] = true, [0xC0] = true, [0xD0] = true, [0xE0] = true } -- (program changes now; no system messages)
local ONE_BYTE = { [0xC0] = true, [0xD0] = true } -- (program change, channel pressure: one data byte)
local function byte(x) x = tonumber(x); return x and x >= 0 and x <= 127 and math.floor(x) == x and math.floor(x) or nil end
local function guid_ok(g) return type(g) == "string" and g:match("^{[%x%-]+}$") and #g <= 40 end
-- What a page sent (a trust boundary) -> { track, sid, on, panic, ev = { { st, d1, d2, seq } } }, or nil and why.
function livekeys.parse(k)
  if type(k) ~= "table" then return nil, "not a keys message" end
  local out = { on = k.on ~= false, panic = k.panic == true or nil, ev = {} }
  out.track = guid_ok(k.track) and k.track or nil
  out.sid = type(k.sid) == "string" and #k.sid <= 24 and k.sid:match("^[%w%-]+$") and k.sid or nil
  out.pads = k.pads == true or nil -- (the page is playing drum pads: it would like channel 10)
  if out.on and not (out.track and out.sid) then return nil, "no track or page named" end
  local ev = k.ev
  if ev ~= nil and (type(ev) ~= "table" or #ev > livekeys.EV_MAX) then return nil, "too many notes at once" end
  for _, e in ipairs(ev or {}) do
    local st, seq = type(e) == "table" and tonumber(e[1]), type(e) == "table" and tonumber(e[4])
    local d1, d2 = type(e) == "table" and byte(e[2]), type(e) == "table" and byte(e[3])
    if st and ONE_BYTE[st & 0xF0] then d2 = d2 or 0 end
    if st and st == math.floor(st) and KINDS[st & 0xF0] and st <= 0xEF and d1 and d2 and seq and seq >= 0 and seq < 2 ^ 40 and seq == math.floor(seq) then
      out.ev[#out.ev + 1] = { st, d1, d2, seq }
    end
  end
  return out
end
-- What an event is about, for its order: a note (on, off, its pressure), a controller, or the channel's bend / pressure. Pure.
function livekeys.slot(st, d1)
  local kind, ch = st & 0xF0, st & 15
  if kind == 0x80 or kind == 0x90 or kind == 0xA0 then return ch * 128 + d1 end
  if kind == 0xB0 then return 2048 + ch * 128 + d1 end
  return 4096 + kind + ch
end
-- One event onto what's held ({ [ch*128+note] = true, sus = { [ch] = true }, chans = { [ch] = true } }). Pure.
function livekeys.hold(held, st, d1, d2)
  local kind, ch = st & 0xF0, st & 15
  held.sus, held.chans = held.sus or {}, held.chans or {}
  held.chans[ch] = true
  if kind == 0x90 and d2 > 0 then held[ch * 128 + d1] = true
  elseif kind == 0x80 or kind == 0x90 then held[ch * 128 + d1] = nil
  elseif kind == 0xB0 and d1 == 64 then held.sus[ch] = d2 >= 64 or nil end
end
-- Everything that lets go of what's held: each note's off, sustain up, all notes off on each channel used. Pure. -> { { st, d1, d2 } }
function livekeys.release(held)
  local out, keys = {}, {}
  for k in pairs(held) do if type(k) == "number" then keys[#keys + 1] = k end end
  table.sort(keys)
  for _, k in ipairs(keys) do out[#out + 1] = { 0x80 | (k // 128), k % 128, 0 } end
  local chans = {}
  for ch in pairs(held.chans or {}) do chans[#chans + 1] = ch end
  table.sort(chans)
  for _, ch in ipairs(chans) do
    out[#out + 1] = { 0xB0 | ch, 64, 0 }
    out[#out + 1] = { 0xB0 | ch, 123, 0 }
  end
  return out
end
-- Does a track's record input take the virtual keyboard (it, or all MIDI inputs), on channel ch when given (its own channel filter lets it through)? Pure.
function livekeys.takes_vkb(input, ch)
  input = math.floor(tonumber(input) or -1)
  if input < 4096 then return false end
  local dev, chan = (input >> 5) & 63, input & 31
  return (dev == livekeys.VKB or dev == 63) and (ch == nil or chan == 0 or chan == ch)
end

-- ---- REAPER ----------------------------------------------------------------------------------------------------------------------------
-- One entry per page (its sid): { sid, tr, guid, ch, saved, held, last, seq, heard, name, also, why, stopped }. guid is nil once it has stopped (why
-- and stopped stay a while, so the page hears why).
local S = { pages = {} }
function livekeys.reset() S = { pages = {} } end -- (tests)
local function stuff(st, d1, d2) reaper.StuffMIDIMessage(0, st, d1, d2) end
local function let_go(P)
  for _, e in ipairs(livekeys.release(P.held or {})) do stuff(e[1], e[2], e[3]) end
  P.held = {}
end
local function track_of(proj, guid)
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if reaper.GetTrackGUID(tr) == guid then return tr end
  end
end
local function getv(tr, k) return reaper.GetMediaTrackInfo_Value(tr, k) end
local function channels_used(except)
  local used = {}
  for _, P in pairs(S.pages) do if P.guid and P ~= except and P.ch then used[P.ch] = true end end
  return used
end
-- Armed, monitored, on the virtual keyboard (this page's channel): what was there kept to put back.
local function take(P, tr)
  local input = livekeys.input(P.ch)
  P.saved = { arm = getv(tr, "I_RECARM"), input = getv(tr, "I_RECINPUT"), mon = getv(tr, "I_RECMON") }
  if P.saved.input ~= input then reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", input) end
  if P.saved.mon ~= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1) end
  if P.saved.arm ~= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1) end
end
-- Put back what was there, each part only while it's still what this set (someone here may have changed it meanwhile).
local function put_back(P)
  local tr, s = P.tr, P.saved
  if tr and s and reaper.ValidatePtr2(0, tr, "MediaTrack*") then
    if getv(tr, "I_RECARM") == 1 and s.arm ~= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", s.arm) end
    if getv(tr, "I_RECMON") == 1 and s.mon ~= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", s.mon) end
    local mine = livekeys.input(P.ch)
    if getv(tr, "I_RECINPUT") == mine and s.input ~= mine then reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", s.input) end
  end
  P.tr, P.guid, P.saved, P.name, P.ch = nil, nil, nil, nil, nil
end
local function stop(P, why)
  let_go(P)
  put_back(P)
  P.why, P.stopped = why, reaper.time_precise()
end
-- The other armed tracks the virtual keyboard reaches too on this page's channel (their input is it, or all MIDI inputs): said on the page.
local function also(proj, tr, ch)
  local out = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local t = reaper.GetTrack(proj, i)
    if t ~= tr and getv(t, "I_RECARM") == 1 and getv(t, "I_RECMON") > 0 and livekeys.takes_vkb(getv(t, "I_RECINPUT"), ch) then
      out[#out + 1] = select(2, reaper.GetTrackName(t))
      if #out >= 8 then break end
    end
  end
  return next(out) and out or nil
end
-- The room's rule now, asked again at most every AUTH_EVERY s (or at once with force).
local function rule(cfg, b, now, force)
  if force or not S.can or now - (S.auth_at or -math.huge) >= livekeys.AUTH_EVERY then S.can, S.who = require("dawedit").authority(cfg, b); S.auth_at = now end
end
-- -> nil, or why this computer's user may not play track tr.
local function refusal(cfg, b, tr, now)
  local mirror, dawedit = require("mirror"), require("dawedit")
  if mirror.local_track and mirror.local_track(tr) then return "that's this computer's own track" end
  rule(cfg, b, now)
  return dawedit.item_refusal(S.can, S.who, cfg.user, select(2, reaper.GetTrackName(tr)), mirror.track_oid(tr), nil, nil)
end

-- An action from a page (through lib/phonedaw.lua). -> words for the log, or nil (notes aren't logged).
function livekeys.action(proj, cfg, b, k)
  local now = reaper.time_precise()
  local d, why = livekeys.parse(k)
  if not d then return "the page's notes weren't played: " .. why end
  local P = d.sid and S.pages[d.sid]
  if not d.on then
    if P and P.guid then stop(P, nil); return "the page stopped playing the track" end
    return
  end
  if not P then
    local n = 0
    for sid, Q in pairs(S.pages) do
      if not Q.guid and now - (Q.stopped or now) > livekeys.STOPPED_KEEP then S.pages[sid] = nil else n = n + 1 end
    end
    if n >= 16 then return "the page's notes weren't played: 16 pages are playing" end
    P = { sid = d.sid, seq = nil }
    S.pages[d.sid] = P
  end
  local tr = track_of(proj, d.track)
  if not tr then stop(P, "that track isn't in the project open here"); return end
  why = refusal(cfg, b, tr, now)
  if why then
    if P.guid then stop(P, why) else P.why, P.stopped = why, now end
    return "the page may not play that track: " .. why
  end
  local said
  if P.guid ~= d.track or P.tr ~= tr then
    if P.guid then let_go(P); put_back(P) end
    for _, Q in pairs(S.pages) do -- (a track one page holds: the page that asks for it now has it)
      if Q ~= P and Q.guid and Q.tr == tr then stop(Q, "another page took this track") end
    end
    P.ch = livekeys.pick_channel(channels_used(P), d.pads)
    if not P.ch then P.why, P.stopped = "all 16 virtual keyboard channels are in use", now; return "the page's notes weren't played: no free channel" end
    P.tr, P.guid, P.held, P.last, P.seq = tr, d.track, {}, {}, nil
    P.name = select(2, reaper.GetTrackName(tr))
    take(P, tr)
    P.also = also(proj, tr, P.ch)
    said = "a web page is playing " .. P.name .. " live (armed, on the virtual keyboard channel " .. P.ch .. ", until it stops)"
  end
  P.heard, P.why = now, nil
  for _, e in ipairs(d.ev) do
    local st = (e[1] & 0xF0) | (P.ch - 1) -- (every event on the page's own channel)
    local slot = livekeys.slot(st, e[2])
    if not P.last[slot] or e[4] > P.last[slot] then
      P.last[slot] = e[4]
      stuff(st, e[2], e[3])
      livekeys.hold(P.held, st, e[2], e[3])
    end
    if not P.seq or e[4] > P.seq then P.seq = e[4] end
  end
  if d.panic then let_go(P) end
  return said
end

-- Each tick in front (lib/webui.lua, whether or not a page is looking: a page that went away must still let go).
function livekeys.tick(proj, cfg, b, publish, now)
  local fresh = now - (S.auth_at or -math.huge) >= livekeys.AUTH_EVERY
  if fresh and next(S.pages) then rule(cfg, b, now, true) end
  local topic = {}
  for sid, P in pairs(S.pages) do
    if P.guid then
      if not reaper.ValidatePtr2(proj, P.tr, "MediaTrack*") then P.tr = nil; stop(P, "the track was deleted")
      elseif now - (P.heard or now) > livekeys.IDLE then stop(P, nil)
      else
        if next(P.held or {}) and now - (P.heard or now) > livekeys.GRACE then let_go(P) end -- (the page went quiet: hidden, or no network)
        local why = fresh and refusal(cfg, b, P.tr, now)
        if why then stop(P, why) end
      end
    end
    if not P.guid and now - (P.stopped or now) > livekeys.STOPPED_KEEP then S.pages[sid] = nil
    else topic[sid] = { sid = sid, seq = P.seq, track = P.guid, name = P.name, why = P.why, ch = P.ch, also = P.guid and P.also or nil } end
  end
  if next(topic) or S.published then publish("phonekeys", { pages = topic }) end -- (nothing until a page has played; once more when the last is forgotten)
  S.published = next(topic) ~= nil
end

-- Live sync stopping: nothing left sounding, the tracks as they were.
function livekeys.on_exit()
  for _, P in pairs(S.pages) do if P.guid then stop(P, nil) end end
end

return livekeys
