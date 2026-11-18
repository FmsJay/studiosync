-- Finding a plug-in (James, 0.59.24: "it's hard to actually find plugins... add the same categories REAPER uses, or an easy filter to see only
-- studiosync plugins or both"). REAPER's FX folders don't nest, so "StudioSync (everyone has)" can't hold its categories; this list can: a
-- search, REAPER's own categories (reaper-fxtags.ini's [category], as its FX browser shows them, and Instruments), Only what everyone has
-- or all of yours, and Add puts one on the selected track.
local band = require("band")
local plugins = require("plugins")
local fxpick = {}

local PREFER = { VST3 = 1, VST3i = 1, CLAP = 2, CLAPi = 2, VST = 3, VSTi = 3, AU = 4, AUi = 4, LV2 = 5, LV2i = 5, JS = 6 }

-- reaper-fxtags.ini's [category]: file key -> { categories }. Pure.
function fxpick.categories(text)
  local out, sec = {}, nil
  for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local s = line:match("^%[(.-)%]%s*$")
    if s then sec = s
    elseif sec == "category" then
      local k, v = line:match("^(.-)=(.*)$")
      if k then
        local cats = {}
        for c in (v .. "|"):gmatch("([^|]*)|") do if c ~= "" and c ~= "BandSync" and c:sub(1, #plugins.CATEGORY) ~= plugins.CATEGORY then cats[#cats + 1] = c end end
        out[k] = cats
      end
    end
  end
  return out
end

-- Every plug-in here once (its best format), with its categories and whether everyone in the studio has it. Pure but for `installed`
-- ({ {name, ident} }), the tags file's text and the set everyone has.
function fxpick.list(installed, tags_text, everyone)
  local cats, best = fxpick.categories(tags_text), {}
  for _, p in ipairs(installed) do
    local kind = plugins.kind(p.name) or ""
    local k = plugins.key(p.name)
    if PREFER[kind] and (not best[k] or PREFER[kind] < PREFER[best[k].kind]) then best[k] = { name = p.name, ident = p.ident, kind = kind, key = k } end
  end
  local out = {}
  for k, it in pairs(best) do
    local tk = plugins.tag_key(it.ident, it.kind)
    local c = {}
    for _, x in ipairs(tk and cats[tk] or {}) do c[#c + 1] = x end
    if it.kind:match("i$") then table.insert(c, 1, "Instruments") end
    if it.kind == "JS" then c[#c + 1] = "JSFX" end
    if #c == 0 then c[1] = "Other" end
    it.cats, it.everyone = c, everyone[k] == true or it.kind == "JS" -- (JSFX are on every computer: REAPER's own, or the same ReaPack package)
    it.label = (it.name:gsub("^%w+:%s*", ""))
    out[#out + 1] = it
  end
  table.sort(out, function(a, z) return a.label:lower() < z.label:lower() end)
  return out
end

local state = { filter = "", cat = "All", only = true, at = -math.huge, root = nil, items = {}, cats = {} }
local function refresh(cfg)
  if reaper.time_precise() - state.at < 30 and state.root == (cfg and cfg.root) then return end
  local everyone = {}
  if cfg and cfg.root then
    local ok, set = pcall(plugins.band, cfg)
    if ok and set then everyone = set end
  end
  state.items = fxpick.list(plugins.installed(), band.read(reaper.GetResourcePath() .. "/reaper-fxtags.ini") or "", everyone)
  local seen, cats = {}, {}
  for _, it in ipairs(state.items) do for _, c in ipairs(it.cats) do if not seen[c] then seen[c] = true; cats[#cats + 1] = c end end end
  table.sort(cats, function(a, z) if a == "Instruments" then return true elseif z == "Instruments" then return false end return a < z end)
  table.insert(cats, 1, "All")
  state.cats, state.at, state.root = cats, reaper.time_precise(), cfg and cfg.root
end

-- Does `it` match the search, the category and the switch? Pure.
function fxpick.matches(it, filter, cat, only)
  if only and not it.everyone then return false end
  if cat ~= "All" then
    local hit = false
    for _, c in ipairs(it.cats) do if c == cat then hit = true end end
    if not hit then return false end
  end
  filter = (filter or ""):lower()
  return filter == "" or it.label:lower():find(filter, 1, true) ~= nil or table.concat(it.cats, " "):lower():find(filter, 1, true) ~= nil
end

function fxpick.draw(ctx, ImGui, cfg, proj)
  refresh(cfg)
  ImGui.SetNextItemWidth(ctx, 160)
  local ch, v = ImGui.InputTextWithHint(ctx, "##fxfind", "Search plug-ins", state.filter)
  if ch then state.filter = v end
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 150)
  if ImGui.BeginCombo(ctx, "##fxcat", state.cat) then
    for _, c in ipairs(state.cats) do if ImGui.Selectable(ctx, c, c == state.cat) then state.cat = c end end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, "REAPER's own categories (its FX browser's Category list), and Instruments.")
  ImGui.SameLine(ctx)
  local cho, only = ImGui.Checkbox(ctx, "Only what everyone has", state.only)
  if cho then state.only = only end
  ImGui.SetItemTooltip(ctx, "On: only plug-ins every computer in the studio has (and JSFX), so the part sounds the same everywhere.\nOff: all of yours, the ones everyone has marked.")
  local shown, h = 0, math.max(120, math.min(320, select(2, ImGui.GetContentRegionAvail(ctx)) - 8))
  if ImGui.BeginTable(ctx, "fxpick", 3, ImGui.TableFlags_RowBg | ImGui.TableFlags_ScrollY, 0, h) then
    ImGui.TableSetupColumn(ctx, "Plug-in", ImGui.TableColumnFlags_WidthStretch, 3)
    ImGui.TableSetupColumn(ctx, "Category", ImGui.TableColumnFlags_WidthStretch, 2)
    ImGui.TableSetupColumn(ctx, "", ImGui.TableColumnFlags_WidthFixed, 44)
    for _, it in ipairs(state.items) do
      if fxpick.matches(it, state.filter, state.cat, state.only) then
        shown = shown + 1
        ImGui.TableNextRow(ctx)
        ImGui.TableNextColumn(ctx)
        if it.everyone or state.only then ImGui.Text(ctx, it.label) else ImGui.TextDisabled(ctx, it.label) end
        if not state.only then ImGui.SetItemTooltip(ctx, it.everyone and "Everyone in the studio has it." or "Not everyone has it: their copy plays a print of the part.") end
        ImGui.TableNextColumn(ctx); ImGui.TextDisabled(ctx, table.concat(it.cats, ", "))
        ImGui.TableNextColumn(ctx)
        ImGui.PushID(ctx, it.key)
        if ImGui.SmallButton(ctx, "Add") then
          local tr = proj and reaper.GetSelectedTrack(proj, 0)
          if not tr then band.msg("Select a track first: Add puts the plug-in on it.")
          else
            local idx = reaper.TrackFX_AddByName(tr, it.name, false, -1)
            if idx >= 0 then reaper.TrackFX_Show(tr, idx, 3); band.log(it.label .. " added to " .. select(2, reaper.GetTrackName(tr))) end
          end
        end
        ImGui.SetItemTooltip(ctx, "On the selected track, its window open.")
        ImGui.PopID(ctx)
      end
    end
    ImGui.EndTable(ctx)
  end
  ImGui.TextDisabled(ctx, string.format("%d shown. New plug-ins show after REAPER restarts (it lists them when it starts).", shown))
end

return fxpick
