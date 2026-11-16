-- services.is_device_id / on_tailnet are pure (lupa or any Lua 5.4, from the repo root)
reaper = reaper or { GetOS = function() return "Win64" end }
package.loaded.band = package.loaded.band or {}
package.path = "lib/?.lua;" .. package.path
local services = require("services")
assert(services.is_device_id("2MOGZMD-MVLUUSO-D6GXQIG-HMDVUBG-AOW6LHR-LMQQT6P-V4V5P73-6ZR5NQZ"), "a real device ID")
assert(not services.is_device_id("2MOGZMD-MVLUUSO-D6GXQIG-HMDVUBG-AOW6LHR-LMQQT6P-V4V5P73"), "too short")
assert(not services.is_device_id("2MOGZMD-MVLUUSO-D6GXQIG-HMDVUBG-AOW6LHR-LMQQT6P-V4V5P73-6ZR5NQ;"), "odd characters")
assert(not services.is_device_id("2MOGZMDMVLUUSO-D6GXQIG-HMDVUBG-AOW6LHR-LMQQT6P-V4V5P73-6ZR5NQZ-"), "dashes in the wrong places")
assert(services.on_tailnet("100.97.210.49:22000") and services.on_tailnet("100.64.0.1:22000") and services.on_tailnet("100.127.255.1:1"), "100.64.0.0/10")
assert(not services.on_tailnet("100.63.0.1:22000") and not services.on_tailnet("100.128.0.1:22000"), "just outside it")
assert(not services.on_tailnet("162.157.58.171:22000") and not services.on_tailnet("192.168.1.5:22000"), "internet and LAN")
assert(services.on_tailnet("[fd7a:115c:a1e0::7e48:8e48]:22000"), "Tailscale's IPv6 range")
local ts = '{"Self": {"ID": "1", "DNSName": "pc.tail1234.ts.net.", "OS": "windows"}, "CurrentTailnet": {"MagicDNSEnabled": %s}}'
assert(services.tailscale_name_in(ts:format("true")) == "pc.tail1234.ts.net", "its name, no last dot")
assert(services.tailscale_name_in(ts:format("false")) == nil, "names turned off: not a name that won't resolve")
assert(services.tailscale_name_in("") == nil, "not signed in")
assert(services.tailscale_running_in('{"BackendState": "Running"}'), "on")
assert(not services.tailscale_running_in('{"BackendState":"Stopped"}') and not services.tailscale_running_in(""), "off, or no answer")
assert(not services.on_tailnet("[fd7a:115c:a1e1::1]:22000") and not services.on_tailnet(""), "other IPv6, nothing")
-- the invitation: both lines carry the ID as the installers read it (BS_HOST_ID on a Mac, -HostId on Windows)
local inv_id = "2MOGZMD-MVLUUSO-D6GXQIG-HMDVUBG-AOW6LHR-LMQQT6P-V4V5P73-6ZR5NQZ"
local inv = services.invite_text(inv_id, { id = "bandsync", name = "Chilio" })
assert(inv:find('install_mac.sh?$(date +%s)" | BS_HOST_ID=' .. inv_id .. " BS_BAND_ID=bandsync BS_BAND_NAME='Chilio' bash", 1, true), "Mac line")
assert(inv:find('install_linux.sh?$(date +%s)" | BS_HOST_ID=' .. inv_id .. " BS_BAND_ID=bandsync BS_BAND_NAME='Chilio' bash", 1, true), "Linux line (0.58.74)")
assert(inv:find("-File $f -HostId " .. inv_id .. " -BandId bandsync -BandName 'Chilio'", 1, true) and inv:find('"$env:TEMP\\studiosync_install.ps1"', 1, true), "Windows line")
assert(inv:find("^Join Chilio on StudioSync"), "it says which band")
local g = services.invite_text(inv_id, { id = "bandsync", name = "Chilio" }, "tskey-auth-kAbc123CNTRL-xyz")
assert(g:find("BS_BAND_NAME='Chilio' BS_TS_KEY=tskey-auth-kAbc123CNTRL-xyz bash", 1, true) and g:find("-BandName 'Chilio' -TsKey tskey-auth-kAbc123CNTRL-xyz\n", 1, true), "a guest's key, in both lines")
assert(not services.invite_text(inv_id, { id = "bandsync", name = "Chilio" }, "tskey-auth-x; rm -rf ~"):find("rm -rf", 1, true), "only a key goes into a command")
-- the join code: on its own, in the whole message, from an old invitation's lines; nothing else reads as one
local code = services.parse_join(services.join_code(inv_id, { id = "bandsync-night-shift-1a2b", name = "Night Shift" }))
assert(code and code.id == inv_id and code.band == "bandsync-night-shift-1a2b" and code.name == "Night Shift", "the code")
code = services.parse_join(services.invite_text(inv_id, { id = "bandsync", name = "Chilio" }))
assert(code and code.id == inv_id and code.band == "bandsync" and code.name == "Chilio", "the whole message")
assert(code.key == nil, "no guest key in an ordinary invitation")
assert(services.parse_join(g).key == "tskey-auth-kAbc123CNTRL-xyz", "a guest's key comes through a pasted invitation")
assert(services.parse_join(inv:gsub("Chilio", "X", 1) .. "\ntskey-auth-x; rm -rf ~").key == "tskey-auth-x", "only key characters")
code = services.parse_join("powershell -File $f -HostId " .. inv_id .. " -BandId bandsync-x -BandName 'Old One'\n")
assert(code and code.band == "bandsync-x" and code.name == "Old One", "an old Windows line")
assert(services.parse_join("studiosync-join:" .. inv_id .. ":default:Evil") == nil and services.parse_join("studiosync-join:" .. inv_id .. ":studiosync-a-1b2c:A").band == "studiosync-a-1b2c", "only a StudioSync folder (0.58.76)")
code = services.parse_join("curl x | BS_HOST_ID=" .. inv_id .. " BS_BAND_ID=bandsync-y BS_BAND_NAME='Old Two' bash")
assert(code and code.band == "bandsync-y" and code.name == "Old Two", "an old Mac line")
assert(services.parse_join("") == nil and services.parse_join("hello") == nil and services.parse_join("studiosync-join:ABC:x:y") == nil, "not a code")
code = services.parse_join("studiosync-join:" .. inv_id .. ":bandsync-z:Bad \"; rm -rf ~\n")
assert(code and code.name == "Bad  rm -rf", "a name can't carry anything into a command")
-- who's asking: only the studios you may let people into, and a new computer with no studio named
local bands_stub, groups_stub = { { id = "a", name = "Mine", root = "/a" }, { id = "b", name = "Theirs", root = "/b" }, { id = "c", name = "Closed", root = "/c" } }, nil
package.loaded.band.bands = function() return bands_stub end
groups_stub = { is_old = function(r) return r == "/c" end, may_manage = function(r, me) return me == "Owner" or (me == "Half" and r == "/a") end }
package.loaded.groups = groups_stub
services.pending_devices = function() return { { id = "NEW", name = "New", address = "x" } } end
services.pending_folders = function() return { { folder = "a", id = "K1" }, { folder = "b", id = "K2" }, { folder = "c", id = "K3" }, { folder = "stranger", id = "K4" } } end
services.device_name = function(id) return "name of " .. id end
local asks = services.join_asks("Half")
assert(#asks == 2 and asks[1].id == "NEW" and asks[1].folder == nil, "a new computer asks, with no studio named")
assert(asks[2].id == "K1" and asks[2].root == "/a" and asks[2].band == "Mine" and asks[2].name == "name of K1", "the one studio this person runs, not the others")
assert(#services.join_asks("Member") == 0, "someone who runs nothing is asked nothing")
asks = services.join_asks("Owner")
assert(#asks == 3 and asks[2].band == "Mine" and asks[3].band == "Theirs", "a closed studio and one that isn't here don't ask")
-- a band's Syncthing folder id from its name
assert(services.band_id("The Night Shift") == "studiosync-the-night-shift" and services.band_id("  Chilio ") == "studiosync-chilio", "ids")
assert(services.band_id("") == "studiosync-band" and services.band_id("Jazz--Trio") == "studiosync-jazz-trio", "empty, repeats")
-- Tailscale's policy: the tagOwners lines go in once, comments and trailing commas kept; a tag in a comment or a rule doesn't count
package.loaded.band.json_decode = function(s) local ok, v = pcall(require("json").decode, s); return ok and v or nil end
local pol = '// Example policy {\n{\n\t"acls": [\n\t\t{"action": "accept", "src": ["tag:bandsync"], "dst": ["*:*"]},\n\t],\n}\n'
local new = services.policy_with_tags(pol)
assert(new and new:find('^// Example policy {\n{\n\t"tagOwners": {\n\t\t"tag:bandsync": %["autogroup:member"%],\n\t\t"tag:bandsync%-guest": %["autogroup:member"%],\n\t},\n\t"acls"'), "added after the policy's own {, not the comment's")
assert(services.policy_with_tags(new) == nil, "nothing to add the second time")
local half = '{\n  // "tag:bandsync-guest": [],\n  "tagOwners": {\n    "tag:bandsync": ["autogroup:admin"],\n  },\n}'
new = services.policy_with_tags(half)
assert(new == '{\n  // "tag:bandsync-guest": [],\n  "tagOwners": {\n\t\t"tag:bandsync-guest": ["autogroup:member"],\n    "tag:bandsync": ["autogroup:admin"],\n  },\n}', "only the missing one, into the existing tagOwners: someone's own owners stay")
assert(services.policy_with_tags("") == nil, "no policy at all: nothing")
-- the guest rule: only Tailscale's starting allow-all is split; anyone's own rules stay
local start = '{\n\t"grants": [\n\t\t// Allow all connections.\n\t\t{"src": ["*"], "dst": ["*"], "ip": ["*"]},\n\t],\n\t"ssh": [\n\t\t{"action": "check", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["root"]},\n\t],\n}'
new = services.policy_with_guest_rule(services.policy_with_tags(start))
assert(new and new:find('\t\t{"src": ["autogroup:member", "tag:bandsync"], "dst": ["*"], "ip": ["*"]},\n\t\t{"src": ["tag:bandsync-guest"], "dst": ["autogroup:member", "tag:bandsync"], "ip": ["tcp:22000", "udp:22000", "tcp:2049"]},\n\t],', 1, true), "split in place, same indent")
assert(new:find("// Allow all connections.", 1, true) and new:find('"ssh"', 1, true), "comments and the rest stay")
assert(select(2, services.policy_with_guest_rule(new)) == "has it", "once")
local acl = '{"acls": [{"action": "accept", "src": ["*"], "dst": ["*:*"]}]}'
assert(services.policy_with_guest_rule(acl) == '{"acls": [{"action": "accept", "src": ["autogroup:member", "tag:bandsync"], "dst": ["*:*"]},\n' ..
  '{"action": "accept", "src": ["tag:bandsync-guest"], "dst": ["autogroup:member:22000,2049", "tag:bandsync:22000,2049"]}]}', "the older acls form")
assert(select(2, services.policy_with_guest_rule('{"tagOwners": {"tag:server": []}, "grants": [{"src": ["*"], "dst": ["*"], "ip": ["*"]}]}')) == "own rules", "another tag")
assert(select(2, services.policy_with_guest_rule('{"grants": [{"src": ["*"], "dst": ["*"], "ip": ["*"]}, {"src": ["*"], "dst": ["autogroup:internet"], "ip": ["*"]}]}')) == "own rules", "another rule from everyone")
assert(select(2, services.policy_with_guest_rule('{"grants": [{"src": ["group:band"], "dst": ["*"], "ip": ["*"]}]}')) == "own rules", "no allow-all")
assert(services.policy_with_guest_rule('{"grants": [/* {"src": ["*"], "dst": ["*"], "ip": ["*"]} */ {"src": ["*"], "dst": ["*"], "ip": ["*"]}]}'):find('/* {"src": ["*"]', 1, true), "the rule, not a commented-out copy")
-- guests more than a day old
local now = os.time({ year = 2026, month = 11, day = 6, hour = 12, min = 0, sec = 0 })
local devs = '{"devices": [{"id": "1", "tags": ["tag:bandsync-guest"], "created": "2026-11-05T11:00:00Z"}, {"id": "2", "tags": ["tag:bandsync-guest"], "created": "2026-11-05T13:00:00Z"},' ..
  ' {"id": "3", "tags": ["tag:bandsync"], "created": "2020-01-01T00:00:00Z"}, {"id": "4", "created": "2020-01-01T00:00:00Z"}]}'
local old = services.old_guests(devs, now)
assert(#old == 1 and old[1] == "1", "only the guest from over a day ago; members and group machines stay")
assert(#services.old_guests("", now) == 0 and #services.old_guests('{"message": "unauthorized"}', now) == 0, "no answer, an error: nobody")

-- (0.58.57) which Tailscale network this computer is on, and which accounts it's signed in to: from the PC's own output, 2026-11-15
local status = '{"Version":"1.104.5","BackendState":"Running","CurrentTailnet":{"Name":"jamesalexander190@gmail.com","StableID":"Tybtnk",' ..
  '"MagicDNSSuffix":"tail99132c.ts.net","MagicDNSEnabled":true},"Self":{"DNSName":"james-main.tail99132c.ts.net."}}'
local name, suffix = services.tailnet_in(status)
assert(name == "jamesalexander190@gmail.com" and suffix == "tail99132c.ts.net", "the network it's on: " .. tostring(name) .. " " .. tostring(suffix))
assert(services.tailnet_in('{"BackendState":"NeedsLogin"}') == nil, "signed out: none")
local list = services.profiles_in("0\nID    Tailnet                      Account\nb793  chiliocosm01@gmail.com       chiliocosm01@gmail.com\n" ..
  "4696  jamesalexander190@gmail.com  jamesalexander190@gmail.com*\n")
assert(#list == 2, "two accounts: " .. #list)
assert(list[1].id == "b793" and list[1].tailnet == "chiliocosm01@gmail.com" and not list[1].current, "the other one")
assert(list[2].id == "4696" and list[2].account == "jamesalexander190@gmail.com" and list[2].current, "the one in use (marked *)")
assert(#services.profiles_in("") == 0, "no answer yet: none")
assert(not services.tailscale_switch("4696; calc") and not services.tailscale_switch(nil), "only a plain account id is ever switched to")

-- (0.58.58) a switch away is written down, so a computer others rely on can put itself back; switching back removes it
local t0 = 1794775000
local away = services.switch_note(list, "b793", nil, t0)
assert(away.from_id == "4696" and away.from_tailnet == "jamesalexander190@gmail.com" and away.to_id == "b793" and away.to_tailnet == "chiliocosm01@gmail.com", "from home to the other")
assert(away.by == "StudioSync" and away["until"] > away.at, "with a time it's good until")
local on_b = services.profiles_in("b793  chiliocosm01@gmail.com  chiliocosm01@gmail.com*\n4696  jamesalexander190@gmail.com  jamesalexander190@gmail.com\n")
assert(services.switch_note(on_b, "4696", away, t0 + 60) == nil, "back where it came from: the note goes")
local third = services.profiles_in("c001  third@x.com  third@x.com\nb793  chiliocosm01@gmail.com  chiliocosm01@gmail.com*\n4696  jamesalexander190@gmail.com  jamesalexander190@gmail.com\n")
local onward = services.switch_note(third, "c001", away, t0 + 120)
assert(onward.from_id == "4696" and onward.to_id == "c001", "on to a third network: it still says where home is")
assert(services.switch_note(list, "4696", nil, t0) == nil, "already there: nothing written")

-- (0.58.61) Syncthing where winget unpacked it and made no shortcut (AgentBox's fresh Windows): the newest version's copy
do
  local band = package.loaded.band
  local real_sub, real_cmp, real_fe = band.subdirs, band.compare_versions, reaper.file_exists
  local tree = { ["L/Microsoft/WinGet/Packages"] = { "astral-sh.uv_x", "Syncthing.Syncthing_Microsoft.Winget.Source_8wekyb3d8bbwe" },
    ["L/Microsoft/WinGet/Packages/Syncthing.Syncthing_Microsoft.Winget.Source_8wekyb3d8bbwe"] = { "syncthing-windows-amd64-v2.1.7", "syncthing-windows-amd64-v2.1.10", "notes" } }
  band.subdirs = function(d) return tree[d] or {} end
  band.compare_versions = function(a, b)
    local pa, pb = {}, {}
    for n in a:gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
    for n in b:gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
    for i = 1, math.max(#pa, #pb) do if (pa[i] or 0) ~= (pb[i] or 0) then return (pa[i] or 0) > (pb[i] or 0) and 1 or -1 end end
    return 0
  end
  reaper.file_exists = function(p) return p:find("syncthing%.exe$") ~= nil end
  local got = services.winget_syncthing("L")
  assert(got and got:find("v2.1.10/syncthing.exe", 1, true), "the newest unpacked copy: " .. tostring(got))
  tree["L/Microsoft/WinGet/Packages"] = {}
  assert(services.winget_syncthing("L") == nil, "none there: nil")
  band.subdirs, band.compare_versions, reaper.file_exists = real_sub, real_cmp, real_fe
end
print("ok")
