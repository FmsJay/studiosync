# ReaPersona dev tool (Windows): restart REAPER through ReaPersona's installer, wait until it's back, then optionally run a test script.
#   restart_and_test.ps1 -Reaper "D:\Portable Workstation\DAW\REAPER\reaper.exe" [-Test C:\path\test.lua] [-Wait 8]
# The test .lua is handed to the new REAPER on its command line (it runs once REAPER has started).
# Run it in the logged-in desktop session (REAPER is a GUI app), e.g. through Invoke-InSession.ps1 from another computer.
# restart_reaper.lua refuses to quit when a project has unsaved changes. Log: %TEMP%\rp_restart.log
param([Parameter(Mandatory = $true)][string]$Reaper, [string]$Test = "", [int]$Wait = 8)
$log = Join-Path $env:TEMP "rp_restart.log"
function Note($s) { Add-Content $log ((Get-Date -Format "HH:mm:ss ") + $s) }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$before = @(Get-Process reaper -ErrorAction SilentlyContinue | ForEach-Object Id)
if ($before.Count -eq 0) { Set-Content $log "not restarted: REAPER isn't running"; exit 1 }
Remove-Item $log -ErrorAction SilentlyContinue
$tfile = Join-Path $env:TEMP "rp_restart_test.txt"  # (restart_reaper.lua gives this test to the new REAPER at its start)
if ($Test) { Set-Content $tfile $Test } else { Remove-Item $tfile -ErrorAction SilentlyContinue }
& $Reaper -nonewinst (Join-Path $here "restart_reaper.lua")
for ($i = 0; $i -lt 40 -and -not (Test-Path $log); $i++) { Start-Sleep -Milliseconds 250 }
if (-not (Select-String -Path $log -Pattern "^quitting" -Quiet -ErrorAction SilentlyContinue)) { exit 1 }  # (the reason is in the log)
Add-Type -Name P -Namespace RPW -MemberDefinition @'
public delegate bool EP(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EP f, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
'@
# (only empty new projects unsaved, as restart_reaper.lua checked: REAPER's "Save changes?" prompt for them is answered No, nothing else)
$no = Select-String -Path $log -Pattern "answer No" -Quiet
for ($i = 0; $i -lt 40; $i++) {  # (20 seconds for REAPER to close)
  if (-not (Get-Process -Id $before -ErrorAction SilentlyContinue)) { break }
  if ($no) {
    [RPW.P]::EnumWindows({ param($h, $l) $q = 0; [void][RPW.P]::GetWindowThreadProcessId($h, [ref]$q)
      if ($before -contains $q -and [RPW.P]::IsWindowVisible($h)) { $sb = New-Object Text.StringBuilder 256; [void][RPW.P]::GetWindowText($h, $sb, 256)
        if ($sb.ToString() -eq "REAPER Query") { [void][RPW.P]::PostMessage($h, 0x0111, [IntPtr]7, [IntPtr]::Zero); Note "answered No: save the empty new project" } }
      $true }, [IntPtr]::Zero) | Out-Null
  }
  Start-Sleep -Milliseconds 500
}
if (Get-Process -Id $before -ErrorAction SilentlyContinue) {
  # (still open: it's asking something else. Cancel it and stop the installer: nothing is discarded, REAPER stays open)
  New-Item -ItemType File -Force (Join-Path (Split-Path -Parent $Reaper) "Scripts\ReaPersona\install_cancelled") | Out-Null
  $main = (Get-Process -Id $before[0]).MainWindowHandle
  [RPW.P]::EnumWindows({ param($h, $l) $q = 0; [void][RPW.P]::GetWindowThreadProcessId($h, [ref]$q)
    if ($before -contains $q -and $h -ne $main -and [RPW.P]::IsWindowVisible($h)) {
      $sb = New-Object Text.StringBuilder 256; [void][RPW.P]::GetWindowText($h, $sb, 256)
      if ($sb.ToString() -match "save|REAPER" -and $sb.ToString() -notmatch "console") { [void][RPW.P]::PostMessage($h, 0x0111, [IntPtr]2, [IntPtr]::Zero); Note ("cancelled: " + $sb.ToString()) } }
    $true }, [IntPtr]::Zero) | Out-Null
  Note "REAPER didn't close (it asked something, cancelled above): not restarted"; exit 1
}
Note "closed"
for ($i = 0; $i -lt 240; $i++) {  # (2 minutes for the installer to start it again)
  $p = Get-Process reaper -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($p) { break }
  Start-Sleep -Milliseconds 500
}
if (-not $p) { Note "REAPER didn't start again"; exit 1 }
Note "back (pid $($p.Id))"
# (an evaluation copy opens with its About box, and while that's open -nonewinst can't reach this REAPER: it starts a second one. The
# box is closed (its button waits a few seconds), then the startup scripts get their time)
$pid0 = $p.Id
for ($i = 0; $i -lt 60; $i++) {
  $nag = $null
  [RPW.P]::EnumWindows({ param($h, $l) $q = 0; [void][RPW.P]::GetWindowThreadProcessId($h, [ref]$q)
    if ($q -eq $pid0 -and [RPW.P]::IsWindowVisible($h)) { $sb = New-Object Text.StringBuilder 256; [void][RPW.P]::GetWindowText($h, $sb, 256)
      if ($sb.ToString().StartsWith("About REAPER")) { $script:nag = $h } }
    $true }, [IntPtr]::Zero) | Out-Null
  if (-not $nag) { if ($seen -or $i -ge 30) { break } } else { $seen = $true; [void][RPW.P]::PostMessage($nag, 0x0111, [IntPtr]2, [IntPtr]::Zero); [void][RPW.P]::PostMessage($nag, 0x0111, [IntPtr]1, [IntPtr]::Zero) }
  Start-Sleep -Milliseconds 500
}
if ($nag) { Note "its About box didn't close: no test run"; exit 1 }
Start-Sleep -Seconds $Wait  # (its startup scripts and ReaPersona's own start first)
$note = Join-Path (Split-Path -Parent $Reaper) "Scripts\ReaPersona\last_install.txt"
if (Test-Path $note) { Note ("installer: " + ((Get-Content $note) -join " / ")) }
if ($Test) { Note "the test was given to REAPER at its start: $Test" }
Remove-Item $tfile -ErrorAction SilentlyContinue
exit 0
