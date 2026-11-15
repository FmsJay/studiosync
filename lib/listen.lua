-- The listening page (research of other tools, 0.58.53: half a band's listening happens away from the DAW, and the Google Drive app took no
-- comments). One web page for the studio listing every song's mixes (<Song>/mixes, newest first), to play on a phone or any browser with no
-- REAPER. Whoever shares it serves the studio folder over Tailscale (`tailscale serve`, a path of its own beside anything else served), so
-- only computers and phones on the tailnet reach it, and nothing goes to an outside website. A comment typed under a mix goes to the studio's
-- phone-alerts channel (lib/alerts.lua); the computer sharing the page reads it there and puts it in that song's chat, with the mix and the
-- moment ("Bee on mix 3 at 1:23: ..."). Without phone alerts on, the page plays but takes no comments.
local band = require("band")
local listen = {}
listen.AUDIO = { wav = true, flac = true, mp3 = true, ogg = true, m4a = true, aif = true, aiff = true }

local function esc(s) return (tostring(s):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" })) end
local function url(s) return (tostring(s):gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end)) end
function listen.path_of(root) return root .. "/_band/listen.html" end

-- The page. songs: { { name, mixes = { file, ... } } } newest first; channel/server: the alerts channel, or nil (no comments). Pure.
function listen.page(studio, songs, channel, server)
  local h = { [[<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>]] .. esc(studio) .. [[ - mixes</title><style>
body{font:16px system-ui,sans-serif;margin:0;padding:12px 16px;background:#16181c;color:#e8e8e8}h1{font-size:20px}h2{font-size:17px;margin:22px 0 6px}
.mix{background:#22252b;border-radius:8px;padding:10px;margin:8px 0}.name{font-size:14px;color:#aab}audio{width:100%;margin:6px 0}
input,button{font:inherit;border-radius:6px;border:1px solid #444;background:#111;color:#eee;padding:6px}input.t{width:100%;box-sizing:border-box}
button{background:#2e7d4f;border:0;margin-top:6px}.ok{color:#8c8;font-size:14px}.dim{color:#889;font-size:14px}</style></head><body>
<h1>]] .. esc(studio) .. [[</h1>]] }
  if channel then
    h[#h + 1] = [[<p class="dim">Your name: <input id="who" placeholder="your name"> Comments go to the song's chat in StudioSync, at the moment you were listening to.</p>]]
  else
    h[#h + 1] = [[<p class="dim">To leave comments here, the studio's owner turns on phone alerts in StudioSync's Settings.</p>]]
  end
  local n = 0
  for _, s in ipairs(songs) do
    if #s.mixes > 0 then
      h[#h + 1] = "<h2>" .. esc(s.name) .. "</h2>"
      for _, f in ipairs(s.mixes) do
        n = n + 1
        h[#h + 1] = string.format('<div class="mix"><div class="name">%s</div><audio id="a%d" controls preload="none" src="../%s/mixes/%s"></audio>',
          esc(f), n, url(s.name), url(f))
        if channel then
          h[#h + 1] = string.format('<input class="t" id="c%d" placeholder="a comment at this moment"><button onclick="say(%d,%s,%s)">Send</button> <span class="ok" id="k%d"></span>',
            n, n, esc(band.json_encode(s.name)), esc(band.json_encode(f)), n)
        end
        h[#h + 1] = "</div>"
      end
    end
  end
  if n == 0 then h[#h + 1] = [[<p class="dim">No mixes yet: Render current mix (StudioSync's Restore page) puts one here.</p>]] end
  if channel then
    h[#h + 1] = "<script>const CH=" .. band.json_encode(channel) .. ",SV=" .. band.json_encode(server) .. [[;
const who=document.getElementById("who");who.value=localStorage.getItem("who")||"";who.onchange=()=>localStorage.setItem("who",who.value);
function mmss(t){t=Math.floor(t||0);return Math.floor(t/60)+":"+String(t%60).padStart(2,"0")}
async function say(i,song,mix){const c=document.getElementById("c"+i),k=document.getElementById("k"+i),t=c.value.trim();if(!t)return;
const name=(who.value.trim()||"someone").slice(0,40),at=mmss(document.getElementById("a"+i).currentTime);
const msg=name+" on "+mix+" at "+at+": "+t.slice(0,400);
try{const r=await fetch(SV+"/",{method:"POST",body:JSON.stringify({topic:CH,title:"Note on "+song,message:msg,tags:["studiosync-note","s:"+song]})});
k.textContent=r.ok?"sent":"not sent ("+r.status+")";if(r.ok)c.value=""}catch(e){k.textContent="not sent (no connection)"}}
</script>]]
  end
  h[#h + 1] = "</body></html>\n"
  return table.concat(h, "\n")
end

-- Every song's mixes, newest first.
function listen.songs(cfg)
  local out = {}
  for _, song in ipairs(band.songs(cfg)) do
    local dir, files = band.song_dir(cfg, song) .. "/mixes", {}
    for _, f in ipairs(band.files(dir)) do
      if listen.AUDIO[(f:match("%.([^.]+)$") or ""):lower()] and not f:find("^%.") then files[#files + 1] = f end
    end
    table.sort(files, function(a, z) return a > z end) -- (renders are named by date: newest first)
    out[#out + 1] = { name = song, mixes = files }
  end
  return out
end
function listen.write(cfg)
  local alerts = require("alerts")
  local text = listen.page(band.info(cfg.root).name, listen.songs(cfg), alerts.channel(cfg.root), alerts.server(cfg.root))
  if band.read(listen.path_of(cfg.root)) ~= text then band.write_atomic(listen.path_of(cfg.root), text) end
end

-- A comment from the channel's JSON stream (one line of ntfy's /json?poll=1), as a song and the words for its chat, or nil. Pure.
function listen.comment(line, songs)
  local ok, m = pcall(band.json_decode, line)
  if not ok or type(m) ~= "table" or m.event ~= "message" or type(m.message) ~= "string" or type(m.tags) ~= "table" then return nil end
  local note, song = false, nil
  for _, t in ipairs(m.tags) do
    if t == "studiosync-note" then note = true end
    if type(t) == "string" and t:sub(1, 2) == "s:" then song = t:sub(3) end
  end
  if not note or not song or not songs[song] then return nil end
  local text = m.message:gsub("[%c]", " "):sub(1, 500)
  return song, text, tostring(m.id or ""), tonumber(m.time)
end

-- The share switch. Tailscale shares a folder only for an administrator (Windows says so), so a little server of StudioSync's own
-- (lib/listen/listen_server.ps1, or .pl on a Mac) serves the page and the mixes on this computer alone, and Tailscale forwards to it, which
-- needs no administrator. The server quits once the heartbeat (lib/listen.tick, every 30 s) stops: REAPER closed, or sharing stopped.
-- -> the page's address, or nil + why.
local function key(root) return "listen sharing " .. root end
function listen.sharing(root) return reaper.GetExtState(band.SECTION, key(root)) ~= "" and reaper.GetExtState(band.SECTION, key(root)) or nil end
local WIN = (reaper.GetOS() or ""):match("^Win") ~= nil
local function q(s) return '"' .. s .. '"' end
function listen.port(id) -- one per studio, the same every time. Pure.
  local h = 0
  for i = 1, #id do h = (h * 31 + id:byte(i)) % 1000 end
  return 47800 + h % 100
end
local function beat_file(id) return band.home() .. "/listen-" .. id .. ".beat" end
local function beat(id) local f = io.open(beat_file(id), "w"); if f then f:write(os.date("!%Y-%m-%dT%H:%M:%SZ")); f:close() end end
local function start_server(cfg)
  local id = band.info(cfg.root).id
  beat(id)
  local here = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]") .. "/listen/"
  local root, prefix = cfg.root:gsub("\\", "/"), "/studiosync-" .. id
  if WIN then
    local services = require("services")
    local cmd = string.format('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%slisten_server.ps1" -Root "%s" -Port %d -Beat "%s" -Prefix "%s"',
      here, root, listen.port(id), beat_file(id), prefix)
    local bat, vbs = services.TMP .. "/bandsync-listen-" .. id .. ".cmd", services.TMP .. "/bandsync-listen.vbs"
    band.write_atomic(bat, "@" .. cmd .. "\r\n")
    band.write_atomic(vbs, 'CreateObject("WScript.Shell").Run """" & WScript.Arguments(0) & """", 0, False\r\n')
    reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', vbs, bat), -1)
  else
    local s = function(x) return "'" .. x:gsub("'", "'\\''") .. "'" end
    reaper.ExecProcess("/bin/sh -c " .. s("/usr/bin/perl " .. s(here .. "listen_server.pl") .. " " .. s(root) .. " " .. listen.port(id) .. " " ..
      s(beat_file(id)) .. " " .. s(prefix) .. " >/dev/null 2>&1 &"), -1)
  end
end
function listen.share(cfg, on)
  local services = require("services")
  local exe = services.tailscale_exe()
  if not exe then return nil, "Tailscale isn't installed on this computer." end
  local id = band.info(cfg.root).id
  local path = "/studiosync-" .. id
  if not on then
    reaper.ExecProcess(q(exe) .. " serve --https=443 --set-path " .. path .. " off", 10000)
    reaper.DeleteExtState(band.SECTION, key(cfg.root), true)
    os.remove(beat_file(id)) -- (the server sees it gone and quits)
    return true
  end
  local host = services.tailscale_address()
  if not host or not host:find("%.ts%.net$") then return nil, "Tailscale isn't signed in here, or the tailnet has its names turned off (MagicDNS)." end
  listen.write(cfg)
  start_server(cfg)
  local r = reaper.ExecProcess(q(exe) .. " serve --bg --yes --set-path " .. path .. " http://127.0.0.1:" .. listen.port(id), 15000) or ""
  if not r:match("^0\n") then os.remove(beat_file(id)); return nil, "Tailscale didn't share it: " .. r:gsub("^%d+\n", ""):sub(1, 300) end
  local address = "https://" .. host .. path .. "/_band/listen.html"
  reaper.SetExtState(band.SECTION, key(cfg.root), address, true)
  return address
end

-- Run every 30 s or so (Autostart, Live sync): on the computer sharing a studio's page, it's kept up to date and comments come in.
local tick_at = -math.huge
function listen.tick()
  if reaper.time_precise() - tick_at < 30 then return end
  tick_at = reaper.time_precise()
  for _, g in ipairs(band.bands()) do
    if listen.sharing(g.root) then pcall(listen.tick_one, { root = g.root, user = reaper.GetExtState(band.SECTION, "user") }) end
  end
end
function listen.tick_one(cfg)
  local id = band.info(cfg.root).id
  beat(id)
  if not require("services").port_open("127.0.0.1:" .. listen.port(id)) then start_server(cfg) end -- (REAPER restarted, or it stopped: back)
  pcall(listen.write, cfg)
  local alerts, services = require("alerts"), require("services")
  local channel = alerts.channel(cfg.root)
  if not channel then return end
  local since_key = "listen since " .. cfg.root
  local since = reaper.GetExtState(band.SECTION, since_key)
  local out = services.background("listen-notes", 'curl -s -m 15 "' .. alerts.server(cfg.root) .. "/" .. channel .. "/json?poll=1&since=" .. (since ~= "" and since or "12h") .. '"', 25)
  if not out then return end
  local songs = {}
  for _, s in ipairs(band.songs(cfg)) do songs[s] = true end
  local seen = reaper.GetExtState(band.SECTION, "listen seen " .. cfg.root)
  local last
  for line in out:gmatch("[^\r\n]+") do
    local song, text, id = listen.comment(line, songs)
    if song and id ~= "" and not seen:find(id, 1, true) then
      local chat = require("page_chat")
      pcall(function()
        local d = chat.dir(cfg, { song = song }, "song") .. "/msgs"
        reaper.RecursiveCreateDirectory(d, 0)
        band.write_json(d .. "/" .. os.date("!%Y%m%d-%H%M%S") .. "-listen-" .. id:gsub("[^%w]", "") .. ".json",
          { text = text .. " (from the listening page)", user = "Listening page", time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
      end)
      seen = (seen .. " " .. id):sub(-2000)
      band.log("a comment on " .. song .. " came in from the listening page")
    end
    local ok, m = pcall(band.json_decode, line)
    if ok and type(m) == "table" and type(m.id) == "string" and m.id:match("^[%w]+$") then last = m.id end
  end
  reaper.SetExtState(band.SECTION, "listen seen " .. cfg.root, seen, true)
  if last then reaper.SetExtState(band.SECTION, since_key, last, true) end
end

return listen
