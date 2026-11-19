-- StudioSync AI: the jobs the helper can run, and what the consent box says about each. Pure (no REAPER calls), so tests read it.
-- Figures and licences are docs/ai-research.md's (speeds are estimates on an RTX 4080, not measured here). A new tool: a row here and a
-- module in helper/jobs/.
--   input:  "mix" (the master, the time selection or the whole song) or "tracks" (the selected tracks, one file each)
--   import: what the result becomes in the project (lib/ai_import.lua)
--   where:  "gpu" (this computer's graphics card), "cpu", or what the endpoint decides (feedback)
local jobs = {}

jobs.LIST = {
  { id = "stems", label = "Split the mix into stems", input = "mix", import = "tracks", where = "gpu", timeout = 1800,
    model = "BS-RoFormer (vocals) + Demucs htdemucs_ft (drums, bass, other), through python-audio-separator",
    time = "about 15-60 s per 4-minute song", vram = "4-8 GB",
    licence = "MIT code; many RoFormer weights state no licence (downloaded on demand, never shared)" },
  { id = "sections", label = "Find sections and tempo", input = "mix", import = "regions", where = "gpu", timeout = 1800,
    model = "All-In-One (allin1)", time = "not measured here yet (minutes at most)", vram = "not measured here yet", licence = "MIT" },
  { id = "transcribe", label = "Transcribe the talk (who said what)", input = "mix", import = "notes", where = "gpu", timeout = 3600,
    model = "faster-whisper large-v3-turbo + pyannote community-1 (speakers)", time = "roughly 50x realtime", vram = "3-6 GB",
    licence = "MIT (faster-whisper); pyannote weights CC-BY-4.0, behind a Hugging Face login" },
  { id = "midi", label = "Selected tracks to MIDI", input = "tracks", import = "midi", where = "cpu", timeout = 900,
    model = "Spotify Basic Pitch (ADTOF for drums)", time = "near-instant", vram = "none (CPU)", licence = "Apache-2.0" },
  { id = "chords", label = "Chords and key", input = "mix", import = "markers", where = "cpu", timeout = 900,
    model = "Chordino / NNLS Chroma + libKeyFinder", time = "seconds", vram = "none (CPU)", licence = "GPL-2+ / GPL-3" },
  { id = "master", label = "Master to a reference track", input = "mix", import = "tracks", where = "cpu", timeout = 900,
    model = "Matchering 2", time = "seconds", vram = "none (CPU)", licence = "GPL-3.0" },
}
jobs.BY_ID = {}
for _, j in ipairs(jobs.LIST) do jobs.BY_ID[j.id] = j end

-- "Ask an AI about the mix": the helper's feedback job. Where it runs is the endpoint's: the hub runs a model on a GPU, Claude is a cloud
-- service. Either way only the numbers go, never audio.
jobs.FEEDBACK = { id = "feedback", label = "Ask an AI about the mix", input = "stats", import = "none", timeout = 330 }
function jobs.feedback_where(endpoint) return ({ hub = "gpu", claude = "cloud" })[endpoint] or "none" end

local WHERE = {
  gpu = "on a graphics card (a local GPU model)",
  cpu = "on this computer's processor (CPU)",
  cloud = "in the cloud",
}

-- The consent box's text for a run. job: a row of LIST (or FEEDBACK); o: { where, missing = {packages}, endpoint, model, service,
-- hub_url }. -> the text, ending in the question.
function jobs.consent_text(job, o)
  o = o or {}
  local where = o.where or job.where
  local t = { job.label .. "?", "" }
  if job.id == "feedback" then
    if o.endpoint == "claude" then
      t[#t + 1] = "Sends the mix's numbers (loudness, peaks, stereo and spectrum figures; no audio) to the Claude API (" .. tostring(o.model) ..
        "), in the cloud, on your own API key."
    else
      t[#t + 1] = "Runs " .. tostring(o.model) .. " on your AI hub (" .. tostring(o.hub_url) .. "): that uses a graphics card (a local GPU model)."
      t[#t + 1] = "Only the mix's numbers go to it, no audio."
    end
  else
    t[#t + 1] = "Model: " .. job.model
    if where == "cloud" then
      t[#t + 1] = "Where: " .. tostring(o.service or "a cloud service") .. ", in the cloud. Your audio leaves this computer."
    else
      t[#t + 1] = "Where: " .. WHERE[where]
      t[#t + 1] = "Time: " .. job.time .. ". Graphics memory: " .. job.vram .. "."
    end
    t[#t + 1] = "Licence: " .. job.licence
  end
  if o.missing and #o.missing > 0 then
    t[#t + 1] = ""
    t[#t + 1] = "First it downloads and installs: " .. table.concat(o.missing, ", ") ..
      " into StudioSync AI's own Python folder. The model's weights download the first time it runs."
  end
  t[#t + 1] = ""
  t[#t + 1] = "Go ahead?"
  return table.concat(t, "\n")
end

return jobs
