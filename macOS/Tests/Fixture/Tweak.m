// A tweak for the end-to-end test: records that it was loaded, and in which app.
#import <Foundation/Foundation.h>

__attribute__((constructor)) static void TweakLoaded(void) {
    NSString *name = @(TWEAK_NAME);
    NSString *path = [NSHomeDirectory() stringByAppendingFormat:@"/Documents/%@-loaded", name];
    [NSBundle.mainBundle.bundleIdentifier writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
