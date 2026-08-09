# Bit Check — Development Plan

## Product Direction

Bit Check is a native macOS application for determining whether an audio file's claimed quality is credible, whether it has been transcoded or upconverted, and whether the file has technical defects that deserve review. The Xcode target and Swift module remain `BitCheck`.

The long-term ambition is to deliver broad, advanced audio-quality analysis within a focused, polished Mac experience. Spectral cutoff detection remains an important signal, but it is not the final product boundary. Bit Check should combine spectral, codec, container, temporal, integrity, and signal-quality evidence to reach the strongest defensible result.

The work is deliberately staged. Repository accuracy, testability, correctness, performance, and core macOS interaction come before expanding the detector.

---

## Product Principles

- **Advanced, multi-signal analysis**: do not limit the product to a single spectral threshold or heuristic.
- **Evidence-backed results**: expose the evidence behind a verdict and calibrate confidence against labelled material.
- **Defensive classification**: retain an inconclusive state where evidence conflicts, without making that the limit of the product's ambition.
- **Native Mac workflow**: fast drag and drop, keyboard support, clear batch results, restrained hierarchy, and useful Finder integration.
- **Safe by default**: analysis is read-only. Any later rename, move, or delete capability must be explicit and recoverable.
- **Local processing**: keep audio analysis on-device with no external service or package dependency.
- **Scalable batches**: library-sized imports must remain responsive, cancellable, and memory-bounded.

---

## Current Implemented Baseline

### Application

- Native SwiftUI macOS application with App Sandbox enabled
- File and folder selection plus drag-and-drop import
- Recursive discovery of supported audio files
- Native toolbar and decision-focused sortable batch-results table
- Finder reveal action
- Training CSV export
- Separate spectrogram windows keyed by file path

### Analysis

- Native decoding through `AVAudioFile`
- `Accelerate`/vDSP real FFT processing
- 8192-sample Hann windows with 50% overlap
- Power-spectrum averaging based on Welch's method
- Gradient, cumulative-energy, and noise-floor cutoff estimates fused by median
- Shelf sharpness, segment stability, high-band energy, spectral flatness, and method-agreement features
- Provisional codec-specific cutoff-to-bitrate mappings
- Provisional weighted confidence and lossless discrimination models
- Encoded codec inspection separated from filename container extension
- Five-region sampling for long tracks and all-channel power-domain analysis

Current codec cutoff tables, formulas, and thresholds are maintained in `CALCULATIONS.md`. They remain subject to corpus validation and replacement by codec-appropriate bandwidth models. The implementation treats these as absolute decoded bandwidths rather than scaling them with output sample rate.

### Spectrogram

- Logarithmic and linear frequency views
- Spek-inspired colour scale and dB legend
- Detected-cutoff overlay
- Optional grid and dark background

### Verification status

- The application builds successfully with the current Xcode toolchain.
- The focused unit suite executes successfully: 6 tests covering the new foundation contracts.
- The unit-test target now contains deterministic coverage for codec routing, absolute bandwidth mapping, independent training labels, distributed window selection, all-channel analysis, and stable result identity. The UI-test target remains template-only.
- No committed labelled audio corpus currently validates thresholds, feature weights, confidence percentages, or false-positive rates.
- The current detector is therefore an implemented experimental baseline, not a calibrated final engine.

---

## Known Issues to Resolve

### Correctness

- Lossless-container failures are mapped through MP3 bitrate buckets even when the earlier codec is unknown.
- Reported bitrate, encoded bitrate, PCM data rate, bit depth, sample rate, channel layout, and duration are not yet represented as distinct concepts throughout the result model.
- Heuristic scores are displayed as confidence percentages without empirical calibration.
- Codec routing recognises the encoded stream independently from the container, but still groups codec families broadly and does not expose profiles such as AAC-LC versus HE-AAC.
- Channel and window disagreement contributes to stability but is not yet preserved as explicit per-channel evidence.

### Performance and resilience

- Folder discovery and metadata inspection can block the main actor.
- Batch analysis is sequential and has no cancellation path.
- Result arrays are repeatedly replaced during a run, although file-based result identity is now stable.
- Spectrogram rendering reads the complete file and creates two duration-proportional images, causing unbounded memory growth.
- File corruption detection is limited to whether native decoding throws an error.

### Product and project consistency

- The app icon set has no artwork.
- The table has been simplified, but a proper result inspector and adaptive batch summary are still missing.

---

## Staged Roadmap

### Stage 0 — Repository and product cleanup

- [x] Present the product as **Bit Check** while retaining `BitCheck` for the target, module, bundle identifier, and source symbols
- [x] Set and document macOS 14 as the compatibility floor
- [x] Remove stale legacy-script references from public documentation
- [x] Stop bundling development-only Markdown as an application resource
- [x] Remove the apparent self-reference from the Xcode project
- [ ] Add complete application icon artwork
- [x] Give results stable file-based identity
- [x] Align `README.md`, `PLAN.md`, and `CALCULATIONS.md` with what is actually implemented

### Stage 1 — Validation infrastructure

