"""Signed updates (docs/realtime-roadmap.md "Signed updates"): writes a StudioSync copy's lib/files.txt (version, each code file's length and
FNV hash as before, and a SHA-256 row for every file that ships: code and helpers) and signs it with the studio owner's Ed25519 key into
lib/files.txt.sig, which a studio's computers check (extension/sign.cpp StudioSync_VerifyFiles, lib/band.lua code_guard) before they run a
folder copy. tools/make_index.py calls this for the repo; run it yourself on a studio's folder copy after putting a new version there.

usage: python tools/sign_release.py [DIR] [--key PATH] [--new-key] [--unsigned]
  DIR        the copy (default: this repo)
  --key      the private key (default: $STUDIOSYNC_UPDATE_KEY, else ~/.studiosync/update-key). Keep it out of every synced folder.
  --new-key  make the key first if there's none (prints the public key: band.json "update_key", or Settings > Studio in REAPER)
  --unsigned only write lib/files.txt

Ed25519 below is RFC 8032 section 6's reference code (Simplified BSD licence, IETF Trust), trimmed. GPL-3.0-or-later for the rest."""
import hashlib, os, pathlib, re, secrets, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PREFIX = b"StudioSync files.txt v1\n"  # (extension/sign.h SIGN_FILES_PREFIX)

# ---- Ed25519 (RFC 8032 section 6) ----
p = 2**255 - 19
q = 2**252 + 27742317777372353535851937790883648493
d = -121665 * pow(121666, p - 2, p) % p
SQRT_M1 = pow(2, (p - 1) // 4, p)

def _add(P, Q):
    A, B = (P[1] - P[0]) * (Q[1] - Q[0]) % p, (P[1] + P[0]) * (Q[1] + Q[0]) % p
    C, D = 2 * P[3] * Q[3] * d % p, 2 * P[2] * Q[2] % p
    E, F, G, H = B - A, D - C, D + C, B + A
    return (E * F % p, G * H % p, F * G % p, E * H % p)

def _mul(s, P):
    Q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            Q = _add(Q, P)
        P = _add(P, P)
        s >>= 1
    return Q

def _equal(P, Q):
    return (P[0] * Q[2] - Q[0] * P[2]) % p == 0 and (P[1] * Q[2] - Q[1] * P[2]) % p == 0

def _recover_x(y, sign):
    if y >= p:
        return None
    x2 = (y * y - 1) * pow(d * y * y + 1, p - 2, p)
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (p + 3) // 8, p)
    if (x * x - x2) % p != 0:
        x = x * SQRT_M1 % p
    if (x * x - x2) % p != 0:
        return None
    return p - x if (x & 1) != sign else x

_gy = 4 * pow(5, p - 2, p) % p
_gx = _recover_x(_gy, 0)
G = (_gx, _gy, 1, _gx * _gy % p)

def _compress(P):
    zinv = pow(P[2], p - 2, p)
    x, y = P[0] * zinv % p, P[1] * zinv % p
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")

def _decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign, y = y >> 255, y & ((1 << 255) - 1)
    x = _recover_x(y, sign)
    return None if x is None else (x, y, 1, x * y % p)

def _hq(b):
    return int.from_bytes(hashlib.sha512(b).digest(), "little") % q

def _expand(seed):
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]

def public_key(seed):
    return _compress(_mul(_expand(seed)[0], G))

def sign(seed, msg):
    a, prefix = _expand(seed)
    A = _compress(_mul(a, G))
    r = _hq(prefix + msg)
    Rs = _compress(_mul(r, G))
    s = (r + _hq(Rs + A + msg) * a) % q
    return Rs + int.to_bytes(s, 32, "little")

def verify(public, msg, sig):
    if len(public) != 32 or len(sig) != 64:
        return False
    A, R = _decompress(public), _decompress(sig[:32])
    if not A or not R:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= q:
        return False
    return _equal(_mul(s, G), _add(R, _mul(_hq(sig[:32] + public + msg), A)))

# ---- the copy ----
def as_signed(data):
    """Text (no NUL byte) with CRLF read as LF; anything else as it is (extension/sign.cpp as_signed)."""
    return data if b"\0" in data else data.replace(b"\r\n", b"\n")

def fnv(data):  # band.code_hash: 64-bit FNV-1a over the text without carriage returns
    h = 0xcbf29ce484222325
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"

EXTENSIONS = ["reaper_studiosync-x64.dll", "reaper_studiosync.dylib", "reaper_studiosync-x86_64.so", "reaper_studiosync-aarch64.so"]

def code_files(root):
    return sorted(root.glob("StudioSync - *.lua")) + sorted((root / "lib").glob("*.lua"))

