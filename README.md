# Synology Codecs — HEVC/AAC for DSM 7

Drop-in replacement SPK packages that restore **HEVC, H.264, and AAC** codec support removed from Synology's Advanced Media Extensions (AME) starting with v4.0 in DSM 7.2.2.

## Why

Synology silently removed HEVC/AVC decoding and encoding from AME 4.0. The official Surveillance Video Extension only provides basic H.264. This project builds two SPK packages from scratch that bring full codec support back.

## Packages

| SPK file | Replaces | What it covers |
|----------|----------|----------------|
| `CodecPack-x86_64-99.0.0-0001.spk` | Advanced Media Extensions | Media Server, Synology Photos, Video Station, CLI transcoding |
| `SurveillanceVideoExtension-x86_64-99.0.0-0001.spk` | Surveillance Video Extension | Surveillance Station H.265 camera streams |

## How it works

**Static FFmpeg** — Each package ships [John Van Sickle's](https://johnvansickle.com/ffmpeg/) static FFmpeg build for amd64, which includes libx265, libx264, and AAC encoders/decoders out of the box.

**License library patch** — The build script downloads the official AME 3.1.0-3005 SPK, decrypts it (Synology uses an XChaCha20-Poly1305 encrypted archive format), extracts `libsynoame-license.so`, and patches five license-check functions to unconditionally return true:

| Function | File offset | Patch |
|----------|-------------|-------|
| `IsValidStatus` | `0x9144` | `mov eax, 1; ret` |
| `ValidateLicense` | `0x9234` | `mov eax, 1; ret` |
| `CheckLicense` | `0x9614` | `mov eax, 1; ret` |
| `CheckOfflineLicense` | `0x9804` | `mov eax, 1; ret` |
| `SLIsXA` | `0xbe74` | `mov eax, 1; ret` |

Each patch writes `B8 01 00 00 00 C3` immediately after the `endbr64` instruction at the function entry point. Both the original and patched checksums are verified during the build.

**Activation files** — Pre-filled `activation.conf` and `offline_license.json` are bundled and copied into place at install time.

## Requirements

**Target NAS:**
- Synology NAS with an **x86_64** CPU (Intel Celeron, Atom, Xeon, or AMD)
- **DSM 7.0** or later

**Build host:**
- `bash`, `curl`, `tar`, `xz`, `python3`
- Python packages: `pysodium`, `msgpack` (used to decrypt the Synology SPK archive)

```sh
pip3 install pysodium msgpack
```

## Build

```sh
git clone https://github.com/renaudallard/synology_codecs.git
cd synology_codecs
./build.sh
```

The script will:

1. Download AME 3.1.0-3005 from the Synology CDN
2. Decrypt the encrypted SPK and extract `libsynoame-license.so`
3. Apply the five binary patches (with MD5 verification before and after)
4. Download the latest static FFmpeg release for amd64
5. Package everything into two SPK files in `out/`

Downloads are cached in `build/cache/` so subsequent builds skip the download step.

## Install

1. Open **Package Center** on your NAS
2. **Uninstall** the official *Advanced Media Extensions* and *Surveillance Video Extension* if present
3. Click **Manual Install** and select `CodecPack-x86_64-99.0.0-0001.spk`
4. Repeat for `SurveillanceVideoExtension-x86_64-99.0.0-0001.spk`
5. If the installer cannot write activation files, it will print a one-line `sudo` command to run via SSH

## Verify

SSH into the NAS and check that HEVC is available:

```sh
# CodecPack — should show libx265
/var/packages/CodecPack/target/pack/bin/ffmpeg41 -encoders 2>/dev/null | grep hevc

# SVE — should show libx265
/var/packages/SurveillanceVideoExtension/target/bin/ffmpeg -encoders 2>/dev/null | grep hevc
```

Then test with your apps:
- **Media Server** — play an HEVC video via DLNA
- **Synology Photos** — open a HEVC video in the browser player
- **Surveillance Station** — add an H.265 camera stream

## Project structure

```
.
├── build.sh                        # Main build script
└── src/
    ├── codecpack/                   # CodecPack SPK sources
    │   ├── INFO                     # Package metadata
    │   ├── conf/
    │   │   ├── privilege            # Run-as config
    │   │   └── resource             # usr-local-linker paths
    │   ├── scripts/
    │   │   ├── postinst             # Copies activation files
    │   │   ├── start-stop-status    # Always reports running
    │   │   └── ...                  # Other lifecycle scripts (exit 0)
    │   └── package/
    │       ├── activation/          # activation.conf, offline_license.json
    │       ├── pack/bin/            # ffmpeg41, ffprobe (placed by build)
    │       ├── usr/bin/             # synoame-bin-check-license (stub)
    │       └── usr/lib/             # patched .so (placed by build)
    └── sve/                         # SurveillanceVideoExtension SPK sources
        ├── INFO
        ├── conf/
        │   ├── privilege
        │   └── resource
        ├── scripts/
        │   ├── start-stop-status
        │   └── ...
        └── package/
            └── bin/                 # ffmpeg, ffprobe (placed by build)
```

## Notes

- Package version `99.0.0` ensures Package Center treats it as newer than any official release
- The `start-stop-status` script always reports the package as running (there is no daemon)
- Both packages declare `run-as: package` privilege
- The SPK decryption keys are public knowledge, extracted from `libsynocodesign.so` by the [SynoXtract](https://github.com/prt1999/SynoXtract) and [synodecrypt](https://github.com/synacktiv/synodecrypt) projects

## License

This project is provided as-is for personal use. FFmpeg is licensed under LGPL/GPL. The patched Synology library remains the property of Synology Inc.
