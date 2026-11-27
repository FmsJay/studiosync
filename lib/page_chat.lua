-- The panel's Chat page: messages, to-dos and links for the band, this song or this room. Each message or to-do is
-- its own small file in the shared folder (no two people ever write the same file, so Syncthing never conflicts).
local band = require("band")
local chat = {}

local SCOPES = { { "room", "This room" }, { "song", "This project" }, { "band", "Studio" } }
local scope, draft, todo_text, link_title, link_url = "song", "", "", "", ""
local cache, cache_at, cache_key = nil, -math.huge, ""

-- Whose things show (the Chat page's Everyone box; the notes and the drawings go by it too). "" for everyone's.
function chat.only() return reaper.GetExtState(band.SECTION, "show only") end

-- Direct messages and channels (rt-chat2): a scope "dm:<16 hex>" (a 1:1 or small group conversation, its id the hash of its members' names)
-- or "ch:<12 hex>" (one of the studio's named text channels). -> "dm" or "ch", the id; nil for anything else.
function chat.conv_of(sc)
  if type(sc) ~= "string" then return nil end
  local id = sc:match("^dm:([0-9a-f]+)$")
  if id and #id == 16 then return "dm", id end
  id = sc:match("^ch:([0-9a-f]+)$")
  if id and #id == 12 then return "ch", id end
end

function chat.dir(cfg, b, sc)
  local kind, id = chat.conv_of(sc)
  if kind == "dm" then return cfg.root .. "/_band/dm/" .. id end
  if kind == "ch" then return cfg.root .. "/_band/channels/" .. id end
  if sc == "band" then return cfg.root .. "/_band/chat" end
  if sc == "room" then return band.song_dir(cfg, b.song) .. "/rooms/" .. (b.room or "main") .. "/chat" end
  return band.song_dir(cfg, b.song) .. "/chat"
end

local function stamp(cfg) return os.date("!%Y%m%d-%H%M%S") .. "-" .. (cfg.user:gsub("[^%w]", "_")) .. "-" .. math.random(1000, 9999) end

-- The folders a scope shows, each with where it is in words: { { dir, where } }. This room: only its own. This project: the project's and
-- every room's. The group: the group's and every project's, every room's. (A project with only its listing here still has its chat.)
function chat.sources(cfg, b, sc)
  local out = {}
  if chat.conv_of(sc) then -- (a DM or a channel: its own folder, and a DM only for its members)
    if chat.scope_ok(cfg, sc) then out[1] = { chat.dir(cfg, b, sc), nil } end
    return out
  end
  local function project(song)
    local dir = band.song_dir(cfg, song)
    out[#out + 1] = { dir .. "/chat", song }
    for _, room in ipairs(band.subdirs(dir .. "/rooms")) do out[#out + 1] = { dir .. "/rooms/" .. room .. "/chat", song .. " / " .. room } end
  end
  -- (This room: its own chat, and the project's messages sent from it. Typed under This project (where Chat starts), or posted by StudioSync
  -- (a new mix), they were in the project's chat only, and This room seemed to have lost them. James, 0.58.99)
  if sc == "room" then
    out[1] = { chat.dir(cfg, b, "room"), b.room or "main" }
    out[2] = { chat.dir(cfg, b, "song"), b.room or "main", room = b.room or "main" }
  elseif sc == "song" then project(b.song)
  else
    out[1] = { cfg.root .. "/_band/chat", "Studio" }
    for _, song in ipairs(band.songs(cfg)) do project(song) end
  end
  return out
end
-- Where a message came from, in words, or nil when it's from here (James, 0.59.3): This room says nothing; This project names a room only when it
-- isn't the one you're in; Studio names a project only when it isn't the one you're in.
function chat.where_label(where, b, sc)
  if not where or sc == "room" or chat.conv_of(sc) then return nil end
  local here_song, here_room = b.song or "", b.song and (b.song .. " / " .. (b.room or "main")) or ""
  if sc == "song" then
    if where == here_song or where == here_room or where == (b.room or "main") then return nil end
    return (where:gsub("^" .. here_song:gsub("%p", "%%%0") .. " / ", ""))
  end
  if where == "Studio" or where == here_song or where:sub(1, #here_song + 3) == here_song .. " / " then return nil end
  return where
end
-- Messages over the direct link (lib/direct.lua; James, 0.60.0-rt): shown at once, until their file is here (the file is the record). The panel
-- polls its own: Live sync is another script. path -> the message.
local live_msgs = {}
function chat.from_msg(cfg, d)
  local direct = require("direct")
  if type(d) ~= "table" or not (d.sc == "room" or d.sc == "song" or d.sc == "band" or chat.conv_of(d.sc)) or not direct.plain(d.song) or not direct.plain(d.room)
    or type(d.name) ~= "string" or not d.name:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-[%w_]+%-%d+$") or type(d.v) ~= "table"
    or type(d.v.text) ~= "string" or type(d.v.user) ~= "string" or d.v.user == cfg.user or type(d.v.time) ~= "string" then return false end
  -- (a DM says who's in it, and only a member takes it: its members.json may not have come through Syncthing yet. rt-chat2)
  local kind, id = chat.conv_of(d.sc)
  if kind == "dm" then
    local m = chat.names_ok(d.members)
    if not (m and chat.dm_id(m) == id and chat.has(m, cfg.user) and chat.has(m, d.v.user)) then return false end
  end
  local path = chat.dir(cfg, { song = d.song, room = d.room }, d.sc) .. "/msgs/" .. d.name .. ".json"
  if live_msgs[path] or reaper.file_exists(path) then return false end
  live_msgs[path] = { text = d.v.text, user = d.v.user, time = d.v.time, room = type(d.v.room) == "string" and d.v.room or nil, title = "",
    attach = require("chatfiles").check(d.v.attach), join = require("invite").join_ok(d.v.join) } -- (join: a join request, lib/invite.lua)
  cache = nil
  return true
end
function chat.take_live(cfg)
  local direct = require("direct")
  local ok, msgs = pcall(direct.messages, cfg)
  if ok then direct.dispatch(msgs, nil, nil, { chat = function(d) chat.from_msg(cfg, d) end }) end
end
-- What a scope shows (sc: "room", "song" or "band"; the page's own by default): { msgs, todo, links }, each oldest first, with the live
-- messages not yet here as files. Kept 3 s. (The web UI reads it from Live sync, which takes the link's messages itself: lib/webui.lua. James, rt)
function chat.read(cfg, b, sc)
  sc = sc or scope
  local key = sc .. "\0" .. (b.song or "") .. "\0" .. (b.room or "") .. "\0" .. cfg.root .. "\0" .. tostring(cfg.user) -- (a DM shows only to its members)
  if cache and key == cache_key and reaper.time_precise() - cache_at < 3 then return cache end
  local t = { msgs = {}, todo = {}, links = {} }
  for _, src in ipairs(chat.sources(cfg, b, sc)) do
    for kind in pairs(t) do
      for _, f in ipairs(band.files(src[1] .. "/" .. kind, ".json")) do
        local v = band.read_json(src[1] .. "/" .. kind .. "/" .. f)
        -- (a link with no url, from a bandmate's damaged or newer file, errored every frame. Review, 0.58.47)
        local here = not src.room or v == nil or type(v) ~= "table" or v.room == src.room or (v.room == nil and src.room == "main")
        if here and type(v) == "table" and (kind ~= "links" or type(v.url) == "string") then
          if type(v.title) ~= "string" then v.title = "" end
          v.file, v.where = src[1] .. "/" .. kind .. "/" .. f, src[2]; t[kind][#t[kind] + 1] = v
        end
      end
    end
  end
  for path, v in pairs(live_msgs) do -- (until its file is here)
    if reaper.file_exists(path) then live_msgs[path] = nil
    else
      for _, src in ipairs(chat.sources(cfg, b, sc)) do
        if path:sub(1, #src[1] + 6) == src[1] .. "/msgs/" and (not src.room or v.room == src.room or (v.room == nil and src.room == "main")) then
          local m = {}
          for k, x in pairs(v) do m[k] = x end
          m.file, m.where = path, src[2]
          t.msgs[#t.msgs + 1] = m
          break
        end
      end
    end
  end
  for kind in pairs(t) do table.sort(t[kind], function(a, x) return (a.time or "") < (x.time or "") end) end
  for _, m in ipairs(t.msgs) do -- (a file sent in the chat: is it here yet, saved, offered for download. lib/chatfiles.lua; rt-chat2)
    if m.attach ~= nil then m.attach = require("chatfiles").check(m.attach); m.fstat = m.attach and require("chatfiles").status(cfg, m) end
  end
  cache, cache_at, cache_key = t, reaper.time_precise(), key
  return t
end
-- The newest messages and to-dos of a scope without reading the rest (Home's read of the whole studio's chat every 15 s: rt-p5, rt-home's
-- wish). Names begin with their UTC stamp, so the newest are known from the folder listing alone; only those files are read, and a message
-- (never changed once written) is kept from one read to the next, so a quiet studio costs the listings. -> { msgs, todo }, each oldest first, as
-- chat.read's (file, where; links and live messages not included). k: messages, kt: to-dos (a to-do's done flag changes: read each time).
chat.NEWEST_MAX = 300
local newest_memo, newest_n = {}, 0
function chat.newest(cfg, b, sc, k, kt)
  local t = { msgs = {}, todo = {} }
  for _, kind in ipairs({ "msgs", "todo" }) do
    local want = math.max(1, math.min(tonumber(kind == "msgs" and k or kt or k) or 40, chat.NEWEST_MAX))
    local names = {}
    for _, src in ipairs(chat.sources(cfg, b, sc)) do
      for _, f in ipairs(band.files(src[1] .. "/" .. kind, ".json")) do names[#names + 1] = { src = src, f = f, key = f:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d") or "" } end
    end
    table.sort(names, function(x, y) if x.key ~= y.key then return x.key > y.key end return x.f > y.f end)
    for i = 1, math.min(#names, want) do
      local n = names[i]
      local path = n.src[1] .. "/" .. kind .. "/" .. n.f
      local v = kind == "msgs" and newest_memo[path] or nil
      if not v then
        v = band.read_json(path)
        if kind == "msgs" and type(v) == "table" then
          if newest_n >= 600 then newest_memo, newest_n = {}, 0 end
          newest_memo[path], newest_n = v, newest_n + 1
        end
      end
      local here = not n.src.room or type(v) ~= "table" or v.room == n.src.room or (v.room == nil and n.src.room == "main")
      if type(v) == "table" and here then
        local m = {}
        for kk, x in pairs(v) do m[kk] = x end
        m.file, m.where = path, n.src[2]
        t[kind][#t[kind] + 1] = m
      end
    end
    table.sort(t[kind], function(x, y) return (x.time or "") < (y.time or "") end)
  end
  return t
end
local function load(cfg, b)
  chat.take_live(cfg)
  return chat.read(cfg, b, scope)
end

local index_v -- (the conversations and their unread counts, chat.index: dropped when something's written here)
local function add(cfg, b, kind, v, sc, name)
  sc = sc or scope
  local d = chat.dir(cfg, b, sc) .. "/" .. kind
  reaper.RecursiveCreateDirectory(d, 0)
  v.user, v.time, v.room = cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ"), b and b.room or "main" -- (the room it was sent from: This room shows it)
  name = name or stamp(cfg)
  band.write_json(d .. "/" .. name .. ".json", v)
  cache, index_v = nil, nil
  local dm, members = chat.conv_of(sc) == "dm", nil
  if dm then members = chat.dm_members(cfg, select(2, chat.conv_of(sc))) end
  if kind == "msgs" and b and b.song then -- (to those here at once, over the direct link: chat.from_msg. James, 0.60.0-rt)
    -- (a DM goes only to its members' computers, never to everyone in the room. rt-chat2)
    local to = dm and require("chatfiles").reachable(cfg, b, members or {}) or nil
    if not to or #to > 0 then
      require("direct").send_live(cfg, "chat", { sc = sc, song = b.song, room = b.room or "main", name = name, v = v, members = members },
        b.song, b.room or "main", name, to)
    end
  end
  if dm then return end -- (no phone alert, no API event: the studio's alert channel reaches everyone's phone)
  if kind == "msgs" and type(v.text) == "string" then
    pcall(require("alerts").send, cfg, "chat", "StudioSync: " .. tostring(b.song), cfg.user .. ": " .. v.text)
    pcall(require("api").event, "chat", { text = v.text, song = b.song, user = cfg.user })
  end
end

-- Something said for the band from elsewhere (a mix rendered, say): a message in this project's chat.
-- sc: another scope ("room", "band"); the project's by default. (The web UI's messages come this way: lib/webui.lua)
-- extra: more fields for the message (a join request's `join`, its answer's `join_answer`: lib/invite.lua).
function chat.post(cfg, b, text, sc, extra)
  local v = { text = text }
  for k, x in pairs(type(extra) == "table" and extra or {}) do if k ~= "text" and k ~= "user" and k ~= "time" then v[k] = x end end
  add(cfg, b, "msgs", v, sc or "song")
end
-- To-dos and links, ticking one off and deleting your own: the panel's tabs and the web UI's Chat (chat.web_action) both go through these.
-- for_user: who it's for (a person of the studio, you included), shown to them on Home's "For you". rt-p5, rt-home's wish
function chat.add_todo(cfg, b, text, sc, for_user) add(cfg, b, "todo", { text = text, done = false, ["for"] = type(for_user) == "string" and for_user ~= "" and for_user or nil }, sc) end
function chat.add_link(cfg, b, title, url, sc) add(cfg, b, "links", { title = title, url = url }, sc) end
function chat.set_done(cfg, d, v) d.done, d.done_by = v, cfg.user; local f = d.file; d.file = nil; band.write_json(f, d); cache = nil end
function chat.remove(cfg, e) -- -> true when it was yours and is gone (for everyone)
  if e.user ~= cfg.user then return false end
  os.remove(e.file); cache = nil
  return true
end

-- ---- the web UI's Chat (lib/webui.lua hands each action over; James, rt) -----------------------------------------------------------------
chat.SCOPE_OK = { room = true, song = true, band = true }

-- ---- direct messages and channels (rt-chat2) ----------------------------------------------------------------------------------------------
-- A DM lives in <studio>/_band/dm/<id>/ (members.json, then msgs/ as any chat), its id the hash of its members' names sorted, so the same
-- people always reach the same conversation and a members.json whose list doesn't hash to its folder is no DM. A channel lives in
-- <studio>/_band/channels/<id>/ (channel.json: name, archived; then msgs/, todo/, links/). Both are in the shared folder: see
-- docs/rt/rt-chat2.md for who can really read them.
chat.DM_MAX, chat.NAME_MAX, chat.CHANNEL_MAX = 8, 64, 40
function chat.has(list, x) for _, v in ipairs(type(list) == "table" and list or {}) do if v == x then return true end end return false end
-- names -> them sorted, each once, or nil when one isn't a name or there are fewer than 2 or more than DM_MAX. Pure.
function chat.names_ok(names)
  if type(names) ~= "table" then return nil end
  local seen, out = {}, {}
  for _, n in ipairs(names) do
    if type(n) ~= "string" or n == "" or #n > chat.NAME_MAX or n:find("%c") then return nil end
    if not seen[n] then seen[n] = true; out[#out + 1] = n end
  end
  if #out < 2 or #out > chat.DM_MAX then return nil end
  table.sort(out)
  return out
end
function chat.dm_id(members) return band.code_hash(table.concat(members, "\n")) end -- (members: names_ok's)
local dm_cache = {} -- root\0id -> { at, members or false }
function chat.dm_members(cfg, id)
  local k, now = cfg.root .. "\0" .. tostring(id), reaper.time_precise()
  local c = dm_cache[k]
  if c and now - c.at < 10 then return c.m or nil end
  local v = band.read_json(cfg.root .. "/_band/dm/" .. tostring(id) .. "/members.json")
  local m = type(v) == "table" and chat.names_ok(v.members)
  if m and chat.dm_id(m) ~= id then m = nil end -- (a list rewritten to add someone no longer hashes to its folder)
  dm_cache[k] = { at = now, m = m or false }
  return m or nil
end
-- The studio's people (from its devices files), not you: who a DM can be with. Kept 30 s.
local people_c = {}
function chat.people(cfg)
  local c = people_c[cfg.root]
  if c and reaper.time_precise() - c.at < 30 then return c.list end
  local seen, list = { [cfg.user] = true }, {}
  for _, f in ipairs(band.files(cfg.root .. "/_band/devices", ".json")) do
    local d = band.read_json(cfg.root .. "/_band/devices/" .. f)
    local u = type(d) == "table" and d.user
    if type(u) == "string" and u ~= "" and #u <= chat.NAME_MAX and not u:find("%c") and not seen[u] then seen[u] = true; list[#list + 1] = u end
  end
  table.sort(list)
  people_c[cfg.root] = { at = reaper.time_precise(), list = list }
  return list
end
-- A DM with these people (you're added): its id, made the first time (members.json, written once). -> id, or nil and why.
function chat.dm_open(cfg, names)
  local all = { cfg.user }
  for _, n in ipairs(type(names) == "table" and names or {}) do
    if not chat.has(chat.people(cfg), n) and n ~= cfg.user then return nil, tostring(n) .. " isn't in the studio" end
    all[#all + 1] = n
  end
  local m = chat.names_ok(all)
  if not m then return nil, "a direct message is with 1 to " .. (chat.DM_MAX - 1) .. " others" end
  local id = chat.dm_id(m)
  local f = cfg.root .. "/_band/dm/" .. id .. "/members.json"
  if not reaper.file_exists(f) then
    reaper.RecursiveCreateDirectory(cfg.root .. "/_band/dm/" .. id, 0)
    band.write_json(f, { members = m, by = cfg.user, time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
  end
  dm_cache[cfg.root .. "\0" .. id], index_v = nil, nil
  return id
end
-- The DMs you're in: { { id, members } }, kept 5 s.
local dms_c = {}
function chat.dms(cfg)
  local c = dms_c[cfg.root]
  if c and reaper.time_precise() - c.at < 5 then return c.list end
  local list = {}
  for _, id in ipairs(band.subdirs(cfg.root .. "/_band/dm")) do
    local m = id:match("^[0-9a-f]+$") and #id == 16 and chat.dm_members(cfg, id)
    if m and chat.has(m, cfg.user) then list[#list + 1] = { id = id, members = m } end
  end
  dms_c[cfg.root] = { at = reaper.time_precise(), list = list }
  return list
end
-- The studio's channels: { { id, name, archived } } by name, kept 5 s.
local ch_c = {}
function chat.channels(cfg)
  local c = ch_c[cfg.root]
  if c and reaper.time_precise() - c.at < 5 then return c.list end
  local list = {}
  for _, id in ipairs(band.subdirs(cfg.root .. "/_band/channels")) do
    local v = id:match("^[0-9a-f]+$") and #id == 12 and band.read_json(cfg.root .. "/_band/channels/" .. id .. "/channel.json")
    if type(v) == "table" and type(v.name) == "string" and v.name ~= "" then
      list[#list + 1] = { id = id, name = v.name:sub(1, 200), archived = v.archived == true or nil }
    end
  end
  table.sort(list, function(a, z) return a.name:lower() < z.name:lower() end)
  ch_c[cfg.root] = { at = reaper.time_precise(), list = list }
  return list
end
function chat.channel(cfg, id) for _, c in ipairs(chat.channels(cfg)) do if c.id == id then return c end end end
-- Owner and admins: c = { new = name } | { id, name } (rename) | { id, archive = true/false }. -> words for the log when refused, or nil.
function chat.channel_action(cfg, c)
  if not require("groups").may_manage(cfg.root, cfg.user) then return "only the studio's owner and admins make, rename or archive channels" end
  local name = c.new or c.name
  if name ~= nil then
    name = require("webui").clean_text(name)
    name = name and name:gsub("^#+%s*", "")
    if not name or name == "" or #name > chat.CHANNEL_MAX then return "a channel's name is 1 to " .. chat.CHANNEL_MAX .. " characters" end
  end
  local id = c.new and band.secret(12) or (type(c.id) == "string" and chat.channel(cfg, c.id) and c.id)
  if not id then return "no such channel" end
  local f = cfg.root .. "/_band/channels/" .. id .. "/channel.json"
  local v = band.read_json(f) or {}
  if name then v.name = name end
  if c.archive ~= nil then v.archived = c.archive == true or nil end
  v.by, v.time = cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ")
  reaper.RecursiveCreateDirectory(cfg.root .. "/_band/channels/" .. id, 0)
  band.write_json(f, v)
  ch_c[cfg.root], index_v = nil, nil
end
-- May this computer's user see (and with `write`, write in) the scope? The three of the project's are always theirs; a DM only its members',
-- a channel while it's there (an archived one is read-only).
function chat.scope_ok(cfg, sc, write)
  if chat.SCOPE_OK[sc] then return true end
  local kind, id = chat.conv_of(sc)
  if kind == "dm" then return chat.has(chat.dm_members(cfg, id), cfg.user) end
  if kind == "ch" then local c = chat.channel(cfg, id); return c ~= nil and not (write and c.archived) end
  return false
end
function chat.topic_of(sc) -- the web UI's topic for a DM or a channel ("chat_dm_<id>", "chat_ch_<id>": the server's topic rule)
  local kind, id = chat.conv_of(sc)
  return kind and ("chat_" .. kind .. "_" .. id) or nil
end

-- One of a scope's messages, to-dos or links, named by its file's name (what lib/webui.lua's chat_model gives the pages as its id): only what
-- that scope's own listing holds can be touched, never a path a page made up.
function chat.find(cfg, b, sc, kind, id)
  if type(id) ~= "string" or not id:match("^[%w_%-]+$") or not chat.scope_ok(cfg, sc) then return nil end
  for _, v in ipairs(chat.read(cfg, b, sc)[kind] or {}) do
    if type(v.file) == "string" and v.file:match("([^/\\]+)%.json$") == id then return v end
  end
end
local conv_want, web_dirty = {}, false -- (a DM or channel a page shows -> until when; something changed: the index goes again)
local notes_want = -math.huge -- (a page shows All for This room or This project: the room's notes and likes go as "chat_notes" until then. rt-ui9)
-- a: { scope, and text (a message), todo (a new to-do's text), title + url (a link), done = id + on (ticked or not), delete = { kind, id },
-- seen (you've read the scope), want (a DM or channel shown), dm = { names } (open a DM), channel = { new | id, name | archive } (admins),
-- file = { id (POST /api/upload's), name, size }, save / download = a message's id (into = "project": an audio file to the project's folder) }.
-- The page acts as this computer's user, as the panel does: anyone ticks a to-do, only the writer deletes. -> words for the log, or nil.
function chat.web_action(cfg, b, a)
  local clean = require("webui").clean_text
  if type(a.dm) == "table" then
    web_dirty = true
    local id, why = chat.dm_open(cfg, a.dm)
    if not id then return "the web page's direct message wasn't opened: " .. why end
  end
  if type(a.channel) == "table" then web_dirty = true; return chat.channel_action(cfg, a.channel) end
  if a.notes == true then notes_want = reaper.time_precise() + 30; web_dirty = true end -- (All shows the room's notes and likes: rt-ui9)
  local sc = a.scope
  if chat.conv_of(sc) then
    -- (never the project's chat instead: a DM sent there would be read by everyone)
    if not chat.scope_ok(cfg, sc) then return "the web page wrote to a conversation that isn't yours, or isn't there: nothing done" end
    if a.want == sc then conv_want[sc] = reaper.time_precise() + 30; web_dirty = true end
  elseif not chat.SCOPE_OK[sc] then sc = "song" end
  local text, todo, url = clean(a.text), clean(a.todo), clean(a.url)
  if (text or todo or url or type(a.file) == "table") and not chat.scope_ok(cfg, sc, true) then return "that channel is archived: nothing sent" end
  if a.seen == true then chat.mark_seen(cfg, b, sc) end
  if text then chat.post(cfg, b, text, sc) end
  if todo then
    local who = type(a.todofor) == "string" and a.todofor or nil
    if who and who ~= cfg.user and not chat.has(chat.people(cfg), who) then who = nil end -- (someone of the studio, or nobody)
    chat.add_todo(cfg, b, todo, sc, who)
  end
  if url then chat.add_link(cfg, b, clean(a.title) or "", url, sc) end
  if a.done ~= nil then
    local d = chat.find(cfg, b, sc, "todo", a.done)
    if d then chat.set_done(cfg, d, a.on == true) end
  end
  if type(a.delete) == "table" then
    local kind = ({ msgs = "msgs", todo = "todo", links = "links" })[a.delete.kind]
    local e = kind and chat.find(cfg, b, sc, kind, a.delete.id)
    if e and not chat.remove(cfg, e) then return "the web page asked to delete " .. tostring(e.user) .. "'s " .. kind .. " entry: only its writer may" end
  end
  local files = require("chatfiles")
  if type(a.file) == "table" then -- (a file dropped on a person or a conversation)
    local name = stamp(cfg)
    local kind, id = chat.conv_of(sc)
    local att, why = files.send(cfg, b, chat.dir(cfg, b, sc), a.file, name, kind == "dm" and chat.dm_members(cfg, id) or nil)
    if not att then return "a file from the web page wasn't sent: " .. why end
    add(cfg, b, "msgs", { text = "sent a file: " .. att.name, attach = att }, sc, name)
  end
  local which = type(a.save) == "string" and a.save or type(a.download) == "string" and a.download
  if which then
    local m = chat.find(cfg, b, sc, "msgs", which)
    if not (m and m.attach) then return "the web page asked for a file that isn't in that conversation" end
    cache, web_dirty = nil, true
    return files.save(cfg, m, a.download and "download" or (a.into == "project" and "project" or "keep"))
  end
end

-- ---- unread, seen, @mentions --------------------------------------------------------------------------------------------------------------
-- Messages newer than the last time this person looked at the song's chat (for the tab's count).
local unread_at, unread_n, unread_song = -math.huge, 0, nil
function chat.unread(cfg, b)
  if not b or not b.song then return 0 end
  if b.song == unread_song and reaper.time_precise() - unread_at < 5 then return unread_n end -- (drawn every frame)
  unread_at, unread_song = reaper.time_precise(), b.song
  unread_n = chat.count_unread(cfg, b)
  return unread_n
end
local function seen_key(b, sc)
  if chat.conv_of(sc) then return "chat seen " .. sc end
  return "chat seen " .. sc .. " " .. (sc == "band" and "" or b.song) .. (sc == "room" and (" " .. (b.room or "main")) or "")
end
-- Does `text` mention any of `names` ("@Bo", any case, not "@Bobby")? names: one name or a list (a user name, a display name, everyone: names_of).
-- (Home, the chat's counts and the page agree on what a mention is: rt-p5.) Pure.
function chat.mentions(text, names)
  if type(text) ~= "string" or not text:find("@", 1, true) then return false end
  if type(names) == "string" then names = { names } end
  if type(names) ~= "table" then return false end
  local t = text:lower()
  for _, me in ipairs(names) do
    if type(me) == "string" and me ~= "" then
      local m, i = "@" .. me:lower(), 1
      while true do
        local s, e = t:find(m, i, true)
        if not s then break end
        if not t:sub(e + 1, e + 1):match("[%w_]") then return true end
        i = e + 1
      end
    end
  end
  return false
end
chat.EVERYONE = { "everyone", "all" } -- (@everyone and @all mention every member)
-- What mentions you: your user name, your display name (lib/profile.lua) and everyone. Pure but for the profile files it reads.
function chat.names_of(cfg)
  local names = { cfg.user }
  local ok, all = pcall(function() return require("profile").all(cfg.root) end)
  local me = ok and type(all) == "table" and all[cfg.user] or nil
  if type(me) == "table" and type(me.name) == "string" and me.name ~= "" and me.name ~= cfg.user then names[#names + 1] = me.name end
  -- (and your person's name, your computers folded into one: "@James" is James-Laptop and James-Main. lib/persons.lua, rt-people)
  local okp, p = pcall(function() return require("persons").map(cfg.root)[cfg.user] end)
  if okp and type(p) == "table" and type(p.name) == "string" and p.name ~= "" and not chat.has(names, p.name) then names[#names + 1] = p.name end
  for _, n in ipairs(chat.EVERYONE) do names[#names + 1] = n end
  return names
end
-- A scope's messages (its own folder) newer than you last read it, not yours: how many, and how many of those mention you.
chat.MENTION_READS = 200
-- ---- read on another of your computers (rt-people) ---------------------------------------------------------------------------------------
-- With computers folded into one person (lib/persons.lua), what you read on one counts as read on the others: each writes what it marked
-- seen to _band/seen/<name>.json ({ user, at, seen = { [seen key] = stamp } }, its own file, only while it has other computers), and each
-- reads its other computers' files, counted only when Syncthing says that computer wrote it (trust.own_file_ok). And your own messages from
-- another of your computers aren't unread to you.
chat.SEEN_KEYS = 300
local function seen_rel(user) return "_band/seen/" .. (tostring(user):gsub("[^%w%-_ ]", "")) .. ".json" end
local function my_others(cfg)
  local ok, p = pcall(function() return require("persons").map(cfg.root)[cfg.user] end)
  local out = {}
  for _, u in ipairs(ok and type(p) == "table" and p.users or {}) do if u ~= cfg.user then out[#out + 1] = u end end
  return out
end
local function share_seen(cfg, moved)
  if #my_others(cfg) == 0 then return end
  local path = cfg.root .. "/" .. seen_rel(cfg.user)
  local cur = band.read_json(path)
  local seen, list = type(cur) == "table" and type(cur.seen) == "table" and cur.seen or {}, {}
  for k, s in pairs(moved) do if type(seen[k]) ~= "string" or seen[k] < s then seen[k] = s end end
  for k, s in pairs(seen) do if type(k) == "string" and type(s) == "string" then list[#list + 1] = { k, s } end end
  table.sort(list, function(x, y) return x[2] > y[2] end)
  local keep = {}
  for i = 1, math.min(#list, chat.SEEN_KEYS) do keep[list[i][1]] = list[i][2] end
  reaper.RecursiveCreateDirectory(cfg.root .. "/_band/seen", 0)
  band.write_json(path, { user = cfg.user, at = os.time(), seen = keep })
end
local others_c = {} -- root .. user -> { at, seen }
function chat.others_seen(cfg)
  local k = cfg.root .. "\0" .. cfg.user
  local c = others_c[k]
  if c and reaper.time_precise() - c.at < 10 then return c.seen end
  local out = {}
  for _, u in ipairs(my_others(cfg)) do
    local d = band.read_json(cfg.root .. "/" .. seen_rel(u))
    if type(d) == "table" and d.user == u and type(d.seen) == "table" then
      local ok, said = pcall(require("trust").own_file_ok, cfg.root, seen_rel(u), u, d.at)
      if ok and said == true then
        local n = 0
        for key, s in pairs(d.seen) do
          n = n + 1
          if n > chat.SEEN_KEYS then break end
          if type(key) == "string" and type(s) == "string" and s:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$") and (out[key] or "") < s then out[key] = s end
        end
      end
    end
  end
  others_c[k] = { at = reaper.time_precise(), seen = out }
  return out
end
function chat.unread_in(cfg, b, sc)
  local key = seen_key(b, sc)
  local seen = reaper.GetExtState(band.SECTION, key) -- (each scope has its own: reading one doesn't clear the others)
  local other = chat.others_seen(cfg)[key]
  if other and other > seen then seen = other end
  local dir, n, at = chat.dir(cfg, b, sc) .. "/msgs", 0, 0
  local mine = { "-" .. (cfg.user:gsub("[^%w]", "_")) .. "-" }
  for _, u in ipairs(my_others(cfg)) do mine[#mine + 1] = "-" .. (u:gsub("[^%w]", "_")) .. "-" end
  local function is_mine(f) for _, m in ipairs(mine) do if f:find(m, 1, true) then return true end end return false end
  local names = chat.names_of(cfg)
  for _, f in ipairs(band.files(dir, ".json")) do
    if f:sub(1, 15) > seen and not is_mine(f) then
      n = n + 1
      if n <= chat.MENTION_READS then
        local v = band.read_json(dir .. "/" .. f)
        if type(v) == "table" and chat.mentions(v.text, names) then at = at + 1 end
      end
    end
  end
  return n, at
end
function chat.count_unread(cfg, b)
  local n = 0
  for _, sc in ipairs(SCOPES) do n = n + chat.unread_in(cfg, b, sc[1]) end
  return n
end
-- The other scopes whose every message a scope's view shows, by their seen keys: This project shows each room's chat, Studio every project's
-- and room's (chat.sources). Reading those views read them too. (They stayed unread: a room's messages read under This project, where Chat
-- starts, still counted on the tab, Home and the phone, as only This project's own key moved. rt-people, James's findings 2026-11-27)
local function covered(cfg, b, sc)
  local out = {}
  local function rooms_of(song)
    for _, room in ipairs(band.subdirs(band.song_dir(cfg, song) .. "/rooms")) do out[#out + 1] = seen_key({ song = song, room = room }, "room") end
  end
  if sc == "song" and b.song then rooms_of(b.song)
  elseif sc == "band" then
    for _, song in ipairs(band.songs(cfg)) do out[#out + 1] = seen_key({ song = song }, "song"); rooms_of(song) end
  end
  return out
end
chat.seen_gen = 0 -- (one more each time something was marked seen here: Home's unread count is built again at once. lib/webhome.lua)
local cascaded = {} -- seen key -> the newest it was last carried to the covered scopes with (once per new message, not every frame)
-- You've read a scope: its newest message counts as seen, and in the scopes its view covers (the panel's Messages tab does the same as it's
-- drawn, passing what it shows as t).
function chat.mark_seen(cfg, b, sc, t)
  if not b then return end
  t = t or chat.read(cfg, b, sc)
  local newest = ""
  for _, m in ipairs(t.msgs) do -- (the newest name, not the last by time: what unread_in compares)
    local s = type(m.file) == "string" and (m.file:match("([^/\\]+)$") or ""):sub(1, 15) or ""
    if s > newest then newest = s end
  end
  local k, moved, changed = seen_key(b, sc), {}, false
  local function mark(key) if reaper.GetExtState(band.SECTION, key) < newest then reaper.SetExtState(band.SECTION, key, newest, true); moved[key], changed = newest, true end end
  mark(k)
  if newest ~= "" and cascaded[k] ~= newest then
    cascaded[k] = newest
    for _, ck in ipairs(covered(cfg, b, sc)) do mark(ck) end
  end
  if changed then
    index_v, unread_at, chat.seen_gen = nil, -math.huge, chat.seen_gen + 1
    pcall(share_seen, cfg, moved) -- (and to your other computers: rt-people)
  end
end
-- Every conversation you can see with its unread count and @mentions: { total, mentions, convs = { { scope, kind ("here", "ch", "dm"),
-- name, n, at, members, archived } } }. The total leaves archived channels out. Kept 5 s.
local index_at, index_key = -math.huge, nil
function chat.index(cfg, b)
  local key = cfg.root .. "\0" .. tostring(b and b.song) .. "\0" .. tostring(b and b.room)
  if index_v and key == index_key and reaper.time_precise() - index_at < 5 then return index_v end
  local convs = {}
  local function conv(c) c.n, c.at = chat.unread_in(cfg, b, c.scope); convs[#convs + 1] = c end
  if b and b.song then conv({ scope = "room", kind = "here", name = "This room" }); conv({ scope = "song", kind = "here", name = "This project" }) end
  conv({ scope = "band", kind = "here", name = "Studio" })
  for _, c in ipairs(chat.channels(cfg)) do conv({ scope = "ch:" .. c.id, kind = "ch", name = c.name, archived = c.archived }) end
  for _, d in ipairs(chat.dms(cfg)) do
    local others = {}
    for _, m in ipairs(d.members) do if m ~= cfg.user then others[#others + 1] = m end end
    conv({ scope = "dm:" .. d.id, kind = "dm", name = table.concat(others, ", "), members = d.members })
  end
  local total, at = 0, 0
  for _, c in ipairs(convs) do if not c.archived then total, at = total + c.n, at + c.at end end
  index_v, index_at, index_key = { total = total, mentions = at, convs = convs }, reaper.time_precise(), key
  return index_v
end
-- For a Home page's badge: { total, mentions, by = { [scope] = { n, at, name, kind } } }. b may be nil (no project open: the Studio, channels
-- and DMs only).
function chat.unread_summary(cfg, b)
  local x, by = chat.index(cfg, b), {}
  for _, c in ipairs(x.convs) do by[c.scope] = { n = c.n, at = c.at, name = c.name, kind = c.kind } end
  return { total = x.total, mentions = x.mentions, by = by }
end
-- What the web UI's conversation list shows (topic "chat_index").
function chat.index_model(cfg, b)
  local x, files = chat.index(cfg, b), require("chatfiles")
  return { me = cfg.user, admin = require("groups").may_manage(cfg.root, cfg.user) == true, people = chat.people(cfg), total = x.total,
    mentions = x.mentions, convs = x.convs, file_max = files.MAX, file_ext = files.EXTS, dm_max = chat.DM_MAX }
end
-- Live sync's web UI tick (lib/webui.lua): files on their way (always), and while a page looks, the index and each DM or channel a page shows,
-- every 2 s or at once after an action.
local web_at = -math.huge
-- The room's notes and likes for the web chat's All (topic "chat_notes"), as the panel's All shows them: newest first, NOTES_MAX at most, only
-- what a page needs (rt-ui9, docs/rt/ui-web-plan.md 1.3 "Notes and Likes join Chat's All"). notes: recall.notes's. Pure.
chat.NOTES_MAX, chat.NOTE_TEXT_MAX = 100, 2000
function chat.notes_model(song, room, notes)
  local out = {}
  for _, e in ipairs(type(notes) == "table" and notes or {}) do
    if #out >= chat.NOTES_MAX then break end
    if type(e) == "table" and (e.type == "note" or e.type == "like") then
      out[#out + 1] = { id = type(e.id) == "string" and e.id or nil, type = e.type, user = tostring(e.user or "?"),
        time = type(e.time) == "string" and e.time or nil, text = e.type == "note" and tostring(e.text or ""):sub(1, chat.NOTE_TEXT_MAX) or nil,
        track = type(e.track) == "string" and e.track:sub(1, 200) or nil, pos = tonumber(e.pos) }
    end
  end
  return { song = song, room = room or "main", notes = out }
end
function chat.web_tick(cfg, b, publish, now, look)
  local ok, e = pcall(require("chatfiles").tick, cfg, now)
  if not ok then band.log("chat files: " .. tostring(e)) end
  local noting = look and b and b.song and notes_want > reaper.time_precise()
  -- (a little of the room's changes each tick while All shows, as the panel's Chat page reads them: lib/recall.lua)
  if noting then pcall(require("recall").warm, cfg, b.song, b.room, 0.004, false) end
  if not look or (now - web_at < 2 and not web_dirty) then return end
  web_at, web_dirty = now, false
  publish("chat_index", chat.index_model(cfg, b))
  if noting then
    local okn, m = pcall(function() return chat.notes_model(b.song, b.room, require("recall").notes(cfg, b.song, b.room)) end)
    if okn then publish("chat_notes", m) end
  end
  local webui = require("webui")
  for sc, til in pairs(conv_want) do
    if til < now then conv_want[sc] = nil
    elseif chat.scope_ok(cfg, sc) then publish(chat.topic_of(sc), webui.chat_model(chat.read(cfg, b, sc), nil, nil, sc)) end
  end
end

-- "2026-10-30T21:05:00Z" -> "Thu 21:05" (this machine's time)
local function when(iso)
  local utc = band.iso_time(iso)
  if not utc then return "" end
  local now = os.time()
  local offset = os.difftime(now, os.time(os.date("!*t", now)))
  local t = utc + offset
  return os.date(os.date("%Y%m%d", t) == os.date("%Y%m%d") and "%H:%M" or "%a %d %b %H:%M", t)
end
local function delete_mine(ctx, ImGui, cfg, e)
  if e.user ~= cfg.user then return end
  ImGui.SameLine(ctx)
  if ImGui.GetContentRegionAvail(ctx) < 30 then ImGui.NewLine(ctx) end -- (after a long row it ran off the panel: Mac, 0.51.13)
  if ImGui.SmallButton(ctx, "x") and reaper.MB("Delete this for everyone?", "StudioSync", 4) == 6 then chat.remove(cfg, e) end
  ImGui.SetItemTooltip(ctx, "Delete yours (for everyone).")
end

-- A text box with a button beside it. (Not EnterReturnsTrue: with it the text only comes back on Return, so pressing the button lost what was typed and sent
-- nothing: James and the Mac both hit it.) -> Return was pressed in it, the text.
function chat.input(ctx, ImGui, id, hint, text)
  local _, v = ImGui.InputTextWithHint(ctx, id, hint, text)
  return ImGui.IsItemDeactivated(ctx) and (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)), v
end

-- ---------------------------------------------------------------- All (James, 0.58.81)
-- Everything said or marked here, newest first: messages, to-dos and links (in the scope picked above), and this room's notes, likes and
-- drawings, each with its time, and Go for what sits on the timeline. Filters along the top; the Everyone box applies too.
chat.KINDS = { { "msgs", "Messages" }, { "todo", "To-dos" }, { "links", "Links" }, { "note", "Notes" }, { "like", "Likes" }, { "draw", "Drawings" } }
local drawn_at, drawn = -math.huge, {}
local function drawings(cfg, b)
  if reaper.time_precise() - drawn_at < 3 then return drawn end
  drawn_at, drawn = reaper.time_precise(), {}
  local d = band.song_dir(cfg, b.song) .. "/rooms/" .. (b.room or "main") .. "/drawings"
  for _, f in ipairs(band.files(d, ".json")) do
    local s = band.read_json(d .. "/" .. f)
    if type(s) == "table" and type(s.points) == "table" and type(s.points[1]) == "table" then drawn[#drawn + 1] = s end
  end
  return drawn
end
-- The rows, newest first. `notes`: the room's notes and likes (recall.notes). Pure but for reading the folders.
function chat.all_rows(cfg, b, notes)
  local t, rows = load(cfg, b), {}
  for _, kind in ipairs({ "msgs", "todo", "links" }) do
    for _, v in ipairs(t[kind]) do
      rows[#rows + 1] = { kind = kind, time = v.time or "", user = v.user, where = v.where,
        text = kind == "links" and ((v.title ~= "" and v.title or v.url) .. "  " .. tostring(v.url)) or (kind == "todo" and ((v.done and "[done] " or "[ ] ") .. tostring(v.text)) or tostring(v.text)),
        url = kind == "links" and v.url or nil }
    end
  end
  for _, e in ipairs(notes or {}) do
    if e.type == "note" or e.type == "like" then
      rows[#rows + 1] = { kind = e.type, time = e.time or "", user = e.user, text = e.type == "like" and ("liked a take" .. (e.track and (" on " .. e.track) or "")) or tostring(e.text or ""),
        pos = e.pos, take = e.take }
    end
  end
  for _, s in ipairs(drawings(cfg, b)) do
    local what = (s.kind == "text" and ("text: " .. tostring(s.text)) or (s.kind or "pen") .. " drawing") .. (s.view == "mixer" and " on the Mixer" or "")
    -- (a Mixer drawing's first number is a place down a strip, not a time: no Go for it. lib/webdraw.lua, rt-draw)
    rows[#rows + 1] = { kind = "draw", time = s.time or "", user = s.user, text = what, pos = s.view == nil and tonumber(s.points[1][1]) or nil, track_oid = s.view == nil and s.points[1][2] or nil }
  end
  table.sort(rows, function(a, z) return a.time > z.time end)
  return rows
end
local function shown_kinds()
  local off = reaper.GetExtState(band.SECTION, "chat all off")
  local on = {}
  for _, k in ipairs(chat.KINDS) do on[k[1]] = not off:find("|" .. k[1] .. "|", 1, true) end
  return on
end
function chat.all_tab(ctx, ImGui, cfg, b, notes)
  local on = shown_kinds()
  for i, k in ipairs(chat.KINDS) do
    if i > 1 then ImGui.SameLine(ctx, 0, 10); if ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, k[2]) + 30 then ImGui.NewLine(ctx) end end
    local ch, v = ImGui.Checkbox(ctx, k[2] .. "##allf", on[k[1]])
    if ch then
      on[k[1]] = v
      local off = "|"
      for _, x in ipairs(chat.KINDS) do if not on[x[1]] then off = off .. x[1] .. "|" end end
      reaper.SetExtState(band.SECTION, "chat all off", off == "|" and "" or off, true)
    end
  end
  local only = chat.only()
  local proj = reaper.EnumProjects(-1)
  local accent = require("theme").ACCENT
  if ImGui.BeginChild(ctx, "allrows", 0, 0, ImGui.ChildFlags_Borders) then
    local n = 0
    for i, r in ipairs(chat.all_rows(cfg, b, notes)) do
      if on[r.kind] and (only == "" or r.user == only) then
        n = n + 1
        if n > 300 then break end
        ImGui.PushID(ctx, i)
        if r.pos then
          if ImGui.SmallButton(ctx, "Go") then
            reaper.SetEditCurPos2(proj, r.pos, true, false)
            local tr = r.track_oid and require("mirror").find(proj, "track", r.track_oid)
            if tr then reaper.SetOnlyTrackSelected(tr); reaper.Main_OnCommand(40913, 0) end -- (Track: Vertical scroll selected tracks into view)
          end
          local _, bars = reaper.TimeMap2_timeToBeats(proj, r.pos)
          ImGui.SetItemTooltip(ctx, "Put the edit cursor there: bar " .. math.floor(bars + 1) .. (r.track_oid and ", and show its track" or ""))
          ImGui.SameLine(ctx)
        elseif r.url then
          -- (a bandmate typed it: a web link opens, anything else is shown first, as on the Links tab. It opened a synced file or a program
          -- with one click: security review, 0.58.87)
          if ImGui.SmallButton(ctx, "Open") and (tostring(r.url):match("^https?://") or reaper.MB("Open this? It isn't a web link:\n\n" .. tostring(r.url), "StudioSync", 4) == 6) then
            band.open_url(r.url)
          end
          ImGui.SetItemTooltip(ctx, tostring(r.url))
          ImGui.SameLine(ctx)
        end
        ImGui.TextDisabled(ctx, when(r.time))
        ImGui.SameLine(ctx)
        local label = ({ msgs = "message", todo = "to-do", links = "link", note = "note", like = "like", draw = "drawing" })[r.kind]
        ImGui.TextColored(ctx, require("theme").readable(accent), label)
        ImGui.SameLine(ctx)
        local wl = chat.where_label(r.where, b, scope)
        ImGui.TextWrapped(ctx, tostring(r.user) .. ": " .. r.text .. (wl and ("  (" .. wl .. ")") or ""))
        ImGui.PopID(ctx)
      end
    end
    if n == 0 then ImGui.TextDisabled(ctx, "Nothing here yet with these filters.") end
    ImGui.EndChild(ctx)
  end
end

-- `tabs`: more tabs, { { label, draw, first } } (the panel's All, Notes and Likes): `first` ones before Messages, the rest after Links.
function chat.draw(ctx, ImGui, cfg, b, tabs)
  if not b or not b.song then return ImGui.TextDisabled(ctx, "Open a studio project to chat about it.") end
  -- next to the last thing, or on a new line when `w` more won't fit (the Everyone box ran off the right of the panel)
  local function fits(w, gap)
    ImGui.SameLine(ctx, 0, gap or 8)
    if ImGui.GetContentRegionAvail(ctx) < w then ImGui.NewLine(ctx) end
  end
  local t = load(cfg, b)
  local short = select(2, ImGui.GetContentRegionAvail(ctx)) < 220 -- (below this the switches cost the messages a third of what they had)
  local function switches()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 4, 1)
  for i, sc in ipairs(SCOPES) do
    if i > 1 then fits(ImGui.CalcTextSize(ctx, sc[2]) + 36) end
    if ImGui.RadioButton(ctx, sc[2], scope == sc[1]) then scope, cache = sc[1], nil end
  end
  ImGui.PopStyleVar(ctx)
  ImGui.SetItemTooltip(ctx, "What you see and who you're writing to. This room: only this room's. This project: the project's and all its rooms'. " ..
    "Studio: everything, from every project and room. What you write goes to the one picked here.")
  do -- whose: messages, to-dos, links, notes and drawings, one person's or everyone's
    local names, seen, only = { cfg.user }, { [cfg.user] = true }, chat.only()
    for _, list in pairs(t) do
      for _, v in ipairs(list) do
        if type(v.user) == "string" and not seen[v.user] then seen[v.user] = true; names[#names + 1] = v.user end
      end
    end
    for _, st in ipairs(require("presence").peers(cfg, b.song, b.room)) do
      if not seen[st.user] then seen[st.user] = true; names[#names + 1] = st.user end
    end
    table.sort(names)
    fits(150, 24)
    ImGui.SetNextItemWidth(ctx, 150)
    if ImGui.BeginCombo(ctx, "##only", only == "" and "Everyone" or only) then
      if ImGui.Selectable(ctx, "Everyone", only == "") then reaper.DeleteExtState(band.SECTION, "show only", false) end
      for _, n in ipairs(names) do
        if ImGui.Selectable(ctx, n, n == only) then reaper.SetExtState(band.SECTION, "show only", n, false) end
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.SetItemTooltip(ctx, "Show only one person's messages, to-dos, links, notes and drawings, on this computer.")
  end
  end
  local function draw_buttons() -- drawing on the arrange view (StudioSync - Draw.lua): what's drawn there is the room's, seen by everyone in it
    -- (buttons beside the switches and the Everyone box, above the tabs: they were tabs at the right of the tab bar, but they don't
    -- open a page as tabs do. James, 0.58.79)
    -- (its toggle, from the running script's own beat: asking REAPER for the script's id rewrote its key file every frame this page
    -- was open, the lag on this page: James, 0.42.28)
    local root = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\]") or ""
    local running = reaper.time_precise() - (tonumber(reaper.GetExtState(band.SECTION, "draw alive")) or -60) < 3
    local drawing = reaper.GetExtState(band.SECTION, "draw on") ~= ""
    local label = drawing and "Drawing" or "Draw"
    fits(ImGui.CalcTextSize(ctx, label) + 24, short and 8 or 24)
    if drawing then
      local accent = require("theme").ACCENT
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, accent); ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, accent); ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
    end
    if ImGui.Button(ctx, label .. "##draw") then
      if drawing then reaper.DeleteExtState(band.SECTION, "draw on", false)
      else
        reaper.DeleteExtState(band.SECTION, "draw hidden", true)
        reaper.SetExtState(band.SECTION, "draw on", "1", false)
        band.start_draw(root)
      end
    end
    if drawing then ImGui.PopStyleColor(ctx, 3) end
    ImGui.SetItemTooltip(ctx, drawing and "Stop drawing (or Done on the bar, or Esc)." or "Draw on the tracks for everyone in this room: the tools show at the foot of the tracks.\n" ..
      "A drawing stays on its bar and track however anyone scrolls or zooms.")
    local shown_label = running and "Hide drawings" or "Show drawings"
    fits(ImGui.CalcTextSize(ctx, shown_label) + 24)
    if ImGui.Button(ctx, shown_label .. "##drawings") then
      if running then
        reaper.SetExtState(band.SECTION, "draw hidden", "1", true)
        reaper.DeleteExtState(band.SECTION, "draw on", false)
        reaper.SetExtState(band.SECTION, "draw quit", "1", false)
      else
        reaper.DeleteExtState(band.SECTION, "draw hidden", true)
        band.start_draw(root)
      end
    end
    ImGui.SetItemTooltip(ctx, running and "Stop showing the others' drawings on this computer. They stay for everyone else." or "Show what the others drew, over the arrange view (clicks still go to REAPER).")
    -- the web UI (lib/webui.lua): who's here and this chat in a browser, and the link for a phone on the studio's Tailscale (James, rt)
    local webui = require("webui")
    if webui.available() then
      fits(ImGui.CalcTextSize(ctx, "Web UI") + 24, 24)
      if ImGui.Button(ctx, "Web UI##webui") then webui.dock(cfg, ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift ~= 0) end
      ImGui.SetItemTooltip(ctx, "Opens who's here and this project's chat in a REAPER window that docks (Shift-click: in your browser; " ..
        "this computer only). Live sync shows and sends them.")
      fits(ImGui.CalcTextSize(ctx, "Copy phone link") + 24)
      if ImGui.Button(ctx, "Copy phone link##webui") then
        local url, why = webui.phone_link(cfg)
        if url then band.copy(url, ctx, ImGui) else band.log("no phone link: " .. tostring(why)) end
      end
      ImGui.SetItemTooltip(ctx, "The web UI's link for a phone or another computer on the studio's Tailscale. It carries the studio's key: " ..
        "share it only with the band (a phone keeps it after the first visit).")
    end
  end
  local function to_button()
    local now = "?"
    for _, sc in ipairs(SCOPES) do if sc[1] == scope then now = sc[2] end end
    if ImGui.Button(ctx, "To: " .. now .. "...") then ImGui.OpenPopup(ctx, "chat switches") end -- (who you're writing to stays in view)
    ImGui.SetItemTooltip(ctx, "What you see, who you're writing to, and whose things show.")
    if ImGui.BeginPopup(ctx, "chat switches") then switches(); ImGui.EndPopup(ctx) end
  end
  if short then to_button() else switches() end
  draw_buttons()
  local only = chat.only()
  local function shown(v) return only == "" or v.user == only end
  if ImGui.BeginTabBar(ctx, "chat", ImGui.TabBarFlags_FittingPolicyScroll) then -- (squeezed to "Mes..." docked at the side: review, 0.59.14)
    for _, tab in ipairs(tabs or {}) do
      if tab[3] and ImGui.BeginTabItem(ctx, tab[1]) then tab[2](); ImGui.EndTabItem(ctx) end
    end
    if ImGui.BeginTabItem(ctx, "Messages") then
      chat.mark_seen(cfg, b, scope, t) -- (and the rooms This project shows, every project's under Studio: rt-people)
      local _, h = ImGui.GetContentRegionAvail(ctx)
      local function typing()
        ImGui.SetNextItemWidth(ctx, -60)
        local enter
        enter, draft = chat.input(ctx, ImGui, "##draft", "message", draft)
        if enter then ImGui.SetKeyboardFocusHere(ctx, -1) end -- (the next one straight away)
        ImGui.SameLine(ctx)
        if (ImGui.Button(ctx, "Send") or enter) and draft:match("%S") then add(cfg, b, "msgs", { text = draft }); draft = "" end
      end
      -- (with no room for the list and the box, the box comes first: to reach Send in a short docker meant scrolling down to it: Mac, 0.51.9)
      local tight = h < 40 + ImGui.GetFrameHeightWithSpacing(ctx)
      if tight then typing() end
      -- (what's under this is one row: at some scales a row is taller than the 34 this was, and in a short docker the box and Send went out of reach: James)
      if ImGui.BeginChild(ctx, "msgs", 0, tight and 60 or (h - ImGui.GetFrameHeightWithSpacing(ctx)), ImGui.ChildFlags_Borders) then
        if #t.msgs == 0 then ImGui.TextDisabled(ctx, "No messages yet: write one below. Everyone in it sees it, even if they're not in the project right now.") end
        for _, m in ipairs(t.msgs) do
          if shown(m) then
            ImGui.PushID(ctx, m.file)
            local wl = chat.where_label(m.where, b, scope)
            if wl then -- (where it was sent from, on the left: only when it isn't here)
              ImGui.TextColored(ctx, require("theme").readable(require("theme").ACCENT), wl)
              ImGui.SameLine(ctx)
            end
            ImGui.TextDisabled(ctx, when(m.time))
            if ImGui.GetContentRegionAvail(ctx) >= 420 then ImGui.SameLine(ctx) end -- (narrow, they took half the column from the words: design review)
            ImGui.TextWrapped(ctx, tostring(m.user) .. ": " .. tostring(m.text))
            delete_mine(ctx, ImGui, cfg, m)
            ImGui.PopID(ctx)
          end
        end
        if ImGui.GetScrollY(ctx) >= ImGui.GetScrollMaxY(ctx) - 20 then ImGui.SetScrollHereY(ctx, 1) end -- follow new ones
        ImGui.EndChild(ctx)
      end
      if not tight then typing() end
      ImGui.EndTabItem(ctx)
    end
    if ImGui.BeginTabItem(ctx, "To-do") then
      for _, d in ipairs(t.todo) do
        if shown(d) then
          ImGui.PushID(ctx, d.file)
          local ch, v = ImGui.Checkbox(ctx, tostring(d.text), d.done == true)
          if ch then chat.set_done(cfg, d, v) end
          if d.done and d.done_by then ImGui.SameLine(ctx); ImGui.TextDisabled(ctx, "(" .. d.done_by .. ")") end
          delete_mine(ctx, ImGui, cfg, d)
          ImGui.PopID(ctx)
        end
      end
      ImGui.SetNextItemWidth(ctx, -60)
      local enter
      enter, todo_text = chat.input(ctx, ImGui, "##todo", "add a to-do", todo_text)
      ImGui.SameLine(ctx)
      if (ImGui.Button(ctx, "Add") or enter) and todo_text:match("%S") then chat.add_todo(cfg, b, todo_text); todo_text = "" end
      ImGui.EndTabItem(ctx)
    end
    if ImGui.BeginTabItem(ctx, "Links") then
      for _, l in ipairs(t.links) do
        if not shown(l) then goto next_link end
        ImGui.PushID(ctx, l.file)
        if ImGui.SmallButton(ctx, "Open") then
          -- a bandmate typed this: web links open in the browser; anything else (a file, a program) is shown first
          local web = l.url:match("^https?://") ~= nil
          if web or reaper.MB("Open this? It isn't a web link:\n\n" .. l.url, "StudioSync", 4) == 6 then
            if reaper.CF_ShellExecute then reaper.CF_ShellExecute(l.url)
            elseif band.WIN then os.execute('start "" "' .. l.url:gsub('"', "") .. '"')
            -- (single quotes: inside double ones the shell still runs $(...) and `...` from a link someone typed)
            elseif band.LINUX then os.execute("xdg-open '" .. l.url:gsub("'", "'\\''") .. "' >/dev/null 2>&1 &")
            else os.execute("open '" .. l.url:gsub("'", "'\\''") .. "'") end
          end
        end
        ImGui.SetItemTooltip(ctx, l.url)
        ImGui.SameLine(ctx)
        ImGui.TextWrapped(ctx, (l.title ~= "" and l.title or l.url) .. "  (" .. tostring(l.user) .. ")")
        delete_mine(ctx, ImGui, cfg, l)
        ImGui.PopID(ctx)
        ::next_link::
      end
      ImGui.SetNextItemWidth(ctx, 160)
      link_title = select(2, ImGui.InputTextWithHint(ctx, "##lt", "title (lyrics, chart...)", link_title))
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, -60)
      link_url = select(2, ImGui.InputTextWithHint(ctx, "##lu", "link or file path", link_url))
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Add##l") and link_url:match("%S") then chat.add_link(cfg, b, link_title, link_url); link_title, link_url = "", "" end
      ImGui.EndTabItem(ctx)
    end
    for _, tab in ipairs(tabs or {}) do
      local flags = chat.want_tab == tab[1] and ImGui.TabItemFlags_SetSelected or ImGui.TabItemFlags_None
      if not tab[3] and ImGui.BeginTabItem(ctx, tab[1], nil, flags) then tab[2](); ImGui.EndTabItem(ctx) end
    end
    chat.want_tab = nil -- (a tab asked for from elsewhere: the phone on a person's card opens Call. 0.59.8)
    ImGui.EndTabBar(ctx)
  end
end

return chat