- [x] Expose narrow testable analysis seams without moving signal work onto the main actor
- [x] Replace the template unit test with deterministic coverage for codec routing, mapping, labels, sampling, all-channel analysis, and result identity
- [ ] Add focused cutoff-fusion, metadata extraction, confidence, and verdict tests
- [ ] Build generated fixtures across MP3, AAC-LC, HE-AAC, Opus, FLAC, ALAC, WAV, and AIFF
- [ ] Cover CBR, ABR, VBR, encoder-defined low-pass settings, mono/stereo, bit depth, and common sample rates
- [ ] Create independently labelled genuine-lossless and transcode material from known sources
- [ ] Keep training and evaluation sets separate
- [ ] Record precision, recall, confusion matrices, and false-positive rates by codec and source class
- [ ] Derive confidence calibration from held-out results rather than hand-selected percentages

### Stage 2 — Correct analysis foundations

- [x] Identify codec and container separately using stream metadata rather than extensions
- [ ] Represent claimed bitrate, average encoded bitrate, PCM data rate, sample rate, bit depth, channels, and duration explicitly
- [x] Replace proportional sample-rate scaling with provisional absolute bandwidth models
- [x] Analyse every decoded channel in the power domain without phase cancellation
- [x] Sample multiple regions across the complete track
- [ ] Introduce explicit result classes such as likely authentic, likely transcoded, lossy as expected, technically defective, and inconclusive
- [ ] Separate detected bandwidth from estimated source bitrate and source-codec hypotheses
- [ ] Preserve per-method evidence so every result can explain its conclusion
- [x] Correct the training-label contract so only independent labels are trainable

### Stage 3 — Batch performance and spectrogram resilience

- [ ] Move file discovery and metadata reads off the main actor
- [ ] Add bounded task-group concurrency appropriate to Apple silicon
- [ ] Add progress, cancellation, and per-file failure isolation
- [ ] Update individual results without replacing stable collection identity
- [ ] Bound spectrogram width and aggregate FFT frames into display columns
- [ ] Avoid retaining duplicate full-resolution intensity and pixel buffers
- [ ] Benchmark large folders, long recordings, and high-sample-rate material

### Stage 4 — Native macOS workflow

- [x] Move Add Files, Add Folder, Clear, and Run into a native toolbar; cancellation remains pending
- [x] Move training controls into a secondary toolbar menu
- [x] Simplify the main table to the most decision-relevant columns
- [ ] Add a detail inspector for codec metadata, evidence, confidence, and spectrogram access
- [ ] Add verdict filters and a compact batch summary
- [ ] Add File and View menu commands with keyboard shortcuts
- [ ] Support double-click and Space for fast inspection
- [ ] Add accessible non-colour verdict labels and accessible spectrogram summaries
- [ ] Preserve a read-only workflow while considering later Finder tags and export actions

### Stage 5 — Advanced multi-signal detection

- [ ] Detect HE-AAC/SBR and other bandwidth-extension patterns
- [ ] Detect resampling and sample-rate upconversion evidence
- [ ] Model encoder- and mode-specific artefacts beyond a single cutoff frequency
- [ ] Add temporal cutoff and bandwidth-distribution analysis across complete tracks
- [ ] Detect clipping and sustained inter-sample peak risk where practical
- [ ] Validate declared duration against decoded frame duration
- [ ] Detect truncated, malformed, unreadable, and internally inconsistent streams
- [ ] Investigate codec residue, quantisation-noise, low-pass shape, pre-echo, and spectral-texture features
- [ ] Combine independent feature families through a calibrated classifier when the corpus supports it
- [ ] Add optional playback with navigation to suspicious regions
- [ ] Expand format support where native macOS decoding permits reliable analysis
- [ ] Evaluate explicit rename, move, copy, Finder-tag, and delete workflows only after safe result handling is mature

---

## Success Criteria

Bit Check is ready to make strong automatic claims when:

- labelled-corpus results demonstrate repeatable accuracy across codecs, modes, sample rates, and musical styles;
- false-positive rates are documented and acceptable for the displayed verdict strength;
- confidence values are calibrated against observed outcomes;
- high-sample-rate, ALAC/M4A, multichannel, VBR, SBR, naturally bandwidth-limited, and historical recordings have dedicated coverage;
- large batches remain responsive and cancellable;
- spectrogram rendering remains memory-bounded for long files; and
- users can understand why a file was flagged without reading implementation details.

---

## Repository Structure

```text
BitCheck.xcodeproj/       Xcode project
BitCheck/
  BitCheckApp.swift       Application entry point
  ContentView.swift       Interface, analysis engine, and spectrogram renderer
  Assets.xcassets/
BitCheckTests/            Unit-test target with deterministic foundation coverage
BitCheckUITests/          UI-test target; meaningful coverage pending
README.md                 User-facing overview and usage
CALCULATIONS.md           Current algorithm specification
PLAN.md                   Product direction, current state, and roadmap
```

---

## Building

```bash
xcodebuild -scheme BitCheck -destination 'platform=macOS' build | xcbeautify
```
