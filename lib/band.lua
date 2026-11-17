-- StudioSync shared library: settings, song folders, session.json, stems and take placement.
-- Pure REAPER API, no extensions required (js_ReaScriptAPI only improves the folder picker).
local json = require("json")
local band = { VERSION = "0.58.93", FORMAT = 1, SECTION = "BandSync", TAKES = "BandSync.takes" }

-- 1 if version a is newer than b, -1 if older, 0 if equal ("0.10.0" > "0.9.1").
function band.compare_versions(a, b)
  local pa, pb = {}, {}
  for n in tostring(a):gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
  for n in tostring(b):gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y and 1 or -1 end
  end
  return 0
end

-- Seconds since an ISO UTC timestamp ("2026-10-27T02:43:22Z"). Both sides are broken-down UTC times
-- run through os.time, which reads them as local time: the offset cancels only if neither applies DST,
-- and os.date("!*t") can carry isdst = true (it did on a UTC-6 laptop in October: every age read +1 h).
function band.age(iso, now)
  local y, m, d, H, M, S = (iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return math.huge end
  local n = now or os.date("!*t") -- copied: os.time normalises (rewrites) the table it is given
  local t = { year = n.year, month = n.month, day = n.day, hour = n.hour, min = n.min, sec = n.sec, isdst = false }
  return os.time(t) - os.time({ year = y, month = m, day = d, hour = H, min = M, sec = S, isdst = false })
end

-- Say once per run when a bandmate's file was made with a newer StudioSync than this one: in the log, and Health shows it. Never a box: one
-- pauses every defer script until someone clicks it (it froze a Live sync for 3 minutes), and came back at every open (Mac, 0.57.6).
local warned = {}
function band.check_version(theirs, what)
  if theirs and band.compare_versions(theirs, band.VERSION) > 0 and not warned[theirs] then
    warned[theirs] = true
    local text = string.format("%s was made with StudioSync %s; you have %s. Run 'StudioSync - Update' so everyone stays compatible.",
      what, theirs, band.VERSION)
    band.log(text)
  end
end

-- ---- small helpers --------------------------------------------------------------------------

-- Which kind of computer (REAPER's GetOS: "Win64"..., "OSX64" or "macOS-arm64", and "Other" or "linux-..." on Linux). Much of StudioSync took
-- anything that isn't Windows for a Mac; Linux shares the Mac's shell but not its programs (open, Trash, nc's flags). 0.58.74
local OSNAME = tostring(reaper and reaper.GetOS and reaper.GetOS() or "")
band.WIN = OSNAME:find("^Win") ~= nil
band.MAC = OSNAME:find("^OSX") ~= nil or OSNAME:find("^macOS") ~= nil
band.LINUX = not band.WIN and not band.MAC

function band.clean(s) return (s:gsub("[^%w%-_ ]", ""):match("^%s*(.-)%s*$")) end
local function norm(p) return (p:gsub("\\", "/"):gsub("/+$", "")) end
band.norm = norm

-- ReaImGui's 0.10 interface, or nil after saying what to do: an older ReaImGui threw from inside require, and REAPER's own error box was
-- all anyone saw (review, 0.58.91).
function band.imgui()
  local ok, ImGui = pcall(function() return require "imgui" "0.10" end)
  if ok then return ImGui end
  band.msg("StudioSync needs ReaImGui 0.10 or newer. Update it in ReaPack (Extensions > ReaPack > Synchronize packages), then run this again.")
end
function band.msg(text) reaper.MB(text, "StudioSync", 0) end
-- A request the panel carries out ("panel do": the radial menu's slices, the bindable actions), so each asks first exactly as its button there does.
-- The panel is opened first when it isn't running (running it again would close it). `dir`: the scripts' folder.
function band.panel_do(dir, what)
  reaper.SetExtState(band.SECTION, "panel do", what, false)
  reaper.DeleteExtState(band.SECTION, "panel minimized", true) -- (the pill doesn't run the panel's pages)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "panel alive"))
  if not (beat and reaper.time_precise() - beat < 10) then
    local id = reaper.AddRemoveReaScript(true, 0, dir .. "/StudioSync - Panel.lua", true)
    if id > 0 then reaper.Main_OnCommand(id, 0) end
  end
end

-- This computer's own StudioSync folder (projects as you work on them, reopen list). One that's been here since it was called BandSync keeps its
-- folder: open tabs, recent projects and saved paths all point there.
local home_dir
function band.home()
  if not home_dir then
    local old = reaper.GetResourcePath() .. "/BandSync"
    home_dir = reaper.EnumerateSubdirectories and (reaper.EnumerateSubdirectories(old, 0) or reaper.EnumerateFiles(old, 0)) and old or (reaper.GetResourcePath() .. "/StudioSync")
  end
  return home_dir
end
-- Start Live sync for the tab in front. REAPER runs a script action once at a time (Live sync sets
-- set_action_options(2): triggered again while running, it quietly does nothing), so each further session tab
-- syncing at once gets a launcher action of its own: <resource>/Scripts/StudioSync tabs/StudioSync - Live sync (tab N).lua.
-- Live sync stamps "live cmd <action>" while it runs, so a free one is found. Returns true if one was started.
function band.start_live(dir)
  local main = dir .. "/StudioSync - Live sync.lua"
  for n = 0, 16 do
    local path = main
    if n > 0 then
      local d = reaper.GetResourcePath() .. "/Scripts/StudioSync tabs"
      path = d .. "/StudioSync - Live sync (tab " .. n .. ").lua"
      -- (written again when it points elsewhere: after moving from the shared folder to ReaPack, or a renamed folder, extra tabs ran the
      -- old copy, or nothing. Review, 0.58.87)
      local want = "-- StudioSync: Live sync for one more session tab at once (see group.start_live)\ndofile([[" .. main .. "]])\n"
      if band.read(path) ~= want then
        reaper.RecursiveCreateDirectory(d, 0)
        band.write_atomic(path, want)
      end
    end
    local cmd = reaper.AddRemoveReaScript(true, 0, path, true)
    local beat = cmd > 0 and tonumber(reaper.GetExtState(band.SECTION, "live cmd " .. cmd))
    -- (its toggle says whether that one's running: the beat alone goes stale behind any dialog, such as Publish's song name,
    -- and running a script that's already running does nothing, so the new tab stayed "Sync off": PC and laptop, 0.42.2)
    if cmd > 0 and not (beat and reaper.time_precise() - beat < 5) and reaper.GetToggleCommandState(cmd) ~= 1 then
      reaper.Main_OnCommand(cmd, 0)
      return true
    end
  end
  return false
end
-- What StudioSync did, for the panel's Activity list (the last 80 lines). It no longer opens the
-- ReaScript console, which popped up in front on every send and read like an error (Mac, 2026-10-28). Nor does it copy
-- a line there when the console is open: finding that out searched every window, 0.38 s a line, which froze REAPER on
-- every change the band sent (PC, 0.42.2). Setup > Console shows them.
-- And on disk, as it goes (James, 0.58.86: "make sure logs/console and everything is saved as we go for debugging"): every line, and
-- every error with where it happened, in <StudioSync home>/logs/studiosync-YYYY-MM-DD.log, a file a day kept LOG_DAYS days, each line
-- saying which script wrote it (band.WHO). The Console starts from today's file after a restart.
band.LOG_KEY, band.LOG_MAX, band.LOG_DAYS = "activity", 80, 14
band.WHO = "script" -- (each script says what it is: "panel", "live <song>", "autostart")
function band.log_dir() return band.home() .. "/logs" end
local log_ready
-- Log files older than `days` before `today` (a time), by the date in their names. Pure.
function band.old_logs(names, today, days)
  local out = {}
  for _, n in ipairs(names) do
    local y, m, d = n:match("^studiosync%-(%d%d%d%d)%-(%d%d)%-(%d%d)%.log$")
    if y and today - os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) > days * 86400 then out[#out + 1] = n end
  end
  return out
end
function band.log_file(text)
  local dir = band.log_dir()
  if not log_ready then
    log_ready = true
    reaper.RecursiveCreateDirectory(dir, 0)
    for _, n in ipairs(band.old_logs(band.files(dir, ".log"), os.time(), band.LOG_DAYS)) do os.remove(dir .. "/" .. n) end
  end
  local f = io.open(dir .. "/studiosync-" .. os.date("%Y-%m-%d") .. ".log", "a")
  if not f then return end
  f:write(os.date("%H:%M:%S ") .. "[" .. tostring(band.WHO) .. "] " .. (tostring(text):gsub("\r?\n", "\n    ")) .. "\n")
  f:close()
end
-- An error and where it happened (a traceback): to the file in full, to the Console as one line.
function band.log_error(where, err)
  band.log_file("ERROR in " .. where .. ": " .. tostring(err))
end
-- pcall that says so: a step that fails goes to the log file with where (once per different message), and the rest carries on. Bare pcalls
-- swallowed failures of the end-of-session save, removals, the tabs to reopen... with nothing anywhere (review, 0.58.87).
local tried = {}
function band.try(where, fn, ...)
  local res = table.pack(xpcall(fn, debug.traceback, ...))
  if not res[1] then
    local k = where .. "\0" .. tostring(res[2]):match("^[^\n]*")
    if not tried[k] then tried[k] = true; band.log_error(where, res[2]) end
  end
  return table.unpack(res, 1, res.n)
end
function band.log(text)
  local lines = {}
  for l in reaper.GetExtState(band.SECTION, band.LOG_KEY):gmatch("[^\n]+") do lines[#lines + 1] = l end
  lines[#lines + 1] = os.date("%H:%M ") .. tostring(text):gsub("\n", " ")
  while #lines > band.LOG_MAX do table.remove(lines, 1) end
  reaper.SetExtState(band.SECTION, band.LOG_KEY, table.concat(lines, "\n"), false)
  pcall(band.log_file, text)
end
-- Lines from a log file, as the Console shows them ("HH:MM text"), the last `n`. Continuation lines (a traceback) are left out. Pure.
function band.console_lines(text, n)
  local out = {}
  for l in (text or ""):gmatch("[^\n]+") do
    local hm, rest = l:match("^(%d%d:%d%d):%d%d %[[^%]]*%] (.*)$")
    if hm then out[#out + 1] = hm .. " " .. rest end
  end
  while #out > n do table.remove(out, 1) end
  return out
end
-- The Activity lines, newest first. After a restart (nothing this session yet), today's file's last lines.
local activity_loaded
function band.activity()
  if not activity_loaded and reaper.GetExtState(band.SECTION, band.LOG_KEY) == "" then
    activity_loaded = true
    local text = band.read(band.log_dir() .. "/studiosync-" .. os.date("%Y-%m-%d") .. ".log")
    local back = band.console_lines(text, band.LOG_MAX)
    if #back > 0 then reaper.SetExtState(band.SECTION, band.LOG_KEY, table.concat(back, "\n"), false) end
  end
  local lines = {}
  for l in reaper.GetExtState(band.SECTION, band.LOG_KEY):gmatch("[^\n]+") do table.insert(lines, 1, l) end
  return lines
end

function band.read(path)
  local f = io.open(path, "rb")
  if not f then
    -- (a power cut between finish's two renames on Windows left only the old copy, under a name Syncthing ignores: its deletion went to
    -- everyone. Put back on the next read. Review, 0.58.47)
    local dir, name = path:match("^(.*)/([^/]+)$")
    if not dir or not os.rename(dir .. "/.syncthing." .. name .. ".old.tmp", path) then return nil end
    f = io.open(path, "rb")
    if not f then return nil end
  end
  local s = f:read("a"); f:close()
  return s
end

-- Remove a file and a leftover of an interrupted rename beside it (band.read puts that back: a removal mark or a guest list deleted on purpose
-- came back from it. Review, 0.58.92)
function band.remove(path)
  local dir, name = path:match("^(.*)/([^/]+)$")
  if dir then os.remove(dir .. "/.syncthing." .. name .. ".old.tmp") end
  return os.remove(path)
end

function band.size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local n = f:seek("end"); f:close()
  return n
end

-- Write under a temp name, then rename, so a syncing peer never picks up a half-written file.
-- The ".syncthing.*.tmp" name is one Syncthing always ignores; cloud drives may upload it briefly.
-- A write that didn't all reach the disk (a full disk) raises, and the old file stays: renaming a cut-off file into
-- place made it the band's copy (review, 2026-10-31).
local function finish(tmp, path, f, want)
  local ok_close = f:close()
  if not ok_close or band.size(tmp) ~= want then
    os.remove(tmp)
    error("couldn't write " .. path .. " (is the disk full?)")
  end
  if os.rename(tmp, path) then return end -- POSIX: replaces it in one step
  -- Windows won't rename over a file: move the old one aside first (never deleted before the new one is in place;
  -- named so Syncthing ignores it, as it does the .tmp)
  local dir, name = path:match("^(.*)/([^/]+)$")
  local old = dir .. "/.syncthing." .. name .. ".old.tmp"
  os.remove(old)
  os.rename(path, old)
  if not os.rename(tmp, path) then os.rename(old, path); error("cannot replace " .. path) end
  os.remove(old)
end
function band.write_atomic(path, data)
  local dir, name = path:match("^(.*)/([^/]+)$")
  local tmp = dir .. "/.syncthing." .. name .. ".tmp"
  local f = assert(io.open(tmp, "wb"))
  if not f:write(data) then f:close(); os.remove(tmp); error("couldn't write " .. path .. " (is the disk full?)") end
  finish(tmp, path, f, #data)
end

-- A copy, a piece at a time (a long recording or a video read whole took that much memory, and froze REAPER while
-- it did), checked to be complete before it's put in place.
function band.copy_atomic(src, dst)
  local fi = assert(io.open(src, "rb"), "cannot read " .. src)
  local dir, name = dst:match("^(.*)/([^/]+)$")
  local tmp = dir .. "/.syncthing." .. name .. ".tmp"
  local fo = io.open(tmp, "wb")
  if not fo then fi:close(); error("cannot write " .. dst) end
  local total = 0
  while true do
    local chunk = fi:read(1048576)
    if not chunk then break end
    if not fo:write(chunk) then fi:close(); fo:close(); os.remove(tmp); error("couldn't write " .. dst .. " (is the disk full?)") end
    total = total + #chunk
  end
  fi:close()
  if total ~= band.size(src) then fo:close(); os.remove(tmp); error("couldn't read all of " .. src) end
  finish(tmp, dst, fo, total)
end

function band.read_json(path)
  local s = band.read(path)
  if not s then return nil end
  local ok, v = pcall(json.decode, s)
  return ok and type(v) == "table" and v or nil
end

function band.write_json(path, t) band.write_atomic(path, json.encode(t, true)) end
function band.json_encode(t) return json.encode(t) end -- keys sorted: equal tables give equal strings
function band.json_decode(s) local ok, v = pcall(json.decode, s); return ok and v or nil end

local function enum(fn, dir)
  local out, i = {}, 0
  fn(dir, -1) -- invalidate REAPER's directory cache so newly synced files show up
  while true do
    local name = fn(dir, i)
    if not name then break end
    out[#out + 1] = name; i = i + 1
  end
  table.sort(out)
  return out
end

-- Sync conflict copies ("x.sync-conflict-20261028-071122-ABCDEF.json", Drive's "x (1).json") aren't files of
-- ours: a copy of an event would be applied again on every pass (it never counts as applied).
function band.is_conflict_copy(f) return f:find(".sync-conflict-", 1, true) ~= nil or f:match(" %(%d+%)%.[^.]+$") ~= nil end
function band.files(dir, ext)
  local out = {}
  for _, f in ipairs(enum(reaper.EnumerateFiles, dir)) do
    if (not ext or f:lower():sub(-#ext) == ext) and not band.is_conflict_copy(f) then out[#out + 1] = f end
  end
  return out
end

function band.subdirs(dir) return enum(reaper.EnumerateSubdirectories, dir) end

-- Pop a menu at the mouse (or at x, y); returns the chosen string or nil. Lines starting "#" are greyed headers.
function band.pick(items, x, y)
  if #items == 0 then return nil end
  if not x then x, y = reaper.GetMousePosition() end
  gfx.init("", 0, 0, 0, x, y)
  gfx.x, gfx.y = 0, 0
  local i = gfx.showmenu(table.concat(items, "|"))
  gfx.quit()
  return items[i]
end

-- ---- settings and project binding -----------------------------------------------------------

function band.settings(force)
  local root = reaper.GetExtState(band.SECTION, "sync_root")
  local user = reaper.GetExtState(band.SECTION, "user")
  if force or root == "" or user == "" then
    if root == "" and reaper.JS_Dialog_BrowseForFolder then
      local ok, picked = reaper.JS_Dialog_BrowseForFolder("StudioSync: pick the shared (Syncthing) folder", "")
      if ok == 1 then root = picked end
    end
    local ok, csv = reaper.GetUserInputs("StudioSync settings", 2,
      "Shared folder (Syncthing),Your name,separator=|,extrawidth=250", root .. "|" .. user)
    if not ok then return nil end
    root, user = csv:match("^(.-)|(.*)$")
    root = root:gsub("^~", os.getenv("HOME") or os.getenv("USERPROFILE") or "~")
    root, user = norm(root), band.clean(user)
    if root == "" or user == "" then return nil end
    local probe = root .. "/.bandsync-write-test" -- the folder must exist and be writable
    local f = io.open(probe, "w")
    if not f then
      band.msg("Can't write to " .. root .. ". Check the folder exists (is Syncthing set up?).")
      return nil
    end
    f:close(); os.remove(probe)
    local old = reaper.GetExtState(band.SECTION, "user")
    reaper.SetExtState(band.SECTION, "sync_root", root, true)
    reaper.SetExtState(band.SECTION, "user", user, true)
    if old ~= "" and old ~= user then band.rename_everywhere(old, user, root) end
  end
  return { root = root, user = user }
end

-- Old names, so a renamed bandmate's tracks stay theirs: <root>/_band/names.json, an old name's tag -> the name now.
-- (Checked by mirror.is_creator; read at most every 10 s.)
local names_at, names = {}, {}
function band.names(root)
  root = root or reaper.GetExtState(band.SECTION, "sync_root")
  if reaper.time_precise() - (names_at[root] or -math.huge) > 10 then
    names_at[root] = reaper.time_precise()
    names[root] = band.read_json(root .. "/_band/names.json") or {}
  end
  return names[root]
end

-- Someone took a new name: everywhere the band's files hold the old one (who drives each room, their claims, their
-- Who's here file) it becomes the new one, and the old name is remembered. Their history keeps the old name.
function band.rename(root, old, new)
  local tag = function(u) return ((u or "x"):gsub("[^%w]", "_")):upper() end
  local file = function(u) return (u:gsub("[^%w%-_ ]", "")) .. ".json" end
  local npath = root .. "/_band/names.json"
  local map = band.read_json(npath)
  if map or not reaper.file_exists(npath) then -- (half-synced: left as it is, not written back empty. Review, 0.58.92)
    map = map or {}
    for k, v in pairs(map) do if v == old then map[k] = new end end -- (renamed before: those names lead here too)
    map[tag(old)] = new
    map[tag(new)] = nil
    reaper.RecursiveCreateDirectory(root .. "/_band", 0)
    band.write_json(npath, map)
  end
  names_at[root] = nil
  local j = band.read_json(root .. "/_band/band.json") -- (who runs the group: lib/groups.lua)
  if type(j) == "table" then -- (only when a role named them: written by anyone renaming, a newly invited computer set the roles aside. Review, 0.58.92)
    local changed = j.owner == old
    if changed then j.owner = new end
    for i, a in ipairs(type(j.admins) == "table" and j.admins or {}) do if a == old then j.admins[i] = new; changed = true end end
    if changed then band.write_json(root .. "/_band/band.json", j) end
  end
  -- (this computer's files under the old name: its devices file and plug-in list are written again under the new one at the next look, and the
  -- old ones stayed, a second member with the old name on every computer: James, 0.58.81. A colour picked moves over.)
  local dev = band.read_json(root .. "/_band/devices/" .. file(old)) -- (its names on each Tailscale network go along: services.pin_tailnet)
  if type(dev) == "table" and not reaper.file_exists(root .. "/_band/devices/" .. file(new)) then
    dev.user = new
    band.write_json(root .. "/_band/devices/" .. file(new), dev)
  end
  band.remove(root .. "/_band/devices/" .. file(old))
  band.remove(root .. "/plugins/" .. file(old))
  local col = band.read_json(root .. "/_band/colours/" .. file(old))
  if type(col) == "table" then
    col.user = new
    band.write_json(root .. "/_band/colours/" .. file(new), col)
    os.remove(root .. "/_band/colours/" .. file(old))
  end
  local n = 0
  for _, song in ipairs(band.subdirs(root)) do
    for _, room in ipairs(band.subdirs(root .. "/" .. song .. "/rooms")) do
      local rdir = root .. "/" .. song .. "/rooms/" .. room
      local d = band.read_json(rdir .. "/driver.json")
      if d and d.driver == old then d.driver = new; band.write_json(rdir .. "/driver.json", d); n = n + 1 end
      local c = band.read_json(rdir .. "/claims/" .. file(old))
      if c then
        c.user = new
        band.write_json(rdir .. "/claims/" .. file(new), c)
        os.remove(rdir .. "/claims/" .. file(old))
        n = n + 1
      end
      os.remove(rdir .. "/status/" .. file(old)) -- (Live sync writes the new one)
    end
  end
  band.log(string.format("you're %s now (was %s): who drives and your claims moved over in %d place(s); your tracks stay yours. " ..
    "Changes you made as %s stay under that name in Restore (Undo only steps back through changes made as %s).", new, old, n, old, new))
end

-- Your name is this computer's in every studio it's in, so a new one goes to all of them (James, 0.58.81: "make the names stay the same across
-- my studios"; it went only to the studio open then). `extra`: a studio not on the list yet.
function band.rename_everywhere(old, new, extra)
  local done = {}
  local roots = {}
  for _, x in ipairs(band.bands()) do roots[#roots + 1] = x.root end
  if extra then roots[#roots + 1] = extra end
  for _, r in ipairs(roots) do
    if not done[r] then done[r] = true; band.rename(r, old, new) end
  end
end

-- A project is bound to one song: role (host/guest), song, room, version, take_mode.
function band.binding(proj)
  local b = {}
  for _, k in ipairs({ "role", "song", "room", "version", "take_mode", "stem_mode", "print", "root" }) do
    local _, v = reaper.GetProjExtState(proj, band.SECTION, k)
    b[k] = v ~= "" and v or nil
  end
  return b.song and b or nil
end
-- Another tab already syncing this song's room (the same .rpp opened twice): that tab, or nil. A second copy's Live
-- sync would work on a stale or empty copy of the song (laptop, block K: the panel offered Start in it).
-- Two studios' folders the same one? A binding from before studios names none: that counts as any (it was the only one). (A song of the
-- same name in two studios was taken for one: opening the second switched to the first's tab, or opened its file and took the second's
-- changes in. Review, 0.58.87)
function band.same_studio(a, b)
  if (a or "") == "" or (b or "") == "" then return true end
  return band.norm(a):lower() == band.norm(b):lower()
end
-- This computer's own project file for a studio's song: remembered per studio ("project file <studio id>/<song>", 0.58.87), else as before
-- by song alone. And the studio's own local folder for songs opened from now on.
function band.studio_key(root) return band.clean(tostring(band.info(root or "").id or "")) end
function band.project_file(root, song)
  local f = root and reaper.GetExtState(band.SECTION, "project file " .. band.studio_key(root) .. "/" .. song) or ""
  return f ~= "" and f or reaper.GetExtState(band.SECTION, "project file " .. song)
end
function band.set_project_file(root, song, path)
  reaper.SetExtState(band.SECTION, "project file " .. band.studio_key(root) .. "/" .. song, path, true)
end
function band.forget_project_file(root, song)
  reaper.DeleteExtState(band.SECTION, "project file " .. band.studio_key(root) .. "/" .. song, true)
  reaper.DeleteExtState(band.SECTION, "project file " .. song, true)
end
function band.synced_elsewhere(proj)
  local b = band.binding(proj)
  if not b then return nil end
  for k = 0, 512 do
    local p = reaper.EnumProjects(k)
    if not p then break end
    local o = p ~= proj and band.binding(p)
    if o and o.song == b.song and (o.room or "main") == (b.room or "main") and band.same_studio(o.root, b.root) then
      local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(p)))
      if beat and reaper.time_precise() - beat < 30 then return p end
    end
  end
end

-- Colours travel in one byte order, Windows' (0x01BBGGRR: REAPER's native colour there, so nothing a Windows machine
-- already sent changes). A Mac's native one is 0x01RRGGBB: sent raw, a red track showed blue on the other platform.
-- out: this machine's native -> travelling; in: travelling -> native. The 0x1000000 "colour set" flag is kept.
function band.color_out(c)
  c = math.floor(tonumber(c) or 0)
  if c == 0 or not reaper.ColorFromNative then return c end
  local r, g, b = reaper.ColorFromNative(c & 0xFFFFFF)
  return (c & ~0xFFFFFF) | (b << 16) | (g << 8) | r
end
function band.color_in(c)
  c = math.floor(tonumber(c) or 0)
  if c == 0 or not reaper.ColorToNative then return c end
  return (c & ~0xFFFFFF) | reaper.ColorToNative(c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF)
end

-- SWS auto track colouring is off while a band song is in front (James, 2026-11-01): its rules recolour every
-- track, so a machine with it on could neither send the band's colours nor keep them. It goes back on when another
-- project comes to the front (Live sync and Autostart both look). "sws colour off": StudioSync switched it off, so
-- StudioSync switches it back (and only then: someone who has it off themselves keeps it off).
function band.sws_colours()
  local id = reaper.NamedCommandLookup and reaper.NamedCommandLookup("_SWSAUTOCOLOR_ENABLE") or 0
  if id <= 0 then return end
  local front = band.binding(reaper.EnumProjects(-1)) ~= nil
  local on, ours = reaper.GetToggleCommandState(id) == 1, reaper.GetExtState(band.SECTION, "sws colour off") ~= ""
  if front and on then
    reaper.Main_OnCommand(id, 0)
    reaper.SetExtState(band.SECTION, "sws colour off", "1", true)
    reaper.SetExtState(band.SECTION, "sws colours ran", tostring(reaper.time_precise()), false) -- (it may have just recoloured this tab: mirror.watch)
  elseif not front and ours then
    if not on then reaper.Main_OnCommand(id, 0) end
    reaper.DeleteExtState(band.SECTION, "sws colour off", true)
  end
end

-- ---- what's in REAPER's Actions list ----------------------------------------------------------------------------
-- Someone who isn't binding keys needs only what opens StudioSync (James, 0.58.71: the Actions list showed 26 of ours). Kept: the panel (also
-- Extensions > StudioSync and View > StudioSync, extension/reaper_menu.cpp), Undo and Redo (Ctrl+Z runs them), and Live sync and Draw (they run
-- as actions). The rest come back when the panel runs one, when a key, a toolbar or a menu uses one, or all of them with Settings >
-- "Every StudioSync action in REAPER's Actions list" (ExtState "all actions"). Their command ids come from their paths, so bindings survive.
band.SHOWN = { Panel = true, Undo = true, Redo = true, ["Live sync"] = true, Draw = true }
function band.all_actions() return reaper.GetExtState(band.SECTION, "all actions") == "1" end
-- Should this script be in the Actions list? Pure. name: "Hold my changes"; used: a key, toolbar or menu runs it.
function band.shown_action(name, all, used) return all or used or band.SHOWN[name] == true end
-- Registers what should be listed and takes the rest out. at_start: REAPER is just starting, so nothing of ours runs yet, and Live sync's
-- copies for more tabs (band.start_live: registered again as each starts) go too, as do actions whose script is gone. -> listed, taken out.
function band.sync_actions(dir, at_start)
  local res = norm(reaper.GetResourcePath())
  local kb, menus = band.read(res .. "/reaper-kb.ini") or "", band.read(res .. "/reaper-menu.ini") or ""
  local ids, drop = {}, {}
  for id, path in kb:gmatch('SCR %d+ 0 (%S+) "[^"]*" "([^"]+)"') do
    path = norm(path)
    if not (path:match("^/") or path:match("^%a:")) then path = res .. "/Scripts/" .. path end
    ids[path:lower()] = id
    local ours = path:match("/StudioSync %- [^/]+%.lua$")
    if at_start and ours and (path:find("/StudioSync tabs/", 1, true) or not reaper.file_exists(path)) then drop[#drop + 1] = path end
  end
  local all, add = band.all_actions(), {}
  for _, f in ipairs(band.files(dir, ".lua")) do
    local name = f:match("^StudioSync %- (.+)%.lua$")
    if name then
      local path = norm(dir) .. "/" .. f
      local id = ids[path:lower()]
      local used = id ~= nil and (kb:find(" _" .. id .. " ", 1, true) ~= nil or menus:find("=_" .. id, 1, true) ~= nil)
      if band.shown_action(name, all, used) then add[#add + 1] = path elseif id then drop[#drop + 1] = path end
    end
  end
  for i, p in ipairs(add) do reaper.AddRemoveReaScript(true, 0, p, i == #add and #drop == 0) end
  for i, p in ipairs(drop) do reaper.AddRemoveReaScript(false, 0, p, i == #drop) end
  return #add, #drop
end

-- ---- bands: each band is its own shared folder (docs/bands-design.md) ----------------------------------------
-- The drawings over the arrange view (StudioSync - Draw.lua), if they aren't showing. Running it again would close it.
function band.start_draw(dir)
  local id = reaper.AddRemoveReaScript(true, 0, dir .. "/StudioSync - Draw.lua", true)
  -- (a script that died keeps its toggle lit: its beat says whether it's really running)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "draw alive"))
  if id > 0 and (reaper.GetToggleCommandState(id) ~= 1 or not beat or reaper.time_precise() - beat > 3) then reaper.Main_OnCommand(id, 0) end
end
-- <root>/_band/band.json says which band a folder is: { name, id = its Syncthing folder id, drive = its Google Drive
-- folder's name }. A folder without one is the first band StudioSync had: id "bandsync", Drive folder "BandSync".
-- (the folder's Syncthing id never changes (groups.rename), and everything that asks Syncthing about the studio goes by it, lib/trust.lua too: a
-- member rewriting band.json's id sent those questions to a folder Syncthing doesn't have, whose empty answer was believed, and pointed the
-- role pins at a fresh, empty set. So the id this computer first knew for the folder stands: its own start or join, the invitation the
-- installer ran (installer/studiosync_setup.lua), else the first band.json it saw (band.bands). Security review, 0.58.78)
local function id_key(root) return "band id " .. (root:gsub("\\", "/"):gsub("/+$", ""):lower()) end
function band.pin_id(root, id) -- (no id: forgotten, for a scratch studio)
  if id then reaper.SetExtState(band.SECTION, id_key(root), id, true) else reaper.DeleteExtState(band.SECTION, id_key(root), true) end
end
function band.info(root)
  local j = (root and (band.read_json(root .. "/_band/band.json") or band.json_decode(reaper.GetExtState(band.SECTION, "joining " .. root)))) or {}
  -- (only a plain folder id: it goes into Syncthing's command line, and a space in it added arguments of its own. Review, 0.58.53)
  local id = type(j.id) == "string" and j.id:match("^[%w%-_.]+$") and j.id or "bandsync"
  local pinned = root and reaper.GetExtState(band.SECTION, id_key(root))
  local pin = type(pinned) == "string" and pinned:match("^[%w%-_.]+$") and pinned
  -- (named: what band.json, or the join waiting for it, says, for band.bands to pin, or to say when it differs)
  local named = next(j) ~= nil and (j.id ~= nil and tostring(j.id) or "bandsync") or nil
  if pin then id = pin end
  return { name = type(j.name) == "string" and j.name ~= "" and j.name or "the studio", id = id, named = named, pinned = pin and true or nil,
    drive = type(j.drive) == "string" and j.drive ~= "" and j.drive or (id == "bandsync" and "BandSync" or ("StudioSync - " .. (j.name or id))) }
end
-- The bands this computer is in (persistent ExtState "bands": their folders), the current one always among them:
-- { { root, name, id, drive } }, by name.
-- Is StudioSync running from inside a shared folder (the installer's -Scripts folder)? Then anyone in the studio can change what runs here.
function band.from_shared(dir)
  local d = (dir or ""):gsub("\\", "/"):lower()
  for _, g in ipairs(band.bands()) do
    local r = (g.root or ""):gsub("\\", "/"):lower():gsub("/+$", "")
    if r ~= "" and d:sub(1, #r + 1) == r .. "/" then return true end
  end
  return false
end
-- May a running script switch to the version now on disk? Installed through ReaPack (or by hand), yes: you asked for it. Run from a shared
-- folder, only once you've said yes to that version (Autostart asks): any computer in the studio can put new code there, and it ran on
-- everyone within seconds (review, 0.58.52). (It still runs when REAPER next starts: Settings > Health says so, and ReaPack is the safer install.)
function band.update_ok(dir, version)
  if not band.from_shared(dir) then return true end
  return reaper.GetExtState(band.SECTION, "update ok") == version and band.files_complete(dir)
end
-- Has every file of the version in `dir` arrived whole? The release lists its code files and their lengths (lib/files.txt, counted without
-- carriage returns so Windows' and a Mac's line endings agree: tools/make_index.py). Syncthing brings files one at a time, small ones first
-- on a joiner, so band.lua's new VERSION arrived before mirror.lua and the panel, and the reload ran half-new, half-old code until REAPER
-- restarted (review, 0.58.89). No list (older versions): true. Each version is looked over at most every 3 s, and believed once whole.
local complete_seen, complete_at = {}, -math.huge
function band.files_list(text)
  local out = {}
  for path, n in (text or ""):gmatch("([^\t\r\n]+)\t(%d+)") do out[#out + 1] = { path = path, len = tonumber(n) } end
  return out
end
function band.files_complete(dir)
  local list_text = band.read(dir .. "/lib/files.txt")
  if not list_text then return true end
  local v = list_text:match("^version (%S+)") or ""
  if complete_seen[dir .. v] then return true end
  if reaper.time_precise() - complete_at < 3 then return false end
  complete_at = reaper.time_precise()
  for _, f in ipairs(band.files_list(list_text)) do
    local s = band.read(dir .. "/" .. f.path)
    if not s or #s - select(2, s:gsub("\r", "")) ~= f.len then return false end
  end
  complete_seen[dir .. v] = true
  return true
end

-- The few settings a crash can lose (persisted ExtState reaches disk only at a clean exit): the studios list, the folder in use, your
-- name, this computer's id, and each studio's pinned roles and inviter. Kept in <StudioSync home>/settings.json as well, and put back
-- from there when REAPER comes up without them. A crash right after joining lost the studio from the list, and its security pins. Review, 0.58.89.
function band.kept_keys()
  local keys = { "bands", "sync_root", "user", "machine id" }
  for r in reaper.GetExtState(band.SECTION, "bands"):gmatch("[^|]+") do
    local n = (r:gsub("\\", "/"):gsub("/+$", ""):lower())
    keys[#keys + 1] = "role pins " .. tostring(band.info(r).id) .. " " .. n
    keys[#keys + 1] = "invited by " .. n
  end
  return keys
end
local kept_text
function band.keep_settings()
  local t = {}
  for _, k in ipairs(band.kept_keys()) do
    local v = reaper.GetExtState(band.SECTION, k)
    if v ~= "" then t[k] = v end
  end
  local text = band.json_encode(t)
  if text ~= kept_text and next(t) then kept_text = text; pcall(band.write_atomic, band.home() .. "/settings.json", text) end
end
function band.restore_settings()
  local t = band.read_json(band.home() .. "/settings.json")
  if type(t) ~= "table" then return 0 end
  local n = 0
  for k, v in pairs(t) do
    if type(k) == "string" and type(v) == "string" and reaper.GetExtState(band.SECTION, k) == "" then reaper.SetExtState(band.SECTION, k, v, true); n = n + 1 end
  end
  return n
end

local id_said = {}
function band.bands()
  local roots, seen, out = {}, {}, {}
  for r in reaper.GetExtState(band.SECTION, "bands"):gmatch("[^|]+") do roots[#roots + 1] = r end
  roots[#roots + 1] = reaper.GetExtState(band.SECTION, "sync_root")
  for _, r in ipairs(roots) do
    -- (a folder that's gone is left out. One just joined, with nothing arrived yet, is in, marked waiting: it was left out too, and a joiner
    -- read "You're not in a studio yet" until they were let in. Beginner review, 0.58.62)
    local real = false
    -- (_band doesn't count: this computer writes its own device file there within 30 s of joining. Review, 0.58.67)
    for _, d in ipairs(r ~= "" and band.subdirs(r) or {}) do if d:sub(1, 1) ~= "." and (d ~= "_band" or reaper.file_exists(r .. "/_band/band.json")) then real = true end end
    if r ~= "" and not seen[r] and (real or band.subdirs(r)[1] or reaper.EnumerateFiles(r, 0)) then
      seen[r] = true
      local i = band.info(r)
      if not i.pinned then
        if i.named then band.pin_id(r, i.id) end
      elseif i.named and i.named ~= i.id and not id_said[r] then
        id_said[r] = true
        band.log(i.name .. "'s band.json names another Syncthing folder (" .. i.named .. "): StudioSync keeps " .. i.id .. ", the one this computer joined")
      end
      out[#out + 1] = { root = r, name = i.name, id = i.id, drive = i.drive, waiting = not real or nil }
    end
  end
  table.sort(out, function(a, z) return a.name:lower() < z.name:lower() end)
  return out
end
-- Make `root` the band this computer works in (new songs, the start screen, the chooser), and remember it.
function band.use_band(root)
  local list = {}
  for _, x in ipairs(band.bands()) do list[#list + 1] = x.root end
  local known = false
  for _, r in ipairs(list) do if r == root then known = true end end
  if not known then list[#list + 1] = root end
  reaper.SetExtState(band.SECTION, "bands", table.concat(list, "|"), true)
  reaper.SetExtState(band.SECTION, "sync_root", root, true)
end
-- The settings for a song tab: its own band's folder, whichever band this computer is working in now. A tab
-- bound before bands (no root) is in the current band. `cfg.base` keeps the computer's own settings.
function band.for_tab(cfg, b)
  local base = cfg and (cfg.base or cfg)
  if not base then return nil end
  local root = b and b.root
  if b and not root and b.song then
    -- a tab bound before bands names no band: the one whose folder has its song (laptop, 0.35.1: a Chilio song read
    -- through Test Band, "nil drives", once the computer worked in Test Band). The current band first.
    local roots = { base.root }
    for _, x in ipairs(band.bands()) do roots[#roots + 1] = x.root end
    for _, r in ipairs(roots) do
      if reaper.file_exists(band.session_path({ root = r }, b.song)) then root = r; break end
    end
  end
  if root and root ~= base.root and band.subdirs(root)[1] then
    return { root = root, user = base.user, base = base }
  end
  return base
end

-- The key that says "start Live sync with REAPER for this project": its path in one spelling (forward slashes, lower
-- case), as REAPER may be handed it with either slash (Recent projects, the browser, a script).
function band.live_here(proj) -- Live sync's running for this tab
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(proj)))
  return beat ~= nil and reaper.time_precise() - beat < 5
end
-- REAPER's "Set media items offline when application is not active" leaves a song's parts OFFLINE and without peaks while the studio sends them in behind
-- another app (Mac, 0.45.0). Turned off once on this computer, the first time a song syncs; turned on again by hand, it stays on (Health says so).
function band.stay_online()
  local mark = band.home() .. "/stay-online" -- (a file: a kept ExtState is only written at a clean exit, and a crash then undid someone turning it back on)
  if not reaper.SNM_GetIntConfigVar or not reaper.BR_Win32_WritePrivateProfileString or reaper.file_exists(mark) then return end
  band.write_atomic(mark, "turned off once: yours from here on\n")
  if reaper.SNM_GetIntConfigVar("offlineinact", 0) == 0 then return end
  reaper.SNM_SetIntConfigVar("offlineinact", 0)
  reaper.BR_Win32_WritePrivateProfileString("REAPER", "offlineinact", "0", reaper.get_ini_file()) -- (in the file too, as lib/startup.lua's)
  band.log("turned off REAPER's 'Set media items offline when application is not active', so parts stay online while the studio sends them in (Preferences > Media)")
end

-- Actions an old install left behind, from REAPER's key file: { {section, path} }. BandSync's scripts whose file's gone, and BandSync's tab launchers,
-- whose file stays but runs a script that's gone (Mac, 0.58.3). `exists`, `read`: file_exists and "the file's text". Pure.
function band.old_actions(text, scripts, exists, read)
  local out = {}
  for section, path in text:gmatch('SCR %d+ (%d+) %S+ "[^"]*" "([^"]*BandSync %- [^"]*%.lua)"') do
    local p = band.norm(path)
    if not p:match("^/") and not p:match("^%a:") then p = scripts .. "/" .. p end
    local target = exists(p) and (read(p) or ""):match("dofile%(%[%[(.-)%]%]%)")
    if not exists(p) or (target and not exists(target)) then out[#out + 1] = { section = tonumber(section), path = p } end
  end
  return out
end

-- A web page in the browser.
function band.open_url(url)
  if reaper.CF_ShellExecute then return reaper.CF_ShellExecute(url) end
  if band.WIN then os.execute('start "" "' .. url:gsub('"', "") .. '"')
  elseif band.LINUX then os.execute("xdg-open '" .. url:gsub("'", "") .. "' >/dev/null 2>&1 &")
  else os.execute("open '" .. url:gsub("'", "") .. "'") end
end

-- Text onto the clipboard, saying so. SWS's when it's there: ReaImGui's left a Mac's clipboard as it was (Health's Copy the line, 0.58.20).
function band.copy(text, ctx, ImGui)
  if reaper.CF_SetClipboard then reaper.CF_SetClipboard(text) else ImGui.SetClipboardText(ctx, text) end
  band.log("copied: " .. (#text > 60 and (text:sub(1, 57) .. "...") or text))
end

function band.autosync_key(path) return "autosync " .. (path or ""):gsub("\\", "/"):lower() end

function band.bind(proj, b)
  for k, v in pairs(b) do reaper.SetProjExtState(proj, band.SECTION, k, tostring(v)) end
end

function band.song_dir(cfg, song) return cfg.root .. "/" .. song end
function band.session_path(cfg, song) return band.song_dir(cfg, song) .. "/session.json" end
function band.takes_dir(cfg, song, room) return band.song_dir(cfg, song) .. "/rooms/" .. room .. "/takes" end

-- Newest publish first (the song you're working on now is at the top of the menu).
function band.songs(cfg)
  local out, when = {}, {}
  -- (a guest who was given only some projects sees only those: lib/access.lua, 0.58.89)
  local oka, allowed = pcall(function() return require("access").mine(cfg.root) end)
  if not oka then allowed = nil end
  for _, d in ipairs(band.subdirs(cfg.root)) do
    local s = (not allowed or allowed[d]) and reaper.file_exists(band.session_path(cfg, d)) and band.read_json(band.session_path(cfg, d))
    if s then out[#out + 1], when[d] = d, s.published or "" end
  end
  table.sort(out, function(x, y) if when[x] ~= when[y] then return when[x] > when[y] end return x < y end)
  return out
end

-- ---- timeline: sample rate, tempo map, markers ----------------------------------------------

function band.srate(proj)
  if reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", 0, false) == 1 then
    return reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", 0, false)
  end
  local _, sr = reaper.GetAudioDeviceInfo("SRATE")
  return tonumber(sr) or 48000
end

function band.capture_tempo(proj)
  local out = {}
  for i = 0, reaper.CountTempoTimeSigMarkers(proj) - 1 do
    local _, t, _, _, bpm, num, den, lin = reaper.GetTempoTimeSigMarker(proj, i)
    out[#out + 1] = { time = t, bpm = bpm, num = num, denom = den, linear = lin }
  end
  if #out == 0 or out[1].time > 0 then -- make the project's base tempo explicit at time 0
    local num, den, bpm = reaper.TimeMap_GetTimeSigAtTime(proj, 0)
    table.insert(out, 1, { time = 0, bpm = bpm, num = num, denom = den, linear = false })
  end
  return out
end

function band.apply_tempo(proj, map)
  for i = reaper.CountTempoTimeSigMarkers(proj) - 1, 0, -1 do reaper.DeleteTempoTimeSigMarker(proj, i) end
  for _, m in ipairs(map) do
    reaper.SetTempoTimeSigMarker(proj, -1, m.time, -1, -1, m.bpm, m.num, m.denom, m.linear)
  end
  reaper.UpdateTimeline()
end

-- Regions StudioSync draws to show who claimed a stretch of time ("[claimed: James]") are this machine's
-- display only: they're never captured as the song's markers, and applying the band's markers keeps them.
band.CLAIM_MARK = "[claimed: "
function band.is_claim_mark(name) return (name or ""):sub(1, #band.CLAIM_MARK) == band.CLAIM_MARK end
-- A marker or region only this machine shows: a claim, or a bandmate's ping ("[ping] Bee", lib/presence.lua).
function band.is_local_mark(name) return band.is_claim_mark(name) or (name or ""):sub(1, 7) == "[ping] " end

function band.capture_markers(proj)
  local out, i = {}, 0
  while true do
    local n, rgn, pos, rend, name, _, color = reaper.EnumProjectMarkers3(proj, i)
    if n == 0 then break end
    if not band.is_local_mark(name) then
      local m = reaper.GetRegionOrMarker and reaper.GetRegionOrMarker(proj, i, "")
      local lane = m and reaper.GetRegionOrMarkerInfo_Value(proj, m, "I_LANENUMBER") or -1
      out[#out + 1] = { region = rgn, pos = pos, ["end"] = rend, name = name, color = band.color_out(color), lane = lane >= 0 and math.floor(lane) or nil }
    end
    i = i + 1
  end
  return out
end

-- The project's own settings that change how the song plays or reads: title, author, notes, track group names and the
-- timebase (with different timebases one tempo change moves items differently per machine). Travel with the timeline.
function band.capture_project(proj)
  local p = { title = select(2, reaper.GetSetProjectInfo_String(proj, "PROJECT_TITLE", "", false)),
    author = select(2, reaper.GetSetProjectInfo_String(proj, "PROJECT_AUTHOR", "", false)), notes = reaper.GetSetProjectNotes(proj, false, ""),
    groups = {}, timebase = "" }
  for g = 1, 64 do
    local name = select(2, reaper.GetSetProjectInfo_String(proj, "TRACK_GROUP_NAME:" .. g, "", false))
    if name ~= "" then p.groups[tostring(g)] = name end
  end
  p.lanes = {}
  for l = 0, math.floor(reaper.GetSetProjectInfo(proj, "RULER_LANE_COUNT", 0, false)) - 1 do
    local lane = { name = select(2, reaper.GetSetProjectInfo_String(proj, "RULER_LANE_NAME:" .. l, "", false)) }
    for _, k in ipairs(band.LANE_KEYS) do lane[k] = reaper.GetSetProjectInfo(proj, "RULER_LANE_" .. k .. ":" .. l, 0, false) end
    p.lanes[#p.lanes + 1] = lane
  end
  if reaper.SNM_GetIntConfigVarEx then -- (no setter in REAPER's API: SWS reaches the project's own config)
    p.timebase = reaper.SNM_GetIntConfigVarEx(proj, "itemtimelock", -1) .. " " .. reaper.SNM_GetIntConfigVarEx(proj, "tempoenvtimelock", -1)
    -- the project's defaults that change what's heard: its pan law and pan mode (tracks on "project default" use them), whether overlapping
    -- items mix, and the default pitch-shift mode (review, 0.58.89: equal only from the first copy, then each computer's own)
    p.defaults = { panmode = reaper.SNM_GetIntConfigVarEx(proj, "panmode", -1), panlawflags = reaper.SNM_GetIntConfigVarEx(proj, "panlawflags", -1),
      itemmixflag = reaper.SNM_GetIntConfigVarEx(proj, "itemmixflag", -1), defpitchcfg = reaper.SNM_GetIntConfigVarEx(proj, "defpitchcfg", -1),
      panlaw = reaper.SNM_GetDoubleConfigVarEx and math.floor(reaper.SNM_GetDoubleConfigVarEx(proj, "panlaw", -1) * 1e6 + 0.5) / 1e6 or nil }
  end
  return p
end

function band.apply_project(proj, p)
  if type(p) ~= "table" then return end
  for _, kv in ipairs({ { "title", "PROJECT_TITLE" }, { "author", "PROJECT_AUTHOR" } }) do
    if type(p[kv[1]]) == "string" and select(2, reaper.GetSetProjectInfo_String(proj, kv[2], "", false)) ~= p[kv[1]] then
      reaper.GetSetProjectInfo_String(proj, kv[2], p[kv[1]], true)
    end
  end
  if type(p.notes) == "string" and reaper.GetSetProjectNotes(proj, false, "") ~= p.notes then reaper.GetSetProjectNotes(proj, true, p.notes) end
  if type(p.groups) == "table" then
    for g = 1, 64 do
      local want = p.groups[tostring(g)] or ""
      if type(want) == "string" and select(2, reaper.GetSetProjectInfo_String(proj, "TRACK_GROUP_NAME:" .. g, "", false)) ~= want then
        reaper.GetSetProjectInfo_String(proj, "TRACK_GROUP_NAME:" .. g, want, true)
      end
    end
  end
  if type(p.defaults) == "table" and reaper.SNM_SetIntConfigVarEx then
    for _, k in ipairs({ "panmode", "panlawflags", "itemmixflag", "defpitchcfg" }) do
      local v = math.tointeger(tonumber(p.defaults[k]))
      if v and v >= 0 and reaper.SNM_GetIntConfigVarEx(proj, k, -1) ~= v then reaper.SNM_SetIntConfigVarEx(proj, k, v) end
    end
    local law = tonumber(p.defaults.panlaw)
    if law and law >= 0 and reaper.SNM_SetDoubleConfigVarEx and math.abs(reaper.SNM_GetDoubleConfigVarEx(proj, "panlaw", -1) - law) > 1e-6 then
      reaper.SNM_SetDoubleConfigVarEx(proj, "panlaw", law)
    end
  end
  local it, te = tostring(p.timebase or ""):match("^(%-?%d+) (%-?%d+)$")
  if it and reaper.SNM_SetIntConfigVarEx and tonumber(it) >= 0 then
    reaper.SNM_SetIntConfigVarEx(proj, "itemtimelock", tonumber(it))
    reaper.SNM_SetIntConfigVarEx(proj, "tempoenvtimelock", tonumber(te))
  end
  if type(p.lanes) == "table" and #p.lanes > 0 then
    if reaper.GetSetProjectInfo(proj, "RULER_LANE_COUNT", 0, false) ~= #p.lanes then reaper.GetSetProjectInfo(proj, "RULER_LANE_COUNT", #p.lanes, true) end
    for l, lane in ipairs(p.lanes) do
      if type(lane.name) == "string" then reaper.GetSetProjectInfo_String(proj, "RULER_LANE_NAME:" .. (l - 1), lane.name, true) end
      for _, k in ipairs(band.LANE_KEYS) do
        if tonumber(lane[k]) then reaper.GetSetProjectInfo(proj, "RULER_LANE_" .. k .. ":" .. (l - 1), tonumber(lane[k]), true) end
      end
    end
  end
end
band.LANE_KEYS = { "DEFAULT", "LOCKED", "COLOR", "TIMEBASE" }

-- Which marker here each wanted one is (review, 0.58.91: they were all deleted and added again, so their numbers changed on every
-- update, and a region's place in the render matrix went with it). Same kind, then position and name, then name (moved), then position
-- (renamed). -> { [wanted index] = index into have }. Pure.
function band.match_markers(have, want)
  local used, out = {}, {}
  local tests = {
    function(h, w) return math.abs(h.pos - w.pos) < 1e-9 and h.name == w.name end,
    function(h, w) return h.name == w.name and w.name ~= "" end,
    function(h, w) return math.abs(h.pos - w.pos) < 1e-9 end,
  }
  for _, same in ipairs(tests) do
    for wi, w in ipairs(want) do
      if not out[wi] then
        for hi, h in ipairs(have) do
          if not used[hi] and h.region == w.region and same(h, w) then out[wi], used[hi] = hi, true; break end
        end
      end
    end
  end
  return out, used
end
function band.apply_markers(proj, list)
  local have = {}
  for i = 0, reaper.CountProjectMarkers(proj) - 1 do
    local _, rgn, pos, rend, name, num, color = reaper.EnumProjectMarkers3(proj, i)
    if not band.is_local_mark(name) then have[#have + 1] = { region = rgn, pos = pos, ["end"] = rend, name = name, num = num, color = color } end
  end
  local match, used = band.match_markers(have, list)
  -- (each changed in place by its number, so it keeps it; the ones that went, deleted; the new ones, added with the next free number)
  for wi, m in ipairs(list) do
    local h = match[wi] and have[match[wi]]
    local c = band.color_in(m.color)
    if h and (math.abs(h.pos - m.pos) > 1e-9 or math.abs(h["end"] - m["end"]) > 1e-9 or h.name ~= m.name or h.color ~= c) then
      reaper.SetProjectMarker4(proj, h.num, m.region, m.pos, m["end"], m.name, c, m.name == "" and 1 or 0)
    end
  end
  for hi, h in ipairs(have) do if not used[hi] then reaper.DeleteProjectMarker(proj, h.num, h.region) end end
  for wi, m in ipairs(list) do if not match[wi] then reaper.AddProjectMarker2(proj, m.region, m.pos, m["end"], m.name, -1, band.color_in(m.color)) end end
  if not reaper.GetRegionOrMarker then return end
  -- each one back in its ruler lane (matched by kind, position and name: AddProjectMarker2 gives no handle)
  for i = 0, reaper.GetNumRegionsOrMarkers(proj) - 1 do
    local mk = reaper.GetRegionOrMarker(proj, i, "")
    local _, rgn, pos, _, name = reaper.EnumProjectMarkers3(proj, i)
    for _, m in ipairs(list) do
      if m.lane and m.region == rgn and math.abs(m.pos - pos) < 1e-9 and m.name == name then
        reaper.SetRegionOrMarkerInfo_Value(proj, mk, "I_LANENUMBER", m.lane)
        break
      end
    end
  end
end

-- ---- rendering ------------------------------------------------------------------------------

local RENDER_N = { "RENDER_TAILMS", "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_STARTPOS", "RENDER_ENDPOS", "RENDER_SRATE",
  "RENDER_CHANNELS", "RENDER_TAILFLAG", "RENDER_ADDTOPROJ", "RENDER_NORMALIZE", "RENDER_BRICKWALL" }
local RENDER_S = { "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT", "RENDER_FORMAT2" }
-- Sink configs read back from REAPER 7.83 and patched: FLAC 24-bit level 5 ("calf", int bits, int level);
-- Opus 64 kbps per channel ("SggO", float kbps/ch, then REAPER's defaults).
band.FLAC, band.OPUS = "Y2FsZhgAAAAFAAAA", "U2dnTwAAgEIACgAAAAAAAAA="

-- REAPER's render limiter: only what goes over is touched, and timing stays as it was (measured, a part 18 dB over: same length, same
-- first sample). FLAC can't hold anything over full scale, so a hot part was clipped for good in its print, on everyone's machine: 9 of
-- Sunset Drive's 287 prints sat at exactly 0 dB (2026-11-03). 64: limit on, and nothing else (a project's own normalizing stayed on for prints).
-- RENDER_BRICKWALL is a gain, not dB: 0.966 is -0.3 dB.
band.LIMIT = { RENDER_NORMALIZE = 64, RENDER_BRICKWALL = 0.966 }

-- Render the active project with temporary settings, then put the user's render settings back.
function band.render(n, s)
  local saved_n, saved_s = {}, {}
  for _, k in ipairs(RENDER_N) do saved_n[k] = reaper.GetSetProjectInfo(0, k, 0, false) end
  for _, k in ipairs(RENDER_S) do saved_s[k] = select(2, reaper.GetSetProjectInfo_String(0, k, "", false)) end
  for k, v in pairs(band.LIMIT) do reaper.GetSetProjectInfo(0, k, v, true) end
  for k, v in pairs(n) do reaper.GetSetProjectInfo(0, k, v, true) end
  for k, v in pairs(s) do reaper.GetSetProjectInfo_String(0, k, v, true) end
  local job = band.render_job -- (lib/bgrender.lua: a copy set up for this render, rendered by a second REAPER)
  if job then
    reaper.GetSetProjectInfo_String(0, "RENDER_FILE", job.dir, true)
    reaper.Main_SaveProjectEx(0, job.copy, 0) -- (0: a copy; the project keeps its own file)
  else
    -- (a print that clips left the render window open until someone clicked it: Mac, 0.42.2. 4: it closes regardless.)
    local keep = reaper.SNM_GetIntConfigVar and reaper.SNM_GetIntConfigVar("renderclosewhendone", -1)
    if keep and keep >= 0 then reaper.SNM_SetIntConfigVar("renderclosewhendone", 4) end
    reaper.Main_OnCommand(42230, 0) -- File: Render project, most recent settings, auto-close dialog
    if keep and keep >= 0 then reaper.SNM_SetIntConfigVar("renderclosewhendone", keep) end
  end
  for k, v in pairs(saved_n) do reaper.GetSetProjectInfo(0, k, v, true) end
  for k, v in pairs(saved_s) do reaper.GetSetProjectInfo_String(0, k, v, true) end
end


-- ---- items, tracks, P_EXT tags --------------------------------------------------------------

function band.track_ext(tr, key) return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. key, "", false)) end

-- A track's colour as the band has it (REAPER's native I_CUSTOMCOLOR): a person's colour may be showing in its place
-- here (lib/people.lua), with the band's waiting in P_EXT:band_colour. Everything that sends, saves or restores a
-- track's colour goes through these two.
function band.track_colour(tr)
  local held = band.track_ext(tr, "band_colour")
  if held ~= "" then return tonumber(held) or 0 end
  return reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR")
end
function band.set_track_colour(tr, c)
  if band.track_ext(tr, "band_colour") ~= "" then
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_colour", tostring(math.floor(c)), true)
  else
    reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", c)
  end
end
-- Show `c` (native) on a track here only, or (nil) the band's colour again.
function band.show_colour(tr, c)
  local held = band.track_ext(tr, "band_colour")
  if c then
    if held == "" then reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_colour", tostring(math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR"))), true) end
    if reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR") ~= c then reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", c) end
  elseif held ~= "" then
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_colour", "", true)
    reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", tonumber(held) or 0)
  end
end
function band.set_track_ext(tr, key, v) reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. key, v, true) end
function band.item_ext(it, key) return select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:" .. key, "", false)) end
function band.set_item_ext(it, key, v) reaper.GetSetMediaItemInfo_String(it, "P_EXT:" .. key, v, true) end
-- (a take lane can be empty: GetTake gives nil for it, and sharing a project with one stopped at "MediaItem_Take expected": James's Nostalgia, 0.58.81)
function band.take_ext(tk, key) return tk and select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_EXT:" .. key, "", false)) or "" end
function band.set_take_ext(tk, key, v) if tk then reaper.GetSetMediaItemTakeInfo_String(tk, "P_EXT:" .. key, v, true) end end

function band.add_item(track, path, pos, len)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len or (reaper.GetMediaSourceLength(src)))
  band.follow_tempo(item, take)
  reaper.UpdateItemInProject(item)
  return item, take
end

-- Band audio follows tempo changes the way the project says, but properly. REAPER's default timebase (beats:
-- position, length, rate) gives a whole item ONE playrate at a tempo change, so a song-long print or pad drifted
-- everywhere before the change (seen: up to 0.8 s). REAPER's own "auto-stretch at tempo changes" stretches each
-- part of the item by the tempo where it plays instead: unchanged before the change, stretched after it, the same
-- on every machine (same map). So in that timebase band audio gets auto-stretch; in "position only" or "time" the
-- project's setting is left alone. MIDI is left alone: its notes follow the beat, and its prints are re-rendered.
function band.follow_tempo(item, take)
  if not take or reaper.TakeIsMIDI(take) then return end
  local proj = reaper.GetItemProjectContext(item)
  local mode = reaper.GetMediaItemInfo_Value(item, "C_BEATATTACHMODE")
  if mode == -1 then mode = reaper.GetSetProjectInfo(proj, "PROJECT_TIMEBASE", 0, false) end
  if mode == 1 and reaper.GetMediaItemInfo_Value(item, "C_AUTOSTRETCH") ~= 1 then
    reaper.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", 1)
    reaper.SetMediaItemInfo_Value(item, "C_AUTOSTRETCH", 1)
  end
end


function band.find_track(proj, name, skip_stems)
  local lname = name:lower()
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, n = reaper.GetTrackName(tr)
    if n:lower() == lname and not (skip_stems and band.track_ext(tr, "band_stem") ~= "") then return tr end
  end
end

-- Append a track to the end of proj, which may be a background tab (the inbox runs on one).
-- Before 7.18 tracks can only be added to the active tab: return nil and the caller retries later.
function band.new_track(proj, name)
  local n = reaper.CountTracks(proj)
  if reaper.InsertTrackInProject then
    reaper.InsertTrackInProject(proj, n, 1)
  elseif proj == reaper.EnumProjects(-1) then
    reaper.InsertTrackAtIndex(n, true)
  else
    return nil
  end
  local tr = reaper.GetTrack(proj, n)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end


-- ---- stems ----------------------------------------------------------------------------------

local function best(dir, st)
  local full, prev = dir .. "/" .. st.file, st.preview and (dir .. "/" .. st.preview)
  if reaper.file_exists(full) then return full, "full" end
  if prev and reaper.file_exists(prev) then return prev, "preview" end
end

-- ---- takes ----------------------------------------------------------------------------------

function band.take_state(proj, id) return select(2, reaper.GetProjExtState(proj, band.TAKES, id)) end
function band.set_take_state(proj, id, v) reaper.SetProjExtState(proj, band.TAKES, id, v) end

-- A take's StudioSync id: received takes carry band_take, our own sent takes band_sent.
function band.take_id(tk)
  local id = band.take_ext(tk, "band_take")
  if id == "" then id = band.take_ext(tk, "band_sent") end
  return id ~= "" and id or nil
end

-- lower(id) -> { item, take } for every StudioSync take in proj. Lowercased because REAPER upper-cases
-- ProjExtState keys on save, so ids read back from state can differ in case from the takes' own.
function band.take_index(proj)
  local idx = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local id = band.take_id(tk)
      if id then idx[id:lower()] = { it, tk } end
    end
    local legacy = band.item_ext(it, "band_take") -- 0.2 tagged the item instead of the take
    if legacy ~= "" and not idx[legacy:lower()] then idx[legacy:lower()] = { it, reaper.GetActiveTake(it) } end
  end
  return idx
end

function band.find_take(proj, id)
  local hit = band.take_index(proj)[id:lower()]
  if hit then return hit[1], hit[2] end
end

-- "takes" mode: add the incoming take to the item on the matching track it overlaps most, so a
-- bandmate's passes stack as takes of one item. The item grows to fit; nothing already in it moves
-- (REAPER honours negative take start offsets: silence until the source begins).
-- The track a take for `name` belongs on. A wet print already carries the sender's FX, so it goes on a
-- StudioSync mirror track (no FX of ours, never processed twice): `name` itself when we have no track by
-- that name, else "name (studio)" beside our own. Dry takes go on our real track, through our FX once.
function band.dest_track(proj, name, wet)
  if not wet then return band.find_track(proj, name, true) or band.new_track(proj, name) end
  for _, n in ipairs({ name, name .. " (studio)", name .. " (band)" }) do
    local tr = band.find_track(proj, n, true)
    if tr and band.track_ext(tr, "band_mirror") ~= "" then return tr end
  end
  local tr = band.new_track(proj, band.find_track(proj, name, true) and (name .. " (studio)") or name)
  if tr then reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_mirror", "1", true) end
  return tr
end

-- Add take t as another take of item `best`, growing the item to fit without moving anything in it.
local function add_take_to(best, t, path)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local p = reaper.GetMediaItemInfo_Value(best, "D_POSITION")
  local e = p + reaper.GetMediaItemInfo_Value(best, "D_LENGTH")
  local np, ne = math.min(p, t.pos), math.max(e, t.pos + t.len)
  if np < p then -- grow left: shift every existing take's offset so its audio stays put
    for k = 0, reaper.CountTakes(best) - 1 do
      local tk = reaper.GetTake(best, k)
      if tk then reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS") - (p - np)) end
    end
    reaper.SetMediaItemInfo_Value(best, "D_POSITION", np)
  end
  reaper.SetMediaItemInfo_Value(best, "D_LENGTH", ne - np)
  reaper.SetMediaItemInfo_Value(best, "B_LOOPSRC", 0) -- a grown item must play silence, not repeat a shorter take
  local playing = reaper.GetActiveTake(best)
  local take = reaper.AddTakeToMediaItem(best)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", np - t.pos)
  if playing then reaper.SetActiveTake(playing) end -- never change what is already playing
  reaper.UpdateItemInProject(best)
  return best, take
end


-- "mirror" (the default): rebuild the sender's structure. Passes of one sender item (same group) stay
-- one item here, in the same lane, on a track with the same lane layout; so takes and lanes coexist
-- exactly as they do for the sender.
local function mirror(proj, t, path)
  if t.based_on then -- a shared sound: an extra take in the band item holding the original. Not in the owner's own
    -- item: that's on their real track, whose plug-ins would process the print a second time; there it goes on the
    -- FX-free mirror track like any print
    local it, tk = band.find_take(proj, t.based_on)
    if it and band.take_ext(tk, "band_take") ~= "" then return add_take_to(it, t, path) end
  end
  local tr = band.dest_track(proj, t.track, t.wet)
  if not tr then return nil end
  if t.lane then
    if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2 then
      reaper.SetMediaTrackInfo_Value(tr, "I_FREEMODE", 2)
      reaper.UpdateTimeline()
    end
    if reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") < t.lane + 1 then
      reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", t.lane + 1)
    end
  end
  if t.group then
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, i)
      if band.item_ext(it, "band_group") == t.group then return add_take_to(it, t, path) end
    end
  end
  local it, tk = band.add_item(tr, path, t.pos, t.len)
  if not it then return nil end
  if t.group then band.set_item_ext(it, "band_group", t.group) end
  if t.lane then
    reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", t.lane)
    if t.lane_name and t.lane_name ~= "" then reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. t.lane, t.lane_name, true) end
  end
  return it, tk
end

-- Where a take lands. mode: "lanes" (new fixed lane on the matching track), "takes" (see above),
-- "person" ("Takes - <user>" track) or "inbox" (one muted "StudioSync inbox" track).
local function target(proj, t, mode)
  if mode == "person" then
    local name = "Takes - " .. t.user
    return band.find_track(proj, name) or band.new_track(proj, name)
  elseif mode == "inbox" then
    local tr = band.find_track(proj, "StudioSync inbox")
    if not tr then
      tr = band.new_track(proj, "StudioSync inbox")
      if tr then reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1) end
    end
    return tr
  end
  local tr = band.dest_track(proj, t.track, t.wet)
  if not tr or reaper.CountTrackMediaItems(tr) == 0 then return tr end -- first take on an empty part just plays
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2 then
    reaper.SetMediaTrackInfo_Value(tr, "I_FREEMODE", 2)
    reaper.UpdateTimeline()
  end
  local lane = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES"))
  reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", lane + 1)
  return tr, lane
end

function band.base_offs(tk) return tonumber(band.take_ext(tk, "band_base_offs")) or 0 end


-- ---- MIDI copies ------------------------------------------------------------------------------
-- A MIDI take's notes travel with its print. Each receiver gets them as an editable MIDI item (tagged
-- band_midi = id) on a muted "<track> (MIDI)" track: edit the notes and everyone follows, or put your own
-- instrument on that track and "Print my MIDI" to replace the print everyone hears.

function band.find_midi(proj, id)
  local lid = id:lower()
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    if tk and band.take_ext(tk, "band_midi"):lower() == lid then return it, tk end
  end
end

-- Notes in drum map `from` (a take's), rewritten into the drum map set on track tr ("" or unset: as they are).
function band.to_track_map(root, buf, from, tr)
  local to = band.track_ext(tr, "band_drummap")
  if not root or (from or "") == "" or to == "" or from == to then return buf end
  local dm = require("drummap")
  return dm.translate(buf, dm.table(dm.load(root, from), dm.load(root, to)))
end

return band
