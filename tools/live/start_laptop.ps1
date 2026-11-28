# tools/live/start_laptop.ps1 (run on the desktop): start the laptop's REAPER when it isn't running, then its dev eval hook. Exactly one
# reaper.exe: it refuses when one runs already (use -Restart to close it first: unsaved projects are never saved; REAPER's own "Save?" box
# is answered No only by ss_restart's restart_and_test.ps1, which only does that for empty projects, and cancelled otherwise).
# Never clicks: REAPER starts minimised and without focus in James's session (Invoke-InSession), the evaluation About box is closed the way
# Escape closes it (ss_restart\close_about_focus.ps1), and the hook is handed to the running REAPER with -nonewinst once it's up.
param([switch]$Restart)
$inv = "$env:USERPROFILE\.claude\skills\cross-pc-admin-computer-use\scripts\Invoke-InSession.ps1"
$restartPart = if ($Restart) { '$restart = $true' } else { '$restart = $false' }
$c = $restartPart + "`n" + @'
$t = "C:\ProgramData\ss_restart"; $exe = "D:\Portable Workstation\DAW\REAPER\reaper.exe"
$hook = '"D:\Portable Workstation\DAW\REAPER\Scripts\MIDI Control Center\MIDI Control Center - Dev eval.lua"'
$old = @(Get-Process reaper -ErrorAction SilentlyContinue)
if ($old.Count -gt 1) { "REFUSED: $($old.Count) REAPERs running on the laptop: close the stray one first"; return }
if ($old.Count -eq 1 -and -not $restart) { "REAPER already running (pid $($old[0].Id)): left alone"; return }
if ($old.Count -eq 1) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$t\restart_and_test.ps1" -Reaper $exe -Wait 5
  "restart exit $LASTEXITCODE"
} else {
  Start-Process -FilePath $exe -ArgumentList '-nosplash','-noactivate' -WorkingDirectory (Split-Path $exe) -WindowStyle Minimized
  "started"
}
& powershell -NoProfile -ExecutionPolicy Bypass -File "$t\close_about_focus.ps1"
$new = $null
for ($i = 0; $i -lt 120; $i++) {
  $ps = @(Get-Process reaper -ErrorAction SilentlyContinue)
  # (60 s, not 20: on 11-27 a -nonewinst 27 s after the start still made a second REAPER; at 2 minutes it reached the running one)
  if ($ps.Count -eq 1 -and ((Get-Date) - $ps[0].StartTime).TotalSeconds -ge 60) { $new = $ps[0]; break }
  Start-Sleep 1
}
if (-not $new) { "REAPER didn't come up as one process in 2 minutes: not starting the hook"; return }
for ($try = 1; $try -le 3; $try++) {
  Start-Process $exe -ArgumentList '-nonewinst', $hook
  Start-Sleep 8
  $stray = @(Get-Process reaper -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $new.Id })
  if ($stray.Count -eq 0) { "hook started (pid $($new.Id))"; return }
  # (a second REAPER the launch made just now, with nothing in it but the hook: stopped, then try again later)
  $stray | Stop-Process -Force; "a second REAPER appeared (try $try): stopped it"
  Start-Sleep 30
}
"WARNING: the hook didn't reach the running REAPER in 3 tries"
'@
& $inv -Target laptop -Command $c -TimeoutSeconds 240
