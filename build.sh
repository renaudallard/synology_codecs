#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
BUILD_DIR="$SCRIPT_DIR/build"
CACHE_DIR="$SCRIPT_DIR/build/cache"
OUT_DIR="$SCRIPT_DIR/out"

AME_VER="3.1.0-3005"
AME_URL="https://global.synologydownload.com/download/Package/spk/CodecPack/${AME_VER}/CodecPack-x86_64-${AME_VER}.spk"
FFMPEG_URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"

ORIG_SO_MD5="09e3adeafe85b353c9427d93ef0185e9"
PATCHED_SO_MD5="86d5f9f93c80c35e6c59f8ab05da3dc2"

CP_PKG="CodecPack"
SVE_PKG="SurveillanceVideoExtension"
PKG_VER="99.0.0-0001"

# SPK decryption key (keytype 3) — extracted from libsynocodesign.so
SPK_SIGNING_KEY="FECAA2DD065A86A68E5FE86BA34CD8481590A79FA2C29A7D69F25A3B3BFAA19E"
SPK_MASTER_KEY="CF0D8D6ECB95EF97D0AC6A7021D99124C699808CF2CC5157DFEA5EBF15C805E7"

# ── helpers ────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

check_deps() {
    local missing=()
    for cmd in tar curl xz python3; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required tools: ${missing[*]}"
    fi
    # Check python modules needed for SPK decryption
    python3 -c "import pysodium, msgpack" 2>/dev/null || \
        die "Missing Python modules. Install with: pip3 install pysodium msgpack"
}

# Generate a solid-color PNG using only python3 + zlib (no PIL)
gen_png() {
    local size=$1 outfile=$2
    python3 -c "
import struct, zlib

size = $size
r, g, b = 0x4A, 0x5A, 0x6A

raw = b''
for _ in range(size):
    raw += b'\x00' + bytes([r, g, b]) * size

def chunk(ctype, data):
    c = ctype + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)

png  = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(raw))
png += chunk(b'IEND', b'')

with open('$outfile', 'wb') as f:
    f.write(png)
"
}

