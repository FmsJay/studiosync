-- The cloud copy's file work off REAPER's thread (rt-drivebg, 2026-11-20). A pass listed the cloud drive's folders, read its files and copied to
-- and from it on REAPER's own thread: 223-273 ms on the desktop and 963 ms on the laptop each time (Google Drive for desktop is a slow virtual
-- folder; the listing is the slow part), every 2 s while a copy caught up.
-- Now a background worker (a small PowerShell script on Windows, /bin/sh elsewhere, started hidden as services.run_hidden starts everything)
-- does every read, listing and write in the cloud folder. Live sync's pass only plans: drive.mirror, drive.upkeep, drive.tools_pass and
-- cloudmodes.tick run as before, but through `bg.C`, which answers cloud reads from the worker's last listings and copies, and queues every
-- write as a step of the next job. A plan that needs a folder or file the worker hasn't read yet stops (bg.NEED) and asks for it in that job.
-- Jobs are files in <temp>/bandsync-drive-<hash of the cloud folder>/, as bgrender's are:
--   plan-<instance>-<n>.txt     "studiosync-drive 1", then one step a line: op TAB a TAB b TAB c
--                                 L dir out        list `dir` into `out`: "ok" or "none", then  kind TAB size TAB mtime TAB name  a line
--                                 C from to flags  copy to a temporary name beside `to`, the size checked before and after, then into place
--                                                  (flags "j": only if it reads as a whole JSON document, { ... } or [ ... ])
--                                 M from to        rename; or, when `to` has it at the same size already, drop `from`
--                                 R path guard     remove `path` (a cloud file goes to the service's trash), only while `guard` exists
--   result-<instance>-<n>.txt   step TAB "ok" [TAB size TAB mtime] or step TAB "no" TAB why, a line each, then "end" (written whole)
--   owner, beat                 the worker allowed to write (a token), and its heartbeat: token, time, plan, step
-- One worker writes at a time: it stops before its next step once `owner` names another, and REAPER waits for its heartbeat before starting
-- one. One stuck on a step (a dead mount) longer than it should take, or gone, is left to stop: what it did is read again from fresh listings.
-- Three failures in a row and passes run on REAPER's thread again for 10 minutes (the old way, slow but sure); ExtState "drive bg" = "off"
-- does that for good.
local band = require("band")
local bg = {}

bg.MAX_AGE = 30 -- s a cloud folder's listing is planned from (drive.listed's 30 s, as before)
bg.MAX_OPS, bg.MAX_BYTES = 200, 64 * 1024 * 1024 -- a job's writes at most: its results come back, and a new edit's copy gets a turn
bg.GAP = 1 -- s between one job and the next at least (Drive limits how often one account changes files)
bg.START_WAIT = 20 -- s for a worker just started to show a heartbeat (PowerShell can take seconds, cold)
bg.BEAT_STALE = 5 -- s an idle worker may go without one
bg.OP_WAIT = 30 -- s the worker may go without a heartbeat on a step (a copy beats each second it makes progress) before it counts as stuck or gone
bg.GIVE_UP, bg.REST = 3, 600 -- failures in a row before passes run on REAPER's thread again, and for how long
bg.NEED = setmetatable({}, { __tostring = function() return "cloud copy: waiting for the worker's listing" end })
function bg.is_need(e) return e == bg.NEED end

local function now() return reaper.time_precise() end
local function win() return band.WIN or tostring(reaper.GetOS and reaper.GetOS() or ""):find("^Win") ~= nil end
local TMP
local function tmp()
  if not TMP then
    local t = win() and (os.getenv("TEMP") or os.getenv("TMP")) or os.getenv("TMPDIR") or os.getenv("XDG_RUNTIME_DIR") or "/tmp"
    TMP = (t:gsub("\\", "/"):gsub("/+$", ""))
  end
  return TMP
end
bg.tmp = function(v) if v then TMP = v end; return tmp() end -- (tests: their own folder)
-- A name for a path: two 32-bit hashes (FNV-1a and djb2). Pure.
function bg.hash(s)
  local h1, h2 = 2166136261, 5381
  for i = 1, #s do
    local c = s:byte(i)
    h1 = ((h1 ~ c) * 16777619) % 4294967296
    h2 = (h2 * 33 + c) % 4294967296
  end
  return string.format("%08x%08x", h1, h2)
