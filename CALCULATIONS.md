# Bitrate Calculation and Confidence Calibration

## Goal

Determine whether an audio file's claimed quality is genuine or whether it has been upconverted from a lower-quality lossy source (e.g. a 128 kbps MP3 re-encoded as 320 kbps or FLAC). Detection is based entirely on native spectral signal analysis — no dependency on the output of other tools.

---

## Core Physics

All common lossy codecs (MP3, AAC, Opus) apply a low-pass filter during encoding whose cutoff frequency is determined by the target bitrate. This "spectral shelf" is a permanent artefact baked into the decoded PCM — re-encoding at a higher bitrate or into a lossless container cannot restore the removed high-frequency content.

### MP3 (LAME) Cutoff Reference — 44.1 kHz

| Bitrate | Approx. cutoff | Cutoff ratio | Hz range |
|---------|---------------|--------------|----------|
| 32 kbps | ~4 kHz | 0.18 | 3500–4500 Hz |
| 64 kbps | ~11 kHz | 0.50 | 10500–11500 Hz |
| 96 kbps | ~14 kHz | 0.63 | 13500–14500 Hz |
| 128 kbps | ~16 kHz | 0.73 | 15500–16500 Hz |
| 160 kbps | ~17.5 kHz | 0.79 | 17000–18000 Hz |
| 192 kbps | ~19 kHz | 0.86 | 18500–19500 Hz |
| 224 kbps | ~19.5 kHz | 0.88 | 19200–19800 Hz |
| 256 kbps | ~20 kHz | 0.91 | 19800–20200 Hz |
| 320 kbps | ~20.25 kHz | 0.92 | 20000–20500 Hz |
| Lossless | ~Nyquist | ≥ 0.96 | — |

These ranges are treated as **absolute decoded bandwidths**. They are not scaled with the output sample rate: a 16 kHz shelf remains evidence at 16 kHz when a lower-rate source has been transcoded into a 44.1, 48, or 96 kHz file. The tables are provisional and still require encoder- and corpus-based calibration.

### AAC-LC Cutoff Reference — 44.1 kHz

| Bitrate | Approx. cutoff | Hz range |
|---------|---------------|----------|
| 64 kbps | ~13 kHz | 12500–13500 Hz |
| 96 kbps | ~15 kHz | 14500–15500 Hz |
| 128 kbps | ~16 kHz | 15500–17000 Hz |
| 160 kbps | ~17.5 kHz | 17000–18000 Hz |
| 192 kbps | ~19 kHz | 18500–19500 Hz |
| 256 kbps | ~20 kHz | 19800–20500 Hz |

### Opus Cutoff Reference — 44.1 kHz

| Bitrate | Approx. cutoff | Hz range |
|---------|---------------|----------|
| 64 kbps | ~11 kHz | 10000–12000 Hz |
| 96 kbps | ~13 kHz | 12000–14000 Hz |
| 128 kbps | ~15.5 kHz | 14000–17000 Hz |
| 160 kbps | ~18 kHz | 17000–19000 Hz |
| 192 kbps | ~19.5 kHz | 19000–20500 Hz |

---

## Signal Processing Pipeline

### 1. Sample Loading

```
frameBudget = min(file.length, sampleRate × 30)

if file.length ≤ frameBudget:
    regions = [the complete file]
else:
    regions = 5 evenly distributed ranges whose combined length is frameBudget

for each region:
    seek to region.start
    decode every channel as PCM
    append each channel to its analysis buffer
    record the appended range as a region boundary
```

Region boundaries are retained so an FFT window can never bridge two non-contiguous parts of the source. Analysing channels separately in the power domain preserves content that appears in only one channel and avoids phase cancellation from a premature mono mix.

### 2. Welch's Method — Power Spectral Density

