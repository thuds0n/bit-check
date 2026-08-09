# Bit Check

Bit Check is a native macOS application that looks for evidence that an audio file was transcoded or upconverted from a lower-quality source.

It inspects the encoded stream metadata separately from the file container, samples audio throughout the track, and analyses the decoded spectrum with native `AVFoundation` and `Accelerate` APIs. Processing stays on the Mac and does not require third-party tools or services.

The current detector is an experimental baseline. Its cutoff and confidence models still need calibration against an independently labelled audio corpus before they should be treated as definitive.

## Usage

Open `BitCheck.xcodeproj` in Xcode and run, or build from the command line:

```bash
xcodebuild -scheme BitCheck -destination 'platform=macOS' build | xcbeautify
```

**Requires macOS 14+.**

Once running:

- Drag audio files or folders onto the drop area, or use **Add Files** and **Add Folder** in the toolbar.
- Select **Run** to analyse the queue.
- Review the estimated source, detected cutoff, confidence, and verdict.
- Control-click a result to reveal the file in Finder or open its spectrogram.

Supported formats: MP3, FLAC, WAV, AAC (M4A), AIFF, ALAC, OGG, Opus

### Reading the Results

The table separates the detected spectral cutoff from the estimated source bitrate. A premature, stable cutoff in a lossless container is evidence of an earlier lossy source; a spectrum extending towards Nyquist without a clear shelf supports a lossless interpretation. **Inconclusive** means the available signals did not agree strongly enough for the current model.

Colour supplements the text verdict: green indicates agreement, red indicates a mismatch, and orange indicates that the estimate is higher than the reported value.

### Spectrogram Viewer

The spectrogram displays time on the horizontal axis and frequency on the vertical axis. A transcoded file often shows a horizontal shelf where an earlier encoder removed high-frequency content. Naturally bandwidth-limited recordings can look similar, so the app combines this view with several other spectral measurements.

## Algorithm

See `CALCULATIONS.md` for the full specification.

Short version:

1. Read up to 30 seconds of decoded PCM from one region for short files or five distributed regions for long files.
2. Analyse every decoded channel with 8192-sample Hann windows and 50% overlap.
3. Average squared FFT magnitudes in the power domain using Welch's method.
4. Fuse gradient, cumulative-energy, and noise-floor cutoff estimates.
5. Combine shelf sharpness, temporal and channel stability, high-band energy, spectral flatness, method agreement, and sample support.
6. Map the absolute detected bandwidth through provisional codec-specific source-bitrate ranges.

See `CALCULATIONS.md` for the current formulas, cutoff tables, confidence model, and limitations.
