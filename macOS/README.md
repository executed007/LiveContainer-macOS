# LiveContainer for macOS

**Run iOS apps natively on Apple silicon Macs, LiveContainer-style:** one manager, many apps,
and as many separate data containers per app as you like, each running in its own Mac window.

This folder is the Mac port of [LiveContainer](https://github.com/LiveContainer/LiveContainer).
It reuses LiveContainer's own runtime (`LiveContainer/`, `TweakLoader/`): the guest bootstrap,
the dyld hooks, and the NSUserDefaults, file manager and app group isolation. It adds what a
Mac needs on top, taking the Mac Catalyst conversion and window adaptations from Catalyst
Runner and PlayCover.

> You bring your own **decrypted** `.ipa`. App Store downloads are FairPlay-encrypted and are refused.

## What you get

| | |
|---|---|
| **Containers** | Each app can have several data containers: separate logins, keychain, preferences and files. Use one for work and one for personal, or keep a clean profile for testing. |
| **Run several at once** | Every app, and every container, runs in its own process with its own Dock icon. Two accounts of the same app can be open side by side. On iOS, LiveContainer needs extra copies of itself or its multitasking mode for this. |
| **A real Mac app per iOS app** | Each app gets a small launcher with its name, icon, URL schemes and permission texts. *Add to Applications* puts it in Launchpad and Spotlight. `tiktok://` links and sign-in callbacks reach the right app. |
| **Fast install** | No per-app sandbox signing. Binaries are converted in parallel, copies are APFS clones, and signing runs in parallel per nesting level. A 520 MB TikTok `.ipa` installs in about 8 seconds. |
| **Updates keep everything** | Installing a newer `.ipa` keeps containers, keychain and settings. The launcher is only rewritten when something it shows changes, so macOS doesn't ask for camera access again after every update. |
| **Tweaks** | Upstream's TweakLoader with CydiaSubstrate: global tweaks plus per-app tweak sets. iOS tweaks are converted when imported; on Macs that allow it, unconverted iOS dylibs load too. |
| **LiveContainer options** | Hide LiveContainer from the app, report a different iOS SDK version, run in another language, and give each container its own identifierForVendor. |
| **Mac adaptations** | Full-height windows, phone or tablet size at launch, a volume control for each app, arrow keys through swipe feeds, and an upright portrait camera image. |

## Install

```bash
macOS/build.sh            # needs only the Xcode Command Line Tools
open macOS/build/LiveContainer.app
```

Move `LiveContainer.app` to `/Applications` if you like. App launchers find it there, and they
are refreshed automatically when LiveContainer moves. Drop an `.ipa` on the window to install it.

Command line: `LiveContainer.app/Contents/MacOS/lcmac` (also at `macOS/build/lcmac`).

```bash
lcmac install TikTok.ipa --run
lcmac list
lcmac container add TikTok Work
lcmac run TikTok --container Work      # runs alongside the default container
lcmac set TikTok spoofSDKVersion 17.0
lcmac mac TikTok windowSize phone
lcmac tweak add MyTweak.dylib --folder TikTokTweaks
lcmac set TikTok tweakFolder TikTokTweaks
lcmac export TikTok                    # put it in ~/Applications
lcmac container backup TikTok Work ~/Desktop/Work.lcbackup   # keychain included
lcmac container restore TikTok ~/Desktop/Work.lcbackup        # always a new container
lcmac container clear-caches TikTok Work
lcmac reset-permissions TikTok
lcmac uninstall TikTok                 # data kept unless --delete-data
lcmac help
```

## Where things are

Upstream's layout, under `~/Library/Application Support/LiveContainer/`:

```
Documents/Applications/<bundle id>.app   installed apps, with LCAppInfo.plist and LCMacSettings.plist
Documents/Data/Application/<UUID>/       containers: each one is the app's home folder
Documents/Data/AppGroup/<group>/         app group folders
Documents/Tweaks/                        global tweaks; subfolders are per-app tweak sets
Launchers/<bundle id>.app                the Mac launchers (moved to ~/Applications when exported)
```

`LC_HOME_PATH` changes the location; the tests use it to run in a temporary folder.

## How it works

1. **Install** (`Sources/Installer.swift`)
   - Thin every Mach-O to arm64 and refuse FairPlay-encrypted ones.
   - Retarget each binary to Mac Catalyst. This is PlayCover's `LC_BUILD_VERSION` rewrite; see Catalyst Runner's `EVIDENCE.md`.
   - Apply LiveContainer's executable patch (upstream `LCPatchExecSlice`, ported to Swift in `Sources/LiveContainerPatch.swift`): `MH_EXECUTE` becomes `MH_DYLIB`, `__PAGEZERO` shrinks to one page, an `LC_ID_DYLIB` and the TweakLoader load command are added, and duplicate dependencies are dropped.
   - Sign everything ad hoc and write `LCAppInfo.plist`.
2. **Launcher** (`Sources/Launchers.swift`, `Runtime/launcher.c`)
   - A tiny Mac Catalyst app whose Info.plist carries the guest's name, URL types and usage descriptions, plus a Mac icon.
   - Its executable contains no app code: it loads `LiveContainerMac.dylib` from LiveContainer and calls `LiveContainerMacMain`.
3. **Runtime** (`Runtime/LCMacBootstrap.inc.m`, compiled into `LiveContainer/LCBootstrap.m`)
   - Picks the app and container, takes a file lock so a container is only open once, and gives the container a private temporary folder.
   - Hands over to upstream's `invokeAppMain()`, which swaps `NSBundle`/`CFBundle.mainBundle` and `@executable_path`, points `HOME` at the container, hooks NSUserDefaults and app groups, then `dlopen`s the app and jumps to its `main()`.
4. **Keychain** (`Runtime/LCMacKeychain.m`)
   - Upstream separates containers with 128 keychain access groups, which needs entitlements an ad hoc Mac app cannot have.
   - On a Mac, password items are kept per container in `<container>/LCKeychain.plist` instead.
5. **Mac adaptations** (`Runtime/LCMacSupport.m`): Catalyst Runner's RunnerShim, configured per app.

### Changes to upstream files

All guarded by `TARGET_OS_MACCATALYST` unless noted; `git diff upstream/main -- LiveContainer TweakLoader` shows them.

- `Tweaks/Dyld.m`
  - macOS 26 renamed dyld's platform check to `mach_o::UnsafeHeader::loadableIntoProcess`, so upstream's Catalyst path asserted. It is now read from `/usr/lib/dyld` on disk, under either name, and fails soft.
  - `dlopen_nolock` uses a plain `dlopen`, because the lock hooks need shared-cache `.symbols`, which macOS doesn't ship.
- `Tweaks/NSUserDefaults.m`
  - System framework paths use `Versions/A`, and CoreFoundation is searched from image 0.
  - The private `_CFPrefsCurrentAppIdentifierCache` is not needed: the Mac bootstrap keeps preferences untouched until the guest's bundle is in place.
- `LCBootstrap.m`
  - No JIT or JIT-less requirement on a Mac.
  - The TweakLoader location comes from the runtime.
  - The keychain hooks are the Mac ones.
  - No tmp self-symlink.
  - The Mac entry point is included.
- `LCSharedUtils.m`
  - *(all platforms)* `teamIdentifier` no longer crashes on `CFGetTypeID(NULL)` when there is no team entitlement.
  - On Mac, `appGroupID` is fixed, so it never probes or creates `~/Library/Group Containers`.
- `NSFileManager+GuestHooks.m`, `FoundationPrivate.h`, `LCMachOUtils.h`, `TweakLoader.m`: Mac framework paths, guards and header conflicts.

### Preferences editor

The editor (`App/PlistEditor.swift`, `Sources/Preferences.swift`) works on the `.plist` files in a container's
`Library/Preferences`. It reads them with `defaults export` and saves them with `defaults import`, both of which go
through `cfprefsd`. Writing the file directly does not work: `cfprefsd` keeps its own copy, hands that to the app,
and later writes it back over the edit. The paths given to `defaults` are resolved first, because `cfprefsd` does
not find a file spelled `/var/folders/…`, only `/private/var/folders/…`.

### Backups

A `.lcbackup` file is a zip of the container's folder, keychain included, plus `LiveContainerBackup.plist`
naming the app. A backup is only restored into the same app, and always as a new container. Running containers
are not backed up, because their databases may be mid-write.

## Tests

```bash
macOS/build.sh       # unit tests: Mach-O conversion, the LiveContainer patch, the library model, the keychain store
macOS/test-live.sh   # 40 end-to-end checks on a real UIKit app, in a temporary library
```

`test-live.sh` installs an iOS fixture and checks what the app sees from inside its container:
- bundle identifier, Info.plist, home, tmp, preferences, keychain and app group;
- that a second container is isolated, and that both run at once in two processes;
- that an update keeps data;
- that both kinds of tweak load;
- that uninstall cleans up.

## Tested with

| | |
|---|---|
| TikTok | 47.7.0 (build 477034): installs in 8 s, launches and reaches its sign-in screen |
| Mac | macOS 26.6.2 on Apple silicon, Command Line Tools only |

## Limits

- **Apple silicon only.** Encrypted App Store apps are refused.
- **The dyld platform patch** lets unconverted iOS binaries load. It was verified on a Mac whose SIP configuration has debugging restrictions off, and it is untested on a stock configuration. Nothing depends on it by default: apps and imported tweaks are converted at install. If the patch is refused, only raw iOS dylibs dropped into Tweaks by hand fail to load.
- **The keychain store is a property list readable by your user account** (mode 0600), not the system keychain. Treat it like any other app data in your home folder.
- **Language override** sets `AppleLanguages` for the app. Bundle localization caches that the iOS build overwrites through private symbols can't be reached on macOS.
- **Not available:** app extensions (widgets, share extensions), remote push notifications, and frameworks macOS does not ship for Catalyst.
- **Guests are not sandboxed**, as in upstream: an app can read other containers' files.
