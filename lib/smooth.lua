-- The page eases to where the wheel sends it (James, 0.58.23), and is drawn where it is on the way: never ahead, then back (James, 0.59.10:
-- "it kind of shakes around when I scroll on home"). ImGui moves the scroll in the frame the wheel turns, before StudioSync sees it, so
-- setting it back to the eased place showed each notch a jump forward and a step back. Now the content is drawn shifted to where it eases
-- to, and the scroll follows a frame later. Pure: the panel makes the ImGui calls (ui.smooth_scroll).
local smooth = {}

-- st: the page's state (nil the first time). y: the scroll ImGui has this frame. maxy: its range. held: the mouse is down (the scrollbar).
-- -> st, off (draw the page this much lower: y minus where it shows), set (the scroll to ask for, for next frame, or nil)
function smooth.step(st, y, maxy, held)
  if not st or held then return { at = y, to = y, set = y, prev = y, off = 0 }, 0, nil end
  -- (something moved it: the wheel, here or passed up from a card that can't scroll, or a key. ImGui's move replaces the one asked for
  -- last frame, so it counts from where the page was then)
  if math.abs(y - st.set) > 0.5 then st.to = st.to + (y - st.prev) end
  st.to = math.max(0, math.min(maxy, st.to))
  local at = math.abs(st.to - st.at) < 1 and st.to or st.at + (st.to - st.at) * 0.35
  st.at, st.prev = at, y
  st.off = math.abs(y - at) > 0.5 and y - at or 0
  st.set = st.off ~= 0 and at or y
  return st, st.off, st.off ~= 0 and at or nil
end

return smooth
