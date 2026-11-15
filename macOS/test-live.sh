#!/bin/sh
# End-to-end test of LiveContainer for macOS on a real UIKit app.
#
# Builds an iOS fixture .ipa, then with lcmac: installs it, runs it, checks what the app
# sees from inside its container, adds a second container and runs both at once, updates
# the app, loads tweaks (one imported, one left as an iOS binary), and uninstalls.
# Everything happens in a temporary LC_HOME_PATH; the real library is never touched.
set -eu
cd "$(dirname "$0")/.."
[ -x macOS/build/lcmac ] || macOS/build.sh
LCMAC="$PWD/macOS/build/lcmac"
WORK="$(mktemp -d)"
export LC_HOME_PATH="$WORK/home"
export LC_NO_ALERTS=1
cleanup() { pkill -f "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
SDK="$(xcrun --show-sdk-path)"
PASS=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
fail() { echo "FAIL $1"; exit 1; }
check() { # check <description> <command...>: fails the test when the command fails
    name="$1"; shift
    if "$@"; then ok "$name"; else fail "$name"; fi
}
equals() { [ "$1" = "$2" ] || { echo "     expected \"$2\", got \"$1\""; return 1; }; }
contains() { case "$1" in *"$2"*) return 0;; *) echo "     \"$1\" does not contain \"$2\""; return 1;; esac; }
running() { pgrep -f "$LAUNCHER/Contents/MacOS/Fixture" | wc -l | tr -d ' '; }

probe() { # probe <container folder> <key>
    python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" \
        "$LC_HOME_PATH/Documents/Data/Application/$1/Documents/probe.json" "$2"
}
wait_for() { # wait_for <file> [seconds]
    i=0; while [ ! -e "$1" ] && [ $i -lt "${2:-20}" ]; do sleep 1; i=$((i + 1)); done; [ -e "$1" ]
}
wait_gone() { # wait_gone <pattern>
    i=0; while pgrep -f "$1" >/dev/null && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done
}

echo "== Building the iOS fixture"
# The Command Line Tools ship no iPhoneOS SDK, so link against the Catalyst UIKit and then
# stamp the binary as a real iOS one (platform 2), which is what an .ipa contains.
APP="$WORK/Payload/Fixture.app"
mkdir -p "$APP"
swiftc -O -parse-as-library -target arm64-apple-ios15.0-macabi -sdk "$SDK" \
    -Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -I "$SDK/System/iOSSupport/usr/lib/swift" -L "$SDK/System/iOSSupport/usr/lib/swift" \
    -Xlinker -headerpad -Xlinker 0x1000 macOS/Tests/Fixture/App.swift -o "$WORK/Fixture.catalyst"
vtool -set-build-version ios 15.0 17.0 -replace -output "$APP/Fixture" "$WORK/Fixture.catalyst" 2>/dev/null
cat > "$APP/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.livecontainer.fixture</string>
  <key>CFBundleExecutable</key><string>Fixture</string>
  <key>CFBundleName</key><string>Fixture</string>
  <key>CFBundleDisplayName</key><string>Fixture App</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>15.0</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>FixtureMarker</key><string>guest-info</string>
  <key>NSCameraUsageDescription</key><string>Fixture camera text</string>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>lcfixture</string></array></dict></array>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
EOF
swift -e 'import AppKit; let i = NSImage(size: NSSize(width: 180, height: 180)); i.lockFocus(); NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 180, height: 180).fill(); i.unlockFocus(); try! NSBitmapImageRep(data: i.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))' "$APP/AppIcon60x60@3x.png" 2>/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons dict" -c "Add :CFBundleIcons:CFBundlePrimaryIcon dict" \
    -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" \
    -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon60x60" "$APP/Info.plist"
(cd "$WORK" && zip -qr Fixture.ipa Payload)
check "fixture is an iOS binary" contains "$("$LCMAC" inspect "$APP/Fixture")" "platform iOS"

