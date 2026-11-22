"""Is this tree ready to publish through ReaPack (index.xml on main)? Run after tools/make_index.py and before pushing the tag.
Checks what broke or could break a release: an index entry whose files point at a tag that doesn't exist (0.59.49.1 and extension 1.0.9 did,
on the realtime branch: every computer's ReaPack would have offered them and failed), a version that older copies don't see as newer, a test
build's four-number version, the extension's three version numbers disagreeing or a binary of another version, a stale lib/files.txt, and the
Hop plug-in builds the installers hand out (plugin/dist). docs/rt/install-realtime.md "Releasing".
usage: python tools/release_check.py   (exit 1 when something isn't ready)"""
import pathlib, re, subprocess, sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXT_FILES = {"reaper_studiosync-x64.dll": "win64", "reaper_studiosync.dylib": "darwin",
             "reaper_studiosync-x86_64.so": "linux64", "reaper_studiosync-aarch64.so": "linux-aarch64"}
HOP_DIRS = ("windows-x64", "mac", "linux-x86_64", "linux-aarch64")  # (the installers read plugin/dist/<these>/StudioSync Hop.clap and .vst3)


def nums(v):
    return [int(n) for n in re.findall(r"\d+", v)]


def newer(a, b):  # (as band.compare_versions: number by number, a missing one is 0)
    x, y = nums(a), nums(b)
    n = max(len(x), len(y))
    return (x + [0] * (n - len(x))) > (y + [0] * (n - len(y)))


def tag_of(url):
    m = re.search(r"/raw/([^/]+)/", url or "")
    return m.group(1) if m else None


def local_tags(root):
    try:
        out = subprocess.run(["git", "-C", str(root), "tag", "--list"], capture_output=True, text=True, timeout=30)
        return set(out.stdout.split()) if out.returncode == 0 else None
    except OSError:
        return None


def grab(path, pattern):
    m = re.search(pattern, path.read_text(encoding="utf-8", errors="replace")) if path.exists() else None
    return m.group(1) if m else None


def problems(root=ROOT, tags=None):
    root = pathlib.Path(root)
    out = []
    version = grab(root / "lib" / "band.lua", r'VERSION = "([^"]+)"')
    if not version:
        return ["lib/band.lua has no VERSION"]
    if len(nums(version)) > 3:
        out.append(f"VERSION {version} has four numbers: that's a test build's (0.59.49.N); a release has three, above every test build (0.60.0)")
    index = ET.parse(root / "index.xml").getroot()
    pkgs = {p.get("name"): p for p in index.iter("reapack")}
    main, ext = pkgs.get("StudioSync.lua"), pkgs.get("StudioSync menus.ext")
    if main is None or ext is None:
        return out + ["index.xml lacks the StudioSync.lua or StudioSync menus.ext package"]
    tags = local_tags(root) if tags is None else tags
    if tags is not None:  # (every source must point at a tag that exists, or at the one about to be pushed)
        for pkg in (main, ext):
            for v in pkg.findall("version"):
                bad = sorted({t for t in (tag_of(s.text) for s in v.findall("source")) if t and t not in tags and t != f"v{version}"})
                if bad:
                    out.append(f"index.xml: {pkg.get('name')} {v.get('name')} points at {', '.join(bad)}, which isn't a tag")
    vers = [v.get("name") for v in main.findall("version")]
    others = [v for v in vers if v != version]
    if version not in vers:
        out.append(f"index.xml has no StudioSync.lua {version}: run python tools/make_index.py")
    top = max(others, key=nums, default=None)
    if top and not newer(version, top):
        out.append(f"VERSION {version} isn't newer than {top} in index.xml: copies on {top} wouldn't update to it")
    entry = next((v for v in main.findall("version") if v.get("name") == version), None)
    if entry is not None:
        files = {s.get("file") for s in entry.findall("source")}
        want = {f.name for f in root.glob("StudioSync - *.lua")} | {f"lib/{f.name}" for f in (root / "lib").glob("*.lua")} | \
               {f"lib/webui/{f.name}" for f in (root / "lib" / "webui").glob("*") if f.is_file()}
        missing = sorted(want - files)
        if missing:
            out.append(f"index.xml {version} lacks {len(missing)} file(s), e.g. {missing[0]}: run python tools/make_index.py again")
        wrong = sorted({tag_of(s.text) for s in entry.findall("source")} - {f"v{version}"})
        if wrong:
            out.append(f"index.xml {version} points at {wrong[0]}, not v{version}")
    ev = {"tools/make_index.py": grab(root / "tools" / "make_index.py", r'EXT_VERSION = "([^"]+)"'),
          "lib/tools.lua EXT_WANT": grab(root / "lib" / "tools.lua", r'tools\.EXT_WANT = "([^"]+)"'),
          "extension/reaper_menu.cpp": grab(root / "extension" / "reaper_menu.cpp", r'#define EXT_VERSION "([^"]+)"')}
    if len(set(ev.values())) != 1 or None in ev.values():
        out.append("the extension's version disagrees: " + ", ".join(f"{k} {v}" for k, v in ev.items()))
    want_ext = ev["tools/make_index.py"]
    if want_ext:
        e = next((v for v in ext.findall("version") if v.get("name") == want_ext), None)
        if e is None:
            out.append(f"index.xml has no StudioSync menus.ext {want_ext}: run python tools/make_index.py")
        elif {s.get("platform") for s in e.findall("source")} != set(EXT_FILES.values()):
            out.append(f"index.xml menus.ext {want_ext} doesn't have all four platforms' builds")
        for name in EXT_FILES:
            f = root / "extension" / name
            if not f.exists():
                out.append(f"extension/{name} is missing")
            elif (want_ext + "\0").encode() not in f.read_bytes():  # (as lib/fromfolder.lua extension_tick tells a build's version)
                out.append(f"extension/{name} isn't the {want_ext} build")
    sys.path.insert(0, str(ROOT / "tools"))
    try:
        import files_check
        stale = files_check.problems(root)
        if stale:
            out.append(f"lib/files.txt doesn't match the code ({len(stale)}, e.g. {stale[0]}): run python tools/make_index.py")
    finally:
        sys.path.pop(0)
    for d in HOP_DIRS:
        for n in ("StudioSync Hop.clap", "StudioSync Hop.vst3"):
            if not (root / "plugin" / "dist" / d / n).exists():
                out.append(f"plugin/dist/{d}/{n} is missing: the installers hand out the Hop plug-in from there")
    return out


if __name__ == "__main__":
    p = problems()
    for x in p:
        print(x)
    print(f"not ready to release ({len(p)})" if p else "ready to release")
    sys.exit(1 if p else 0)
