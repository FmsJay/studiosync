-- Who's online and what they're doing, from the receipts every Live sync writes (rooms/<room>/status).
-- Shared by the Status window and the control panel.
local band = require("band")
local sync = require("sync")
local status = {}

status.COLORS = { ["synced"] = { 0.35, 0.8, 0.45 }, ["syncing"] = { 0.95, 0.75, 0.25 },
  offline = { 0.55, 0.55, 0.55 } } -- ("no receipt" went with the take-based sync: nobody is listed without one. Round 3 review, 0.59.48)

function status.ago(sec)
  if sec == math.huge then return "never" elseif sec < 60 then return math.floor(sec) .. " s ago" end
  return math.floor(sec / 60) .. " min ago"
end

-- The newest change anyone posted (event file names carry their UTC stamp), as an ISO time ("" for none). Each name's stamp is worked out
-- once: names never change, and doing it for all 20,000 of a big room every 1.5 s was most of a panel refresh (0.59.14, review). Pure.
local iso_of, last_files, last_newest = {}, nil, "" -- file name -> its ISO stamp, or false; the listing last looked at and its answer
function status.newest_event(files)
  if files == last_files then return last_newest end -- (the same shared listing: band.listing)
  local newest = ""
  for _, f in ipairs(files) do
    local iso = iso_of[f]
    if iso == nil then
      local d, t = f:match("(%d%d%d%d%d%d%d%d)%-(%d%d%d%d%d%d)Z")
      iso = d and string.format("%s-%s-%sT%s:%s:%sZ", d:sub(1, 4), d:sub(5, 6), d:sub(7, 8), t:sub(1, 2), t:sub(3, 4), t:sub(5, 6)) or false
      iso_of[f] = iso -- shortcut: names trimmed away stay here (a few bytes each), fine for a session
    end
    if iso and iso > newest then newest = iso end
  end
  last_files, last_newest = files, newest
  return newest
end

-- { rows = { name, age, version, pending, state, ... }, my_age, newer, driver, print }
function status.gather(cfg, b, proj)
  local view = {}
  local s = band.read_json(band.session_path(cfg, b.song)) or {}
  local newest = band.VERSION
  local function note_version(v) if v and band.compare_versions(v, newest) > 0 then newest = v end end
  -- (no take counting: the take-based sync is gone, and a room with files from before 0.32 read "N take(s) still arriving" for everyone, for
  -- good. Round 2 review, 0.59.46)
  -- the newest change anyone posted (event file names carry their UTC stamp), as an ISO time
  local newest_event = status.newest_event(band.listing(sync.room_dir(cfg, b.song, b.room) .. "/events", ".json"))
  view.newest_event = newest_event
  local rows, seen = {}, require("removal").gone(cfg.root) -- (someone taken out of the group isn't listed)
  seen[cfg.user] = nil
  -- (each one's newer status over the direct link in its file's place: written every 30 s while the link reaches everyone. lib/presence.lua, James, rt)
  local dir, sts = sync.room_dir(cfg, b.song, b.room) .. "/status", {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local st = band.read_json(dir .. "/" .. f)
    if type(st) == "table" and type(st.user) == "string" then sts[#sts + 1] = st end
  end
  local presence = require("presence")
  for _, st in ipairs(presence.with_live(sts, presence.live(cfg, b.song, b.room))) do
    if not seen[st.user] then
      seen[st.user] = true
      if st.user ~= cfg.user then note_version(st.version) end
      if st.user == cfg.user then view.my_age, view.my_mirror, view.my_pending = band.age(st.time), st.mirror, st.pending or 0 else
        local a = band.age(st.time)
        -- a receipt older than the newest change can't vouch for it yet
        local behind = (st.pending or 0) > 0 or (st.said or st.time or "") < newest_event -- (said: a heartbeat's time vouches for nothing)
        rows[#rows + 1] = { name = st.user, age = a, version = st.version or "?", pending = st.pending or 0, hold = st.hold,
          armed = st.armed, side = st.side, playing = st.playing, recording = st.recording, mirror = st.mirror,
          behind = behind, reaper = st.reaper, last_track = st.last_track, last_at = tonumber(st.last_at), lets = st.lets, live = st.live, call = st.call == true or nil, -- (lets: whoever produces them may start and stop their transport)
          state = a > 60 and "offline" or (not behind and "synced" or "syncing") }
      end
    end
  end
  table.sort(rows, function(x, y) return x.name < y.name end)
  view.rows = rows
  view.newer = band.compare_versions(newest, band.VERSION) > 0 and newest or nil
  view.driver = sync.driver(cfg, b.song, b.room, s)
  view.print = s.print or "wet"
  view.session = s
  return view
end

-- What stands between now and a clean handover: { problems = {...}, offline = {...} }. Offline people
-- can't be waited for; they catch up when they're back.
function status.handover_check(cfg, b, proj)
  local v = status.gather(cfg, b, proj)
  local out, offline = {}, {}
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(proj)))
  if not beat or reaper.time_precise() - beat > 30 then out[#out + 1] = "your Live sync isn't running" end -- a long reprint holds its tick
  local mine = sync.pending_events(proj, cfg, b.song, b.room)
  if mine > 0 then out[#out + 1] = string.format("you: %d change(s) from the others not applied yet", mine) end
  if select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= "" then out[#out + 1] = "you: Hold sync is on" end
  for _, r in ipairs(v.rows) do
    if r.state == "offline" then offline[#offline + 1] = r.name
    elseif r.hold then out[#out + 1] = r.name .. " is holding sync (their changes haven't gone out)"
    elseif r.behind then out[#out + 1] = r.name .. ": still applying the latest changes" end
  end
  return { problems = out, offline = offline }
end

return status
