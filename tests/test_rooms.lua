-- rooms.bad_name is pure (lupa or any Lua 5.4, from the repo root). (rooms.plan / merged went in 0.58.97: Bring into is mirror's.)
package.loaded.band = {}
package.loaded.sync = {}
package.path = "lib/?.lua;" .. package.path
local rooms = require("rooms")
assert(rooms.bad_name("chorus ideas") == nil and rooms.bad_name("Take-2_b") == nil, "ordinary names")
for _, n in ipairs({ "", " lead", "../up", "a/b", "dot.name", "CON", "nul", "Com1", "lpt9", string.rep("x", 31), "caf\195\169", "tab\1x" }) do
  assert(rooms.bad_name(n), "refused: " .. n)
end
print("ok")
