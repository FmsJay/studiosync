-- Live plug-ins in a FX chain: SonoBus and ReaNINJAM belong to this machine (lib/export.lua, lib/sessionfile.lua).
local mix = {}

-- A FXCHAIN block without SonoBus / ReaNINJAM, and those plug-ins on their own (each "BYPASS" line at the chain's
-- top level starts a plug-in). They belong to live sessions and carry this machine's identity (SonoBus: user name,
-- group and its password), so they never travel with the mix and a machine's own stay where they are. Pure.
-- Returns the block, the live plug-ins' text (list), and the chain's own header lines (list).
function mix.split_live(block)
  if not block then return nil, {}, {} end
  local lines = {}
  for l in (block .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
  if lines[#lines] == "" then lines[#lines] = nil end
  local head, groups, depth, cur = {}, {}, 0, nil
  for i = 2, #lines - 1 do -- inside "<FXCHAIN" ... ">"
    local l = lines[i]
    local t = l:match("^%s*(%S*)")
    if depth == 0 and t == "BYPASS" then cur = { l }; groups[#groups + 1] = cur
    elseif cur then cur[#cur + 1] = l
    else head[#head + 1] = l end
    if t:sub(1, 1) == "<" then depth = depth + 1 elseif t == ">" then depth = depth - 1 end
  end
  local out, live = { lines[1] }, {}
  for _, l in ipairs(head) do out[#out + 1] = l end
  for _, g in ipairs(groups) do
    local is_live = false
    for _, l in ipairs(g) do if l:match("^%s*<") and require("live").is_live_fx(l) then is_live = true end end
    if is_live then live[#live + 1] = table.concat(g, "\n") else out[#out + 1] = table.concat(g, "\n") end
  end
  out[#out + 1] = lines[#lines]
  return table.concat(out, "\n"), live, head
end

return mix
