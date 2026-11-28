-- Undo / Redo of your own changes, for everyone (mirror sync): the top bar's arrows, the radial menu, and the
-- "StudioSync - Undo" / "StudioSync - Redo" actions (bind them to Ctrl+Z / Ctrl+Shift+Z). A bandmate's change is never
-- stepped over the way REAPER's own undo does (it restores a whole-project snapshot, theirs included).
local band = require("band")
local undo = {}

-- What Ctrl+Z does in a band song, by what's on top of REAPER's undo list (`top`). Your own edit: REAPER's undo, which is that
-- one step and also covers what hasn't gone out yet, or never does. A change StudioSync made, a bandmate's among them: your own last
-- change instead, as REAPER's would roll theirs back (the Mac's 4 presses re-sent old parts as its own: 0.42.10). Pure.
function undo.native(top) return (top or "") ~= "" and not top:find("^StudioSync") and not top:find("^BandSync") end

-- Ctrl+Z and Ctrl+Shift+Z, in the main window and the MIDI editor (it has its own Ctrl+Z, and that's where notes get moved).
-- REAPER reads shortcuts only when it starts, so undo.auto_keys sets them for the next start; Setup's button (REAPER's own box,
-- for each) is for where that doesn't apply. What's still without one:
local ids = {}
local KEYS = { { "Undo", 0, "the main window", 9 }, { "Undo", 32060, "the MIDI editor", 9 }, { "Redo", 0, "the main window", 13 }, { "Redo", 32060, "the MIDI editor", 13 } }
-- Every copy of the script reaper-kb.ini knows, by section: { "Undo0" = { "_RS..", .. } }. Pure.
function undo.copies(text)
  local out = {}
  for sec, rs, what in (text or ""):gmatch('SCR %d+ (%d+) (%S+) "[^"]*StudioSync %- ([UR]%a+)%.lua"') do
    local key = what .. sec
    out[key] = out[key] or {}
    table.insert(out[key], "_" .. rs)
  end
  return out
end
local copies, copies_at = {}, -1e9
-- Is a key on another copy of this script? Each copy hands over to the one StudioSync runs from (lib/fromfolder.lua), so Ctrl+Z on the
-- copy it ran from before still undoes through StudioSync: Health called it unset on the laptop and the Mac once they ran from the
-- studio's folder. James, 0.59.32.
local function keyed_elsewhere(k, key)
  if reaper.time_precise() - copies_at > 10 then copies, copies_at = undo.copies(band.read(reaper.GetResourcePath() .. "/reaper-kb.ini")), reaper.time_precise() end
  for _, rs in ipairs(copies[key] or {}) do
    local cmd = reaper.NamedCommandLookup(rs)
    if cmd ~= 0 and reaper.CountActionShortcuts(reaper.SectionFromUniqueID(k[2]), cmd) > 0 then return true end
  end
  return false
