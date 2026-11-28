-- The merges (rt-sync2 phase 1, docs/rt/rt-sync2a.md): two versions of one object, changed apart from one base, put together attribute by
-- attribute (an item by line, block and MIDI note; automation by point; a track by setting; a plug-in chain by plug-in), and a state cut into
-- the pieces those merges cut it into (what the claim checks compare). Pure: no REAPER, no clock, no events. Moved from lib/mirror.lua as it
-- was, which keeps mirror.merge_item = M.merge_item and so on, so its callers and tests are unchanged.
local M = {}

-- What a chunk says differently on each platform, said one way for hashing (Mac, 0.34.3: every chain with a Cockos
-- plug-in and every coloured item read "project differs" against Windows, for good). Windows' text is left as it
-- is, so nothing a Windows machine already sent hashes differently:
--   the plug-in's file: reasynth.vst.dylib (macOS), reasynth.vst.so (Linux), Foo.vst (a macOS VST2 bundle) -> .dll
--   "COLOR n B" / "TAKECOLOR n B": the colour in macOS byte order -> Windows' "n R" (REAPER converts either on load)
-- shortcut: a third-party VST2 named differently per platform (Foo_x64.dll vs Foo.vst) still reads as different.
local function portable(s)
  s = s:gsub('(<VST "[^"\n]*" "?[^"\n]-)%.vst%.dylib("? )', "%1.dll%2"):gsub('(<VST "[^"\n]*" "?[^"\n]-)%.vst%.so("? )', "%1.dll%2")
    :gsub('(<VST "[^"\n]*" "?[^"\n]-)%.vst("? )', "%1.dll%2")
  return (s:gsub("(COLOR )(%d+) B", function(p, n)
    n = math.tointeger(tonumber(n)) or 0
    local c = n & 0xFFFFFF
    return p .. ((n & ~0xFFFFFF) | ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF)) .. " R"
  end))
end

local function restless_key(line) return line:match('^<%S+%s+"([^"]*)"') or line:match("^<%S+%s+(%S+)") end

-- Two versions of an item, changed apart from one base, put together (docs/clashes.md): each line or block of the chunk (keyed by which take it's
-- in, its keyword and which of them it is) comes from whichever side changed it; where both did, the winner's stands. When both changed the
-- same take's audio or notes (its <SOURCE>), the loser's take comes along as one more take, named for them, so nothing they recorded is lost.
-- base, winner, loser: normalized item states (mirror.item_state). -> the merged state, and the keys both changed. Pure.
local ITEM_LEVEL = { POSITION = true, SNAPOFFS = true, LENGTH = true, LOOP = true, ALLTAKES = true, FADEIN = true, FADEOUT = true, MUTE = true,
  BEAT = true, COLOR = true, LOCK = true, GROUP = true, IMGRESOURCEFLAGS = true, ["<NOTES"] = true, ["<EXTI"] = true, BANDLANE = true, BANDTAKE = true }
