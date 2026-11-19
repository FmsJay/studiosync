"""StudioSync AI helper: the job registry, the result.json contract, consent gating, dry runs, and the feedback request (never sent here).
Run: python -m unittest discover -s addons/ai/tests   (tests/run.py runs it too). No network, no models, no installs."""
import json, math, os, shutil, struct, subprocess, sys, tempfile, time, unittest, wave
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(os.path.dirname(HERE), "helper")
sys.path.insert(0, HELPER)
import ssai  # noqa: E402
from jobs import REGISTRY, common, feedback  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")


def make_wav(path, secs=2.0, sr=8000):
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"".join(struct.pack("<hh", int(8000 * math.sin(i / 10)), 0) for i in range(int(secs * sr))))


class Base(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="ssai-test-")
        self.wav = os.path.join(self.out, "in.wav")
        make_wav(self.wav)

    def tearDown(self):
        shutil.rmtree(self.out, ignore_errors=True)

    def consent(self, job, where, install=False, at=None, token="t0k3n"):
        with open(os.path.join(self.out, "consent.json"), "w", encoding="utf-8") as f:
            json.dump({"job": job, "where": where, "install": install, "at": time.time() if at is None else at, "token": token}, f)
        return token

    def run_helper(self, *args):
        code = ssai.main(list(args) + ["--out", self.out])
        with open(os.path.join(self.out, "result.json"), encoding="utf-8") as f:
            return code, json.load(f)


class Registry(unittest.TestCase):
    def test_every_job_is_a_complete_module(self):
        self.assertEqual(sorted(REGISTRY), ["chords", "feedback", "master", "midi", "sections", "stems", "transcribe"])
        for name, m in REGISTRY.items():
            for attr in ("NAME", "PACKAGES", "MODEL", "LICENCE", "ESTIMATE", "CLOUD", "where", "run"):
                self.assertTrue(hasattr(m, attr), f"{name} lacks {attr}")
            self.assertEqual(m.NAME, name)
            self.assertIn(m.where({}), ("gpu", "cpu", "cloud", "none"))
            self.assertIsInstance(common.describe(m)["missing"], list)

    def test_cloud_choice_changes_where(self):
        self.assertEqual(REGISTRY["stems"].where({"cloud": True}), "cloud")
        self.assertEqual(REGISTRY["feedback"].where({"endpoint": "hub"}), "gpu")
        self.assertEqual(REGISTRY["feedback"].where({"endpoint": "claude"}), "cloud")


