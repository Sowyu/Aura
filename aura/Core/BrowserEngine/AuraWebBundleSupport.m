#import "AuraWebBundleSupport.h"

#import <WebKit/WebKit.h>

#import "AuraWebBundleWK.h"

// Private API, transcribed from WebKit trunk
// Source/WebKit/UIProcess/API/Cocoa/_WKProcessPoolConfiguration.h and
// Source/WebKit/UIProcess/API/Cocoa/WKProcessPoolPrivate.h.
@interface _WKProcessPoolConfiguration: NSObject <NSCopying>
@property (nonatomic, copy) NSURL *injectedBundleURL;
@end

@interface WKProcessPool (AuraPrivate)
- (instancetype)_initWithConfiguration:(_WKProcessPoolConfiguration *)configuration;
@end

WKProcessPool *AuraMakeInjectedBundleProcessPool(NSURL *bundleURL)
{
    Class configurationClass = NSClassFromString(@"_WKProcessPoolConfiguration");
    if (!configurationClass) { return nil; }
    if (![WKProcessPool instancesRespondToSelector:@selector(_initWithConfiguration:)]) { return nil; }

    _WKProcessPoolConfiguration *configuration = [[configurationClass alloc] init];
    if (![configuration respondsToSelector:@selector(setInjectedBundleURL:)]) { return nil; }
    configuration.injectedBundleURL = bundleURL;

    return [[WKProcessPool alloc] _initWithConfiguration:configuration];
}

// MARK: - Synchronous messages from the injected bundle

// UI-process half of WebKit's injected-bundle C API, transcribed from
// Source/WebKit/UIProcess/API/C/WKContext.h. The bundle side of the same
// protocol lives in auraWebBundle/AuraWebBundleWK.h.
typedef const void *WKContextRef;

typedef void (*WKContextDidReceiveMessageFromInjectedBundleCallback)(
    WKContextRef, WKStringRef messageName, WKTypeRef messageBody, const void *clientInfo);
typedef void (*WKContextDidReceiveSynchronousMessageFromInjectedBundleCallback)(
    WKContextRef, WKStringRef messageName, WKTypeRef messageBody, WKTypeRef *returnData, const void *clientInfo);

typedef struct WKContextInjectedBundleClientBase {
    int version;
    const void *clientInfo;
} WKContextInjectedBundleClientBase;

typedef struct WKContextInjectedBundleClientV0 {
    WKContextInjectedBundleClientBase base;
    WKContextDidReceiveMessageFromInjectedBundleCallback didReceiveMessageFromInjectedBundle;
    WKContextDidReceiveSynchronousMessageFromInjectedBundleCallback didReceiveSynchronousMessageFromInjectedBundle;
} WKContextInjectedBundleClientV0;

extern void WKContextSetInjectedBundleClient(WKContextRef context, const WKContextInjectedBundleClientBase *client);

static NSString *_Nullable (^AuraBundleMessageHandler)(NSString *, NSString *);

static NSString *AuraStringFromWK(WKTypeRef value)
{
    if (!value || WKGetTypeID(value) != WKStringGetTypeID()) { return nil; }
    return CFBridgingRelease(WKStringCopyCFString(kCFAllocatorDefault, (WKStringRef)value));
}

static void AuraDidReceiveSynchronousMessage(
    WKContextRef context, WKStringRef messageName, WKTypeRef messageBody, WKTypeRef *returnData, const void *clientInfo)
{
    if (returnData) { *returnData = NULL; }
    if (!AuraBundleMessageHandler) { return; }

    @autoreleasepool {
        NSString *name = AuraStringFromWK((WKTypeRef)messageName);
        if (!name) { return; }
        NSString *reply = AuraBundleMessageHandler(name, AuraStringFromWK(messageBody) ?: @"");
        if (reply && returnData) {
            *returnData = (WKTypeRef)WKStringCreateWithCFString((__bridge CFStringRef)reply);
        }
    }
}

BOOL AuraSetInjectedBundleMessageHandler(WKProcessPool *pool, NSString *_Nullable (^handler)(NSString *, NSString *))
{
    // In the Cocoa port every C-API object *is* its Objective-C wrapper
    // (API::Object::wrap returns it), so the process pool doubles as the
    // WKContextRef the C client wants. `_apiObject` is what WebKit's own
    // unwrap calls; if it went away the cast would crash instead of failing.
    if (![pool respondsToSelector:NSSelectorFromString(@"_apiObject")]) { return NO; }

    AuraBundleMessageHandler = handler;

    static WKContextInjectedBundleClientV0 client;
    memset(&client, 0, sizeof(client));
    client.base.version = 0;
    client.didReceiveSynchronousMessageFromInjectedBundle = AuraDidReceiveSynchronousMessage;
    WKContextSetInjectedBundleClient((__bridge WKContextRef)pool, &client.base);
    return YES;
}
