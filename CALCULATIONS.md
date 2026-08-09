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
```

### Fusion

```
sortedCutoffs = sort([cutoffA, cutoffB, cutoffC])
fusedCutoffHz = sortedCutoffs[1]                            // median

cutoffSpread     = sortedCutoffs[2] - sortedCutoffs[0]      // Hz
cutoffAgreement  = 1 - normalized(cutoffSpread, 0, 2000)    // 0..1
cutoffRatio      = fusedCutoffHz / nyquistHz
```

High `cutoffAgreement` (all three methods agree) is strong evidence for a well-defined spectral shelf.

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
    for each bucket (lo, hi, center, label) in codecBuckets:
        spread = (hi - lo) × 0.55

        if lo ≤ cutoffHz ≤ hi:
            score = exp(-|cutoffHz - center| / spread)
            score = clamp(score, 0.30, 0.99)
        else if distance_to_range < spread × 2:
            score = exp(-|cutoffHz - center| / spread) × 0.80
        else:
            skip

    return (best matching label, best score)
    if no match: return ("unknown", 0.35)
```

The exponential distance score handles edge cases continuously rather than snapping every cutoff directly to a bucket. The bucket ranges themselves remain provisional until validated against independently labelled encodes.

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

confidence = clamp(0.65 × evidenceConfidence + 0.35 × classificationScore)
```

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
