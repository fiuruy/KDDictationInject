#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$ROOT/out"
NAME="KDDictationInject"

mkdir -p "$OUT"

xcrun clang \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=16.0 \
  -fobjc-arc \
  -O2 \
  -fPIC \
  -dynamiclib \
  -framework Foundation \
  -framework UIKit \
  -framework WebKit \
  -framework Speech \
  -framework AVFoundation \
  -framework QuartzCore \
  -o "$OUT/$NAME.dylib" \
  "$ROOT/Source/Tweak.m"

codesign --force --sign - --identifier "com.kddictation.inject" "$OUT/$NAME.dylib"
file "$OUT/$NAME.dylib"
zip -j "$OUT/$NAME.zip" "$OUT/$NAME.dylib"
