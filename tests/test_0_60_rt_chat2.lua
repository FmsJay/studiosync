-- The chat's direct messages, channels, unread counts and file drops (lib/page_chat.lua, lib/chatfiles.lua; rt-chat2): the pure rules (scopes,
-- members, mentions, file names, a program's first bytes), then everything over a stand-in shared folder: a DM seen only by its members and sent
-- over the link only to them, a DM never falling back into the project's chat, channels made, renamed and archived by admins only, unread and
-- @mention counts and marking seen, and a file sent link-only in a DM, falling back to the shared folder when the link fails, saved only when
-- its SHA-256 matches and never when it's a program.
package.path = "lib/?.lua;" .. package.path
local clock, ext, logged, guid = 1000, {}, {}, 0
local real_open = io.open
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  genGuid = function() guid = guid + 1; return string.format("{%08X-0000-0000-0000-%012X}", guid, guid) end,
  RecursiveCreateDirectory = function() return 1 end,
  EnumProjects = function() return "P1" end,
  GetProjectPathEx = function() return "R/S/media" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end

-- ---- pure ---------------------------------------------------------------------------------------------------------------------------------
local direct_real = require("direct")
local cf = require("chatfiles")
for _, e in ipairs(cf.EXTS) do assert(direct_real.stream_ext("x." .. e), e .. ": on the link's own list too") end
for _, e in ipairs({ "exe", "dll", "lua", "js", "bat", "ps1", "sh", "app", "lnk", "msi", "scr", "html", "svg" }) do
  assert(not cf.name_ok("song." .. e), e .. " refused") end
assert(cf.name_ok(" Bass idea.WAV ") == "Bass idea.WAV" and cf.name_ok("take.wav.exe") == nil and cf.name_ok("a/b.wav") == nil
  and cf.name_ok("..wav") == nil and cf.name_ok("CON.wav") == nil and cf.name_ok("com1.mp3") == nil and cf.name_ok("noext") == nil, "names")
assert(cf.runs_head("MZ\144\0") and cf.runs_head("\127ELF") and cf.runs_head("#!/b") and cf.runs_head("\207\250\237\254") and not cf.runs_head("RIFF")
  and not cf.runs_head(""), "a program's first bytes")
local SHA = string.rep("ab", 32)
local good = { name = "a.wav", size = 10, sha = SHA, key = "20261120-101500-James-1234~a.wav" }
assert(cf.check(good).via == "shared" and not cf.check({ name = "a.wav", size = 10, sha = SHA, key = "../x~a.wav" })
  and not cf.check({ name = "a.exe", size = 10, sha = SHA, key = "20261120-101500-James-1234~a.exe" })
  and not cf.check({ name = "a.wav", size = cf.MAX + 1, sha = SHA, key = good.key }) and not cf.check({ name = "a.wav", size = 1, sha = "x", key = good.key }), "attach checked")
assert(cf.model(good, { state = "coming", bytes = 4 }).audio and cf.model(good).state == "waiting" and cf.model({}) == nil, "model")
assert(cf.link_state(nil) == "gone" and cf.link_state({ peers = { a = { done = true }, b = { done = true } } }) == "done"
  and cf.link_state({ peers = { a = { done = true }, b = { error = "refused" } } }) == "failed" and cf.link_state({ peers = { a = {} } }) == "going", "link state")
local taken = { ["D/a.wav"] = true, ["D/a (2).wav"] = true }
assert(cf.free_name("D", "a.wav", function(p) return taken[p] end) == "D/a (3).wav", "a free name")

local chat = require("page_chat")
assert(chat.conv_of("dm:0123456789abcdef") == "dm" and chat.conv_of("ch:0123456789ab") == "ch" and chat.conv_of("dm:0123") == nil
  and chat.conv_of("dm:0123456789ABCDEF") == nil and chat.conv_of("song") == nil and chat.conv_of("ch:../../x") == nil, "scopes")
assert(table.concat(chat.names_ok({ "Bo", "Al", "Bo" }), ",") == "Al,Bo" and chat.names_ok({ "Al" }) == nil and chat.names_ok({ "Al", 5 }) == nil
  and chat.names_ok({ "A", "B", "C", "D", "E", "F", "G", "H", "I" }) == nil, "members")
