-- 0.59.40: the studio's debug reports reach the owner and admins only (lib/songsync.lua debug lines in .stignore).
package.path = "lib/?.lua;" .. package.path
reaper = setmetatable({ GetExtState = function() return "" end }, { __index = function() return function() return "" end end })
local songsync = require("songsync")
local member = { me = "Bee", hide = true }
local owner = { me = "James", hide = false }
assert(#songsync.debug_lines(owner) == 0, "the owner downloads everyone's")
local l = songsync.debug_lines(member)
assert(l[1] == "!/_debug/Bee" and l[2] == "/_debug", "a member keeps their own folder (so it's sent) and leaves the rest")
local text = songsync.merge("", { Lantern = true }, nil, nil, member)
local mine, rest, bandwide
local i = 0
for line in text:gmatch("[^\n]+") do
  i = i + 1
  if line == "!/_debug/Bee" then mine = i elseif line == "/_debug" then rest = i elseif line == "!/_*" then bandwide = i end
end
assert(mine and rest and bandwide and mine < rest and rest < bandwide, "first matching line wins: own, then the rest of _debug, before the band-wide folders")
assert(not songsync.merge("", { Lantern = true }, nil, nil, owner):find("_debug", 1, true), "nothing about _debug for the owner")
local only = songsync.merge("", nil, {}, nil, member)
assert(only:find("!/_debug/Bee", 1, true) and only:find("\n/_debug\n", 1, true), "a member keeping every song still leaves the others' reports")
assert(songsync.merge("", nil, {}, nil, owner) == "", "the owner keeping every song: no block at all, as before")

-- mirror.memo is (prefix, text, make) since 0.59.40: a caller still on (prefix .. text, make) failed every print (prints.lua, found by the suites)
local function memo_args(call) -- commas at the call's own depth, up to its `function`
  local depth, n, q = 0, 0, nil
  for c in call:gmatch(".") do
    if q then if c == q then q = nil end
    elseif c == '"' or c == "'" then q = c
    elseif c == "(" then depth = depth + 1 elseif c == ")" then depth = depth - 1
    elseif c == "," and depth == 0 then n = n + 1 end
  end
  return n
end
local files = { "lib/mirror.lua", "lib/prints.lua" }
for _, f in ipairs(files) do
  local h = assert(io.open(f, "r")); local s = h:read("a"); h:close()
  local calls = 0
  for start in s:gmatch("%.memo%(()") do
    if s:sub(start - 21, start - 1) ~= "function mirror.memo(" then
      local call = s:sub(start, s:find("function%s*%(", start) - 1)
      assert(memo_args(call) == 2, f .. ": mirror.memo takes (prefix, text, make): " .. call:sub(1, 60))
      calls = calls + 1
    end
  end
  assert(calls > 0, f .. ": its memo calls were found")
end
print("ok")
