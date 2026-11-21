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

-- Undo (or with `redo`, redo) this person's newest own change in the bound project. `opts.ask`: asks first, always
-- (the panel); otherwise it asks only when a bandmate changed the same thing since. `opts.describe(e)`: the wording.
-- Returns what happened, for the Activity list, or nil and why not.
function undo.step(proj, cfg, b, redo, opts)
  opts = opts or {}
  local mirror, recall, sync = require("mirror"), require("recall"), require("sync")
  local all = recall.entries(cfg, b.song, b.room)
  local i
  if redo then i = mirror.last_undo(all, cfg.user) else i = mirror.last_mine(all, cfg.user) end -- (with "and/or", nothing to redo undid your last change)
  if not i then
    return nil, redo and "Nothing to redo: you haven't undone anything since your last change." or "You haven't changed anything here yet."
  end
  local e = all[i]
  local what = (redo and "redo: " or "undo: ") .. (opts.describe or recall.describe)(e)
  local others = mirror.later_by_others(all, i)
  if opts.ask or #others > 0 then
    if reaper.MB(what:sub(1, 1):upper() .. what:sub(2) .. "?\n\nIt goes to everyone." .. (#others > 0 and ("\n\n" .. table.concat(others, ", ") ..
        " changed it after that: what they changed stays, unless it's what you changed.") or ""), "StudioSync", 4) ~= 6 then return nil end
  end
  local can, who = sync.authority(cfg, b.song, b.room, band.read_json(band.session_path(cfg, b.song)))
  local o = { can = can, mode = who and who.mode, driver = who and who.driver, is_claimed = who and who.is_claimed, local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" }
  -- (the whole act, as Restore's rows: it could land on a print swapped in the same second, and nothing you'd hear went back)
  local plan, ids = mirror.plan_undo_moment(all, i)
  -- (only your change goes back: what a bandmate changed since in the same item, track or automation, and you didn't, stays. rt-merge)
  if plan then
    local room_dir, mine, newest = sync.room_dir(cfg, b.song, b.room), {}, {}
    for _, id in ipairs(ids or {}) do mine[id] = true end
    for _, x in ipairs(all) do if mine[x.id] and x.oid and plan[x.oid] then newest[x.oid] = x end end
    for oid, x in pairs(newest) do
      local _, _, kev = mirror.known(proj, oid)
      plan[oid] = mirror.undo_keeping(x, plan[oid], (kev or "") ~= "" and mirror.event_file(room_dir, kev) or nil)
    end
  end
  -- (every change of the act on each restore event, only when there are several: the next presses redid the same restore. A few bytes an
  -- event. Round 1 review, 0.59.45)
  local act = ids and #ids > 1 and ids or nil
  if redo then o.redoes, o.redoes_all = e.id, act else o.undoes, o.undoes_all = e.id, act end
  -- (the act's tempo map or markers first, where it changed them and they're yours to change: a region copied with its items stayed on every
  -- computer after the undo. The tempo goes back before the items, so REAPER moves nothing the restores put in place. REAPER check F3, rt-edits)
  local tl = can(cfg.user, nil, nil) and sync.act_timeline(all, i, cfg.user, redo)
  if tl then
    local okt, err, tempo = pcall(sync.undo_timeline, proj, cfg, b.song, b.room, all, tl, redo and { redoes = e.id } or { undoes = e.id },
      band.read_json(band.session_path(cfg, b.song)))
    if not okt then band.log("undo: the tempo map and markers stay as they are (" .. tostring(err) .. ")") end
    o.retimed = okt and err == true and tempo == true -- (REAPER just moved things for the map: mirror.revert)
  end
  local ok, res = pcall(mirror.revert, proj, cfg, b.song, b.room, plan, o)
  if not ok then return nil, "undo failed: " .. tostring(res) end
  return res
end

return undo
