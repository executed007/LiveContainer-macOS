// LiveContainer for macOS: launch path.
//
// Included at the end of LiveContainer/LCBootstrap.m when building for Mac Catalyst, so it
// drives upstream's own invokeAppMain() (bundle, executable path, NSUserDefaults and file
// manager hooks, dyld hooks, tweak loading, entry point) and only replaces the iOS-specific
// prelude in LiveContainerMain(): app groups, JIT, SideStore and switching between
// LiveContainer copies through URL schemes.
//
// On iOS one LiveContainer process hosts one guest at a time. On a Mac every guest runs in
// its own process, started from a small launcher bundle (macOS/Runtime/launcher.c) that has
// the app's name, icon and URL schemes. The launcher loads this library and calls
// LiveContainerMacMain(). Which app and container to run come from, in order:
//   LC_SELECTED_APP / LC_SELECTED_CONTAINER environment variables (set by `lcmac run`),
//   the launcher's Info.plist (LCGuestApp), and the app's default container (LCDataUUID).

#include <sys/file.h>
#include <sys/stat.h>
#include <pwd.h>
#include <libgen.h>

void LCMacSupportInstall(NSString *settingsPath);
bool DyldHookLoadableIntoProcess(void);

// Foundation on macOS takes the temporary folder from confstr(_CS_DARWIN_USER_TEMP_DIR),
// not $TMPDIR, so the guest's NSTemporaryDirectory() is redirected explicitly.
static NSString *LCMacTemporaryDirectory;
static NSString *LCMacHookNSTemporaryDirectory(void) {
    return LCMacTemporaryDirectory;
}

static NSString *LCMacRealHome(void) {
    struct passwd *user = getpwuid(getuid());
    return user && user->pw_dir ? @(user->pw_dir) : NSHomeDirectory();
}

// No UIApplication exists yet, so errors before the guest starts use a plain system alert.
static void LCMacShowError(NSString *title, NSString *message) {
    NSLog(@"[LCMac] %@: %@", title, message);
    fprintf(stderr, "LiveContainer: %s: %s\n", title.UTF8String, message.UTF8String);
    if (getenv("LC_NO_ALERTS")) return;
    typedef SInt32 (*AlertFn)(CFTimeInterval, CFOptionFlags, CFURLRef, CFURLRef, CFURLRef,
                              CFStringRef, CFStringRef, CFStringRef, CFStringRef, CFStringRef, CFOptionFlags *);
    AlertFn alert = (AlertFn)dlsym(RTLD_DEFAULT, "CFUserNotificationDisplayAlert");
    if (alert) {
        CFOptionFlags response = 0;
        alert(0, 2 /* kCFUserNotificationCautionAlertLevel */, NULL, NULL, NULL,
              (__bridge CFStringRef)title, (__bridge CFStringRef)message, CFSTR("OK"), NULL, NULL, &response);
    }
}

// One process per container: two copies of an app writing the same files and preferences
// corrupt them. The lock is released by the kernel when the process exits, even on a crash.
static BOOL LCMacLockContainer(NSString *containerPath) {
    NSString *lockPath = [containerPath stringByAppendingPathComponent:@"LCContainer.lock"];
    int fd = open(lockPath.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return YES; // cannot create it: do not block the launch over bookkeeping
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd);
        return NO;
    }
    char pid[16];
    int length = snprintf(pid, sizeof(pid), "%d\n", getpid());
    ftruncate(fd, 0);
    pwrite(fd, pid, length, 0);
    return YES; // fd stays open for the life of the process
}

static BOOL LCMacFolderHasEntries(NSString *path) {
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil]) {
        if (![name isEqualToString:@"TweakLoader.dylib"] && ![name hasPrefix:@"."]) return YES;
    }
    return NO;
}

static NSString *LCMacTakeEnv(const char *name) {
    const char *value = getenv(name);
    NSString *result = value && *value ? @(value) : nil;
    unsetenv(name);
    return result;
}