class Contract(Base):
    def test_check_needs_no_consent_and_lists_jobs(self):
        code, res = self.run_helper("check")
        self.assertEqual(code, 0)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(set(res["data"]["jobs"]), set(REGISTRY))

    def test_result_json_always_has_the_contract_keys(self):
        for args in (["check"], ["stems", "--in", self.wav]):  # (one ok, one refused)
            _, res = self.run_helper(*args)
            for k in ("job", "status", "message", "files", "data", "timings", "helper_version"):
                self.assertIn(k, res)
            self.assertIn("total_s", res["timings"])

    def test_a_real_process_exits_nonzero_when_refused(self):
        r = subprocess.run([sys.executable, os.path.join(HELPER, "ssai.py"), "stems", "--in", self.wav, "--out", self.out], capture_output=True)
        self.assertEqual(r.returncode, 1)
        with open(os.path.join(self.out, "result.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f)["status"], "refused")
        self.assertFalse(os.path.exists(os.path.join(self.out, "result.json.tmp")))

    def test_bad_opts_still_end_in_a_result(self):
        tok = self.consent("stems", "gpu")
        code, res = self.run_helper("stems", "--in", self.wav, "--consent", tok, "--opts", "[1, 2]")
        self.assertEqual((code, res["status"]), (1, "error"))


class Consent(Base):
    def refused(self, *args):
        code, res = self.run_helper(*args)
        self.assertEqual((code, res["status"]), (1, "refused"), res)
        return res["message"]

    def test_no_token_no_run(self):
        self.consent("stems", "gpu")
        self.assertIn("no consent token", self.refused("stems", "--in", self.wav))

    def test_no_record_no_run(self):
        self.assertIn("no consent record", self.refused("stems", "--in", self.wav, "--consent", "anything"))

    def test_wrong_token(self):
        self.consent("stems", "gpu")
        self.assertIn("doesn't match", self.refused("stems", "--in", self.wav, "--consent", "guess"))

    def test_consent_for_another_job(self):
        tok = self.consent("midi", "cpu")
        self.assertIn("not 'stems'", self.refused("stems", "--in", self.wav, "--consent", tok))

    def test_a_hub_ok_is_not_a_cloud_ok(self):
        tok = self.consent("feedback", "gpu")
        stats = os.path.join(self.out, "stats.json")
        with open(stats, "w") as f:
            json.dump({"master": {}}, f)
        self.assertIn("'cloud'", self.refused("feedback", "--in", stats, "--consent", tok, "--opts", '{"endpoint": "claude"}'))

    def test_stale_consent(self):
        tok = self.consent("stems", "gpu", at=time.time() - 3600)
        self.assertIn("15 minutes", self.refused("stems", "--in", self.wav, "--consent", tok))

    def test_install_needs_its_own_ok(self):
        tok = self.consent("stems", "gpu", install=False)
        with mock.patch.object(common, "install") as inst:
            self.assertIn("installing", self.refused("stems", "--in", self.wav, "--consent", tok, "--install"))
            inst.assert_not_called()

    def test_without_install_nothing_is_installed(self):
        tok = self.consent("stems", "gpu")
        with mock.patch.object(common, "install") as inst, mock.patch.object(common, "missing", return_value=["audio-separator"]):
            code, res = self.run_helper("stems", "--in", self.wav, "--consent", tok)
            inst.assert_not_called()
        self.assertEqual(res["status"], "missing")
        self.assertEqual(res["packages"], ["audio-separator"])

    def test_install_runs_only_when_agreed(self):
        tok = self.consent("stems", "gpu", install=True)
        with mock.patch.object(common, "install") as inst, mock.patch.object(common, "missing", return_value=["audio-separator"]):
            self.run_helper("stems", "--in", self.wav, "--consent", tok, "--install")
            inst.assert_called_once()


class DryRuns(Base):
    def test_each_model_job_makes_its_fixture_shape(self):
        """The dry-run output has the keys the Lua importer's fixtures (fixtures/results/*.json) were made from."""
        for job in ("stems", "sections", "transcribe", "midi", "master", "chords"):
            out = tempfile.mkdtemp(prefix="ssai-dry-")
            try:
                res = REGISTRY[job].example(self.wav, out, {})
                with open(os.path.join(FIXTURES, "results", job + ".json"), encoding="utf-8") as f:
                    fixture = json.load(f)
                self.assertEqual(res["status"], "ok")
                self.assertEqual(sorted(res["data"]), sorted(fixture["data"]), job)
                for name in res["files"]:
                    self.assertTrue(os.path.isfile(os.path.join(out, name)), name)
            finally:
                shutil.rmtree(out, ignore_errors=True)

    def test_dry_run_through_the_cli(self):
        tok = self.consent("stems", "gpu")
        code, res = self.run_helper("stems", "--in", self.wav, "--consent", tok, "--dry-run")
        self.assertEqual((code, res["status"]), (0, "ok"))
        self.assertEqual([s["name"] for s in res["data"]["stems"]], ["Vocals", "Drums", "Bass", "Other"])

    def test_midi_files_are_midi(self):
        folder = os.path.join(self.out, "in")
        os.makedirs(folder)
        shutil.copy(self.wav, os.path.join(folder, "Bass.wav"))
        res = REGISTRY["midi"].example(folder, self.out, {})
        self.assertEqual(res["data"]["midi"], [{"name": "Bass", "file": "Bass.mid"}])
        with open(os.path.join(self.out, "Bass.mid"), "rb") as f:
            self.assertEqual(f.read(4), b"MThd")

    def test_model_jobs_say_they_are_not_built_yet(self):
        with mock.patch.object(common, "missing", return_value=[]):
            res = REGISTRY["stems"].run(self.wav, self.out, {})
        self.assertEqual(res["status"], "error")
        self.assertIn("interface only", res["message"])


class Feedback(Base):
    KEY = "sk-test-NEVER-WRITTEN"

    def stats(self):
        path = os.path.join(FIXTURES, "mixstats.json")
        dst = os.path.join(self.out, "stats.json")
        shutil.copy(path, dst)
        return dst

    def test_claude_dry_run_sends_nothing_and_never_writes_the_key(self):
        tok = self.consent("feedback", "cloud")
        with mock.patch.dict(os.environ, {"ANTHROPIC_API_KEY": self.KEY}), mock.patch("urllib.request.urlopen") as net:
            code, res = self.run_helper("feedback", "--in", self.stats(), "--consent", tok, "--dry-run",
                                        "--opts", '{"endpoint": "claude"}')
            net.assert_not_called()
        self.assertEqual((code, res["status"]), (0, "ok"))
        with open(os.path.join(self.out, "request.json"), encoding="utf-8") as f:
            req = json.load(f)
        self.assertEqual(req["url"], feedback.CLAUDE_URL)
        self.assertEqual(req["headers"]["x-api-key"], "<redacted>")
        self.assertEqual(req["headers"]["anthropic-version"], "2026-10-21")
        self.assertEqual(req["body"]["model"], "claude-opus-5-5")
        self.assertIn("Bass", req["body"]["messages"][0]["content"])  # (the numbers went in)
        for name in os.listdir(self.out):
            with open(os.path.join(self.out, name), "rb") as f:
                self.assertNotIn(self.KEY.encode(), f.read(), name)

    def test_hub_request_shape(self):
        url, headers, body = feedback.build_request({"master": {}}, {"endpoint": "hub", "hub_url": "http://127.0.0.1:4000/", "model": "qwen-auto"})
        self.assertEqual(url, "http://127.0.0.1:4000/v1/chat/completions")
        self.assertEqual(body["model"], "qwen-auto")
        self.assertEqual(body["messages"][0]["role"], "system")
        self.assertNotIn("x-api-key", headers)
        with self.assertRaises(ValueError):
            feedback.build_request({}, {"endpoint": "hub", "hub_url": "file:///etc/passwd"})

    def test_only_a_stats_summary_is_sent(self):
        tok = self.consent("feedback", "gpu")
        big = os.path.join(self.out, "big.json")
        with open(big, "w") as f:
            f.write('{"x": "' + "a" * (feedback.MAX_STATS + 10) + '"}')
        _, res = self.run_helper("feedback", "--in", big, "--consent", tok, "--opts", '{"endpoint": "hub"}')
        self.assertEqual(res["status"], "error")
        self.assertIn("too big", res["message"])

    def test_no_key_no_call(self):
        tok = self.consent("feedback", "cloud")
        env = {k: v for k, v in os.environ.items() if k != "ANTHROPIC_API_KEY"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch("urllib.request.urlopen") as net:
            _, res = self.run_helper("feedback", "--in", self.stats(), "--consent", tok, "--opts", '{"endpoint": "claude"}')
            net.assert_not_called()
        self.assertIn("no Claude API key", res["message"])

    def test_reply_parsing(self):
        self.assertEqual(feedback.reply_text("claude", {"content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": "Turn it down."}],
                                                        "stop_reason": "end_turn"}), "Turn it down.")
        with self.assertRaises(ValueError):
            feedback.reply_text("claude", {"stop_reason": "refusal", "content": []})
        self.assertEqual(feedback.reply_text("hub", {"choices": [{"message": {"content": " Less bass. "}}]}), "Less bass.")
        with self.assertRaises(ValueError):
            feedback.reply_text("hub", {"choices": []})


if __name__ == "__main__":
    unittest.main()
