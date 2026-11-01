#!/usr/bin/env bash
set -euo pipefail

# Builds a universal (arm64 + x86_64) static YARA 4.5.4 with static OpenSSL,
# then vendors YARA and the maclean helper into Sources/MacLeanCore/Resources/bin.
#
# Build-time dependencies (not runtime): git, curl, perl, autoconf, automake,
# libtool, pkg-config, Xcode command line tools.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${YARA_VERSION:-4.5.4}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.0.16}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/maclean-yara-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Building OpenSSL ${OPENSSL_VERSION} (static universal) in ${BUILD_DIR}"
curl -L --fail --silent --show-error \
  "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" \
  -o "$BUILD_DIR/openssl.tar.gz"
tar xzf "$BUILD_DIR/openssl.tar.gz" -C "$BUILD_DIR"
for arch in arm64 x86_64; do
  cp -R "$BUILD_DIR/openssl-${OPENSSL_VERSION}" "$BUILD_DIR/openssl-${arch}"
  (
    cd "$BUILD_DIR/openssl-${arch}"
    ./Configure "darwin64-${arch}-cc" no-shared no-tests \
      --prefix="$BUILD_DIR/openssl-${arch}" >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
  )
done

OPENSSL_DIR="$BUILD_DIR/openssl-universal"
mkdir -p "$OPENSSL_DIR/lib/pkgconfig" "$OPENSSL_DIR/include"
lipo -create \
  "$BUILD_DIR/openssl-arm64/libcrypto.a" \
  "$BUILD_DIR/openssl-x86_64/libcrypto.a" \
  -output "$OPENSSL_DIR/lib/libcrypto.a"
lipo -create \
  "$BUILD_DIR/openssl-arm64/libssl.a" \
  "$BUILD_DIR/openssl-x86_64/libssl.a" \
  -output "$OPENSSL_DIR/lib/libssl.a"
cp -R "$BUILD_DIR/openssl-arm64/include/openssl" "$OPENSSL_DIR/include/"
for pc in libcrypto libssl openssl; do
  cp "$BUILD_DIR/openssl-arm64/$pc.pc" "$OPENSSL_DIR/lib/pkgconfig/$pc.pc"
  sed -i '' "s#^prefix=.*#prefix=$OPENSSL_DIR#" "$OPENSSL_DIR/lib/pkgconfig/$pc.pc"
done

echo "Building YARA ${VERSION} with static OpenSSL"
git clone --depth 1 --branch "v${VERSION}" \
  https://github.com/VirusTotal/yara.git "$BUILD_DIR/yara"

cd "$BUILD_DIR/yara"
sed -i '' 's/#define YR_MAX_LOOP_NESTING 4/#define YR_MAX_LOOP_NESTING 32/' \
  libyara/include/yara/limits.h

./bootstrap.sh >/dev/null

PKG_CONFIG_PATH="$OPENSSL_DIR/lib/pkgconfig" \
CFLAGS="-arch arm64 -arch x86_64 -O2 -I$OPENSSL_DIR/include" \
CXXFLAGS="-arch arm64 -arch x86_64 -O2 -I$OPENSSL_DIR/include" \
LDFLAGS="-arch arm64 -arch x86_64 -L$OPENSSL_DIR/lib" \
./configure \
  --disable-shared \
  --enable-static \
  --enable-macho \
  --prefix="$BUILD_DIR/install" >/dev/null

make -j"$(sysctl -n hw.ncpu)" >/dev/null

clang -arch arm64 -arch x86_64 -O2 \
  -Ilibyara/include -I. \
  "$ROOT/Tools/yara-helper/maclean-yara.c" \
  "$BUILD_DIR/yara/.libs/libyara.a" \
  "$OPENSSL_DIR/lib/libcrypto.a" \
  "$OPENSSL_DIR/lib/libssl.a" \
  -lz \
  -o "$BUILD_DIR/maclean-yara"

DEST="$ROOT/Sources/MacLeanCore/Resources"
mkdir -p "$DEST/bin"
cp "$BUILD_DIR/yara/yara" "$DEST/bin/yara"
cp "$BUILD_DIR/yara/yarac" "$DEST/bin/yarac"
cp "$BUILD_DIR/maclean-yara" "$DEST/bin/maclean-yara"
cp "$BUILD_DIR/yara/COPYING" "$DEST/YARA-COPYING"
cp "$BUILD_DIR/openssl-${OPENSSL_VERSION}/LICENSE.txt" "$DEST/OPENSSL-COPYING"
chmod +x "$DEST/bin/yara" "$DEST/bin/yarac" "$DEST/bin/maclean-yara"

printf 'YARA %s\nUniversal arm64+x86_64 static build\nMacho module enabled; OpenSSL %s static; loop nesting limit 32.\n' \
  "$VERSION" "$OPENSSL_VERSION" > "$DEST/YARA-BUILD.txt"

echo "Vendored YARA into $DEST/bin"
file "$DEST/bin/yara" | head -2