local function elements(state)
  local els, order, nth, section, depth, block = {}, {}, {}, 0, 0, nil
  local function add(key, text)
    local k = section .. "\0" .. key
    nth[k] = (nth[k] or 0) + 1
    local full = k .. "\0" .. nth[k]
    els[full] = text
    order[#order + 1] = { key = full, section = section, word = key }
  end
  for line in (state or ""):gmatch("[^\n]+") do
    if depth == 0 then
      if line == "<ITEM" then depth = 1
      else add(line:match("^(%S+)") or line, line) end -- (BANDLANE, after the item)
    elseif depth == 1 then
      if line == ">" then depth = 0
      elseif line == "TAKE" then section = section + 1
      elseif line == "TAKE NULL" then section = section + 1; add("TAKE NULL", line) -- (an empty take: a section with only this in it)
      elseif line:sub(1, 1) == "<" then block = { word = line:match("^(%S+)"), lines = { line } }; depth = 2
      else add(line:match("^(%S+)") or line, line) end
    else
      block.lines[#block.lines + 1] = line
      if line:sub(1, 1) == "<" then depth = depth + 1 elseif line == ">" then depth = depth - 1 end
      if depth == 1 then add(block.word, table.concat(block.lines, "\n")); block = nil end
    end
  end
  return els, order
end
-- Where an item sits and what part of its source plays: one thing, not separate lines. (0.59.14, review: one person's left trim, POSITION
-- LENGTH and SOFFS, merged with another's move, POSITION alone, gave a state neither made, its audio off by the trim.)
-- (not the snap offset or the fades: one person's fade and another's snap offset are both kept, as before. merge_items suite, 0.59.14)
local TIMING = { POSITION = true, LENGTH = true, SOFFS = true, PLAYRATE = true, SM = true }
function M.merge_item(base, winner, loser, loser_name)
  local b, border = elements(base)
  local w, worder = elements(winner)
  local l, lorder = elements(loser)
  -- both changed the timing (a line of it changed, added or taken away): the winner's whole timing stands
  local w_timed, l_timed = false, false
  for _, list in ipairs({ border, worder, lorder }) do
    for _, e in ipairs(list) do
      if TIMING[e.word] then
        w_timed = w_timed or w[e.key] ~= b[e.key]
        l_timed = l_timed or l[e.key] ~= b[e.key]
      end
    end
  end
  local timing_clash = w_timed and l_timed
  local out, both, keep_take = {}, {}, {}
  local seq, at = {}, {} -- (the winner's order; what only the loser has goes in after the element it followed there)
  for _, e in ipairs(worder) do seq[#seq + 1] = e; at[e.key] = true end
  for i, e in ipairs(lorder) do
    if not at[e.key] then
      local where = 0
      for j = i - 1, 1, -1 do
        for k, x in ipairs(seq) do if x.key == lorder[j].key then where = k; break end end
        if where > 0 then break end
      end
      table.insert(seq, where + 1, e); at[e.key] = true
    end
  end
  for _, e in ipairs(seq) do
    local bv, wv, lv = b[e.key], w[e.key], l[e.key]
    if timing_clash and TIMING[e.word] then
      out[e.key] = wv
      if wv ~= lv then both[#both + 1] = e.key end
    elseif wv == lv or lv == bv then out[e.key] = wv
    elseif wv == bv then out[e.key] = lv
    else
      -- (both changed one take's MIDI: note by note, so two people adding notes keep both. rt-merge)
      local notes, clash = nil, false
      if e.word == "<SOURCE" then notes, clash = M.merge_midi(bv, wv, lv) end
      if notes then
        out[e.key] = notes
        if clash then both[#both + 1] = e.key .. "\0notes" end -- (a note both changed: the winner's. Not a take of theirs, below)
      else
        out[e.key] = wv; both[#both + 1] = e.key
        if e.word == "<SOURCE" then keep_take[e.section] = true end
      end
    end
  end
  local lines, section, after = { "<ITEM" }, 0, {}
  for _, e in ipairs(seq) do
    local v = out[e.key]
    if v and (e.word == "BANDLANE" or e.word == "BANDTAKE") then after[#after + 1] = v -- (both after the item, as mirror.item_state has them)
    elseif v then
      local null = v == "TAKE NULL"
      while section < e.section do section = section + 1; lines[#lines + 1] = (null and section == e.section) and "TAKE NULL" or "TAKE" end
      if not null then lines[#lines + 1] = v end
    end
  end
  -- the loser's own take of whatever both re-recorded: one more take, its take-level lines, named for them
  local secs = {}
  for s in pairs(keep_take) do secs[#secs + 1] = s end
  table.sort(secs)
  for _, s in ipairs(secs) do
    lines[#lines + 1] = "TAKE"
    lines[#lines + 1] = "NAME " .. string.format("%q", (loser_name or "their") .. "'s version")
    for _, e in ipairs(lorder) do
      if e.section == s and not ITEM_LEVEL[e.word] and e.word ~= "NAME" then lines[#lines + 1] = l[e.key] end
    end
  end
  lines[#lines + 1] = ">"
  return table.concat(lines, "\n") .. "\n" .. (#after > 0 and (table.concat(after, "\n") .. "\n") or ""), both
end

-- rt-merge (docs/rt/rt-merge.md): three-way merges finer than an item's lines, so two people editing one thing at once both keep their work.
-- Which side stands for one key, by what base, winner and loser hold there (nil: nothing): "w" or "l", and whether both changed it. Pure.
function M.side3(b, w, l)
  if w == l or l == b then return "w", false end
  if w == b then return "l", false end
  return "w", true
end
-- Keyed lines (`list`: { key, text } in order) of three versions put together: each key from whichever side changed it (added, changed or
-- taken away). -> the winner's order with what only the loser has after it, the texts that stand, and the keys both changed. Pure.
local function merge_keyed(bl, wl, ll)
  local b, w, l, out, both, seen = {}, {}, {}, {}, {}, {}
  for _, e in ipairs(bl) do b[e[1]] = e[2] end
  for _, e in ipairs(wl) do w[e[1]] = e[2] end
  for _, e in ipairs(ll) do l[e[1]] = e[2] end
  for _, list in ipairs({ wl, ll, bl }) do
    for _, e in ipairs(list) do
      local k = e[1]
      if not seen[k] then
        seen[k] = true
        local s, clash = M.side3(b[k], w[k], l[k])
        local v = l[k]
        if s == "w" then v = w[k] end -- (not "and/or": the winner's nil, taken away, would read as the loser's)
        if v then out[#out + 1] = { k, v } end
        if clash then both[#both + 1] = k end
      end
    end
  end
  return out, both
end
-- One thing moved by both. A note or an automation point has no id: a move reads as one taken away and one added, so a note both people
-- moved ended up twice, once where each put it (and a note the winner changed in place, twice: theirs, and the loser's moved copy). Now the
-- same note or point is one thing: where the loser moved it and the winner changed it too (moved, changed in place, or removed), the
-- winner's stands whole and the loser's moved copy is left out, as a clash (the loser is told, with Use mine, as for any clash).
-- Which of the loser's added things is a base thing moved is only told where it's plain: among things of one kind (`group`: a note's channel,
-- length and velocity, which a move keeps; an envelope's points), the loser took away exactly as many as it added. Then they pair in order
-- (`pos`), which holds for one thing moved, a selection dragged, and everything shifted. Other counts (some deleted, some new, of one kind):
-- not paired, both copies stay as before, rather than risk leaving out a note that was new.
-- `loose` (optional): a wider kind, asked the same of what `group` left unpaired: a note moved and resized at once keeps its channel and
-- velocity, not its length, so it was never paired and stayed doubled. Paired only on the same plain count, so the risk is the one `group`
-- already takes: a note deleted and another drawn in its place, of the same channel and velocity, read as that note moved; it's left out only
-- where the winner changed the deleted note too, and the loser is told, with Use mine. (rt-edits round 5)
-- b, w, l: key -> its text (nil: not there); border, lorder: the base's and the loser's keys in order; group(side, key) -> a kind or nil;
-- pos(side, key) -> a number. -> the loser's keys to leave out. Pure. rt-edits, backlog 1
-- (move_pairs: the pairing on its own, for one side `s` ("l" or "w") of what it holds (`x`, its keys in order `xorder`): base key -> that side's
-- moved copy. merge_midi pairs both sides' moves, so a note one moved and the other changed is merged by what each changed. rt-p1)
local function move_pairs(border, b, x, xorder, s, group, pos, loose)
  local gone, added, out = {}, {}, {}
  for _, k in ipairs(border) do if x[k] == nil then gone[#gone + 1] = k end end
  if #gone == 0 then return out end
  for _, k in ipairs(xorder) do if b[k] == nil then added[#added + 1] = k end end
  for _, kind in ipairs({ group, loose }) do
    local G, A = {}, {}
    for _, k in ipairs(gone) do local g = kind("b", k); if g then G[g] = G[g] or {}; G[g][#G[g] + 1] = k end end
    for _, k in ipairs(added) do local g = kind(s, k); if g and G[g] then A[g] = A[g] or {}; A[g][#A[g] + 1] = k end end
    for g, list in pairs(G) do
      local a = A[g]
      if a and #a == #list then
        local function by(side) return function(p, q) local pp, pq = pos(side, p), pos(side, q); if pp ~= pq then return pp < pq end; return p < q end end
        table.sort(list, by("b"))
        table.sort(a, by(s))
        for i, k in ipairs(list) do out[k] = a[i] end
      end
    end
    local paired = {}
    for k, v in pairs(out) do paired[k], paired[v] = true, true end
    local g2, a2 = {}, {} -- (what's left, for the looser kind)
    for _, k in ipairs(gone) do if not paired[k] then g2[#g2 + 1] = k end end
    for _, k in ipairs(added) do if not paired[k] then a2[#a2 + 1] = k end end
    gone, added = g2, a2
  end
  return out
end
local function moved_twice(border, b, w, l, lorder, group, pos, loose)
  local out = {}
  for k, a in pairs(move_pairs(border, b, l, lorder, "l", group, pos, loose or function() end)) do
    if w[k] ~= b[k] and w[a] == nil then out[a] = true end -- (the winner changed that one too, and not by the same move)
  end
  return out
end
-- Keys for lines: the first word, and which of that word it is ("PT 4.5": a point, by its time, when `pt`).
local function keyed_lines(lines, pt)
  local nth, out = {}, {}
  for _, t in ipairs(lines) do
    local word = t:match("^(%S+)") or t
    if pt and word == "PT" then word = "PT " .. string.format("%.10g", tonumber(t:match("^PT%s+(%S+)")) or 0) end
    nth[word] = (nth[word] or 0) + 1
    out[#out + 1] = { word .. "#" .. nth[word], t }
  end
  return out
end

-- A MIDI take's source block (<SOURCE MIDI or MIDIPOOL) as notes and events. -> { head, tail (lines or blocks before and after the events),
-- units (key -> { cmp, evs }), order, ppq }, or nil when it isn't one or has something between its events it doesn't know. Pure.
-- A note is a note-on with the next note-off of its channel and pitch, keyed by channel, pitch and start; any other event by its tick, status and
-- first byte (a SysEx or text event <X ...> by its tick and data); the end-of-source event (the last, a CC 123) is one unit, END.
-- Selection (lower-case e) doesn't count as a change: it's each person's own.
local function midi_read(block)
  if type(block) ~= "string" then return nil end
  local lines = {}
  for l in block:gmatch("[^\n]+") do lines[#lines + 1] = l end
  local kind = lines[1] and lines[1]:match("^<SOURCE (%S+)$")
  if not (kind == "MIDI" or kind == "MIDIPOOL") or lines[#lines] ~= ">" then return nil end
  local head, tail, evs, tick, i = {}, {}, {}, 0, 2
  local function other(text) if #evs > 0 then tail[#tail + 1] = text else head[#head + 1] = text end end
  while i < #lines do
    local l = lines[i]
    local flag, d, rest = l:match("^([Ee]m?)%s+(%d+)%s*(.*)$")
    local xflag, xd, xrest = l:match("^<([Xx]m?)%s+(%d+)%s*(.*)$")
    if flag then
      if #tail > 0 then return nil end
      tick = tick + tonumber(d)
      evs[#evs + 1] = { tick = tick, flag = flag, bytes = rest }
    elseif xflag then
      if #tail > 0 then return nil end
      tick = tick + tonumber(xd)
      local body = {}
      i = i + 1
      while i < #lines and lines[i] ~= ">" do body[#body + 1] = lines[i]; i = i + 1 end
      if i >= #lines then return nil end
      evs[#evs + 1] = { tick = tick, flag = "<" .. xflag, bytes = xrest, body = table.concat(body, "\n") }
    elseif l:sub(1, 1) == "<" then -- (another block, before or after the events: kept whole)
      local b, depth = { l }, 1
      while depth > 0 do
        i = i + 1
        if i >= #lines then return nil end
        b[#b + 1] = lines[i]
        if lines[i]:sub(1, 1) == "<" then depth = depth + 1 elseif lines[i] == ">" then depth = depth - 1 end
      end
      other(table.concat(b, "\n"))
    else other(l) end
    i = i + 1
  end
  local units, order, open, nth = {}, {}, {}, {}
  local function add(key, cmp, list)
    nth[key] = (nth[key] or 0) + 1
    key = key .. "#" .. nth[key]
    units[key] = { cmp = cmp, evs = list }
    order[#order + 1] = key
  end
  local function plain(ev) return ev.tick .. " " .. ev.flag:upper() .. " " .. ev.bytes .. (ev.body and ("\n" .. ev.body) or "") end
  local function hex(ev) local s, a, b = ev.bytes:match("^(%x%x)%s+(%x%x)%s+(%x%x)") ; if s then return tonumber(s, 16), tonumber(a, 16), tonumber(b, 16) end end
  for k, ev in ipairs(evs) do
    local s, a, v = nil, nil, nil
    if not ev.body then s, a, v = hex(ev) end
    local ch = s and (s & 0x0F)
    if s and s >= 0x90 and s <= 0x9F and v > 0 then
      local id = ch .. " " .. a
      open[id] = open[id] or {}
      table.insert(open[id], ev)
      ev.on = true
    elseif s and ((s >= 0x80 and s <= 0x8F) or (s >= 0x90 and s <= 0x9F and v == 0)) and open[ch .. " " .. a] and #open[ch .. " " .. a] > 0 then
      local on = table.remove(open[ch .. " " .. a], 1)
      on.off, ev.paired = ev, true
    elseif k == #evs and s and s >= 0xB0 and s <= 0xBF and a == 0x7B then ev.ending = true end
  end
  for _, ev in ipairs(evs) do
    if ev.ending then add("END", plain(ev), { ev })
    elseif ev.on and ev.off then
      local s, a = hex(ev)
      add(string.format("N %d %d %d", s & 0x0F, a, ev.tick), plain(ev) .. "|" .. plain(ev.off), { ev, ev.off })
    elseif not ev.paired then
      local s, a = hex(ev)
      add(ev.body and ("X " .. ev.tick .. " " .. ev.body) or string.format("E %d %s %s", ev.tick, s or ev.bytes, a or ""), plain(ev), { ev })
    end
  end
  return { first = lines[1], head = head, tail = tail, units = units, order = order }
end
-- (merge_midi's note helpers, shared with mirror.clashes so the claim judgement pairs a moved note as the merge does: rt-fix6a)
local function midi_cmps(x) local t = {}; for k, u in pairs(x.units) do t[k] = u.cmp end; return t end
-- group, pos, loose for move_pairs over `sides` (side letter -> a midi_read):
local function note_keys(sides)
  local info = {}
  local function note(side, k) -- -> its kind (channel, length, velocity, mute), place (tick, then pitch) and kind less its length, once per key
    local n = info[side .. k]
    if n == nil then
      local ch, pitch, tick = k:match("^N (%d+) (%d+) (%d+)#")
      local u = ch and sides[side].units[k]
      local rest = u and u.evs[2] and (u.evs[1].flag:upper() .. " " .. tostring(u.evs[1].bytes:match("^%x%x%s+%x%x%s+(.*)$")))
      n = rest and { ch .. " " .. (u.evs[2].tick - u.evs[1].tick) .. " " .. rest, tonumber(tick) * 128 + tonumber(pitch), ch .. " " .. rest } or false
      info[side .. k] = n
    end
    return n
  end
  return function(side, k) local n = note(side, k); return n and n[1] end,
    function(side, k) return note(side, k)[2] end,
    function(side, k) local n = note(side, k); return n and n[3] end
end
local function note_parts(u) -- a note's start, length, channel, pitch, on velocity and the rest, flags, and its note-off's status, velocity and rest
  local on, off = u.evs[1], u.evs[2]
  local s, p, v, rest = on.bytes:match("^(%x%x)%s+(%x%x)%s+(%x%x)(.*)$")
  local os_, _, ov, orest = off.bytes:match("^(%x%x)%s+(%x%x)%s+(%x%x)(.*)$")
  if not (s and os_) then return nil end
  s, os_ = tonumber(s, 16), tonumber(os_, 16)
  return { start = on.tick, len = off.tick - on.tick, ch = s & 0x0F, pitch = tonumber(p, 16), vel = v, rest = rest, flag = on.flag:upper(), offs = os_ & 0xF0,
    offv = ov, orest = orest, oflag = off.flag:upper() }
end
-- An item's MIDI notes that one version (`a`) moved or changed into the next (`b`), paired as merge_midi pairs a move: mirror.pieces' key of the
-- note in `b` -> { from = its key in `a`, fields = { [part] = true } for each part of it that changed (start, pitch, len, vel...) }. Pure.
function M.note_changes(a, b)
  local out = {}
  if type(a) ~= "string" or type(b) ~= "string" then return out end
  local ea = elements(a)
  local eb, order = elements(b)
  for _, e in ipairs(order) do
    local ta, tb = ea[e.key], eb[e.key]
    local A = e.word == "<SOURCE" and ta and ta ~= tb and midi_read(ta)
    local B = A and midi_read(tb)
    if A and B then
      local ca, cb = midi_cmps(A), midi_cmps(B)
      local group, pos, loose = note_keys({ b = A, w = B })
      local paired = move_pairs(A.order, ca, cb, B.order, "w", group, pos, loose)
      for k in pairs(A.units) do if cb[k] and cb[k] ~= ca[k] then paired[k] = k end end -- (changed in place: its velocity, say)
      for ka, kb in pairs(paired) do
        local ua, ub = A.units[ka], B.units[kb]
        local pa, pb = ua and ua.evs[2] and note_parts(ua), ub and ub.evs[2] and note_parts(ub)
        if pa and pb then
          local f = {}
          for n, v in pairs(pa) do if pb[n] ~= v then f[n] = true end end
          out[e.key .. "\0" .. kb] = { from = e.key .. "\0" .. ka, fields = f }
        end
      end
    end
  end
  return out
end
-- Two versions of a MIDI take's notes, changed apart from one base, put together note by note (docs/rt/rt-merge.md): each note or event from
-- whichever side changed it, added or taken away; where both changed the same note, the winner's stands. A note moved is one taken away and one
-- added, so two people moving one note differently keep both copies. -> the merged block and whether a note clashed, or nil when any of the
-- three can't be read as notes (the take-copy rule stands) or they differ in ticks per quarter note. Pure.
function M.merge_midi(base, winner, loser)
  local b, w, l = midi_read(base), midi_read(winner), midi_read(loser)
  if not (b and w and l) then return nil end
  local function ppq(x) for _, t in ipairs(x.head) do local q = t:match("^HASDATA%s+%S+%s+(%S+)") if q then return q end end end
  if ppq(b) ~= ppq(w) or ppq(w) ~= ppq(l) then return nil end
  local clash, chosen = false, {}
  local cmps = midi_cmps
  -- (a note one side moved, in time or pitch, that the other changed too (moved, resized, its velocity or mute): one note, made of what each
  -- changed, and where both changed the same thing (its start, pitch, length, velocity, mute) the winner's. A transposition and a move in time
  -- both stand. A note the winner removed stays removed. Before, the winner's note stood whole: a pitch change counted as a move. rt-p1)
  local cb, cw, cl = cmps(b), cmps(w), cmps(l)
  local group, pos, loose = note_keys({ b = b, w = w, l = l })
  local pw, pl = move_pairs(b.order, cb, cw, w.order, "w", group, pos, loose), move_pairs(b.order, cb, cl, l.order, "l", group, pos, loose)
  local drop = {}
  local parts = note_parts
  for _, k in ipairs(b.order) do
    local mw, ml = pw[k], pl[k]
    local vw, vl = w.units[mw or k], l.units[ml or k]
    if (mw or ml) and mw ~= ml and vw and vl and (mw or cw[k] ~= cb[k]) and (ml or cl[k] ~= cb[k]) and b.units[k].evs[2] then
      local pb, pw_, pl_ = parts(b.units[k]), parts(vw), parts(vl)
      if pb and pw_ and pl_ then
        local n = {}
        for f in pairs(pb) do
          local s, c = M.side3(pb[f], pw_[f], pl_[f])
          n[f] = s == "w" and pw_[f] or pl_[f]
          clash = clash or c
        end
        drop[k] = true
        if mw then drop[mw] = true end
        if ml then drop[ml] = true end
        local on = { tick = n.start, flag = n.flag, bytes = string.format("%02x %02x %s%s", 0x90 | n.ch, n.pitch, n.vel, n.rest), on = true }
        local off = { tick = n.start + n.len, flag = n.oflag, bytes = string.format("%02x %02x %s%s", n.offs | n.ch, n.pitch, n.offv, n.orest), paired = true }
        chosen[#chosen + 1], chosen[#chosen + 2] = on, off
      end
    end
  end
  -- (a note the loser moved that the winner removed: gone, as the winner left it. moved_twice)
  for a in pairs(moved_twice(b.order, cb, cw, cl, l.order, group, pos, loose)) do if not drop[a] then drop[a], clash = true, true end end
  -- (one controller (or pitch bend, pressure) drawn by both over the same stretch: the winner's drawing stands across each run of ticks it
  -- changed, and the loser's points inside it go, so the two curves aren't interleaved into a zigzag. The loser's drawing elsewhere stays. A
  -- run is changed points no more than a quarter note apart. rt-p1)
  local force_w = {}
  do
    local function lane(k) -- -> a lane name and the tick, for a CC, pitch bend, channel or poly pressure event
      local tick, st, a = k:match("^E (%d+) (%d+) (%d*)#")
      st = tonumber(st)
      if not st then return nil end
      local hi = st & 0xF0
      if hi == 0xB0 or hi == 0xA0 then return st .. " " .. a, tonumber(tick) end
      if hi == 0xE0 or hi == 0xD0 then return tostring(st), tonumber(tick) end
    end
    local quarter = tonumber(ppq(b) or "") or 960
    local runs, lanes = {}, {}
    for _, x in ipairs({ w, b }) do
      for _, k in ipairs(x.order) do
        local ln, t = lane(k)
        if ln and cw[k] ~= cb[k] then runs[ln] = runs[ln] or {}; runs[ln][#runs[ln] + 1] = t end
      end
    end
    for ln, ticks in pairs(runs) do
      table.sort(ticks)
      local list, lo, hi = {}, ticks[1], ticks[1]
      for i = 2, #ticks + 1 do
        local t = ticks[i]
        if t and t - hi <= quarter then hi = t else list[#list + 1] = { lo, hi }; lo, hi = t, t end
      end
      lanes[ln] = list
    end
    for _, x in ipairs({ l, b }) do
      for _, k in ipairs(x.order) do
        local ln, t = lane(k)
        if ln and lanes[ln] and cl[k] ~= cb[k] and cw[k] == cb[k] then
          for _, r in ipairs(lanes[ln]) do if t >= r[1] and t <= r[2] then force_w[k], clash = true, true end end
        end
      end
    end
  end
  local seen = {}
  for _, x in ipairs({ w, l, b }) do
    for _, k in ipairs(x.order) do
      if not seen[k] and not drop[k] then
        seen[k] = true
        local bu, wu, lu = b.units[k], w.units[k], l.units[k]
        local s, c = M.side3(bu and bu.cmp, wu and wu.cmp, lu and lu.cmp)
        if force_w[k] then s = "w" end
        clash = clash or c
        local u = lu
        if s == "w" then u = wu end
        if u then for _, ev in ipairs(u.evs) do chosen[#chosen + 1] = ev end end
      end
    end
  end
  -- the end never before a note the other side put later
  local top = 0
  for _, ev in ipairs(chosen) do if not ev.ending then top = math.max(top, ev.tick) end end
  for i, ev in ipairs(chosen) do
    if ev.ending and ev.tick < top then chosen[i] = { tick = top, flag = ev.flag, bytes = ev.bytes, ending = true } end
  end
  -- in time order; at one tick note-offs first, then other events, then note-ons, the end last (then by text: the same everywhere)
  local function class(ev) return ev.ending and 3 or ev.on and 2 or ev.paired and 0 or 1 end
  local function text(ev) return ev.flag .. " " .. ev.bytes .. (ev.body or "") end
  table.sort(chosen, function(x, y)
    if x.tick ~= y.tick then return x.tick < y.tick end
    if class(x) ~= class(y) then return class(x) < class(y) end
    return text(x) < text(y)
  end)
  local lines, last = { w.first }, 0
  local hb, hw, hl = keyed_lines(b.head), keyed_lines(w.head), keyed_lines(l.head)
  for _, e in ipairs((merge_keyed(hb, hw, hl))) do lines[#lines + 1] = e[2] end
  for _, ev in ipairs(chosen) do
    local d = ev.tick - last
    last = ev.tick
    if ev.body then
      lines[#lines + 1] = ev.flag .. " " .. d .. (ev.bytes ~= "" and (" " .. ev.bytes) or "")
      lines[#lines + 1] = ev.body
      lines[#lines + 1] = ">"
    else lines[#lines + 1] = ev.flag .. " " .. d .. " " .. ev.bytes end
  end
  for _, e in ipairs((merge_keyed(keyed_lines(b.tail), keyed_lines(w.tail), keyed_lines(l.tail)))) do lines[#lines + 1] = e[2] end
  lines[#lines + 1] = ">"
  return table.concat(lines, "\n"), clash
end

-- A track's automation (mirror.track_parts' "env": its envelope blocks and their automation item lines), changed apart from one base, put
-- together point by point: each envelope by its name (which of that name), each point by its time, each other line by its word. Where both
-- changed the same point or setting the winner's stands. -> the merged state and the keys both changed. Pure.
local function env_units(state) -- (its envelope blocks and lone lines, each keyed by its name and which of that name it is)
  local out, nth, cur = {}, {}, nil
  for line in (state or ""):gmatch("[^\n]+") do
    if cur then
      cur.lines[#cur.lines + 1] = line
      if line:sub(1, 1) == "<" then cur.depth = cur.depth + 1 elseif line == ">" then cur.depth = cur.depth - 1 end
      if cur.depth == 0 then cur = nil end
    elseif line:sub(1, 1) == "<" then
      local tag = line:match("^<(%S+)") or line
      nth[tag] = (nth[tag] or 0) + 1
      cur = { key = "<" .. tag .. "#" .. nth[tag], lines = { line }, depth = 1 }
      out[#out + 1] = cur
    else
      local word = line:match("^(%S+)") or line
      nth[word] = (nth[word] or 0) + 1
      out[#out + 1] = { key = word .. "#" .. nth[word], lines = { line }, depth = 0 }
    end
  end
  return out
end
function M.merge_env(base, winner, loser)
  local units = env_units
  local function flat(u) return table.concat(u.lines, "\n") end
  local function list(us) local t = {}; for _, u in ipairs(us) do t[#t + 1] = { u.key, flat(u) } end; return t end
  local bu, wu, lu = units(base), units(winner), units(loser)
  local merged, both = merge_keyed(list(bu), list(wu), list(lu))
  local function by(us) local t = {}; for _, u in ipairs(us) do t[u.key] = u end; return t end
  local B, W, L = by(bu), by(wu), by(lu)
  local out = {}
  for i, e in ipairs(merged) do
    local k = e[1]
    local b, w, l = B[k], W[k], L[k]
    -- (an envelope both changed: point by point, when it's one level of lines inside)
    local inner = b and w and l and #w.lines > 2 and flat(w) ~= flat(l) and flat(w) ~= flat(b) and flat(l) ~= flat(b)
    local function body(u)
      local t = {}
      for j = 2, #u.lines - 1 do
        if u.lines[j]:sub(1, 1) == "<" then return nil end
        t[#t + 1] = u.lines[j]
      end
      return t
    end
    local bb, wb, lb = inner and body(b), inner and body(w), inner and body(l)
    if bb and wb and lb then
      -- (a point the loser moved that the winner changed too: one point, the winner's. moved_twice)
      local kb, kw, kl = keyed_lines(bb, true), keyed_lines(wb, true), keyed_lines(lb, true)
      local function map(list) local t, order = {}, {}; for n, x in ipairs(list) do t[x[1]], order[n] = x[2], x[1] end; return t, order end
      local mb, ob = map(kb)
      local ml, ol = map(kl)
      local function at(key) return tonumber(key:match("^PT (%S+)#")) end
      local drop = moved_twice(ob, mb, (map(kw)), ml, ol, function(_, key) return at(key) and "PT" end, function(_, key) return at(key) end)
      local dropped = {}
      if next(drop) then
        local kept = {}
        for _, x in ipairs(kl) do if drop[x[1]] then dropped[#dropped + 1] = x[1] else kept[#kept + 1] = x end end
        kl = kept
      end
      local m, c = merge_keyed(kb, kw, kl)
      for _, x in ipairs(dropped) do c[#c + 1] = x end
      for j = #both, 1, -1 do if both[j] == k then table.remove(both, j) end end
      for _, x in ipairs(c) do both[#both + 1] = k .. " " .. x end
      local pts, rest = {}, {}
      for _, x in ipairs(m) do if x[1]:sub(1, 3) == "PT " then pts[#pts + 1] = x else rest[#rest + 1] = x[2] end end
      table.sort(pts, function(p, q)
        local tp, tq = tonumber(p[1]:match("^PT (%S+)#")), tonumber(q[1]:match("^PT (%S+)#"))
        if tp ~= tq then return tp < tq end
        return tonumber(p[1]:match("#(%d+)$")) < tonumber(q[1]:match("#(%d+)$"))
      end)
      local t = { w.lines[1] }
      for _, x in ipairs(rest) do t[#t + 1] = x end
      for _, x in ipairs(pts) do t[#t + 1] = x[2] end
      t[#t + 1] = ">"
      out[i] = table.concat(t, "\n")
    else out[i] = e[2] end
  end
  return #out > 0 and (table.concat(out, "\n") .. "\n") or "", both
end

-- A track's settings (mirror.track_state), changed apart from one base, put together setting by setting: one renames it while another turns it
-- up, and both stand. Lanes (how many, which play, their names, the mode) go together. Numbers compare as numbers (0 and 0.0 are one). -> the
-- merged state and the settings both changed. Pure.
-- (a track's folder is its parent and its depth together: merged apart, one side's parent with the other's depth made a folder neither had,
-- and an older StudioSync, which puts the depth in place, another tree than the parent gives. rt-sync2d)
local TRACK_TOGETHER = { freemode = "lanes", lanes = "lanes", plays = "lanes", lanenames = "lanes", parent = "folder", depth = "folder" }
function M.merge_track(base, winner, loser)
  local function norm(v) if v == nil then return nil end; local n = tonumber(v); return n and string.format("%.10g", n) or tostring(v) end
  local keys, out, both = {}, {}, {}
  for _, t in ipairs({ base, winner, loser }) do for k in pairs(t) do keys[k] = true end end
  local together = {} -- group -> both changed some part of it
  for k in pairs(keys) do
    local g = TRACK_TOGETHER[k]
    if g then
      local cw, cl = norm(winner[k]) ~= norm(base[k]), norm(loser[k]) ~= norm(base[k])
      together[g] = together[g] or { w = false, l = false }
      together[g].w, together[g].l = together[g].w or cw, together[g].l or cl
    end
  end
  for k in pairs(keys) do
    local g = TRACK_TOGETHER[k]
    if g and together[g].w and together[g].l then
      out[k] = winner[k]
      if norm(winner[k]) ~= norm(loser[k]) then both[#both + 1] = k end
    elseif g and together[g].l then out[k] = loser[k]
    elseif g then out[k] = winner[k]
    else
      local wv, lv = winner[k], loser[k]
      if k == "rank" then wv, lv = wv == nil and base[k] or wv, lv == nil and base[k] or lv end -- (a version from before ranks says nothing of the place: unchanged. rt-sync2c)
      local s, c = M.side3(norm(base[k]), norm(wv), norm(lv))
      out[k] = lv
      if s == "w" then out[k] = wv end
      if c then both[#both + 1] = k end
    end
  end
  table.sort(both)
  return out, both
end

-- A plug-in chain (mirror.fxchain's text) as its pieces: the lines before the first plug-in, then each plug-in (from its BYPASS line to the
-- line before the next one's, its saved data, preset name and lanes with it) keyed by the name REAPER gives the plug-in itself (not one you
-- renamed it to) and which of that name it is. FX ids are each computer's own and never travel (FX_LOCAL), so the name is what all agree on.
-- -> { head = { lines }, units = { { key, text, cmp } }, last } or nil when it isn't a chain. Pure. rt-p1
local function fx_units(state)
  if state == "" then return { head = {}, units = {}, last = ">" } end
  local lines = {}
  for l in (state or ""):gmatch("[^\n]+") do lines[#lines + 1] = l end
  if lines[1] ~= "<FXCHAIN" or lines[#lines] ~= ">" then return nil end
  local head, units, nth, depth, cur = {}, {}, {}, 1, nil
  local function cmp(text) -- (as fx_hash reads a plug-in: its file named one way on every platform, a VST's program line left out)
    local ls = {}
    for l in portable(text):gmatch("[^\n]+") do ls[#ls + 1] = l end
    for i = #ls, 1, -1 do
      if ls[i]:match("^<VST") then
        local j = i + 1
        while j <= #ls and ls[j] ~= ">" and ls[j]:sub(1, 1) ~= "<" do j = j + 1 end
        if ls[j] == ">" and j - i - 1 >= 2 and ls[j - 1]:match("^[A-Za-z0-9+/]+=*$") then table.remove(ls, j - 1) end
      end
    end
    return table.concat(ls, "\n")
  end
  local function close() if cur then cur.text = table.concat(cur.lines, "\n"); cur.cmp = cmp(cur.text); cur.lines = nil end end
  for i = 2, #lines - 1 do
    local l = lines[i]
    if depth == 1 and l:match("^BYPASS ") then close(); cur = { lines = { l } }; units[#units + 1] = cur
    elseif cur then
      if not cur.key and l:sub(1, 1) == "<" then
        local name = (l:match("^<(%S+)") or "") .. " " .. (restless_key(l) or "")
        nth[name] = (nth[name] or 0) + 1
        cur.key = name .. "#" .. nth[name]
      end
      cur.lines[#cur.lines + 1] = l
    else head[#head + 1] = l end
    if l:sub(1, 1) == "<" then depth = depth + 1 elseif l == ">" then depth = depth - 1 end
  end
  close()
  for i, u in ipairs(units) do if not u.key then u.key = "?" .. i end end -- (a BYPASS with no plug-in after it: by its place)
  return { head = head, units = units, last = ">" }
end
-- Two versions of a track's plug-in chain, changed apart from one base, put together plug-in by plug-in: one person's EQ change and another's
-- compressor change both stand, and so do plug-ins each added. The same plug-in changed by both: the winner's. The order: whoever moved
-- plug-ins round, with what the other added put in after the plug-in it followed there; both moved them: the winner's order (a clash).
-- -> the merged chain and the keys both changed, or nil when one isn't a chain. Pure. (backlog 1.3 and 3.13: one chain stood, the other was
-- told with Use mine.) rt-p1
function M.merge_fx(base, winner, loser)
  local b, w, l = fx_units(base), fx_units(winner), fx_units(loser)
  if not (b and w and l) then return nil end
  local function by(x) local t, order = {}, {}; for i, u in ipairs(x.units) do t[u.key], order[i] = u, u.key end; return t, order end
  local B, ob = by(b)
  local W, ow = by(w)
  local L, ol = by(l)
  -- (the same kind of plug-in added by both, unlike: two plug-ins, not one clash. Nothing was there to clash over)
  for i, k in ipairs(ol) do
    if not B[k] and W[k] and L[k].cmp ~= W[k].cmp then local k2 = k .. "\0l"; L[k2], L[k], ol[i] = L[k], nil, k2 end
  end
  local both, text = {}, {}
  for _, list in ipairs({ ow, ol }) do
    for _, k in ipairs(list) do
      if text[k] == nil then
        local s, c = M.side3(B[k] and B[k].cmp, W[k] and W[k].cmp, L[k] and L[k].cmp)
        local u = L[k]
        if s == "w" then u = W[k] end -- (not "and/or": the winner's nil, taken away, would read as the loser's)
        text[k] = u and u.text or false
        if c then both[#both + 1] = k end
      end
    end
  end
  -- the order: did either side move plug-ins it shares with the base?
  local function moved(o)
    local inb, a, c = {}, {}, {}
    for _, k in ipairs(o) do inb[k] = true end
    for _, k in ipairs(ob) do if inb[k] then a[#a + 1] = k end end
    local inx = {}
    for _, k in ipairs(ob) do inx[k] = true end
    for _, k in ipairs(o) do if inx[k] then c[#c + 1] = k end end
    return table.concat(a, "\0") ~= table.concat(c, "\0")
  end
  local mw, ml = moved(ow), moved(ol)
  local first, second = ow, ol
  if ml and not mw then first, second = ol, ow end
  if mw and ml and table.concat(ow, "\0") ~= table.concat(ol, "\0") then both[#both + 1] = "\0order" end
  local seq, at = {}, {}
  for _, k in ipairs(first) do seq[#seq + 1] = k; at[k] = true end
  for i, k in ipairs(second) do
    if not at[k] then
      local where = 0
      for j = i - 1, 1, -1 do
        for n, x in ipairs(seq) do if x == second[j] then where = n; break end end
        if where > 0 then break end
      end
      table.insert(seq, where + 1, k); at[k] = true
    end
  end
  local out = { "<FXCHAIN" }
  local hb, hw, hl = keyed_lines(b.head), keyed_lines(w.head), keyed_lines(l.head)
  local head, hboth = merge_keyed(hb, hw, hl)
  for _, e in ipairs(head) do out[#out + 1] = e[2] end
  for _, k in ipairs(hboth) do both[#both + 1] = "head " .. k end
  for _, k in ipairs(seq) do if text[k] then out[#out + 1] = text[k] end end
  if #out == 1 then return (#w.units == 0 and winner) or (#l.units == 0 and loser) or "<FXCHAIN\n>\n", both end -- (nothing left: as the side that emptied it)
  out[#out + 1] = ">"
  return table.concat(out, "\n") .. "\n", both
end
-- A state as its pieces, key -> text, cut where the merges cut it: an item's lines (its place, length, offset and rate as one piece; a MIDI
-- take's notes and events each their own), a track's settings (its lanes as one), automation's envelopes, their points and other lines. Pure.
function M.pieces(kind, state)
  local out = {}
  if kind == "track" then
    if type(state) ~= "table" then return nil end
    local lanes = {}
    for k, v in pairs(state) do
      local n = tonumber(v)
      local s = n and string.format("%.10g", n) or tostring(v)
      if TRACK_TOGETHER[k] then lanes[#lanes + 1] = k .. "=" .. s else out[k] = s end
    end
    table.sort(lanes)
    if #lanes > 0 then out["\0lanes"] = table.concat(lanes, ";") end
    return out
  end
  if type(state) ~= "string" then return nil end
  if kind == "item" then
    local els, order = elements(state)
    local timing = {}
    for _, e in ipairs(order) do
      local text = els[e.key]
      local midi = e.word == "<SOURCE" and midi_read(text)
      if TIMING[e.word] then timing[#timing + 1] = e.key .. "=" .. text
      elseif midi then
        out[e.key .. "\0"] = midi.first
        for k, u in pairs(midi.units) do out[e.key .. "\0" .. k] = u.cmp end
        for _, part in ipairs({ { "head ", midi.head }, { "tail ", midi.tail } }) do
          for _, kl in ipairs(keyed_lines(part[2])) do out[e.key .. "\0" .. part[1] .. kl[1]] = kl[2] end
        end
      else out[e.key] = text end
    end
    if #timing > 0 then out["\0timing"] = table.concat(timing, "\n") end
    return out
  end
  if kind == "env" then
    for _, u in ipairs(env_units(state)) do
      local body, plain = {}, u.lines[1]:sub(1, 1) == "<" and #u.lines > 2
      for j = 2, #u.lines - 1 do
        if u.lines[j]:sub(1, 1) == "<" then plain = false end
        body[#body + 1] = u.lines[j]
      end
      if plain then
        out[u.key .. "\0"] = u.lines[1]
        for _, kl in ipairs(keyed_lines(body, true)) do out[u.key .. "\0" .. kl[1]] = kl[2] end
      else out[u.key] = table.concat(u.lines, "\n") end
    end
    return out
  end
  if kind == "fx" then -- (each plug-in, the lines before them, and the order as one piece. rt-p1)
    local x = fx_units(state)
    if not x then return nil end
    local order = {}
    for _, kl in ipairs(keyed_lines(x.head)) do out["head " .. kl[1]] = kl[2] end
    for i, u in ipairs(x.units) do out[u.key] = u.cmp; order[i] = u.key end
    out["\0order"] = table.concat(order, "\0")
    return out
  end
  return nil
end
-- The pieces that differ between two states' pieces (added, taken away or changed), as a set. Pure.
function M.pieces_changed(a, b)
  local out = {}
  for k, v in pairs(a) do if b[k] ~= v then out[k] = true end end
  for k in pairs(b) do if a[k] == nil then out[k] = true end end
  return out
end

M.portable, M.restless_key = portable, restless_key -- (lib/mirror.lua uses them too)

return M