def shipped_files(root):
    """Every file a copy runs or hands out: the code, the helpers ReaPack ships (tools/make_index.py), the extension binaries."""
    out = code_files(root)
    for sub in ("lib/mac", "lib/ninjam", "lib/listen", "lib/toolbar_icons"):
        out += sorted(f for f in (root / sub).rglob("*") if f.is_file() and not f.name.startswith("."))
    out += [root / "extension" / n for n in EXTENSIONS if (root / "extension" / n).is_file()]
    return out

def files_txt(root):
    root = pathlib.Path(root)
    version = re.search(r'VERSION = "([^"]+)"', (root / "lib" / "band.lua").read_text(encoding="utf-8")).group(1)
    lines = [f"version {version}"]
    for f in code_files(root):
        data = f.read_bytes().replace(b"\r", b"")
        lines.append(f"{f.relative_to(root).as_posix()}\t{len(data)}\t{fnv(data)}")
    for f in shipped_files(root):
        lines.append(f"sha256 {hashlib.sha256(as_signed(f.read_bytes())).hexdigest()} {f.relative_to(root).as_posix()}")
    return "\n".join(lines) + "\n"

def key_path():
    return pathlib.Path(os.environ.get("STUDIOSYNC_UPDATE_KEY") or (pathlib.Path.home() / ".studiosync" / "update-key"))

def load_seed(path):
    text = pathlib.Path(path).read_text(encoding="ascii").strip()[:64]
    seed = bytes.fromhex(text)
    if len(seed) != 32:
        raise ValueError(f"{path} isn't an update key")
    return seed

def new_key(path):
    """The key at `path`, made if there's none (never overwritten). -> its seed."""
    path = pathlib.Path(path)
    if path.exists():
        return load_seed(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    seed = secrets.token_bytes(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)  # (only this user)
    with os.fdopen(fd, "w", encoding="ascii") as f:
        f.write(seed.hex() + "\n")
    return seed

def write(root, seed=None):
    """lib/files.txt for the copy at `root`, signed into lib/files.txt.sig when `seed` is given. -> the signature (hex) or None."""
    root = pathlib.Path(root)
    text = files_txt(root)
    (root / "lib" / "files.txt").write_text(text, encoding="utf-8", newline="\n")
    sig_path = root / "lib" / "files.txt.sig"
    if seed is None:
        sig_path.unlink(missing_ok=True)  # (a signature of the old list would only be refused)
        return None
    sig = sign(seed, PREFIX + text.encode("utf-8")).hex()
    sig_path.write_text(sig + "\n", encoding="ascii", newline="\n")
    return sig

def file_hash(path):
    """StudioSync_FileHash in Python: a file's SHA-256 as lib/files.txt lists it."""
    return hashlib.sha256(as_signed(pathlib.Path(path).read_bytes())).hexdigest()

def sign_dir(root, keypath):
    """The copy at `root` signed with the key at `keypath` (made if there's none). -> the public key (hex)."""
    seed = new_key(keypath)
    write(root, seed)
    return public_key(seed).hex()

def check(root, public):
    """What StudioSync_VerifyFiles answers, in Python (tests). -> "ok <version>" + a new line + lib/files.txt as signed, or why not."""
    root = pathlib.Path(root)
    try:
        listing = as_signed((root / "lib" / "files.txt").read_bytes())
        sig = bytes.fromhex((root / "lib" / "files.txt.sig").read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return "it isn't signed (no lib/files.txt.sig)"
    if not verify(bytes.fromhex(public), PREFIX + listing, sig):
        return "lib/files.txt isn't signed by the studio's update key"
    text = listing.decode("utf-8")
    for line in text.split("\n"):
        m = re.match(r"^sha256 ([0-9a-f]{64}) (.+)$", line)
        if m:
            f = root / m.group(2)
            if not f.is_file():
                return f"{m.group(2)} isn't there"
            if hashlib.sha256(as_signed(f.read_bytes())).hexdigest() != m.group(1):
                return f"{m.group(2)} doesn't match its signed SHA-256"
    if not any(line.startswith("sha256 ") for line in text.split("\n")):
        return "lib/files.txt lists no SHA-256 hashes"
    return "ok " + text.split("\n", 1)[0][len("version "):] + "\n" + text

if __name__ == "__main__":
    args = sys.argv[1:]
    opt = lambda name: name in args and (args.remove(name) or True)
    make, unsigned = opt("--new-key"), opt("--unsigned")
    kp = key_path()
    if "--key" in args:
        i = args.index("--key")
        kp = pathlib.Path(args[i + 1])
        del args[i:i + 2]
    root = pathlib.Path(args[0]) if args else ROOT
    seed = None
    if not unsigned:
        if make:
            seed = new_key(kp)
        elif kp.exists():
            seed = load_seed(kp)
        else:
            sys.exit(f"no update key at {kp} (--new-key makes one, --unsigned writes lib/files.txt only)")
    write(root, seed)
    print(f"{root / 'lib' / 'files.txt'}: written" + (f", signed (update_key {public_key(seed).hex()})" if seed else ", unsigned"))
