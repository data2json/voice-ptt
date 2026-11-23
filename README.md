# VoicePTT

A lightweight, native macOS menu-bar Push-to-Talk & continuous-buffer local voice dictation app powered by [`whisper.cpp`](https://github.com/ggml-org/whisper.cpp) and Silero VAD, with optional **Decision Router** and **OpenAI-compatible LLM refinement**.

Zero Electron, zero Python runtime dependencies — just a single Objective-C Cocoa binary + local `whisper-server`.

---

## Features

- **Always-On Circular Audio Ring Buffer**: Continuously records 16 kHz mono PCM into a 3-minute in-memory ring buffer (~5.8 MB RAM), with automatic wake and CoreAudio hot-plug recovery and a menu-bar **Arm / Pause** toggle.
- **Zero-Clip Pre-Roll & Speech-Tail Post-Roll**:
  - Starts slicing `300 ms` *before* your trigger press so opening consonants are never cut off.
  - On release, listens for `350 ms` minimum and rides out active speech (up to `1800 ms`, closing after `450 ms` of silence) so releasing mid-word never chops your last word.
- **Adaptive Room-Noise Gate + 80 Hz High-Pass Filter**: Tracks a rolling 30th-percentile ambient room floor while idle so the gate adapts automatically to TV/HVAC/background noise (plus manual presets & quick Mic Input Gain controls).
- **Single-Model Incremental Streaming**: Runs one dedicated `whisper-server` on all physical CPU cores. Short 1–4.5 s phrases execute once with zero overlap; longer dictations commit completed sentences during natural pauses or via segment timestamps so release stays snappy.
- **Focus-Aware Output Routing**:
  - **Smart Auto (default)**: Inspects macOS Accessibility focus (`AXUIElement` + terminal bundle IDs). Pastes cleanly into editable fields/terminals (preserving your existing clipboard), or copies to clipboard + flashes a non-activating OSD toast when no text input is focused.
  - **Always Paste** and **Clipboard Only** modes also available.
- **Flexible Triggers**:
  - **Smart Mode**: Hold to talk, or quick double-tap to lock hands-free (Esc cancels anytime).
  - **Hold Only** or **Tap-to-Toggle** modes.
  - Configurable hotkey (`Right ⌥`, `Right ⌘`, `Right ⌃`, `F5`, `F13 / Foot Pedal`) + wired headset inline Play/Pause button support.
- **Optional Post-Processing Pipeline**:
  - **OpenAI-Compatible LLM Refinement** (Ollama, `llama-server`, LM Studio, OpenAI, etc.) with active-app context, word-count skip gate, and automatic fallback to raw ASR on timeout/error.
  - **Decision Router (DR) HTTP Hook** structured for single-pass decision models like XTuner's **Intern-Decision** (`needs_refine`, `output_action`, `style`).
- **Live Per-Stage Latency Telemetry**: Logs exact release-to-emit timing breakdown to `~/.config/voice-ptt/latency.log`.

---

## Architecture

```text
[Continuous Mic (CoreAudio)] ──► [3-min PCM Ring Buffer + Ambient Noise Floor]
                                                    │
                    Trigger Down (t0 - 300ms) .. Trigger Up (VAD tail settle)
                                                    ▼
                    Stage 1: 80 Hz High-Pass Filter + Adaptive Noise Gate
                                                    ▼
                    Stage 2: Local whisper-server (Single Model + Silero VAD)
                             (Pause/Segment Incremental Commits on Long Speech)
                                                    ▼
                    Stage 3A: Optional Decision Router HTTP Hook (Intern-Decision)
                    Stage 3B: Optional OpenAI-Compatible LLM Refinement
                                                    ▼
                    Stage 4: Focus-Aware Output (Smart Auto Paste / Clipboard)
```

---

## Requirements

- macOS 12.0+ (Intel `x86_64` or Apple Silicon `arm64`)
- Xcode Command Line Tools (`xcode-select --install`)
- `cmake` (e.g., `brew install cmake`) to build `whisper.cpp`

---

## Quick Start

### Option A: Download Prebuilt Release (No Xcode/CMake needed)

1. Download the archive for your Mac from **GitHub Releases**:
   - **Apple Silicon (M1/M2/M3/M4)**: `VoicePTT-*-macos-arm64.zip` *(built with Metal GPU acceleration)*
   - **Intel Mac**: `VoicePTT-*-macos-x86_64.zip` *(built with Accelerate)*
2. Unzip, drag `VoicePTT.app` to `/Applications` (or keep it anywhere), and download a Whisper + Silero VAD model:
   ```bash
   ./download-models.sh                  # large-v3-turbo-q5_0 (best accuracy)
   # or: ./download-models.sh small.en-q5_1  (fastest on Intel CPU)
   ```
3. Since prebuilt releases are ad-hoc signed, clear the macOS quarantine attribute on first launch:
   ```bash
   xattr -dr com.apple.quarantine VoicePTT.app
   open VoicePTT.app
   ```

### Option B: Build from Source

```bash
git clone --recurse-submodules <your-repo-url> voice-ptt
cd voice-ptt

# 1. Build static whisper-server and download Silero VAD + Whisper model
#    (defaults to large-v3-turbo-q5_0; pass e.g. small.en-q5_1 for faster Intel CPU)
./scripts/setup.sh

# 2. Compile and sign VoicePTT.app
./build.sh

# 3. Launch
open VoicePTT.app
```

### Permissions

On first launch, macOS will ask for two permissions:
1. **Microphone** — to capture audio into the ring buffer.
2. **Accessibility** (*System Settings → Privacy & Security → Accessibility*) — for global hotkeys, focus detection, and `Cmd+V` paste injection.

*(Note: After rebuilding and ad-hoc signing `VoicePTT.app`, macOS may require toggling VoicePTT off/on once in Accessibility settings.)*

---

## CI & Automated Releases (GitHub Actions)

- **CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml))**: Runs on every push and PR to `main`, building and verifying `VoicePTT.app` on both **Apple Silicon (`macos-15`)** and **Intel (`macos-15-intel`)** with cached `whisper-server` builds, `codesign --verify`, and downloadable `.zip` artifacts.
- **Releases ([`.github/workflows/release.yml`](.github/workflows/release.yml))**: Push any `v*` tag (or trigger manually via **Actions → Release**) to automatically build both `arm64` and `x86_64` archives + `SHA256SUMS.txt` and publish a GitHub Release:
  ```bash
  git tag v1.0.0
  git push origin v1.0.0
  ```

