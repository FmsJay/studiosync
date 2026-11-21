-- Start and stop together. Someone clicks "Play together" (or "Record together"): a start event says WHEN (a wall-clock
-- moment a few seconds ahead) and WHERE (song position, with a count-in). Each machine's Live sync fires its transport
-- at that moment. The event travels through the shared folder, which can take seconds; a machine that gets it late
-- starts right away at the position the song has reached by now, so it still lines up instead of starting late.
-- In Play along (NINJAM synced) the listeners must run behind the one playing: they start `lag` seconds later.
-- Clocks: machines keep internet time (NTP), usually within tens of milliseconds of each other.
local together = {}

together.LEAD = 5 -- seconds between the click and the start: the shared folder takes 1-3 s to deliver the event

-- A start's skip: the time selection REAPER's "Transport: Play (skip time selection)" (40317) plays over, { s, e } in the start
-- (together.start), checked as anything a bandmate sends is. -> s, e, or nil. Pure. (James, 2026-11-21: "Play together" honours it)
function together.skip_range(ev)
  local k = type(ev) == "table" and type(ev.skip) == "table" and ev.skip or nil
  local s, e = k and tonumber(k[1]), k and tonumber(k[2])
  if s and e and s >= 0 and e > s and e < 1e7 then return s, e end
end
-- When and from where this machine starts. Pure.
-- ev = { at = epoch seconds, pos = song position, countin = seconds, lag = seconds, lead = user, skip = { s, e } }; me; now (epoch).
-- Returns fire (epoch) and from (position). Already past fire: fire now, from as far into the song as time has gone (past a skipped
-- time selection, as far as the others have got by skipping it).
function together.plan(ev, me, now)
  local fire = ev.at + ((ev.lead and ev.lead ~= me) and (ev.lag or 0) or 0)
  local from = (ev.pos or 0) - (ev.countin or 0)
  if from < 0 then fire, from = fire - from, 0 end -- can't play before 0: start at 0, that much later
  if now and now > fire then
    if ev.behind then return now, from end -- (producing someone: by position it lines up at any lag, so nothing's missed by being late)
    local s, e = together.skip_range(ev)
    local at = from + (now - fire)
    if s and from < s and at >= s then at = at + (e - s) end
    return now, at
  end
  return fire, from
end

-- Seconds of `bars` bars ending at pos (the count-in), by the project's own tempo map and time signature.
function together.bars_before(proj, pos, bars)
  if (bars or 0) <= 0 then return 0 end
  local num, den = reaper.TimeMap_GetTimeSigAtTime(proj, pos)
  local qn = reaper.TimeMap2_timeToQN(proj, pos)
  return pos - reaper.TimeMap2_QNToTime(proj, qn - bars * num * 4 / den)
end
-- Seconds of `bars` bars starting at pos.
function together.bars_after(proj, pos, bars)
  if (bars or 0) <= 0 then return 0 end
  local num, den = reaper.TimeMap_GetTimeSigAtTime(proj, pos)
  return reaper.TimeMap2_QNToTime(proj, reaper.TimeMap2_timeToQN(proj, pos) + bars * num * 4 / den) - pos
end

-- A side-by-side stop's playhead readings: `past` readings in a row at or beyond `target` so far, and this one at `pos`. -> the new count, and
-- whether that's two in a row (one reading can be a few hundred ms off for a moment). Pure; asked once a pass (review, 0.58.92).
function together.count_reading(past, pos, target)
  past = pos >= target - 0.005 and past + 1 or 0
  return past, past >= 2
end
-- Someone else's start or stop that's due here is left alone when you're recording a take you started yourself (one started together
-- may be stopped together), or when it would start a recording here while another tab plays. Pure (review, 0.58.91).
function together.leave_alone(due, theirs, remote, recording, together_take, busy_elsewhere)
  return (due and theirs and not remote and ((recording and not together_take) or busy_elsewhere)) and true or false
end
-- The status write while poll waits (a take, Live set playing, the undo wait): every 15 s. Pure (review, 0.58.92-93).
function together.heartbeat_due(waiting, has_status, now, last) return (waiting and has_status and now - last > 15) and true or false end

-- Wall clock with sub-second precision: os.time() only counts whole seconds, so note where reaper.time_precise()
-- stands when the second ticks over (call tick() often; precise to about one defer cycle after the first tick).
local offset, offset_at, last_sec, cur_best, prev_best
function together.tick()
  local s = os.time()
  if last_sec and s ~= last_sec then
    -- (each look comes a little after the second ticked over, so it reads a little low and the highest is nearest: one late tick (REAPER busy
    -- for half a second) put every start that far out until the next second. A clock set back or forward starts it again. Review, 0.58.92)
    -- (the best of the last half minute, not of all time: a wall clock running a little slow, or pulled back under a second, kept an old high
    -- reading for good, up to a second out by the end of a long session. Review, 0.58.95)
    local t = reaper.time_precise()
    local o = s - t
    -- (the best of this half minute and the last: a fresh window started on one stalled reading put starts that far out. Review, 0.58.96)
    if not offset or offset - o > 1 then cur_best, prev_best, offset_at = o, nil, t -- (the first reading, or the clock set back)
    elseif t - offset_at > 30 then prev_best, cur_best, offset_at = cur_best, o, t
    else cur_best = math.max(cur_best, o) end
    offset = math.max(cur_best, prev_best or cur_best)
  end
  last_sec = s
