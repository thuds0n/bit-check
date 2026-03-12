# BitCheck — Development Plan

## What It Is

**BitCheck** is a native macOS app that detects whether an audio file's claimed quality is genuine or upconverted from a lower-quality lossy source.

Detection is based entirely on native spectral signal analysis through pure signal physics.

---

## How Detection Works

When audio is encoded with a lossy codec (MP3, AAC, Opus), the encoder applies a **low-pass filter** whose cutoff frequency is determined by the target bitrate. This spectral shelf is a permanent artefact baked into the decoded PCM — re-encoding at a higher bitrate or into a lossless container cannot restore the removed content.

### Pipeline

1. Open file natively with `AVAudioFile` (supports MP3, FLAC, WAV, AAC, AIFF, ALAC — no ffmpeg needed)
2. For tracks > 60 s, seek to the 20% mark before reading to skip silent intros
3. Read up to 30 seconds of mono Float32 PCM
4. For each 1-second window: apply Hann window via `vDSP`, compute FFT via `vDSP.FFT`
5. Average magnitude spectra across all windows, convert to log₁₀ scale, smooth
6. Estimate cutoff with a two-stage algorithm:
   - **Primary**: last bin where `spectrum ≥ peak − thresholdDrop`
   - **Gradient refinement**: find the steepest local drop in a ±12.5% window around the primary estimate (the "knee" of the shelf)
7. Map cutoff frequency → bitrate label using codec-specific buckets

### Lossless Container Logic

This is the core detection path for **fake lossless** files (FLAC/WAV/AIFF upconverted from MP3):

```
cutoffRatio = cutoffHz / nyquistHz

if cutoffRatio ≥ 0.92  →  "lossless" (spectrum reaches near Nyquist)
else                   →  apply MP3 bucket mapping, status = "Fake lossless — upconverted from ~X kbps"
```

A 320 kbps MP3 upconverted to FLAC produces `cutoffRatio ≈ 0.91`. Genuine lossless audio at 44.1 kHz typically reaches `cutoffRatio ≥ 0.97`.

### Cutoff → Bitrate Map (MP3)

| Cutoff | Bitrate |
|--------|---------|
| ≤ 11 kHz | 64 kbps |
| 12–14 kHz | 128 kbps |
| 15–16 kHz | 160 kbps |
| 17–18 kHz | 192 kbps |
| 19 kHz | 224 kbps |
| 20–21 kHz | 320 kbps |
| > 92% Nyquist | lossless |

Full detail in `BITRATE_CALCULATION.md`.

---

## Current State

### ✅ Done
- Native macOS SwiftUI app (`BitCheck/ContentView.swift`)
- AVFoundation audio decoding (no ffmpeg required)
- FFT spectral analysis via Accelerate/vDSP
- Spectrogram viewer with time/frequency axes
- Codec-specific cutoff thresholds (MP3, AAC, Opus, lossless containers)
- **Fixed: fake lossless detection** — FLAC/WAV files now check spectrum instead of always returning "lossless"
- **Fixed: intro-skip** — analysis seeks to 20% mark on long tracks
- **Improved: gradient-based cutoff** — finds the spectral shelf knee, not just the threshold crossing
- Confidence scoring (drop sharpness, segment stability, suppression above cutoff)
- Training Mode with CSV export (for future native-labeled calibration)
- Batch file/folder scanning with table UI
- **Spectrogram cutoff overlay** — yellow horizontal line drawn at detected cutoff frequency with kHz label; visible when opening "View Spectrogram" after running analysis
- **Borderline lossless status** — cutoffRatio 0.92–0.95 now shows "Possibly lossless (borderline)" instead of "Likely lossless"; confidence already capped at 70% for this zone

### 🔜 Next
- **AAC/Opus improvements** — thresholds were tuned for MP3; AAC and Opus have different filter shapes and may need separate bucket tuning
- **Re-calibration with native labels** — build a labeled dataset using files with known provenance (not FTF output), run through Training Mode, tune thresholds using `calibrate.py`

---

## Repo Structure

```
BitCheck.xcodeproj/       Xcode project (open this)
BitCheck/
  BitCheckApp.swift       @main entry point
  ContentView.swift       entire app: UI, analysis engine, spectrogram renderer
  Assets.xcassets/
BITRATE_CALCULATION.md    algorithm specification
BitCheckTests/            unit test target (placeholder)
BitCheckUITests/          UI test target (placeholder)
true-bitrate              legacy bash CLI wrapper (uses ffmpeg + Python)
true-bitrate.py           legacy Python spectral analysis script
```

---

## Building

Open `BitCheck.xcodeproj` in Xcode, select the **BitCheck** scheme, and run. macOS 14+ target. Zero external dependencies.

```
xcodebuild -scheme BitCheck -destination 'platform=macOS' build
```
