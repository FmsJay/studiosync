-- Mirror sync: every machine in a room holds the same project (see docs/mirror-design.md).
-- This file's top half is pure (chunk normalizing, hashing, ordering, merging) so it runs under any Lua.
local mirror = {}
local merges = require("mirror_merge") -- (pure: the three-way merges, rt-sync2 phase 1)
local judge = require("judge") -- (pure: what each object is, from its own versions: rt-sync2 phase 2)

-- Lines in an item chunk that are this machine's business only: selection, REAPER's own ids (regenerated on
-- apply), MIDI pooling (a copy is its own item), MIDI editor view state, which take is active (wet/dry is each
-- person's choice) and item grouping (group numbers are per project: another machine's group 3 is other items).
-- Which notes are selected is each person's too: a selected event is written "e"/"x"/"<x", and goes out as "E"/"X"/"<X"
-- (opening the MIDI editor sent its VELLANE line, and a moved note went out selected: laptop, 2026-11-01).
-- GROUP (item grouping) is each computer's own: a group is a number inside one project, and the same number already means another
-- group in each collaborator's copy, so it would tie their items to yours. (Explained in the README: power-user review, 0.58.62.)
local LOCAL = { "SEL", "IGUID", "IID", "GUID", "POOLEDEVTS", "POOLCOLOR", "CFGEDITVIEW", "CFGEDIT", "EVTFILTER", "KEYSNAP", "TRACKSEL", "GROUP", "VELLANE" }
local LOCAL_SET = {}
for _, k in ipairs(LOCAL) do LOCAL_SET[k] = true end
-- P_EXT keys that travel: our object id, and mirrored markers (band_m_*). Everything else is this machine's.
local function ext_travels(key) return key == "band_oid" or key:sub(1, 7) == "band_m_" end

-- A plug-in chain's lines that are this machine's own: FX ids, window positions, which window is open or docked.
local FX_LOCAL = { FXID = true, FLOATPOS = true, FLOAT = true, WNDRECT = true, SHOW = true, LASTSEL = true, DOCKED = true }
-- At any depth (FX containers, REAPER 7): those lines of the chain or container a line sits in, and the view lines of a
-- plug-in's envelope lanes and modulation window. (Showing an FX lane, or opening a plug-in's window inside a container,
-- resent the whole chain and reloaded everyone's plug-ins: plug-ins review, 0.58.76.) `parent`: the enclosing block's tag.
local CHAIN_BLOCK = { FXCHAIN = true, TAKEFX = true, CONTAINER = true }
local PARM_VIEW = { EGUID = true, ARM = true, VIS = true, LANEHEIGHT = true, MODWND = true,
  POOLEDENVINST = true } -- (its pool number is this computer's: another's means another item. The items travel in the automation part, 0.58.89)
local function chain_local(parent, key)
  if not key then return false end
  if CHAIN_BLOCK[parent] then return FX_LOCAL[key] == true end
  return (parent == "PARMENV" or parent == "PROGRAMENV") and PARM_VIEW[key] == true
end
mirror.chain_local = chain_local

-- A take envelope's lines that are this computer's view of it: shown or not, its lane's height, armed (review, 0.58.91: they went out as edits).
local TAKE_ENV_VIEW = { EGUID = true, VIS = true, LANEHEIGHT = true, ARM = true }
-- Normalized item chunk: what the band shares about this item, byte-identical on every machine that holds it.
local byte = string.byte
function mirror.normalize_item(chunk)
  local out, in_ext, fx = {}, false, {} -- (fx: the blocks open inside a take's <TAKEFX chain, empty outside it)
  local tenv = false -- (inside a take's envelope)
  for line in chunk:gmatch("[^\r\n]+") do
    -- (a MIDI event, "E <ticks> ...", unindented: kept as it is, as the lines below would keep it. Nearly every line of a big MIDI item, and
    -- each went through a trim and four patterns: half a big MIDI item's look after one note changed. rt-look)
    local b1, b2 = byte(line, 1, 2)
    if b1 == 69 and b2 == 32 and not in_ext and byte(line, -1) > 32 then out[#out + 1] = line; goto next_line end
    do
    local s = line:match("^%s*(.-)%s*$")
    local key = s:match("^(%S+)")
    if #fx == 0 and not tenv and key and key:match("^<%u+ENV%d*$") then tenv = true elseif tenv and s == ">" then tenv = false end
    local parent = fx[#fx]
    if #fx > 0 then
      if s:sub(1, 1) == "<" then fx[#fx + 1] = s:match("^<(%S+)") elseif s == ">" then fx[#fx] = nil end
    elseif s == "<TAKEFX" then fx[1] = "TAKEFX" end
    if chain_local(parent, key) then -- (a take plug-in's window opened or moved isn't a change)
    elseif in_ext then
      if s == ">" then in_ext = false; out[#out + 1] = s
      elseif key and ext_travels(key) then out[#out + 1] = s end
    elseif s == "<EXT" or s == "<EXTI" then -- (REAPER writes an item's P_EXT as <EXTI, a track's or take's as <EXT)
      in_ext = true; out[#out + 1] = s
    elseif key == "TAKE" then
      -- ("TAKE SEL" marks the active take, which travels as BANDTAKE. An empty take stays one, "TAKE NULL": as a bare "TAKE" it arrived as a
      -- real take with nothing in it, and the item never read back as it was sent. Review, 0.58.87)
      out[#out + 1] = s:match("^TAKE%s+NULL") and "TAKE NULL" or "TAKE"
    elseif s == "<SOURCE MIDIPOOL" then
      out[#out + 1] = "<SOURCE MIDI" -- (a pooled copy arrives as an item of its own: REAPER writes it as plain MIDI there)
    elseif s:match("^[ex]m? ") or s:match("^<x ") then
      out[#out + 1] = s:gsub("^(<?)(.)", function(lt, c) return lt .. c:upper() end, 1)
    elseif tenv and TAKE_ENV_VIEW[key] then -- (left out)
    elseif not (key and LOCAL_SET[key]) then
      out[#out + 1] = s
    end
    end
    ::next_line::
  end
  -- an <EXT> block left empty by the filter is dropped
  return (table.concat(out, "\n"):gsub("<EXTI?\n>\n?", "")) .. "\n"
end

-- The <FXCHAIN> block of a track chunk, normalized: no FX ids, window positions or open/closed state.
-- `skip` (optional set of FXIDs) leaves out this machine's own additions (plug-in translations). A plug-in runs
-- from its BYPASS line to the line before the next BYPASS (FXID and WAK follow its block).
function mirror.fxchain(track_chunk, skip)
  local raw, stack, on = {}, {}, false
  for line in track_chunk:gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    if not on and s == "<FXCHAIN" then on = true end
    if on then
      local parent = stack[#stack]
      if s:sub(1, 1) == "<" then stack[#stack + 1] = s:match("^<(%S+)") elseif s == ">" then stack[#stack] = nil end
      raw[#raw + 1] = { s = s, top = parent == "FXCHAIN", parent = parent } -- (top: a line directly inside <FXCHAIN>)
      if #stack == 0 then break end
    end
  end
  if not on then return nil end
  local out, group, drop = {}, nil, false
  local function flush()
    if group and not drop then for _, g in ipairs(group) do out[#out + 1] = g end end
    group, drop = nil, false
  end
  for i, r in ipairs(raw) do
    local key = r.s:match("^(%S+)")
    if r.top and key == "BYPASS" then flush(); group = {} end
    if i == #raw then flush() end -- the closing ">"
    local sk = r.top and key == "FXID" and skip and skip[r.s:match("^FXID (%S+)")]
    if sk == true then drop = true elseif sk and group then group[1] = sk end -- (a string: the BYPASS line to send for it, lib/hops.lua's held chain)
    if not chain_local(r.parent, key) then
      if group then group[#group + 1] = r.s else out[#out + 1] = r.s end
    end
  end
  return table.concat(out, "\n") .. "\n"
end

local portable = merges.portable -- (what a chunk says differently on each platform, said one way: lib/mirror_merge.lua)
mirror.portable = portable

-- Restless plug-ins: some write different saved data every time REAPER reads it (Kilohearts Disperser, Mac, 0.42.0). Their
-- track never held still, so its chain never went out and its parts never got a print, and nothing said so. One that
-- keeps changing while its knobs don't and nothing else in the project does (mirror.watch) goes on this list, which
-- every machine learns from the band's events. Its saved data then stays out of the hash, and its knobs say when it
-- really changed. (Not everything's data: loading a patch in a sampler changes only that, and must still count.)
mirror.restless = {} -- plug-in name -> true
mirror.RESTLESS_FLIPS, mirror.RESTLESS_SECS = 4, 12 -- changes in a row, and for how long, before a plug-in counts
local RESTLESS_KEY = "restless plugins"
local restless_key = merges.restless_key
local function fx_block_start(l) return l:sub(1, 1) == "<" and l ~= "<FXCHAIN" and not l:match("^<PARMENV") and not l:match("^<PROGRAMENV") end
-- A chain's plug-in blocks. Pure. -> list of { key, first, last, text } (line numbers in `lines`).
function mirror.plugin_blocks(lines)
  local out, i = {}, 1
  while i <= #lines do
    if fx_block_start(lines[i]) then
      local depth, j = 1, i
      while depth > 0 and j < #lines do
        j = j + 1
        if lines[j]:sub(1, 1) == "<" then depth = depth + 1 elseif lines[j] == ">" then depth = depth - 1 end
      end
      local b = out[#out]
      if lines[i]:match("^<JS_SER") and b then -- (a JSFX's saved data: a block of its own, right after the plug-in's)
        b.last, b.text = j, table.concat(lines, "\n", b.first, j)
      else
        out[#out + 1] = { key = restless_key(lines[i]), first = i, last = j, text = table.concat(lines, "\n", i, j) }
      end
      i = j
    end
    i = i + 1
  end
  return out
end
local function chain_lines(chain)
  local lines = {}
  for l in (chain or ""):gmatch("[^\n]+") do lines[#lines + 1] = l end
  return lines
end
-- The restless plug-ins in a chain (a list), and which plug-ins differ between two reads of one. Pure.
function mirror.restless_in(chain)
  if not next(mirror.restless) then return nil end
  local names, seen = {}, {}
  for _, b in ipairs(mirror.plugin_blocks(chain_lines(chain))) do
    if b.key and mirror.restless[b.key] and not seen[b.key] then seen[b.key] = true; names[#names + 1] = b.key end
  end
  return #names > 0 and names or nil
end
-- (inside a container, the plug-ins in it, never the container: "Container" went on the list, and everything inside every container, in
-- every song and on every computer, was left out of the hash from then. Plug-in test, 0.59.17)
function mirror.fx_differing(a, b)
  local names = {}
  local function cmp(la, lb)
    local x, y = mirror.plugin_blocks(la), mirror.plugin_blocks(lb)
    if #x ~= #y then return end
    for i, p in ipairs(x) do
      local q = y[i]
      if p.key and p.key == q.key and p.text ~= q.text then
        if p.text:match("^<CONTAINER") then
          local ia, ib = {}, {}
          for k = p.first + 1, p.last - 1 do ia[#ia + 1] = la[k] end
          for k = q.first + 1, q.last - 1 do ib[#ib + 1] = lb[k] end
          cmp(ia, ib)
        else names[#names + 1] = p.key end
      end
    end
  end
  cmp(chain_lines(a), chain_lines(b))
  return names
end
-- Plug-ins with a knob an LFO or audio control moves: what they save holds that knob as it was at that instant, so the
-- chain never read the same on two machines, or twice (a lasting "differs". Linux stress test, 0.58.77). Their saved data
-- stays out of the hash, as a restless plug-in's does, and their other knobs say when they really changed. Pure.
-- -> { [plug-in block number] = { [knob] = true }, or true for a container with one inside }, or nil.
function mirror.modulated(chain)
  local lines = type(chain) == "table" and chain or chain_lines(chain)
  local function moved(i) -- lines[i] opens a PROGRAMENV: the knob it moves, if an LFO or audio control is on
    local h = lines[i]:match("^%s*(.-)%s*$")
    if h:match("^<PROGRAMENV%s+%S+%s+1") then return nil end -- (its modulation switched off)
    for k = i + 1, #lines do
      local l = lines[k]:match("^%s*(.-)%s*$")
      if l == ">" then return nil end
      if l == "LFO 1" or l == "AUDIOCTL 1" then return tonumber(h:match("^<PROGRAMENV%s+(%d+)")) or -1 end
    end
  end
  local blocks, out = mirror.plugin_blocks(lines), {}
  for b, x in ipairs(blocks) do
    for i = x.first + 1, x.last - 1 do
      if lines[i]:match("^%s*<PROGRAMENV") and moved(i) then out[b] = true; break end
    end
    if out[b] == nil then
      for i = x.last + 1, blocks[b + 1] and blocks[b + 1].first - 1 or #lines do
        local p = lines[i]:match("^%s*<PROGRAMENV") and moved(i)
        if p then out[b] = out[b] or {}; out[b][p] = true end
      end
    end
  end
  return next(out) and out or nil
end
-- Do two chains say the same thing? Each plug-in's saved data is lines of base64, and REAPER re-encodes it on a machine
-- without the plug-in: the same bytes in different pieces (a Mac's GGD chain read differently on the PC and the laptop,
-- so the fingerprints stayed apart for good: 0.42.2). Pure.
local BASE64_BLOCK = { VST = true, AU = true, CLAP = true, LV2 = true, DX = true }
function mirror.fx_same(a, b)
  if a == b then return true end
  local fxfiles = require("fxfiles")
  local function bytes(chain)
    local out, plug = {}, false
    for _, l in ipairs(chain_lines(chain)) do
      -- (inside a plug-in's saved data every line is base64, however short: a Surge XT chain's "AA==" read as text and never matched. Linux stress test, 0.58.77)
      if l:sub(1, 1) == "<" then plug = BASE64_BLOCK[l:match("^<(%u+)") or ""] == true
      elseif l == ">" then plug = false end
      out[#out + 1] = (l:match("^[A-Za-z0-9+/]+=*$") and (#l >= 8 or plug)) and fxfiles.unbase64(l) or ("\0" .. l .. "\0")
    end
    return table.concat(out)
  end
  return bytes(a) == bytes(b)
end
function mirror.restless_load()
  if mirror.restless_loaded or not (reaper and reaper.GetExtState) then return end
  mirror.restless_loaded = true
  for n in reaper.GetExtState("BandSync", RESTLESS_KEY):gmatch("[^\n]+") do if n ~= "Container" then mirror.restless[n] = true end end -- (one put there before 0.59.17)
end
-- Add names (from this machine's own finding, or a bandmate's event). -> whether any is new.
function mirror.restless_add(names)
  local new = false
  for _, n in ipairs(type(names) == "table" and names or {}) do
    if type(n) == "string" and n ~= "Container" and not mirror.restless[n] then mirror.restless[n], new = true, true end -- (never a container: 0.59.17)
  end
  if new and reaper and reaper.SetExtState then
    local all = {}
    for n in pairs(mirror.restless) do all[#all + 1] = n end
    table.sort(all)
    reaper.SetExtState("BandSync", RESTLESS_KEY, table.concat(all, "\n"), true)
  end
  return new
end
local function restless_sig()
  local all = {}
  for n in pairs(mirror.restless) do all[#all + 1] = n end
  table.sort(all)
  return table.concat(all, "\0")
end
-- All the knobs of a track's plug-ins, as a string: what says a restless plug-in really changed. This machine's only,
-- as a machine without the plug-in has none, so it never goes into a hash. Knobs an LFO or audio control moves are left
-- out (mirror.modulated, as of this track's last scan): they never hold still.
mirror.mod_params = {} -- track -> mirror.modulated of its whole chain
-- The plug-ins inside a container at top-level index i, at any depth: their addresses (REAPER's container_item.k), or nil for a plain one.
-- (A knob or preset changed inside a container was never sent: only the top-level plug-ins were looked at, and the container's own knobs
-- didn't move. Plug-in test, 0.59.14)
local function inside(tr, i)
  local _, n = reaper.TrackFX_GetNamedConfigParm(tr, i, "container_count")
  if not tonumber(n) then return nil end
  local out = {}
  local function walk(idx)
    local _, c = reaper.TrackFX_GetNamedConfigParm(tr, idx, "container_count")
    if tonumber(c) then
      for k = 0, tonumber(c) - 1 do
        local _, sub = reaper.TrackFX_GetNamedConfigParm(tr, idx, "container_item." .. k)
        if tonumber(sub) then walk(math.tointeger(tonumber(sub))) end
      end
    elseif idx ~= i then out[#out + 1] = idx end
  end
  walk(i)
  return out
end
mirror.fx_inside = inside
function mirror.fx_params(tr)
  local out, mods = {}, mirror.mod_params[tr]
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local m = mods and mods[i + 1]
    if m ~= true then
      for p = 0, math.min(reaper.TrackFX_GetNumParams(tr, i), 3000) - 1 do
        out[#out + 1] = (m and m[p]) and "~" or string.format("%.4f", (reaper.TrackFX_GetParamNormalized(tr, i, p)))
      end
      -- (a container: the knobs of what's in it too. Only then: a plain chain reads as before, so what's stored for it still agrees)
      for _, sub in ipairs(inside(tr, i) or {}) do
        out[#out + 1] = ":"
        for p = 0, math.min(reaper.TrackFX_GetNumParams(tr, sub), 3000) - 1 do out[#out + 1] = string.format("%.4f", (reaper.TrackFX_GetParamNormalized(tr, sub, p))) end
      end
    end
    out[#out + 1] = "|"
  end
  return table.concat(out, ",")
end
-- A chain whose saved data its own knobs speak for: a restless plug-in on it, or a modulated one. Pure.
-- Each plug-in's preset name: a script or an action that loads one changes the data with no window open, often with no knob moving.
function mirror.fx_presets(tr)
  local out = {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local w = select(2, reaper.TrackFX_GetPreset(tr, i, "")) or ""
    for _, sub in ipairs(inside(tr, i) or {}) do w = w .. ":" .. (select(2, reaper.TrackFX_GetPreset(tr, sub, "")) or "") end -- (inside a container too)
    out[#out + 1] = w
  end
  return table.concat(out, "|")
end
mirror.fx_quiet_presets = mirror.fx_quiet_presets or {} -- (the presets as of the knobs in mirror.fx_quiet)
-- (memoized by the restless list and the text: every look asked it of every unchanged chain, parsing it twice. 0.59.14, review)
function mirror.knobs_count(chain)
  return mirror.memo("k\0" .. restless_sig(), chain, function() return mirror.restless_in(chain) ~= nil or mirror.modulated(chain) ~= nil end)
end

-- A plug-in chain's hash: its normalized text without each VST's last state line. That line is REAPER's program block
-- for the instance, and a plug-in loaded from a chunk writes its program name there ("Program 1"), so the same chain
-- read differently on every machine that received it (laptop, 2026-10-31). It still travels; only the hash skips it.
-- A restless plug-in counts by its first line only.
-- The saved data of the restless and modulated plug-ins in lines[from..to] taken out, back to front. Inside a container, only those of
-- its plug-ins (one modulated plug-in in a container hid every plug-in's data in it, so a patch changed beside it never went out:
-- review, 0.58.89); a container's own lines stay, so one added inside still counts.
local function hide_moving(lines, from, to)
  local sub = {}
  for k = from, to do sub[#sub + 1] = lines[k] end
  local mods, blocks = mirror.modulated(sub), mirror.plugin_blocks(sub)
  for b = #blocks, 1, -1 do
    local first, last = from + blocks[b].first - 1, from + blocks[b].last - 1
    if blocks[b].key and mirror.restless[blocks[b].key] or mods and type(mods[b]) == "table" then
      for k = last - 1, first + 1, -1 do table.remove(lines, k) end
    elseif mods and mods[b] and last - first > 1 then
      local before = #lines
      hide_moving(lines, first + 1, last - 1)
      if #lines == before then -- (the container's own knob is the modulated one: its plug-ins' data, as before)
        for k = last - 1, first + 1, -1 do if lines[k]:match("^[A-Za-z0-9+/]+=*$") then table.remove(lines, k) end end
      end
    end
  end
end
function mirror.fx_hash(chain)
  local lines = {}
  for l in portable(chain):gmatch("[^\n]+") do lines[#lines + 1] = l end
  if next(mirror.restless) or mirror.modulated(lines) then hide_moving(lines, 1, #lines) end
  local i = 1
  while i <= #lines do
    if lines[i]:match("^<VST") then
      local j = i + 1
      while j <= #lines and lines[j] ~= ">" and lines[j]:sub(1, 1) ~= "<" do j = j + 1 end
      if lines[j] == ">" and j - i - 1 >= 2 and lines[j - 1]:match("^[A-Za-z0-9+/]+=*$") then table.remove(lines, j - 1) end
    end
    i = i + 1
  end
  return mirror.hash(table.concat(lines, "\n") .. "\n")
end
-- An item's hash: the same, with take plug-ins' program lines left out as above (laptop, block K: an item with ReaEQ
-- as a take FX read "Program 1" on the machine that applied it, and the two projects differed for good). Only items
-- with a VST take FX hash differently from before, so an update doesn't make everyone send every item again.
-- (kept per exact text, as the scan's own work is: four passes over every item's text each look, a quarter of a look at 2,000 items.
-- The restless list is part of the key, as its take FX part depends on it. 0.59.19)
local item_hash
function mirror.item_hash(track, state)
  return mirror.memo("ih\0" .. restless_sig() .. "\0" .. track, state, function() return item_hash(track, state) end)
end
function item_hash(track, state)
  state = portable(state)
  -- (on a lane its YPOS is only its share of the track's height, so adding a lane changed every item, and each machine sent
  -- them all: 500 events a minute on Bass Guitar, laptop and PC, 0.42.7. BANDLANE is what counts)
  if state:find("BANDLANE", 1, true) then state = state:gsub("YPOS [^\n]*\n", "") end
  -- (nothing below changes an item with neither: its hash as the end of this has it, without splitting every item into lines each look. 0.59.14, review)
  if not state:find("<TAKEFX", 1, true) and not state:find("<VST", 1, true) then return mirror.hash(track .. "\n" .. state) end
  local lines = {}
  for l in (state .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  lines[#lines] = nil -- (the one the extra "\n" made)
  -- take FX that never read the same (a restless plug-in, an LFO on a knob) leave their saved data out, as on a track (mirror.fx_hash):
  -- an item with one changed on every look, and went out over and over (plug-ins review, 0.58.76). Only those items hash differently.
  -- shortcut: a knob turned on such a take FX goes out with the item's next other change (items have no knob check, as chains do).
  local dropped = false
  if state:find("<TAKEFX", 1, true) then
    local trimmed, drop, k = {}, {}, 1
    for n, l in ipairs(lines) do trimmed[n] = l:match("^%s*(.-)%s*$") end
    while k <= #trimmed do
      if trimmed[k]:match("^<TAKEFX") then
        local depth, e = 1, k
        while depth > 0 and e < #trimmed do
          e = e + 1
          if trimmed[e]:sub(1, 1) == "<" then depth = depth + 1 elseif trimmed[e] == ">" then depth = depth - 1 end
        end
        local part = table.move(trimmed, k + 1, e - 1, 1, {}) -- (inside it: <TAKEFX itself would read as one plug-in)
        local mods = mirror.modulated(part)
        for b, x in ipairs(mirror.plugin_blocks(part)) do
          if x.key and mirror.restless[x.key] or mods and mods[b] then
            for d = x.first + 1, x.last - 1 do
              if mods and mods[b] == true then drop[k + d] = part[d]:match("^[A-Za-z0-9+/]+=*$") ~= nil else drop[k + d] = true end
            end
          end
        end
        k = e
      end
      k = k + 1
    end
    for d = #lines, 1, -1 do if drop[d] then table.remove(lines, d); dropped = true end end
  end
  if not dropped and not state:find("<VST", 1, true) then return mirror.hash(track .. "\n" .. state) end
  local i = 1
  while i <= #lines do
    if lines[i]:match("^%s*<VST") then
      local j = i + 1
      while j <= #lines and not lines[j]:match("^%s*>$") and not lines[j]:match("^%s*<") do j = j + 1 end
      if j <= #lines and lines[j]:match("^%s*>$") and j - i - 1 >= 2 and lines[j - 1]:match("^%s*[A-Za-z0-9+/]+=*$") then table.remove(lines, j - 1) end
    end
    i = i + 1
  end
  return mirror.hash(track .. "\n" .. table.concat(lines, "\n"))
end

-- A track's automation ("E-" + its oid) and its receives ("R-", each with its send envelopes) travel as objects of
-- their own, cut out of the track chunk and spliced back in. Writing a track chunk back keeps its plug-ins running
-- (measured, REAPER 7.83: no @init, even with a changed parameter). Which envelopes show, which is armed and how
-- tall its lane is stay each person's own. A receive names its source track by oid (REAPER's chunk says its
-- position); receives from a track that isn't mirrored (Real time, live views) stay as they are on each machine.
mirror.HV = 8 -- how object hashes are made: bump it whenever what goes into one changes (events carry it as hv). 8: a track's line leaves out its parent (0.59.14)
mirror.KIND = { T = "track", F = "fx", E = "env", R = "recv", M = "misc", I = "item" } -- (an oid's first letter)
mirror.PART = { fx = "the plug-ins", env = "the automation", recv = "the sends", misc = "the groups, lock, input FX or note names" }
mirror.PARTS = { "F", "E", "R", "M" } -- (what a track oid T-x carries: F-x, E-x, R-x, M-x)
local ENV_LOCAL = { EGUID = true, ARM = true, VIS = true, LANEHEIGHT = true, POOLEDENVINST = true }
local function is_env(u) return u.block and u.tag:find("ENV") and u.tag:sub(1, 3) ~= "AUX" end
local function is_aux(u) return u.block and u.tag:sub(1, 3) == "AUX" and u.tag:find("ENV") end
-- (FREEZE: what unfreezing brings back, so anyone can unfreeze a track someone else froze. Linux stress test, 0.58.77)
-- shortcut: audio items kept in a FREEZE block point at the freezer's own files; a frozen audio track unfrozen elsewhere finds them offline.
local MISC = { GROUP_FLAGS = true, GROUP_FLAGS_HIGH = true, LOCK = true, FXCHAIN_REC = true, MIDINOTENAMES = true, FREEZE = true }
local function is_misc(u) return MISC[u.tag] ~= nil end

-- A track chunk's first line, its top-level parts in order ({ tag, lines, block }) and its closing line.
local function track_units(chunk)
  local head, units, tail, depth, cur = nil, {}, ">", 0, nil
  for line in (chunk:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
    local s = line:match("^%s*(.-)%s*$")
    if s == "" then -- (nothing)
    elseif depth == 0 then head, depth = line, 1
    elseif depth == 1 then
      if s == ">" then tail, depth = line, 0
      elseif s:sub(1, 1) == "<" then cur = { tag = s:match("^<(%S+)"), lines = { line }, block = true }; units[#units + 1] = cur; depth = 2
      else units[#units + 1] = { tag = s:match("^(%S+)"), lines = { line } } end
    else
      cur.lines[#cur.lines + 1] = line
      if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
    end
  end
  return head, units, tail
end

-- An envelope block as it travels: trimmed, without its view lines.
local function env_norm(lines, drop)
  local out, depth = {}, 0
  for _, l in ipairs(lines) do
    local s = l:match("^%s*(.-)%s*$")
    if not (depth == 1 and (drop or ENV_LOCAL)[s:match("^(%S+)")]) then out[#out + 1] = s end
    if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
  end
  return table.concat(out, "\n") .. "\n"
end

-- A track's MIDI note names, { "chan pitch" = name }, from its chunk or a travelling state. A cleared name stays in
-- REAPER's block as "" (the same as none).
function mirror.note_names(text)
  local out, on = {}, false
  for line in text:gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    if s == "<MIDINOTENAMES" then on = true
    elseif on and s == ">" then on = false
    elseif on then
      local chan, pitch, rest = s:match("^(%-?%d+)%s+(%d+)%s+(.*)$")
      local name = rest and (rest:match('^"(.-)"') or rest:match("^'(.-)'") or rest:match("^`(.-)`") or rest:match("^(%S+)"))
      if name and name ~= "" then out[chan .. " " .. pitch] = name end
    end
  end
  return out
end

-- A track chunk's envelopes, receives and other settings (groups, lock, input FX, note names) as they travel.
-- `oid_at(index)`: the oid of the track at that 0-based position, nil when it isn't mirrored (its receive is left out).
function mirror.track_parts(chunk, oid_at)
  local _, units = track_units(chunk)
  local env, recv, misc, cur = {}, {}, {}, nil
  for _, u in ipairs(units) do
    if u.tag == "MIDINOTENAMES" then -- (named notes only, in a fixed order: set through REAPER's API on the other side)
      local names, keys = mirror.note_names(table.concat(u.lines, "\n")), {}
      for k in pairs(names) do keys[#keys + 1] = k end
      table.sort(keys)
      if #keys > 0 then
        local b = { "<MIDINOTENAMES" }
        for _, k in ipairs(keys) do local q = names[k]:find('"') and "`" or '"'; b[#b + 1] = k .. " " .. q .. names[k] .. q end
        misc[#misc + 1] = table.concat(b, "\n") .. "\n>\n"
      end
    elseif is_misc(u) then misc[#misc + 1] = u.block and env_norm(u.lines, FX_LOCAL) or (u.lines[1]:match("^%s*(.-)%s*$") .. "\n") end
    if u.tag == "AUXRECV" then
      local idx, rest = u.lines[1]:match("^%s*AUXRECV%s+(%d+)(.-)%s*$")
      local src = idx and oid_at(tonumber(idx))
      cur = src and { "AUXRECV " .. src .. rest .. "\n" } or nil
      if cur then recv[#recv + 1] = cur end
    elseif is_aux(u) then
      if cur then cur[#cur + 1] = env_norm(u.lines) end
    else
      cur = nil
      if is_env(u) then env[#env + 1] = env_norm(u.lines) end
    end
  end
  for i, r in ipairs(recv) do recv[i] = table.concat(r) end
  return table.concat(env), table.concat(recv), table.concat(misc)
end

-- The track chunk with its envelopes (what = "env") or its mirrored receives ("recv") replaced by `state` (as
-- track_parts gives it). `index_of(oid)`: that track's 0-based position here, nil when it isn't here yet (then nil
-- is returned: try again later). Envelopes keep this machine's view lines; a new one shows in its lane.
function mirror.splice_parts(chunk, what, state, index_of, oid_at)
  local head, units, tail = track_units(chunk)
  local new, view = {}, {}
  for _, u in ipairs(units) do
    if is_env(u) then
      local keep = {}
      for k = 2, #u.lines do
        local key = u.lines[k]:match("^%s*(%S+)")
        if ENV_LOCAL[key] and key ~= "EGUID" and key ~= "POOLEDENVINST" then keep[#keep + 1] = u.lines[k] end
      end
      view[u.tag] = keep
    end
  end
  local cur
  for line in state:gmatch("[^\n]+") do -- the incoming parts, back into chunk lines
    local src, rest = line:match("^AUXRECV (%S+)(.*)$")
    if src then
      local idx = index_of(src)
      if not idx then return nil end
      cur = { tag = "AUXRECV", lines = { "AUXRECV " .. idx .. rest } }
      new[#new + 1] = cur
    elseif line:match("^BANDAI") or line:match("^BANDFXEN") then -- (automation items: rebuilt through the API, mirror.set_ai; the master's FX button)
    elseif not (cur and cur.open) and line:sub(1, 1) ~= "<" then -- (a lone line: GROUP_FLAGS, LOCK)
      cur = { tag = line:match("^(%S+)"), lines = { line } }
      new[#new + 1] = cur
    elseif line:sub(1, 1) == "<" and not (cur and cur.open) then
      cur = { tag = line:match("^<(%S+)"), lines = { line }, block = true, open = 1 }
      new[#new + 1] = cur
      if what == "env" then for _, v in ipairs(view[cur.tag] or { "VIS 1 1 1" }) do cur.lines[#cur.lines + 1] = v end end
    else
      cur.lines[#cur.lines + 1] = line
      if line:sub(1, 1) == "<" then cur.open = cur.open + 1 elseif line == ">" then cur.open = cur.open - 1 end
      if cur.open == 0 then cur.open = nil end
    end
  end
  -- note names aren't read from a chunk written back (measured 7.83): mirror.apply sets them through REAPER's API
  for i = #new, 1, -1 do if new[i].tag == "MIDINOTENAMES" then table.remove(new, i) end end
  local out, at, after_recv = { head }, nil, false
  for _, u in ipairs(units) do
    local drop
    if what == "env" then drop = is_env(u)
    elseif what == "misc" then drop = is_misc(u) and u.tag ~= "MIDINOTENAMES"
    elseif u.tag == "AUXRECV" then
      local idx = u.lines[1]:match("^%s*AUXRECV%s+(%d+)")
      drop = idx and oid_at(tonumber(idx)) ~= nil
      after_recv = drop
    else drop = is_aux(u) and after_recv end
    if not is_aux(u) and u.tag ~= "AUXRECV" then after_recv = false end
    -- the new parts go where the old ones were, else before the plug-ins and items
    if not at and (drop or u.tag == "FXCHAIN" or u.tag == "ITEM" or (what == "recv" and is_env(u))) then
      at = true
      for _, n in ipairs(new) do for _, l in ipairs(n.lines) do out[#out + 1] = l end end
    end
    if not drop then for _, l in ipairs(u.lines) do out[#out + 1] = l end end
  end
  if not at then for _, n in ipairs(new) do for _, l in ipairs(n.lines) do out[#out + 1] = l end end end
  out[#out + 1] = tail
  return table.concat(out, "\n") .. "\n"
end

-- The plug-ins in a track chunk's <FXCHAIN> whose FXID is in `keep`, as raw lines (each from its BYPASS line to the
-- line before the next plug-in's): what stays on this machine when the band's chain lands (the master's live link).
function mirror.fx_blocks(track_chunk, keep)
  local out, group, depth, on, hit = {}, nil, 0, false, false
  local function flush() if group and hit then for _, l in ipairs(group) do out[#out + 1] = l end end; group, hit = nil, false end
  for line in track_chunk:gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    if not on and s == "<FXCHAIN" then on, depth = true, 1
    elseif on then
      local top = depth == 1
      if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
      if depth == 0 then flush(); break end
      if top and s:match("^BYPASS ") then flush(); group = {} end
      if group then group[#group + 1] = s end
      if top and keep[s:match("^FXID (%S+)") or ""] then hit = true end
    end
  end
  return out
end

-- The plug-ins a chain uses, as REAPER names them ("VST3: ReaEQ (Cockos)", "JS: utility/volume"). Pure.
function mirror.fx_names(chain)
  local out = {}
  for line in chain:gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    local name = s:match('^<%u+%d? "([^"]+)"') or (s:match("^<JS (%S+)") and ("JS: " .. s:match("^<JS (%S+)")))
    if name then out[#out + 1] = name end
  end
  return out
end

-- 32-bit FNV-1a: cheap, stable on every Lua; enough to tell versions apart (not a security hash).
-- Results for text seen before (a whole look reads every track and item; most haven't changed since the last one,
-- and working them out again in Lua was most of a look's time: 0.5 s at 60 tracks and 2,000 items, measured
-- 2026-10-31). Keyed by the exact text, so any change misses and is worked out afresh. Emptied when its keys and what
-- they hold reach 128 MB (a track's text holds all its items, so a busy session makes big ones), or 50,000 of them.
-- (128 counting both is what 64 counting keys alone came to: 0.59.19)
-- (keyed by a short prefix, then by the text itself: "prefix .. text" made a copy of every chunk at every look, only to look it up.
-- Review list, 0.59.40)
-- (in two generations, each half the old limit: full, the newer becomes the older and a new one starts, and what's found in the older moves
-- up. Emptied whole, the next look worked out everything again, 2 to 4 s on a big song. Round 1 review, 0.59.45)
-- (and turned over only between looks, mirror.memo_turn at each scan's start: turned over mid-look, a song whose entries in use came to 64 to
-- 128 MB lost some before they were touched again, and recomputed up to all of them every look, 0.2 to 2 s. Between looks the newer holds
-- everything the last look used, so nothing in use is ever lost; the cost is memory, up to twice what a look uses. Inside a look it turns over
-- only past four times the limit, a safety valve. Round 2 review, 0.59.46)
local memo, memo_n, memo_bytes, memo_old = {}, 0, 0, {}
mirror.MEMO_N, mirror.MEMO_BYTES = 25000, 64 * 1048576
local function memo_over(k) return memo_n > mirror.MEMO_N * k or memo_bytes > mirror.MEMO_BYTES * k end
function mirror.memo_turn()
  if memo_over(1) then memo_old, memo, memo_n, memo_bytes = memo, {}, 0, 0 end
end
function mirror.memo(prefix, text, make)
  local box = memo[prefix]
  local v = box and box[text]
  if v == nil then
    local old = memo_old[prefix]
    v = old and old[text]
    if memo_over(4) then memo_old, memo, memo_n, memo_bytes = memo, {}, 0, 0 end
    if v == nil then v = make() end
    -- (what it holds counts too, not just its key: a track's parts or an item's text are as big as the key. Review, 0.59.19)
    local size = #prefix + #text
    if type(v) == "string" then size = size + #v
    elseif type(v) == "table" then for _, x in pairs(v) do if type(x) == "string" then size = size + #x end end end
    box = memo[prefix]
    if not box then box = {}; memo[prefix] = box end
    box[text], memo_n, memo_bytes = v, memo_n + 1, memo_bytes + size
  end
  return v
end
-- (eight bytes a call, masked once at the end: the low 32 bits of Lua's wrapping 64-bit product depend only on the low 32 bits of what made
-- it, so the same hash as byte by byte with a mask each step, four times faster. A changed 300 KB text (mirror.root at 4,700 objects, a track
-- with big plug-in states) took 9 ms to hash, 2 now. tests/test_0_60_rt_bigproj.lua checks it against the plain loop. Bigger projects, rt)
local byte = string.byte
local function fnv(s)
  local h, n, i = 2166136261, #s, 1
  while i + 7 <= n do
    local a, b, c, d, e, f, g, k = byte(s, i, i + 7)
    h = (h ~ a) * 16777619; h = (h ~ b) * 16777619; h = (h ~ c) * 16777619; h = (h ~ d) * 16777619
    h = (h ~ e) * 16777619; h = (h ~ f) * 16777619; h = (h ~ g) * 16777619; h = (h ~ k) * 16777619
    i = i + 8
  end
  for j = i, n do h = (h ~ byte(s, j)) * 16777619 end
  return string.format("%08x", h & 0xFFFFFFFF)
end
mirror.fnv = fnv -- (tests)
-- (short ones too, in a table of their own: hashed afresh byte by byte in Lua, they were 7% of a look at 2,000 items, and kept in the
-- memo they'd fill its 50,000 and empty it of the big ones. 0.59.19)
local short, short_n = {}, 0
function mirror.hash(s)
  if #s < 256 then
    local h = short[s]
    if not h then
      if short_n > 20000 then short, short_n = {}, 0 end
      h = fnv(s); short[s], short_n = h, short_n + 1
    end
    return h
  end
  return mirror.memo("h", s, function() return fnv(s) end)
end

-- The next revision number. An owner's change (they've claimed it, or they drive and it's unclaimed) steps far past anything made meanwhile, so it stands however many
-- times someone else changed it while apart, and every computer agrees without being told who owned what. Whoever has seen it follows it with a higher number still.
mirror.OWNER_STEP = 1000
function mirror.next_rev(rev, owned) return (rev or 0) + 1 + (owned and mirror.OWNER_STEP or 0) end
mirror.SESSION_SECS = 30 -- changes to one thing this close together are one edit (watch)
mirror.sessions = {} -- proj .. oid -> { rev, at }: our last change to it
-- What equal revisions are settled by, an "order": "<ms>|<user>" since 0.58.43, a hybrid logical clock (milliseconds, never behind any change
-- this computer has seen, so a clock that's minutes off can't win ties it shouldn't: docs/clashes.md), or "<YYYY-MM-DDTHH:MM:SSZ><user>" from
-- before. -> milliseconds (UTC), the rest. Pure.
local utc_secs = judge.utc_secs
mirror.utc_secs, mirror.order_parts, mirror.order_of = judge.utc_secs, judge.order_parts, judge.order_of
-- The clock: never behind the newest change seen (kept in non-persistent ExtState: Live sync and the panel each post changes)
function mirror.hlc_seen(v)
  v = tonumber(v)
  if v and v > (tonumber(reaper.GetExtState("BandSync", "hlc")) or 0) then reaper.SetExtState("BandSync", "hlc", string.format("%d", v), false) end
end
function mirror.hlc_next()
  local v = math.max(math.floor(require("together").now() * 1000), (tonumber(reaper.GetExtState("BandSync", "hlc")) or 0) + 1)
  reaper.SetExtState("BandSync", "hlc", string.format("%d", v), false)
  return v
end
-- Which of two revisions of one object wins: higher rev, then the later order, then the larger user name (lib/judge.lua).
mirror.newer = judge.newer

-- The merges themselves (merge_item, merge_midi, merge_env, merge_track, merge_fx, side3, note_changes, pieces, pieces_changed) are pure and
-- live in lib/mirror_merge.lua (rt-sync2 phase 1); which versions may be merged, and merge_state's choice of merge, stay here.
for _, k in ipairs({ "merge_item", "side3", "note_changes", "merge_midi", "merge_env", "merge_track", "merge_fx", "pieces", "pieces_changed" }) do mirror[k] = merges[k] end


-- What merges, and how: items line by line (notes by note), automation by point, tracks by setting, plug-in chains by plug-in (rt-p1).
-- -> the merged state and the keys both changed, or nil.
-- Which versions may be merged, the same on every computer (rt-p1, backlog 1.1):
--   a track's settings or automation only when made after merging them began (rt-merge, c130487, 2026-11-20 19:42 UTC): older pairs made
--   apart were settled newest-wins by every computer then, and heal (mirror.settled) merging them now changed the track everywhere, a day late;
--   a plug-in chain only when both versions come from a StudioSync that merges chains (`mg` >= 1, set by sync.post): with an older one about,
--   it keeps the newest, so these do too.
mirror.MG = 1 -- (on every change this version sends, as `mg`: 1 = plug-in chains merge by plug-in)
mirror.MERGE_SINCE = { track = "20261120-194204", env = "20261120-194204" }
mirror.MERGE_MG = { fx = 1 }
mirror.MERGES = { item = "merge_item", env = "merge_env", track = "merge_track", fx = "merge_fx" }
function mirror.mergeable(x)
  if not (type(x) == "table" and not x.gone and mirror.MERGES[x.obj] ~= nil and type(x.state) == (x.obj == "track" and "table" or "string")) then return false end
  local need = mirror.MERGE_MG[x.obj]
  if need and (tonumber(x.mg) or 0) < need then return false end
  local since = mirror.MERGE_SINCE[x.obj]
  if since and type(x.id) == "string" then
    for d in x.id:gmatch("(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d)Z") do if d < since then return false end end
  end
  return true
end
function mirror.merge_state(kind, base, winner, loser, loser_name)
  local f = mirror.MERGES[kind]
  if not f or type(base) ~= type(winner) or type(winner) ~= type(loser) or type(winner) ~= (kind == "track" and "table" or "string") then return nil end
  return mirror[f](base, winner, loser, loser_name)
end
-- Does a change (`state`, of `kind`, made from `from`, the version its maker's computer held) touch a piece (a note, a point, a setting) that
-- `user`, who holds an auto-claim on it (lib/claimask.lua soft), changed lately: in the changes of theirs `from` builds on, back as far as an
-- auto-claim lasts (sync.AUTO_IDLE)? By what each changed from the version it started from, not by a three-way merge: setting their new value
-- back to what it was is a change to their piece too (it went out with no ask and undid theirs: Cross Test, 0.59.49.72). Nothing of theirs
-- lately: no clash. A version on the way not here, or one that can't be read as pieces: a clash (asked, as before). Pure but for reading
-- events and the clock.
function mirror.clashes(room_dir, kind, state, from, user)
  local cut = (require("together").now() - require("sync").AUTO_IDLE) * 1000
  local theirs, any, todo, seen, n = {}, false, { from }, {}, 0
  -- (a note of theirs that a later version moved or changed again goes by another key by then: its key as `from` has it, through each
  -- version between (mirror.note_changes pairs a note with what it was). Without it a second move of a note the claimer had moved, after
  -- your own transposition of it, wasn't seen as theirs and nobody was asked: P1-8's second part, rt-r3. rt-converge)
  local fwd = {}
  local function forward(x, y) -- y: what x was made on, or a side of the merge x is -> y's note keys as `from` has those notes
    local fx = fwd[x.id] or {}
    if kind ~= "item" or type(x.state) ~= "string" or type(y.state) ~= "string" then return fx end
    local fy
    for kx, nc in pairs(mirror.note_changes(y.state, x.state)) do
      fy = fy or setmetatable({}, { __index = fx })
      fy[nc.from] = fx[kx] or kx
    end
    return fy or fx
  end
  while #todo > 0 and n < 64 do
    local x = table.remove(todo, 1)
    if type(x) == "table" and x.id and not seen[x.id] then
      seen[x.id], n = true, n + 1
      local F = fwd[x.id] or {}
      local w, l = mirror.split_merge(x.id)
      local at = w and math.huge or mirror.order_parts(mirror.order_of(x)) -- (a merged version is as new as its newer side: both are looked at)
      if at >= cut then -- (what it builds on is older still: no further down than an auto-claim lasts)
        if not w and x.user == user and not x.gone then
          if not (mirror.mergeable(x) and x.obj == kind) then return true end
          local b = x.base_ev and mirror.event_file(room_dir, x.base_ev)
          if x.base_ev and not b then return true end
          local bp, xp = b and mirror.mergeable(b) and mirror.pieces(kind, b.state) or {}, mirror.pieces(kind, x.state)
          if not xp then return true end
          -- (a MIDI note they moved or changed: which of its parts, so a transposition of their moved note isn't a clash. rt-fix6a)
          local notes = kind == "item" and b and mirror.mergeable(b) and mirror.note_changes(b.state, x.state) or {}
          for k in pairs(mirror.pieces_changed(bp, xp)) do
            local kk = F[k] or k
            local nc, t = notes[k], theirs[kk]
            if nc and t ~= true then
              t = t or {}
              for f in pairs(nc.fields) do t[f] = true end
              theirs[kk] = t
            else theirs[kk] = true end
            any = true
          end
        end
        for _, id in ipairs(w and { w, l } or { x.base_ev }) do
          local y = mirror.event_file(room_dir, id)
          if y then
            if y.id and fwd[y.id] == nil then fwd[y.id] = forward(x, y) end
            todo[#todo + 1] = y
          elseif not w and x.user == user then return true end
        end
      end
    end
  end
  if not any then return false end
  local fp, sp = mirror.mergeable(from) and from.obj == kind and mirror.pieces(kind, from.state), mirror.pieces(kind, state)
  if not (fp and sp) then return true end
  -- (a note of theirs this change moved or changed: a clash only where both changed the same part of it, as merge_midi puts the two together.
  -- A transposition of a note they'd just moved asked them, and was put back after 30 s though the merge keeps both: P1-8, rt-r1. rt-fix6a)
  local mine = {}
  if kind == "item" then for _, nc in pairs(mirror.note_changes(from.state, state)) do mine[nc.from] = nc.fields end end
  for k in pairs(mirror.pieces_changed(fp, sp)) do
    local t = theirs[k]
    if t == true then return true end
    if t then
      local f = mine[k]
      if not f then return true end -- (taken away, or another note put there)
      for part in pairs(f) do if t[part] then return true end end
    end
  end
  return false
end
-- Undo (or redo) of `e` keeps what others changed since: the version to go back to (`to`), with what the version held now (`now`) changed after
-- `e`, and `e` didn't, kept (`e` as the base of a three-way merge). Where both changed one thing, going back stands, as before. -> a version
-- like `to` (same id) or `to` itself. Pure.
function mirror.undo_keeping(e, to, now)
  if not (mirror.mergeable(to) and mirror.mergeable(now) and mirror.mergeable(e) and now.id ~= e.id and to.obj == now.obj) then return to end
  local m, both = mirror.merge_state(to.obj, e.state, to.state, now.state, now.user)
  if m == nil then return to end
  for _, k in ipairs(both or {}) do -- (not a take of theirs added by going back: plain going back, as before)
    if tostring(k):find("<SOURCE", 1, true) and not tostring(k):find("\0notes", 1, true) then return to end
  end
  local v = {}
  for k, x in pairs(to) do v[k] = x end
  v.state = m
  return v
end

-- Going back (History). `entries` are History's (recall.entries: mirror events have kind "obj"). A plan maps
-- oid -> the revision to bring back, or false (the object didn't exist then: it goes). Pure.
-- Restore project / selection state: every object in scope as it was right after entries[upto].
-- (which revision an object had: the one that won, as sync settles it (rev first, then time and name), not the latest
-- by time; a clash's loser is later by time and was never the band's: review, 2026-10-31)
local function won(a, x)
  return not x or mirror.newer({ rev = a.rev or 0, time = mirror.order_of(a) }, { rev = x.rev or 0, time = mirror.order_of(x) })
end
mirror.won = won
-- Is this entry where its object began? A first version names none before it (an owner's starts past 1, so the rev alone can't say).
-- (0.59.14, review: trimming takes changes older than 60 days away but keeps each object's newest, so an object whose first version
-- was trimmed had nothing at or before an older row, was planned as "didn't exist then", and went for everyone.) Pure.
function mirror.began(e)
  if e.base_ev then return false end -- (made from a version before it: that one existed)
  if e.base ~= nil then return e.base == 0 end
  return (e.rev or 0) <= 1 -- (an event too old to carry its base)
end
-- (each object's version then is the judge's answer from its versions up to that row (lib/judge.lua, rt-sync2b): a merge of two people's edits
-- made apart, not the newer alone, and a deletion over an edit made without seeing it, whatever their revs, as every computer held it then.
-- Missing versions count as trimmed (History has what it has). Merges are rebuilt from the room's files (mirror.event_file), found from the
-- rows' own paths; `read` (optional) says where else.)
function mirror.plan_restore(entries, upto, in_scope, read)
  local upto_by, last, first, by_id, room_dir = {}, {}, {}, {}, nil
  for i, e in ipairs(entries) do
    if e.kind == "obj" and e.oid then
      by_id[e.id or ""] = e
      if won(e, last[e.oid]) then last[e.oid] = e end
      if not first[e.oid] or won(first[e.oid], e) then first[e.oid] = e end
      if i <= upto then local t = upto_by[e.oid] or {}; upto_by[e.oid] = t; t[#t + 1] = e end
      room_dir = room_dir or (type(rawget(e, "path_")) == "string" and rawget(e, "path_"):match("^(.*)/events/[^/]+$"))
    end
  end
  read = read or (room_dir and mirror.reader(room_dir))
  local function rd(id)
    local x = by_id[id]
    if x then return x end
    if read then return read(id) end
  end
  local opt = { mergeable = mirror.mergeable, days = mirror.MERGE_DAYS, give_up = true }
  local plan = {}
  for oid, l in pairs(last) do
    local at = upto_by[oid] and judge.settled(upto_by[oid], rd, opt).v
    if not in_scope or in_scope(oid, l, at) then
      local t = at
      -- (nothing then, and its oldest version kept isn't its first: it existed, in a version trimmed away. Left as it is)
      if t or mirror.began(first[oid]) then plan[oid] = (t and not t.gone) and t or false end
    end
  end
  return plan
end
-- Restore to a saved version that holds the project's own map, oid -> event id (recall.save, mirror.known_map): exactly the versions it
-- held. By time ("each object's newest at or before it"), a bandmate's work done alone, with earlier clocks, was taken in, and "yours before
-- X's work" didn't give your side back. An object with a past here but not in the map wasn't there then (false); one whose version can't be
-- read is left as it is. `lookup(id)` -> that version (a merge rebuilt). James: all saved versions. Round 1 review, 0.59.45. Pure but for lookup.
function mirror.plan_known(entries, known, lookup, in_scope)
  local last = {}
  for _, e in ipairs(entries) do
    if e.kind == "obj" and e.oid and won(e, last[e.oid]) then last[e.oid] = e end
  end
  local plan = {}
  for oid, l in pairs(last) do
    local id = known[oid]
    local t = id and lookup(id)
    if not in_scope or in_scope(oid, l, t or nil) then
      if not id then plan[oid] = false
      elseif t then plan[oid] = (not t.gone) and t or false end
    end
  end
  return plan
end
-- What recall.save keeps: every object here, oid -> the event id of its version (a record hashed "" is gone here, and left out).
function mirror.known_map(proj)
  local t, i = {}, 0
  while true do
    local ok, oid, v = reaper.EnumProjExtState(proj, mirror.SEC, i)
    if not ok then break end
    i = i + 1
    local h, ev = v:match("^%d+|([^|]*)|([^|]*)")
    if h and h ~= "" and ev ~= "" then t[oid:upper()] = ev end
  end
  return t
end
-- Undo one change: that object back to the revision before entries[i] (none before: it was new, so it goes).
function mirror.plan_undo(entries, i)
  local e = entries[i]
  if not (e and e.kind == "obj" and e.oid) then return nil end
  local best -- (the revision it had before: the winner among the older ones, not just the one before it by time)
  for j = 1, #entries do
    local p = entries[j]
    if j ~= i and p.kind == "obj" and p.oid == e.oid and (p.time or "") <= (e.time or "") and won(e, p) and won(p, best) then best = p end -- (made before it)
  end
  if best then return { [e.oid] = (not best.gone) and best or false } end
  if not mirror.began(e) then return {} end -- (its version before was trimmed away: not "it was new", nothing to plan. 0.59.14, review)
  return { [e.oid] = false }
end

-- Which tracks moved between two looks at the list (arrays of oids), as a set: those that don't fit the order the rest kept,
-- longest run first. Tracks added or gone aren't moves, nor is what they shift. `selected` (a set) is what a person drags, so a
-- swap of two neighbours blames the selected one; it counts if the track above it changed. Pure.
function mirror.moved_tracks(old, new, selected)
  local in_old, in_new, moved = {}, {}, {}
  for _, x in ipairs(old) do in_old[x] = true end
  for _, x in ipairs(new) do in_new[x] = true end
  local a, b = {}, {}
  for _, x in ipairs(old) do if in_new[x] and not selected[x] then a[#a + 1] = x end end
  for _, x in ipairs(new) do if in_old[x] and not selected[x] then b[#b + 1] = x end end
  -- (longest common run, table by table: lists are short, and it's only worked out when the order has changed)
  local len = {}
  for i = #a + 1, 1, -1 do
    len[i] = {}
    for j = #b + 1, 1, -1 do
      if i > #a or j > #b then len[i][j] = 0
      elseif a[i] == b[j] then len[i][j] = len[i + 1][j + 1] + 1
      else len[i][j] = math.max(len[i + 1][j], len[i][j + 1]) end
    end
  end
  local kept, i, j = {}, 1, 1
  while i <= #a and j <= #b do
    if a[i] == b[j] then kept[a[i]] = true; i, j = i + 1, j + 1
    elseif len[i + 1][j] >= len[i][j + 1] then i = i + 1
    else j = j + 1 end
  end
  for _, x in ipairs(a) do if not kept[x] then moved[x] = true end end
  local above = {}
  for k, x in ipairs(old) do above[x] = old[k - 1] or "" end
  for k, x in ipairs(new) do
    if selected[x] and in_old[x] and above[x] ~= (new[k - 1] or "") then moved[x] = true end
  end
  return moved
end

-- The order the studio's tracks should be in: the newest list anyone published, then whatever's newer than that list under the
-- track it sat under (`after`: oid -> oid above), or at the end. The same list on every computer. Pure.
-- (the newer tracks in the order they were made (their ids say when: K-USER-<when>-<n>; then by id), each put under the track its change
-- names, as it landed on every computer that was here: of two added under one track the later one sits right under it, the earlier below.
-- By id alone the earlier came first, so the list wasn't the order three computers had all landed, a late joiner went to the list, and the
-- order heal then moved everyone else's tracks to it. The soak's late joiner, "track order differs". rt-converge)
function mirror.wanted_order(list, here, after)
  local has, out, put = {}, {}, {}
  for _, x in ipairs(here) do has[x] = true end
  for _, x in ipairs(list or {}) do if has[x] and not put[x] then put[x] = true; out[#out + 1] = x end end
  local new, made = {}, {}
  for _, x in ipairs(here) do
    if not put[x] then
      new[#new + 1] = x
      local when, n = tostring(x):match("%-(%d+)%-(%d+)$")
      made[x] = { when or "", tonumber(n) or 0 }
    end
  end
  table.sort(new, function(a, b)
    local ma, mb = made[a], made[b]
    if ma[1] ~= mb[1] then return ma[1] < mb[1] end
    if ma[2] ~= mb[2] then return ma[2] < mb[2] end
    return tostring(a) < tostring(b)
  end)
  -- (a track it names that's gone since but is on the list: under what sat above that one, as every computer that was here has it: the track
  -- moved up when the one above it was deleted. At the end, a late joiner had a new track anchored on a deleted one below everything, the
  -- others at the top. The soak's reopen, seed 37, rt-guard)
  local list_above = {}
  for k, y in ipairs(list or {}) do list_above[y] = (list or {})[k - 1] or "" end
  repeat
    local landed, k = false, 1
    while k <= #new do -- (oldest first: each lands right under the track it names, above what landed there before it)
      local x, above = new[k], after[new[k]] or ""
      for _ = 1, #(list or {}) do if above == "" or has[above] or not list_above[above] then break end; above = list_above[above] end
      local at = above == "" and 0 or nil
      if not at then for i, y in ipairs(out) do if y == above then at = i end end end
      if at then table.insert(out, at + 1, x); put[x] = true; table.remove(new, k); landed = true else k = k + 1 end
    end
  until not landed
  for _, x in ipairs(new) do out[#out + 1] = x end -- (what it sat under is gone)
  return out
end

-- An item's state with its place and length to 8 decimals: beyond that it's arithmetic, not an edit. Pure.
function mirror.rounded(state)
  local function round(k, v) return k .. string.format("%.8f", tonumber(v) or 0) end
  return (state:gsub("(%f[%w]POSITION )([%d%.]+)", round, 1):gsub("(%f[%w]LENGTH )([%d%.]+)", round, 1))
end

-- How much of a track's parts the lanes that play cover, in seconds, against all it holds: { pos, len, plays } per item. Pure.
function mirror.lane_cover(items)
  local function span(only)
    local list = {}
    for _, x in ipairs(items) do if not only or x.plays then list[#list + 1] = x end end
    table.sort(list, function(a, z) return a.pos < z.pos end)
    local total, reach = 0, -math.huge
    for _, x in ipairs(list) do
      local from = math.max(x.pos, reach)
      if x.pos + x.len > from then total = total + x.pos + x.len - from; reach = x.pos + x.len end
    end
    return total
  end
  return span(true), span(false)
end
-- Which fixed lane a comp piece came from: REAPER's comp copies a stretch of a source lane's item into the lane that plays, so the piece is
-- the same file, rate and alignment (where the source's start falls on the timeline) as an item on another lane, within its span. `state`:
-- the piece's item state; `plays`: its track's "1,0,0" (C_LANEPLAYS per lane); `others`: the track's other item states. -> the lowest such
-- lane (0-based, as BANDLANE), or nil (not on a lane, a lane that doesn't play, MIDI, or no match). History's time lapse names it
-- (lib/webui/history.js, from the change's `from_lane`). P6 item 2, rt-p1b. Pure.
local function piece_of(st)
  local lane = tonumber(st:match("BANDLANE (%d+)"))
  local file = st:match('\n%s*FILE "([^"\n]+)"')
  if not lane or not file then return nil end
  local rate = tonumber(st:match("\n%s*PLAYRATE (%S+)")) or 1
  local pos, len = tonumber(st:match("\n%s*POSITION (%S+)")), tonumber(st:match("\n%s*LENGTH (%S+)"))
  if not pos or not len or rate <= 0 then return nil end
  return { lane = lane, file = file:match("[^/\\]*$"):lower(), rate = rate, pos = pos, len = len,
    zero = pos - (tonumber(st:match("\n%s*SOFFS (%S+)")) or 0) / rate }
end
function mirror.comp_from(state, plays, others)
  local me = type(state) == "string" and piece_of(state)
  if not me then return nil end
  local flags = {}
  for v in ((plays or "") .. ","):gmatch("([^,]*),") do flags[#flags + 1] = v end
  if flags[me.lane + 1] == "0" then return nil end
  local best
  for _, st in ipairs(others or {}) do
    local x = type(st) == "string" and piece_of(st)
    if x and x.lane ~= me.lane and x.file == me.file and math.abs(x.rate - me.rate) < 1e-6 and math.abs(x.zero - me.zero) < 1e-3
      and me.pos >= x.pos - 1e-3 and me.pos + me.len <= x.pos + x.len + 1e-3 and (not best or x.lane < best) then best = x.lane end
  end
  return best
end

-- Which lane entries[i]'s item sat on, or nil (not on a lane). A delete holds no state, so it's the one its item had last.
-- Kept on the entry: lists call this for every row they draw. Pure.
function mirror.entry_lane(entries, i)
  local e = entries[i]
  if e.lane_seen == nil then
    local from = e
    for j = i - 1, 1, -1 do
      if type(from.state) == "string" then break end
      if not e.gone then break end
      if entries[j].oid == e.oid then from = entries[j] end
    end
    e.lane_seen = type(from.state) == "string" and tonumber(from.state:match("BANDLANE (%d+)")) or false
    e.lane_time = from.time
  end
  return e.lane_seen or nil
end

-- One act that made several changes on one lane: a glue that took three items and made one, a delete of parts picked together.
-- History's indexes of entries[i] and the others on that lane from the same person in the same second. Pure.
-- (A glue's deletes undone without its new item left all three playing: laptop, 0.42.8. But not across lanes: deleting a pass
-- also deletes its copies in the comp, and undoing them together put old copies over newer comp pieces: Mac, 0.42.10. So those
-- are rows of their own, each naming its lane: mirror.lane_words.)
-- shortcut: same second only, so an act that straddles one shows as two rows; a per-act id on events would settle it.
function mirror.same_moment(entries, i)
  local e, out = entries[i], { i }
  if not (e and e.kind == "obj" and e.oid) then return out end
  local had = { [i] = true }
  for _, step in ipairs({ -1, 1 }) do
    local j = i + step
    while entries[j] and entries[j].time == e.time do
      local p = entries[j]
      if p.kind == "obj" and p.oid ~= e.oid and p.user == e.user and p.obj == e.obj and p.name == e.name
        and (not p.restored) == (not e.restored) and mirror.entry_lane(entries, j) == mirror.entry_lane(entries, i) then out[#out + 1] = j; had[j] = true end
      j = j + step
    end
  end
  -- (and the rest of its act, the look that sent it (mirror.watch's `act`): other tracks and kinds too, in any second. Deletions on different
  -- lanes stay apart, as above. rt-edits)
  if e.act then
    for j, p in ipairs(entries) do
      if not had[j] and p.act == e.act and p.kind == "obj" and p.oid ~= e.oid and p.user == e.user and (not p.restored) == (not e.restored)
        and not (e.gone and p.gone and mirror.entry_lane(entries, j) ~= mirror.entry_lane(entries, i)) then out[#out + 1] = j; had[j] = true end
    end
  end
  return out
end
-- " (lane Take 2)" for a row about an item on a lane, else "": the lane's name when the change was made, from its track's newest
-- event by then, as lanes added or removed since shift the numbers. Pure.
function mirror.lane_words(entries, i)
  local e, lane = entries[i], mirror.entry_lane(entries, i)
  if not lane or not e.track then return "" end
  if e.lane_words_seen == nil then
    local start = i
    while entries[start + 1] and entries[start + 1].time == e.time do start = start + 1 end -- (a track's event can follow its items' in the same second)
    local name, plain = "", false
    for j = start, 1, -1 do
      local p = entries[j]
      if p.obj == "track" and p.oid == e.track and type(p.state) == "table" and (p.time or "") <= (e.lane_time or "") then
        plain = (tonumber(p.state.lanes) or 0) < 2
        local n = 0
        for v in ((p.state.lanenames or "") .. ","):gmatch("([^,]*),") do
          if n == lane then name = v end
          n = n + 1
        end
        break
      end
    end
    e.lane_words_seen = plain and "" or string.format(" (lane %s)", name ~= "" and name or tostring(lane + 1))
  end
  return e.lane_words_seen
end
-- -> the plan, and the ids of every entry it undoes (the act's: lib/undo.lua carries them all on the restore events, mirror.last_mine).
function mirror.plan_undo_moment(entries, i)
  local plan, ids, used = nil, {}, {}
  local function add(j)
    if used[j] then return end
    used[j] = true
    ids[#ids + 1] = entries[j].id
    for oid, v in pairs(mirror.plan_undo(entries, j) or {}) do plan = plan or {}; plan[oid] = v end
  end
  for _, j in ipairs(mirror.same_moment(entries, i)) do add(j) end
  local e = entries[i]
  if plan and e and e.kind == "obj" then
    -- (the rest of the act, by the same person in the same second, though another kind of object: a track deleted with its items (undoing the
    -- items alone failed, as their track wasn't there, and every press picked the same change), and the other restores of one undo, so a redo
    -- takes back all of it. Cost: one pass over History per press. Round 1 review, 0.59.45)
    local tracks = {}
    if e.gone and e.obj == "track" then tracks[e.oid] = true end
    for _, v in pairs(plan) do if v and v.obj ~= "track" and v.track then tracks[v.track] = true end end
    -- (an Undo's or Redo's own changes by its step id, whatever second each was written in (lib/undo.lua gives every change of one press the
    -- same `act`): an Undo whose writes crossed a clock second, 3 in one and 18 in the next, was redone as "18 changes", and items and automation
    -- points stayed missing on every computer, alike. Without a step id (an older build's), the same second, as before. REAPER check,
    -- 0.59.49.75, rt-edits)
    for j, x in ipairs(entries) do
      if x.kind == "obj" and x.user == e.user and x.oid ~= e.oid then
        local now = x.time == e.time
        local deleted = now and e.gone and x.gone and not x.restored and ((x.obj == "track" and tracks[x.oid]) or (x.obj == "item" and x.track and tracks[x.track]))
        local same_undo = (e.undoes and x.undoes == e.undoes) or (e.redoes and x.redoes == e.redoes)
        if deleted or (same_undo and (now or (e.act ~= nil and x.act == e.act))) then add(j) end
      end
    end
    -- (and in another second: a track with a few hundred items is deleted a quarter second a pass, so its deletion and its items' straddle
    -- seconds. The same person's deletion of a planned item's track, when it's that track's newest change, and that track's other items they
    -- deleted from then on, each still deleted. Undoing the items alone failed for good. Cost: the same single pass. Round 2 review, 0.59.46)
    if e.gone and not e.restored then
      local newest = {}
      for j, x in ipairs(entries) do if x.kind == "obj" and x.oid and won(x, newest[x.oid] and entries[newest[x.oid]]) then newest[x.oid] = j end end
      local since = {}
      for t in pairs(tracks) do
        local j = newest[t]
        local x = j and entries[j]
        if x and x.gone and not x.restored and x.user == e.user then add(j); since[t] = x.time or "" end
      end
      for j, x in ipairs(entries) do
        if x.kind == "obj" and x.obj == "item" and x.gone and not x.restored and x.user == e.user and x.track and since[x.track]
            and (x.time or "") >= since[x.track] and newest[x.oid] == j then add(j) end
      end
    end
  end
  return plan or {}, ids -- (nothing to plan, a trimmed chain say: an empty plan, never nil for revert to fail on. 0.59.14)
end

-- The top bar's Undo / Redo (your own changes only, for everyone). Pure, over History's entries:
-- last_mine: your newest change not undone yet (undo events carry `undoes`, redo events `redoes`).
-- (a tempo map or marker change of yours is a change too, when it's the whole act: a marker added and nothing else was stepped over, and Undo
-- took back the edit before it. One sent with an act's items goes back with them (lib/undo.lua), so it's passed over here: its act is undone
-- when its items are (undone_act), and an undo's own timeline change counts as redone when its items' undo was (cancelled). One sent in a later
-- pass than some of its act's items (a burst over several passes) is taken from those items, so the act still goes back as one. A Restore's
-- (`restored`) is passed over, as a restored object is. `passed`: ids lib/undo.lua found nothing left to take back of (a bandmate removed
-- the marker since): the next Undo is the change before. rt-edits)
function mirror.last_mine(entries, user, passed)
  local undone, undone_act, cancelled = {}, {}, {}
  for i = #entries, 1, -1 do
    local e = entries[i]
    if e.kind == "obj" and e.user == user then
      -- (every change of the act counts as undone, not only the one named: the next presses restored the same three items again, N² events
      -- for N items. `undoes_all` / `redoes_all`: lib/undo.lua. Round 1 review, 0.59.45)
      if e.undoes and not undone[e.id] then undone[e.undoes] = true; for _, x in ipairs(type(e.undoes_all) == "table" and e.undoes_all or {}) do undone[x] = true end
      elseif e.undoes then cancelled[e.undoes] = true
      elseif e.redoes then undone[e.redoes] = true; for _, x in ipairs(type(e.redoes_all) == "table" and e.redoes_all or {}) do undone[x] = true end -- (a redo undoes an undo: the change it undid counts again)
      elseif not e.restored and not e.auto then -- (auto: a print StudioSync refreshed)
        if not undone[e.id] then return i end
        if e.act then undone_act[e.act] = true end
      end
    elseif e.kind == "timeline" and e.user == user and type(e.tempo) == "table" and not e.restored then
      if e.undoes then if not undone[e.id] and not cancelled[e.undoes] then undone[e.undoes] = true end
      elseif e.redoes then undone[e.redoes] = true
      elseif not undone[e.id] and not (e.act and undone_act[e.act]) and not (passed and passed[e.id]) then
        for j = i - 1, 1, -1 do
          local x = e.act and entries[j]
          if not x then break end
          if x.act == e.act and x.kind == "obj" and x.user == user and not (x.undoes or x.redoes or x.restored or x.auto or undone[x.id]) then return j end
        end
        return i
      end
    end
  end
end
-- Who else changed entries[i]'s object after it (undoing it takes their later change back too). Pure.
function mirror.later_by_others(entries, i)
  local e, who, seen = entries[i], {}, {}
  for j = i + 1, #entries do
    local x = entries[j]
    if x.kind == "obj" and x.oid == e.oid and x.user ~= e.user and not seen[x.user] then seen[x.user] = true; who[#who + 1] = x.user end
  end
  return who
end
-- last_undo: your newest undo that hasn't been redone.
function mirror.last_undo(entries, user)
  local redone, cancelled = {}, {}
  for i = #entries, 1, -1 do
    local e = entries[i]
    if e.kind == "obj" and e.user == user then
      if e.redoes then redone[e.redoes] = true; for _, x in ipairs(type(e.redoes_all) == "table" and e.redoes_all or {}) do redone[x] = true end
      elseif e.undoes then
        if not redone[e.id] then return i end -- (one redone is passed over, not taken for a new change: redo stopped after
        -- redoing an undo that removed something, as that carries no `restored`. Round 2 review, 0.59.46)
        cancelled[e.undoes] = true -- (its timeline change, sent just before it, was redone with it)
      elseif not e.restored and not e.auto then return nil end -- a new change since: nothing to redo (a print StudioSync refreshed isn't one)
    elseif e.kind == "timeline" and e.user == user and type(e.tempo) == "table" and not e.restored then -- (an undo that was only a tempo or marker change: rt-edits)
      if e.redoes then redone[e.redoes] = true
      elseif e.undoes then if not redone[e.id] and not cancelled[e.undoes] then return i end
      else return nil end
    end
  end
end

-- Media paths in chunks: anything in one of the song's rooms' media folders travels as {media:<room>}/<file>, so
-- every machine resolves it to its own shared folder (J:/... here, /Volumes/... on a Mac), and a side room's copy of
-- main's items still points at main's media (it isn't a change). `media_dir`: this room's, <song>/rooms/<room>/media.
local function norm_path(p) return (p:gsub("\\", "/")) end
local function rooms_dir(media_dir) return (norm_path(media_dir):gsub("/$", ""):gsub("/[^/]+/media$", "")) end
function mirror.tokenize_media(chunk, media_dir)
  local base = rooms_dir(media_dir):lower() .. "/"
  return (chunk:gsub('(FILE ")([^"]+)(")', function(a, path, z)
    local p = norm_path(path)
    if p:lower():sub(1, #base) == base then
      local room, rel = p:sub(#base + 1):match("^([^/]+)/media/(.+)$")
      if room then return a .. "{media:" .. room .. "}/" .. rel .. z end
    end
    return a .. path .. z
  end))
end
local function media_path(media_dir, room, rel)
  -- (a bandmate's item can't point outside the band folder: "{media:..}/../../Users/x/secret.wav" took a private file, which
  -- editing the item then copied into the band's media. Review, 0.58.47)
  if (room and (room:find("[/\\]") or room:find("..", 1, true))) or rel:find("%.%.[/\\]") or rel:find("^[/\\]") or rel:find("^%a:") then
    return norm_path(media_dir):gsub("/$", "") .. "/(refused path)"
  end
  return room and (rooms_dir(media_dir) .. "/" .. room .. "/media/" .. rel) or (norm_path(media_dir):gsub("/$", "") .. "/" .. rel)
end
function mirror.resolve_media(chunk, media_dir)
  chunk = chunk:gsub('FILE "{media:([^}]+)}/([^"]+)"', function(room, rel) return 'FILE "' .. media_path(media_dir, room, rel) .. '"' end)
  return (chunk:gsub('FILE "{media}/([^"]+)"', function(rel) return 'FILE "' .. media_path(media_dir, nil, rel) .. '"' end))
end
-- A band version's item with every FILE path that isn't the studio's media ({media...}) emptied. Senders have copied media in or held the item
-- back since 0.59.44, so any other path is a dead one from an old version or one planted to name a file on your disk: applied as written,
-- the end-of-session export, a print or your next edit could copy that file out. James: refuse non-shared paths. Security, Round 2 review,
-- 0.59.46. Cost: one pattern over the state being applied. Pure.
function mirror.only_shared(state)
  return (state:gsub('FILE (["\'`])(.-)%1', function(_, path) if not path:find("^{media") then return 'FILE ""' end end))
end
-- The media files (full paths here) a tokenized chunk needs.
function mirror.media_needed(chunk, media_dir)
  local t = {}
  for room, rel in chunk:gmatch('FILE "{media:([^}]+)}/([^"]+)"') do t[#t + 1] = media_path(media_dir, room, rel) end
  for rel in chunk:gmatch('FILE "{media}/([^"]+)"') do t[#t + 1] = media_path(media_dir, nil, rel) end
  return t
end

-- A fresh object id: kind letter, user, time, counter (unique without coordination: the counter carries 4 random
-- digits, since two machines under one name can start the same second). Upper case throughout: REAPER hands
-- project ExtState keys back upper-cased (EnumProjExtState), and every object is looked up by them.
local seq = 0
function mirror.user_tag(user) return ((user or "x"):gsub("[^%w]", "_")):upper() end
function mirror.new_oid(kind, user, now)
  seq = seq + 1
  return string.format("%s-%s-%s-%d%04d", kind:upper(), mirror.user_tag(user), now or os.date("!%Y%m%d%H%M%S"), seq, math.random(0, 9999))
end
-- Who made an object (its oid's second field).
function mirror.creator(oid) return (oid or ""):match("^%a%-(.-)%-%d+%-%d+$") end
-- Did `user` make the object with this oid? Under an old name too (band.names: they renamed since).
function mirror.is_creator(oid, user)
  local c = mirror.creator(oid)
  if not c then return false end
  if c == mirror.user_tag(user) then return true end
  local now = require("band").names()[c]
  return now ~= nil and mirror.user_tag(now) == mirror.user_tag(user)
end

-- Track settings that travel, as one line (order matters only for hashing). Faders and pan always travel, but with
-- Local mixing on they aren't a change here. Never: record arm, input, monitoring, height, selection.
-- `colour` (tests and re-anchoring): whether the colour counts; by default it does unless SWS colours tracks here.
function mirror.track_hash(t, local_mix, colour) return mirror.hash(mirror.track_line(t, local_mix, colour) .. "|" .. (t.after or "")) end
-- Does SWS auto-colouring colour tracks on this machine? Then its track colours are its own: not a change, and not
-- sent (its rules would recolour whatever the band set, and sending them made machines recolour each other).
local auto_colour = { at = -math.huge }
function mirror.own_colours()
  if not reaper.NamedCommandLookup then return false end
  if reaper.time_precise() - auto_colour.at > 1 then
    local id = reaper.NamedCommandLookup("_SWSAUTOCOLOR_ENABLE") or 0
    auto_colour.at, auto_colour.on = reaper.time_precise(), id > 0 and reaper.GetToggleCommandState(id) == 1
  end
  return auto_colour.on
end
-- More of a track's settings, as { field, REAPER parameter }: the FX button, channels, the parent/master send and
-- its channels, timebase, playback offset, solo defeat, lane settings and pan law; MIX ones follow Local mixing.
mirror.TRACK_MORE = { { "fxen", "I_FXEN" }, { "nchan", "I_NCHAN" }, { "mainsend", "B_MAINSEND" }, { "msoffs", "C_MAINSEND_OFFS" },
  { "msnch", "C_MAINSEND_NCH" }, { "timebase", "C_BEATATTACHMODE" }, { "playoffs", "D_PLAY_OFFSET" }, { "playoffsflag", "I_PLAY_OFFSET_FLAG" },
  { "solodefeat", "B_SOLO_DEFEAT" }, { "lanesettings", "C_LANESETTINGS" }, { "panlaw", "D_PANLAW" }, { "panlawflags", "I_PANLAW_FLAGS" } }
mirror.TRACK_MIX = { { "width", "D_WIDTH" }, { "panmode", "I_PANMODE" }, { "dualpanl", "D_DUALPANL" }, { "dualpanr", "D_DUALPANR" } }

-- A track icon, the same on every computer: one of REAPER's own track icons by its name in Data/track_icons (each computer's REAPER is
-- somewhere else: J:\ on one, D:\ on another, ~/Library on a Mac), any other picture as it is. Pure. (The laptop's REAPER rewrote the
-- desktop's J:\...\bass4.png as its own D:\ path, read that as an edit, put it back, and round again: 104 times on 11-18. 0.59.17)
function mirror.icon_key(icon)
  icon = tostring(icon or "")
  local name = icon:gsub("\\", "/"):match("/[Tt]rack_icons/(.+)$")
  return name and ("track_icons/" .. name) or icon
end
-- ...and on this computer: its own REAPER's copy of one of those, when it has it.
function mirror.icon_here(icon)
  local key = mirror.icon_key(icon)
  local name = key:match("^track_icons/(.+)$")
  if not name then return icon or "" end
  local here = reaper.GetResourcePath():gsub("\\", "/") .. "/Data/track_icons/" .. name
  return reaper.file_exists(here) and here or (icon or "")
end
-- A track's colour for comparing: one without REAPER's 0x1000000 "custom colour set" flag is no colour at all, whatever its other bits hold
-- (REAPER keeps the last colour there: every Cross Test track reads 16576 with the flag off). So "none" is 0 however it's stored, on either
-- side, and two tracks with no colour never differ by it. Pure. rt-edits
function mirror.colour_key(c)
  local n = tonumber(c) or 0
  local i = math.tointeger(n)
  if i and i & 0x1000000 == 0 then return 0 end
  return i or n
end
function mirror.track_line(t, local_mix, colour)
  -- (its parent left out, "" in its place: it follows from the depths above it, which travel, so a folder change arriving in pieces made the
  -- tracks under it read as edited, and put back or sent each other back and forth. 0.59.14, review. An older event's hash names it, which the
  -- band's-hash checks in watch and apply take as the same track: nothing goes out again for it)
  local f = { t.name or "", "", t.depth or 0, t.mute or 0, "", t.phase or 0, mirror.icon_key(t.icon), -- ("": solo is each person's own)
    t.freemode or 0, t.lanes or 0, t.plays or "", t.lanenames or "", 0, local_mix and "" or (t.vol or ""), local_mix and "" or (t.pan or "") }
  for _, kp in ipairs(mirror.TRACK_MORE) do f[#f + 1] = t[kp[1]] or "" end
  for _, kp in ipairs(mirror.TRACK_MIX) do f[#f + 1] = local_mix and "" or (t[kp[1]] or "") end
  if colour == nil then colour = not mirror.own_colours() end
  if colour then f[#f + 1] = mirror.colour_key(t.color) end -- (left off, not blank, when it doesn't count: the line from before 0.36)
  -- Automation mode, only when it's Read (power-user review, 0.58.62): left off at the default, so no track's hash changed and nothing was sent
  -- again. Read or Trim/Read is how the song plays; Touch, Latch and Write are what one person is doing, so they travel as Read.
  if (tonumber(t.automode) or 0) >= 1 then f[#f + 1] = "am1" end
  for i, v in ipairs(f) do
    local s = tostring(v)
    f[i] = s:find("|", 1, true) and s:gsub("|", "/") or s -- (the same text; the gsub only when there's a "|": 150 tracks' 30 fields a look)
  end
  return table.concat(f, "|")
end

-- The same settings? As track_line, but 0 and 0.0 are one number: a state read here has floats, and one from a bandmate's event can have
-- whole numbers. Read as different, a track that had only moved in the list was put back and suggested to its owner at every restart.
-- (The hash stays on track_line: changing what it reads would make every track look changed.) Pure.
function mirror.same_line(x, y, local_mix)
  local function plain(t) return (mirror.track_line(t, local_mix):gsub("(%d)%.0%f[|\0]", "%1")) end
  return plain(x) == plain(y)
end

-- Do two track states differ only in their lanes (how many, their names, which play: the settings that go together) and maybe their place?
-- Pure.
function mirror.same_but_lanes(x, y, local_mix)
  if mirror.same_line(x, y, local_mix) then return false end
  local a, b = {}, {}
  for k, v in pairs(x) do a[k] = v end
  for k, v in pairs(y) do b[k] = v end
  for _, k in ipairs({ "freemode", "lanes", "plays", "lanenames" }) do a[k], b[k] = 0, 0 end
  return mirror.same_line(a, b, local_mix)
end
-- With Local mixing on, a track's faders and pan here are this person's own: what goes out carries the band's (its last event's) in their
-- place. They always went out, so a rename sent your own mix to everyone not on Local mixing, and Follow's copy of a bandmate's faders with
-- it (0.59.14, review). A track the band hasn't had yet: its own, there's nothing else. Pure.
function mirror.band_faders(state, band_state)
  if type(state) ~= "table" or type(band_state) ~= "table" then return state end
  local out = {}
  for k, v in pairs(state) do out[k] = v end
  out.vol, out.pan = band_state.vol, band_state.pan
  for _, kp in ipairs(mirror.TRACK_MIX) do out[kp[1]] = band_state[kp[1]] end
  return out
end

-- An item's take plug-ins: their blocks' lines alone (what fxfiles looks through for files they load; the item's own FILE lines are its
-- media, shared by share_media). Pure.
function mirror.take_fx(state)
  local out, depth = {}, 0
  for line in (state or ""):gmatch("[^\n]+") do
    local t = line:match("^%s*(.-)%s*$")
    if depth == 0 then
      if t:match("^<TAKEFX") then depth = 1; out[#out + 1] = line end
    else
      out[#out + 1] = line
      if t:sub(1, 1) == "<" then depth = depth + 1 elseif t == ">" then depth = depth - 1 end
    end
  end
  return table.concat(out, "\n")
end

-- What runs through each track: its folder's tracks, what it receives, the tracks a VCA fader on it leads, and what runs through
-- those. Tracks with nothing running through them aren't listed. Pure. tracks: { { oid, parent, recv, lead, follow } } (recv: its R- part;
-- lead, follow: the VCA groups it leads and follows, as bits). A VCA moves no follower's own fader, only how it sounds: a bus, as far
-- as anyone's claim goes.
function mirror.feeders(tracks)
  local direct = {}
  local function add(to, from) direct[to] = direct[to] or {}; direct[to][#direct[to] + 1] = from end
  for _, t in ipairs(tracks) do
    if (t.parent or "") ~= "" then add(t.parent, t.oid) end
    for src in (t.recv or ""):gmatch("AUXRECV (%S+)") do add(t.oid, src) end
    if (t.lead or 0) ~= 0 then
      for _, x in ipairs(tracks) do if x ~= t and (t.lead & (x.follow or 0)) ~= 0 then add(t.oid, x.oid) end end
    end
  end
  local all = {}
  for oid in pairs(direct) do
    local seen, list = { [oid] = true }, {}
    local function walk(x)
      for _, f in ipairs(direct[x] or {}) do
        if not seen[f] then seen[f] = true; list[#list + 1] = f; walk(f) end
      end
    end
    walk(oid)
    all[oid] = list
  end
  return all
end

-- "Mac's Keys, Guitar and Bee's Bass" from { { owner, name } }, in a fixed order. Pure.
function mirror.whose(list)
  local by, owners = {}, {}
  for _, x in ipairs(list) do
    if not by[x[1]] then by[x[1]] = {}; owners[#owners + 1] = x[1] end
    by[x[1]][#by[x[1]] + 1] = x[2]
  end
  table.sort(owners)
  local out = {}
  for _, o in ipairs(owners) do table.sort(by[o]); out[#out + 1] = o .. "'s " .. table.concat(by[o], ", ") end
  return table.concat(out, " and ")
end

-- Automation without what a tempo change moves: each point's time (and an automation item's place and length), its value and shape kept.
-- (Just after a tempo change landed, any automation that differed was taken for REAPER moving it with the tempo, and kept here as the band's:
-- a point drawn then was neither sent nor put back. Now only one that differs in its times alone is. 0.59.39) Pure.
function mirror.env_sans_tempo(state)
  local out = {}
  for line in (state or ""):gmatch("[^\n]+") do
    local kw, rest = line:match("^%s*(%S+)%s*(.*)$")
    if kw == "PT" then out[#out + 1] = "PT " .. rest:gsub("^%S+%s*", "")
    elseif kw == "POOLEDENVINST" then out[#out + 1] = "POOLEDENVINST " .. rest:gsub("^%S+%s+%S+%s+%S+%s*", "")
    -- (and an automation item's place and length, and its points' times, as mirror.ai_lines writes them: a tempo change moves those too.
    -- rt-fix9)
    elseif kw == "BANDAI" then out[#out + 1] = "BANDAI " .. rest:gsub("^(%S+)%s+%S+%s+%S+", "%1")
    elseif kw == "BANDAIPT" then out[#out + 1] = "BANDAIPT " .. rest:gsub("^(%S+%s+%S+)%s+%S+", "%1")
    else out[#out + 1] = line end
  end
  return table.concat(out, "\n")
end
-- Two automation states alike but for what a tempo change moves (env_sans_tempo), line by line and number by number: a point's line written
-- with other digits, or without the trailing fields another REAPER writes (missing ones read as 0), is the same point. A bandmate's REAPER
-- writes its automation its own way, and the text compare took this computer's own tempo change, made right after a bandmate's, for an edit
-- of the one track with automation, and claimed it (rt-r4's bug B, three of three; never after a tempo change of this computer's own). Pure.
local function same_words(x, y)
  if x == y then return true end
  local tx, ty = {}, {}
  for t in x:gmatch("%S+") do tx[#tx + 1] = t end
  for t in y:gmatch("%S+") do ty[#ty + 1] = t end
  if tx[1] ~= ty[1] then return false end
  for i = 2, math.max(#tx, #ty) do
    local p, q = tx[i] or "0", ty[i] or "0"
    if p ~= q then
      local m, n = tonumber(p), tonumber(q)
      if not (m and n and math.abs(m - n) <= 1e-9 * math.max(1, math.abs(m))) then return false end
    end
  end
  return true
end
function mirror.env_same_but_times(a, b)
  local la, lb = {}, {}
  for l in mirror.env_sans_tempo(a):gmatch("[^\n]+") do la[#la + 1] = l end
  for l in mirror.env_sans_tempo(b):gmatch("[^\n]+") do lb[#lb + 1] = l end
  if #la ~= #lb then return false end
  for i = 1, #la do if not same_words(la[i], lb[i]) then return false end end
  return true
end
-- An item without what a tempo change moves: where it sits, how long, and how fast. Pure.
local TEMPO_MOVES = { POSITION = true, LENGTH = true, PLAYRATE = true, SOFFS = true, SNAPOFFS = true, FADEIN = true, FADEOUT = true }
function mirror.sans_tempo(state)
  local out = {}
  for line in (state or ""):gmatch("[^\n]+") do
    if not TEMPO_MOVES[line:match("^%s*(%S+)") or ""] then out[#out + 1] = line end
  end
  return table.concat(out, "\n")
end
-- An item's version made under the tempo map `from`, put where REAPER would have moved it on the map `to` (band.capture_tempo's lists): on the
-- same beat, by its timebase (its BEAT line, else `mode`, the project's: 1 beats (position, length, rate), 2 beats (position only), 0 time).
-- A take restored to a point after a tempo change it was last changed before sat at its old seconds, off its beat (rt-history2's limits).
-- Mode 1 stretches the whole item as REAPER does for that timebase: its length to the same beats, and with it the snap offset and fades
-- (seconds inside the item: they stay on the same part of the audio), and an audio take's rate by the inverse (the same stretch of source
-- fills the new length; SOFFS, a source position, stays). A MIDI take's rate stays: its notes are in beats already. Mode 2 moves the
-- position only. (rt-p1b, P6's round 2 proposal)
-- shortcut: a map with a gradual (linear) tempo change isn't converted at all, the item's timebase -1 goes by the project's (not its track's),
-- and take envelopes stay as stored. Upgrade if a REAPER check shows those off. Pure.
local function map_qn(map, t)
  local q, pt, pb = 0, 0, map[1].bpm
  for _, m in ipairs(map) do
    if m.time > t then break end
    q, pt, pb = q + (m.time - pt) * pb / 60, m.time, m.bpm
  end
  return q + (t - pt) * pb / 60
end
local function map_time(map, q)
  local pq, pt, pb = 0, 0, map[1].bpm
  for _, m in ipairs(map) do
    local mq = pq + (m.time - pt) * pb / 60
    if mq > q then break end
    pq, pt, pb = mq, m.time, m.bpm
  end
  return pt + (q - pq) * 60 / pb
end
local function maps_ok(from, to)
  if type(from) ~= "table" or type(to) ~= "table" or #from == 0 or #to == 0 then return false end
  for _, map in ipairs({ from, to }) do
    for _, m in ipairs(map) do if m.linear or not (tonumber(m.time) and tonumber(m.bpm) and m.bpm > 0) then return false end end
  end
  return true
end
-- A time under one tempo map, on the same beat under another: a marker's place (sync.undo_timeline). As mirror.retime: only where the
-- timebase is beats and neither map has a gradual change; else the time as it is. Pure. rt-converge
function mirror.time_on(t, from, to, mode)
  if (mode ~= 1 and mode ~= 2) or type(t) ~= "number" or not maps_ok(from, to) then return t end
  return map_time(to, map_qn(from, t))
end
local function g14(x) return string.format("%.14g", x) end
local function join_like(L, was) if L[#L] == "" then L[#L] = nil end; return table.concat(L, "\n") .. (was:sub(-1) == "\n" and "\n" or "") end
function mirror.retime(state, from, to, mode)
  if type(state) ~= "string" or not maps_ok(from, to) then return state end
  local beat = tonumber(state:match("\n%s*BEAT (%-?%d+)"))
  if beat and beat >= 0 then mode = beat end
  local p, l = tonumber(state:match("\n%s*POSITION ([%d%.%-e]+)")), tonumber(state:match("\n%s*LENGTH ([%d%.%-e]+)"))
  if (mode ~= 1 and mode ~= 2) or not p then return state end
  local np = map_time(to, map_qn(from, p))
  local out = state
  if math.abs(np - p) > 1e-9 then out = out:gsub("(\n%s*POSITION )[^\n]+", "%1" .. g14(np), 1) end
  if mode == 1 and l and l > 0 then
    local nl = map_time(to, map_qn(from, p + l)) - np
    if math.abs(nl - l) > 1e-9 then
      local s = nl / l
      out = out:gsub("(\n%s*LENGTH )[^\n]+", "%1" .. g14(nl), 1)
      -- (the item's own lines, depth 1, take by take: SNAPOFFS, FADEIN/FADEOUT's length and auto length, each audio take's PLAYRATE)
      local L, depth, take = {}, 0, { midi = false }
      local takes = { take }
      for line in (out .. "\n"):gmatch("([^\n]*)\n") do
        L[#L + 1] = line
        local kw = line:match("^%s*(%S+)") or ""
        if depth == 1 then
          if kw == "TAKE" then take = { midi = false }; takes[#takes + 1] = take
          elseif kw == "SNAPOFFS" then L[#L] = line:gsub("^(%s*SNAPOFFS )(%S+)", function(a, v) return a .. g14((tonumber(v) or 0) * s) end)
          elseif kw == "FADEIN" or kw == "FADEOUT" then
            L[#L] = line:gsub("^(%s*%S+ %S+ )(%S+) (%S+)", function(a, len, auto) return a .. g14((tonumber(len) or 0) * s) .. " " .. g14((tonumber(auto) or 0) * s) end)
          elseif kw == "PLAYRATE" then take.rate = #L end
        end
        if line:find("^%s*<SOURCE MIDI") then take.midi = true end
        if kw:sub(1, 1) == "<" then depth = depth + 1 elseif kw == ">" then depth = depth - 1 end
      end
      for _, t in ipairs(takes) do
        if t.rate and not t.midi then L[t.rate] = L[t.rate]:gsub("^(%s*PLAYRATE )(%S+)", function(a, v) return a .. g14((tonumber(v) or 1) / s) end) end
      end
      out = join_like(L, out)
    end
  end
  return out
end
-- An automation part's version made under the map `from`, onto the same beats on `to`, as REAPER moves points when the map changes (`mode`:
-- the project's timebase; 0 = time, nothing moves): each point (PT), each automation item's place (POOLEDENVINST; BANDAI, mirror.ai_lines)
-- and, in mode 1, its length, and its points (BANDAIPT, project time) onto their beats. An item's rate stays: its pool is in beats
-- (D_POOL_QNLEN). (P6's round 2 proposal, rt-p1b. shortcut: as mirror.retime, a gradual tempo change isn't converted.) Pure.
function mirror.retime_env(state, from, to, mode)
  if type(state) ~= "string" or (mode ~= 1 and mode ~= 2) or not maps_ok(from, to) then return state end
  local function at(t) return map_time(to, map_qn(from, t)) end
  local function put(was, now) return math.abs(now - tonumber(was)) > 1e-9 and g14(now) or was end -- (unmoved: its text kept)
  local L = {}
  for line in (state .. "\n"):gmatch("([^\n]*)\n") do
    local a, t, z = line:match("^(%s*PT )(%S+)(.*)$")
    local h, pos, len, rest = line:match("^(%s*POOLEDENVINST %S+ )(%S+) (%S+)(.*)$")
    if not h then h, pos, len, rest = line:match("^(BANDAI %S+ )(%S+) (%S+)(.*)$") end
    local ph, pt, pz = line:match("^(BANDAIPT %S+ %S+ )(%S+)(.*)$")
    if a and tonumber(t) then line = a .. put(t, at(tonumber(t))) .. z
    elseif h and tonumber(pos) and tonumber(len) then
      local np = at(tonumber(pos))
      line = h .. put(pos, np) .. " " .. (mode == 1 and put(len, at(tonumber(pos) + tonumber(len)) - np) or len) .. rest
    elseif ph and tonumber(pt) then line = ph .. put(pt, at(tonumber(pt))) .. pz end
    L[#L + 1] = line
  end
  return join_like(L, state)
end
-- The tempo map a version's seconds are on travels with it (rt-converge): `tm`, band.capture_tempo's list as it was where the version was made,
-- and `tb`, that project's timebase. An item's or automation's text is in seconds, and every computer's REAPER moves it onto its beat when a
-- tempo map lands; a version that crossed paths with a map (made just before it arrived, put back after it, merged with one made across it,
-- read by a late joiner in another order) sat at its old seconds on some computers and not others, for good (the soak's bugs 5 and 7, and
-- most of its tempo failures). So whoever puts a version in place puts it on the same beat under the map in place (mirror.on_map, from
-- mirror.apply), versions made under different maps are merged on one map (event_file), and "is this only the map's move?" is asked of the
-- version on today's map (mirror.map_moved), not of a 15 s window. A version from before this carries no map and is taken as it is.
-- shortcut: a map of more than MAP_MAX points isn't carried (a 4 KB tail on every change): those versions land as before. Upgrade to naming
-- the timeline change (its id) and reading its map if long tempo maps show the old drift.
mirror.MAP_MAX = 64
-- (what arrives is a bandmate's: only a list of points with a place and a tempo is a map. Pure)
local function map_ok(m)
  if type(m) ~= "table" or #m == 0 or #m > mirror.MAP_MAX then return false end
  for _, p in ipairs(m) do
    if type(p) ~= "table" or type(p.time) ~= "number" or type(p.bpm) ~= "number" or not (p.bpm > 0 and p.bpm < 1e6 and p.time >= 0 and p.time < 1e9) then return false end
  end
  return true
end
local function same_map(a, b)
  if #a ~= #b then return false end
  for i, x in ipairs(a) do
    local y = b[i]
    if math.abs(x.time - y.time) > 1e-9 or math.abs(x.bpm - y.bpm) > 1e-9 or (x.linear and true or false) ~= (y.linear and true or false) then return false end
  end
  return true
end
mirror.map_ok, mirror.same_map = map_ok, same_map
-- A version about to go out, stamped with the map in place (items and automation: what a tempo map moves). -> ev.
function mirror.map_tag(proj, ev)
  if (ev.obj == "item" or ev.obj == "env") and type(ev.state) == "string" then
    local map = require("band").capture_tempo(proj)
    if map_ok(map) then ev.tm, ev.tb = map, reaper.GetSetProjectInfo(proj, "PROJECT_TIMEBASE", 0, false) end
  end
  return ev
end
-- A version's state on the map `to`, by the timebase `mode`: on the same beats as under the map it was made on. -> the state, and whether
-- that moved it. Pure.
function mirror.state_on(ev, to, mode)
  if not (type(ev) == "table" and (ev.obj == "item" or ev.obj == "env") and type(ev.state) == "string" and map_ok(ev.tm) and map_ok(to)) or same_map(ev.tm, to) then
    return type(ev) == "table" and ev.state or nil, false
  end
  local st = (ev.obj == "item" and mirror.retime or mirror.retime_env)(ev.state, ev.tm, to, mode)
  return st, st ~= ev.state
end
-- ... on the map in place in `proj`.
function mirror.on_map(proj, ev)
  if not (type(ev) == "table" and type(ev.tm) == "table") then return type(ev) == "table" and ev.state or nil, false end
  return mirror.state_on(ev, require("band").capture_tempo(proj), reaper.GetSetProjectInfo(proj, "PROJECT_TIMEBASE", 0, false))
end
-- Did a tempo map, not a hand, make `now` out of `was`: two readings of one item or automation on this computer, under the maps `from` and `to`
-- (`mode`: the project's timebase)? As mirror.only_map_moved, but against this computer's own reading at its last look instead of the band's
-- text, which another REAPER writes its own way: W.send's other way to tell a tempo change of yours from an edit. Pure. rt-fix9
function mirror.moved_by_map(kind, was, now, from, to, mode)
  if type(was) ~= "string" or type(now) ~= "string" or not (map_ok(from) and map_ok(to)) or same_map(from, to) then return false end
  if kind == "env" then return mirror.env_same_but_times(was, now) end
  if kind ~= "item" or mirror.sans_tempo(was) ~= mirror.sans_tempo(now) then return false end
  local want = mirror.retime(was, from, to, mode)
  for _, k in ipairs({ "POSITION", "LENGTH" }) do
    local a, b = tonumber(want:match("\n%s*" .. k .. " ([%d%.%-e]+)")), tonumber(now:match("\n%s*" .. k .. " ([%d%.%-e]+)"))
    if a and b and math.abs(a - b) > 1e-6 then return false end
  end
  return true
end
-- `state` with each line that says the same as a line of `ref` to 7 decimals written as `ref` writes it: a place worked out two ways (REAPER's
-- own move for a map, mirror.retime's) differs in its last digits, and a merge reading that as "both changed it" called a clash. Pure.
local function near_key(line) return (line:gsub("%-?%d+%.%d+e?%-?%d*", function(x) local n = tonumber(x); return n and string.format("%.7f", n) or x end)) end
function mirror.snap_to(state, ref)
  local exact, near = {}, {}
  for line in ref:gmatch("[^\n]+") do exact[line] = true; if line:find("%d%.%d") then near[near_key(line)] = line end end
  return (state:gsub("[^\n]+", function(line)
    if exact[line] or not line:find("%d%.%d") then return nil end
    return near[near_key(line)]
  end))
end

-- ---- REAPER side ------------------------------------------------------------------------------------------
-- Everything below talks to REAPER. Kept per project: SEC "<oid>" = "rev|hash|event id" (the newest revision
-- this machine holds, and the event it came in, which is what a put-back re-applies).
mirror.SEC = "BandSync.mirror"
local function ext(proj, key) return select(2, reaper.GetProjExtState(proj, mirror.SEC, key)) end
mirror.rec_writes = mirror.rec_writes or 0 -- (records written by this script: mirror.root holds its code until one is. rt-perfcut2)
local function setext(proj, key, v) mirror.rec_writes = mirror.rec_writes + 1; reaper.SetProjExtState(proj, mirror.SEC, key, v) end
-- rev|hash|event id|order ("order" = time .. user of that revision: equal revs are settled by it, the same way
-- on every machine)
function mirror.known(proj, oid)
  local rev, h, ev, order = ext(proj, oid):match("^(%d+)|([^|]*)|([^|]*)|?(.*)$")
  return tonumber(rev), h, ev, order
end
-- This machine's ids also live in a file beside the project (<project>.bandsync-ids.json): REAPER's GUID -> oid, and
-- what was last known of each oid. The project only keeps them once it's saved, so one reopened without its last
-- save (closed unsaved, a crash) saw its tracks and items as new and sent them again as copies (2026-10-30: Mirror
-- Test came back with every track twice). Untitled projects have no file.
local idc = {}
local function ids(proj)
  local fn
  for i = 0, math.huge do
    local p, f = reaper.EnumProjects(i)
    if not p or p == proj then fn = p and f or ""; break end
  end
  if fn == "" then return nil end
  local c = idc[proj]
  if not c or c.fn ~= fn then
    local path = (fn:gsub("\\", "/"):gsub("%.[Rr][Pp][Pp]$", "")) .. ".bandsync-ids.json"
    local d = require("band").read_json(path) or {}
    c = { fn = fn, path = path, guid = d.guid or {}, rec = d.rec or {} }
    idc[proj] = c
  end
  return c
end
function mirror.save_ids(proj)
  local c = idc[proj]
  if c and c.dirty then c.dirty = false; require("band").write_json(c.path, { guid = c.guid, rec = c.rec }) end
end

local function remember(proj, oid, rev, h, evid, order)
  local v = string.format("%d|%s|%s|%s", rev or 0, h or "", evid or "", order or "")
  setext(proj, oid, v)
  local c = ids(proj)
  if c and c.rec[oid] ~= v then c.rec[oid], c.dirty = v, true end
  local pk = tostring(proj) -- (the next quick look reads this object's track afresh and puts it through W.one: rt-look)
  local r = mirror.remembered[pk]
  if not r then r = {}; mirror.remembered[pk] = r end
  r[oid] = true
end
mirror.remember = remember

local function trk_oid(tr) return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", "", false)):upper() end
local function itm_oid(it) return select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", false)):upper() end
mirror.track_oid, mirror.item_oid = trk_oid, itm_oid
-- StudioSync's own helper tracks (the SonoBus return, stems) never mirror
local function local_track(tr) -- (also live placeholders and live MIDI views: each machine draws its own)
  return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", "", false)) ~= ""
    or select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_live_track", "", false)) ~= ""
end
mirror.local_track = local_track

-- A track's travelling settings (see track_line).
function mirror.track_state(proj, tr, local_mix)
  local parent = reaper.GetParentTrack(tr)
  local t = { name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)), parent = parent and trk_oid(parent) or "",
    depth = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH"), mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"),
    solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO"), phase = reaper.GetMediaTrackInfo_Value(tr, "B_PHASE"),
    color = require("band").color_out(require("band").track_colour(tr)), icon = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_ICON", "", false)),
    autocolour = mirror.own_colours() or nil, automode = reaper.GetMediaTrackInfo_Value(tr, "I_AUTOMODE") >= 1 and 1 or 0, freemode = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE"), lanes = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") } -- (not lanes collapsed: a view, each person's own. It was put back as a bandmate's edit: Mac, 0.42.5)
  local try = mirror.tried_track(proj, tr) -- (a colour look tried here: the colour from before it, until it's kept. rt-nohold)
  if try then t.color = require("band").color_out(require("band").untried(require("band").track_colour(tr), try)) end
  local held_mute = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_quiet", "", false)) -- (quiet only here, for now: lib/producer.lua)
  if held_mute ~= "" then t.mute = tonumber(held_mute) or 0 end
  local plays, names = {}, {}
  for l = 0, t.lanes - 1 do
    plays[#plays + 1] = math.floor(reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. l))
    names[#names + 1] = (select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. l, "", false)):gsub(",", ";"))
  end
  t.plays, t.lanenames = table.concat(plays, ","), table.concat(names, ",")
  t.vol = string.format("%.6f", reaper.GetMediaTrackInfo_Value(tr, "D_VOL"))
  t.pan = string.format("%.4f", reaper.GetMediaTrackInfo_Value(tr, "D_PAN"))
  for _, list in ipairs({ mirror.TRACK_MORE, mirror.TRACK_MIX }) do
    for _, kp in ipairs(list) do t[kp[1]] = string.format("%.6g", reaper.GetMediaTrackInfo_Value(tr, kp[2])) end
  end
  local held = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_fxen", "", false)) -- (lib/prints.lua hold_fx)
  if held ~= "" then t.fxen = string.format("%.6g", tonumber(held) or 1) end
  -- (the track above, so new tracks land in the same order)
  t.after = ""
  for i = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")) - 2, 0, -1 do -- (the nearest mirrored one above)
    local above = reaper.GetTrack(proj, i)
    if not local_track(above) then t.after = trk_oid(above); break end
  end
  return t
end

function mirror.set_track_state(proj, tr, t, local_mix)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", t.name or "", true)
  -- never fewer lanes than its items sit on: REAPER then says those items are on lane 255, and it went out as an edit, and every
  -- machine grew to 256 lanes (a Back to before the lanes, with items not yet gone: laptop and PC, 0.42.7)
  local in_use = 0
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2 then
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local lane = reaper.GetMediaItemInfo_Value(reaper.GetTrackMediaItem(tr, i), "I_FIXEDLANE")
      if lane < mirror.BAD_LANE then in_use = math.max(in_use, lane + 1) end
    end
  end
  for _, kp in ipairs({ { "freemode", "I_FREEMODE" }, { "lanes", "I_NUMFIXEDLANES" }, { "mute", "B_MUTE" },
      { "phase", "B_PHASE" }, { "depth", "I_FOLDERDEPTH" } }) do
    local v = t[kp[1]] and (tonumber(t[kp[1]]) or 0)
    if v and kp[1] == "lanes" then v = math.max(v, in_use) end
    if v and kp[1] == "freemode" and in_use > 1 then v = 2 end
    if v then reaper.SetMediaTrackInfo_Value(tr, kp[2], v) end
  end
  -- (not from "no colour" to "no colour": nothing to write, whatever bits each holds. And the colour hold below is told, so it holds this one)
  -- (a colour look tried on it here, and the band's colour is still the one from before the try: the tried one stays on. A bandmate's change
  -- landing on it, or an item landing (lanes_back), put the band's back over the try. Backlog 1.6, rt-p1)
  local want = t.color and require("band").color_in(t.color)
  local tried = want and mirror.tried_track(proj, tr)
  if tried and mirror.colour_key(want) == mirror.colour_key(tonumber(tried[1]) or 0) then want = tonumber(tried[2]) or want end
  if want and not t.autocolour and mirror.colour_key(want) ~= mirror.colour_key(require("band").track_colour(tr)) then
    require("band").set_track_colour(tr, want)
    mirror.held_colour(tr)
  end
  -- (from a StudioSync that sends it; never out of a Touch, Latch or Write someone is using here)
  if t.automode ~= nil and reaper.GetMediaTrackInfo_Value(tr, "I_AUTOMODE") <= 1 then reaper.SetMediaTrackInfo_Value(tr, "I_AUTOMODE", (tonumber(t.automode) or 0) >= 1 and 1 or 0) end
  reaper.GetSetMediaTrackInfo_String(tr, "P_ICON", mirror.icon_here(t.icon), true) -- (this computer's own copy of a REAPER icon: 0.59.17)
  local l = 0
  for v in ((t.plays or "") .. ","):gmatch("([^,]*),") do
    if v ~= "" then reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. l, tonumber(v) or 0) end
    l = l + 1
  end
  l = 0
  for v in ((t.lanenames or "") .. ","):gmatch("([^,]*),") do
    if l < (tonumber(t.lanes) or 0) then reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. l, v, true) end
    l = l + 1
  end
  local held = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_fxen", "", false)) ~= ""
  for _, kp in ipairs(mirror.TRACK_MORE) do
    if held and kp[1] == "fxen" and tonumber(t.fxen) then -- (held off here while a wet take plays: the band's goes in its place)
      reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_fxen", tostring(math.floor(tonumber(t.fxen))), true)
    elseif tonumber(t[kp[1]]) then reaper.SetMediaTrackInfo_Value(tr, kp[2], tonumber(t[kp[1]])) end -- (a sender without it: left)
  end
  if not local_mix then
    if t.vol and t.vol ~= "" then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", tonumber(t.vol)) end
    if t.pan and t.pan ~= "" then reaper.SetMediaTrackInfo_Value(tr, "D_PAN", tonumber(t.pan)) end
    for _, kp in ipairs(mirror.TRACK_MIX) do
      if tonumber(t[kp[1]]) then reaper.SetMediaTrackInfo_Value(tr, kp[2], tonumber(t[kp[1]])) end
    end
  end
end

-- A lane number that makes sense: REAPER reads 255 for an item on a lane the track has lost. Pure.
mirror.BAD_LANE = 200
function mirror.clean_lane(lane, lanes)
  lane, lanes = math.floor(tonumber(lane) or 0), math.floor(tonumber(lanes) or 1)
  if lane >= mirror.BAD_LANE then return 0 end
  return lanes > 0 and math.min(lane, lanes - 1) or lane
end

-- Which take an item plays, when it has a choice: its takes that aren't prints (an empty take counts, a comp can pick silence), and
-- which of them is playing, counted from 0. Which take plays was each machine's own before 0.58.85 ("TAKE SEL" is still left out
-- of the chunk), so a comp made by picking takes (split, a take each) never reached anyone, and an item arriving new played its
-- first take: Nostalgia's take comps turned into lanes with the wrong takes and silences (James, 0.58.85). The print-or-dry choice
-- stays each machine's: a print playing counts as the first real take, the one a print is made from.
local PRINT_KEY = "P_EXT:band_m_print" -- (prints.KEY: on a print take)
function mirror.real_takes(it)
  local out = {}
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if not (tk and select(2, reaper.GetSetMediaItemTakeInfo_String(tk, PRINT_KEY, "", false)) ~= "") then out[#out + 1] = k end
  end
  return out
end
-- How many real takes have something in them: an empty take (REAPER's TAKE NULL) isn't one to choose. For deciding whether a print plays or
-- takes go into lanes; the pick index (picked_take, pick_take) keeps counting them, as every computer's does. Review, 0.58.97: prints counted
-- one way and this the other, so a take, an empty take and a print never played the print.
function mirror.filled_takes(it)
  local n = 0
  for _, k in ipairs(mirror.real_takes(it)) do if reaper.GetTake(it, k) then n = n + 1 end end
  return n
end
-- -> the playing take's place among the real ones (0 = first), or nil with fewer than two real takes.
function mirror.picked_take(it)
  if reaper.CountTakes(it) < 2 then return nil end -- (most items: no choice, and no take's P_EXT read for it. 0.59.19)
  local list = mirror.real_takes(it)
  if #list < 2 then return nil end
  local cur = reaper.GetMediaItemInfo_Value(it, "I_CURTAKE")
  for i, k in ipairs(list) do if k == cur then return i - 1 end end
  -- (a print playing: the take it was made from (prints.FROM), else the first. Prints follow the picked take now, so playing one here mustn't
  -- send everyone back to the first take. James, rt)
  local tk = reaper.GetTake(it, cur)
  local from = tk and math.tointeger(tonumber(select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_EXT:band_m_printof", "", false))))
  if from and from >= 0 and from < #list then return from end
  return 0
end
-- Play the `pick`th real take (from 0). -> true when there is one.
function mirror.pick_take(it, pick)
  local k = mirror.real_takes(it)[(tonumber(pick) or -1) + 1]
  if not k then return false end
  if reaper.GetMediaItemInfo_Value(it, "I_CURTAKE") ~= k then reaper.SetMediaItemInfo_Value(it, "I_CURTAKE", k) end
  return true
end

-- An item's travelling state: its normalized chunk, plus its lane (REAPER keeps an item's fixed lane out of the
-- item's chunk, so it gets a line of its own), and which take it plays when it has a choice (BANDTAKE: mirror.picked_take).
local function item_base(chunk, media_dir) -- (the chunk's part of an item's state: mirror.item_states reuses it)
  return mirror.memo("i\0" .. media_dir, chunk, function() return mirror.tokenize_media(mirror.normalize_item(chunk), media_dir) end)
end
local function item_tail(it) -- (and what REAPER keeps out of the chunk, read through the API every time: "" for most items)
  local tr, st = reaper.GetMediaItem_Track(it), ""
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2 then
    st = "BANDLANE " .. mirror.clean_lane(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"), reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES")) .. "\n"
  end
  local pick = mirror.picked_take(it)
  if pick then st = st .. "BANDTAKE " .. pick .. "\n" end
  return st
end
-- A colour look tried here (lib/colours.lua, band.colour_try): an item still showing the tried colour reads with its COLOR line from before
-- (REAPER writes it after MUTE; "" for none), so the try sends nothing until it's kept, and holds back nothing else. Pure. rt-nohold
function mirror.with_colour_line(st, line)
  local s, n = st:gsub("\nCOLOR [^\n]*", line ~= "" and ("\n" .. line:gsub("%%", "%%%%")) or "", 1)
  if n == 0 and line ~= "" then s = s:gsub("(\nMUTE [^\n]*)", "%1\n" .. line:gsub("%%", "%%%%"), 1) end
  return s
end
local function untried_item(st, c)
  if not c then return st end
  local now = st:match("\n(COLOR [^\n]*)") or ""
  if now ~= c[2] then return st end
  return mirror.with_colour_line(st, c[1])
end
function mirror.tried_track(proj, tr)
  local try = require("band").colour_try(proj)
  return try and try.tracks and try.tracks[reaper.GetTrackGUID(tr)] or nil
end
function mirror.item_state(it, media_dir)
  local _, chunk = reaper.GetItemStateChunk(it, "", false)
  local st = item_base(chunk, media_dir) .. item_tail(it)
  local try = reaper.GetItemProjectContext and require("band").colour_try(reaper.GetItemProjectContext(it))
  return try and try.items and untried_item(st, try.items[select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false))]) or st
end
-- Every listed item's state for a look ({ ptr, tr, guid }: mirror.scan), in order. A track whose whole chunk, items and all, is byte for byte
-- the last look's holds the same item chunks: their states are the last look's, without asking REAPER for each item's chunk again. On a
-- changed track, an item whose chunk is the last look's reuses its state too (a string compare, not the memo's hash of the whole text). Lane
-- and picked take are read through the API as always. Not on a track marked `dirty` (an item's id set this look, after its chunk was read),
-- holding a GUID twice, or with pooled MIDI (a pooled copy's notes can be written in another track's chunk, as a project file writes them
-- once, so its own track's text needn't change with them). Each look serialized every item twice, a third to a half of a warm look at
-- 2,000-3,000 MIDI items. Cost: one string compare a track, one plain find on a track whose chunk changed, and last look's track chunks kept in
-- memory (an item's own chunk only while its track changes: Round 4 review, 0.59.49). Round 3 review, 0.59.48
-- Real MIDI pools (rt-perfcut2). REAPER writes "POOLEDEVTS {guid}" into every MIDI item, pooled or not (rt-perf: 60 MIDI items, 60 GUIDs),
-- so the token alone had every MIDI track and all its items read at every look. A pool is a GUID that two or more items in the project hold.
-- A chunk's pool GUIDs, each with how many of its items hold it, or nil. (Plain finds: a pattern over a 3 MB synth track costs far more.)
function mirror.pool_ids(chunk)
  local t, i = nil, 1
  while true do
    local _, b = chunk:find("POOLEDEVTS ", i, true)
    if not b then return t end
    local g = chunk:match("^%S+", b + 1)
    if g then t = t or {}; g = g:upper(); t[g] = (t[g] or 0) + 1 end
    i = b + 1
  end
end
-- The GUIDs held by two or more items, over a table whose values are mirror.pool_ids'. -> { [guid] = true }
function mirror.shared_pools(of)
  local n, out = {}, {}
  for _, p in pairs(of) do for g, c in pairs(p) do n[g] = (n[g] or 0) + c; if n[g] >= 2 then out[g] = true end end end
  return out
end
function mirror.in_pool(p, shared)
  for g in pairs(p or {}) do if shared[g] then return true end end
  return false
end
local look_items, look_proj = {}, {} -- tostring(proj) -> { [track] = { chunk, media, pooled, items = { [item GUID] = { chunk, base } } } }; -> proj
-- (`partial`: `list` holds only some tracks' items, a quick look's changed tracks: the others' boxes are kept as they were. rt-look)
-- (`pooled_tr`: { [track] = true } for the tracks holding a real pool (mirror.pool_ids): REAPER writes POOLEDEVTS into every MIDI item,
-- pooled or not. Without it, as before: any POOLEDEVTS counts. rt-perfcut2)
function mirror.item_states(proj, list, chunks, media_dir, dirty, partial, pooled_tr)
  local pk = tostring(proj)
  local was, now, out = look_items[pk] or {}, {}, {}
  local try = require("band").colour_try(proj)
  local tried = try and try.items -- (a colour look tried here: mirror.item_state)
  for _, x in ipairs(list) do
    local box = now[x.tr]
    if not box then
      local prev, ch = was[x.tr], chunks[x.tr]
      if prev and prev.media ~= media_dir then prev = nil end
      local same = prev ~= nil and ch ~= nil and prev.chunk == ch
      local pooled
      if pooled_tr then pooled = pooled_tr[x.tr] == true
      elseif same then pooled = prev.pooled else pooled = ch ~= nil and ch:find("POOLEDEVTS", 1, true) ~= nil end
      box = { chunk = not dirty[x.tr] and ch or nil, media = media_dir, items = {}, prev = prev, pooled = pooled }
      box.same = same and not pooled and not dirty[x.tr]
      now[x.tr] = box
    end
    if box.items[x.guid] then box.same, box.chunk = false, nil end -- (a GUID twice on it)
    box.items[x.guid] = true
  end
  for i, x in ipairs(list) do
    local box = now[x.tr]
    local p = box.prev and box.prev.items[x.guid]
    local keep = box.same and p or nil
    if not keep then
      local _, chunk = reaper.GetItemStateChunk(x.ptr, "", false)
      keep = p and p.chunk == chunk and p or { chunk = chunk, base = item_base(chunk, media_dir) }
    elseif keep.chunk then keep.chunk = nil end -- (its track's chunk holds it: kept too, a memo hit's chunk was a second copy. Round 4 review, 0.59.49)
    box.items[x.guid] = keep
    -- (a lane or take line unchanged: last look's whole state, the same string, so item_hash's memo finds it without hashing it all again.
    -- Cost: one short string compare an item. Round 4 review, 0.59.49)
    local tail = item_tail(x.ptr)
    if tail == "" then out[i] = keep.base
    else
      if keep.tail ~= tail then keep.tail, keep.st = tail, keep.base .. tail end
      out[i] = keep.st
    end
    if tried then out[i] = untried_item(out[i], tried[x.guid]) end
  end
  for _, box in pairs(now) do box.prev = nil end -- (only last look's is kept)
  if partial then for tr, box in pairs(was) do if now[tr] == nil then now[tr] = box end end end
  look_items[pk], look_proj[pk] = now, proj
  for k, p in pairs(look_proj) do -- (a closed tab's go: the panel looks at several)
    if k ~= pk and not reaper.ValidatePtr(p, "ReaProject*") then look_items[k], look_proj[k] = nil, nil end
  end
  return out
end
-- A state from an older version that's this one but for what that version left out: the BANDTAKE line (before 0.58.85), and empty takes
-- written as bare "TAKE" (before 0.58.87). The same item, read the way this version reads one. Pure.
local function older_form(s) return (s:gsub("BANDTAKE %d+\n", ""):gsub("\nTAKE NULL%f[\n]", "\nTAKE")) end -- (any run of empty takes, not two at most. 0.58.92)
mirror.older_form = older_form
function mirror.only_pick_new(track, here, theirs)
  if type(theirs) ~= "string" or theirs:find("BANDTAKE", 1, true) or theirs:find("\nTAKE NULL\n", 1, true) then return false end
  if not (here:find("BANDTAKE", 1, true) or here:find("\nTAKE NULL\n", 1, true)) then return false end
  return mirror.item_hash(track, older_form(mirror.normalize_item(theirs))) == mirror.item_hash(track, older_form(here))
end

-- A track's chunk up to its first item, closed. Not on a frozen track: its <FREEZE block holds items of its own, before the track's, and was
-- cut through (B couldn't unfreeze what A froze). The whole chunk then. Pure.
function mirror.track_head(chunk)
  local cut = not chunk:find("<FREEZE", 1, true) and chunk:find("\n%s*<ITEM")
  return cut and (chunk:sub(1, cut) .. ">\n") or chunk
end
-- A track's plug-ins, automation, sends and the rest, from its chunk (or its chunk up to its first item). `lfx`: its P_EXT band_local_fx
-- (this machine's plug-in translations, never sent), then its P_EXT band_fx_held. Pure.
function mirror.track_head_parts(chunk, lfx, oid_at)
  local skip = {} -- this machine's plug-in translations (lib/page_plugins.lua): never sent
  for g in (lfx or ""):gmatch("({[^}]+})for=") do skip[g] = true end
  -- (a track whose FX run on a bandmate's computer has them bypassed here: each goes out with the BYPASS line the band has. Shared CPU, rt)
  for g, v in (lfx or ""):gmatch("({[^}]+})held=([^;]*);") do skip[g] = "BYPASS " .. v end
  local fx = mirror.fxchain(chunk, skip) or ""
  local env, recv, misc = mirror.track_parts(chunk, oid_at)
  return { fx = fx, fxh = mirror.fx_hash(fx), env = env, recv = recv, misc = misc, mods = mirror.modulated(mirror.fxchain(chunk) or "") }
end
-- Every mirrored object in the project, with its normalized state and hash. Objects with no oid, or a copy that
-- carries another object's oid, get a fresh oid here (they are new). `media_dir`: the room's media folder.
-- Copies (Ctrl+drag, paste, duplicate track) carry their source's oid. Whichever of them REAPER's own GUID shows to
-- be the one this machine already knew keeps the oid, wherever it sits (a copy placed before its source must not take
-- it: the source would then look new and be put back); the others become new objects. Returns the oid per entry.
mirror.CSEC = "BandSync.colours" -- "colours" = "own" (SWS auto-colours tracks here) or "band": as of the last look
mirror.GSEC = "BandSync.mirrorg" -- oid -> REAPER GUID of the object holding it here (this machine's own)
-- (`also_held`: oids items outside `list` hold, a quick look's unchanged tracks: no GUID gets one of those back. rt-look)
local function settle_ids(proj, list, kind, user, set_oid, also_held)
  local keeper, matched, c, held = {}, {}, ids(proj), {}
  -- no oid, but this machine gave its GUID one before (the project wasn't saved since): it gets that oid back
  for oid in pairs(also_held or {}) do held[oid] = true end
  for _, x in ipairs(list) do if x.oid ~= "" then held[x.oid] = true end end
  for _, x in ipairs(list) do
    local was = x.oid == "" and c and c.guid[x.guid]
    if was and not held[was] then
      x.oid, x.restored, held[was] = was, true, true
      set_oid(x.ptr, was)
      for _, p in ipairs(kind == "T" and { "T", table.unpack(mirror.PARTS) } or { "I" }) do -- what this machine knew of it (and its parts)
        local oid = p .. was:sub(2)
        if c.rec[oid] and ext(proj, oid) == "" then setext(proj, oid, c.rec[oid]) end
      end
    end
  end
  for k, x in ipairs(list) do
    if x.oid ~= "" and not matched[x.oid] then
      local known = x.guid == select(2, reaper.GetProjExtState(proj, mirror.GSEC, x.oid))
      if not keeper[x.oid] or known then keeper[x.oid], matched[x.oid] = k, known end -- (the first that REAPER knows wins)
    end
  end
  for k, x in ipairs(list) do
    if x.oid == "" or keeper[x.oid] ~= k then
      -- (a track's copy says what it's a copy of, on the track: whichever script looks first gives it its oid. mirror.watch)
      if kind == "T" and x.oid ~= "" then reaper.GetSetMediaTrackInfo_String(x.ptr, "P_EXT:band_copy_of", x.oid, true) end
      x.oid = mirror.new_oid(kind, user); set_oid(x.ptr, x.oid)
    end
    if select(2, reaper.GetProjExtState(proj, mirror.GSEC, x.oid)) ~= x.guid then reaper.SetProjExtState(proj, mirror.GSEC, x.oid, x.guid) end
    if c and c.guid[x.guid] ~= x.oid then c.guid[x.guid], c.dirty = x.oid, true end
    if x.restored then
      mirror.reopened[tostring(proj) .. x.oid] = true
      mirror.restored_now[#mirror.restored_now + 1] = tostring(proj) .. x.oid -- (which, for the look that follows: mirror.watch)
      if kind == "T" then
        for _, p in ipairs(mirror.PARTS) do
          mirror.reopened[tostring(proj) .. p .. x.oid:sub(2)] = true
          mirror.restored_now[#mirror.restored_now + 1] = tostring(proj) .. p .. x.oid:sub(2)
        end
      end
    end
  end
end
-- oids given back after an unsaved reopen whose state here is older than the band's: put back, never sent, until they
-- match what this machine last knew (proj .. oid -> true)
mirror.reopened = {}
mirror.restored_now = {} -- the keys settle_ids marked since the last look (mirror.watch takes them)
mirror.auto = {} -- proj .. oid -> its next send is a print StudioSync refreshed (Undo skips those)
mirror.print_quiet = {} -- proj .. oid -> { key, at }: nothing to print for it as of then (W.prints)
mirror.tracks_back = mirror.tracks_back or {} -- tostring(proj) -> { oid = event }: tracks put back by a look, settings again after their items (mirror.watch)
mirror.unsent = {} -- proj .. oid -> changed here, not sent yet (settling, playing, a burst's rest): mirror.receive waits
mirror.asked_of = {} -- proj .. oid -> { who, at }: an edit held here for that bandmate's answer, as of the last look that held it (W.refuse)
-- Items that can't go out (their audio couldn't be copied into the studio's folder or isn't on this computer, or their send threw), per
-- project: Sync and exit counts them (mirror.waiting). Not mirror.unsent, which receive waits on: the band's version of such an item would
-- wait for ever if the file never comes back. Round 1 review, 0.59.45
mirror.held_back = mirror.held_back or {} -- tostring(proj) -> { oid = true }
local function held_back_set(proj, oid)
  local k = tostring(proj)
  mirror.held_back[k] = mirror.held_back[k] or {}
  mirror.held_back[k][oid] = true
end
local function held_back_clear(proj, oid)
  local t = mirror.held_back[tostring(proj)]
  if t then t[oid] = nil end
end
-- What still waits to go out from the project `key` (tostring(proj)), in words, or nil. Live sync's outbox (Sync and exit) asks. Pure but for
-- this module's tables.
function mirror.waiting(key)
  if mirror.more then return "changes" end
  for k in pairs(mirror.unsent) do
    if k:sub(1, #key) == key then return "changes waiting their turn (a recording still copying, or plug-ins settling)" end
  end
  if next(mirror.held_back[key] or {}) then
    -- (any change held back, not only audio: a send that threw counts too. Round 2 review, 0.59.46)
    return "a change that can't go out yet (an item's audio couldn't be copied into the studio's folder or isn't on this computer, or sending it failed: see Settings > Console)"
  end
  if mirror.unsettled then return "plug-ins or automation settling" end
end
mirror.anchor_seen = {} -- proj .. oid .. known hash -> its event was checked against what's here (see watch)
mirror.said_outside = {} -- proj .. oid -> a landed chain's ReaInsert / ReaStream was mentioned

-- Crash-safe sessions. What's changed here and not gone out yet (mirror.unsent: plug-ins or automation settling or waiting for the stop, a big
-- file still copying, a burst's rest; and held-back items) lived only in memory: REAPER killed or crashed, it went with the
-- unsaved project. So it's kept beside the project too, <project>.bandsync-unsent.json ({ objs = { [oid] = { kind, track, state, hash, pos, known,
-- gone } } }, `known` the record it was made on), and the first look after the project opens again puts it back on the project, which that look
-- then sends as any change of yours. Written at a look's end when what's in it changed, STASH_SECS apart at most (a knob turned while
-- playing rewrote the chain every look). Live sync's clean stop takes it away (mirror.drop_stash): REAPER asked about saving then, and a project
-- closed unsaved is the user's choice. Untitled projects have none. James, rt
mirror.STASH_SECS = 2
mirror.restoring = {} -- tostring(proj) -> { [oid] = entry } read back and not put back yet (playing, its tab behind: the next look tries again)
local stash_sig, stash_at, stash_read = {}, {}, {} -- path -> what was last written, and when; tostring(proj) -> the master track it was read for
local function stash_path(c) return c and (c.path:gsub("ids%.json$", "unsent.json")) end
function mirror.stash_unsent(proj, by_oid)
  local path = stash_path(ids(proj))
  if not path then return end
  local key, waiting, oids, out, sig = tostring(proj), mirror.restoring[tostring(proj)] or {}, {}, {}, {}
  for k in pairs(mirror.unsent) do if k:sub(1, #key) == key then oids[#oids + 1] = k:sub(#key + 1) end end
  for oid in pairs(mirror.held_back[key] or {}) do oids[#oids + 1] = oid end
  for oid in pairs(waiting) do
    oids[#oids + 1] = oid
    mirror.unsent[key .. oid] = true -- (still to put back: the band's change to it waits, as for any change of yours not sent)
  end
  for _, oid in ipairs(oids) do
    local o, kind = by_oid[oid], mirror.KIND[oid:sub(1, 1)]
    if out[oid] then
    elseif waiting[oid] then out[oid] = waiting[oid]
    elseif o then out[oid] = { kind = o.kind, track = o.track, state = o.state, hash = o.hash, pos = o.pos, known = ext(proj, oid) }
    elseif kind == "track" or kind == "item" then -- (gone here, its delete held: only what the band has)
      local _, h = mirror.known(proj, oid)
      if h and h ~= "" then out[oid] = { kind = kind, gone = true, known = ext(proj, oid) } end
    end
    if out[oid] and not sig[oid] then sig[oid] = true; sig[#sig + 1] = oid .. "|" .. tostring(out[oid].hash or "gone") end
  end
  table.sort(sig)
  local s, now = table.concat(sig, "\n"), reaper.time_precise()
  if s == stash_sig[path] or now - (stash_at[path] or -math.huge) < mirror.STASH_SECS then return end
  stash_sig[path], stash_at[path] = s, now
  if s == "" then os.remove(path) else require("band").write_json(path, { objs = out }) end
end
-- The file read once per opening (a file opened again in its tab has a new master track, as W.order tells), and each entry put back unless the
-- project already has it, or holds a newer version than the one it was made on. Tracks first, deletions last. -> how many were put back.
local RANK = { T = 1, F = 2, E = 2, R = 2, M = 2, I = 3 }
function mirror.restore_unsent(proj, by_oid, media, local_mix)
  local key, master = tostring(proj), reaper.GetMasterTrack(proj) or false
  if stash_read[key] ~= master then
    stash_read[key] = master
    local path = stash_path(ids(proj))
    local d = path and require("band").read_json(path)
    mirror.restoring[key] = type(d) == "table" and type(d.objs) == "table" and next(d.objs) and d.objs or nil -- (an older file's `hold`: ignored)
  end
  local list = mirror.restoring[key]
  if not list then return 0 end
  local oids = {}
  for oid, e in pairs(list) do
    if type(oid) == "string" and RANK[oid:sub(1, 1)] and type(e) == "table" and (e.gone or e.state ~= nil) then oids[#oids + 1] = oid else list[oid] = nil end
  end
  local function rank(oid) return list[oid].gone and 7 - RANK[oid:sub(1, 1)] or RANK[oid:sub(1, 1)] end -- (an item's delete before its track's)
  table.sort(oids, function(a, b) if rank(a) ~= rank(b) then return rank(a) < rank(b) end; return a < b end)
  local n = 0
  for _, oid in ipairs(oids) do
    local e, o = list[oid], by_oid[oid]
    local krev, kh = mirror.known(proj, oid)
    local r, h, evid, order = tostring(e.known or ""):match("^(%d+)|([^|]*)|([^|]*)|?(.*)$")
    r = tonumber(r)
    if (krev or -1) > (r or -1) then list[oid] = nil -- (the project holds a newer version than the one it was made on: older news)
    elseif e.gone then
      list[oid] = nil
      if o and o.hash == kh then -- (still as the band last had it here)
        local ok, done = pcall(mirror.apply, proj, { obj = e.kind, oid = oid, gone = true }, media, local_mix)
        if ok and done then n = n + 1 end
      end
    elseif o and o.hash == e.hash then -- (saved with it: the look sends it as it is)
      list[oid] = nil
      -- (built on what it was made on, too: the file can hold the change on an older record, and then the band's newer one landed over it as
      -- news, a held edit gone. Laptop kill test, rt)
      if r and r ~= krev then remember(proj, oid, r, h, evid, order) end
    else
      local ok, done = pcall(mirror.apply, proj, { obj = e.kind, oid = oid, track = e.track, state = e.state, pos = e.pos }, media, local_mix)
      if not ok then require("band").log("couldn't put back a change of yours from before REAPER stopped: " .. tostring(done)) end
      if not ok or done then list[oid] = nil end -- (false: playing, or its tab behind, as the band's changes wait)
      if ok and done then
        n = n + 1
        if r and r ~= krev then remember(proj, oid, r, h, evid, order) end -- (what it was made on: the look builds on that, as it would have)
        local k = key .. oid
        mirror.reopened[k] = nil -- (the newest of yours, not an older save to put back)
        -- (nor a chain's read-back as it loads: apply marks the band's chains so)
        mirror.fx_readback[k], mirror.fx_loading[k], mirror.fx_load_knobs[k], mirror.fx_quiet[k] = nil, nil, nil, nil
      end
    end
  end
  if next(list) == nil then mirror.restoring[key] = nil end
  if n > 0 then require("band").log(string.format("REAPER stopped before %d change(s) of yours went out: they're back in the project and go out now", n)) end
  return n
end
-- Once each opening, before the look reads anything. Hold my changes is gone (James, 2026-11-20: "someone can go into a different room to
-- test"): a project saved with it on (ProjExtState "hold": "1", or a colour try's "try"/"try1") has it cleared, and what it held goes out
-- through this look as any change of yours. The only place "hold" is read (tests/test_0_60_rt_nohold.lua checks). And a colour look REAPER
-- stopped during is put back, nothing sent (lib/colours.lua). rt-nohold
mirror.opened = {} -- tostring(proj) -> the master track it was opened with (a test forgets one to open it again)
-- -> true on a new opening: this script's first look at the project, or a file opened again in its tab (rt-guard, mirror.watch)
function mirror.on_open(proj)
  local key, master = tostring(proj), reaper.GetMasterTrack(proj) or false
  if mirror.opened[key] == master then return false end
  mirror.opened[key] = master
  local B = require("band")
  if select(2, reaper.GetProjExtState(proj, B.SECTION, "hold")) ~= "" then
    reaper.SetProjExtState(proj, B.SECTION, "hold", "")
    B.log("Hold my changes was removed: this project's held changes go out now")
  end
  local ok, err = pcall(require("colours").put_back_stale, proj)
  if not ok then B.log("colours: " .. tostring(err)) end
  return true
end
function mirror.drop_stash(proj)
  local path = stash_path(idc[proj])
  if path then os.remove(path); stash_sig[path], stash_at[path] = nil, nil end
end

-- The mirrored tracks, their oids settled, and where each sits (what the receives' track numbers mean). mirror.scan and mirror.quick_scan.
local function scan_tracks(proj, user)
  local tl = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if not local_track(tr) then
      tl[#tl + 1] = { ptr = tr, oid = trk_oid(tr), guid = select(2, reaper.GetSetMediaTrackInfo_String(tr, "GUID", "", false)) }
    end
  end
  settle_ids(proj, tl, "T", user, function(tr, oid) reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", oid, true) end)
  local at = {} -- 0-based position -> oid, for receives
  for _, x in ipairs(tl) do at[math.floor(reaper.GetMediaTrackInfo_Value(x.ptr, "IP_TRACKNUMBER")) - 1] = x.oid end
  local function oid_at(i) return at[i] end
  local sig = {} -- (where each mirrored track sits: what the receives' track numbers mean, part of the memo's key)
  for i = 0, reaper.CountTracks(proj) - 1 do sig[#sig + 1] = at[i] or "-" end
  return tl, oid_at, table.concat(sig, ",")
end
local function track_lfx(tr)
  return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local_fx", "", false))
    .. select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_fx_held", "", false)) -- (lib/hops.lua: offloaded, held off here)
end
-- (keyed on the track's own part, before its first item: an item edit missed the whole track's entry, and its item lines were parsed again
-- in Lua, 50 to 200 ms on a big MIDI track. Nothing of the track's follows its items: 574 tracks in 60 projects here, and
-- tests/test_0_59_45_engine.lua asserts the parts come out the same. Round 1 review, 0.59.45)
local function head_parts(chunk, lfx, at_sig, oid_at)
  local head = mirror.track_head(chunk)
  return mirror.memo("t\0" .. at_sig .. "\0" .. restless_sig() .. "\0" .. lfx, head, function() return mirror.track_head_parts(head, lfx, oid_at) end)
end
-- A track's plug-ins, automation, sends and the rest as objects (its automation items read through the API every look, as always).
local function add_parts(objs, by_oid, tr, oid, parts)
  mirror.mod_params[tr] = parts.mods -- (every plug-in, in REAPER's order: what mirror.fx_params counts by)
  local fo = { kind = "fx", oid = "F" .. oid:sub(2), ptr = tr, track = oid, state = parts.fx, hash = parts.fxh }
  objs[#objs + 1], by_oid[fo.oid] = fo, fo
  local env, recv = parts.env .. mirror.ai_lines(tr), parts.recv .. mirror.ai_lines(tr, "recv")
  for _, p in ipairs({ { "E", "env", env }, { "R", "recv", recv }, { "M", "misc", parts.misc } }) do
    local po = { kind = p[2], oid = p[1] .. oid:sub(2), ptr = tr, track = oid, state = p[3], hash = mirror.hash(p[3]) }
    objs[#objs + 1], by_oid[po.oid] = po, po
  end
end
local function add_master(proj, objs, by_oid, oid_at)
  local master = reaper.GetMasterTrack(proj)
  local _, mch = reaper.GetTrackStateChunk(master, "", false)
  local mfx = mirror.fxchain(mch, mirror.live_fx(master)) or ""
  mirror.mod_params[master] = mirror.modulated(mirror.fxchain(mch) or "")
  if mfx:match("^<FXCHAIN[^\n]*\n>%s*$") then mfx = "" end -- (only this computer's live mix on it: Real time mode read as "changed the plug-ins on the master")
  local menv = mirror.track_parts(mch, oid_at) .. mirror.ai_lines(master) .. mirror.master_fxen_line(proj, master)
  for _, p in ipairs({ { "F-MASTER", "fx", mfx }, { "E-MASTER", "env", menv } }) do
    local po = { kind = p[2], oid = p[1], ptr = master, track = mirror.MASTER, state = p[3], hash = p[2] == "fx" and mirror.fx_hash(p[3]) or mirror.hash(p[3]) }
    objs[#objs + 1], by_oid[po.oid] = po, po
  end
  by_oid[mirror.MASTER] = { kind = "master", state = { name = "Master" } } -- (who may change it: as a track called Master)
end
-- ---- Quick looks (rt-look: docs/rt/rt-look.md) ----
-- A look asked REAPER for every track's chunk and worked every object out again, ~150-300 ms of Lua and 144,000 calls at 150 tracks and 4,000
-- items, after every edit. A quick look reads each track's cheap fingerprint (track_fp) and asks for the chunks of the tracks that may have
-- changed only (track_fp moved, a selected item or track, the MIDI editor's, the selected envelope's, an FX window open in the last minute,
-- something StudioSync wrote or wants to look at again); a track whose chunk is byte for byte the last one keeps its parts and items. When
-- none of those changed anything, every chunk is read (an edit the hints can't see: a script's, a knob turned with no window open). Every
-- chunk is read at least each QUICK_ALL_SECS, and a full look (mirror.scan, every object through W.one, as before) runs each QUICK_FULL_SECS
-- and logs anything the quick one would have missed. mirror.watch with opts.quick only (Live sync's looks); everything else looks in full.
mirror.QUICK_ALL_SECS, mirror.QUICK_FULL_SECS = 10, 60
-- How far apart the timed full looks are, by how long the last one took (rt-perfcut2): they keep to QUICK_FULL_SHARE of REAPER's main thread,
-- at least QUICK_FULL_SECS and at most QUICK_FULL_MAX apart. A small song's (10-15 ms) stays a minute; a heavy song's 300+ ms stall comes every
-- 2.5 minutes, 0.6 s and over every 5. The safety net found nothing in 297 looks (rt-perf); the every-chunk read each 10 s stays as it was.
mirror.QUICK_FULL_SHARE, mirror.QUICK_FULL_MAX = 0.002, 300
function mirror.full_every(took) return math.min(mirror.QUICK_FULL_MAX, math.max(mirror.QUICK_FULL_SECS, (took or 0) / mirror.QUICK_FULL_SHARE)) end
mirror.more_act = mirror.more_act or {} -- tostring(proj) -> the act a burst's first pass sent under, while more of it waits (mirror.watch)
mirror.looks = mirror.looks or {} -- tostring(proj) -> what the last look saw (tracks by GUID, objects' hashes, which were clean)
mirror.remembered = mirror.remembered or {} -- tostring(proj) -> { oid = true }: records written since the last look (remember)
mirror.touched = mirror.touched or {} -- tostring(proj) -> { [track] = true }: written by StudioSync without a record, read at the next look
mirror.look_stats = mirror.look_stats or { quick = 0, full = 0, all_chunks = 0, missed = 0 }
-- Another module wrote to a track or item outside a record (a print, video stand-ins: rt-video2): its chunk is read at the next quick look.
function mirror.touch(proj, tr)
  if not tr then return end
  mirror.applied = (mirror.applied or 0) + 1 -- (as mirror.apply's)
  local pk = tostring(proj)
  mirror.touched[pk] = mirror.touched[pk] or {}
  mirror.touched[pk][tr] = true
end
-- What a track's chunk would show changed, read through the API: its settings line, plug-in translations, how many items and where the first
-- and last sit (a move, a trim at either end, ripple and insert-space moving everything after), plug-ins and which are on, envelopes and their
-- points, receives and their levels. Not complete (a knob, a point dragged, a fade): the hints and the read of every chunk catch those.
local function track_fp(tr, th, lfx)
  local n, nfx, nenv, nrecv = reaper.CountTrackMediaItems(tr), reaper.TrackFX_GetCount(tr), reaper.CountTrackEnvelopes(tr), reaper.GetTrackNumSends(tr, -1)
  local f = { th, lfx, n, nfx, reaper.TrackFX_GetRecCount(tr), nenv, nrecv, reaper.GetTrackNumSends(tr, 0), reaper.GetTrackNumSends(tr, 1) }
  if n > 0 then
    local a, z = reaper.GetTrackMediaItem(tr, 0), reaper.GetTrackMediaItem(tr, n - 1)
    f[#f + 1] = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
    f[#f + 1] = reaper.GetMediaItemInfo_Value(z, "D_POSITION")
    f[#f + 1] = reaper.GetMediaItemInfo_Value(z, "D_LENGTH")
  end
  for i = 0, nfx - 1 do f[#f + 1] = reaper.TrackFX_GetEnabled(tr, i) and "e" or "b" end
  for e = 0, nenv - 1 do f[#f + 1] = reaper.CountEnvelopePoints(reaper.GetTrackEnvelope(tr, e)) end
  for r = 0, nrecv - 1 do
    f[#f + 1] = reaper.GetTrackSendInfo_Value(tr, -1, r, "D_VOL")
    f[#f + 1] = reaper.GetTrackSendInfo_Value(tr, -1, r, "D_PAN")
    f[#f + 1] = reaper.GetTrackSendInfo_Value(tr, -1, r, "B_MUTE")
  end
  return table.concat(f, " ")
end
mirror.track_fp = track_fp -- (tests)
local function tempo_fp(proj)
  local f = {}
  for i = 0, reaper.CountTempoTimeSigMarkers(proj) - 1 do
    local _, t, m, b, bpm, num, den, lin = reaper.GetTempoTimeSigMarker(proj, i)
    f[#f + 1] = string.format("%.10g %.10g %.10g %.10g %s %s %s", t or 0, m or 0, b or 0, bpm or 0, tostring(num), tostring(den), tostring(lin))
  end
  return table.concat(f, ";")
end
-- Tracks an edit was most likely on: selected items' and tracks, the last touched, the MIDI editor's take's, the selected envelope's, and any
-- with an FX window open in the last minute (mirror.note_open_fx, keyed by tostring). A set of track pointers and their tostring.
local function hinted(proj)
  local set = {}
  local function add(tr) if tr then set[tr] = true end end
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
    local it = reaper.GetSelectedMediaItem(proj, i)
    if it then add(reaper.GetMediaItem_Track(it)) end
  end
  for i = 0, reaper.CountSelectedTracks(proj) - 1 do add(reaper.GetSelectedTrack(proj, i)) end
  if reaper.GetLastTouchedTrack then add(reaper.GetLastTouchedTrack()) end
  local ed = reaper.MIDIEditor_GetActive and reaper.MIDIEditor_GetActive()
  local tk = ed and reaper.MIDIEditor_GetTake(ed)
  if tk then add(reaper.GetMediaItemTake_Track(tk)) end
  local env = reaper.GetSelectedEnvelope and reaper.GetSelectedEnvelope(proj)
  if env then
    local tr = reaper.Envelope_GetParentTrack(env)
    if not tr then
      local take = reaper.Envelope_GetParentTake(env)
      tr = take and reaper.GetMediaItemTake_Track(take)
    end
    add(tr)
  end
  local now = reaper.time_precise()
  for k, at in pairs(mirror.fx_open_at) do if now - at < 60 then set[k] = true end end
  return set
end
mirror.hinted = hinted -- (lib/dawview.lua's partial reads use the same hints; tests. rt-perfcut4)
-- What a quick look needs to be the same as the last look's to build on it: anything that changes how every object reads.
local function look_ctx(proj, user, media_dir, local_mix, at_sig)
  return table.concat({ media_dir, tostring(local_mix), tostring(user), restless_sig(), tostring(mirror.own_colours()), at_sig,
    tostring(reaper.GetMasterTrack(proj)), reaper.GetExtState(require("band").SECTION, "colour try " .. tostring(proj)) }, "\1") -- (a colour try's stamp: rt-nohold)
end
-- (an unchanged track's item, its pointer looked up only if something asks: by its place, checked by its GUID)
local lazy = setmetatable({}, { __mode = "k" })
local LAZY = { __index = function(o, k)
  local l = k == "ptr" and lazy[o]
  if not l then return nil end
  local tr, j, g = l[1], l[2], l[3]
  local function guid(x) return x and select(2, reaper.GetSetMediaItemInfo_String(x, "GUID", "", false)) end
  local it = reaper.ValidatePtr2(0, tr, "MediaTrack*") and reaper.GetTrackMediaItem(tr, j)
  if guid(it) ~= g then
    it = nil
    for i = 0, reaper.ValidatePtr2(0, tr, "MediaTrack*") and reaper.CountTrackMediaItems(tr) - 1 or -1 do
      local x = reaper.GetTrackMediaItem(tr, i)
      if guid(x) == g then it = x; break end
    end
  end
  if it then rawset(o, "ptr", it) end
  return it
end }
local function item_obj(p, tr, toid)
  local o = setmetatable({ kind = "item", oid = p.oid, track = toid, state = p.state, hash = p.hash, pos = p.pos }, LAZY)
  lazy[o] = { tr, p.j, p.guid }
  return o
end
-- A new look record. `L`: the last one, for what carries over.
local function new_look(L, ctx, now)
  return { ctx = ctx, tracks = {}, where = {}, all_at = L and L.all_at or now, full_at = L and L.full_at or now, tempo = L and L.tempo, attn = {}, clean = {},
    raw = {}, guid_of = {}, full_took = L and L.full_took }
end

function mirror.scan(proj, user, media_dir, local_mix, rec)
  mirror.memo_turn() -- (between looks only: see mirror.memo)
  mirror.restless_load()
  local objs, by_oid, tracks, chunks, pools = {}, {}, {}, {}, {}
  local tl, oid_at, at_sig = scan_tracks(proj, user)
  local tg = {} -- track -> its record (rec)
  for _, x in ipairs(tl) do
    local tr, oid = x.ptr, x.oid
    do
      local t = mirror.track_state(proj, tr, local_mix)
      local o = { kind = "track", oid = oid, ptr = tr, state = t, hash = mirror.track_hash(t, local_mix) }
      objs[#objs + 1], by_oid[oid], tracks[tr] = o, o, oid
      local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
      chunks[tr] = chunk -- (its items' states may be last look's: mirror.item_states)
      pools[tr] = mirror.pool_ids(chunk)
      local lfx = track_lfx(tr)
      local parts = head_parts(chunk, lfx, at_sig, oid_at)
      add_parts(objs, by_oid, tr, oid, parts)
      if rec then
        local e = { ptr = tr, oid = oid, chunk = chunk, lfx = lfx, parts = parts, pools = pools[tr], fp = track_fp(tr, o.hash, lfx), items = {},
          lanes = t.freemode == 2 }
        rec.tracks[x.guid], tg[tr], rec.guid_of[tr] = e, e, x.guid
        for _, p in ipairs({ "T", table.unpack(mirror.PARTS) }) do rec.where[p .. oid:sub(2)] = x.guid end
      end
    end
  end
  add_master(proj, objs, by_oid, oid_at)
  local shared, pooled_tr = mirror.shared_pools(pools), {}
  for tr, p in pairs(pools) do pooled_tr[tr] = mirror.in_pool(p, shared) or nil end
  if rec then
    rec.shared = shared
    for tr, e in pairs(tg) do e.pooled = pooled_tr[tr] == true end
  end
  local il, jn = {}, {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local itr = reaper.GetMediaItem_Track(it)
    local toid = tracks[itr]
    local j = jn[itr] or 0 -- (its place on its track: rec's lazy pointer starts looking there)
    jn[itr] = j + 1
    if toid and select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_arriving", "", false)) == "" then -- (a stand-in: never sent)
      il[#il + 1] = { ptr = it, tr = itr, toid = toid, oid = itm_oid(it), guid = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)), j = j }
    end
  end
  local dirty = {} -- (tracks an item's id was set on just now, after their chunks were read: mirror.item_states)
  settle_ids(proj, il, "I", user, function(it, oid) reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", oid, true); dirty[reaper.GetMediaItem_Track(it)] = true end)
  local states = mirror.item_states(proj, il, chunks, media_dir, dirty, nil, pooled_tr)
  for i, x in ipairs(il) do
    local norm = states[i]
    local o = { kind = "item", oid = x.oid, ptr = x.ptr, track = x.toid, state = norm, hash = mirror.item_hash(x.toid, norm),
      pos = reaper.GetMediaItemInfo_Value(x.ptr, "D_POSITION") }
    objs[#objs + 1], by_oid[x.oid] = o, o
    local e = rec and tg[x.tr]
    if e then
      e.items[#e.items + 1] = { oid = x.oid, guid = x.guid, state = norm, hash = o.hash, pos = o.pos, j = x.j }
      rec.where[x.oid] = rec.guid_of[x.tr]
    end
  end
  if rec then rec.ctx, rec.tempo = look_ctx(proj, user, media_dir, local_mix, at_sig), tempo_fp(proj) end
  return objs, by_oid
end

-- The same objects mirror.scan finds, in the same order, building on the last look `L` (see "Quick looks" above). -> objs, by_oid, and what
-- the look found ({ L = the new look record, fresh = oids worked out anew this time (tracks, the master's, a changed track's parts and items:
-- their records are read again before they're left out of W.one), all = every chunk was read }), or nil when the
-- last look can't be built on (tracks added, removed or moved, the restless list, colours, Local mixing, another media folder or master).
-- `remembered`: oids recorded since the last look.
function mirror.quick_scan(proj, user, media_dir, local_mix, L, remembered, now)
  mirror.memo_turn()
  mirror.restless_load()
  local tl, oid_at, at_sig = scan_tracks(proj, user)
  local ctx = look_ctx(proj, user, media_dir, local_mix, at_sig)
  if not L or ctx ~= L.ctx then return nil end
  local N = new_look(L, ctx, now)
  local tfp = tempo_fp(proj)
  -- (every chunk: due, ripple editing on all tracks (it moves everyone's items after an edit), or the tempo map changed (items and points move))
  local wide = now - L.all_at >= mirror.QUICK_ALL_SECS or reaper.GetToggleCommandStateEx(0, 41991) == 1 or tfp ~= L.tempo
  N.tempo = tfp
  local want, want_g = hinted(proj), {}
  local pk = tostring(proj)
  for tr in pairs(mirror.touched[pk] or {}) do want[tr] = true end
  mirror.touched[pk] = nil
  for g in pairs(L.attn) do want_g[g] = true end
  for oid in pairs(remembered or {}) do
    local g = L.where[oid]
    if g then want_g[g] = true
    elseif not oid:find("MASTER", 1, true) and oid:sub(1, 1) ~= "I" then wide = true end -- (a new item changes its track's count)
  end
  local found = false
  local recs = {}
  for k, x in ipairs(tl) do
    local tr, oid = x.ptr, x.oid
    local t = mirror.track_state(proj, tr, local_mix)
    local o = { kind = "track", oid = oid, ptr = tr, state = t, hash = mirror.track_hash(t, local_mix) }
    local lfx = track_lfx(tr)
    local fp = track_fp(tr, o.hash, lfx)
    local e = L.tracks[x.guid]
    -- (fixed lanes: an item's lane is read through the API, REAPER keeps it out of the item's chunk, so a lane track's items are always worked
    -- out again, and once more as it leaves lanes)
    local lanes = t.freemode == 2
    local r = { x = x, o = o, lfx = lfx, fp = fp, e = e, lanes = lanes }
    -- (need: read for a reason of its own, so its objects are checked even if its chunk is the same; fresh: read)
    r.need = not e or e.ptr ~= tr or e.oid ~= oid or e.pooled or lanes or e.lanes or want[tr] or want[tostring(tr)] or want_g[x.guid]
    r.fresh = wide or r.need or e.fp ~= fp
    if L.raw[oid] ~= o.hash then found = true end
    recs[k] = r
  end
  local function read(r, pooled)
    if r.read then return end
    r.read = true
    local tr, oid, e = r.x.ptr, r.x.oid, r.e
    local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
    r.chunk = chunk
    local same = e and e.ptr == tr and e.oid == oid and e.chunk == chunk
    r.pools = same and e.pools or mirror.pool_ids(chunk)
    r.pooled = pooled or mirror.in_pool(r.pools, L.shared or {}) -- (a real pool: mirror.pool_ids. rt-perfcut2)
    -- (byte for byte the last look's: its parts and items stand. Not pooled MIDI: a pooled copy's notes can change in another track's chunk)
    if same and not r.pooled and not r.lanes and not e.lanes and e.lfx == r.lfx then return end
    r.changed = true
    r.parts = head_parts(chunk, r.lfx, at_sig, oid_at)
    r.il = {}
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, j)
      if select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_arriving", "", false)) == "" then -- (a stand-in: never sent)
        r.il[#r.il + 1] = { ptr = it, tr = tr, toid = oid, oid = itm_oid(it), guid = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)), j = j }
      end
    end
    r.states = mirror.item_states(proj, r.il, { [tr] = chunk }, media_dir, {}, true, { [tr] = r.pooled })
    -- (did it change anything the band would see? A selection or a lane's height changes the chunk, not the objects)
    local p = e and e.parts
    if not p or p.fxh ~= r.parts.fxh or p.env ~= r.parts.env or p.recv ~= r.parts.recv or p.misc ~= r.parts.misc or #e.items ~= #r.il then found = true
    else
      for i, x in ipairs(r.il) do
        local q = e.items[i]
        if q.guid ~= x.guid or q.oid ~= x.oid or q.state ~= r.states[i] then found = true; break end
      end
    end
  end
  for _, r in ipairs(recs) do if r.fresh then read(r) end end
  local mobjs, mby = {}, {}
  add_master(proj, mobjs, mby, oid_at)
  for _, o in ipairs(mobjs) do if L.raw[o.oid] ~= o.hash then found = true end end
  -- nothing the hints pointed at changed: an edit they can't see, so every chunk is read
  local all = wide
  if not found and not all then
    all = true
    for _, r in ipairs(recs) do read(r) end
  end
  if all then N.all_at = now end
  -- (a pool that formed this look, a pooled copy on one track of an item on another: every track holding it is read as pooled now, so an edit
  -- to the pool made with it goes at once, not at the next read of every chunk. rt-perfcut2)
  local shared
  repeat
    local of, more = {}, false
    for k, r in ipairs(recs) do of[k] = r.pools or (r.e and r.e.pools) end
    shared = mirror.shared_pools(of)
    for _, r in ipairs(recs) do
      if not r.pooled and mirror.in_pool(r.pools or (r.e and r.e.pools), shared) then r.read = false; read(r, true); more = true end
    end
  until not more
  N.shared = shared
  -- items: ids settled as mirror.scan does, over the changed tracks' items and any unchanged one sharing an id with them (a copy and its source)
  local new_oids, blank = {}, false
  for _, r in ipairs(recs) do
    if r.changed then for _, x in ipairs(r.il) do if x.oid ~= "" then new_oids[x.oid] = true else blank = true end end end
  end
  local list, also = {}, nil
  for _, r in ipairs(recs) do
    if r.changed then for _, x in ipairs(r.il) do list[#list + 1] = x end
    elseif r.e then
      for _, q in ipairs(r.e.items) do
        if new_oids[q.oid] then
          local ptr = item_obj(q, r.x.ptr, r.x.oid).ptr
          if ptr then list[#list + 1] = { ptr = ptr, tr = r.x.ptr, toid = r.x.oid, oid = q.oid, guid = q.guid, j = q.j, rec = r } end
        elseif blank then also = also or {}; also[q.oid] = true end
      end
    end
  end
  local dirty = {}
  if #list > 0 then
    settle_ids(proj, list, "I", user, function(it, oid) reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", oid, true); dirty[reaper.GetMediaItem_Track(it)] = true end, also)
  end
  for _, x in ipairs(list) do -- (an unchanged track's item lost its id to its copy: that track is read again, with its new id)
    if x.rec and dirty[x.tr] and not x.rec.changed then x.rec.read = false; read(x.rec); x.rec.e = nil end
  end
  for _, r in ipairs(recs) do
    if r.changed and dirty[r.x.ptr] then
      r.states = mirror.item_states(proj, r.il, { [r.x.ptr] = r.chunk }, media_dir, { [r.x.ptr] = true }, true, { [r.x.ptr] = r.pooled })
    end
  end
  -- the objects, in mirror.scan's order: each track and its parts, the master's, then every item
  local objs, by_oid, fresh, check, gone = {}, {}, {}, {}, {}
  for _, r in ipairs(recs) do
    local tr, oid, g = r.x.ptr, r.x.oid, r.x.guid
    objs[#objs + 1], by_oid[oid] = r.o, r.o
    fresh[oid] = true
    check[#check + 1] = r.o
    local e = r.e
    local ne
    if r.changed then
      ne = { ptr = tr, oid = oid, chunk = r.chunk, lfx = r.lfx, parts = r.parts, pools = r.pools, fp = r.fp, items = {}, lanes = r.lanes }
    else
      ne = e.fp == r.fp and e or { ptr = e.ptr, oid = e.oid, chunk = e.chunk, lfx = e.lfx, parts = e.parts, pools = e.pools, fp = r.fp, items = e.items }
    end
    ne.pooled = mirror.in_pool(ne.pools, shared)
    add_parts(objs, by_oid, tr, oid, ne.parts)
    if r.changed or r.need then for k = #objs - 3, #objs do check[#check + 1] = objs[k] end end
    N.tracks[g], N.guid_of[tr] = ne, g
    for _, p in ipairs({ "T", table.unpack(mirror.PARTS) }) do
      N.where[p .. oid:sub(2)] = g
      if r.changed then fresh[p .. oid:sub(2)] = true end
    end
  end
  for _, o in ipairs(mobjs) do objs[#objs + 1] = o; fresh[o.oid] = true; check[#check + 1] = o end
  for k, v in pairs(mby) do by_oid[k] = v end
  for _, r in ipairs(recs) do
    local tr, toid, g = r.x.ptr, r.x.oid, r.x.guid
    local ne = N.tracks[g]
    if r.changed then
      for i, x in ipairs(r.il) do
        local norm = r.states[i]
        local o = { kind = "item", oid = x.oid, ptr = x.ptr, track = toid, state = norm, hash = mirror.item_hash(toid, norm),
          pos = reaper.GetMediaItemInfo_Value(x.ptr, "D_POSITION") }
        objs[#objs + 1], by_oid[x.oid] = o, o
        ne.items[#ne.items + 1] = { oid = x.oid, guid = x.guid, state = norm, hash = o.hash, pos = o.pos, j = x.j }
        N.where[x.oid], fresh[x.oid] = g, true
        check[#check + 1] = o
      end
      local now_here = {} -- (what was on it at the last look and isn't now: W.gone's candidates)
      for _, x in ipairs(r.il) do now_here[x.oid] = true end
      for _, q in ipairs(r.e and r.e.items or {}) do if not now_here[q.oid] then gone[#gone + 1] = q.oid end end
    else
      for _, q in ipairs(ne.items) do
        -- (the same object as last look, its fields as read: W.one may have re-anchored its hash, and its pointer is looked up again)
        local o = q.obj
        if o then o.hash, o.state, o.ptr = q.hash, q.state, nil
        else o = item_obj(q, tr, toid); q.obj = o end
        objs[#objs + 1], by_oid[q.oid] = o, o
        N.where[q.oid] = g
        if r.need then check[#check + 1] = o end
      end
    end
  end
  -- (check: the objects that may need W.one: a changed track's, and those of a track read for a reason of its own (hinted, busy at the last
  -- look, recorded since). Any other track's are unchanged and were left with nothing to do, or it would have been read for that. gone: items
  -- on a changed track that aren't there now)
  return objs, by_oid, { L = N, fresh = fresh, all = all, check = check, gone = gone }
end

-- Paths a band's version put on an item or a track here (as REAPER reads them back), in a P_EXT that never travels: never copied out of this
-- computer by share_media or fxfiles.share. Judged by the band's last event's text alone, the guard was skipped once that event was deleted,
-- and missed a line written another way than REAPER reads it back: a bandmate could have a file of yours uploaded. Security, Round 1 review,
-- 0.59.45. A set of fxfiles.key (lower case, "/"), joined by "|": no path a plug-in or an item names has one (fxfiles.paths stops at it), and
-- a line break inside a P_EXT broke the item's chunk, so it no longer read back as it was sent.
mirror.THEIRS = "P_EXT:band_theirs"
function mirror.theirs(ptr, is_track)
  local set = {}
  if not ptr then return set end
  local get = is_track and reaper.GetSetMediaTrackInfo_String or reaper.GetSetMediaItemInfo_String
  for l in select(2, get(ptr, mirror.THEIRS, "", false)):gmatch("[^|]+") do set[l] = true end
  return set
end
local function note_theirs(ptr, is_track, paths)
  local fxfiles, keys, seen = require("fxfiles"), {}, {}
  for _, p in ipairs(paths) do
    local k = fxfiles.key(p)
    if not seen[k] then seen[k] = true; keys[#keys + 1] = k end
  end
  table.sort(keys)
  local v = table.concat(keys, "|")
  local get = is_track and reaper.GetSetMediaTrackInfo_String or reaper.GetSetMediaItemInfo_String
  if select(2, get(ptr, mirror.THEIRS, "", false)) ~= v then get(ptr, mirror.THEIRS, v, true) end -- (written only when it changes)
end
mirror.note_theirs = note_theirs -- (a template's chains: lib/extras.lua)
-- An item's paths outside the studio's media (its FILE lines not made {media...} tokens), and what its take plug-ins load. Pure.
function mirror.item_paths(state)
  local out = {}
  for _, path in state:gmatch('FILE (["\'`])(.-)%1') do
    if path ~= "" and not path:find("^{media") then out[#out + 1] = path end
  end
  if state:find("<TAKEFX", 1, true) then
    for _, p in ipairs(require("fxfiles").paths(mirror.take_fx(state))) do out[#out + 1] = p end
  end
  return out
end

-- Media an item uses from outside the room's media folder is copied in (once) so the band has it. Returns the
-- chunk with paths rewritten to the copies. `sent`: the item's last change as the band has it; a path already in it as written came
-- from a bandmate (a shared sample library, say) and is left alone: copied, a bandmate could send a path to any file you have and
-- have your next edit of the item share it (review, 0.58.53)
mirror.media_from = {} -- a shared copy's path (normalized, lower case) -> the file it was copied from
function mirror.share_media(chunk, media_dir, it, sent)
  reaper.RecursiveCreateDirectory(media_dir, 0)
  local room = norm_path(media_dir):match("([^/]+)/media/?$") or "main"
  -- (any quote: a name with a " in it is written between ' or `, and REAPER then turns a ` inside it into ', so the
  -- path no longer names the file and the item's own source has to say. Missed, the item went out with a Mac path nobody
  -- else has, and REAPER stopped on "Replace missing file" reopening the song: Mac and laptop, 0.42.2)
  local function actual(path)
    if reaper.file_exists(path) or not it then return path end
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local src = tk and reaper.GetMediaItemTake_Source(tk)
      local f = src and reaper.GetMediaSourceFileName(src, "") or ""
      if f:gsub("`", "'") == path then return f end
    end
    return path
  end
  local theirs, key = mirror.theirs(it), require("fxfiles").key
  return (chunk:gsub('FILE (["\'`])(.-)%1', function(q, written)
    local a, z = "FILE " .. q, q
    if written:find("^{media") then return a .. written .. z end
    if theirs[key(written)] or theirs[key(actual(written))] then return a .. written .. z end -- (a path a band's version put here: mirror.theirs)
    -- (a subproject: its .rpp alone went, without its media, and pointing the item at that copy crashed a freshly started REAPER on Linux.
    -- Held back with a word instead. Linux stress test, 0.58.77)
    if written:lower():find("%.rpp$") then mirror.copy_failed = "it plays a subproject, which isn't shared: glue it to audio to send it"; return a .. written .. z end
    if type(sent) == "string" and sent:find(a .. written .. z, 1, true) then return a .. written .. z end
    local path = actual(written)
    local name = path:gsub("\\", "/"):match("[^/]+$") or "media"
    -- (plain characters only: an accented name can reach a Mac decomposed and come back as other bytes than Windows
    -- wrote, and the item then reads as different on each machine)
    -- (and its size: by path alone, a file bounced again at the same path and dragged in again played the old shared copy for everyone, with
    -- no word. A copy under the old name is still used when it's the same size. 0.59.14, review)
    local band = require("band")
    local size, safe = band.size(path), name:gsub("[^%w%-_.]", "_")
    -- (and its modified time, where js_ReaScriptAPI tells it: bounced again at the same path and length, the same size played the old shared
    -- copy. Cost: one stat per path copied. Round 1 review, 0.59.45)
    local stamp = ""
    if reaper.JS_File_Stat then
      local st, _, _, modified = reaper.JS_File_Stat(path)
      if st == 0 and modified then stamp = "|" .. tostring(modified) end
    end
    local copy = mirror.hash(path:lower()) .. "-" .. safe
    if size and (stamp ~= "" or not (reaper.file_exists(media_dir .. "/" .. copy) and band.size(media_dir .. "/" .. copy) == size)) then -- (no source to measure: the old name, as before)
      copy = mirror.hash(path:lower() .. "|" .. tostring(size or "") .. stamp) .. "-" .. safe
    end
    local dst = media_dir .. "/" .. copy
    if not reaper.file_exists(dst) and reaper.file_exists(path) then
      -- (a big one, a long recording or a video, in the background: copied here, REAPER held still for the whole copy. Its item waits till
      -- it's there. Review, 0.59.18)
      if (size or 0) > band.BIG then band.copy_background(path, dst); mirror.copy_pending = true
      else
        local ok, err = pcall(band.copy_atomic, path, dst)
        if not ok then mirror.copy_failed = tostring(err) end -- (watch holds the item back and says so: mirror.local_files)
      end
    end
    -- (only once the copy is really there: pointing at a copy that was never made left everyone waiting for it)
    if reaper.file_exists(dst) then
      mirror.media_from[band.norm(dst):lower()] = band.norm(path) -- (a byte-for-byte copy of path: a take already streamed needn't go again. lib/streams.lua offer_media, rt)
      return 'FILE "{media:' .. room .. "}/" .. copy .. '"'
    end
    -- (its file isn't here at all (an unplugged drive, a moved folder): sent as it was, it pointed everyone at a path only this computer ever
    -- had, and their copy of the item went silent. Held back with a word, as a failed copy is. Full review, 0.59.44)
    if not mirror.copy_pending and not mirror.copy_failed and not reaper.file_exists(path) then
      mirror.copy_failed = "its audio file isn't on this computer (" .. name .. "): reconnect the drive or folder it's on"
    end
    return a .. written .. z
  end))
end

-- Find a track or item by oid.
-- The master track travels as two parts only, F-MASTER (its plug-ins) and E-MASTER (its automation): its fader and
-- pan are each person's listening level. ReaNINJAM and SonoBus on it are this machine's live link, never sent, and so
-- is StudioSync's live mix (lib/hear.lua: who you hear, and in whose time).
mirror.MASTER = "T-MASTER"
-- The master's FX button travels in E-MASTER as "BANDFXEN 0", only while it's off (James, 0.58.89; so a project with it on reads as
-- before). A computer with its live link on the master (SonoBus, ReaNINJAM) keeps the button on, as switching it off there would cut the
-- live audio, and holds the band's setting in the project ("master fxen held") so it isn't sent back as a change of its own.
function mirror.master_fxen_line(proj, master)
  local _, held = reaper.GetProjExtState(proj, mirror.SEC, "master fxen held")
  local on = held ~= "" and held ~= "0" or held == "" and reaper.GetMediaTrackInfo_Value(master, "I_FXEN") ~= 0
  return on and "" or "BANDFXEN 0\n"
end
local said_master_fx = {}
function mirror.set_master_fxen(proj, master, state)
  local want = state:find("BANDFXEN 0", 1, true) and 0 or 1
  if want == 0 and next(mirror.live_fx(master)) then
    reaper.SetProjExtState(proj, mirror.SEC, "master fxen held", "0")
    if reaper.GetMediaTrackInfo_Value(master, "I_FXEN") == 0 then reaper.SetMediaTrackInfo_Value(master, "I_FXEN", 1) end
    if not said_master_fx[tostring(proj)] then
      said_master_fx[tostring(proj)] = true
      require("band").log("The band switched the master's plug-ins off; here they stay on, as SonoBus or NINJAM runs on the master and would go quiet")
    end
    return
  end
  reaper.SetProjExtState(proj, mirror.SEC, "master fxen held", "")
  if reaper.GetMediaTrackInfo_Value(master, "I_FXEN") ~= want then reaper.SetMediaTrackInfo_Value(master, "I_FXEN", want) end
end
function mirror.live_fx(tr)
  local set = {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, name = reaper.TrackFX_GetFXName(tr, i, "")
    if name:find("ReaNINJAM", 1, true) or name:find("SonoBus", 1, true) or name:find("StudioSync live mix", 1, true) or name:find("BandSync live mix", 1, true) then
      set[reaper.TrackFX_GetFXGUID(tr, i)] = true
    end
  end
  return set
end

-- While a receive pass runs (mirror.index_for), items are found through an index made once for the pass: looking
-- through every item for every change made catching up on a long song take minutes (review, 2026-10-31).
local index
function mirror.index_for(proj) index = proj and { proj = proj } or nil end
-- Two items carrying one id (a studio part Ctrl+dragged onto a track of your own keeps it, as items on local tracks get no new id): the one
-- REAPER's GUID shows is the studio's (BandSync.mirrorg), else one on a mirrored track. The last in project order was taken, and a bandmate's
-- change landed on your copy, moved it to the band track and overwrote it. Round 1 review, 0.59.45
local function item_guid(it) return select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)) end
local function studio_item(proj, oid, a, b)
  local g = select(2, reaper.GetProjExtState(proj, mirror.GSEC, oid))
  if g ~= "" then
    if item_guid(a) == g then return a end
    if item_guid(b) == g then return b end
  end
  if local_track(reaper.GetMediaItem_Track(a)) and not local_track(reaper.GetMediaItem_Track(b)) then return b end
  return a
end
mirror.studio_item = studio_item
-- The studio's item itself, still here off its track (on a track of your own): not a copy of it that kept its id. A copy taken for it
-- meant deleting the original was never sent (W.gone). No GUID recorded: anything carrying the id, as before. Round 1 review, 0.59.45
-- (a grey stand-in carrying the id isn't it either, third value true: one stands only where the item isn't, so with the item's record here it's
-- a copy of the stand-in the item landed on (a track or a stretch duplicated while the audio was arriving), or one made for a version that
-- hadn't landed when the item was deleted. Taken for "still here", deleting the item was never sent, on this computer alone. rt-converge)
function mirror.local_copy_is_it(proj, oid)
  local it = mirror.find(proj, "item", oid)
  if not it then return false end
  if (select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_arriving", "", false)) or "") ~= "" then return false, it, true end
  local g = select(2, reaper.GetProjExtState(proj, mirror.GSEC, oid))
  return g == "" or item_guid(it) == g or not local_track(reaper.GetMediaItem_Track(it)), it -- (not on a track of your own, a stand-in say: as before)
end
function mirror.find(proj, kind, oid)
  if oid == mirror.MASTER then return reaper.GetMasterTrack(proj) end
  if kind == "item" then
    if index and index.proj == proj then
      if not index.map then
        index.map = {}
        for i = 0, reaper.CountMediaItems(proj) - 1 do
          local it = reaper.GetMediaItem(proj, i)
          local o = itm_oid(it)
          local had = o ~= "" and index.map[o] -- (only when an id collides: nothing more on the usual path)
          index.map[o] = had and studio_item(proj, o, had, it) or it
        end
      end
      local it = index.map[oid]
      if it and reaper.ValidatePtr2(proj, it, "MediaItem*") and itm_oid(it) == oid then return it end
    end
    -- (the first whose GUID is the recorded one is the studio's for sure; else every match is weighed. Cost: one ExtState read per lookup
    -- here, which already walks every item)
    local found, g
    for i = 0, reaper.CountMediaItems(proj) - 1 do
      local it = reaper.GetMediaItem(proj, i)
      if itm_oid(it) == oid then
        g = g or select(2, reaper.GetProjExtState(proj, mirror.GSEC, oid))
        if g ~= "" and item_guid(it) == g then found = it; break end
        found = found and studio_item(proj, oid, found, it) or it
      end
    end
    if found and index and index.map and index.proj == proj then index.map[oid] = found end
    return found
  else
    for i = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, i)
      if trk_oid(tr) == oid then return tr end
    end
  end
end

-- A track's automation items, as lines: "BANDAI <envelope> position length offset rate baseline amplitude loop mute poollength" and each
-- point "BANDAIPT <envelope> <item> time value shape tension". Their pools live outside the track, so each arrives as an item of its own
-- (unpooled, like a MIDI copy). <envelope>: the chunk name of one of the track's own ("VOLENV2"); "PARMENV:<fx>:<param>" for a plug-in's
-- (in the automation part, which owns them); "AUX:<source track>:<nth from it>:<VOLENV|PANENV|MUTEENV>" for a receive's (in the sends
-- part: `which` = "recv"). From 0.58.89 the pool's length in beats comes last and the points are one pass of the pool (the 0x10000000
-- flag), so a looped, rate-changed or trimmed item rebuilds as it was; an older version's item has neither and its points are what showed.
local AI_KEYS = { "D_POSITION", "D_LENGTH", "D_STARTOFFS", "D_PLAYRATE", "D_BASELINE", "D_AMPLITUDE", "D_LOOPSRC", "D_MUTE" }
local ONE_PASS = 0x10000000
local AUX_ENVS = { "VOLENV", "PANENV", "MUTEENV" }
local function env_head(env) return (select(2, reaper.GetEnvelopeStateChunk(env, "", false)):match("^%s*<(%S+)")) end
local function env_tag(env, tr)
  local tag = env_head(env)
  if tag == "PARMENV" then
    local _, fx, param = reaper.Envelope_GetParentTrack(env)
    return fx and fx >= 0 and param and param >= 0 and ("PARMENV:" .. math.floor(fx) .. ":" .. math.floor(param)) or nil
  end
  return tag and tag:sub(1, 3) ~= "AUX" and tag or nil
end
-- A track's receives from mirrored tracks: { { env = { VOLENV = env, ... }, tag = "AUX:<source>:<n>" } } (the nth from that source).
local function receives(tr)
  local out, nth = {}, {}
  for r = 0, reaper.GetTrackNumSends(tr, -1) - 1 do
    local src = reaper.GetTrackSendInfo_Value(tr, -1, r, "P_SRCTRACK")
    local o = src and src ~= 0 and trk_oid(src) or ""
    if o ~= "" then
      nth[o] = (nth[o] or 0) + 1
      local e = {}
      for _, name in ipairs(AUX_ENVS) do
        local env = reaper.GetTrackSendInfo_Value(tr, -1, r, "P_ENV:<" .. name)
        if env and env ~= 0 then e[name] = env end
      end
      out[#out + 1] = { env = e, tag = "AUX:" .. o .. ":" .. nth[o] }
    end
  end
  return out
end
local function item_lines(env, tag, out)
  for a = 0, reaper.CountAutomationItems(env) - 1 do
    local v = {}
    for _, k in ipairs(AI_KEYS) do v[#v + 1] = string.format("%.10g", reaper.GetSetAutomationItemInfo(env, a, k, 0, false)) end
    v[#v + 1] = string.format("%.10g", reaper.GetSetAutomationItemInfo(env, a, "D_POOL_QNLEN", 0, false))
    out[#out + 1] = "BANDAI " .. tag .. " " .. table.concat(v, " ")
    for p = 0, reaper.CountEnvelopePointsEx(env, a | ONE_PASS) - 1 do
      local _, t, val, shape, ten = reaper.GetEnvelopePointEx(env, a | ONE_PASS, p)
      out[#out + 1] = string.format("BANDAIPT %s %d %.10g %.10g %d %.6g", tag, a, t, val, shape, ten)
    end
  end
end
function mirror.ai_lines(tr, which)
  local out = {}
  if which == "recv" then
    for _, r in ipairs(receives(tr)) do
      for _, name in ipairs(AUX_ENVS) do
        local env = r.env[name]
        if env and reaper.CountAutomationItems(env) > 0 then item_lines(env, r.tag .. ":" .. name, out) end
      end
    end
  else
    for e = 0, reaper.CountTrackEnvelopes(tr) - 1 do
      local env = reaper.GetTrackEnvelope(tr, e)
      local tag = reaper.CountAutomationItems(env) > 0 and env_tag(env, tr)
      if tag and (which ~= "parm" or tag:sub(1, 8) == "PARMENV:") then item_lines(env, tag, out) end
    end
  end
  return #out > 0 and (table.concat(out, "\n") .. "\n") or ""
end

-- One past the highest pool number in the project: the track envelopes (a plug-in's among them) and every receive's.
local function next_pool(proj)
  local pool = 0
  local function look(env) for a = 0, reaper.CountAutomationItems(env) - 1 do pool = math.max(pool, reaper.GetSetAutomationItemInfo(env, a, "D_POOL_ID", 0, false) + 1) end end
  for t = -1, reaper.CountTracks(proj) - 1 do
    local track = t < 0 and reaper.GetMasterTrack(proj) or reaper.GetTrack(proj, t)
    for e = 0, reaper.CountTrackEnvelopes(track) - 1 do look(reaper.GetTrackEnvelope(track, e)) end
    for r = 0, reaper.GetTrackNumSends(track, -1) - 1 do
      for _, name in ipairs(AUX_ENVS) do
        local env = reaper.GetTrackSendInfo_Value(track, -1, r, "P_ENV:<" .. name)
        if env and env ~= 0 then look(env) end
      end
    end
  end
  return pool
end
-- An envelope without its automation items (no API removes one: its instance lines come out of its chunk).
local function clear_ai(env)
  if reaper.CountAutomationItems(env) == 0 then return end
  local _, ch = reaper.GetEnvelopeStateChunk(env, "", false)
  local new = ch:gsub("[ \t]*POOLEDENVINST[^\n]*\n", "")
  if new ~= ch then reaper.SetEnvelopeStateChunk(env, new, false) end
end

-- Rebuild the automation items a travelling part lists. The envelope part's splice left the track's own envelopes with none, and the
-- sends part's its receives'; a plug-in's are cleared here first (its chain isn't part of the splice). `which`: "recv" for the sends part,
-- "parm" for a plug-in's only (put back after an incoming chain replaced them), else the envelope part. Each item gets a pool of its own.
function mirror.set_ai(proj, tr, state, which)
  if which ~= "recv" then
    for e = 0, reaper.CountTrackEnvelopes(tr) - 1 do
      local env = reaper.GetTrackEnvelope(tr, e)
      if env_head(env) == "PARMENV" then clear_ai(env) end
    end
  end
  if not state:find("BANDAI ", 1, true) then return end
  local pool = next_pool(proj)
  local aux = {}
  if which == "recv" then for _, r in ipairs(receives(tr)) do for name, env in pairs(r.env) do aux[r.tag .. ":" .. name] = env end end end
  local function find(tag)
    if which == "recv" then return aux[tag] end
    if tag:sub(1, 4) == "AUX:" then return nil end
    local fx, param = tag:match("^PARMENV:(%d+):(%d+)$")
    if fx then return reaper.GetFXEnvelope(tr, tonumber(fx), tonumber(param), true) end
    if which == "parm" then return nil end
    return reaper.GetTrackEnvelopeByChunkName(tr, "<" .. tag)
  end
  local made, count = {}, {}
  for line in state:gmatch("[^\n]+") do
    local tag, rest = line:match("^BANDAI (%S+) (.*)$")
    if tag then
      local v = {}
      for x in rest:gmatch("%S+") do v[#v + 1] = tonumber(x) end
      local env = find(tag)
      local k = count[tag] or 0
      count[tag] = k + 1
      if env and v[2] then
        local a = reaper.InsertAutomationItem(env, pool, v[1], v[2])
        pool = pool + 1
        local pass = v[#AI_KEYS + 1] and ONE_PASS or 0 -- (an older version's: the points that showed, as before)
        if pass ~= 0 then reaper.GetSetAutomationItemInfo(env, a, "D_POOL_QNLEN", v[#AI_KEYS + 1], true) end
        for i = 3, #AI_KEYS do if v[i] then reaper.GetSetAutomationItemInfo(env, a, AI_KEYS[i], v[i], true) end end
        for _ = 1, reaper.CountEnvelopePointsEx(env, a | ONE_PASS) do reaper.DeleteEnvelopePointEx(env, a | ONE_PASS, 0) end -- (a new item's own point)
        made[tag .. " " .. k] = { env, a | pass }
      end
    else
      local ptag, k, t, val, shape, ten = line:match("^BANDAIPT (%S+) (%d+) (%S+) (%S+) (%S+) (%S+)$")
      local m = ptag and made[ptag .. " " .. k]
      if m then reaper.InsertEnvelopePointEx(m[1], m[2], tonumber(t), tonumber(val), tonumber(shape), tonumber(ten), false, true) end
    end
  end
  for _, m in pairs(made) do reaper.Envelope_SortPointsEx(m[1], m[2]) end
end

-- A stand-in for a bandmate's item whose audio is still arriving: an empty grey item at its place and length (and
-- lane), named for what it is, holding the item's oid so the real one replaces it. Never sent (mirror.scan skips it).
function mirror.placeholder(tr, oid, state, track_name)
  local it = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", tonumber(state:match("\nPOSITION ([%d%.%-e]+)")) or 0)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", tonumber(state:match("\nLENGTH ([%d%.%-e]+)")) or 1)
  local lane = tonumber(state:match("BANDLANE (%d+)"))
  if lane then reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", lane < mirror.BAD_LANE and lane or 0) end
  reaper.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", reaper.ColorToNative(90, 90, 90) | 0x1000000)
  reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "arriving: " .. ((state:match("\nNAME ([^\n]+)") or ""):gsub('^"(.*)"$', "%1")) ..
    " (" .. (track_name or "") .. "), still syncing", true)
  reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_arriving", "1", true)
  reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", oid, true)
  reaper.UpdateItemInProject(it)
end

-- Apply one revision (an "obj" event) here. Returns true when done, false to try again later (its track or its
-- media hasn't arrived yet), and the hash now held.
-- (through JSON, as an event's was: REAPER's 0.0 reads back as 0)
local function band_json(t) local band = require("band"); return band.json_decode(band.json_encode(t)) end
-- What first differs between this machine's state and the band's, in a word for the Console: a track's setting, or the
-- first word of an item's or chain's line ("Not sent ... back as it was" never said what, so nobody could tell what moved:
-- sync engine review, 0.58.76). Pure.
function mirror.first_diff(a, b)
  if type(a) == "table" and type(b) == "table" then
    local band, keys, seen = require("band"), {}, {}
    for k in pairs(a) do if not seen[k] then seen[k] = true; keys[#keys + 1] = tostring(k) end end
    for k in pairs(b) do if not seen[k] then seen[k] = true; keys[#keys + 1] = tostring(k) end end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local x, y = a[k], b[k]
      if k == "icon" then x, y = mirror.icon_key(x), mirror.icon_key(y) end
      -- (autocolour says whether that computer colours its own tracks: never what differs. 0.59.17)
      if k ~= "autocolour" and band.json_encode(x) ~= band.json_encode(y) then return k end
    end
  elseif type(a) == "string" and type(b) == "string" then
    local la, lb = {}, {}
    for l in a:gmatch("[^\n]+") do la[#la + 1] = l end
    for l in b:gmatch("[^\n]+") do lb[#lb + 1] = l end
    for i = 1, math.max(#la, #lb) do
      if la[i] ~= lb[i] then return (((la[i] or lb[i]):match("^<?(%S+)")) or "a line"):sub(1, 24) end
    end
  end
end
-- What a track's deletion says went with it (`items`, bandmate data: at most ITEMS_MAX ids of at most 200 characters, no slashes), as a set
-- of oids; nil when it doesn't say (a StudioSync before rt-sync2b, more than ITEMS_MAX, or malformed): then the old guess applies.
mirror.ITEMS_MAX = 2000
function mirror.named_items(ev)
  local t = type(ev) == "table" and ev.items
  if type(t) ~= "table" or #t > mirror.ITEMS_MAX then return nil end
  local set = {}
  for _, x in ipairs(t) do
    if type(x) ~= "string" or #x > 200 or x:find("[/\\]") then return nil end
    set[x:upper()] = true
  end
  return set
end
-- The items a track holds here, by oid (sorted), for its deletion's `items`; nil past ITEMS_MAX (the receivers' old guess then).
function mirror.items_on(tr)
  local out = {}
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local io = itm_oid(reaper.GetTrackMediaItem(tr, i))
    if io ~= "" then out[#out + 1] = io end
  end
  if #out > mirror.ITEMS_MAX then return nil end
  table.sort(out)
  return out
end
-- An item whose newest version is this computer's, from the last two minutes: a track deleted elsewhere may have gone before it arrived there
-- (a take just recorded and sent), so it's kept here, not lost with the track. Review, 0.58.95
function mirror.just_made_here(proj, io, now_ms)
  local order = select(4, mirror.known(proj, io))
  local h, who = tostring(order or ""):match("^(%d+)|(.*)$")
  local me = reaper.GetExtState(require("band").SECTION, "user")
  return h ~= nil and me ~= "" and who == me and (now_ms or require("together").now() * 1000) - tonumber(h) < 120000
end
-- The cheap cases where mirror.receive says "later" for an incoming change (an edit of yours unsent, a chain while playing or its tab behind,
-- a track part while recording or behind, an item open in the MIDI editor): sync.receive opens no undo block for it. Opened, it closed as an
-- empty point on the pass a change first waited, and on top of REAPER's list it sent Ctrl+Z StudioSync's way. A miss costs only that point,
-- as before; one that lands after all gets its point after the pass. Cost: a few lookups per landing change. Round 3 review, 0.59.48
-- A change to something on a track the band has deleted, and not here: mirror.receive drops it before its unsent check. Cost: one known() read.
local function on_gone_track(proj, ev)
  if ev.obj == "track" or not ev.track or ev.track == mirror.MASTER then return false end
  local trev, th = mirror.known(proj, ev.track)
  if not (trev ~= nil and th == "" and not mirror.find(proj, "track", ev.track)) then return false end
  -- (not an item's deletion while the item itself is still here: moved to another track here before its old track went, it didn't go with
  -- that track, and "it went with its track" recorded it gone and left it in the project. The look then found an item the band doesn't
  -- have, couldn't put back a deletion, and asked the track's claimer for it every 90 s for good. The deletion lands. rt-converge)
  if ev.gone and ev.obj == "item" and mirror.find(proj, "item", ev.oid) then return false end
  return true
end
-- Is this computer's record of an item a change that only moved it as a tempo change does (mirror.sans_tempo), against what it built on?
function mirror.only_retimed(proj, io, room_dir)
  local _, _, kev = mirror.known(proj, io)
  local e = room_dir and (kev or "") ~= "" and mirror.event_file(room_dir, kev)
  local b = e and e.base_ev and mirror.event_file(room_dir, e.base_ev)
  return b and type(e.state) == "string" and type(b.state) == "string" and mirror.sans_tempo(e.state) == mirror.sans_tempo(b.state) or false
end
-- Is this computer's record of an item its own new work: every version back to the first this person's (a take just recorded, trimmed since)?
-- An edit of an item the band had isn't: a track's deletion made without seeing it beats it, as for any edit (the judge's deletion rule, lib/judge.lua). A version that
-- can't be read here counts as new (kept, as before). LinuxBox's move of the desktop's take, made with Live sync off, kept the deleted track as
-- "XT R1 take (yours, not sent)" (rt-linkmove round 5 C, rt-r1). rt-fix6a
function mirror.new_here(proj, io, room_dir)
  local _, _, kev = mirror.known(proj, io)
  local me = reaper.GetExtState(require("band").SECTION, "user")
  local e = room_dir and (kev or "") ~= "" and mirror.event_file(room_dir, kev)
  for _ = 1, 50 do
    if not e then return true end
    if e.user ~= me or mirror.split_merge(e.id or "") then return false end -- (a bandmate's, or merged with one)
    if not e.base_ev then return true end
    e = mirror.event_file(room_dir, e.base_ev)
  end
  return true
end
-- (putting_back: the band's version goes over this computer's own unsent one (W.put_back), so that flag doesn't hold it. The tab's published
-- unsent list still named a held deletion as Keep put it back, so the put-back opened no undo point: REAPER recheck, 0.59.49.80, round 7)
function mirror.will_wait(proj, ev, putting_back)
  -- (not on a track deleted since: receive returns before its unsent check, and a wrong "waits" left an empty point. Round 4 review, 0.59.49)
  if on_gone_track(proj, ev) then return false end
  if not putting_back and (mirror.unsent[tostring(proj) .. ev.oid] or mirror.unsent_elsewhere(proj)[ev.oid]) then return true end
  local kind = ev.obj
  if mirror.PART[kind] and not mirror.find(proj, "track", ev.track or ("T" .. ev.oid:sub(2))) then return false end -- (no track: as apply finds)
  -- (and within FX_SET_GAP of the band's last chain on it, as apply waits. Round 4 review, 0.59.49)
  if kind == "fx" then
    return reaper.GetPlayStateEx(proj) ~= 0 or reaper.EnumProjects(-1) ~= proj or
      reaper.time_precise() - (mirror.fx_set_at[tostring(proj) .. ev.oid] or -math.huge) < mirror.FX_SET_GAP
  end
  if kind == "env" or kind == "recv" or kind == "misc" then return reaper.GetPlayStateEx(proj) & 4 == 4 or reaper.EnumProjects(-1) ~= proj end
  if kind == "item" and not ev.gone and reaper.MIDIEditor_GetActive then
    local ed = reaper.MIDIEditor_GetActive()
    local tk = ed and reaper.MIDIEditor_GetTake(ed)
    if not (tk and reaper.ValidatePtr2(proj, tk, "MediaItem_Take*")) then return false end
    local it = mirror.find(proj, "item", ev.oid)
    return it ~= nil and reaper.GetMediaItemTake_Item(tk) == it
  end
  return false
end
function mirror.apply(proj, ev, media_dir, local_mix)
  mirror.applied = (mirror.applied or 0) + 1 -- (StudioSync wrote the project: lib/dawview.lua reads every track for the page again. rt-perfcut4)
  if ev.obj == "track" then mirror.order_band[tostring(proj)] = true end
  local kind, oid = ev.obj, ev.oid
  mirror.retimed_here = false -- (set where an item or automation is put on another tempo map than it was made under: mirror.on_map)
  if ev.gone and mirror.PART[kind] then
    -- a part back to "didn't exist" (a track's first plug-in undone, say): an empty one, as put_back does for misc. Gone did nothing to a
    -- part, so the chain stayed everywhere and went out again. 0.59.14, review. (Its track from its oid when the event doesn't name it;
    -- no track here: nothing to empty)
    local toid = ev.track or ("T" .. oid:sub(2))
    if not mirror.find(proj, "track", toid) then return true, "" end
    if not mirror.apply(proj, { obj = kind, oid = oid, track = toid, name = ev.name, state = "" }, media_dir, local_mix) then return false end -- (playing, or its tab behind: later)
    return true, ""
  end
  if ev.gone then
    local p = mirror.find(proj, kind == "fx" and "track" or kind, kind == "fx" and ev.track or oid)
    if p and kind == "item" then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(p), p)
    elseif p and kind == "track" then -- (auto-colour rules recolour the rest when a track goes: theirs are the band's)
      -- (your items on it the band doesn't have yet, a held or just-made recording, go to "<track> (yours, not sent)" first: deleted with the
      -- track, they were lost with no copy. Review, 0.58.92)
      local tname = select(2, reaper.GetTrackName(p))
      -- (and what Live sync holds unsent for this tab: in the panel or the Undo script mirror.unsent is empty, and a Restore deleted a held
      -- edit with its track. Round 3 review, 0.59.48)
      local elsewhere = mirror.unsent_elsewhere(proj)
      local room_dir = media_dir and media_dir:gsub("/media$", "")
      local named = mirror.named_items(ev)
      for i = reaper.CountTrackMediaItems(p) - 1, 0, -1 do
        local it = reaper.GetTrackMediaItem(p, i)
        local io = itm_oid(it)
        -- (not one whose just-sent change was only REAPER re-timing it for a tempo map that landed: nobody's work, and kept, a delete-all
        -- with a tempo change left "(yours, not sent)" tracks on the computers that had re-timed it. Cross test, James, rt)
        -- (and just made here only when it's new work of ours: an edit of the band's item made without seeing the deletion goes with it. rt-fix6a)
        -- (nor an edit of the band's item held here for the answer of the bandmate who has now deleted the track: nothing is left to answer,
        -- and it goes with the track as it would have had it gone out, where it was kept on "(yours, not sent)" for holding their claim on a
        -- track they'd deleted. An item of your own making is still kept. rt-r3, rt-converge)
        local asked = io ~= "" and mirror.asked_of[tostring(proj) .. io]
        local moot = asked and ev.user ~= nil and asked.who == ev.user and reaper.time_precise() - asked.at < 60 and mirror.known(proj, io) ~= nil
          and not mirror.new_here(proj, io, room_dir)
        if moot then mirror.unsent[tostring(proj) .. io], mirror.asked_of[tostring(proj) .. io] = nil, nil end
        -- (new work of yours the deleter never saw: a fact since the deletion names what went with it (`items`, mirror.named_items): not named
        -- there, and every version of it yours. From a StudioSync before that (or past ITEMS_MAX), the old guess: yours, from the last two
        -- minutes, not a re-time. rt-sync2 section 1, rt-sync2b)
        local mine_new = io ~= "" and mirror.known(proj, io) ~= nil
        if mine_new and named then mine_new = not named[io] and mirror.new_here(proj, io, room_dir)
        elseif mine_new then mine_new = mirror.just_made_here(proj, io) and not mirror.only_retimed(proj, io, room_dir) and mirror.new_here(proj, io, room_dir) end
        if io == "" or not mirror.known(proj, io) or ((mirror.unsent[tostring(proj) .. io] or elsewhere[io]) and not moot) or mine_new then
          -- (kept as new work only, no edit of yours waiting in it, from a deletion that doesn't name its items: noted with the version it holds,
          -- so the deleter's own deletion of that very version, which comes beside the track's, takes it after all: mirror.receive. rt-fix9.
          -- A deletion that names them never needs it: what it names went, and what it doesn't the deleter never had)
          if not named and not (mirror.unsent[tostring(proj) .. io] or elsewhere[io]) then mirror.kept_new[tostring(proj) .. io] = { it = it, ev = select(3, mirror.known(proj, io)) } end
          reaper.MoveMediaItemToTrack(it, mirror.keep_track(proj, tname))
          -- (yours now: not the band's item, and nothing waits on it, or the band's delete of it waited for good. 0.58.93)
          reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", true)
          mirror.unsent[tostring(proj) .. io] = nil
        end
      end
      local colours = mirror.track_colours(proj)
      reaper.DeleteTrack(p)
      mirror.hold_colours(proj, colours)
      -- (should the track come back (the deletion undone, a Restore), what sat on it comes back by the judge, on every computer: sync.receive
      -- judges what a track holds in the pass it comes back in (lib/evindex.lua contents). rt-sync2b)
    end
    return true, ""
  end
  if kind == "track" then
    local tr = mirror.find(proj, "track", oid)
    local made = not tr
    if not tr then
      local idx = 0 -- under the track it sat under there (or first)
      local above = ev.state.after ~= "" and mirror.find(proj, "track", ev.state.after)
      if above then idx = math.floor(reaper.GetMediaTrackInfo_Value(above, "IP_TRACKNUMBER")) end
      local colours = mirror.track_colours(proj) -- (auto-colour rules recolour the other tracks when one goes in: theirs are the band's)
      reaper.InsertTrackInProject(proj, idx, 0) -- (InsertTrackAtIndex only knows the tab in front; REAPER 7.18+)
      mirror.hold_colours(proj, colours)
      tr = reaper.GetTrack(proj, idx)
      reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", oid, true)
    end
    mirror.set_track_state(proj, tr, ev.state, local_mix)
    -- moved in the band's project: here too (REAPER reorders only in the tab in front; a tab behind keeps its order)
    -- (mirror.STAY: mirror.heal's mark on a version whose place is the one already held here. A key no event file can carry)
    if not ev[mirror.STAY] and mirror.track_state(proj, tr, local_mix).after ~= ev.state.after and reaper.EnumProjects(-1) == proj then
      local above = ev.state.after ~= "" and mirror.find(proj, "track", ev.state.after)
      if above or ev.state.after == "" then
        local sel = {}
        for i = 0, reaper.CountSelectedTracks(proj) - 1 do sel[#sel + 1] = reaper.GetSelectedTrack(proj, i) end
        reaper.SetOnlyTrackSelected(tr)
        reaper.ReorderSelectedTracks(above and math.floor(reaper.GetMediaTrackInfo_Value(above, "IP_TRACKNUMBER")) or 0, 0)
        mirror.order_landed[tostring(proj)] = reaper.time_precise() -- (its mover's order list is on its way: mirror.order_heal waits for it)
        mirror.order_moved[tostring(proj)] = true -- (and this computer says the order it has now, after the pass: sync.receive)
        reaper.SetOnlyTrackSelected(tr); reaper.SetTrackSelected(tr, false)
        for _, x in ipairs(sel) do if reaper.ValidatePtr2(proj, x, "MediaTrack*") then reaper.SetTrackSelected(x, true) end end
      end
    end
    local t = mirror.track_state(proj, tr, local_mix)
    mirror.track_seen[tostring(proj) .. oid] = t -- (as it was put in place: mirror.receive's keep_unsent)
    -- (landed, only its place in this machine's list can differ: the band's hash stands, so fingerprints agree, and it isn't
    -- "came out different". Track order can differ: PC Fight, laptop, 0.42.3)
    local h = mirror.track_hash(t, local_mix)
    if ev.hash and h ~= ev.hash and type(ev.state) == "table" and mirror.same_line(t, ev.state, local_mix) then h = ev.hash end
    if made and media_dir then mirror.bring_parts(proj, oid, media_dir, local_mix) end
    return true, h
  elseif kind == "fx" then
    local tr = mirror.find(proj, "track", ev.track)
    if not tr then return false end
    if reaper.GetPlayStateEx(proj) ~= 0 then return false end -- replacing a chain reloads plug-ins: only while stopped
    if reaper.EnumProjects(-1) ~= proj then return false end -- (see below: a track chunk waits for its tab to be in front)
    -- (not again within 5 s of the last: a second chain replaced RS5K seconds after the first had loaded its sample, and REAPER crashed in
    -- the middle of it, the sample perhaps still loading. Plug-in test, 0.59.14. Tried again on a later pass)
    local set_key = tostring(proj) .. ev.oid
    if reaper.time_precise() - (mirror.fx_set_at[set_key] or -math.huge) < mirror.FX_SET_GAP then return false end
    require("fxfiles").fetch(ev.files, media_dir, (ev.name or "") ~= "" and ev.name or "a track") -- (before the plug-ins load)
    local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
    local sync = require("sync")
    local block = (ev.state or ""):gsub("\n$", "")
    if ev.track == mirror.MASTER then -- (this machine's ReaNINJAM / SonoBus stay on its master, at the end of the chain)
      local live = mirror.fx_blocks(chunk, mirror.live_fx(tr))
      -- (without its id: REAPER gives the incoming plug-ins, which travel without ids, the ids of the old chain by
      -- position, so the live link's own id would land on the band's first plug-in too; it's found by name anyway)
      for i = #live, 1, -1 do if live[i]:match("^FXID ") then table.remove(live, i) end end
      if #live > 0 then
        block = block ~= "" and block:gsub("\n>$", "\n" .. table.concat(live, "\n") .. "\n>") or ("<FXCHAIN\n" .. table.concat(live, "\n") .. "\n>")
      end
    end
    local parm_ai = mirror.ai_lines(tr, "parm") -- (the plug-ins' automation items belong to the automation part: kept through this)
    local new = sync.chunk_set_block(chunk, "FXCHAIN", block ~= "" and block or nil)
    if new and new ~= chunk then reaper.SetTrackStateChunk(tr, new, false); mirror.set_ai(proj, tr, parm_ai, "parm"); mirror.fx_set_at[set_key] = reaper.time_precise() end
    -- (ReaInsert and ReaStream reach outside REAPER: the sender's audio interface channels, or a computer on their network. Here they
    -- play or send whatever those settings mean on this machine, so it's said, once per track. Plug-ins review, 0.58.76)
    local outside = block:match('<VST "VSTi?: (ReaInsert)') or block:match('<VST "VSTi?: (ReaStream)')
    if outside and not mirror.said_outside[tostring(proj) .. ev.oid] then
      mirror.said_outside[tostring(proj) .. ev.oid] = true
      require("band").log((ev.name or "a track") .. " has " .. outside .. ", set up for its sender's own audio interface or network: check its settings here before playing it loud")
    end
    -- the band's chain replaced this machine's translations too: put them back (they're never part of the hash)
    if select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local_fx", "", false)) ~= "" then
      reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local_fx", "", true)
      local cfg = require("band").settings()
      if cfg then pcall(require("page_plugins").apply_here, proj, cfg) end
    end
    local _, after = reaper.GetTrackStateChunk(tr, "", false)
    local skip = ev.track == mirror.MASTER and mirror.live_fx(tr) or {}
    for g in select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local_fx", "", false)):gmatch("({[^}]+})for=") do skip[g] = true end
    mirror.fx_knobs[tostring(proj) .. ev.oid], mirror.fxk_ok[tostring(proj) .. ev.oid] = nil, nil -- (its knobs are the band's now: the next look notes them)
    reaper.SetProjExtState(proj, mirror.SEC, "fxk " .. ev.oid, "") -- (and are stored once it has loaded)
    reaper.SetProjExtState(proj, mirror.SEC, "fxp " .. ev.oid, "") -- (its presets likewise: 0.59.17)
    local here = mirror.fxchain(after, skip) or ""
    -- (mirror.theirs: what the band's chain loads, as sent and as REAPER wrote it back (a path in base64 lines too short to read in the event's
    -- text shows once REAPER rewrites it), the master's too. Cost: one pattern over the chain read anyway. Security, Round 4 review, 0.59.49)
    local loads = require("fxfiles").paths(block)
    for _, p in ipairs(require("fxfiles").paths(here)) do loads[#loads + 1] = p end
    note_theirs(tr, true, loads)
    local h = mirror.fx_hash(here)
    local key = tostring(proj) .. ev.oid
    -- the band's hash stands, whatever a plug-in that loads here makes of its own saved data: read back, it differs from
    -- what was sent (Superior Drummer on the laptop), so fingerprints never agreed and whoever claimed the track re-rendered
    -- every part. What it reads as here, and for a while as it finishes loading, isn't a change.
    mirror.fx_readback[key], mirror.fx_loading[key], mirror.fx_load_knobs[key] = h, reaper.time_precise() + mirror.FX_LOAD_SECS, mirror.fx_params(tr)
    mirror.fx_quiet[key], mirror.fx_quiet_presets[key] = mirror.fx_load_knobs[key], nil
    mirror.fx_last[key], mirror.fx_doubt[key] = mirror.fx_load_knobs[key], nil -- (its knobs as it landed: mirror.receive's unseen-edit check)
    if ev.hash then h = ev.hash end
    -- (a part that arrived before its plug-ins chose its take with nothing missing, and stayed on silent notes: laptop, 0.42.4)
    local prints = require("prints")
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do pcall(prints.choose, reaper.GetTrackMediaItem(tr, i)) end
    return true, h
  elseif kind == "env" or kind == "recv" or kind == "misc" then
    local tr = mirror.find(proj, "track", ev.track)
    if not tr then return false end
    if reaper.GetPlayStateEx(proj) & 4 == 4 then return false end -- (a track chunk isn't rewritten mid-recording)
    -- a track chunk written in a tab that isn't in front breaks that project's sends (REAPER reads the receives'
    -- track positions against the tab in front; measured 7.83: "source sends 0"): it waits until this tab is in front
    if reaper.EnumProjects(-1) ~= proj then return false end
    local at, pos = {}, {}
    for i = 0, reaper.CountTracks(proj) - 1 do
      local t = reaper.GetTrack(proj, i)
      local o = not local_track(t) and trk_oid(t) or ""
      if o ~= "" then at[i], pos[o] = o, i end
    end
    local function oid_at(i) return at[i] end
    local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
    -- (automation made under another tempo map: onto its beats under the one in place, as an item is. rt-converge)
    if kind == "env" then
      local st, moved = mirror.on_map(proj, ev)
      if moved then ev = setmetatable({ state = st }, { __index = ev }); mirror.retimed_here = true end
    end
    local new = mirror.splice_parts(chunk, kind, ev.state or "", function(o) return pos[o] end, oid_at)
    if not new then return false end -- a receive's source track hasn't arrived yet
    if new ~= chunk then reaper.SetTrackStateChunk(tr, new, false) end
    if kind == "misc" then -- note names: through the API (see splice_parts)
      local have, want = mirror.note_names(chunk), mirror.note_names(ev.state or "")
      for k in pairs(have) do if not want[k] then local c, n = k:match("^(%S+) (%S+)$"); reaper.SetTrackMIDINoteNameEx(proj, tr, tonumber(n), tonumber(c), "") end end
      for k, name in pairs(want) do
        if have[k] ~= name then local c, n = k:match("^(%S+) (%S+)$"); reaper.SetTrackMIDINoteNameEx(proj, tr, tonumber(n), tonumber(c), name) end
      end
    end
    local _, after = reaper.GetTrackStateChunk(tr, "", false)
    local env, recv, misc = mirror.track_parts(after, oid_at)
    if kind == "env" then mirror.set_ai(proj, tr, ev.state or ""); env = env .. mirror.ai_lines(tr) end
    if kind == "env" and ev.track == mirror.MASTER then mirror.set_master_fxen(proj, tr, ev.state or ""); env = env .. mirror.master_fxen_line(proj, tr) end
    if kind == "recv" then mirror.set_ai(proj, tr, ev.state or "", "recv"); recv = recv .. mirror.ai_lines(tr, "recv") end
    return true, mirror.hash(kind == "env" and env or kind == "recv" and recv or misc)
  elseif kind == "item" then
    mirror.in_editor = nil -- (set below when its take is open in the MIDI editor: put_back then waits quietly)
    local tr = mirror.find(proj, "track", ev.track)
    if not tr then return false end
    for _, path in ipairs(mirror.media_needed(ev.state, media_dir)) do
      if not reaper.file_exists(path) then -- still on its way: a grey stand-in shows where it goes until it lands
        if not mirror.find(proj, "item", oid) then mirror.placeholder(tr, oid, ev.state, ev.name) end
        return false
      end
    end
    require("fxfiles").fetch(ev.files, media_dir, (ev.name or "") ~= "" and ev.name or "a track") -- (what its take plug-ins load, before they do: 0.59.14)
    local it = mirror.find(proj, "item", oid)
    -- (its take open in the MIDI editor here: rewritten under it, what's being edited there goes. Later, once it's closed or on another item.
    -- 0.59.14, review)
    if it and reaper.MIDIEditor_GetActive then
      local ed = reaper.MIDIEditor_GetActive()
      local tk = ed and reaper.MIDIEditor_GetTake(ed)
      if tk and reaper.ValidatePtr2(proj, tk, "MediaItem_Take*") and reaper.GetMediaItemTake_Item(tk) == it then mirror.in_editor = oid; return false end
    end
    -- (an item with Melodyne / ARA on a take isn't rebuilt in place from a chunk without take ids: REAPER kept one
    -- take of two (measured 7.83). A fresh item takes it whole.)
    if it and require("prints").ara_take(it) then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it); it = nil end
    if not it then it = reaper.AddMediaItemToTrack(tr)
    elseif reaper.GetMediaItem_Track(it) ~= tr then reaper.MoveMediaItemToTrack(it, tr) end
    local sel, grp = reaper.IsMediaItemSelected(it), reaper.GetMediaItemInfo_Value(it, "I_GROUPID") -- (item groups are this computer's: kept. 0.58.91)
    -- (which take plays: the sender's pick, BANDTAKE, from 0.58.85. A version from before says nothing, and this machine's own
    -- pick stays: setting the chunk put it back to the first, so an audio comp lost its pick on every update. Review, 2026-10-31)
    local active = reaper.CountTakes(it) > 1 and reaper.GetMediaItemInfo_Value(it, "I_CURTAKE")
    local lane = tonumber(ev.state:match("BANDLANE (%d+)"))
    local pick = tonumber(ev.state:match("BANDTAKE (%d+)"))
    -- (a pooled MIDI ghost copy here: out of its pool first, as the put-backs do. Given a plain <SOURCE MIDI>, its pool-mates kept an entry
    -- for it, which REAPER's MIDI code crashed on at a later tab close. 0.59.14, review)
    do
      local got, ch = reaper.GetItemStateChunk(it, "", false)
      local unpooled, n = (ch or ""):gsub("\n%s*POOLEDEVTS[^\n]*", "")
      if got and n > 0 then reaper.SetItemStateChunk(it, unpooled, false) end
    end
    -- (a colour look tried here on this item, and the band's version keeps the colour from before it: the tried colour stays on, so the try
    -- still shows, Keep still sends it and Put back still restores. The bandmate's change replaced it. Backlog 1.6, rt-p1)
    -- (on its beat under the map in place, when it was made under another: mirror.on_map. rt-converge)
    local state, moved = mirror.on_map(proj, ev)
    mirror.retimed_here = moved
    local try = require("band").colour_try(proj)
    local tried = try and try.items and try.items[select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false))]
    if tried and portable(state:match("\n(COLOR [^\n]*)") or "") == portable(tried[1] or "") then state = mirror.with_colour_line(state, tried[2] or "") end
    reaper.SetItemStateChunk(it, mirror.resolve_media(mirror.only_shared((state:gsub("BANDLANE %d+\n?", ""):gsub("BANDTAKE %d+\n?", ""))), media_dir), false)
    reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", oid, true)
    if pick then mirror.pick_take(it, pick)
    elseif active and active < reaper.CountTakes(it) then reaper.SetMediaItemInfo_Value(it, "I_CURTAKE", active) end
    if lane then reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", lane < mirror.BAD_LANE and lane or 0) end -- (events from 0.42.7 hold 255)
    require("prints").choose(it) -- notes or the print, as this machine chose (never part of what travels)
    reaper.SetMediaItemSelected(it, sel)
    if grp > 0 then reaper.SetMediaItemInfo_Value(it, "I_GROUPID", grp) end
    reaper.UpdateItemInProject(it)
    local st = mirror.item_state(it, media_dir)
    note_theirs(it, false, mirror.item_paths(st)) -- (as read back: mirror.theirs. Cost: a pattern over the state just read)
    -- (which item holds this id here, said as it's put in place and not only by the next look: one made anew (a put-back, a restore) has
    -- another GUID than the note names, and copied before the next look, neither it nor its copy was "the one this machine knew", the first
    -- in the project took the id, and where that was the copy the two swapped: the original went out as a new item and the id as "moved
    -- to where the copy is", which then met the bandmates' changes to the original. The soak's seed 8023, two items alike. rt-converge)
    local guid = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false))
    if guid ~= "" and select(2, reaper.GetProjExtState(proj, mirror.GSEC, oid)) ~= guid then reaper.SetProjExtState(proj, mirror.GSEC, oid, guid) end
    return true, mirror.item_hash(ev.track, st)
  end
  return true, ""
end

local id_span = judge.id_span
-- Two versions of an item, one started from a version over a month older than the newer of them: never merged, decided from the ids alone
-- (lib/judge.lua). MERGE_DAYS stays here: lib/trim.lua keeps history twice as long.
function mirror.too_old_to_merge(a, b) return judge.too_old_to_merge(a, b, mirror.MERGE_DAYS) end
mirror.MERGE_DAYS = 30 -- (lib/trim.lua keeps history twice as long)
mirror.merge_order = judge.merge_order -- (versions made apart as one merged version's id, in any order: lib/judge.lua)

-- ---- the judge, asked here (lib/judge.lua, rt-sync2b) ----
-- An answer may stay incomplete here (a version a walk needs isn't here yet) this long before what's missing counts as trimmed: a bound on
-- waiting, not a decision (it was merge_for's and gone_race's two minutes). When the version arrives the object is judged again, so every
-- computer ends on the same answer whatever it held meanwhile.
mirror.WAIT_MISSING = 120
mirror.missing_since = {} -- room dir \0 oid -> when its answer was first incomplete here (time_precise)
local READABLE = { track = "table" }
-- The judge's answer for object `oid` here: from its versions in the index (lib/evindex.lua), the ones given (`news`: what a receive pass read
-- for it) and what this computer holds (a merge's sides too; a version held that can't be read here stands in from its record, so nothing
-- older is put back over it, as `wins` did). Never a change too new for this version (sync.too_new), nor one in `skip` (ids refused here for
-- now, or waiting for their tempo map: sync.receive). `proj` nil: nothing held. -> judge.settled's answer, with s.oid and s.held = { rev, h,
-- id, order } from the record. Replaces wins, merge_for (and its first_seen), gone_race, beaten_by and lands_over: arrival order and how long
-- anything took decide nothing. Cost: the object's versions sorted, and a walk per leaf pair and per deletion.
function mirror.judge(proj, oid, room_dir, news, skip)
  local too_new, vs, seen = require("sync").too_new, {}, {}
  local function add(v)
    if type(v) == "table" and type(v.id) == "string" and not seen[v.id] and not (skip and skip[v.id]) and v.oid == oid and type(v.rev) == "number"
        and not (v.type ~= nil and too_new(v)) then
      seen[v.id] = true
      vs[#vs + 1] = v
    end
  end
  for _, v in ipairs(news or {}) do add(v) end
  for _, v in ipairs(require("evindex").versions(room_dir, oid)) do add(v) end
  local held = {}
  if proj then
    local krev, kh, kev, kord = mirror.known(proj, oid)
    held = { rev = krev, h = kh, id = kev, order = kord }
    local function flat(id, depth)
      if type(id) ~= "string" or id == "" or depth > 12 or seen[id] then return end
      local w, l = mirror.split_merge(id)
      if w then flat(w, depth + 1); flat(l, depth + 1); return end
      local v = mirror.event_file(room_dir, id)
      if v then add(v)
      elseif id == kev and not (skip and skip[id]) then -- (its file not readable here: what it was, from the record)
        -- (held as absent here, a deletion (or gone with its track): it counts as one, so an edit made without seeing it doesn't bring the
        -- thing back while its file is on its way (the soak's seed 8059: heal undid a deletion that had come over the link))
        local ms, who = judge.order_parts(kord)
        add({ type = "obj", obj = mirror.KIND[oid:sub(1, 1)], oid = oid, id = id, rev = krev or 0, hlc = ms > 0 and ms or nil, user = who, stub = true,
          gone = kh == "" or nil })
      end
    end
    flat(kev, 0)
  end
  local opt, rd = { mergeable = mirror.mergeable, days = mirror.MERGE_DAYS }, mirror.reader(room_dir)
  local s
  local function settle()
    for _ = 1, 4 do -- (an answer whose state can't be read as its kind's is left out, and the rest judged again)
      s = judge.settled(vs, rd, opt)
      local v = s.v
      if not (v and not v.gone and not v.stub and type(v.state) ~= (READABLE[v.obj] or "string")) then break end
      for i = #vs, 1, -1 do if vs[i].id == v.id then table.remove(vs, i) end end
    end
    -- (a version held here and present, unreadable just now, beside another leaf: it can't be merged or weighed, so nothing lands over it
    -- until it reads (as heal's "ahead" kept it), or until it's given up on)
    if s.complete and not opt.give_up and #s.leaves > 1 then
      for _, v in ipairs(vs) do
        if v.stub and not v.gone then
          for _, id in ipairs(s.leaves) do if id == v.id then s.complete, s.v, s.gone, s.missing = false, nil, nil, { v.id } end end
        end
      end
    end
  end
  settle()
  local key = room_dir .. "\0" .. oid
  if s.complete then mirror.missing_since[key] = nil
  else
    local now = reaper.time_precise()
    local t0 = mirror.missing_since[key] or now
    mirror.missing_since[key] = t0
    if now - t0 >= mirror.WAIT_MISSING then opt.give_up = true; settle() end
  end
  s.oid, s.held = oid, held
  return s
end
-- Does the answer change anything here: another version than the one held, or the one held but not in place (recorded gone with its track,
-- and the track is here: a part or item comes back with it; `force`: an item a track that came back in this pass holds, and isn't here)?
function mirror.lands(proj, s, force)
  local v = s and s.complete and s.v
  if not v or v.stub then return false end
  local _, kh, kev = mirror.known(proj, s.oid or v.oid)
  if kev ~= v.id then return true end
  if v.gone then return false end
  if kh == "" then return not on_gone_track(proj, v) end
  -- (an item its returning track held, deleted with the track in REAPER since no look recorded it gone: back with the track)
  return force == true and v.obj == "item" and mirror.find(proj, "item", s.oid) == nil and not on_gone_track(proj, v)
end
-- An item landing in a lane resets which lanes play: the track's own settings go back on top (a merged item too: review, 0.58.47).
local function lanes_back(proj, ev, media_dir, local_mix)
  if not ev.track then return end
  if mirror.unsent[tostring(proj) .. ev.track] then return end -- (a change of yours not sent yet, held or settling: kept. Sync engine review, 0.58.76)
  local tr = mirror.find(proj, "track", ev.track)
  local krev, _, kev, kord = mirror.known(proj, ev.track)
  if tr and krev then
    local tev = kev ~= "" and mirror.event_file((media_dir:gsub("/media$", "")), kev)
    -- (through event_file, which finds a side room's in its main room; and when it can't be read, nothing is remembered: the reset lane plays
    -- were taken for the band's and the comp played the wrong lane here. Review, 0.58.92)
    if kev ~= "" and type(tev) ~= "table" then return end
    if type(tev) == "table" and type(tev.state) == "table" then mirror.set_track_state(proj, tr, tev.state, local_mix) end
    local t = mirror.track_state(proj, tr, local_mix)
    remember(proj, ev.track, krev, mirror.track_hash(t, local_mix), kev, kord)
  end
end

-- (a plug-in chain landed: its track's parts pick again, so one with a plug-in you don't have plays its print on Auto, not the dry take
-- through a plug-in that isn't there. It waited for that part's next change. James, 0.59.13)
local function fx_landed(proj, ev)
  local tr = mirror.find(proj, "track", ev.track)
  if tr then
    local prints = require("prints")
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do prints.choose(reaper.GetTrackMediaItem(tr, i), true) end
    prints.hold_fx(tr) -- (once for the track, not once per item: review, 0.59.14)
  end
end
-- A bandmate's track change `x` about to land: the settings changed here and not sent yet, against the band's version as this computer holds
-- it (mirror.track_seen), are kept over it where it doesn't change them itself. The record is then the band's version, under the band's
-- hash, so the next look finds the track changed and sends yours built on theirs: both stand. Not the settings a bandmate's live move is
-- showing on the track (lib/controllers.lua): those are theirs. A rename, a colour or a mute made in the same moment as a bandmate's fader
-- move was lost under it, on the renamer's computer too, with no line: the band's version, built on the old settings, replaced the track
-- whole (rt-r4 check 4, rt-r5 check 1, 4 of 4). rt-fix9's first answer held the band's change back while the track read otherwise than the
-- last look had read it; but the fader move's live preview stops that look sending the track (mirror.previewing), so the look read the rename,
-- recorded it as seen and never sent it, and the band's change then landed whole; and where the preview's own value was the difference, the
-- band's change waited behind it until the preview gave up and put the fader back (rt-r5's 27 s, "put back" before it landed). Kept here, no
-- local change waits on the order the look and the receive run in, and nothing waits on a look at all. -> what to put in place, and the hash
-- to record when something was kept (else nil). rt-fix9
local TRACK_OWN = { after = true, parent = true, solo = true, autocolour = true } -- (its place, its parent, each person's own solo)
local PREVIEWED = { vol = true, pan = true, mute = true }
local function same_setting(a, b)
  local x, y = tonumber(a), tonumber(b)
  if x and y then return math.abs(x - y) <= 1e-6 * math.max(1, math.abs(x)) end
  return tostring(a) == tostring(b)
end
local function keep_unsent(proj, x, local_mix)
  if x.obj ~= "track" or x.gone or type(x.state) ~= "table" then return x, nil end
  local key = tostring(proj) .. x.oid
  local base = mirror.track_seen[key]
  local tr = type(base) == "table" and mirror.find(proj, "track", x.oid)
  if not tr then return x, nil end
  local cur, pv = mirror.track_state(proj, tr, local_mix), mirror.previewing[key]
  local shown = type(pv) == "table" and pv or pv and PREVIEWED or {} -- (the settings a live move shows: lib/controllers.lua names them)
  local full
  for k, v in pairs(cur) do
    if not TRACK_OWN[k] and not shown[k] and not same_setting(v, base[k]) and same_setting(x.state[k], base[k]) then
      if not full then full = {}; for k2, v2 in pairs(x.state) do full[k2] = v2 end end
      full[k] = v
    end
  end
  if not full then return x, nil end
  return setmetatable({ state = full }, { __index = x }), mirror.track_hash(x.state, local_mix)
end
-- An incoming change (sync.receive, through sync.apply): what its object is now by the judge (mirror.judge: this change, `more` (the object's
-- other changes read in this pass), its other versions here and what's held), put in place when that differs from what's held. `s`: the
-- answer, when the caller asked already (sync.receive asks first, for its undo point); `ev` may then be nil. `force`: put the answer in place
-- even where the record names it (what a track that came back holds). -> true when handled (put in place, or nothing to change), false to
-- try again later: the answer is incomplete, or a wait of this object's own (an edit here not sent yet, its track or media not here yet,
-- playing, its tab behind, the MIDI editor). rt-sync2b
function mirror.receive(proj, ev, media_dir, local_mix, me, more, s, force)
  local news = {}
  for _, x in ipairs(ev and { ev } or {}) do news[#news + 1] = x end
  for _, x in ipairs(more or {}) do if x ~= ev then news[#news + 1] = x end end
  for _, x in ipairs(news) do
    if x.obj == "fx" and x.restless then mirror.restless_load(); mirror.restless_add(x.restless) end
    mirror.hlc_seen(x.hlc)
  end
  local room_dir = media_dir:gsub("/media$", "")
  s = s or mirror.judge(proj, ev.oid, room_dir, news)
  -- (mirror.dropped: handled but nothing changed here, so sync.receive doesn't log "<who>: changed an item on X" for it. Cross test, James, rt)
  mirror.dropped = true
  if not s.complete then return false end
  if not mirror.lands(proj, s, force) then return true end
  local land = s.v
  local oid = s.oid
  local order = mirror.order_of(land)
  local merging = mirror.split_merge(land.id) and land or nil
  -- (what would be put in place: a merged version sits on its winner's track, which may not be this change's. Asked of the change alone, a
  -- merge whose winner sat on a deleted track was tried every pass for good, "its track hasn't arrived": a computer catching up kept
  -- "Receiving 2" and never took the studio's track order, which waits for nothing to be pending. The soak's late joiner, seed 7051. rt-converge)
  mirror.dropped = land.gone ~= true and on_gone_track(proj, land)
  -- (on a track the band has deleted since: nothing to apply it to, ever. Waiting for it kept "still to come" above
  -- 0 for good: review, 2026-10-31. Before the unsent check below: a flag
  -- left on a part of a deleted track held this back for good. 0.59.14, review)
  if on_gone_track(proj, land) then
    -- (unless the track comes back: then what it holds is judged again in that pass, sync.receive (Laptop, 0.34.8: a fresh song lost Keys'
    -- items). rt-sync2b)
    -- (an item's own deletion is recorded though: it went with its track, and every computer then holds the same deletion, whichever came first)
    -- (and nothing of yours waits on it any more: a deletion of yours held for a claimer's answer, or an edit that went with the track, left
    -- its flag on, which only a look at an object still recorded here takes off (W.gone), and the item's return then waited behind it for
    -- good, on this computer alone. The soak's seed 5045. rt-converge)
    if land.gone then remember(proj, oid, land.rev, "", land.id, order); mirror.unsent[tostring(proj) .. oid] = nil end
    -- (an item of yours kept on "(yours, not sent)" when the band deleted its track, as new work they might not have had: this is their
    -- deletion of the very version you hold, so they had it, saw it, and deleted it with the track. It goes, and so does the kept track if
    -- nothing else is on it. A Redo's item, deleted with its track 21 s after it reached the deleter, stayed on the redoer's computer alone
    -- (rt-r6's H). An edit of yours made since, or a version they never had, stays kept. rt-fix9)
    local kn = land.gone and land.obj == "item" and mirror.kept_new[tostring(proj) .. oid]
    if kn then
      mirror.kept_new[tostring(proj) .. oid] = nil
      if kn.ev ~= nil and land.base_ev == kn.ev and reaper.ValidatePtr2(proj, kn.it, "MediaItem*") and select(2, reaper.GetSetMediaItemInfo_String(kn.it, "P_EXT:band_oid", "", false)) == "" then
        local ktr = reaper.GetMediaItem_Track(kn.it)
        reaper.DeleteTrackMediaItem(ktr, kn.it)
        if reaper.CountTrackMediaItems(ktr) == 0 and mirror.local_track(ktr) then reaper.DeleteTrack(ktr) end
      end
    end
    -- (and an item moved onto that track by someone who hadn't the deletion yet, still here on the track it came from: it went with the track
    -- it was moved to, as it did on its mover's computer when the deletion landed there. Left where it was, it stayed on every computer but
    -- the mover's. Recorded gone with its track under this version, so it comes back, on that track, if the track does (mirror.heal). One
    -- of yours not sent yet is kept on "(yours, not sent)" instead. The soak's seed 103. rt-converge)
    -- (recorded so whether or not the item is here yet: its earlier versions may land after this one (Syncthing brings files in any order,
    -- and a version waits for its audio), and with nothing recorded the earlier one landed as the newest: the item on its old track on this
    -- computer, gone with the deleted track on the others. The soak's seed 5010. rt-converge)
    if land.obj == "item" and not land.gone then
      local it = mirror.find(proj, "item", oid)
      local key = tostring(proj) .. oid
      if it then
        if mirror.unsent[key] or mirror.unsent_elsewhere(proj)[oid] then
          reaper.MoveMediaItemToTrack(it, mirror.keep_track(proj, select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(it)))))
          reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", true)
        else reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it) end
        mirror.dropped = false
      end
      mirror.unsent[key] = nil
      remember(proj, oid, land.rev, "", land.id, order)
    end
    -- (and a track's part, its plug-ins, automation or sends: its newer version is recorded too, gone with the track under that version.
    -- A returning track brings each part back as this computer's record names it (mirror.bring_parts); with nothing recorded for a change
    -- that arrived while the track was away, that was the version before, and a plug-in a bandmate had taken off just as the track was
    -- deleted was back on this computer alone once the deletion was undone. The soak's long run, seed 11013. rt-converge)
    if mirror.PART[land.obj] and not land.gone then remember(proj, oid, land.rev, "", land.id, order) end
    return true
  end
  -- a change of ours to it hasn't gone out yet (plug-ins and automation waiting to settle or
  -- for playback to stop, a long edit): theirs waits until ours has gone, then the two are settled like any clash.
  -- Applied at once, ours was lost with no trace, not even on the Restore page (review, 2026-10-31).
  -- (watch marks those: comparing hashes here also caught what applying the band's last change had changed as a
  -- side effect, like a frozen track's items, and held it back for good)
  -- (Live sync's own unsent, as it publishes it, too: "Bring into main" lands through here in the panel, whose table is empty. Round 2, 0.59.46)
  -- (and a plug-in's knob turned here that no look has seen yet: a script's, a control surface's or automation's write moves neither REAPER's
  -- change count nor its undo list, so Live sync's "a look first" gate didn't hold the band's chain back; it replaced this one, the knob's
  -- new value with it, and the edit was gone on every computer with no line anywhere (P1-4 and P1-1's first try, rt-r2). The knobs as the
  -- chain last landed here or went out from here (mirror.fx_last) against now: moved, it may be an edit of yours not sent yet, and theirs
  -- waits for the next look to say (it sends yours, or finds nothing changed and takes the knobs as they are: W.one). rt-converge)
  if land.obj == "fx" and not land.gone then
    local key = tostring(proj) .. oid
    local tr = not mirror.unsent[key] and mirror.fx_last[key] ~= nil and mirror.find(proj, "track", land.track)
    -- (not where no plug-in is here: none has a knob to turn. The chain had gone with its track, or by the band's deletion, with the knobs
    -- of its last landing still noted; that read as "moved", and no look settles a chain recorded gone, so the band's new chain for the
    -- track waited behind the doubt for good, on this computer alone. The soak's seed 5008. rt-converge)
    local knobs = tr and mirror.fx_params(tr)
    if tr and knobs ~= "" and mirror.fx_last[key] ~= knobs then mirror.unsent[key], mirror.fx_doubt[key], mirror.unsettled = true, true, true end
  end
  if mirror.unsent[tostring(proj) .. oid] or mirror.unsent_elsewhere(proj)[oid] then return false end
  -- (an item of yours held back (its audio couldn't be copied, its last version unreadable) is about to be replaced by the band's: a copy goes to
  -- "(yours, not sent)" first, as a refusal keeps one; it went with no copy. Only for held-back items. Round 2 review, 0.59.46)
  -- (once per item and band version, as W.put_back's copy_key: a retry while the band's audio still arrived made a copy every pass. Its mark goes
  -- only once a copy is made; with none (the copy failed) the band's version waits, rather than replace the only one. Round 3 review, 0.59.48)
  -- (and by the item's state now, its mark kept until the band's version lands: one that waited after the copy (its audio on the way, the part
  -- open in the MIDI editor) and was edited meanwhile was replaced with no copy of that edit. Cost: one chunk read and hash per such receive,
  -- held-back items only. Data safety, Round 4 review, 0.59.49)
  local hb = mirror.held_back[tostring(proj)]
  local held = hb and hb[oid] and land.obj == "item"
  if held then
    local it = mirror.find(proj, "item", oid)
    local key = it and (tostring(proj) .. oid .. "\0held " .. tostring(land.id) .. "\0" .. mirror.hash(select(2, reaper.GetItemStateChunk(it, "", false))))
    if key and not mirror.copied[key] then
      if not mirror.keep_item_copy(proj, it) then return false end
      mirror.copied[key] = true
    end
  end
  -- (a track's change moves the track only when its place is what it changes, against the version held here, as mirror.heal lands one: every
  -- track change carries the place its track had where it was made, so a bandmate's rename of Drums, landing after your own move of Gtr above
  -- it, put Drums back on top here and nowhere else, until the order heal two minutes later. The soak's bug 6. A change that says it is a
  -- move (`moved`, W.send) always places: a track dragged back under the one its record names reads the same there. rt-converge)
  -- (and only a move: the place a change names is where its track sat on its sender's computer, which follows whatever landed there; a
  -- fader moved on a computer whose order had drifted moved the track on everyone else's, away from the studio's order list. mirror.says_move)
  local function placed(x)
    if x.obj ~= "track" or x.gone or type(x.state) ~= "table" then return x end
    local _, kh, kev = mirror.known(proj, x.oid)
    if (kev or "") == "" or kh == "" or mirror.says_move(room_dir, x, kev) then return x end
    return setmetatable({ [mirror.STAY] = true }, { __index = x })
  end
  if merging then
    local land, band_h = keep_unsent(proj, merging, local_mix)
    local ok, h = mirror.apply(proj, placed(land), media_dir, local_mix)
    if ok and held then hb[oid] = nil end
    if ok and band_h then h = band_h; mirror.track_seen[tostring(proj) .. oid] = merging.state end
    if ok then
      remember(proj, oid, merging.rev, h, merging.id, mirror.order_of(merging))
      if merging.obj == "item" then
        require("sync").landed_media = true
        lanes_back(proj, merging, media_dir, local_mix)
      end
      local lost, on = merging.loser, (merging.name or "") ~= "" and merging.name or "an unnamed track"
      -- (what was merged, in words: an item, a track's settings, its automation. rt-merge)
      local what = merging.obj == "track" and ("track " .. on) or merging.obj == "env" and ("the automation on " .. on) or merging.obj == "fx" and ("the plug-ins on " .. on) or ("an item on " .. on)
      local takes = false
      for _, key in ipairs(merging.clashed or {}) do takes = takes or (key:find("<SOURCE", 1, true) ~= nil and not key:find("\0notes", 1, true)) end
      -- (nothing said where your side was only your tempo change's move: you changed nothing of it. rt-fix9)
      local only_map = lost and lost.user == me and merging.l_retimed or merging.user == me and merging.w_retimed
      if only_map then
      elseif lost and me and lost.user == me and #(merging.clashed or {}) > 0 then -- (only what you both changed is theirs; Use mine brings all of yours back)
        require("sync").put_back(string.format("%s changed the same thing as you on %s: %s, and the rest of your change is in", tostring(merging.user), what,
          takes and "their take plays, and yours is kept as another take on it" or "theirs stands where you both changed it"), { oid = oid, ev = lost.id, name = merging.name })
      elseif me and (merging.user == me or (lost and lost.user == me)) then
        require("band").log(string.format("%s changed %s as you did, at the same time: both changes are kept", tostring(merging.user == me and lost and lost.user or merging.user), what))
      end
      if merging.obj == "fx" then fx_landed(proj, merging) end -- (a merged chain picks its track's prints as any chain does. rt-p1)
    end
    return ok
  end
  -- both changed it while apart: theirs wins everywhere (the same on every machine); ours stays in History
  local krev, _, kev = mirror.known(proj, oid)
  -- (sync.is_mine, not the name as a prefix: "James" took "James-Laptop"'s changes for its own, and said you both changed it. James, 0.58.82)
  if me and krev and land.base and land.base < krev and require("sync").is_mine(kev, me) then
    -- (within seconds of each other it was a race, not time apart: "while you were apart" read wrong, laptop round 2)
    local function secs(y, mo, d, h, mi, s) return y and os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s }) end
    local mine = secs(kev:match("%-(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z"))
    local theirs = secs((land.time or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"))
    local race = mine and theirs and math.abs(mine - theirs) <= 10
    require("sync").put_back(string.format("%s also changed %s %s: theirs is in.", tostring(land.user), (land.name or "") ~= "" and ("something on " .. land.name) or "the same thing",
      race and "at the same moment as you" or "while you were apart"), { oid = oid, ev = kev, name = land.name })
  end
  local midiview = land.obj == "item" and not land.gone and require("midiview")
  if midiview and not (midiview.on() and midiview.recent(land.time)) then midiview = nil end
  local notes_before = midiview and midiview.notes(mirror.find(proj, "item", oid))
  local put, band_h = keep_unsent(proj, land, local_mix)
  local ok, h = mirror.apply(proj, placed(put), media_dir, local_mix)
  if ok and held then hb[oid] = nil end
  if ok and band_h then h = band_h; mirror.track_seen[tostring(proj) .. oid] = land.state end
  if ok then remember(proj, oid, land.rev, h, land.id, order) end
  if ok and land.obj == "item" then require("sync").landed_media = true end -- (Live sync builds its peaks, if nothing else will)
  if ok and midiview then midiview.show(proj, mirror.find(proj, "item", oid), notes_before) end
  -- applied, but it isn't what they have: the projects differ (only when made the same way: a change from an older
  -- StudioSync hashed fewer of a track's settings, so it always reads as different; the laptop saw 4 on its first open)
  -- (nor when the colour counts on one machine and not the other: SWS auto-colouring)
  local same_way = land.obj ~= "track" or type(land.state) ~= "table" or (land.state.autocolour == true) == (mirror.own_colours() == true)
    and (land.local_mix == true) == (local_mix == true) -- (nor when one has Local mixing on and the other not: their faders count differently. 0.59.14)
  -- (nor when it was put on another tempo map than it was made under: it reads as it should here, not as it did there. rt-converge)
  if ok and land.hash and land.hv == mirror.HV and same_way and h ~= land.hash and not land.gone and not mirror.retimed_here and not band_h then
    local band = require("band")
    local n = (tonumber(reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(proj))) or 0) + 1
    reaper.SetExtState(band.SECTION, "mirror drift " .. tostring(proj), tostring(n), false)
    reaper.SetExtState(band.SECTION, "mirror drift last", oid .. " here " .. tostring(h) .. " theirs " .. land.hash, false) -- (for a bug report)
    local where = (land.name or "") ~= "" and land.name or "an unnamed track"
    band.log(string.format("%s's change to %s came out different here than on their machine (the panel's Health shows it)", tostring(land.user),
      mirror.PART[land.obj] and (mirror.PART[land.obj] .. " on " .. where) or land.obj == "track" and ("track " .. where) or ("an item on " .. where)))
  end
  if ok and land.obj == "item" then lanes_back(proj, land, media_dir, local_mix) end
  if ok and land.obj == "fx" and not land.gone then fx_landed(proj, land) end
  return ok
end

-- (a side room starts as a copy: what hasn't changed in it last changed in the room it came from. Looked for only here, a chain
-- that merely reads differently on this machine went out as a change, and opening a room printed 16 parts again: Mac, 0.42.27)
local room_parent = {}
local plain_cache, plain_n = {}, 0 -- room dir \0 id -> the event (events never change: the walks below read the same ones over and over)
local function plain_event(room_dir, evid)
  if not evid or evid == "" then return nil end
  local key = room_dir .. "\0" .. evid
  if plain_cache[key] then return plain_cache[key] end
  local band = require("band")
  -- (or the direct link's inbox copy, until Syncthing's is here: lib/direct.lua. James, 0.60.0-rt)
  local ev = band.read_json(require("direct").path(nil, room_dir .. "/events", evid .. ".json"))
  if not ev then
    room_parent[room_dir] = room_parent[room_dir] or (band.read_json(room_dir .. "/room.json") or {}).parent -- (it may not have synced here yet: not noted as none)
    ev = room_parent[room_dir] and plain_event((room_dir:gsub("[^/]+$", (room_parent[room_dir]:gsub("%%", "%%%%")))), evid) or nil
  end
  if type(ev) == "table" then
    if plain_n > 20000 then plain_cache, plain_n = {}, 0 end -- shortcut: a whole flush past 20,000 events, enough for any song's working set
    plain_cache[key], plain_n = ev, plain_n + 1
  end
  return ev
end
-- A merged version of an item (mirror.merge_item) has the id "m(<winner>&<loser>)" (either may be one itself). It's nowhere on disk: every computer
-- rebuilds it the same way from the two events and the version both came from, so all agree with nobody sending it.
-- -> it like an event (the winner's fields; rev, base, state its own), or nil when an event or a base (base_ev: 0.58.43 on) isn't there.
mirror.merge_id, mirror.split_merge = judge.merge_id, judge.split_merge
-- Ancestry, read from a room's versions (lib/judge.lua: descends, apart, common_base): true, false, or nil while a version on the way isn't here.
local function reader(room_dir) return function(id) return mirror.event_file(room_dir, id) end end -- (and true when a merge's side or base isn't here)
mirror.reader = reader
function mirror.descends(room_dir, v, of, of_hlc) return judge.descends(reader(room_dir), v, of, of_hlc) end
function mirror.apart(room_dir, a, b) return judge.apart(reader(room_dir), a, b) end
local parents = judge.parents
local function common_base(room_dir, a, b) return judge.common_base(reader(room_dir), a, b) end
local merged = {} -- room dir \0 id -> the version (events never change, so neither do their merges)
local function event_file(room_dir, evid, depth)
  local w_id, l_id = mirror.split_merge(evid)
  if not w_id then return plain_event(room_dir, evid) end
  local key = room_dir .. "\0" .. evid
  if merged[key] then return merged[key] end
  depth = (depth or 0) + 1
  if depth > 12 then return nil end
  local w, w_lost = event_file(room_dir, w_id, depth)
  local l, l_lost = event_file(room_dir, l_id, depth)
  -- (a side that is itself a merge with a version not here yet: the judge waits for it. One that can't be built at all (its sides share only a
  -- deletion, say) is no merge, not one on its way: taken for missing, the judge waited on it for good. rt-sync2b)
  if not (w and l) then return nil, (w_lost or l_lost) or nil end
  if not (mirror.mergeable(w) and mirror.mergeable(l) and w.obj == l.obj) then return nil end
  local base_id, missing = common_base(room_dir, w, l)
  -- (a version one of them builds on isn't here yet, so where the two meet can't be told: no merge for now, and none remembered. With "the
  -- older of their two bases" in its place a computer that had a change before the change it was built on (the link ahead of Syncthing) put
  -- the two together from the wrong version, kept that for good, and held a merge of the same name as everyone else's with other notes in
  -- it: nothing ever compared them again. The soak's seed 43. The judge waits for it, as for a change in between: incomplete. rt-converge, rt-sync2b)
  if not base_id and missing then mirror.base_missing = true; return nil, true end
  if not base_id then -- (no shared past here: the older of their two bases, as before 0.58.47)
    local older = w
    if (l.base or 0) < (w.base or 0) or ((l.base or 0) == (w.base or 0) and (l.base_ev or "") < (w.base_ev or "")) then older = l end
    base_id = older.base_ev
  end
  local b = base_id and event_file(room_dir, base_id, depth)
  if not b and base_id then return nil, true end
  if not (b and type(b.state) == type(w.state)) then return nil end
  local v = {}
  for k, x in pairs(w) do v[k] = x end
  -- (made under different tempo maps: all three on the winner's first (the merge is then on that map, and says so: v.tm is the winner's).
  -- Merged as their seconds stood, the side REAPER had moved for the map "changed its place" and the other's move was lost, or both read as
  -- changing it. From the versions alone, so every computer builds the same merge. rt-converge)
  local bs, ws, ls = b.state, w.state, l.state
  if (w.obj == "item" or w.obj == "env") and map_ok(w.tm) then
    local moved_b, moved_l
    bs, moved_b = mirror.state_on(b, w.tm, w.tb)
    ls, moved_l = mirror.state_on(l, w.tm, w.tb)
    if moved_b or moved_l then ws, ls = mirror.snap_to(ws, bs), mirror.snap_to(ls, bs) end
  end
  -- (a side that is only the map's move of the version both came from (`retimed`, W.send) brings nothing of its own: the merge is the other
  -- side's, on the winner's map. Against a version from before maps were named, its moved timing read as a change of its own: the other's move
  -- "clashed", "theirs stands where you both changed it" was said on the computer that had only changed the tempo (rt-r4 check 1), and where
  -- the map's side won, the hand's move was lost. rt-fix9)
  -- (only where that side builds straight on that version: one on a change of its own made since keeps that change)
  local only_w = w.retimed and not l.retimed and w.base_ev == base_id
  local only_l = l.retimed and not w.retimed and l.base_ev == base_id
  if only_w then ws = bs elseif only_l then ls = bs end
  v.state, v.clashed = mirror.merge_state(w.obj, bs, ws, ls, l.user)
  if v.state == nil then return nil end
  -- (which track an item sits on is one more attribute, merged three-way: copied from the winner, a loser's move to another track was lost
  -- when the winner only nudged the item, and every log said "both changes are kept". Both moved it elsewhere: the winner's, a clash.
  -- rt-sync2 judge step 5; the soak's scenario item-track-merge. rt-sync2b)
  if w.obj == "item" and l.track ~= nil and l.track ~= b.track then
    if w.track == b.track then v.track = l.track
    elseif w.track ~= l.track then v.clashed = v.clashed or {}; v.clashed[#v.clashed + 1] = "\0track" end
  end
  v.retimed, v.w_retimed, v.l_retimed = nil, only_w or nil, only_l or nil -- (the merge isn't the map's move alone; which side was: mirror.receive's words)
  v.id, v.rev, v.hash, v.base, v.base_ev, v.loser = evid, math.max(w.rev or 0, l.rev or 0), nil, b.rev or 0, base_id, l
  -- (and the files the loser's plug-ins load (a sampler's sample, an impulse): their plug-in is in the merge too, and with the winner's list
  -- alone a computer that took the winner first never fetched them. rt-p1)
  if type(l.files) == "table" and #l.files > 0 then
    local all = {}
    for _, list in ipairs({ type(w.files) == "table" and w.files or {}, l.files }) do for _, x in ipairs(list) do all[#all + 1] = x end end
    v.files = all
  end
  -- (the later of the two clocks: with the winner's, a walk from a later change stopped here before reaching the loser. Review, 0.58.47)
  if tonumber(w.hlc) or tonumber(l.hlc) then v.hlc = math.max(tonumber(w.hlc) or 0, tonumber(l.hlc) or 0) end
  merged[key] = v
  return v
end
mirror.event_file = event_file
-- The name permissions use for an object (claims are by track name): its track's name.
local function perm_name(o, by_oid)
  if o.kind == "track" then return o.state.name end
  local t = by_oid[o.track]
  return t and t.state.name or ""
end

mirror.said = mirror.said or {} -- (things said once per session, not every pass)
mirror.copied = mirror.copied or {} -- proj .. oid .. event id -> a refused edit's copy was made
mirror.fx_seen = mirror.fx_seen or {} -- oid -> { hash, since }: a plug-in chain goes out once it has settled
mirror.fx_knobs = mirror.fx_knobs or {} -- oid -> its knobs when it last went out or landed (chains with a restless plug-in)
mirror.fx_alias = mirror.fx_alias or {} -- chain hash and event id -> the event's hash, if the two are the same bytes (else false)
mirror.track_alias = mirror.track_alias or {} -- track hash and event id -> the event's hash, if only the place differs (else false)
mirror.FX_LOAD_SECS = 60 -- how long after landing or opening a chain's data may change by itself, with its knobs still
-- A chain's knobs when this machine last agreed with the band about it (sent, landed and loaded, or read back), kept in the
-- project: a change made while StudioSync wasn't running read as the plug-in loading at the next open, and never went out
-- (Linux stress test, 0.58.77). Knobs not as they were left mean someone turned them.
mirror.fxk_ok = {} -- proj .. oid -> stored this session
-- A chain's plug-ins, in order (their keys): one added, removed or moved changes this; data or knobs don't.
local function plugin_keys(chain)
  local t = {}
  for _, x in ipairs(mirror.plugin_blocks(chain_lines(chain))) do t[#t + 1] = tostring(x.key) end
  return table.concat(t, "\0")
end
local function loaded(proj, rk) return reaper.time_precise() >= math.max(mirror.fx_loading[rk] or 0, mirror.first_look[tostring(proj)] or 0) end
local function knobs_as_left(proj, o, rk)
  if reaper.time_precise() < (mirror.fx_loading[rk] or 0) then return true end -- (just landed: the band's knobs, not the ones stored)
  local was = select(2, reaper.GetProjExtState(proj, mirror.SEC, "fxk " .. o.oid))
  if was ~= "" and was ~= mirror.hash(mirror.fx_params(o.ptr)) then return false end
  -- (and its presets: a preset loaded in the first minute after the project opened, with no window open and no knob moving, read as the
  -- plug-in loading and never went out. Plug-in test, 0.59.17)
  local wp = select(2, reaper.GetProjExtState(proj, mirror.SEC, "fxp " .. o.oid))
  return wp == "" or wp == mirror.hash(mirror.fx_presets(o.ptr))
end
local function knobs_agreed(proj, o, rk)
  if not o.ptr or reaper.time_precise() < (mirror.fx_loading[rk] or 0) then return end -- (still loading: once it has)
  local k = mirror.hash(mirror.fx_params(o.ptr))
  if select(2, reaper.GetProjExtState(proj, mirror.SEC, "fxk " .. o.oid)) ~= k then reaper.SetProjExtState(proj, mirror.SEC, "fxk " .. o.oid, k) end
  local pk = mirror.hash(mirror.fx_presets(o.ptr))
  if select(2, reaper.GetProjExtState(proj, mirror.SEC, "fxp " .. o.oid)) ~= pk then reaper.SetProjExtState(proj, mirror.SEC, "fxp " .. o.oid, pk) end
  mirror.fxk_ok[rk] = true
end
mirror.fx_set_at = mirror.fx_set_at or {} -- proj .. chain oid -> when a band's chain last replaced it here
mirror.FX_SET_GAP = 5 -- seconds between two of the band's chains replacing one track's here (tests that land chains back to back set 0)
mirror.fx_readback = mirror.fx_readback or {} -- chain -> what its hash reads as here, now the band's has landed
mirror.fx_loading = mirror.fx_loading or {} -- chain -> until when it may be still loading
mirror.fx_load_knobs = mirror.fx_load_knobs or {} -- chain -> its knobs at the start of that
-- When each track last had a plug-in window open, looked at once a second: a change inside a plug-in's own window often moves no knob.
mirror.fx_open_at = {}
mirror.fx_open_text = mirror.fx_open_text or {} -- chain whose data the hash can't see -> its text when a window of it was first seen open
mirror.cc_seen = {}
mirror.master_seen = {} -- project -> its master track at the last look (W.order: a file opened again in the same tab has a new one)
mirror.fx_quiet = mirror.fx_quiet or {}
mirror.fx_last = mirror.fx_last or {} -- proj .. chain oid -> its knobs when it last landed here or went out from here (mirror.receive's unseen-edit check)
mirror.fx_doubt = mirror.fx_doubt or {} -- proj .. chain oid -> true: mirror.receive held the band's chain back for a look to say whether the knobs are an edit
mirror.kept_new = mirror.kept_new or {} -- proj .. item oid -> { it, ev }: kept on "(yours, not sent)" as new work when the band deleted its track (mirror.receive)
mirror.track_seen = mirror.track_seen or {} -- proj .. track oid -> its state as the band's version is here: as it landed, went out, or a look found it unchanged (mirror.receive)
local function fx_open_now(tr)
  if reaper.TrackFX_GetChainVisible(tr) ~= -1 then return true end
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if reaper.TrackFX_GetOpen(tr, i) then return true end
    for _, sub in ipairs(mirror.fx_inside(tr, i) or {}) do if reaper.TrackFX_GetOpen(tr, sub) then return true end end -- (floated from a container)
  end
  return false
end
function mirror.note_open_fx(proj)
  if not reaper.ValidatePtr2(0, proj, "ReaProject*") then return end -- (the tab closing just now: it was an error in the log. Laptop, 0.59.37)
  local now = reaper.time_precise()
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if fx_open_now(tr) then mirror.fx_open_at[tostring(tr)] = now end
  end
end
function mirror.fx_was_open(tr)
  return fx_open_now(tr) or reaper.time_precise() - (mirror.fx_open_at[tostring(tr)] or -math.huge) < 60
end
mirror.first_look = mirror.first_look or {} -- project -> until when its chains may be still loading after it opened
mirror.order_seen = mirror.order_seen or {} -- project -> its tracks' order at the last look
mirror.order_band = mirror.order_band or {} -- project -> a band's track landed since the last look
mirror.holds = mirror.holds or {} -- project -> track oid -> { what runs through it }, as of the last look
mirror.bus_said = mirror.bus_said or {} -- track oid -> when "that changes how X sounds" was last said
mirror.tempo_until = mirror.tempo_until or {} -- project -> until when items may be moving for a tempo change
mirror.TEMPO_SECS = 15
-- `from` (optional): the tempo map before this change (band.capture_tempo's list), when it's this computer's own; the first of a burst is kept.
mirror.tempo_from = mirror.tempo_from or {} -- project -> the map items were on before the tempo change REAPER may be moving them for
function mirror.tempo_changed(proj, from)
  local pk = tostring(proj)
  if reaper.time_precise() >= (mirror.tempo_until[pk] or 0) then mirror.tempo_from[pk] = nil end
  if type(from) == "table" and not mirror.tempo_from[pk] then mirror.tempo_from[pk] = { map = from, at = os.date("!%Y-%m-%dT%H:%M:%SZ") } end
  mirror.tempo_until[pk] = reaper.time_precise() + mirror.TEMPO_SECS
end
-- Did the tempo map, not a hand, move this item from its last version (`last`, an event) to `now` (its state)? Only where this computer's own
-- map change is known (mirror.tempo_from): REAPER keeps an item on its beat, so where the old map's beat falls on the new map (mirror.retime)
-- is where the map put it; a version made after the change is already on the new map. Elsewhere: true, as before. (An item moved by hand in
-- the 15 s after a tempo change read as the map's move and didn't claim its track. Backlog 1.10, rt-p1)
-- shortcut: in a burst of tempo changes, a version made between two of them is judged against the first map: a map move then claims, as
-- before AL. Keep each change's map if REAPER checks show bursts claiming.
-- (a version that names its map, `tm`: exactly, on any computer and at any time: it's the map's move only if the map in place puts that
-- version where the item now is. Under the map it was made on, nothing moved it: any difference is an edit. A hand edit in the 15 s after a
-- bandmate's map landed was taken for REAPER's move and kept on that computer alone, silently: the soak's bug 1. rt-converge)
function mirror.map_moved(proj, last, now)
  if type(last.state) ~= "string" then return true end
  local want
  if map_ok(last.tm) then
    local moved
    want, moved = mirror.on_map(proj, last)
    if not moved then return false end
  else
    local tf = mirror.tempo_from[tostring(proj)]
    if not tf then return true end
    local to = require("band").capture_tempo(proj)
    want = last.state
    if not (type(last.time) == "string" and last.time > tf.at) then want = mirror.retime(want, tf.map, to, reaper.GetSetProjectInfo(proj, "PROJECT_TIMEBASE", 0, false)) end
  end
  for _, k in ipairs({ "POSITION", "LENGTH" }) do
    local a, b = tonumber(want:match("\n%s*" .. k .. " ([%d%.%-e]+)")), tonumber(now:match("\n%s*" .. k .. " ([%d%.%-e]+)"))
    if a and b and math.abs(a - b) > 1e-6 then return false end
  end
  return true
end
-- Does `o` (an item or automation as a look reads it) differ from the band's version `last` only as a tempo map moved it? A version that
-- names its map (`tm`) is judged exactly, whenever; one from before only in the TEMPO_SECS after a tempo change here, as before. rt-converge
function mirror.only_map_moved(proj, o, last)
  if not (last and type(last.state) == "string" and type(o.state) == "string") then return false end
  local named = map_ok(last.tm)
  if not named and reaper.time_precise() >= (mirror.tempo_until[tostring(proj)] or 0) then return false end
  if o.kind == "env" then
    return mirror.env_same_but_times(o.state, last.state) and (not named or select(2, mirror.on_map(proj, last)) == true)
  end
  -- (and on the track the band has it on: a tempo map never moves an item to another track. Moved there with its position unchanged, it read
  -- as the map's move after a tempo change, was recorded as it was and never sent: the item sat on another track on that computer alone, which
  -- the soak's oracle can't see (it hashes an item's text). Found by rt-sync2b's track check: seeds 5000, 9001, 9002, 9006)
  return o.kind == "item" and (last.track == nil or o.track == nil or last.track == o.track) and mirror.sans_tempo(o.state) == mirror.sans_tempo(last.state)
    and mirror.map_moved(proj, last, o.state)
end
-- A tempo map that wasn't made here is put in place by `set` (a bandmate's change, or the studio's map as a project opens): what REAPER moves
-- for it isn't this computer's edit. Every item and automation is read before and after; one that was as the studio has it and now differs
-- only in its timing has its record moved with it, there and then, so no look ever sees it as changed: nothing is sent, nobody is asked,
-- nothing is put back, however late the sender's own versions arrive (they land over it). By this computer's own two readings, not against
-- the event's text: LinuxBox's REAPER writes an item a little differently from the desktop's, so a compare with the sender's text failed there
-- and it asked the track's claimer to let it "edit", then put its "edit" back, eight lines at each tempo step. REAPER checks, 0.59.49.74-75,
-- rt-edits. Cost: two full reads of the project per tempo map that lands. -> how many it moved.
function mirror.map_landing(proj, user, media_dir, local_mix, set)
  local ok, objs = pcall(mirror.scan, proj, user, media_dir, local_mix)
  local before = {}
  for _, o in ipairs(ok and objs or {}) do
    if (o.kind == "item" or o.kind == "env") and type(o.state) == "string" then before[o.oid] = o end
  end
  set()
  local ok2, after = pcall(mirror.scan, proj, user, media_dir, local_mix)
  if not (ok and ok2) then return 0 end
  local n = 0
  for _, o in ipairs(after) do
    local b = before[o.oid]
    if b and b.hash ~= o.hash and b.track == o.track and type(o.state) == "string" then
      local rev, h, evid, kord = mirror.known(proj, o.oid)
      if rev and h == b.hash and (o.kind == "env" and mirror.env_same_but_times(o.state, b.state)
          or o.kind == "item" and mirror.sans_tempo(o.state) == mirror.sans_tempo(b.state)) then
        mirror.remember(proj, o.oid, rev, o.hash, evid, kord)
        n = n + 1
      end
    end
  end
  return n
end
-- The tempo map a change was made under, while REAPER may be moving things for one (TEMPO_SECS after a tempo change here): the newest map this
-- project holds, as sync.NEWEST names it. It goes on the change as `tl`, and a receiver lands the change only once it holds that map
-- (sync.receive). An item or automation that came before its map was put where the new map has it, then moved again by REAPER when the map
-- landed: lengths scaled twice on LinuxBox, and nothing put them right (REAPER check F6, rt-edits). nil outside that window.
function mirror.map_stamp(proj)
  if reaper.time_precise() >= (mirror.tempo_until[tostring(proj)] or 0) then return nil end
  local v = select(2, reaper.GetProjExtState(proj, require("sync").NEWEST, "timeline"))
  return v ~= "" and v or nil
end
-- One act, one id (rt-edits): every change a look sends carries it, and a tempo map or marker change sent just before that look
-- (sync.watch_timeline runs first) takes the id the look will use, so Undo puts the act's region or markers back with its items.
mirror.ACT_SECS = 2.5
mirror.ACT_KEEP = 70 -- seconds a look's act still takes what later looks find, while you haven't edited (a full look runs every QUICK_FULL_SECS)
-- (and past the next timed full look however far apart they are: a heavy song's are up to QUICK_FULL_MAX apart, and a part of an act only the
-- full look found came after ACT_KEEP, a second Undo step. L: the tab's look record. Backlog 1.10, rt-p1)
function mirror.act_keep(L)
  return math.max(mirror.ACT_KEEP, (L and mirror.full_every(L.full_took) or 0) + mirror.ACT_KEEP - mirror.QUICK_FULL_SECS)
end
mirror.last_act = mirror.last_act or {} -- tostring(proj) -> { act, at }: the act of the last look that sent anything, and when it looked
mirror.look_act = mirror.look_act or {} -- tostring(proj) -> { act, at }: the id a timeline change just took
local function new_act(me, now) return string.format("%s-%s-%d", require("sync").id_user(me), os.date("!%Y%m%d%H%M%S"), math.floor(now * 1000) % 1000000) end
function mirror.act_for(proj, me)
  local pk, now = tostring(proj), reaper.time_precise()
  local a = mirror.more_act[pk] or new_act(me, now)
  mirror.look_act[pk] = { act = a, at = now }
  return a
end

-- Where a recording this person wasn't allowed to add goes (kept, never deleted): a track of their own, not sent.
local function keep_track(proj, name)
  local label = (name ~= "" and name or "Track") .. " (yours, not sent)"
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)) == label and local_track(tr) then return tr end
  end
  return mirror.add_local_track(proj, label, "yours") -- (auto-colouring recoloured Keys when this track went in, on the laptop: 2026-10-31)
end
mirror.keep_track = keep_track
-- A copy of an item on its track's "(yours, not sent)": new ids, out of any pool (plain MIDI, as a pooled copy travels), no band id. -> the copy.
function mirror.keep_item_copy(proj, it)
  local got, ch = reaper.GetItemStateChunk(it, "", false)
  if not got then return nil end
  local on = select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(it)))
  local copy = reaper.AddMediaItemToTrack(keep_track(proj, on))
  if not (copy and reaper.SetItemStateChunk(copy, (ch:gsub("\n%s*POOLEDEVTS[^\n]*", ""):gsub("\n%s*I?GUID[^\n]*", ""):gsub("<SOURCE MIDIPOOL", "<SOURCE MIDI")), false)) then return nil end
  reaper.GetSetMediaItemInfo_String(copy, "P_EXT:band_oid", "", true)
  require("band").log("an item of yours on " .. on .. " that couldn't go out was replaced by the studio's version: yours is on '" .. on .. " (yours, not sent)'")
  return copy
end
-- Automation that didn't go out, kept as a file in StudioSync's folder for Restore > Kept automation (James, 0.59.39). -> the path, or nil.
local function keep_automation(oid, track, name, state, room_dir)
  local band = require("band")
  local dir = band.home() .. "/kept automation"
  reaper.RecursiveCreateDirectory(dir, 0)
  local nm = ((name or "") ~= "" and name or "a track"):gsub("[^%w%-_ ]", "")
  -- (with its id: two same-named tracks kept in one second overwrote each other. Round 1 review, 0.59.45)
  local path = dir .. "/" .. nm .. " " .. oid:gsub("[^%w%-_]", "_") .. " " .. os.date("%Y-%m-%d %H%M%S") .. ".json"
  local keep = { oid = oid, track = track or ("T" .. oid:sub(2)), name = name, state = state, room = room_dir, time = os.date("!%Y-%m-%dT%H:%M:%SZ") }
  if pcall(band.write_json, path, keep) then return path end
end
-- Kept automation put back with "Put mine back" (marked `back`, lib/page_restore.lua) goes once that automation has gone out as yours: the
-- button deleted it, and refused again it was lost for good. Cost: one folder listing per automation send. Round 1 review, 0.59.45
-- (only one whose kept state is what just went: any later automation send on that track removed it, though it never went out. Round 2 review,
-- 0.59.46. Cost: one string compare)
-- (any send of that automation from the moment it was put back (`back` holds that time, lib/page_restore.lua): by exact text, a put-back
-- envelope REAPER reads back another way, or touched again before it went, stayed listed for good. One marked before 0.59.48 (`back` true)
-- still goes by its text. Round 3 review, 0.59.48. Cost: none)
local function drop_kept_automation(oid, state, now)
  local band = require("band")
  local dir, tag = band.home() .. "/kept automation", oid:gsub("[^%w%-_]", "_")
  now = now or os.time()
  for _, f in ipairs(band.files(dir, ".json")) do
    if f:find(tag, 1, true) then
      local k = band.read_json(dir .. "/" .. f)
      if type(k) == "table" and k.oid == oid and k.back and ((type(k.back) == "number" and now >= k.back) or k.state == state) then os.remove(dir .. "/" .. f) end
    end
  end
end
mirror.drop_kept_automation = drop_kept_automation
-- A suggestion that didn't go in (declined or withdrawn): what you did to the part stays here, as a refusal keeps it. An item on a track of
-- your own ("(yours, not sent)"), automation in Kept automation. Its parts file was the only copy, and went once answered. Full review,
-- 0.59.44. -> true when something was kept.
function mirror.keep_suggested(proj, c, room_dir)
  if type(c) ~= "table" or c.gone or type(c.state) ~= "string" or c.state == "" then return false end
  if (tonumber(c.rev) or 0) == 0 then return false end -- (something new: already on '(yours, not sent)', as a refusal put it there)
  if c.obj == "item" then
    local it = reaper.AddMediaItemToTrack(keep_track(proj, c.name or ""))
    -- (only the studio's media paths, as any band version: anyone can write a parts file in the room's folder, and a path it named was put on
    -- a track of yours, then copied out by your next send. Security, Round 3 review, 0.59.48. Cost: one pattern)
    local chunk = mirror.resolve_media(mirror.only_shared((c.state:gsub("BANDLANE %d+\n?", ""):gsub("BANDTAKE %d+\n?", ""))), room_dir .. "/media")
    chunk = chunk:gsub("\n%s*POOLEDEVTS[^\n]*", ""):gsub("\n%s*I?GUID[^\n]*", ""):gsub("<SOURCE MIDIPOOL", "<SOURCE MIDI")
    reaper.SetItemStateChunk(it, chunk, false)
    reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", true)
    -- (and what its take plug-ins load recorded as theirs (mirror.theirs), as apply does: moved onto a band track, it went out as new and its
    -- take FX's file was copied into the studio. Security, Round 4 review, 0.59.49. Cost: one pattern, at that click)
    note_theirs(it, false, mirror.item_paths(chunk))
    return true
  elseif c.obj == "env" then
    return keep_automation(c.oid, c.track, c.name, c.state, room_dir) ~= nil
  end
  return false
end
-- A track of this machine's own (never mirrored) at the end, with the band's colours held.
-- Keep selected tracks local (power-user review, 0.58.62): a track of your own that never goes to the others (a reference mix, a guide, a
-- scratch idea). Only a track that hasn't gone out yet: a shared one made local would read as deleted, for everyone. When every one given
-- is local this way already, they're shared again (sent as new). -> how many changed, how many were shared already (left alone), and
-- true when they were made local, false when shared again.
function mirror.keep_local(proj, tracks)
  local key = "P_EXT:band_local"
  local all_kept = #tracks > 0
  for _, tr in ipairs(tracks) do if select(2, reaper.GetSetMediaTrackInfo_String(tr, key, "", false)) ~= "kept" then all_kept = false end end
  local n, shared, helpers = 0, 0, 0
  local given = {}
  for _, tr in ipairs(tracks) do given[tr] = true end
  -- (a folder's tracks would still go out naming a parent nobody else has, and land in the wrong place for everyone: the folder only
  -- with all its tracks. Review, 0.58.67)
  local function whole_folder(tr)
    if reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") ~= 1 then return true end
    local proj_tr = reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")
    local depth, i = 1, math.floor(proj_tr) -- (IP_TRACKNUMBER is 1-based: index i is the track after the folder)
    while depth > 0 do
      local c = reaper.GetTrack(proj, i)
      if not c then break end
      if not given[c] and not local_track(c) then return false end
      depth = depth + reaper.GetMediaTrackInfo_Value(c, "I_FOLDERDEPTH")
      i = i + 1
    end
    return true
  end
  for _, tr in ipairs(tracks) do
    if all_kept then reaper.GetSetMediaTrackInfo_String(tr, key, "", true); n = n + 1
    elseif local_track(tr) then helpers = helpers + 1
    elseif not whole_folder(tr) then shared = shared + 1
    else
      local oid = trk_oid(tr)
      local _, h = mirror.known(proj, oid)
      if oid ~= "" and (h or "") ~= "" then shared = shared + 1
      else reaper.GetSetMediaTrackInfo_String(tr, key, "kept", true); n = n + 1 end
    end
  end
  return n, shared, not all_kept, helpers
end
function mirror.add_local_track(proj, name, tag)
  local colours = mirror.track_colours(proj)
  local idx = reaper.CountTracks(proj)
  reaper.InsertTrackInProject(proj, idx, 0)
  local tr = reaper.GetTrack(proj, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", tag, true)
  mirror.hide_helper(tr, tag)
  mirror.hold_colours(proj, colours)
  return tr
end
-- StudioSync's own working tracks stay out of sight (James, 0.59.7: "can see the extra tracks at the bottom"; 0.58.99: no visible track
-- for anyone's mic unless invisible). Hidden tracks still play, monitor and feed SonoBus. Older projects' are hidden as they're found.
mirror.HELPERS = { realtime = true, talk = true, talkback = true, click = true, hop = true } -- (hop: a live hop's hidden track, lib/hops.lua)
function mirror.hide_helper(tr, tag)
  if not mirror.HELPERS[tag] then return end
  if reaper.GetMediaTrackInfo_Value(tr, "B_SHOWINTCP") ~= 0 or reaper.GetMediaTrackInfo_Value(tr, "B_SHOWINMIXER") ~= 0 then
    reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 0)
    reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 0)
    reaper.TrackList_AdjustWindows(false)
  end
end
-- The band's track colours (by REAPER GUID), as they are before a track goes in or out: auto-colour rules recolour
-- the rest then, and again a moment later, so mirror.hold_colours puts them back for 5 s. The hold is kept in
-- ExtState: the panel adds tracks too (Real time mode's), and only Live sync's look runs often enough to hold them.
function mirror.track_colours(proj)
  local c = {}
  for t = 0, reaper.CountTracks(proj) - 1 do local x = reaper.GetTrack(proj, t); c[reaper.GetTrackGUID(x)] = reaper.GetMediaTrackInfo_Value(x, "I_CUSTOMCOLOR") end
  return c
end
-- (Only where SWS's auto track colouring is on here, the one thing that recolours tracks by itself: with it off, which is how a studio song
-- runs (band.sws_colours), the hold had nothing to fight and put its snapshot back over colours that changed for a reason. A project
-- reopened from an old file caught up: tracks went (the hold was taken), a track's newer colour landed in the same pass, and the next look
-- put the old colour back, which then went out as this computer's own change ("something with no undo point changed XT Drums A right after
-- a bandmate's change landed") and auto-claimed the track. The desktop and the laptop sent XT Drums A's colour back and forth at each
-- restart so, under main's build and this one. REAPER check, 0.59.49.75, rt-edits. mirror.held_colour: a colour StudioSync sets while a hold
-- runs is what's held from then.)
function mirror.held_colour(tr)
  local band = require("band")
  if reaper.GetExtState(band.SECTION, "colour hold") == "" then return end
  local k = band.ext_json(band.SECTION, "colour hold")
  local g = reaper.GetTrackGUID(tr)
  if type(k) == "table" and type(k.colours) == "table" and k.colours[g] ~= nil then
    k.colours[g] = reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR")
    band.set_ext_json(band.SECTION, "colour hold", k, false)
  end
end
function mirror.hold_colours(proj, colours)
  local band = require("band")
  if proj and mirror.own_colours() then
    band.set_ext_json(band.SECTION, "colour hold", { proj = tostring(proj), till = reaper.time_precise() + 5, colours = colours }, false)
  end
  local k = band.ext_json(band.SECTION, "colour hold")
  if not k then return end
  if reaper.time_precise() > (tonumber(k.till) or 0) or not mirror.own_colours() then return reaper.DeleteExtState(band.SECTION, "colour hold", false) end
  for i = 0, 512 do
    local p = reaper.EnumProjects(i)
    if not p then break end
    if tostring(p) == k.proj then
      for t = 0, reaper.CountTracks(p) - 1 do
        local x = reaper.GetTrack(p, t)
        local c = k.colours[reaper.GetTrackGUID(x)]
        if c and reaper.GetMediaTrackInfo_Value(x, "I_CUSTOMCOLOR") ~= c then reaper.SetMediaTrackInfo_Value(x, "I_CUSTOMCOLOR", c) end
      end
    end
  end
end

-- Is this an owner's change (they've claimed it, or they drive and it's unclaimed)? It then takes the owner step (mirror.next_rev): sends,
-- and since 0.59.45 deletions and restores too, which took +1, so a non-owner's later edit made apart could bring the item back (docs/clashes.md
-- rule 2. Round 1 review). By the studio's rules, not "alone": two edits made alone outvoted the claimant's own (Sync engine review, 0.58.76).
-- `opts`: can, owner_can, mode; `is_claimed`: the room's (sync.authority's who.is_claimed), else the last authority call's.
function mirror.owned(opts, me, name, pos, is_claimed)
  local sync = require("sync")
  is_claimed = is_claimed or opts.is_claimed or sync.is_claimed
  local free = opts.mode == "open" or opts.mode == "everyone" -- (nobody's ahead by being the driver; in Everyone, by a claim either)
  -- (opts.driver: the room's, sync.authority's who.driver. sync.driver_name is set only by Live sync and preload, so the driver's own restores
  -- from the panel or the Undo script never took the owner step. Round 2 review, 0.59.46)
  local driver = opts.driver or sync.driver_name
  return (opts.mode ~= "everyone" and is_claimed and is_claimed(name, pos) and (opts.owner_can or opts.can)(me, name, pos)) or (not free and me == driver) or false
end

-- mirror.watch's parts (split, 0.59.40): each takes the pass's shared state `w` (made in mirror.watch) and does what its
-- inline code did. w.sent and w.back count what went out and what was put back.
local W = {}
mirror.W = W -- (tests drive a part on its own: tests/test_0_59_46_engine.lua)
-- { owner, name } for the tracks in `oids` (by name, as of `names`) that someone else has claimed, out of this person's reach
function W.others_claims(w, oids, names)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  local list = {}
  for _, oid in ipairs(oids) do
    local name = names(oid)
    if name and name ~= "" and w.is_claimed and w.is_claimed(name) and not opts.can(me, name) then
      list[#list + 1] = { w.owner_of(name), name }
    end
  end
  return list
end
-- -> true when the pass stops here (a chain only comes back in front, stopped)
function W.keep_held(w)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  -- A folder or bus holding a bandmate's claimed part isn't deleted (James, 2026-11-02): their part would lose its routing
  -- with no say of theirs. Before anything else is looked at: its folder's tracks read as changed now, and would go out.
  for oid, held in pairs(holds) do
    local rev, h = mirror.known(proj, oid)
    if not by_oid[oid] and rev and h ~= "" then
      local theirs = others_claims(held.oids, function(x) return held.names[x] end)
      if #theirs > 0 then
        if reaper.EnumProjects(-1) ~= proj or reaper.GetPlayStateEx(proj) ~= 0 then return true end -- (a chain only comes back in front, stopped)
        -- (REAPER's Remove tracks takes a folder's tracks with it, so they come back too, parts and all. One still here only
        -- needs its folder setting back)
        local function bring(x)
          local _, _, evid, order = mirror.known(proj, x)
          local ev = event_file(room_dir, evid)
          if ev and not ev.gone then
            local ok, hash = mirror.apply(proj, ev, media, opts.local_mix)
            if ok then remember(proj, x, ev.rev, hash, ev.id, order) end
          end
        end
        local tracks = { oid, table.unpack(held.oids) }
        for _, x in ipairs(tracks) do
          local was_gone = not by_oid[x]
          bring(x)
          if was_gone then
            kept_back[x] = true
            for _, p in ipairs(mirror.PARTS) do bring(p .. x:sub(2)) end
          end
        end
        sync.put_back(string.format("%s holds %s: it's back, as deleting it would take them out of it. Ask them to move out of it first",
          held.name ~= "" and held.name or "That track", mirror.whose(theirs)))
        w.back = w.back + 1
      end
    end
  end
end
function W.credit(w)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  -- A copy of a part someone else has claimed goes out as yours, under a name of its own, and says whose it was: claims go by
  -- name, so as a second "Keys" it would be theirs, and refused.
  for _, o in ipairs(objs) do
    local from = o.kind == "track" and select(2, reaper.GetSetMediaTrackInfo_String(o.ptr, "P_EXT:band_copy_of", "", false)) or ""
    if from ~= "" then
      reaper.GetSetMediaTrackInfo_String(o.ptr, "P_EXT:band_copy_of", "", true)
      local name = o.state.name
      if opts.mode ~= "driver" and w.is_claimed and w.is_claimed(name) and not opts.can(me, name) then
        local who, label, n = w.owner_of(name), name .. " (" .. me .. "'s copy)", 1
        local function taken(x)
          for _, t in ipairs(objs) do if t.kind == "track" and t ~= o and t.state.name == x then return true end end
        end
        while taken(label) do n = n + 1; label = string.format("%s (%s's copy %d)", name, me, n) end
        reaper.GetSetMediaTrackInfo_String(o.ptr, "P_NAME", label, true)
        o.state.name = label
        o.hash = mirror.track_hash(o.state, opts.local_mix)
        credit[o.oid] = string.format("%s copied %s's %s as '%s'. The original isn't touched", me, who, name, label)
        band.log(credit[o.oid])
      end
    end
  end
end
-- Says so when what changes on a bus, a folder or the master changes how a bandmate's claimed part sounds. Nothing's
-- refused for that: the part itself isn't touched. Once a minute per track at most, or a fader dragged about says it each time.
function W.bus_note(w, o, name, last)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  local at = o.kind == "track" and o.oid or o.track
  local what = o.kind == "fx" and "the plug-ins on" or o.kind == "env" and "the automation on"
  if o.kind == "track" and last and type(last.state) == "table" then
    -- (with Local mixing on, faders, pan and width here are your own and don't go out: not said. 0.59.14)
    for _, f in ipairs(opts.local_mix and { "mute", "fxen", "phase" } or { "vol", "pan", "mute", "fxen", "phase", "width" }) do
      if tostring(o.state[f]) ~= tostring(last.state[f]) then what = "the fader, pan or mute of" end
    end
  end
  if not what or reaper.time_precise() - (mirror.bus_said[at] or -60) < 60 then return nil end
  local oids
  if at == mirror.MASTER then
    oids = {}
    for _, t in ipairs(objs) do if t.kind == "track" then oids[#oids + 1] = t.oid end end
  else oids = (holds[at] or {}).oids or {} end
  local theirs = others_claims(oids, function(x) return by_oid[x] and by_oid[x].state.name end)
  if #theirs == 0 then return nil end
  mirror.bus_said[at] = reaper.time_precise()
  return string.format("%s changed %s %s: that changes how %s sound", me, what, at == mirror.MASTER and "the master" or name, mirror.whose(theirs))
end
-- -> w.moved_set (tracks this person moved), w.first_here
function W.order(w)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  -- Did this person move a track? A track's place is the track above it, so anything that lands above it reads as a change
  -- of it. Sent, that came back round: a bandmate's track put back moved this one, it went out, and they moved in turn,
  -- every 2 s for good (laptop, undoing bandmates' new tracks, 0.42.3). So a track that differs only by its place is a
  -- change only on the look where the list has changed and nothing from the band landed since the last look.
  local order_key, order = tostring(proj), {}
  do -- (a file opened again in the same tab keeps the tab's address, and Live sync runs on through it: its tracks are all new. Then it's a first look.
    -- Deleting the first track reads the same: a first look does no harm)
    local had = mirror.cc_seen[order_key]
    if had and not reaper.ValidatePtr2(proj, had, "MediaTrack*") then mirror.order_seen[order_key] = nil end
    mirror.cc_seen[order_key] = reaper.GetTrack(proj, 0)
    -- (the timeline's "opened behind the song" look only for a file opened again, told by its new master track, as sync.settled_for does. On a
    -- deleted first track it ran too, and the band's delete-all with a tempo change, landed over the link before session.json had come through
    -- Syncthing, had its new tempo put back to the old one on every other computer. Cross test step 1, James, rt)
    local mhad, master = mirror.master_seen[order_key], reaper.GetMasterTrack(proj)
    if mhad and not (mhad == master and reaper.ValidatePtr2(proj, mhad, "MediaTrack*")) then sync.timeline_looked[proj], sync.timeline_live[proj] = nil, nil end
    mirror.master_seen[order_key] = master
  end
  for _, o in ipairs(objs) do if o.kind == "track" then order[#order + 1] = o.oid end end
  order = table.concat(order, ",")
  local moved_here = mirror.order_seen[order_key] ~= nil and mirror.order_seen[order_key] ~= order and not mirror.order_band[order_key]
  -- (by track, not "the list changed": a track added at the end sent or put back every track whose place differs here: Mac, 0.42.9)
  local moved_set = {}
  if moved_here then
    local function split(text) local t = {}; for x in text:gmatch("[^,]+") do t[#t + 1] = x end; return t end
    local selected = {}
    for _, o in ipairs(objs) do if o.kind == "track" and o.ptr and reaper.IsTrackSelected(o.ptr) then selected[o.oid] = true end end
    moved_set = mirror.moved_tracks(split(mirror.order_seen[order_key]), split(order), selected)
    -- (and the track each sat under before: its change says so, `moved`, so Undo and Restore put it back there. mirror.moved_since)
    w.moved_from = {}
    local old = split(mirror.order_seen[order_key])
    for k, x in ipairs(old) do if moved_set[x] then w.moved_from[x] = old[k - 1] or "" end end
  end
  -- the first look at a project: which take plays is looked at again. (A part that arrived while the plug-in looked
  -- loaded stayed on silent notes, with its print sitting right there: laptop, 0.42.3)
  local first_here = mirror.order_seen[order_key] == nil
  if first_here then
    mirror.first_look[order_key] = reaper.time_precise() + mirror.FX_LOAD_SECS
    local prints = require("prints")
    for _, o in ipairs(objs) do
      if o.kind == "item" and o.ptr then pcall(prints.choose, o.ptr)
      elseif o.kind == "fx" and o.ptr then mirror.fx_load_knobs[order_key .. o.oid] = mirror.fx_params(o.ptr) end
    end
  end
  w.order_was = mirror.order_seen[order_key] -- (the tracks as the look before had them: where a track deleted since sat, W.gone)
  mirror.order_seen[order_key], mirror.order_band[order_key] = order, nil
  w.moved_set, w.first_here = moved_set, first_here
end
function W.put_back(w, o, rev, evid, why)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  mirror.unsent[tostring(proj) .. o.oid] = nil -- (the band's version is back: nothing of ours waits)
  held_back_clear(proj, o.oid)
  local said_text = why.text
  local ev = event_file(room_dir, evid)
  local copy_key = tostring(proj) .. o.oid .. tostring(evid) .. "\0" .. tostring(o.hash)
  local function keep_part_copy()
    -- (your plug-in settings, refused, saved first as an FX chain to load back: a song's knob work made while playing went for good when the
    -- driver changed hands before the stop. Review, 0.59.18. Once for that edit, as the item copy above)
    if o.kind == "fx" and why.text and not why.to and not mirror.copied[copy_key] and type(o.state) == "string" and o.state:find("\n<", 1, true) then
      local band = require("band")
      local dir = band.home() .. "/kept plug-ins"
      reaper.RecursiveCreateDirectory(dir, 0)
      local nm = ((why.name or "") ~= "" and why.name or "a track"):gsub("[^%w%-_ ]", "")
      local path = dir .. "/" .. nm .. " " .. o.oid:gsub("[^%w%-_]", "_") .. " " .. os.date("%Y-%m-%d %H%M%S") .. ".RfxChain" -- (its id: see keep_automation)
      local body = {}
      for l in o.state:gmatch("[^\n]+") do body[#body + 1] = l end
      table.remove(body, 1); table.remove(body) -- (the <FXCHAIN around it: a chain file is what's inside)
      local keep = {}
      for _, l in ipairs(body) do if not l:match("^WNDRECT ") and not l:match("^SHOW ") and not l:match("^LASTSEL ") and not l:match("^DOCKED ") then keep[#keep + 1] = l end end
      if pcall(band.write_atomic, path, table.concat(keep, "\n") .. "\n") then
        mirror.copied[copy_key] = true
        why.text = why.text .. ". Your plug-in settings are saved as an FX chain (load it from the track's FX window: FX > Load FX chain): " .. path
      end
    end
    -- (your automation, refused, kept likewise: there's no envelope file REAPER loads, so Restore > Kept automation puts it back on the track,
    -- where it goes out as your change if it may by then. Automation drawn while playing was lost when the driver changed hands before the
    -- stop. James, 0.59.39)
    if o.kind == "env" and why.text and not why.to and not mirror.copied[copy_key] and type(o.state) == "string" and o.state ~= "" then
      if keep_automation(o.oid, o.track, why.name, o.state, room_dir) then
        mirror.copied[copy_key] = true
        why.text = why.text .. ". Your automation is kept: Restore > Kept automation puts it back"
      end
    end
  end
  if ev and not ev.gone then
    if o.kind == "fx" and playing then return end -- (reloading plug-ins mid-song: after the stop)
    w.back_point(ev)
    -- (your edit to someone else's item, refused: a copy of yours first goes to a track of your own, as a new item would. Not when it went to
    -- them as a suggestion: that holds it, and accepted, a copy would be a second part. Only a selected one: what you just edited, not every
    -- part a refused tempo change moved, say. Review, 0.58.91)
    -- (once for that edit: while the band's version waits for its recording the put-back returns, and every pass made another copy. Review, 0.58.95)
    -- (and per refused version: the band's event doesn't change when you're refused, so a second refused edit in the session got no copy and
    -- no word, and was gone. Full review, 0.59.44)
    -- (the copied flag only once the copy is made: set before, a copy that failed was never tried again and the edit went. Round 1 review, 0.59.45)
    if o.kind == "item" and why.copy and not why.to and why.text and not mirror.copied[copy_key] and o.ptr and reaper.ValidatePtr2(proj, o.ptr, "MediaItem*") and reaper.IsMediaItemSelected(o.ptr) then
      local got, ch = reaper.GetItemStateChunk(o.ptr, "", false)
      if got then
        local on = select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(o.ptr)))
        local copy = reaper.AddMediaItemToTrack(keep_track(proj, on))
        -- (new ids, and out of any pool: plain MIDI, as a pooled copy travels. A pool entry left behind is what REAPER's MIDI code crashed on)
        if copy and reaper.SetItemStateChunk(copy, (ch:gsub("\n%s*POOLEDEVTS[^\n]*", ""):gsub("\n%s*I?GUID[^\n]*", ""):gsub("<SOURCE MIDIPOOL", "<SOURCE MIDI")), false) then
          reaper.GetSetMediaItemInfo_String(copy, "P_EXT:band_oid", "", true)
          mirror.copied[copy_key] = true
          why.text = why.text .. ". Your version is on '" .. on .. " (yours, not sent)'"
        end
      end
    end
    keep_part_copy()
    local ok, h = mirror.apply(proj, ev, media, opts.local_mix)
    if ok then
      remember(proj, o.oid, ev.rev, h, ev.id, mirror.order_of(ev))
      if o.kind == "track" and type(ev.state) == "table" then local tb = mirror.tracks_back[tostring(proj)] or {}; tb[o.oid] = ev; mirror.tracks_back[tostring(proj)] = tb end
    elseif mirror.PART[o.kind] then return -- (waits for this tab to come to the front)
    elseif o.kind == "item" and mirror.in_editor == o.oid then return -- (open in the MIDI editor: once it's closed)
    elseif o.kind == "item" and ev.track and mirror.find(proj, "track", ev.track) then
      -- (its track is here, so its recording is still on its way: deleted, your item was gone until the next change. Review, 0.58.92)
      return say_once("arriving" .. o.oid, "an item's put-back waits: the band's version of it needs a recording that hasn't reached this computer yet")
    else -- it can't land here (its track is gone): the band's state wins, and that has no such item
      if o.kind == "item" and o.ptr and reaper.ValidatePtr2(proj, o.ptr, "MediaItem*") then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(o.ptr), o.ptr) end
      remember(proj, o.oid, rev or 0, "", evid, mirror.order_of(ev))
    end
  elseif not rev or (ev and ev.gone) then
    -- never the band's: something new this person may not add. Kept here, on a track of their own (never deleted)
    -- (or no longer the band's: its newest version is a deletion, and it's here again (REAPER's own Undo, or a deletion that hadn't landed).
    -- "Its last change can't be read" left it in the project, asked about again every 90 s. Kept the same way, and no longer the band's item.
    -- rt-converge)
    local where = (why.name or "") ~= "" and why.name or "an unnamed track"
    if (o.kind == "item" or o.kind == "track") and o.ptr or o.kind == "misc" then w.back_point() end
    if o.kind == "item" and o.ptr then
      reaper.MoveMediaItemToTrack(o.ptr, keep_track(proj, why.name or ""))
      if rev then reaper.GetSetMediaItemInfo_String(o.ptr, "P_EXT:band_oid", "", true) end
      -- (out of the pool it shares with the part it was copied from, which is then put back from its event: REAPER's MIDI code crashed on a
      -- later tab close with a freed entry in its list, about 1 run in 5 after this step, and never without it: PC, 2026-11-03)
      do
        local got, ch = reaper.GetItemStateChunk(o.ptr, "", false)
        local unpooled, n = ch:gsub("\n%s*POOLEDEVTS[^\n]*", "")
        if got and n > 0 then reaper.SetItemStateChunk(o.ptr, unpooled, false) end
      end
      why.text = "Not sent: " .. where .. " isn't yours to add to. Your item is on '" .. where .. " (yours, not sent)'" ..
        (why.to and (", and sent to " .. why.to .. " as a suggestion") or ". Claim " .. where .. " to share it")
    elseif o.kind == "track" and o.ptr then
      reaper.GetSetMediaTrackInfo_String(o.ptr, "P_EXT:band_local", "yours", true)
      why.text = "Not sent: only the driver adds tracks here. Yours stays on this computer (Take control to add tracks)"
    elseif o.kind == "misc" then
      -- a group or lock put on someone's track: nothing here is worth keeping, and left on, your VCA went on moving their track on
      -- this computer alone (what you hear and render differs from everyone else). If they accept, it lands as theirs.
      if not mirror.apply(proj, { obj = "misc", oid = o.oid, track = o.track, state = "" }, media, opts.local_mix) then return end -- (waits for this tab to come to the front)
    elseif (o.kind == "fx" or o.kind == "env" or o.kind == "recv") and why.text and o.track then
      -- (plug-ins, automation or sends put on a track that had none, and not this person's to add: taken off again, the plug-ins or the
      -- automation kept as any refused edit's are. Left on ("it stays on this computer"), this computer played the bandmate's part through a
      -- plug-in nobody else had, for good, and asked them for the track again every 90 s for as long as the session ran: the soak never
      -- went quiet. What you see is what the band has. rt-converge)
      if o.kind == "fx" and playing then return end -- (plug-ins change only while stopped)
      if mirror.will_wait(proj, { obj = o.kind, oid = o.oid, track = o.track }, true) then return end -- (its tab behind, or recording: next look)
      w.back_point()
      keep_part_copy()
      if not mirror.apply(proj, { obj = o.kind, oid = o.oid, track = o.track, name = why.name, state = "" }, media, opts.local_mix) then return end
    elseif why.text then -- (a part that never went out: said once. Every pass, it pushed all else out of the log: laptop, 0.42.4)
      say_once("never" .. o.oid, why.text .. " (it stays on this computer)")
      return
    end
  else
    -- known, but its last change can't be read here (still arriving, or from another room): left as it is
    return say_once("noev" .. o.oid, "couldn't put back a change on " .. ((why.name or "") ~= "" and why.name or "an unnamed track") ..
      " (the studio's version hasn't arrived here yet): it stays as it is for now")
  end
  w.back = w.back + 1
  -- (why.quiet: these words were just said for the same answer (claimask.hold); a copy's own words, added above, still are. rt-edits round 6)
  if why.text and not (why.quiet and why.text == said_text) then sync.put_back(why.text) end
end
-- What was refused goes to whoever claimed it, as a suggestion, if it's a claim that refused it. -> true when it went.
function W.propose(w, o, rev, who, claim_name, pos, name, gone)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  if o.kind == "fx" or not who or who == me or opts.mode == "driver" or not (w.is_claimed and w.is_claimed(claim_name, pos)) then return false end
  local _, _, kev = mirror.known(proj, o.oid)
  local c = { obj = o.kind, oid = o.oid, rev = rev or 0, ev = kev ~= "" and kev or nil, track = o.track, name = name, pos = pos, gone = gone or nil } -- (ev: one edit's nudges share a rev)
  if o.kind == "track" and o.ptr and not gone then -- (a normal group's fader moves the owner's track too: that's why this is a suggestion, and there's a better way)
    for _, g in ipairs({ "VOLUME_LEAD", "VOLUME_FOLLOW" }) do c.grouped = c.grouped or reaper.GetSetTrackGroupMembership(o.ptr, g, 0, 0) ~= 0 end
  end
  if not gone then
    c.state = o.state
    if o.kind == "track" and opts.local_mix then -- (the band's faders, not your own: see band_faders)
      local last = kev ~= "" and event_file(room_dir, kev) or nil
      c.state = mirror.band_faders(o.state, last and not last.gone and last.state)
    end
    if o.kind == "item" then
      mirror.copy_failed, mirror.copy_pending = nil, nil
      local last = kev ~= "" and event_file(room_dir, kev) or nil
      if (kev or "") ~= "" and not last then return false end -- (its last version unreadable: see W.send. Round 1 review, 0.59.45)
      c.state = mirror.share_media(o.state, media, o.ptr, last and last.state)
      if mirror.copy_failed or mirror.copy_pending then return false end
    end
  end
  return suggest.add(room_dir, me, who, c)
end
-- It may go: out it goes, as this person's change.
-- An item's or automation's reading at the look `L` (the last one's record), if it was the band's version then (W.one found it unchanged):
-- what W.send tells a tempo change's move from an edit by. Automation as its track's lines, without automation items' (read through the API,
-- not kept): a track with those goes by the band's text as before. -> the state, or nil. rt-fix9
local function look_reading(L, o)
  if not (L.map and L.clean and L.clean[o.oid] ~= nil and L.where and L.tracks) then return nil end
  local e = L.tracks[L.where[o.oid] or ""]
  if not e then return nil end
  if o.kind == "env" then return e.parts and e.parts.env end
  for _, q in ipairs(o.kind == "item" and e.items or {}) do if q.oid == o.oid then return q.state end end
end
function W.send(w, o, rk, rev, evid, kord, last, name, knobs)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  local state = o.state
  -- (known to the band, but its last version can't be read here (removed, still arriving): nothing can say which of its paths a bandmate put
  -- there, so it waits rather than copy any. Security stopgap, Round 1 review, 0.59.45)
  if (o.kind == "item" or o.kind == "fx") and rev and (evid or "") ~= "" and not last then
    held_back_set(proj, o.oid)
    mirror.auto[rk] = nil
    return say_once("unread" .. o.oid, string.format("a change on %s waits: the studio's last version of it isn't readable on this computer (still arriving, or removed)",
      name ~= "" and name or "an unnamed track"))
  end
  if o.kind == "item" then
    mirror.copy_failed, mirror.copy_pending = nil, nil
    local shared = mirror.share_media(state, media, o.ptr, last and last.state)
    if mirror.copy_pending then -- (a big file still on its way into the studio's folder: it goes once it's there. 0.59.18)
      mirror.unsent[tostring(proj) .. o.oid] = true
      return say_once("copying" .. o.oid, string.format("copying a big file on %s into the studio's folder: it goes out to everyone once it's there",
        name ~= "" and name or "an unnamed track"))
    end
    if mirror.copy_failed then -- (its audio didn't reach the band's folder: sent, it'd point at a file only we have)
      held_back_set(proj, o.oid) -- (counted by Sync and exit: it said "safe" over a take only this computer had. Round 1 review, 0.59.45)
      mirror.auto[rk] = nil -- (a print's flag doesn't wait with it: see W.one)
      return say_once("copy" .. o.oid, string.format("couldn't copy the audio of an item on %s into the studio's folder (%s): it goes out once it can",
        name ~= "" and name or "an unnamed track", mirror.copy_failed))
    end
    if shared ~= state then -- it now plays the shared copy here too, so the next look sees the same thing
      -- (which take plays, the selection and its group put back: the normalized chunk has none of them, so a new recording's first
      -- send played its first take, for everyone. And no BANDTAKE line inside REAPER's chunk. Review, 0.58.87)
      local cur, sel, grp = reaper.GetMediaItemInfo_Value(o.ptr, "I_CURTAKE"), reaper.IsMediaItemSelected(o.ptr), reaper.GetMediaItemInfo_Value(o.ptr, "I_GROUPID")
      local theirs = select(2, reaper.GetSetMediaItemInfo_String(o.ptr, mirror.THEIRS, "", false)) -- (the chunk set below has no such P_EXT: kept)
      reaper.SetItemStateChunk(o.ptr, mirror.resolve_media((shared:gsub("BANDLANE %d+\n?", ""):gsub("BANDTAKE %d+\n?", "")), media), false)
      if cur < reaper.CountTakes(o.ptr) then reaper.SetMediaItemInfo_Value(o.ptr, "I_CURTAKE", cur) end
      if theirs ~= "" then reaper.GetSetMediaItemInfo_String(o.ptr, mirror.THEIRS, theirs, true) end
      reaper.SetMediaItemSelected(o.ptr, sel)
      if grp > 0 then reaper.SetMediaItemInfo_Value(o.ptr, "I_GROUPID", grp) end
      state = mirror.item_state(o.ptr, media)
      o.hash = mirror.item_hash(o.track, state)
    end
  end
  -- (by the studio's rules, not "alone": two edits made alone outvoted the claimant's own. Sync engine review, 0.58.76)
  local owned = mirror.owned(opts, me, name, o.pos, w.is_claimed)
  -- (one edit, however many nudges: a change within SESSION_SECS of our own last one to it, nobody's in between, keeps its number, and its
  -- later order makes it the newer. Ten nudges outvoted one careful edit: docs/clashes.md)
  local s = mirror.sessions[rk]
  -- (what we hold is still our own last one. Not for an owner: theirs jumps past what others made meanwhile, which a reused number wouldn't)
  -- (shortcut: StudioSync before 0.58.43 settles equal revisions by the second, so two nudges in one second can end differently there; the
  -- version warning asks everyone to update)
  local same_edit = not owned and s and s.rev == rev and s.id == evid and reaper.time_precise() - s.at < mirror.SESSION_SECS
  mirror.hlc_seen(last and last.hlc) -- (the clock past what this builds on: after a restart it could fall behind, and every walk stopped short)
  local ev = { type = "obj", obj = o.kind, oid = o.oid, rev = same_edit and rev or mirror.next_rev(rev, owned), base = rev or 0, state = state, track = o.track,
    base_ev = evid ~= "" and evid or nil, -- (the version this one started from: a merge finds the base there, mirror.merge_item)
    name = name, pos = o.pos, hash = o.hash, hv = mirror.HV, act = w.act, tl = mirror.map_stamp(proj) } -- (hash: what it is here; every receiver checks it came out the same)
  mirror.map_tag(proj, ev) -- (the tempo map its seconds are on: whoever lands it elsewhere puts it on the same beat there. rt-converge)
  if o.kind == "track" and opts.local_mix then ev.state, ev.local_mix = mirror.band_faders(state, last and not last.gone and last.state), true end
  if o.kind == "track" and w.moved_from then ev.moved = w.moved_from[o.oid] end -- (the track it sat under before you moved it: mirror.moved_since)
  if w.unasked[o.oid] then ev.unasked = true end -- (sent past an auto-claim whose claimer couldn't be asked: W.refuse, sync.receive's soft_ok)
  if ev.moved ~= nil then w.order_out = true end -- (a move of yours goes out: the studio's order list follows, after this look's sends)
  if o.kind == "item" and type(state) == "string" and state:find("BANDLANE", 1, true) then -- (a comp piece's source lane: mirror.comp_from)
    local others, t = {}, by_oid[o.track]
    for _, x in ipairs(objs or {}) do if x.kind == "item" and x.track == o.track and x.oid ~= o.oid then others[#others + 1] = x.state end end
    ev.from_lane = mirror.comp_from(state, t and type(t.state) == "table" and t.state.plays, others)
  end
  if o.kind == "track" and o.ptr and (tonumber(o.state.lanes) or 0) > 1 then
    -- (the first comp area: REAPER's new lane holds only that piece, and the rest of the part goes silent, with no word: Mac, 0.42.10)
    local items = {}
    for j = 0, reaper.CountTrackMediaItems(o.ptr) - 1 do
      local x = reaper.GetTrackMediaItem(o.ptr, j)
      items[#items + 1] = { pos = reaper.GetMediaItemInfo_Value(x, "D_POSITION"), len = reaper.GetMediaItemInfo_Value(x, "D_LENGTH"),
        plays = reaper.GetMediaTrackInfo_Value(o.ptr, "C_LANEPLAYS:" .. math.floor(reaper.GetMediaItemInfo_Value(x, "I_FIXEDLANE"))) > 0 }
    end
    local playing, holds = mirror.lane_cover(items)
    if holds > 0 and playing < holds / 2 then
      say_once("cover " .. o.oid .. tostring(o.state.plays), string.format("%s: the lane that plays holds %.0f s of the %.0f s on this track. The rest is silent until it's comped in, or another lane plays",
        name ~= "" and name or "a track", playing, holds))
    end
  end
  if mirror.auto[tostring(proj) .. o.oid] then ev.auto, mirror.auto[tostring(proj) .. o.oid] = true, nil end
  local sb = mirror.set_backs[rk]
  ev.note = credit[o.oid] or (sb and sb.id == evid and sb.note) or bus_note(o, name, last) -- (said on every machine as it lands: sync.receive)
  if ev.note and not credit[o.oid] then band.log(ev.note) end
  if o.kind == "fx" then
    -- (samples, IRs, models it loads; and the presets REAPER shows on it from your own preset folder, looked through, never in the event:
    -- lib/content.lua. rt)
    ev.files = require("fxfiles").share(state .. require("content").preset_text(o.ptr, media), media, last and last.state, last and last.files, o.ptr and mirror.theirs(o.ptr, true) or nil)
    -- (the master's record too: a template's master chain is noted as theirs, lib/extras.lua. Security, Round 4 review, 0.59.49)
    ev.restless = mirror.restless_in(state)
    if ev.restless or mirror.modulated(state) then mirror.fx_knobs[rk] = knobs or mirror.fx_params(o.ptr) end
  elseif o.kind == "item" and state:find("<TAKEFX", 1, true) then
    -- (and a take plug-in's: a sampler, RS5k or a convolution reverb as take FX played silent on everyone else's. 0.59.14)
    local files = require("fxfiles").share(mirror.take_fx(state), media, last and type(last.state) == "string" and mirror.take_fx(last.state) or nil, last and last.files, mirror.theirs(o.ptr))
    if #files > 0 then ev.files = files end
  end
  -- (not a move that is only the tempo map's: it travels, made under its map (`tl`), but nobody worked on that track. The desktop's own 90 bpm
  -- marker sent 11 items and auto-claimed all three tracks. REAPER recheck, 0.59.49.80, round 7)
  -- (or against this computer's own reading at its last look, while it was the band's: the band's text is another REAPER's when a bandmate's
  -- change was the last, and a tempo change made after a bandmate's auto-claimed the track with automation, three of three (rt-r4's bug B).
  -- Said on the change (`retimed`): a merge then takes nothing of it but the map, mirror.event_file. rt-fix9)
  local tempo_only = (ev.tl ~= nil or map_ok(last and last.tm)) and mirror.only_map_moved(proj, o, last)
    or w.look_was and mirror.moved_by_map(o.kind, look_reading(w.look_was, o), o.state, w.look_was.map, w.map_now, reaper.GetSetProjectInfo(proj, "PROJECT_TIMEBASE", 0, false))
  if tempo_only then ev.retimed = true end
  local id = sync.post(cfg, song, room, ev)
  -- (and only from an edit of yours: mirror.user_edited. rt-fix6a)
  if opts.sent and not tempo_only and w.edited ~= false then pcall(opts.sent, o, name, ev) end -- (Claims: what you edit becomes yours. lib/claimask.lua, rt-claims)
  pcall(require("compat").sent, proj, o.oid, name, o.kind, o.ptr, ev.auto) -- (changed again right after a bandmate's change, or by itself: lib/compat.lua)
  require("streams").offer_media(cfg, song, room, media, ev, last) -- (the media it newly names, to whoever's here over the direct link too. James, rt)
  if o.kind == "fx" and o.ptr then mirror.fx_quiet[rk], mirror.fx_quiet_presets[rk] = mirror.fx_params(o.ptr), mirror.fx_presets(o.ptr); knobs_agreed(proj, o, rk) end -- (what it's changed from, next time)
  if o.kind == "fx" and o.ptr then mirror.fx_last[rk], mirror.fx_doubt[rk] = mirror.fx_quiet[rk], nil end -- (its knobs as it went out: mirror.receive)
  -- (and what an earlier version of the band's read back as here no longer stands for anything: the chain is this one now. Kept, a chain
  -- changed back to exactly what that earlier version was (a plug-in added and taken off again, a knob turned and turned back) hashed as the
  -- old read-back, was taken for "the band's, as it reads here", and never went out: it stayed on this computer alone, with no line. The
  -- soak's "plug-ins differ" at 150 edits. rt-converge)
  if o.kind == "fx" then mirror.fx_readback[rk] = nil end
  remember(proj, o.oid, ev.rev, o.hash, id, mirror.order_of(ev))
  -- (your claimed track renamed: the claim goes with it. 0.59.14)
  if o.kind == "track" and last and not last.gone and type(last.name) == "string" and last.name ~= "" and name ~= "" and last.name ~= name then
    pcall(sync.claim_renamed, cfg, song, room, last.name, name)
  end
  mirror.sessions[rk] = { rev = ev.rev, at = reaper.time_precise(), id = id }
  if o.kind == "track" then mirror.track_seen[rk] = o.state end -- (what went out is the band's now: mirror.receive's keep_unsent. rt-fix9)
  -- (in ExtState, as last_at: a ProjExtState write counts as a project change, and held the band's changes until another look. Round 1
  -- review, 0.59.45)
  if name ~= "" and not ev.auto and reaper.GetExtState(band.SECTION, "last_track " .. tostring(proj)) ~= name then
    reaper.SetExtState(band.SECTION, "last_track " .. tostring(proj), name, false) -- (what they're working in: Who's here)
  end
  -- (and where in the song: clicking "Working in" goes there. An item's own place, or the edit cursor's. James, 0.59.32)
  if name ~= "" and not ev.auto then
    reaper.SetExtState(band.SECTION, "last_at " .. tostring(proj), string.format("%.3f", tonumber(ev.pos) or reaper.GetCursorPositionEx(proj)), false) -- (not in the project: a ProjExtState write counts as a project change, and the race guard read it as an edit not yet seen. merge_items, 0.59.37)
  end
  mirror.unsent[tostring(proj) .. o.oid] = nil -- (gone out: the band's next change to it may land)
  held_back_clear(proj, o.oid)
  if o.kind == "env" then pcall(drop_kept_automation, o.oid, o.state) end
  require("presence").touch(proj, o.oid)
  w.sent = w.sent + 1
end
-- It may not: put back, or sent to whoever claimed it as a suggestion (unless it isn't a change at all).
-- Why an edit of `me`'s to `where` wasn't sent, by the room's mode (sync.MODES; `claimer`: whose claim holds there, if any; `to`: it went
-- to them as a suggestion). Pure.
--   driver (Driver only): only the driver edits; claims are kept but don't count, so nothing says "claim it" or "ask them to release it"
--   admins (Admins only): a claim holds against everyone; what nobody claimed is the admins' and whoever an admin let edit
--   open (Claims): only someone else's claim refuses (asked first when they're here: lib/claimask.lua)
--   everyone (Open): nothing is refused for whose it is
function mirror.refusal_words(mode, where, me, driver, claimer, to)
  if to and claimer then return where .. " is " .. claimer .. "'s, so it's sent to them as a suggestion" end
  if mode == "driver" then
    return (driver and driver ~= "" and driver ~= me) and ("only the driver (" .. driver .. ") edits in this room (Take control, or ask them to set Who controls to Claims)")
      or "only the driver edits in this room"
  end
  if claimer and claimer ~= me then
    return where .. " is claimed by " .. claimer .. (mode == "admins" and ": ask them to release it, or an admin to give it to you" or ": ask them to release it")
  end
  if mode == "admins" then return "only admins, and whoever an admin lets edit here, change what nobody has claimed in this room" end
  return "it isn't yours to change right now"
end
-- A bandmate's change to a track that wasn't theirs to make, answered instead of applied (sync.receive: a rename of a track you've claimed,
-- from a StudioSync that didn't ask). It's noted as the band's newest version without being put in place, so the next look finds the track
-- differs from it and sends it as it is here, built on theirs: it goes back on every computer. `note`: said in everyone's log as it lands.
mirror.set_backs = mirror.set_backs or {} -- tostring(proj) .. oid -> { id = the answered change, note }
function mirror.set_back(proj, ev, note)
  remember(proj, ev.oid, ev.rev or 0, ev.hash or "set back", ev.id, mirror.order_of(ev))
  mirror.set_backs[tostring(proj) .. ev.oid] = { id = ev.id, note = note }
end
function W.refuse(w, o, rk, rev, evid, kord, last, name, ok_before)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  -- only its place in the list differs: a track above it went (a bandmate's, say, joining late, or one that's coming
  -- back), and nobody changed this one, so it isn't news ("Track Mac Audio ... put back": laptop, 0.42.2)
  if o.kind == "track" and last and type(last.state) == "table" and mirror.same_line(o.state, last.state, opts.local_mix) then
    return put_back(o, rev, evid, { name = name })
  end
  -- the tempo changed and REAPER moved this with it: nobody's edit. It's where it should be, and whoever may change it sends
  -- it. (Put back, a bandmate's part sat at its old time, out of step with the new tempo, until theirs arrived.)
  if mirror.only_map_moved(proj, o, last) then
    mirror.unsent[rk] = nil
    return remember(proj, o.oid, rev, o.hash, evid, kord)
  end
  -- only how its folder closes differs, in the same folder: a track added or copied after it did that, and nobody changed
  -- this one. Nothing to ask its owner about (a copy of Keys asked Mac about Keys)
  if o.kind == "track" and last and type(last.state) == "table" then
    local x, y = band_json(o.state), band_json(last.state)
    x.depth, y.depth = 0, 0
    if mirror.same_line(x, y, opts.local_mix) then return put_back(o, rev, evid, { name = name }) end
  end
  -- a chain that only just landed or opened, none of its windows open, the same plug-ins: it reads back its own way here as it loads
  -- (James, 0.59.8: TONEX and Pro-L 2 on the laptop, "2 edits not sent" on opening Nostalgia, and put back, which loads it again).
  -- Nobody's edit: what it reads as here stands for the band's, as the readback above has it.
  if o.kind == "fx" and o.ptr and last and type(last.state) == "string" and not mirror.fx_was_open(o.ptr) and not loaded(proj, rk) then
    -- (and its knobs and presets as they were: a knob turned from the mixer, a control surface or a preset action in that minute
    -- is someone's edit, and stays one. Review, 0.59.9)
    local lk = mirror.fx_load_knobs[rk]
    if plugin_keys(last.state) == plugin_keys(o.state) and (lk == nil or lk == mirror.fx_params(o.ptr)) and knobs_as_left(proj, o, rk)
        and (mirror.fx_quiet_presets[rk] == nil or mirror.fx_quiet_presets[rk] == mirror.fx_presets(o.ptr)) then
      mirror.fx_readback[rk], mirror.unsent[rk] = o.hash, nil
      return
    end
  end
  local where = (ok_before and name or last.name or "") ~= "" and (ok_before and name or last.name) or "an unnamed track"
  -- whose it is, and what would let you: "or take control" told the driver to take control (laptop, round 2)
  local owner_of = w.owner_of
  local pos = o.pos -- (a plug-in chain has none, and one that's never gone out has no last change: laptop, 0.42.3)
  if not ok_before and last then pos = last.pos end
  local who = owner_of and owner_of(ok_before and name or (last.name or ""), pos)
  -- (Claims: someone else's claim is asked for, the edit held here meanwhile, or put back with why. lib/claimask.lua, rt-claims)
  local asked, quiet = nil, nil
  if opts.ask then asked, quiet = opts.ask(ok_before and name or (last and last.name or ""), pos) end
  if asked == true then
    mirror.unsent[rk] = true
    mirror.asked_of[rk] = { who = who, at = reaper.time_precise() } -- (held for their answer, as of this look: mirror.apply, a track deleted)
    return
  end
  -- (their auto-claim, and the link can't reach them to ask: it goes out, rt-fix6a, and says so (`unasked`), so the computers the link does
  -- reach land it at once too. Unsaid, each of them held it back for the claimer's auto-claim, a minute or two: rt-r3. rt-converge)
  if asked == false then
    w.unasked[o.oid] = true
    return W.send(w, o, rk, rev, evid, kord, last, name)
  end
  if type(asked) == "string" then return put_back(o, rev, evid, { name = ok_before and name or (last and last.name or ""), copy = true, text = asked, quiet = quiet }) end
  -- (someone's claim: what was done to it goes to them to accept. lib/suggest.lua)
  local to = propose(o, rev, who, ok_before and name or (last and last.name or ""), pos, name)
  -- (plain words, whose it is first: "Undone: ... put back (claim it, or take control)" read as your own Undo. UX review, 0.58.47)
  -- (by the room's mode, as lib/dawedit.lua's item_refusal: "James is driving and X is nobody's: claim it to edit it" was Driver + claims'
  -- words, said in Driver only, where a claim doesn't count. Cross Test, 0.59.49.72. rt-merge)
  local how = mirror.refusal_words(opts.mode or sync.room_mode, where, me, sync.driver_name,
    w.is_claimed and w.is_claimed(ok_before and name or (last and last.name or ""), pos) and who or nil, to)
  local differed = last and mirror.first_diff(o.state, last.state)
  put_back(o, rev, evid, { name = ok_before and name or (last.name or ""), to = to and who or nil, copy = true,
    text = string.format("Not sent: %s. %s%s", how, o.kind == "track" and "The track is back as it was" or o.kind == "item" and "The item is back as it was"
      or (mirror.PART[o.kind]:gsub("^%l", string.upper)) .. ((o.kind == "env") and " is back as it was" or " are back as they were"),
      differed and (" (what differed: " .. differed .. ")") or "") })
end
-- One object of the pass: sent, put back, or nothing to do.
-- Plug-in chains and automation go once they've held still SETTLE_SECS (was 3 s), or at once after an undo point (W.one). settle_due: the
-- soonest one waiting is due then, and Live sync passes at that moment, not at the next 2 s pass. look_cc: each project's change count at the
-- end of its last look. rt-look
mirror.SETTLE_SECS = 0.3
mirror.look_cc = mirror.look_cc or {}
mirror.settle_due = nil
local function settle_at(t) if not mirror.settle_due or t < mirror.settle_due then mirror.settle_due = t end end
function W.one(w, o)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  local rev, h, evid, kord = mirror.known(proj, o.oid)
  local rk = tostring(proj) .. o.oid
  -- the colour has just started or stopped counting here (before 0.36 it never did; SWS auto-colouring switched on
  -- or off): a track that differs from the band's version only in colour isn't a change of ours. With the colour
  -- counting, the band's last change to the track says what it is, so every machine ends up with the same (0.36
  -- and 0.37 kept each machine's own: Bass I differed PC/laptop for good). One sent from a machine whose SWS chose
  -- its colours says nothing: ours stays.
  if rescheme and o.kind == "track" and rev and h ~= "" then
    local ev = event_file(room_dir, evid)
    local function sans_colour(t) -- (through JSON both, as the event's was: REAPER's 0.0 reads back as 0)
      return mirror.track_line(band.json_decode(band.json_encode(t)), opts.local_mix, false)
    end
    if ev and type(ev.state) == "table" and sans_colour(ev.state) == sans_colour(o.state) then
      if scheme ~= "own" and tonumber(ev.state.color) and not ev.state.autocolour and o.ptr and not mirror.tried_track(proj, o.ptr) -- (a colour look tried here stays: rt-nohold)
          and mirror.colour_key(band.color_in(ev.state.color)) ~= mirror.colour_key(band.track_colour(o.ptr)) then
        band.set_track_colour(o.ptr, band.color_in(ev.state.color))
        o.state = mirror.track_state(proj, o.ptr, opts.local_mix)
        o.hash = mirror.track_hash(o.state, opts.local_mix)
      end
      -- (somewhere else in the list too: that's for the look below, now the colour's out of it)
      if (ev.state.after or "") == (o.state.after or "") then remember(proj, o.oid, rev, o.hash, evid, kord); return end
    end
  end
  -- only its place differs from the band's, and not by this person's doing: not a change, and the band's hash is
  -- what's recorded, so everyone's fingerprint agrees whatever order their list has ended up in (once per state and event)
  if o.kind == "track" and rev and h ~= "" and not moved_set[o.oid] and not mirror.reopened[rk] then
    local key = o.hash .. "\0" .. tostring(evid)
    local a = mirror.track_alias[key]
    if a == nil then
      local ev = event_file(room_dir, evid)
      -- (a track Back restored has no hash on its event: it went out on every machine whose list differs: PC, 0.42.11)
      a = ev and type(ev.state) == "table"
        and mirror.same_line(ev.state, o.state, opts.local_mix) and (ev.hash or h) or false
      mirror.track_alias[key] = a
    end
    if a then
      o.hash = a
      if h ~= a then remember(proj, o.oid, rev, a, evid, kord); h = a end
    end
  end
  -- a chain whose hash differs from its event's only as this machine re-encoded it: the band's hash stands (once per
  -- chain text and event), so everyone's fingerprint agrees and nothing re-prints
  if o.kind == "fx" and rev and evid and evid ~= "" then
    local key = o.hash .. "\0" .. evid
    local a = mirror.fx_alias[key]
    if a == nil then
      local ev = event_file(room_dir, evid)
      a = ev and ev.hash and ev.hash ~= o.hash and type(ev.state) == "string" and mirror.fx_same(o.state, ev.state) and ev.hash or false
      mirror.fx_alias[key] = a
    end
    if a then
      o.hash = a
      if h ~= a then remember(proj, o.oid, rev, a, evid, kord); h = a end
    end
  end
  -- this chain reads differently here from what the band has, as a plug-in saves its data its own way, or is still
  -- loading (knobs still, and only just landed or opened): not a change of ours
  if o.kind == "fx" and rev and h ~= "" and h ~= o.hash then
    if mirror.fx_readback[rk] == o.hash then o.hash = h
    elseif reaper.time_precise() < math.max(mirror.fx_loading[rk] or 0, mirror.first_look[tostring(proj)] or 0) then
      -- (knobs as they were when it opened or landed, and the band's plug-ins: one added, removed or moved changes those,
      -- as freezing and unfreezing a track do)
      local ev = event_file(room_dir, evid)
      if ev and type(ev.state) == "string" and plugin_keys(ev.state) == plugin_keys(o.state) and mirror.fx_load_knobs[rk] == mirror.fx_params(o.ptr) and knobs_as_left(proj, o, rk) then
        mirror.fx_readback[rk] = o.hash; o.hash = h; knobs_agreed(proj, o, rk)
      end
    end
  end
  -- its data changed, but no window of it has been open, no knob moved and the plug-ins are the same: nobody did that. Superior Drummer writes
  -- different data after every playthrough, which claimed the Drums, went to everyone and re-printed every item, each pass (PC, 0.57.5)
  -- (its knobs as they landed or were first seen, or as of the last change that went out or landed. Not the knobs of every pass while it
  -- loads: a knob turned from a control surface in that minute then read as quiet, and never went out. Linux stress test, 0.58.77)
  if o.kind == "fx" and o.ptr and (mirror.fx_quiet[rk] == nil or reaper.time_precise() < math.max(mirror.fx_loading[rk] or 0, mirror.first_look[tostring(proj)] or 0)) then
    mirror.fx_quiet[rk] = mirror.fx_load_knobs[rk] or mirror.fx_params(o.ptr)
    mirror.fx_quiet_presets[rk] = mirror.fx_presets(o.ptr)
  end
  -- (and no preset was loaded: a script's or an action's, which opens no window and may move no knob, read as noise. Review, 0.58.89)
  if o.kind == "fx" and o.ptr and mirror.fx_quiet_presets[rk] == nil then mirror.fx_quiet_presets[rk] = mirror.fx_presets(o.ptr) end
  if o.kind == "fx" and rev and h ~= "" and h ~= o.hash and o.ptr and not mirror.fx_was_open(o.ptr) and mirror.fx_quiet[rk] == mirror.fx_params(o.ptr)
      and mirror.fx_quiet_presets[rk] == mirror.fx_presets(o.ptr) then
    local ev = event_file(room_dir, evid)
    if ev and type(ev.state) == "string" and plugin_keys(ev.state) == plugin_keys(o.state) and knobs_as_left(proj, o, rk) then
      mirror.fx_readback[rk] = o.hash; o.hash = h; knobs_agreed(proj, o, rk)
    end
  end
  -- a chain with a restless plug-in: the hash can't see its knobs move, so they're looked at here
  local knobs_moved, knobs
  if o.kind == "fx" and h == o.hash and mirror.knobs_count(o.state) then
    knobs = mirror.fx_params(o.ptr)
    if mirror.fx_knobs[rk] == nil then mirror.fx_knobs[rk] = knobs end
    -- (loaded, still as first seen, but not as left last time: turned while StudioSync wasn't running)
    if not mirror.fxk_ok[rk] and loaded(proj, rk) and mirror.fx_knobs[rk] == knobs and not knobs_as_left(proj, o, rk) then mirror.fx_knobs[rk] = "" end
    knobs_moved = mirror.fx_knobs[rk] ~= knobs
    -- (a patch or IR loaded in a modulated or restless plug-in moves no knob, and its data is out of the hash: when its window closes
    -- with the chain's text changed, the chain goes out. With an LFO running the text always differs, so closing it sends once. 0.58.91)
    if o.ptr and fx_open_now(o.ptr) then mirror.fx_open_text[rk] = mirror.fx_open_text[rk] or mirror.hash(o.state)
    elseif mirror.fx_open_text[rk] then
      if mirror.fx_open_text[rk] ~= mirror.hash(o.state) then knobs_moved = true end
      mirror.fx_open_text[rk] = nil
    end
  end
  if h == o.hash and not knobs_moved then
    if o.kind == "fx" and o.ptr and not mirror.fxk_ok[rk] and loaded(proj, rk) then knobs_agreed(proj, o, rk) end
    -- (mirror.receive doubted this chain, its knobs not as they last landed or went out, and this look finds it unchanged (a plug-in settling
    -- as it loads): the knobs as they are now are what it compares with from here, or the band's chain would wait on it for good)
    if o.kind == "fx" and o.ptr and mirror.fx_doubt[rk] then mirror.fx_last[rk], mirror.fx_doubt[rk] = mirror.fx_params(o.ptr), nil end
    -- (and no leftover print flag: it let the next real edit past the permission checks and hid it from Undo. Nothing held back either: what
    -- it was is the band's. Round 1 review, 0.59.45)
    mirror.reopened[rk], mirror.unsent[rk], mirror.auto[rk] = nil, nil, nil
    if o.kind == "track" then mirror.track_seen[rk] = o.state end -- (the band's, as it reads here: mirror.receive's keep_unsent. rt-fix9)
    held_back_clear(proj, o.oid)
    w.clean[o.oid] = true -- (nothing to do again until it or its record changes: a quick look leaves it out. rt-look)
    return
  end
  -- (put-backs count too: each rewrites an item or chain, and hundreds refused at once held REAPER up as sends did. 0.59.14, review)
  if w.sent + w.back > 0 and reaper.time_precise() - t_send > 0.25 then mirror.unsent[rk], mirror.more = true, true; return end
  -- recorded under a hash this machine no longer makes (before 0.34.4 a Mac hashed plug-in files and colours its
  -- own way): what's here IS the band's version, so it's re-anchored, not sent as a change of ours. Once per record.
  if rev and h ~= "" and not knobs_moved and not mirror.anchor_seen[rk .. "\0" .. h] then
    mirror.anchor_seen[rk .. "\0" .. h] = true
    local ev = event_file(room_dir, evid)
    -- (or its item, read the way this machine reads one now: 0.40.3 left selected notes and VELLANE out)
    -- (or its chain: a plug-in on it was found restless since)
    -- (the event's item normalized once for both checks below: 3 to 6 ms each on a big MIDI item, every edit. rt-look)
    -- (only on the track the band has it on: an item dragged or moved to another track with nothing else changed read as "the band's version,
    -- hashed anew", as both checks took the track it's on now, so the move was never sent. REAPER check, rt-edits)
    local on_its_track = ev and (ev.track == nil or ev.track == o.track)
    local ev_norm = on_its_track and ev.hash ~= o.hash and o.kind == "item" and type(ev.state) == "string" and mirror.normalize_item(ev.state)
    if ev and (ev.hash == o.hash or ev_norm and mirror.item_hash(o.track, ev_norm) == o.hash
        or o.kind == "fx" and type(ev.state) == "string" and mirror.fx_hash(ev.state) == o.hash
        -- (or the same but for its 14th digit, a tempo map put back: the Mac sent its Keys part as its own change, 0.42.8)
        or ev_norm and mirror.rounded(ev_norm) == mirror.rounded(o.state)) then
      remember(proj, o.oid, rev, o.hash, evid, kord); return
    end
    -- (an item with takes, the band's version from before which take plays travelled: its own author sends the pick it plays, so
    -- their comp reaches everyone; anyone else keeps theirs till it comes, and isn't sending or putting back a "change". 0.58.85)
    if on_its_track and o.kind == "item" and mirror.only_pick_new(o.track, o.state, ev.state) and not mine(evid) then
      remember(proj, o.oid, rev, o.hash, evid, kord); return
    end
  end
  if mirror.reopened[rk] and rev then -- opened without its last save: the band's version, not this older one
    say_once("reopened" .. tostring(proj), "this project was opened without its last save: what changed since is back as the studio has it")
    if h == "" then -- the band deleted it since: gone here too (2026-10-31: three deleted tracks came back on a reopen)
      mirror.reopened[rk] = nil
      if o.kind == "track" or o.kind == "item" then mirror.apply(proj, { obj = o.kind, oid = o.oid, gone = true }, media, opts.local_mix) end
      -- (its plug-ins, automation and items were read before it went: W.each passes over them, or each threw on the dead track,
      -- "bad argument #1 to 'TrackFX_GetCount' (MediaTrack expected)". P1-6, rt-r2)
      if o.kind == "track" then w.gone_now = w.gone_now or {}; w.gone_now[o.oid] = true end
      w.back = w.back + 1
      return
    end
    return put_back(o, rev, evid, { name = perm_name(o, by_oid) })
  end
  -- (an empty part nobody has sent. Nor one gone from the band and just back with its track: its plug-ins were still on
  -- their way, and "none" went out as this machine's change, taking the Neve from everyone: Mac, 0.42.6)
  -- (nothing of ours waits then: a burst had marked it, and the band's chain never landed, as it waited for ours: PC, 0.42.9)
  if o.state == "" and o.kind ~= "track" and o.kind ~= "item" then
    if not rev then mirror.unsent[rk] = nil; w.clean[o.oid] = true; return end
    -- (recorded as gone, by its own delete or its track's: an empty part is that, not news. Its track deleted and brought back bare (Restore,
    -- Undo, Ctrl+Z) sent "no plug-ins, no automation, no sends" to everyone over the real ones. Full review, 0.59.44)
    if h == "" then
      mirror.unsent[rk] = nil
      -- (and brought now, if its last change isn't a deletion: a part that couldn't land when its track came back (playing, the tab behind)
      -- was retried only when fingerprints differed, so with every computer playing all stayed bare. One cached read a look per bare part.
      -- Round 2 review, 0.59.46)
      local ev = (evid or "") ~= "" and event_file(room_dir, evid)
      if ev and not ev.gone and type(ev.state) == "string" and ev.state ~= "" then
        local ok, applied, hash = pcall(mirror.apply, proj, ev, media, opts.local_mix)
        if ok and applied then remember(proj, o.oid, ev.rev, hash or "", ev.id, mirror.order_of(ev)) end
      else w.clean[o.oid] = true end -- (nothing to bring: done until it changes. A bring that didn't land is tried every look)
      return
    end
  end
  -- plug-ins and automation: only while stopped, once settled (not a whole chain per knob turn, or an envelope per
  -- point drawn)
  if o.kind == "fx" or o.kind == "env" then
    local key = tostring(proj) .. o.oid -- (per tab: a side room's copy shares the oid)
    local f = mirror.fx_seen[key]
    mirror.unsent[rk] = true -- (until it goes: the band's change to it waits)
    if playing then return end
    mirror.unsettled = true -- (Live sync looks again soon)
    if not f or f.hash ~= o.hash or f.knobs ~= knobs then
      local now, cc = reaper.time_precise(), reaper.GetProjectStateChangeCount(proj)
      local n = { hash = o.hash, knobs = knobs, since = now, text = o.state, cc = cc, flips = 0, began = now }
      if o.kind == "fx" then
        n.params = mirror.fx_params(o.ptr)
        -- it changed again with its knobs still and nothing else happening: restless, if it goes on
        if f and f.text and f.hash ~= o.hash and f.cc == cc and f.params == n.params then n.flips, n.began = (f.flips or 0) + 1, f.began or now end
        if n.flips >= mirror.RESTLESS_FLIPS and now - n.began >= mirror.RESTLESS_SECS then
          local names = mirror.fx_differing(f.text, o.state)
          if mirror.restless_add(names) then
            band.log(table.concat(names, ", ") .. " keeps changing its saved data by itself: StudioSync goes by its knobs from now on")
            o.hash = mirror.fx_hash(o.state)
            knobs = mirror.fx_params(o.ptr)
            mirror.fx_knobs[rk] = knobs
            -- (its knobs didn't move: what it reads as now stands for the band's. Going by its knobs isn't a change, and it went out
            -- to everyone as one, at every open where it was found again. 0.59.8. Only if the band's chain has the same plug-ins and
            -- its knobs are as left: a plug-in just added, restless from the start, never went out. Review, 0.59.9)
            local ev = rev and h ~= "" and event_file(room_dir, evid)
            if ev and type(ev.state) == "string" and plugin_keys(ev.state) == plugin_keys(o.state) and knobs_as_left(proj, o, rk) then
              mirror.fx_readback[rk] = o.hash
            end
            n = { hash = o.hash, knobs = nil, since = now }
          end
        end
      end
      mirror.fx_seen[key] = n
      -- (an undo point since the last look: the edit is finished (a drop, a script's undo block, a typed value), so it goes now. A drag isn't
      -- looked at until the drop, and a knob turned from a control surface makes no undo point, so that settles. Not on a project's first look,
      -- while its plug-ins load. An envelope point set from a script took 4.2 s to go: 3 s of settling, then the next 2 s pass. rt-look)
      local last_cc = mirror.look_cc[tostring(proj)]
      if not (n.text and n.flips == 0 and last_cc and cc ~= last_cc) then settle_at(now + mirror.SETTLE_SECS); return end
    elseif reaper.time_precise() - f.since < mirror.SETTLE_SECS then settle_at(f.since + mirror.SETTLE_SECS); return end
  end
  local name = perm_name(o, by_oid)
  -- someone else is working on it right now (lib/presence.lua): said, never put back. Both changes go out and are merged everywhere (items by
  -- line and note, tracks by setting, automation by point: mirror.MERGES); where both changed the same thing the later stands, and the other
  -- gets "Use mine". The 15 s hold put your edit back, which outlasted the conflict once changes came in 0.25 s. (James, 2026-11-20: rt-merge)
  local holder = rev and opts.held and opts.held(o.oid)
  if holder then
    local k, now = "editing " .. tostring(proj) .. o.oid .. "\0" .. tostring(holder), reaper.time_precise()
    if not mirror.said[k] or now - mirror.said[k] > 30 then
      mirror.said[k] = now
      band.log(string.format("%s is editing %s too: both changes go in, and where you both change the same thing the later one stands", holder,
        o.kind == "track" and ("track " .. (name ~= "" and name or "(unnamed)")) or ((o.kind == "item" and "that item" or mirror.PART[o.kind]) .. " on " .. (name ~= "" and name or "an unnamed track"))))
    end
  end
  local last = rev and event_file(room_dir, evid) or nil
  -- (an item's or part's track by the name it has now, not the one its last change was made under: a claimed Keys renamed Piano let anyone
  -- delete its older items, and refused its claimant on the rest. A view: the read event isn't changed. Full review, 0.59.44)
  local now_name = last and o.kind ~= "track" and last.track and by_oid[last.track] and by_oid[last.track].state.name
  if now_name and now_name ~= last.name then last = setmetatable({ name = now_name }, { __index = last }) end
  -- (a track whose lanes alone read differently from the band's version here (their names, which play), on a look with no edit of this
  -- person's behind it, after the project's first: REAPER's own reading, not a change. A fresh REAPER read XT Rec A's lane names as 1 to 8 and
  -- their play states its own way some seconds after opening, with nobody editing, and that went out and replaced the band's lane names on
  -- every computer (LinuxBox2, rt-r1; left by rt-fix6a, which stopped the auto-claim). What's here stands for the band's version, said once;
  -- a comp or a lane renamed by hand has an edit behind it and goes out as before, as does what a project's first look finds changed while
  -- Live sync was off. Only with Live sync's edit time (opts.edited_at). rt-converge)
  if o.kind == "track" and last and not last.gone and type(last.state) == "table" and w.edited == false and not w.first_here
      and mirror.same_but_lanes(o.state, last.state, opts.local_mix) then
    say_once("lanes" .. rk, string.format("%s: its lanes read differently here than the studio has them, with no edit of yours: left as they are, and not sent",
      (o.state.name or "") ~= "" and o.state.name or "a track"))
    mirror.unsent[rk] = nil
    return remember(proj, o.oid, rev, o.hash, evid, kord)
  end
  -- (on the track the band has it on: moved to another track with nothing else changed, it's a change. REAPER check, rt-edits)
  if o.kind == "item" and last and (last.track == nil or last.track == o.track) and type(last.state) == "string" and type(o.state) == "string"
      and mirror.same_but_labels(o.state, last.state) then
    return remember(proj, o.oid, rev, last.hash or o.hash, evid, kord) -- (the event's hash: fingerprints stay the same as everyone's)
  end
  -- (a track renamed to a name someone else has claimed: refused. Claims go by name, so it took their claim over, or lost yours, by whose date
  -- was newer. Not in Everyone, where claims don't hold. James: refuse. Round 1 review, 0.59.45)
  if o.kind == "track" and last and not last.gone and type(last.name) == "string" and name ~= "" and last.name:lower() ~= name:lower()
      and opts.mode ~= "everyone" and w.is_claimed and w.is_claimed(name) then
    local who = w.owner_of and w.owner_of(name)
    if who and who ~= me then
      return put_back(o, rev, evid, { name = last.name, text = string.format("%s has claimed %s: pick another name", tostring(who), name) })
    end
  end
  -- allowed where it is now, and where it was (moving an item off a claimed track, or renaming a claimed track,
  -- mustn't slip past the claim)
  -- (a wet take StudioSync just made: whoever is to print it may send it, whatever the claims: prints.printer)
  local auto = o.kind == "item" and mirror.auto[tostring(proj) .. o.oid]
  local ok_now = auto or allowed(o, name, o.pos) or (o.kind == "track" and last ~= nil and allowed(o, last.name or "", last.pos))
  -- (or it answers a change that wasn't its sender's to make: mirror.set_back. A claim on the name that change gave it doesn't stand in front)
  local ok_before = auto or not last or last.gone or allowed(o, last.name or "", last.pos) or (mirror.set_backs[rk] or {}).id == evid
  if ok_now and ok_before then return W.send(w, o, rk, rev, evid, kord, last, name, knobs) end
  -- (held back only by a bandmate's auto-claim, Claims mode: an item, automation or track settings that merge with their change go out, and
  -- only an edit to the same note, point or setting asks them. Asked, two people adding notes to one part waited 30 s and were put back:
  -- Cross Test, 0.59.49.70. rt-merge)
  -- (not a track's rename: a claim holds a track by its name, so a new name takes it out of the claim. Renamed on a bandmate's auto-claim, it
  -- went out as a setting they hadn't touched, their claim stayed on the old name and the renamer auto-claimed the new one. REAPER check,
  -- 0.59.49.73: asked for, as any edit to a lasting claim. rt-claims)
  local renamed = o.kind == "track" and last ~= nil and not last.gone and type(last.name) == "string" and last.name:lower() ~= name:lower()
  if opts.soft and not renamed and mirror.MERGES[o.kind] and type(o.state) == (o.kind == "track" and "table" or "string") then
    local by_now = not ok_now and opts.soft(name, o.pos)
    local by_before = not ok_before and last and opts.soft(last.name or "", last.pos)
    if (ok_now or by_now) and (ok_before or by_before) then
      local clash = false
      for _, by in ipairs({ by_now or by_before, (by_now and by_before and by_before ~= by_now) and by_before or nil }) do -- (moved from one's to another's: both)
        clash = clash or (last ~= nil and mirror.clashes(room_dir, o.kind, o.state, last, by))
      end
      if not clash then return W.send(w, o, rk, rev, evid, kord, last, name, knobs) end
    end
  end
  return W.refuse(w, o, rk, rev, evid, kord, last, name, ok_before)
end
function W.prints(w)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  -- MIDI prints: an item whose newest change is this person's gets a fresh print once its notes, length or the
  -- band's plug-in chain on its track changed (it goes out on the next pass). Only theirs, so two machines never take
  -- turns re-printing one item. Rendering needs this tab in front and the transport stopped; two per pass at most.
  if reaper.EnumProjects(-1) == proj and not playing and not mirror.more then -- (prints wait until a burst has gone)
    local prints, made = require("prints"), 0
    prints.begin_look() -- (each track's routing and plug-ins worked out once for all its items, not once each: 0.59.19)
    w.ara = prints.watch_ara(proj, w.ara_tracks) -- (a Melodyne window closed: that take gets a new print below)
    pcall(prints.release_held, proj) -- (FX held off for a part that's gone)
    pcall(require("libraries").tick, proj, cfg) -- (which of the song's sounds and small files this computer has, once a minute: lib/libraries.lua. rt)
    -- takes become lanes, by whoever owns them (their newest change, or not sent yet). Once caught up: an old file reopened
    -- split its old comps and sent them before the band's newer versions had landed (laptop, 0.42.9)
    if mirror.has_takes(w.print_tracks) and w.pending() == 0 then
      prints.takes_to_lanes(proj, function(it)
        local _, _, k = mirror.known(proj, itm_oid(it))
        return not k or k == "" or mine(k)
      end, cfg.root, w.print_tracks) -- (only while the studio's setting is on: Settings > Studio. James, rt)
    end
    local here = { [me] = true } -- (bandmates in the song now: who may print in place of whoever changed an item)
    for u in pairs(opts.here or {}) do here[u] = true end
    local keys_of = {} -- track -> the plug-in keys its prints go through
    -- (a restless plug-in's knobs aren't in its chain's hash, but they change the sound: Disperser's Amount moved
    -- and went out, and the print stayed as it was: Mac, 0.42.1. Once per chain a pass)
    local function sounds(f)
      if not f then return nil end
      if f.print_key == nil then f.print_key = mirror.knobs_count(f.state) and (f.hash .. mirror.hash(mirror.fx_params(f.ptr))) or f.hash end
      return f.print_key
    end
    -- ("nothing to print" remembered per item, by its state, its version, what its print goes through (its track's chain and a routed
    -- instrument's, restless knobs included) and who's here, and looked at again after a minute: every item was walked on every look, 60 to 90
    -- ms at 3,000 MIDI items. Round 1 review, 0.59.45)
    local who_here = {}
    for u in pairs(here) do who_here[#who_here + 1] = u end
    table.sort(who_here)
    who_here = table.concat(who_here, "\0")
    local now = reaper.time_precise()
    -- (the alert bar's Try again forgets "nothing to print": a silent print waited up to a minute for it. Round 2 review, 0.59.46)
    local retry = reaper.GetExtState(band.SECTION, "prints retry")
    if retry ~= mirror.print_retry_seen then mirror.print_retry_seen, mirror.print_quiet = retry, {} end
    -- (quiet_min: the oldest "nothing to print" an item has, quiet_missing: one has none or wasn't looked at; a quick look goes by them to look
    -- at only the changed items until one comes due. rt-look)
    local quiet_min, quiet_missing = math.huge, false
    local function note_quiet(o, key) -- (not while any print waits its turn or renders: one picked up later reads as nothing to do until then)
      if not (prints.waiting() or require("bgrender").waiting()) then mirror.print_quiet[tostring(proj) .. o.oid] = { key = key, at = now }
      else quiet_missing = true end
    end
    -- (a quick look: only an item that changed, whose track or its plug-ins did, a restless chain's, or one not found quiet in the last minute.
    -- Anything that changes every item's answer (who's here, any chain or routing, the last look not getting here) looks at them all. rt-look)
    local want = mirror.print_want(w, who_here, now)
    w.prints_who = who_here
    for _, o in ipairs(objs) do
      local kh, kev, fx, dfx, qkey
      if made < 2 and o.kind == "item" and (not want or want(o)) and reaper.ValidatePtr2(proj, o.ptr, "MediaItem*") then
        kh, kev = select(2, mirror.known(proj, o.oid))
        fx = by_oid["F" .. o.track:sub(2)]
        local dest = prints.route(reaper.GetMediaItem_Track(o.ptr)) -- (an instrument on another track: its chain is part of the print)
        dfx = dest and by_oid["F" .. mirror.track_oid(dest):sub(2)]
        qkey = tostring(o.hash) .. "\0" .. tostring(kev) .. "\0" .. tostring(sounds(fx)) .. "\0" .. tostring(sounds(dfx)) .. "\0" .. who_here
        local q = mirror.print_quiet[tostring(proj) .. o.oid]
        if q and q.key == qkey and now - q.at < 60 then qkey, quiet_min = nil, math.min(quiet_min, q.at) end -- (else it's noted again now, below)
      elseif made >= 2 and o.kind == "item" then quiet_missing = true -- (not looked at this time: all of them next time)
      end
      if qkey then
        -- who refreshes a print (prints.printer): the track's printer if they're here and can, else whoever changed
        -- it last if they can, else the first one here who can. Whoever changed it last but may not change it now
        -- (someone claimed the track since) is stood in for by the one who may (laptop, 2026-10-31: its re-print of a
        -- claimed track's item was put back three times).
        local name = perm_name(o, by_oid)
        local may = false
        -- (a side room starts as a copy: what hasn't changed in it keeps the print it came with. Another machine's reading of the
        -- same chain differs, so whoever opened the room rendered the Drums again: laptop, 0.42.5)
        local same_as_parent = false
        if room ~= "main" and fx then
          local _, _, fev = mirror.known(proj, fx.oid)
          local direct = require("direct") -- (a change that came over the direct link is this room's too: James, 0.60.0-rt)
          same_as_parent = not reaper.file_exists(direct.path(nil, room_dir .. "/events", tostring(kev) .. ".json")) and not reaper.file_exists(direct.path(nil, room_dir .. "/events", tostring(fev) .. ".json"))
        end
        -- (not an item that differs from the band's and isn't yours to change: its put-back waits (MIDI editor open, a recording on its way),
        -- and a print of the refused notes went out with them past the claim. Cost: one compare an item. Round 1 review, 0.59.45)
        local refused_here = kh ~= o.hash and not allowed(o, name, o.pos)
        local relay
        if fx and kev and not same_as_parent and not refused_here then
          local tr = reaper.GetMediaItem_Track(o.ptr)
          local author = mine(kev) and me or (event_file(room_dir, kev) or {}).user
          if type(author) ~= "string" then author = nil end
          if author and author ~= me and not opts.can(author, name, o.pos) and allowed(o, name, o.pos) then author = me end
          keys_of[tr] = keys_of[tr] or prints.track_keys(tr)
          local function can(u) if u == me then return prints.track_plays(tr, true) end return prints.has(cfg, u, keys_of[tr]) end
          local printer = prints.printer(name, author, here, opts.printers or {}, can)
          may = printer == me
          -- (nobody here has the whole chain: it may print in stages, each on a computer that has its part. lib/prints.lua relay_stage,
          -- James 0.59.49. The chains' text for linked knobs, which keep a part out)
          if not printer then relay = { author = author, here = here, me = me, chains = { fx.state, dfx and dfx.state } } end
        end
        if may or relay then
          local ok, did, waiting = pcall(prints.refresh, proj, o.ptr, media, sounds(fx), sounds(dfx), cfg, relay)
          if ok and did then made = made + 1; mirror.auto[tostring(proj) .. o.oid] = true -- (its next send is StudioSync's, not theirs)
          elseif ok and not waiting then note_quiet(o, qkey) else quiet_missing = true end -- (a stage waiting on a computer that's here: looked at again next pass)
        else note_quiet(o, qkey) end
      end
    end
    -- (a print just went on: out on the very next pass. It waited for the 10-second look: 9 s on a print that was
    -- already there, 18 s on a rendered one: PC, 0.41.1)
    if made > 0 then mirror.more = true end
    local L = w.look
    if want and L then quiet_min, quiet_missing = math.min(quiet_min, L.quiet_min or -math.huge), quiet_missing or L.prints_missing end
    w.quiet_min, w.prints_missing = quiet_min, quiet_missing
    prints.end_look()
  end
end
mirror.gone_why = mirror.gone_why or {} -- tostring(proj) .. oid -> "user" (a deletion of this person's) or "not": W.gone's judgement, until seen again
mirror.empty_since = mirror.empty_since or {} -- tostring(proj) -> when a look first found it with no tracks and the studio's records (W.gone)
mirror.EMPTY_SECS = 10 -- seconds an emptied project is left as it is before the studio's tracks are put back (W.gone, rt-guard)
mirror.guard_said = mirror.guard_said or {}
mirror.order_owed = mirror.order_owed or {} -- tostring(proj) -> tracks W.gone put back wait for mirror.keep_order (mirror.watch, at its end)
function mirror.guard_say(pk, now, text) -- (once a minute a project at most: a put-back that waits would say it every pass)
  if now - (mirror.guard_said[pk] or -math.huge) >= 60 then mirror.guard_said[pk] = now; require("band").log(text) end
end
function W.gone(w)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  local undeleted = {}
  -- gone here: deleted (sent, if allowed) or put back
  local i, gone = 0, {}
  -- (a quick look: only what was here at the last look, was left gone then, or was recorded since, not every record. rt-look)
  local cand, ci = w.gone_oids, 0
  w.gone_seen = {}
  while true do
    local ok, oid
    if cand then ci = ci + 1; oid = cand[ci]; ok = oid ~= nil
    else ok, oid = reaper.EnumProjExtState(proj, mirror.SEC, i) end
    if not ok then break end
    i = i + 1
    local rev, h, evid, kord = mirror.known(proj, oid)
    -- (object records only, "rev|hash|event|order": the section also keeps "fxk <oid>" and "master fxen held", which read as gone and were
    -- overwritten with "0|||" every pass: knob checks failed after the first minute and the band's master FX switch went back on. Review, 0.58.92)
    if not seen[oid] and rev and h ~= "" then
      w.gone_seen[#w.gone_seen + 1] = oid
      local is_it, stray, standin
      if oid:sub(1, 1) == "I" then is_it, stray, standin = mirror.local_copy_is_it(proj, oid) end
      if is_it then
        -- still here, on a track of this machine's own (Real time, "yours, not sent"): not deleted. Sent as gone, it
        -- went for everyone (review, 2026-10-31); the band keeps it where it was
        say_once("local" .. oid, "an item of the studio's is on a track of your own: it isn't sent from there, and the others keep it where it was (move it back to a studio track to change it)")
      else
        -- (a copy that kept the deleted original's id is yours alone from now: left with it, the band's next change or a restore of the
        -- original landed on it. Round 1 review, 0.59.45)
        -- (a stand-in for it goes with it: grey for good otherwise. One is made again if a version of it still has to land. rt-converge)
        if stray and standin then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(stray), stray)
        elseif stray then reaper.GetSetMediaItemInfo_String(stray, "P_EXT:band_oid", "", true) end
        gone[#gone + 1] = { oid = oid, rev = rev, evid = evid, order = kord }
      end
    end
  end
  -- tracks first: a bandmate's track deleted here came back without its items, which had nowhere to land yet, and that
  -- machine stayed different until the owner next changed them (laptop, 0.42.2)
  local function gone_rank(g) return g.oid:sub(1, 1) == "T" and 1 or 2 end
  -- (and tracks in the studio's order: one put back lands under the track its version names, so that one has to be back first. rt-guard)
  local in_order = {}
  for _, g in ipairs(gone) do
    if g.oid:sub(1, 1) == "T" then
      local best = mirror.read_order(room_dir)
      for k, x in ipairs(best and best.list or {}) do in_order[x] = k end
      break
    end
  end
  table.sort(gone, function(a, b)
    if gone_rank(a) ~= gone_rank(b) then return gone_rank(a) < gone_rank(b) end
    local ra, rb = in_order[a.oid] or math.huge, in_order[b.oid] or math.huge
    if ra ~= rb then return ra < rb end
    return a.oid < b.oid
  end)
  -- (rt-guard: a deletion goes out only with something to show this person made it here, this session: not a new opening, and an edit of
  -- theirs behind the look (mirror.user_edited, as auto-claims judge). A project with no tracks at all needs a new undo point of someone's on
  -- top, whatever the edit count says (a project read while closing or loading moves it). Each absence is judged once, on the look that
  -- first misses it (mirror.gone_why), so a burst's rest and a deletion held for a claimer's answer go as judged. Without it the band's last
  -- version is put back and nothing is sent; an emptied project is left alone for EMPTY_SECS first. On 11-23 a look sent deletions of
  -- Cross Test's 3 tracks and 10 items for a project it read with its records and none of its objects: docs/rt/rt-reopen.md)
  local pk, now = tostring(proj), reaper.time_precise()
  for k in pairs(mirror.gone_why) do if k:sub(1, #pk) == pk and seen[k:sub(#pk + 1)] then mirror.gone_why[k] = nil end end
  -- (what each deleted track held: its items, missing with it, named on the track's deletion (`items`), so each receiver keeps only work of
  -- its own the deleter never saw. rt-sync2 section 1, rt-sync2b)
  local held_items = {}
  for _, g in ipairs(gone) do
    if g.oid:sub(1, 1) == "I" and (g.evid or "") ~= "" then
      local e = event_file(room_dir, g.evid)
      local t = e and e.track
      if type(t) == "string" then held_items[t] = held_items[t] or {}; table.insert(held_items[t], g.oid) end
    end
  end
  local hold_empty, guarded = false, 0
  if #gone == 0 then mirror.empty_since[pk] = nil
  else
    local tracks_here = false
    for t = 0, reaper.CountTracks(proj) - 1 do if not local_track(reaper.GetTrack(proj, t)) then tracks_here = true; break end end
    local evidence = not w.opened_now and w.edited ~= false and (tracks_here or w.new_point == true)
    if tracks_here or evidence then mirror.empty_since[pk] = nil
    else
      mirror.empty_since[pk] = mirror.empty_since[pk] or now
      hold_empty = now - mirror.empty_since[pk] < mirror.EMPTY_SECS
      if hold_empty then mirror.guard_say(pk .. " empty", now, "this project has no tracks but still holds the studio's: nothing is sent to the others for it, and if it stays empty the studio's tracks come back") end
    end
    for _, g in ipairs(gone) do
      local k = pk .. g.oid
      mirror.gone_why[k] = mirror.gone_why[k] or (evidence and "user") or (not hold_empty and "not") or nil
    end
  end
  for _, g in ipairs(gone) do
    local gk = pk .. g.oid
    if hold_empty and mirror.gone_why[gk] == nil then goto next_gone end -- (an emptied project, waiting: nothing judged or changed)
    if w.sent + w.back > 0 and reaper.time_precise() - t_send > 0.25 then mirror.more = true; break end -- (the rest next pass, as above)
    -- (gone here, whatever happens to it below: nothing of ours waits on it. A flag left on a deleted track's plug-ins held a bandmate's
    -- restored chain back for good, and an empty chain won. 0.59.14, review)
    mirror.unsent[tostring(proj) .. g.oid] = nil
    held_back_clear(proj, g.oid)
    local ok, err = pcall(function()
      local last = event_file(room_dir, g.evid)
      -- (its last change is named but isn't here, so the deletion can't say what it was or check who may make it. Taken for gone, it was deleted
      -- here only, never sent and never healed: the projects differed for good. Left as it was instead, said once: the band's next change to it
      -- brings it back here. Review, 0.58.53)
      if not last and (g.evid or "") ~= "" then
        return say_once("gone" .. g.oid, "a deleted " .. (g.oid:sub(1, 1) == "T" and "track" or "item") ..
          " couldn't go to the others (its history isn't on this computer yet), so it may come back: delete it again once Live sync has caught up")
      end
      if not last then -- nothing ever sent: forgotten, not resurrected or repeated
        return remember(proj, g.oid, g.rev or 0, "", g.evid)
      end
      local o = { kind = last.obj or (g.oid:sub(1, 1) == "T" and "track" or "item"), oid = g.oid, track = last.track, state = last.state }
      local name = last.name or ""
      if o.kind ~= "track" and o.track and by_oid[o.track] then name = by_oid[o.track].state.name or name end -- (its track's name now, as W.one. 0.59.44)
      local _, th, tev = mirror.known(proj, o.track or "")
      local asked_memo -- (Claims: the ask, made once, below; false lets the deletion go: an auto-claimer the link can't reach. rt-fix6a)
      local function ask_once()
        if not asked_memo then asked_memo = { nil, nil }; if opts.ask then asked_memo = { opts.ask(name, last.pos) } end end
        return asked_memo[1], asked_memo[2]
      end
      if kept_back[o.track or ""] then -- (on a folder or bus that was refused above: it comes back with it)
        put_back(o, g.rev, g.evid, { name = name })
      elseif mirror.PART[o.kind] and w.back_tracks[o.track or ""] then -- (its track's deletion was refused just now: it comes back whole, not
        -- bare with its plug-ins, automation and sends marked gone. Full review, 0.59.44)
        put_back(o, g.rev, g.evid, { name = name })
      elseif mirror.PART[o.kind] and w.held_tracks[o.track or ""] then -- (its track's deletion waits for an answer, below: so do they)
        mirror.unsent[tostring(proj) .. g.oid] = true
      elseif mirror.PART[o.kind] then -- (its track went: the track's own deletion covers it)
        remember(proj, g.oid, (g.rev or 0) + 1, "", g.evid)
      elseif o.kind == "item" and th == "" and not mine(tev)
          and not mirror.find(proj, "track", o.track) then
        -- the band deleted its track, and the item went with it here before the item's own delete arrived: theirs,
        -- not ours (the Mac put back 226 of a deleted track's items one by one: laptop's restore, 0.34.4). Same rev,
        -- so the item's delete still lands when it comes.
        -- (and the same order: recorded without it, an earlier version of the same rev that arrived after (one session's first change, a
        -- bandmate's made at once) beat the record and brought the item back, on this computer alone. rt-converge)
        remember(proj, g.oid, g.rev or 0, "", g.evid, g.order)
      elseif mirror.gone_why[gk] ~= "user" then -- (no deletion of this person's behind it: the band's version back, nothing sent. rt-guard, above)
        -- (its items and parts come back with it, and it goes to its place in the studio's order: it landed wherever apply put it, which the
        -- order list didn't say, and a late joiner had another order. The soak's reopen, seed 37)
        if o.kind == "track" then w.back_tracks[g.oid] = true; mirror.order_owed[pk] = true end
        guarded = guarded + 1
        local was_back = w.back
        put_back(o, g.rev, g.evid, { name = name })
        if w.back > was_back then mirror.gone_why[gk] = nil end -- (it's back: if it goes again, that's judged afresh)
      elseif allowed(o, name, last.pos) or ask_once() == false then
        -- (the clock past what it deletes, and an owner's step, as W.send does: a restart behind the version's clock read as made apart, and
        -- a non-owner's later edit brought an owner's deletion back. Round 1 review, 0.59.45)
        mirror.hlc_seen(last.hlc)
        local unasked = asked_memo ~= nil and asked_memo[1] == false or nil -- (past an auto-claim that couldn't be asked: as W.send says it)
        -- (a track's deletion names the track it sat under, `was_after`: where it goes back if the deletion is undone, mirror.revert)
        local was_after
        if o.kind == "track" and type(w.order_was) == "string" then
          local prev = ""
          for x in w.order_was:gmatch("[^,]+") do
            if x == g.oid then was_after = prev; break end
            prev = x
          end
        end
        local items
        if o.kind == "track" then
          items = held_items[g.oid] or {}
          table.sort(items)
          if #items > mirror.ITEMS_MAX then items = nil end
        end
        local ev = { type = "obj", obj = o.kind, oid = g.oid, rev = mirror.next_rev(g.rev, mirror.owned(opts, me, name, last.pos, w.is_claimed)), base = g.rev or 0, base_ev = (g.evid or "") ~= "" and g.evid or nil, gone = true, track = o.track, name = name, pos = last.pos, act = w.act, unasked = unasked, was_after = was_after, items = items }
        local id = sync.post(cfg, song, room, ev)
        if o.kind == "track" and opts.sent then pcall(opts.sent, o, name, ev) end -- (Claims: your auto-claim on a track you deleted goes with it. rt-converge)
        remember(proj, g.oid, ev.rev, "", id, mirror.order_of(ev)) -- (with its order: a racing edit is settled alike everywhere)
        mirror.unsent[tostring(proj) .. g.oid] = nil
        w.sent = w.sent + 1
        if o.kind == "track" and holds[g.oid] then -- (nobody else's: it goes, and is said)
          local names = {}
          for _, x in ipairs(holds[g.oid].oids) do if holds[g.oid].names[x] then names[#names + 1] = holds[g.oid].names[x] end end
          band.log(string.format("you deleted %s, which held %s: they aren't in it any more", name ~= "" and name or "a track", table.concat(names, ", ")))
        end
      else
        -- (Claims: someone else's claim is asked for first, as an edit to it is (W.refuse): deleting several of their items or tracks at once
        -- went to the old suggestion instead. Held meanwhile: still gone here, nothing sent, the band's changes to it waiting; Release sends the
        -- deletion on a later look, Keep or no answer puts it back with the words. One ask per claim, however many it covers. rt-edits)
        local asked, quiet = ask_once()
        if asked == true then
          mirror.unsent[tostring(proj) .. g.oid] = true
          if o.kind == "track" then w.held_tracks[g.oid] = true end
          return
        end
        if type(asked) == "string" then
          if o.kind == "track" then w.back_tracks[g.oid] = true end
          return put_back(o, g.rev, g.evid, { name = name, text = asked, quiet = quiet })
        end
        local who = w.owner_of and w.owner_of(name, last.pos)
        local to = propose(o, g.rev, who, name, last.pos, name, true)
        if o.kind == "track" then w.back_tracks[g.oid] = true end
        if o.kind == "item" and not to then -- (one line for all of a track's: a deleted track's items each said so)
          undeleted[name] = (undeleted[name] or 0) + 1
          put_back(o, g.rev, g.evid, { name = name })
        else
          put_back(o, g.rev, g.evid, { name = name, text = string.format("%s on %s isn't yours to delete: it's back%s",
            o.kind == "track" and "that track" or "that item", name ~= "" and name or "an unnamed track", to and (", and suggested to " .. who) or "") })
        end
      end
    end)
    if not ok then held_back_set(proj, g.oid); say_once("err" .. g.oid, "mirror sync skipped " .. g.oid .. ": " .. tostring(err)) end
    if select(2, mirror.known(proj, g.oid)) == "" then mirror.gone_why[gk] = nil end -- (settled gone: sent, or the band's already)
    ::next_gone::
  end
  if guarded > 0 then
    mirror.guard_say(pk, now, string.format("%d track(s) or item(s) of the studio's weren't in this project, with no deletion of yours behind it (a file older " ..
      "than the studio, or a project read while closing or loading): they're back as the studio has them, and nothing was sent to the others", guarded))
  end
  for name, n in pairs(undeleted) do
    sync.put_back(string.format("%s on %s %s yours to delete: %s back", n == 1 and "that item" or (n .. " items"), name ~= "" and name or "an unnamed track", n == 1 and "isn't" or "aren't", n == 1 and "it's" or "they're"))
  end
end
function W.remember_holds(w)
  local band, sync, proj, cfg, song, room, opts, me = w.band, w.sync, w.proj, w.cfg, w.song, w.room, w.opts, w.me
  local room_dir, media, objs, by_oid, holds, playing = w.room_dir, w.media, w.objs, w.by_oid, w.holds, w.playing
  local mine, allowed, say_once, others_claims, put_back, propose, bus_note = w.mine, w.allowed, w.say_once, w.others_claims, w.put_back, w.propose, w.bus_note
  local suggest, kept_back, credit, moved_set, seen, t_send, scheme, rescheme = w.suggest, w.kept_back, w.credit, w.moved_set, w.seen, w.t_send, w.scheme, w.rescheme
  do -- (what each track holds, for the next look: a deleted track's can't be read any more)
    local list, names, silent = {}, {}, {}
    for _, o in ipairs(objs) do
      if o.kind == "track" then
        names[o.oid] = o.state.name
        if tostring(o.state.mainsend) == "0" and not mirror.said["hwout" .. tostring(proj) .. o.oid]
            and reaper.GetTrackNumSends(o.ptr, 0) == 0 and reaper.GetTrackNumSends(o.ptr, 1) == 0 then silent[#silent + 1] = o end
        -- shortcut: VCA groups 1 to 32 only (the rest are a second pair of calls): a VCA in 33 to 64 isn't seen as holding anything.
        list[#list + 1] = { oid = o.oid, parent = o.state.parent, recv = by_oid["R" .. o.oid:sub(2)] and by_oid["R" .. o.oid:sub(2)].state,
          lead = reaper.GetSetTrackGroupMembership(o.ptr, "VOLUME_VCA_LEAD", 0, 0), follow = reaper.GetSetTrackGroupMembership(o.ptr, "VOLUME_VCA_FOLLOW", 0, 0) }
      end
    end
    local now = {}
    for oid, oids in pairs(mirror.feeders(list)) do
      local held = {}
      for _, x in ipairs(oids) do held[x] = names[x] end
      now[oid] = { oids = oids, names = held, name = names[oid] or "" }
    end
    mirror.holds[tostring(proj)] = now
    -- A bandmate's track with its master send off and no send here plays silent: hardware outputs never travel. Said once, once caught up
    -- (its sends may still be on their way before). 0.59.14
    if #silent > 0 and w.pending() == 0 then
      for _, o in ipairs(silent) do
        local _, _, evid = mirror.known(proj, o.oid)
        local ev = evid and evid ~= "" and not mine(evid) and event_file(room_dir, evid)
        if ev and type(ev.user) == "string" then
          say_once("hwout" .. tostring(proj) .. o.oid, string.format("%s goes only to a hardware output on %s's computer: it's silent here",
            (o.state.name or "") ~= "" and o.state.name or "A track", ev.user))
        end
      end
    end
  end
end

-- proj .. oid -> a bandmate's fader or knob shown here live, their change for it not landed yet: neither sent as yours nor put back (lib/controllers.lua)
mirror.previewing = mirror.previewing or {}
-- Every object of a look through W.one. (A function of its own, so the hold-back of one that threw is tested. Round 3 review, 0.59.48)
-- A track a bandmate's live move is showing on (lib/controllers.lua: `pv` names the settings it shows) and changed here in another setting:
-- it goes through W.one now, with the shown settings as the band has them, so yours goes out at once and theirs isn't sent as yours. Left
-- out of W.one whole, a colour, a mute or a rename made as a bandmate moved the fader waited for the preview to end, which (its change
-- having landed before its let-go) was the 60 s timeout: rt-r6's G, 61-63 s late, and a minute-late claim ask put back unanswered. Only
-- shown settings differing from the band's: left alone, as before. -> true to go through W.one (o's state is then the masked one). rt-fix9
function W.past_preview(w, o, pv)
  if o.kind ~= "track" or type(pv) ~= "table" or type(o.state) ~= "table" then return false end
  local _, h, kev = mirror.known(w.proj, o.oid)
  local ev = (kev or "") ~= "" and h ~= "" and event_file(w.room_dir, kev)
  if not (ev and type(ev.state) == "table") then return false end
  local st = {}
  for k, v in pairs(o.state) do st[k] = v end
  for f in pairs(pv) do if ev.state[f] ~= nil then st[f] = ev.state[f] end end
  if mirror.same_line(st, ev.state, w.opts.local_mix) then return false end
  o.state, o.hash = st, mirror.track_hash(st, w.opts.local_mix)
  return true
end
function W.each(w)
  local dirty = w.dirty -- (a quick look: only what may have changed, or still has something to do. rt-look)
  for _, o in ipairs(w.objs) do
    w.seen[o.oid] = true
    local pv = mirror.previewing[tostring(w.proj) .. o.oid]
    if (not dirty or dirty[o.oid]) and not (pv and not W.past_preview(w, o, pv)) and not (w.gone_now and o.track and w.gone_now[o.track]) then
      local ok, err = pcall(W.one, w, o)
      if not ok then held_back_set(w.proj, o.oid); w.say_once("err" .. o.oid, "mirror sync skipped " .. o.oid .. ": " .. tostring(err)) end -- (a send that threw: counted. Round 1 review, 0.59.45)
    end
  end
end
-- ---- the quick look's side of mirror.watch (rt-look) ----
-- The undo and redo names: an undo or redo puts back any set of changes, the records in the project among them, so the next look is a full one.
-- -> both as one string, and whether there's something to redo.
local function undo_names(proj)
  local u = reaper.Undo_CanUndo2 and reaper.Undo_CanUndo2(proj) or ""
  local r = reaper.Undo_CanRedo2 and reaper.Undo_CanRedo2(proj) or ""
  return tostring(u) .. "\0" .. tostring(r), r ~= ""
end
-- A full look's check on the quick one: what a quick look would have read at this moment (oid -> hash), or nil when it couldn't have run.
local function look_quick_view(proj, user, media, local_mix, L, remembered, now)
  if not L then return nil end
  local qobjs = mirror.quick_scan(proj, user, media, local_mix, L, remembered, now)
  if not qobjs then return nil end
  local q = {}
  for _, o in ipairs(qobjs) do q[o.oid] = o.hash end
  return q
end
mirror.MISSED_SAY_SECS = 60
local missed_said = -math.huge
-- Anything the full look read differently from what the quick one would have: logged (the quick look's hints missed an edit; it goes out now).
local function look_missed(qraw, objs, by_oid)
  local missed, here = {}, {}
  for _, o in ipairs(objs) do
    here[o.oid] = true
    if qraw[o.oid] ~= o.hash then missed[#missed + 1] = o end
  end
  for oid in pairs(qraw) do if not here[oid] then missed[#missed + 1] = { oid = oid, kind = "deleted" } end end
  if #missed == 0 then return end
  mirror.look_stats.missed = mirror.look_stats.missed + #missed
  local now = reaper.time_precise()
  if now - missed_said < mirror.MISSED_SAY_SECS then return end
  missed_said = now
  local what = {}
  for i = 1, math.min(5, #missed) do
    local o = missed[i]
    local t = o.kind == "track" and o or by_oid[o.track or ""]
    what[#what + 1] = string.format("%s %s%s", o.kind or "?", o.oid, t and t.state and t.state.name and (" on " .. t.state.name) or "")
  end
  require("band").log(string.format("mirror: the full look found %d change(s) the quick looks hadn't (%s%s); they go out now as usual",
    #missed, table.concat(what, ", "), #missed > 5 and ", ..." or ""))
end
-- A chain W.one has nothing more to do for while it reads the same: loaded, its knobs agreed (an empty one has none), first knobs and presets
-- noted, no window open with its text noted, and not restless or modulated (W.one reads their knobs every look).
local function fx_settled(proj, rk, o)
  return (mirror.fxk_ok[rk] or o.state == "") and loaded(proj, rk) and mirror.fx_quiet[rk] ~= nil and mirror.fx_quiet_presets[rk] ~= nil
    and not mirror.fx_open_text[rk] and not mirror.knobs_count(o.state)
end
-- Which objects go through W.one in a quick look (w.dirty), and which changed since the last look (w.changed). An object is left out only when
-- it reads the same as at the last look, W.one left it with nothing to do then (w.clean), its record is as it was then (read for objects worked
-- out afresh this look; an unchanged track's are only recorded through remember, which reads that track afresh), and nothing waits on it: no
-- unsent, print, reopened or held-back flag, not moved, not a colour scheme change, and for a chain: loaded, its knobs agreed, not restless or
-- modulated (W.one reads their knobs every look), no window open with its text noted.
-- This project's objects with an unsent, print, reopened or held-back flag: { oid = true } (the flag tables hold a few keys, the project many objects)
local function flagged(pk)
  local out, n = {}, #pk
  for _, t in ipairs({ mirror.unsent, mirror.auto, mirror.reopened }) do
    for k in pairs(t) do if k:sub(1, n) == pk then out[k:sub(n + 1)] = true end end
  end
  for oid in pairs(mirror.held_back[pk] or {}) do out[oid] = true end
  return out
end
local function look_dirty(w, L, info, raw, remembered)
  local proj, pk = w.proj, tostring(w.proj)
  local flags, dirty, changed, Lraw, Lclean, fresh, moved = flagged(pk), {}, {}, L.raw, L.clean, info.fresh, w.moved_set
  local retrack = w.rescheme
  for _, o in ipairs(info.check) do
    local oid = o.oid
    local skip = Lraw[oid] == raw[oid]
    if not skip then changed[oid] = true
    else
      skip = Lclean[oid] ~= nil and not remembered[oid] and not flags[oid] and not moved[oid] and not (retrack and o.kind == "track")
      if skip and o.kind == "fx" then skip = fx_settled(proj, pk .. oid, o) end
      if skip and fresh[oid] then skip = ext(proj, oid) == Lclean[oid] end
    end
    if not skip then dirty[oid] = true end
  end
  w.dirty, w.changed, w.look = dirty, changed, L
  -- the prints' walks over tracks: only tracks with something changed or looked at, and those holding an ARA take last time
  local tracks, ara = {}, {}
  for oid in pairs(dirty) do
    local o = w.by_oid[oid]
    local t = o and (o.kind == "track" and o or w.by_oid[o.track or ""])
    if t and t.ptr and t.kind == "track" then tracks[t.ptr] = true; ara[t.ptr] = true end
  end
  for _, o in ipairs(w.objs) do
    if o.kind == "track" and (L.ara or {})[info.L.guid_of[o.ptr] or ""] then ara[o.ptr] = true end
  end
  w.print_tracks, w.ara_tracks = tracks, ara
end
-- Could takes become lanes on any of these tracks (nil: all of them): one of their items has more than one take. A quick look asks before
-- counting the band's changes waiting (a listing of every change of the room), which takes_to_lanes waits on.
function mirror.has_takes(tracks)
  if not tracks then return true end
  for tr in pairs(tracks) do
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      if reaper.CountTakes(reaper.GetTrackMediaItem(tr, j)) > 1 then return true end
    end
  end
  return false
end
-- W.prints' items in a quick look: nil (all of them) when who's here, any chain or routing changed, or the last look didn't get to them; else
-- -> a function saying whether an item needs looking at (changed or looked at, its track changed, a restless chain's, or not found quiet in
-- the last minute: what W.prints would have computed anew anyway).
function mirror.print_want(w, who_here, now)
  local L, dirty, changed = w.look, w.dirty, w.changed
  if not (dirty and L and L.prints_who == who_here) then return nil end
  for oid in pairs(changed) do local k = oid:sub(1, 1); if k == "F" or k == "R" then return nil end end
  -- (an item not found quiet, or one whose minute is up: all of them, as before)
  if L.prints_missing ~= false or now - (L.quiet_min or -math.huge) >= 60 then return nil end
  local by_oid, restless = w.by_oid, {}
  return function(o)
    if dirty[o.oid] or changed[o.track] then return true end
    local r = restless[o.track]
    if r == nil then
      local f = by_oid["F" .. tostring(o.track):sub(2)]
      r = f and mirror.knobs_count(f.state) or false
      restless[o.track] = r
    end
    return r
  end
end
-- W.gone's candidates in a quick look: what was here at the last look and isn't now, what was left gone then (a deletion that couldn't go yet,
-- held, an item on a track of your own), and anything recorded since.
local function look_gone_oids(w, L, remembered, info)
  local out, have, seen = {}, {}, w.seen
  local function add(oid) if not have[oid] and not seen[oid] then have[oid] = true; out[#out + 1] = oid end end
  for _, oid in ipairs(info.gone) do add(oid) end
  for oid in pairs(L.lingering or {}) do add(oid) end
  for oid in pairs(remembered) do add(oid) end
  table.sort(out)
  return out
end
-- The look done: what it saw, for the next quick look to build on. `N`: the scan's record; `full`: this was a full look.
local function look_commit(w, N, raw, L, now, full, undo, redo, all)
  if not N then return end
  N.map = w.map_now -- (the tempo map its readings are under: W.send's look_reading. rt-fix9)
  local proj, pk = w.proj, tostring(w.proj)
  local flags, dirty, where, attn = flagged(pk), w.dirty, N.where, N.attn
  N.raw = raw
  -- (a quick look carries the last look's clean records over and changes only what went through W.one; a full one starts afresh)
  if dirty then N.clean = L.clean end
  local clean = N.clean
  local list = w.objs
  if dirty then -- (a quick look: what went through W.one, and anything flagged; the rest keep what they had)
    list = {}
    for oid in pairs(dirty) do list[#list + 1] = w.by_oid[oid] end
    for oid in pairs(flags) do if not dirty[oid] and w.by_oid[oid] then list[#list + 1] = w.by_oid[oid] end end
  end
  for _, o in ipairs(list) do
    local oid = o.oid
    -- (anything W.one will look at next time is read afresh first: W.one never works on a state carried over from an earlier look. One left out
    -- of W.one this time passed the same checks in look_dirty, so only a flag set since makes it busy)
    local busy = flags[oid]
    if not dirty or dirty[oid] then
      local c = w.clean[oid] and ext(proj, oid) or nil
      clean[oid] = c
      busy = busy or not c or o.kind == "fx" and not fx_settled(proj, pk .. oid, o)
    end
    if busy and where[oid] then attn[where[oid]] = true end
  end
  N.seen = w.seen
  N.lingering = {}
  for _, oid in ipairs(w.gone_seen or {}) do
    local rev, h = mirror.known(proj, oid)
    if rev and h ~= "" and not w.seen[oid] then N.lingering[oid] = true end
  end
  N.prints_who, N.quiet_min, N.prints_missing = w.prints_who, w.quiet_min, w.prints_missing
  if w.ara then
    N.ara = {}
    for tr in pairs(w.ara) do if N.guid_of[tr] then N.ara[N.guid_of[tr]] = true end end
  else N.ara = L and L.ara end
  N.undo, N.redo = undo, redo
  if full then N.full_at, N.all_at, N.full_took = now, now, reaper.time_precise() - now end -- (its whole time, the safety net's quick scan too)
  local s = mirror.look_stats
  if full then s.full = s.full + 1 else s.quick = s.quick + 1 end
  if full or all then s.all_chunks = s.all_chunks + 1 end
  mirror.looks[tostring(proj)] = N
  reaper.SetExtState(require("band").SECTION, "look stats", string.format("quick %d, full %d, every chunk read %d, missed %d", s.quick, s.full, s.all_chunks, s.missed), false)
end
-- Whether a call wrote to the project (rt-perfcut2: Live sync redraws after a look only when it sent, put back or wrote something). REAPER's
-- writers are wrapped for the call's length: a Set..., Delete..., Add..., Insert..., Move... and the like, or a GetSet... whose last argument
-- (its "set") is true. ExtState and P_EXT notes don't count: nothing on screen changes. -> whether any wrote, then fn's results. An error is
-- raised again once the writers are put back.
do
  local WRITERS = { "^Set", "^Delete", "^Add", "^Insert", "^Move", "^Reorder", "^Split", "^Apply", "^Main_On", "^Undo_Do", "^Undo_OnStateChange",
    "^TrackFX_Set", "^TrackFX_Delete", "^TrackFX_Add", "^TrackFX_Copy", "^TakeFX_Set", "^TakeFX_Delete", "^TakeFX_Add", "^TakeFX_Copy",
    "^MIDI_Set", "^MIDI_Insert", "^MIDI_Delete", "^MIDI_Sort", "^GetSet", "^CreateTrackSend", "^RemoveTrackSend", "^CreateNewMIDIItem",
    "^Envelope_Sort", "^UpdateItemInProject" }
  local QUIET = { SetExtState = true, DeleteExtState = true, SetProjExtState = true }
  local names_of = setmetatable({}, { __mode = "k" }) -- (REAPER's writers by name, per reaper table: the tests swap theirs)
  function mirror.counting_writes(fn, ...)
    local R = reaper
    local names = names_of[R]
    if not names then
      names = {}
      for k, v in pairs(R) do
        if type(k) == "string" and type(v) == "function" and not QUIET[k] then
          for _, p in ipairs(WRITERS) do if k:find(p) then names[#names + 1] = k; break end end
        end
      end
      names_of[R] = names
    end
    local saved, wrote = {}, false
    for _, k in ipairs(names) do
      local f, w = R[k], nil
      if k:sub(1, 6) == "GetSet" then
        w = function(...)
          local n = select("#", ...)
          if n > 0 and select(n, ...) == true and not tostring((select(2, ...))):find("^P_EXT:") then wrote = true end
          return f(...)
        end
      else w = function(...) wrote = true; return f(...) end end
      saved[k], R[k] = { f, w }, w
    end
    local r = table.pack(pcall(fn, ...))
    for k, s in pairs(saved) do if R[k] == s[2] then R[k] = s[1] end end -- (unless the call swapped one itself)
    if not r[1] then error(r[2], 0) end
    return wrote, table.unpack(r, 2, r.n)
  end
end
-- Was there an edit of this person's behind what this look sends? Auto-claims come only from one (W.send's opts.sent). Yes when Live sync's count
-- moved by them (`edited_at`: its own writes left out) in the last EDIT_SECS, past the value its first look saw (Live sync's first tick takes
-- the project's count as a change), or when a new undo point on top since the last look isn't StudioSync's own syncing (a web page's edit is
-- made inside Live sync's tick, so it isn't in that count). No `edited_at` (a caller that doesn't keep it): yes, as before. A fresh REAPER on
-- LinuxBox2 read XT Rec A's lane names its own way at open; that went out 21 s later and auto-claimed the track with nobody editing (rt-r1).
-- shortcut: one answer for the whole look, so a read-back sent in the EDIT_SECS after a real edit elsewhere still claims; per object would need
-- REAPER to say what an edit touched. rt-fix6a
mirror.EDIT_SECS = 30
mirror.edit_seen = mirror.edit_seen or {} -- tostring(proj) -> { base = the first look's edited_at, top = the undo point on top at the last look }
function mirror.user_point(top) -- an undo point that's someone's edit (a web page's or the phone's too), not StudioSync syncing or recolouring
  return type(top) == "string" and top ~= "" and not top:find("^StudioSync: ") and not top:find("^BandSync") and not require("compat").OWN[top]
end
function mirror.user_edited(pk, edited_at, now, top)
  local s = mirror.edit_seen[pk]
  if not s then s = { base = edited_at or false }; mirror.edit_seen[pk] = s end
  local last_top = s.top -- (nil only before the first look; nothing to undo is "")
  s.top = top or ""
  if edited_at == nil then return true end
  if edited_at ~= s.base and now - edited_at <= mirror.EDIT_SECS then return true end
  return last_top ~= nil and (top or "") ~= last_top and mirror.user_point(top)
end
-- One pass: what changed here goes out if this person may change it, else the band's version is put back.
-- opts: local_mix, can (sync.authority's), mode (room mode); ask(name, pos), sent(o, name, ev): Claims mode's asks and auto-claims (lib/claimask.lua);
-- edited_at: when this person last edited (Live sync's count), for which looks may auto-claim (mirror.user_edited).
-- Returns sent, put back.
function mirror.watch(proj, cfg, song, room, opts)
  local band, sync = require("band"), require("sync")
  if reaper.JS_Mouse_GetState and reaper.JS_Mouse_GetState(1) & 1 == 1 then return 0, 0 end -- mid-drag: wait for the drop
  local pk, now = tostring(proj), reaper.time_precise()
  -- (a new opening: nothing from before it is this person's edit, and the last look's record is another project's. A file opened again in
  -- the tab kept the old project's edit count as "you edited", and W.gone took what the file lacked for a deletion. rt-guard)
  local opened_now = mirror.on_open(proj)
  if opened_now then
    mirror.edit_seen[pk], mirror.looks[pk] = nil, nil
    for k in pairs(mirror.gone_why) do if k:sub(1, #pk) == pk then mirror.gone_why[k] = nil end end
  end
  mirror.hold_colours()
  local room_dir = sync.room_dir(cfg, song, room)
  local media = room_dir .. "/media"
  -- (a quick look when it can build on the last one: opts.quick (Live sync's looks), not an undo or redo, and a full one each QUICK_FULL_SECS,
  -- which also says if the quick one would have missed anything. See "Quick looks" by mirror.quick_scan. rt-look)
  mirror.settle_due = nil
  local L = mirror.looks[pk]
  local remembered = mirror.remembered[pk] or {}
  mirror.remembered[pk] = {}
  local undo, redo = undo_names(proj)
  local due = not (opts.quick and L) or now - L.full_at >= mirror.full_every(L.full_took) or (undo ~= L.undo and (redo or L.redo))
  local objs, by_oid, info, rec
  if not due then objs, by_oid, info = mirror.quick_scan(proj, cfg.user, media, opts.local_mix, L, remembered, now) end
  if not info then
    local qraw = due and opts.quick and look_quick_view(proj, cfg.user, media, opts.local_mix, L, remembered, now)
    rec = new_look(L, nil, now)
    objs, by_oid = mirror.scan(proj, cfg.user, media, opts.local_mix, rec)
    if qraw then look_missed(qraw, objs, by_oid) end
  end
  -- (changes of yours REAPER stopped before sending: back in the project first, so this look sends them. Crash-safe sessions, rt)
  if mirror.restore_unsent(proj, by_oid, media, opts.local_mix) > 0 then
    info, rec = nil, new_look(L, nil, now)
    objs, by_oid = mirror.scan(proj, cfg.user, media, opts.local_mix, rec)
  end
  local me = cfg.user
  mirror.unsettled = false
  local suggest = require("suggest")
  local w = { band = band, sync = sync, proj = proj, cfg = cfg, song = song, room = room, opts = opts, me = me, room_dir = room_dir, media = media,
    objs = objs, by_oid = by_oid, sent = 0, back = 0, suggest = suggest, kept_back = {}, holds = mirror.holds[tostring(proj)] or {}, credit = {},
    back_tracks = {}, held_tracks = {}, clean = {}, unasked = {},
    -- (the last look's record, with each item's reading and the map then, and this look's map: W.send. rt-fix9)
    look_was = L, map_now = band.capture_tempo(proj) }
  local top = reaper.Undo_CanUndo2 and reaper.Undo_CanUndo2(proj) or nil
  local es = mirror.edit_seen[pk]
  -- (a new undo point of someone's on top since the last look: what a project emptied of tracks needs before its deletions go. W.gone, rt-guard)
  w.new_point = es ~= nil and es.top ~= nil and (top or "") ~= es.top and mirror.user_point(top)
  w.edited = mirror.user_edited(pk, opts.edited_at, now, top) -- (auto-claims: rt-fix6a)
  w.opened_now = opened_now
  w.pending = function() -- (how many of the band's changes wait here: once a look)
    if w.n_pending == nil then w.n_pending = sync.pending_events(proj, cfg, song, room) end
    return w.n_pending
  end
  -- (whose claims these are: opts' (sync.authority's who, Live sync passes them), else the last authority call's. One for another room in
  -- between judged this room by that room's claims. Round 1 review, 0.59.45)
  w.is_claimed, w.owner_of = opts.is_claimed or sync.is_claimed, opts.owner_of or sync.owner_of
  w.others_claims = function(oids, names) return W.others_claims(w, oids, names) end
  w.put_back = function(...) return W.put_back(w, ...) end
  -- (what a look puts back is one undo point, StudioSync's, opened before its first change (not for one that waits: an empty point) and closed
  -- after W.gone: with none, a Keep's put-back of a deleted track went into the person's next point, REAPER's "Remove tracks" stayed on top,
  -- and Ctrl+Z after their next edit deleted what the claimer kept. A "StudioSync" point on top is StudioSync's Undo of their own last change
  -- (undo.native), as heals' are (round 5). REAPER recheck, 0.59.49.79, rt-edits round 6)
  w.back_point = function(ev)
    if not w.back_open and not (ev and mirror.will_wait(proj, ev, true)) then reaper.Undo_BeginBlock2(proj); w.back_open = true end
  end
  w.propose = function(...) return W.propose(w, ...) end
  w.bus_note = function(...) return W.bus_note(w, ...) end
  if W.keep_held(w) then return 0, 0 end
  if next(w.kept_back) then
    info, rec = nil, new_look(L, nil, now)
    w.objs, w.by_oid = mirror.scan(proj, me, media, opts.local_mix, rec)
  end
  objs, by_oid = w.objs, w.by_oid
  W.credit(w)
  W.order(w)
  -- (something that came back without its id in a session that has been looking at this project all along isn't a file opened without its
  -- last save: it's REAPER's own Undo bringing back what this person deleted (the track returns as its undo point had it, before StudioSync
  -- wrote its id on it). Taken for a reopen, the track was deleted again as "the band deleted it since", with "this project was opened without
  -- its last save", and Ctrl+Z after a track delete brought it back nowhere (P1-6, rt-r2). Not marked, it's this person's change like any:
  -- built on the deletion, it goes back to everyone, or is put back if it isn't theirs to bring back. Only a project's first look keeps the
  -- marks. rt-converge)
  do
    local now_back = mirror.restored_now
    mirror.restored_now = {}
    if not w.first_here then for _, k in ipairs(now_back) do if k:sub(1, #pk) == pk then mirror.reopened[k] = nil end end end
  end
  local raw = {} -- (each object's hash as read, before W.one re-anchors any: what the next look compares with)
  for _, o in ipairs(objs) do raw[o.oid] = o.hash end
  local first_here = w.first_here
  local playing = reaper.GetPlayStateEx(proj) & 1 == 1
  local function mine(id) return sync.is_mine(id, me) end -- (event ids start with their author's name, then the date: "James" isn't "James-Laptop". 0.58.82)
  local function allowed(o, name, pos)
    if opts.can(me, name, pos) then return true end
    return sync.maker_may(o.kind == "track" and o.oid or o.track, me, name, pos, opts.mode, o.kind == "item" and o.oid or nil, w.is_claimed)
  end
  local function say_once(key, text)
    if not mirror.said[key] then mirror.said[key] = true; band.log(text) end
  end
  w.playing, w.mine, w.allowed, w.say_once = playing, mine, allowed, say_once
  -- (the studio's order list is written after this look's sends, and only when a move went out: w.order_out, below. Written here, before any
  -- was judged, it went out for a move that was then held for an ask and put back half a minute later: the list said an order no change had
  -- made, and the order heal moved everyone's tracks to it. rt-converge)
  local seen = {}
  mirror.index_for(proj) -- (put-backs find items through the index, not a walk through every item each: 0.59.14, review)
  -- a burst (hundreds of items moved at once) goes out a quarter second a pass, the rest on the next passes, which
  -- Live sync runs straight after: writing all 320 at once held REAPER up for 4.7 s (laptop, 0.34.5). What waits is
  -- marked unsent, so the band's changes to it wait too. `mirror.more`: there's more to send.
  local t_send = reaper.time_precise()
  -- (one look, one act: every change it sends carries the same `act`, so one Undo takes back all of it, whatever tracks and kinds it touched (a
  -- region copied with its items on several tracks and their envelope points was three presses). A burst spread over passes keeps the first
  -- pass's act. rt-edits)
  -- (and the id a tempo map or marker change took just before this look, when there is one: mirror.act_for)
  local la = mirror.look_act[pk]
  mirror.look_act[pk] = nil
  -- (and the act of the last look that sent anything, while you haven't edited since that look: what this look finds was made before it, so
  -- it's the rest of that act. A script's edit to unselected items on two tracks is found one track now and the other up to 10 s later
  -- (the quick look's hints), and a plug-in chain goes once it has held still: each was a second Undo step. `opts.edited_at`: when you last
  -- edited, by Live sync's count (its own writes left out); without it, as before. Not past ACT_KEEP since that look. rt-edits)
  local kept = mirror.last_act[pk]
  kept = kept and opts.edited_at and opts.edited_at <= kept.at and now - kept.at <= mirror.act_keep(mirror.looks[pk]) and kept.act or nil
  w.act = mirror.more_act[pk] or (la and math.abs(now - la.at) <= mirror.ACT_SECS and la.act) or kept or new_act(me, now)
  mirror.more = false
  -- (whether track colours count here, per project: see below. "band2": 0.38 looks once more, as 0.36/0.37 kept each
  -- machine's own colour where it should have taken the band's: Bass I differed PC/laptop for good, 2026-11-01)
  local scheme = mirror.own_colours() and "own" or "band2"
  -- (or SWS's rules may just have recoloured it: it's only switched off once a band song is in front, so a project opened or
  -- brought forward with it on came in recoloured, and that went out as this person's change: laptop's Bass tracks, every reopen, 0.57.7)
  local sws_ran = reaper.time_precise() - (tonumber(reaper.GetExtState(require("band").SECTION, "sws colours ran")) or -math.huge) < 5
  local rescheme = first_here or sws_ran or select(2, reaper.GetProjExtState(proj, mirror.CSEC, "colours")) ~= scheme
  w.seen, w.t_send, w.scheme, w.rescheme = seen, t_send, scheme, rescheme
  local ok_look, err_look = pcall(function()
    if info then look_dirty(w, L, info, raw, remembered) end
    W.each(w)
    W.prints(w)
    if info then w.gone_oids = look_gone_oids(w, L, remembered, info) end
    W.gone(w)
    -- (the studio's order list, whenever a move of yours went out: it was written only when every moved track was yours outright, so a move of
    -- a bandmate's auto-claimed track, which goes out and merges (W.one's soft path), reached everyone here but never the list. Anyone who
    -- opened the song later went to the old list, and the order heal then pulled everyone else back to it: the move undone for all, minutes
    -- later. The soak's late joiner, "track order differs". As it stands after this look's sends and put-backs. rt-converge)
    if w.order_out then mirror.publish_order(proj, room_dir, me) end
    -- (a track put back takes its settings again once its items are back, and is remembered as it reads then, as mirror.revert's finish does:
    -- REAPER names a lane only once an item is in it, so a kept track read as changed at the next full look, which put it back a second time,
    -- with a cooldown line nobody's edit caused. REAPER recheck, 0.59.49.80, round 7. After a burst's last pass.)
    local tb = mirror.tracks_back[pk]
    if tb and not mirror.more then
      mirror.tracks_back[pk] = nil
      for oid, ev in pairs(tb) do
        local tr = mirror.find(proj, "track", oid)
        local rev, h, evid, ord = mirror.known(proj, oid)
        if tr and evid == ev.id and (h or "") ~= "" then
          mirror.set_track_state(proj, tr, ev.state, opts.local_mix)
          remember(proj, oid, rev, mirror.track_hash(mirror.track_state(proj, tr, opts.local_mix), opts.local_mix), evid, ord)
        end
      end
    end
  end)
  if w.back_open then reaper.Undo_EndBlock2(proj, "StudioSync: put back what wasn't sent", -1); w.back_open = nil end
  if not ok_look then error(err_look, 0) end
  mirror.index_for(nil)
  -- (tracks W.gone put back go to the studio's order once keep_order can run: the tab in front, stopped, nothing of the band's waiting. rt-guard)
  if mirror.order_owed[pk] and not mirror.more and reaper.EnumProjects(-1) == proj and reaper.GetPlayStateEx(proj) == 0
      and sync.pending_events(proj, cfg, song, room) == 0 then
    mirror.order_owed[pk] = nil
    local okk, errk = pcall(mirror.keep_order, proj, cfg, song, room)
    if not okk then band.log("track order: " .. tostring(errk)) end
  end
  if not mirror.more then mirror.sweep_unsent(proj, seen) end
  mirror.more_act[pk] = mirror.more and w.act or nil
  if w.sent > 0 then mirror.last_act[pk] = { act = w.act, at = now } end
  mirror.save_ids(proj)
  mirror.stash_unsent(proj, by_oid) -- (what's still not out, kept beside the project: crash-safe sessions, rt)
  if rescheme and not mirror.more then reaper.SetProjExtState(proj, mirror.CSEC, "colours", scheme) end
  mirror.summary(proj, cfg, room_dir, objs, media)
  suggest.flush()
  W.remember_holds(w)
  look_commit(w, info and info.L or rec, raw, L, now, info == nil, undo, redo, info and info.all)
  mirror.look_cc[pk] = reaper.GetProjectStateChangeCount(proj) -- (after this look's own writes)
  return w.sent, w.back
end

-- At the end of a whole pass: this project's unsent and held-back flags on an object neither here nor known to the band (flagged before it ever
-- went out, then deleted) go. Nothing else cleared them, and Sync and exit waited on them until Live sync restarted. Cost: one walk of the
-- flags per pass. Round 1 review, 0.59.45
function mirror.sweep_unsent(proj, seen)
  local key = tostring(proj)
  for k in pairs(mirror.unsent) do
    if k:sub(1, #key) == key then
      local oid = k:sub(#key + 1)
      -- (an oid, not another project's key that merely starts the same: "userdata: 0x12" is the start of "userdata: 0x123...")
      if oid:match("^%a%-") and not seen[oid] and not mirror.known(proj, oid) then mirror.unsent[k] = nil end
    end
  end
  for oid in pairs(mirror.held_back[key] or {}) do
    if not seen[oid] and not mirror.known(proj, oid) then mirror.held_back[key][oid] = nil end
  end
end

-- What the song chooser shows before someone joins (lib/chooser.lua): the room's tracks, plug-ins and how much audio
-- it holds. rooms/<room>/summary/<user>.json (each machine its own file), rewritten only when it changed; the media
-- folder is measured once a minute at most.
local summary_seen, media_mb, media_sizes = {}, {}, {}
function mirror.summary(proj, cfg, room_dir, objs, media)
  local band = require("band")
  local key = tostring(proj) .. room_dir
  local m = media_mb[key]
  if not m or reaper.time_precise() - m.at > 60 then
    -- (sizes remembered by name, so only new names are opened: media files are written once, under a name of their own, and every file was
    -- opened once a minute per tab, 85 ms to over half a second. Round 1 review, 0.59.45)
    local bytes, was, now = 0, media_sizes[media] or {}, {}
    for _, f in ipairs(band.files(media)) do
      now[f] = was[f] or band.size(media .. "/" .. f) -- (one that can't be measured now is tried again next time)
      bytes = bytes + (now[f] or 0)
    end
    media_sizes[media] = now
    m = { at = reaper.time_precise(), mb = math.floor(bytes / 1048576 + 0.5) }
    media_mb[key] = m
  end
  local names, seen, tracks = {}, {}, 0
  for _, o in ipairs(objs) do
    if o.kind == "track" then tracks = tracks + 1 end
    if o.kind == "fx" then
      -- (the names once per chain text, not every chain's every look: 0.59.14, review)
      for _, n in ipairs(mirror.memo("n", o.state, function() return mirror.fx_names(o.state) end)) do if not seen[n] then seen[n] = true; names[#names + 1] = n end end
    end
  end
  table.sort(names)
  local s = { tracks = tracks, plugins = names, media_mb = m.mb }
  local text = band.json_encode(s)
  if summary_seen[key] == text then return end
  summary_seen[key] = text
  s.time = os.date("!%Y-%m-%dT%H:%M:%SZ")
  reaper.RecursiveCreateDirectory(room_dir .. "/summary", 0)
  band.write_json(room_dir .. "/summary/" .. (cfg.user:gsub("[^%w%-_ ]", "")) .. ".json", s)
end


-- History's "selected tracks" scope: the tracks selected in REAPER, their plug-ins and everything on them (then or
-- now). nil when nothing is selected.
function mirror.selection_scope(proj)
  local set, any = {}, false
  for i = 0, reaper.CountSelectedTracks(proj) - 1 do
    local oid = trk_oid(reaper.GetSelectedTrack(proj, i))
    if oid ~= "" then for _, p in ipairs({ "T", table.unpack(mirror.PARTS) }) do set[p .. oid:sub(2)] = true end; any = true end
  end
  if not any then return nil end
  return function(oid, last, at) return set[oid] or (last and set[last.track or ""]) or (at and set[at.track or ""]) or false end
end

-- Carry out a History plan (plan_restore / plan_undo) here and send it to the band as new revisions, so a restore
-- is itself a change that can be undone. Objects this person may not change are left (counted). Returns a summary.
-- Whether two states of an item differ only in what a print adds to a take's name. REAPER gives a comp piece its source pass's take name
-- as a project opens, so one whose piece is printed and whose pass isn't went from "dry - x" to "x" and out as a change, from just opening
-- (Mac, 0.45.0). Pure.
function mirror.same_but_labels(x, y)
  if x == y then return true end
  local function labelled(s) return s:find('NAME "dry - ', 1, true) or s:find('NAME "wet - ', 1, true) end
  if not labelled(x) and not labelled(y) then return false end -- (no label on either: as plain as they are. rt-look: two copies of a big MIDI item each edit)
  local function plain(s) return (s:gsub('NAME "dry %- ', 'NAME "'):gsub('NAME "wet %- ', 'NAME "')) end
  return plain(x) == plain(y)
end

-- A deleted item being brought back whose very place on its lane is taken by the same thing under another id. Undoing a pass makes
-- REAPER rebuild its comp piece as a new item, so the comp lane's own row, undone after, played a second copy on top (Mac 0.42.27, PC 0.45).
-- `plan` (mirror.revert's: oid -> the version it goes to, or false to remove): an item the same plan is about to move off that place or
-- remove doesn't count. REAPER's "Copy contents" on a track in lanes leaves the items it had at the copy's place and new ones, the same in every
-- way, where they were; Redo brought a new one back, found its twin still on the lane (the same Redo moved it away a moment later), and left
-- it out: 4 of 8 items gone on every computer, alike, so nothing flagged it. REAPER check, 0.59.49.74, rt-edits.
function mirror.sits_there(proj, ev, plan)
  if ev.obj ~= "item" or type(ev.state) ~= "string" or mirror.find(proj, "item", ev.oid) then return false end
  local function leaving(it, lane, pos)
    local to = plan and plan[itm_oid(it)]
    if to == nil then return false end
    if to == false then return true end
    if type(to) ~= "table" or type(to.state) ~= "string" then return false end
    local tl, tp = tonumber(to.state:match("BANDLANE (%d+)")), tonumber(to.state:match("POSITION ([%d%.%-e]+)"))
    return to.track ~= ev.track or tl ~= lane or not tp or math.abs(tp - pos) >= 1e-6
  end
  local lane, pos, len = tonumber(ev.state:match("BANDLANE (%d+)")), tonumber(ev.state:match("POSITION ([%d%.%-e]+)")), tonumber(ev.state:match("LENGTH ([%d%.%-e]+)"))
  local tr = ev.track and mirror.find(proj, "track", ev.track)
  if not (tr and lane and pos and len) then return false end
  -- (by name without what a print adds: the same pass reads "x", "dry - x" or "wet - x" by whether it's been printed yet: Mac, 0.45.0)
  local function plain(n) return (n:gsub("^dry %- ", ""):gsub("^wet %- ", "")) end
  local name = ev.state:match('NAME "([^"\n]*)"') or ev.state:match("NAME ([^\n]*)")
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    if reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE") == lane and math.abs(reaper.GetMediaItemInfo_Value(it, "D_POSITION") - pos) < 1e-6
      and math.abs(reaper.GetMediaItemInfo_Value(it, "D_LENGTH") - len) < 1e-6 and not leaving(it, lane, pos) then
      if not name then return true end
      for k = 0, reaper.CountTakes(it) - 1 do
        local take = reaper.GetTake(it, k)
        if take and plain(select(2, reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false))) == plain(name) then return true end
      end
    end
  end
  return false
end

mirror.REVERT_AT_ONCE, mirror.REVERT_SLICE = 120, 0.1 -- (changes; seconds per pass)
function mirror.revert(proj, cfg, song, room, plan, opts)
  local sync = require("sync")
  mirror.last_act[tostring(proj)] = nil -- (what a look finds after this isn't the rest of the act before it: mirror.watch. rt-edits)
  local function band_log(text) require("band").log(text) end
  local room_dir = sync.room_dir(cfg, song, room)
  local media = room_dir .. "/media"
  local order = { track = 1, fx = 2, item = 3 }
  local list = {}
  for oid, t in pairs(plan) do list[#list + 1] = { oid = oid, t = t } end
  -- tracks before what sits on them when bringing back; the other way round when removing
  table.sort(list, function(a, x)
    local ka, kx = order[a.t and a.t.obj or (a.oid:sub(1, 1) == "T" and "track" or "item")] or 3, order[x.t and x.t.obj or (x.oid:sub(1, 1) == "T" and "track" or "item")] or 3
    if (a.t and 1 or 0) ~= (x.t and 1 or 0) then return a.t ~= false end
    if ka ~= kx then if a.t then return ka < kx else return ka > kx end end
    return a.oid < x.oid -- (then by id: among equals the order was the plan table's, which Lua walks differently every run. rt-converge)
  end)
  -- (a deleted track that comes back goes where it sat when it was deleted, which its deletion names (`was_after`): its last version's
  -- "sits under" is the place of the day that version was made, and a track isn't sent again when others land above it or the studio's
  -- order moves it, so an Undo then Redo of adding a track brought it back at the top, for everyone. Before the ordering below, which goes
  -- by the place each will take. The soak's undo probe, seeds 6037 and 7055. rt-converge)
  for _, p in ipairs(list) do
    if p.t and p.t.obj == "track" and type(p.t.state) == "table" then
      local _, _, kev = mirror.known(proj, p.oid)
      local last = (kev or "") ~= "" and event_file(room_dir, kev) or nil
      if last and last.gone and type(last.was_after) == "string" and #last.was_after < 200 and last.was_after ~= p.t.state.after then
        local st = {}
        for k, v in pairs(p.t.state) do st[k] = v end
        st.after = last.was_after
        p.t = setmetatable({ state = st }, { __index = p.t })
      end
    end
  end
  -- (and where each track sits now, before any of them goes: what a deletion made here says, for its return. Read as each went, the second
  -- of two tracks deleted in one act sat "at the top", and Undo then Redo of a whole song brought its tracks back in reverse)
  local sat, above = {}, ""
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local o = not local_track(tr) and trk_oid(tr) or ""
    if o ~= "" then sat[o], above = above, o end
  end
  -- and a track only after the one it sits under, when that comes back too: put back first, Keys found no K4 Inner
  -- yet and went to the top, out of its folder (laptop, block K)
  local back, placed, sorted = {}, {}, {}
  for _, p in ipairs(list) do if p.t and p.t.obj == "track" then back[p.oid] = p end end
  local function place(p)
    if placed[p] then return end
    placed[p] = true -- (before going up: tracks from different times can sit under each other in a ring, and each of 7 went out 73 times,
    -- 7.5 s with REAPER stopped: laptop, 0.42.8)
    local after = type(p.t.state) == "table" and p.t.state.after or ""
    if back[after] then place(back[after]) end
    sorted[#sorted + 1] = p
  end
  for _, p in ipairs(list) do
    if p.t and p.t.obj == "track" then place(p) elseif not placed[p] then placed[p] = true; sorted[#sorted + 1] = p end
  end
  list = sorted
  local done, refused, kept, kept_names, there, waiting, edited, gone_since = 0, 0, 0, {}, 0, 0, 0, 0
  local now_map -- (the tempo map in place, read once: opts.map_of below)
  local function one(p)
    local rev, h, evid = mirror.known(proj, p.oid)
    local name = p.t and p.t.name or ""
    if p.t and p.t.obj ~= "track" and p.t.track then -- (a part or item: on the track as it's called now, not was; laptop 0.34.4)
      local tr = mirror.find(proj, "track", p.t.track)
      if tr then name = select(2, reaper.GetTrackName(tr)) end
    end
    local last = evid and evid ~= "" and event_file(room_dir, evid) or nil
    if not p.t and last and name == "" then name = last.name or "" end
    -- (a track stays where it sits, unless a move someone made is among what's taken back: then it goes back under the track it sat under
    -- before that move, which the move's change names (`moved`). An older version's "sits under" is the place of the day it was made, and a
    -- track isn't sent again when another lands above it: Undo of a mute moved the track above one added since, for everyone. rt-undo's
    -- limits, rt-edits. p.moved: where it sat before this put it back, for the Redo.)
    if p.t and p.t.obj == "track" and type(p.t.state) == "table" and last and not last.gone then
      local tr = mirror.find(proj, "track", p.oid)
      local here = tr and mirror.track_state(proj, tr, opts.local_mix).after
      if here then
        local from = mirror.moved_since(room_dir, last, p.t.id)
        if from and from ~= here then p.moved = here end
        if (from or here) ~= p.t.state.after then
          local st = {}
          for k, v in pairs(p.t.state) do st[k] = v end
          st.after = from or here
          p.t = setmetatable({ state = st }, { __index = p.t })
        end
      end
    end
    -- (an item's version made under another tempo map than the one in place now goes onto its beat here, as REAPER moved it when the maps
    -- changed: opts.map_of(version) -> the map it was made under (History's Restore: lib/histhear.lua). rt-history2's limits, rt-edits round 6)
    -- (and an automation part's points and items the same way: mirror.retime_env. rt-p1b)
    -- (the map the version itself names (`tm`, mirror.map_tag) first: Undo and Redo pass no map_of, and a put-back version named the wrong
    -- seconds across a tempo change. What goes out below is on the map in place, and says so. rt-converge)
    if p.t and (p.t.obj == "item" or p.t.obj == "env") and type(p.t.state) == "string" then
      local mode = reaper.GetSetProjectInfo(proj, "PROJECT_TIMEBASE", 0, false)
      now_map = now_map or require("band").capture_tempo(proj)
      if mirror.map_ok(p.t.tm) then
        local st, moved = mirror.state_on(p.t, now_map, mode)
        if moved then p.t = setmetatable({ state = st, tm = now_map, tb = mode }, { __index = p.t }) end
      else
        local from = opts.map_of and opts.map_of(p.t)
        if from then
          local st = (p.t.obj == "item" and mirror.retime or mirror.retime_env)(p.t.state, from, now_map, mode)
          if st ~= p.t.state then p.t = setmetatable({ state = st }, { __index = p.t }) end
        end
      end
    end
    -- (an owner's restore or deletion takes the owner step, as their sends do: mirror.owned. Round 1 review, 0.59.45)
    local function owned(pos) return not opts.exact and mirror.owned(opts, cfg.user, name, pos) end
    -- Going back never removes what a bandmate has made since: the driver going back a version took the Mac's new track and
    -- its 4 items for everyone, and forward couldn't return them, as the Mac's claim on it still stood (laptop, 0.42.5). And
    -- what you removed yourself you may bring back, whoever's claim stands now.
    -- (by who made it, not who touched it last: having restored the Mac's track earlier made it "yours" to remove. Only undoing
    -- that very change of yours may take it away again.)
    -- (nor what your own going back revived after a bandmate deleted it: forward left a glue's pieces under the glued part: laptop, 0.42.10)
    -- (opts.exact: a room made to look at that moment, where nothing is anybody's to keep)
    -- (nor what your own Undo brought back: its Redo takes it away again, as the deletion it redoes did. "0 change(s) brought back (kept
    -- what collaborators added since)" left a bandmate's item you had deleted, undone, and redone. The soak's bug 9. rt-converge)
    local theirs_new = not opts.exact and not p.t and not mirror.is_creator(p.oid, cfg.user) and not ((opts.undoes or opts.redoes) and last and last.user == cfg.user)
      and not (last and last.user == cfg.user and last.revived)
    local mine_gone = p.t and last and last.gone and last.user == cfg.user
    if not p.t and (h or "") == "" then -- gone then, gone now
    elseif p.t and evid == p.t.id and ((h or "") ~= "" or p.t.obj ~= "track" and not (p.t.track and mirror.find(proj, "track", p.t.track))) then -- already that revision
      -- (not a part recorded as gone with its track, which still names its last real change: Restore brought a deleted track back bare. Full
      -- review, 0.59.44. But only when its track is here (tracks are placed first): a still-deleted track's parts read as "couldn't change here
      -- yet, do it again" for good. Round 1 review, 0.59.45)
    -- (opts.retimed: the undo just put the tempo map back, and REAPER moved the items and points with it. That isn't an edit of yours made
    -- since, nor "already there": each still goes back to what it was and is sent, or the look after took REAPER's moves for new changes of
    -- yours, and Redo had nothing to redo. rt-edits)
    elseif p.t and not opts.exact and not (opts.retimed and (p.t.obj == "item" or p.t.obj == "env")) and mirror.sits_there(proj, p.t, plan) then there = there + 1
    elseif not opts.exact and not (opts.retimed and p.t and (p.t.obj == "item" or p.t.obj == "env")) and mirror.edited_here(proj, p.oid, h, last, media, opts.local_mix) then
      -- (changed here since it last went out or came in, and not sent yet (a look hasn't run): left as it is. Going back
      -- put the old version over it for everyone, with no copy and nothing in History. Cost: one hash per planned item or track. Round 1
      -- review, 0.59.45)
      edited = edited + 1
    elseif theirs_new then
      kept = kept + 1
      kept_names[name ~= "" and name or "an unnamed track"] = true
    -- (an Undo or Redo of your change to something a bandmate deleted since: their deletion stays, as what they changed since stays. It
    -- brought the deleted item back for everyone, as it was before your edit; Undo then Redo left an item the song didn't have. A Restore
    -- still brings back what it's asked to. The soak's undo probe, seed 113. rt-converge)
    elseif p.t and (opts.undoes or opts.redoes) and last and last.gone and last.user ~= cfg.user then
      gone_since = gone_since + 1
    elseif mine_gone then
      local ok, nh = mirror.apply(proj, p.t, media, opts.local_mix)
      if ok then
        mirror.hlc_seen(last and last.hlc)
        local ev = { type = "obj", obj = p.t.obj, oid = p.oid, rev = mirror.next_rev(rev, owned(p.t.pos)), base = rev or 0, base_ev = evid ~= "" and evid or nil, state = p.t.state, track = p.t.track, name = name, pos = p.t.pos, restored = p.t.id, moved = p.moved, from_lane = p.t.from_lane,
          undoes = opts.undoes, redoes = opts.redoes, undoes_all = opts.undoes_all, redoes_all = opts.redoes_all, act = opts.act, tl = mirror.map_stamp(proj) }
        mirror.map_tag(proj, ev)
        local id = sync.post(cfg, song, room, ev)
        remember(proj, p.oid, ev.rev, nh, id, mirror.order_of(ev))
        done = done + 1
        p.landed = true
      else waiting = waiting + 1 end -- (can't land here now: not sent, and said. 0.59.14, review)
    -- (or an Undo or Redo of your own change that only a bandmate's auto-claim, made since, stands in front of: it goes through as the edit did,
    -- when the newest version of the thing is still yours, so nothing of theirs is in it. "19 brought back (2 not yours to change)" left a
    -- copied item on every computer because the laptop had auto-claimed the track meanwhile. A lasting claim still refuses. opts.soft: lib/undo.lua.
    -- rt-edits)
    elseif not (opts.can(cfg.user, name, p.t and p.t.pos or nil) or ((opts.undoes or opts.redoes) and opts.soft and last and last.user == cfg.user
        and opts.soft(name, (p.t and p.t.pos) or last.pos) ~= nil) or sync.maker_may(p.t and p.t.obj == "track" and p.oid or (p.t and p.t.track) or p.oid, cfg.user, name, p.t and p.t.pos or nil, opts.mode, p.t and p.t.obj == "item" and p.oid or nil)) then
      refused = refused + 1
    elseif p.t then
      local ok, nh = mirror.apply(proj, p.t, media, opts.local_mix)
      if ok then
        mirror.hlc_seen(last and last.hlc)
        local ev = { type = "obj", obj = p.t.obj, oid = p.oid, rev = mirror.next_rev(rev, owned(p.t.pos)), base = rev or 0, base_ev = evid ~= "" and evid or nil, state = p.t.state, track = p.t.track, name = name, pos = p.t.pos, restored = p.t.id, moved = p.moved, from_lane = p.t.from_lane,
          undoes = opts.undoes, redoes = opts.redoes, undoes_all = opts.undoes_all, redoes_all = opts.redoes_all, revived = (last and last.gone and last.user ~= cfg.user) or nil, act = opts.act, tl = mirror.map_stamp(proj) } -- (act: a History page restore is one act, rt-history)
        mirror.map_tag(proj, ev)
        local id = sync.post(cfg, song, room, ev)
        remember(proj, p.oid, ev.rev, nh, id, mirror.order_of(ev))
        done = done + 1
        p.landed = true
      else waiting = waiting + 1 end
    else
      local kind = mirror.KIND[p.oid:sub(1, 1)] or "item"
      -- (a part: emptied on its track, which apply needs named. One that can't change now isn't sent: sent, this computer's chain went out
      -- again as a change of its own. 0.59.14, review)
      local was_after = kind == "track" and sat[p.oid] or nil -- (where it sat before this act, for its return: above)
      local tr_here = kind == "track" and mirror.find(proj, "track", p.oid)
      local items = tr_here and mirror.items_on(tr_here) or (kind == "track" and {} or nil) -- (what went with it: rt-sync2b)
      if not mirror.apply(proj, { obj = kind, oid = p.oid, gone = true, track = last and last.track }, media, opts.local_mix) then waiting = waiting + 1; return end
      mirror.hlc_seen(last and last.hlc)
      local gev = { type = "obj", obj = kind, oid = p.oid, rev = mirror.next_rev(rev, owned(last and last.pos)), base = rev or 0, base_ev = evid ~= "" and evid or nil, gone = true, undoes = opts.undoes, redoes = opts.redoes, undoes_all = opts.undoes_all, redoes_all = opts.redoes_all, act = opts.act,
        name = last and last.name, track = last and last.track, pos = last and last.pos, was_after = was_after, items = items } -- (named: read later, it said "an unnamed track")
      local id = sync.post(cfg, song, room, gev)
      remember(proj, p.oid, gev.rev, "", id, mirror.order_of(gev))
      done = done + 1
    end
  end
  local function finish()
    reaper.Undo_EndBlock2(proj, "StudioSync: go back", -1)
    reaper.UpdateArrange()
    -- a lane takes its name only now its items are in, and they came after the track: forward lost "Take 1", and sent that (Mac, 0.42.5)
    local tracks_landed = false
    for _, p in ipairs(list) do
      local tr = p.landed and p.t.obj == "track" and type(p.t.state) == "table" and mirror.find(proj, "track", p.oid)
      if tr then
        tracks_landed = true
        mirror.set_track_state(proj, tr, p.t.state, opts.local_mix)
        local rev, _, evid, ord = mirror.known(proj, p.oid)
        remember(proj, p.oid, rev, mirror.track_hash(mirror.track_state(proj, tr, opts.local_mix), opts.local_mix), evid, ord)
      end
    end
    if tracks_landed then mirror.publish_order(proj, room_dir, cfg.user) end -- (the order it had then is the order now)
    local names = {}
    for n in pairs(kept_names) do names[#names + 1] = n end
    table.sort(names)
    if done == 0 and there > 0 and refused == 0 and kept == 0 and waiting == 0 and edited == 0 then return "it's already back: REAPER rebuilt it from its pass, so nothing changed", 0 end
    -- (and how many, for lib/undo.lua: an Undo that took nothing back leaves nothing to redo. rt-converge)
    return string.format("%d change(s) brought back and sent to the others%s%s%s%s", done, refused > 0 and string.format(" (%d not yours to change, left as they are)", refused) or "",
      (kept > 0 and string.format(" (kept what collaborators added since: %s)", table.concat(names, ", ")) or "")
        .. (gone_since > 0 and string.format(" (%d deleted by a bandmate since, left deleted)", gone_since) or ""),
      edited > 0 and string.format(" (%d left as they are: you've changed them here since, and that hasn't gone out yet. Let it go out, or undo it, then do this again)", edited) or "",
      waiting > 0 and string.format(". %d couldn't change here yet and weren't sent (plug-ins change only while stopped, and plug-ins, automation and sends only with this project's tab in front; an item may still be arriving, or open in the MIDI editor): do it again then", waiting) or ""), done
  end
  if #list <= mirror.REVERT_AT_ONCE or opts.at_once then
    reaper.Undo_BeginBlock2(proj)
    for _, p in ipairs(list) do one(p) end
    return finish()
  end
  -- A big one, a slice per pass: 415 changes held REAPER still for 6.9 s (Mac, 0.42). Each object lands and is remembered whole, so Live sync can
  -- look in between. No undo blocks in the middle: the one at the end is the single undo point for all of it.
  local i = 1
  local function slice()
    if not reaper.ValidatePtr(proj, "ReaProject*") then return band_log("Stopped bringing back changes: the project closed.") end
    local t0 = reaper.time_precise()
    while i <= #list and reaper.time_precise() - t0 < mirror.REVERT_SLICE do one(list[i]); i = i + 1 end
    if i <= #list then return reaper.defer(slice) end
    reaper.Undo_BeginBlock2(proj)
    band_log(finish())
  end
  mirror.revert_slice = slice -- (tests step it by hand)
  slice()
  return string.format("bringing back %d changes: REAPER keeps working while it does", #list)
end

-- Track order. A move used to travel only as that track's "sits under", landing only if its tab was in front, with each track
-- that came in later going wherever its neighbour then was: orders drifted apart, and nothing brought them back (0.56).
-- Each person's newest deliberate order: <room>/order/<user>.json, { list, time, by }; the newest of them is the studio's.
local function mirrored_order(proj)
  local list = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if not local_track(tr) then
      local oid = trk_oid(tr)
      if oid ~= "" then list[#list + 1] = oid end
    end
  end
  return list
end
-- After a receive pass that landed a bandmate's track (made, moved or deleted): the order as that left it is what the next look compares
-- with. A look took any difference in the order for the band's doing whenever a track of theirs had landed since the look before
-- (mirror.order_band), so a track you dragged in the seconds after a bandmate added one was never sent as a move: it stayed where you put it
-- on your computer alone, or rode out on the track's next change with no order list behind it. Now only what you changed after their
-- track landed reads as yours. (A band track landing outside a receive pass, a heal or a put-back, keeps the old rule until the next look.)
-- rt-converge
function mirror.order_after_band(proj)
  local pk = tostring(proj)
  if not mirror.order_band[pk] or mirror.order_seen[pk] == nil then return end
  mirror.order_seen[pk], mirror.order_band[pk] = table.concat(mirrored_order(proj), ","), nil
end
function mirror.read_order(room_dir)
  local band, best = require("band"), nil
  for _, f in ipairs(band.files(room_dir .. "/order", ".json")) do
    local j = band.read_json(room_dir .. "/order/" .. f)
    if type(j) == "table" and type(j.list) == "table" and type(j.time) == "string" and type(j.by) == "string"
      and (not best or j.time .. j.by > best.time .. best.by) then best = j end
  end
  return best
end
function mirror.publish_order(proj, room_dir, me)
  local band = require("band")
  reaper.RecursiveCreateDirectory(room_dir .. "/order", 0)
  band.write_json(room_dir .. "/order/" .. me:gsub("[^%w%-_ ]", "_") .. ".json", { list = mirrored_order(proj), time = os.date("!%Y-%m-%dT%H:%M:%SZ"), by = me })
end
-- This tab's tracks onto the studio's list, moving as few as it takes. Only with the tab in front (REAPER reorders nowhere else), stopped,
-- and caught up. -> how many moved.
function mirror.keep_order(proj, cfg, song, room)
  local sync = require("sync")
  if reaper.EnumProjects(-1) ~= proj or reaper.GetPlayStateEx(proj) ~= 0 then return 0 end
  if sync.pending_events(proj, cfg, song, room) > 0 then return 0 end
  local room_dir = sync.room_dir(cfg, song, room)
  local best, here = mirror.read_order(room_dir), mirrored_order(proj)
  if not best then -- (nobody's said yet: whoever's here first, and what they have then, is where everyone starts)
    if #here > 0 then mirror.publish_order(proj, room_dir, cfg.user) end
    return 0
  end
  local after = {}
  local listed = {}
  for _, x in ipairs(best.list) do listed[x] = true end
  for _, x in ipairs(here) do
    if not listed[x] then -- (only what's newer than the list: reading each record on every look isn't free)
      local _, _, evid = mirror.known(proj, x)
      local ev = evid and evid ~= "" and event_file(room_dir, evid)
      after[x] = ev and type(ev.state) == "table" and ev.state.after or ""
    end
  end
  local want = mirror.wanted_order(best.list, here, after)
  if table.concat(want, ",") == table.concat(here, ",") then return 0 end
  local moved, n = mirror.moved_tracks(here, want, {}), 0
  local sel = {}
  for i = 0, reaper.CountSelectedTracks(proj) - 1 do sel[#sel + 1] = reaper.GetSelectedTrack(proj, i) end
  -- (one undo point, StudioSync's: each ReorderSelectedTracks made REAPER's own "Change track order" on top of the person's list, which Ctrl+Z
  -- took for their own edit and undid in REAPER, and the next look sent that as their move. A "StudioSync: ..." point on top is one
  -- StudioSync's Undo steps over to the person's own last change (undo.native). REAPER check, rt-edits)
  reaper.Undo_BeginBlock2(proj)
  reaper.PreventUIRefresh(1)
  for k, x in ipairs(want) do
    local tr = moved[x] and mirror.find(proj, "track", x)
    if tr then
      local above = k > 1 and mirror.find(proj, "track", want[k - 1])
      reaper.SetOnlyTrackSelected(tr)
      reaper.ReorderSelectedTracks(above and math.floor(reaper.GetMediaTrackInfo_Value(above, "IP_TRACKNUMBER")) or 0, 0)
      n = n + 1
    end
  end
  for i = reaper.CountSelectedTracks(proj) - 1, 0, -1 do reaper.SetTrackSelected(reaper.GetSelectedTrack(proj, i), false) end
  for _, x in ipairs(sel) do if reaper.ValidatePtr2(proj, x, "MediaTrack*") then reaper.SetTrackSelected(x, true) end end
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock2(proj, "StudioSync: the studio's track order", -1)
  mirror.order_seen[tostring(proj)] = table.concat(mirrored_order(proj), ",") -- (not a move of this person's: the next look mustn't send it)
  reaper.TrackList_AdjustWindows(false)
  return n
end

-- Did someone move this track between the version `upto` (an event id) and `x`, a newer version built on it? -> the track it sat under
-- before the oldest such move ("" for the top), or nil when nobody moved it. A change sent with a move of yours carries `moved` (W.send);
-- changes from before rt-edits carry none, so those moves aren't taken back. Walks what x builds on (a merged version: its winner), 200
-- versions at most.
function mirror.moved_since(room_dir, x, upto)
  local from, steps = nil, 0
  while type(x) == "table" and x.id ~= upto and steps < 200 do
    if type(x.moved) == "string" then from = x.moved end
    steps = steps + 1
    local next_id = mirror.split_merge(x.id) or x.base_ev
    x = next_id and event_file(room_dir, next_id) or nil
  end
  return from
end
-- Does landing version `x` of a track move the track, on a computer that holds version `held` (an event id)? Only when someone moved it on
-- purpose in between: x, or a version x builds on down to `held`, says it is a move (`moved`: W.send, mirror.revert), on either side of a
-- merge. The place every change names (`after`) is only where the track sat on its sender's computer. rt-converge
function mirror.says_move(room_dir, x, held)
  if mirror.moved_since(room_dir, x, held) ~= nil then return true end
  return type(x.loser) == "table" and mirror.moved_since(room_dir, x.loser, held) ~= nil
end
-- Track order put right during a session. keep_order ran only as a project opened, and did nothing then if changes still waited, so a move
-- that never landed (its tab was behind; a catch-up that applied two tracks' old places one after the other) or an older file's order stayed
-- until the project was opened again, with Health red. REAPER check, 0.59.49.76: the desktop reopened an older file and one change of a
-- track carried that file's place; LinuxBox moved the track, the laptop, catching up after a restart, ended on the studio's list, and nothing
-- brought them together for 15 minutes. Live sync asks every pass (P.heal). The rule, so tracks never move under someone at work:
--   only this tab in front, the transport stopped (not playing or recording), this project's first catch-up done;
--   only `idle` >= ORDER_IDLE: seconds since your last edit, 0 while a mouse button is down (Live sync's count);
--   the first time after opening: once nothing of the band's waits to land;
--   after that: only when a caught-up bandmate has had another track order for APART_SECS (mirror.order_apart_for, whatever else differs), not within
--   ORDER_WAIT of a bandmate's move landing here (its mover's order list comes through Syncthing, seconds behind the move), and at most
--   every APART_SECS.
-- Where the tracks go: the studio's newest order list, as when opening (mirror.wanted_order). Every computer goes to the same list, so
-- whichever of them is off moves. -> how many tracks moved.
mirror.ORDER_IDLE, mirror.ORDER_WAIT = 10, 120
mirror.order_landed = mirror.order_landed or {} -- tostring(proj) -> when a bandmate's track move last landed here (mirror.apply)
mirror.order_moved = mirror.order_moved or {} -- tostring(proj) -> true: a bandmate's move landed in this receive pass (sync.receive publishes the order)
mirror.order_kept = mirror.order_kept or {} -- tostring(proj) -> when order_heal last put the order right, or found it right
function mirror.order_heal(proj, cfg, song, room, now, idle)
  local sync, pk = require("sync"), tostring(proj)
  if (idle or 0) < mirror.ORDER_IDLE or sync.loading[pk] or reaper.EnumProjects(-1) ~= proj or reaper.GetPlayStateEx(proj) ~= 0 then return 0 end
  if mirror.order_kept[pk] then
    if not mirror.order_apart_for(proj, now) or now - mirror.order_kept[pk] < mirror.APART_SECS or now - (mirror.order_landed[pk] or -math.huge) < mirror.ORDER_WAIT then return 0 end
  elseif sync.pending_events(proj, cfg, song, room) > 0 then return 0 end
  mirror.order_kept[pk] = now
  local n = mirror.keep_order(proj, cfg, song, room)
  if n > 0 then
    require("band").log(string.format("%d track(s) put in the studio's order: a move that hadn't landed here, or an older file's order", n))
  end
  return n
end

-- Use mine: what lost a clash comes back at once, for everyone. mine: { { oid, ev (the event id of your version) } }. -> what happened in words, or nil with nothing to do.
function mirror.use_mine(proj, cfg, song, room, mine, opts)
  local dir, plan = require("sync").room_dir(cfg, song, room), {}
  for _, m in ipairs(mine or {}) do
    local ev = type(m.ev) == "string" and event_file(dir, m.ev)
    if ev and m.oid then plan[m.oid] = (not ev.gone) and ev or false end
  end
  if not next(plan) then return nil end
  return mirror.revert(proj, cfg, song, room, plan, opts)
end

-- Local mixing on: each track's record here is redone without its fader and pan.
function mirror.begin_local_mix(proj)
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local oid = trk_oid(tr)
    local rev, h, evid, order = mirror.known(proj, oid)
    if rev and h ~= "" then remember(proj, oid, rev, mirror.track_hash(mirror.track_state(proj, tr), true), evid, order) end
  end
end

-- Local mixing off again: either adopt the band's faders and pan (each track as its newest revision has them), or
-- send yours (each track's next look counts as a change; it goes out if you may change that track).
function mirror.end_local_mix(proj, cfg, song, room, adopt)
  local band, sync = require("band"), require("sync")
  local rdir = sync.room_dir(cfg, song, room)
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local oid = trk_oid(tr)
    local rev, h, evid, order = mirror.known(proj, oid)
    if rev then
      if adopt then
        local ev = evid ~= "" and band.read_json(require("direct").path(cfg, rdir .. "/events", evid .. ".json")) -- (or its inbox copy: James, 0.60.0-rt)
        if type(ev) == "table" and type(ev.state) == "table" then
          if ev.state.vol and ev.state.vol ~= "" then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", tonumber(ev.state.vol)) end
          if ev.state.pan and ev.state.pan ~= "" then reaper.SetMediaTrackInfo_Value(tr, "D_PAN", tonumber(ev.state.pan)) end
          for _, kp in ipairs(mirror.TRACK_MIX) do
            if tonumber(ev.state[kp[1]]) then reaper.SetMediaTrackInfo_Value(tr, kp[2], tonumber(ev.state[kp[1]])) end
          end
        end
        local t = mirror.track_state(proj, tr, false)
        remember(proj, oid, rev, mirror.track_hash(t, false), evid, order)
      else
        remember(proj, oid, rev, "-", evid, order) -- (no hash matches "-": the next look sends it)
      end
    end
  end
end

-- One code for this whole project as mirrored (every object's version here): two machines with the same code hold
-- the same project. Published in the status file; Who's here compares it.
-- (held between passes, 10-13 ms a pass on a heavy song: until the project's change count moves, this script writes a record, or ROOT_HOLD
-- seconds pass, for records another script wrote (the panel's Restore or Undo). rt-perfcut2)
mirror.ROOT_HOLD = 10
mirror.root_memo = mirror.root_memo or {}
function mirror.root(proj)
  local pk, cc, now = tostring(proj), reaper.GetProjectStateChangeCount and reaper.GetProjectStateChangeCount(proj), reaper.time_precise()
  local m = mirror.root_memo[pk]
  if m and m.cc == cc and m.n == mirror.rec_writes and now >= m.at and now - m.at < mirror.ROOT_HOLD then return m.code end
  local t, i = {}, 0
  while true do
    local ok, oid, v = reaper.EnumProjExtState(proj, mirror.SEC, i)
    if not ok then break end
    i = i + 1
    -- the band's newest change of each thing, not its hash: a plug-in saves its data its own way on each machine, and a
    -- machine without it re-encodes it, so hashes differ for good with nothing different to hear (Surge, UADx, Superior Drummer:
    -- Mac, 0.42.6). What came out differently on landing is what "mirror drift" reports.
    local h, ev = v:match("^%d+|([^|]*)|([^|]*)")
    if h and h ~= "" then t[#t + 1] = oid:upper() .. "=" .. tostring(ev) end
  end
  table.sort(t)
  local code = mirror.hash(table.concat(t, "\n"))
  mirror.root_memo[pk] = { cc = cc, n = mirror.rec_writes, at = now, code = code }
  return code
end
-- The mirrored tracks' order as one code, beside `mirror` in the status: the code above doesn't hold it (a track's place isn't part of its
-- version), so two computers with the same code could show their tracks in another order with nothing said. rt-undo
function mirror.order_code(proj) return mirror.hash(table.concat(mirrored_order(proj), ",")) end
-- Who has every change, as this computer has, yet holds another project or another track order. Live sync notes it each pass (non-persisted
-- ExtState "apart <proj>": since|key|what|names), and Health's "come out the same here" row is red once the same difference has stood for
-- APART_SECS (the codes differ for some seconds after any edit: each computer says its own every few seconds). The row went by the "mirror
-- drift" count alone, a change that hashed differently here than on its sender's computer the moment it landed, and stayed green through F5:
-- every change hashed the same as it landed, and again when heal put the older one back. rt-undo
-- mine, order: mirror.root's and mirror.order_code's here; pending: the band's changes not applied here yet; peers: the others' statuses
-- ({ user, mirror, order, pending }; no order from an older StudioSync: not compared); now: reaper.time_precise().
mirror.APART_SECS = 30
function mirror.apart_note(proj, mine, order, pending, peers, now)
  local band = require("band")
  local names, key, what = {}, { tostring(mine), tostring(order) }, nil
  local onames, okey = {}, { tostring(order) }
  for _, st in ipairs(peers) do
    local caught_up = st.mirror and st.pending == 0
    local p = caught_up and st.mirror ~= mine
    local o = caught_up and st.order ~= nil and order ~= nil and st.order ~= order
    if p or o then
      names[#names + 1] = tostring(st.user)
      key[#key + 1] = tostring(st.user) .. "=" .. tostring(st.mirror) .. "/" .. tostring(st.order)
      what = (p or what == "project") and "project" or "order"
    end
    if o then onames[#onames + 1] = tostring(st.user); okey[#okey + 1] = tostring(st.user) .. "=" .. tostring(st.order) end
  end
  -- (pending: a number, or a function asked only when someone's apart: counting walks the folder's listing)
  if #names > 0 and (type(pending) == "function" and pending() or pending or 0) ~= 0 then names, onames = {}, {} end
  local function note(k, list, parts, w)
    local had = reaper.GetExtState(band.SECTION, k)
    if #list == 0 then
      if had ~= "" then reaper.DeleteExtState(band.SECTION, k, false) end
      return
    end
    local h = mirror.hash(table.concat(parts, " "))
    local since, was = had:match("^([^|]*)|([^|]*)|")
    local v = (was == h and since or string.format("%.3f", now)) .. "|" .. h .. "|" .. w .. "|" .. table.concat(list, ", ")
    if v ~= had then reaper.SetExtState(band.SECTION, k, v, false) end
  end
  note("apart " .. tostring(proj), names, key, what)
  -- (and the track order alone, against each caught-up computer that says its order, whatever else differs: one bandmate on an older StudioSync,
  -- whose project code always differs, made the note "project", and the order heal waited on "order" for over 6 minutes. REAPER recheck,
  -- 0.59.49.79, rt-edits round 6)
  note("apart order " .. tostring(proj), onames, okey, "order")
end
-- -> who, for how many seconds, while some caught-up computer has held another track order for APART_SECS; nil otherwise.
function mirror.order_apart_for(proj, now)
  local since, names = reaper.GetExtState(require("band").SECTION, "apart order " .. tostring(proj)):match("^([^|]*)|[^|]*|[^|]*|(.*)$")
  since = tonumber(since)
  if not since or now - since < mirror.APART_SECS then return nil end
  return names, now - since
end
-- -> who, for how many seconds, and what differs ("project" or "order"); nil while nobody's apart or it hasn't stood APART_SECS.
function mirror.apart_for(proj, now)
  local since, what, names = reaper.GetExtState(require("band").SECTION, "apart " .. tostring(proj)):match("^([^|]*)|[^|]*|([^|]*)|(.*)$")
  since = tonumber(since)
  if not since or now - since < mirror.APART_SECS then return nil end
  return names, now - since, what
end


-- ---- side rooms ------------------------------------------------------------------------------------------
-- A side room starts as a copy of its parent tab (ids and all), so both share every object's history up to then.

-- The newest revision of each object among a room's events, optionally only those after `since` (ISO time).
-- (each file read once per session and kept without its state, which is read from the file when something asks for it (heal applying it,
-- a settle merging it), as History keeps events, lib/recall.lua: every heal read and decoded the room's whole history, 0.5 to 1 s at 2,400
-- events, 5 to 10 s at 20,000. Events never change once written. Cost: a few hundred bytes an event in memory. Round 2 review, 0.59.46)
local light_events = {} -- room dir -> { file -> the event, state on demand }
local lazy_state = { __index = function(ev, k)
  if k ~= "state" then return nil end
  -- (where its file is now: one that came over the direct link is in the link's inbox until Syncthing's copy is here. F5, rt-undo)
  local dir, f = rawget(ev, "path_"):match("^(.*)/([^/]+)$")
  local full = require("band").read_json(require("direct").path(nil, dir, f))
  local st = type(full) == "table" and full.state or nil
  rawset(ev, "state", st) -- (kept once asked for: apply reads it many times)
  return st
end }
local function light_event(room_dir, f, inbox) -- (inbox: it's in the direct link's inbox, not the folder yet)
  local box = light_events[room_dir]
  if not box then box = {}; light_events[room_dir] = box end
  local ev = box[f]
  if ev == nil then
    local path = room_dir .. "/events/" .. f
    ev = require("band").read_json(inbox and require("direct").path(nil, room_dir .. "/events", f) or path)
    if type(ev) ~= "table" then return nil end -- (half-synced: read again next time)
    if ev.state ~= nil then ev.state, ev.path_ = nil, path; setmetatable(ev, lazy_state) end
    box[f] = ev
  end
  return ev
end
mirror.light_event = light_event
-- An event already read whole (sync.receive's), kept as light_event would have kept it: for the index, without reading its file again.
function mirror.light_of(room_dir, f, ev)
  local box = light_events[room_dir]
  if not box then box = {}; light_events[room_dir] = box end
  if box[f] ~= nil then return box[f] end
  local l = {}
  for k, x in pairs(ev) do if k ~= "state" then l[k] = x end end
  if ev.state ~= nil then l.path_ = room_dir .. "/events/" .. f; setmetatable(l, lazy_state) end
  box[f] = l
  return l
end
function mirror.room_newest(room_dir, since)
  local too_new, evindex = require("sync").too_new, require("evindex")
  local out, all = {}, {}
  evindex.load(room_dir)
  for _, oid in ipairs(evindex.oids(room_dir)) do
    local list = evindex.versions(room_dir, oid)
    table.sort(list, function(a, b) return a.id < b.id end)
    for _, ev in ipairs(list) do
      -- (not a change too new for this version: receive leaves it for the version that knows it, and heal applied it anyway and recorded it held,
      -- so once updated it never landed properly. Round 3 review, 0.59.48. Cost: one comparison an event)
      if (not since or (ev.time or "") > since) and not too_new(ev) then
        local cur = out[oid]
        if not cur or mirror.newer({ rev = ev.rev, time = mirror.order_of(ev) }, { rev = cur.rev, time = mirror.order_of(cur) }) then out[oid] = ev end
        all[oid] = all[oid] or {}
        table.insert(all[oid], ev)
      end
    end
  end
  return out, all
end
-- The version every computer ends on, from an object's changes in a room (`all`, as room_newest lists them; `newest`, its newest): the judge's
-- answer (lib/judge.lua), or the newest while that's incomplete. rt-sync2b
function mirror.settled(room_dir, newest, all)
  local s = judge.settled(all or { newest }, reader(room_dir), { mergeable = mirror.mergeable, days = mirror.MERGE_DAYS })
  return s.v or newest
end

-- Has this object been changed here since the version this computer last sent or took in (its record's hash `h`)? Then it isn't sent yet
-- (a look hasn't run, or it's settling), and revert and heal leave it: they put the band's version over it with no copy. Items and tracks by
-- their state now (one hash each); plug-ins, automation and the rest by the unsent flag watch keeps while they settle. `last`: the record's
-- event (only its place or a print's label differing isn't an edit). Round 1 review, 0.59.45
-- (and what Live sync holds unsent for this tab, published in a non-persisted ExtState "unsent <tostring(proj)>" (oids, comma-separated): its
-- own table is in its own Lua, and Restore or Ctrl+Z from the panel or the Undo script went over a held plug-in chain with no copy. Parsed once
-- per change of the text. Round 2 review, 0.59.46)
local unsent_text, unsent_set = nil, {}
function mirror.unsent_elsewhere(proj)
  local v = reaper.GetExtState(require("band").SECTION, "unsent " .. tostring(proj))
  if v ~= unsent_text then
    unsent_text, unsent_set = v, {}
    for x in v:gmatch("[^,]+") do unsent_set[x] = true end
  end
  return unsent_set
end
function mirror.edited_here(proj, oid, h, last, media, local_mix)
  if mirror.unsent[tostring(proj) .. oid] or mirror.unsent_elsewhere(proj)[oid] then return true end
  mirror.restless_load() -- (the panel never loaded it: an item with a restless take plug-in read as "changed here". Round 2 review, 0.59.46)
  if (h or "") == "" then return false end
  local kind = oid:sub(1, 1)
  if kind == "I" then
    local it = mirror.find(proj, "item", oid)
    if not it then return false end
    local st = mirror.item_state(it, media)
    local on = trk_oid(reaper.GetMediaItem_Track(it))
    local now = mirror.item_hash(on, st)
    if now == h then return false end
    -- (moved to another track and nothing else: edited here. rt-edits)
    return not (last and type(last.state) == "string" and (last.hash == now or ((last.track == nil or last.track == on) and mirror.same_but_labels(st, last.state))))
  elseif kind == "T" then
    local tr = mirror.find(proj, "track", oid)
    if not tr then return false end
    local t = mirror.track_state(proj, tr, local_mix)
    if mirror.track_hash(t, local_mix) == h then return false end
    return not (last and type(last.state) == "table" and mirror.same_line(t, last.state, local_mix))
  end
  return false
end

-- A track made again here by a band event or a revert (Bo's later fader move winning over Al's delete, StudioSync's Undo of a deletion): its
-- plug-ins, automation, sends and the rest, recorded gone with it but still naming a change that isn't a deletion, come back too, as
-- W.keep_held's bring does. It came back bare, and the projects stayed different for good. One that can't land now (playing, its tab behind)
-- is brought by heal. Cost: at most 4 cached event reads per returning track. Round 1 review, 0.59.45
function mirror.bring_parts(proj, toid, media_dir, local_mix)
  local room_dir = media_dir:gsub("/media$", "")
  for _, p in ipairs(mirror.PARTS) do
    local x = p .. toid:sub(2)
    -- (whatever its record's hash: a track just made has none of its parts, and one deleted by one receive pass and made again by the next,
    -- with no look between, still had live records and stayed bare; the next look sent "no plug-ins" to everyone. Remembered with the event's
    -- own order, not the gone record's empty one. Round 2 review, 0.59.46)
    local _, _, evid = mirror.known(proj, x)
    local ev = (evid or "") ~= "" and event_file(room_dir, evid)
    if ev and not ev.gone then
      local ok, applied, hash = pcall(mirror.apply, proj, ev, media_dir, local_mix)
      if ok and applied then remember(proj, x, ev.rev, hash or "", ev.id, mirror.order_of(ev)) end
    end
  end
end

-- Bring this project in line with the judge's answer for every object in the room (lib/evindex.lua, lib/judge.lua: the folder and the link's
-- inbox): a change that was skipped or never landed here (an unreadable file, a failed apply) left two projects different for good, since
-- nothing applied it again (review, 2026-10-31). Always towards the room's own events, never towards a particular machine, so two machines
-- can't pull each other back and forth. What the judge says is already held is left as it is (what came out different there isn't fixed by
-- applying it again). The judge replaces mirror.settled's newest-plus-rivals and its exceptions (rt-sync2b): a version held here but not read
-- ("ahead") stands in from its record, so nothing older goes back over it; a part or item recorded gone with a track that's here comes back
-- with it ("bare", mirror.lands); and MERGE_NEWS_SECS's hour is the grandfather rule below. Returns how many were brought in line.
-- Grandfathered (rt-sync2 section 1, "Old history"): an object whose every version predates JUDGE_SINCE (by its id's time), and whose held
-- version is one of its leaves, stands as it is: a race settled before the judge (newest-wins, or by clock), which the judge would settle
-- otherwise now, changed a day or a month late on every computer. A held version behind a leaf is still brought forward. Health's "Bring in
-- line" settles the rest deliberately (James, 2026-11-27: a button, not automatic; phase 8).
mirror.STAY = {} -- (see mirror.apply: a track version put in place without moving the track)
mirror.JUDGE_SINCE = "20261128-000000"
local function grandfathered(s, kev, versions)
  if (kev or "") == "" then return false end
  for _, v in ipairs(versions) do
    for d in tostring(v.id):gmatch("(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d)Z") do if d >= mirror.JUDGE_SINCE then return false end end
  end
  local leaf = {}
  for _, id in ipairs(s.leaves or {}) do leaf[id] = true end
  for id in tostring(kev):gmatch("[^()&]+") do if id ~= "m" and not leaf[id] then return false end end
  return true
end
function mirror.heal(proj, room_dir, local_mix)
  local n = 0
  local evindex = require("evindex")
  evindex.load(room_dir)
  -- (its changes under one undo point, StudioSync's, opened before the first: with none, the person's next edit took them into its own point,
  -- and REAPER's Undo of that edit undid the catch-up too, which the next look sent as theirs. keep_order's reason too. rt-edits)
  -- (and not for a change that waits (mirror.will_wait, as sync.receive opens none): opened, it closed as a point with nothing in it and no log
  -- line. REAPER recheck, 0.59.49.79, rt-edits round 6)
  local open = false
  local function apply(p, e, ...)
    if not open and not mirror.will_wait(p, e) then reaper.Undo_BeginBlock2(proj); open = true end
    return mirror.apply(p, e, ...)
  end
  -- (in one order on every computer and every run: tracks, each after the track it sits under when that's among them, then their parts,
  -- then items, by id. Walked as Lua's table gave them, an item came before its track and waited for the next heal, five minutes on, and a
  -- track before the one it sits under went to the top; which computer had which depended on its Lua's hash seed. The soak's bug 8.
  -- rt-converge)
  local oids, rank, answers = evindex.oids(room_dir), { T = 1, F = 2, E = 2, R = 2, M = 2 }, {}
  table.sort(oids, function(a, b)
    local ra, rb = rank[a:sub(1, 1)] or 3, rank[b:sub(1, 1)] or 3
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  local function answer(oid)
    local s = answers[oid]
    if not s then s = mirror.judge(proj, oid, room_dir, {}); answers[oid] = s end
    return s
  end
  local ordered, placed = {}, {}
  local function place(oid)
    if placed[oid] then return end
    placed[oid] = true
    local ev = oid:sub(1, 1) == "T" and answer(oid).v
    local above = ev and ev.obj == "track" and not ev.gone and type(ev.state) == "table" and ev.state.after
    if type(above) == "string" and above:sub(1, 1) == "T" and evindex.versions(room_dir, above)[1] then place(above) end
    ordered[#ordered + 1] = oid
  end
  for _, oid in ipairs(oids) do place(oid) end
  local ok_all, err_all = pcall(function()
  for _, oid in ipairs(ordered) do
    local s = answer(oid)
    local ev = s.complete and s.v
    local krev, kh, kev = mirror.known(proj, oid)
    if not ev or ev.stub or mirror.unsent[tostring(proj) .. oid] then -- (a change of yours not sent yet (held, settling): it goes out, or is put back, by mirror.watch. Sync engine review, 0.58.76)
    elseif kev ~= ev.id and krev and grandfathered(s, kev, evindex.versions(room_dir, oid)) then
    elseif mirror.lands(proj, s) and not mirror.edited_here(proj, oid, kh, kev and kev ~= "" and event_file(room_dir, kev) or nil, room_dir .. "/media", local_mix) then
      -- (not over an edit of yours a look hasn't sent yet: the next look sends it, or puts it back. Round 1 review, 0.59.45)
      local order = mirror.order_of(ev)
      if ev.gone then
        -- (a part of a track that isn't here: only its record. Applied, it changed nothing and still counted, a "caught up" line for nothing. round 6)
        if kh and kh ~= "" and mirror.PART[ev.obj] and not mirror.find(proj, "track", ev.track or ("T" .. oid:sub(2))) then
          remember(proj, oid, ev.rev, "", ev.id, order)
        elseif kh and kh ~= "" then
          -- (a part that can't change now, playing or its tab behind: next time, not recorded as gone with its chain still here. 0.59.14)
          -- (and a track's deletion with what it says went with it, and who made it: apply keeps only work of yours it never saw. rt-sync2b)
          if apply(proj, { obj = ev.obj, oid = oid, gone = true, track = ev.track, items = ev.items, user = ev.user }, room_dir .. "/media", local_mix) then
            remember(proj, oid, ev.rev, "", ev.id, order)
            n = n + 1
          end
        else remember(proj, oid, ev.rev, "", ev.id, order) end -- (not here, and gone: the record says so)
      elseif not on_gone_track(proj, ev) then
        -- (a track stays where it is unless its place is what this version changes, against the one held here: a track's newest change
        -- keeps the "sits under" of the day it was made, and one that only sits elsewhere since isn't sent again. F5, rt-undo)
        -- (and only where a move was made on purpose between the version held and this one, as mirror.receive lands one: mirror.says_move.
        -- rt-converge)
        local held, put = ev.obj == "track" and (kev or "") ~= "" and event_file(room_dir, kev), ev
        if held and type(held.state) == "table" and type(ev.state) == "table" and (held.state.after == ev.state.after or not mirror.says_move(room_dir, ev, kev)) then
          put = setmetatable({ [mirror.STAY] = true }, { __index = ev })
        end
        local ok, applied, h = pcall(apply, proj, put, room_dir .. "/media", local_mix)
        if ok and applied then -- (a part waiting for its tab to be in front, or a track not here yet: next time)
          remember(proj, oid, ev.rev, h or "", ev.id, order)
          n = n + 1
        end
      else remember(proj, oid, ev.rev, "", ev.id, order) end -- (on a track that's gone: recorded gone with it, under this version)
    end
  end
  end)
  if open then reaper.Undo_EndBlock2(proj, "StudioSync: changes that hadn't arrived here", -1) end
  if not ok_all then error(err_all, 0) end
  return n
end

-- What bringing a side room into its parent does, from both rooms' changes since the room was made: what only the
-- side room changed comes in; what both changed is a clash, and the parent's stays. Pure.
-- `everything` (optional): the parent's newest of all time. What the side room deleted and the parent no longer has isn't a change to bring (Windows, 0.58.7: a backup listed a
-- track gone from main long ago as "deleted").
function mirror.plan_bring(side, main, everything)
  local bring, clash = {}, {}
  for oid, ev in pairs(side) do
    if main[oid] then clash[#clash + 1] = ev
    elseif not (ev.gone and everything and (not everything[oid] or everything[oid].gone)) then bring[#bring + 1] = ev end
  end
  local o = { track = 1, fx = 2, item = 3 } -- a new track before what sits on it
  table.sort(bring, function(a, x) return (o[a.obj] or 3) < (o[x.obj] or 3) end)
  return bring, clash
end

-- Bring a side room into its parent: what the side room changed comes in, unless the parent's version has moved on from the one the side
-- room started from (a clash: the parent keeps its own). Decided by versions, not clocks: "changed since the room was made" was each
-- author's clock against the room's, so a slow clock's change in the parent was missed and overwritten. Review, 0.58.97.
-- What the parent already has as the side room has it (brought before) isn't brought again. -> bring, clash.
function mirror.bring_plan(side_dir, main_dir, side_name)
  local side, side_all = mirror.room_newest(side_dir)
  local main, main_all = mirror.room_newest(main_dir)
  local moved = {}
  for oid, list in pairs(side_all) do
    local m = main[oid]
    if m and m.from_room ~= side_name then -- (the parent's newest is what this room brought: not a change of the parent's own)
      local first
      for _, ev in ipairs(list) do
        if not first or mirror.newer({ rev = first.rev, time = mirror.order_of(first) }, { rev = ev.rev, time = mirror.order_of(ev) }) then first = ev end
      end
      -- (the parent's version may be a merge, which the side room started from as "m(a&b)": the parent's newest plain id never matched it,
      -- and every such item was a clash. Review, 0.58.98)
      local settled = main_all[oid] and mirror.settled(main_dir, m, main_all[oid])
      if m.id ~= first.base_ev and not (settled and settled.id == first.base_ev) then moved[oid] = m end
    end
  end
  local bring, clash = mirror.plan_bring(side, moved, main)
  local out = {}
  for _, ev in ipairs(bring) do
    local m = main[ev.oid]
    if not (m and m.state == ev.state and (m.gone or false) == (ev.gone or false)) then out[#out + 1] = ev end
  end
  return out, clash
end

-- Send revisions into room `to` (as its newest revisions there). `here`:
-- that room's tab on this machine, if open (your own changes never come back to you through Live sync).
function mirror.post_into(cfg, song, from, to, list, here)
  local band, sync = require("band"), require("sync")
  local fdir, tdir = sync.room_dir(cfg, song, from), sync.room_dir(cfg, song, to)
  local newest = mirror.room_newest(tdir)
  reaper.RecursiveCreateDirectory(tdir .. "/media", 0)
  local n = 0
  for _, ev in ipairs(list) do
    -- (its media stays where it is: tokens name their room's folder, which every machine has)
    local cur = newest[ev.oid]
    mirror.hlc_seen(cur and cur.hlc) -- (the clock past the version it lands on there, as W.send does. Round 1 review, 0.59.45)
    local new = { type = "obj", obj = ev.obj, oid = ev.oid, rev = (cur and cur.rev or 0) + 1, base = cur and cur.rev or 0, base_ev = cur and cur.id,
      state = ev.state, track = ev.track, name = ev.name, pos = ev.pos, gone = ev.gone, from_room = from, tm = ev.tm, tb = ev.tb }
    sync.post(cfg, song, to, new)
    if here and reaper.ValidatePtr2(0, here, "ReaProject*") then -- (with that tab's own Local mixing: off, its faders took the band's. 0.59.14, review)
      mirror.receive(here, new, tdir .. "/media", select(2, reaper.GetProjExtState(here, band.SECTION, "local_mix")) == "1")
    end
    n = n + 1
  end
  return n
end

-- Of these revisions, those this person may make in `to` by that room's claims and driver; and how many they may not.
-- ("Send selected" took a bandmate's claimed item into main with nothing to stop it: laptop, 0.42.2)
function mirror.allowed_into(cfg, song, to, list, session)
  local sync = require("sync")
  local can, who = sync.authority(cfg, song, to, session)
  local keep, refused = {}, 0
  for _, ev in ipairs(list) do
    local t = ev.obj == "track" and ev.oid or ev.track
    if can(cfg.user, ev.name or "", ev.pos) or sync.maker_may(t, cfg.user, ev.name or "", ev.pos, who.mode, ev.obj == "item" and ev.oid or nil, who.is_claimed) then keep[#keep + 1] = ev
    else refused = refused + 1 end
  end
  return keep, refused
end

-- The selected items here (and any track of theirs the other room hasn't got), as revisions to send to `to`.
function mirror.selected(proj, cfg, song, from, to)
  local sync = require("sync")
  local media = sync.room_dir(cfg, song, from) .. "/media"
  local there = mirror.room_newest(sync.room_dir(cfg, song, to))
  local list, tracks = {}, {}
  local _, by_oid = mirror.scan(proj, cfg.user, media, false)
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
    local it = reaper.GetSelectedMediaItem(proj, i)
    local tr = reaper.GetMediaItem_Track(it)
    local toid, ioid = trk_oid(tr), itm_oid(it)
    if toid ~= "" and ioid ~= "" then
      local name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false))
      if not tracks[toid] and not there[toid] then
        tracks[toid] = true
        list[#list + 1] = { obj = "track", oid = toid, state = mirror.track_state(proj, tr), name = name }
        -- (with its plug-ins, automation, sends and the rest: a new idea arrived in main without its Neve: Mac, 0.42.4)
        for _, p in ipairs(mirror.PARTS) do
          local o = by_oid[p .. toid:sub(2)]
          if o and o.state ~= "" then list[#list + 1] = { obj = o.kind, oid = o.oid, track = toid, state = o.state, name = name } end
        end
      end
      list[#list + 1] = { obj = "item", oid = ioid, track = toid, state = mirror.item_state(it, media), name = name,
        pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION") }
    end
  end
  return list
end

return mirror
