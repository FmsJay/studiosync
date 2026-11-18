-- drive.parse / place / trashed are pure (lupa or any Lua 5.4, from the repo root)
package.loaded.band = package.loaded.band or {}
package.path = "lib/?.lua;" .. package.path
local drive = require("drive")
local id, rev, man = drive.parse("James-20261028-032515Z-2-dry-r6.flac")
assert(id == "James-20261028-032515Z-2" and rev == 6 and not man, "dry twin of revision 6")
id, rev, man = drive.parse("Laptop-Mac-20261028-161310Z-12.json")
assert(id == "Laptop-Mac-20261028-161310Z-12" and rev == 1 and man, "a manifest; hyphens in the name are fine")
assert(drive.parse("index.json") == nil and drive.parse("notes.txt") == nil, "not take files")
local trashed = drive.trashed({
  { type = "delete", take = "A-20261028-010101Z-1", time = "2026-10-28T01:00:00Z", id = "x1" },
  { type = "undelete", take = "A-20261028-010101Z-1", time = "2026-10-28T02:00:00Z", id = "x2" },
  { type = "delete", take = "B-20261028-010101Z-1", time = "2026-10-28T02:00:00Z", id = "x3" },
  { type = "edit", take = "C-20261028-010101Z-1", time = "2026-10-28T03:00:00Z", id = "x4" },
})
assert(not trashed["a-20261028-010101z-1"] and trashed["b-20261028-010101z-1"] and not trashed["c-20261028-010101z-1"], "newest delete/undelete wins")
local cur = { ["c-20261028-010101z-1"] = 3 }
assert(drive.place("B-20261028-010101Z-1.flac", trashed, cur) == "_trash", "deleted take's audio")
assert(drive.place("B-20261028-010101Z-1.json", trashed, cur) == "_trash", "and its manifest")
assert(drive.place("C-20261028-010101Z-1-r2.opus", trashed, cur) == "_trash", "an older revision")
assert(drive.place("C-20261028-010101Z-1-r3.opus", trashed, cur) == "takes", "the current revision")
assert(drive.place("C-20261028-010101Z-1.json", trashed, cur) == "takes", "the manifest stays with a live take")
assert(drive.place("D-20261028-010101Z-1.flac", trashed, cur) == "takes", "a take with no manifest yet (still arriving)")
local tree = { ["G:/My Drive"] = { "Music", "Photos" }, ["H:/My Drive"] = { "Stuff", "bandsync" } }
local function subdirs(d) return tree[d] or {} end
local root, missing = drive.find({ "G:/My Drive", "H:/My Drive", "Z:/My Drive" }, subdirs)
assert(root == "H:/My Drive/bandsync" and not missing, "the account holding the shared folder, on any letter, its own spelling")
root, missing = drive.find({ "G:/My Drive", "Z:/My Drive" }, subdirs)
assert(root == nil and missing == "G:/My Drive", "My Drive without the shortcut: nothing made, and the panel is told where")
root, missing = drive.find({ "Z:/My Drive" }, subdirs)
assert(root == nil and missing == nil, "no Google Drive at all")
-- a Mac's shortcut is a symlink a folder listing may leave out: found by looking for it directly
local mac = "/Users/x/Library/CloudStorage/GoogleDrive-b@y.com/My Drive"
root = drive.find({ "G:/My Drive", mac }, subdirs, function(p) return p == mac .. "/BandSync" end)
assert(root == mac .. "/BandSync", "the shortcut, though no listing shows it")
-- whose a recording is: the first change that used it, in its own room
local owners = drive.media_owners({
  { user = "Laptop", time = "2026-11-01T02:00:00Z", id = "b", media = { { "main", "rec1.flac" }, { "main", "rec2.flac" } } },
  { user = "James", time = "2026-11-01T01:00:00Z", id = "a", media = { { "main", "rec1.flac" } } },
  { user = "Mac", time = "2026-11-01T00:00:00Z", id = "c", media = { { "side", "rec3.flac" } } },
  { user = "Mac", time = "2026-11-01T00:00:00Z", id = "d" },
}, "main")
assert(owners["rec1.flac"] == "James" and owners["rec2.flac"] == "Laptop", "the first user's, whoever moved it later")
assert(owners["rec3.flac"] == nil, "another room's recording isn't this room's to send")
print("ok")
-- which cloud drive a folder is in (0.58.79)
assert(drive.service_of("G:/My Drive/StudioSync - Chilio") == "google", "Google Drive letter")
assert(drive.service_of("/Users/x/Library/CloudStorage/GoogleDrive-a@b.com/My Drive/S") == "google", "Google Drive on a Mac")
assert(drive.service_of("C:/Users/x/Dropbox/S") == "dropbox" and drive.service_of("/Users/x/Library/CloudStorage/Dropbox/S") == "dropbox", "Dropbox")
assert(drive.service_of("C:/Users/x/OneDrive/S") == "onedrive", "OneDrive")
assert(drive.service_of("/Users/x/Library/Mobile Documents/com~apple~CloudDocs/S") == "icloud" and drive.service_of("C:/Users/x/iCloudDrive/S") == "icloud", "iCloud")
assert(drive.service_of("C:/Users/x/Box/S") == "box" and drive.service_of("/Users/x/Library/CloudStorage/Box-Box/S") == "box", "Box")
assert(drive.service_of("D:/Music/S") == nil and drive.label("dropbox") == "Dropbox", "nothing known")
-- several cloud drives on one computer (0.59.4)
local g, o, g2 = "G:/My Drive/S", "C:/Users/x/OneDrive/S", "H:/My Drive/S"
local here = { [g] = true, [o] = true, [g2] = true }
local function ex(p) return here[p] == true end
assert(drive.settle(g, "", ex) == g, "first time: the one found")
assert(drive.settle(o, g, ex) == g, "the one in use stays while it's there, though another drive's comes first now")
here[g] = nil
local use, away, other = drive.settle(o, g, ex)
assert(use == nil and away == g and other == o, "Google Drive not up: no jump to OneDrive's folder of that name")
assert(drive.settle(g2, g, ex) == g2, "the same Google Drive on another letter")
assert(drive.settle(o, g, ex, "onedrive") == o, "OneDrive picked in Settings: it moves")
here[g] = true
assert(drive.settle(o, g, ex, "onedrive") == o, "picked, though the old one's still there")
use, away = drive.settle(nil, g2, function() return false end)
assert(use == nil and away == g2, "nothing here now")
print("ok")
