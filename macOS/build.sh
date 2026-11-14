#!/bin/sh
# Builds LiveContainer for macOS with the Xcode Command Line Tools (no Xcode project needed).
#
#   macOS/build.sh           build everything into macOS/build/ and run the unit tests
#   macOS/build.sh runtime   build only the runtime pieces (fast iteration)
#
# Output: macOS/build/LiveContainer.app and macOS/build/lcmac (command-line tool).
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/macOS/build"
SDK="$(xcrun --show-sdk-path)"
CATALYST="arm64-apple-ios15.0-macabi"
MACOS="arm64-apple-macos14.0"
mkdir -p "$OUT"

[ -f litehook/src/litehook.c ] || git submodule update --init --depth 1 litehook

CFLAGS="-fobjc-arc -fmodules -O2 -target $CATALYST -isysroot $SDK
  -iframework $SDK/System/iOSSupport/System/Library/Frameworks
  -Ilitehook/src -Ilitehook/external/include -ILiveContainer -ILiveContainerSwiftUI/Utilities
  -Wno-deprecated-declarations -Wno-unused-variable -Wno-unguarded-availability-new -Wno-nullability-completeness"

echo "== Runtime: LiveContainerMac.dylib (upstream LiveContainer + macOS/Runtime)"
# shellcheck disable=SC2086
xcrun clang -dynamiclib $CFLAGS \
    LiveContainer/LCBootstrap.m LiveContainer/LCMachOUtils.m LiveContainer/LCSharedUtils.m \
    LiveContainer/Localization.m LiveContainer/dyld_bypass_validation.m LiveContainer/utils.m \
    LiveContainer/Tweaks/Dead10ccFix.m LiveContainer/Tweaks/Dyld.m LiveContainer/Tweaks/IDFV.m \
    LiveContainer/Tweaks/NSBundle+FixCydiaSubstrate.m LiveContainer/Tweaks/NSExtension+GuestHooks.m \
    LiveContainer/Tweaks/NSFileManager+GuestHooks.m LiveContainer/Tweaks/NSURLSessionConfiguration+GuestHooks.m \
    LiveContainer/Tweaks/NSUserDefaults.m LiveContainer/Tweaks/SecItem.m LiveContainer/Tweaks/mach_excServer.c \
    litehook/src/litehook.c \
    macOS/Runtime/LCMacSupport.m macOS/Runtime/LCMacKeychain.m \
    -framework UIKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
    -framework QuartzCore -framework AudioToolbox -framework Security \
    -install_name @rpath/LiveContainerMac.dylib -o "$OUT/LiveContainerMac.dylib"

echo "== Runtime: TweakLoader.dylib"
# shellcheck disable=SC2086
xcrun clang -dynamiclib $CFLAGS TweakLoader/TweakLoader.m -framework UIKit \
    -undefined dynamic_lookup -install_name @rpath/TweakLoader.dylib -o "$OUT/TweakLoader.dylib"

echo "== Runtime: launcher"
xcrun clang -O2 -target "$CATALYST" -isysroot "$SDK" macOS/Runtime/launcher.c \
    -framework CoreFoundation -o "$OUT/LCLauncher"

echo "== Runtime: CydiaSubstrate (upstream's, retargeted to Mac Catalyst)"
rm -rf "$OUT/CydiaSubstrate.framework"
cp -R Resources/Frameworks/CydiaSubstrate.framework "$OUT/"
vtool -set-build-version maccatalyst 14.0 17.0 -replace -output "$OUT/CydiaSubstrate.framework/CydiaSubstrate" \
    Resources/Frameworks/CydiaSubstrate.framework/CydiaSubstrate 2>/dev/null
codesign --force --sign - "$OUT/CydiaSubstrate.framework" 2>/dev/null

for f in LiveContainerMac.dylib TweakLoader.dylib LCLauncher; do codesign --force --sign - "$OUT/$f" 2>/dev/null; done
[ "${1:-}" = runtime ] && exit 0

echo "== Unit tests"
swiftc -O -target "$MACOS" macOS/Sources/MachO.swift macOS/Sources/LiveContainerPatch.swift macOS/Sources/Library.swift \
    macOS/Tests/main.swift -o "$OUT/unit-tests"
"$OUT/unit-tests"
# shellcheck disable=SC2086
xcrun clang $CFLAGS -framework Security macOS/Runtime/LCMacKeychain.m litehook/src/litehook.c \
    macOS/Tests/keychain-test.m -o "$OUT/keychain-tests"
"$OUT/keychain-tests"

SWIFT_SOURCES="macOS/Sources/MachO.swift macOS/Sources/LiveContainerPatch.swift macOS/Sources/Library.swift
  macOS/Sources/Installer.swift macOS/Sources/Launchers.swift macOS/Sources/MacIcon.swift"

echo "== lcmac (command-line tool)"
# shellcheck disable=SC2086
swiftc -O -target "$MACOS" $SWIFT_SOURCES macOS/CLI/main.swift -o "$OUT/lcmac"
codesign --force --sign - "$OUT/lcmac"

echo "== LiveContainer.app"
APPDIR="$OUT/LiveContainer.app"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Frameworks" "$APPDIR/Contents/Resources"
cp macOS/App/Info.plist "$APPDIR/Contents/Info.plist"
swiftc -O -target "$MACOS" macOS/Sources/MacIcon.swift macOS/App/IconTool/main.swift -o "$OUT/make-icon"
"$OUT/make-icon" screenshots/AppIcon1024.png "$APPDIR/Contents/Resources/AppIcon.icns"
cp -R "$OUT/LiveContainerMac.dylib" "$OUT/TweakLoader.dylib" "$OUT/LCLauncher" "$OUT/CydiaSubstrate.framework" "$APPDIR/Contents/Frameworks/"
cp "$OUT/lcmac" "$APPDIR/Contents/MacOS/lcmac"
# shellcheck disable=SC2086
swiftc -O -parse-as-library -target "$MACOS" $SWIFT_SOURCES macOS/App/App.swift -o "$APPDIR/Contents/MacOS/LiveContainer"
codesign --force --sign - "$APPDIR/Contents/MacOS/lcmac"
codesign --force --sign - "$APPDIR"
echo "Built $APPDIR"
echo "Command-line tool: $APPDIR/Contents/MacOS/lcmac (also $OUT/lcmac)"
