# REAPER's evaluation About box: its countdown only runs while it has focus. Bring it forward, then close it the way Escape does
# (IDCANCEL), never pressing Buy or a licence button. Runs in the logged-in session (Invoke-InSession on the laptop).
Add-Type -Name P -Namespace CAF -MemberDefinition @'
public delegate bool EP(System.IntPtr h, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EP f, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@
$seen = $false
for ($i = 0; $i -lt 90; $i++) {
  $pids = @(Get-Process reaper -ErrorAction SilentlyContinue | ForEach-Object Id)
  $script:nag = $null
  [CAF.P]::EnumWindows({ param($h, $l) $q = 0; [void][CAF.P]::GetWindowThreadProcessId($h, [ref]$q)
    if ($pids -contains $q -and [CAF.P]::IsWindowVisible($h)) { $sb = New-Object Text.StringBuilder 256; [void][CAF.P]::GetWindowText($h, $sb, 256)
      if ($sb.ToString().StartsWith("About REAPER")) { $script:nag = $h } }
    $true }, [IntPtr]::Zero) | Out-Null
  if (-not $script:nag) { if ($seen -or $i -ge 40) { "About box closed (or none)"; exit 0 } } else {
    $seen = $true
    [CAF.P]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [CAF.P]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero) # (Alt tap: lets SetForegroundWindow through)
    [void][CAF.P]::SetForegroundWindow($script:nag)
    [void][CAF.P]::PostMessage($script:nag, 0x0111, [IntPtr]2, [IntPtr]::Zero)
  }
  Start-Sleep -Milliseconds 500
}
"About box still open"; exit 1
