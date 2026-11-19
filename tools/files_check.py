"""Does lib/files.txt match the code? Its version line must be band.lua's VERSION, it must list every StudioSync - *.lua and lib/*.lua, and each
row's length and hash (64-bit FNV-1a over the text without carriage returns, as band.code_hash and tools/make_index.py work it out) must match.
A stale list stops every computer that runs StudioSync from a studio's folder from taking the release (band.files_complete), silently: 0.59.43
shipped with only its version line changed. tests/run.py runs this; it fails the run with --release. Round 2 review, 0.59.46.
usage: python tools/files_check.py   (exit 1 when it doesn't match)"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

def fnv(data):
    h = 0xcbf29ce484222325
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"

def problems(root=ROOT):
    out = []
    version = re.search(r'VERSION = "([^"]+)"', (root / "lib" / "band.lua").read_text(encoding="utf-8")).group(1)
    text = (root / "lib" / "files.txt").read_text(encoding="utf-8") if (root / "lib" / "files.txt").exists() else ""
    lines = text.splitlines()
    if not lines or lines[0] != f"version {version}":
        out.append(f"version line is {lines[0] if lines else 'missing'!r}, band.lua says {version}")
    listed = {}
    for l in lines[1:]:
        m = re.match(r"^([^\t]+)\t(\d+)\t?([0-9a-f]*)$", l)
        if m:
            listed[m.group(1)] = (int(m.group(2)), m.group(3))
    code = sorted(root.glob("StudioSync - *.lua")) + sorted((root / "lib").glob("*.lua"))
    for f in code:
        rel = f.relative_to(root).as_posix()
        data = f.read_bytes().replace(b"\r", b"")
        if rel not in listed:
            out.append(f"{rel} isn't listed")
            continue
        n, h = listed.pop(rel)
        if n != len(data):
            out.append(f"{rel}: listed {n} bytes, is {len(data)}")
        elif h and h != fnv(data):
            out.append(f"{rel}: hash differs")
    for rel in listed:
        out.append(f"{rel} is listed but isn't there")
    return out

if __name__ == "__main__":
    p = problems()
    for x in p[:20]:
        print(x)
    print(f"lib/files.txt doesn't match the code ({len(p)}): run python tools/make_index.py" if p else "lib/files.txt matches the code")
    sys.exit(1 if p else 0)
