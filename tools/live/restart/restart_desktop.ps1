# tools/live/restart/restart_desktop.ps1 (from the 11-20 rounds' desk_restart.ps1): restart the desktop's REAPER through ReaPersona's own
# restart (restart_and_test.ps1 + restart_reaper.lua: James's 11-19 OK, unsaved test projects are discarded, never saved), answer REAPER's
# "Save?" box No while it quits, close the evaluation About box, then hand the dev hook to the one new REAPER. Run by `live.py restart`.
# Restart the desktop REAPER (to load a new extension) and start the dev eval hook. Answers REAPER's "Save project?" No while it quits
# (James: quitting unsaved test projects is fine), and refuses to start the hook if the old REAPER didn't quit. (2026-11-20: answer_no.ps1
# alone missed the box once and the old REAPER sat on it, the hook's launch then stacked a task-control box on top.)
$R = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = 'J:\Portable Workstation\DAW\REAPER\reaper.exe'
$old = @(Get-Process reaper -ErrorAction SilentlyContinue | ForEach-Object Id)
$no = Start-Job -ScriptBlock { param($r) for ($i = 0; $i -lt 90; $i++) { & "$r\click_btn.ps1" -Title 'REAPER Query' -Button 'No' | Out-Null; Start-Sleep 1 } } -ArgumentList $R
& "$R\restart_and_test.ps1" -Reaper $exe -Wait 8 | Select-Object -Last 2
# (the save box can come after restart_and_test returns: keep answering until the old REAPER is gone, up to 60 s)
for ($i = 0; $i -lt 60 -and @(Get-Process reaper -ErrorAction SilentlyContinue | Where-Object { $old -contains $_.Id }).Count; $i++) { Start-Sleep 1 }
Stop-Job $no -ErrorAction SilentlyContinue; Remove-Job $no -Force -ErrorAction SilentlyContinue
$still = @(Get-Process reaper -ErrorAction SilentlyContinue | Where-Object { $old -contains $_.Id })
if ($still.Count) { "old REAPER still running (pid $($still.Id -join ',')): not starting the hook"; return }
& "$R\close_about_focus.ps1" | Select-Object -Last 1
# (2026-11-20: launched while the new REAPER was still loading, -nonewinst started a SECOND REAPER, which took the hook and didn't sync.
# Wait until the one new REAPER shows its main window with a project, then launch, then check there is still exactly one.)
$new = $null
for ($i = 0; $i -lt 120; $i++) {
  $ps = @(Get-Process reaper -ErrorAction SilentlyContinue)
  if ($ps.Count -eq 1 -and $ps[0].MainWindowTitle -match 'REAPER v') { $new = $ps[0]; break }
  Start-Sleep 1
}
if (-not $new) { "the new REAPER's main window didn't appear (or there are several REAPERs): not starting the hook"; return }
Start-Sleep 5
Start-Process $exe -ArgumentList '-nonewinst', '"J:\Portable Workstation\DAW\REAPER\Scripts\MIDI Control Center\MIDI Control Center - Dev eval.lua"'
Start-Sleep 6
$n = @(Get-Process reaper -ErrorAction SilentlyContinue).Count
if ($n -ne 1) { "WARNING: $n REAPERs are running after the hook launch: close the stray one before testing"; return }
"desktop restarted; hook started in pid $($new.Id)"
