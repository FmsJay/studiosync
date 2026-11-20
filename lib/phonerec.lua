-- Record from a phone (docs/realtime-roadmap.md "New features the extension makes possible"). A singer with only a phone opens the web UI's
-- Record page (lib/webui/record.html), picks a track this computer's user may record on (the page acts as this computer's user, as the Song
-- page does: the same claims and room rules as the panel), and presses Record: the page captures the microphone (an AudioWorklet, lossless
-- 32-bit float WAV; MediaRecorder's compressed file where there's no worklet, and it says so), this computer plays the song (Play together
-- with a bar's count-in and the click, or on its own when the room's rules keep this user from starting the band; a start that's already
-- coming, someone's Play or Record together, is simply joined), and at Stop the take is uploaded to this computer (POST /api/upload,
-- extension/webui.cpp) and put in as a real take on that track, where the song was when the phone heard its first sample.
--
-- In time: the page measures its clock against this computer's link clock (GET /api/time: StudioSync_DirectNow, NTP's way, the quickest of
-- 8 round trips), works out when its first sample was really heard (the audio context's output timestamp, less the output and the reported
-- input latency), and sends that moment on the link clock. Here, every tick while a Record page is open, the play position is read with the
-- link clock beside it; the take goes where the song was at that moment (the median over the playing stretch, so one late tick doesn't move
-- it), trimmed to the stretch this computer played (the rest is still in the item, as a recording's pre-roll is). The singer must hear this
-- computer's playback (its speakers, or headphones off it): over a call it lands the call's delay late. Expected: within about 10-30 ms on
-- Tailscale at home (the page says its own estimate), worse on mobile data or where the phone misreports its input delay; the page's nudge
-- moves the take afterwards. Credited by name: "<section> - <singer> - take N" (lib/recap.lua's naming, read only), the singer's name typed
-- on the page (this computer's user if none). It reaches the band as any new item does: mirror shares its file and sends it.
--
-- The phone's browser lets a page use the microphone only on a secure page: http://127.0.0.1 on this computer is one, the phone link
-- (http://<name>:47281) isn't. `tailscale serve` gives the pages an https:// address with a real certificate on the tailnet: this
-- computer's name on port 8443 (443 is often someone's already: James's AI hub has it), proxied to 127.0.0.1:47281, where the server asks
-- for the studio's token as on the link's port (webui_auth: X-Forwarded-*). The Record page offers the setup once (a button running it here)
-- and the https link. (James, rt)
-- It sets itself up now (James: "fewer things to press"): the first time a Record page asks here each session, in the background, and
-- only with HTTPS certificates on for the tailnet (else `tailscale serve` waits for them). Tailnet-only and still behind the studio's
-- token, as the http link is; Settings > Advanced turns it off (ExtState "phone link auto" "0"), and the page's button stays.
--
-- The phone app (docs/realtime-roadmap.md "StudioSync on the phone", stage 1): the same page installed on the phone (phone.webmanifest,
-- phone-sw.js) opens without a studio computer and records there, playing the song's latest mix itself (each song's newest file in
-- <Song>/mixes, offered for download by id: StudioSync_WebUIOffer, GET /api/file). Such a take knows its own place, the mix's position
-- under its first sample (`pos`, and stamped in the WAV's BWF time reference, which REAPER reads), so here it only needs its song in front
-- and the same room rules; a MIDI take (a Standard MIDI File from a USB keyboard, Web MIDI) becomes an ordinary MIDI item the same way.
-- Each take carries the phone's id for it (`cid`): put in once, and the page hears how it went (`done`) before it lets go of its copy.
-- (James, rt)
local band = require("band")
local phonerec = {}
phonerec.WANT_FOR = 30       -- seconds a Record page's "I'm open" lasts (it says so every 10 s)
phonerec.PUBLISH_EVERY = 0.5 -- seconds between the page's state while it's open (the page moves the position on between)
phonerec.TRACKS_EVERY = 2    -- seconds between rebuilding who may record where (sync.authority reads the claims files' caches)
phonerec.KEEP = 20 * 60      -- seconds of play readings kept: a longer take can't be placed
phonerec.AUTO_KEY = "phone link auto" -- ExtState: "0" keeps the secure link to the Record page's button
function phonerec.auto_on() return reaper.GetExtState(band.SECTION, phonerec.AUTO_KEY) ~= "0" end
phonerec.JUMP = 0.1          -- seconds the position may be off where it should be before it counts as a jump (a new stretch)
phonerec.LEAD_ALONE = 2      -- seconds from the press to a start on this computer alone
phonerec.HTTPS_PORT = 8443   -- `tailscale serve`'s https port for the pages
phonerec.NUDGE_MAX = 500     -- ms one nudge may move a take
phonerec.NAME_MAX = 32       -- characters of a singer's name
phonerec.KINDS = { wav = "wav", webm = "webm", ogg = "ogg", mp4 = "m4a", mid = "mid" } -- what a page may upload -> the file's extension
phonerec.MIX_EVERY = 30      -- seconds between looking for each song's newest mix while a Record page is open
phonerec.DONE_KEEP = 20      -- how the last takes went, for the pages (by the phone's id for each)
phonerec.POS_MAX = 24 * 3600 -- seconds: a stamped position past this is nonsense
-- A page recording along to this computer says it's alive every 2 s (record.js); the start it made is stopped once it's this many seconds
-- quiet (the page closed, the phone slept or lost the network), so the band isn't left playing. Only for a page that says so (an older page
-- never does: its start stays, as before). VM test, rt.
phonerec.GONE_AFTER = 8

-- ---- pure -------------------------------------------------------------------------------------------------------------------------------
-- The pages' secure address, through `tailscale serve`: this computer's MagicDNS name. nil from a bad name or token (as webui.phone_url).
function phonerec.secure_url(name, token, port)
  if type(name) ~= "string" or not name:match("^[%w][%w%.%-]*$") or type(token) ~= "string" or not token:match("^%x+$") then return nil end
  return "https://" .. name .. ":" .. math.floor(tonumber(port) or phonerec.HTTPS_PORT) .. "/record.html?t=" .. token
end
-- Tailscale's arguments for it: an https port of its own, added beside whatever else `tailscale serve` already serves.
function phonerec.serve_args(web_port, https_port)
  return "serve --bg --https=" .. math.floor(tonumber(https_port) or phonerec.HTTPS_PORT) .. " http://127.0.0.1:" .. math.floor(tonumber(web_port) or 47281)
end
-- A singer's name from a page: letters (any language), digits, spaces and .'_- only, trimmed; nil when nothing's left or it's too long.
function phonerec.clean_name(s)
  if type(s) ~= "string" or not utf8.len(s) then return nil end
  local out = {}
  for _, c in utf8.codes(s) do
    local ch = utf8.char(c)
    if c >= 128 or ch:match("[%w%s%.'_%-]") then out[#out + 1] = c < 128 and ch:gsub("%s", " ") or ch end
  end
  local t = table.concat(out):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if t == "" or utf8.len(t) > phonerec.NAME_MAX or t:find("[\194][\128-\159]") then return nil end -- (no C1 control characters)
  return t
end
-- A file a page sent is what it says it is: its first bytes. Pure.
function phonerec.magic_ok(kind, head)
  head = tostring(head or "")
  if kind == "wav" then return head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WAVE" end
  if kind == "webm" then return head:sub(1, 4) == "\26\69\223\163" end
  if kind == "ogg" then return head:sub(1, 4) == "OggS" end
  if kind == "mp4" then return head:sub(5, 8) == "ftyp" end
  if kind == "mid" then return head:sub(1, 4) == "MThd" end
  return false
end

-- A song's mix's id for the pages: 16 hex characters from the song, file and size, so a new render is a new id (the phone fetches it
-- again). Pure.
function phonerec.mix_id(song, file, size)
  local s, a, b = tostring(song) .. "/" .. tostring(file) .. "/" .. tostring(size), 2166136261, 5381
  for i = 1, #s do
    local c = s:byte(i)
    a = ((a ~ c) * 16777619) & 0xffffffff
    b = (b * 33 + c) & 0xffffffff
  end
  return string.format("%08x%08x", a, b)
end
-- A phone's MIDI take: a Standard MIDI File as the page writes it (format 0, one track, ticks per beat; tempo meta events followed) ->
-- { { t = seconds from its start, msg = the event's bytes } }, channel messages only, or nil and why. Pure.
function phonerec.smf_events(s)
  if type(s) ~= "string" or #s < 22 or s:sub(1, 4) ~= "MThd" then return nil, "not a MIDI file" end
  local hlen, fmt, ntr, div = string.unpack(">I4I2I2I2", s, 5)
  if fmt ~= 0 or ntr ~= 1 or div == 0 or div >= 0x8000 then return nil, "not a phone's MIDI take (one track, ticks per beat)" end
  local at = 9 + hlen
  if s:sub(at, at + 3) ~= "MTrk" then return nil, "a MIDI file without its track" end
  local i, z = at + 8, math.min(#s, at + 7 + string.unpack(">I4", s, at + 4))
  local tempo, sec, out, status = 500000, 0, {}, nil
  local function vlq()
    local v = 0
    for _ = 1, 4 do
      local c = s:byte(i)
      if not c or i > z then return nil end
      i = i + 1
      v = v * 128 + (c & 127)
      if c < 128 then return v end
    end
  end
  while i <= z do
    local d = vlq()
    if not d then break end
    sec = sec + d * tempo / 1e6 / div
    local c = s:byte(i)
    if c == 0xFF then
      local kind = s:byte(i + 1)
      i = i + 2
      local n = vlq()
      if not n or kind == 0x2F then break end
      if kind == 0x51 and n == 3 then tempo = string.unpack(">I3", s, i) end
      i = i + n
    elseif c == 0xF0 or c == 0xF7 then
      i = i + 1
      local n = vlq()
      if not n then break end
      i = i + n
    else
      if c >= 0x80 then status, i = c, i + 1 end
      if not status or status >= 0xF0 then return nil, "a MIDI file the phone didn't write" end
      local n = (status >= 0xC0 and status < 0xE0) and 1 or 2
      if i + n - 1 > z then break end
      out[#out + 1] = { t = sec, msg = string.char(status) .. s:sub(i, i + n - 1) }
      i = i + n
    end
  end
  return out
end
-- A take's WAV, its BWF time reference (the bext chunk right after the RIFF header, as the phone writes it) set to the sample its audio
-- starts at in the song, so REAPER's "move to source preferred position" puts it back where it was placed. -> true when stamped.
function phonerec.stamp(path, srate, at)
  local f = io.open(path, "r+b")
  if not f then return false end
  local head = f:read(16) or ""
  local ok = head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WAVE" and head:sub(13, 16) == "bext" and (tonumber(srate) or 0) > 0
  if ok then f:seek("set", 358); f:write(string.pack("<I8", math.max(0, math.floor(at * srate + 0.5)))) end -- (12 + 8 + 338: TimeReference)
  f:close()
  return ok
end

-- Play readings. list: { { t (link clock), pos, rate, seg } }, the oldest first; a reading that doesn't follow on from the last one (stopped
-- between, a jump, another rate) starts a new stretch. playing false: nothing kept, but the next reading starts a new stretch. Pure.
function phonerec.add_reading(list, t, pos, rate, playing)
  local last = list[#list]
  if not playing then list.broken = true; return list end
  local seg = last and last.seg or 0
  if not last or list.broken or rate ~= last.rate or math.abs(pos - (last.pos + (t - last.t) * last.rate)) > phonerec.JUMP then seg = seg + 1 end
  list.broken = nil
  list[#list + 1] = { t = t, pos = pos, rate = rate, seg = seg }
  return list
end
-- The readings older than `keep` seconds before t, gone. Pure.
function phonerec.prune(list, t, keep)
  local first = 1
  while list[first] and list[first].t < t - (keep or phonerec.KEEP) do first = first + 1 end
  if first > 1 then
    local n = #list
    table.move(list, first, n, 1)
    for i = n - first + 2, n do list[i] = nil end
  end
  return list
end
-- Where a take goes. t0: the link-clock moment of its first sample; len: its seconds. The stretch this computer played that covers most of it;
-- the song's position at t0 from that stretch's readings (the median of pos - t * rate: one late tick moves nothing). -> { at = song position
-- of the first sample, from, to = the stretch's ends (the item's), rate }, or nil and why. Pure.
-- cue: where the phone's own start was (Play together's count-in runs before it): inside the stretch, the item starts there, as REAPER's own
-- take does after a count-in; the count-in bar stays in the source. It started at the count-in and covered the bar before. LinuxBox phone test, rt
function phonerec.place(list, t0, len, cue)
  local count, best = {}, nil
  for _, r in ipairs(list) do
    if r.t >= t0 and r.t <= t0 + len then
      count[r.seg] = (count[r.seg] or 0) + 1
      if not best or count[r.seg] > count[best] then best = r.seg end
    end
  end
  if not best then return nil, "this computer wasn't playing the project while the phone recorded" end
  local cs, from, to, rate = {}, math.huge, -math.huge, 1
  for _, r in ipairs(list) do
    if r.seg == best then cs[#cs + 1] = r.pos - r.t * r.rate; from, to, rate = math.min(from, r.pos), math.max(to, r.pos), r.rate end
  end
  table.sort(cs)
  local c = #cs % 2 == 1 and cs[(#cs + 1) // 2] or (cs[#cs // 2] + cs[#cs // 2 + 1]) / 2
  if tonumber(cue) and cue > from and cue < to then from = cue end
  return { at = c + t0 * rate, from = from, to = to, rate = rate }
end
-- The item for a placed take: { pos, offs (the take's start offset), len }, inside both the take and the stretch, never before the song's
-- start. nil when they don't overlap. Pure.
function phonerec.item_plan(p, len)
  local a = math.max(0, p.from, p.at)
  local z = math.min(p.to, p.at + len)
  if z - a < 0.05 then return nil end
  return { pos = a, offs = a - p.at, len = z - a }
end
-- A nudge: the take's audio `ms` later (negative: earlier), the item's edges where they were unless the audio would start after the item:
-- then the item starts where its audio does. -> pos, offs, len. Pure.
function phonerec.nudge(pos, offs, len, ms)
  local o = offs - ms / 1000
  if o < 0 then return pos - o, 0, len + o end
  return pos, o, len
end
-- The take's name: smart ("<section> - <singer> - take N", recap's own functions, counted with every take name in the song). Pure.
function phonerec.take_name(markers, pos, singer, names, smart)
  if not smart then return singer .. " - phone take" end
  local recap = require("recap")
  local section = recap.section_at(markers, pos)
  return recap.smart_name(section, singer, recap.next_n(names, section, singer))
end
-- An action from a page ({ topic = "phonerec", ... }) -> what it asks, checked: { want, start = { track, bars }, stop, setup, nudge = ms,
-- take = { id, track, t0 | pos, len, kind, name, err, cid, song, tname, title, when } }. t0: the link-clock moment of its first sample (this
-- computer played the song); pos: the song position under it (the phone played the mix itself). tname: the track's name, if its GUID is
-- gone; title: the singer's own name for the take; when: when it was recorded (the phone's clock).
local function guid_ok(g) return type(g) == "string" and g:match("^{[%x%-]+}$") and #g <= 40 end
function phonerec.parse(a)
  if type(a) ~= "table" then return nil end
  local out = { want = a.want == true or nil, stop = a.stop == true or nil, setup = a.setup == true or nil, alive = a.alive == true or nil }
  if type(a.start) == "table" and guid_ok(a.start.track) then
    out.start = { track = a.start.track, bars = math.max(0, math.min(4, math.floor(tonumber(a.start.bars) or 1))) }
  end
  local n = tonumber(a.nudge)
  if n and n == n and math.abs(n) <= phonerec.NUDGE_MAX and n ~= 0 then out.nudge = n end
  local t = a.take
  if type(t) == "table" and type(t.id) == "string" and t.id:match("^%x+$") and #t.id <= 32 and guid_ok(t.track) and phonerec.KINDS[t.kind] then
    local t0, pos, len = tonumber(t.t0), tonumber(t.pos), tonumber(t.len)
    t0 = t0 and t0 == t0 and t0 > 0 and t0 < math.huge and t0 or nil
    pos = pos and pos == pos and math.abs(pos) < phonerec.POS_MAX and pos or nil
    if (t0 or pos) and len and len > 0 and len < phonerec.KEEP then
      local err = tonumber(t.err)
      local str = function(v, max) return type(v) == "string" and #v <= max and utf8.len(v) and not v:find("%c") and v or nil end
      out.take = { id = t.id, track = t.track, t0 = not pos and t0 or nil, pos = pos, len = len, kind = t.kind, name = phonerec.clean_name(t.name),
        err = err and err == err and math.max(0, math.min(9999, math.floor(err + 0.5))) or nil,
        cid = type(t.cid) == "string" and t.cid:match("^%x+$") and #t.cid <= 32 and t.cid or nil,
        song = str(t.song, 200), tname = str(t.tname, 200), title = phonerec.clean_name(t.title),
        when = type(t.when) == "string" and t.when:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d[%d:%.Z%+%-]*$") and t.when:sub(1, 30) or nil }
    end
  end
  return out
end

-- ---- REAPER -----------------------------------------------------------------------------------------------------------------------------
function phonerec.available() return reaper.StudioSync_WebUISaveUpload ~= nil and reaper.StudioSync_DirectNow ~= nil end
local S = { want_until = -math.huge, readings = {}, done = {}, done_order = {}, offered = {} }
function phonerec.reset() S = { want_until = -math.huge, readings = {}, done = {}, done_order = {}, offered = {} } end -- (tests)

local function track_of(proj, guid)
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if reaper.GetTrackGUID(tr) == guid then return tr end
  end
end
local function authority(cfg, b)
  local can, who = require("sync").authority(cfg, b.song, b.room, band.read_json(band.session_path(cfg, b.song)))
  return can, who
end
-- May this computer's user change track `name` at song position pos? -> true, or false and whose it is.
local function may(can, who, cfg, name, pos)
  if can(cfg.user, name, pos) then return true end
  local owner = who and who.owner_of and who.owner_of(name, pos)
  return false, owner and owner ~= cfg.user and (owner .. "'s") or "not yours to change in this room"
end
local function tracks_model(proj, cfg, b)
  local can, who = authority(cfg, b)
  local pos = reaper.GetCursorPositionEx(proj)
  local out = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local name = select(2, reaper.GetTrackName(tr))
    local ok, why = may(can, who, cfg, name, pos)
    out[#out + 1] = { name = name, guid = reaper.GetTrackGUID(tr), may = ok or nil, why = not ok and why or nil }
  end
  return out, who
end
-- (said_at: new for every word, not the second: the page shows a word only when said_at changes, and "the phone stopped its take", the
-- take's own word and a nudge's land in the same second, so the singer never saw where the take went. In ms, so a reload stays ahead.
-- LinuxBox phone test, rt)
local function say(text) S.said, S.said_at = text, math.max((S.said_at or 0) + 1, os.time() * 1000); return text end

-- Starting the song for a phone's take: a start already coming is joined; already playing, it records along; else Play together (or this
-- computer alone when the room's rules keep this user from starting the band) from the edit cursor with `bars` of count-in and the click.
local function start(proj, cfg, b, d)
  local key = tostring(proj)
  S.take_cue = nil -- (someone else's start, or already playing: the stretch as played)
  if (tonumber(reaper.GetExtState(band.SECTION, "together_at " .. key)) or 0) > require("together").now() then return say("joining the start that's coming") end
  if reaper.GetPlayStateEx(proj) & 1 == 1 then return say("recording along: the project is already playing") end
  local together = require("together")
  local pos = reaper.GetCursorPositionEx(proj)
  local ev = { type = "start", pos = pos, countin = together.bars_before(proj, pos, d.bars), click = d.bars > 0 or nil, lag = 0, lead = cfg.user }
  local _, who = authority(cfg, b)
  S.cue, S.started, S.take_cue, S.alive = pos, reaper.time_precise(), pos, nil -- (take_cue outlives Stop: the take arrives after it)
  if require("dawview").may_transport(who.mode, cfg.user, who.driver, require("groups").may_manage(cfg.root, cfg.user)) then
    together.go(proj, cfg, b, ev)
    return say("a phone's take: Play together from bar " .. reaper.format_timestr_pos(pos, "", 2))
  end
  -- (only here: the room's rules say this user doesn't start the band. Live sync fires it as it fires any start)
  ev.at, ev.user = together.now() + phonerec.LEAD_ALONE, cfg.user
  band.set_ext_json(band.SECTION, "transport " .. key, ev, false)
  return say("a phone's take: playing here only (in this room only the driver starts everyone)")
end

local function take_names(proj)
  local names = {}
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, j)
      for k = 0, reaper.CountTakes(it) - 1 do
        local tk = reaper.GetTake(it, k)
        if tk then names[#names + 1] = select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)) end
      end
    end
  end
  return names
end
local function head_of(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local h = f:read(12) or ""
  f:close()
  return h
end

-- A take uploaded: saved beside the project's recordings, checked, placed and named. -> words for the log.
local function track_named(proj, name)
  for i = 0, name and reaper.CountTracks(proj) - 1 or -1 do
    local tr = reaper.GetTrack(proj, i)
    if select(2, reaper.GetTrackName(tr)) == name then return tr end
  end
end
local put_take_in
local function put_take(proj, cfg, b, t)
  local d = t.cid and S.done[t.cid]
  if d and d.ok then return say(d.said .. " (already in)") end
  local said, ok = put_take_in(proj, cfg, b, t)
  if t.cid then
    if not S.done[t.cid] then S.done_order[#S.done_order + 1] = t.cid end
    S.done[t.cid] = { ok = ok or nil, said = said }
    while #S.done_order > phonerec.DONE_KEEP do S.done[table.remove(S.done_order, 1)] = nil end
  end
  return said
end
-- (-> words, and true when it went in)
function put_take_in(proj, cfg, b, t)
  if t.song and t.song ~= b.song then return say("the phone's take for " .. t.song .. " waits: open that project in front here") end
  local tr = track_of(proj, t.track) or track_named(proj, t.tname)
  if not tr then return say("the phone's take wasn't put in: its track is gone") end
  local name = select(2, reaper.GetTrackName(tr))
  local p, why
  if t.pos then p = { at = t.pos, from = -math.huge, to = math.huge, rate = 1 } -- (the phone played the mix: it knows its own place)
  else p, why = phonerec.place(S.readings, t.t0, t.len, S.take_cue) end
  if not p then return say("the phone's take wasn't put in: " .. why) end
  local can, who = authority(cfg, b)
  local ok, whose = may(can, who, cfg, name, math.max(0, p.from, p.at))
  if not ok then return say("the phone's take wasn't put in: " .. name .. " is " .. whose) end
  local singer = t.name or cfg.user
  local dir = reaper.GetProjectPathEx(proj, "")
  if dir == "" then dir = band.home() .. "/phone takes" end
  reaper.RecursiveCreateDirectory(dir, 0)
  local file = string.format("%s/%s phone %s %s.%s", dir, (tostring(b.song):gsub("[^%w%-_ ]", "_")), (band.clean(singer):gsub("[^%w%-_ ]", "_")),
    os.date("%Y-%m-%d %H%M%S"), phonerec.KINDS[t.kind])
  local n = reaper.StudioSync_WebUISaveUpload(t.id, file)
  if n == 0 then return say("the phone's take wasn't put in: its upload isn't here any more (send it again)") end
  if n < 0 then return say("the phone's take couldn't be saved in " .. dir .. " (full, or not writable): press Put in again") end
  if not phonerec.magic_ok(t.kind, head_of(file)) then os.remove(file); return say("the phone's upload wasn't a " .. t.kind .. " file: not put in") end
  local src, plan, evs, srate
  if t.kind == "mid" then
    evs = phonerec.smf_events(band.read(file))
    plan = evs and phonerec.item_plan(p, t.len)
  else
    src = reaper.PCM_Source_CreateFromFile(file)
    local srclen = src and reaper.GetMediaSourceLength(src) or 0
    plan = srclen > 0 and phonerec.item_plan(p, srclen)
    srate = src and reaper.GetMediaSourceSampleRate(src)
  end
  if not plan then
    if src then reaper.PCM_Source_Destroy(src) end
    return say("the phone's take is saved (" .. file .. ") but REAPER couldn't read it, or it missed what this computer played")
  end
  reaper.Undo_BeginBlock2(proj)
  local it, tk
  if evs then -- (an ordinary MIDI item, its events at their song times: right whatever the project's tempo)
    it = reaper.CreateNewMIDIItemInProj(tr, plan.pos, plan.pos + plan.len)
    tk = reaper.GetActiveTake(it)
    for _, e in ipairs(evs) do
      local at = p.at + e.t * p.rate
      if at >= plan.pos and at <= plan.pos + plan.len then reaper.MIDI_InsertEvt(tk, false, false, reaper.MIDI_GetPPQPosFromProjTime(tk, at), e.msg) end
    end
    reaper.MIDI_Sort(tk)
  else
    it = reaper.AddMediaItemToTrack(tr)
    tk = reaper.AddTakeToMediaItem(it)
    reaper.SetMediaItemTake_Source(tk, src)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", plan.pos)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", plan.len)
    reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", plan.offs)
    phonerec.stamp(file, srate, plan.pos - plan.offs)
  end
  local recap = require("recap")
  local tname = t.title and (t.title .. " - " .. singer) or phonerec.take_name(band.capture_markers(proj), plan.pos, singer, take_names(proj), recap.names_on(cfg.root))
  reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", tname, true)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock2(proj, "StudioSync: a take from a phone", -1)
  local bar = reaper.format_timestr_pos(plan.pos, "", 2)
  -- (the take's note beside its file: which project, where, whose; REAPER ignores it, a person or another tool can read it)
  band.write_atomic((file:gsub("%.%w+$", ".json")), band.json_encode({ project = b.song, track = name, by = singer, take = tname, bar = bar,
    position = plan.pos - plan.offs, recorded = t.when, file = file:match("[^/\\]+$"), from = "StudioSync phone" }))
  S.last = { item = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)), track = t.track, name = tname, nudged = 0,
    file = not evs and file or nil, srate = srate }
  return say(string.format("%s: on %s at bar %s%s%s", tname, name, bar,
    t.err and string.format(", in time to about %d ms (nudge it if it sounds off)", t.err) or "",
    t.kind ~= "wav" and t.kind ~= "mid" and " (compressed: the phone couldn't record lossless)" or "")), true
end

local function nudge(proj, cfg, b, ms)
  local l = S.last
  local tr = l and track_of(proj, l.track)
  local it
  for j = 0, tr and reaper.CountTrackMediaItems(tr) - 1 or -1 do
    local x = reaper.GetTrackMediaItem(tr, j)
    if select(2, reaper.GetSetMediaItemInfo_String(x, "GUID", "", false)) == l.item then it = x end
  end
  local tk = it and reaper.GetActiveTake(it)
  if not tk then return say("no phone take here to nudge") end
  local pos, offs, len = reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
  local can, who = authority(cfg, b)
  local ok, whose = may(can, who, cfg, select(2, reaper.GetTrackName(tr)), pos)
  if not ok then return say("not nudged: the track is " .. whose) end
  pos, offs, len = phonerec.nudge(pos, offs, len, ms)
  if l.file then phonerec.stamp(l.file, l.srate, pos - offs) end
  reaper.Undo_BeginBlock2(proj)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", len)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", offs)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock2(proj, "StudioSync: nudge a phone's take", -1)
  l.nudged = l.nudged + ms
  return say(string.format("%s nudged %+d ms (%+d ms in all)", l.name, ms, l.nudged))
end

-- Stopping the start the phone made (and only that): Stop together, or this computer's own stop where it started here alone.
local function stop_mine(proj, cfg, b)
  S.started, S.cue, S.alive = nil, nil, nil
  local _, who = authority(cfg, b)
  if require("dawview").may_transport(who.mode, cfg.user, who.driver, require("groups").may_manage(cfg.root, cfg.user)) then
    require("together").go(proj, cfg, b, { type = "stop" })
  else reaper.OnStopButtonEx(proj) end
end

-- An action a page sent. -> words for the log, or nil.
function phonerec.action(proj, cfg, b, a)
  local d = phonerec.parse(a)
  if not d then return end
  if d.want then S.want_until = reaper.time_precise() + phonerec.WANT_FOR end
  if d.alive then S.heard_at = reaper.time_precise() end -- (the recording page's "still here": phonerec.watch)
  if not phonerec.available() and (d.start or d.take or d.nudge) then return say("this computer's StudioSync extension is older: update it to record from a phone") end
  if d.setup then
    local out = require("services").ts_exec(phonerec.serve_args(require("direct").port(), phonerec.HTTPS_PORT), 10000)
    local code, text = out:match("^(%-?%d+)\n?(.*)$")
    local msg = (text or out):gsub("%s+", " "):sub(1, 300)
    if code == "0" then return say("the phone's secure link is set up (tailscale serve, port " .. phonerec.HTTPS_PORT .. ")") end
    -- (no answer in 10 s: `tailscale serve` waits while the tailnet has HTTPS certificates off, after printing where to turn them on)
    return say("tailscale serve didn't set it up: " .. (msg ~= "" and msg or
      "no answer in 10 s (Tailscale not installed here, or HTTPS certificates off for the tailnet: login.tailscale.com/admin/dns)"))
  end
  if d.start then
    local said = start(proj, cfg, b, d.start)
    if d.alive and S.started then S.alive = true end -- (a page that says it's alive while it records: watched)
    return said
  end
  if d.alive and S.started then S.alive = true end
  if d.stop then
    if not S.started then return end -- (only a start the phone made: someone else's stays theirs)
    stop_mine(proj, cfg, b)
    return say("the phone stopped its take")
  end
  if d.take then return put_take(proj, cfg, b, d.take) end
  if d.nudge then return nudge(proj, cfg, b, d.nudge) end
end

-- Each song's newest mix (<Song>/mixes; renders are named by date, as lib/listen.lua lists them), offered for the pages to download, the
-- older offers withdrawn. -> { { song, id, file, bytes } }
-- shortcut: the phone takes a mix to start at the song's start (as Render current mix does); a render of a time selection lands its
-- takes early by the selection's start, nudge it until mixes say where they start.
local function mixes(cfg)
  local out, offered, audio = {}, {}, require("listen").AUDIO
  for _, song in ipairs(band.songs(cfg)) do
    local dir, best = band.song_dir(cfg, song) .. "/mixes", nil
    for _, f in ipairs(band.files(dir)) do
      if audio[(f:match("%.([^.]+)$") or ""):lower()] and not f:find("^%.") and (not best or f > best) then best = f end
    end
    local fh = best and io.open(dir .. "/" .. best, "rb")
    if fh then
      local size = fh:seek("end")
      fh:close()
      local id = phonerec.mix_id(song, best, size)
      if reaper.StudioSync_WebUIOffer(id, dir .. "/" .. best) == 1 then offered[id] = true; out[#out + 1] = { song = song, id = id, file = best, bytes = size } end
    end
  end
  for id in pairs(S.offered) do if not offered[id] then reaper.StudioSync_WebUIOffer(id, "") end end
  S.offered = offered
  return out
end

-- The secure link set up by itself, once a session (see the top): in the background, so REAPER never waits on Tailscale. -> true when asked.
function phonerec.auto_link()
  local services = require("services")
  local exe = services.tailscale_exe and services.tailscale_exe()
  if not exe or not (services.tailscale_certs_on and services.tailscale_certs_on()) then return end -- (asked again next tick: certificates may come on)
  S.auto_tried = true
  services.run_hidden("phone-serve", '"' .. exe .. '" ' .. phonerec.serve_args(require("direct").port(), phonerec.HTTPS_PORT), 0)
  band.log(say("setting up the phone's secure link by itself (tailscale serve, port " .. phonerec.HTTPS_PORT .. "; Settings > Advanced turns this off)"))
  return true
end

-- Each tick in front, whether or not a page still looks (lib/webui.lua: a closed page is one that doesn't): the start a phone made, stopped
-- when its page has gone quiet for GONE_AFTER s mid-take. A start someone made in REAPER is never the phone's (S.started is only its own),
-- and once nothing plays or is due here the phone's start is over: forgotten, so a later start by someone else isn't taken for it. -> words.
function phonerec.watch(proj, cfg, b, now)
  if not S.started then return end
  local together = require("together")
  local due = (tonumber(reaper.GetExtState(band.SECTION, "together_at " .. tostring(proj))) or 0) > together.now()
  if now - S.started > together.LEAD + 3 and reaper.GetPlayStateEx(proj) & 1 == 0 and not due then S.started, S.cue, S.alive = nil, nil, nil; return end
  if not S.alive or now - (S.heard_at or now) < phonerec.GONE_AFTER then return end
  local quiet = math.floor(now - S.heard_at)
  stop_mine(proj, cfg, b)
  return say(string.format("the phone recording along went quiet for %d s (its page closed, or it lost the network): the start it made is stopped", quiet))
end

-- Each tick in front while a page looks (lib/webui.lua): the play readings, and the Record page's state while one is open.
function phonerec.tick(proj, cfg, b, publish, now)
  if now >= S.want_until or not phonerec.available() then return end
  if not S.auto_tried and now - (S.auto_at or -math.huge) >= 20 and phonerec.auto_on() then S.auto_at = now; phonerec.auto_link() end
  if S.proj ~= proj then S.proj, S.readings = proj, {} end
  local ps = reaper.GetPlayStateEx(proj)
  local t = reaper.StudioSync_DirectNow()
  local pos = ps & 1 == 1 and reaper.GetPlayPositionEx(proj) or reaper.GetCursorPositionEx(proj)
  phonerec.add_reading(S.readings, t, pos, reaper.Master_GetPlayRate(proj), ps & 1 == 1)
  if #S.readings > 2000 and S.readings[1].t < t - phonerec.KEEP then phonerec.prune(S.readings, t, phonerec.KEEP) end
  if now - (S.pub_at or -math.huge) < phonerec.PUBLISH_EVERY then return end
  S.pub_at = now
  if now - (S.tracks_at or -math.huge) >= phonerec.TRACKS_EVERY then S.tracks_at, S.tracks = now, tracks_model(proj, cfg, b) end
  if reaper.StudioSync_WebUIOffer and now - (S.mixes_at or -math.huge) >= phonerec.MIX_EVERY then S.mixes_at, S.mixes = now, mixes(cfg) end
  local key = tostring(proj)
  local due = tonumber(reaper.GetExtState(band.SECTION, "together_at " .. key))
  local together = require("together")
  local st = require("webui").status()
  local secure = phonerec.secure_url(require("services").my_tailscale_name(), st.token, phonerec.HTTPS_PORT)
  publish("phonerec", { me = cfg.user, song = b.song, tracks = S.tracks, playing = ps & 1 == 1 or nil, rec = ps & 4 == 4 or nil,
    pos = math.floor(pos * 1000 + 0.5) / 1000, at = t, bar = reaper.format_timestr_pos(pos, "", 2),
    due = due and due > together.now() and t + (due - together.now()) or nil, cue = S.cue, secure = secure, port = phonerec.HTTPS_PORT,
    said = S.said, said_at = S.said_at, last = S.last and S.last.name or nil, mixes = S.mixes, done = next(S.done) and S.done or nil })
end

return phonerec
