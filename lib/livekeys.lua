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
-- shortcut: one track at a time per computer (a second page or track takes over and the first stops), as the virtual keyboard is one bus; per
-- page channels would let two phones play two tracks, when bands ask for it. (James, rt)
local livekeys = {}
livekeys.GRACE = 3       -- seconds without a word from the page, with notes held, before all notes off
livekeys.IDLE = 30       -- seconds without a word before the track is put back as it was
livekeys.AUTH_EVERY = 1  -- seconds between asking again who may play the track
livekeys.EV_MAX = 64     -- events in one action
livekeys.VKB = 62        -- REAPER's virtual MIDI keyboard, as a MIDI input device
livekeys.INPUT = 4096 + (livekeys.VKB << 5) -- I_RECINPUT: MIDI, the virtual keyboard, all channels

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local KINDS = { [0x80] = true, [0x90] = true, [0xA0] = true, [0xB0] = true, [0xD0] = true, [0xE0] = true } -- (no program changes or system)
local function byte(x) x = tonumber(x); return x and x >= 0 and x <= 127 and math.floor(x) == x and math.floor(x) or nil end
local function guid_ok(g) return type(g) == "string" and g:match("^{[%x%-]+}$") and #g <= 40 end
-- What a page sent (a trust boundary) -> { track, sid, on, panic, ev = { { st, d1, d2, seq } } }, or nil and why.
function livekeys.parse(k)
  if type(k) ~= "table" then return nil, "not a keys message" end
  local out = { on = k.on ~= false, panic = k.panic == true or nil, ev = {} }
  out.track = guid_ok(k.track) and k.track or nil
  out.sid = type(k.sid) == "string" and #k.sid <= 24 and k.sid:match("^[%w%-]+$") and k.sid or nil
  if out.on and not (out.track and out.sid) then return nil, "no track or page named" end
  local ev = k.ev
  if ev ~= nil and (type(ev) ~= "table" or #ev > livekeys.EV_MAX) then return nil, "too many notes at once" end
  for _, e in ipairs(ev or {}) do
    local st, seq = type(e) == "table" and tonumber(e[1]), type(e) == "table" and tonumber(e[4])
    local d1, d2 = type(e) == "table" and byte(e[2]), type(e) == "table" and byte(e[3])
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
-- Does a track's record input take the virtual keyboard (it, or all MIDI inputs)? Pure.
function livekeys.takes_vkb(input)
  input = math.floor(tonumber(input) or -1)
  if input < 4096 then return false end
  local dev = (input >> 5) & 63
  return dev == livekeys.VKB or dev == 63
end

-- ---- REAPER ----------------------------------------------------------------------------------------------------------------------------
local S = {}
function livekeys.reset() S = {} end -- (tests)
local function stuff(st, d1, d2) reaper.StuffMIDIMessage(0, st, d1, d2) end
local function let_go()
  for _, e in ipairs(livekeys.release(S.held or {})) do stuff(e[1], e[2], e[3]) end
  S.held = {}
end
local function track_of(proj, guid)
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if reaper.GetTrackGUID(tr) == guid then return tr end
  end
end
local function getv(tr, k) return reaper.GetMediaTrackInfo_Value(tr, k) end
-- Armed, monitored, on the virtual keyboard: what was there kept to put back.
local function take(tr)
  S.saved = { arm = getv(tr, "I_RECARM"), input = getv(tr, "I_RECINPUT"), mon = getv(tr, "I_RECMON") }
  if S.saved.input ~= livekeys.INPUT then reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", livekeys.INPUT) end
  if S.saved.mon ~= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1) end
  if S.saved.arm ~= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1) end
end
-- Put back what was there, each part only while it's still what this set (someone here may have changed it meanwhile).
local function put_back()
  local tr, s = S.tr, S.saved
  if tr and s and reaper.ValidatePtr2(0, tr, "MediaTrack*") then
    if getv(tr, "I_RECARM") == 1 and s.arm ~= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", s.arm) end
    if getv(tr, "I_RECMON") == 1 and s.mon ~= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", s.mon) end
    if getv(tr, "I_RECINPUT") == livekeys.INPUT and s.input ~= livekeys.INPUT then reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", s.input) end
  end
  S.tr, S.guid, S.saved, S.name = nil, nil, nil, nil
