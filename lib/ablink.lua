-- The Ableton Link bridge (James, rt: docs/realtime-roadmap.md "Decisions and additions", docs/tools-research.md #10).
-- Link keeps tempo, beat phase and start/stop together between apps on one network (Ableton Live, phone groove boxes, drum machines);
-- ReaBlink (ak5k, MIT, its API is Blink_*) puts REAPER on a Link session. Two halves:
--  1. This computer joins its local Link session (Settings > Advanced, only on this computer, off by default).
--     - Tempo: REAPER's tempo goes to Link whenever it changes (the song's map, or the playhead passing a tempo marker), and while REAPER
--       plays Link keeps REAPER's tempo. A Link app's tempo change becomes the song's tempo only when this person may change the song's
--       timeline (the driver, Anyone mode, or alone; not holding changes), nobody is recording, and the song has one tempo. It then syncs as
--       any tempo change does: this edits the map, Live sync's watch_timeline sees it and sends it in the "timeline" event
--       (sync.TIMELINE_FORMAT), so every REAPER gets the same map by the same path. Otherwise it's put back on Link, as watch_timeline puts a
--       tempo change back that isn't yours to make: the song's tempo stays the studio's, and Link stays in step with it.
--     - Phase: while REAPER plays it leads: Link's bar lines up with REAPER's bar (Blink_SetBeatAtTimeForce). REAPER never follows Link's
--       phase: Play together pins its playhead to the studio's shared clock, and nudging it (ReaBlink's Puppet changes the playrate and the
--       tempo marker) would pull it off the band and edit the map outside the studio's rules.
--     - Start/stop: REAPER's play and stop start and stop the Link apps here. A Link app's start or stop doesn't start REAPER: Play together
--       owns REAPER's transport.
--  2. Link across the internet. Link only reaches one network; the direct link spans the studio. Every computer with Link on sends its Link
--     state ("ablink" messages, direct.send_live) every 2 s and at once when something changes: tempo, the beat at a moment on the shared
--     clock (direct.shared_now, as Play together times its starts), the quantum, and playing. The leader is whoever changed tempo or
--     start/stop last on their Link (newest stamp on the shared clock); before anyone has, the studio's driver; then the lowest device id.
--     The others' local Link sessions follow the leader, so remote Link apps line up on the bar. While REAPER plays here, REAPER leads this
--     computer's Link instead (the band's REAPERs already share the clock).
--     Feedback: a tempo or start/stop that came from the network (or from REAPER) is marked as ours (ablink.set) and isn't taken for a Link
--     app's change when it shows up, so it never stamps or goes out again; only a computer whose own Link app changed something stamps.
local band = require("band")
local ablink = {}