end
local function parent(p) return p:match("^(.*)/([^/]+)$") end
local function conflict(f) return f:find(".sync-conflict-", 1, true) ~= nil or f:match(" %(%d+%)%.[^.]+$") ~= nil end
local function ours(names, ext) -- (as band.files filters)
  local out = {}
  for _, f in ipairs(names) do if (not ext or f:lower():sub(-#ext) == ext) and not conflict(f) then out[#out + 1] = f end end
  return out
end

-- ---- what the worker has read: listings and copies ----
local L = {} -- cloud folder -> { at, file } (parsed on first use: names, size, mtime, dirs)
local F = {} -- cloud file -> { size, mtime, file } (its copy here), or { size, mtime, failed = true }
local dirty = {} -- cloud folders a planned step writes in: listed again before anything is planned from them
bg.root, bg.dir = nil, nil
local function cloud(p) return bg.root ~= nil and (p == bg.root or p:sub(1, #bg.root + 1) == bg.root .. "/") end
-- One listing as the worker wrote it. Pure. -> { names (sorted), size, mtime, dirs, exists }
function bg.parse_listing(text)
  local l = { names = {}, size = {}, mtime = {}, dirs = {}, exists = false }
  local first = true
  for line in (text or ""):gmatch("[^\r\n]+") do
    if first then l.exists, first = line == "ok", false
    else
      local kind, sz, mt, path = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.+)$")
      local name = path and path:match("([^/\\]+)[/\\]?$") -- (the sh worker prints whole paths)
      if name and name ~= "." and name ~= ".." then
        if kind == "d" or kind:lower():find("directory", 1, true) then l.dirs[#l.dirs + 1] = name
        else l.names[#l.names + 1] = name; l.size[name], l.mtime[name] = tonumber(sz), mt end
      end
    end
  end
  table.sort(l.names); table.sort(l.dirs)
  return l
end
local function listing(dir)
  local l = L[dir]
  if not l or dirty[dir] or now() - l.at >= bg.MAX_AGE then return nil end
  if not l.names then
    local text = l.text or band.read(l.file)
    if not text then L[dir] = nil; return nil end
    local p = bg.parse_listing(text)
    p.at = l.at
    L[dir], l = p, p
  end
  return l
end

-- ---- the plan being made ----
local plan -- { ops, list = {dir}, fetch = {path -> dest or true}, bytes, dirty = {dir} }
local missing = false -- the unit being planned read something the worker hasn't yet
local said = {}
local function want_list(dir) if plan then plan.list[dir] = true end; missing = true end
local function get(dir) local l = listing(dir); if not l then want_list(dir) end; return l end
local function cached(p, dest) -- the copy here of cloud file `p` while it matches the listing, or nil (asked for)
  local d, n = parent(p)
  local l = d and get(d)
  if not l or not l.size[n] then return nil end
  local f = F[p]
  if f and f.size == l.size[n] and f.mtime == l.mtime[n] then
    if f.failed then return nil end -- (one that couldn't be read: as band.read's nil, not asked again until it changes)
    if not dest or f.file == dest then
      if reaper.file_exists(f.file) then return f.file end
    end
  end
  if plan then plan.fetch[p] = dest or true end
  missing = true
  return nil
end
local function push(op, a, b, c, tag, bytes)
  if missing then error(bg.NEED, 0) end -- (nothing is written on a half-read picture)
  for _, s in ipairs({ a, b or "", c or "" }) do
    if s:find("[\t\r\n]") then
      if not said[s] then said[s] = true; band.log("the cloud copy left out a file with a tab or line break in its name: " .. s:gsub("[\t\r\n]", " ")) end
      return false
    end
  end
  plan.ops[#plan.ops + 1] = { op, a, b or "", c or "", tag = tag, bytes = bytes or 0 }
  plan.bytes = plan.bytes + (bytes or 0)
  for _, p in ipairs({ a, b }) do if p and cloud(p) then local d = parent(p); if d then plan.dirty[d] = true end end end
  return true
end

-- The file functions drive.mirror and cloudmodes go through. `direct`: the old way, on this thread (tests, and the fallback). `planned`: cloud
-- reads from the worker's listings and copies, every write a step of the next job (local writes too, so each runs in its order).
local direct = { planned = false }
function direct.cloud() return false end
function direct.files(d, e) return band.files(d, e) end
function direct.raw(d)
  local out, i = {}, 0
  reaper.EnumerateFiles(d, -1)
  while true do local f = reaper.EnumerateFiles(d, i); if not f then break end; out[#out + 1] = f; i = i + 1 end
  return out
end
function direct.subdirs(d) return band.subdirs(d) end
function direct.size(p) return band.size(p) end
function direct.exists(p) return reaper.file_exists(p) end
function direct.read(p) return band.read(p) end
function direct.read_json(p) return band.read_json(p) end
function direct.rename(a, z) return os.rename(a, z) end
function direct.remove(p) return os.remove(p) end
function direct.mkdir(d) return reaper.RecursiveCreateDirectory(d, 0) end
function direct.check() end
function direct.full() return false end
local P = { planned = true }
P.cloud = cloud
function P.files(d, e)
  if not cloud(d) then return band.files(d, e) end
  local l = get(d)
  return l and ours(l.names, e) or {}
end
function P.raw(d)
  if not cloud(d) then return direct.raw(d) end
  local l = get(d)
  local out = {}
  for _, f in ipairs(l and l.names or {}) do out[#out + 1] = f end
  return out
end
function P.subdirs(d)
  if not cloud(d) then return band.subdirs(d) end
  local l = get(d)
  local out = {}
  for _, f in ipairs(l and l.dirs or {}) do out[#out + 1] = f end
  return out
end
function P.size(p)
  if not cloud(p) then return band.size(p) end
  local d, n = parent(p)
  local l = d and get(d)
  return l and l.size[n]
end
function P.exists(p)
  if not cloud(p) then return reaper.file_exists(p) end
  local d, n = parent(p)
  local l = d and get(d)
  return l ~= nil and l.size[n] ~= nil
end
function P.read(p)
  if not cloud(p) then return band.read(p) end
  local f = cached(p)
  return f and band.read(f)
end
function P.read_json(p)
  if not cloud(p) then return band.read_json(p) end
  local f = cached(p)
  return f and band.read_json(f)
end
local notwhole = {} -- cloud JSON file -> { size, mtime } it had when the worker found it not whole yet (a bandmate's change still arriving)
function P.copy(a, z, json, tag)
  -- (not again until it changes, as the old pass left one that didn't read for later: planned every pass, it made each look "copying". rt-drive2)
  local w = json and notwhole[a]
  if w then
    local d, n = parent(a)
    local l = d and get(d)
    if l and l.size[n] == w.size and l.mtime[n] == w.mtime then return false end
  end
  return push("C", a, z, json and "j" or "", tag, P.size(a) or 0)
end
function P.rename(a, z) return push("M", a, z, "", "count") end
function P.remove(p, guard, tag) return push("R", p, guard or "", "", tag == nil and "count" or tag) end
function P.mkdir() return true end
function P.check() if missing then error(bg.NEED, 0) end end
function P.full() return plan ~= nil and (#plan.ops >= bg.MAX_OPS or plan.bytes >= bg.MAX_BYTES) end
-- A local folder holding the cloud folder's files `rels` (signed update files: checked here, never in the cloud folder), or nil while they're
-- being copied (bg.NEED once checked). `tag`: the folder's own name, so a new version starts in an empty one.
function P.stage(dir, rels, tag)
  local out = bg.dir .. "/stage/" .. bg.hash(dir .. "\0" .. (tag or ""))
  for _, rel in ipairs(rels) do cached(dir .. "/" .. rel, out .. "/" .. rel) end
  P.check()
  return out
end
bg.direct, bg.planned = direct, P
bg.C = direct

-- Non-raising asks, for a planner that knows what it will read (one job instead of one per folder).
function bg.peek(dir) return listing(dir) end
function bg.want(dir) if not listing(dir) then want_list(dir) end end
function bg.want_file(p) cached(p) end
function bg.missing() return missing end
function bg.pending() return plan and #plan.ops or 0 end -- (steps in the plan being made: drive.bg_step tells a unit that has work by it)
-- What the worker last said of cloud file `p` (its size), or nil: never asks.
function bg.known_size(p) local d, n = parent(p); local l = d and listing(d); return l and l.size[n] end

-- ---- the worker ----
bg.PS1 = [=[
param([string]$Dir, [string]$Token)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
$slow = 0
if (Test-Path -LiteralPath "$Dir/slow") { $slow = [double]((Get-Content -LiteralPath "$Dir/slow" -Raw).Trim()) }
function Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Owned { try { ([IO.File]::ReadAllText("$Dir/owner")).Trim() -eq $Token } catch { $false } }
function Beat($p, $i) { try { [IO.File]::WriteAllText("$Dir/beat.tmp", "$Token $(Now) $p $i", $utf8); Put "$Dir/beat.tmp" "$Dir/beat" } catch {} }
function Put($t, $z) { if ([IO.File]::Exists($z)) { try { [IO.File]::Replace($t, $z, $null); return } catch { [IO.File]::Delete($z) } }; [IO.File]::Move($t, $z) }
function Whole($p) { $s = [IO.File]::ReadAllText($p).Trim(); return ($s.StartsWith('{') -and $s.EndsWith('}')) -or ($s.StartsWith('[') -and $s.EndsWith(']')) }
function List($d, $out) {
  $di = New-Object IO.DirectoryInfo $d
  $sb = New-Object System.Text.StringBuilder
  if ($di.Exists) {
    [void]$sb.Append("ok`n")
    foreach ($e in $di.EnumerateFileSystemInfos()) {
      if ($e -is [IO.DirectoryInfo]) { [void]$sb.Append("d`t0`t0`t$($e.Name)`n") } else { [void]$sb.Append("f`t$($e.Length)`t$($e.LastWriteTimeUtc.Ticks)`t$($e.Name)`n") }
    }
  } else { [void]$sb.Append("none`n") }
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($out)) | Out-Null
  [IO.File]::WriteAllText("$out.tmp", $sb.ToString(), $utf8); Put "$out.tmp" $out
  return "ok"
}
function Copy1($a, $z, $fl) {
  $fa = New-Object IO.FileInfo $a
  if (-not $fa.Exists) { return "no`tmissing" }
  $size = $fa.Length; $mt = $fa.LastWriteTimeUtc.Ticks
  $dir = [IO.Path]::GetDirectoryName($z); [IO.Directory]::CreateDirectory($dir) | Out-Null
  $t = [IO.Path]::Combine($dir, ".syncthing." + [IO.Path]::GetFileName($z) + "." + (Get-Random) + ".tmp")
  try {
    $in = [IO.File]::OpenRead($a)
    try {
      $out = [IO.File]::Create($t)
      try {
        $buf = New-Object byte[] 1048576; $last = Now
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
          $out.Write($buf, 0, $n)
          if ((Now) -ne $last) { if (-not (Owned)) { throw "another worker took over" }; Beat $name $i; $last = Now }
        }
      } finally { $out.Close() }
    } finally { $in.Close() }
    $fa.Refresh(); $ft = New-Object IO.FileInfo $t
    if ($fa.Length -ne $size -or $ft.Length -ne $size) { throw "it changed while it copied" }
    if ($fl.Contains('j') -and -not (Whole $t)) { throw "not whole yet" }
    Put $t $z
  } catch { if ([IO.File]::Exists($t)) { [IO.File]::Delete($t) }; throw }
  return "ok`t$size`t$mt"
}
function Move1($a, $z) {
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($z)) | Out-Null
  if (-not [IO.File]::Exists($z)) { [IO.File]::Move($a, $z); return "ok" }
  if ((New-Object IO.FileInfo $z).Length -eq (New-Object IO.FileInfo $a).Length) { [IO.File]::Delete($a); return "ok" }
  return "no`tsomething else is there"
}
function Remove1($p, $g) {
  if ($g -ne '' -and -not [IO.File]::Exists($g)) { return "no`tguard" }
  if (-not [IO.File]::Exists($p)) { return "no`tmissing" }
  [IO.File]::Delete($p); return "ok"
}
try {
  $old = (Get-Date).AddDays(-7)
  foreach ($sub in @('cache', 'stage', 'lists')) { Get-ChildItem -LiteralPath "$Dir/$sub" -Force -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -lt $old } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
  Get-ChildItem -LiteralPath $Dir -Filter 'result-*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}
$idle = Now; $beat = 0
while ($true) {
  if (-not (Owned)) { exit }
  $plan = Get-ChildItem -LiteralPath $Dir -Filter 'plan-*.txt' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'plan-*.txt' } | Sort-Object Name | Select-Object -First 1
  if ($plan) {
    $name = $plan.BaseName
    $lines = [IO.File]::ReadAllLines($plan.FullName, $utf8)
    $sb = New-Object System.Text.StringBuilder
    if ($lines.Length -lt 1 -or $lines[0] -ne 'studiosync-drive 1') { $lines = @() }
    for ($i = 1; $i -lt $lines.Length; $i++) {
      if (-not (Owned)) { exit }
      Beat $name $i
      if ($slow -gt 0) { Start-Sleep -Milliseconds ([int]($slow * 1000)) }
      $f = $lines[$i].Split("`t")
      try {
        switch ($f[0]) {
          'L' { $r = List $f[1] $f[2] }
          'C' { $r = Copy1 $f[1] $f[2] $f[3] }
          'M' { $r = Move1 $f[1] $f[2] }
          'R' { $r = Remove1 $f[1] $f[2] }
          default { $r = "no`tunknown step" }
        }
      } catch { $r = "no`t" + ($_.Exception.Message -replace "[`t`r`n]", ' ') }
      [void]$sb.Append("$i`t$r`n")
    }
    [void]$sb.Append("end`n")
    if (-not (Owned)) { exit }
    $res = Join-Path $Dir ($name -replace '^plan-', 'result-')
    [IO.File]::WriteAllText("$res.txt.tmp", $sb.ToString(), $utf8); Put "$res.txt.tmp" "$res.txt"
    try { [IO.File]::Delete($plan.FullName) } catch {}
    $idle = Now
    Beat '-' 0
  } else {
    if ((Now) - $idle -gt 60) { exit }
    if ((Now) -ne $beat) { Beat '-' 0; $beat = Now }
    Start-Sleep -Milliseconds 100
  }
}
]=]
bg.SH = [=[
D=$1; T=$2
TAB=$(printf '\t')
SLOW=; [ -f "$D/slow" ] && read -r SLOW < "$D/slow"
if stat -c %s / >/dev/null 2>&1; then GNU=1; else GNU=; fi
owned() { cur=; read -r cur < "$D/owner" 2>/dev/null; [ "$cur" = "$T" ]; }
beat() { printf '%s %s %s %s\n' "$T" "$(date +%s)" "$1" "$2" > "$D/beat.tmp" 2>/dev/null && mv -f "$D/beat.tmp" "$D/beat"; }
size_of() { wc -c < "$1" | tr -d ' '; }
mtime_of() { if [ -n "$GNU" ]; then stat -L -c %Y "$1"; else stat -L -f %m "$1"; fi; }
list1() {
  mkdir -p "${2%/*}"
  if [ -d "$1" ]; then
    { echo ok
      if [ -n "$GNU" ]; then find "$1/" -mindepth 1 -maxdepth 1 -exec stat -L -c "%F$TAB%s$TAB%Y$TAB%n" {} + 2>/dev/null
      else find "$1/" -mindepth 1 -maxdepth 1 -exec stat -L -f "%HT$TAB%z$TAB%m$TAB%N" {} + 2>/dev/null; fi
    } > "$2.tmp"
  else echo none > "$2.tmp"; fi
  mv -f "$2.tmp" "$2" && echo ok || echo "no${TAB}couldn't write the listing"
}
copy1() {
  [ -f "$1" ] || { echo "no${TAB}missing"; return; }
  s=$(size_of "$1"); m=$(mtime_of "$1")
  dir=${2%/*}; mkdir -p "$dir" || { echo "no${TAB}couldn't make its folder"; return; }
  t="$dir/.syncthing.${2##*/}.$$.tmp"
  if [ "$s" -gt 4194304 ]; then # (a big one: a heartbeat each second it copies, so a long upload isn't taken for a stuck worker)
    cp "$1" "$t" 2>/dev/null & cpid=$!; k=0
    while kill -0 "$cpid" 2>/dev/null; do
      sleep 0.1; k=$((k + 1))
      if [ $((k % 10)) -eq 0 ]; then owned || { kill "$cpid" 2>/dev/null; rm -f "$t"; exit 0; }; beat "$name" "$i"; fi
    done
    wait "$cpid" || { rm -f "$t"; echo "no${TAB}couldn't copy"; return; }
  else
    cp "$1" "$t" 2>/dev/null || { rm -f "$t"; echo "no${TAB}couldn't copy"; return; }
  fi
  if [ "$(size_of "$1")" != "$s" ] || [ "$(size_of "$t")" != "$s" ]; then rm -f "$t"; echo "no${TAB}it changed while it copied"; return; fi
  case $3 in *j*)
    w="$(tr -d ' \t\r\n' < "$t" | head -c 1)$(tr -d ' \t\r\n' < "$t" | tail -c 1)"
    case $w in '{}'|'[]') ;; *) rm -f "$t"; echo "no${TAB}not whole yet"; return;; esac;;
  esac
  mv -f "$t" "$2" || { rm -f "$t"; echo "no${TAB}couldn't put it in place"; return; }
  echo "ok${TAB}$s${TAB}$m"
}
move1() {
  mkdir -p "${2%/*}"
  if [ ! -e "$2" ]; then mv "$1" "$2" 2>/dev/null && echo ok || echo "no${TAB}couldn't move"; return; fi
  if [ "$(size_of "$2")" = "$(size_of "$1")" ]; then rm -f "$1" && echo ok || echo "no${TAB}couldn't remove"; return; fi
  echo "no${TAB}something else is there"
}
remove1() {
  if [ -n "$2" ] && [ ! -e "$2" ]; then echo "no${TAB}guard"; return; fi
  [ -e "$1" ] || { echo "no${TAB}missing"; return; }
  rm -f "$1" && echo ok || echo "no${TAB}couldn't remove"
}
for sub in cache stage lists; do [ -d "$D/$sub" ] && find "$D/$sub" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null; done
find "$D" -maxdepth 1 -name 'result-*.txt' -mtime +1 -exec rm -f {} + 2>/dev/null
idle=0; n=0
while :; do
  owned || exit 0
  p=
  for f in "$D"/plan-*.txt; do [ -f "$f" ] && { p=$f; break; }; done
  if [ -n "$p" ]; then
    name=${p##*/}; name=${name%.txt}; res="$D/result-${name#plan-}.txt"
    : > "$res.tmp"; i=0; ok=
    while IFS= read -r line <&3 || [ -n "$line" ]; do
      if [ -z "$ok" ]; then [ "$line" = "studiosync-drive 1" ] || break; ok=1; continue; fi
      i=$((i + 1))
      owned || exit 0
      beat "$name" "$i"
      [ -n "$SLOW" ] && sleep "$SLOW"
      op=${line%%"$TAB"*}; r=${line#*"$TAB"}; a=${r%%"$TAB"*}; r=${r#*"$TAB"}; b=${r%%"$TAB"*}; c=${r#*"$TAB"}
      case $op in
        L) out=$(list1 "$a" "$b");;
        C) out=$(copy1 "$a" "$b" "$c");;
        M) out=$(move1 "$a" "$b");;
        R) out=$(remove1 "$a" "$b");;
        *) out="no${TAB}unknown step";;
      esac
      printf '%s\t%s\n' "$i" "$out" >> "$res.tmp"
    done 3< "$p"
    echo end >> "$res.tmp"
    owned || exit 0
    mv -f "$res.tmp" "$res"; rm -f "$p"
    idle=0; beat - 0
  else
    idle=$((idle + 1)); [ "$idle" -gt 600 ] && exit 0
    n=$((n + 1)); [ $((n % 10)) -eq 1 ] && beat - 0
    sleep 0.1
  fi
done
]=]

local inst = nil
local seq, token, spawned_at = 0, nil, -math.huge
local job -- in flight: { dir, name, plan, res, ops, started, spawns, checked }
local fails, rest_until, last_submit = 0, -math.huge, -math.huge
local after = {} -- functions to run once the job they were planned with has finished (drive.date_like after the copies)
local function sh_q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
-- How the worker is started: hidden, never waited for (services.run_hidden). Tests put their own here.
function bg.spawn(cmd, tok) return require("services").run_hidden("drive-worker-" .. tok, cmd, 0) end
local function start_worker(dir)
  token = bg.hash(tostring(inst) .. tostring(now()) .. tostring(math.random()))
  local script = dir .. (win() and "/worker.ps1" or "/worker.sh")
  local body = win() and bg.PS1 or bg.SH
  if band.read(script) ~= body then band.write_atomic(script, body) end
  band.write_atomic(dir .. "/owner", token)
  local cmd = win() and ('powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' .. script .. '" "' .. dir .. '" ' .. token)
    or ("/bin/sh " .. sh_q(script) .. " " .. sh_q(dir) .. " " .. token)
  spawned_at = now()
  bg.spawn(cmd, token)
end
local function read_beat(dir)
  local s = band.read(dir .. "/beat")
  local t, at, name, i = (s or ""):match("^(%S+) (%d+) (%S+) (%d+)")
  return t, tonumber(at), name, tonumber(i)
end
local function owner(dir) return (band.read(dir .. "/owner") or ""):match("%S+") end
local function worker_alive(dir)
  local own = owner(dir)
  local t, at = read_beat(dir)
  if own and t == own and at and os.time() - at <= bg.BEAT_STALE then return true end
  return own ~= nil and own == token and now() - spawned_at < bg.START_WAIT
end

-- Whether passes go through the worker now (not after three failures in a row, for 10 minutes; not with ExtState "drive bg" = "off").
function bg.on() return now() >= rest_until and reaper.GetExtState(band.SECTION, "drive bg") ~= "off" end
function bg.busy() return job ~= nil end
function bg.ready() return job == nil and now() - last_submit >= bg.GAP end
function bg.after(fn) if plan then plan.after = plan.after or {}; plan.after[#plan.after + 1] = fn end end

-- Start planning in cloud folder `root`: cloud reads and every write go through bg.C (bg.planned) until bg.submit.
function bg.begin(root)
  bg.root = root
  bg.dir = tmp() .. "/bandsync-drive-" .. bg.hash(root)
  plan = plan or { ops = {}, list = {}, fetch = {}, bytes = 0, dirty = {} }
  bg.C = P
end
-- One planner (drive.mirror for a room, say), called as fn(...): -> pcall's results, or false and bg.NEED when it read something not read
-- yet (asked for in the job). The folders it wrote in count as changed only once it's done: its own reads plan from one picture.
function bg.unit(fn, ...)
  missing, plan.dirty = false, {}
  local res = table.pack(pcall(fn, ...))
  if res[1] and missing then res = table.pack(false, bg.NEED) end
  for d in pairs(plan.dirty) do dirty[d] = true end
  missing = false
  return table.unpack(res, 1, res.n)
end
function bg.full() return P.full() end
-- The plan as the worker reads it: -> its text and the steps as REAPER keeps them. Pure but for paths.
local function plan_text(p, dir)
  local lines, ops = { "studiosync-drive 1" }, {}
  local function add(op, a, b, c, tag, bytes)
    lines[#lines + 1] = op .. "\t" .. a .. "\t" .. b .. "\t" .. c
    ops[#ops + 1] = { op = op, a = a, b = b, tag = tag, bytes = bytes or 0 }
  end
  for _, o in ipairs(p.ops) do add(o[1], o[2], o[3], o[4], o.tag, o.bytes) end
  -- (then each cloud folder it writes in or a planner asked for, listed after the writes: the next plan sees what they did)
  local lists = {}
  for d in pairs(dirty) do lists[#lists + 1] = d end
  for d in pairs(p.list) do if not dirty[d] then lists[#lists + 1] = d end end
  table.sort(lists)
  for _, d in ipairs(lists) do if not d:find("[\t\r\n]") then add("L", d, dir .. "/lists/" .. bg.hash(d) .. ".txt", "", "list") end end
  local fetch = {}
  for f, dest in pairs(p.fetch) do fetch[#fetch + 1] = { f, dest } end
  table.sort(fetch, function(a, z) return a[1] < z[1] end)
  for _, f in ipairs(fetch) do
    if not f[1]:find("[\t\r\n]") then add("C", f[1], f[2] == true and (dir .. "/cache/" .. bg.hash(f[1])) or f[2], "", "fetch", 0) end
  end
  return table.concat(lines, "\n") .. "\n", ops
end
bg.plan_text = plan_text
-- The plan made since bg.begin to the worker, if it has anything in it. -> true when a job went.
function bg.submit()
  bg.C = direct
  local p = plan
  plan = nil
  if not p then return false end
  if not inst then inst = string.format("%08x", math.random(0, 0x7fffffff)) end
  local text, ops = plan_text(p, bg.dir)
  if #ops == 0 then return false end
  reaper.RecursiveCreateDirectory(bg.dir, 0)
  seq = seq + 1
  local name = string.format("plan-%s-%08d", inst, seq)
  band.write_atomic(bg.dir .. "/" .. name .. ".txt", text)
  job = { dir = bg.dir, name = name, plan = bg.dir .. "/" .. name .. ".txt", res = bg.dir .. "/result-" .. name:sub(6) .. ".txt", ops = ops,
    after = p.after, at = now(), checked = now() }
  last_submit = now()
  if not worker_alive(bg.dir) then start_worker(bg.dir) end
  return true
end

-- A result file's lines -> { [step] = { ok, a, b } } and whether it's whole. Pure.
function bg.parse_result(text)
  local out, whole = {}, false
  for line in (text or ""):gmatch("[^\r\n]+") do
    if line == "end" then whole = true
    else
      local i, st, rest = line:match("^(%d+)\t(%a+)\t?(.*)$")
      if i then
        local a, b = rest:match("^([^\t]*)\t?([^\t]*)$")
        out[tonumber(i)] = { st == "ok", a, b }
      end
    end
  end
  return out, whole
end
local copy_said = {}
local function collect(j, text)
  local r = bg.parse_result(text)
  local moved, landed, failed, wrote, waits = 0, {}, {}, {}, {}
  for i, op in ipairs(j.ops) do
    local x = r[i]
    local ok = x and x[1]
    if op.tag == "list" then
      if ok then L[op.a] = { at = now(), file = op.b }; dirty[op.a] = nil
      else L[op.a] = { at = now(), text = "none\n" } end -- (a folder that couldn't be listed reads as empty, as EnumerateFiles' would)
    elseif op.tag == "fetch" then
      local d, n = parent(op.a)
      local l = d and L[d] and listing(d)
      if ok then F[op.a] = { size = tonumber(x[2]), mtime = x[3], file = op.b }
      elseif l and l.size[n] then F[op.a] = { size = l.size[n], mtime = l.mtime[n], failed = true } end
    elseif ok then
      if op.op == "C" or op.op == "M" then wrote[#wrote + 1] = op.b end
      if op.tag == "count" or op.tag == "landed" then moved = moved + 1 end
      if op.tag == "landed" then landed[#landed + 1] = op.b end
    else
      -- (drive.bg_step: the copy isn't up to date while one stays failed; not a bandmate's change still arriving, left for later as before)
      if op.op == "C" and x and x[2] == "not whole yet" then waits[#waits + 1] = op.a
      elseif op.op == "C" or op.op == "M" then failed[#failed + 1] = op.b end
      if op.op == "C" and x and not copy_said[op.a] then
        copy_said[op.a] = true
        band.log("couldn't copy " .. tostring(op.a:match("[^/]+$")) .. " for the cloud copy: " .. tostring(x[2]))
      end
    end
  end
  for _, a in ipairs(waits) do -- (as the job's own listing after its writes has it)
    local d, n = parent(a)
    local l = d and L[d] and listing(d)
    if l and l.size[n] then notwhole[a] = { size = l.size[n], mtime = l.mtime[n] } end
  end
  for _, fn in ipairs(j.after or {}) do pcall(fn) end
  return { moved = moved, landed = landed, failed = failed, wrote = wrote }
end
local function fail(j, why)
  os.remove(j.plan) -- (one the worker never took up never runs now)
  band.write_atomic(j.dir .. "/owner", "none") -- (and one stuck on a step stops before its next)
  token = nil
  L = {} -- (what it did is unknown: every cloud folder is listed again before anything more is planned)
  fails = fails + 1
  local msg = "the cloud copy's background worker " .. why
  if fails >= bg.GIVE_UP then
    rest_until = now() + bg.REST
    fails = bg.GIVE_UP - 1
    msg = msg .. ": passes run in REAPER again for " .. math.floor(bg.REST / 60) .. " minutes"
  end
  band.log(msg)
  job = nil
  return { moved = 0, landed = {}, err = msg }
end
-- The job in flight, looked at: -> its results once it's done ({ moved, landed, err }), else nil. A file check a tick, a heartbeat a second.
function bg.poll()
  local j = job
  if not j then return nil end
  local text = band.read(j.res)
  if text then
    local _, whole = bg.parse_result(text)
    if whole then
      os.remove(j.res)
      job, fails = nil, 0
      return collect(j, text)
    end
  end
  if now() - j.checked < 1 then return nil end
  j.checked = now()
  local own = owner(j.dir)
  local t, at, name, i = read_beat(j.dir)
  local live = t ~= nil and t == own
  if live and name == j.name then -- (on ours: stuck when a step takes far longer than it should)
    j.started = true
    local op = j.ops[i or 0]
    if os.time() - at > bg.OP_WAIT then
      return fail(j, "stopped answering on " .. tostring(op and (op.a:match("[^/]+$") or op.a) or "a step") .. " (the cloud drive stuck, or the worker gone)")
    end
    return nil
  end
  if live and at and os.time() - at <= bg.BEAT_STALE then return nil end -- (idle, or on another Live sync's job: ours is next)
  if j.started then return fail(j, "stopped part-way through a job") end
  if own == token and now() - spawned_at < bg.START_WAIT then return nil end -- (still starting)
  j.spawns = (j.spawns or 0) + 1
  if j.spawns > 2 then return fail(j, "didn't start") end
  start_worker(j.dir)
  return nil
end
-- (tests)
function bg.reset()
  L, F, dirty, plan, missing, job, fails, rest_until, last_submit, token, spawned_at = {}, {}, {}, nil, false, nil, 0, -math.huge, -math.huge, nil, -math.huge
  notwhole = {}
  bg.C = direct
end
function bg.job() return job end

return bg
