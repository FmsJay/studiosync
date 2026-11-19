-- Their time by measurement (James, 0.59.32: "can their time be based on measured latency?"). It was a number you set by hand, 100 ms
-- unless you read each person's off SonoBus's window. Now, while you play in Their time, each bandmate who's playing too is timed in
-- turn: their computer sends the position bursts Produce uses (lib/stamp.lua) for a few seconds, and your reader times each one against
-- your own playhead. That is the whole delay at once: the network, SonoBus's buffer, both audio interfaces, and how far apart the two
-- transports started. The latest of them is what your backing waits for. At each start, and again every two minutes, as SonoBus's buffer can move.
-- Their computer is asked through your status file (`measure`), as Produce asks: producer.tick answers.
local band = require("band")
local L = {}

L.EVERY, L.WAIT, L.ENOUGH = 120, 20, 5 -- seconds between timings of one person; the most a timing waits; bursts it wants
local cur, done_at = {}, {} -- tab -> the timing going on { name, since, n, vals }; tab..name -> when last timed

-- Real time mode is on in `proj` (My time or Their time), and its transport plays. (The others are timed only then: the bursts say song
-- positions.) My time shows what was measured; only Their time moves your backing by it.
function L.wanted(proj)
  return require("live").realtime_on(proj) and reaper.GetPlayStateEx(proj) & 1 == 1
end
local function their_time(proj) return select(2, reaper.GetProjExtState(proj, band.SECTION, "hear their time")) == "1" end
-- The middle one, after dropping any more than 50 ms from the middle (a burst caught across a seek). Pure.
function L.median(vals)
  if #vals == 0 then return nil end
  local t = {}
  for i, v in ipairs(vals) do t[i] = v end
  table.sort(t)
  local mid = t[(#t + 1) // 2]
  local near = {}
  for _, v in ipairs(t) do if math.abs(v - mid) <= 0.05 then near[#near + 1] = v end end
  return near[(#near + 1) // 2]
end
-- Someone's measured delay here (ms), or nil.
function L.of(proj, name) return tonumber(select(2, reaper.GetProjExtState(proj, band.SECTION, "lat " .. name))) end
-- Whom this tab is timing now (its status says so, and their computer sends the bursts), or nil.
-- (in ExtState: the panel shows it, from its own Lua)
function L.asking(proj) local v = reaper.GetExtState(band.SECTION, "timing " .. tostring(proj)); return v ~= "" and v or nil end
local function set_cur(tab, c)
  cur[tab] = c
  if c then reaper.SetExtState(band.SECTION, "timing " .. tab, c.name, false) else reaper.DeleteExtState(band.SECTION, "timing " .. tab, false) end
end
-- The delay Their time should use: the latest of those measured who have a pair here, or nil.
function L.delay(proj)
  local most
  for name in pairs(require("hear").pairs(proj)) do
    local v = L.of(proj, name)
    if v and (not most or v > most) then most = v end
  end
  return most
end

-- Each pass of Live sync, with the others' status files.
local was_on = {} -- tab -> whether it was timing-ready (playing in Real time) at the last pass
function L.tick(proj, cfg, b, peers)
  local tab, stamp = tostring(proj), require("stamp")
  local c = cur[tab]
  local on = L.wanted(proj)
  if on and not was_on[tab] then -- (each new start: the two transports start a little apart each time, and that's part of the delay. Live test, 0.59.35)
    for k in pairs(done_at) do if k:sub(1, #tab) == tab then done_at[k] = nil end end
  end
  was_on[tab] = on
  if not on or require("producer").who(proj) then -- (producing someone, the reader is theirs)
    if c then stamp.read(proj, false); set_cur(tab, nil) end
    return
  end
  if not c then
    local pairs_ = require("hear").pairs(proj)
    for _, st in ipairs(peers) do
      -- (My time only shows it: timed every ten minutes there, as each timing puts them in mono for a few seconds)
      if st.user ~= cfg.user and st.playing and pairs_[st.user] and reaper.time_precise() - (done_at[tab .. st.user] or -math.huge) > (their_time(proj) and L.EVERY or 600) then
        set_cur(tab, { name = st.user, since = reaper.time_precise(), n = stamp.lateness().n, vals = {} })
        stamp.read(proj, true, pairs_[st.user])
        return
      end
    end
    return
  end
  local s = stamp.lateness()
  if s.n ~= c.n then
    c.n = s.n
    if s.late > -0.05 and s.late < 3 then c.vals[#c.vals + 1] = s.late end
  end
  if #c.vals >= L.ENOUGH or reaper.time_precise() - c.since > L.WAIT then
    stamp.read(proj, false)
    set_cur(tab, nil)
    done_at[tab .. c.name] = reaper.time_precise()
    local late = #c.vals >= 3 and L.median(c.vals)
    if not late then return band.log("couldn't time " .. c.name .. " for Their time (no bursts came back): trying again in two minutes") end
    local ms = math.floor(late * 1000 + 0.5)
    local had = L.of(proj, c.name)
    reaper.SetProjExtState(proj, band.SECTION, "lat " .. c.name, tostring(ms))
    local d = L.delay(proj)
    if d and their_time(proj) then
      require("hear").set_delay(proj, d)
      reaper.SetProjExtState(proj, band.SECTION, "their ms", tostring(d))
    end
    if not had or math.abs(had - ms) > 15 then
      band.log(string.format("%s arrives %d ms late here", c.name, ms) .. (their_time(proj) and string.format(": Their time holds your backing back %d ms", d or ms) or ""))
    end
  end
end

return L
