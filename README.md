# BitCheck

Native macOS app that detects whether an audio file's claimed quality is genuine or upconverted from a lower-quality lossy source.

The problem: a 128 kbps MP3 re-encoded as "320 kbps" or FLAC will have the same file size and correct metadata as the quality it claims, but the audio content is degraded. 
The solution: BitCheck validates this from the frequency spectrum alone.

## How It Works

All lossy codecs (MP3, AAC, Opus) apply a low-pass filter whose cutoff frequency is set by the target bitrate. This spectral shelf is a permanent artefact and re-encoding at a higher bitrate or into a lossless container cannot restore the removed high-frequency content. BitCheck finds this shelf and maps it to the original encoding bitrate.

Detection is entirely native signal analysis using `AVFoundation` + `Accelerate`. No third-party tools required.

## Usage

Open `BitCheck.xcodeproj` in Xcode and run, or build from the command line:

```
xcodebuild -scheme BitCheck -destination 'platform=macOS' build
```

**Requires macOS 14+.**

Once running:
- Drag and drop audio files or folders onto the app
- Use **Choose Files** or **Choose Folder** for a file picker
- Click **Run Validation** — results appear in the table with reported vs. detected bitrate and confidence

Supported formats: MP3, FLAC, WAV, AAC (M4A), AIFF, ALAC, OGG, Opus

### Reading the Results

| Actual Bitrate | Meaning |
|----------------|---------|
| `lossless` | Spectrum extends to near Nyquist — content is genuinely lossless |
| `128 kbps` (on a FLAC) | Spectral shelf detected at ~16 kHz — file is upconverted from 128 kbps MP3 |
| `320 kbps` (on a FLAC) | Spectral shelf detected at ~20 kHz — file is upconverted from 320 kbps MP3 |

The **Analysis Status** column makes this explicit: `Fake lossless — upconverted from ~128 kbps`.

Row color indicates agreement between reported and detected bitrate: green = match, red = mismatch, orange = unknown.

### Spectrogram Viewer

Click any analysed file to open its spectrogram — frequency on the Y axis (0 to Nyquist), time on the X axis. A genuine lossless file shows energy fading smoothly toward Nyquist. An upconverted file shows a hard horizontal wall where the low-pass filter cut off.

## Algorithm

See `BITRATE_CALCULATION.md` for the full specification.

Short version:

1. Seek to the 20% mark of the track (avoids silent intros)
2. Read up to 30 s of mono PCM via `AVAudioFile`
3. Apply Hann window + FFT via `vDSP` for each 1-second segment
4. Average spectra, find the cutoff with a gradient-based shelf detection
5. For lossless containers (FLAC/WAV/AIFF): if `cutoffHz / nyquistHz < 0.92`, classify as upconverted

## Legacy CLI

The original Python tool is still present for reference:

```bash
# Requires: ffmpeg, python-scipy
./true-bitrate "my-file.flac"
```

This uses the same spectral cutoff principle but is a much simpler implementation derived from [FakeFLAC](http://www.maurits.vdschee.nl/fakeflac/) by Maurits van der Schee.
