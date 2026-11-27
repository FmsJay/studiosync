"""The pages' read-rate control matches the extension's (rt-audio4, docs/rt/rt-audio4.md section 5: one controller, the JS copy tested to
match). Runs lib/webui/guestworklet.js's own ssPace text (the same text in sharemix.js and listen.js: tests/test_0_60_rt_p11.lua) in Node
over the golden trace tests/fixtures/pace_lite.json, which tests/rtaudio_test.cpp pace_lite_test checks extension/pace.h's pace::Lite
against: both must give its rates. Without Node: says so and passes (as tools/js_check.py). tests/run.py runs it.
usage: python tests/pace_lite_check.py   (exit 1 when they differ)"""
import pathlib, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
JS = r"""
const fs = require('fs');
const src = fs.readFileSync(process.argv[1], 'utf8').replace(/\r\n/g, '\n'), fx = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')); // (a CRLF checkout: the same text)
const consts = src.match(/^const PACE_WIN = [^\n]*\n/m), fn = src.match(/^function ssPace\(st, fill, target, dt, age\) \{[\s\S]*?\n\}\n/m), again = src.match(/^function ssPaceAgain\(st\) \{[^\n]*\n/m);
if (!consts || !fn || !again) { console.log('FAIL: ssPace, ssPaceAgain or PACE_WIN not found in the worklet'); process.exit(1); }
const m = new Function(consts[0] + fn[0] + again[0] + 'return { ssPace, ssPaceAgain };')();
const st = {}, got = [];
for (let i = 0; i < fx.steps.length; i++) {
  if (fx.again.includes(i)) m.ssPaceAgain(st);
  const r = m.ssPace(st, fx.steps[i][0], fx.target, fx.dt, fx.steps[i][1]);
  if (i % fx.every === 0) got.push(r);
}
let worst = got.length === fx.rates.length && got.length > 0 ? 0 : 1;
for (let i = 0; i < Math.min(got.length, fx.rates.length); i++) worst = Math.max(worst, Math.abs(got[i] - fx.rates[i]));
console.log((worst < 1e-12 ? 'ok' : 'FAIL') + ' the pages\' ssPace over the golden trace: ' + got.length + ' rates, worst difference ' + worst);
process.exit(worst < 1e-12 ? 0 : 1);
"""

def main():
    node = shutil.which("node")
    if not node:
        print("node not found: the pages' ssPace not checked against the golden trace")
        return 0
    r = subprocess.run([node, "-e", JS, str(ROOT / "lib/webui/guestworklet.js"), str(ROOT / "tests/fixtures/pace_lite.json")], capture_output=True, text=True)
    print((r.stdout or r.stderr).strip())
    return r.returncode

if __name__ == "__main__":
    sys.exit(main())
