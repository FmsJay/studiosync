"""Mix feedback from an AI (docs/ai-research.md section 4, "best value of anything here").
--in is the mix's numbers as JSON (stats.json from the Lua side: loudness, peaks, crest factor, stereo and spectrum figures, and the
rule-based notes already made). Only that JSON is sent, never audio. Two places to send it:
  opts["endpoint"] = "hub":    an OpenAI-compatible server (the owner's AI hub, http://127.0.0.1:4000): runs a model on a local GPU
  opts["endpoint"] = "claude": the Claude API (cloud), with the person's own key from ANTHROPIC_API_KEY or opts["key_file"]
The key is read here, sent only in the request's header, and never written to result.json, request.json or any log.
--dry-run writes request.json (what would be sent, key replaced by <redacted>) and sends nothing.
Result contract: files = ["feedback.md"] (and request.json on a dry run); data = {"reply": "...", "endpoint": ..., "model": ...}."""
import json, os, urllib.error, urllib.request

NAME = "feedback"
PACKAGES = []
MODEL = "your AI hub's model, or Claude (set in StudioSync AI's settings)"
LICENCE = "no model ships with the add-on: the hub's own models, or Anthropic's terms for the Claude API"
ESTIMATE = "seconds: a short text prompt (a small model handles it)"
CLOUD = "Claude API (text only: the numbers, no audio)"

CLAUDE_URL = "https://api.anthropic.com/v1/messages"
CLAUDE_MODEL = "claude-opus-5-5"
HUB_URL, HUB_MODEL = "http://127.0.0.1:4000", "qwen-auto"
MAX_STATS = 200_000  # bytes: the numbers for a big session are a few KB; anything this size isn't a stats summary
SECRET_HEADERS = {"x-api-key", "authorization"}

SYSTEM = ("You are an experienced mixing engineer giving a band notes on their mix. You get only measurements (no audio): integrated "
          "loudness (LUFS), sample and true peak, RMS, crest factor, stereo phase coherence and width, spectrum balance, for the "
          "master and each track, plus notes already made by fixed rules. Thresholds: peaks above -0.3 dBFS risk clipping; streaming "
          "plays at about -14 LUFS; phase coherence under 0.5 may cancel in mono; crest factor under 6 dB suggests over-compression; "
          "200-500 Hz more than 10 dB above 500-2000 Hz reads boxy. Give at most 8 short, concrete notes, most important first, each "
          "naming the track and a move to try. Don't repeat the rule notes word for word, and say when the numbers can't tell.")


def where(opts):
    return {"hub": "gpu", "claude": "cloud"}.get(opts.get("endpoint"), "none")


def read_key(opts):
    key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not key and opts.get("key_file"):
        try:
            with open(opts["key_file"], encoding="utf-8") as f:
                key = f.read().strip()
        except OSError:
            key = ""
    return key


def build_request(stats, opts, key=""):
    """-> (url, headers, body) for the chosen endpoint."""
    user = "The mix's numbers:\n" + json.dumps(stats, indent=1, sort_keys=True)
    if opts.get("endpoint") == "claude":
        model = opts.get("model") or CLAUDE_MODEL
        headers = {"content-type": "application/json", "x-api-key": key, "anthropic-version": "2026-10-21",
                   "anthropic-beta": "server-side-fallback-2026-07-01"}
        body = {"model": model, "max_tokens": 16000, "system": SYSTEM, "messages": [{"role": "user", "content": user}],
                "fallbacks": "default"}  # (a policy decline re-runs on a fallback model inside the same call)
        return CLAUDE_URL, headers, body
    base = (opts.get("hub_url") or HUB_URL).rstrip("/")
    if not base.startswith(("http://", "https://")):
        raise ValueError(f"the hub address must start with http:// or https://, not {base!r}")
    body = {"model": opts.get("model") or HUB_MODEL, "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}]}
    return base + "/v1/chat/completions", {"content-type": "application/json"}, body


def reply_text(endpoint, resp):
    """The answer's text out of the endpoint's JSON. Raises ValueError with a readable reason when there isn't one."""
    if endpoint == "claude":
        if resp.get("stop_reason") == "refusal":
            raise ValueError("Claude declined to answer (refusal)")
        text = "\n".join(b.get("text", "") for b in resp.get("content", []) if b.get("type") == "text").strip()
    else:
        text = ((resp.get("choices") or [{}])[0].get("message") or {}).get("content", "").strip()
    if not text:
        raise ValueError("the answer had no text in it")
    return text


def run(inp, out, opts, dry_run=False):
    if os.path.getsize(inp) > MAX_STATS:
        return {"status": "error", "message": "that input is too big to be the mix's numbers: only the stats summary is ever sent"}
    with open(inp, encoding="utf-8") as f:
        stats = json.load(f)
    if not isinstance(stats, dict):
        return {"status": "error", "message": "the mix's numbers should be a JSON object"}
    endpoint = opts.get("endpoint")
    if endpoint not in ("hub", "claude"):
        return {"status": "error", "message": "no AI is set for mix feedback (StudioSync AI > Settings)"}
    key = read_key(opts) if endpoint == "claude" else ""
    if endpoint == "claude" and not key and not dry_run:
        return {"status": "error", "message": "no Claude API key: set one in StudioSync AI > Settings, or ANTHROPIC_API_KEY"}
    url, headers, body = build_request(stats, opts, key)
    files = ["feedback.md"]
    if dry_run:
        shown = {k: ("<redacted>" if k.lower() in SECRET_HEADERS else v) for k, v in headers.items()}
        with open(os.path.join(out, "request.json"), "w", encoding="utf-8") as f:
            json.dump({"url": url, "headers": shown, "body": body}, f, indent=1)
        files.append("request.json")
        text = "(dry run: nothing was sent. request.json shows what would have been.)"
    else:
        req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                resp = json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:  # (the body is the server's error message; our headers, and the key, aren't in it)
            return {"status": "error", "message": f"{url} answered {e.code}: {e.read().decode('utf-8', 'replace')[:500]}"}
        except (urllib.error.URLError, TimeoutError) as e:
            return {"status": "error", "message": f"couldn't reach {url}: {getattr(e, 'reason', e)}"}
        try:
            text = reply_text(endpoint, resp)
        except ValueError as e:
            return {"status": "error", "message": str(e)}
    with open(os.path.join(out, "feedback.md"), "w", encoding="utf-8") as f:
        f.write(text + "\n")
    return {"status": "ok", "files": files, "data": {"reply": text, "endpoint": endpoint, "model": body["model"]}}
