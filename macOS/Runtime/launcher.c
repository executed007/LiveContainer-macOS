// The executable of each app's launcher bundle.
//
// A launcher is a tiny Mac Catalyst app with the guest's name, icon, Info.plist and URL
// schemes, so the guest gets its own Dock icon, menu bar name and camera/microphone
// permissions. It contains no app code: it loads LiveContainer's runtime from the
// LiveContainer app and hands over, the same way LiveContainer's own main.c loads
// LiveContainerShared on iOS.
//
// Where the runtime is: $LC_MAC_RUNTIME, then the LCMacRuntime key in Info.plist (written
// when the launcher is made), then the usual install locations.

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define RUNTIME_SUBPATH "Contents/Frameworks/LiveContainerMac.dylib"

static void *tryLoad(const char *path, char *error, size_t errorSize) {
    if (!path || !*path || access(path, R_OK) != 0) return NULL;
    void *handle = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
    if (!handle) snprintf(error, errorSize, "%s", dlerror());
    return handle;
}

int main(int argc, char *argv[]) {
    char error[2048] = "";
    void *runtime = tryLoad(getenv("LC_MAC_RUNTIME"), error, sizeof(error));
    unsetenv("LC_MAC_RUNTIME");

    if (!runtime) {
        CFStringRef value = CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(), CFSTR("LCMacRuntime"));
        char path[PATH_MAX];
        if (value && CFGetTypeID(value) == CFStringGetTypeID()
            && CFStringGetFileSystemRepresentation(value, path, sizeof(path))) {
            runtime = tryLoad(path, error, sizeof(error));
        }
    }
    if (!runtime) {
        char path[PATH_MAX];
        const char *home = getenv("HOME");
        runtime = tryLoad("/Applications/LiveContainer.app/" RUNTIME_SUBPATH, error, sizeof(error));
        if (!runtime && home) {
            snprintf(path, sizeof(path), "%s/Applications/LiveContainer.app/" RUNTIME_SUBPATH, home);
            runtime = tryLoad(path, error, sizeof(error));
        }
    }

    int (*entry)(int, char **) = runtime ? (int (*)(int, char **))dlsym(runtime, "LiveContainerMacMain") : NULL;
    if (!entry) {
        CFStringRef message = CFStringCreateWithFormat(NULL, NULL,
            CFSTR("LiveContainer could not be found. Open the LiveContainer app once, then try again.%s%s"),
            *error ? "\n\n" : "", error);
        fprintf(stderr, "LiveContainer runtime not found. %s\n", error);
        typedef SInt32 (*AlertFn)(CFTimeInterval, CFOptionFlags, CFURLRef, CFURLRef, CFURLRef,
                                  CFStringRef, CFStringRef, CFStringRef, CFStringRef, CFStringRef, CFOptionFlags *);
        AlertFn alert = (AlertFn)dlsym(RTLD_DEFAULT, "CFUserNotificationDisplayAlert");
        CFOptionFlags response;
        if (alert && !getenv("LC_NO_ALERTS")) {
            alert(0, 2, NULL, NULL, NULL, CFSTR("Cannot open app"), message, CFSTR("OK"), NULL, NULL, &response);
        }
        CFRelease(message);
        return 1;
    }
    return entry(argc, argv);
}