echo "== Install"
"$LCMAC" install "$WORK/Fixture.ipa"
INSTALLED="$LC_HOME_PATH/Documents/Applications/dev.livecontainer.fixture.app"
check "executable retargeted to Mac Catalyst" contains "$("$LCMAC" inspect "$INSTALLED/Fixture")" "platform Mac Catalyst"
check "executable patched to a dylib" contains "$("$LCMAC" inspect "$INSTALLED/Fixture")" "file type dylib"
# Only the code signature matters to dyld; LCAppInfo.plist is added after signing, as upstream does.
check "executable signed" contains "$(codesign -dv "$INSTALLED/Fixture" 2>&1)" "Signature=adhoc"
LAUNCHER="$LC_HOME_PATH/Launchers/dev.livecontainer.fixture.app"
check "launcher made and signed" codesign --verify --strict "$LAUNCHER"
check "launcher carries the app's permission texts" \
    equals "$(/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$LAUNCHER/Contents/Info.plist")" "Fixture camera text"
check "launcher registers the app's URL scheme" \
    equals "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$LAUNCHER/Contents/Info.plist")" lcfixture
check "launcher has a Mac icon made from the app's" test -f "$LAUNCHER/Contents/Resources/AppIcon.icns"
DEFAULT="$("$LCMAC" containers Fixture | awk 'NR==1 {print $3}')"
check "default container created" test -n "$DEFAULT"

echo "== Run"
"$LCMAC" run Fixture --env LC_FIXTURE_QUIT=1 --wait
check "app sees its own bundle identifier" equals "$(probe "$DEFAULT" bundleIdentifier)" dev.livecontainer.fixture
check "app reads its own Info.plist" equals "$(probe "$DEFAULT" infoValue)" guest-info
check "home folder is the container" contains "$(probe "$DEFAULT" home)" "/Data/Application/$DEFAULT"
check "temporary folder is inside the container" contains "$(probe "$DEFAULT" tmp)" "/Data/Application/$DEFAULT/tmp/"
check "keychain works" equals "$(probe "$DEFAULT" keychainStatus)" 0
check "app group container provided" contains "$(probe "$DEFAULT" appGroup)" "/Documents/Data/AppGroup/group.dev.livecontainer.fixture"
check "preferences saved in the container" \
    test -f "$LC_HOME_PATH/Documents/Data/Application/$DEFAULT/Library/Preferences/dev.livecontainer.fixture.plist"
"$LCMAC" run Fixture --env LC_FIXTURE_QUIT=1 --wait
check "preferences persist between launches" equals "$(probe "$DEFAULT" defaultsLaunches)" 2
check "keychain persists between launches" equals "$(probe "$DEFAULT" keychainLaunches)" 2

echo "== Second container"
"$LCMAC" container add Fixture Work >/dev/null
WORKC="$("$LCMAC" containers Fixture | awk '$1 == "Work" {print $2}')"
"$LCMAC" run Fixture --container Work --env LC_FIXTURE_QUIT=1 --wait
check "a new container has its own preferences" equals "$(probe "$WORKC" defaultsLaunches)" 1
check "a new container has its own keychain" equals "$(probe "$WORKC" keychainLaunches)" 1
check "the other container is untouched" equals "$(probe "$DEFAULT" defaultsLaunches)" 2

echo "== Two containers at once"
rm -f "$LC_HOME_PATH/Documents/Data/Application/$DEFAULT/Documents/probe.json" "$LC_HOME_PATH/Documents/Data/Application/$WORKC/Documents/probe.json"
"$LCMAC" run Fixture
"$LCMAC" run Fixture --container Work
check "default container running" wait_for "$LC_HOME_PATH/Documents/Data/Application/$DEFAULT/Documents/probe.json"
check "second container running" wait_for "$LC_HOME_PATH/Documents/Data/Application/$WORKC/Documents/probe.json"
check "in two separate processes" equals "$(running)" 2
check "lcmac list shows them running" contains "$("$LCMAC" list)" "Default (default, running)"
"$LCMAC" run Fixture
sleep 2
check "opening a running container brings it forward instead of starting a copy" equals "$(running)" 2
pkill -f "$LAUNCHER/Contents/MacOS/Fixture"; wait_gone "$LAUNCHER/Contents/MacOS/Fixture"

