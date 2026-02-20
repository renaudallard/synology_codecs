# HEVC Codec Pack for Synology DSM 7

Drop-in replacement SPKs that restore HEVC/AVC/AAC codec support removed from Advanced Media Extensions (AME) v4.0 in DSM 7.2.2.

## Packages

| SPK | Replaces | Covers |
|-----|----------|--------|
| `CodecPack-x86_64-99.0.0-0001.spk` | AME (CodecPack) | Media Server, Photos, CLI transcoding |
| `SurveillanceVideoExtension-x86_64-99.0.0-0001.spk` | SVE | Surveillance Station H.265 streams |

## How It Works

- **FFmpeg**: John Van Sickle's static amd64 build (includes libx265, libx264, AAC)
- **License bypass**: AME 3.1.0-3005 `libsynoame-license.so` with 5 function patches (`mov eax,1; ret` after `endbr64`) — forces `CheckLicense`, `CheckOfflineLicense`, `IsValidStatus`, `ValidateLicense`, and `SLIsXA` to always return true
- **Activation files**: Pre-filled `activation.conf` and `offline_license.json` templates

## Requirements

- Synology NAS with **x86_64** CPU (Intel/AMD)
- **DSM 7.0+**
- Build host with: `bash`, `curl`, `tar`, `xz`, `python3`, `pip3 install pysodium msgpack` (for SPK decryption)

## Build

```sh
./build.sh
```

Output goes to `out/`:
- `CodecPack-x86_64-99.0.0-0001.spk`
- `SurveillanceVideoExtension-x86_64-99.0.0-0001.spk`

Downloaded files are cached in `build/` — delete it to force re-download.

## Install

1. Uninstall the official **Advanced Media Extensions** and **Surveillance Video Extension** from Package Center
2. In Package Center, click **Manual Install** and select each `.spk` file
3. If activation file copy fails during install, run the printed `sudo` command

## Verify

```sh
# Check HEVC encoder availability
/var/packages/CodecPack/target/pack/bin/ffmpeg41 -encoders 2>/dev/null | grep hevc

# Check SVE ffmpeg
/var/packages/SurveillanceVideoExtension/target/bin/ffmpeg -encoders 2>/dev/null | grep hevc
```

## File Structure

```
hevc-codec/
├── build.sh              # Main build script
├── README.md
└── src/
    ├── codecpack/        # CodecPack SPK sources
    │   ├── INFO
    │   ├── conf/         # privilege, resource
    │   ├── scripts/      # install lifecycle scripts
    │   └── package/      # pack/bin/, usr/lib/, usr/bin/, activation/
    └── sve/              # SurveillanceVideoExtension SPK sources
        ├── INFO
        ├── conf/         # privilege, resource
        ├── scripts/      # install lifecycle scripts
        └── package/      # bin/
```

## Notes

- Version `99.0.0` ensures Package Center treats this as newer than any official release
- The `start-stop-status` script always reports running (the package has no daemon)
- Both packages set `run-as: package` privilege level
