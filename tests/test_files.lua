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
  local dir = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ss_files_" .. os.time() .. "_" .. math.random(100000, 999999) -- (two runs in one second shared a folder; Round 1 review, 0.59.45)
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
  -- (0.58.54) the disk fills up mid-write: an error that says so, the old file whole, and nothing half-written left beside it
  band.write_atomic(path, "before")
  local real_open = io.open
  io.open = function(p, mode)
    if mode == "wb" and p:find(".syncthing.", 1, true) then
      local f = real_open(p, mode)
      return setmetatable({ write = function() return nil end, close = function() return f:close() end }, { __index = f })
    end
    return real_open(p, mode)
  end
  local ok, err = pcall(band.write_atomic, path, "after")
  io.open = real_open
  assert(not ok and tostring(err):find("disk", 1, true), "a full disk says so: " .. tostring(err))
  assert(band.read(path) == "before", "and the old file is whole")
  assert(not real_open(dir .. "/.syncthing.session.json.tmp", "rb"), "no half-written copy left")
  os.remove(path)
  os.execute((package.config:sub(1, 1) == "\\" and ('rmdir /s /q "' .. dir:gsub("/", "\\") .. '"') or ("rm -rf '" .. dir .. "'"))) -- (os.remove can't take a folder away on Windows: 747 were left)
end
print("ok")
