-- mixlayer.split_live is pure (lupa or any Lua 5.4, from the repo root)
package.path = "lib/?.lua;" .. package.path
local mix = require("mixlayer")
local chain = table.concat({ "<FXCHAIN", "  WNDRECT 0 0 0 0", "  SHOW 0",
  "  BYPASS 0 0 0", "  <VST \"VST3: SonoBus (Sonosaurus)\" SonoBus.vst3 0", "    dXNlck5hbWU9SmFtZXM=", "  >", "  FXID {S}", "  WAK 0 0",
  "  BYPASS 0 0 0", "  <JS loser/limiter \"\"", "    0 0", "  >", "  FXID {L}", "  WAK 0 0", ">" }, "\n")
local kept, live, head = mix.split_live(chain)
assert(not kept:find("SonoBus") and not kept:find("dXNlck5hbWU9"), "SonoBus and its state (user name, group password) never travel")
assert(kept:find("loser/limiter", 1, true) and kept:find("FXID {L}", 1, true) and kept:find("SHOW 0", 1, true), "the rest of the chain does")
assert(#live == 1 and live[1]:find("FXID {S}", 1, true) and #head == 2, "the live plug-in comes back whole, for the machine to keep")
assert(kept:sub(1, 8) == "<FXCHAIN" and kept:sub(-1) == ">", "still one block")
print("ok")
