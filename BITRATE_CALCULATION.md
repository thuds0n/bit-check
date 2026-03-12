# Bitrate Calculation and Confidence Calibration

## Goal

Determine whether an audio file's claimed quality is genuine or whether it has been
upconverted from a lower-quality lossy source (e.g. a 128 kbps MP3 re-encoded as 320 kbps
or FLAC). Detection is based entirely on native spectral signal analysis — no dependency
on the output of other tools.

## Core Physics

All common lossy codecs (MP3, AAC, Opus) apply a low-pass filter during encoding whose
cutoff frequency is determined by the target bitrate. This "spectral shelf" is a permanent
artefact baked into the decoded PCM — re-encoding at a higher bitrate or into a lossless
container cannot restore the removed high-frequency content.

| MP3 bitrate | Approx. cutoff | Cutoff ratio (44.1 kHz) |
|-------------|---------------|--------------------------|
| 64 kbps     | ~11 kHz       | 0.50                     |
| 128 kbps    | ~16 kHz       | 0.73                     |
| 160 kbps    | ~17 kHz       | 0.77                     |
| 192 kbps    | ~19 kHz       | 0.86                     |
| 224 kbps    | ~19.5 kHz     | 0.88                     |
| 320 kbps    | ~20 kHz       | 0.91                     |
| Lossless    | ~Nyquist      | ≥ 0.92                   |

## Signal Processing Pipeline

1. Open file with AVAudioFile (native — supports MP3, FLAC, WAV, AAC, AIFF, ALAC).
2. For tracks longer than 60 s, seek to the 20% mark before reading to skip silent intros.
3. Read up to 30 seconds of mono Float32 PCM.
4. Use 1-second windows (`windowLength = sampleRate`).
5. For each window:
   - Apply Hann window via `vDSP_hann_window`.
   - Pack as split-complex and run `vDSP.FFT` (real FFT via half-complex trick).
   - Compute magnitudes with `vDSP_zvabs`.
6. Accumulate magnitudes across all windows, then average.
7. Convert averaged magnitudes to log10 scale.
8. Smooth with a moving average (`window = max(3, fftLength / 100)`).
9. Estimate spectral cutoff index with gradient-based refinement (see below).

## Cutoff Detection

Codec-specific `thresholdDropDB` (log₁₀ units):

- MP3: `1.55`
- AAC: `1.40`
- Opus: `1.25`
- Lossless container: `1.55` (same as MP3 — we must detect MP3-like shelves inside FLAC/WAV)
- Generic: `1.50`

`estimateCutoffIndex` operates in two stages:

1. **Primary**: find the last frequency bin where `spectrum ≥ peak − thresholdDrop`.
   This is the outer boundary of where meaningful energy exists.

2. **Gradient refinement**: within a ±12.5% search window around the primary estimate,
   find the bin with the steepest local drop (computed over a 2%-of-spectrum gradient step).
   A genuine MP3 low-pass shelf produces a sharp, localized drop; a gradual roll-off from
   natural content does not. The gradient-derived knee is used only when the local drop
   exceeds `0.5 × thresholdDrop`.

## Bitrate Class Mapping

Cutoff frequency (kHz) → bitrate bucket, by codec:

- **MP3**: `≤11 → 64`, `12-14 → 128`, `15-16 → 160`, `17-18 → 192`, `19 → 224`, `20-21 → 320`
- **AAC**: `≤13 → 96`, `14-17 → 128`, `18-20 → 192`, `21-22 → 256`
- **Opus**: `≤11 → 96`, `12-16 → 128`, `17-20 → 192`

### Lossless Container Logic (FLAC / WAV / AIFF / ALAC)

This is the primary detection path for "fake lossless" files:

```
cutoffRatio = cutoffHz / nyquistHz

if cutoffRatio ≥ 0.92:
    → "lossless"  (spectrum extends to near Nyquist — content is genuinely lossless)
else:
    → apply MP3 bucket mapping to cutoffKHz
    → status = "Fake lossless — upconverted from ~X kbps"
```

A 320 kbps MP3 upconverted to FLAC produces cutoffRatio ≈ 0.91, safely below the 0.92
threshold. Genuine lossless audio at 44.1 kHz Nyquist = 22.05 kHz typically reaches
cutoffRatio ≥ 0.97 for most music content.

## Confidence Model

```
evidenceConfidence =
  clamp(0.05
        + 0.38 × dropScore
        + 0.30 × stability
        + 0.20 × suppressionScore
        + 0.07 × sampleSupport)

confidence =
  clamp(0.70 × evidenceConfidence + 0.30 × classificationScore)
```

Post-adjustments:
- Penalty when both `dropScore < 0.03` and `stability < 0.10` (multiply × 0.45)
- Penalty when `suppressionScore < 0.20` (multiply × 0.75)
- Penalty for high-bitrate labels with weak evidence (multiply × 0.60)
- Penalty when cutoff is nearly at Nyquist edge (`cutoffRatio > 0.995`, multiply × 0.90)
- Cap `"unknown"` outputs at 55%
- Cap uncertain lossless (`cutoffRatio < 0.95`) at 70%
- Cap fake-lossless detections at 85% — we know the content is lossy but cannot recover
  the exact original encoding parameters from the waveform alone

## Spectrogram Visual Guide

On the spectrogram, a fake lossless file shows a horizontal "wall" — a sharp, flat line
where all energy suddenly cuts off below Nyquist. Genuine lossless content extends with
diminishing energy all the way to the top of the display (Nyquist frequency).

| What you see                          | Interpretation                        |
|---------------------------------------|---------------------------------------|
| Sharp horizontal cutoff below Nyquist | Upconverted from lossy (fake)         |
| Energy gradually fading to Nyquist    | Genuine lossless or very high bitrate |
| Cutoff at ~16 kHz                     | Upconverted from ~128 kbps MP3        |
| Cutoff at ~20 kHz                     | Upconverted from ~320 kbps MP3        |
