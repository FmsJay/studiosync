-- band.is_conflict_copy: sync tools' duplicate files are never read as ours (lupa or any Lua 5.4, from the repo root)
reaper = setmetatable({}, { __index = function() return function() end end }) -- band.lua only needs reaper at call time
package.path = "lib/?.lua;" .. package.path
local band = require("band")
assert(band.is_conflict_copy("James-20261028-070536Z-00009-8160.sync-conflict-20261028-071122-ABCDEF.json"), "Syncthing conflict copy")
assert(band.is_conflict_copy("James-20261028-070536Z-00009-8160 (1).json"), "Drive duplicate")
assert(not band.is_conflict_copy("James-20261028-070536Z-00009-8160.json"), "a real event")
assert(not band.is_conflict_copy("Gtr (band).fxchain"), "a name with brackets isn't a duplicate")

-- writing a file over an old one, interrupted (0.58.52): the old one is never lost
do
  local dir = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ss_files_" .. os.time()
  os.execute((package.config:sub(1, 1) == "\\" and 'mkdir "' .. dir:gsub("/", "\\") .. '"' or "mkdir -p '" .. dir .. "'"))
  local path = dir .. "/session.json"
  band.write_atomic(path, "old")
  assert(band.read(path) == "old", "written")
  band.write_atomic(path, "new")
  assert(band.read(path) == "new", "replaced")
  -- the rename that would put the new one in place fails: a whole file is still there, never a cut-off one
  local real_rename = os.rename
  local calls = 0
  os.rename = function(a, b) calls = calls + 1; if calls == 1 then return nil, "busy" end; return real_rename(a, b) end
  pcall(band.write_atomic, path, "newer")
  os.rename = real_rename
  assert(band.read(path) == "new" or band.read(path) == "newer", "after a failed rename, a whole file is there: " .. tostring(band.read(path)))
  -- a power cut between the two renames on Windows: only the old copy is left, under the name Syncthing ignores. The next read puts it back
  local was = band.read(path)
  real_rename(path, dir .. "/.syncthing." .. path:match("[^/]+$") .. ".old.tmp")
  assert(band.read(path) == was, "the next read puts the old copy back: " .. tostring(band.read(path)))
  os.remove(path)
  os.remove(dir)
end
print("ok")