end
function undo.keys_left(dir)
  local left = {}
  for _, k in ipairs(KEYS) do
    local key = k[1] .. k[2]
    ids[key] = ids[key] or reaper.AddRemoveReaScript(true, k[2], dir .. "/StudioSync - " .. k[1] .. ".lua", true)
    if ids[key] ~= 0 and reaper.CountActionShortcuts(reaper.SectionFromUniqueID(k[2]), ids[key]) == 0 and not keyed_elsewhere(k, key) then
      left[#left + 1] = { what = k[1], section = k[2], where = k[3], id = ids[key], mod = k[4], key = key }
    end
  end
  return left
end
-- The lines to add to reaper-kb.ini (its text) for `wants`, { what, section, mod }: Ctrl is mod 9, Ctrl+Shift 13, Z is key 90.
-- A key that section already has is someone's own choice, and is left alone. Pure.
function undo.kb_lines(text, wants)
  local add = {}
  for _, w in ipairs(wants) do
    local rs = text:match("SCR %d+ " .. w.section .. " (%S+) \"[^\"]*StudioSync %- " .. w.what .. "%.lua\"")
    if rs and not ("\n" .. text):find("\nKEY " .. w.mod .. " 90 %S+ " .. w.section .. "%f[%D]") then
      add[#add + 1] = string.format("KEY %d 90 _%s %d", w.mod, rs, w.section)
    end
  end
  return add
end
-- reaper-kb.ini without the keys of the scripts as they were called before the rename, or Ctrl+Z stays bound to a script that's gone,
-- and that reads as someone's own choice of key. Pure.
function undo.strip_old(text)
  for rs in text:gmatch('SCR %d+ %d+ (%S+) "[^"]*BandSync %- [UR]%a+%.lua"') do
    text = text:gsub("\nKEY %d+ %d+ _" .. rs:gsub("%p", "%%%0") .. " [^\n]*", "")
  end
  return text
end
-- Sets what's missing for the next time REAPER starts: at its start, and again as it quits (a new action registered meanwhile
-- rewrites the file from REAPER's memory). A key once seen set and now gone was removed by its owner: not set again.
-- (a Mac too, since 0.59.14: its Cmd+Z lines are the ones Setup's button writes, seen working in a bandmate's reaper-kb.ini)
function undo.auto_keys(dir)
  local kb_path = reaper.GetResourcePath() .. "/reaper-kb.ini"
  local kb_text = band.read(kb_path)
  if kb_text and undo.strip_old(kb_text) ~= kb_text then pcall(band.write_atomic, kb_path, undo.strip_old(kb_text)) end
  local left, seen = undo.keys_left(dir), reaper.GetExtState(band.SECTION, "undo keys seen 2") -- (2: the actions are new since the rename)
  local missing = {}
  for _, k in ipairs(left) do missing[k.key] = true end
  for _, k in ipairs(KEYS) do
    local key = k[1] .. k[2]
    if not missing[key] and ids[key] ~= 0 and not seen:find(key, 1, true) then seen = seen .. key .. " " end
  end
  reaper.SetExtState(band.SECTION, "undo keys seen 2", seen, true)
  local wants = {}
  for _, k in ipairs(left) do
    if not seen:find(k.key, 1, true) then wants[#wants + 1] = k end
  end
  if #wants == 0 then return end
  local path = reaper.GetResourcePath() .. "/reaper-kb.ini"
  local text = band.read(path)
  local lines = text and undo.kb_lines(text, wants) or {}
  if #lines == 0 then return end
  local f = io.open(path, "a")
  if not f then return end
  f:write((text:sub(-1) == "\n" and "" or "\n") .. table.concat(lines, "\n") .. "\n")
  f:close()
end
function undo.key_name() return (reaper.GetOS():find("^OSX") or reaper.GetOS():find("^macOS")) and "Cmd+Z" or "Ctrl+Z" end
function undo.bind_keys(dir)
  local left, z = undo.keys_left(dir), undo.key_name()
  local list = {}
  for _, k in ipairs(left) do list[#list + 1] = string.format("%d. %s in %s: press %s, then OK", #list + 1, k.what, k.where, k.what == "Undo" and z or z:gsub("%+Z", "+Shift+Z")) end
  if #left == 0 or reaper.MB("REAPER's own box opens " .. #left .. " time(s), one after the other. If it says the key is in use, choose to replace it:\n\n" .. table.concat(list, "\n") ..
      "\n\nOutside studio projects these keys do what they always did.", "StudioSync", 1) ~= 1 then return end
  for _, k in ipairs(left) do
    if not reaper.DoActionShortcutDialog(reaper.GetMainHwnd(), reaper.SectionFromUniqueID(k.section), k.id, -1) then break end
  end
end

-- Undo's ask, when a bandmate changed the same thing since (or always, from the panel), is never a modal box: REAPER's MB holds every script
-- in that REAPER, Live sync among them, until someone answers, and a scripted Undo on the laptop sat behind one for over an hour (rt-r4). The
-- ask is noted per tab (ExtState "undo ask <proj>": the change, Undo or Redo, the words, until when) and said in the log, a tooltip and the
-- panel's bar (Yes / No: lib/claimask.lua). The same Undo (or Redo) pressed again within ASK_WAIT s is Yes, and so is the bar's Yes, which
-- Live sync carries out (claimask.tick). No answer is No: nothing changes. rt-fix9
undo.ASK_WAIT = 30
undo.confirm = nil -- (tests: function(words) -> true answers Yes at once, false No)
local function ask_key(proj) return "undo ask " .. tostring(proj) end
function undo.pending(proj) -- -> the ask waiting in this tab ({ id, redo, text, till }), or nil
  local a = band.ext_json(band.SECTION, ask_key(proj))
  if type(a) == "table" and type(a.id) == "string" and type(a.text) == "string" and (tonumber(a.till) or 0) >= os.time() then return a end
end
function undo.clear(proj) reaper.DeleteExtState(band.SECTION, ask_key(proj), false) end
function undo.ask(proj, id, redo, text)
  band.set_ext_json(band.SECTION, ask_key(proj), { id = tostring(id), redo = redo == true, text = text, till = os.time() + undo.ASK_WAIT }, false)
  local key = redo and (undo.key_name():gsub("%+Z", "+Shift+Z")) or undo.key_name()
  local say = text .. " Press " .. key .. " again within " .. undo.ASK_WAIT .. " s for yes (or Yes in StudioSync's bar); otherwise nothing changes."
  undo.say(say)
  return say
end
-- Words for whoever pressed Undo or Redo, never in a modal box ("You haven't changed anything here yet.", "Nothing to redo ..."): in the
-- log, and by the mouse when the panel isn't showing, as sync.put_back's words (Autostart takes the tooltip away after a few seconds). A box
-- held that REAPER, Live sync and all, until someone answered it (rt-r5). rt-fix9
function undo.say(text)
  band.log(text)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "panel alive"))
  if not (beat and reaper.time_precise() - beat < 5 and reaper.GetExtState(band.SECTION, "panel minimized") == "") then
    local x, y = reaper.GetMousePosition()
    reaper.TrackCtl_SetToolTip("StudioSync: " .. text, x + 14, y + 14, true)
    reaper.SetExtState(band.SECTION, "tooltip until", tostring(reaper.time_precise() + 8), false)
  end
end

-- ---- Undo from ancestry (docs/rt/rt-sync2.md 5a, rt-sync2i) ----------------------------------------------------------------------------
-- Which act to undo is chosen from your own acts by your own clock (`hlc` only grows on one computer), never by History's rows, which sort by
-- each computer's clock. What an Undo writes, per object, is built on what this computer holds (the judge's answer), with the act's change
-- reversed by the three-way merge. Redo is the same rule applied to the Undo act. Pure below, but for `read` and `held`.
local judge = require("judge")
local less, cmp = require("rank").less, require("rank").cmp
local function clock(e) return tonumber(e.hlc) or (judge.order_parts(e.time or "")) end -- (ms: a change from before clocks, by its second)
local function after(a, b) -- a made after b, on one person's clock
  local ca, cb = clock(a), clock(b)
  if ca ~= cb then return ca > cb end
  return less(tostring(b.id), tostring(a.id))