echo "== Update"
"$LCMAC" install "$WORK/Fixture.ipa" >/dev/null
"$LCMAC" run Fixture --env LC_FIXTURE_QUIT=1 --wait
check "updating keeps preferences" equals "$(probe "$DEFAULT" defaultsLaunches)" 4
check "updating keeps the keychain" equals "$(probe "$DEFAULT" keychainLaunches)" 4
check "updating keeps both containers" equals "$("$LCMAC" containers Fixture | wc -l | tr -d ' ')" 2

echo "== Preferences"
# Through cfprefsd, as the app's editor saves (writing the file directly gets overwritten).
# pwd -P: cfprefsd does not find files spelled /var/folders/... (mktemp's), only /private/var/...
PREFS="$(cd "$("$LCMAC" path Fixture)/Library/Preferences" && pwd -P)/dev.livecontainer.fixture.plist"
defaults write "$PREFS" launches -int 50
"$LCMAC" run Fixture --env LC_FIXTURE_QUIT=1 --wait
check "an edited preference reaches the app" equals "$(probe "$DEFAULT" defaultsLaunches)" 51

echo "== Backup and restore"
"$LCMAC" container backup Fixture Default "$WORK/Default.lcbackup" >/dev/null
check "backup file written" test -s "$WORK/Default.lcbackup"
"$LCMAC" container restore Fixture "$WORK/Default.lcbackup" >/dev/null
RESTORED="$("$LCMAC" containers Fixture | awk '/restored/ {print $3}')"
check "restored as a new container" test -n "$RESTORED"
"$LCMAC" run Fixture --container "$RESTORED" --env LC_FIXTURE_QUIT=1 --wait
check "restored preferences carry on" equals "$(probe "$RESTORED" defaultsLaunches)" 52
check "restored keychain carries on" equals "$(probe "$RESTORED" keychainLaunches)" 6
"$LCMAC" container clear-caches Fixture Default
check "clearing caches keeps the data" equals "$(defaults read "$PREFS" launches)" 51

echo "== Tweaks"
xcrun clang -dynamiclib -fobjc-arc -target arm64-apple-ios15.0-macabi -isysroot "$SDK" -DTWEAK_NAME='"imported"' \
    -framework Foundation macOS/Tests/Fixture/Tweak.m -o "$WORK/Imported.catalyst"
vtool -set-build-version ios 15.0 17.0 -replace -output "$WORK/Imported.dylib" "$WORK/Imported.catalyst" 2>/dev/null
"$LCMAC" tweak add "$WORK/Imported.dylib" >/dev/null
# An iOS tweak dropped straight into the folder, as users do: loads through the dyld patch.
xcrun clang -dynamiclib -fobjc-arc -target arm64-apple-ios15.0-macabi -isysroot "$SDK" -DTWEAK_NAME='"raw"' \
    -framework Foundation macOS/Tests/Fixture/Tweak.m -o "$WORK/Raw.catalyst"
vtool -set-build-version ios 15.0 17.0 -replace -output "$LC_HOME_PATH/Documents/Tweaks/Raw.dylib" "$WORK/Raw.catalyst" 2>/dev/null
codesign --force --sign - "$LC_HOME_PATH/Documents/Tweaks/Raw.dylib" 2>/dev/null
"$LCMAC" run Fixture --env LC_FIXTURE_QUIT=1 --wait
DOCS="$LC_HOME_PATH/Documents/Data/Application/$DEFAULT/Documents"
check "imported tweak loaded into the app" equals "$(cat "$DOCS/imported-loaded" 2>/dev/null)" dev.livecontainer.fixture
if [ "$(cat "$DOCS/raw-loaded" 2>/dev/null)" = dev.livecontainer.fixture ]; then
    ok "unconverted iOS tweak loaded (dyld platform patch works on this Mac)"
else
    echo "note unconverted iOS tweak not loaded: this Mac does not allow the dyld platform patch; use lcmac tweak add"
fi

echo "== Uninstall"
"$LCMAC" uninstall Fixture --delete-data >/dev/null
check "app removed" test ! -e "$INSTALLED"
check "launcher removed" test ! -e "$LAUNCHER"
check "data removed" test ! -e "$LC_HOME_PATH/Documents/Data/Application/$DEFAULT"

echo "All $PASS end-to-end checks passed"
