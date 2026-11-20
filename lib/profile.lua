-- Each member's profile for the web UI (James: "profile pictures and other customisation"): a display name, a small picture and their
-- colour, shown in presence, chat and Home. The colour is lib/people.lua's own (one per person, the same in every studio they're in); the
-- name and the picture are per studio, in the studio's shared folder, one writer per file as everything else there:
--   _band/profiles/<id>.json       { user, name, pic = "jpg" | "png" | nil, time }
--   _band/profiles/<id>.jpg|.png   the picture: PNG or JPEG only, at most PIC_MAX bytes and PIC_DIM px a side
-- A picture comes from a page already re-encoded (drawn into a small canvas and saved as JPEG there), and is checked here whatever the page
-- did: real PNG or JPEG bytes (signature, header, end marker, the size in its own header), never anything else (no SVG, nothing that runs).
-- A bandmate's file is checked again on every computer that reads it, before it goes to a page, and only ever as a data: image whose type
-- comes from its bytes, never from its name. (James, rt)
local band = require("band")
local profile = {}
profile.PIC_MAX = 10000   -- bytes of a picture (a 96 px JPEG is 3-6 KB; the server takes 16 KB per action, base64 makes it 4/3)
profile.PIC_DIM = 256     -- pixels a side at most
profile.NAME_MAX = 40     -- bytes of a display name
profile.EVERY = 10        -- seconds between reading everyone's profiles (a page's own change: at once)
profile.MAX_PEOPLE = 60   -- profiles read (the topic stays well under the server's 1 MB per topic)

local function id(user) return (tostring(user):gsub("[^%w%-_]", "_")) end
function profile.dir(root) return root .. "/_band/profiles" end

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local function be16(s, i) local a, b = s:byte(i, i + 1); return a * 256 + b end
local function be32(s, i) local a, b, c, d = s:byte(i, i + 3); return ((a * 256 + b) * 256 + c) * 256 + d end
-- What a picture's bytes are: mime ("image/png" | "image/jpeg"), width, height; or nil and why. Only whole, well-formed PNG or JPEG files
-- within the limits pass. Pure.
function profile.image_info(s)
  if type(s) ~= "string" or #s < 24 then return nil, "not a picture" end
  if #s > profile.PIC_MAX then return nil, "the picture is too big (at most " .. profile.PIC_MAX .. " bytes)" end
  local mime, w, h
  if s:sub(1, 8) == "\137PNG\r\n\26\n" then
    if s:sub(9, 16) ~= "\0\0\0\13IHDR" or #s < 45 then return nil, "not a whole PNG" end
    if s:sub(-12) ~= "\0\0\0\0IEND\174\66\96\130" then return nil, "not a whole PNG" end
    mime, w, h = "image/png", be32(s, 17), be32(s, 21)
  elseif s:sub(1, 3) == "\255\216\255" then
    if s:sub(-2) ~= "\255\217" then return nil, "not a whole JPEG" end
    local i = 3
    while i + 3 <= #s do
      if s:byte(i) ~= 0xFF then return nil, "not a whole JPEG" end
      local m = s:byte(i + 1)
      if m == 0xFF then i = i + 1 -- (fill)
      elseif m == 0x01 or (m >= 0xD0 and m <= 0xD7) then i = i + 2
      elseif m == 0xD9 or m == 0xDA then break -- (the image data before any frame header: no size, refused below)
      else
        local len = be16(s, i + 2)
        if len < 2 or i + 1 + len > #s then return nil, "not a whole JPEG" end
        if m >= 0xC0 and m <= 0xCF and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
          if len < 7 then return nil, "not a whole JPEG" end
          h, w = be16(s, i + 5), be16(s, i + 7)
          break
        end
        i = i + 2 + len
      end
    end
    mime = "image/jpeg"
  else
    return nil, "only PNG or JPEG pictures"
  end
  if not (w and h) or w < 1 or h < 1 then return nil, "the picture has no size" end
  if w > profile.PIC_DIM or h > profile.PIC_DIM then return nil, "the picture is too large (at most " .. profile.PIC_DIM .. " px a side)" end
  return mime, w, h
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function profile.base64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    out[#out + 1] = B64:sub((n >> 18) + 1, (n >> 18) + 1) .. B64:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
      .. (b and B64:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or "=") .. (c and B64:sub((n & 63) + 1, (n & 63) + 1) or "=")
  end
  return table.concat(out)
end
-- A picture as a page sends it: base64, with or without a data:image/png|jpeg;base64, prefix. -> the bytes, or nil and why. Strict: only the
-- base64 alphabet, padded, and never more than PIC_MAX bytes' worth (checked before decoding). Pure.
function profile.unbase64(s)
  if type(s) ~= "string" then return nil, "no picture" end
  s = s:gsub("^data:image/[pngjeg]+;base64,", "", 1)
  if #s == 0 or #s % 4 ~= 0 or #s > math.ceil(profile.PIC_MAX / 3) * 4 or not s:match("^[A-Za-z0-9+/]+=?=?$") then return nil, "not a picture" end
  return require("fxfiles").unbase64(s)
end
-- A display name from a page: clean_text's rule, at most NAME_MAX bytes (cut on a character); "" -> nil (back to the user name).
function profile.clean_name(s)
  local t = require("webui").clean_text(type(s) == "string" and s:sub(1, 400) or nil)
  if not t then return nil end
  if #t > profile.NAME_MAX then
    t = t:sub(1, profile.NAME_MAX)
    while #t > 0 and not utf8.len(t) do t = t:sub(1, -2) end -- (not cut inside a character)
    t = t:gsub("%s+$", "")
  end
  return t ~= "" and t or nil
end
-- "#rrggbb" -> 0xRRGGBB; "" -> false (the default colour); anything else -> nil. Pure.
function profile.colour_of(s)
  if s == "" then return false end
  if type(s) ~= "string" or not s:match("^#%x%x%x%x%x%x$") then return nil end
  return tonumber(s:sub(2), 16)
end
function profile.hex(rgb) return math.tointeger(rgb) and string.format("#%06x", rgb & 0xFFFFFF) or nil end

-- ---- reading ---------------------------------------------------------------------------------------------------------------------------
local pics = {} -- picture path .. its profile's time -> its data: URL, or false (refused)
-- A picture file as a data: URL, or nil: checked on its size first (never read whole when it's big), then its bytes.
function profile.pic_url(path)
  local n = band.size(path)
  if not n or n > profile.PIC_MAX then return nil end
  local s = band.read(path)
  local mime = s and profile.image_info(s)
  return mime and ("data:" .. mime .. ";base64," .. profile.base64(s)) or nil
end
local cache = {} -- root -> { at, people }
function profile.forget(root) cache[root] = nil end
-- Everyone's profile: user -> { name, colour = "#rrggbb", pic = data: URL }. A file's user must be the one its name says (no file speaks for
-- someone else's name); colours for everyone people.lua knows of, these too. Kept EVERY s.
function profile.all(root)
  local c = cache[root]
  if c and reaper.time_precise() - c.at < profile.EVERY then return c.people end
  local out, names, dir = {}, {}, profile.dir(root)
  for i, f in ipairs(band.files(dir, ".json")) do
    if i > profile.MAX_PEOPLE then break end
    local p = band.read_json(dir .. "/" .. f)
    if type(p) == "table" and type(p.user) == "string" and id(p.user) .. ".json" == f then
      local e = { name = type(p.name) == "string" and profile.clean_name(p.name) or nil }
      if p.pic == "jpg" or p.pic == "png" then
        local path = dir .. "/" .. id(p.user) .. "." .. p.pic
        -- (and its size: a profile can come over the direct link before its picture does, lib/signed.lua. rt-linkfirst)
        local key = path .. "|" .. tostring(p.time) .. "|" .. tostring(band.size(path))
        if pics[key] == nil then pics[key] = profile.pic_url(path) or false end
        e.pic = pics[key] or nil
      end
      out[p.user], names[#names + 1] = e, p.user
    end
  end
  local ok, colours = pcall(require("people").colours, root, names)
  for user, rgb in pairs(ok and colours or {}) do
    out[user] = out[user] or {}
    out[user].colour = profile.hex(rgb)
  end
  cache[root] = { at = reaper.time_precise(), people = out }
  return out
end

-- ---- what a page sends -----------------------------------------------------------------------------------------------------------------
-- a: { topic = "profile", id, name (a display name, "" for none), colour ("#rrggbb", "" for the default), pic (base64 PNG/JPEG, or "" to
-- remove it) }; any of them. Only this computer's user's own profile is ever written (a page acts as them). -> { id, ok | why }, and words
-- for the log or nil.
function profile.action(cfg, a)
  local dir, me = profile.dir(cfg.root), id(cfg.user)
  local cur = band.read_json(dir .. "/" .. me .. ".json")
  local p = { user = cfg.user, name = type(cur) == "table" and cur.name or nil, pic = type(cur) == "table" and cur.pic or nil }
  local changed, why = false, nil
  if a.name ~= nil then
    local n = profile.clean_name(a.name)
    if a.name ~= "" and not n then why = "that name can't be used" else p.name, changed = n, true end
  end
  if a.colour ~= nil then
    local c = profile.colour_of(a.colour)
    if c == nil then why = why or "not a colour" else require("people").pick(cfg, c or nil) end
  end
  local bytes, ext
  if a.pic == "" then p.pic, changed = nil, true
  elseif a.pic ~= nil then
    local err
    bytes, err = profile.unbase64(a.pic)
    local mime
    if bytes then mime, err = profile.image_info(bytes) end
    if not mime then why, bytes = why or err, nil
    else ext = mime == "image/png" and "png" or "jpg"; p.pic, changed = ext, true end
  end
  local said
  if changed then
    p.time = os.date("!%Y-%m-%dT%H:%M:%SZ")
    reaper.RecursiveCreateDirectory(dir, 0)
    if bytes then band.write_atomic(dir .. "/" .. me .. "." .. ext, bytes) end
    for _, x in ipairs({ "jpg", "png" }) do if x ~= p.pic and reaper.file_exists(dir .. "/" .. me .. "." .. x) then band.remove(dir .. "/" .. me .. "." .. x) end end
    band.write_json(dir .. "/" .. me .. ".json", p)
    said = "your profile was changed from the web page"
  end
  cache[cfg.root] = nil
  return { id = type(a.id) == "string" and a.id:sub(1, 40) or nil, ok = not why or nil, why = why }, why and ("the web page's profile change: " .. why) or said
end

-- The "profiles" topic: { me, people = { user = { name, colour, pic } }, reply }.
function profile.model(cfg, reply) return { me = cfg.user, people = profile.all(cfg.root), reply = reply } end

return profile
