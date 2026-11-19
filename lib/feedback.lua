-- Bug reports, feedback and feature requests from inside StudioSync (James, 0.58.79: "a bug report/feedback button that saves either to
-- GitHub, or to our local folder or both, for you to take in feedback after our tests and other users' tests").
--   The studio's folder: <root>/_band/feedback/<kind>-<UTC>-<user>.md, one file each (one writer, so Syncthing never conflicts). It
--     reaches every computer in the studio, the developer's too, with what the computer was running and the last of its activity list.
--     With no studio yet: <StudioSync home>/feedback/, on this computer only.
--   GitHub: opens a new issue on github.com/FmsJay/studiosync in the browser, filled in (title, body, label), for the person to send with
--     their own GitHub account. Nothing is sent from here: no token, no account of ours.
-- GitHub needs a title: a blank subject takes the body's first line, a blank body says so. A report needs one or the other.
local band = require("band")
local feedback = {}

feedback.REPO = "https://github.com/FmsJay/studiosync"
feedback.KINDS = { { "bug", "Bug report", "bug", "What happened, and what you expected. Steps to make it happen again help most." },
  { "feedback", "Feedback", "feedback", "What works, what's confusing, what you'd change." },
  { "feature", "Feature request", "enhancement", "What you'd like it to do, and what for." } }
feedback.URL_MAX = 7000 -- (browsers and GitHub take about 8 KB of address: the rest is cut, saying so)

local function kind_of(k) for _, x in ipairs(feedback.KINDS) do if x[1] == k then return x end end return feedback.KINDS[1] end

-- The title and body a report goes out with. Pure. -> title, body, or nil + why.
function feedback.compose(kind, subject, body)
  subject, body = (subject or ""):match("^%s*(.-)%s*$"), (body or ""):match("^%s*(.-)%s*$")
  if subject == "" and body == "" then return nil, "Write a subject or what happened first." end
  if subject == "" then subject = body:match("^[^\r\n]*"):sub(1, 80) end
  if body == "" then body = "(no details: the subject says it)" end
  local tag = ({ bug = "[Bug] ", feedback = "[Feedback] ", feature = "[Feature] " })[kind] or ""
  return tag .. subject, body
end

-- %-encoding for a URL's query. Pure.
function feedback.encode(s) return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)) end

-- The new-issue address for GitHub, kept under URL_MAX (the body cut from the end, saying so). Pure.
function feedback.issue_url(title, body, label)
  local function url(b)
    return feedback.REPO .. "/issues/new?title=" .. feedback.encode(title) .. "&labels=" .. feedback.encode(label) .. "&body=" .. feedback.encode(b)
  end
  local u = url(body)
  local cut = #body
  while #u > feedback.URL_MAX and cut > 0 do
    cut = math.floor(cut * 0.8)
    u = url(body:sub(1, cut) .. "\n\n(cut short: the full report is in the studio's _band/feedback folder)")
  end
  return u
end

-- What this computer runs, for the report.
function feedback.system(proj)
  local ok, have, mode = pcall(reaper.GetAudioDeviceInfo, "MODE")
  local lines = { "- StudioSync " .. band.VERSION, "- REAPER " .. reaper.GetAppVersion() .. " on " .. reaper.GetOS(),
    "- Audio: " .. ((ok and have and mode ~= "") and mode or "?") }
  local b = proj and band.binding(proj)
  if b then lines[#lines + 1] = "- Project: " .. tostring(b.song) .. " / " .. tostring(b.room) end
  return table.concat(lines, "\n")
end

-- Save it to the studio's folder (or this computer's, with no studio). -> path, or nil + why.
function feedback.save(cfg, kind, title, body, extra)
  local dir = (cfg and cfg.root and cfg.root ~= "") and (cfg.root .. "/_band/feedback") or (band.home() .. "/feedback")
  reaper.RecursiveCreateDirectory(dir, 0)
  local user = (cfg and cfg.user) or "someone"
  local path = string.format("%s/%s-%s-%s.md", dir, kind, os.date("!%Y%m%d-%H%M%SZ"), (user:gsub("[^%w%-_]", "_")))
  local text = "# " .. title .. "\n\n" .. kind_of(kind)[2] .. " from " .. user .. ", " .. os.date("!%Y-%m-%d %H:%M UTC") .. "\n\n" .. body .. "\n\n" .. (extra or "") .. "\n"
  local ok, why = pcall(band.write_atomic, path, text)
  if not ok then return nil, tostring(why) end
  return path
end

-- ---------------------------------------------------------------- the window
local st = { open = false, kind = "bug", subject = "", body = "", folder = true, github = false, log = true }

-- The button that opens it. `small`: a SmallButton.
function feedback.button(ctx, ImGui, small)
  if (small and ImGui.SmallButton or ImGui.Button)(ctx, "Feedback##fb") then st.open = true end
  ImGui.SetItemTooltip(ctx, "Report a bug, give feedback or ask for a feature: saved in the studio's folder for whoever looks after StudioSync, and/or as an issue on GitHub.")
end

