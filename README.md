# Synology Codecs — HEVC/AAC for DSM 7

Drop-in replacement SPK packages that restore **HEVC, H.264, and AAC** codec support removed from Synology's Advanced Media Extensions (AME) starting with v4.0 in DSM 7.2.2.

## Why

Synology silently removed HEVC/AVC decoding and encoding from AME 4.0. The official Surveillance Video Extension only provides basic H.264. This project builds two SPK packages from scratch that bring full codec support back.

## Packages

| SPK file | Replaces | What it covers |
|----------|----------|----------------|
| `CodecPack-{arch}-99.0.0-9999.spk` | Advanced Media Extensions | Media Server, Synology Photos, Video Station, CLI transcoding |
| `SurveillanceVideoExtension-{arch}-99.0.0-9999.spk` | Surveillance Video Extension | Surveillance Station H.265 camera streams |

Both packages are built for **x86_64** (Intel/AMD) and **aarch64** (ARM64: rtd1296, rtd1619b, armada37xx).

## How it works

**FFmpeg built from source** — The build script compiles FFmpeg 7.1 and all codec libraries from their official upstream repositories as a fully static binary. No pre-built third-party binaries are used. Cross-compilation is supported in both directions (x86_64 host building aarch64, or vice versa).

Included codecs:

| Library | Version | Codec |
|---------|---------|-------|
| [x264](https://code.videolan.org/videolan/x264) | stable | H.264 video |
| [x265](https://bitbucket.org/multicoreware/x265_git) | 4.1 | H.265/HEVC video |
| [fdk-aac](https://github.com/mstorsjo/fdk-aac) | 2.0.3 | AAC audio |
| [libvpx](https://chromium.googlesource.com/webm/libvpx) | 1.16.0 | VP8/VP9 video |
| [opus](https://github.com/xiph/opus) | 1.6 | Opus audio |
| [lame](https://lame.sourceforge.io) | 3.100 | MP3 audio |
| [libaom](https://aomedia.googlesource.com/aom) | 3.13.1 | AV1 video |
| [libvorbis](https://github.com/xiph/vorbis) | 1.3.7 | Vorbis audio |

**License library patch** — The build script downloads the official AME 3.1.0-3005 SPK, decrypts it (Synology uses an XChaCha20-Poly1305 encrypted archive format), extracts `libsynoame-license.so`, and patches five license-check functions to unconditionally return true.

x86_64 patches (`B8 01 00 00 00 C3` = `mov eax, 1; ret` after `endbr64`):

| Function | File offset |
|----------|-------------|
| `IsValidStatus` | `0x9144` |
| `ValidateLicense` | `0x9234` |
| `CheckLicense` | `0x9614` |
| `CheckOfflineLicense` | `0x9804` |
| `SLIsXA` | `0xbe74` |

aarch64 patches (`20 00 80 52 C0 03 5F D6` = `mov w0, #1; ret`):

| Function | File offset |
|----------|-------------|
| `IsValidStatus` | `0x74c4` |
| `ValidateLicense` | `0x75f0` |
| `CheckLicense` | `0x7a10` |
| `CheckOfflineLicense` | `0x7c00` |
| `SLIsXA` | `0xa220` |

Both the original and patched checksums are verified during the build.

**Activation files** — Pre-filled `activation.conf` and `offline_license.json` are bundled and copied into place at install time.

## Supported NAS platforms

| Architecture | Synology platforms | Example models |
|-------------|-------------------|----------------|
| x86_64 | All Intel/AMD | DS920+, DS1621+, DS723+, RS1221+ |
| aarch64 | rtd1296, rtd1619b, armada37xx | DS220j, DS420j, DS124, DS223, DS423, DS119j |

## Requirements

### Debian / Ubuntu

```sh
sudo apt update
sudo apt install build-essential git curl xz-utils cmake autoconf automake libtool \
    python3 python3-pysodium python3-msgpack

# Cross-compilation (optional):
# Building aarch64 targets on an x86_64 host:
sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
# Building x86_64 targets on an aarch64 host:
sudo apt install gcc-x86-64-linux-gnu g++-x86-64-linux-gnu
```

### Fedora / RHEL / CentOS / Rocky / Alma

```sh
sudo dnf groupinstall "Development Tools"
sudo dnf install git curl xz cmake autoconf automake libtool \
    python3 python3-pysodium python3-msgpack

# Cross-compilation (optional, Fedora only):
sudo dnf install gcc-aarch64-linux-gnu gcc-c++-aarch64-linux-gnu
```

### Arch Linux / Manjaro

```sh
sudo pacman -S base-devel git curl xz cmake autoconf automake libtool \
    python python-pysodium python-msgpack
```

Note: `python-pysodium` is in the [AUR](https://aur.archlinux.org/packages/python-pysodium), install it with your AUR helper (e.g., `yay -S python-pysodium`).

### openSUSE

```sh
sudo zypper install -t pattern devel_basis
sudo zypper install git curl xz cmake autoconf automake libtool \
    python3 python3-pysodium python3-msgpack
```

### Alpine Linux

```sh
sudo apk add build-base git curl xz cmake autoconf automake libtool \
    python3 py3-pip py3-msgpack libsodium-dev
pip3 install pysodium
```

Note: `py3-pysodium` is not in Alpine repos, so `pysodium` must be installed via pip.

## Build

```sh
git clone https://github.com/renaudallard/synology_codecs.git
cd synology_codecs

# Build for host architecture (auto-detected)
./build.sh

# Build for a specific architecture
./build.sh --arch x86_64
./build.sh --arch aarch64

# Build for both architectures
./build.sh --arch all
```

The script will:

1. Download AME 3.1.0-3005 from Synology's CDN (tries multiple mirrors automatically)
2. Decrypt the encrypted SPK and extract `libsynoame-license.so`
3. Apply the five binary patches (with MD5 verification before and after)
4. Clone and compile all codec libraries and FFmpeg from source as a static binary
5. Package everything into two SPK files in `out/`

Source repos and downloads are cached in `build/cache/` so subsequent builds are fast. Per-architecture build artifacts are kept in separate directories (`build/x86_64/`, `build/aarch64/`).

If the AME download fails (e.g., Synology removes the file from their CDN), you can manually download the SPK and place it in `build/cache/`:

```sh
# For x86_64:
cp CodecPack-x86_64-3.1.0-3005.spk build/cache/

# For aarch64:
cp CodecPack-rtd1296-3.1.0-3005.spk build/cache/
```

## Install

1. Open **Package Center** on your NAS
2. **Uninstall** the official *Advanced Media Extensions* if present
3. Click **Manual Install** and select the `CodecPack` SPK matching your NAS architecture
4. If you use Surveillance Station, install the `SurveillanceVideoExtension` SPK the same way — it will replace the official one in place (you cannot uninstall the official Surveillance Video Extension without removing Surveillance Station first)
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
    │   ├── INFO                     # Package metadata (arch set at build time)
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

## Why no pre-built downloads?

Pre-built SPK packages cannot be distributed for two reasons:

1. **Patched Synology proprietary library** — The CodecPack SPK contains a modified `libsynoame-license.so` (Synology's property) with license checks patched out. Distributing this modified binary would mean redistributing proprietary Synology code.

2. **FFmpeg GPL + nonfree license conflict** — FFmpeg is built with `--enable-gpl` (required by x264/x265) and `--enable-nonfree` (required by fdk-aac). The Fraunhofer FDK AAC license is GPL-incompatible, which makes the resulting binary non-redistributable under the GPL.

Building locally from source avoids both issues. The build script automates the entire process — you only need a compiler and standard build tools.

## Notes

- Package version `99.0.0` ensures Package Center treats it as newer than any official release
- The `start-stop-status` script always reports the package as running (there is no daemon)
- Both packages declare `run-as: package` privilege
- The aarch64 SPK covers all ARM64 Synology platforms (rtd1296, rtd1619b, armada37xx) — the `libsynoame-license.so` is identical across all three
- The SPK decryption keys are public knowledge, extracted from `libsynocodesign.so` by the [SynoXtract](https://github.com/prt1999/SynoXtract) and [synodecrypt](https://github.com/synacktiv/synodecrypt) projects
- FFmpeg and all codec libraries are compiled from source — no pre-built third-party binaries are trusted

## License

This project is provided as-is for personal use. FFmpeg is licensed under LGPL/GPL (this build uses GPL due to x264/x265). fdk-aac is under a Fraunhofer FDK AAC license. The patched Synology library remains the property of Synology Inc.
