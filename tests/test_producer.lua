-- lib/producer.lua's and lib/together.lua's pure parts, and the stamp reader's and sender's text
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
reaper.GetResourcePath = reaper.GetResourcePath or function() return "res" end
local together = require("together")
local producer = require("producer")
local stamp = require("stamp")

-- a follower a set way behind: on time it starts at the moment and the place...
local ev = { at = 100, pos = 30, countin = 0, lag = 2, lead = "Maya", behind = true }
local fire, from = together.plan(ev, "James", nil)
assert(fire == 102 and from == 30, "two seconds after the press, from where they pressed")
-- ...and late, it still starts from the top: by position nothing's missed
fire, from = together.plan(ev, "James", 110)
assert(fire == 110 and from == 30, "late: now, from the top")
-- without it, late means as far in as time has gone
fire, from = together.plan({ at = 100, pos = 30, countin = 0, lag = 2, lead = "Maya" }, "James", 110)
assert(fire == 110 and from == 38, "side by side keeps time")

-- the stream says they've started
local cue = producer.fast_cue({ active = true, count = 3, pos = 40 }, nil, "Maya", 500, 1.5, false)
assert(cue and cue.pos == 39.5 and cue.lead == "Maya" and cue.follow and cue.lag == 1.5 and cue.type == "start", "half a second back: the reader keeps that much before the first burst")
assert(producer.fast_cue({ active = false, count = 3, pos = 40 }, nil, "Maya", 500, 1.5, false) == nil, "not while nothing's coming")
assert(producer.fast_cue({ active = true, count = 3, pos = 40 }, nil, "Maya", 500, 1.5, true) == nil, "not when it's already going")
assert(producer.fast_cue({ active = true, count = 3, pos = 40 }, 3, "Maya", 500, 1.5, false) == nil, "not twice")
assert(producer.fast_cue({ active = true, count = 3, pos = 0.25 }, nil, "Maya", 500, 1.5, false).pos == 0, "not before the song")

-- the effects' text: what they must have to work (they're tried for real by tests/reaper/stamp_chain.lua)
assert(stamp.SEND:find("desc:StudioSync stamp send", 1, true) and stamp.READ:find("desc:StudioSync stamp read", 1, true))
assert(stamp.READ:find("options:gmem=StudioSyncStamp", 1, true), "Live sync hears from it")
for _, text in ipairs({ stamp.SEND, stamp.READ }) do
  assert(not text:find("1e%d") and not text:find("[^%w_]BIT[^_%w]"), "EEL2's names aren't case-sensitive: BIT and bit are one variable")
end
-- a producer's hands on someone's transport: only theirs, only with their say-so, only from someone producing them now, only fresh
local cue = { type = "start", at = 1000, pos = 12, rec = true, lead = "James", remote = "Maya" }
assert(producer.remote_ok(cue, "Maya", "James", "James", 1003), "for me, allowed, from my producer, 3 s old")
assert(not producer.remote_ok(cue, "Maya", nil, "James", 1003), "not allowed: nothing happens")
assert(not producer.remote_ok(cue, "Sam", "James", "James", 1003), "for someone else")
assert(not producer.remote_ok(cue, "Maya", "James", "Laptop", 1003), "from someone who isn't producing me")
assert(producer.remote_ok(cue, "Maya", "James", "Laptop, James", 1003), "one of two producing me")
assert(not producer.remote_ok(cue, "Maya", "Sam", "James", 1003), "said yes to Sam, not James: James producing me can't")
assert(not producer.remote_ok(cue, "Maya", "James", "James", 1031), "half a minute old: too late to start a take")
assert(not producer.remote_ok({ type = "start", at = 1000, lead = "James" }, "Maya", "James", "James", 1003), "an ordinary cue isn't a remote one")
print("ok")
