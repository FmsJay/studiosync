-- The 0.59.14 code check (review): a script run from the shared folder loads only the code you said yes to (lib/band.lua band.code_guard),
-- over a small in-memory REAPER and folder (lupa or Lua 5.4, from the repo root).
local ext, fs, boxes, answer = {}, {}, 0, 7
local function dir_list(dir, want_dirs)
  local out, seen = {}, {}
  for p in pairs(fs) do
    local rest = p:sub(1, #dir + 1) == dir .. "/" and p:sub(#dir + 2)
    local name = rest and rest:match("^([^/]+)")
    if name and not seen[name] and ((rest:find("/", 1, true) ~= nil) == want_dirs) then seen[name] = true; out[#out + 1] = name end
  end
  table.sort(out)
  return out
end
reaper = setmetatable({
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  file_exists = function(p) return fs[p] ~= nil end,
  EnumerateFiles = function(d, i) return i >= 0 and dir_list(d, false)[i + 1] or nil end,
  EnumerateSubdirectories = function(d, i) return i >= 0 and dir_list(d, true)[i + 1] or nil end,
  GetResourcePath = function() return "/res" end,
  MB = function() boxes = boxes + 1; return answer end,
}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local band = require("band")
band.read = function(p) return fs[p] end
band.write_atomic = function(p, s) fs[p] = s end
band.home = function() return "/res/StudioSync" end
band.log = function() end

-- the pure parts
local h = band.code_hash("x = 1\n")
assert(h:match("^%x+$") and #h == 16 and band.code_hash("x = 1\r\n") == h and band.code_hash("x = 2\n") ~= h, "a hash, the same on either line ending")
assert(band.code_verdict(nil, { a = h }, "1", "") == "record", "the first look here is remembered")
local had = { version = "1", files = { a = h, b = h } }
assert(band.code_verdict(had, { a = h, b = h }, "1", "") == "same", "nothing changed")
local v, changed = band.code_verdict(had, { a = "x", b = h, c = h }, "1", "1")
assert(v == "ask" and changed[1] == "a" and changed[2] == "c", "a file changed (or new) in the same version is asked about")
assert(select(2, band.code_verdict(had, { a = h }, "1", ""))[1] == "b", "a file gone counts as changed")
assert(band.code_verdict(had, { a = "x", b = h }, "2", "2") == "record", "a new version you said yes to is remembered")
assert(band.code_verdict(had, { a = "x", b = h }, "2", "1") == "ask", "a new version you didn't say yes to is asked about")

-- run from the shared folder
local D = "/s/_tools/studiosync"
fs["/s/_band/band.json"] = '{"name":"S","id":"studiosync-s-0001"}'
fs[D .. "/StudioSync - Panel.lua"] = "panel()\n"
fs[D .. "/lib/band.lua"] = 'local band = { VERSION = "1" }\n'
fs[D .. "/lib/mod.lua"] = "return { n = 1 }\n"
ext["BandSync/bands"] = "/s"
assert(band.from_shared(D), "the test's folder is a shared one")
assert(band.code_guard(D) and fs["/res/StudioSync/approved code.json"] and boxes == 0, "the first look is remembered without asking")
local hashes, real_hash = 0, band.code_hash
band.code_hash = function(s) hashes = hashes + 1; return real_hash(s) end
assert(require("mod").n == 1, "a module said yes to loads")
assert(hashes == 0, "and isn't hashed again: its text is the one the check just read (Round 3 review, 0.59.48: every module was hashed twice per start)")
band.code_hash = real_hash
package.loaded.mod = nil
fs[D .. "/lib/mod.lua"] = "return { n = 2 }\n" -- (changed after the script started: Autostart requires some modules only when first needed)
assert(not pcall(require, "mod"), "a module changed since then won't load")
answer = 7 -- No
assert(not pcall(band.code_guard, D) and boxes == 1, "a changed file is asked about at the start, and No stops the script")
assert(not pcall(band.code_guard, D) and boxes == 1, "and isn't asked about again")
fs[D .. "/lib/mod.lua"] = "return { n = 3 }\n"
answer = 6 -- Yes
assert(band.code_guard(D) and boxes == 2, "changed again, it's asked about again; Yes lets it run")
package.loaded.mod = nil
assert(require("mod").n == 3 and band.code_guard(D) and boxes == 2, "and it's what's said yes to from then on")
fs[D .. "/lib/band.lua"] = 'local band = { VERSION = "2" }\n'
ext["BandSync/update ok"] = "2"
assert(band.code_guard(D) and boxes == 2, "a new version you said yes to (Autostart asks) loads without asking again")
assert(band.code_guard("/elsewhere/studiosync"), "a copy outside the shared folders (ReaPack) isn't checked")
-- (0.59.28) a script reloading itself for a new version you said yes to: the old version's check would refuse the new modules
assert(band.code_guard(D), "version 2's check in place")
fs[D .. "/lib/mod.lua"] = "return { n = 4 }\n" -- (version 3's: arrives while version 2's check is in place)
fs[D .. "/lib/band.lua"] = 'local band = { VERSION = "3" }\n'
ext["BandSync/update ok"] = "3"
package.loaded.mod = nil
assert(not pcall(require, "mod"), "under the old version's check, the new module is refused")
band.drop_code_searcher() -- (what the reload does: the new band.lua then runs its own check as it loads)
assert(band.code_guard(D) and boxes == 2 and require("mod").n == 4, "the new version's own check says yes to it, without asking, and it loads")
print("ok")