-- What's in its window (feedback.draw).
local function body(ctx, ImGui, cfg, proj)
  local k = kind_of(st.kind)
  ImGui.SetNextItemWidth(ctx, 200)
  if ImGui.BeginCombo(ctx, "##fbkind", k[2]) then
    for _, x in ipairs(feedback.KINDS) do
      if ImGui.Selectable(ctx, x[2], x[1] == st.kind) then st.kind = x[1]; st.log = x[1] == "bug" end
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetNextItemWidth(ctx, -1)
  _, st.subject = ImGui.InputTextWithHint(ctx, "##fbsubject", "subject (or leave it: the first line below is used)", st.subject)
  local _, h = ImGui.GetContentRegionAvail(ctx)
  _, st.body = ImGui.InputTextMultiline(ctx, "##fbbody", st.body, -1, math.max(80, h - 4 * ImGui.GetFrameHeightWithSpacing(ctx)))
  if st.body == "" and not ImGui.IsItemActive(ctx) then -- (a hint for the big box: InputTextMultiline has none)
    local x, y = ImGui.GetItemRectMin(ctx)
    ImGui.DrawList_AddText(ImGui.GetWindowDrawList(ctx), x + 6, y + 4, 0x888888FF, k[4])
  end
  local has_studio = cfg and cfg.root and cfg.root ~= ""
  -- (each on the next line when it won't fit: three in a row ran off the 520 px window. Round 1 review, 0.59.45)
  local function beside(label)
    ImGui.SameLine(ctx, 0, 16)
    if ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, label) + ImGui.GetFrameHeight(ctx) + 12 then ImGui.NewLine(ctx) end
  end
  _, st.folder = ImGui.Checkbox(ctx, has_studio and "Save in the studio's folder" or "Save on this computer", st.folder)
  ImGui.SetItemTooltip(ctx, has_studio and "Goes to everyone in the studio with the rest of its files (_band/feedback), where it's read after testing." or
    "No studio yet: kept in StudioSync's own folder on this computer. Use GitHub to send it on.")
  beside("Open it on GitHub")
  _, st.github = ImGui.Checkbox(ctx, "Open it on GitHub", st.github)
  ImGui.SetItemTooltip(ctx, "Opens a new issue on GitHub in your browser, filled in, for you to send with your GitHub account (it's free).\nAnyone can read issues there.")
  beside("Add what it was doing")
  _, st.log = ImGui.Checkbox(ctx, "Add what it was doing", st.log)
  if ImGui.IsItemHovered(ctx) then -- (with debug mode on, Send also saves the project's copy and crash reports, ticked or not: said so. Round 1 review, 0.59.45)
    local dbg = has_studio and require("debugmode").on(cfg.root)
    ImGui.SetItemTooltip(ctx, "Adds StudioSync's version, REAPER's, the audio system, the project's name and the last lines of the activity list. No files or audio." ..
      (dbg and "\nDebug mode is on in this studio, so Send also saves a copy of this project, its log and REAPER's crash reports for the owner and admins." or ""))
  end
  local title, body = feedback.compose(st.kind, st.subject, st.body)
  ImGui.BeginDisabled(ctx, not title or not (st.folder or st.github)); st.disabled = true
  if ImGui.Button(ctx, "Send##fbsend") then
    local extra = ""
    if st.log then
      local lines = {}
      for i, l in ipairs(band.activity()) do if i > 25 then break end; lines[#lines + 1] = "    " .. l end
      extra = "## This computer\n\n" .. feedback.system(proj) .. "\n\n## Activity (newest first)\n\n" .. table.concat(lines, "\n")
    end
    local said = {}
    -- (the studio's debug mode: this computer's report, project copy, setup and crash reports go with it. lib/debugmode.lua, 0.59.43)
    if has_studio then
      local dm = require("debugmode")
      if dm.on(cfg.root) then
        pcall(dm.collect, cfg, proj, proj and band.binding(proj), "bug report")
        pcall(dm.write_computer, cfg)
      end
    end
    if st.folder then
      local path, why = feedback.save(cfg, st.kind, title, body, extra)
      said[#said + 1] = path and ("saved in " .. (has_studio and "the studio's feedback folder" or path)) or ("couldn't save it: " .. tostring(why))
    end
    if st.github then
      band.open_url(feedback.issue_url(title, body .. (extra ~= "" and ("\n\n" .. extra) or ""), k[3]))
      said[#said + 1] = "opened on GitHub: press Submit new issue there"
    end
    band.log(k[2] .. ": " .. table.concat(said, "; "))
    st.subject, st.body, st.open = "", "", false
  end
  ImGui.EndDisabled(ctx); st.disabled = false
  if not title then ImGui.SameLine(ctx); ImGui.TextDisabled(ctx, "Write a subject or what happened.") end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Cancel##fbcancel") then st.open = false end
end
-- Draw it while open (each frame, after the panel's main window). `proj`: the project in front.
-- (its body in a pcall, as lib/callwin.lua's: an error in Send left its window and disabled block open, and the panel died with them. End is
-- always reached; the error goes to the log file, once per different one. Round 4 review, 0.59.49)
function feedback.draw(ctx, ImGui, cfg, proj)
  if not st.open then return end
  ImGui.SetNextWindowSize(ctx, 520, 440, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "StudioSync feedback##fbwin", true, ImGui.WindowFlags_NoCollapse)
  st.open = open
  if not visible then return end
  st.disabled = false
  local ok, e = xpcall(body, debug.traceback, ctx, ImGui, cfg, proj)
  if not ok then
    if st.disabled then pcall(ImGui.EndDisabled, ctx) end
    local line = tostring(e):match("^[^\n]*")
    if line ~= st.err_said then st.err_said = line; band.log_error("feedback", e); band.log("feedback couldn't finish: " .. line) end
  end
  ImGui.End(ctx)
end

return feedback
