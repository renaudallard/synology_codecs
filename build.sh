#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
BUILD_DIR="$SCRIPT_DIR/build"
CACHE_DIR="$BUILD_DIR/cache"
OUT_DIR="$SCRIPT_DIR/out"

NJOBS=$(nproc)
HOST_ARCH="$(uname -m)"

AME_VER="3.1.0-3005"
CP_PKG="CodecPack"
SVE_PKG="SurveillanceVideoExtension"
PKG_VER="99.0.0-9999"

# SPK decryption key (keytype 3) — extracted from libsynocodesign.so
SPK_SIGNING_KEY="FECAA2DD065A86A68E5FE86BA34CD8481590A79FA2C29A7D69F25A3B3BFAA19E"
SPK_MASTER_KEY="CF0D8D6ECB95EF97D0AC6A7021D99124C699808CF2CC5157DFEA5EBF15C805E7"

# ── helpers ────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ── per-architecture configuration ────────────────────────────────────
set_arch_config() {
    case "$TARGET_ARCH" in
        x86_64)
            AME_SPK_ARCH="x86_64"
            SPK_ARCH="x86_64"
            INFO_ARCH="x86_64"
            ORIG_SO_MD5="09e3adeafe85b353c9427d93ef0185e9"
            PATCHED_SO_MD5="86d5f9f93c80c35e6c59f8ab05da3dc2"
            PATCH_OFFSETS=(9144 9234 9614 9804 be74)
            PATCH_BYTES="B8 01 00 00 00 C3"  # x86_64: mov eax,1; ret
            VPX_TARGET="x86_64-linux-gcc"
            NEEDS_NASM=true
            ;;
        aarch64)
            AME_SPK_ARCH="rtd1296"
            SPK_ARCH="aarch64"
            INFO_ARCH="rtd1296 rtd1619b armada37xx"
            ORIG_SO_MD5="f0b33cc2ec241a43f02a332bcbf0d701"
            PATCHED_SO_MD5="05ae2e473d9c20d6e3630bb751122305"
            PATCH_OFFSETS=(74c4 75f0 7a10 7c00 a220)
            PATCH_BYTES="20 00 80 52 C0 03 5F D6"  # aarch64: mov w0,#1; ret
            VPX_TARGET="arm64-linux-gcc"
            NEEDS_NASM=false
            ;;
        *)
            die "Unsupported architecture: $TARGET_ARCH (must be x86_64 or aarch64)"
            ;;
    esac

    # Per-arch build directories (shared source cache)
    ARCH_BUILD_DIR="$BUILD_DIR/$TARGET_ARCH"
    FF_SRC="$ARCH_BUILD_DIR/ffmpeg-src"
    FF_PREFIX="$ARCH_BUILD_DIR/ffmpeg-prefix"

    # Cross-compilation setup
    if [ "$HOST_ARCH" = "$TARGET_ARCH" ]; then
        CROSS_PREFIX=""
        CROSS_HOST=""
    else
        CROSS_HOST="${TARGET_ARCH}-linux-gnu"
        CROSS_PREFIX="${CROSS_HOST}-"
    fi

    AME_SPK_NAME="CodecPack-${AME_SPK_ARCH}-${AME_VER}.spk"
    AME_URLS=(
        "https://global.synologydownload.com/download/Package/spk/CodecPack/${AME_VER}/${AME_SPK_NAME}"
        "https://global.download.synology.com/download/Package/spk/CodecPack/${AME_VER}/${AME_SPK_NAME}"
        "https://archive.synology.com/download/Package/spk/CodecPack/${AME_VER}/${AME_SPK_NAME}"
    )
}

