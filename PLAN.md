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
4. Apply **Welch's method**: 8192-sample Hann-windowed segments with 50% overlap
5. For each segment: apply real FFT via vDSP, accumulate **squared magnitudes** (power spectrum)
6. Average power spectrum across all segments; convert to dB: `10 × log₁₀(avgPower)`
7. Smooth with a moving average (`window = max(3, freqBins / 80)`)
8. Detect cutoff with **three independent methods**, fuse by median
9. Map fused cutoff frequency → bitrate label using Hz-precision codec-specific thresholds

### Lossless Container Logic

This is the core detection path for **fake lossless** files (FLAC/WAV/AIFF upconverted from MP3).
Unlike simple cutoff-ratio thresholding, detection now uses a **multi-feature lossless score**:

```
losslessScore =
  0.25 × normalized(cutoffRatio, 0.90, 1.00)
+ 0.20 × (1 − shelfSharpness)
+ 0.20 × normalized(highBandEnergyRatio, 0.001, 0.02)
+ 0.15 × normalized(airBandSpectralFlatness, 0.01, 0.50)
+ 0.10 × (1 − cutoffAgreement)
+ 0.10 × (1 − segmentStability)

if losslessScore > 0.65  →  "lossless"
else                     →  apply MP3 Hz-precision mapping → "Fake lossless — upconverted from ~X kbps"
```

### Cutoff → Bitrate Map (MP3, reference 44.1 kHz)

| Cutoff range | Center | Bitrate |
|-------------|--------|---------|
| 3500–4500 Hz | 4000 Hz | 32 kbps |
| 10500–11500 Hz | 11000 Hz | 64 kbps |
| 13500–14500 Hz | 14000 Hz | 96 kbps |
| 15500–16500 Hz | 16000 Hz | 128 kbps |
| 17000–18000 Hz | 17500 Hz | 160 kbps |
| 18500–19500 Hz | 19000 Hz | 192 kbps |
| 19200–19800 Hz | 19500 Hz | 224 kbps |
| 19800–20200 Hz | 20000 Hz | 256 kbps |
| 20000–20500 Hz | 20250 Hz | 320 kbps |

All thresholds scale: `threshold × (sampleRate / 44100)`.

Full detail in `CALCULATIONS.md`.

---

## Current State

### ✅ Done
- Native macOS SwiftUI app (`BitCheck/ContentView.swift`)
- AVFoundation audio decoding (no ffmpeg required)
- FFT spectral analysis via Accelerate/vDSP
- Spectrogram viewer with time/frequency axes (log and linear scale toggle)
- Log/linear scale toggle on spectrogram (pre-renders both, instant switch)
- Codec-specific cutoff thresholds (MP3, AAC, Opus, lossless containers)
- **Fixed: fake lossless detection** — FLAC/WAV files now check spectrum instead of always returning "lossless"
- **Fixed: intro-skip** — analysis seeks to 20% mark on long tracks
- **Fixed: real FFT interleaving bug** — audio samples were being incorrectly treated as complex pairs; fixed by proper `withMemoryRebound` real-FFT packing in both the analyzer and spectrogram renderer
- **Improved: Welch's method** — 8192-sample FFT, 50% overlapping windows, power spectrum (squared magnitude) averaging instead of linear magnitude averaging
- **Improved: multi-method cutoff detection** — gradient, cumulative energy ratio, and noise floor methods fused by median; `cutoffAgreement` score measures inter-method consensus
- **Improved: Hz-precision bitrate mapping** — continuous Hz thresholds replacing integer kHz buckets; all thresholds scale with sample rate
- **Improved: sub-band energy analysis** — 8 logarithmically-spaced bands; high-band energy ratio and air-band spectral flatness computed
- **Improved: multi-feature lossless discrimination** — replaces single `cutoffRatio ≥ 0.92` check with weighted 6-feature score
- **Improved: confidence model** — incorporates shelf sharpness, cutoff agreement, spectral flatness; new penalty for low cutoff agreement
- Confidence scoring (shelf sharpness, segment stability, high-band suppression, cutoff agreement, spectral flatness)
- Training Mode with CSV export (for future native-labeled calibration)
- Batch file/folder scanning with table UI
- **Spectrogram cutoff overlay** — yellow horizontal line drawn at detected cutoff frequency with kHz label
- **Borderline lossless status** — cutoffRatio 0.92–0.95 shows "Possibly lossless (borderline)"; confidence capped at 70%
- **Spek-style spectrogram** — logarithmic frequency axis (20 Hz → Nyquist), Spek colour palette (black → purple → orange → yellow → white), 120 dB dynamic range, log-spaced y-axis labels
- Dark background toggle for spectrogram (transparent silence pixels composite over black/white background)
- dB legend with colour gradient and tick marks

### 🔜 Next
- **Calibration with known files** — test against a corpus of known-bitrate files to verify Hz-precision thresholds are well-centered; adjust bucket centers if systematic bias is found
- **AAC/Opus threshold tuning** — the Hz-precision buckets for AAC and Opus were derived from published encoder documentation; real-world validation may require fine-tuning
- **HE-AAC / SBR detection** — Spectral Band Replication synthesis creates artificial high-frequency energy that can fool energy-ratio methods; cross-correlation between low/high band envelopes would catch this

---

## Repo Structure

```
BitCheck.xcodeproj/       Xcode project (open this)
BitCheck/
  BitCheckApp.swift       @main entry point
  ContentView.swift       entire app: UI, analysis engine, spectrogram renderer
  Assets.xcassets/
CALCULATIONS.md    algorithm specification (detailed maths)
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
