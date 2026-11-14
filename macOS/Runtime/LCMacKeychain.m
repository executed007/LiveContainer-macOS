// LiveContainer for macOS: per-container keychain.
//
// On iOS, LiveContainer separates containers by giving each one of 128 keychain access
// groups from its entitlements (LiveContainer/Tweaks/SecItem.m). A Mac app signed ad hoc
// cannot carry keychain-access-groups, and without them iOS apps get errSecMissingEntitlement
// from the data protection keychain, so sign-in tokens are lost on every launch.
//
// Instead, password items (kSecClassGenericPassword and kSecClassInternetPassword, which is
// what apps use for tokens) are kept in a property list inside the container:
//   <container>/LCKeychain.plist   (mode 0600, readable only by this user)
// Each container therefore has its own keychain, which moves and is deleted with the
// container. Other item classes (keys, certificates, identities) go to the system unchanged.
//
// Supported: SecItemAdd, SecItemCopyMatching, SecItemUpdate, SecItemDelete with attribute
// matching, kSecMatchLimitOne/All, and kSecReturnData/Attributes/PersistentRef/Ref
// (Ref and PersistentRef return an opaque identifier). Not supported: kSecMatchSearchList,
// kSecMatchItemList, case-insensitive or substring matching.

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <os/lock.h>
#import <sys/stat.h>
#import "../../litehook/src/litehook.h"

static NSString *LCKStorePath;
static NSMutableArray<NSMutableDictionary *> *LCKItems;
static os_unfair_lock LCKLock = OS_UNFAIR_LOCK_INIT;

// What iOS reports as the access group of an app's items: "<team>.<bundle id>". Apps read it
// back to learn their team prefix, so give them a stable, well-formed one.
static NSString *LCKDefaultAccessGroup;

static OSStatus (*LCKOrigAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*LCKOrigCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*LCKOrigUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*LCKOrigDelete)(CFDictionaryRef);

static BOOL LCKHandles(NSDictionary *query) {
    id cls = query[(__bridge id)kSecClass];
    return [cls isEqual:(__bridge id)kSecClassGenericPassword] || [cls isEqual:(__bridge id)kSecClassInternetPassword];
}

// Query keys that steer the search or the result instead of naming an attribute.
static NSSet<NSString *> *LCKControlKeys(void) {
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithArray:@[
            (__bridge id)kSecReturnData, (__bridge id)kSecReturnAttributes, (__bridge id)kSecReturnRef,
            (__bridge id)kSecReturnPersistentRef, (__bridge id)kSecMatchLimit, (__bridge id)kSecMatchCaseInsensitive,
            (__bridge id)kSecUseDataProtectionKeychain, (__bridge id)kSecUseAuthenticationUI,
            (__bridge id)kSecUseAuthenticationContext, (__bridge id)kSecUseOperationPrompt,
            (__bridge id)kSecAttrAccessGroup, (__bridge id)kSecAttrAccessible, (__bridge id)kSecAttrAccessControl,
            (__bridge id)kSecValueData, (__bridge id)kSecValueRef, @"u_Keychain",
            @"u_AuthUI", @"u_DataProtectionKeychain", @"nleg", @"musr", @"sync_any",
        ]];
    });
    return keys;
}

static BOOL LCKIsPlistValue(id value) {
    return [value isKindOfClass:NSString.class] || [value isKindOfClass:NSData.class] ||
           [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSDate.class];
}

static void LCKLoad(void) {
    NSData *data = [NSData dataWithContentsOfFile:LCKStorePath];
    NSArray *items = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:nil error:nil] : nil;
    LCKItems = [items isKindOfClass:NSArray.class] ? (NSMutableArray *)items : [NSMutableArray array];
}

static void LCKSave(void) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:LCKItems format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data) return;
    [data writeToFile:LCKStorePath options:NSDataWritingAtomic error:nil];
    chmod(LCKStorePath.fileSystemRepresentation, 0600);
}

static BOOL LCKMatches(NSDictionary *item, NSDictionary *query) {
    NSSet *control = LCKControlKeys();
    for (NSString *key in query) {
        if ([control containsObject:key]) continue;
        id wanted = query[key];
        if ([key isEqualToString:(__bridge id)kSecAttrSynchronizable]) {
            // kSecAttrSynchronizableAny matches both; a missing attribute means "not synchronizable".
            if ([wanted isEqual:(__bridge id)kSecAttrSynchronizableAny]) continue;
            if ([item[key] boolValue] != [wanted boolValue]) return NO;
            continue;
        }
        if (![item[key] isEqual:wanted]) return NO;
    }
    return YES;
}

