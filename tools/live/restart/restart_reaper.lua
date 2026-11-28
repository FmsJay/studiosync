-- ReaPersona dev tool: restart REAPER the way ReaPersona's Apply does (install_shortcuts.py --after-reaper-quits --apply-setup), so
-- what waits in Scripts/ReaPersona/pending goes in, with no one at the computer. Run by restart_and_test.ps1 (reaper.exe -nonewinst).
-- Never loses work: it won't quit while any open project has unsaved changes, or is a new project with tracks that was never saved.
-- Writes %TEMP%/rp_restart.log: "quitting" or "not restarted: why".
local log = io.open((os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp") .. "/rp_restart.log", "w")
local function done(s) log:write(s, "\n"); log:close() end
local res = reaper.GetResourcePath()
local installer = res .. "/Scripts/ReaPersona/install_shortcuts.py"
if not reaper.file_exists(installer) then return done("not restarted: no " .. installer) end
local open, answer_no = {}, false
for i = 0, 255 do
  local p, fn = reaper.EnumProjects(i)
  if not p then break end
  local name = fn ~= "" and fn or "an unsaved project"
  local empty = fn == "" and reaper.CountTracks(p) == 0 and reaper.CountProjectMarkers(p) == 0 -- (a new project nothing was put in: nothing to lose)
  -- (James, 11-19: nothing important open in any REAPER; unsaved changes are discarded, never saved)
  if reaper.IsProjectDirty(p) ~= 0 then answer_no = true end -- (REAPER still asks to save it: restart_and_test.ps1 may answer No)
  if fn ~= "" then open[#open + 1] = ' --open "' .. fn .. '"' end
end
-- (a test to run once REAPER is back: given to the new REAPER at its start, so nothing has to reach it while it's still opening)
local tf = io.open((os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp") .. "/rp_restart_test.txt", "rb")
if tf then local test = tf:read("a"):match("^%s*(.-)%s*$"); tf:close(); if test ~= "" and reaper.file_exists(test) then open[#open + 1] = ' --open "' .. test .. '"' end end
local win = reaper.GetOS():find("^Win") ~= nil
local py
if win then
  for _, c in ipairs({ "pythonw", "pyw" }) do -- (the windowless Python: no console over REAPER)
    local out = reaper.ExecProcess("cmd.exe /c where " .. c, 8000) or ""
    if out:match("^0") then py = c == "pyw" and "pyw -3" or c; break end
  end
end
py = py or (win and "python" or "python3")
local exe = reaper.GetExePath() .. (win and "\\reaper.exe" or "")
local cfg = reaper.get_ini_file()
reaper.ExecProcess(py .. ' "' .. installer .. '" --after-reaper-quits --apply-setup --relaunch "' .. exe .. '" --cfgfile "' .. cfg .. '"' .. table.concat(open), -1)
done(answer_no and "quitting; unsaved changes discarded: answer No" or "quitting")
reaper.defer(function() reaper.Main_OnCommand(40004, 0) end) -- File: Quit REAPER (the installer waits for it to close)
