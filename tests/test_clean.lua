-- 0.59.19 (lupa or Lua 5.4, from the repo root): band.clean makes the names the Mac and Linux installers' iconv makes.
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
reaper.GetOS = reaper.GetOS or function() return "Win64" end
reaper.GetExtState = reaper.GetExtState or function() return "" end
local band = require("band")
assert(band.clean("CHILIØ") == "CHILIO", "Ø, as the installer makes it")
assert(band.clean("José") == "Jose", "precomposed é")
assert(band.clean("Jose\204\129") == "Jose", "a Mac's decomposed é")
assert(band.clean("Straße Œuvre") == "Strasse OEuvre", "ß and Œ")
assert(band.clean("Łódź Þór Ñandú") == "Lodz Thor Nandu", "Latin Extended-A, Þ as the Mac's iconv makes it")
assert(band.clean("2×4") == "2x4", "×")
assert(band.clean("  Al-B_2 (demo)! ") == "Al-B_2 demo", "plain names as before")
assert(band.clean("bad\255byte") == "badbyte", "not UTF-8: odd bytes dropped")
assert(band.clean("Café") == band.clean(band.clean("Café")), "cleaning twice changes nothing")
print("ok")
