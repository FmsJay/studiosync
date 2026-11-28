# usage: click_btn.ps1 -Title "<dialog title>" -Button "<button text>": clicks that button (BM_CLICK) in REAPER's visible #32770 dialog with that exact title.
param([string]$Title, [string]$Button)
Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class CB {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EP f, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EP f, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  public static int Click(int[] pids, string title, string button) {
    int n = 0;
    EnumWindows((h, l) => {
      int p; GetWindowThreadProcessId(h, out p);
      if (Array.IndexOf(pids, p) < 0 || !IsWindowVisible(h)) return true;
      var t = new StringBuilder(256); var c = new StringBuilder(64);
      GetWindowText(h, t, 256); GetClassName(h, c, 64);
      if (c.ToString() != "#32770" || t.ToString() != title) return true;
      EnumChildWindows(h, (k, l2) => {
        var b = new StringBuilder(256); GetWindowText(k, b, 256);
        if (b.ToString().Replace("&", "") == button) { PostMessage(k, 0x00F5, IntPtr.Zero, IntPtr.Zero); n++; }
        return true; }, IntPtr.Zero);
      return true; }, IntPtr.Zero);
    return n; }
}
"@
$pids = [int[]]@(Get-Process reaper -ErrorAction SilentlyContinue | ForEach-Object Id)
"clicked $([CB]::Click($pids, $Title, $Button)) x '$Button' in '$Title'"
