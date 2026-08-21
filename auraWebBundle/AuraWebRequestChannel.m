#import "AuraWebRequestChannel.h"

#import <os/lock.h>
#import <os/log.h>

#import "AuraResourceTypes.h"

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

static _Atomic(BOOL) AuraActive;

BOOL AuraWebRequestChannelIsActive(void)
{
    return AuraActive;
}

void AuraWebRequestChannelSetActive(NSString *state)
{
    AuraActive = [state isEqualToString:@"1"];
    os_unfair_lock_lock(&AuraCacheLock);
    [AuraDecisionCache() removeAllObjects];
    os_unfair_lock_unlock(&AuraCacheLock);
}

void AuraWebRequestChannelRefreshActive(void)
{
    NSString *state = AuraWebRequestChannelPostSync(AuraWebRequestStateMessageName, @"");
    // No handler on the host side: stay quiet rather than stall every load.
    if (!state) { state = @"0"; }
    if ([state isEqualToString:@"1"] != AuraActive) { AuraWebRequestChannelSetActive(state); }
}

#pragma mark - Synchronous ask

NSString *AuraWebRequestChannelPostSync(NSString *name, NSString *body)
{
    if (!AuraBundle) { return nil; }
    WKStringRef wkName = WKStringCreateWithCFString((__bridge CFStringRef)name);
    WKStringRef payload = WKStringCreateWithCFString((__bridge CFStringRef)(body ?: @""));
    WKTypeRef reply = NULL;
    WKBundlePostSynchronousMessage(AuraBundle, wkName, (WKTypeRef)payload, &reply);
    WKRelease((WKTypeRef)wkName);
    WKRelease((WKTypeRef)payload);

    NSString *result = nil;
    if (reply && WKGetTypeID(reply) == WKStringGetTypeID()) {
        result = CFBridgingRelease(WKStringCopyCFString(kCFAllocatorDefault, (WKStringRef)reply));
    }
    if (reply) { WKRelease(reply); }
    return result;
}

static NSDictionary *AuraParseReply(NSString *json)
{
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
    NSDictionary *decision = AuraParseReply(AuraWebRequestChannelPostSync(AuraWebRequestMessageName, json));
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
