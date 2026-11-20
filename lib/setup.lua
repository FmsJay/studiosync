-- Setting a project up for the band: what's in place, what's missing, and the fixes that need no human
-- (a loopback cable, a sign-in or a share can't be clicked from a script). The panel's Set up list and its
-- "Set up everything I can" button are a view over this.
local band = require("band")
local live = require("live")
local services = require("services")
local sonobus = require("sonobus")
local setup = {}

function setup.live_file(cfg, b) return band.song_dir(cfg, b.song) .. "/live.json" end

-- The band's SonoBus group and password, made by whoever needs it first: <shared folder>/sonobus.json.
function setup.sonobus_group(cfg)
  local secret = require("groups").sonobus_secret(cfg.root)
  if secret then return live.sonobus_group({}, band.info(cfg.root).id, secret) end -- (from the studio's secret: nothing to keep)
  local file = cfg.root .. "/sonobus.json"
  local data = band.read_json(file) or {}
  local had = data.group
  local group, pw = live.sonobus_group(data, band.info(cfg.root).id)
  if not had then band.write_json(file, data) end
  return group, pw
end

-- SonoBus on Real time mode's own track (lib/live.lua rt_track), set to join the band's group by itself: StudioSync
-- writes the group, password and your name into its saved state (lib/sonobus.lua), with "Reconnect Last" on, so
-- SonoBus joins whenever it's on. It stays there once added, offline while not in use, so it never joins (or
-- streams anything) until someone connects. With open: brings it online, which joins. Returns the join link (for
-- SonoBus's own app), the track and the FX index; or nil + why.
function setup.sonobus(cfg, b, proj, open)
  local group, pw = setup.sonobus_group(cfg)
  local m, i = live.fx(proj, false, live.SONOBUS)
  if m and m == reaper.GetMasterTrack(proj) then -- the old place (it sent the whole mix): moves to Real time's own track
    reaper.TrackFX_Delete(m, i)
    m = nil
  end
  if not m then
    m, i = live.fx(proj, true, live.SONOBUS)
    if not m then
      return nil, "SonoBus (its VST3) isn't installed here (sonobus.net, free; on a Mac, keep VST3 ticked in its installer), or REAPER hasn't seen it yet: REAPER finds new plug-ins when it starts, so restart REAPER after installing it."
    end
  end
  if open then -- one SonoBus per machine in the group: another tab's still in it was a second you ("Laptop 4"), and
    -- the group then renamed this one "Laptop 5" (laptop, 2026-10-31). Theirs go offline while this one's on.
    for k = 0, 512 do
      local p = reaper.EnumProjects(k)
      if not p then break end
      local om, oi
      if p ~= proj then om, oi = live.fx(p, false, live.SONOBUS) end
      if om and not reaper.TrackFX_GetOffline(om, oi) then
        reaper.TrackFX_SetOffline(om, oi, true)
        -- (and what it was on for, so that tab doesn't show a call or Real time mode that's gone, or follow at 0 bars: review, 0.59.8)
        if live.rt_flag(p) then reaper.SetProjExtState(p, band.SECTION, "rt", "0"); reaper.SetProjExtState(p, band.SECTION, "side", "") end
        reaper.SetProjExtState(p, band.SECTION, "call", ""); reaper.SetProjExtState(p, band.SECTION, "rt talk only", "")
        if select(2, reaper.GetProjExtState(p, band.SECTION, "hear their time")) == "1" then
          reaper.SetProjExtState(p, band.SECTION, "hear their time", ""); require("hear").set_delay(p, 0)
        end
        band.log("live audio moved to the project in front: the other tab's Real time mode and call are off")
      end
    end
  end
  local was_offline = reaper.TrackFX_GetOffline(m, i)
  reaper.TrackFX_SetOffline(m, i, false) -- its state can only be read and written while it's loaded
  local _, chunk = reaper.TrackFX_GetNamedConfigParm(m, i, "vst_chunk")
  local hear = require("hear")
  local outs = hear.order(hear.bandmates(cfg, b), cfg.user) -- each bandmate on an output pair of their own (who you hear)
  local new = chunk
  sonobus.use_buffer(reaper.GetExtState(band.SECTION, "rt buffer"))
  sonobus.use_quality(reaper.GetExtState(band.SECTION, "rt quality"))
  local host, port = require("groups").sonobus_server(cfg.root) -- (the studio's own, over Tailscale, or SonoBus's public one)
  if not sonobus.is_set_up(chunk, group, cfg.user, host) then
    local why
    new, why = sonobus.join_state(chunk, { user = cfg.user, group = group, password = pw, host = host, port = port })
    if not new then return nil, "Couldn't set SonoBus up (" .. why .. "): join by hand with its Connect button." end
  end
  for name, start in pairs(outs) do
    if sonobus.output_of(new, name) ~= start then new = sonobus.set_outputs(new, outs) or new; break end
  end
  if not sonobus.buffer_ok(new, sonobus.BUFFER.defnetbuf * 1000, sonobus.BUFFER.defnetauto) then
    new = sonobus.set_buffer(new, sonobus.BUFFER.defnetbuf * 1000, sonobus.BUFFER.defnetauto) or new
  end
  if not sonobus.quality_ok(new, sonobus.SEND) then new = sonobus.set_quality(new, sonobus.SEND) or new end
  -- (the talk mic as a group of its own, and each bandmate's talk to the call's pair: the call apart from the playing. 0.59.27)
  if not sonobus.input_split_ok(new) then new = sonobus.set_input_split(new) or new end
  if not sonobus.talk_ok(new, outs, hear.TALK) then new = sonobus.set_talk(new, outs, hear.TALK) or new end
  if new ~= chunk then
    reaper.TrackFX_SetNamedConfigParm(m, i, "vst_chunk", new)
    reaper.TrackFX_SetOffline(m, i, true) -- reloading it with that state is what makes it join
    was_offline = true
  end
  hear.set_pairs(proj, outs)
  hear.route(proj, m)
  if open and was_offline then -- (when it went online: Live sync checks it joined after that; lib/live.lua join_check)
    reaper.SetProjExtState(proj, band.SECTION, "sonobus online", tostring(os.time()))
  end
  reaper.TrackFX_SetOffline(m, i, not open)
  return live.sonobus_link(group, pw, host and (host .. ":" .. port)), m, i
end

local function has_subdir(path, name)
  for _, d in ipairs(band.subdirs(path)) do if d == name then return true end end
  return false
end

-- What's in place. Slow-ish (tasklist): call every few seconds, not every frame.
function setup.check(cfg, b, proj)
  local data = band.read_json(setup.live_file(cfg, b)) or {}
  local st = {}
  st.audio = reaper.Audio_IsRunning() == 1 -- a closed device (driver missing, interface unplugged) makes Live and recording silently do nothing
  local syncthing = has_subdir(cfg.root, ".stfolder") -- a cloud-drive root needs nothing
  st.folder = not syncthing or services.running("syncthing")
  if syncthing and st.folder then st.peers, st.devices = services.syncthing_peers() end
  st.connected = not syncthing or (st.peers or 0) > 0
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(proj)))
  st.sync = beat ~= nil and reaper.time_precise() - beat < 5
  st.sonobus = live.fx(proj, false, live.SONOBUS) ~= nil
  st.server = (data.server or "") ~= ""
  st.hosting = (data.server or "") ~= "" and data.by == cfg.user
  st.ninjam = not st.hosting or services.running("ninjamsrv")
  return st
end

-- Every fix that needs no human. start_sync starts Live sync (an action, so the panel passes how to run it).
-- Returns what it did, as short notes.
function setup.all(cfg, b, proj, st, start_sync, play_along)
  local notes = {}
  if not st.folder then
    local ok, why = services.ensure_syncthing()
    notes[#notes + 1] = ok and "Syncthing started" or ("Syncthing: " .. why)
  end
  if not st.sync and not require("rooms").is_copy(proj, cfg, b) then -- (a backup's edits would go out to everyone: lib/rooms.lua)
    reaper.DeleteExtState(band.SECTION, "stop " .. tostring(proj), false)
    start_sync()
    notes[#notes + 1] = "Live sync started"
  end
  if play_along and (st.hosting or not st.server) then
    local server, why = services.ninjam_for(cfg, setup.live_file(cfg, b), true)
    notes[#notes + 1] = server and ("NINJAM server: " .. server) or why
  end
  if not st.sonobus and not live.builtin_audio(cfg.root) then -- (the studio's own live audio carries the sound: no SonoBus. rt-audit §1)
    local link, why = setup.sonobus(cfg, b, proj, false)
    notes[#notes + 1] = link and "SonoBus added (off until you switch on Real time mode)" or why
  end
  return notes
end

return setup
