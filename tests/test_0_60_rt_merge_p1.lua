-- rt-p1 (docs/rt/rt-p1.md): the sync-core leftovers' pure parts. Plug-in chains merged plug-in by plug-in, one controller drawn by both, and
-- which versions may be merged at all (old track pairs, chains from a StudioSync that doesn't merge them). Lua 5.4, from the repo root.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
reaper = reaper or {}
local mirror = require("mirror")

-- ---- plug-in chains (backlog 1.3, 3.13): one person's EQ change and another's compressor change both stand ----
local function chain(...) return "<FXCHAIN\n" .. table.concat({ ... }, "\n") .. "\n>\n" end
local function eq(gain, prog) return "BYPASS 0 0 0\n<VST \"VST: ReaEQ (Cockos)\" reaeq.dll 0 \"\" 1919247729<56535472656571726561657100000000> \"\"\nZXE" .. gain .. "AAAA\n" .. (prog or "AAAQAAAA") .. "\n>\nPRESETNAME \"stock\"\nWAK 0 0" end
local function comp(ratio) return "BYPASS 0 0 0\n<VST \"VST: ReaComp (Cockos)\" reacomp.dll 0 \"\" 1919247213<56535472636D70726561636F6D7000> \"\"\nY29t" .. ratio .. "AAAA\nAAAQAAAA\n>\nWAK 0 0" end
local function js(v) return "BYPASS 0 0 0\n<JS utility/volume \"\"\n" .. v .. " - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -\n>\nWAK 0 0" end
do
  local base = chain(eq("1"), comp("2"))
  local m, both = mirror.merge_fx(base, chain(eq("5"), comp("2")), chain(eq("1"), comp("9")))
  assert(m == chain(eq("5"), comp("9")) and #both == 0, "two plug-ins, one changed by each: both stand\n" .. tostring(m))
  m, both = mirror.merge_fx(base, chain(eq("5"), comp("2")), chain(eq("7"), comp("2")))
  assert(m == chain(eq("5"), comp("2")) and #both == 1 and both[1]:find("ReaEQ", 1, true), "the same plug-in changed by both: the winner's, one clash\n" .. tostring(m))
  -- each adds a plug-in: both kept, the loser's after the one it followed there
  m, both = mirror.merge_fx(base, chain(eq("1"), comp("2"), js("1")), chain(eq("1"), js("3"), comp("2")))
  assert(m == chain(eq("1"), js("3"), comp("2"), js("1")) and #both == 0, "a JS volume added by each: two, the loser's where they put it\n" .. tostring(m))
  -- one removes a plug-in, the other changes another
  m, both = mirror.merge_fx(base, chain(comp("2")), chain(eq("1"), comp("4")))
  assert(m == chain(comp("4")) and #both == 0, "one removed the EQ, the other turned the compressor: both\n" .. tostring(m))
  -- removed by one, changed by the other: the winner's word
  m, both = mirror.merge_fx(base, chain(comp("2")), chain(eq("3"), comp("2")))
  assert(m == chain(comp("2")) and #both == 1, "removed by the winner, changed by the loser: gone, a clash\n" .. tostring(m))
  m, both = mirror.merge_fx(base, chain(eq("3"), comp("2")), chain(comp("2")))
  assert(m == chain(eq("3"), comp("2")) and #both == 1, "changed by the winner, removed by the loser: the winner's, a clash\n" .. tostring(m))
  -- order: one moves the compressor first, the other changes the EQ: both
  m, both = mirror.merge_fx(base, chain(eq("6"), comp("2")), chain(comp("2"), eq("1")))
  assert(m == chain(comp("2"), eq("6")) and #both == 0, "one reordered, the other changed a plug-in: both\n" .. tostring(m))
  m, both = mirror.merge_fx(chain(eq("1"), comp("2"), js("1")), chain(comp("2"), eq("1"), js("1")), chain(eq("1"), js("1"), comp("2")))
  assert(m == chain(comp("2"), eq("1"), js("1")) and both[#both] == "\0order", "both reordered: the winner's order, a clash\n" .. tostring(m))
  -- a VST's program line is each computer's reading (fx_hash leaves it out): not a change
  m, both = mirror.merge_fx(base, chain(eq("1", "UHJvZzE="), comp("2")), chain(eq("1"), comp("8")))
  assert(m:find("Y29t8AAAA", 1, true) and #both == 0, "a program line read differently isn't a clash\n" .. tostring(m))
  -- a plug-in renamed by one (its own name stays the key), changed by the other
  local renamed = eq("1"):gsub('1919247729<56535472656571726561657100000000> ""', '1919247729<56535472656571726561657100000000> "Vocal EQ"')
  m, both = mirror.merge_fx(base, chain(renamed, comp("2")), chain(eq("1"), comp("3")))
  assert(m == chain(renamed, comp("3")) and #both == 0, "a renamed plug-in is still that plug-in\n" .. tostring(m))
  -- from no chain (an empty part) to one, on both sides; to none on the winner's
  m = mirror.merge_fx("", chain(eq("1")), chain(comp("2")))
  assert(m == chain(comp("2"), eq("1")), "a first plug-in added by each: both (the loser's first: nothing was before it)\n" .. tostring(m))
  m = mirror.merge_fx(base, "", chain(eq("1"), comp("2")))
  assert(m == "", "the winner removed every plug-in, the loser changed nothing: none\n" .. tostring(m))
  assert(mirror.merge_fx(base, "<SOURCE WAVE\n>\n", base) == nil, "not a chain: not merged")
  assert(mirror.merge_state("fx", base, chain(eq("5"), comp("2")), chain(eq("1"), comp("9"))) == chain(eq("5"), comp("9")), "through merge_state")
  -- pieces, for the claims ask (mirror.clashes): each plug-in, and the order as one
  local function changed(x, y) local n = {}; for k in pairs(mirror.pieces_changed(mirror.pieces("fx", x), mirror.pieces("fx", y))) do n[#n + 1] = k end; return n end
  assert(#changed(base, chain(eq("5"), comp("2"))) == 1 and #changed(base, base) == 0, "one plug-in changed: one piece")
  assert(#changed(base, chain(comp("2"), eq("1"))) == 1, "reordered: the order piece")
  print("rt-p1: plug-in chains merge plug-in by plug-in (each changed by one: both; the same one: the winner's; the order by whoever moved them)")
end

-- ---- one controller drawn by both over the same stretch (backlog 1.3): the winner's drawing across its run, not a zigzag of both ----
do
  local function midi(...) return "<SOURCE MIDI\nHASDATA 1 960 QN\n" .. table.concat({ ... }, "\n") .. "\nE 0 b0 7b 00\n>" end
  local function cc(list) -- { tick, value } absolute -> lines with deltas, then a note at 3840 so the end doesn't move
    local out, last = {}, 0
    for _, p in ipairs(list) do out[#out + 1] = string.format("E %d b0 01 %02x", p[1] - last, p[2]); last = p[1] end
    out[#out + 1] = string.format("E %d 90 3c 60", 3840 - last)
    out[#out + 1] = "E 240 80 3c 00"
    return table.unpack(out)
  end
  local base = midi(cc({}))
  local w = midi(cc({ { 0, 10 }, { 120, 20 }, { 240, 30 }, { 360, 40 } })) -- (the winner draws CC1 over the first beat)
  local l = midi(cc({ { 60, 100 }, { 180, 90 }, { 300, 80 }, { 2880, 5 } })) -- (the loser over the same beat, and one point three beats on)
  local m, clash = mirror.merge_midi(base, w, l)
  local function values(text) local t = {}; for v in text:gmatch("E %d+ b0 01 (%x%x)") do t[#t + 1] = tonumber(v, 16) end; return table.concat(t, ",") end
  assert(values(m) == "10,20,30,40,5" and clash, "the winner's drawing across its stretch, the loser's point elsewhere kept: " .. values(m) .. "\n" .. m)
  -- different controllers over the same stretch: both, no clash
  local l2 = midi((cc({ { 60, 100 }, { 180, 90 } }):gsub("b0 01", "b0 0b")))
  m, clash = mirror.merge_midi(base, w, l2)
  assert(values(m) == "10,20,30,40" and m:find("b0 0b 64", 1, true) and not clash, "CC1 and CC11 drawn over one beat: both\n" .. m)
  -- one stretch each, far apart on one controller: both
  local l3 = midi(cc({ { 1920, 50 }, { 2040, 60 } }))
  m, clash = mirror.merge_midi(base, w, l3)
  assert(values(m) == "10,20,30,40,50,60" and not clash, "one controller drawn in two places: both drawings\n" .. m)
  -- a base point the loser removed inside the winner's run comes back with the winner's run (theirs stands there)
  local b4 = midi(cc({ { 200, 64 } }))
  local w4 = midi(cc({ { 0, 10 }, { 200, 64 }, { 360, 40 } }))
  local l4 = midi(cc({}))
  m, clash = mirror.merge_midi(b4, w4, l4)
  assert(values(m) == "10,64,40" and clash, "inside the winner's run the winner's curve stands whole: " .. values(m))
  print("rt-p1: one controller drawn by both over one stretch: the winner's drawing there, the loser's elsewhere; other controllers both")
end

-- ---- which versions merge (backlog 1.1; and chains only between versions that merge them) ----
do
  local since = mirror.MERGE_SINCE
  mirror.MERGE_SINCE = { track = "20261120-194204", env = "20261120-194204" }
  local function tev(id) return { obj = "track", id = id, state = { name = "K" } } end
  assert(not mirror.mergeable(tev("Mac-20261120-004314Z-00001-0001")), "a track change from before track merging began: not merged")
  assert(mirror.mergeable(tev("Mac-20261120-200000Z-00001-0001")), "one from after: merged")
  assert(not mirror.mergeable(tev("m(Mac-20261120-200000Z-00001-0001&Pc-20261120-004314Z-00002-0001)")), "a merge holding an older one: not merged")
  assert(mirror.mergeable({ obj = "env", state = "" }), "a change being made (no id yet) counts as new")
  assert(mirror.mergeable({ obj = "item", id = "Mac-20261101-000000Z-00001-0001", state = "<ITEM\n>\n" }), "items merged long before: unchanged")
  mirror.MERGE_SINCE = since
  local base = chain(eq("1"))
  assert(not mirror.mergeable({ obj = "fx", id = "a", state = base }), "a chain from a StudioSync that doesn't say it merges chains: not merged")
  assert(mirror.mergeable({ obj = "fx", id = "a", state = base, mg = 1 }), "one that says so: merged")
  assert(mirror.MG >= mirror.MERGE_MG.fx, "this version says so")
  print("rt-p1: track and automation pairs from before merging began, and chains from older versions, keep the newest as every computer did")
end
-- ---- the web page's claim-ask countdown (backlog 1.4): it moved only when the presence topic changed; now every second, in place ----
do
  local fh = assert(io.open("lib/webui/app.js", "rb"))
  local js = fh:read("a")
  fh:close()
  local body = js:match("function asks%(a%) {(.-)\n}\n")
  assert(body, "app.js has asks(a)")
  assert(js:find("setInterval(() => { for (const s of document.querySelectorAll('#asks .asktill')) s.textContent = askLeft(Number(s.dataset.till)); }, 1000);", 1, true),
    "a one-second tick rewrites each ask's seconds left")
  local n = 0
  for _ in body:gmatch("askTill%(%a%.till%)") do n = n + 1 end
  assert(n == 2 and not body:find("Math.round(", 1, true), "both kinds of ask (on you, and yours) show a ticking count, none a fixed one")
  print("rt-p1: the web page's claim asks count down every second")
end
print("ok rt-p1 merge")