end
function together.now()
  return reaper.time_precise() + (offset or (os.time() - reaper.time_precise()))
end

-- The studio's shared clock over the direct link (lib/direct.lua shared_now): internet time left the laptop 322 ms off the desktop, enough to
-- wreck Play and Record together. The starter picks start_at = shared now + lead (nil without the link: ev.at's internet time then); each
-- computer fires at its own clock + (start_at - shared now), here in together.now()'s terms. (James, 0.60.0-rt)
function together.start_at(lead)
  local ok, sn = pcall(function() return require("direct").shared_now() end)
  return ok and sn and sn + (lead or 0) or nil
end
function together.local_at(start_at, shared_now, local_now) return local_now + (start_at - shared_now) end -- (pure)

-- A start or stop for the band: posted for everyone, and fired here through this tab's own Live sync. The panel's Play/Record/Stop together
-- and the web UI's Song page (lib/dawview.lua) both send theirs this way. (James, rt)
-- The loop a start carries: { start, end } while repeat is on over a loop range, else false (rt-edits: Play together started everyone, but
-- each REAPER looped by its own repeat and loop range, so a loop rehearsal came apart at the first loop end).
function together.loop_of(proj)
  local ls, le = reaper.GetSet_LoopTimeRange2(proj, false, true, 0, 0, false)
  return reaper.GetSetRepeatEx(proj, -1) == 1 and le > ls and { ls, le } or false
end
-- A start's loop put in place here: its range with repeat on, or repeat off; nil (an older StudioSync's start) leaves yours.
function together.apply_loop(proj, loop)
  if type(loop) == "table" and tonumber(loop[1]) and tonumber(loop[2]) and tonumber(loop[2]) > tonumber(loop[1]) then
    reaper.GetSet_LoopTimeRange2(proj, true, true, tonumber(loop[1]), tonumber(loop[2]), false)
    reaper.GetSetRepeatEx(proj, 1)
  elseif loop == false then reaper.GetSetRepeatEx(proj, 0) end
end
-- The time selection a start skips: the one ahead of `pos`, as REAPER's Play (skip time selection) skips it, else false.
function together.skip_of(proj, pos)
  local s, e = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  return e > s and s > (pos or 0) and { s, e } or false
end
-- A start's play, fired here (Live sync): with a skip, REAPER's own Play (skip time selection) over that selection, so every computer skips
-- it as the leader does (the selection is set to the leader's here). Not for a recording, nor from past it (a late start: together.plan),
-- nor in a tab that isn't in front (REAPER's actions go to the tab in front: it plays through there, and says so). -> true when it skips.
function together.play(proj, ev)
  local s, e = together.skip_range(ev)
  if s and not ev.rec and reaper.GetCursorPositionEx(proj) < s then
    if reaper.EnumProjects(-1) == proj then
      reaper.GetSet_LoopTimeRange2(proj, true, false, s, e, false)
      reaper.Main_OnCommandEx(40317, 0, proj) -- Transport: Play (skip time selection)
      return true
    end
    require("band").log("a start that skips a time selection plays through it in a tab that isn't in front")
  end
  reaper.OnPlayButtonEx(proj)
  return false
end
function together.go(proj, cfg, b, ev)
  local band = require("band")
  if ev.type == "start" and ev.loop == nil then ev.loop = together.loop_of(proj) end
  ev.at = math.floor(os.time()) + together.LEAD
  ev.start_at = together.start_at(together.LEAD) -- (the same moment on the studio's shared clock, when the direct link has one. James, 0.60.0-rt)
  require("sync").post(cfg, b.song, b.room, ev)
  ev.user = cfg.user
  band.set_ext_json(band.SECTION, "transport " .. tostring(proj), ev, false)
end
-- Play or Record together from `pos`, after `countin` bars, with listeners `lag` bars later (Time-sync only, else 0). The panel's Start together,
-- the web UI's Play page and its Song page's Play (lib/webpages.lua, lib/dawview.lua) all start this way. (James, rt)
-- `skip`: as REAPER's Play (skip time selection), the time selection ahead of pos skipped on every computer (play only; together.skip_of).
function together.start(proj, cfg, b, pos, rec, countin, click, lag, skip)
  together.go(proj, cfg, b, { type = "start", rec = rec or nil, pos = pos, countin = together.bars_before(proj, pos, countin), click = click or nil,
    lag = together.bars_after(proj, pos, lag or 0), lead = cfg.user, skip = skip and not rec and together.skip_of(proj, pos) or nil })
end
-- The project's regions, in order, for "start from": { { name, pos } } (an unnamed one is "region <n>").
function together.regions(proj)
  local out, i = {}, 0
  while true do
    local ok, isrgn, p, _, name = reaper.EnumProjectMarkers3(proj, i)
    if ok == 0 then break end
    if isrgn then out[#out + 1] = { name = name ~= "" and name or ("region " .. (#out + 1)), pos = p } end
    i = i + 1
  end
  return out
end
-- "5", or "5 beat 3" off the bar line (the panel's and the web UI's start-from labels).
function together.bar_of(pos)
  local bar, beat = reaper.format_timestr_pos(pos, "", 2):match("^(%d+)%.(%d+)")
  return beat == "1" and bar or (bar .. " beat " .. beat)
end

return together
