-- Song forks and versioned notes with client links (James, rt): lib/forks.lua and lib/review.lua's pure parts, and recall's words for a
-- client's note.
package.path = "lib/?.lua;" .. package.path
local forks = require("forks")
local review = require("review")

-- ---- forks: where they came from, in words ----
local rows = {
  { name = "main" },
  { name = "chorus ideas", parent = "main" },
  { name = "slow version", parent = "main", fork = { from = "main", label = "chorus with double guitars" } },
  { name = "old idea", parent = "main", fork = { from = "main" }, binned = "Bo" },
  { name = "main before slow", parent = "main", fork = { from = "main", label = "before 'slow' was adopted" } },
}
assert(forks.origin_words(rows[3]) == "fork of main, from 'chorus with double guitars'", forks.origin_words(rows[3]))
assert(forks.origin_words({ parent = "main", fork = {} }) == "fork of main", "no label: just where from")
assert(forks.origin_words({ parent = "main", fork = { from = "main" }, adopted = { by = "James" } }):find("adopted as main by James", 1, true), "adopted said")

-- ---- the comparison ----
local bring = {
  { obj = "track", oid = "T9", name = "Strings" },
  { obj = "fx", oid = "F9", track = "T9", name = "Strings" },
  { obj = "item", oid = "I9", track = "T9", name = "Strings" },
  { obj = "item", oid = "I1", track = "T1", name = "Bass" },
  { obj = "item", oid = "I2", track = "T1", name = "Bass" },
}
local clash = { { obj = "item", oid = "I3", track = "T2", name = "drums" } }
local newest = { I4 = { oid = "I4", name = "Bass" }, I5 = { oid = "I5", name = "Vox" }, I1 = { oid = "I1", name = "Bass", from_room = "slow version" } }
local theirs = forks.theirs(newest, "slow version")
assert(#theirs == 2, "the original's own changes, not what the fork brought there: " .. #theirs)
local t = forks.by_track(bring, clash, theirs)
assert(#t == 4 and t[1].name == "Bass" and t[2].name == "drums" and t[3].name == "Strings" and t[4].name == "Vox", "by name, any case")
assert(t[1].fork == 2 and t[1].theirs == 1 and t[1].both == 0, "Bass: two here, one there")
assert(t[2].both == 1 and t[3].fork == 3 and t[4].theirs == 1, "drums both, Strings here, Vox there")
assert(forks.by_track({ { obj = "item", oid = "x" } }, {}, {})[1].name == "(unnamed track)", "a track with no name")

-- ---- picking ----
local has = { T1 = true, I1 = true }
local function oids(list) local s = {} for _, ev in ipairs(list) do s[#s + 1] = ev.oid end return table.concat(s, ",") end
assert(oids(forks.pick(bring, { I1 = true }, has)) == "I1", "one item on a track the original has")
assert(oids(forks.pick(bring, { I9 = true }, has)) == "T9,I9", "an item on a new track brings the track")
assert(oids(forks.pick(bring, { T9 = true }, has)) == "T9,F9", "a new track brings its plug-ins, not its items")
assert(oids(forks.pick(bring, { T9 = true, F9 = true, I9 = true, I1 = true, I2 = true }, has)) == oids(bring), "everything ticked: everything, in order")
assert(oids(forks.pick(bring, { I9 = true }, { T9 = true })) == "I9", "the original has that track already: not brought again")
assert(#forks.pick(bring, {}, has) == 0, "nothing ticked")

-- ---- the old main's name ----
assert(forks.keep_name("main", "slow", {}) == "main before slow")
assert(forks.keep_name("main", "a very long fork name here", {}) == "main before a very long fork n", "cut to 30: " .. forks.keep_name("main", "a very long fork name here", {}))
assert(forks.keep_name("main", "slow", { ["main before slow"] = true }) == "main before slow 2", "taken: numbered")
local long = forks.keep_name("main", "a very long fork name here", { ["main before a very long fork n"] = true })
assert(#long <= 30 and long:match(" 2$"), "numbered within 30: " .. long)
local rooms = (function() package.loaded.band, package.loaded.sync = package.loaded.band or {}, package.loaded.sync or {}; return require("rooms") end)()
assert(rooms.bad_name(forks.keep_name("main", "x_y-z", {})) == nil and rooms.bad_name(long) == nil, "names a room takes")

-- ---- adopting: the original made exactly as the fork is ----
local pe = {
  { kind = "obj", oid = "T1", id = "p1", rev = 1, time = "2026-11-19T10:00:00Z", obj = "track", state = "track" },
  { kind = "obj", oid = "I1", id = "p2", rev = 1, time = "2026-11-19T10:01:00Z", obj = "item", state = "bass v1" },
  { kind = "obj", oid = "I2", id = "p3", rev = 1, time = "2026-11-19T11:00:00Z", obj = "item", state = "added in main after the fork" },
  { kind = "note", id = "n1", time = "2026-11-19T11:00:00Z" },
}
local fe = {
  { kind = "obj", oid = "I1", id = "f1", rev = 2, base_ev = "p2", time = "2026-11-19T10:30:00Z", obj = "item", state = "bass v2" },
  { kind = "obj", oid = "I3", id = "f2", rev = 1, time = "2026-11-19T10:40:00Z", obj = "item", state = "new in the fork" },
}
local by = {}
for _, e in ipairs(pe) do by[e.id] = e end
for _, e in ipairs(fe) do by[e.id] = e end
local plan = forks.adopt_plan(pe, fe, { T1 = "p1", I1 = "f1", I3 = "f2" }, function(id) return by[id] end)
assert(plan.T1 == by.p1, "untouched since the fork: the original's own version")
assert(plan.I1 == by.f1 and plan.I3 == by.f2, "the fork's versions, its new item too")
assert(plan.I2 == false, "what the fork hasn't got goes")
assert(plan.n1 == nil, "notes aren't objects")

-- ---- versioned notes ----
local versions = { -- newest first, as recall.list gives them
  { file = "v3.json", time = "2026-11-19T12:00:00Z" },
  { file = "v2.json", time = "2026-11-19T11:00:00Z" },
  { file = "v1.json", time = "2026-11-19T10:00:00Z" },
}
assert(review.version_n(versions, { ver = "v2.json", time = "2026-11-19T13:00:00Z" }) == 2, "named: that one")
assert(review.version_n(versions, { time = "2026-11-19T11:30:00Z" }) == 2, "an older note: by time")
assert(review.version_n(versions, { ver = "trimmed.json", time = "2026-11-19T12:30:00Z" }) == 3, "its version trimmed: by time")
assert(review.version_n(versions, { time = "2026-11-19T09:00:00Z" }) == 0 and review.version_n({}, { time = "x" }) == 0, "before the first")

local events = {
  { type = "obj", obj = "item", oid = "I1", name = "Bass", pos = 10, time = "2026-11-19T12:10:00Z", id = "e1" },
  { type = "obj", obj = "fx", oid = "F2", name = "Vox", time = "2026-11-19T12:20:00Z", id = "e2" },
  { type = "obj", obj = "item", oid = "I7", name = "Gtr", pos = 100, time = "2026-11-19T12:30:00Z", id = "e3" },
}
local note = { type = "note", id = "n", time = "2026-11-19T12:05:00Z" }
local function with(t) local n = {} for k, v in pairs(note) do n[k] = v end for k, v in pairs(t) do n[k] = v end return n end
assert(review.spot_changed(with({ item = "I1" }), events), "its item changed later")
assert(not review.spot_changed(with({ item = "I1", time = "2026-11-19T12:15:00Z" }), events), "changed only before the note")
assert(not review.spot_changed(with({ item = "I9" }), events), "another item")
assert(review.spot_changed(with({ track = "Vox", pos = 50 }), events), "the track's plug-ins changed")
assert(review.spot_changed(with({ track = "Bass", pos = 20, len = 4 }), events), "an item starting 10 s before, on its track")
assert(not review.spot_changed(with({ track = "Bass", pos = 60 }), events), "an item far before the spot")
assert(not review.spot_changed(with({ track = "Bass", pos = 5, len = 2 }), events), "an item after the stretch")
assert(review.spot_changed(with({ pos = 105 }), events), "at the cursor: any track's item there")
assert(not review.spot_changed(with({ pos = 300 }), events), "nothing there")
assert(review.spot_changed(with({ pos = 300 }), { { kind = "timeline", time = "2026-11-19T13:00:00Z", id = "t" } }), "the tempo map moved the bars")
assert(review.spot_changed(with({ take = "James-1", track = "Bass" }), { { kind = "edit", take = "James-1", time = "2026-11-19T13:00:00Z", id = "x" } }), "an old take's edit")
assert(review.words(0, false) == "made before the first saved version; unchanged since")
assert(review.words(3, true) == "made on version 3; that spot changed since")
local marks = review.marks({ with({ id = "a", item = "I1" }), { type = "like", id = "b" }, with({ id = "c", ver = "v1.json", pos = 300 }) }, versions, events)
assert(marks.a == "made on version 3; that spot changed since" and marks.b == nil and marks.c == "made on version 1; unchanged since", "notes only")
local many = {}
for i = 1, 40 do many[i] = with({ id = "m" .. i }) end
local count = 0
for _ in pairs(review.marks(many, versions, events, 30)) do count = count + 1 end
assert(count == 30, "only the notes on show")

-- ---- client links ----
assert(review.link_name("Sunset Drive", "Sunset Drive 2026-11-19 James.wav") == "Sunset Drive - Sunset Drive 2026-11-19 James", review.link_name("Sunset Drive", "Sunset Drive 2026-11-19 James.wav"))
assert(review.link_name("Caf\195\169", "a/b:c*?.wav") == "Caf\195\169 - abc", "what Windows refuses taken out, letters kept whole")
assert(review.link_name("Song", "x\\y...wav") == "Song - xy", "a backslash out, no dot at the end (Windows drops it)")
assert(review.mmss(92) == "1:32" and review.mmss(3725) == "62:05" and review.mmss(nil) == "0:00")
local tmpl = review.template("Song", "mix.wav")
local who0, none = review.parse(tmpl, "client")
assert(who0 == "client" and #none == 0, "the template alone: no comments, no name")
local who, c = review.parse("\239\187\191# a heading\nName: Dana K\n1:32 the vocal is quiet\n0:05 - intro too long\n1:02:03: late one\nbar 17 love this\n" ..
  "Bar 3: drums\nthe mix is dark\n\n  \n1:32\n", "client")
assert(who == "Dana K", "the Name line")
assert(#c == 7, "seven comments: " .. #c)
assert(c[1].at == 92 and c[1].text == "the vocal is quiet", "minutes:seconds")
assert(c[2].at == 5 and c[2].text == "intro too long", "with a dash")
assert(c[3].at == 3723 and c[3].text == "late one", "hours")
assert(c[4].bar == 17 and c[4].text == "love this" and c[5].bar == 3 and c[5].text == "drums", "bars")
assert(c[6].at == nil and c[6].bar == nil and c[6].text == "the mix is dark", "the whole mix")
assert(c[7].text == "1:32", "a time with nothing after it is kept as words")
assert(select(1, review.parse("Name:   \nhi", "x")) == "x", "an empty name: the fallback")
assert(review.key("comments.txt", "Dana", c[1]) ~= review.key("comments.txt", "Dana", c[2]) and review.key("a", "b", c[1]) == review.key("a", "b", { at = 92, text = "the vocal is quiet" }), "keys")
local text = review.notes_text("Song", "mix.wav", { with({ id = "a", user = "Bo", text = "louder", pos = 12, ver = "v2.json" }),
  { type = "like", id = "b" }, with({ id = "c", client = "Dana", user = "James", text = "dark" }) }, versions,
  function(e) return e.pos and ("bar 5, " .. review.mmss(e.pos)) or "(the whole mix)" end, { a = true })
assert(text:find("[done] bar 5, 0:12  Bo: louder  (version 2)", 1, true), text)
assert(text:find("(the whole mix)  Dana (client): dark  (version 3)", 1, true), text)
assert(not text:find("like", 1, true), "likes left out")
assert(review.notes_text("S", "m", {}, {}, tostring):find("No notes yet", 1, true))

-- ---- recall's words for a client's note ----
package.loaded.band, package.loaded.sync = {}, {}
package.loaded.recall = nil
local recall = require("recall")
assert(recall.describe({ kind = "note", client = "Dana", text = "dark" }) == "note from Dana (client) on the whole mix: dark")
assert(recall.describe({ kind = "note", client = "Dana", pos = 92, text = "quiet" }) == "note from Dana (client) at 92.00 s: quiet")
assert(recall.describe({ kind = "note", pos = 1, text = "x" }) == "note at 1.00 s: x", "a band note as before")
print("ok")
