#import "AuraWebBundleSupport.h"

#import <WebKit/WebKit.h>

#import "AuraWebBundleWK.h"

#import <dlfcn.h>
#import <libproc.h>
#import <objc/runtime.h>

// Private API, transcribed from WebKit trunk
// Source/WebKit/UIProcess/API/Cocoa/_WKProcessPoolConfiguration.h and
// Source/WebKit/UIProcess/API/Cocoa/WKProcessPoolPrivate.h.
@interface _WKProcessPoolConfiguration: NSObject <NSCopying>
@property (nonatomic, copy) NSURL *injectedBundleURL;
@end

@interface WKProcessPool (AuraPrivate)
- (instancetype)_initWithConfiguration:(_WKProcessPoolConfiguration *)configuration;
@end

// MARK: - Keeping the Development WebContent service awake

// Loading a non-platform injected bundle makes WebKit host pages in
// `com.apple.WebKit.WebContent.Development`, which ships without the
// `com.apple.runningboard.assertions.webkit` entitlement and without the RunningBoard
// block in its Info.plist (WebKit bug 263078 only took it out of launchd's hands).
// Every RunningBoard assertion WebKit takes against such a process is refused, and
// WebKit's UI-process throttler reads a refusal as "this process is being
// suspended": ProcessAssertion::acquireSync -> processAssertionWasInvalidated ->
// ProcessThrottler::invalidateAllActivities -> sendPrepareToSuspend, which freezes
// the web process's layer tree (requestAnimationFrame lives inside the frozen
// rendering update) and detaches the page's root layer in the UI process. Pages
// paint once and go blank while their JavaScript keeps running.
//
// RunningBoard never manages that process, so nothing is lost by not asking it: for
// assertions whose target is a Development WebContent process, `acquireWithError:`
// reports success without contacting RunningBoard (its client library would
// otherwise tell WebKit's invalidation observer about the refusal even when the
// return value says otherwise), and the matching `invalidate` is skipped. Every
// other target, the ordinary WebContent, Networking and GPU services included,
// goes through RunningBoard untouched.
//
// Read from WebKit trunk (319772@main, 2026-08-25):
// Source/WebKit/UIProcess/Cocoa/ProcessAssertionCocoa.mm (acquireSync,
// processAssertionWasInvalidated, the WKRBSAssertionDelegate observer),
// Source/WebKit/UIProcess/ProcessThrottler.cpp (assertionWasInvalidated,
// invalidateAllActivities, sendPrepareToSuspendIPC),
// Source/WebKit/UIProcess/WebProcessProxy.cpp (sendPrepareToSuspend),
// Source/WebKit/UIProcess/RemoteLayerTree/RemoteLayerTreeDrawingAreaProxy.mm
// (hideContentUntilPendingUpdate), Source/WebKit/WebProcess/WebProcess.cpp
// (prepareToSuspend, freezeAllLayerTrees), and
// Source/WebKit/UIProcess/mac/WebProcessProxyMac.mm (shouldAllowNonValidInjectedCode,
// which is what selects the Development service). Measured on macOS 27 (Xcode 27.0
// beta 27A5218g): the paint probe reads 0 rAF callbacks and an empty layer tree for
// the bundle page without this, 120 per 2 s and a full tree with it.
//
// ponytail: swizzles a private RunningBoardServices class WebKit uses on macOS; if a
// future WebKit acquires through ExtensionKit's grantCapability instead (the
// USE(EXTENSIONKIT) path), this becomes a no-op and the paint probe's fallback to
// uBO Lite is what the user sees.

static BOOL (*AuraOriginalAcquireWithError)(id, SEL, NSError **);
static void (*AuraOriginalInvalidate)(id, SEL);
static const void *AuraSkippedAssertionKey = &AuraSkippedAssertionKey;

// The pid RunningBoard would be asked about. RBSTarget's description is
// "<pid><ShortName>" (for example "99432<WebProcess99432>"); the leading integer is
// the pid, and its ivars hold nothing simpler to read.
static pid_t AuraAssertionTargetPID(id assertion)
{
    @try {
        return (pid_t)[[[assertion valueForKey:@"target"] description] intValue];
    } @catch (NSException *exception) {
        return 0;
    }
}

static BOOL AuraIsDevelopmentWebContent(pid_t pid)
{
    if (pid <= 0) { return NO; }
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) { return NO; }
    return strstr(path, "WebContent.Development") != NULL;
}

