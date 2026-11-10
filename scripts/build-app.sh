#!/bin/sh
# Собирает Rust-ядро, Swift-привязки и "build/VPN Lens.app".
#
#   scripts/build-app.sh              release-сборка под архитектуру этого Mac
#   scripts/build-app.sh --universal  Apple Silicon + Intel (нужен rustup)
#   scripts/build-app.sh --zip        ещё и архив для релиза с SHA-256
#   scripts/build-app.sh --run        собрать и запустить
set -eu

cd "$(dirname "$0")/.."
ROOT=$(pwd)
MACOS="$ROOT/macos"
export MACOSX_DEPLOYMENT_TARGET=14.0

UNIVERSAL=0 ZIP=0 RUN=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --zip) ZIP=1 ;;
        --run) RUN=1 ;;
        *) echo "непонятный аргумент: $arg" >&2; exit 2 ;;
    esac
done

echo "== rust"
if [ "$UNIVERSAL" = 1 ]; then
    command -v rustup >/dev/null || { echo "для --universal нужен rustup" >&2; exit 1; }
    rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
    for target in aarch64-apple-darwin x86_64-apple-darwin; do
        cargo build -p vpnlens-core --release --target "$target"
    done
    mkdir -p target/universal
    lipo -create \
        target/aarch64-apple-darwin/release/libvpnlens_core.a \
        target/x86_64-apple-darwin/release/libvpnlens_core.a \
        -output target/universal/libvpnlens_core.a
    STATIC="$ROOT/target/universal/libvpnlens_core.a"
    DYLIB="$ROOT/target/aarch64-apple-darwin/release/libvpnlens_core.dylib"
    SWIFT_TRIPLES="arm64-apple-macosx14.0 x86_64-apple-macosx14.0"
else
    cargo build -p vpnlens-core --release
    STATIC="$ROOT/target/release/libvpnlens_core.a"
    DYLIB="$ROOT/target/release/libvpnlens_core.dylib"
    SWIFT_TRIPLES=""
fi

echo "== uniffi"
GEN="$MACOS/Generated"
rm -rf "$GEN" && mkdir -p "$GEN"
cargo run -q -p uniffi-bindgen -- generate --library "$DYLIB" --language swift --out-dir "$GEN"
# Папки нет в git: в ней только сгенерированный файл, а он в .gitignore.
mkdir -p "$MACOS/Sources/VPNLensCore"
cp "$GEN/vpnlens_core.swift" "$MACOS/Sources/VPNLensCore/vpnlens_core.swift"

HEADERS="$GEN/headers"
mkdir -p "$HEADERS"
cp "$GEN/vpnlens_coreFFI.h" "$HEADERS/"
cp "$GEN/vpnlens_coreFFI.modulemap" "$HEADERS/module.modulemap"
rm -rf "$MACOS/Frameworks/VPNLensCoreFFI.xcframework"
xcodebuild -create-xcframework -library "$STATIC" -headers "$HEADERS" \
    -output "$MACOS/Frameworks/VPNLensCoreFFI.xcframework" >/dev/null

echo "== swift"
if [ -n "$SWIFT_TRIPLES" ]; then
    # Каждая архитектура отдельно, потом lipo. С "--arch arm64 --arch x86_64" SwiftPM
    # собирает через xcbuild, а компоновщик Xcode 16 падает на его склеенном модуле.
    BIN="$ROOT/target/universal/VPNLens"
    rm -f "$BIN"
    for triple in $SWIFT_TRIPLES; do
        swift build -c release --package-path "$MACOS" --triple "$triple"
        SLICE="$(swift build -c release --package-path "$MACOS" --triple "$triple" --show-bin-path)/VPNLens"
        if [ -f "$BIN" ]; then
            lipo -create "$BIN" "$SLICE" -output "$BIN"
        else
            cp "$SLICE" "$BIN"
        fi
    done
else
    swift build -c release --package-path "$MACOS"
    BIN="$(swift build -c release --package-path "$MACOS" --show-bin-path)/VPNLens"
fi

echo "== bundle"
APP="$ROOT/build/VPN Lens.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VPNLens"
cp "$MACOS/Info.plist" "$APP/Contents/Info.plist"
cp "$MACOS/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$MACOS/Resources/"*.lproj "$APP/Contents/Resources/"
# Подпись ad-hoc: без аккаунта Apple Developer нотаризация недоступна.
codesign --force --sign - "$APP" >/dev/null
echo "$APP ($(lipo -archs "$APP/Contents/MacOS/VPNLens"))"

if [ "$ZIP" = 1 ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MACOS/Info.plist")
    ARCHIVE="$ROOT/build/VPN-Lens-$VERSION.zip"
    rm -f "$ARCHIVE"
    ditto -c -k --keepParent "$APP" "$ARCHIVE"
    (cd "$ROOT/build" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
    echo "$ARCHIVE"
fi

if [ "$RUN" = 1 ]; then
    pkill -x VPNLens 2>/dev/null || true
    open "$APP"
fi