```
fftLength = 8192
hopLength = fftLength × 0.50    // 50% overlap
freqBins  = fftLength / 2       // 4096 bins
candidateStarts = every valid hop-aligned start within each sampled region
segmentStarts   = at most 200 starts selected evenly across candidateStarts
transformCount  = 0

for each start in segmentStarts:
  for each decoded channel:
    windowed[i] = channel[start + i] × hannWindow[i]   for i in [0, fftLength)

    // Real FFT: reinterpret float buffer as complex pairs
    // windowed[0,1] → complex[0].re, complex[0].im  etc.
    vDSP_ctoz(windowed as DSPComplex*, stride=2, &split, stride=1, freqBins)
    vDSP.fft.forward(split)
    vDSP_zvabs(split, &magnitudes)                      // |FFT[k]|

    power[k] = magnitudes[k]²                          for k in [0, freqBins)
    averagedPower += power
    transformCount += 1

averagedPower /= transformCount

spectrumDb[k] = 10 × log₁₀(max(averagedPower[k], 1e-24))
smoothedDb    = movingAverage(spectrumDb, window = max(3, freqBins / 80))
```

**Why power averaging?** Averaging squared magnitudes (power) is mathematically correct (Welch's method). Averaging linear magnitudes before log conversion biases the estimate, as `E[log(x)] ≠ log(E[x])`.

**Why 8192 FFT?** Gives ~5.4 Hz/bin frequency resolution at 44.1 kHz — sufficient to distinguish adjacent bitrate tiers (the narrowest gap between tiers is ~300 Hz at 224/256 kbps). Using sampleRate as FFT length (previous approach) wasted computation without improving resolution.

---

## Multi-Method Cutoff Detection

Three independent methods are run in parallel, then fused by taking the **median**.

### Method A: Gradient (Steepest Spectral Descent)

```
step = max(4, freqBins / 200)      // ~0.5% of spectrum per derivative step

steepestDrop = 0
kneeIndex = 0

for i in [freqBins/20, freqBins × 19/20):   // search 5%–95% of spectrum
    drop = smoothedDb[i] - smoothedDb[min(i + step, freqBins - 1)]
    if drop > steepestDrop:
        steepestDrop = drop
        kneeIndex = i

if steepestDrop < 3.0 dB:
    cutoffA = (freqBins - 1) × frequencyResolution   // no clear shelf → near Nyquist
else:
    cutoffA = kneeIndex × frequencyResolution
```

The 3 dB minimum drop requirement prevents gradual natural high-frequency roll-off from being mistaken for a codec shelf.

### Method B: Cumulative Energy Ratio

```
cumulative[i] = Σ averagedPower[0..i]
totalEnergy   = cumulative[freqBins - 1]

cutoffB = first k where cumulative[k] ≥ 0.995 × totalEnergy
cutoffB = cutoffB × frequencyResolution
```

For lossy audio, 99.5% of energy lies below the shelf. For genuine lossless content, 99.5% energy extends close to Nyquist. The 0.995 threshold was chosen to sit comfortably between the two cases.

### Method C: Noise Floor Scan

```
noiseSlice = smoothedDb[freqBins × 0.95 .. freqBins]
noiseFloor = mean(noiseSlice)           // estimate noise from top 5% of bins
margin     = 10.0 dB
bandWidth  = max(4, freqBins / 50)      // ~500 Hz per band

scan from top downward in bands of bandWidth:
    bandMean = mean(smoothedDb[bandStart .. bandEnd])
    if bandMean > noiseFloor + margin:
        cutoffC = bandEnd × frequencyResolution
        break

if no band rises above the top-band reference:
    cutoffC = frequency of the final bin   // no distinct shelf; bandwidth reaches Nyquist
```

### Fusion

```
sortedCutoffs = sort([cutoffA, cutoffB, cutoffC])
fusedCutoffHz = sortedCutoffs[1]                            // median

cutoffSpread     = sortedCutoffs[2] - sortedCutoffs[0]      // Hz
meanDeviation    = mean(abs(cutoff - fusedCutoffHz))         // robust around median
cutoffAgreement  = 1 - normalized(meanDeviation, 0, 2000)   // 0..1
cutoffRatio      = fusedCutoffHz / nyquistHz
```

High `cutoffAgreement` is strong evidence for a well-defined spectral shelf. Agreement is centred on the median so one outlying method cannot erase agreement between the other two; full spread remains available as a diagnostic.

The analyser retains `cutoffA`, `cutoffB`, `cutoffC`, the fused cutoff, spread, mean deviation, and agreement as `CutoffEvidence`. These values flow into `AnalysisFeatures` and the training CSV so disagreements can be examined during corpus calibration instead of being lost after fusion.

---

## Shelf Sharpness

Measures how abruptly the spectrum drops at the fused cutoff.

```
fusedIndex = round(fusedCutoffHz / frequencyResolution)
width      = max(4, freqBins / 100)   // ~50 Hz wide measurement window

preBand  = smoothedDb[fusedIndex - width .. fusedIndex]
postBand = smoothedDb[fusedIndex + 2 .. fusedIndex + 2 + width]

preMean  = mean(preBand)
postMean = mean(postBand)
drop     = max(0, preMean - postMean)       // dB

shelfSharpness = normalized(drop, minValue=0, maxValue=20)   // 0..1
```

A genuine MP3 shelf drops 15–30 dB across a few hundred Hz. Natural high-frequency roll-off drops gradually over several kHz.

---

## Sub-Band Energy Analysis

Divides the spectrum into 8 logarithmically-spaced bands (at 44.1 kHz) and computes energy distributions.

| Band | Frequency range | Label |
|------|----------------|-------|
| 1 | 20–200 Hz | sub-bass |
| 2 | 200–500 Hz | bass |
| 3 | 500–1500 Hz | low-mid |
| 4 | 1500–4000 Hz | mid |
| 5 | 4000–8000 Hz | upper-mid |
| 6 | 8000–12000 Hz | presence |
| 7 | 12000–16000 Hz | brilliance |
| 8 | 16000–Nyquist Hz | air |

```
for each band b:
    loIdx = round(band.lo / binHz)
    hiIdx = round(band.hi / binHz)
    bandEnergy[b] = Σ averagedPower[loIdx..hiIdx]

// High-band energy ratio
lowEnergy         = Σ bandEnergy[0..5]      // bands 1–6
highEnergy        = Σ bandEnergy[6..7]      // bands 7–8
highBandEnergyRatio = highEnergy / max(lowEnergy, 1e-12)
```

Typical values:
- Genuine lossless: `highBandEnergyRatio > 0.01`
- 320 kbps MP3: `highBandEnergyRatio ≈ 0.005–0.01`
- 128 kbps MP3: `highBandEnergyRatio < 0.001`

### Air Band Spectral Flatness (Wiener Entropy)

Measures how noise-like the content is above 16 kHz. Genuine high-frequency audio content has higher flatness; synthesised or near-zero energy content has near-zero flatness.

```
airSlice = averagedPower[airLo .. freqBins]

geometricMean  = exp(mean(log(airSlice)))
arithmeticMean = mean(airSlice)

airBandFlatness = geometricMean / max(arithmeticMean, 1e-24)   // 0..1
```

---

## Lossless Discrimination

Replaces the previous single `cutoffRatio ≥ 0.92` threshold with a weighted multi-feature score.

```
losslessScore =
    0.25 × normalized(cutoffRatio, 0.90, 1.00)
  + 0.20 × (1 − shelfSharpness)
  + 0.20 × normalized(highBandEnergyRatio, 0.001, 0.02)
  + 0.15 × normalized(airBandFlatness, 0.01, 0.50)
  + 0.10 × (1 − cutoffAgreement)
  + 0.10 × (1 − segmentStability)

if losslessScore > 0.65  →  classify as lossless
else                     →  classify as upconverted lossy (use Hz-precision bucket mapping)
```

**Why the additional features?** A 320 kbps MP3 has `cutoffRatio ≈ 0.91–0.92`, dangerously close to the old 0.92 threshold. It also has low `highBandEnergyRatio`, high `shelfSharpness`, and high `cutoffAgreement`. Genuine lossless content may occasionally roll off naturally below 0.95 (especially in bass-heavy or recorded-in-poor-room material) but will score high on flatness and low on sharpness. The combined score separates these cases cleanly.

---

## Hz-Precision Bitrate Classification

Classification uses distance-weighted scoring over absolute Hz threshold ranges. `sampleRate` is retained in the current API but deliberately does not rescale the ranges.

```
func classifyContinuous(cutoffHz, sampleRate):
    if cutoffHz is not finite or cutoffHz ≤ 0:
        return ("unknown", 0)

    nearest = bucket whose centre has the smallest absolute distance from cutoffHz
    spread  = max(100 Hz, (nearest.hi - nearest.lo) × 0.55)
    score   = exp(-|cutoffHz - nearest.center| / spread)
    score   = clamp(score, 0.30, 0.99)

    return (nearest.label, score)
```

The named tiers form the product's granular bitrate vocabulary. A valid cutoff always receives the nearest tier, while distance continuously reduces confidence; falling into a narrow gap between provisional ranges no longer erases the estimate. The bucket centres and ranges remain provisional until validated against independently generated, encoder-diverse material.

---

## Full-Stream Technical Evidence

An opt-in full-stream pass now exposes raw evidence for technical-quality evaluation. It is deliberately separate from the quick spectral result path until batch cancellation, bounded concurrency, and defect thresholds are ready.

```
chunkFrames = 32768

while decoded frames remain:
    decode one PCM chunk for every channel
    decodedFrames += chunk.frameLength
    peakAmplitude = max(peakAmplitude, max(abs(samples)))
    clippedSamples += count(abs(sample) ≥ 0.999)

    framePeak = maximum absolute sample across channels for each frame
    longestSilentFrames = longest consecutive run where framePeak < 0.001  // below -60 dBFS

clippingRatio        = clippedSamples / (decodedFrames × channelCount)
longestSilence       = longestSilentFrames / sampleRate
durationShortfall    = max(0, declaredFrames - decodedFrames) / sampleRate
durationShortfallPct = max(0, declaredFrames - decodedFrames) / declaredFrames
```

A full-read error is technical defect evidence. A duration shortfall must exceed both one second and 0.5% of the declared frames to avoid normal codec padding. Clipping and silence are currently retained as measurements rather than converted directly into a defect verdict: both are programme-dependent, and the available composite labels do not reveal which user-configurable check produced them.

---

## Per-Segment Stability

Stability measures how consistently the cutoff is detected across sampled windows and decoded channels, using the gradient method for each channel/window transform.

```
for each sampled window and channel:
    segmentCutoffRatios.append(gradientCutoff(segment) / nyquistHz)

mean = average(segmentCutoffRatios)
variance = average((ratio - mean)² for ratio in segmentCutoffRatios)
stdDev = sqrt(variance)

segmentStability = clamp(1 - (stdDev / 0.12), 0, 1)
```

A codec shelf at a fixed frequency → low stdDev → high stability. Natural content without a shelf → variable per-segment cutoffs → low stability.

---

## Confidence Model

```
highBandSuppression = 1 - normalized(highBandEnergyRatio, 0.001, 0.10)
sampleSupport       = normalized(sampledWindowCount, 6, 60)

evidenceConfidence =
    clamp(
        0.05
      + 0.25 × shelfSharpness
      + 0.20 × segmentStability
      + 0.15 × highBandSuppression
      + 0.15 × cutoffAgreement
      + 0.10 × normalized(airBandFlatness, 0, 0.30)
      + 0.05 × sampleSupport
      + 0.05 × shelfSharpness     // double-weighted as primary discriminator
    )

if classification == lossless:
    bandwidthSupport = normalized(cutoffRatio, 0.92, 1.00)
    highBandPresence  = 1 - highBandSuppression
    confidence =
        0.55 × classificationScore
      + 0.25 × bandwidthSupport
      + 0.10 × highBandPresence
      + 0.10 × sampleSupport
else:
    confidence = clamp(0.65 × evidenceConfidence + 0.35 × classificationScore)
```

Lossless confidence uses positive authenticity evidence. Penalising low shelf sharpness, unstable per-window cutoffs, or low high-band suppression would invert their meaning for a genuine full-band lossless signal.

### Post-Adjustment Penalties

| Condition | Multiplier |
|-----------|-----------|
| `shelfSharpness < 0.05` AND `segmentStability < 0.10` | × 0.45 |
| `highBandSuppression < 0.20` | × 0.75 |
| `cutoffAgreement < 0.30` (three methods disagree strongly) | × 0.60 |
| High-bitrate label (192/224/256/320) AND `evidenceConfidence < 0.30` | × 0.60 |
| `cutoffRatio > 0.995` (ambiguous near-Nyquist) | × 0.90 |

### Output Caps

| Condition | Cap |
|-----------|-----|
| Label = "unknown" | 55% |
| Label = "lossless" AND `cutoffRatio < 0.95` | 70% |
| Fake lossless (lossless container, lossy content) | 85% |

---

## Verdict Classification

The estimate is converted into an explicit `AnalysisVerdict` rather than relying on a display string as the result model:

| Verdict | Current trigger |
|---------|-----------------|
| `likelyAuthentic` | Lossless profile, inferred lossless, cutoff ratio at least 0.95, and sufficient model confidence |
| `likelyTranscoded` | Lossless profile with a lossy source-bitrate estimate |
| `lossyAsExpected` | Known lossy profile; the source-bitrate estimate is omitted when model confidence is below 0.30 |
| `inconclusive` | Raw model confidence below 0.30 or a borderline lossless result |
| `technicallyDefective` | Reserved for decoded integrity and defect evidence introduced in a later analysis stage |

The enum owns the current user-facing labels, while the underlying class and associated source estimate remain independently testable.

---

## Spectrogram Visual Guide

On the spectrogram, a fake lossless file shows a horizontal "wall" — a sharp, flat line where all energy suddenly cuts off below Nyquist. Genuine lossless content extends with diminishing energy all the way to the top of the display (Nyquist frequency).

| What you see | Interpretation |
|---|---|
| Sharp horizontal cutoff below Nyquist | Upconverted from lossy (fake) |
| Energy gradually fading to Nyquist | Genuine lossless or very high bitrate |
| Cutoff at ~16 kHz | Upconverted from ~128 kbps MP3 |
| Cutoff at ~20 kHz | Upconverted from ~320 kbps MP3 |
| Three detection methods agree closely | High confidence shelf present |
| Methods disagree by >2 kHz | Ambiguous — likely no clear shelf or borderline |

---

## Known Limitations

- **HE-AAC / SBR**: Spectral Band Replication synthesises high-frequency energy from low-frequency content. This creates artificial content above the actual coding cutoff, causing the energy ratio method to over-estimate the cutoff. Detected as high-bitrate AAC when it may be low-bitrate HE-AAC. Future work: cross-correlation of low/high band envelopes to detect SBR symmetry.
- **Very short files**: Files under ~8 seconds yield fewer than 6 Welch segments, reducing stability and suppression evidence. Confidence is appropriately reduced via `sampleSupport`.
- **High-sample-rate files**: Absolute source-bandwidth mapping avoids the previous proportional-scaling error, but encoder behaviour and genuinely ultrasonic content at uncommon sample rates have not yet been empirically validated.
- **VBR MP3**: Variable bitrate files show per-segment cutoff variation. The stability penalty reduces confidence appropriately, but the inferred bitrate reflects the average rather than the minimum.
- **Encoder-dependent bitrate tiers**: A runtime-generated Apple AAC encode labelled 128 kbps retained a cutoff around 18.7 kHz and currently maps to the provisional 192 kbps AAC bucket. Cutoff frequency alone is therefore insufficient for reliable source-bitrate claims across encoders.
- **Native corpus coverage**: The deterministic runtime corpus currently covers AAC, ALAC, FLAC, and AAC-to-ALAC transcoding. The built-in MP3 and Opus encoder paths advertised by `afconvert` fail on the current host, so those codecs still require independently generated reference fixtures.
