"""Every web page script parses: `node --check` on lib/webui/*.js (2026-11-20: a line break inside a string in phonedaw.js broke the
phone's Project, Sheet and Play views for two releases and no test noticed). Without Node on this computer it says so and passes."""
import glob, os, shutil, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
node = shutil.which("node")
if not node:
    print("node not found: web page scripts not checked")
    sys.exit(0)
bad = []
files = sorted(glob.glob(os.path.join(root, "lib", "webui", "*.js")))
for f in files:
    r = subprocess.run([node, "--check", f], capture_output=True, text=True)
    if r.returncode != 0:
        bad.append(os.path.relpath(f, root) + ": " + (r.stderr.strip().splitlines() or ["?"])[0][:200])
for b in bad:
    print(b)
print(f"{len(files) - len(bad)} of {len(files)} web page scripts parse")
sys.exit(1 if bad else 0)