assert(chat.mentions("hey @james, listen", "James") and chat.mentions("@James", "James") and not chat.mentions("@Jameson", "James")
  and not chat.mentions("james", "James") and not chat.mentions(nil, "James"), "mentions")
assert(chat.topic_of("dm:0123456789abcdef") == "chat_dm_0123456789abcdef" and #chat.topic_of("dm:0123456789abcdef") <= 32, "a topic the server takes")

-- ---- a stand-in shared folder and extension ------------------------------------------------------------------------------------------------
local fs, uploads = {}, {}
local function copyv(v) return type(v) == "table" and band.json_decode(band.json_encode(v)) or v end
band.write_json = function(path, t) fs[path] = copyv(t) end
band.read_json = function(path) return type(fs[path]) == "table" and copyv(fs[path]) or nil end
band.files = function(dir, ext_)
  local out = {}
  for path in pairs(fs) do local d, f = path:match("^(.*)/([^/]+)$"); if d == dir and (not ext_ or f:sub(-#ext_) == ext_) then out[#out + 1] = f end end
  table.sort(out)
  return out
end
band.subdirs = function(dir)
  local seen, out = {}, {}
  for path in pairs(fs) do local s = path:sub(1, #dir + 1) == dir .. "/" and path:sub(#dir + 2):match("^([^/]+)/"); if s and not seen[s] then seen[s] = true; out[#out + 1] = s end end
  table.sort(out)
  return out
end
band.songs = function() return { "S" } end
band.home = function() return "H" end
band.info = function() return { id = "studio1" } end
band.copy_atomic = function(a, z) fs[z] = fs[a] end
band.copy_background = band.copy_atomic
reaper.file_exists = function(p) return fs[p] ~= nil end
os.remove = function(p) fs[p] = nil; return true end
os.rename = function(a, z) if fs[a] == nil then return nil end fs[z], fs[a] = fs[a], nil; return true end
io.open = function(p) local s = fs[p]; if type(s) ~= "string" then return nil end return { read = function(_, n) return s:sub(1, n) end, close = function() end } end
reaper.StudioSync_WebUISaveUpload = function(id, path) local d = uploads[id]; if not d then return 0 end fs[path], uploads[id] = d, nil; return #d end
reaper.StudioSync_FileHash = function(path) return type(fs[path]) == "string" and (band.code_hash(fs[path]):rep(4)) or "" end
local offers = {}
reaper.StudioSync_WebUIOffer = function(id, path) offers[id] = path; return 1 end
local live_sent, alerts, streams_out, streamed = {}, {}, {}, {}
local peers_by, reach = { Bo = "bo:47281", Cy = "cy:47281" }, { Bo = { ok = true }, Cy = { ok = true } }
package.loaded.direct = { send_live = function(_, kind, d, song, room, id, to) live_sent[#live_sent + 1] = { d = d, to = to } end,
  messages = function() return {} end, dispatch = function() end, plain = direct_real.plain, reach = function() return reach end,
  stream_start = function(_, path, song, room, iv, name, to) streamed[#streamed + 1] = { path = path, name = name, to = to }; return song .. "/" .. name end,
  stream_end = function() return true end, streams = function() return { out = streams_out, inn = {} } end,
  stream_path = function(_, rel) return "H/direct/studio1/.streams/" .. rel end, inbox = function() return "H/direct/studio1" end }
package.loaded.hops = { peers_by_user = function() local t = {}; for k, v in pairs(peers_by) do t[k] = v end return t end }
package.loaded.alerts = { send = function(_, _, _, text) alerts[#alerts + 1] = text end }
package.loaded.api = { event = function() end }
local manages = false
package.loaded.groups = { may_manage = function() return manages end }
for _, u in ipairs({ "James", "Bo", "Cy", "Di" }) do fs["R/_band/devices/" .. u .. ".json"] = { user = u, device = "D-" .. u } end
local cfg, b = { root = "R", user = "James" }, { song = "S", room = "main" }
local function mine_as(user) return { root = "R", user = user } end

-- ---- direct messages --------------------------------------------------------------------------------------------------------------------
assert(table.concat(chat.people(cfg), ",") == "Bo,Cy,Di", "the studio's people, not you")
assert(chat.web_action(cfg, b, { topic = "chat", dm = { "Zed" } }):find("isn't in the studio"), "only the studio's people")
chat.web_action(cfg, b, { topic = "chat", dm = { "Bo" } })
local dm = "dm:" .. chat.dm_id({ "Bo", "James" })
assert(fs["R/_band/dm/" .. dm:sub(4) .. "/members.json"].members[2] == "James", "members.json written")
assert(chat.scope_ok(cfg, dm) and not chat.scope_ok(mine_as("Cy"), dm), "a DM: its members only")
clock = clock + 20
chat.web_action(cfg, b, { topic = "chat", scope = dm, text = "just you, @Bo" })
local dmsg
for p, v in pairs(fs) do if p:find("^R/_band/dm/" .. dm:sub(4) .. "/msgs/") then dmsg = v end end
assert(dmsg and dmsg.text == "just you, @Bo", "a DM's message in its own folder")
assert(#alerts == 0, "no studio-wide phone alert for a DM")
assert(#live_sent == 1 and #live_sent[1].to == 1 and live_sent[1].to[1] == "bo:47281" and live_sent[1].d.members[1] == "Bo", "over the link to Bo alone")
-- someone else's DM: refused, and never written into the project's chat instead
local cy_dm = "dm:" .. chat.dm_id({ "Bo", "Cy" })
fs["R/_band/dm/" .. cy_dm:sub(4) .. "/members.json"] = { members = { "Bo", "Cy" } }
local n_files = 0
for _ in pairs(fs) do n_files = n_files + 1 end
assert(chat.web_action(cfg, b, { topic = "chat", scope = cy_dm, text = "sneaky" }):find("isn't yours"), "not my DM: refused")
assert(chat.web_action(cfg, b, { topic = "chat", scope = "dm:0000000000000000", text = "x" }):find("isn't yours"), "no such DM: refused")
local n2 = 0
for _ in pairs(fs) do n2 = n2 + 1 end
assert(n2 == n_files, "nothing written anywhere")
-- a members list rewritten to add someone no longer hashes to its folder
clock = clock + 20
fs["R/_band/dm/" .. cy_dm:sub(4) .. "/members.json"] = { members = { "Bo", "Cy", "James" } }
assert(not chat.scope_ok(cfg, cy_dm), "a tampered members list: no DM")
-- a bandmate's DM over the link: taken by a member only
local msg = { sc = dm, song = "S", room = "main", name = "20261120-101600-Bo-1111", members = { "Bo", "James" },
  v = { text = "hi James", user = "Bo", time = "2026-11-20T10:16:00Z" } }
assert(chat.from_msg(cfg, msg) and not chat.from_msg(mine_as("Cy"), msg), "a member takes it; anyone else doesn't")
assert(not chat.from_msg(cfg, { sc = dm, song = "S", room = "main", name = "20261120-101601-Bo-1112", members = { "Bo", "Cy" },
  v = { text = "x", user = "Bo", time = "t" } }), "members that don't hash to the DM: dropped")
local r = chat.read(cfg, b, dm)
local live_shown = false
for _, x in ipairs(r.msgs) do if x.text == "hi James" then live_shown = true end end
assert(#r.msgs == 2 and live_shown, "the live one shown until its file comes")
assert(#chat.read(mine_as("Cy"), b, dm).msgs == 0, "Cy sees none of it")

-- ---- channels ---------------------------------------------------------------------------------------------------------------------------
assert(chat.web_action(cfg, b, { topic = "chat", channel = { new = "mixing" } }):find("owner and admins"), "a member can't make one")
manages = true
chat.web_action(cfg, b, { topic = "chat", channel = { new = "#mixing" } })
clock = clock + 10
local chans = chat.channels(cfg)
assert(#chans == 1 and chans[1].name == "mixing" and #chans[1].id == 12, "made")
local ch = "ch:" .. chans[1].id
chat.web_action(cfg, b, { topic = "chat", channel = { id = chans[1].id, name = "mix notes" } })
assert(chat.channels(cfg)[1].name == "mix notes", "renamed")
assert(chat.web_action(cfg, b, { topic = "chat", channel = { id = "ffffffffffff", name = "x" } }) == "no such channel", "only one that's there")
assert(chat.web_action(cfg, b, { topic = "chat", channel = { new = string.rep("x", 41) } }):find("1 to 40"), "a name's length")
chat.web_action(mine_as("Bo"), b, { topic = "chat", scope = ch, text = "kick's too loud @James" })
chat.web_action(cfg, b, { topic = "chat", channel = { id = chans[1].id, archive = true } })
assert(chat.channels(cfg)[1].archived and chat.scope_ok(cfg, ch) and not chat.scope_ok(cfg, ch, true), "archived: read-only")
assert(chat.web_action(cfg, b, { topic = "chat", scope = ch, text = "late" }):find("archived"), "no new messages there")

-- ---- unread, @mentions, seen ------------------------------------------------------------------------------------------------------------
clock = clock + 10
fs["R/_band/dm/" .. dm:sub(4) .. "/msgs/20261120-101600-Bo-1111.json"] = { text = "hi @james", user = "Bo", time = "2026-11-20T10:16:00Z" }
fs["R/S/chat/msgs/20261120-101700-Cy-2222.json"] = { text = "new mix", user = "Cy", time = "2026-11-20T10:17:00Z" }
local s = chat.unread_summary(cfg, b)
assert(s.by[dm].n == 1 and s.by[dm].at == 1 and s.by.song.n == 1 and s.by.song.at == 0, "unread per conversation, @mentions")
assert(s.by[ch].n == 1 and s.total == 2 and s.mentions == 1, "an archived channel's left out of the total")
assert(chat.unread_summary(cfg, nil).by.band and not chat.unread_summary(cfg, nil).by.song, "with no project open: Studio, channels, DMs")
chat.web_action(cfg, b, { topic = "chat", scope = dm, seen = true })
s = chat.unread_summary(cfg, b)
assert(s.by[dm].n == 0 and s.by.song.n == 1 and s.total == 1, "seen: that one only")
assert(chat.count_unread(cfg, b) == 1, "the panel's count, as before")
local idx = chat.index_model(cfg, b)
assert(idx.me == "James" and idx.admin and idx.file_max == cf.MAX and #idx.people == 3 and idx.convs[1].scope == "room", "the page's index")
local pub = {}
chat.web_tick(cfg, b, function(t, v) pub[t] = v end, clock, true)
assert(pub.chat_index and pub.chat_index.total == 1, "published while a page looks")
chat.web_action(cfg, b, { topic = "chat", scope = dm, want = dm })
clock = clock + 3
pub = {}
chat.web_tick(cfg, b, function(t, v) pub[t] = v end, clock, true)
assert(pub[chat.topic_of(dm)] and #pub[chat.topic_of(dm)].msgs == 2 and pub[chat.topic_of(dm)].scope == dm, "a DM a page shows: its own topic")
pub = {}
chat.web_tick(cfg, b, function(t, v) pub[t] = v end, clock + 10, false)
assert(not next(pub), "nobody looking: nothing built")

-- ---- files --------------------------------------------------------------------------------------------------------------------------------
local WAV = "RIFF" .. string.rep("x", 96)
-- a DM whose member the link reaches: over the link only, off the shared folder
uploads.aa01 = WAV
clock = clock + 10
assert(chat.web_action(cfg, b, { topic = "chat", scope = dm, file = { id = "aa01", name = "idea.wav", size = #WAV } }) == nil, "sent")
local fmsg, fpath
for p, v in pairs(fs) do if p:find("^R/_band/dm/" .. dm:sub(4) .. "/msgs/") and type(v) == "table" and v.attach then fmsg, fpath = v, p end end
assert(fmsg and fmsg.attach.via == "link" and fmsg.attach.size == #WAV and fmsg.text == "sent a file: idea.wav", "a file message, link only")
local key = fmsg.attach.key
assert(fs["H/chat files/studio1/" .. key] == WAV and not fs["R/_band/dm/" .. dm:sub(4) .. "/files/" .. key], "kept off the shared folder")
assert(#streamed == 1 and streamed[1].name == key and streamed[1].to[1] == "bo:47281" and #streamed[1].to == 1, "streamed to Bo alone")
-- the link fails: the shared folder after all
streams_out[1] = { rel = "_chat/" .. key, peers = { ["bo:47281"] = { sent = 10, error = "refused" } } }
clock = clock + 3
chat.web_tick(cfg, b, function() end, clock, false)
assert(fs["R/_band/dm/" .. dm:sub(4) .. "/files/" .. key] == WAV and logged[#logged]:find("shared folder"), "fell back to the shared folder")
-- the Studio scope: through the shared folder, and over the link to those here
uploads.aa02 = WAV
streamed = {}
chat.web_action(cfg, b, { topic = "chat", scope = "band", file = { id = "aa02", name = "for all.wav", size = #WAV } })
local found
for p, v in pairs(fs) do if p:find("^R/_band/chat/files/.*for all%.wav$") then found = v end end
assert(found == WAV and #streamed == 1 and #streamed[1].to == 2, "the Studio: shared folder, and the link to Bo and Cy")
-- refused: a program renamed, a kind that runs, too big, an upload that isn't whole
uploads.aa03 = "MZ\144\0rest"
assert(chat.web_action(cfg, b, { topic = "chat", scope = "band", file = { id = "aa03", name = "song.wav", size = 8 } }):find("program"), "a program, whatever it's called")
assert(chat.web_action(cfg, b, { topic = "chat", scope = "band", file = { id = "aa09", name = "run.exe", size = 8 } }):find("never programs"), "an .exe")
assert(chat.web_action(cfg, b, { topic = "chat", scope = "band", file = { id = "aa09", name = "big.wav", size = cf.MAX + 1 } }):find("MB"), "too big")
uploads.aa04 = WAV
assert(chat.web_action(cfg, b, { topic = "chat", scope = "band", file = { id = "aa04", name = "x.wav", size = 5 } }):find("whole"), "the size the page said")
for p in pairs(fs) do assert(not p:find("song%.wav") and not p:find("x%.wav") and not p:find("%.tmp$"), "nothing left of a refused file: " .. p) end
-- a file in another's DM can't be asked for
assert(chat.web_action(mine_as("Cy"), b, { topic = "chat", scope = dm, save = fpath:match("([^/]+)%.json$") }):find("isn't yours"), "not Cy's to save")
-- Bo saves it: whole, matching its SHA-256
local bo = mine_as("Bo")
clock = clock + 10
local id = fpath:match("([^/]+)%.json$")
local said = chat.web_action(bo, b, { topic = "chat", scope = dm, save = id })
assert(said:find("saved idea.wav") and fs["H/Received files/idea.wav"] == WAV, "saved to Received files: " .. tostring(said))
said = chat.web_action(bo, b, { topic = "chat", scope = dm, save = id, into = "project" })
assert(fs["R/S/media/idea.wav"] == WAV, "audio to the project's folder: " .. tostring(said))
chat.web_action(bo, b, { topic = "chat", scope = dm, download = id })
assert(offers[band.code_hash(key)] and #band.code_hash(key) == 16, "offered to the page for download")
clock = clock + 10
local m = require("webui").chat_model(chat.read(bo, b, dm), nil, nil, dm)
local fm
for _, x in ipairs(m.msgs) do if x.file then fm = x.file end end
assert(fm and fm.state == "ready" and fm.saved == "R/S/media/idea.wav" and fm.dl == band.code_hash(key) and fm.audio, "the page sees it ready, saved, offered")
-- a copy that doesn't match the sender's SHA-256, or turned into a program: not saved
fs["R/_band/dm/" .. dm:sub(4) .. "/files/" .. key] = WAV .. "tampered"
clock = clock + 10
assert(chat.web_action(bo, b, { topic = "chat", scope = dm, save = id }):find("SHA%-256"), "a changed copy isn't saved")
fs["R/_band/dm/" .. dm:sub(4) .. "/files/" .. key] = "MZ" .. WAV
assert(chat.web_action(bo, b, { topic = "chat", scope = dm, save = id }):find("program"), "nor a program")
-- the page files: chat.js reads the index, sends files through the upload, never opens one
local function read(p) local f = assert(real_open(p, "rb")); local t = f:read("a"); f:close(); return t end
local js = read("lib/webui/chat.js")
assert(js:find("chat_index", 1, true) and js:find("'api/upload'", 1, true) and js:find("ssTabs.act('chat'", 1, true), "chat.js: the index, the upload, its own topic")
assert(not js:find("innerHTML", 1, true) and not js:find("window.open", 1, true), "chat.js: bandmates' words as text, nothing opened")
assert(read("lib/webui/chat.css"):find(".cbadge", 1, true), "chat.css")
print("ok")