end
-- Your own acts in History's `entries`, newest first: { key, rows (indexes, newest first), top (the newest row), kind = "edit" | "undo" |
-- "redo" }. An act is the changes one look (or one Undo or Redo press) sent, by their `act`; a change with none (an older build's) is an act
-- alone. A Restore (`restored`, no `undoes` / `redoes`) and StudioSync's own refreshes (`auto` alone) aren't acts Undo steps.
-- -> the list, and your newest change's id.
function undo.acts(entries, user)
  local by, list, newest = {}, {}, nil
  for j, e in ipairs(entries) do
    if e.user == user and ((e.kind == "obj" and e.oid) or (e.kind == "timeline" and type(e.tempo) == "table")) then
      if not newest or after(e, entries[newest]) then newest = j end
      local k = e.act and ("a" .. tostring(e.act)) or ("i" .. tostring(e.id))
      local g = by[k]
      if not g then g = { key = k, rows = {} }; by[k] = g; list[#list + 1] = g end
      g.rows[#g.rows + 1] = j
      if not g.top or after(e, entries[g.top]) then g.top = j end
      if e.undoes then g.undo = true elseif e.redoes then g.redo = true elseif e.restored then g.restore = true elseif not e.auto then g.edit = true end
    end
  end
  local out = {}
  for _, g in ipairs(list) do
    g.kind = (g.undo and "undo") or (g.redo and "redo") or (g.edit and not g.restore and "edit") or nil
    if g.kind then
      table.sort(g.rows, function(x, y) return after(entries[x], entries[y]) end)
      out[#out + 1] = g
    end
  end
  table.sort(out, function(x, y) return after(entries[x.top], entries[y.top]) end)
  return out, newest and entries[newest].id
end
-- Which changes your Undos took back: those an Undo names (`undoes`, `undoes_all`) that no Redo names (`redoes`, `redoes_all` name the Undo's
-- own changes). Marks each undo act `redone`. -> set of ids.
local function undone_of(entries, list)
  local redone = {}
  for _, g in ipairs(list) do
    if g.kind == "redo" then
      for _, j in ipairs(g.rows) do
        local e = entries[j]
        redone[tostring(e.redoes)] = true
        for _, x in ipairs(type(e.redoes_all) == "table" and e.redoes_all or {}) do redone[tostring(x)] = true end
      end
    end
  end
  local undone = {}
  for _, g in ipairs(list) do
    if g.kind == "undo" then
      g.redone = false
      for _, j in ipairs(g.rows) do if redone[tostring(entries[j].id)] then g.redone = true end end
      if not g.redone then
        for _, j in ipairs(g.rows) do
          local e = entries[j]
          if e.undoes then undone[tostring(e.undoes)] = true end
          for _, x in ipairs(type(e.undoes_all) == "table" and e.undoes_all or {}) do undone[tostring(x)] = true end
        end
      end
    end
  end
  return undone
end
-- Undo: your newest act with changes not taken back yet, as { key, rows, top, kind = "edit" }, or nil. `passed`: ids (set) lib/undo.lua found
-- nothing left to take back of (a timeline change a bandmate changed since): their act is passed over. A deletion on another lane than the
-- act's newest change is left for the next press (a pass and its copies in a comp: mirror.same_moment, Mac 0.42.10). An act whose object
-- changes are all taken back counts as undone, its timeline change with them (an older build's Undo didn't name it).
function undo.last_mine(entries, user, passed)
  local list = undo.acts(entries, user)
  local undone = undone_of(entries, list)
  for _, g in ipairs(list) do
    if g.kind == "edit" then
      local left, objs, objs_left, skip = {}, 0, 0, false
      for _, j in ipairs(g.rows) do
        local e = entries[j]
        if passed and passed[tostring(e.id)] then skip = true end
        if e.kind == "obj" then objs = objs + 1 end
        if not undone[tostring(e.id)] then
          left[#left + 1] = j
          if e.kind == "obj" then objs_left = objs_left + 1 end
        end
      end
      if objs > 0 and objs_left == 0 then left = {} end
      if #left > 0 and not skip then
        local top, track_gone = left[1], false
        for _, j in ipairs(left) do if entries[j].gone and entries[j].obj == "track" then track_gone = true end end
        if entries[top].gone and entries[top].obj == "item" and not track_gone then -- (a track deleted with its items comes back whole)
          local mirror, keep = require("mirror"), {}
          local lane = mirror.entry_lane(entries, top)
          for _, j in ipairs(left) do
            if not (entries[j].gone and entries[j].obj == "item" and mirror.entry_lane(entries, j) ~= lane) then keep[#keep + 1] = j end
          end
          left = keep
        end
        return { key = g.key, rows = left, top = top, kind = "edit" }
      end
    end
  end
end
-- Redo: your newest Undo act not redone yet, or nil. A change of yours since (not an Undo or Redo) ends it.
function undo.last_undo(entries, user)
  local list = undo.acts(entries, user)
  undone_of(entries, list)
  for _, g in ipairs(list) do
    if g.kind == "edit" then return nil end
    if g.kind == "undo" and not g.redone then return g end
  end
end
-- History's "Undo this change" on entries[i]: its row's moment (mirror.same_moment), and, where that deletes a track or items on one, the
-- rest of that deletion in the same act (the track, and its items on every lane), so the track comes back whole. -> row indexes.
function undo.moment(entries, i)
  local rows, had, tracks = require("mirror").same_moment(entries, i), {}, {}
  local e = entries[i]
  for _, j in ipairs(rows) do
    had[j] = true
    local x = entries[j]
    if x.gone and x.obj == "track" then tracks[x.oid] = true elseif x.gone and x.obj == "item" and x.track then tracks[x.track] = "item" end
  end
  if not (e and e.act and next(tracks)) then return rows end
  local deleted = {}
  for j, x in ipairs(entries) do
    if x.act == e.act and x.user == e.user and x.gone and x.obj == "track" and tracks[x.oid] then
      deleted[x.oid] = true
      if not had[j] then rows[#rows + 1] = j; had[j] = true end
    end
  end
  for j, x in ipairs(entries) do
    if not had[j] and x.act == e.act and x.user == e.user and x.gone and x.obj == "item" and deleted[x.track or ""] then rows[#rows + 1] = j; had[j] = true end
  end
  return rows
end
local function parents(x)
  local w, l = judge.split_merge(x.id)
  if w then return { w, l } end
  return { x.base_ev }
end
-- Who else's changes are in `now` (what's held) that `a` (the act's version) didn't see: its later versions and the ones made apart from it
-- and merged in. Undoing `a` takes back theirs where they changed what `a` did. Bounded walks. -> sorted names, not `me`.
function undo.since(read, a, now, me)
  if not (now and now.id and now.id ~= a.id) then return {} end
  local saw, todo = { [a.id] = true }, { a }
  for _ = 1, 64 do -- (what a saw: its own ancestry, a few steps down)
    local x = table.remove(todo)
    if not x then break end
    for _, p in ipairs(parents(x)) do
      if type(p) == "string" and not saw[p] then saw[p] = true; local y = read(p); if y then todo[#todo + 1] = y end end
    end
  end
  local who, out, seen, n = {}, {}, {}, 0
  todo = { now }
  while #todo > 0 and n < 128 do
    local x = table.remove(todo, 1)
    n = n + 1
    if not saw[x.id] and not seen[x.id] then
      seen[x.id] = true
      if not judge.split_merge(x.id) and x.user and x.user ~= me and not x.auto and not who[x.user] then who[x.user] = true; out[#out + 1] = x.user end
      for _, p in ipairs(parents(x)) do
        if type(p) == "string" and not saw[p] and not seen[p] then local y = read(p); if y then todo[#todo + 1] = y end end
      end
    end
  end
  table.sort(out, cmp)
  return out
end
-- `a`'s change taken back onto `now`: merge_state(kind, base = a, winner = what a was built on (`to`), loser = now). What a bandmate changed
-- since and `a` didn't stays; where both did, going back wins. -> a version like `to` with that state, or `to` itself (no merge for its kind,
-- or going back would add a take of theirs: plain going back, as before).
function undo.reverse(a, to, now)
  local mirror = require("mirror")
  if not (now and mirror.mergeable(to) and mirror.mergeable(now) and mirror.mergeable(a) and now.id ~= a.id and to.obj == now.obj) then return to end
  local m, both = mirror.merge_state(to.obj, a.state, to.state, now.state, now.user)
  if m == nil then return to end
  for _, k in ipairs(both or {}) do
    if tostring(k):find("<SOURCE", 1, true) and not tostring(k):find("\0notes", 1, true) then return to end
  end
  local v = {}
  for k, x in pairs(to) do v[k] = x end
  v.state = m
  return v
end
-- The plan for undoing the object changes entries[rows] (one act): oid -> the version to write (mirror.revert), or false (it goes). Per object,
-- the act's newest version `a`, and what the act's first version was built on (`base_ev`, down past the act's own: `before`):
--   a creation (nothing before it, mirror.began): it goes
--   a deletion: `before` comes back (its rank, parent and state; its items and parts by containment, mirror.revert's contents_owed), unless
--     it's here again already
--   a version built on a deletion (an Undo of one, redone): it goes
--   an edit: undo.reverse(a, before, held), unless what's held is a deletion: an edit a deletion beat stays beaten (planned as `before`
--     marked `beaten`, which mirror.revert leaves and counts as "deleted by a bandmate since")
-- Where `before` can't be read (trimmed away, not here yet), nothing is planned for that object.
-- `read(id)` -> a version (a merge rebuilt: mirror.event_file); `held(oid)` -> the version this computer holds, or nil.
-- -> plan, who else changed them since (undo.since: names other than the act's maker), ids of every row.
function undo.plan(entries, rows, read, held)
  local mirror = require("mirror")
  local in_act, by_oid, oids, ids = {}, {}, {}, {}
  for _, j in ipairs(rows) do
    local e = entries[j]
    ids[#ids + 1] = e.id
    if e.kind == "obj" and e.oid then
      in_act[e.id] = true
      if not by_oid[e.oid] then by_oid[e.oid] = {}; oids[#oids + 1] = e.oid end
      table.insert(by_oid[e.oid], e)
    end
  end
  table.sort(oids, cmp)
  local plan, who, others = {}, {}, {}
  for _, oid in ipairs(oids) do
    local a
    for _, e in ipairs(by_oid[oid]) do if not a or after(e, a) then a = e end end
    a = read(a.id) or a
    local cur, before, lost = a, nil, false
    for _ = 1, 64 do
      local b = cur.base_ev
      if type(b) ~= "string" or b == "" then break end
      local x = read(b)
      if not x then lost = true; break end
      if not in_act[x.id] then before = x; break end
      cur = x
    end
    if not before then
      if not lost and mirror.began(cur) then plan[oid] = false end
    elseif a.gone then
      local now = held(oid)
      if not before.gone and not (now and not now.gone and now.id ~= a.id) then plan[oid] = before end
    elseif before.gone then plan[oid] = false
    else
      local now = held(oid)
      if now and now.gone then plan[oid] = setmetatable({ beaten = true }, { __index = before }) -- (mirror.revert leaves it, and says so)
      else
        plan[oid] = undo.reverse(a, before, now)
        for _, u in ipairs(undo.since(read, a, now, a.user)) do if not who[u] then who[u] = true; others[#others + 1] = u end end
      end
    end
  end
  table.sort(others, cmp)
  return plan, others, ids
end

-- Undo (or with `redo`, redo) this person's newest own change in the bound project. `opts.ask`: asks first, always
-- (the panel); otherwise it asks only when a bandmate changed the same thing since. `opts.describe(e)`: the wording.
-- `opts.confirmed`: the change already answered Yes (the panel's bar, through Live sync).
-- Returns what happened, for the Activity list, or nil and why not; nil, nil, the words when it asked (undo.ask: already said).
function undo.step(proj, cfg, b, redo, opts)
  opts = opts or {}
  local mirror, recall, sync = require("mirror"), require("recall"), require("sync")
  local all = recall.entries(cfg, b.song, b.room)
  -- (marker or tempo changes of yours with nothing left to take back: passed over, below. rt-edits)
  local passed_text, passed = select(2, reaper.GetProjExtState(proj, band.SECTION, "undo passed")), {}
  for id in passed_text:gmatch("%S+") do passed[id] = true end
  -- (your own acts by your own clock, and which of them your Undos took back: undo.last_mine / last_undo. rt-sync2i)
  local g
  if redo then g = undo.last_undo(all, cfg.user) else g = undo.last_mine(all, cfg.user, passed) end
  if not g then
    return nil, redo and "Nothing to redo: you haven't undone anything since your last change." or "You haven't changed anything here yet."
  end
  -- (an Undo that took nothing back (not yours to change any more, changed here since, the map changed since) wrote nothing, so the Redo after
  -- it found your Undo before that one still waiting and redid it: Undo then Redo brought back a copy you had undone two minutes earlier.
  -- The soak's bug 9. Noted per tab, by your newest change then; anything of yours since (a change, an Undo that did something) and it's
  -- spent. Not in the project: a ProjExtState write counts as a project change. rt-converge)
  local newest_mine = tostring(select(2, undo.acts(all, cfg.user)) or "")
  local nothing_key = "undo nothing " .. tostring(proj)
  if redo and reaper.GetExtState(band.SECTION, nothing_key) == newest_mine then
    return nil, "Nothing to redo: your last Undo took nothing back."
  end
  local function took(n) -- (n: how many changes this press made; nil when it can't say)
    if not redo and n == 0 then reaper.SetExtState(band.SECTION, nothing_key, newest_mine, false)
    elseif reaper.GetExtState(band.SECTION, nothing_key) ~= "" then reaper.DeleteExtState(band.SECTION, nothing_key, false) end
  end
  -- (the act's object changes, and its tempo map or marker change: the newest of each)
  local objs, i, tl = {}, nil, nil
  for _, j in ipairs(g.rows) do
    if all[j].kind == "obj" then objs[#objs + 1] = j; i = i or j else tl = tl or j end
  end
  local e = all[i or tl]
  local room_dir = sync.room_dir(cfg, b.song, b.room)
  local function read(id) return mirror.event_file(room_dir, id) end
  local function held(oid)
    local _, h, kev = mirror.known(proj, oid)
    if (kev or "") == "" then return nil end
    return read(kev) or { id = kev, oid = oid, gone = h == "" or nil, stub = true }
  end
  local plan, others = undo.plan(all, objs, read, held)
  for k = #others, 1, -1 do if others[k] == cfg.user then table.remove(others, k) end end
  -- (a tempo or marker change by what it changed, not "now 130 bpm": History's words are the version's, and an Undo of a marker rename said
  -- "now 130 bpm" while a bandmate's 100 stayed. rt-r4, rt-fix9)
  local what = (redo and "redo: " or "undo: ") .. (e.kind == "timeline" and sync.timeline_words(cfg, b.song, b.room, all, tl, band.read_json(band.session_path(cfg, b.song)))
    or (opts.describe or recall.describe)(e))
  if (opts.ask or #others > 0) and opts.confirmed ~= tostring(e.id) then
    local text = what:sub(1, 1):upper() .. what:sub(2) .. "? It goes to everyone." .. (#others > 0 and (" " .. table.concat(others, ", ") ..
      " changed it after that: what they changed stays, unless it's what you changed.") or "")
    local a = undo.pending(proj)
    if undo.confirm then
      if not undo.confirm(text) then return nil end
    elseif not (a and a.id == tostring(e.id) and a.redo == (redo == true)) then
      return nil, nil, undo.ask(proj, e.id, redo, text)
    end
  end
  undo.clear(proj)
  local can, who = sync.authority(cfg, b.song, b.room, band.read_json(band.session_path(cfg, b.song)))
  -- (every change this press makes carries one step id: a Redo then takes back all of them, whatever second each was written in. rt-edits)
  local step_id = string.format("%s-%s-%s%d", sync.id_user(cfg.user), os.date("!%Y%m%d%H%M%S"), redo and "r" or "u", math.random(0, 999999))
  -- (every change of the act on each change this press writes, only when there are several: the next presses redid the same restore. A few
  -- bytes an event. Round 1 review, 0.59.45)
  local act = #g.rows > 1 and {} or nil
  for _, j in ipairs(act and g.rows or {}) do act[#act + 1] = all[j].id end
  local tags = redo and { redoes = e.id, redoes_all = act, act = step_id } or { undoes = e.id, undoes_all = act, act = step_id }
  -- (an act that was only a tempo map or marker change, a marker added and nothing else: that goes back by itself, or comes back. What it
  -- added goes and what it took away returns; a bandmate's markers since stay. sync.undo_timeline, rt-edits)
  if not i then
    if not can(cfg.user, nil, nil) then return nil, "The tempo map and markers aren't yours to change here: nothing was taken back." end
    local okt, changed = pcall(sync.undo_timeline, proj, cfg, b.song, b.room, all, tl, tags, band.read_json(band.session_path(cfg, b.song)))
    if not okt then return nil, "undo failed: " .. tostring(changed) end
    if not changed then
      -- (a bandmate took the marker away since, or changed the map: every press stopped here, and the changes before it couldn't be undone.
      -- Passed over from now on, on this computer; a redo has nothing to bring back. The last 20 kept)
      if not redo then
        local list = {}
        for id in passed_text:gmatch("%S+") do list[#list + 1] = id end
        list[#list + 1] = e.id
        reaper.SetProjExtState(proj, band.SECTION, "undo passed", table.concat(list, " ", math.max(1, #list - 19)))
      end
      took(0)
      return nil, "The tempo map or markers have changed since: nothing was taken back." .. (redo and "" or " Undo again goes to your change before it.")
    end
    took(1)
    return what
  end
  local o = { can = can, mode = who and who.mode, driver = who and who.driver, is_claimed = who and who.is_claimed, local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1",
    undoes = tags.undoes, undoes_all = tags.undoes_all, redoes = tags.redoes, redoes_all = tags.redoes_all, act = step_id }
  -- (only a bandmate's auto-claim made since doesn't stand in front of taking your own change back: mirror.revert. rt-edits)
  o.soft = who and function(name, pos) return require("claimask").soft(who, name, pos, cfg.user) end or nil
  -- (the act's tempo map or markers first, where it changed them and they're yours to change: a region copied with its items stayed on every
  -- computer after the undo. The tempo goes back before the items, so REAPER moves nothing the restores put in place. An Undo's own timeline
  -- change from an older build carries no act: found by what it undid. REAPER check F3, rt-edits)
  tl = tl or (redo and sync.act_timeline(all, g.top, cfg.user, true))
  if tl and can(cfg.user, nil, nil) then
    local okt, err = pcall(sync.undo_timeline, proj, cfg, b.song, b.room, all, tl, tags, band.read_json(band.session_path(cfg, b.song)))
    if not okt then band.log("undo: the tempo map and markers stay as they are (" .. tostring(err) .. ")") end
  end
  local ok, res, n = pcall(mirror.revert, proj, cfg, b.song, b.room, plan, o)
  if not ok then return nil, "undo failed: " .. tostring(res) end
  took(n)
  return res
end

return undo