// The attributes that make an item unique, as defined for each class on iOS.
static BOOL LCKSameIdentity(NSDictionary *a, NSDictionary *b) {
    NSArray *keys = [a[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword]
        ? @[(__bridge id)kSecClass, (__bridge id)kSecAttrAccount, (__bridge id)kSecAttrService, (__bridge id)kSecAttrSynchronizable]
        : @[(__bridge id)kSecClass, (__bridge id)kSecAttrAccount, (__bridge id)kSecAttrServer, (__bridge id)kSecAttrProtocol,
            (__bridge id)kSecAttrPort, (__bridge id)kSecAttrPath, (__bridge id)kSecAttrSecurityDomain,
            (__bridge id)kSecAttrAuthenticationType, (__bridge id)kSecAttrSynchronizable];
    for (NSString *key in keys) {
        id x = a[key], y = b[key];
        if ([key isEqualToString:(__bridge id)kSecAttrSynchronizable]) {
            if ([x boolValue] != [y boolValue]) return NO;
        } else if ((x || y) && ![x isEqual:y]) {
            return NO;
        }
    }
    return YES;
}

static id LCKResult(NSDictionary *item, NSDictionary *query) {
    BOOL data = [query[(__bridge id)kSecReturnData] boolValue];
    BOOL attributes = [query[(__bridge id)kSecReturnAttributes] boolValue];
    BOOL ref = [query[(__bridge id)kSecReturnRef] boolValue] || [query[(__bridge id)kSecReturnPersistentRef] boolValue];
    NSUInteger kinds = data + attributes + ref;
    if (kinds == 0) return nil;
    NSData *persistent = [item[@"LCKID"] dataUsingEncoding:NSUTF8StringEncoding];
    if (kinds == 1 && data) return item[(__bridge id)kSecValueData] ?: [NSData data];
    if (kinds == 1 && ref) return persistent;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if (attributes) {
        for (NSString *key in item) {
            if (![key isEqualToString:(__bridge id)kSecValueData] && ![key isEqualToString:@"LCKID"]) result[key] = item[key];
        }
    }
    if (data) result[(__bridge id)kSecValueData] = item[(__bridge id)kSecValueData] ?: [NSData data];
    if (ref) result[(__bridge id)kSecValuePersistentRef] = persistent;
    return result;
}

static NSArray<NSMutableDictionary *> *LCKFind(NSDictionary *query) {
    // A persistent reference names exactly one item.
    NSData *persistent = query[(__bridge id)kSecValuePersistentRef];
    NSMutableArray *found = [NSMutableArray array];
    for (NSMutableDictionary *item in LCKItems) {
        if (persistent) {
            if ([[item[@"LCKID"] dataUsingEncoding:NSUTF8StringEncoding] isEqual:persistent]) [found addObject:item];
        } else {
            NSMutableDictionary *withoutRef = query.mutableCopy;
            [withoutRef removeObjectForKey:(__bridge id)kSecValuePersistentRef];
            if (LCKMatches(item, withoutRef)) [found addObject:item];
        }
    }
    return found;
}

static OSStatus LCKAdd(CFDictionaryRef attributesRef, CFTypeRef *result) {
    NSDictionary *attributes = (__bridge NSDictionary *)attributesRef;
    if (!LCKHandles(attributes)) return LCKOrigAdd(attributesRef, result);
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    for (NSString *key in attributes) {
        if ([LCKControlKeys() containsObject:key] && ![key isEqualToString:(__bridge id)kSecValueData] &&
            ![key isEqualToString:(__bridge id)kSecAttrAccessGroup] && ![key isEqualToString:(__bridge id)kSecAttrAccessible]) continue;
        id value = attributes[key];
        if ([key isEqualToString:(__bridge id)kSecValueData] && [value isKindOfClass:NSString.class]) {
            value = [value dataUsingEncoding:NSUTF8StringEncoding];
        }
        if (LCKIsPlistValue(value)) item[key] = value;
    }
    if (!item[(__bridge id)kSecAttrAccessGroup]) item[(__bridge id)kSecAttrAccessGroup] = LCKDefaultAccessGroup;
    if (!item[(__bridge id)kSecAttrAccessible]) item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlocked;
    NSDate *now = [NSDate date];
    item[(__bridge id)kSecAttrCreationDate] = now;
    item[(__bridge id)kSecAttrModificationDate] = now;
    item[@"LCKID"] = NSUUID.UUID.UUIDString;

    os_unfair_lock_lock(&LCKLock);
    for (NSDictionary *existing in LCKItems) {
        if (LCKSameIdentity(existing, item)) {
            os_unfair_lock_unlock(&LCKLock);
            return errSecDuplicateItem;
        }
    }
    [LCKItems addObject:item];
    LCKSave();
    id value = LCKResult(item, attributes);
    os_unfair_lock_unlock(&LCKLock);
    if (result) *result = value ? CFBridgingRetain(value) : NULL;
    return errSecSuccess;
}

static OSStatus LCKCopyMatching(CFDictionaryRef queryRef, CFTypeRef *result) {
    NSDictionary *query = (__bridge NSDictionary *)queryRef;
    if (!LCKHandles(query)) return LCKOrigCopyMatching(queryRef, result);
    BOOL all = [query[(__bridge id)kSecMatchLimit] isEqual:(__bridge id)kSecMatchLimitAll];
    os_unfair_lock_lock(&LCKLock);
    NSArray *found = LCKFind(query);
    NSMutableArray *values = [NSMutableArray array];
    for (NSDictionary *item in found) {
        id value = LCKResult(item, query);
        if (value) [values addObject:value];
        if (!all) break;
    }
    os_unfair_lock_unlock(&LCKLock);
    if (found.count == 0) return errSecItemNotFound;
    if (result) {
        id value = all ? values : values.firstObject;
        *result = value ? CFBridgingRetain(value) : NULL;
    }
    return errSecSuccess;
}

static OSStatus LCKUpdate(CFDictionaryRef queryRef, CFDictionaryRef changesRef) {
    NSDictionary *query = (__bridge NSDictionary *)queryRef;
    if (!LCKHandles(query)) return LCKOrigUpdate(queryRef, changesRef);
    NSDictionary *changes = (__bridge NSDictionary *)changesRef;
    os_unfair_lock_lock(&LCKLock);
    NSArray *found = LCKFind(query);
    for (NSMutableDictionary *item in found) {
        for (NSString *key in changes) {
            id value = changes[key];
            if ([key isEqualToString:(__bridge id)kSecValueData] && [value isKindOfClass:NSString.class]) {
                value = [value dataUsingEncoding:NSUTF8StringEncoding];
            }
            if (LCKIsPlistValue(value) && ![key isEqualToString:(__bridge id)kSecClass]) item[key] = value;
        }
        item[(__bridge id)kSecAttrModificationDate] = [NSDate date];
    }
    if (found.count) LCKSave();
    os_unfair_lock_unlock(&LCKLock);
    return found.count ? errSecSuccess : errSecItemNotFound;
}

static OSStatus LCKDelete(CFDictionaryRef queryRef) {
    NSDictionary *query = (__bridge NSDictionary *)queryRef;
    if (!LCKHandles(query)) return LCKOrigDelete(queryRef);
    os_unfair_lock_lock(&LCKLock);
    NSArray *found = LCKFind(query);
    [LCKItems removeObjectsInArray:found];
    if (found.count) LCKSave();
    os_unfair_lock_unlock(&LCKLock);
    return found.count ? errSecSuccess : errSecItemNotFound;
}

void LCMacKeychainInit(NSString *containerPath) {
    LCKStorePath = [containerPath stringByAppendingPathComponent:@"LCKeychain.plist"];
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"app";
    LCKDefaultAccessGroup = [@"LCMACTEAM0." stringByAppendingString:bundleID];
    LCKLoad();
    LCKOrigAdd = SecItemAdd;
    LCKOrigCopyMatching = SecItemCopyMatching;
    LCKOrigUpdate = SecItemUpdate;
    LCKOrigDelete = SecItemDelete;
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemAdd, LCKAdd, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemCopyMatching, LCKCopyMatching, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemUpdate, LCKUpdate, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemDelete, LCKDelete, nil);
}

// For the test suite: use a store without hooking anything.
void LCMacKeychainTestInit(NSString *containerPath) {
    LCKStorePath = [containerPath stringByAppendingPathComponent:@"LCKeychain.plist"];
    LCKDefaultAccessGroup = @"LCMACTEAM0.test";
    LCKOrigAdd = SecItemAdd;
    LCKOrigCopyMatching = SecItemCopyMatching;
    LCKOrigUpdate = SecItemUpdate;
    LCKOrigDelete = SecItemDelete;
    LCKLoad();
}
OSStatus LCMacKeychainTestAdd(CFDictionaryRef a, CFTypeRef *r) { return LCKAdd(a, r); }
OSStatus LCMacKeychainTestCopyMatching(CFDictionaryRef q, CFTypeRef *r) { return LCKCopyMatching(q, r); }
OSStatus LCMacKeychainTestUpdate(CFDictionaryRef q, CFDictionaryRef c) { return LCKUpdate(q, c); }
OSStatus LCMacKeychainTestDelete(CFDictionaryRef q) { return LCKDelete(q); }
