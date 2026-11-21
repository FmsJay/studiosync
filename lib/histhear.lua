-- Song history playback (roadmap item 12; James, rt): on the History page, pick a point and hear the song as it was then, A/B it against
-- now, and restore that point (the whole song, or chosen tracks) as a new change everyone gets.
-- Hearing never touches the open project: a copy of it is saved (band.save_copy, as prints and bounces save theirs), rebuilt as text to that
-- moment (histhear.rebuild: mirror.plan_restore's plan, each object's state from History put into the copy, objects made since taken out,
-- deleted ones put back, receives renumbered), and a background REAPER (lib/bgrender.lua's hidden -renderproject job) renders it to a
-- small Opus file. What a chunk can't say (an item's fixed lane, its picked take, a track's settings, the render format) the job's own
-- prep.lua sets through REAPER's API in that background REAPER before its first pass (histhear.prep; bgrender runs it). The file is served
-- to the page through GET /api/file?id= (Lua names it: StudioSync_WebUIOffer), kept per point (KEEP files) in this computer's temp folder.
-- One render at a time ("then", then "now" for A/B), cancellable.
-- Restoring goes through the Restore page's own machinery (mirror.plan_restore, sync.restore_timeline, mirror.revert) after a confirm that
-- says what changes: one REAPER undo point (at_once) and one act in History (every event carries the same `act`, so Undo this change on any
-- row of it takes all of it back). Whole song: the driver only, as on the panel; chosen tracks: each object as its usual rules allow.
local band = require("band")
local histhear = {}
histhear.KEEP = 10          -- previews kept on this computer (per song and room), newest last
histhear.RECIPE = 3         -- how a preview is rendered: raised when that changes, so a preview an older build kept is never served (0.59.49.74 played .73's clipping one; 3: the tempo map, markers, track order and master automation then, rt-history2)
histhear.PASSES = 2         -- renders of the copy at most (bgrender's pass script: a sampler still loading gets its second)
histhear.START_GAP = 3      -- seconds between starting renders (a page can't make this computer start one after another)
histhear.ASK_FOR = 120      -- seconds a restore's "what changes" stays good for its yes
histhear.TRACKS_MAX = 200   -- tracks a page may name for a restore
histhear.TRACKS_EVERY = 5   -- seconds between reading the project's tracks for the page's list
histhear.NAMES_MAX = 6      -- track names a restore's words list

-- ---- pure: the copy as it was ----------------------------------------------------------------------------------------------------------
local function trim(l) return l:match("^%s*(.-)%s*$") end
-- Lines from i to j at one depth -> units { tag, lines, block }: a block's lines whole, its first to its closing ">".
local function units(L, i, j)
  local out, k = {}, i
  while k <= j do
    local s = trim(L[k])
    if s:sub(1, 1) == "<" then
      local d, a = 1, k
      k = k + 1
      while k <= j and d > 0 do
        local t = trim(L[k])
        if t:sub(1, 1) == "<" then d = d + 1 elseif t == ">" then d = d - 1 end
        k = k + 1
      end
      local lines = {}
      for x = a, k - 1 do lines[#lines + 1] = L[x] end
      out[#out + 1] = { tag = s:match("^<(%S+)"), lines = lines, block = true }
    elseif s ~= "" then
      out[#out + 1] = { tag = s:match("^(%S+)"), lines = { L[k] } }
      k = k + 1
    else k = k + 1 end
  end
  return out
end
local function split(text)
  local L = {}
  for l in (tostring(text):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do L[#L + 1] = l end
  while #L > 0 and trim(L[#L]) == "" do L[#L] = nil end
  return L
end
-- A block's inner units (its first and last lines left out).
local function inner(u) return units(u.lines, 2, #u.lines - 1) end
local function flat(list, out)
  out = out or {}
  for _, u in ipairs(list) do for _, l in ipairs(u.lines) do out[#out + 1] = l end end
  return out
end
-- A block unit back from inner units.
local function block(head, list, tail)
  local lines = { head }
  flat(list, lines)
  lines[#lines + 1] = tail or ">"
  return { tag = trim(head):match("^<(%S+)"), lines = lines, block = true }
end
-- The EXT keys a track or item holds (its <EXT> / <EXTI> block straight under it). -> { key = value }
local function ext_of(list)
  for _, u in ipairs(list) do
    if u.block and (u.tag == "EXT" or u.tag == "EXTI") then
      local t = {}
      for k = 2, #u.lines - 1 do
        local key, v = trim(u.lines[k]):match("^(%S+)%s*(.*)$")
        if key then t[key] = v end
      end
      return t
    end
  end
  return {}
end
-- A track unit -> its record { guid, oid, kids, local_ }.
local function track_rec(u)
  local kids = inner(u)
  local ext = ext_of(kids)
  return { guid = trim(u.lines[1]):match("^<TRACK%s+(%b{})"), oid = ext.band_oid and ext.band_oid:upper() or nil, kids = kids,
    local_ = (ext.band_local or "") ~= "" or (ext.band_live_track or "") ~= "" }
end
-- (by its lines, not its units: a big MIDI item is thousands of lines, each looked at once)
local function item_oid(u)
  local d, ext = 0, false
  for k = 2, #u.lines - 1 do
    local s = trim(u.lines[k])
    if d == 0 and (s == "<EXT" or s == "<EXTI") then ext = true
    elseif ext and d == 1 then local o = s:match("^band_oid%s+(%S+)"); if o then return o:upper() end end
    if s:sub(1, 1) == "<" then d = d + 1 elseif s == ">" then d = d - 1; if d == 0 then ext = false end end
  end
end
-- An item's state from History as chunk lines: StudioSync's own lines out, media back to this computer's paths (only the studio's media:
-- mirror.only_shared, as mirror.apply does). -> lines, its lane, its picked take, the media files it plays.
local function item_lines(state, media)
  local mirror = require("mirror")
  local lane, pick = tonumber(state:match("BANDLANE (%d+)")), tonumber(state:match("BANDTAKE (%d+)"))
  local tok = mirror.only_shared((state:gsub("BANDLANE %d+\n?", ""):gsub("BANDTAKE %d+\n?", "")))
  local L = split(mirror.resolve_media(tok, media))
  return L, lane, pick, mirror.media_needed(tok, media)
end
-- A Lua literal of a plain value (strings %q, numbers as numbers, tables of those). Pure.
local function lit(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) == "number" then return v == v and v ~= math.huge and v ~= -math.huge and string.format("%.17g", v) or "0" end
  if type(v) == "boolean" then return tostring(v) end
  if type(v) ~= "table" then return "nil" end
  local out, n = {}, #v
  for i = 1, n do out[#out + 1] = lit(v[i]) end
  local keys = {}
  for k in pairs(v) do if type(k) == "string" then keys[#keys + 1] = k end end
  table.sort(keys)
  for _, k in ipairs(keys) do out[#out + 1] = "[" .. string.format("%q", k) .. "]=" .. lit(v[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end
histhear.lit = lit

-- The saved copy's text rebuilt to a moment. plan: mirror.plan_restore's (oid -> that moment's version, or false: it didn't exist then; an
-- object not in it stays as it is). o: { media = the room's media folder, now = oid -> the version id held here (an object already at that
-- version is left as it is, its state never read), exists(path), guid() -> a new "{...}", moves = histhear.moves_since's list (tracks moved
-- since go back), map_of(ev) -> the timeline entry a version was made under (histhear.map_of) }.
-- -> the text, and { tracks = track oid -> a track's settings then (prep sets them), items = oid -> { lane, pick, track }, missing = media not here,
-- len = the song's length in seconds, skipped = parts that couldn't go in (a receive from a track not there), n = objects changed,
-- placed = item oid -> the timeline entry it was made under (false: before any History keeps) for each item put in from History,
-- master = { env, fxen } the master's automation then (when it changed), moved = tracks put back where they sat,
-- ai = track oid ("MASTER" for the master) -> its automation items then as BANDAI lines (prep rebuilds them), envplaced = the same keys ->
-- the timeline entry the automation put in was made under (false: before any History keeps) }. Pure.
-- A version's automation items: its BANDAI and BANDAIPT lines (mirror.ai_lines' form), or nil.
local function ai_lines(state)
  local out = {}
  for l in tostring(state):gmatch("[^\n]+") do if l:find("^BANDAI") then out[#out + 1] = l end end
  return #out > 0 and table.concat(out, "\n") or nil
end
function histhear.rebuild(text, plan, o)
  o = o or {}
  local mirror = require("mirror")
  local now, media = o.now or {}, o.media or ""
  local L = split(text)
  local root = units(L, 2, #L - 1)
  local info = { tracks = {}, items = {}, missing = {}, len = 0, skipped = 0, n = 0, locals = 0, placed = {}, ai = {}, envplaced = {} }
  -- the tracks, in order; every receive tied to its source's record (renumbered once tracks come and go)
  local orig = {}
  for _, u in ipairs(root) do
    if u.tag == "TRACK" and u.block then orig[#orig + 1] = track_rec(u) end
  end
  for _, r in ipairs(orig) do
    local src
    for _, u in ipairs(r.kids) do
      if u.tag == "AUXRECV" then
        local idx = tonumber(trim(u.lines[1]):match("^AUXRECV%s+(%d+)"))
        src = idx and orig[idx + 1] or false
        u.src = src
      elseif u.block and u.tag:sub(1, 3) == "AUX" and u.tag:find("ENV") then u.of = src
      else src = nil end
    end
  end
  local list, by_oid = {}, {}
  for _, r in ipairs(orig) do
    if r.local_ then info.locals = info.locals + 1 -- (this computer's own tracks (click, talkback, kept as yours): not the band's song)
    else list[#list + 1] = r; if r.oid then by_oid[r.oid] = r end end
  end
  local function same(oid, ev) return ev and ev.id ~= nil and now[oid] == ev.id end
  local oids = {}
  for oid in pairs(plan) do oids[#oids + 1] = oid end
  table.sort(oids)
  -- tracks gone then go; tracks there then and not now come back, under the track they sat under (or first, as mirror.apply puts them)
  local new = {}
  for _, oid in ipairs(oids) do
    local ev = plan[oid]
    if oid:sub(1, 1) == "T" and oid ~= mirror.MASTER then
      local r = by_oid[oid]
      if ev == false then
        if r then for i, x in ipairs(list) do if x == r then table.remove(list, i); break end end; by_oid[oid] = nil; info.n = info.n + 1 end
      elseif ev and not (r and same(oid, ev)) then
        local st = type(ev.state) == "table" and ev.state or {}
        if not r then
          r = { guid = (o.guid and o.guid() or "{00000000-0000-0000-0000-000000000000}"):upper(), oid = oid, after = tostring(st.after or "") }
          -- (TRACKID: without it REAPER gives the track a new GUID as it loads, whatever its first line says. Desktop, 0.59.49.73)
          r.kids = { { tag = "NAME", lines = { "NAME \"\"" } }, { tag = "TRACKID", lines = { "TRACKID " .. r.guid } },
            block("<EXT", { { tag = "band_oid", lines = { "band_oid " .. oid } } }) }
          by_oid[oid] = r
          new[#new + 1] = r
        end
        info.tracks[oid] = st
        info.n = info.n + 1
      end
    end
  end
  repeat -- (those whose track above is placed first, so a run of tracks comes back in its order)
    local placed = false
    for k = #new, 1, -1 do
      local r = new[k]
      local at = r.after == "" and 0 or nil
      if not at then for i, x in ipairs(list) do if x.oid == r.after then at = i end end end
      if at then table.insert(list, at + 1, r); table.remove(new, k); placed = true end
    end
  until not placed
  for _, r in ipairs(new) do table.insert(list, 1, r) end -- (the track it sat under is gone: first, as mirror.apply)
  -- tracks moved since go back, the newest move first: each under the track it sat under before that move (its change says so, `moved`:
  -- histhear.moves_since). A track that's only been changed otherwise stays where it sits, as mirror.revert has it. rt-history2
  for _, m in ipairs(o.moves or {}) do
    local r = by_oid[m.oid]
    local cur, at
    for i, x in ipairs(list) do if x == r then cur = i end end
    if m.from == "" then at = 0 else for i, x in ipairs(list) do if x.oid == m.from and x ~= r then at = i end end end
    if cur and at then
      table.remove(list, cur)
      table.insert(list, at < cur and at + 1 or at, r)
      info.moved = (info.moved or 0) + 1
    end
  end
  -- receives renumbered to the tracks as they are now; one from a track not there goes, with its envelopes
  local index = {}
  for i, r in ipairs(list) do index[r] = i - 1 end
  for _, r in ipairs(list) do
    local kids, drop = {}, nil
    for _, u in ipairs(r.kids) do
      if u.tag == "AUXRECV" and u.src ~= nil then
        drop = not (u.src and index[u.src])
        if not drop then u.lines = { (u.lines[1]:gsub("^(%s*AUXRECV%s+)%d+", "%1" .. index[u.src], 1)) } end
      elseif not (u.of ~= nil and u.block and u.tag:sub(1, 3) == "AUX") then drop = nil end
      if not (drop and (u.tag == "AUXRECV" or u.of ~= nil)) then kids[#kids + 1] = u end
    end
    r.kids = kids
  end
  local function oid_at(i) return list[i + 1] and list[i + 1].oid or nil end
  local function index_of(x) local r = by_oid[x]; return r and index[r] or nil end
  local function track_of(ev, oid) return by_oid[(ev and ev.track) or ("T" .. oid:sub(2))] end
  -- a track's parts: plug-ins, automation, sends, groups
  for _, oid in ipairs(oids) do
    local ev, k = plan[oid], oid:sub(1, 1)
    local kind = mirror.KIND[k]
    if (kind == "fx" or kind == "env" or kind == "recv" or kind == "misc") and not same(oid, ev) then
      local trk = (ev and ev.track) or ("T" .. oid:sub(2))
      local state = ev and type(ev.state) == "string" and ev.state or ""
      if trk == mirror.MASTER then
        if kind == "fx" then -- (the master's chain is the project's <MASTERFXLIST>)
          local at
          for i, u in ipairs(root) do if u.tag == "MASTERFXLIST" then at = i end end
          if at then table.remove(root, at) end
          if state ~= "" then
            local L2 = split(state)
            L2[1] = "<MASTERFXLIST"
            if not at then at = #root + 1; for i, u in ipairs(root) do if u.tag == "TRACK" then at = i; break end end end
            table.insert(root, at, { tag = "MASTERFXLIST", lines = L2, block = true })
          end
          info.n = info.n + 1
        elseif kind == "env" then
          -- (the master's automation, E-MASTER, as mirror.apply puts it in: its envelopes in a track chunk's form, with their view lines, which
          -- prep swaps into the master's own chunk in the background REAPER; its FX button, BANDFXEN. Automation items aren't rebuilt.)
          local x = mirror.splice_parts("<TRACK\n>\n", "env", state, function() return nil end, function() return nil end) or ""
          info.master = { env = x:gsub("^<TRACK\n", ""):gsub(">\n$", ""), fxen = state:find("BANDFXEN 0", 1, true) and 0 or 1 }
          info.ai.MASTER = ai_lines(state)
          if o.map_of and ev then info.envplaced.MASTER = o.map_of(ev) or false end
          info.n = info.n + 1
        else info.skipped = info.skipped + 1 end -- (the master has no sends or other parts in History: F-MASTER and E-MASTER only)
      else
        local r = track_of(ev, oid)
        if not r then if ev then info.skipped = info.skipped + 1 end
        elseif kind == "fx" then
          local at
          for i, u in ipairs(r.kids) do if u.tag == "FXCHAIN" then at = i end end
          if at then table.remove(r.kids, at) end
          if state ~= "" then
            if not at then at = #r.kids + 1; for i, u in ipairs(r.kids) do if u.tag == "ITEM" then at = i; break end end end
            table.insert(r.kids, at, { tag = "FXCHAIN", lines = split(state), block = true })
          end
          info.n = info.n + 1
        else
          local chunk = table.concat(flat({ block("<TRACK " .. (r.guid or ""), r.kids) }), "\n")
          local out = mirror.splice_parts(chunk, kind, state, index_of, oid_at)
          if out then
            local L2 = split(out); r.kids = units(L2, 2, #L2 - 1); info.n = info.n + 1
            if kind == "env" then
              info.ai[r.oid] = ai_lines(state)
              if o.map_of and ev then info.envplaced[r.oid] = o.map_of(ev) or false end
            end
          else info.skipped = info.skipped + 1 end
        end
      end
    end
  end
  -- items: each where and as it was, or gone
  local items_at = {} -- item oid -> { { record, unit } } (an oid twice: every copy goes)
  for _, r in ipairs(list) do
    for _, u in ipairs(r.kids) do
      local io = u.tag == "ITEM" and item_oid(u)
      if io then items_at[io] = items_at[io] or {}; table.insert(items_at[io], { r, u }) end
    end
  end
  for _, oid in ipairs(oids) do
    local ev = plan[oid]
    if mirror.KIND[oid:sub(1, 1)] == "item" then
      local here = items_at[oid]
      if not (here and same(oid, ev)) and (ev or here) then
        for _, x in ipairs(here or {}) do
          for i, u in ipairs(x[1].kids) do if u == x[2] then table.remove(x[1].kids, i); break end end
        end
        local r = ev and type(ev.state) == "string" and by_oid[ev.track or ""]
        if r then
          local lines, lane, pick, needs = item_lines(ev.state, media)
          r.kids[#r.kids + 1] = { tag = "ITEM", lines = lines, block = true }
          if lane or pick then info.items[oid] = { lane = lane and lane < mirror.BAD_LANE and lane or nil, pick = pick, track = r.oid } end
          if o.map_of then info.placed[oid] = o.map_of(ev) or false end -- (its seconds are on the tempo map it was made under: histhear.tempo_plan)
          for _, p in ipairs(needs) do if o.exists and not o.exists(p) then info.missing[#info.missing + 1] = p end end
        elseif ev then info.skipped = info.skipped + 1 end
        info.n = info.n + 1
      end
    end
  end
  -- StudioSync's own project state goes (as bgrender.prepare drops it): the copy isn't the band's song
  for i, u in ipairs(root) do
    if u.tag == "EXTSTATE" and u.block then
      local kids = {}
      for _, x in ipairs(inner(u)) do if not (x.tag or ""):upper():find("^BANDSYNC") then kids[#kids + 1] = x end end
      root[i] = block(u.lines[1], kids, u.lines[#u.lines])
    end
  end
  -- the song's length (what the render's limit goes by)
  for _, r in ipairs(list) do
    for _, u in ipairs(r.kids) do
      if u.tag == "ITEM" then
        local pos, len
        for _, l in ipairs(u.lines) do
          local s = trim(l)
          pos = pos or tonumber(s:match("^POSITION%s+(%S+)")); len = len or tonumber(s:match("^LENGTH%s+(%S+)"))
          if pos and len then break end
        end
        info.len = math.max(info.len, (pos or 0) + (len or 0))
      end
    end
  end
  -- out, the tracks where the first one was (or before the project's closing line)
  local out = { L[1] }
  local function tracks_out()
    for _, r in ipairs(list) do flat({ block("<TRACK " .. (r.guid or ""), r.kids) }, out) end
  end
  local put = false
  for _, u in ipairs(root) do
    if u.tag == "TRACK" and u.block then
      if not put then put = true; tracks_out() end
    else flat({ u }, out) end
  end
  if not put then tracks_out() end
  out[#out + 1] = L[#L] or ">"
  return table.concat(out, "\n") .. "\n", info
end

-- The job's prep.lua: what the background REAPER sets through its API once the copy has loaded, before its first render: the render itself
-- (master mix, whole project, Opus with a FLAC beside it for the pass script's size check), each restored track's settings (mirror's own
-- list of them), each item's lane and picked take (counted among its takes that aren't prints, as mirror.pick_take does). Values only ever
-- go in as literals (lit). Tracks and items are found by the band's own id (P_EXT band_oid), which a project keeps through a load: a GUID
-- isn't (a <TRACK {GUID}> with no TRACKID line loads under a new one, so nothing keyed by GUID matched: no names, every lane playing, a
-- preview clipping at 0 dB. Desktop, 0.59.49.73). Which lanes play is set last, once the items are on their lanes. Pure.
-- Then the tempo map then (TL: histhear.tempo_plan), put in the way live sync puts a map in (band.apply_tempo), so REAPER moves what follows
-- the tempo as it does when a map lands: everything held in place (timebase time), then for the copy's own (on today's map) and for each
-- other map items were made under: that map in, those items let go, the map then in (REAPER moves them onto it), held again; at the end every
-- item's own timebase back. Then the markers then, and the master's automation then (ME), swapped into its chunk as mirror.apply does.
local PREP_ENV = [==[
-- (the master's automation then, swapped into its chunk as mirror.apply does, and the automation items then; before the tempo map, which moves them)
if ME then
  local master = reaper.GetMasterTrack(proj)
  local ok, chunk = reaper.GetTrackStateChunk(master, '', false)
  if ok then
    local out, d, drop, put = {}, 0, false, false
    local env = (ME.env or ''):gsub('\n$', '')
    local function put_env() if not put then put = true; if env ~= '' then out[#out + 1] = env end end end
    for line in (chunk:gsub('\r', '') .. '\n'):gmatch('(.-)\n') do
      local s = line:match('^%s*(.-)%s*$')
      if d == 1 and not drop and s:sub(1, 1) == '<' then
        local tag = s:match('^<(%S+)') or ''
        if tag:find('ENV') and tag:sub(1, 3) ~= 'AUX' then drop = true elseif tag == 'FXCHAIN' or tag == 'ITEM' then put_env() end
      end
      if d == 1 and s == '>' and not drop then put_env() end
      if not drop and s ~= '' then out[#out + 1] = line end
      if s:sub(1, 1) == '<' then d = d + 1 elseif s == '>' then d = d - 1; if drop and d == 1 then drop = false end end
    end
    reaper.SetTrackStateChunk(master, table.concat(out, '\n') .. '\n', false)
  end
  reaper.SetMediaTrackInfo_Value(master, 'I_FXEN', ME.fxen or 1)
end
if next(AI or {}) then -- (the automation items then: the envelope part's splice and the chunk left none; mirror.set_ai's rebuild, the track's own envelopes)
  local KEYS = { 'D_POSITION', 'D_LENGTH', 'D_STARTOFFS', 'D_PLAYRATE', 'D_BASELINE', 'D_AMPLITUDE', 'D_LOOPSRC', 'D_MUTE' }
  local ONE, pool = 0x10000000, 0
  local function owner(key)
    if key == 'MASTER' then return reaper.GetMasterTrack(proj) end
    for i = 0, reaper.CountTracks(proj) - 1 do
      local t = reaper.GetTrack(proj, i)
      if ((select(2, reaper.GetSetMediaTrackInfo_String(t, 'P_EXT:band_oid', '', false))) or ''):upper() == key then return t end
    end
  end
  for t = -1, reaper.CountTracks(proj) - 1 do
    local tr = t < 0 and reaper.GetMasterTrack(proj) or reaper.GetTrack(proj, t)
    for e = 0, reaper.CountTrackEnvelopes(tr) - 1 do
      local env = reaper.GetTrackEnvelope(tr, e)
      for a = 0, reaper.CountAutomationItems(env) - 1 do pool = math.max(pool, reaper.GetSetAutomationItemInfo(env, a, 'D_POOL_ID', 0, false) + 1) end
    end
  end
  for key, lines in pairs(AI) do
    local tr, made, count = owner(key), {}, {}
    for line in (tr and lines or ''):gmatch('[^\n]+') do
      local tag, rest = line:match('^BANDAI (%S+) (.*)$')
      if tag then
        local v = {}
        for x in rest:gmatch('%S+') do v[#v + 1] = tonumber(x) end
        local env = tag:sub(1, 8) ~= 'PARMENV:' and tag:sub(1, 4) ~= 'AUX:' and reaper.GetTrackEnvelopeByChunkName(tr, '<' .. tag)
        local k = count[tag] or 0
        count[tag] = k + 1
        if env and v[2] then
          local a = reaper.InsertAutomationItem(env, pool, v[1], v[2])
          pool = pool + 1
          local pass = v[#KEYS + 1] and ONE or 0
          if pass ~= 0 then reaper.GetSetAutomationItemInfo(env, a, 'D_POOL_QNLEN', v[#KEYS + 1], true) end
          for i = 3, #KEYS do if v[i] then reaper.GetSetAutomationItemInfo(env, a, KEYS[i], v[i], true) end end
          for _ = 1, reaper.CountEnvelopePointsEx(env, a | ONE) do reaper.DeleteEnvelopePointEx(env, a | ONE, 0) end
          made[tag .. ' ' .. k] = { env, a | pass }
        end
      else
        local ptag, k, t, val, shape, ten = line:match('^BANDAIPT (%S+) (%d+) (%S+) (%S+) (%S+) (%S+)$')
        local m = ptag and made[ptag .. ' ' .. k]
        if m then reaper.InsertEnvelopePointEx(m[1], m[2], tonumber(t), tonumber(val), tonumber(shape), tonumber(ten), false, true) end
      end
    end
    for _, m in pairs(made) do reaper.Envelope_SortPointsEx(m[1], m[2]) end
  end
end]==]
local PREP_TIME = [==[
local function tempo(map)
  for i = reaper.CountTempoTimeSigMarkers(proj) - 1, 0, -1 do reaper.DeleteTempoTimeSigMarker(proj, i) end
  for _, m in ipairs(map) do reaper.SetTempoTimeSigMarker(proj, -1, m.time, -1, -1, m.bpm, m.num, m.denom, m.linear == true) end
  reaper.UpdateTimeline()
end
local function track_of(key)
  if key == 'MASTER' then return reaper.GetMasterTrack(proj) end
  for i = 0, reaper.CountTracks(proj) - 1 do
    local t = reaper.GetTrack(proj, i)
    if ((select(2, reaper.GetSetMediaTrackInfo_String(t, 'P_EXT:band_oid', '', false))) or ''):upper() == key then return t end
  end
end
if TL.tempo then
  -- automation put in from History, made under another map: its points and items by the beats they had there (read now, on the copy's map)
  local EV = {}
  for key, k in pairs(TL.envs or {}) do
    local tr = track_of(key)
    for e = 0, (tr and reaper.CountTrackEnvelopes(tr) or 0) - 1 do
      local env = reaper.GetTrackEnvelope(tr, e)
      local x = { env = env, pts = {}, ai = {}, k = k }
      for p = 0, reaper.CountEnvelopePoints(env) - 1 do x.pts[p + 1] = select(2, reaper.GetEnvelopePoint(env, p)) end
      for a = 0, reaper.CountAutomationItems(env) - 1 do
        x.ai[a + 1] = { reaper.GetSetAutomationItemInfo(env, a, 'D_POSITION', 0, false), reaper.GetSetAutomationItemInfo(env, a, 'D_LENGTH', 0, false) }
      end
      EV[#EV + 1] = x
    end
  end
  local all = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local _, oid = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:band_oid', '', false)
    all[#all + 1] = { it = it, mode = reaper.GetMediaItemInfo_Value(it, 'C_BEATATTACHMODE'), g = (TL.groups or {})[(oid or ''):upper()] or 0 }
    reaper.SetMediaItemInfo_Value(it, 'C_BEATATTACHMODE', 0)
  end
  for k = 0, #(TL.maps or {}) do
    if k > 0 then
      tempo(TL.maps[k])
      for _, x in ipairs(EV) do
        if x.k == k then
          x.qp, x.qa = {}, {}
          for i, t in ipairs(x.pts) do x.qp[i] = reaper.TimeMap2_timeToQN(proj, t) end
          for i, v in ipairs(x.ai) do x.qa[i] = { reaper.TimeMap2_timeToQN(proj, v[1]), reaper.TimeMap2_timeToQN(proj, v[1] + v[2]) } end
        end
      end
    end
    for _, x in ipairs(all) do if x.g == k then reaper.SetMediaItemInfo_Value(x.it, 'C_BEATATTACHMODE', x.mode) end end
    tempo(TL.tempo)
    for _, x in ipairs(all) do if x.g == k then reaper.SetMediaItemInfo_Value(x.it, 'C_BEATATTACHMODE', 0) end end
  end
  for _, x in ipairs(all) do reaper.SetMediaItemInfo_Value(x.it, 'C_BEATATTACHMODE', x.mode) end
  -- (the map then is in for good: each envelope's points and items go where their beats are on it)
  for _, x in ipairs(EV) do
    if x.qp then
      for i, q in ipairs(x.qp) do reaper.SetEnvelopePoint(x.env, i - 1, reaper.TimeMap2_QNToTime(proj, q), nil, nil, nil, nil, true) end
      reaper.Envelope_SortPoints(x.env)
      for i, q in ipairs(x.qa) do
        local from = reaper.TimeMap2_QNToTime(proj, q[1])
        reaper.GetSetAutomationItemInfo(x.env, i - 1, 'D_POSITION', from, true)
        reaper.GetSetAutomationItemInfo(x.env, i - 1, 'D_LENGTH', reaper.TimeMap2_QNToTime(proj, q[2]) - from, true)
      end
    end
  end
end
if TL.markers then
  for i = reaper.CountProjectMarkers(proj) - 1, 0, -1 do reaper.DeleteProjectMarkerByIndex(proj, i) end
  for _, m in ipairs(TL.markers) do
    local pos = tonumber(m.pos) or 0
    reaper.AddProjectMarker2(proj, m.region == true, pos, tonumber(m['end']) or pos, tostring(m.name or ''), math.tointeger(tonumber(m.num)) or -1, 0)
  end
end
]==]
function histhear.prep(info)
  local mirror = require("mirror")
  local tracks = {}
  local in_use = {} -- (a track never has fewer lanes than its items sit on: mirror.set_track_state's rule)
  for _, x in pairs(info.items or {}) do if x.lane and x.track then in_use[x.track] = math.max(in_use[x.track] or 0, x.lane + 1) end end
  for toid, t in pairs(info.tracks or {}) do
    local num = {}
    local function put(k, v) v = tonumber(v); if v then num[#num + 1] = { k, v } end end
    local lanes = tonumber(t.lanes)
    put("I_FREEMODE", (in_use[toid] or 0) > 1 and 2 or t.freemode)
    if lanes or in_use[toid] then put("I_NUMFIXEDLANES", math.max(lanes or 0, in_use[toid] or 0)) end
    put("B_MUTE", t.mute); put("B_PHASE", t.phase); put("I_FOLDERDEPTH", t.depth); put("D_VOL", t.vol); put("D_PAN", t.pan)
    for _, list in ipairs({ mirror.TRACK_MORE, mirror.TRACK_MIX }) do for _, kp in ipairs(list) do put(kp[2], t[kp[1]]) end end
    local plays = {}
    for v in (tostring(t.plays or "") .. ","):gmatch("([^,]*),") do plays[#plays + 1] = tonumber(v) or false end
    if t.plays == nil or t.plays == "" then plays = {} end
    tracks[toid] = { name = tostring(t.name or ""), num = num, plays = plays }
  end
  local items = {}
  for oid, x in pairs(info.items or {}) do items[oid] = { lane = x.lane, pick = x.pick } end
  local render = { { "RENDER_FORMAT", band.OPUS }, { "RENDER_FORMAT2", band.FLAC }, { "RENDER_SETTINGS", 0 }, { "RENDER_BOUNDSFLAG", 1 },
    { "RENDER_PATTERN", "preview" }, { "RENDER_ADDTOPROJ", 0 }, { "RENDER_CHANNELS", 2 }, { "RENDER_SRATE", 48000 }, { "RENDER_NORMALIZE", 0 },
    { "RENDER_TAILFLAG", 0 } }
  return table.concat({
    "-- StudioSync's song as it was (written by lib/histhear.lua; run by the background REAPER's pass script before its first render)",
    "local proj = ...",
    "local R, T, I = " .. lit(render) .. ", " .. lit(tracks) .. ", " .. lit(items),
    "for _, kv in ipairs(R) do",
    "  if type(kv[2]) == 'string' then reaper.GetSetProjectInfo_String(proj, kv[1], kv[2], true) else reaper.GetSetProjectInfo(proj, kv[1], kv[2], true) end",
    "end",
    "local function settings(tr) return T[(select(2, reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:band_oid', '', false)) or ''):upper()] end",
    "for i = 0, reaper.CountTracks(proj) - 1 do",
    "  local tr = reaper.GetTrack(proj, i)",
    "  local t = settings(tr)",
    "  if t then",
    "    reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', t.name, true)",
    "    for _, kv in ipairs(t.num) do reaper.SetMediaTrackInfo_Value(tr, kv[1], kv[2]) end",
    "  end",
    "end",
    "for i = 0, reaper.CountMediaItems(proj) - 1 do",
    "  local it = reaper.GetMediaItem(proj, i)",
    "  local _, oid = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:band_oid', '', false)",
    "  local x = I[(oid or ''):upper()]",
    "  if x then",
    "    if x.lane then reaper.SetMediaItemInfo_Value(it, 'I_FIXEDLANE', x.lane) end",
    "    if x.pick then",
    "      local real = {}",
    "      for k = 0, reaper.CountTakes(it) - 1 do",
    "        local tk = reaper.GetTake(it, k)",
    "        if not (tk and select(2, reaper.GetSetMediaItemTakeInfo_String(tk, 'P_EXT:band_m_print', '', false)) ~= '') then real[#real + 1] = k end",
    "      end",
    "      if real[x.pick + 1] then reaper.SetMediaItemInfo_Value(it, 'I_CURTAKE', real[x.pick + 1]) end",
    "    end",
    "  end",
    "end",
    "for i = 0, reaper.CountTracks(proj) - 1 do",
    "  local tr = reaper.GetTrack(proj, i)",
    "  local t = settings(tr)",
    "  if t then for l, v in ipairs(t.plays) do if v then reaper.SetMediaTrackInfo_Value(tr, 'C_LANEPLAYS:' .. (l - 1), v) end end end",
    "end",
    "local TL, ME, AI = " .. lit(info.tl or {}) .. ", " .. lit(info.master or false) .. ", " .. lit(info.ai or {}),
    PREP_ENV,
    PREP_TIME,
    "reaper.UpdateTimeline()",
    "" }, "\n")
end

-- ---- pure: which point, what a restore changes ------------------------------------------------------------------------------------------
-- The last History entry at or before t (UTC seconds), 0 for none. entries: recall.entries' (sorted by time).
function histhear.upto(entries, t)
  local epoch, n = require("webhistory").epoch, 0
  for i, e in ipairs(entries) do
    local x = epoch(e.time)
    if x and x <= t then n = i elseif x and x > t then break end
  end
  return n
end
-- ---- pure: the tempo map, markers and track order then (rt-history2) ---------------------------------------------------------------------
-- A timeline change's place among the others: the order sync.post gave it (after the newest map seen where it was made), which is what the
-- studio goes by (sync.newest_map, sync.studio_timeline), not its file time. Older ones have none: their time and id.
local function tl_order(e) return tostring(e.order or ((e.time or "") .. (e.id or ""))) end
local function is_tl(e) return e.kind == "timeline" and type(e.tempo) == "table" and #e.tempo > 0 end
-- The tempo map and markers as they stood at entries[upto]: of the timeline changes at or before it, the one the studio put in place last
-- (the highest order: one from a computer whose clock ran ahead sorts later by time but wasn't the map then). None by then: o.first (the map
-- the song began with, histhear.first_map), else, when History holds no timeline change at all, today's stands then too ({ how = "today" }).
-- -> { tempo, markers, how = "then" | "first" | "today", ev }, or nil when the map then isn't known (changes since, none kept before). Pure.
function histhear.timeline_at(entries, upto, o)
  o = o or {}
  local best, any
  for i, e in ipairs(entries) do
    if is_tl(e) then
      any = true
      if i <= upto and (not best or tl_order(e) > tl_order(best)) then best = e end
    end
  end
  if best then return { tempo = best.tempo, markers = type(best.markers) == "table" and best.markers or {}, how = "then", ev = best } end
  if type(o.first) == "table" and type(o.first.tempo) == "table" then return { tempo = o.first.tempo, markers = type(o.first.markers) == "table" and o.first.markers or {}, how = "first" } end
  if not any then return { how = "today" } end
  return nil
end
-- The map the song began with, where one was kept: a side room's room.json (the map it was made from), else session.json's first_timeline
-- (kept while someone on an older build read the timeline there). Not session.json's own tempo: since the timeline went into one file per
-- computer (0ae5fbf) it's no longer kept up to date, so it can be any map since, not the first.
function histhear.first_map(cfg, b, session)
  local meta = band.read_json(require("sync").room_dir(cfg, b.song, b.room) .. "/room.json")
  if type(meta) == "table" and meta.parent then return type(meta.tempo) == "table" and meta or nil end
  return type(session) == "table" and type(session.first_timeline) == "table" and session.first_timeline or nil
end
-- -> fn(ev): the timeline change an object's version was made under (its seconds are on that map), or nil before any. A change sent while
-- REAPER may still be moving things for a new map names it (`tl`, mirror.map_stamp); others were made under the newest one before them. Pure.
function histhear.map_of(entries)
  local tls = {}
  for _, e in ipairs(entries) do if is_tl(e) then tls[#tls + 1] = e end end
  return function(ev)
    local best, mine = nil, (ev.time or "") .. (ev.id or "")
    for _, t in ipairs(tls) do
      local ok
      if type(ev.tl) == "string" then ok = tl_order(t) <= ev.tl else ok = (t.time or "") .. (t.id or "") < mine end
      if ok and (not best or tl_order(t) > tl_order(best)) then best = t end
    end
    return best
  end
end
-- Tracks moved since entries[upto], newest first: { oid, from = the track it sat under before that move ("" the top) }. A move's change says
-- where it sat (`moved`, since rt-edits; a restore's and an undo's say where they took it from), so putting each back in turn, newest first,
-- is the order then. Moves from before rt-edits carry none and aren't taken back. Pure.
function histhear.moves_since(entries, upto)
  local out = {}
  for i = #entries, upto + 1, -1 do
    local e = entries[i]
    if e.kind == "obj" and e.obj == "track" and type(e.oid) == "string" and type(e.moved) == "string" then out[#out + 1] = { oid = e.oid:upper(), from = e.moved:upper() } end
  end
  return out
end
-- What prep does with the tempo map, from the map then (timeline_at), today's (`now`, the copy's own) and the map each item put in from
-- History was made under (rebuild's `placed`). Seconds are only right on their own map: an item made under another is moved onto the map
-- then the way REAPER moves it when a map lands (by its timebase), and so is everything already in the copy, from today's.
-- -> nil (nothing to change), or { tempo = the map then or nil (as it is), markers, maps = the other maps, groups = item oid -> its map's
-- place in maps }. Pure.
function histhear.tempo_plan(placed, tl, now, envplaced)
  if not (tl and tl.tempo) then return nil end
  local nowk, maps, idx, groups = lit(now or {}), {}, {}, {}
  local oids = {}
  for oid in pairs(placed or {}) do oids[#oids + 1] = oid end
  table.sort(oids)
  local function group(e, into, key)
    local m = e and e.tempo or tl.tempo -- (made before any change History keeps: on the map then, its seconds kept)
    local k = lit(m)
    if k ~= nowk then
      if not idx[k] then maps[#maps + 1] = m; idx[k] = #maps end
      into[key] = idx[k]
    end
  end
  for _, oid in ipairs(oids) do group(placed[oid], groups, oid) end
  -- (automation put in from History is on the map it was made under too: its points and items are moved onto the map then, by their beats)
  local envs, keys = {}, {}
  for key in pairs(envplaced or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do group(envplaced[key], envs, key) end
  return { tempo = (lit(tl.tempo) ~= nowk or #maps > 0) and tl.tempo or nil, markers = tl.markers or {}, maps = maps, groups = groups, envs = envs }
end
-- A plan as the song really stood then. mirror.plan_restore gives each object its own newest version at the point, but deleting a track
-- sends no change for what was on it: an item whose version then sits on a track that was gone then went with that track, so it wasn't
-- there (false, not that version), and that track's parts go with it (left out). Likewise what sits on a track that's neither here
-- (here(oid) -> bool) nor coming back can't land, and is left out. Without this the words said "brings back 2 tracks and 14 items" where
-- the preview, and a restore, had 2 (12 on tracks deleted before the point: Cross Test, desktop, 0.59.49.73). The preview, the words and
-- the restore all go by this one plan. Pure.
function histhear.settle(plan, here)
  local mirror, out = require("mirror"), {}
  for oid, ev in pairs(plan) do
    local item = mirror.KIND[oid:sub(1, 1)] == "item"
    local trk = ev and oid:sub(1, 1) ~= "T" and (ev.track or (not item and ("T" .. oid:sub(2)))) or nil -- (a part's track is in its own id)
    if trk and trk ~= mirror.MASTER and plan[trk] == false then
      if item then out[oid] = false end
    elseif trk and trk ~= mirror.MASTER and plan[trk] == nil and here and not here(trk) then -- (left out)
    else out[oid] = ev end
  end
  return out
end
-- History's "these tracks" scope (as mirror.selection_scope, from track oids): the tracks, their parts and everything on them, then or now.
function histhear.scope(oids)
  local set = {}
  for _, oid in ipairs(oids) do for _, p in ipairs({ "T", "F", "E", "R", "M" }) do set[p .. oid:sub(2)] = true end end
  return function(oid, last, at) return set[oid] or (last and set[last.track or ""]) or (at and set[at.track or ""]) or false end
end
-- What a restore would change, in words. plan: as above; held(oid) -> what's here now: (hash, version id), hash "" or nil when it isn't here;
-- name_of(oid) -> a track's name. -> words, how many objects change. Pure.
function histhear.describe(plan, held, name_of)
  local back, gone, changed, names, seen, n = { track = 0, item = 0 }, { track = 0, item = 0 }, 0, {}, {}, 0
  local mirror = require("mirror")
  for oid, ev in pairs(plan) do
    local h, id = held(oid)
    local here = (h or "") ~= ""
    local kind = mirror.KIND[oid:sub(1, 1)] or "item"
    local what = (ev == false and here and "gone") or (ev and not here and "back") or (ev and here and id ~= ev.id and "changed") or nil
    if what then
      n = n + 1
      local tally = what == "back" and back or gone
      if what == "changed" or kind ~= "track" and kind ~= "item" then changed = changed + 1 -- (a part brought back or emptied is a change to its track)
      else tally[kind] = tally[kind] + 1 end
      local trk = kind == "track" and oid or (ev and ev.track) or ("T" .. oid:sub(2))
      local nm = name_of(trk)
      if nm and nm ~= "" and not seen[nm] then seen[nm] = true; names[#names + 1] = nm end
    end
  end
  if n == 0 then return "Nothing would change: it's already like that.", 0 end
  local function count(c, one, many) return c == 1 and ("1 " .. one) or (c .. " " .. many) end
  local parts = {}
  local function both(t, verb)
    local x = {}
    if t.track > 0 then x[#x + 1] = count(t.track, "track", "tracks") end
    if t.item > 0 then x[#x + 1] = count(t.item, "item", "items") end
    if #x > 0 then parts[#parts + 1] = verb .. " " .. table.concat(x, " and ") end
  end
  both(back, "brings back")
  both(gone, "takes away")
  if changed > 0 then parts[#parts + 1] = "changes " .. count(changed, "thing", "things") .. " (settings, plug-ins, automation, sends, items)" end
  table.sort(names)
  local more = #names - histhear.NAMES_MAX
  while #names > histhear.NAMES_MAX do names[#names] = nil end
  local words = parts[1]:sub(1, 1):upper() .. table.concat(parts, "; "):sub(2)
  if #names > 0 then words = words .. ". Tracks: " .. table.concat(names, ", ") .. (more > 0 and (" and " .. more .. " more") or "") end
  return words .. ". Today's version stays in History, and Undo takes this back.", n
end
-- A whole-song restore's words with the tempo map and markers: tl as timeline_at gives it, now = sync.timeline_sig decoded ({ tempo, markers,
-- ... }). -> words, how many things change. Pure.
function histhear.tempo_words(words, n, tl, now)
  local differs = tl and tl.tempo and not (type(now) == "table" and band.json_encode({ tl.tempo, tl.markers or {} }) == band.json_encode({ now[1], now[2] or {} }))
  local say = differs and "It puts the tempo map and markers back as they were too."
    or not tl and "The tempo map and markers then aren't kept in History: today's stay." or nil
  if not say then return words, n end
  if differs and n == 0 then return "Puts the tempo map and markers back as they were. Today's version stays in History, and Undo takes this back.", 1 end
  return words .. " " .. say, n + (differs and 1 or 0)
end
-- A preview's file id for the web server: 32 lower-case hex from a key. Pure.
function histhear.file_id(key)
  local fnv = require("mirror").fnv
  return fnv("a" .. key) .. fnv("b" .. key) .. fnv("c" .. key) .. fnv("d" .. key)
end

-- ---- Live sync's side (through lib/webhistory.lua, from lib/webui.lua's tick) -----------------------------------------------------------
local S = { slots = {}, last_start = -math.huge, offered = {} }
histhear.S = S -- (tests)
local function bg() return require("bgrender") end
local function cache_dir(cfg, b) return (bg().TMP:gsub("/bandsync%-render$", "")) .. "/bandsync-hear/" .. require("mirror").fnv(tostring(cfg.root) .. "|" .. b.song .. "|" .. b.room) end
histhear.SWEEP_EVERY, histhear.SWEEP_FOR, histhear.SWEEP_WAIT = 2, 60, 30
local function tidy(dir)
  if not dir then return end
  local empty_dir = bg().empty_dir -- (the folders too: on Windows os.remove left every job's empty folders behind)
  if empty_dir then return empty_dir(dir) end
  local function empty(d)
    local names = {}
    for i = 0, 199 do local f = reaper.EnumerateFiles(d, i); if not f then break end; names[#names + 1] = f end
    for _, f in ipairs(names) do os.remove(d .. "/" .. f) end
    os.remove(d)
  end
  for _, sub in ipairs(band.subdirs(dir)) do empty(dir .. "/" .. sub) end
  empty(dir)
end
-- A job folder done with (rendered, failed, cancelled, replaced): emptied now and again every SWEEP_EVERY s for SWEEP_FOR s. Its REAPER
-- is ended by a script that takes a moment, and meanwhile it saves its job.rpp again, finishes a pass, and its launcher writes done.txt
-- when it has gone: one tidy left those behind for hours (desktop, 0.59.49.73). A job cancelled before its process id was written is ended
-- once it is (its folder kept till then: the id is in it), or it rendered on to its end, unseen. Each start has a folder of its own, so a
-- job being ended never writes into the next one's.
S.trash = {}
-- (once its launcher says it has gone, nothing is ended: its process id may be something else's by now)
local function end_it(dir) return reaper.file_exists(dir .. "/done.txt") or bg().end_job(dir) == true end
local function drop(dir)
  if not dir then return end
  local t = S.trash[dir] or { at = reaper.time_precise() }
  S.trash[dir] = t
  t.ended = t.ended or end_it(dir)
  if t.ended or (band.read(dir .. "/pid.txt") or ""):match("^failed") then tidy(dir) end
end
local function sweep(now)
  if now - (S.swept or -math.huge) < histhear.SWEEP_EVERY then return end
  S.swept = now
  for dir, t in pairs(S.trash) do
    t.ended = t.ended or end_it(dir)
    -- (no process id yet: its folder waits for it, unless it never started or has gone by itself)
    if t.ended or now - t.at > histhear.SWEEP_WAIT or (band.read(dir .. "/pid.txt") or ""):match("^failed") then tidy(dir) end
    if now - t.at > histhear.SWEEP_FOR then S.trash[dir] = nil end
  end
end
-- the previews kept, newest last (index.json beside them); the oldest past KEEP go
local function keep(dir, id)
  local idx = band.read_json(dir .. "/index.json") or {}
  local list = {}
  for _, x in ipairs(idx) do if x ~= id and type(x) == "string" and x:match("^%x+$") then list[#list + 1] = x end end
  list[#list + 1] = id
  while #list > histhear.KEEP do os.remove(dir .. "/" .. table.remove(list, 1) .. ".opus") end
  band.write_json(dir .. "/index.json", list)
end
local function offer(slot, id, path)
  local was = S.offered[slot]
  if was and was ~= id and reaper.StudioSync_WebUIOffer then reaper.StudioSync_WebUIOffer(was, "") end
  S.offered[slot] = nil
  if not (id and reaper.StudioSync_WebUIOffer and reaper.StudioSync_WebUIOffer(id, path) == 1) then return nil end
  S.offered[slot] = id
  return id
end
local function cancel(why)
  for _, s in pairs(S.slots) do
    if s.job then drop(s.job.dir); s.job = nil end
    if s.state == "queued" or s.state == "rendering" then s.state, s.why = "cancelled", why end
  end
end
local function track_names(proj)
  local out, mirror, dawview = {}, require("mirror"), require("dawview")
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local oid = mirror.track_oid(tr)
    if oid and oid ~= "" and not mirror.local_track(tr) and dawview.shown(tr) then out[#out + 1] = { oid:upper(), select(2, reaper.GetTrackName(tr)) } end
  end
  return out
end
local function entries_of(cfg, b) return require("recall").entries(cfg, b.song, b.room) end
local function newest_id(entries) local e = entries[#entries]; return e and tostring(e.id) or "none" end
-- Another song or room in front: what was asked for the last one goes.
function histhear.room(b)
  local key = b.song .. "/" .. b.room
  if S.key == key then return end
  if S.key then cancel("the song or room changed") end
  S.slots, S.ask, S.key, S.tracks_at = {}, nil, key, nil
end

-- A page's ask: { hear = { t, now } } (a point to hear, or now for A/B), { cancel = true }, { restore = { t, tracks } } (what would change)
-- or { restore = { id, yes = true } } (do it). -> words for the log, or nil.
function histhear.action(proj, cfg, b, a)
  histhear.room(b)
  if a.cancel == true then cancel("cancelled"); return nil end
  if type(a.hear) == "table" then
    local h = a.hear
    local slot = h.now == true and "now" or "then"
    local t = tonumber(h.t)
    if slot == "then" and not (t and t > 0 and t < 1e11) then return nil end
    local entries = entries_of(cfg, b)
    local key, upto
    if slot == "now" then key = "now|" .. newest_id(entries)
    else
      upto = histhear.upto(entries, t)
      if upto < 1 then S.slots["then"] = { t = t, state = "failed", why = "that's before anything kept in History" }; return nil end
      key = "then|" .. tostring(entries[upto].id)
    end
    local s = S.slots[slot]
    if s and s.key == key and (s.state == "queued" or s.state == "rendering" or s.state == "ready") then return nil end
    if slot == "then" and s and s.job then drop(s.job.dir) end -- (one render at a time: a new point replaces the one going)
    local id = histhear.file_id(cfg.root .. "|" .. b.song .. "|" .. b.room .. "|" .. key .. "|r" .. histhear.RECIPE)
    local path = cache_dir(cfg, b) .. "/" .. id .. ".opus"
    s = { t = t, key = key, upto = upto, id = id, path = path, state = "queued", asked = reaper.time_precise() }
    if reaper.file_exists(path) then s.state, s.file, s.cached = "ready", offer(slot, id, path), true; keep(cache_dir(cfg, b), id) end
    S.slots[slot] = s
    return nil
  end
  if type(a.restore) == "table" then return histhear.restore(proj, cfg, b, a.restore) end
end

-- Is this object in the project now? (mirror's own record of it: a hash, "" once it's gone here)
function histhear.here(proj, oid) local _, h = require("mirror").known(proj, oid); return (h or "") ~= "" end
-- One job: the copy saved, rebuilt, its prep and the hidden REAPER started. -> nil, or why not.
local function start(proj, cfg, b, slot, s)
  local mirror, sync = require("mirror"), require("sync")
  local dir = string.format("%s/hear-%s-%06x", bg().TMP, s.id:sub(1, 12), math.floor(reaper.time_precise() * 1000) % 0x1000000) -- (one a start)
  reaper.RecursiveCreateDirectory(dir, 0)
  local copy = dir .. "/copy.rpp"
  band.save_copy(proj, copy) -- (a copy: the open project isn't renamed, and its "changed" mark is kept)
  local text = band.read(copy)
  os.remove(copy)
  if not text then tidy(dir); return "the project's copy couldn't be saved" end
  local plan, entries, tl = {}, nil, nil
  if slot == "then" then
    entries = entries_of(cfg, b)
    plan = histhear.settle(mirror.plan_restore(entries, s.upto), function(oid) return histhear.here(proj, oid) end)
    tl = histhear.timeline_at(entries, s.upto, { first = histhear.first_map(cfg, b, band.read_json(band.session_path(cfg, b.song))) })
  end
  local now = {}
  for oid in pairs(plan) do local _, _, ev = mirror.known(proj, oid); now[oid] = ev end
  local out, info = histhear.rebuild(text, plan, { media = sync.room_dir(cfg, b.song, b.room) .. "/media", now = now, exists = reaper.file_exists,
    guid = function() return reaper.genGuid("") end, moves = entries and histhear.moves_since(entries, s.upto), map_of = entries and histhear.map_of(entries) })
  info.tl = histhear.tempo_plan(info.placed, tl, band.capture_tempo(proj), info.envplaced) -- (today's map: what the copy was saved with)
  s.tempo = tl and tl.how or "unknown"
  band.write_atomic(dir .. "/job.rpp", out)
  band.write_atomic(dir .. "/prep.lua", histhear.prep(info))
  band.write_atomic(dir .. "/maxpasses.txt", tostring(histhear.PASSES))
  local limit = bg().time_limit(math.max(info.len, 1) * histhear.PASSES, 1)
  bg().launch_job(dir, math.min(limit + 180, 32767))
  s.job = { dir = dir, started = reaper.time_precise(), limit = limit }
  s.state, s.missing, s.len, s.passes = "rendering", #info.missing, info.len, histhear.PASSES
  S.last_start = reaper.time_precise()
end
-- A job's progress: "done", "failed" and why, or nil while it runs (and which pass it's on).
local function poll(s)
  local d = s.job.dir
  if reaper.file_exists(d .. "/passes.txt") then
    for _, f in ipairs(band.files(d)) do if f:lower():match("%.opus$") then return "done", d .. "/" .. f end end
    return "failed", "the background REAPER rendered nothing"
  end
  if (band.read(d .. "/pid.txt") or ""):match("^failed") then return "failed", "the background REAPER didn't start" end
  if reaper.file_exists(d .. "/done.txt") then return "failed", "the background REAPER quit without rendering (a plug-in may have stopped it)" end
  if reaper.time_precise() - s.job.started > s.job.limit then return "failed", "it took too long (a plug-in may be waiting on a window nobody can see)" end
  local pass = 0
  for _, sub in ipairs(band.subdirs(d)) do local n = tonumber(sub:match("^pass(%d+)$")); if n and n > pass then pass = n end end
  s.pass = pass
end

-- Each tick while a page shows anything (lib/webhistory.lua calls it first, looking at History or not, so a render goes on).
function histhear.tick(proj, cfg, b, publish, now)
  histhear.room(b)
  local looking = require("webhistory").looking(now)
  sweep(now)
  if not looking and not next(S.slots) and not S.ask then return end -- (nothing asked, nobody on History: nothing read, nothing sent)
  local busy
  for _, slot in ipairs({ "then", "now" }) do
    local s = S.slots[slot]
    if s and s.job then
      local st, x = poll(s)
      if st == "done" then
        local dir = cache_dir(cfg, b)
        reaper.RecursiveCreateDirectory(dir, 0)
        local ok = os.rename(x, s.path) or (pcall(band.copy_atomic, x, s.path) and reaper.file_exists(s.path))
        drop(s.job.dir) -- (and its REAPER ended: a question stopping it from quitting mustn't keep it on, unseen)
        s.job = nil
        if ok then keep(dir, s.id); s.state, s.file = "ready", offer(slot, s.id, s.path) else s.state, s.why = "failed", "the preview couldn't be kept" end
      elseif st == "failed" then drop(s.job.dir); s.job, s.state, s.why = nil, "failed", x
      else busy = true end
    end
  end
  if not busy and now - S.last_start >= histhear.START_GAP then -- (one at a time: "then" first, then "now")
    for _, slot in ipairs({ "then", "now" }) do
      local s = S.slots[slot]
      if s and s.state == "queued" and not s.job then
        if reaper.GetPlayStateEx(proj) & 4 == 4 then s.why = "waiting for the recording to stop"
        else
          s.why = nil
          local ok, why = pcall(start, proj, cfg, b, slot, s)
          if not ok or why then s.state, s.why = "failed", tostring(why or "it couldn't start"); band.log("History's preview couldn't start: " .. s.why) end
        end
        break
      end
    end
  end
  if S.ask and now > S.ask.until_ then S.ask = nil end
  if looking and (not S.tracks_at or now - S.tracks_at >= histhear.TRACKS_EVERY) then
    S.tracks_at, S.tracks = now, track_names(proj)
    local _, who = require("sync").authority(cfg, b.song, b.room, band.read_json(band.session_path(cfg, b.song)))
    S.driver = who and who.driver == cfg.user or nil -- (whole-song restores: the driver's, as on the panel)
  end
  local model = { tracks = S.tracks, ask = S.ask and { id = S.ask.id, words = S.ask.words, n = S.ask.n, t = S.ask.t, whole = S.ask.whole } or nil,
    said = S.said, driver = S.driver }
  for _, slot in ipairs({ "then", "now" }) do
    local s = S.slots[slot]
    if s then
      model[slot] = { t = s.t, state = s.state, why = s.why, file = s.state == "ready" and s.file or nil, cached = s.cached, missing = s.missing,
        pass = s.pass, passes = s.passes, secs = s.job and math.floor(now - s.job.started) or nil, len = s.len and math.floor(s.len + 0.5) or nil, tempo = s.tempo }
    end
  end
  publish("hhear", model)
end

-- A restore from the page: first what would change (an ask with its id, shown in the page's confirm), then, with that id and yes, done.
-- -> words for the log, or nil.
function histhear.restore(proj, cfg, b, r)
  local sync, mirror = require("sync"), require("mirror")
  local session = band.read_json(band.session_path(cfg, b.song))
  local can, who = sync.authority(cfg, b.song, b.room, session)
  S.driver = who and who.driver == cfg.user or nil
  local tracks
  if r.tracks ~= nil then
    if type(r.tracks) ~= "table" or #r.tracks == 0 or #r.tracks > histhear.TRACKS_MAX then S.said = "Pick the tracks to put back first."; return nil end
    tracks = {}
    for _, x in ipairs(r.tracks) do
      if type(x) ~= "string" or not x:match("^T%-[%w%-_]+$") or #x > 120 then S.said = "That track list didn't make sense."; return nil end
      tracks[#tracks + 1] = x:upper()
    end
  end
  if r.yes == true then
    local p = S.ask
    if not (p and type(r.id) == "string" and r.id == p.id and reaper.time_precise() <= p.until_) then S.said = "That restore's check ran out: press Restore again."; return nil end
    S.ask = nil
    if not p.tracks and not S.driver then S.said = "Only the driver can restore the whole song: ask them, or take control."; return nil end
    local entries = entries_of(cfg, b)
    local upto = histhear.upto(entries, p.t)
    if upto < 1 then S.said = "That point is before anything kept in History."; return nil end
    local plan = histhear.settle(mirror.plan_restore(entries, upto, p.tracks and histhear.scope(p.tracks) or nil), function(oid) return histhear.here(proj, oid) end)
    local act = string.format("%s-%s-r%d", sync.id_user and sync.id_user(cfg.user) or cfg.user, os.date("!%Y%m%d%H%M%S"), math.floor(reaper.time_precise() * 1000) % 1000000)
    local opts = { can = can, mode = who and who.mode, driver = who and who.driver, is_claimed = who and who.is_claimed, at_once = true, act = act,
      local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" }
    -- (each item's version onto its beat on the map in place: one made under an older map than the point's sat at its old seconds. rt-edits round 6)
    local map_of, first = histhear.map_of(entries), histhear.first_map(cfg, b, session)
    opts.map_of = function(ev) local t = map_of(ev) or first; return t and t.tempo end
    if not p.tracks then -- (the map then, as the preview has it: histhear.timeline_at; unknown or never changed: left as it is)
      local tl = histhear.timeline_at(entries, upto, { first = histhear.first_map(cfg, b, session) })
      -- (under the Restore's act, so "Undo this change" on one of its rows takes the map back: lib/page_restore.lua. James, 2026-11-21)
      if tl and tl.how == "then" then sync.restore_timeline(proj, cfg, b.song, b.room, { tl.ev }, 1, session, nil, act)
      elseif tl and tl.how == "first" then sync.restore_timeline(proj, cfg, b.song, b.room, {}, 0, { first_timeline = tl }, nil, act) end
    end
    local said = mirror.revert(proj, cfg, b.song, b.room, plan, opts)
    S.said = "Restored to " .. os.date("%a %H:%M", p.t) .. ": " .. tostring(said)
    return "History page: " .. S.said
  end
  local t = tonumber(r.t)
  if not (t and t > 0 and t < 1e11) then return nil end
  if not tracks and not S.driver then S.said = "Only the driver can restore the whole song: ask them, or take control. You can restore chosen tracks."; return nil end
  local entries = entries_of(cfg, b)
  local upto = histhear.upto(entries, t)
  if upto < 1 then S.said = "That point is before anything kept in History, so it can't be rebuilt from it."; return nil end
  local plan = histhear.settle(mirror.plan_restore(entries, upto, tracks and histhear.scope(tracks) or nil), function(oid) return histhear.here(proj, oid) end)
  local names = {}
  for _, e in ipairs(entries) do if e.kind == "obj" and e.obj == "track" and e.oid and (e.name or "") ~= "" then names[e.oid:upper()] = e.name end end
  for _, x in ipairs(S.tracks or {}) do names[x[1]] = x[2] end
  local words, n = histhear.describe(plan, function(oid) local _, h, ev = mirror.known(proj, oid); return h, ev end, function(oid) return names[oid:upper()] end)
  if not tracks then words, n = histhear.tempo_words(words, n, histhear.timeline_at(entries, upto, { first = histhear.first_map(cfg, b, band.read_json(band.session_path(cfg, b.song))) }),
    sync.timeline_sig and band.json_decode(sync.timeline_sig(proj))) end
  S.ask = { id = band.secret(16), words = words, n = n, t = t, tracks = tracks, whole = not tracks or nil, until_ = reaper.time_precise() + histhear.ASK_FOR }
  S.said = nil
  return nil
end

return histhear