end
local function stop(why)
  let_go()
  put_back()
  S.why = why
end
-- The other armed tracks the virtual keyboard reaches too (their input is it, or all MIDI inputs): said on the page.
local function also(proj, tr)
  local out = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local t = reaper.GetTrack(proj, i)
    if t ~= tr and getv(t, "I_RECARM") == 1 and getv(t, "I_RECMON") > 0 and livekeys.takes_vkb(getv(t, "I_RECINPUT")) then
      out[#out + 1] = select(2, reaper.GetTrackName(t))
      if #out >= 8 then break end
    end
  end
  return next(out) and out or nil
end
-- -> nil, or why this computer's user may not play track tr.
local function refusal(cfg, b, tr, now)
  local mirror, dawedit = require("mirror"), require("dawedit")
  if mirror.local_track and mirror.local_track(tr) then return "that's this computer's own track" end
  if not S.can or now - (S.auth_at or -math.huge) >= livekeys.AUTH_EVERY then S.can, S.who = dawedit.authority(cfg, b); S.auth_at = now end
  return dawedit.item_refusal(S.can, S.who, cfg.user, select(2, reaper.GetTrackName(tr)), mirror.track_oid(tr), nil, nil)
end

-- An action from a page (through lib/phonedaw.lua). -> words for the log, or nil (notes aren't logged).
function livekeys.action(proj, cfg, b, k)
  local now = reaper.time_precise()
  local d, why = livekeys.parse(k)
  if not d then S.why = why; return "the page's notes weren't played: " .. why end
  if not d.on then
    if S.guid and (not d.sid or d.sid == S.sid) then stop(nil); return "the page stopped playing the track" end
    return
  end
  local tr = track_of(proj, d.track)
  if not tr then stop("that track isn't in the project open here"); return end
  why = refusal(cfg, b, tr, now)
  if why then
    if S.guid then stop(why) else S.why = why end
    S.sid = d.sid
    return "the page may not play that track: " .. why
  end
  local said
  if S.guid ~= d.track or S.tr ~= tr then
    if S.guid then let_go(); put_back() end
    S.tr, S.guid, S.held, S.last = tr, d.track, {}, {}
    S.name = select(2, reaper.GetTrackName(tr))
    take(tr)
    S.also = also(proj, tr)
    said = "a web page is playing " .. S.name .. " live (armed, on the virtual keyboard, until it stops)"
  end
  if S.sid ~= d.sid then let_go(); S.sid, S.last, S.seq = d.sid, {}, nil end -- (another page, or this one reloaded: its own count)
  S.heard, S.why = now, nil
  for _, e in ipairs(d.ev) do
    local slot = livekeys.slot(e[1], e[2])
    if not S.last[slot] or e[4] > S.last[slot] then
      S.last[slot] = e[4]
      stuff(e[1], e[2], e[3])
      livekeys.hold(S.held, e[1], e[2], e[3])
    end
    if not S.seq or e[4] > S.seq then S.seq = e[4] end
  end
  if d.panic then let_go() end
  return said
end

-- Each tick in front (lib/webui.lua, whether or not a page is looking: a page that went away must still let go).
function livekeys.tick(proj, cfg, b, publish, now)
  if S.guid then
    if not reaper.ValidatePtr2(proj, S.tr, "MediaTrack*") then S.tr = nil; stop("the track was deleted")
    elseif now - (S.heard or now) > livekeys.IDLE then stop(nil)
    else
      if next(S.held or {}) and now - (S.heard or now) > livekeys.GRACE then let_go() end -- (the page went quiet: hidden, or no network)
      local why = now - (S.auth_at or -math.huge) >= livekeys.AUTH_EVERY and refusal(cfg, b, S.tr, now)
      if why then stop(why) end
    end
  end
  if S.sid or S.why then -- (nothing until a page has played)
    publish("phonekeys", { sid = S.sid, seq = S.seq, track = S.guid, name = S.name, why = S.why, also = S.guid and S.also or nil })
  end
end

-- Live sync stopping: nothing left sounding, the track as it was.
function livekeys.on_exit()
  if S.guid then stop(nil) end
end

return livekeys
