"""Write/extend the ReaPack index.xml for StudioSync.

Usage (repo root):  python tools/make_index.py [--changelog "text"]
Then commit, tag v<VERSION>, and push the tag: every <source> URL points at that tag, so a
published version never changes under a bandmate. Older <version> entries are kept, so ReaPack
can pin or roll back. (reapack-index needs Ruby + pandoc; one package doesn't need that machinery.)
"""
import argparse, datetime, pathlib, re, urllib.parse
import xml.etree.ElementTree as ET

REPO = "FmsJay/studiosync"
ROOT = pathlib.Path(__file__).resolve().parent.parent
INDEX = ROOT / "index.xml"

version = re.search(r'VERSION = "([^"]+)"', (ROOT / "lib" / "band.lua").read_text(encoding="utf-8")).group(1)
ap = argparse.ArgumentParser()
ap.add_argument("--changelog", default="")
args = ap.parse_args()

def url(rel):
    return f"https://github.com/{REPO}/raw/v{version}/{urllib.parse.quote(rel)}"

# lib/files.txt: every code file and its length without carriage returns, so a computer running StudioSync from the shared folder takes an
# update only once all of it has arrived (lib/band.lua band.files_complete; review, 0.58.89)
# (each row's hash: 64-bit FNV-1a, full review, 0.59.44. Signed updates: a SHA-256 row for every file that ships, and lib/files.txt.sig signed
# with the studio owner's key when it's on this computer: tools/sign_release.py, docs/realtime-roadmap.md "Signed updates")
import sign_release
_key = sign_release.key_path()
sign_release.write(ROOT, sign_release.load_seed(_key) if _key.exists() else None)
print("lib/files.txt: " + (f"signed with {_key}" if _key.exists() else f"unsigned (no update key at {_key})"))

if INDEX.exists():
    index = ET.parse(INDEX).getroot()
    pkg = index.find("category/reapack")
else:
    index = ET.Element("index", version="1", name="StudioSync")
    cat = ET.SubElement(index, "category", name="StudioSync")
    pkg = ET.SubElement(cat, "reapack", name="StudioSync.lua", type="script",
                        desc="StudioSync: record together remotely over a shared folder")
    meta = ET.SubElement(pkg, "metadata")
    ET.SubElement(meta, "link", rel="website").text = f"https://github.com/{REPO}"

for old in pkg.findall("version"):
    if old.get("name") == version:  # re-running for the same version replaces it
        pkg.remove(old)
ver = ET.SubElement(pkg, "version", name=version, author="James",
                    time=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
if args.changelog:
    ET.SubElement(ver, "changelog").text = args.changelog
for f in sorted(ROOT.glob("StudioSync - *.lua")):
    ET.SubElement(ver, "source", main="main", file=f.name).text = url(f.name)  # registered as actions
for f in sorted((ROOT / "lib").glob("*.lua")):
    rel = f"lib/{f.name}"
    ET.SubElement(ver, "source", file=rel).text = url(rel)
for f in sorted((ROOT / "lib" / "mac").glob("*")):  # compiled helpers (tools/mac/build.sh): Macs only
    rel = f"lib/mac/{f.name}"
    ET.SubElement(ver, "source", file=rel, platform="darwin").text = url(rel)

for f in sorted(p for p in (ROOT / "lib" / "ninjam").rglob("*") if p.is_file()):  # the NINJAM server (tools/ninjam-server): each computer gets its own
    rel = f.relative_to(ROOT).as_posix()
    if rel.startswith("lib/ninjam/linux-"):  # (Linux's, per processor: lib/ninjam/linux-x86_64/, linux-aarch64/. services.ninjam_bin)
        plat = {"platform": "linux64" if "/linux-x86_64/" in rel else "linux-aarch64"}
    else:
        plat = {"ninjamsrv.exe": {"platform": "win64"}, "ninjamsrv": {"platform": "darwin"}, "njrelay": {"platform": "darwin"}}.get(f.name, {})
    ET.SubElement(ver, "source", file=rel, **plat).text = url(rel)
for f in sorted(p for p in (ROOT / "lib" / "toolbar_icons").rglob("*.png")):  # the toolbar button's image, copied into REAPER's toolbar_icons by the panel
    rel = f.relative_to(ROOT).as_posix()
    ET.SubElement(ver, "source", file=rel).text = url(rel)
for f in sorted((ROOT / "lib" / "listen").glob("*")):  # the listening page's little file server (lib/listen.lua)
    rel = f"lib/listen/{f.name}"
    plat = {"listen_server.ps1": {"platform": "windows"}}.get(f.name, {})  # (the Perl one for Macs and Linux: harmless on Windows)
    ET.SubElement(ver, "source", file=rel, **plat).text = url(rel)

# Extensions > StudioSync and View > StudioSync (extension/reaper_menu.cpp): a package of its own, with a version of its own that goes up
# only when the extension changes (EXT_VERSION), so StudioSync's updates don't try to replace a file REAPER has loaded. Each platform gets
# its build, when there is one (a new platform's build: raise EXT_VERSION).
EXT_VERSION = "1.0.11"  # (1.0.1: macOS and Linux builds, from .github/workflows/extension.yml; 1.0.2: toolbar button, icon map; 1.0.3: on any main toolbar; 1.0.4: lit while the panel is open, however it opened; 1.0.5: the action is called just StudioSync; 1.0.6: an amber dot while something stopped syncing; 1.0.7: the direct link, extension/direct.cpp; 1.0.8: its small messages, shared clock, streamed takes and the audio spike; 1.0.9: signed updates; 1.0.10: streams in 64 KB frames, file times for finding takes; 1.0.11: stream trace, live size, WAV header held back)
EXT_FILES = {"reaper_studiosync-x64.dll": "win64", "reaper_studiosync.dylib": "darwin",  # (the Mac build is universal: arm64 + x86_64)
             "reaper_studiosync-x86_64.so": "linux64", "reaper_studiosync-aarch64.so": "linux-aarch64"}
cat = index.find("category")
ext = next((p for p in cat.findall("reapack") if p.get("type") == "extension"), None)
if ext is None:
    ext = ET.SubElement(cat, "reapack", name="StudioSync menus.ext", type="extension",
                        desc="StudioSync in REAPER's Extensions and View menus")
    ET.SubElement(ET.SubElement(ext, "metadata"), "link", rel="website").text = f"https://github.com/{REPO}"
if not any(v.get("name") == EXT_VERSION for v in ext.findall("version")):
    ev = ET.SubElement(ext, "version", name=EXT_VERSION, author="James",
                       time=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    ET.SubElement(ev, "changelog").text = "The direct link: changes, messages (chat, cues, claims, presence, live MIDI) and takes as they record reach the others over Tailscale in well under a second, on a clock shared by the studio; and signed updates: a studio's owner signs each version, and every computer checks it before it runs."
    for name, plat in EXT_FILES.items():
        if (ROOT / "extension" / name).exists():
            ET.SubElement(ev, "source", platform=plat, file=name).text = url(f"extension/{name}")

ET.indent(index)
ET.ElementTree(index).write(INDEX, encoding="utf-8", xml_declaration=True)
print(f"index.xml: StudioSync {version}, {len(ver)} entries")
