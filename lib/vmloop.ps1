# StudioSync (lib/callapps.lua): which of Voicemeeter's virtual inputs feed which B bus, to spot REAPER hearing itself (an echo in Real time
# mode). Read only: it logs in to Voicemeeter's remote API, reads, and logs out; it changes nothing. Prints "type=N", then "sI=B1,B2,B3" for
# each virtual input strip I (0-based), or "none" (no Voicemeeter) / "off" (Voicemeeter isn't running).
$ErrorActionPreference = 'Stop'
$dll = Join-Path ${env:ProgramFiles(x86)} 'VB\Voicemeeter\VoicemeeterRemote64.dll'
if (-not (Test-Path -LiteralPath $dll)) { 'none'; exit }
$src = @'
using System; using System.Runtime.InteropServices;
public static class StudioSyncVm {
  [DllImport(@"DLLPATH", CharSet = CharSet.Ansi)] public static extern int VBVMR_Login();
  [DllImport(@"DLLPATH", CharSet = CharSet.Ansi)] public static extern int VBVMR_Logout();
  [DllImport(@"DLLPATH", CharSet = CharSet.Ansi)] public static extern int VBVMR_IsParametersDirty();
  [DllImport(@"DLLPATH", CharSet = CharSet.Ansi)] public static extern int VBVMR_GetVoicemeeterType(ref int t);
  [DllImport(@"DLLPATH", CharSet = CharSet.Ansi)] public static extern int VBVMR_GetParameterFloat(string name, ref float v);
}
'@
Add-Type -TypeDefinition ($src.Replace('DLLPATH', $dll))
if ([StudioSyncVm]::VBVMR_Login() -ne 0) { [void][StudioSyncVm]::VBVMR_Logout(); 'off'; exit }
try {
  Start-Sleep -Milliseconds 300
  [void][StudioSyncVm]::VBVMR_IsParametersDirty()
  $t = 0
  [void][StudioSyncVm]::VBVMR_GetVoicemeeterType([ref]$t)
  "type=$t"
  $strips = @{ 1 = @(2); 2 = @(3, 4); 3 = @(5, 6, 7) }[$t]
  foreach ($i in $strips) {
    $flags = foreach ($b in 'B1', 'B2', 'B3') {
      $v = [single]0
      if ([StudioSyncVm]::VBVMR_GetParameterFloat("Strip[$i].$b", [ref]$v) -eq 0 -and $v -ge 0.5) { 1 } else { 0 }
    }
    "s$i=" + ($flags -join ',')
  }
} finally { [void][StudioSyncVm]::VBVMR_Logout() }
