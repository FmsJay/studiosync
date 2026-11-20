-- A fake REAPER serving a tools/bigproject.lua model, for timing StudioSync's code at a big project's size offline
-- (tests/test_0_60_rt_bigproj.lua). Tracks, items and takes are the model's own tables; chunks are made from the model (tools/bigproject.lua)
-- and kept until something changes them, as REAPER's own would read the same. Every call is counted (F.calls), and the bytes the chunk
-- calls hand over (F.chunk_bytes): REAPER's real cost is in those, which a fake can't time.
--   local F = require("bigreaper").new(model); reaper = F.reaper
local G = require("bigproject")
local B = {}

function B.new(m)
  G.wire_receives(m)
  local F = { m = m, calls = {}, chunk_bytes = 0, cc = 1, clock = 1000, playing = 0, missing = {} }
  local proj = { name = "BIGPROJ" }
  F.proj = proj
  local tracks = m.tracks
  local index_of = {}
  local master = { name = "MASTER", guid = "{MASTER}", fx = {}, items = {}, volenv = {}, ext = {}, sends = {}, i = 0, depth = 0, color = 0, vol = 1, pan = 0, mute = 0 }
  F.master = master
  local items, take_of = {}, {}
  local function reindex()
    index_of, items = {}, {}
    local stack = {}
    for i, t in ipairs(tracks) do
      index_of[t] = i
      t.ext = t.ext or {}
      t.parent = stack[#stack]
      if t.depth == 1 then stack[#stack + 1] = t elseif t.depth < 0 then for _ = 1, -t.depth do stack[#stack] = nil end end
      for _, it in ipairs(t.items) do
        it.track, it.ext = t, it.ext or {}
        items[#items + 1] = it
        local tk = take_of[it] or { item = it, ext = {} }
        take_of[it] = tk
      end
    end
  end
  reindex()
  F.reindex = reindex
  local function changed(t) F.cc = F.cc + 1; if t then t.chunk = nil end end
  F.changed = changed
  -- ProjExtState: per section, keys in the order first set (EnumProjExtState walks them)
  local pext = {}
  local function sec(s)
    local x = pext[s]
    if not x then x = { v = {}, keys = {} }; pext[s] = x end
    return x
  end
  F.pext = pext
  local gext = {}
  local function item_chunk(_, it)
    local c = it.raw or it.chunk
    if not c then c = G.item_chunk(m, it); it.chunk = c end
    return c
  end
  local function track_chunk(t)
    if t.raw then return t.raw end
    if not t.chunk then t.chunk = G.track_chunk(m, t, false, item_chunk) end
    return t.chunk
  end
  F.track_chunk = track_chunk
  local function env_list(t)
    if not t.envs then
      t.envs = { { tr = t, tag = "VOLENV2", pts = t.volenv } }
      if t.panenv then t.envs[#t.envs + 1] = { tr = t, tag = "PANENV2", pts = t.panenv } end
      if t.parmenv then t.envs[#t.envs + 1] = { tr = t, tag = "PARMENV", pts = t.parmenv } end
    end
    return t.envs
  end
  local function notes_of(it)
    if not it.notes then
      local list, on = {}, {}
      for _, e in ipairs(it.events or {}) do
        if e[2] == 0x90 then on[e[3]] = on[e[3]] or {}; table.insert(on[e[3]], { e[1], e[4] })
        elseif e[2] == 0x80 and on[e[3]] and #on[e[3]] > 0 then
          local s = table.remove(on[e[3]], 1)
          list[#list + 1] = { s[1], e[1], e[3], s[2] }
        end
      end
      table.sort(list, function(a, b) return a[1] < b[1] end)
      local ccs = {}
      for _, e in ipairs(it.events or {}) do if e[2] == 0xB0 then ccs[#ccs + 1] = e end end
      it.notes, it.ccs = list, ccs
    end
    return it.notes, it.ccs
  end
  local TV = { D_VOL = "vol", D_PAN = "pan", B_MUTE = "mute", I_FOLDERDEPTH = "depth" }
  local R = {
    -- (F.realtime: the clock moves on with the processor's time too, so code that spends a time budget a tick sees it spent)
    time_precise = function() return F.realtime and F.clock + os.clock() or F.clock end,
    GetOS = function() return "Win64" end, GetAppVersion = function() return "7.0/x64" end,
    GetResourcePath = function() return "C:/fake/res" end, GetExePath = function() return "C:/fake" end,
    EnumProjects = function(i) if i == 0 or i == -1 then return proj, "C:/fake/Big/Big.rpp" end end,
    ValidatePtr2 = function() return true end, ValidatePtr = function() return true end,
    GetPlayStateEx = function() return F.playing end, GetPlayState = function() return F.playing end,
    GetProjectStateChangeCount = function() return F.cc end,
    GetProjectLength = function() return m.opts.length end,
    GetCursorPositionEx = function() return 0 end, GetPlayPositionEx = function() return 0 end, Master_GetPlayRate = function() return 1 end,
    GetSet_ArrangeView2 = function() return 0, 60 end, GetSetProjectGrid = function() return 0, 0.25 end,
    GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
    SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
    DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
    HasExtState = function(s, k) return gext[s .. "\0" .. k] ~= nil end,
    GetProjExtState = function(_, s, k) local v = sec(s).v[k] or ""; return v ~= "" and 1 or 0, v end,
    SetProjExtState = function(_, s, k, v)
      local x = sec(s)
      if x.v[k] == nil then x.keys[#x.keys + 1] = k end
      x.v[k] = v
      return 1
    end,
    EnumProjExtState = function(_, s, i)
      local x = pext[s]
      if not x then return false end
      while true do
        local k = x.keys[i + 1]
        if not k then return false end
        if x.v[k] ~= nil and x.v[k] ~= "" then return true, k, x.v[k] end
        i = i + 1 -- (shortcut: a cleared key is skipped, so later indices shift as REAPER's do after a delete)
      end
    end,
    CountTracks = function() return #tracks end,
    GetTrack = function(_, i) return tracks[i + 1] end,
    GetMasterTrack = function() return master end,
    GetParentTrack = function(t) return t.parent end,
    GetTrackName = function(t) return true, t.name end,
    GetTrackGUID = function(t) return t.guid end,
    GetMediaTrackInfo_Value = function(t, k)
      local f = TV[k]
      if f then return t[f] or 0 end
      if k == "IP_TRACKNUMBER" then return t == master and -1 or index_of[t] end
      if k == "I_CUSTOMCOLOR" then return t.color end
      if k == "I_NCHAN" then return 2 end
      local v = t.vals and t.vals[k]
      if v == nil and (k == "B_SHOWINTCP" or k == "B_SHOWINMIXER" or k == "B_MAINSEND") then return 1 end
      return v or 0
    end,
    SetMediaTrackInfo_Value = function(t, k, v)
      local f = TV[k]
      if f then t[f] = v elseif k == "I_CUSTOMCOLOR" then t.color = v else t.vals = t.vals or {}; t.vals[k] = v end
      changed(t)
      return true
    end,
    GetSetMediaTrackInfo_String = function(t, k, v, set)
      if k == "P_NAME" then if set then t.name = v; changed(t) end; return true, t.name end
      if k == "GUID" then return true, t.guid end
      if k:sub(1, 6) == "P_EXT:" then
        local key = k:sub(7)
        if set then t.ext[key] = v ~= "" and v or nil; changed(t) end
        return true, t.ext[key] or ""
      end
      return true, ""
    end,
    GetTrackStateChunk = function(t)
      local c = track_chunk(t)
      F.chunk_bytes = F.chunk_bytes + #c
      return true, c
    end,
    SetTrackStateChunk = function(t, c) t.raw = c; changed(t); return true end,
    GetTrackNumSends = function(t, cat)
      if cat == 0 then return #t.sends end
      if cat == -1 then return t.recv and #t.recv or 0 end
      return 0
    end,
    GetTrackSendInfo_Value = function(t, cat, i, k)
      if k == "D_VOL" then return 1 end
      if k == "P_DESTTRACK" then return cat == 0 and tracks[t.sends[i + 1]] or t end
      if k == "P_SRCTRACK" then return cat == -1 and tracks[t.recv[i + 1]] or t end
      return 0
    end,
    TrackFX_GetCount = function(t) return #t.fx end,
    TrackFX_GetInstrument = function(t) return t.midi and 0 or -1 end,
    TakeFX_GetCount = function() return 0 end, TakeFX_GetOpen = function() return false end, TakeFX_GetFXName = function() return false, "" end,
    TrackFX_GetRecCount = function() return 0 end,
    TrackFX_GetFXName = function(t, i) local fx = t.fx[i + 1]; return fx ~= nil, fx and (fx.kind == "JS" and ("JS: " .. fx.name) or fx.name) or "" end,
    TrackFX_GetFXGUID = function(t, i) local fx = t.fx[i + 1]; return fx and fx.guid end,
    TrackFX_GetOpen = function() return false end,
    TrackFX_GetChainVisible = function() return -1 end,
    TrackFX_GetEnabled = function(t, i) local fx = t.fx[i + 1]; return fx and fx.bypass == 0 end,
    TrackFX_GetNumParams = function() return 8 end,
    TrackFX_GetParamNormalized = function() return 0.5 end,
    TrackFX_GetParam = function() return 0.5, 0, 1 end,
    TrackFX_GetNamedConfigParm = function() return false, "" end,
    TrackFX_GetPreset = function() return false, "" end,
    GetFXEnvelope = function() return nil end,
    CountTrackEnvelopes = function(t) return #env_list(t) end,
    GetTrackEnvelope = function(t, i) return env_list(t)[i + 1] end,
    GetTrackEnvelopeByName = function(t, n) for _, e in ipairs(env_list(t)) do if (n == "Volume" and e.tag == "VOLENV2") or (n == "Pan" and e.tag == "PANENV2") then return e end end end,
    GetTrackEnvelopeByChunkName = function(t, n) for _, e in ipairs(env_list(t)) do if e.tag == n then return e end end end,
    GetEnvelopeName = function(e) return true, e.tag == "VOLENV2" and "Volume" or e.tag == "PANENV2" and "Pan" or "Param" end,
    Envelope_GetParentTrack = function(e) return e.tr end,
    CountAutomationItems = function() return 0 end,
    CountEnvelopePointsEx = function(e) return #e.pts end, CountEnvelopePoints = function(e) return #e.pts end,
    GetEnvelopePointEx = function(e, _, i) local p = e.pts[i + 1]; if p then return true, p[1], p[2], p[3], 0, false end; return false end,
    GetEnvelopeScalingMode = function() return 0 end,
    ScaleToEnvelopeMode = function(_, v) return v end, ScaleFromEnvelopeMode = function(_, v) return v end,
    GetEnvelopeStateChunk = function(e)
      local out = { "<" .. e.tag }
      for _, p in ipairs(e.pts) do out[#out + 1] = string.format("PT %.10g %.10g %d", p[1], p[2], p[3]) end
      local c = table.concat(out, "\n") .. "\n>\n"
      F.chunk_bytes = F.chunk_bytes + #c
      return true, c
    end,
    CountProjectMarkers = function() return #m.regions + #m.markers, #m.markers, #m.regions end,
    EnumProjectMarkers3 = function(_, i)
      local r = m.regions[i + 1]
      if r then return i + 1, true, r[1], r[2], r[3], i + 1, r[4] end
      local k = m.markers[i + 1 - #m.regions]
      if k then return i + 1, false, k[1], 0, k[2], i + 1, 0 end
      return 0
    end,
    EnumProjectMarkers = function(i) local r = m.regions[i + 1]; if r then return i + 1, true, r[1], r[2], r[3], i + 1 end; return 0 end,
    CountMediaItems = function() return #items end,
    GetMediaItem = function(_, i) return items[i + 1] end,
    CountTrackMediaItems = function(t) return #t.items end,
    GetTrackMediaItem = function(t, i) return t.items[i + 1] end,
    GetMediaItem_Track = function(it) return it.track end,
    GetMediaItemInfo_Value = function(it, k)
      if k == "D_POSITION" then return it.pos end
      if k == "D_LENGTH" then return it.len end
      if k == "B_MUTE" then return it.mute end
      if k == "D_VOL" then return it.vol end
      if k == "IP_ITEMNUMBER" then for i, x in ipairs(it.track.items) do if x == it then return i - 1 end end end
      return (it.vals and it.vals[k]) or 0
    end,
    SetMediaItemInfo_Value = function(it, k, v)
      if k == "D_POSITION" then return F.move(it, v - it.pos) or true elseif k == "D_LENGTH" then it.len = v elseif k == "B_MUTE" then it.mute = v
      else it.vals = it.vals or {}; it.vals[k] = v end
      it.chunk = nil; changed(it.track)
      return true
    end,
    GetSetMediaItemInfo_String = function(it, k, v, set)
      if k == "GUID" then return true, it.guid end
      if k:sub(1, 6) == "P_EXT:" then
        local key = k:sub(7)
        if set then it.ext[key] = v ~= "" and v or nil; it.chunk = nil; it.raw = nil; changed(it.track) end
        return true, it.ext[key] or ""
      end
      return true, ""
    end,
    GetItemStateChunk = function(it)
      local c = item_chunk(nil, it)
      F.chunk_bytes = F.chunk_bytes + #c
      return true, c
    end,
    SetItemStateChunk = function(it, c) it.raw = c; changed(it.track); return true end,
    IsMediaItemSelected = function() return false end,
    CountSelectedMediaItems = function() return 0 end, CountSelectedTracks = function() return 0 end,
    GetSelectedMediaItem = function() return nil end, GetSelectedTrack = function() return nil end,
    IsTrackSelected = function() return false end,
    CountTakes = function() return 1 end,
    GetTake = function(it, i) return i == 0 and take_of[it] or nil end,
    GetActiveTake = function(it) return take_of[it] end,
    GetMediaItemTake_Item = function(tk) return tk.item end,
    GetMediaItemTake_Track = function(tk) return tk.item.track end,
    TakeIsMIDI = function(tk) return tk.item.midi == true end,
    GetTakeName = function(tk) return tk.item.name end,
    GetMediaItemTakeInfo_Value = function(tk, k)
      if k == "D_PLAYRATE" then return 1 end
      if k == "D_STARTOFFS" then return tk.item.soffs end
      if k == "D_VOL" then return 1 end
      return 0
    end,
    GetSetMediaItemTakeInfo_String = function(tk, k, v, set)
      if k == "P_NAME" then return true, tk.item.name end
      if k == "GUID" then return true, tk.item.tguid end
      if k:sub(1, 6) == "P_EXT:" then local key = k:sub(7); if set then tk.ext[key] = v end; return true, tk.ext[key] or "" end
      return true, ""
    end,
    GetMediaItemTake_Source = function(tk) return tk end,
    GetMediaSourceFileName = function(src) return src.item.midi and "" or ("C:/fake/Big/" .. m.opts.wav) end,
    GetMediaSourceType = function(src) return src.item.midi and "MIDI" or "WAVE" end,
    GetMediaSourceParent = function() return nil end,
    GetMediaSourceLength = function() return m.opts.wav_secs, false end,
    GetMediaItemTake_Peaks = function() return 0 end,
    MIDI_CountEvts = function(tk) local n, c = notes_of(tk.item); return true, #n, #c, 0 end,
    MIDI_GetNote = function(tk, i)
      local n = notes_of(tk.item)[i + 1]
      if not n then return false end
      return true, false, false, n[1], n[2], 0, n[3], n[4]
    end,
    MIDI_GetCC = function(tk, i)
      local _, c = notes_of(tk.item)
      local e = c[i + 1]
      if not e then return false end
      return true, false, false, e[1], 0xB0, 0, e[3], e[4]
    end,
    MIDI_GetHash = function(tk) -- (REAPER's is a short hex string that changes with the notes; here a version bumped by F.midi_edit)
      return true, string.format("%016X", tk.item.n * 4099 + (tk.item.mver or 0)) end,
    MIDI_GetProjTimeFromPPQPos = function(tk, ppq) return tk.item.pos + ppq / 960 * 60 / m.opts.bpm end,
    MIDI_GetPPQPosFromProjTime = function(tk, t) return (t - tk.item.pos) * m.opts.bpm / 60 * 960 end,
    CountTempoTimeSigMarkers = function() return #m.tempo end,
    GetTempoTimeSigMarker = function(_, i) local p = m.tempo[i + 1]; if p then return true, p[1], 0, 0, p[2], 4, 4, false end; return false end,
    TimeMap_GetTimeSigAtTime = function() return 4, 4, m.opts.bpm end,
    TimeMap2_timeToQN = function(_, t) return t * m.opts.bpm / 60 end,
    TimeMap_QNToMeasures = function(_, qn) return math.floor(qn / 4) + 1 end,
    TimeMap_GetMeasureInfo = function(_, i) return i * 2, i * 4, (i + 1) * 4, 4, 4, m.opts.bpm end,
    ColorToNative = function(r, g, b) return r | (g << 8) | (b << 16) end,
    ColorFromNative = function(c) return c & 255, (c >> 8) & 255, (c >> 16) & 255 end,
    GetToggleCommandStateEx = function() return 0 end, GetToggleCommandState = function() return 0 end,
    NamedCommandLookup = function() return 0 end,
    file_exists = function() return false end,
    JS_Mouse_GetState = function() return 0 end,
    Undo_CanRedo2 = function() return nil end,
    Track_GetPeakInfo = function() return 0 end,
    GetTrackAutomationMode = function() return 0 end,
    GetGlobalAutomationOverride = function() return -1 end,
    format_timestr_pos = function(t) return string.format("%.3f", t) end,
    GetSetTrackGroupMembership = function() return 0 end, GetSetTrackGroupMembershipHigh = function() return 0 end,
  }
  local calls = F.calls
  local wrapped = {}
  for k, fn in pairs(R) do
    wrapped[k] = function(...) calls[k] = (calls[k] or 0) + 1; return fn(...) end
  end
  F.raw = R
  -- (anything else: a no-op answering nothing, named in F.missing so a test can see what it leaned on. Never the extension's own functions:
  -- code asks `if reaper.StudioSync_X then` to know whether the extension is there)
  F.reaper = setmetatable(wrapped, { __index = function(_, k)
    if tostring(k):find("^StudioSync_") or tostring(k):find("^JS_") or tostring(k):find("^CF_") or tostring(k):find("^BR_") then return nil end
    F.missing[k] = true
    return function() end
  end })
  function F.reset_counts() for k in pairs(calls) do calls[k] = nil end; F.chunk_bytes = 0 end
  function F.total_calls() local n = 0; for _, c in pairs(calls) do n = n + c end; return n end
  F.items = function() return items end
  -- (a MIDI note's velocity changed, as an edit in the piano roll makes it)
  function F.midi_edit(it, k, vel)
    it.events[k][4] = vel
    it.mver, it.chunk, it.notes = (it.mver or 0) + 1, nil, nil
    changed(it.track)
  end
  -- (an item moved: its chunk follows, even one StudioSync wrote back)
  function F.move(it, by)
    it.pos = it.pos + by
    if it.raw then it.raw = it.raw:gsub("\nPOSITION [^\n]*", "\nPOSITION " .. string.format("%.10g", it.pos), 1) end
    it.chunk = nil
    changed(it.track)
  end
  F.take_of = take_of
  return F
end

return B
