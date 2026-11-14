// Tests for macOS/Runtime/LCMacKeychain.m: the per-container keychain store, exercised
// directly (no hooks). Run by build.sh.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

void LCMacKeychainTestInit(NSString *containerPath);
OSStatus LCMacKeychainTestAdd(CFDictionaryRef a, CFTypeRef *r);
OSStatus LCMacKeychainTestCopyMatching(CFDictionaryRef q, CFTypeRef *r);
OSStatus LCMacKeychainTestUpdate(CFDictionaryRef q, CFDictionaryRef c);
OSStatus LCMacKeychainTestDelete(CFDictionaryRef q);

static int failures = 0;
static void check(BOOL ok, NSString *name) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", name.UTF8String);
    if (!ok) failures++;
}

#define K(x) ((__bridge id)(x))

int main(void) {
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        LCMacKeychainTestInit(dir);

        NSDictionary *item = @{K(kSecClass): K(kSecClassGenericPassword), K(kSecAttrService): @"svc", K(kSecAttrAccount): @"me",
                               K(kSecValueData): [@"secret" dataUsingEncoding:NSUTF8StringEncoding]};
        check(LCMacKeychainTestAdd((__bridge CFDictionaryRef)item, NULL) == errSecSuccess, @"add a generic password");
        check(LCMacKeychainTestAdd((__bridge CFDictionaryRef)item, NULL) == errSecDuplicateItem, @"same account and service is a duplicate");

        CFTypeRef result = NULL;
        NSDictionary *query = @{K(kSecClass): K(kSecClassGenericPassword), K(kSecAttrService): @"svc", K(kSecReturnData): @YES};
        OSStatus status = LCMacKeychainTestCopyMatching((__bridge CFDictionaryRef)query, &result);
        NSData *data = CFBridgingRelease(result);
        check(status == errSecSuccess && [data isEqual:[@"secret" dataUsingEncoding:NSUTF8StringEncoding]], @"read back the data");

        result = NULL;
        NSDictionary *attrsQuery = @{K(kSecClass): K(kSecClassGenericPassword), K(kSecAttrAccount): @"me",
                                     K(kSecReturnAttributes): @YES, K(kSecReturnData): @YES, K(kSecMatchLimit): K(kSecMatchLimitOne)};
        LCMacKeychainTestCopyMatching((__bridge CFDictionaryRef)attrsQuery, &result);
        NSDictionary *attrs = CFBridgingRelease(result);
        check([attrs[K(kSecAttrService)] isEqual:@"svc"] && attrs[K(kSecValueData)] && [attrs[K(kSecAttrAccessGroup)] hasPrefix:@"LCMACTEAM0."],
              @"attributes include service, data and a well-formed access group");
        check(attrs[K(kSecAttrCreationDate)] != nil, @"creation date recorded");

        NSDictionary *other = @{K(kSecClass): K(kSecClassGenericPassword), K(kSecAttrService): @"svc", K(kSecAttrAccount): @"you",
                                K(kSecValueData): [@"two" dataUsingEncoding:NSUTF8StringEncoding]};
        LCMacKeychainTestAdd((__bridge CFDictionaryRef)other, NULL);
        result = NULL;
        NSDictionary *all = @{K(kSecClass): K(kSecClassGenericPassword), K(kSecAttrService): @"svc",
                              K(kSecReturnAttributes): @YES, K(kSecMatchLimit): K(kSecMatchLimitAll)};
        LCMacKeychainTestCopyMatching((__bridge CFDictionaryRef)all, &result);
        NSArray *list = CFBridgingRelease(result);
        check(list.count == 2, @"match limit all returns both items");

        NSDictionary *sync = @{K(kSecClass): K(kSecClassGenericPassword), K(kSecAttrService): @"svc",
                               K(kSecAttrSynchronizable): K(kSecAttrSynchronizableAny)};
        check(LCMacKeychainTestCopyMatching((__bridge CFDictionaryRef)sync, NULL) == errSecSuccess, @"kSecAttrSynchronizableAny matches");
        NSDictionary *syncOnly = @{K(kSecClass): K(kSecClassGenericPassword), K(kSecAttrService): @"svc", K(kSecAttrSynchronizable): @YES};
        check(LCMacKeychainTestCopyMatching((__bridge CFDictionaryRef)syncOnly, NULL) == errSecItemNotFound, @"synchronizable items only: none");

        NSDictionary *match = @{K(kSecClass): K(kSecClassGenericPassword), K(kSecAttrAccount): @"me"};
        NSDictionary *change = @{K(kSecValueData): [@"new" dataUsingEncoding:NSUTF8StringEncoding]};
        check(LCMacKeychainTestUpdate((__bridge CFDictionaryRef)match, (__bridge CFDictionaryRef)change) == errSecSuccess, @"update");

        // A new store on the same folder (the next launch) sees the change.
        LCMacKeychainTestInit(dir);
        result = NULL;
        NSDictionary *again = @{K(kSecClass): K(kSecClassGenericPassword), K(kSecAttrAccount): @"me", K(kSecReturnData): @YES};
        LCMacKeychainTestCopyMatching((__bridge CFDictionaryRef)again, &result);
        check([CFBridgingRelease(result) isEqual:[@"new" dataUsingEncoding:NSUTF8StringEncoding]], @"changes persist across launches");

        check(LCMacKeychainTestDelete((__bridge CFDictionaryRef)match) == errSecSuccess, @"delete");
        check(LCMacKeychainTestCopyMatching((__bridge CFDictionaryRef)match, NULL) == errSecItemNotFound, @"deleted item is gone");
        check(LCMacKeychainTestDelete((__bridge CFDictionaryRef)match) == errSecItemNotFound, @"deleting again reports not found");

        NSDictionary *internet = @{K(kSecClass): K(kSecClassInternetPassword), K(kSecAttrServer): @"example.com", K(kSecAttrAccount): @"me",
                                   K(kSecValueData): [@"pw" dataUsingEncoding:NSUTF8StringEncoding]};
        check(LCMacKeychainTestAdd((__bridge CFDictionaryRef)internet, NULL) == errSecSuccess, @"internet password stored");
        NSDictionary *otherServer = @{K(kSecClass): K(kSecClassInternetPassword), K(kSecAttrServer): @"example.org", K(kSecAttrAccount): @"me",
                                      K(kSecValueData): [@"pw" dataUsingEncoding:NSUTF8StringEncoding]};
        check(LCMacKeychainTestAdd((__bridge CFDictionaryRef)otherServer, NULL) == errSecSuccess, @"different server is a different item");

        NSString *store = [dir stringByAppendingPathComponent:@"LCKeychain.plist"];
        NSNumber *mode = [NSFileManager.defaultManager attributesOfItemAtPath:store error:nil][NSFilePosixPermissions];
        check(mode.intValue == 0600, @"store is readable only by the user");
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    }
    printf("%s\n", failures ? "keychain tests failed" : "All keychain tests passed");
    return failures ? 1 : 0;
}
