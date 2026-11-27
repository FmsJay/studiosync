-- Other scripts and extensions beside StudioSync (James, rt: "make sure reapersona and other scripts won't mess with functionality of
-- studiosync + a way to see if it does for other scripts that might not play nice"). docs/rt/rt-compat.md has the audit behind this.
-- Three parts:
--  1. A self-check, at Live sync's start and on demand (Health's Check again, the web Health page's button): StudioSync's own hooks still
--     work (Live sync's loop gets its turns, Autostart runs, its start is in Scripts/__startup.lua and nothing above it can stop it, the
--     extension is the one wanted and alone, port 47281 is StudioSync's, its ExtState reads back, change detection sees a scratch edit),
--     and the scripts that start with REAPER (and, on demand, every script in the Actions list) looked through for what's known to clash.
--  2. Guards: StudioSync's start put back when something rewrote Scripts/__startup.lua without it; REAPER's "open projects on startup" kept
--     while a reopen plan is kept; the project grid kept this computer's own while a script changes it as you zoom (FTC's Adaptive grid
--     on James's PC sent the grid to the studio at every zoom); a ReaPersona persona switch never changes a studio song's own settings.
--  3. "Something else changed what StudioSync just wrote": a bandmate's change that lands and is changed again here within seconds, and a
--     thing that keeps going out with no undo point between, named by REAPER's undo history where it names one (else: when).
-- Each Live sync is its own Lua state: what it sees goes into ExtState ("compat <tab>", "compat check") for the panel's and the web's Health.
-- GPL-3.0-or-later.
local band = require("band")
local compat = {
  WINDOW = 5,          -- seconds after a bandmate's change lands in which a change here to the same thing counts as "changed what StudioSync wrote"
  REPEAT = 3,          -- times one named action does that (in KEEP) before Health shows it (a person editing the same thing is rare, a script does it every time)
  NOUNDO = 2,          -- times something with no undo point does it before Health shows it
  RESTLESS = 4,        -- sends of one thing in RESTLESS_SECS with no undo point between them (5 sends) before Health shows it
  RESTLESS_SECS = 60,
  GRID_N = 5,          -- grid-only changes in GRID_SECS that make the grid this computer's own for the session (a script changing it as you zoom)
  GRID_SECS = 60,
  PERSONA_SECS = 5,    -- a ReaPersona persona switch this recent owns a change to a song's settings (Live sync looks every 2 s)
  KEEP = 600,          -- seconds an event stays on Health
  SLOW_MS = 250,       -- median time between Live sync's looks spent elsewhere, past which REAPER is held by something
  CHECK_EVERY = 600,   -- seconds between self-checks (and one 15 s after Live sync starts)
  FILES_PER_PASS = 25, -- scripts read per Live sync pass during a check
  MAX_SCRIPT = 512 * 1024,
  OURS = "StudioSync: changes from the others", -- sync.receive's undo point
  PORT_FIRST = 47281, PORT_LAST = 47297,
}
-- Undo points StudioSync makes without its name in front (lib/colours.lua): its own, not another script's.
compat.OWN = { ["Colour tracks"] = true, ["Colour regions"] = true, ["Colour items"] = true, ["Colours put back"] = true }
-- The extensions StudioSync uses: two loadable copies of one in UserPlugins and REAPER loads one of them, perhaps the older.
compat.FAMILIES = { "reaper_studiosync", "reaper_imgui", "reaper_js_reascriptapi", "reaper_sws", "reaper_reablink" }

local function now() return reaper.time_precise() end
local function top_of(proj) return reaper.Undo_CanUndo2 and reaper.Undo_CanUndo2(proj) or "" end
local function enc(t) return band.json_encode(t) end
local function scripts_dir() return (debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\][^/\\]+$")) end

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
-- A change here to something a bandmate's change just put in. rec: { at, undo } as it landed (undo: the top of REAPER's undo list then,
-- before StudioSync's own point closed); t: now; top: the top of the list now. -> nil (not that), or { by = the action's name, or false:
-- no undo point since, so a script, an extension or a plug-in with none of its own }. StudioSync's own follow-ups and an undo of its point
-- (the person's Ctrl+Z) don't count.
function compat.after_land(rec, t, top, window)
  if type(rec) ~= "table" or t - rec.at > (window or compat.WINDOW) or t < rec.at then return nil end
  top = top or ""
  if top == compat.OURS then return { by = false } end
  if top == (rec.undo or "") or top == "" or top:find("^StudioSync") or top:find("^BandSync") or compat.OWN[top] then return nil end
  return { by = top }
end
-- Sends of one thing, oldest first ({ at, top }): how many came with no new undo point since the one before. Pure.
function compat.restless(list)
  local n = 0
  for i = 2, #list do if list[i].top == list[i - 1].top then n = n + 1 end end
  return n
end
function compat.median(xs)
  if #xs == 0 then return nil end
  local s = { table.unpack(xs) }
  table.sort(s)
  return s[(#s + 1) // 2]
end
-- What differs between two timeline signatures (sync.timeline_sig: { tempo, markers, project, format }): "timeline" (the tempo map or the
-- markers), "settings" (the project's other settings), "grid" (only the grid's value), "grid presence" (only whether the grid is in it: the
-- grid turned this computer's own, or back), or nil (nothing, or one doesn't read). Pure.
function compat.timeline_diff(seen, sig)
  local a, b = band.json_decode(seen or ""), band.json_decode(sig or "")
  if type(a) ~= "table" or type(b) ~= "table" then return nil end
  if enc({ a[1] or {}, a[2] or {} }) ~= enc({ b[1] or {}, b[2] or {} }) then return "timeline" end
  local pa, pb = type(a[3]) == "table" and a[3] or {}, type(b[3]) == "table" and b[3] or {}
  local ga, gb = type(pa.settings) == "table" and pa.settings.grid, type(pb.settings) == "table" and pb.settings.grid
  local function without_grid(p)
    local c = band.json_decode(enc(p)) or {}
    if type(c.settings) == "table" then c.settings.grid = nil end
    return enc(c)
  end
  if without_grid(pa) ~= without_grid(pb) then return "settings" end
  if (ga == nil) ~= (gb == nil) then return "grid presence" end
  if enc(ga or {}) ~= enc(gb or {}) then return "grid" end
  return nil
end
-- Who listens on `port`, from `netstat -ano -p TCP` (Windows) or `lsof -nP -iTCP:<port> -sTCP:LISTEN` (Mac, Linux). -> the process id
-- (Windows) or the program's name, or nil. Pure.
function compat.port_owner(text, port, win)
  for line in (text or ""):gmatch("[^\r\n]+") do
    if win then
      local p, pid = line:match("TCP%s+%S-:(%d+)%s+%S+%s+LISTENING%s+(%d+)")
      if tonumber(p) == port then return tonumber(pid) end
    else -- (lsof was asked for this port's listener: its first line after the header names it)
      local cmd = line:match("^(%S+)%s+%d+%s")
      if cmd and cmd ~= "COMMAND" and line:find(":" .. port .. "%f[%D]") then return cmd end
    end
  end
  return nil
end
-- tasklist /FO CSV /NH's first column. Pure.
function compat.task_name(text) return (text or ""):match('"([^"]+)"') end
-- Lines of Scripts/__startup.lua above StudioSync's block that can stop the file there (a dofile or require outside a pcall, a top-level
-- return other than the render guard's): StudioSync's start, which comes after, then never runs. -> { { n, line } }. Pure.
function compat.startup_risks(before)
  local out, n = {}, 0
  for line in ((before or "") .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    local s = line:gsub("\r$", ""):match("^%s*(.-)%s*$")
    if s ~= "" and not s:find("^%-%-") and not s:find("pcall", 1, true)
        and (s:find("dofile%s*[%(\"'%[]") or s:find("^require%s*[%(\"']") or s:find("[=%s]require%s*[%(\"']") or line:find("^return%f[%W]")) then
      out[#out + 1] = { n, s }
    end
  end
  return out
end
-- Scripts/__startup.lua with StudioSync's block first (after the render guard, which must stay first). split: tools.split_startup.
-- -> the new text, or nil (no block, or it's first already). Pure.
function compat.block_first(text, split)
  local before, after = split(text)
  if not before or not after then return nil end
  local block = text:sub(#before + 1, #text - #after)
  local guard, rest = before:match("^(%-%- BandSync render guard.-%-%- /BandSync render guard\r?\n)(.*)$")
  guard, rest = guard or "", guard and rest or before
  if rest:match("^%s*$") then return nil end
  return guard .. block .. "\n" .. rest .. (after:gsub("^\r?\n", "", 1))
end
-- The scripts Scripts/__startup.lua starts (by command id, through reaper-kb.ini, or a dofile of a path written out), and `ids` (SWS's
-- startup action). -> { { name, path } } (path relative to Scripts unless it's whole), StudioSync's own left out. Pure.
function compat.kb_paths(kb)
  local by = {}
  for line in (kb or ""):gmatch("[^\r\n]+") do
    local sec, id, desc, path = line:match('^SCR %d+ (%d+) (RS[%w_]+) "([^"]*)" (.+)$')
    if id then by[id] = by[id] or { name = desc:gsub("^Custom: ", ""), path = path:match('^"(.*)"$') or path, section = sec } end
  end
  return by
end
local function ours(path) return tostring(path):lower():find("studiosync", 1, true) ~= nil end
function compat.autostarted(startup_text, kb, ids)
  local by, out, seen = compat.kb_paths(kb), {}, {}
  local function add(name, path)
    if path and not ours(path) and not seen[path:lower()] then seen[path:lower()] = true; out[#out + 1] = { name = name, path = path } end
  end
  local text = startup_text or ""
  for id in text:gmatch("[\"']_?(RS[%w_]+)[\"']") do local x = by[id]; if x then add(x.name, x.path) end end
  for _, id in ipairs(ids or {}) do local x = by[(tostring(id):gsub("^_", ""))]; if x then add(x.name, x.path) end end
  for p in text:gmatch("dofile%s*%(?%s*[\"']([^\"']+%.lua)[\"']") do add(p:match("[^/\\]+$"), p) end
  return out
end
-- What a script's text does that's known to clash with StudioSync. background: it runs in a defer loop (or starts with REAPER), so it
-- keeps doing it. -> { kind = { why, fix } }. Pure.
compat.KINDS = {
  extstate = { "writes StudioSync's own settings (its BandSync ExtState)", "Ask its author to use its own ExtState section; until then don't run it while a studio song is open." },
  pext = { "writes StudioSync's ids on tracks or items (P_EXT:band_...)", "Don't run it on a studio song: a changed id makes the studio see a new track or item and lose the old one's history." },
  grid = { "changes the project grid as it runs", "A studio song shares its grid, so StudioSync keeps the grid this computer's own while this runs: snapping here follows your grid, the others keep theirs." },
  tempo = { "changes the tempo map as it runs", "In a studio song a tempo change goes to everyone (driver) or is put back: turn it off while a studio song is open." },
  uirefresh = { "stops REAPER's screen redrawing (PreventUIRefresh(1) with no matching -1 in the script)", "A script that stops between the two leaves the tracks frozen on screen while StudioSync still syncs behind it: ask its author to wrap the work in pcall so the -1 always runs. If tracks stop redrawing, restart REAPER (nothing can read the count)." },
  colour = { "recolours tracks as it runs", "Track colours are shared in a studio song: each recolour goes to everyone. Turn it off for studio songs, or let StudioSync colour them (Settings > Colours)." },
}
function compat.scan_text(text, background)
  local found = {}
  text = text or ""
  -- (every line's comment cut off first; a count that can't balance is the only sign REAPER lets a script leave: the refresh count itself can't be read)
  local plus, minus = 0, 0
  for line in text:gmatch("[^\r\n]+") do
    local code = line:gsub("%-%-.*$", "")
    for _ in code:gmatch("PreventUIRefresh%s*%(%s*1%s*%)") do plus = plus + 1 end
    for _ in code:gmatch("PreventUIRefresh%s*%(%s*%-1%s*%)") do minus = minus + 1 end
  end
  if plus > minus then found.uirefresh = true end
  background = background or text:find("reaper%.defer%s*%(") ~= nil
  for line in text:gmatch("[^\r\n]+") do
    if not line:find("^%s*%-%-") then
      if line:find("BandSync", 1, true) and (line:find("Set%a*ExtState%s*%(") or line:find("Delete%a*ExtState%s*%(")) then found.extstate = true end
      if line:find("P_EXT:band_", 1, true) and line:find("P_EXT:band_[^\"']*[\"']%s*,[^,]*,%s*true") then found.pext = true end
      if background then
        if line:find("GetSetProjectGrid%s*%([^,]*,%s*[1t]") or line:find("[%.:]SetProjectGrid%s*%(") then found.grid = true end
        if line:find("SetCurrentBPM%s*%(") or line:find("SetTempoTimeSigMarker%s*%(") or line:find("AddTempoTimeSigMarker%s*%(") then found.tempo = true end
        if line:find("SetMediaTrackInfo_Value%s*%([^,]+,%s*[\"']I_CUSTOMCOLOR") or line:find("SetTrackColor%s*%(") then found.colour = true end
      end
    end
  end
  local out = {}
  for k in pairs(found) do out[k] = compat.KINDS[k] end
  return out
end
-- File names in UserPlugins -> { { family, files } } for each extension StudioSync uses that has more than one loadable copy. Pure.
function compat.dll_dupes(names)
  local by, out = {}, {}
  for _, n in ipairs(names or {}) do
    local l = n:lower()
    if l:find("%.dll$") or l:find("%.dylib$") or l:find("%.so$") then
      local fam = l:match("^(reaper_[%a_]+)")
      if fam then by[fam] = by[fam] or {}; table.insert(by[fam], n) end
    end
  end
  for _, f in ipairs(compat.FAMILIES) do if by[f] and #by[f] > 1 then table.sort(by[f]); out[#out + 1] = { family = f, files = by[f] } end end
  return out
end

-- ---- the grid: this computer's own while something changes it as you zoom -----------------------------------------------------------------
-- band.capture_settings and band.apply_settings leave the grid out while this says why (nil: it's shared as ever). FTC's Adaptive grid says
-- it runs in its own ExtState; anything else is latched for the session when it's seen (compat.timeline_veto, a scanned startup script).
function compat.grid_local()
  if reaper.GetExtState("FTC.AdaptiveGrid", "is_service_running") == "yes" and (tonumber(reaper.GetExtState("FTC.AdaptiveGrid", "main_mult")) or 0) ~= 0 then
    return "FTC's Adaptive grid"
  end
  local why = reaper.GetExtState(band.SECTION, "compat grid local")
  return why ~= "" and why or nil
end
local function latch_grid(why)
  if reaper.GetExtState(band.SECTION, "compat grid local") ~= "" then return end
  reaper.SetExtState(band.SECTION, "compat grid local", why, false) -- (this REAPER session: a restart looks again)
  band.log("the grid is this computer's own from now on, while " .. why .. " runs: it changes the grid as you zoom, and each change went to the studio")
end

-- ---- what changed what StudioSync just wrote (Live sync's state) ------------------------------------------------------------------------
local landed, sends, said, events = {}, {}, {}, {}
local grid_at, persona = {}, { style = nil, at = -math.huge, name = nil }
local function note(proj, kind, name, by)
  local t = os.time()
  events[#events + 1] = { t = t, k = kind, name = name, by = by or nil, p = tostring(proj) }
  while #events > 40 do table.remove(events, 1) end
  local k = kind .. "\0" .. tostring(name) .. "\0" .. tostring(by)
  if (said[k] or -math.huge) < now() - 60 then
    said[k] = now()
    if kind == "by" then band.log(string.format("'%s' changed %s right after a bandmate's change landed: it went out as yours", by, name))
    elseif kind == "noundo" then band.log(string.format("something with no undo point (a script, an extension or a plug-in) changed %s right after a bandmate's change landed: it went out as yours", name))
    elseif kind == "restless" then band.log(string.format("%s keeps changing with no undo point between: it went out to everyone %d times in a minute", name, compat.RESTLESS + 1)) end
  end
end
compat.events = events -- (tests)
-- sync.receive: a bandmate's change to `oid` (or "timeline") landed here.
function compat.landed(proj, oid)
  landed[tostring(proj) .. tostring(oid)] = { at = now(), undo = top_of(proj) }
end
local function fx_window_open(tr)
  if not tr or not reaper.ValidatePtr2(0, tr, "MediaTrack*") then return false end
  if reaper.TrackFX_GetChainVisible(tr) ~= -1 then return true end
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do if reaper.TrackFX_GetFloatingWindow(tr, i) then return true end end
  return false
end
-- mirror.watch (W.send): a change here to `oid` goes out. auto: a print StudioSync refreshed (its own). ptr: the track, for a plug-in chain
-- (one with a window open is someone turning its knobs, not restless).
function compat.sent(proj, oid, name, kind, ptr, auto)
  if auto then return end
  local k, t, top = tostring(proj) .. tostring(oid), now(), top_of(proj)
  local a = compat.after_land(landed[k], t, top)
  landed[k] = nil
  name = (name or "") ~= "" and name or "a track"
  if a then note(proj, a.by and "by" or "noundo", name, a.by or nil) end
  local list = sends[k] or {}
  sends[k] = list
  list[#list + 1] = { at = t, top = top }
  while #list > 0 and t - list[1].at > compat.RESTLESS_SECS do table.remove(list, 1) end
  if compat.restless(list) >= compat.RESTLESS and not (kind == "fx" and fx_window_open(ptr)) and (said["r" .. k] or -math.huge) < t - compat.KEEP then
    said["r" .. k] = t
    note(proj, "restless", name)
  end
end
local function poll_persona()
  local s = reaper.GetExtState("ReaPersona", "style")
  if persona.style ~= nil and s ~= persona.style then persona.at, persona.name = now(), s end
  persona.style = s
  -- (ReaPersona (next release) stamps the time it started and finished a switch, so a switch to the persona already in use, and one whose changes land
  -- a few passes later, are caught as well)
  local sw = tonumber(reaper.GetExtState("ReaPersona", "switching"))
  if sw and sw <= now() and now() - sw < compat.PERSONA_SECS and (persona.at or -math.huge) < sw then persona.at, persona.name = sw, s end
end
compat.persona = persona -- (tests)
-- sync.watch_timeline, before it sends or puts back a change to the tempo map, markers or project settings. -> nil (go on as ever),
-- "quiet" (not a change: the grid turned this computer's own, or a grid-adapting script was just caught), or words: put the studio's back
-- with them (a ReaPersona persona switch changed the song's own settings).
function compat.timeline_veto(proj, seen, sig)
  local d = compat.timeline_diff(seen, sig)
  if d == "grid presence" then return "quiet" end
  poll_persona()
  if (d == "settings" or d == "grid") and now() - persona.at < compat.PERSONA_SECS then
    note(proj, "persona", "the song's " .. (d == "grid" and "grid" or "settings"), persona.name)
    return "Not sent: switching ReaPersona's persona changed this studio song's own settings (snap, auto-crossfade, grid): the studio's are back. " ..
      "A persona doesn't change a shared song."
  end
  if d == "grid" then
    local t = now()
    grid_at[#grid_at + 1] = t
    while #grid_at > 0 and t - grid_at[1] > compat.GRID_SECS do table.remove(grid_at, 1) end
    if #grid_at >= compat.GRID_N then
      latch_grid("a script that changes the grid as you zoom")
      note(proj, "grid", "the grid")
      return "quiet"
    end
  end
  if d then compat.sent(proj, "timeline", d == "timeline" and "the tempo map or markers" or "the project settings", "timeline") end
  return nil
end

-- ---- the self-check -------------------------------------------------------------------------------------------------------------------
local stats = { last_t0 = nil, last_took = 0, gaps = {}, at = -math.huge, born = nil }
local check = { co = nil, at = -math.huge, due = nil }
local function read_file(path, max)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read(max or compat.MAX_SCRIPT)
  f:close()
  return s
end
local function whole(path)
  local p = tostring(path):gsub("\\", "/")
  if p:find("^%a:/") or p:find("^/") then return p end
  return (reaper.GetResourcePath():gsub("\\", "/")) .. "/Scripts/" .. p
end
local function listing(dir)
  local out = {}
  reaper.EnumerateFiles(dir, -1)
  for i = 0, 4096 do local f = reaper.EnumerateFiles(dir, i); if not f then break end out[#out + 1] = f end
  return out
end
compat.listing = listing
local function startup_path() return reaper.GetResourcePath() .. "/Scripts/__startup.lua" end
local function hhmm(t) return os.date("%H:%M:%S", t) end
local function mtime(path)
  if not reaper.JS_File_Stat then return nil end
  local ok, _, _, m = reaper.JS_File_Stat(path)
  return ok == 0 and m or nil
end

-- Change detection on a scratch track state, nothing in the project touched: an edit changes the hash, the same state hashes the same.
-- colour: true, so it doesn't ask SWS (whether SWS colours tracks here is no part of this). m: lib/mirror.lua. -> true when it works.
function compat.scratch_detect(m)
  return pcall(function()
    local h1, h2 = m.track_hash({ name = "StudioSync scratch", vol = 1, pan = 0 }, false, true), m.track_hash({ name = "StudioSync scratch", vol = 0.5, pan = 0 }, false, true)
    assert(h1 ~= h2 and h1 == m.track_hash({ name = "StudioSync scratch", vol = 1, pan = 0 }, false, true))
  end) == true
end
-- The port in direct.status's `bind` ("100.x.y.z:47281"), or `fallback` (the extension gives the address alone). Pure.
function compat.bind_port(bind, fallback) return tostring(bind or ""):match(":(%d+)$") or tostring(fallback or compat.PORT_FIRST) end

-- The self-check's items, each { id, ok, level ("red", "yellow", "grey"), text, act = "move" | "check" }, and the scripts that clash
-- ({ name, path, kinds = { why, fix } }), published as ExtState "compat check" for Health. full: every script in the Actions list too.
-- Each part runs on its own (guard): one that raises (an odd value from REAPER or an extension) is a grey item and a line in the log file,
-- never the whole check failing, and grey isn't counted as needing a look. (0.59.49.63 on the desktop: direct.status's bind had no port)
local function run_check(proj, cfg, b, dir, full)
  local items, clash = {}, {}
  local function item(id, ok, level, text, act) items[#items + 1] = { id = id, ok = ok and true or nil, level = level, text = tostring(text or ""), act = act } end
  local function guard(id, fn)
    local ok, err = pcall(fn)
    if not ok then
      band.log_error("compat check " .. id, err)
      item(id, false, "grey", "The " .. id .. " check couldn't run here: " .. (tostring(err):match("^[^\n]*") or ""))
    end
  end
  local tools = require("tools")
  local text = band.read(startup_path()) or ""
  guard("loop", function() -- Live sync's loop: what's spent elsewhere between its looks
    local med = compat.median(stats.gaps)
    if not med then return end
    item("loop", med < compat.SLOW_MS, "yellow", med < compat.SLOW_MS and string.format("Live sync gets its turn about every %d ms", math.floor(med + 0.5)) or
      string.format("Something holds REAPER: Live sync waits about %d ms between its looks (it should be under %d). A script with a long loop, a busy plug-in window or a " ..
        "slow screen redraw does that; changes then go out and come in late. Stop other scripts that run in the background one at a time to find it.", math.floor(med + 0.5), compat.SLOW_MS))
  end)
  guard("startup", function() -- its start with REAPER: there, put back when something rewrote the file without it
    if tools.autostart_on() then return item("startup", true, "red", "StudioSync starts with REAPER (Scripts/__startup.lua)") end
    local when = mtime(startup_path())
    pcall(tools.set_autostart, true, dir) -- (always on, as the panel has it: "StudioSync projects start Live sync with REAPER")
    local ok = tools.autostart_on()
    item("startup", ok, "red", ok and ("StudioSync's start was put back in Scripts/__startup.lua at " .. hhmm(os.time()) .. ": something rewrote the file without it" ..
        (when and (" (last written " .. tostring(when) .. ")") or "") .. ". If a script keeps removing it, it's in the list below.")
      or "StudioSync isn't in Scripts/__startup.lua and couldn't be put back: Live sync won't start with REAPER. Check the file can be written.")
    if ok then band.log("StudioSync's start was missing from Scripts/__startup.lua (something rewrote it): put back"); text = band.read(startup_path()) or "" end
  end)
  guard("startup order", function() -- nothing above it that can stop the file
    local before = tools.split_startup(text)
    local risks = before and compat.startup_risks(before) or {}
    if #risks == 0 then return end
    item("startup order", false, "yellow", string.format("Line %d of Scripts/__startup.lua (%s) comes before StudioSync's start and can stop the file there: if it fails, StudioSync " ..
      "never starts with REAPER. Move StudioSync's start to the top.", risks[1][1], tostring(risks[1][2]):sub(1, 60)), "move")
  end)
  guard("autostart", function() -- Autostart's loop (it beats every 2 s: StudioSync - Autostart.lua)
    local beat = tonumber(reaper.GetExtState(band.SECTION, "autostart beat"))
    if not (tools.autostart_on() and stats.born and now() - stats.born > 60) then return end
    local up = beat ~= nil and now() - beat < 20
    item("autostart", up, "yellow", up and "StudioSync's Autostart is running" or "StudioSync's Autostart isn't running in this REAPER, so updates, and Live sync starting again by " ..
      "itself after a restart, wait until REAPER restarts. Restart REAPER; if it stops again, the Console says why.")
  end)
  local okd, direct = pcall(require, "direct")
  guard("extension", function() -- the one wanted (the red "menu ext" row says what's wrong; here only that it's alone)
    local ext_ok = okd and direct.ext_problem() == nil
    item("extension", ext_ok, "grey", ext_ok and ("StudioSync's extension " .. tostring(reaper.GetExtState(band.SECTION, "menu extension")) .. " is loaded") or "StudioSync's extension isn't the one wanted (its row says what to do)")
    for _, d in ipairs(compat.dll_dupes(listing(reaper.GetResourcePath() .. "/UserPlugins"))) do
      item("dll " .. d.family, false, d.family == "reaper_studiosync" and "red" or "yellow", string.format("Two copies of the same extension are in REAPER's UserPlugins folder (%s): REAPER " ..
        "loads only one of them, perhaps the older. With REAPER closed, delete the one you don't want.", table.concat(d.files, ", ")))
    end
  end)
  guard("port", function() -- StudioSync's own listener
    if not (okd and direct.available()) then return end
    local s = direct.status(cfg)
    if s.listening then return item("port", true, "yellow", "Port " .. compat.bind_port(s.bind, direct.port()) .. " is StudioSync's (" .. tostring(s.bind) .. ")") end
    if not tostring(s.error or ""):find("can't listen", 1, true) then return end
    local port = tonumber(tostring(s.error):match(":(%d+)")) or tonumber(direct.port()) or compat.PORT_FIRST
    local who
    if band.WIN then
      local pid = compat.port_owner(reaper.ExecProcess("netstat -ano -p TCP", 4000) or "", port, true)
      who = pid and (compat.task_name(reaper.ExecProcess(string.format('tasklist /FI "PID eq %d" /FO CSV /NH', pid), 4000)) or ("process " .. pid))
    else
      who = compat.port_owner(reaper.ExecProcess(string.format("/bin/sh -c \"lsof -nP -iTCP:%d -sTCP:LISTEN\"", port), 4000) or "", port, false)
    end
    item("port", false, "yellow", string.format("Port %d is taken by %s, so the others' changes can't reach this computer directly (Syncthing still carries them). %s",
      port, tostring(who or "another program"), tostring(who or ""):lower():find("reaper") and "Another REAPER has it: close the second REAPER." or "Close that program, or give the studio another port (ExtState \"direct port\")."))
  end)
  guard("extstate", function() -- what StudioSync writes reads back
    local probe = string.format("%d.%d", os.time(), math.random(1, 1e6))
    reaper.SetExtState(band.SECTION, "compat probe", probe, false)
    local back = reaper.GetExtState(band.SECTION, "compat probe")
    reaper.DeleteExtState(band.SECTION, "compat probe", false)
    item("extstate", back == probe, "red", back == probe and "StudioSync's settings read back as written" or "StudioSync's settings don't read back as written (ExtState): something else changes them. The list below says which script writes them.")
  end)
  guard("detect", function()
    local seen_ok = compat.scratch_detect(require("mirror"))
    item("detect", seen_ok, "red", seen_ok and "Change detection sees a scratch edit" or "Change detection didn't see a scratch edit: StudioSync's files may be half updated. Update StudioSync again.")
  end)
  guard("imgui", function() -- ReaImGui for the panel
    if not reaper.ImGui_GetVersion then return end
    local _, _, rv = reaper.ImGui_GetVersion()
    if rv and band.compare_versions(tostring(rv), "0.10") < 0 then item("imgui", false, "yellow", "ReaImGui " .. tostring(rv) .. " is older than the 0.10 StudioSync's panel needs: Extensions > ReaPack > Synchronize packages.") end
  end)
  guard("openmode", function() -- REAPER's "open projects on startup", held while the studio's tabs are planned to reopen (lib/startup.lua)
    local was = require("startup").keep_open_mode()
    if not was then return end
    item("openmode", true, "yellow", "Something set REAPER's 'Open projects on startup' to " .. tostring(was) .. " while StudioSync holds it: StudioSync keeps your choice for after, and opens the studio's songs itself without REAPER's boxes")
    band.log("REAPER's 'Open projects on startup' was changed by something else while StudioSync held it: set again (your choice is kept for when no studio song is open)")
  end)
  guard("promptendrec", function() -- REAPER asking what to do with new files as recording stops (a ReaPersona persona can turn it on): its box pauses every script
    if reaper.SNM_GetIntConfigVar and math.floor(tonumber(reaper.SNM_GetIntConfigVar("promptendrec", 0)) or 0) & 1 == 1 then
      item("promptendrec", false, "yellow", "REAPER asks what to do with the new files each time recording stops, and while that box is up StudioSync waits: your take reaches " ..
        "the others only once you answer. Turn it off in Preferences > Recording (prompt to save/delete/rename new files), or in your ReaPersona persona's preferences.")
    end
  end)
  guard("sws project action", function() -- a project startup action on a studio song runs on every open, and what it changes goes to the studio
    if not (proj and reaper.NF_GetProjectStartupAction and reaper.EnumProjects(-1) == proj) then return end
    local okp, desc, id = reaper.NF_GetProjectStartupAction("", "")
    if okp and tostring(id or "") ~= "" then
      item("sws project action", false, "yellow", "This song has an SWS project startup action (" .. tostring(desc) .. "): it runs each time the song opens here, and whatever it " ..
        "changes goes out to the studio as your change. If it edits the song, clear it: Extensions > SWS > Startup actions.")
    end
  end)
  guard("reablink", function() -- ReaBlink's own Puppet or Master mode, without StudioSync's Link bridge (which says so itself when it's on)
    if not (reaper.APIExists("Blink_GetPuppet") and reaper.GetExtState(band.SECTION, "ablink") ~= "1") then return end
    if reaper.Blink_GetPuppet() == true or (reaper.Blink_GetMaster and reaper.Blink_GetMaster() == true) then
      item("reablink", false, "yellow", "ReaBlink's Puppet or Master mode is on: it changes the tempo and play rate itself, outside the studio's rules. Turn it off in ReaBlink; " ..
        "StudioSync's own Link (Settings > Advanced) keeps Link apps with the studio.")
    end
  end)
  if reaper.GetExtState("ReaPersona", "follow projects") == "1" then
    item("reapersona", true, "grey", "ReaPersona switches persona with the project tab: a persona never changes a studio song's own settings (snap, auto-crossfade, grid), StudioSync puts the studio's back")
  end
  local list = {}
  guard("scripts", function() -- those that start with REAPER, and on demand every script in the Actions list
    local kb = band.read(reaper.GetResourcePath() .. "/reaper-kb.ini") or ""
    local ids = {}
    if reaper.NF_GetGlobalStartupAction then
      local okg, _, gid = reaper.NF_GetGlobalStartupAction("", "")
      if okg and tostring(gid or "") ~= "" then ids[1] = gid end
    end
    list = compat.autostarted(text, kb, ids)
    local auto_n = #list
    if full then
      local seen = {}
      for _, x in ipairs(list) do seen[x.path:lower()] = true end
      for _, x in pairs(compat.kb_paths(kb)) do
        if x.section == "0" and not ours(x.path) and not seen[x.path:lower()] and x.path:lower():find("%.lua$") then seen[x.path:lower()] = true; list[#list + 1] = x end
      end
    end
    for i, x in ipairs(list) do
      local kinds = compat.scan_text(read_file(whole(x.path)), i <= auto_n)
      if next(kinds) then
        if kinds.grid and i <= auto_n then latch_grid(tostring(x.name)) end
        clash[#clash + 1] = { name = tostring(x.name), path = x.path, start = i <= auto_n or nil, kinds = kinds }
        if #clash >= 20 then break end
      end
      if i % compat.FILES_PER_PASS == 0 then coroutine.yield() end -- (Lua 5.4 yields across the pcall)
    end
  end)
  local res = { at = os.time(), full = full or nil, scanned = #list, items = items, clash = clash }
  reaper.SetExtState(band.SECTION, "compat check", enc(res), false)
  return res
end
compat.run_check = run_check -- (tests)

-- Live sync, each pass (t0: when the pass began; took: how long it took): the time spent elsewhere between its looks, the self-check when
-- it's due or asked for (one tab's Live sync runs it: the one in front), and what this tab saw, published for Health every 2 s.
function compat.tick(proj, cfg, b, t0, took)
  local t = now()
  stats.born = stats.born or t
  if stats.last_t0 then
    stats.gaps[#stats.gaps + 1] = math.max(0, (t0 - stats.last_t0 - stats.last_took) * 1000)
    while #stats.gaps > 90 do table.remove(stats.gaps, 1) end
  end
  stats.last_t0, stats.last_took = t0, took or 0
  poll_persona() -- (each pass, so a switch is timed when it happens, not at the next look 2 s later)
  local front = reaper.EnumProjects(-1) == proj
  if front then
    local asked = reaper.GetExtState(band.SECTION, "compat check now")
    if not check.co and (asked ~= "" or (t - stats.born > 15 and t - check.at > compat.CHECK_EVERY)) and t - check.at > 10 then
      reaper.DeleteExtState(band.SECTION, "compat check now", false)
      check.at, check.full = t, asked ~= ""
      local dir = scripts_dir()
      check.co = coroutine.create(function() return run_check(proj, cfg, b, dir, check.full) end)
    end
    if check.co then
      local ok, res = coroutine.resume(check.co)
      if not ok then
        check.co = nil
        band.log_error("compat check", res)
        reaper.SetExtState(band.SECTION, "compat check", enc({ at = os.time(), items = { { id = "check", level = "yellow", text = "The compatibility check failed: " .. tostring(res):match("^[^\n]*") } }, clash = {} }), false)
      elseif coroutine.status(check.co) == "dead" then
        check.co = nil
        if check.full and type(res) == "table" then
          local bad = 0
          for _, x in ipairs(res.items) do if not x.ok then bad = bad + 1 end end
          band.log(string.format("compatibility check: %d of %d of StudioSync's own checks fine, %d script(s) looked through, %d known to clash", #res.items - bad, #res.items, res.scanned, #res.clash))
        end
      end
    end
  end
  if t - stats.at >= 2 then
    stats.at = t
    local cut, mine = os.time() - compat.KEEP, {}
    for _, e in ipairs(events) do if e.t >= cut and e.p == tostring(proj) then mine[#mine + 1] = e end end
    reaper.SetExtState(band.SECTION, "compat " .. tostring(proj), enc({ med = compat.median(stats.gaps), events = mine }), false)
    for k, l in pairs(sends) do if #l == 0 or t - l[#l].at > compat.RESTLESS_SECS then sends[k] = nil end end
    for k, r in pairs(landed) do if t - r.at > compat.WINDOW then landed[k] = nil end end
  end
end

-- ---- Health ---------------------------------------------------------------------------------------------------------------------------
-- Health's rows from what the self-check and this tab's Live sync published (chk, tab: their tables; grid: compat.grid_local()), each
-- { id, ok, colour, text when ok, text when not, action }. acts: { move = fn, check = fn }. Pure but for the actions it's handed.
function compat.rows_from(chk, tab, grid, t, acts)
  local rows, fine, bad = {}, {}, 0
  acts = acts or {}
  local check_btn = acts.check and { "Check again", acts.check, "Looks again now, and through every script in the Actions list too (a few seconds, in the background)." }
  for _, x in ipairs(type(chk) == "table" and chk.items or {}) do
    if x.ok then fine[#fine + 1] = x.id
    elseif x.level ~= "grey" then -- (grey: another row says it)
      bad = bad + 1
      rows[#rows + 1] = { "compat " .. tostring(x.id), false, x.level or "yellow", "", tostring(x.text),
        action = x.act == "move" and acts.move and { "Move StudioSync's start to the top", acts.move, "Rewrites Scripts/__startup.lua with StudioSync's start first (after its render guard); your lines stay as they are, after it." } or nil }
    end
  end
  for _, c in ipairs(type(chk) == "table" and chk.clash or {}) do
    local whys, fixes = {}, {}
    for _, kv in pairs(c.kinds or {}) do whys[#whys + 1] = kv[1]; fixes[#fixes + 1] = kv[2] end
    table.sort(whys); table.sort(fixes)
    local handled = grid and #whys == 1 and c.kinds.grid
    rows[#rows + 1] = { "compat script " .. tostring(c.name), handled and true or false, "yellow",
      tostring(c.name) .. (c.start and " starts with REAPER and " or " ") .. table.concat(whys, "; ") .. ". " .. table.concat(fixes, " "),
      tostring(c.name) .. (c.start and " (starts with REAPER) " or " ") .. table.concat(whys, "; ") .. ". " .. table.concat(fixes, " ") }
  end
  if type(chk) == "table" and chk.at then
    local when = os.date("%H:%M", chk.at)
    rows[#rows + 1] = { "compat", bad == 0, "yellow", string.format("Other scripts and extensions: StudioSync's own %d checks pass (%s), checked %s%s", #fine, table.concat(fine, ", "), when,
      chk.full and string.format(" with %d scripts looked through", chk.scanned or 0) or ""),
      string.format("Other scripts and extensions: %d of StudioSync's own checks need a look (checked %s)", bad, when), action = check_btn }
    if bad == 0 then rows[#rows].action = nil; rows[#rows].ok_action = check_btn end
  end
  if grid then
    rows[#rows + 1] = { "compat grid", true, "grey", "The project grid stays this computer's own while " .. grid .. " runs: it changes the grid as you zoom, " ..
      "which sent it to the studio at every zoom", "" }
  end
  -- what this tab's Live sync saw change what StudioSync had just written
  local by, noundo, last = {}, {}, {}
  for _, e in ipairs(type(tab) == "table" and tab.events or {}) do
    if e.k == "by" then by[e.by] = (by[e.by] or 0) + 1; last[e.by] = e
    elseif e.k == "noundo" then noundo[#noundo + 1] = e
    elseif e.k == "restless" then
      rows[#rows + 1] = { "compat restless " .. tostring(e.name), false, "yellow", "", string.format("%s kept changing by itself (%s): it went out to everyone %d times in a minute with no undo point between. " ..
        "A plug-in that changes its own state, a script or an extension does that. If you were working on it, that was you; if not, take its plug-ins off one at a time to find it.", tostring(e.name), os.date("%H:%M:%S", e.t), compat.RESTLESS + 1) }
    elseif e.k == "persona" then
      rows[#rows + 1] = { "compat persona", false, "yellow", "", string.format("Switching ReaPersona's persona%s (%s) changed this studio song's own settings; StudioSync put the studio's back. " ..
        "So it stays quiet: in ReaPersona, leave snap and auto-crossfade out of your personas, or turn off switching persona with the project for studio songs.",
        e.by and (" to " .. tostring(e.by)) or "", os.date("%H:%M:%S", e.t)) }
    end
  end
  for name, n in pairs(by) do
    if n >= compat.REPEAT then
      local e = last[name]
      rows[#rows + 1] = { "compat by " .. name, false, "yellow", "", string.format("'%s' changed what a bandmate had just changed %d times in the last %d minutes (last: %s, %s), and each went out as your change. " ..
        "If you didn't do that, it's a script or action running by itself: stop it while a studio song is open.", name, n, compat.KEEP // 60, tostring(e.name), os.date("%H:%M:%S", e.t)) }
    end
  end
  if #noundo >= compat.NOUNDO then
    local e = noundo[#noundo]
    rows[#rows + 1] = { "compat noundo", false, "yellow", "", string.format("Something with no undo point changed what a bandmate had just changed %d times in the last %d minutes (last: %s, %s), and each " ..
      "went out as your change. A script, an extension or a plug-in did it (REAPER doesn't say which): Check again lists the scripts that start with REAPER; stop them one at a time to find it.",
      #noundo, compat.KEEP // 60, tostring(e.name), os.date("%H:%M:%S", e.t)) }
  end
  if type(tab) == "table" and tab.med and tab.med >= compat.SLOW_MS and not (type(chk) == "table" and chk.items and (function() for _, x in ipairs(chk.items) do if x.id == "loop" and not x.ok then return true end end end)()) then
    rows[#rows + 1] = { "compat loop", false, "yellow", "", string.format("Something holds REAPER: Live sync waits about %d ms between its looks. A script with a long loop, a busy plug-in window or a slow screen " ..
      "redraw does that; changes then go out and come in late.", math.floor(tab.med + 0.5)) }
  end
  for _, r in ipairs(rows) do r.other = true end -- (the web page's "Show messages about other scripts" switch: findings item 16, rt-ui4)
  return rows
end
-- Rewrites Scripts/__startup.lua with StudioSync's block first. -> true, or nil and why.
function compat.move_block_first()
  local path = startup_path()
  local text = band.read(path)
  if not text then return nil, "couldn't read " .. path end
  local new = compat.block_first(text, require("tools").split_startup)
  if not new then return nil, "StudioSync's start is first already (or isn't there)" end
  if #new < #text - 2 then return nil, "the rewrite came out shorter: left alone" end -- (never lose the person's lines)
  local ok, err = pcall(band.write_atomic, path, new)
  if not ok then return nil, tostring(err) end
  return true
end
-- Health's rows for the panel and the web page (lib/page_health.lua).
function compat.rows(cfg, b, proj)
  local acts = {
    check = function() reaper.SetExtState(band.SECTION, "compat check now", "1", false); band.log("checking other scripts and extensions (Health shows what it finds)") end,
    move = function() local ok, why = compat.move_block_first(); band.log(ok and "StudioSync's start is first in Scripts/__startup.lua now" or ("StudioSync's start wasn't moved: " .. tostring(why)))
      reaper.SetExtState(band.SECTION, "compat check now", "1", false) end,
  }
  return compat.rows_from(band.ext_json(band.SECTION, "compat check"), proj and band.ext_json(band.SECTION, "compat " .. tostring(proj)), compat.grid_local(), os.time(), acts)
end

return compat
