-- rt-fix7 (2026-11-21), docs/rt/rt-perfcut4.md re-check 7.2: `status/file` took 7-9 ms a write on the desktop (expected ~2). It is
-- band.write_json alone, and band.write_atomic opened its .tmp a second time to measure it, which waits for the virus scanner (4-37 ms
-- measured here); on Windows it also tried a rename over the file first, which never works there. Now: the size from the handle written
-- with (seek flushes, so a full disk still shows), one open per write, and no doomed rename on Windows. The old file stays whole as before.
reaper = setmetatable({ GetOS = function() return "Win64" end, time_precise = os.clock },
  { __index = function() return function() return "" end end })
package.path = "lib/?.lua;" .. package.path
local band = require("band")
assert(band.WIN, "(this test runs the Windows path everywhere: it works on any system)")
local base = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/"):gsub("/+$", "")
local dir = base .. "/ss-rtfix7-" .. tostring(os.time()) .. "-" .. math.random(1, 1e9)
os.execute(package.config:sub(1, 1) == "\\" and ('mkdir "' .. dir:gsub("/", "\\") .. '"') or ("mkdir -p '" .. dir .. "'"))
local path = dir .. "/Box.json"
local real_open, real_rename = io.open, os.rename
local opens, renames = 0, 0
io.open = function(p, m) opens = opens + 1; return real_open(p, m) end
os.rename = function(a, b) renames = renames + 1; return real_rename(a, b) end
band.write_json(path, { user = "Box", time = "x" })
assert(band.read_json(path).user == "Box", "a first file put in place on the Windows path too")
opens, renames = 0, 0
band.write_json(path, { user = "Box", time = "y" })
local o1, r1 = opens, renames
assert(band.read_json(path).time == "y", "replaced")
opens, renames = o1, r1
assert(opens == 1, "one open per write: the .tmp isn't opened again to measure it (" .. opens .. ")")
assert(renames == 2, "the old file aside and the new one in: no rename over it first (" .. renames .. ")")
-- a write the disk cut short (it says it wrote, the file is shorter): still refused, the old file whole, nothing left beside it
io.open = function(p, m)
  local f = real_open(p, m)
  if m == "wb" and f then
    return setmetatable({ write = function(self, s) return f:write(s:sub(1, math.floor(#s / 2))) end, seek = function(_, w) return f:seek(w) end,
      close = function() return f:close() end }, { __index = f })
  end
  return f
end
local ok, err = pcall(band.write_json, path, { user = "Box", time = "z" })
io.open = real_open
os.rename = real_rename
assert(not ok and tostring(err):find("disk", 1, true), "cut short: says so (" .. tostring(err) .. ")")
assert(band.read_json(path).time == "y", "the old file whole")
assert(not real_open(dir .. "/.syncthing.Box.json.tmp", "rb"), "no half-written copy left")
os.remove(path)
os.execute(package.config:sub(1, 1) == "\\" and ('rmdir /s /q "' .. dir:gsub("/", "\\") .. '"') or ("rm -rf '" .. dir .. "'"))
print("ok: rt-fix7 write (one open per write, no doomed rename on Windows, a short write still refused)")