# Write bytes at offset using dd
patch_bytes() {
    local file=$1 offset_hex=$2
    shift 2
    local bytes="$*"
    local offset=$((16#${offset_hex}))
    printf '%b' "$(echo "$bytes" | sed 's/ /\\x/g; s/^/\\x/')" | \
        dd of="$file" bs=1 seek="$offset" conv=notrunc status=none
}

# Decrypt a Synology encrypted SPK to a plain tar
# Based on https://github.com/synacktiv/synodecrypt
decrypt_spk() {
    local spk_file=$1 out_tar=$2
    python3 - "$spk_file" "$out_tar" "$SPK_SIGNING_KEY" "$SPK_MASTER_KEY" <<'PYEOF'
import sys, os, tarfile, struct
from io import BytesIO
import msgpack, pysodium

spk_file, out_tar, signing_hex, master_hex = sys.argv[1:5]
signing_key = bytes.fromhex(signing_hex)
master_key = bytes.fromhex(master_hex)

TAR_BLOCK = 0x200

with open(spk_file, "rb") as f:
    s = BytesIO(f.read())

# Check magic
magic = int.from_bytes(s.read(4), "big") & 0xffffff
assert magic == 0xadbeef, f"Not an encrypted SPK (magic: {hex(magic)})"

# Read header
header_len = int.from_bytes(s.read(4), "little")
header = s.read(header_len)
header_sig = s.read(0x40)

# Verify signature
pysodium.crypto_sign_verify_detached(header_sig, header, signing_key)

# Parse header
mp = msgpack.unpackb(header)
data, entries_info = mp[0], mp[1]
ctx = data[0x18:0x18+7] + b"\x00"
subkey_id = int.from_bytes(data[0x10:0x10+8], "little")
kdf_subkey = pysodium.crypto_kdf_derive_from_key(0x20, subkey_id, ctx, master_key)

# Map entries
class E:
    def __init__(self, off, sz, h):
        self.offset, self.size, self.hash = off, sz, h

entries = []
for entry_len, checksum in entries_info:
    entries.append(E(s.tell(), entry_len, checksum))
    s.seek(entry_len, os.SEEK_CUR)

with open(out_tar, "wb") as w:
    for entry in entries:
        s.seek(entry.offset)
        cipher_header = s.read(0x18)
        state = pysodium.crypto_secretstream_xchacha20poly1305_init_pull(cipher_header, kdf_subkey)
        dec_hdr, _ = pysodium.crypto_secretstream_xchacha20poly1305_pull(state, s.read(0x193), None)
        dec_hdr = dec_hdr.ljust(TAR_BLOCK, b"\x00")
        w.write(dec_hdr)

        tinfo = tarfile.TarInfo.frombuf(dec_hdr, "ascii", "strict")
        size = tinfo.size

        s.seek(entry.offset + TAR_BLOCK)
        cipher_header = s.read(0x18)
        state = pysodium.crypto_secretstream_xchacha20poly1305_init_pull(cipher_header, kdf_subkey)

        rem = size
        while rem > 0:
            n = min(0x400000, rem) + 17
            m, _ = pysodium.crypto_secretstream_xchacha20poly1305_pull(state, s.read(n), None)
            w.write(m)
            rem -= len(m)

        pad = TAR_BLOCK - (w.tell() % TAR_BLOCK)
        if pad % TAR_BLOCK:
            w.write(bytes(pad))

    w.write(bytes(TAR_BLOCK * 2))

print(f"Decrypted: {out_tar}")
PYEOF
}

# ── step 1: download & extract AME ────────────────────────────────────
download_ame() {
    local ame_spk="$CACHE_DIR/ame.spk"
    if [ ! -f "$ame_spk" ]; then
        info "Downloading AME ${AME_VER}..."
        curl -fSL -o "$ame_spk" "$AME_URL"
    else
        info "AME SPK already cached"
    fi

    info "Decrypting AME SPK..."
    local ame_tar="$BUILD_DIR/ame_decrypted.tar"
    decrypt_spk "$ame_spk" "$ame_tar"

    info "Extracting libsynoame-license.so..."
    local ame_tmp="$BUILD_DIR/ame_tmp"
    mkdir -p "$ame_tmp"
    tar xf "$ame_tar" -C "$ame_tmp" package.tgz

    # AME 3.1.0 uses XZ compression for package.tgz
    local pkg_type
    pkg_type=$(file -b "$ame_tmp/package.tgz")
    if echo "$pkg_type" | grep -q "XZ"; then
        tar xJf "$ame_tmp/package.tgz" -C "$ame_tmp"
    else
        tar xzf "$ame_tmp/package.tgz" -C "$ame_tmp"
    fi

    local so_file
    so_file=$(find "$ame_tmp" -name 'libsynoame-license.so' -type f | head -1)
    [ -n "$so_file" ] || die "libsynoame-license.so not found in AME package"

    cp "$so_file" "$BUILD_DIR/libsynoame-license.so"
    rm -rf "$ame_tmp" "$ame_tar"

    # Verify original checksum
    local actual_md5
    actual_md5=$(md5sum "$BUILD_DIR/libsynoame-license.so" | awk '{print $1}')
    if [ "$actual_md5" != "$ORIG_SO_MD5" ]; then
        die "Original .so MD5 mismatch: expected $ORIG_SO_MD5, got $actual_md5"
    fi
    info "Original .so MD5 verified: $actual_md5"
}

# ── step 2: patch libsynoame-license.so ───────────────────────────────
patch_so() {
    local so="$BUILD_DIR/libsynoame-license.so"
    info "Patching libsynoame-license.so..."

    # Each patch: write "mov eax,1; ret" (B8 01 00 00 00 C3) right after endbr64

    # IsValidStatus @ 0x9144
    patch_bytes "$so" 9144 B8 01 00 00 00 C3

    # ValidateLicense @ 0x9234
    patch_bytes "$so" 9234 B8 01 00 00 00 C3

    # CheckLicense @ 0x9614
    patch_bytes "$so" 9614 B8 01 00 00 00 C3

    # CheckOfflineLicense @ 0x9804
    patch_bytes "$so" 9804 B8 01 00 00 00 C3

    # SLIsXA @ 0xbe74
    patch_bytes "$so" be74 B8 01 00 00 00 C3

    # Verify patched checksum
    local actual_md5
    actual_md5=$(md5sum "$so" | awk '{print $1}')
    if [ "$actual_md5" != "$PATCHED_SO_MD5" ]; then
        die "Patched .so MD5 mismatch: expected $PATCHED_SO_MD5, got $actual_md5"
    fi
    info "Patched .so MD5 verified: $actual_md5"
}

# ── step 3: download static ffmpeg ────────────────────────────────────
download_ffmpeg() {
    local ffmpeg_tar="$CACHE_DIR/ffmpeg-static.tar.xz"
    if [ ! -f "$ffmpeg_tar" ]; then
        info "Downloading static FFmpeg (amd64)..."
        curl -fSL -o "$ffmpeg_tar" "$FFMPEG_URL"
    else
        info "FFmpeg archive already cached"
    fi

    info "Extracting ffmpeg and ffprobe..."
    local ff_tmp="$BUILD_DIR/ff_tmp"
    mkdir -p "$ff_tmp"
    tar xJf "$ffmpeg_tar" -C "$ff_tmp"

    local ffmpeg_bin
    ffmpeg_bin=$(find "$ff_tmp" -name 'ffmpeg' -type f | head -1)
    local ffprobe_bin
    ffprobe_bin=$(find "$ff_tmp" -name 'ffprobe' -type f | head -1)
    [ -n "$ffmpeg_bin" ]  || die "ffmpeg binary not found in archive"
    [ -n "$ffprobe_bin" ] || die "ffprobe binary not found in archive"

    cp "$ffmpeg_bin"  "$BUILD_DIR/ffmpeg"
    cp "$ffprobe_bin" "$BUILD_DIR/ffprobe"
    chmod +x "$BUILD_DIR/ffmpeg" "$BUILD_DIR/ffprobe"
    rm -rf "$ff_tmp"
    info "FFmpeg binaries extracted"
}

# ── step 4: generate icons ────────────────────────────────────────────
generate_icons() {
    info "Generating placeholder icons..."
    gen_png 72  "$BUILD_DIR/PACKAGE_ICON.PNG"
    gen_png 256 "$BUILD_DIR/PACKAGE_ICON_256.PNG"
}

# ── step 5: assemble CodecPack SPK ────────────────────────────────────
build_codecpack() {
    info "Building CodecPack SPK..."
    local pkg_src="$SRC_DIR/codecpack"
    local staging="$BUILD_DIR/codecpack_staging"
    rm -rf "$staging"
    mkdir -p "$staging"

    # Place binaries and patched .so into package tree
    cp "$BUILD_DIR/ffmpeg"  "$pkg_src/package/pack/bin/ffmpeg41"
    cp "$BUILD_DIR/ffprobe" "$pkg_src/package/pack/bin/ffprobe"
    cp "$BUILD_DIR/libsynoame-license.so" "$pkg_src/package/usr/lib/libsynoame-license.so"
    chmod +x "$pkg_src/package/pack/bin/ffmpeg41"
    chmod +x "$pkg_src/package/pack/bin/ffprobe"
    chmod +x "$pkg_src/package/usr/bin/synoame-bin-check-license"

    # Create package.tgz
    tar czf "$staging/package.tgz" -C "$pkg_src/package" .

    # Copy metadata files
    cp "$pkg_src/INFO" "$staging/INFO"
    cp "$BUILD_DIR/PACKAGE_ICON.PNG" "$staging/PACKAGE_ICON.PNG"
    cp "$BUILD_DIR/PACKAGE_ICON_256.PNG" "$staging/PACKAGE_ICON_256.PNG"

    # Create scripts archive
    chmod +x "$pkg_src/scripts/"*
    tar czf "$staging/scripts.tar.gz" -C "$pkg_src/scripts" .

    # Copy conf
    mkdir -p "$staging/conf"
    cp "$pkg_src/conf/"* "$staging/conf/"

    # Build SPK (tar)
    local spk_name="${CP_PKG}-x86_64-${PKG_VER}.spk"
    tar cf "$OUT_DIR/$spk_name" -C "$staging" .
    info "Built: $OUT_DIR/$spk_name"
}

# ── step 6: assemble SVE SPK ──────────────────────────────────────────
build_sve() {
    info "Building SurveillanceVideoExtension SPK..."
    local pkg_src="$SRC_DIR/sve"
    local staging="$BUILD_DIR/sve_staging"
    rm -rf "$staging"
    mkdir -p "$staging"

    # Place binaries into package tree
    cp "$BUILD_DIR/ffmpeg"  "$pkg_src/package/bin/ffmpeg"
    cp "$BUILD_DIR/ffprobe" "$pkg_src/package/bin/ffprobe"
    chmod +x "$pkg_src/package/bin/ffmpeg"
    chmod +x "$pkg_src/package/bin/ffprobe"

    # Create package.tgz
    tar czf "$staging/package.tgz" -C "$pkg_src/package" .

    # Copy metadata files
    cp "$pkg_src/INFO" "$staging/INFO"
    cp "$BUILD_DIR/PACKAGE_ICON.PNG" "$staging/PACKAGE_ICON.PNG"
    cp "$BUILD_DIR/PACKAGE_ICON_256.PNG" "$staging/PACKAGE_ICON_256.PNG"

    # Create scripts archive
    chmod +x "$pkg_src/scripts/"*
    tar czf "$staging/scripts.tar.gz" -C "$pkg_src/scripts" .

    # Copy conf
    mkdir -p "$staging/conf"
    cp "$pkg_src/conf/"* "$staging/conf/"

    # Build SPK (tar)
    local spk_name="${SVE_PKG}-x86_64-${PKG_VER}.spk"
    tar cf "$OUT_DIR/$spk_name" -C "$staging" .
    info "Built: $OUT_DIR/$spk_name"
}

# ── main ──────────────────────────────────────────────────────────────
main() {
    check_deps

    # Clean working dirs but preserve download cache
    rm -rf "$BUILD_DIR/ame_tmp" "$BUILD_DIR/ff_tmp" \
           "$BUILD_DIR/codecpack_staging" "$BUILD_DIR/sve_staging"
    mkdir -p "$BUILD_DIR" "$CACHE_DIR" "$OUT_DIR"

    download_ame
    patch_so
    download_ffmpeg
    generate_icons
    build_codecpack
    build_sve

    info ""
    info "Done! SPK files in $OUT_DIR/:"
    ls -lh "$OUT_DIR/"*.spk
}

main "$@"