__attribute__((visibility("default")))
int LiveContainerMacMain(int argc, char *argv[]) {
    lcMainBundle = NSBundle.mainBundle;           // the launcher bundle
    // Not standardUserDefaults: touching it now would make CoreFoundation cache the
    // launcher's bundle identifier as the "current application" for the guest's lifetime.
    lcUserDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.kdt.livecontainer.mac"];
    lcSharedDefaults = lcUserDefaults;            // no app group on a Mac
    lcAppUrlScheme = @"livecontainer";
    isLiveProcess = false;
    isSharedBundle = false;
    isSideStore = false;
    sideStoreExist = false;

    // The LiveContainer app's Frameworks folder: TweakLoader and CydiaSubstrate live next to us.
    Dl_info self;
    dladdr((const void *)LiveContainerMacMain, &self);
    char frameworks[PATH_MAX];
    strlcpy(frameworks, self.dli_fname, sizeof(frameworks));
    setenv("LC_FRAMEWORKS_PATH", dirname(frameworks), 1);

    NSDictionary *launcherInfo = lcMainBundle.infoDictionary;
    NSString *lcHome = LCMacTakeEnv("LC_HOME_PATH") ?: launcherInfo[@"LCHomePath"]
        ?: [LCMacRealHome() stringByAppendingPathComponent:@"Library/Application Support/LiveContainer"];
    setenv("LC_HOME_PATH", lcHome.fileSystemRepresentation, 1);

    NSString *selectedApp = LCMacTakeEnv("LC_SELECTED_APP") ?: launcherInfo[@"LCGuestApp"];
    NSString *selectedContainer = LCMacTakeEnv("LC_SELECTED_CONTAINER");
    lcLaunchURL = LCMacTakeEnv("LC_LAUNCH_URL");
    if (!selectedApp) {
        LCMacShowError(@"No app selected", @"This launcher does not name an app. Open the app from LiveContainer.");
        return 1;
    }

    NSString *docPath = [lcHome stringByAppendingPathComponent:@"Documents"];
    NSString *appPath = [docPath stringByAppendingPathComponent:[@"Applications" stringByAppendingPathComponent:selectedApp]];
    NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
    if (!appInfo) {
        LCMacShowError(@"App not found", [NSString stringWithFormat:@"%@ is not installed in LiveContainer (looked in %@).", selectedApp, appPath]);
        return 1;
    }
    if (!selectedContainer) selectedContainer = appInfo[@"LCDataUUID"];
    if (!selectedContainer) {
        LCMacShowError(@"No data container", [NSString stringWithFormat:@"%@ has no data container. Reinstall it.", selectedApp]);
        return 1;
    }

    NSString *containerPath = [docPath stringByAppendingPathComponent:[@"Data/Application" stringByAppendingPathComponent:selectedContainer]];
    NSString *tmpPath = [containerPath stringByAppendingPathComponent:@"tmp"];
    struct stat tmpInfo;
    if (lstat(tmpPath.fileSystemRepresentation, &tmpInfo) == 0 && S_ISLNK(tmpInfo.st_mode)) {
        unlink(tmpPath.fileSystemRepresentation);   // iOS-style symlink, e.g. from data copied off an iPhone
    }
    [NSFileManager.defaultManager createDirectoryAtPath:tmpPath withIntermediateDirectories:YES attributes:nil error:nil];
    if (!LCMacLockContainer(containerPath)) {
        NSString *name = appInfo[@"LCMacDisplayName"] ?: selectedApp;
        LCMacShowError([NSString stringWithFormat:@"%@ is already open", name],
                       @"This data container is in use by another window of the app. Use another container to run a second copy.");
        return 2;
    }

    // A private temporary folder per container. iOS gives every app its own; on a Mac all
    // processes would otherwise share the user's, and apps that empty it would clear others'.
    LCMacTemporaryDirectory = [tmpPath stringByAppendingString:@"/"];
    setenv("TMPDIR", LCMacTemporaryDirectory.fileSystemRepresentation, 1);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, NSTemporaryDirectory, LCMacHookNSTemporaryDirectory, nil);

    // Guest binaries are retargeted to Mac Catalyst at install time. Anything that is not
    // (an app installed with "Keep iOS platform", or iOS tweaks) needs dyld's platform check off.
    NSString *tweaks = [docPath stringByAppendingPathComponent:@"Tweaks"];
    NSString *tweakFolder = appInfo[@"LCTweakFolder"];
    BOOL wantsIOSBinaries = ![appInfo[@"LCMacConverted"] boolValue] || LCMacFolderHasEntries(tweaks)
        || (tweakFolder.length && LCMacFolderHasEntries([tweaks stringByAppendingPathComponent:tweakFolder]));
    if (wantsIOSBinaries && !DyldHookLoadableIntoProcess() && ![appInfo[@"LCMacConverted"] boolValue]) {
        LCMacShowError(@"Cannot load iOS binaries",
                       @"This app was installed without converting it to Mac Catalyst, and this Mac does not allow LiveContainer to relax dyld's platform check. Reinstall the app with conversion on.");
        return 1;
    }

    LCMacSupportInstall([appPath stringByAppendingPathComponent:@"LCMacSettings.plist"]);

    NSSetUncaughtExceptionHandler(&exceptionHandler);
    NSString *appError = invokeAppMain(selectedApp, selectedContainer, argc, argv);
    LCMacShowError(@"The app could not start", appError ?: @"Unknown error");
    return 1;
}