static BOOL AuraAcquireWithError(id self, SEL _cmd, NSError **error)
{
    pid_t pid = AuraAssertionTargetPID(self);
    if (!AuraIsDevelopmentWebContent(pid)) {
        return AuraOriginalAcquireWithError(self, _cmd, error);
    }
    objc_setAssociatedObject(self, AuraSkippedAssertionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static int logged;
    if (logged < 1) {
        logged += 1;
        NSLog(@"Aura: RunningBoard assertions for Development WebContent (pid %d) are reported as held without asking RunningBoard", pid);
    }
    if (error) { *error = nil; }
    return YES;
}

static void AuraInvalidate(id self, SEL _cmd)
{
    if (objc_getAssociatedObject(self, AuraSkippedAssertionKey)) { return; }
    AuraOriginalInvalidate(self, _cmd);
}

BOOL AuraInstallRunningBoardShim(void)
{
    static BOOL installed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class assertionClass = NSClassFromString(@"RBSAssertion");
        Method acquire = assertionClass ? class_getInstanceMethod(assertionClass, NSSelectorFromString(@"acquireWithError:")) : NULL;
        Method invalidate = assertionClass ? class_getInstanceMethod(assertionClass, NSSelectorFromString(@"invalidate")) : NULL;
        if (!acquire || !invalidate) { return; }
        AuraOriginalAcquireWithError = (BOOL (*)(id, SEL, NSError **))method_getImplementation(acquire);
        AuraOriginalInvalidate = (void (*)(id, SEL))method_getImplementation(invalidate);
        method_setImplementation(acquire, (IMP)AuraAcquireWithError);
        method_setImplementation(invalidate, (IMP)AuraInvalidate);
        installed = YES;
    });
    return installed;
}

WKProcessPool *AuraMakeInjectedBundleProcessPool(NSURL *bundleURL)
{
    Class configurationClass = NSClassFromString(@"_WKProcessPoolConfiguration");
    if (!configurationClass) { return nil; }
    if (![WKProcessPool instancesRespondToSelector:@selector(_initWithConfiguration:)]) { return nil; }

    _WKProcessPoolConfiguration *configuration = [[configurationClass alloc] init];
    if (![configuration respondsToSelector:@selector(setInjectedBundleURL:)]) { return nil; }
    configuration.injectedBundleURL = bundleURL;

    // Before the pool exists: the first assertion is taken as soon as its first
    // web process launches.
    if (!AuraInstallRunningBoardShim()) {
        NSLog(@"Aura: RunningBoard shim unavailable; pages on the injected-bundle pool may stop painting");
    }
    return [[WKProcessPool alloc] _initWithConfiguration:configuration];
}

// MARK: - Window-server capture

// `CGWindowListCreateImage` is marked unavailable in the macOS 27 SDK but still
// exported; looked up at run time so the build does not depend on the header. Only
// ever pointed at this process's own windows, which needs no screen-recording grant.
CGImageRef _Nullable AuraCaptureWindow(uint32_t windowNumber)
{
    typedef CGImageRef (*Capture)(CGRect, uint32_t, uint32_t, uint32_t);
    static Capture capture;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ capture = (Capture)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage"); });
    if (!capture) { return NULL; }
    // kCGWindowListOptionIncludingWindow = 1 << 3; kCGWindowImageBoundsIgnoreFraming = 1 << 0,
    // kCGWindowImageBestResolution = 1 << 3.
    return capture(CGRectNull, 1 << 3, windowNumber, (1 << 0) | (1 << 3));
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
extern void WKContextPostMessageToInjectedBundle(WKContextRef context, WKStringRef messageName, WKTypeRef messageBody);

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

void AuraPostMessageToInjectedBundle(WKProcessPool *pool, NSString *name, NSString *body)
{
    if (![pool respondsToSelector:NSSelectorFromString(@"_apiObject")]) { return; }
    WKStringRef wkName = WKStringCreateWithCFString((__bridge CFStringRef)name);
    WKStringRef wkBody = WKStringCreateWithCFString((__bridge CFStringRef)body);
    WKContextPostMessageToInjectedBundle((__bridge WKContextRef)pool, wkName, (WKTypeRef)wkBody);
    WKRelease((WKTypeRef)wkName);
    WKRelease((WKTypeRef)wkBody);
}
