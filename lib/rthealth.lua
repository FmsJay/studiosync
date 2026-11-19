-- Settings > Health: Syncthing's own view of each studio folder on this computer, and free disk space here and on the others (James, rt).
-- "Why hasn't the Mac got it?" gets an answer on screen: the folder's state, what this computer still needs, the folder's errors in plain
-- words, who's connected and each bandmate's completion. It all comes from Syncthing's REST API in the background (services.st_bg), so REAPER
-- never waits on it, and the rows are built again at most every 10 s (the panel asks every frame).
local band = require("band")
local R = {}

R.LOW_MB, R.VERY_LOW_MB = 5 * 1024, 1024 -- yellow under ~5 GB, red under ~1 GB
R.STUCK_SECS = 600 -- a connected bandmate whose completion hasn't moved in 10 minutes is stuck, not slow
R.PEER_FRESH = 600 -- a bandmate's free space older than this is from a session long gone: not worth a row
R.MB_PER_MIN = 48000 * 3 * 2 * 60 / 1048576 -- 24-bit stereo at 48 kHz, one track: ~16.5 MB a minute

-- Pure: what fits in `mb`, in words ("about 48 minutes of 24-bit stereo at 48 kHz").
function R.fits_words(mb)
  local mins = math.floor(mb / R.MB_PER_MIN)
  local t = mins < 1 and "less than a minute" or mins < 120 and ("about " .. mins .. (mins == 1 and " minute" or " minutes"))
    or ("about " .. math.floor(mins / 60) .. " hours")
  return t .. " of 24-bit stereo at 48 kHz"
end
-- Pure: "800 MB", "4.2 GB".
function R.size_words(mb)
  if mb >= 1024 then return (string.format("%.1f GB", mb / 1024):gsub("%.0 GB$", " GB")) end
  return string.format("%d MB", math.floor(mb))
end

-- Pure: this computer's disk row (Health's { id, ok, level, ok words, problem words }), or nil when REAPER couldn't tell.
function R.disk_row(free_mb)
  if type(free_mb) ~= "number" or free_mb < 0 then return nil end
  local words = R.size_words(free_mb) .. " free where takes are recorded (" .. R.fits_words(free_mb) .. ")"
  return { "disk", free_mb >= R.LOW_MB, free_mb < R.VERY_LOW_MB and "red" or "yellow", "Disk space: " .. words,
    "This computer is low on disk: " .. words .. ". A take stops when the disk fills, and the others' takes can't land here: " ..
      "empty the Recycle Bin or Trash, or move old projects off this drive." }
end

-- Pure: a row for each bandmate low on disk, from their status files (presence.all: free_mb is in each, lib/sync.lua write_status). `now`:
-- os.date("!*t"), as band.age takes it. Each row's .short is the line the recorder is told at record start.
function R.peer_disk_rows(statuses, me, now)
  local out = {}
  for _, st in ipairs(statuses or {}) do
    local mb = type(st) == "table" and tonumber(st.free_mb)
    if mb and mb >= 0 and mb < R.LOW_MB and st.user ~= me and type(st.user) == "string" and band.age(st.time, now) < R.PEER_FRESH then
      local short = string.format("%s is low on disk (%s)", st.user, R.size_words(mb))
      out[#out + 1] = { "disk " .. st.user, false, "yellow", "", short .. ": " .. R.fits_words(mb) .. " fits there, so takes from the others may " ..
        "not land. Tell them, so they free some space.", short = short }
    end
  end
  table.sort(out, function(a, z) return a[1] < z[1] end)
  return out
end

-- Syncthing's error texts in plain words (the first match wins; anything else is shown as Syncthing says it, cut short).
R.PLAIN = {
  { "no space left", "the disk is full" }, { "insufficient space", "the disk is full" }, { "not enough space", "the disk is full" },
  { "permission denied", "Syncthing isn't allowed to write there" }, { "access is denied", "Syncthing isn't allowed to write there" },
  { "used by another process", "another program has it open" },
  { "folder marker missing", "the folder's .stfolder marker is gone (was the folder moved, or its drive unplugged?)" },
  { "folder path missing", "the folder isn't there (was it moved, or its drive unplugged?)" },
  { "no connected device has the required version", "nobody online has this version of it yet" },
  { "peers who had this file went away", "the computer that had it went offline" },
  { "modified but not rescanned", "it changed while it was being copied: Syncthing tries again" },
  { "file name too long", "its name is too long for this computer" }, { "invalid", "its name isn't allowed on this computer" },
}
function R.plain(err)
  local low = tostring(err or ""):lower()
  for _, p in ipairs(R.PLAIN) do if low:find(p[1], 1, true) then return p[2] end end
  local s = tostring(err or "")
  return #s > 80 and (s:sub(1, 77) .. "...") or s
