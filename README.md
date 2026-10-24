# MPC Converter

Batch-convert a whole sample library to clean 44.1 kHz WAV files (16-bit, 24-bit or both) for MPCs, SP-404s, other hardware samplers, DAWs or pack distribution.

Native macOS app (SwiftUI + Core Audio). No third-party code, no ffmpeg.

## Build

Requires macOS 13+ and Xcode (or the Command Line Tools: `xcode-select --install`).

```bash
cd MPCConverter
./build.sh               # → build/MPC Converter.app
./build.sh --universal   # Apple Silicon + Intel (needs full Xcode)
```

You can also open `Package.swift` in Xcode and press ⌘R.

The app is ad-hoc signed. That's fine on the Mac that built it. To give it to other people you'll need to sign it with a Developer ID and notarize it, or macOS Gatekeeper will block it.

## What it does

| | |
|---|---|
| **Input** | WAV, AIFF/AIFC, MP3, M4A/AAC/ALAC, FLAC, CAF. Hidden files and `._` AppleDouble files are skipped. |
| **Output** | WAV, 44.1 kHz, 16-bit / 24-bit / both. Mastering-quality sample-rate conversion (Core Audio). |
| **Header** | Plain 44-byte PCM header (format tag 1). No `bext`, `JUNK`, `LIST`, `cue`, `smpl` or `iXML` chunks. |
| **Folders** | Folder structure is kept: `Drums/Kicks/k1.mp3` becomes `Drums - 16-bit/Kicks/k1.wav` (and `Drums - 24-bit/…` when set to Both). |
| **Safety** | Never overwrites. Existing output folders get ` 2`, ` 3`… Files are written to a hidden `.partial` file first, then renamed. |
| **Undo** | Moves everything the last run created to the Trash. Undo still works after you quit and reopen the app. |
| **Dry Run** | Shows every source → output path, the source format, what will be resampled, lossy sources and renames. Writes nothing. |

### Settings

- **MPC Strict Mode**: metadata is always stripped, files with more than 2 channels are mixed down to stereo, and file names are limited to `A–Z a–z 0–9 space - _`.
- **Strip Metadata**: when this is off (and Strict is off), title, artist, album, comment, genre, year and copyright are carried over into a RIFF `LIST/INFO` chunk placed after the audio data.
- **Sanitize Filenames / Folder Names**: converts names to ASCII (`Café` becomes `Cafe`), removes emoji and control characters, replaces `/ \ : * ? " < > |`, and collapses repeated spaces and underscores. Name collisions get `_2`, `_3`…
- **Max Filename Length**: counted without `.wav`.
- **Save Mode**: Ask Each Time, Next to Source, or a Fixed Folder.
- **Worker Threads**: the number of files converted in parallel.
- **Dither 16-bit Output**: TPDF dither, used only when the 16-bit output actually loses resolution (lossy, float or 24-bit sources, resampled audio, mixdowns). A clean 16-bit/44.1 source comes out bit-identical.

### Rebranding

Edit `Branding` at the top of `Sources/MPCConverter/Theme.swift`. Change the bundle ID in `Resources/Info.plist`.

## Known limits / not yet verified

- **Not yet compiled or run.** It was written in an environment without Xcode. Expect a first build to possibly need small fixes.
- MP3 encoder delay/padding: Core Audio trims this for AAC/M4A. For MP3 it depends on the file's LAME/Xing header. Test a few one-shots for a tiny gap at the start.
- Files with more than 2 channels keep their channel count unless Strict Mode is on. They're written with the plain PCM header, which most hardware accepts but which is technically non-standard for multichannel.
- Each WAV is limited to 4 GB (a limit of the WAV format itself).
