-- 0.59.10 (lupa or Lua 5.4, from the repo root): the page eases to where the wheel sends it, drawn only ever forward, and gets there.
-- ImGui as it behaves: the wheel sets the scroll target in NewFrame (replacing one asked for last frame), Begin applies the target.
package.path = "lib/?.lua;" .. package.path
local smooth = require("smooth")

local function run(wheels, frames, maxy)
  local S, T, st, shown = 0, nil, nil, {}
  for f = 1, frames do
    local w = wheels[f]
    if w then T = S + w end -- NewFrame: the wheel
    if T then S = math.max(0, math.min(maxy, T)); T = nil end -- Begin
    local off, set
    st, off, set = smooth.step(st, S, maxy, false)
    shown[#shown + 1] = S - off
    if set then T = set end -- SetScrollY: next frame
  end
  return shown
end

local shown = run({ [2] = 100, [5] = 100, [8] = 100 }, 60, 10000)
for i = 2, #shown do assert(shown[i] >= shown[i - 1] - 1e-9, ("frame %d drawn back up: %.1f after %.1f"):format(i, shown[i], shown[i - 1])) end
assert(math.abs(shown[#shown] - 300) < 1, "three notches of 100 get to 300: " .. shown[#shown])
assert(shown[2] < 100, "eases: the first frame isn't the whole notch (" .. shown[2] .. ")")

shown = run({ [2] = 400, [10] = -150 }, 60, 10000)
local peak = 0
for i = 2, 9 do assert(shown[i] >= shown[i - 1] - 1e-9, "down: never back up"); peak = shown[i] end
for i = 11, #shown do assert(shown[i] <= shown[i - 1] + 1e-9, "up: never back down") end
assert(math.abs(shown[#shown] - 250) < 1, "down 400, up 150: 250 (" .. shown[#shown] .. ")")

shown = run({ [2] = 500 }, 60, 200)
assert(math.abs(shown[#shown] - 200) < 1 and math.max(table.unpack(shown)) <= 200 + 1e-9, "never past the bottom")
print("ok smooth")