end

R.STATE = { idle = "up to date here", scanning = "looking for changes", ["scan-waiting"] = "waiting to look for changes", syncing = "syncing",
  ["sync-preparing"] = "getting ready to sync", ["sync-waiting"] = "waiting to sync", cleaning = "tidying up", error = "stopped by an error" }

-- Pure: how long a bandmate's completion has stood still. `track` keeps { pct, since } under `key`. -> seconds
function R.still_for(track, key, pct, now)
  local t = track[key]
  if not t or t.pct ~= pct or pct >= 100 then t = { pct = pct, since = now }; track[key] = t end
  return now - t.since
end

-- Pure: one studio folder's row, or nil before Syncthing has answered. st: /rest/db/status; errs: /rest/folder/errors; devs: the folder's
-- other computers { { name, connected, comp = /rest/db/completion or nil, still = seconds it hasn't moved } }.
-- Green: idle, nothing needed here, no errors, every connected bandmate complete. Grey (fine, just said): still syncing. Yellow: an error, or
-- a connected bandmate stuck.
function R.folder_row(name, id, st, errs, devs)
  if type(st) ~= "table" or type(st.state) ~= "string" then return nil end
  local parts, bad = { "Syncthing, " .. name .. ": " .. (R.STATE[st.state] or st.state) }, st.state == "error"
  local need = (tonumber(st.needFiles) or 0) + (tonumber(st.needDeletes) or 0)
  if need > 0 then parts[1] = parts[1] .. string.format(", still needs %d file%s (%s)", need, need == 1 and "" or "s", R.size_words((tonumber(st.needBytes) or 0) / 1048576)) end
  local on, behind, waiting = 0, {}, false
  for _, d in ipairs(devs or {}) do
    if d.connected then on = on + 1 end
    local c = type(d.comp) == "table" and d.comp
    if c and c.remoteState ~= "notSharing" then
      local pct = tonumber(c.completion) or 0
      if pct < 100 then
        local left, stuck = tonumber(c.needItems) or 0, d.connected and (d.still or 0) >= R.STUCK_SECS
        behind[#behind + 1] = string.format("%s: %d%% (%d file%s to go%s)", d.name, math.floor(pct), left, left == 1 and "" or "s",
          c.remoteState == "paused" and ", paused" or not d.connected and ", offline" or stuck and (", no progress for " .. math.floor(d.still / 60) .. " min") or "")
        bad = bad or stuck
        waiting = waiting or d.connected
      end
    end
  end
  if devs and #devs > 0 then parts[#parts + 1] = string.format("%d of %d other computer%s connected", on, #devs, #devs == 1 and "" or "s") end
  if #behind > 0 then parts[#parts + 1] = table.concat(behind, ", ") elseif on > 0 then parts[#parts + 1] = "everyone connected has everything" end
  local list = type(errs) == "table" and type(errs.errors) == "table" and errs.errors or {}
  local said = {}
  if type(st.error) == "string" and st.error ~= "" then said[#said + 1] = R.plain(st.error) end
  for i = 1, math.min(2, #list) do
    local e = list[i]
    if type(e) == "table" then said[#said + 1] = (tostring(e.path or ""):match("([^/\\]+)$") or "a file") .. ": " .. R.plain(e.error) end
  end
  local more = math.max(#list, tonumber(st.pullErrors) or 0) - math.min(2, #list)
  if more > 0 then said[#said + 1] = more .. " more" end
  if #said > 0 then bad = true; parts[#parts + 1] = "problems: " .. table.concat(said, "; ") end
  local text = table.concat(parts, "; ") .. "."
  local fine = not bad and st.state == "idle" and need == 0 and not waiting
  return { "syncthing " .. id, fine, bad and "yellow" or "grey", text, text }
end

-- Pure: durations in seconds -> { n, med, p95, max } in ms (nearest rank), or nil when there are none. Live sync's tick timings, for
-- tests/reaper/rt_perf.lua. (James, rt: an efficiency pass, measured before and after on each computer)
function R.summary(xs)
  local s = {}
  for i, x in ipairs(xs or {}) do s[i] = x end
  local n = #s
  if n == 0 then return nil end
  table.sort(s)
  local function ms(p) return math.floor(s[math.max(1, math.ceil(p * n))] * 10000 + 0.5) / 10 end
  return { n = n, med = ms(0.5), p95 = ms(0.95), max = ms(1) }
end

-- ---- the parts that touch REAPER and Syncthing ----
local S = { at = -math.huge, rows = {}, still = {} }

-- Free space where this project's takes are recorded, in MB (REAPER's own GetFreeDiskSpaceForRecordPath: every platform, no shell, no
-- wait). The record path is the song's folder in the studio unless someone set another. Held 10 s. nil when REAPER can't tell.
function R.free_mb(proj)
  local now = reaper.time_precise()
  if S.free_for ~= proj or not S.free_at or now - S.free_at > 10 then
    local ok, mb = pcall(reaper.GetFreeDiskSpaceForRecordPath, proj or 0, 0)
    S.free_at, S.free_for, S.free = now, proj, ok and type(mb) == "number" and mb >= 0 and mb or nil
  end
  return S.free
end

-- Record start (Live sync): a line, never a box, when this computer or a bandmate here is low.
function R.record_check(proj, cfg, b)
  S.free_at = nil -- (asked fresh: a take is about to need it)
  local mb = R.free_mb(proj)
  if mb and mb < R.LOW_MB then band.log("recording with " .. R.size_words(mb) .. " free on this computer: " .. R.fits_words(mb) .. " fits") end
  local ok, all = pcall(require("presence").all, cfg, b.song, b.room)
  for _, r in ipairs(R.peer_disk_rows(ok and all or {}, cfg.user, os.date("!*t"))) do band.log(r.short .. ": your take may not land there") end
end

-- Health's rows: one per studio folder Syncthing holds here, this computer's disk, and each bandmate low on disk.
function R.rows(cfg, b, proj)
  local now = reaper.time_precise()
  if now - S.at < 10 then return S.rows end
  S.at = now
  local services = require("services")
  local function get(name, path, every) return band.json_decode(services.st_bg(name, path, every) or "") end
  local conns = get("syncthing-connections", "/rest/system/connections", 20) -- (the same run as services.syncthing_peers_now: no second curl)
  conns = type(conns) == "table" and type(conns.connections) == "table" and conns.connections or nil
  local names, me, rows = {}, services.my_device_id(), {}
  local devs_cfg = get("st-devices", "/rest/config/devices", 300)
  for _, d in ipairs(type(devs_cfg) == "table" and devs_cfg or {}) do if type(d) == "table" and d.deviceID then names[d.deviceID] = tostring(d.name or "") end end
  for _, x in ipairs(band.bands()) do
    local id = tostring(x.id)
    if not x.waiting and id:match("^[%w%-]+$") then
      local key = id:gsub("%-", "_")
      local fc = get("st-folder-" .. key, "/rest/config/folders/" .. id, 60)
      local devs = {}
      for _, d in ipairs(type(fc) == "table" and type(fc.devices) == "table" and fc.devices or {}) do
        local did = type(d) == "table" and d.deviceID
        -- (my own ID is in the folder's list too; before Syncthing has said which is mine, only computers it connects to count)
        if services.is_device_id(did) and did ~= me and (me or (conns and conns[did])) then
          local dev = { name = (names[did] or "") ~= "" and names[did] or did:sub(1, 7), connected = conns and type(conns[did]) == "table" and conns[did].connected == true }
          if x.root == cfg.root then -- (bandmates' completion for the studio in use only: it's a call per computer)
            local c = get("st-comp-" .. key .. "-" .. did:sub(1, 7), "/rest/db/completion?folder=" .. id .. "&device=" .. did, 30)
            if type(c) == "table" then dev.comp, dev.still = c, R.still_for(S.still, id .. did, tonumber(c.completion) or 0, now) end
          end
          devs[#devs + 1] = dev
        end
      end
      local row = R.folder_row(x.name or id, id, get("st-status-" .. key, "/rest/db/status?folder=" .. id, 30), get("st-errors-" .. key, "/rest/folder/errors?folder=" .. id, 30), devs)
      if row then rows[#rows + 1] = row end
    end
  end
  local disk = R.disk_row(R.free_mb(proj))
  if disk then rows[#rows + 1] = disk end
  if b then
    local ok, all = pcall(require("presence").all, cfg, b.song, b.room)
    for _, r in ipairs(R.peer_disk_rows(ok and all or {}, cfg.user, os.date("!*t"))) do rows[#rows + 1] = r end
  end
  S.rows = rows
  return rows
end

return R