ablink.KEY = "ablink" -- (ExtState, persisted: "1" joins this computer's Link session)
ablink.EPS = 0.01 -- BPM (and quantum): closer than this is the same (Link hands back floats)
ablink.TOL = 0.02 -- seconds: a phase error past this is fixed; under it is jitter (REAPER's play position moves a block at a time)
ablink.SETTLE = 1 -- seconds a value we set has to show up on Link and still count as ours
ablink.EVERY = 2 -- seconds between bridge messages
ablink.STALE = 8 -- seconds without one before a computer drops out of the bridge
ablink.FORCE_EVERY = 1 -- seconds between phase fixes while REAPER plays (each one jolts the Link apps a little)

function ablink.available() return reaper.APIExists("Blink_GetEnabled") and reaper.APIExists("Blink_SetBeatAtTimeForce") end
function ablink.on() return reaper.GetExtState(band.SECTION, ablink.KEY) == "1" end

-- ---- pure parts (tests/test_0_60_rt_ablink.lua) -------------------------------------------------------------------------------------
function ablink.close(a, b) return type(a) == "number" and type(b) == "number" and math.abs(a - b) < ablink.EPS end
-- How far `have` is ahead of `want` on a cycle of q beats, in (-q/2, q/2]. Phase only means something within a quantum.
function ablink.phase_error(have, want, q)
  local d = (have - want) % q
  if d > q / 2 then d = d - q end
  return d
end
-- A bridge message's beat at shared time `sn` (its tempo held since it was sent: 2 s at most).
function ablink.beat_at(m, sn) return m.beat + (sn - m.at) * m.bpm / 60 end
-- The beat to map to now so Link's phase is `want`'s, or nil when it's already within TOL. Keeps Link's beat count going (only the phase moves).
function ablink.fix(have, want, q, bpm)
  local e = ablink.phase_error(have, want, q)
  if math.abs(e) * 60 / bpm <= ablink.TOL then return nil end
  return have - e
end
-- Echo suppression. tr: { last (what Link showed at the last look), set, prev, til }. ablink.set: we just set v. ablink.seen: Link shows v now ->
-- true when that's a change by a Link app here (not us, not the network), and what it was before.
-- (the one set before counts too: during a tempo ramp REAPER pushes every look, and Link may still show the last push)
function ablink.set(tr, v, now) tr.prev, tr.set, tr.til = tr.set, v, now + ablink.SETTLE end
function ablink.seen(tr, v, now)
  if tr.last == nil then tr.last = v; return false end -- (the first look is where it stands, nobody's change)
  if ablink.close(v, tr.last) then return false end
  local before = tr.last
  tr.last = v
  if tr.til and now < tr.til and (ablink.close(v, tr.set) or ablink.close(v, tr.prev)) then return false, before end -- (ours arriving)
  return true, before
end
-- The bridge's leader. cands: device id -> { user, stamp (shared clock s of its last Link change, or nil), heard (local s), mine }.
-- Newest change leads; with none, the driver's computer; then the lowest device id. Everyone picks the same from the same messages.
function ablink.leader(cands, driver, now)
  local best, bs, bd
  for dev, c in pairs(cands or {}) do
    if c.mine or now - (c.heard or -math.huge) < ablink.STALE then
      local s, d = c.stamp or -math.huge, c.user == driver and 1 or 0
      if not best or s > bs or (s == bs and (d > bd or (d == bd and dev < best))) then best, bs, bd = dev, s, d end
    end
  end
  return best
end
local function num(x) return type(x) == "number" and x == x and x > -math.huge and x < math.huge end
-- A bridge message as it came over the link (a bandmate's computer: checked before anything reaches ReaBlink).
function ablink.valid(d)
  return type(d) == "table" and type(d.dev) == "string" and type(d.user) == "string" and num(d.bpm) and d.bpm >= 20 and d.bpm <= 999
    and num(d.beat) and num(d.at) and num(d.q) and d.q > 0 and d.q <= 64 and type(d.playing) == "boolean"
    and (d.stamp == nil or num(d.stamp)) and (d.play_at == nil or num(d.play_at))
end
-- May a Link app's tempo become the song's? may: this person may change the song's timeline now; tempos: entries in the song's tempo map
-- (band.capture_tempo); recording: anyone here or in the room. -> true, or false and why (said on Health).
function ablink.may_tempo(may, tempos, recording)
  if recording then return false, "a tempo change on Link waits: someone is recording" end -- (never mid-take: the studio didn't choose it)
  if not may then return false, "a tempo change on Link was put back: only the driver changes the song's tempo (Take control first)" end
  if tempos > 1 then return false, "a tempo change on Link was put back: the song has tempo changes, so REAPER's map leads" end
  return true
end
-- Health's line. st: { apps, bpm, lead (the user this computer follows; nil: it leads), others (users on the bridge), phase, clock, note }.
function ablink.health_text(st)
  local apps = tonumber(st.apps) or 0
  local s = string.format("Ableton Link: %d app%s, %.1f BPM", apps, apps == 1 and "" or "s", tonumber(st.bpm) or 0)
  if st.lead then s = s .. (st.phase and ", in phase with " or ", lining up with ") .. st.lead
  elseif type(st.others) == "table" and #st.others > 0 then s = s .. ", leading " .. table.concat(st.others, ", ")
  elseif not st.clock then s = s .. ", this computer only (across the studio it needs the shared clock: StudioSync's extension)" end
  if st.puppet then s = s .. ". ReaBlink's Puppet is on: it edits the tempo map itself, outside the studio's rules. Turn it off in ReaBlink" end
  if st.note then s = s .. ". " .. st.note end
  return s
end

-- ---- Live sync's side (the tab in front drives Link) ----------------------------------------------------------------------------------
local S = { tempo = {}, play = {}, cands = {}, at = -math.huge, sent = -math.huge, forced = -math.huge, said = -math.huge }
local we_enabled -- (ReaBlink switched on by us: we switch it off again, never one the user turned on themselves)
local function shared_now()
  local ok, sn = pcall(function() return require("direct").shared_now() end)
  return ok and sn or nil
end
local function my_dev() return tostring(require("services").my_device_id() or "?") end
local function recording(cfg, b)
  if band.recording_anywhere() then return true end
  for _, st in ipairs(require("presence").peers(cfg, b.song, b.room)) do if st.recording then return true end end
  return false
end
local function push_tempo(v, now) reaper.Blink_SetTempo(v); ablink.set(S.tempo, v, now) end

function ablink.tick(cfg, b, proj)
  local now = reaper.time_precise()
  if now - S.at < 0.1 then return end -- (ten looks a second is plenty: phase is fixed by mapping, not by chasing)
  S.at = now
  if not ablink.on() or not ablink.available() then
    if we_enabled and ablink.available() then reaper.Blink_SetEnabled(false); band.log("Ableton Link: left this computer's Link session") end
    we_enabled = nil
    return
  end
  if reaper.EnumProjects(-1) ~= proj then return end -- (one Link session per computer: the song in front drives it)
  if not reaper.Blink_GetEnabled() then
    reaper.Blink_SetEnabled(true)
    we_enabled = true
    band.log("Ableton Link: joined this computer's Link session (Settings > Advanced)")
  end
  if not S.sync_on then reaper.Blink_SetStartStopSyncEnabled(true); S.sync_on = true end
  local sync = require("sync")
  local link_now, sn = reaper.Blink_GetClockNow(), shared_now()
  local playing = reaper.GetPlayStateEx(proj) & 1 == 1
  local pos = playing and reaper.GetPlayPositionEx(proj) or reaper.GetCursorPositionEx(proj) -- (what's heard now: Link's times are heard times)
  local _, _, r = reaper.TimeMap_GetTimeSigAtTime(proj, pos)
  local inbar, _, cml, _, cdenom = reaper.TimeMap2_timeToBeats(proj, pos)
  local q = cml * 4 / cdenom -- (a bar in quarter notes: Link's phase 0 is the top of REAPER's bar)
  if not ablink.close(q, reaper.Blink_GetQuantum()) then reaper.Blink_SetQuantum(q) end
  -- tempo
  local l = reaper.Blink_GetTempo()
  local app, before = ablink.seen(S.tempo, l, now)
  if S.r and not ablink.close(r, S.r) then
    push_tempo(r, now) -- (REAPER's tempo changed: the driver's map came in or was made here, or the playhead passed a marker. Not bridged: the timeline carries it)
  elseif app then
    local map = band.capture_tempo(proj)
    local ok, why = ablink.may_tempo(sync.timeline_mine, #map, recording(cfg, b))
    if ok then
      map[1].bpm = l
      reaper.Undo_BeginBlock2(proj)
      local aok, e = pcall(band.apply_tempo, proj, map)
      reaper.Undo_EndBlock2(proj, "StudioSync: tempo from Ableton Link", -1)
      if not aok then error(e, 0) end
      r, S.stamp, S.dirty, S.note = l, sn, now, nil
      band.log(string.format("Ableton Link: tempo %.2f BPM from a Link app here, as the song's tempo (it goes to the studio as any tempo change)", l))
    else
      push_tempo(playing and r or before, now)
      S.note = why
      if now - S.said > 10 then S.said = now; band.log("Ableton Link: " .. why) end
    end
  elseif playing and not ablink.close(l, r) then
    push_tempo(r, now) -- (while REAPER plays, Link has REAPER's tempo: a bandmate's Link tempo waits for the timeline to bring it)
  end
  S.r = r
  -- start/stop
  local lp = reaper.Blink_GetPlaying()
  local papp = ablink.seen(S.play, lp and 1 or 0, now)
  if S.rplay ~= nil and playing ~= S.rplay then
    reaper.Blink_SetPlaying(playing, link_now)
    ablink.set(S.play, playing and 1 or 0, now)
    S.stamp, S.play_at, S.dirty = sn, sn, now
  elseif papp then
    S.stamp, S.play_at, S.dirty = sn, sn, now -- (a Link app here started or stopped: the other studio computers' Link apps do too)
  end
  S.rplay = playing
  -- phase: REAPER leads while it plays
  if playing and now - S.forced > ablink.FORCE_EVERY then
    local have = reaper.Blink_GetBeatAtTime(link_now, q)
    local to = ablink.fix(have, inbar * 4 / cdenom, q, r)
    if to then reaper.Blink_SetBeatAtTimeForce(to, link_now, q); S.forced = now end -- (the first argument is a beat, whatever ReaBlink names it)
  end
  -- the bridge
  local me = my_dev()
  S.cands[me] = { user = cfg.user, stamp = S.stamp, mine = true }
  local others = {}
  for _, c in pairs(S.cands) do if not c.mine and now - (c.heard or -math.huge) < ablink.STALE then others[#others + 1] = c.user end end
  table.sort(others)
  if sn and (now - S.sent >= ablink.EVERY or (S.dirty and S.dirty < now)) then -- (a change goes out at the next look, once Link shows it)
    S.sent, S.dirty = now, nil
    pcall(require("direct").send_live, cfg, "ablink", { dev = me, user = cfg.user, bpm = reaper.Blink_GetTempo(), beat = reaper.Blink_GetBeatAtTime(link_now, q),
      at = sn, q = q, playing = reaper.Blink_GetPlaying(), stamp = S.stamp, play_at = S.play_at }, b.song, b.room)
  end
  -- Health's line, for the panel (another script): once a second
  if now - (S.status_at or -math.huge) >= 1 then
    S.status_at = now
    local lead = ablink.leader(S.cands, sync.driver_name, now)
    local lc = lead and lead ~= me and S.cands[lead]
    reaper.SetExtState(band.SECTION, "ablink status", band.json_encode({ at = os.time(), apps = reaper.Blink_GetNumPeers(), bpm = reaper.Blink_GetTempo(),
      lead = lc and not playing and lc.user or nil, phase = S.phase_ok, others = others, clock = sn ~= nil, note = S.note,
      puppet = reaper.APIExists("Blink_GetPuppet") and reaper.Blink_GetPuppet() or nil }), false)
  end
end

-- A bandmate's Link state over the direct link (Live sync's live_handlers.ablink).
function ablink.on_msg(cfg, b, proj, d)
  if not ablink.on() or not ablink.available() or not ablink.valid(d) or reaper.EnumProjects(-1) ~= proj then return end
  local me, now = my_dev(), reaper.time_precise()
  if d.dev == me then return end
  S.cands[d.dev] = { user = d.user, stamp = d.stamp, heard = now }
  S.cands[me] = { user = cfg.user, stamp = S.stamp, mine = true }
  if ablink.leader(S.cands, require("sync").driver_name, now) ~= d.dev then return end
  if reaper.GetPlayStateEx(proj) & 1 == 1 then return end -- (REAPER plays here: it leads this computer's Link)
  local sn = shared_now()
  if not sn or not reaper.Blink_GetEnabled() then return end
  local link_now = reaper.Blink_GetClockNow()
  if not ablink.close(d.bpm, reaper.Blink_GetTempo()) then push_tempo(d.bpm, now) end
  if d.playing ~= reaper.Blink_GetPlaying() then
    reaper.Blink_SetPlaying(d.playing, link_now + ((d.play_at or sn) - sn)) -- (at the moment it happened there, on this computer's Link clock)
    ablink.set(S.play, d.playing and 1 or 0, now)
  end
  local to = ablink.fix(reaper.Blink_GetBeatAtTime(link_now, d.q), ablink.beat_at(d, sn), d.q, d.bpm)
  if to then reaper.Blink_SetBeatAtTimeForce(to, link_now, d.q) end
  S.phase_ok = to == nil
end

-- Health (lib/direct.lua health_rows): nil while Link is off here.
function ablink.health_row()
  if not ablink.on() then return nil end
  if not ablink.available() then
    return { "ablink", false, "yellow", "", "Ableton Link is on for this computer, but ReaBlink isn't installed: Extensions > ReaPack > Browse packages: ReaBlink, then restart REAPER." }
  end
  local st = band.json_decode(reaper.GetExtState(band.SECTION, "ablink status"))
  if type(st) ~= "table" or os.time() - (tonumber(st.at) or 0) > 10 then
    return { "ablink", true, "grey", "Ableton Link: joins while Live sync runs with a studio song in front.", "" }
  end
  local text = ablink.health_text(st)
  return { "ablink", not st.puppet, "yellow", text, text }
end

-- Settings > Advanced (only on this computer).
function ablink.settings_ui(ctx, ImGui)
  ImGui.SeparatorText(ctx, "Ableton Link")
  local on, have = ablink.on(), ablink.available()
  ImGui.TextDisabled(ctx, "Ableton Live, phone apps and drum machines on this computer's network keep REAPER's tempo and bar. Across the studio, " ..
    "each computer with this on lines up its own Link apps with the others'.")
  if not have then ImGui.TextDisabled(ctx, "Needs ReaBlink: Extensions > ReaPack > Browse packages: ReaBlink, then restart REAPER.") end
  if not have and not on then return end
  local ch, v = ImGui.Checkbox(ctx, "Join Ableton Link on this computer##ablink", on)
  if ch then
    reaper.SetExtState(band.SECTION, ablink.KEY, v and "1" or "", true)
    band.log(v and "Ableton Link: on for this computer (it joins while Live sync runs)" or "Ableton Link: off for this computer")
  end
  ImGui.SetItemTooltip(ctx, "Only on this computer. REAPER's tempo and play/stop go to Link; while REAPER plays, Link's bar is REAPER's.\n" ..
    "A Link app's tempo change becomes the song's only if you may change the tempo (driver, or Anyone) and nobody is recording; otherwise it's put back.")
end

return ablink
