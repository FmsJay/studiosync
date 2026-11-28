-- StudioSync: times in beats (rt-sync2 section 2, built in rt-sync2f: docs/rt/rt-sync2f.md).
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- An item's or automation's text as it travels and as every hash sees it is its canonical form: its times in the units its timebase keeps
-- fixed, so a tempo change changes none of it. Read from REAPER (seconds) by the look, written back to REAPER (seconds, on the map in place)
-- by mirror.apply. A tempo change then sends nothing but the timeline change, and a version lands on the same beat on every computer
-- whichever came first, it or the map: REAPER keeps it on its beat when the map lands after it.
--
--   timebase                         | the canonical text
--   0 time                           | the seconds as REAPER writes them (no mark)
--   2 beats (position only)          | BANDBEAT 2; POSITION in quarter notes
--   1 beats (position, length, rate) | BANDBEAT 1; POSITION and LENGTH in quarter notes; SNAPOFFS and the FADEIN length and auto length as
--                                    | quarter notes from the item's start, the FADEOUT's as quarter notes back from its end; an audio take's
--                                    | PLAYRATE as source seconds per item (rate x length), or as it is when the take has stretch markers of
--                                    | its own; each stretch marker's place in quarter notes from the item's start; on an auto-stretch item
--                                    | (IMPLIEDWARP 1), the stretch markers REAPER made for the tempo map alone are left out (beats.rewarp)
--   automation, project timebase 1/2 | BANDBEAT <tb> first; each PT time, POOLEDENVINST / BANDAI place (and in 1 its length) and BANDAIPT
--                                    | time in quarter notes. Automation with no times in it carries no mark.
--
-- These are the quantities REAPER keeps when the map changes (rt-r4 check 1, mirror.retime's before this). A fade or snap offset keeps its
-- beats where it sits, not its share of the length: REAPER 7.86 (Windows and Linux) took an item at 10 s, 6 s long, with a 90 bpm marker
-- added at 10.5 s, to 7.8333 s, its fade in 1 -> 1.1667 s (a share of the length would be 1.2222) and its fade out 0.5 -> 0.6667 s, and live
-- check sync2f f4 saw the share form re-send such an item at every tempo change inside it (rt-sync2g). Stretch markers, measured the same way:
-- REAPER keeps each one's beats; an item with stretch markers of its own keeps its rate (only one without scales it with the length); on an
-- auto-stretch item REAPER adds markers of its own where the map changes inside it ("0 1" after their places), the same ones again from the
-- map alone when C_AUTOSTRETCH is set (beats.rewarp). Quarter notes to 1e-6, the inner spans and rates to 1e-9: past that it's arithmetic, and
-- a value moved for a map and back reads the same.
-- Versions from before (no mark) are read once into this form where their map is known (`tm` on the version: beats.upgrade); one with no map
-- stays as its seconds, which land as they are (the rule for versions from before rt-converge).
local beats = {}

beats.MARK = "BANDBEAT"

local function q6(x) local s = string.format("%.6f", x); return s == "-0.000000" and "0.000000" or s end
local function f9(x) local s = string.format("%.9f", x); return s == "-0.000000000" and "0.000000000" or s end
local function g14(x) return string.format("%.14g", x) end
beats.q6, beats.f9 = q6, f9

-- The mark a canonical text carries (1 or 2), or nil (seconds). Pure.
function beats.mark(state)
  if type(state) ~= "string" then return nil end
  return tonumber(state:match("^BANDBEAT ([12])\n") or state:match("\nBANDBEAT ([12])\n"))
end

-- ---- an item --------------------------------------------------------------------------------------------------------------------------------
-- Its lines at the item's own level (depth 1), take by take: fn(line, kw, take) -> the line to keep (nil drops it). take: { midi, rate (the
-- index of its PLAYRATE line in the result) }. -> the lines and the takes.
local function item_walk(state, fn)
  local L, depth, take = {}, 0, { midi = false }
  local takes = { take }
  for line in (state .. "\n"):gmatch("([^\n]*)\n") do
    local kw = line:match("^%s*(%S+)") or ""
    local out = line
    if depth == 1 then
      if kw == "TAKE" then take = { midi = false }; takes[#takes + 1] = take end
      out = fn(line, kw, take)
      if out and kw == "PLAYRATE" then take.rate = #L + 1 end
      if out and kw == "SM" then take.sm = #L + 1 end
      if kw == "IMPLIEDWARP" then takes.implied = line:match("^%s*IMPLIEDWARP%s+1") ~= nil end
    end
    if line:find("^%s*<SOURCE MIDI") then take.midi = true end
    if out then L[#L + 1] = out end
    if kw:sub(1, 1) == "<" then depth = depth + 1 elseif kw == ">" then depth = depth - 1 end
  end
  if L[#L] == "" then L[#L] = nil end
  return L, takes
end
local function join(L, was)
  local out = {}
  for i = 1, #L do if L[i] then out[#out + 1] = L[i] end end -- (false: a line taken out after the walk)
  return table.concat(out, "\n") .. (was:sub(-1) == "\n" and "\n" or "")
end
-- A take's stretch markers: its SM line's entries ("pos srcpos [slope flags]", joined by " + "), each { pos, rest, made } (made: REAPER's own
-- for the tempo map, flag bit 1). Pure.
local function sm_entries(line)
  local out = {}
  for e in (line:match("^%s*SM%s+(.*)$") or ""):gmatch("[^+]+") do
    local pos, rest = e:match("^%s*(%S+)(.-)%s*$")
    if pos then
      local w = {}
      for t in rest:gmatch("%S+") do w[#w + 1] = t end
      out[#out + 1] = { pos = tonumber(pos), rest = rest, made = (tonumber(w[3]) or 0) % 2 == 1 }
    end
  end
  return out
end
local function sm_line(list, posf)
  local e = {}
  for i, x in ipairs(list) do e[i] = posf(x.pos) .. x.rest end
  return "SM " .. table.concat(e, " + ")
end
local function own_markers(list) for _, x in ipairs(list) do if not x.made then return true end end return false end
local function num_at(line, k) -- (the k-th number after the keyword, its text's start and end)
  local n, pos = 0, 1
  while true do
    local a, b = line:find("%S+", pos)
    if not a then return nil end
    if n == k then return tonumber(line:sub(a, b)), a, b end
    n, pos = n + 1, b + 1
  end
end
local function set_at(line, k, text)
  local _, a, b = num_at(line, k)
  if not a then return line end
  return line:sub(1, a - 1) .. text .. line:sub(b + 1)
end

-- An item's seconds text (mirror.item_state's) in its canonical form, for the timebase `mode` (0, 1 or 2) with `qn(seconds) -> quarter notes`.
-- A text already canonical, or in mode 0, is returned as it is. Pure.
function beats.item(state, mode, qn)
  if (mode ~= 1 and mode ~= 2) or type(state) ~= "string" or beats.mark(state) then return state end
  local p = tonumber(state:match("\n%s*POSITION ([^\n]+)"))
  if not p then return state end
  local l = tonumber(state:match("\n%s*LENGTH ([^\n]+)")) or 0
  if mode == 1 and not (l > 0) then mode = 2 end -- (nothing to take fractions of)
  local q0, qe = qn(p), qn(p + l)
  local function from_start(v) return f9(qn(p + v) - q0) end
  local function from_end(v) return f9(qe - qn(p + l - v)) end
  local L, takes = item_walk(state, function(line, kw)
    if kw == "POSITION" then return "POSITION " .. q6(q0) end
    if mode ~= 1 then return line end
    if kw == "LENGTH" then return "LENGTH " .. q6(qe - q0) end
    if kw == "SNAPOFFS" then local v = num_at(line, 1); return v and set_at(line, 1, from_start(v)) or line end
    if kw == "FADEIN" or kw == "FADEOUT" then
      local span = kw == "FADEIN" and from_start or from_end
      local a, b = num_at(line, 2), num_at(line, 3)
      if a then line = set_at(line, 2, span(a)) end
      if b then line = set_at(line, 3, span(b)) end
    end
    return line
  end)
  if mode == 1 then
    for _, t in ipairs(takes) do
      local r = t.rate and not t.midi and num_at(L[t.rate], 1)
      local sm = t.sm and not t.midi and sm_entries(L[t.sm])
      local own = sm and own_markers(sm)
      if sm and not own and takes.implied then L[t.sm] = false -- (REAPER's alone: made again from the map where it lands)
      elseif sm then local rr = r or 1; L[t.sm] = sm_line(sm, function(x) return q6(qn(p + x / rr) - q0) end) end -- (to 1e-6: REAPER writes them to 1e-9 s)
      if r and not own then L[t.rate] = set_at(L[t.rate], 1, f9(r * l)) end
    end
  end
  for i, line in ipairs(L) do
    if line and line:match("^%s*<ITEM") then table.insert(L, i + 1, "BANDBEAT " .. mode); return join(L, state) end
  end
  table.insert(L, 1, "BANDBEAT " .. mode)
  return join(L, state)
end

-- (a value worked out from a fraction of the length (or a rate from source seconds), rounded to 1e-9: written to the microsecond when it was
-- one there, as most fades are, so a fade of 0.25 s lands as 0.25, not 0.249999999. Only where that reads back as the very same canonical
-- text with this computer's length (`back(r)`): a receiver's length can differ from the sender's in its 7th digit (its place and length are
-- quarter notes to 1e-6), and a fade put back to its round value there read back across a rounding step, so two computers held the same
-- item in two texts (the long soak's 5022 and 5024, a 0.01 s fade on a 2.2 s item). Whatever is written must read back as it travelled.)
local function snapped(v, back)
  local r = math.floor(v * 1e6 + 0.5) / 1e6
  if back and r ~= v and math.abs(v - r) <= 1e-6 and back(r) then return r end
  return v
end
-- A canonical item text back in seconds with `time(quarter notes) -> seconds`, and `qn` (its inverse; optional: without it no inner time is
-- rounded to the microsecond). A text without the mark is returned as it is. Pure.
function beats.item_seconds(state, time, qn)
  local mode = beats.mark(state)
  if not mode then return state end
  local q0 = tonumber(state:match("\n%s*POSITION ([^\n]+)")) or 0
  local lq = tonumber(state:match("\n%s*LENGTH ([^\n]+)")) or 0
  local p = time(q0)
  local l = mode == 1 and (time(q0 + lq) - p) or nil
  -- (REAPER holds the place and length as written: an inner span reads back from those)
  local pr, lr = tonumber(g14(p)), l and tonumber(g14(l))
  local function span_start(x)
    return g14(snapped(time(q0 + x) - p, qn and function(r) return f9(qn(pr + tonumber(g14(r))) - qn(pr)) == f9(x) end))
  end
  local function span_end(x)
    return g14(snapped(p + l - time(q0 + lq - x), qn and function(r) return f9(qn(pr + lr) - qn(pr + lr - tonumber(g14(r)))) == f9(x) end))
  end
  local L, takes = item_walk(state, function(line, kw)
    if kw == "BANDBEAT" then return nil end
    if kw == "POSITION" then return "POSITION " .. g14(p) end
    if not l then return line end
    if kw == "LENGTH" then return "LENGTH " .. g14(l) end
    if kw == "SNAPOFFS" then local v = num_at(line, 1); return v and set_at(line, 1, span_start(v)) or line end
    if kw == "FADEIN" or kw == "FADEOUT" then
      local span = kw == "FADEIN" and span_start or span_end
      local a, b = num_at(line, 2), num_at(line, 3)
      if a then line = set_at(line, 2, span(a)) end
      if b then line = set_at(line, 3, span(b)) end
    end
    return line
  end)
  if l and l > 0 then
    for _, t in ipairs(takes) do
      local r = t.rate and not t.midi and num_at(L[t.rate], 1)
      local sm = t.sm and not t.midi and sm_entries(L[t.sm])
      local own = sm and own_markers(sm)
      local rw = r and not own and tonumber(g14(snapped(r / l, function(x) return f9(tonumber(g14(x)) * l) == f9(r) end))) or r or 1
      if r and not own then L[t.rate] = set_at(L[t.rate], 1, g14(rw)) end
      if sm then L[t.sm] = sm_line(sm, function(x) return g14((time(q0 + x) - p) * rw) end) end
    end
  end
  return join(L, state)
end

-- ---- automation -----------------------------------------------------------------------------------------------------------------------------
local function env_has_times(state)
  return state:find("PT ", 1, true) or state:find("BANDAI", 1, true) or state:find("POOLEDENVINST", 1, true)
end
-- Each time line of an automation text through fn(kind, line) -> the line. kind: "pt" (PT: time first), "inst" (POOLEDENVINST / BANDAI: place
-- and length after one word), "aipt" (BANDAIPT: time after two words).
local function env_walk(state, fn)
  local L = {}
  for line in (state .. "\n"):gmatch("([^\n]*)\n") do
    local kw = line:match("^%s*(%S+)")
    if kw == "PT" then line = fn("pt", line)
    elseif kw == "POOLEDENVINST" or kw == "BANDAI" then line = fn("inst", line)
    elseif kw == "BANDAIPT" then line = fn("aipt", line) end
    if line then L[#L + 1] = line end
  end
  if L[#L] == "" then L[#L] = nil end
  return L
end
-- An automation part's seconds text in its canonical form, for the project timebase `mode`, with qn. Pure.
function beats.env(state, mode, qn)
  if (mode ~= 1 and mode ~= 2) or type(state) ~= "string" or beats.mark(state) or not env_has_times(state) then return state end
  local L = env_walk(state, function(kind, line)
    if kind == "pt" then local t = num_at(line, 1); return t and set_at(line, 1, q6(qn(t))) or line end
    if kind == "aipt" then local t = num_at(line, 3); return t and set_at(line, 3, q6(qn(t))) or line end
    local pos, len = num_at(line, 2), num_at(line, 3)
    if not (pos and len) then return line end
    local q = qn(pos)
    if mode == 1 then line = set_at(line, 3, q6(qn(pos + len) - q)) end
    return set_at(line, 2, q6(q))
  end)
  return "BANDBEAT " .. mode .. "\n" .. join(L, state)
end
-- A canonical automation text back in seconds with time. Pure.
function beats.env_seconds(state, time)
  local mode = beats.mark(state)
  if not mode then return state end
  local L = env_walk(state:gsub("^BANDBEAT [12]\n", ""):gsub("\nBANDBEAT [12]\n", "\n"), function(kind, line)
    if kind == "pt" then local q = num_at(line, 1); return q and set_at(line, 1, g14(time(q))) or line end
    if kind == "aipt" then local q = num_at(line, 3); return q and set_at(line, 3, g14(time(q))) or line end
    local q, lq = num_at(line, 2), num_at(line, 3)
    if not (q and lq) then return line end
    local p = time(q)
    if mode == 1 then line = set_at(line, 3, g14(time(q + lq) - p)) end
    return set_at(line, 2, g14(p))
  end)
  return join(L, state)
end

-- What has times of its own: items, automation, and a track's sends (their envelopes and automation items). Pure.
local ENV_LIKE = { env = true, recv = true }
function beats.kind_has_times(kind) return kind == "item" or ENV_LIKE[kind] == true end
-- Seconds <-> canonical for any object's text, by its kind. Pure.
function beats.canon(kind, state, mode, qn)
  if kind == "item" then return beats.item(state, mode, qn) end
  if ENV_LIKE[kind] then return beats.env(state, mode, qn) end
  return state
end
function beats.seconds(kind, state, time, qn)
  if kind == "item" then return beats.item_seconds(state, time, qn) end
  if ENV_LIKE[kind] then return beats.env_seconds(state, time) end
  return state
end

-- ---- tempo maps as lists (band.capture_tempo's), for versions from before and History's preview ---------------------------------------
-- A tempo map from another computer (a version's `tm`): a list of points with a place and a tempo, the first at 0, in order. Pure.
beats.MAP_MAX = 4096
function beats.map_ok(m)
  if type(m) ~= "table" or #m == 0 or #m > beats.MAP_MAX then return false end
  local last = -1
  for _, p in ipairs(m) do
    if type(p) ~= "table" or type(p.time) ~= "number" or type(p.bpm) ~= "number" or not (p.bpm > 0 and p.bpm < 1e6 and p.time >= 0 and p.time < 1e9)
      or p.time < last then return false end
    last = p.time
  end
  return true
end
-- Quarter notes at `t` seconds on `map`, and its inverse, as REAPER's TimeMap2 counts them: a point's tempo holds until the next point, or,
-- where the point is linear (gradual), goes in a straight line to the next point's tempo. Pure.
local function seg_q(m, n, dt) -- (quarter notes dt seconds into the segment from m (to n))
  if m.linear and n and n.time > m.time then
    local k = (n.bpm - m.bpm) / (n.time - m.time)
    return dt * (m.bpm + k * dt / 2) / 60
  end
  return dt * m.bpm / 60
end
local function seg_t(m, n, dq) -- (seconds dq quarter notes into it)
  if m.linear and n and n.time > m.time then
    local k = (n.bpm - m.bpm) / (n.time - m.time)
    local b = m.bpm / 60
    return 2 * dq / (b + math.sqrt(math.max(0, b * b + k * dq / 30)))
  end
  return dq * 60 / m.bpm
end
function beats.map_qn(map, t)
  local q = 0
  for i, m in ipairs(map) do
    local n = map[i + 1]
    if not n or t < n.time then return q + seg_q(m, n, t - m.time) end
    q = q + seg_q(m, n, n.time - m.time)
  end
  return q
end
function beats.map_time(map, q)
  local acc = 0
  for i, m in ipairs(map) do
    local n = map[i + 1]
    local span = n and seg_q(m, n, n.time - m.time)
    if not n or q < acc + span then return m.time + seg_t(m, n, q - acc) end
    acc = acc + span
  end
  return q
end
-- A version from before this (seconds, made under `map` with the project timebase `mode`: a version's `tm` and `tb`), in canonical form.
-- An item's own timebase (its BEAT line) goes before the project's. Not where the map isn't known: its seconds stand. Pure.
function beats.upgrade(kind, state, map, mode)
  if type(state) ~= "string" or beats.mark(state) or not beats.kind_has_times(kind) or not beats.map_ok(map) then return state end
  if kind == "item" then
    local b = tonumber(state:match("\n%s*BEAT (%-?%d+)"))
    if b and b >= 0 then mode = b end
  end
  return beats.canon(kind, state, tonumber(mode) or 0, function(t) return beats.map_qn(map, t) end)
end
-- An item's canonical text as hash version 12 had it (rt-sync2f: snap offset and fades as fractions of the length) in today's form, with no
-- map: a fraction times the length in quarter notes is the span in quarter notes wherever the tempo holds over the item (where it changes
-- inside the item, hash version 12's form can't say where, and this is the nearest). For history: hash version 12's changes are held by the
-- floor (level 13), but a record (W.one's re-anchor), a merge's base and History still read them. Pure.
function beats.upgrade12(state)
  if beats.mark(state) ~= 1 then return state end
  local lq = tonumber(state:match("\n%s*LENGTH ([^\n]+)")) or 0
  local L, takes = item_walk(state, function(line, kw)
    if kw == "SNAPOFFS" then local v = num_at(line, 1); return v and set_at(line, 1, f9(v * lq)) or line end
    if kw == "FADEIN" or kw == "FADEOUT" then
      local a, b = num_at(line, 2), num_at(line, 3)
      if a then line = set_at(line, 2, f9(a * lq)) end
      if b then line = set_at(line, 3, f9(b * lq)) end
    end
    return line
  end)
  -- (an auto-stretch item's markers REAPER made for the map, kept as they were then: left out, as today. A take's own markers in seconds
  -- would need the map: those items go out once after updating, Known limits in docs/rt/rt-sync2g.md)
  for _, t in ipairs(takes) do
    if t.sm and not t.midi and takes.implied and not own_markers(sm_entries(L[t.sm])) then L[t.sm] = false end
  end
  return join(L, state)
end
-- Two canonical item texts the same but for their inner spans (snap offset, fades) within 1e-7 quarter notes: what upgrade12 can promise, a
-- share of the length at 1e-9 times a length of up to thousands of quarter notes. Pure.
local INNER = { SNAPOFFS = true, FADEIN = true, FADEOUT = true }
function beats.near(a, b)
  if a == b then return true end
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  local la, lb = {}, {}
  for l in (a .. "\n"):gmatch("([^\n]*)\n") do la[#la + 1] = l end
  for l in (b .. "\n"):gmatch("([^\n]*)\n") do lb[#lb + 1] = l end
  if #la ~= #lb then return false end
  for i, x in ipairs(la) do
    local y = lb[i]
    if x ~= y then
      if not INNER[x:match("^%s*(%S+)") or ""] or x:match("^%s*(%S+)") ~= y:match("^%s*(%S+)") then return false end
      local tx, ty = {}, {}
      for t in x:gmatch("%S+") do tx[#tx + 1] = t end
      for t in y:gmatch("%S+") do ty[#ty + 1] = t end
      if #tx ~= #ty then return false end
      for k = 2, #tx do
        local u, v = tonumber(tx[k]), tonumber(ty[k])
        if not (tx[k] == ty[k] or u and v and math.abs(u - v) <= 1e-7) then return false end
      end
    end
  end
  return true
end
-- A canonical text in seconds on `map`. Pure.
function beats.seconds_on(kind, state, map)
  if not beats.mark(state) or not beats.map_ok(map) then return state end
  return beats.seconds(kind, state, function(q) return beats.map_time(map, q) end, function(t) return beats.map_qn(map, t) end)
end

-- ---- REAPER side ------------------------------------------------------------------------------------------------------------------------
-- (a REAPER without the tempo map's calls (a test's stand-in) keeps every time in seconds)
local function has_map() return reaper.TimeMap2_timeToQN ~= nil and reaper.TimeMap2_QNToTime ~= nil end
function beats.project_mode(proj)
  if not (has_map() and reaper.GetSetProjectInfo) then return 0 end
  return math.floor(tonumber((reaper.GetSetProjectInfo(proj, "PROJECT_TIMEBASE", 0, false))) or 0)
end
-- An item's timebase: its own (C_BEATATTACHMODE, its chunk's BEAT line), else its track's, else the project's. `track_mode`: the track's, if
-- read already.
function beats.item_mode(proj, state, tr, track_mode)
  local b = tonumber(type(state) == "string" and state:match("\n%s*BEAT (%-?%d+)") or nil)
  if b and b >= 0 then return b end
  if not has_map() then return 0 end
  local t = track_mode or (tr and math.floor(tonumber((reaper.GetMediaTrackInfo_Value(tr, "C_BEATATTACHMODE"))) or -1)) or -1
  if t >= 0 then return t end
  return beats.project_mode(proj)
end
local function qn_in(proj) return function(t) return reaper.TimeMap2_timeToQN(proj, t) end end
local function time_in(proj) return function(q) return reaper.TimeMap2_QNToTime(proj, q) end end
-- What the look reads (seconds, from REAPER) as it travels.
function beats.read_item(proj, state, tr, track_mode) return beats.item(state, beats.item_mode(proj, state, tr, track_mode), qn_in(proj)) end
function beats.read_env(proj, state) return beats.env(state, beats.project_mode(proj), qn_in(proj)) end
-- After an item's chunk is set from a travelling text: an auto-stretch item whose text left out REAPER's own stretch markers (beats.item)
-- gets them again from the map here, as REAPER makes them (C_AUTOSTRETCH set off and on: measured to give the very chunk REAPER had, on
-- REAPER 7.86, Windows and Linux. rt-sync2g). Nothing for any other item.
function beats.rewarp(it, chunk)
  if type(chunk) ~= "string" or not chunk:find("\n%s*IMPLIEDWARP%s+1") or chunk:find("\n%s*SM ") then return false end
  reaper.SetMediaItemInfo_Value(it, "C_AUTOSTRETCH", 0)
  reaper.SetMediaItemInfo_Value(it, "C_AUTOSTRETCH", 1)
  return true
end
-- A travelling text in seconds on this project's map, for REAPER.
function beats.write(proj, kind, state) return beats.seconds(kind, state, time_in(proj), qn_in(proj)) end
-- Which map and timebases the canonical form is read under here, as one string (a look's reuse of what it read last time).
function beats.map_key(proj)
  local f = { tostring(beats.project_mode(proj)) }
  if not (has_map() and reaper.CountTempoTimeSigMarkers) then return f[1] end
  for i = 0, (tonumber((reaper.CountTempoTimeSigMarkers(proj))) or 0) - 1 do
    local _, t, _, _, bpm, num, den, lin = reaper.GetTempoTimeSigMarker(proj, i)
    f[#f + 1] = string.format("%.17g %.17g %s %s %s", tonumber(t) or 0, tonumber(bpm) or 0, tostring(num), tostring(den), tostring(lin))
  end
  -- (no marker: the project's own tempo)
  if #f == 1 and reaper.TimeMap_GetTimeSigAtTime then local _, _, bpm = reaper.TimeMap_GetTimeSigAtTime(proj, 0); f[2] = string.format("%.17g", tonumber(bpm) or 0) end
  return table.concat(f, ";")
end

return beats
