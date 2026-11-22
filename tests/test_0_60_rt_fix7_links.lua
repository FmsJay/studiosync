-- rt-fix7 (2026-11-21), docs/rt/rt-invite.md "Round 2 re-check results" 3: on LinuxBox the link launcher's `reaper -nonewinst` started a
-- second REAPER beside the running one instead of waking it, and without Autostart nothing read the clicked link's file unless the panel
-- was open. The Linux launcher now starts REAPER only when none of this user's runs; Live sync reads the files where Autostart isn't running.
package.path = "lib/?.lua;" .. package.path
local ext, FS, clock = {}, {}, 1000
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Other" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  file_exists = function(p) return FS[p] ~= nil end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.read = function(p) return FS[p] end
band.size = function(p) return FS[p] and #FS[p] or nil end
band.files = function(dir, e)
  local out, pre = {}, dir .. "/"
  for p in pairs(FS) do local f = p:sub(1, #pre) == pre and p:sub(#pre + 1); if f and not f:find("/", 1, true) and (not e or f:sub(-#e) == e) then out[#out + 1] = f end end
  return out
end
band.home = function() return "H" end
band.log = function() end
os.remove = function(p) FS[p] = nil; return true end

-- ---- 1. the Linux launcher: REAPER started only when none of this user's runs --------------------------------------------------------
local uh = require("urlhandler")
local p = uh.paths({ os = "linux", home = "/home/s/.config/REAPER/StudioSync", scripts = "/home/s/.config/REAPER/Scripts/StudioSync", exe = "/home/s/REAPER/reaper", user_home = "/home/s" })
local sh = uh.linux_launcher(p)
assert(not sh:find("-nonewinst", 1, true), "no `reaper -nonewinst` (it started a second REAPER on Linux)")
local guard = sh:find('pgrep -u "$(id -u)" -x "$N" >/dev/null 2>&1 && exit 0', 1, true)
local start = sh:find('\n"$EXE" >/dev/null 2>&1 &', 1, true)
local write = sh:find("printf '%s' \"$1\" > \"$P.tmp\" && mv -f \"$P.tmp\" \"$P\"", 1, true)
assert(write and guard and start and write < guard and guard < start, "the link written first, then a running REAPER of this user's found (pgrep), and only then one started")
assert(sh:find('elif command -v pidof >/dev/null 2>&1; then pidof "$N" >/dev/null 2>&1 && exit 0; fi', 1, true), "pidof where there's no pgrep")
assert(sh:find('N=$(basename "$EXE")', 1, true) and sh:find("EXE='/home/s/REAPER/reaper'", 1, true), "by the program's own name")
-- the other systems keep theirs (Windows' -nonewinst wakes the running REAPER; the Mac's `open` does)
local w = uh.win_launcher(uh.paths({ os = "win", home = "C:/h", scripts = "C:/s", exe = "C:/R/reaper.exe" }))
assert(w:find("-nonewinst", 1, true), "Windows: as before")

-- ---- 2. Live sync reads the clicked links' files where Autostart isn't running ---------------------------------------------------------
local invite = require("invite")
local handled = {}
invite.handle_link = function(s) handled[#handled + 1] = s; return true, "ok" end
FS["H/link/pending-1795312935-148239.txt"] = "studiosync://join?s=a&p=b"
ext["BandSync/autostart beat"] = tostring(clock - 1)
invite.live_tick(os.time())
assert(#handled == 0 and FS["H/link/pending-1795312935-148239.txt"], "Autostart beating (every 2 s): it reads them, Live sync leaves them")
clock = clock + 30 -- (Autostart's beat 31 s old: stopped, or off as on LinuxBox)
invite.live_tick(os.time())
assert(handled[1] == "studiosync://join?s=a&p=b" and not FS["H/link/pending-1795312935-148239.txt"], "Autostart not running: Live sync reads the link and the file goes")
ext["BandSync/autostart beat"] = nil
FS["H/link/pending-1795312940-1.txt"] = "studiosync://join?s=a&p=c"
clock = clock + invite.LINK_EVERY + 1
invite.live_tick(os.time())
assert(handled[2] == "studiosync://join?s=a&p=c", "no Autostart at all: the same")
local src = assert(io.open("StudioSync - Live sync.lua", "rb")):read("a")
assert(src:find('band.try("invite.live_tick", require("invite").live_tick)', 1, true), "Live sync calls it")

print("ok: rt-fix7 links (no second REAPER from the Linux launcher, Live sync reads clicked links without Autostart)")
