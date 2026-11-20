-- Bigger projects (James, rt: "make sure no issues with bigger projects - lots of tracks, plugins and items and MIDI, plus long (5 minutes
-- at least)"). tools/bigproject.lua's default project (150 tracks in folders with sends, 520 plug-ins, 130 of them with a 16 KB saved state,
-- 4,000 items over 7 minutes, 60 of them MIDI with 72,000 notes and 36,000 CC, automation on every track, 50 regions) served by a fake REAPER
-- (tests/fixtures/bigreaper.lua), and Live sync's work at that size timed: what runs every tick (controllers, follow, the web pages' topics
-- while a page looks at the Project page and the Mixer), the look (scan, watch, after one edit), mirror.root, colour parity, a late joiner's
-- catch-up and memory. Fails when a tick's cost goes over budget: SS_TIMING_STRICT=1 (default here) holds a desktop's figures, 0 (or CI set)
-- four times them, for a loaded runner. Also checks the two things this pass changed behave as before: mirror's hash gives the plain loop's
-- answer, and a Project page look spread over ticks publishes what one in a single tick does. docs/rt/rt-bigproj.md has the numbers.
package.path = "tools/?.lua;lib/?.lua;tests/fixtures/?.lua;" .. package.path
local env = os.getenv("SS_TIMING_STRICT")
local STRICT = env and tonumber(env) ~= 0 or (env == nil and os.getenv("CI") == nil)
local K = STRICT and 1 or 4
local G = require("bigproject")
local m = G.model()
local st = G.stats(m)
assert(st.tracks == 150 and st.fx == 520 and st.big == 130 and st.items == 4000 and st.midi == 60 and st.notes == 72000, "the project is the size asked for")
assert(m.opts.length >= 300, "and at least 5 minutes long")
local F = require("bigreaper").new(m)
reaper = F.reaper
local report = {}
local function say(fmt, ...) local s = string.format(fmt, ...); report[#report + 1] = s; print("bigproj: " .. s) end
say("%d tracks, %d plug-ins (%d big), %d items (%d MIDI, %d notes, %d CC), %d envelope points, %d regions, %d s; the .rpp is %.1f MB",
  st.tracks, st.fx, st.big, st.items, st.midi, st.notes, st.ccs, st.env_points, #m.regions, m.opts.length, #G.rpp(m) / 1048576)

-- ---- the studio's folder in memory ----
local files, logged = {}, {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) return files[path] end
proxy.write_json = function(path, v) files[path] = v; return true end
proxy.listing = function(dir)
  local out = {}
  for p in pairs(files) do local d, f = p:match("^(.*)/([^/]*)$"); if d == dir then out[#out + 1] = f end end
  return out
end
proxy.log = function(t) logged[#logged + 1] = t end
proxy.size = function() return 960044 end
proxy.copy_atomic = function() end
rawset(reaper, "file_exists", function() return true end) -- (every audio item's file is here, and its copy in the studio's media)
package.loaded.band = proxy
local mirror = require("mirror")
local sync = require("sync")
local cfg = { user = "James", root = "C:/fake/StudioSync" }
local b = { song = "Big", room = "main" }
local yes = function() return true end
local opts = { can = yes, mode = "open" }

-- ---- mirror's hash: the same answer as the plain byte loop, at every length around its 8-byte steps ----
local function fnv_plain(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
  return string.format("%08x", h)
end
do
  local parts = {}
  for i = 1, 3000 do parts[i] = string.char((i * 7919 + i // 7) % 256) end
  local s = table.concat(parts)
  for n = 0, 40 do assert(mirror.fnv(s:sub(1, n)) == fnv_plain(s:sub(1, n)), "hash of " .. n .. " bytes") end
  assert(mirror.fnv(s) == fnv_plain(s) and mirror.hash(s) == fnv_plain(s) and mirror.hash("abc") == fnv_plain("abc"), "a long text and a short one")
end

-- ---- timing helpers ----
local function ms(fn, n)
  n = n or 1
  F.reset_counts()
  local t0 = os.clock()
  local a, c
  for _ = 1, n do a, c = fn() end
  return (os.clock() - t0) / n * 1000, F.total_calls() // n, F.chunk_bytes / n / 1048576, a, c
end
local function within(what, got, budget)
  assert(got <= budget * K, string.format("%s took %.1f ms, over its budget of %.0f ms (SS_TIMING_STRICT %s)", what, got, budget * K, STRICT and "on" or "off"))
end

-- ---- the look: everything out the first time, then as Live sync's passes see it ----
local cold, passes = 0, 0
local t_cold = ms(function()
  repeat cold = cold + mirror.watch(F.proj, cfg, b.song, b.room, opts); passes = passes + 1; F.clock = F.clock + 1 until not mirror.more or passes > 50
end)
local nfiles = 0
for _ in pairs(files) do nfiles = nfiles + 1 end
assert(cold > 4000 and nfiles > 4000, "the first look sent every object (" .. cold .. ")")
F.clock = F.clock + 40 -- (past the first look's wait for plug-ins to load: their chains and automation go once)
mirror.watch(F.proj, cfg, b.song, b.room, opts)
say("first look (all %d objects out): %.0f ms in %d pass(es)", cold, t_cold, passes)
local t_scan, c_scan, mb_scan = ms(function() return mirror.scan(F.proj, cfg.user, sync.room_dir(cfg, b.song, b.room) .. "/media", false) end, 3)
say("scan, nothing changed: %.0f ms, %d REAPER calls, %.1f MB of chunks asked for", t_scan, c_scan, mb_scan)
local t_warm, c_warm, _, sent_warm = ms(function() return mirror.watch(F.proj, cfg, b.song, b.room, opts) end, 3)
assert(sent_warm == 0, "nothing changed: nothing sent")
say("look (watch), nothing changed: %.0f ms, %d REAPER calls", t_warm, c_warm)
within("a look with nothing changed", t_warm, 600)
local moved = m.tracks[20].items[5]
F.move(moved, 0.5)
local t_move, _, _, sent_move = ms(function() return mirror.watch(F.proj, cfg, b.song, b.room, opts) end)
assert(sent_move == 1, "one item moved: one change out (" .. tostring(sent_move) .. ")")
say("look after one item moved: %.0f ms (1 change out)", t_move)
local mit
for _, t in ipairs(m.tracks) do for _, it in ipairs(t.items) do if it.midi then mit = it end end end
F.midi_edit(mit, 10, 99)
local t_midi, _, _, sent_midi = ms(function() return mirror.watch(F.proj, cfg, b.song, b.room, opts) end)
assert(sent_midi == 1, "one MIDI note changed: one change out (" .. tostring(sent_midi) .. ")")
say("look after one MIDI note changed: %.0f ms (1 change out)", t_midi)
within("a look after one edit", math.max(t_move, t_midi), 800)
local t_root, c_root = ms(function() return mirror.root(F.proj) end, 5)
say("mirror.root (each pass): %.1f ms, %d REAPER calls", t_root, c_root)
within("mirror.root", t_root, 60)
local t_colour, c_colour = ms(function() require("colours").LOOK_EVERY = 0; return require("colours").look(F.proj) end, 3)
say("colour parity's look (every 5 s, in the pass): %.1f ms, %d REAPER calls", t_colour, c_colour)
within("colour parity's look", t_colour, 60)

-- ---- quick looks (rt-look, docs/rt/rt-look.md): Live sync's looks build on the last one; an edit costs what it touched ----
do
  local q = { can = yes, mode = "open", quick = true }
  F.clock = F.clock + 70 -- (past every chain's loading minute: until then each look reads them all)
  mirror.watch(F.proj, cfg, b.song, b.room, q); F.clock = F.clock + 1; mirror.watch(F.proj, cfg, b.song, b.room, q)
  -- (the fake makes the changed chunks before the clock starts: that's REAPER's work, not StudioSync's Lua)
  local function made(it) F.track_chunk(it.track); F.raw.GetItemStateChunk(it) end
  -- one edit, then the look that sends it, five times: the median (os.clock steps a millisecond on Windows, and other programs' bursts land
  -- in single looks), the REAPER calls and MB of chunks of the last, and each sent exactly one change
  local function edits(edit, what)
    local times, c, mb = {}, 0, 0
    for k = 1, 5 do
      F.clock = F.clock + 1; mirror.watch(F.proj, cfg, b.song, b.room, q) -- (the last one's send looked at again: its track is read once more)
      F.clock = F.clock + 1
      local it = edit(k)
      if it then made(it) end
      local t, calls, mbs, sent = ms(function() return mirror.watch(F.proj, cfg, b.song, b.room, q) end)
      assert(sent == (it and 1 or 0), what .. ": " .. tostring(sent) .. " change(s) out")
      times[k], c, mb = t, calls, mbs
    end
    table.sort(times)
    return times[3], c, mb
  end
  local t_qi, c_qi, mb_qi = edits(function() end, "a quick look, nothing changed")
  say("quick look, nothing changed (hints find nothing, so every chunk is read): %.0f ms, %d REAPER calls, %.1f MB of chunks", t_qi, c_qi, mb_qi)
  local mv = m.tracks[21].items[6]
  local t_qm, c_qm = edits(function(k) F.move(mv, k % 2 == 1 and 0.5 or -0.5); return mv end, "one item moved")
  say("quick look after one item moved (not selected: every chunk read, one track worked out): %.0f ms, %d REAPER calls", t_qm, c_qm)
  -- the same with the item selected, as a drag leaves it: only its track's chunk is asked for
  rawset(reaper, "CountSelectedMediaItems", function() return 1 end)
  rawset(reaper, "GetSelectedMediaItem", function() return mv end)
  local t_qs, c_qs, mb_qs = edits(function(k) F.move(mv, k % 2 == 1 and 0.25 or -0.25); return mv end, "one selected item moved")
  say("quick look after one selected item moved: %.0f ms, %d REAPER calls, %.2f MB of chunks", t_qs, c_qs, mb_qs)
  rawset(reaper, "CountSelectedMediaItems", function() return 0 end)
  local t_qn, c_qn = edits(function(k) F.midi_edit(mit, 12 + k, 70 + k); return mit end, "one MIDI note changed")
  say("quick look after one MIDI note changed (a 41 KB item normalized and sent): %.0f ms, %d REAPER calls", t_qn, c_qn)
  -- (30 ms on this desktop unloaded, when a warm full look takes ~120 ms: other agents' builds slow every figure alike, so the budget follows
  -- how slow this run's warm full look was, up to 3x. And whatever the load: an edit's quick look costs at most a quarter of the full look's,
  -- itself one sample, so not tighter)
  local slow = math.min(3, math.max(1, t_warm / 120))
  within(string.format("a quick look with nothing changed (x%.1f for this run's speed)", slow), t_qi, 30 * slow)
  within(string.format("a quick look after one item moved (x%.1f)", slow), math.max(t_qm, t_qs), 30 * slow)
  within(string.format("a quick look after one MIDI note changed (x%.1f)", slow), t_qn, 30 * slow)
  assert(math.max(t_qm, t_qs) <= t_move / 4 and t_qn <= t_midi / 4, string.format("an edit's quick look is at most a quarter of the full look's (%.0f vs %.0f, %.0f vs %.0f ms)",
    math.max(t_qm, t_qs), t_move, t_qn, t_midi))
  assert(mb_qs < 0.5, string.format("one selected item moved: %.2f MB of chunks asked for, not the whole project's", mb_qs))
  F.clock = F.clock + 1; mirror.watch(F.proj, cfg, b.song, b.room, q)
end

-- ---- every tick, with the live link up, a page on the Project page and one on the Mixer, and an edit every 8 ticks ----
local direct = require("direct")
direct.live_available = function() return true end
direct.peers = function() return { { peer = "bo" } } end
direct.behind = function() return false end
direct.send_live = function() end
direct.shared_now = function() return 1795100000 end
package.loaded.groups = setmetatable({ trusted = function() return {} end, may_manage = function() return true end, colours = function() return nil end },
  { __index = function() return function() end end })
local controllers, follow, recap, dawview, webmixer = require("controllers"), require("follow"), require("recap"), require("dawview"), require("webmixer")
controllers.pass = { can = yes, my_can = yes, who = { mode = "open" } }
local published, pub_n, pub_bytes = {}, 0, 0
local function publish(topic, t)
  local s = band.json_encode(t)
  if published[topic] ~= s then published[topic] = s; pub_n = pub_n + 1; pub_bytes = pub_bytes + #s end
end
-- the Project page's look spread over ticks publishes what one look in a single tick does (frozen clock: never spent)
dawview.action(F.proj, cfg, b, { want = true })
dawview.tick(F.proj, cfg, b, publish, nil, F.clock)
local whole = {}
for k, v in pairs(published) do whole[k] = v end
assert(whole.daw and whole.dawc0 and whole.dawc37, "the Project page's topics, every chunk of tracks")
dawview.reset(); published = {}
F.realtime = true
local was_slice = dawview.SLICE
dawview.SLICE = 0.0005
local ticks = 0
repeat ticks = ticks + 1; F.clock = F.clock + 1 / 30; dawview.tick(F.proj, cfg, b, publish, nil, F.clock) until published.daw or ticks > 2000
assert(ticks > 3, "a look this big takes several ticks at a short slice (" .. ticks .. ")")
for k, v in pairs(whole) do
  local w = (v:gsub('"me":"[^"]*",?', ""))
  assert(published[k] and (published[k]:gsub('"me":"[^"]*",?', "")) == w, "topic " .. k .. " the same spread over " .. ticks .. " ticks")
end
for k in pairs(published) do assert(whole[k], "and no topic more: " .. k) end
dawview.SLICE = was_slice
say("Project page's first look: %d topics, %.0f KB, spread over %d ticks at a 0.5 ms slice (same topics as in one tick)", pub_n, pub_bytes / 1024, ticks)
webmixer.action(F.proj, cfg, b, { want = true })
-- (os.clock's steps are a millisecond on Windows, and other programs' bursts land in single ticks: medians are held tight, the 95th
-- percentile loosely, and REAPER calls a tick, which don't vary, tightly)
local function run_ticks(n, edit_every)
  local times, calls = {}, 0
  F.realtime = true
  F.reset_counts()
  for k = 1, n do
    F.clock = F.clock + 1 / 30
    if edit_every and k % edit_every == 0 then F.cc = F.cc + 1 end -- (an edit: REAPER's change count moves; the Project page looks again)
    local t0 = os.clock()
    controllers.tick(F.proj, cfg, b)
    follow.tick(F.proj, cfg, b, -math.huge)
    recap.lane_tick(F.proj)
    dawview.tick(F.proj, cfg, b, publish, nil, F.clock)
    webmixer.tick(F.proj, cfg, b, publish, F.clock)
    if k % 30 == 0 then mirror.note_open_fx(F.proj) end -- (each second)
    controllers.settle(F.proj)
    times[#times + 1] = (os.clock() - t0) * 1000
  end
  calls = F.total_calls() // n
  F.realtime = false
  table.sort(times)
  return times[(#times + 1) // 2], times[math.floor(#times * 0.95)], calls
end
for _ = 1, 30 do F.clock = F.clock + 1 / 30; dawview.tick(F.proj, cfg, b, publish, nil, F.clock) end -- (the look the move above started, done)
local i_med, i_p95, i_calls = run_ticks(150)
say("a tick, nothing changing (controllers, follow, Project page and Mixer open): median %.1f ms, p95 %.1f ms, %d REAPER calls", i_med, i_p95, i_calls)
within("an idle tick's median", i_med, 2)
within("an idle tick's p95", i_p95, 15)
assert(i_calls <= 2500, string.format("an idle tick asks REAPER %d times, over its budget of 2,500 (150 tracks: controllers read 3 values a track twice)", i_calls))
local e_med, e_p95, e_calls = run_ticks(240, 8)
say("a tick while editing (an edit every 8 ticks: the Project page looks again, %.0f ms of it a tick): median %.1f ms, p95 %.1f ms, %d REAPER calls",
  dawview.SLICE * 1000, e_med, e_p95, e_calls)
within("an editing tick's median", e_med, dawview.SLICE * 1000 + 3)
within("an editing tick's p95", e_p95, 30)
-- the Mixer: an unchanged mix isn't encoded again, a fader moved (no undo point, so no change count) still goes out within a build
do
  local mix_sends, real = 0, publish
  local function counting(topic, t) if topic == "mix" then mix_sends = mix_sends + 1 end; return real(topic, t) end
  for _ = 1, 30 do F.clock = F.clock + 1 / 30; webmixer.tick(F.proj, cfg, b, counting, F.clock) end
  assert(mix_sends == 0, "nothing moved: the mix not handed over again (" .. mix_sends .. ")")
  F.raw.SetMediaTrackInfo_Value(m.tracks[7], "D_VOL", 0.123)
  F.cc = F.cc - 1 -- (as a fader moved by a bandmate's controller or automation: no undo point)
  for _ = 1, 9 do F.clock = F.clock + 1 / 30; webmixer.tick(F.proj, cfg, b, counting, F.clock) end
  assert(mix_sends == 1 and published.mix:find('"v":0.123', 1, true), "the moved fader went out once")
end
-- tracks deleted while a spread-out look is paused: no error, nothing read past the end, and the next look shows the project as it is
do
  F.cc = F.cc + 1
  F.realtime = true
  local was_slice = dawview.SLICE
  dawview.SLICE = 0.0005
  F.clock = F.clock + 1; dawview.tick(F.proj, cfg, b, publish, nil, F.clock) -- (a look starts, and pauses)
  for _ = 1, 100 do table.remove(m.tracks) end
  F.reindex(); F.cc = F.cc + 1
  for _ = 1, 400 do F.clock = F.clock + 1 / 30; dawview.tick(F.proj, cfg, b, publish, nil, F.clock) end
  dawview.SLICE, F.realtime = was_slice, false
  local head = band.json_decode(published.daw)
  assert(#head.tracks == 50 and head.chunks == 13, "the look after the deletion: 50 tracks in 13 chunks (" .. #head.tracks .. ", " .. tostring(head.chunks) .. ")")
end

-- ---- a late joiner's catch-up: every event read, the newest of each object picked (applying measured in REAPER: docs/rt/rt-bigproj.md) ----
do
  local names = {}
  for p in pairs(files) do local f = p:match("/events/([^/]+)$"); if f then names[#names + 1] = f end end
  local F2 = require("bigreaper").new(G.model({ tracks = 6, returns = 1, folders = 1, sends = 1, fx = 2, items = 4, midi = 1, regions = 1, markers = 1 }))
  local keep = reaper
  reaper = F2.reaper
  rawset(reaper, "file_exists", function() return true end)
  local real_receive, real_listing = mirror.receive, direct.listing
  local got = {}
  mirror.receive = function(_, ev) got[#got + 1] = ev.oid; return true end
  direct.listing = function() return names, nil end
  local bee = { user = "Bee", root = cfg.root }
  local t_catch = ms(function() return sync.receive(F2.proj, bee, b.song, b.room, yes) end)
  local seen = {}
  for _, oid in ipairs(got) do assert(not seen[oid], "the newest of each object, once: " .. oid); seen[oid] = true end
  assert(#got > 4000, "every object caught up (" .. #got .. ")")
  local t_after = ms(function() F2.clock = F2.clock + 1; return sync.receive(F2.proj, bee, b.song, b.room, yes) end, 3)
  say("late joiner: %d events read and %d objects handed to mirror.receive in %.0f ms (files in memory); a caught-up pass %.1f ms", #names, #got, t_catch, t_after)
  within("a caught-up pass over 4,000 events", t_after, 20)
  mirror.receive, direct.listing, reaper = real_receive, real_listing, keep
end

-- ---- memory ----
collectgarbage()
local mb = collectgarbage("count") / 1024
say("Lua memory after all of it: %.0f MB (mirror's memo keeps up to twice %d MB of text between looks)", mb, mirror.MEMO_BYTES // 1048576)
within("memory (MB, not ms)", mb, 400)
local missing = {}
for k in pairs(F.missing) do missing[#missing + 1] = k end
table.sort(missing)
print("bigproj: (REAPER calls the fake answers with nothing: " .. table.concat(missing, ", ") .. ")")
print("ok rt bigproj" .. (STRICT and "" or " (loose timing)"))
