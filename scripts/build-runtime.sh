#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVISION="1e411d8f5a1e23525fa3265dfb4bd76265465397"
ARCHIVE_SHA256="e7b9788ae7d41bf388ce4f89d38d372ed17aab2c2da1169f7620acb8419c8e51"
CACHE="${HAIWANG_BUILD_CACHE:-$HOME/Library/Caches/HaiwangDevelopment/runtime}"
SOURCE="$CACHE/llama.cpp-$REVISION"
ARCHIVE="$CACHE/llama-$REVISION.tar.gz"
BUILD="$CACHE/build-$REVISION-macos-arm64"
CMAKE="$(command -v cmake || true)"
if [[ -z "$CMAKE" && -x /opt/homebrew/bin/cmake ]]; then CMAKE=/opt/homebrew/bin/cmake; fi
if [[ -z "$CMAKE" ]]; then echo 'Install CMake: brew install cmake' >&2; exit 1; fi
mkdir -p "$CACHE" "$ROOT/Runtime/Licenses"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 3 --output "$ARCHIVE.partial" \
        "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$REVISION"
    mv "$ARCHIVE.partial" "$ARCHIVE"
fi
ACTUAL="$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)"
if [[ "$ACTUAL" != "$ARCHIVE_SHA256" ]]; then echo 'Runtime source checksum mismatch.' >&2; exit 1; fi
if [[ ! -f "$SOURCE/CMakeLists.txt" ]]; then tar -xzf "$ARCHIVE" -C "$CACHE"; fi
PATCH="$ROOT/Runtime/Patches/hy-mt2-legacy-stq.patch"
if patch -d "$SOURCE" -p1 -N -f --dry-run < "$PATCH" >/dev/null 2>&1; then
    patch -d "$SOURCE" -p1 -N -f < "$PATCH"
elif ! patch -d "$SOURCE" -p1 -R -f --dry-run < "$PATCH" >/dev/null 2>&1; then
    echo 'Runtime compatibility patch no longer matches the pinned source.' >&2
    exit 1
fi

"$CMAKE" -S "$SOURCE" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_CURL=OFF \
    -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16 \
    -DGGML_METAL=OFF -DGGML_BLAS=ON -DGGML_ACCELERATE=ON \
    -DGGML_OPENMP=OFF -DGGML_BACKEND_DL=OFF \
    -DGGML_CPU_KLEIDIAI=OFF -DGGML_LLAMAFILE=ON
"$CMAKE" --build "$BUILD" --config Release --target llama --parallel "${HAIWANG_BUILD_JOBS:-4}"

xcrun clang++ -std=c++17 -O3 -DNDEBUG -arch arm64 -mmacosx-version-min=15.0 \
    -I "$ROOT/Runtime/include" -I "$SOURCE/include" -I "$SOURCE/ggml/include" \
    -c "$ROOT/Runtime/src/CHaHaRuntime.cpp" -o "$BUILD/CHaHaRuntime.o"
xcrun libtool -static -o "$BUILD/libCHaHaRuntime.a" \
    "$BUILD/CHaHaRuntime.o" "$BUILD/src/libllama.a" \
    "$BUILD/ggml/src/libggml.a" "$BUILD/ggml/src/libggml-base.a" \
    "$BUILD/ggml/src/libggml-cpu.a" "$BUILD/ggml/src/ggml-blas/libggml-blas.a"

cp "$SOURCE/LICENSE" "$ROOT/Runtime/Licenses/llama.cpp-MIT.txt"
cp "$SOURCE/licenses/LICENSE-jsonhpp" "$ROOT/Runtime/Licenses/jsonhpp-MIT.txt"
sed -n '1,21p' "$SOURCE/ggml/src/ggml-cpu/llamafile/sgemm.cpp" | sed 's|^// *||' \
    > "$ROOT/Runtime/Licenses/llamafile-MIT.txt"
mkdir -p "$ROOT/Resources/Licenses"
cp "$ROOT/Runtime/Licenses/"*.txt "$ROOT/Resources/Licenses/"
STAGING="$CACHE/CHaHaRuntime.xcframework"
if [[ -d "$STAGING" ]]; then rm -rf "$STAGING"; fi
xcodebuild -create-xcframework -library "$BUILD/libCHaHaRuntime.a" \
    -headers "$ROOT/Runtime/include" -output "$STAGING"
if [[ -d "$ROOT/Runtime/CHaHaRuntime.xcframework" ]]; then rm -rf "$ROOT/Runtime/CHaHaRuntime.xcframework"; fi
ditto "$STAGING" "$ROOT/Runtime/CHaHaRuntime.xcframework"
echo "Built $ROOT/Runtime/CHaHaRuntime.xcframework"
