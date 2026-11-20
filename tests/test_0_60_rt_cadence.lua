-- Real-time cadence (James, rt): a look 0.1 s after your edit settles instead of at the next 2 s pass, one look for a burst or a drag, none
-- mid-drag, at most a fifth of REAPER's time on a big song; the band's changes wait 0.4 s after your last edit while they come over the
-- direct link (2 s on Syncthing alone), never mid-drag, never more than 10 s. Live sync's tick simulated at REAPER's ~30 Hz defer rate.
package.loaded.band = { files = function() return {} end, read_json = function() end, song_dir = function(_, s) return "root/" .. s end }
package.path = "lib/?.lua;" .. package.path
local sync = require("sync")

local TICK, EVERY = 1 / 30, 2
-- The sender: edits at the given times (mouse held over [down, up) if given), passes every EVERY s or when sync.look_now says. -> pass times.
local function sender(edits, until_t, took, down, up)
  local cc, change_count, changed_at = 0, -1, -math.huge
  local last, polled_at, pass_took, passes = 0, -math.huge, 0, {}
  local e = 1
  local t = 0
  while t < until_t do
    while edits[e] and edits[e] <= t do cc = cc + 1; e = e + 1 end -- (your edits land between ticks)
    if cc ~= change_count then change_count, changed_at = cc, t end -- note_change
    local mouse = down and t >= down and t < up or false
    if t - last > EVERY or sync.look_now(changed_at, polled_at, pass_took, t, mouse) then
      last, polled_at = t, t
      passes[#passes + 1] = t
      cc = cc + 1 -- (the pass's own writes)
      pass_took = took
    end
    change_count = cc -- took_in: what the tick changed was ours
    t = t + TICK
  end
  return passes
end
local function first_after(list, t) for _, x in ipairs(list) do if x > t then return x end end end
local function count_between(list, a, b) local n = 0; for _, x in ipairs(list) do if x > a and x < b then n = n + 1 end end; return n end

-- one edit: out within settle + a tick or two, not at the next 2 s pass
local p = sender({ 0.5 }, 3, 0.02)
local sent = first_after(p, 0.5)
assert(sent - 0.5 >= sync.SETTLE and sent - 0.5 <= sync.SETTLE + 2 * TICK + 1e-9, "one edit goes out ~0.1 s later, not up to 2 s: " .. tostring(sent - 0.5))
assert(count_between(p, 0.5, 2.0) == 1, "and its pass's own writes don't bring another")
-- a burst (10 edits 50 ms apart): one look after it settles, none in the middle
local burst = {}
for i = 0, 9 do burst[#burst + 1] = 0.5 + i * 0.05 end
p = sender(burst, 3, 0.02)
assert(count_between(p, 0.5, 1.9) == 1, "a burst is one look: " .. count_between(p, 0.5, 1.9))
assert(first_after(p, 0.5) >= 0.95 + sync.SETTLE, "after the last edit settles")
-- a drag: nothing while the mouse is held, one look just after the drop (the drop is the change: REAPER counts a drag only then)
p = sender({ 1.5 }, 3, 0.02, 0.5, 1.5)
assert(count_between(p, 0.5, 1.5) == 0, "nothing mid-drag (the 2 s pass may still run then: P.look skips mid-drag itself)")
assert(first_after(p, 1.5) - 1.5 <= sync.SETTLE + 2 * TICK + 1e-9, "the drop goes out ~0.1 s later")
assert(not sync.look_now(1.0, 0, 0.02, 1.5, true), "never while the mouse is held")
-- a big song (a pass takes 1 s): the next quick pass waits 5 s after the last began, so REAPER keeps four fifths of its time
assert(not sync.look_now(2.0, 1.0, 1.0, 5.9, false), "a 1 s pass: no quick pass within 5 s of the last")
assert(sync.look_now(2.0, 1.0, 1.0, 6.1, false), "then it goes")
p = sender({ 0.5, 2.6, 4.2 }, 12, 1.0)
for i = 2, #p do assert(p[i] - p[i - 1] > 1.0 * 5 - 1e-9 or p[i] - p[i - 1] > EVERY, "passes stay apart on a big song") end
-- nothing changed: no quick passes, only the regular ones
p = sender({}, 7, 0.02)
for i = 2, #p do assert(p[i] - p[i - 1] > EVERY, "idle: every 2 s as before") end

-- the receiving gate
assert(sync.quiet_for(100, 95) == 0.4 and sync.quiet_for(100, 80) == 2 and sync.quiet_for(100, nil) == 2, "0.4 s while the link brings changes, else 2 s")
local busy, held = sync.editing_now(100, 99.7, nil, 0.4, false)
assert(busy and held == 100, "you edited 0.3 s ago: theirs waits")
busy, held = sync.editing_now(100.2, 99.7, held, 0.4, false)
assert(not busy and held == nil, "0.5 s after: it lands")
busy = sync.editing_now(100.2, 99.7, nil, 2, false)
assert(busy, "on Syncthing alone the 2 s stays")
busy = sync.editing_now(200, 0, nil, 0.4, true)
assert(busy, "never while the mouse is held")
busy, held = sync.editing_now(200, 199.9, 189.5, 0.4, false)
assert(not busy, "but never more than 10 s in a row")
-- what came over the link while you edited: a pass as the 0.4 s window ends, once, not at the next 2 s pass
assert(not sync.receive_now(true, 10, 0.4, 10.2, 0.02, 10.3, false), "still inside the window")
assert(sync.receive_now(true, 10, 0.4, 10.2, 0.02, 10.4, false), "the window's over: a pass now")
assert(not sync.receive_now(true, 10, 0.4, 10.41, 0.02, 10.5, false), "not straight after a pass that ran after the window")
assert(sync.receive_now(true, 10, 0.4, 10.41, 0.02, 10.52, false), "but again RETRY s on while it's still held (a look that hadn't run, the mouse let go), not at the next 2 s pass (rt-look)")
assert(not sync.receive_now(true, 10, 0.4, 10.41, 0.02, 10.52, false, true), "not while a redo waits: that holds the band's changes on purpose")
assert(sync.seen_mine(7, 5, 100, 99, 98.5) and not sync.seen_mine(7, 5, 100, 99, 99.5) and sync.seen_mine(5, 5, 100, 99, 99.5),
  "your last edit before the last look began: seen, whatever StudioSync's own writes did to the count since; after it: not seen (rt-look)")
assert(not sync.receive_now(false, 10, 0.4, 10.2, 0.02, 10.4, false), "nothing waiting: no pass")
assert(not sync.receive_now(true, 10, 0.4, 10.2, 0.02, 10.4, true), "not mid-drag")
assert(not sync.receive_now(true, 10, 0.4, 10.2, 1.0, 10.4, false), "a big song's pass still gets its fifth")
-- StudioSync's own writes don't move changed_at (took_in): an idle receiver applies at once
local cc, change_count, changed_at = 5, 5, 10
cc = cc + 3 -- (a receive, a heal and a paint in one tick)
change_count = cc -- took_in
if cc ~= change_count then changed_at = 50 end -- next tick's note_change: nothing new
assert(not sync.editing_now(50, changed_at, nil, sync.quiet_for(50, 49.97), false), "our own writes aren't you editing")

-- the budget, desktop -> laptop (a small song): sender settle + up to a tick + look, ~30 ms link, receiver's next tick + gate + apply
local look, link, apply = 0.03, 0.03, 0.03
local idle = sync.SETTLE + TICK + look + link + TICK + apply
local edited = idle + sync.QUIET_DIRECT
assert(idle < 0.3 and edited < 0.7, string.format("budget: %.2f s idle, %.2f s if the receiver just edited", idle, edited))
print(string.format("ok budget %.2f s idle, %.2f s worst (receiver mid-edit)", idle, edited))
