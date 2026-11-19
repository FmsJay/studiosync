"""A copy signed by tools/sign_release.py (Python) checked by the extension's verifier (tests/sign_test.cpp "verify"), then tampered with and
refused. Run by tests/build_sign_test.cmd after the native self-test: python tests/sign_cross.py <path to sign_test>"""
import pathlib, subprocess, sys, tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "tools"))
import sign_release

exe = sys.argv[1]
fails = 0
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp) / "copy"
    (root / "lib" / "mac").mkdir(parents=True)
    (root / "StudioSync - Panel.lua").write_bytes(b"-- panel\r\nlocal x = 1\r\n")
    (root / "lib" / "band.lua").write_bytes(b'local band = { VERSION = "9.9.9-rt1" }\nreturn band\n')
    (root / "lib" / "mac" / "helper").write_bytes(b"\xcf\xfa\xed\xfe\0\0\r\n")
    seed = sign_release.new_key(pathlib.Path(tmp) / "update-key")
    pub = sign_release.public_key(seed).hex()
    sign_release.write(root, seed)

    def native(expect_ok, what):
        global fails
        r = subprocess.run([exe, "verify", str(root), pub], capture_output=True, text=True)
        ok = (r.returncode == 0) == expect_ok
        fails += not ok
        print("ok  " if ok else "FAIL", what, "|", r.stdout.strip())

    native(True, "a copy signed in Python passes the extension's check")
    print("ok  " if sign_release.check(root, pub).startswith("ok ") else "FAIL", "and Python's own check")
    (root / "lib" / "band.lua").write_bytes(b'local band = { VERSION = "9.9.9-rt1" }\nreturn band -- changed\n')
    native(False, "a changed file is refused")
    sign_release.write(root, seed)
    native(True, "signed again, it passes")
    (root / "lib" / "files.txt.sig").unlink()
    native(False, "no .sig is refused")
print("all ok" if not fails else f"FAILED ({fails})")
sys.exit(1 if fails else 0)
