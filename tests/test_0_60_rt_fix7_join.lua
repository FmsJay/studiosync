-- rt-fix7 (2026-11-21), docs/rt/rt-joinlink.md "Round 2 re-check results" B: a computer taken out of a studio kept its folder as a current
-- studio (groups.remember_old ran only on leaving), so Paste join code said "you're already in" and an invite link stopped at "already in it":
-- no ask, no welcome, no first copy. Now the removal (or a guest's time over) makes the folder old here, once per mark, and joining it again
-- asks the inviter's computer though the old copy has its band.json; let in again, it isn't old any more.
package.path = "lib/?.lua;" .. package.path
local ext, FS, clock = {}, {}, 1000
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  file_exists = function(p) return FS[p] ~= nil end,
  RecursiveCreateDirectory = function() return 1 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
local logged = {}
band.log = function(s) logged[#logged + 1] = s end
band.read = function(p) return FS[p] end
band.read_json = function(p) local s = FS[p]; local v = s and band.json_decode(s); return type(v) == "table" and v or nil end
band.write_json = function(p, t) FS[p] = band.json_encode(t) end
band.write_atomic = function(p, s) FS[p] = s end
band.files = function(dir, e)
  local out, pre = {}, dir .. "/"
  for p in pairs(FS) do local f = p:sub(1, #pre) == pre and p:sub(#pre + 1); if f and not f:find("/", 1, true) and (not e or f:sub(-#e) == e) then out[#out + 1] = f end end
  table.sort(out)
  return out
end
band.subdirs = function() return {} end
band.home = function() return "H" end
local R, SID, ME = "/s/StudioSync Smiley", "studiosync-smiley-1", "Box"
local MYDEV = ("B"):rep(7) .. ("-" .. ("B"):rep(7)):rep(7)
local bands = { { root = R, id = SID, name = "Smiley" } }
band.bands = function() return bands end
band.info = function(root) return root == R and { id = SID, name = "Smiley" } or { id = "", name = "" } end
ext["BandSync/user"] = ME
package.loaded.trust = { mark_ok = function() return true end, pins = function() return nil end, held = function() return nil end, device_ok = function() return true end,
  deleted_by_manager = function() return true end, inviter = function() return nil end, set_inviter = function() end, user_file = function(u) return u .. ".json" end }
package.loaded.localcopy = { publish_holds = function() end }
local services = require("services")
services.my_device_id = function() return MYDEV end
services.pin_tailnet = function() end
services.tailnet_now = function() return nil end
local groups = require("groups")
groups.may_remove = function() return true end
groups.tick = function() end
local removal = require("removal")

-- ---- 1. taken out: the folder is old here, once per mark ------------------------------------------------------------------------------
local now = os.time()
local function tick() now = now + 31; ext["BandSync/" .. removal.PUBLISH_KEY] = tostring(now); removal.tick(now) end
FS[R .. "/_band/removed/Box.json"] = band.json_encode({ user = ME, device = MYDEV, by = "James", at = now + 31 - 10 })
tick(); tick()
assert(not groups.is_old(R), "within the mark's minute: not yet (nothing has stopped syncing either)")
tick()
assert(groups.is_old(R), "taken out (the minute up): this computer's copy counts as old, as leaving makes it")
assert(ext["BandSync/removed from"]:find("James took you out of Smiley", 1, true), "and it's still said")
groups.forget_old(R) -- (Keep it, hide this, on the Groups page)
tick()
assert(not groups.is_old(R), "hidden once: not made old again by the same mark")
-- let in again: the mark goes (the owner's computer deleted it), and the folder isn't old
groups.remember_old(R, "Smiley", SID)
FS[R .. "/_band/removed/Box.json"] = nil
tick()
assert(not groups.is_old(R), "the mark gone: not old any more")
-- a guest whose time is over: the same
FS[R .. "/_band/removed/Box.json"] = band.json_encode({ user = ME, device = MYDEV, by = "James", at = now - 120, guest = true })
tick()
assert(groups.is_old(R), "a guest's time over: old here too")
-- leaving is groups.leave's own (it marks the folder old itself): a left mark adds nothing
FS[R .. "/_band/removed/Box.json"] = nil
tick()
assert(not groups.is_old(R), "the guest's mark gone: not old")
FS[R .. "/_band/removed/Box.json"] = band.json_encode({ user = ME, device = MYDEV, by = ME, at = now - 120, left = true })
removal.device_of = function() return MYDEV end
tick()
assert(not groups.is_old(R), "a left mark: nothing here (groups.leave already did it)")
FS[R .. "/_band/removed/Box.json"] = nil
tick()

-- ---- 2. Paste join code into the old copy: joined again, not "already in" -----------------------------------------------------------
services.syncthing_path = function() return "st" end
local code = { id = ("J"):rep(7) .. ("-" .. ("J"):rep(7)):rep(7), band = SID, name = "Smiley" }
local root, why = services.join_band({ root = R }, code)
assert(root == R and why == "already", "a current studio: already in, as before")
groups.remember_old(R, "Smiley", SID)
root, why = services.join_band({ root = "/s/StudioSync Other" }, code)
-- (the stand-in can't make the folder: what it tried names the old copy's folder, not a new "StudioSync Smiley 2" beside it)
assert(root == nil and tostring(why):find("Couldn't make the studio's folder at " .. R, 1, true), "an old copy: joined again into it (" .. tostring(why) .. ")")
local src = assert(io.open("lib/services.lua", "rb")):read("a")
assert(src:find('return root, was_old and "back" or nil', 1, true), "and join_band says it's back")

-- ---- 3. joining again asks the inviter's computer, though the old copy has its band.json ----------------------------------------------
FS[R .. "/_band/band.json"] = band.json_encode({ id = SID, name = "Smiley" })
local asked = {}
local joins = require("joins")
joins.request = function(r, tok) asked[#asked + 1] = r; return true end
services.join_band = function() return R, "back" end
services.parse_join = function() return { id = code.id, band = SID, invite = { studio = SID, host = "james-main.tail9.ts.net", name = "Smiley" } } end
band.settings = function() return { root = R, user = ME } end
local invite = require("invite")
local h = band.code_hash("abc")
band.set_ext_json(band.SECTION, "invite redeem", { [h] = { code = "abc", studio = SID, name = "Smiley", host = "james-main.tail9.ts.net", ends = os.time() + 60 } }, true)
assert(invite.on_token(h, { token = "x" }) == true and asked[1] == R, "an invite link's answer into an old copy: their computer asked (it never was)")
local pg = assert(io.open("lib/page_groups.lua", "rb")):read("a")
assert(pg:find('code.invite and (why == "back" or not reaper.file_exists(root .. "/_band/band.json"))', 1, true), "Paste join code: the same")
-- an invite link for a studio whose copy is old here isn't "already in it"
groups.remember_old(R, "Smiley", SID)
invite.say = function() end
invite.confirm = function() return false end
services.my_tailscale_name = function() return "box.tail9.ts.net." end
local _, said = invite.handle_link(invite.code_link(SID, "Smiley", "james-main.tail9.ts.net", ("a"):rep(invite.CODE_LEN)))
assert(said == "not accepted", "a code link for a studio this computer was taken out of: on to the Yes box, not \"already in\" (" .. tostring(said) .. ")")

print("ok: rt-fix7 join (taken out: the copy is old here, Paste join code and links join it again and ask)")
