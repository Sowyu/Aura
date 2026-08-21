#import "AuraWebRequestChannel.h"

#import <os/lock.h>
#import <os/log.h>
#import <sys/stat.h>

#import "AuraBlockRules.h"

NSString *const AuraWebRequestMessageName = @"aura.webRequest.decide";

static WKBundleRef AuraBundle;

static os_log_t AuraChannelLog(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.aurabrowser.app", "webrequest"); });
    return log;
}

void AuraWebRequestChannelSetBundle(WKBundleRef bundle)
{
    AuraBundle = bundle;
}

#pragma mark - Decision cache

/// Decisions repeat constantly (a page reloads the same sprite, the same
/// beacon fires per click), and a repeat costs a full IPC stall. 512 entries of
/// url+type is enough for a heavy page and cheap to blow away wholesale.
static NSMutableDictionary<NSString *, NSDictionary *> *AuraDecisionCache(void)
{
    static NSMutableDictionary<NSString *, NSDictionary *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

/// Guards the cache. Resource loads are main-thread work in the web process,
/// but workers and service workers load from their own threads.
static os_unfair_lock AuraCacheLock = OS_UNFAIR_LOCK_INIT;

#pragma mark - Active flag

BOOL AuraWebRequestChannelIsActive(NSString *statePath)
{
    static BOOL active;
    static CFAbsoluteTime checkedAt;
    static struct timespec writtenAt;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;

    if (!statePath) { return NO; }

    os_unfair_lock_lock(&lock);
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // One stat a second. Long enough that a page full of subresources pays for
    // it once, short enough that enabling uBlock takes effect before the user
    // has finished reading the settings row.
    if (now - checkedAt > 1.0) {
        checkedAt = now;
        struct stat info;
        const BOOL exists = stat(statePath.fileSystemRepresentation, &info) == 0 && info.st_size > 0;
        // The host rewrites this file whenever the set of blocking listeners
        // changes, so a new modification date means every cached verdict was
        // decided by listeners that are no longer the ones in charge.
        if (!exists || info.st_mtimespec.tv_sec != writtenAt.tv_sec
            || info.st_mtimespec.tv_nsec != writtenAt.tv_nsec) {
            writtenAt = exists ? info.st_mtimespec : (struct timespec) { 0, 0 };
            os_unfair_lock_lock(&AuraCacheLock);
            [AuraDecisionCache() removeAllObjects];
            os_unfair_lock_unlock(&AuraCacheLock);
        }
        active = exists;
    }
    const BOOL result = active;
    os_unfair_lock_unlock(&lock);
    return result;
}

#pragma mark - Types

NSString *AuraWebRequestTypeName(uint32_t typeMask, BOOL isMainDocument, BOOL isSubframe)
{
    if (isMainDocument) { return @"main_frame"; }
    if (typeMask & AuraResourceTypeSubdocument) { return @"sub_frame"; }
    if (typeMask & AuraResourceTypeScript) { return @"script"; }
    if (typeMask & AuraResourceTypeImage) { return @"image"; }
    if (typeMask & AuraResourceTypeStylesheet) { return @"stylesheet"; }
    if (typeMask & AuraResourceTypeFont) { return @"font"; }
    if (typeMask & AuraResourceTypeMedia) { return @"media"; }
    if (typeMask & AuraResourceTypeXHR) { return @"xmlhttprequest"; }
    if (typeMask & AuraResourceTypeWebSocket) { return @"websocket"; }
    if (typeMask & AuraResourceTypePing) { return @"ping"; }
    if (typeMask & AuraResourceTypeDocument) { return isSubframe ? @"sub_frame" : @"main_frame"; }
    return @"other";
}

#pragma mark - Synchronous ask

static NSDictionary *AuraParseReply(WKTypeRef reply)
{
    if (!reply || WKGetTypeID(reply) != WKStringGetTypeID()) { return nil; }
    CFStringRef cfJSON = WKStringCopyCFString(kCFAllocatorDefault, (WKStringRef)reply);
    NSString *json = CFBridgingRelease(cfJSON);
    if (json.length == 0) { return nil; }
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
}

NSDictionary *AuraWebRequestChannelDecide(NSDictionary *request)
{
    if (!AuraBundle) { return nil; }

    NSString *cacheKey = [NSString stringWithFormat:@"%@\n%@\n%@",
                                                    request[@"url"] ?: @"",
                                                    request[@"type"] ?: @"",
                                                    request[@"documentUrl"] ?: @""];
    NSMutableDictionary *cache = AuraDecisionCache();
    os_unfair_lock_lock(&AuraCacheLock);
    NSDictionary *cached = cache[cacheKey];
    os_unfair_lock_unlock(&AuraCacheLock);
    if (cached) { return cached; }

    NSData *body = [NSJSONSerialization dataWithJSONObject:request options:0 error:NULL];
    if (!body) { return nil; }
    NSString *json = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];

    const CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    WKStringRef name = WKStringCreateWithCFString((__bridge CFStringRef)AuraWebRequestMessageName);
    WKStringRef payload = WKStringCreateWithCFString((__bridge CFStringRef)json);
    WKTypeRef reply = NULL;
    WKBundlePostSynchronousMessage(AuraBundle, name, (WKTypeRef)payload, &reply);
    WKRelease((WKTypeRef)name);
    WKRelease((WKTypeRef)payload);

    NSDictionary *decision = AuraParseReply(reply);
    if (reply) { WKRelease(reply); }
    os_log_debug(AuraChannelLog(), "decide %{private}@ -> %{public}s in %.2f ms",
                 request[@"url"], [decision[@"cancel"] boolValue] ? "cancel" : "allow",
                 (CFAbsoluteTimeGetCurrent() - start) * 1000.0);

    // A missing "cacheable" flag means the host wants to be asked again (the
    // listener was still starting up, or the answer depends on state it expects
    // to change).
    if ([decision[@"cacheable"] boolValue]) {
        os_unfair_lock_lock(&AuraCacheLock);
        if (cache.count > 512) { [cache removeAllObjects]; }
        cache[cacheKey] = decision;
        os_unfair_lock_unlock(&AuraCacheLock);
    }
    return decision;
}