check_deps() {
    local missing=()
    for cmd in tar curl xz python3 make git cmake; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required tools: ${missing[*]}"
    fi
    python3 -c "import pysodium, msgpack" 2>/dev/null || \
        die "Missing Python modules. Install with: pip3 install pysodium msgpack"

    # Check cross toolchain if cross-compiling
    if [ -n "$CROSS_PREFIX" ]; then
        command -v "${CROSS_PREFIX}gcc" >/dev/null || \
            die "Cross compiler not found. Install with: sudo apt install gcc-${TARGET_ARCH}-linux-gnu g++-${TARGET_ARCH}-linux-gnu"
    fi
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

# Clone or update a git repo into cache
git_clone() {
    local url=$1 dir=$2 ref=$3
    if [ -d "$CACHE_DIR/$dir" ]; then
        info "  $dir already cached"
    else
        git clone --depth 1 --branch "$ref" "$url" "$CACHE_DIR/$dir"
    fi
}

# ── cross-compile setup ──────────────────────────────────────────────
setup_cross_env() {
    # Use system pkg-config (avoid user stubs)
    PKG_CONFIG="$(command -v /usr/bin/pkg-config || command -v pkg-config)"
    export PKG_CONFIG

    if [ -z "$CROSS_PREFIX" ]; then
        # Native build
        export CC=gcc CXX=g++ AR=ar RANLIB=ranlib STRIP=strip
        CONFIGURE_HOST=""
        CMAKE_CROSS_ARGS=""
    else
        export CC="${CROSS_PREFIX}gcc"
        export CXX="${CROSS_PREFIX}g++"
        export AR="${CROSS_PREFIX}ar"
        export RANLIB="${CROSS_PREFIX}ranlib"
        export STRIP="${CROSS_PREFIX}strip"
        CONFIGURE_HOST="--host=${CROSS_HOST}"
        CMAKE_CROSS_ARGS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=${TARGET_ARCH} -DCMAKE_C_COMPILER=${CC} -DCMAKE_CXX_COMPILER=${CXX}"
    fi
    export PKG_CONFIG_PATH="$FF_PREFIX/lib/pkgconfig"
    export CFLAGS="-I$FF_PREFIX/include"
    export CXXFLAGS="-I$FF_PREFIX/include"
    export LDFLAGS="-L$FF_PREFIX/lib"
}

# ── step 1: download & extract AME ────────────────────────────────────
download_ame() {
    local ame_spk="$CACHE_DIR/ame_${TARGET_ARCH}.spk"
    if [ -f "$ame_spk" ]; then
        info "AME SPK for ${TARGET_ARCH} already cached"
    elif [ -f "$CACHE_DIR/$AME_SPK_NAME" ]; then
        info "Using manually placed $AME_SPK_NAME"
        cp "$CACHE_DIR/$AME_SPK_NAME" "$ame_spk"
    else
        info "Downloading AME ${AME_VER} for ${TARGET_ARCH}..."
        local ok=false
        for url in "${AME_URLS[@]}"; do
            if curl -fSL -o "$ame_spk" "$url" 2>/dev/null; then
                ok=true
                break
            fi
            info "  Mirror failed, trying next..."
        done
        if [ "$ok" != "true" ]; then
            die "All download mirrors failed. You can manually download the AME SPK and place it at: $CACHE_DIR/$AME_SPK_NAME"
        fi
    fi

    info "Decrypting AME SPK..."
    local ame_tar="$ARCH_BUILD_DIR/ame_decrypted.tar"
    decrypt_spk "$ame_spk" "$ame_tar"

    info "Extracting libsynoame-license.so..."
    local ame_tmp="$ARCH_BUILD_DIR/ame_tmp"
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

    cp "$so_file" "$ARCH_BUILD_DIR/libsynoame-license.so"
    rm -rf "$ame_tmp" "$ame_tar"

    local actual_md5
    actual_md5=$(md5sum "$ARCH_BUILD_DIR/libsynoame-license.so" | awk '{print $1}')
    if [ "$actual_md5" != "$ORIG_SO_MD5" ]; then
        die "Original .so MD5 mismatch: expected $ORIG_SO_MD5, got $actual_md5"
    fi
    info "Original .so MD5 verified: $actual_md5"
}

# ── step 2: patch libsynoame-license.so ───────────────────────────────
patch_so() {
    local so="$ARCH_BUILD_DIR/libsynoame-license.so"
    info "Patching libsynoame-license.so for ${TARGET_ARCH}..."

    # Patch all 5 license-check functions to unconditionally return true
    for offset in "${PATCH_OFFSETS[@]}"; do
        patch_bytes "$so" "$offset" $PATCH_BYTES
    done

    local actual_md5
    actual_md5=$(md5sum "$so" | awk '{print $1}')
    if [ "$actual_md5" != "$PATCHED_SO_MD5" ]; then
        die "Patched .so MD5 mismatch: expected $PATCHED_SO_MD5, got $actual_md5"
    fi
    info "Patched .so MD5 verified: $actual_md5"
}

# ── step 3: build FFmpeg from source ──────────────────────────────────

fetch_sources() {
    info "Fetching library sources..."
    mkdir -p "$CACHE_DIR"

    git_clone "https://code.videolan.org/videolan/x264.git"         x264     stable
    git_clone "https://bitbucket.org/multicoreware/x265_git.git"    x265     4.1
    git_clone "https://github.com/mstorsjo/fdk-aac.git"            fdk-aac  v2.0.3
    git_clone "https://chromium.googlesource.com/webm/libvpx.git"  libvpx   v1.16.0
    git_clone "https://github.com/xiph/opus.git"                   opus     v1.6
    git_clone "https://github.com/xiph/ogg.git"                    ogg      v1.3.6
    git_clone "https://github.com/xiph/vorbis.git"                 vorbis   v1.3.7
    git_clone "https://aomedia.googlesource.com/aom"               aom      v3.13.1
    git_clone "https://github.com/FFmpeg/FFmpeg.git"               ffmpeg   n7.1.3

    # LAME has no git — download tarball
    if [ ! -f "$CACHE_DIR/lame-3.100.tar.gz" ]; then
        curl -fSL -o "$CACHE_DIR/lame-3.100.tar.gz" \
            "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz"
    fi
}

build_nasm() {
    # nasm outputs x86 machine code — only needed for x86_64 targets
    if [ "$NEEDS_NASM" != "true" ]; then return; fi
    if [ -x "$FF_PREFIX/bin/nasm" ]; then return; fi
    info "Building nasm..."
    local ver="2.16.03"
    if [ ! -f "$CACHE_DIR/nasm-${ver}.tar.xz" ]; then
        curl -fSL -o "$CACHE_DIR/nasm-${ver}.tar.xz" \
            "https://www.nasm.us/pub/nasm/releasebuilds/${ver}/nasm-${ver}.tar.xz"
    fi
    rm -rf "$FF_SRC/nasm"
    mkdir -p "$FF_SRC/nasm"
    tar xJf "$CACHE_DIR/nasm-${ver}.tar.xz" -C "$FF_SRC/nasm" --strip-components=1
    cd "$FF_SRC/nasm"
    # nasm is a build tool — always compile for HOST architecture
    CC=gcc CXX=g++ CFLAGS="" CXXFLAGS="" LDFLAGS="" \
        ./configure --prefix="$FF_PREFIX"
    make -j"$NJOBS"
    make install
}

build_x264() {
    if [ -f "$FF_PREFIX/lib/libx264.a" ]; then return; fi
    info "Building x264..."
    rm -rf "$FF_SRC/x264"
    cp -a "$CACHE_DIR/x264" "$FF_SRC/x264"
    cd "$FF_SRC/x264"
    local args=(
        --prefix="$FF_PREFIX"
        --enable-static --disable-shared --disable-cli
        --extra-cflags="$CFLAGS"
        --extra-ldflags="$LDFLAGS"
    )
    if [ -n "$CROSS_PREFIX" ]; then
        args+=(--cross-prefix="${CROSS_PREFIX}" --host="${CROSS_HOST}")
    fi
    ./configure "${args[@]}"
    make -j"$NJOBS"
    make install
}

build_x265() {
    if [ -f "$FF_PREFIX/lib/libx265.a" ]; then return; fi
    info "Building x265..."
    rm -rf "$FF_SRC/x265"
    cp -a "$CACHE_DIR/x265" "$FF_SRC/x265"
    cd "$FF_SRC/x265/source"
    # Fix cmake_policy(OLD) calls rejected by CMake 4.x
    sed -i 's/cmake_policy(SET CMP0025 OLD)/cmake_policy(SET CMP0025 NEW)/' CMakeLists.txt
    sed -i 's/cmake_policy(SET CMP0054 OLD)/cmake_policy(SET CMP0054 NEW)/' CMakeLists.txt
    sed -i 's/cmake_minimum_required (VERSION 2.8.8)/cmake_minimum_required(VERSION 3.10)/' CMakeLists.txt
    cmake -B build -G "Unix Makefiles" \
        -DCMAKE_INSTALL_PREFIX="$FF_PREFIX" \
        -DENABLE_SHARED=OFF \
        -DENABLE_CLI=OFF \
        $CMAKE_CROSS_ARGS
    cmake --build build -j"$NJOBS"
    cmake --install build
    # Fix x265.pc: remove -lgcc_s which has no static version
    sed -i 's/-lgcc_s //g' "$FF_PREFIX/lib/pkgconfig/x265.pc"
}

build_fdk_aac() {
    if [ -f "$FF_PREFIX/lib/libfdk-aac.a" ]; then return; fi
    info "Building fdk-aac..."
    rm -rf "$FF_SRC/fdk-aac"
    cp -a "$CACHE_DIR/fdk-aac" "$FF_SRC/fdk-aac"
    cd "$FF_SRC/fdk-aac"
    autoreconf -fiv
    ./configure \
        --prefix="$FF_PREFIX" \
        --enable-static --disable-shared \
        $CONFIGURE_HOST
    make -j"$NJOBS"
    make install
}

build_libvpx() {
    if [ -f "$FF_PREFIX/lib/libvpx.a" ]; then return; fi
    info "Building libvpx..."
    rm -rf "$FF_SRC/libvpx"
    cp -a "$CACHE_DIR/libvpx" "$FF_SRC/libvpx"
    cd "$FF_SRC/libvpx"
    CROSS="${CROSS_PREFIX}" ./configure \
        --prefix="$FF_PREFIX" \
        --target="$VPX_TARGET" \
        --enable-static --disable-shared \
        --disable-examples --disable-tools --disable-docs \
        --disable-unit-tests \
        --enable-vp8 --enable-vp9 \
        --enable-vp9-highbitdepth
    make -j"$NJOBS"
    make install
}

build_opus() {
    if [ -f "$FF_PREFIX/lib/libopus.a" ]; then return; fi
    info "Building opus..."
    rm -rf "$FF_SRC/opus"
    cp -a "$CACHE_DIR/opus" "$FF_SRC/opus"
    cd "$FF_SRC/opus"
    autoreconf -fiv
    ./configure \
        --prefix="$FF_PREFIX" \
        --enable-static --disable-shared --disable-doc \
        $CONFIGURE_HOST
    make -j"$NJOBS"
    make install
}

build_lame() {
    if [ -f "$FF_PREFIX/lib/libmp3lame.a" ]; then return; fi
    info "Building lame..."
    rm -rf "$FF_SRC/lame"
    mkdir -p "$FF_SRC/lame"
    tar xzf "$CACHE_DIR/lame-3.100.tar.gz" -C "$FF_SRC/lame" --strip-components=1
    cd "$FF_SRC/lame"
    ./configure \
        --prefix="$FF_PREFIX" \
        --enable-static --disable-shared \
        --disable-frontend --disable-decoder \
        $CONFIGURE_HOST
    make -j"$NJOBS"
    make install
}

build_ogg() {
    if [ -f "$FF_PREFIX/lib/libogg.a" ]; then return; fi
    info "Building libogg..."
    rm -rf "$FF_SRC/ogg"
    cp -a "$CACHE_DIR/ogg" "$FF_SRC/ogg"
    cd "$FF_SRC/ogg"
    autoreconf -fiv
    ./configure \
        --prefix="$FF_PREFIX" \
        --enable-static --disable-shared \
        $CONFIGURE_HOST
    make -j"$NJOBS"
    make install
}

build_vorbis() {
    if [ -f "$FF_PREFIX/lib/libvorbis.a" ]; then return; fi
    info "Building libvorbis..."
    rm -rf "$FF_SRC/vorbis"
    cp -a "$CACHE_DIR/vorbis" "$FF_SRC/vorbis"
    cd "$FF_SRC/vorbis"
    autoreconf -fiv
    ./configure \
        --prefix="$FF_PREFIX" \
        --enable-static --disable-shared \
        --with-ogg="$FF_PREFIX" \
        $CONFIGURE_HOST
    make -j"$NJOBS"
    make install
}

build_aom() {
    if [ -f "$FF_PREFIX/lib/libaom.a" ]; then return; fi
    info "Building libaom..."
    rm -rf "$FF_SRC/aom"
    cp -a "$CACHE_DIR/aom" "$FF_SRC/aom"
    cd "$FF_SRC/aom"
    cmake -B build -G "Unix Makefiles" \
        -DCMAKE_INSTALL_PREFIX="$FF_PREFIX" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_DOCS=OFF \
        -DENABLE_EXAMPLES=OFF \
        -DENABLE_TOOLS=OFF \
        -DENABLE_TESTS=OFF \
        -DCONFIG_MULTITHREAD=1 \
        $CMAKE_CROSS_ARGS
    cmake --build build -j"$NJOBS"
    cmake --install build
}

build_ffmpeg() {
    if [ -f "$ARCH_BUILD_DIR/ffmpeg" ] && [ -f "$ARCH_BUILD_DIR/ffprobe" ]; then
        info "FFmpeg already built"
        return
    fi
    info "Building FFmpeg..."
    rm -rf "$FF_SRC/ffmpeg"
    cp -a "$CACHE_DIR/ffmpeg" "$FF_SRC/ffmpeg"
    cd "$FF_SRC/ffmpeg"

    local cross_args=""
    if [ -n "$CROSS_PREFIX" ]; then
        cross_args="--enable-cross-compile --cross-prefix=${CROSS_PREFIX} --arch=${TARGET_ARCH} --target-os=linux"
    fi

    PKG_CONFIG_PATH="$FF_PREFIX/lib/pkgconfig" ./configure \
        --prefix="$FF_PREFIX" \
        --extra-cflags="-I$FF_PREFIX/include -static" \
        --extra-ldflags="-L$FF_PREFIX/lib -static" \
        --extra-libs="-lpthread -lm -lstdc++" \
        --pkg-config="$PKG_CONFIG" \
        --pkg-config-flags="--static" \
        --enable-gpl \
        --enable-nonfree \
        --enable-static \
        --disable-shared \
        --enable-libx264 \
        --enable-libx265 \
        --enable-libfdk-aac \
        --enable-libvpx \
        --enable-libopus \
        --enable-libmp3lame \
        --enable-libvorbis \
        --enable-libaom \
        $cross_args

    make -j"$NJOBS"

    cp ffmpeg  "$ARCH_BUILD_DIR/ffmpeg"
    cp ffprobe "$ARCH_BUILD_DIR/ffprobe"
    $STRIP "$ARCH_BUILD_DIR/ffmpeg" "$ARCH_BUILD_DIR/ffprobe"
    chmod +x "$ARCH_BUILD_DIR/ffmpeg" "$ARCH_BUILD_DIR/ffprobe"
    info "FFmpeg built and stripped"
}

build_all_ffmpeg() {
    setup_cross_env
    export PATH="$FF_PREFIX/bin:$PATH"
    mkdir -p "$FF_SRC" "$FF_PREFIX"

    fetch_sources
    build_nasm
    build_x264
    build_x265
    build_fdk_aac
    build_libvpx
    build_opus
    build_lame
    build_ogg
    build_vorbis
    build_aom
    build_ffmpeg
}

# ── step 4: generate icons ────────────────────────────────────────────
generate_icons() {
    info "Generating placeholder icons..."
    gen_png 72  "$ARCH_BUILD_DIR/PACKAGE_ICON.PNG"
    gen_png 256 "$ARCH_BUILD_DIR/PACKAGE_ICON_256.PNG"
}

# ── step 5: assemble CodecPack SPK ────────────────────────────────────
build_codecpack() {
    info "Building CodecPack SPK for ${TARGET_ARCH}..."
    local pkg_src="$SRC_DIR/codecpack"
    local staging="$ARCH_BUILD_DIR/codecpack_staging"
    rm -rf "$staging"
    mkdir -p "$staging/package"

    # Copy package tree to staging, then overlay built binaries
    cp -a "$pkg_src/package/"* "$staging/package/"

    # Place binaries in pack/bin/ (matching official codec pack layout)
    cp "$ARCH_BUILD_DIR/ffmpeg"  "$staging/package/pack/bin/ffmpeg41"
    cp "$ARCH_BUILD_DIR/ffprobe" "$staging/package/pack/bin/ffprobe"
    ln -sf ffmpeg41 "$staging/package/pack/bin/ffmpeg33-for-surveillance"
    ln -sf ffmpeg41 "$staging/package/pack/bin/ffmpeg33-for-audio"
    chmod +x "$staging/package/pack/bin/ffmpeg41" "$staging/package/pack/bin/ffprobe"

    # bin/ entries symlink to pack/bin/ (matching official layout)
    ln -sf ../pack/bin/ffmpeg41 "$staging/package/bin/ffmpeg41"
    ln -sf ../pack/bin/ffprobe "$staging/package/bin/ffprobe"
    ln -sf ../pack/bin/ffmpeg33-for-surveillance "$staging/package/bin/ffmpeg33-for-surveillance"
    ln -sf ../pack/bin/ffmpeg33-for-audio "$staging/package/bin/ffmpeg33-for-audio"
    chmod +x "$staging/package/bin/synocodectool"

    # lib/ entries symlink to pack/lib/ (matching official layout)
    ln -sf ../pack/lib/ffmpeg41 "$staging/package/lib/ffmpeg41"
    ln -sf ../pack/lib/ffmpeg33-for-surveillance "$staging/package/lib/ffmpeg33-for-surveillance"
    ln -sf ../pack/lib/ffmpeg33-for-audio "$staging/package/lib/ffmpeg33-for-audio"

    # Update pack/INFO arch
    sed -i "s/^arch=.*/arch=\"${INFO_ARCH}\"/" "$staging/package/pack/INFO"

    cp "$ARCH_BUILD_DIR/libsynoame-license.so" "$staging/package/usr/lib/libsynoame-license.so"
    chmod +x "$staging/package/usr/bin/synoame-bin-check-license"

    tar czf "$staging/package.tgz" -C "$staging/package" .
    rm -rf "$staging/package"

    # INFO with correct arch for this target
    sed "s/^arch=.*/arch=\"${INFO_ARCH}\"/" "$pkg_src/INFO" > "$staging/INFO"

    cp "$ARCH_BUILD_DIR/PACKAGE_ICON.PNG" "$staging/PACKAGE_ICON.PNG"
    cp "$ARCH_BUILD_DIR/PACKAGE_ICON_256.PNG" "$staging/PACKAGE_ICON_256.PNG"

    mkdir -p "$staging/scripts"
    cp "$pkg_src/scripts/"* "$staging/scripts/"
    chmod +x "$staging/scripts/"*

    mkdir -p "$staging/conf"
    cp "$pkg_src/conf/"* "$staging/conf/"

    local spk_name="${CP_PKG}-${SPK_ARCH}-${PKG_VER}.spk"
    (cd "$staging" && tar cpf "$OUT_DIR/$spk_name" --owner=root --group=root \
        package.tgz INFO PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG scripts conf)
    info "Built: $OUT_DIR/$spk_name"
}

# ── step 6: assemble SVE SPK ──────────────────────────────────────────
build_sve() {
    info "Building SurveillanceVideoExtension SPK for ${TARGET_ARCH}..."
    local pkg_src="$SRC_DIR/sve"
    local staging="$ARCH_BUILD_DIR/sve_staging"
    rm -rf "$staging"
    mkdir -p "$staging/package"

    # Copy package tree to staging, then overlay built binaries
    cp -a "$pkg_src/package/"* "$staging/package/"
    chmod +x "$staging/package/bin/synocodectool"
    # SS loads ffmpeg shared libs from lib/ffmpeg33-for-surveillance/ which
    # we symlink to pack/lib/ffmpeg33-for-surveillance/.  Our static ffmpeg
    # doesn't produce .so files, so place the full static binary there as
    # a wrapper that SS can exec instead.
    cp "$ARCH_BUILD_DIR/ffmpeg" "$staging/package/pack/lib/ffmpeg33-for-surveillance/ffmpeg"
    chmod +x "$staging/package/pack/lib/ffmpeg33-for-surveillance/ffmpeg"
    ln -sf ../pack/lib/ffmpeg33-for-surveillance "$staging/package/lib/ffmpeg33-for-surveillance"
    # Also update pack/INFO arch to match target
    sed -i "s/^arch=.*/arch=\"${INFO_ARCH}\"/" "$staging/package/pack/INFO"

    tar czf "$staging/package.tgz" -C "$staging/package" .
    rm -rf "$staging/package"

    # INFO with correct arch for this target
    sed "s/^arch=.*/arch=\"${INFO_ARCH}\"/" "$pkg_src/INFO" > "$staging/INFO"

    cp "$ARCH_BUILD_DIR/PACKAGE_ICON.PNG" "$staging/PACKAGE_ICON.PNG"
    cp "$ARCH_BUILD_DIR/PACKAGE_ICON_256.PNG" "$staging/PACKAGE_ICON_256.PNG"

    mkdir -p "$staging/scripts"
    cp "$pkg_src/scripts/"* "$staging/scripts/"
    chmod +x "$staging/scripts/"*

    mkdir -p "$staging/conf"
    cp "$pkg_src/conf/"* "$staging/conf/"

    local spk_name="${SVE_PKG}-${SPK_ARCH}-${PKG_VER}.spk"
    (cd "$staging" && tar cpf "$OUT_DIR/$spk_name" --owner=root --group=root \
        package.tgz INFO PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG scripts conf)
    info "Built: $OUT_DIR/$spk_name"
}

# ── build one architecture ────────────────────────────────────────────
build_for_arch() {
    TARGET_ARCH="$1"
    set_arch_config
    info "=== Building for ${TARGET_ARCH} (host: ${HOST_ARCH}) ==="

    check_deps
    rm -rf "$ARCH_BUILD_DIR/ame_tmp" \
           "$ARCH_BUILD_DIR/codecpack_staging" "$ARCH_BUILD_DIR/sve_staging"
    mkdir -p "$ARCH_BUILD_DIR" "$CACHE_DIR" "$OUT_DIR"

    download_ame
    patch_so
    build_all_ffmpeg
    generate_icons
    build_codecpack
    build_sve
}

# ── main ──────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 [--arch x86_64|aarch64|all]

Build HEVC codec SPK packages for Synology NAS.
Default: build for host architecture ($(uname -m))

  --arch x86_64    Build for x86_64 (Intel/AMD)
  --arch aarch64   Build for aarch64 (ARM64: rtd1296, rtd1619b, armada37xx)
  --arch all       Build for both architectures
EOF
    exit 1
}

main() {
    local target="$HOST_ARCH"

    while [ $# -gt 0 ]; do
        case "$1" in
            --arch)
                [ $# -ge 2 ] || usage
                target="$2"
                shift 2
                ;;
            -h|--help) usage ;;
            *) usage ;;
        esac
    done

    case "$target" in
        x86_64|aarch64)
            build_for_arch "$target"
            ;;
        all)
            build_for_arch x86_64
            build_for_arch aarch64
            ;;
        *)
            die "Unsupported architecture: $target (must be x86_64, aarch64, or all)"
            ;;
    esac

    info ""
    info "Done! SPK files in $OUT_DIR/:"
    ls -lh "$OUT_DIR/"*.spk
}

main "$@"