---

## Choosing a Whisper Model

Download any additional GGML model into `models/` and it will appear immediately in the menu bar under **Whisper Model**:

```bash
sh whisper.cpp/models/download-ggml-model.sh small.en-q5_1 models/
```

| Model | Size | Best For |
| --- | --- | --- |
| `ggml-large-v3-turbo-q5_0.bin` | ~547 MB | Best overall accuracy (fast on Apple Silicon Metal; ~1.7–2.7 s on Intel CPU) |
| `ggml-medium.en-q5_0.bin` | ~539 MB | Strong English accuracy & background-noise rejection |
| `ggml-small.en-q5_1.bin` | ~190 MB | Snappiest accuracy/speed sweet spot on Intel CPU (~0.5–0.9 s) |
| `ggml-base.en-q5_1.bin` | ~60 MB | Ultra-low latency when paired with LLM refinement |

---

## Configuration

VoicePTT auto-creates `~/.config/voice-ptt/config.json` on launch (see [`config.example.json`](config.example.json)) and hot-reloads it on every capture — no restart required. You can open it anytime from the menu bar via **Edit LLM & DR Config (config.json)…**.

- **Custom Vocabulary**: Edit `~/.config/voice-ptt/prompt.txt` (via **Edit Custom Vocabulary…**) with domain terms, names, or acronyms you want Whisper to bias toward.
- **OpenAI-Compatible LLM**: Set `llm.base_url`, `llm.model`, and optional `llm.api_key` (works with Ollama `http://127.0.0.1:11434/v1`, `llama-server`, LM Studio, OpenAI, etc.), then toggle **LLM Refinement** in the menu bar.

### Decision Router (DR) HTTP Contract

When **Decision Router** is enabled (`decision_router.enabled: true`), VoicePTT POSTs JSON to `decision_router.endpoint_url`:

```json
{
  "model": "Intern-Decision-2B",
  "state": {
    "transcript": "uh actually make that forty five seconds",
    "active_app": "Terminal",
    "focused_editable": true,
    "audio_duration_sec": 3.1,
    "word_count": 7
  },
  "schema": {
    "needs_refine": ["yes", "no"],
    "output_action": ["paste", "clipboard", "discard"],
    "style": ["prose", "code", "command"]
  }
}
```

Expected JSON response:

```json
{
  "decisions": {
    "needs_refine": "yes",
    "output_action": "paste",
    "style": "prose"
  }
}
```

If the DR endpoint is unreachable or times out, VoicePTT falls back cleanly to local routing rules.

---

## Latency Profiling

Watch live per-stage release-to-emit timings in any terminal:

```bash
touch ~/.config/voice-ptt/latency.log && tail -f ~/.config/voice-ptt/latency.log
```

Example output:

```text
[22:39:08] total=2112ms | post_roll=355ms | wait_stream=0ms | whisper=1734ms (tail=2.7s, fastpath=no) | dr=0ms | llm=0ms | out=Pasted (Terminal) | "Damn, that was pretty fire."
```

---

## License

[MIT](LICENSE) — built on [`whisper.cpp`](https://github.com/ggml-org/whisper.cpp) and [Silero VAD](https://github.com/snakers4/silero-vad).
