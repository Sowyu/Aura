// Aura's WebKit injected bundle. Loaded by the WebContent process, so every
// line here runs inside the web process, on the thread that is about to start
// the resource load. That is what makes the block decision synchronous:
// willSendRequestForFrame returns before the network request exists.

#import <Foundation/Foundation.h>
#import <os/lock.h>
#import <os/log.h>

#import "AuraResourceTypes.h"
#import "AuraWebBundleWK.h"
#import "AuraWebRequestChannel.h"

#define AURA_EXPORT __attribute__((visibility("default")))

static os_log_t AuraBundleLog(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.aurabrowser.app", "bundle"); });
    return log;
}

#pragma mark - Main-document tracking

/// Resource identifier of the request that is loading each page's main document.
/// `didInitiateLoadForResource` reports it (with `pageIsProvisionallyLoading`)
/// just before `willSendRequestForFrame` runs for the same identifier, which is
/// the only reliable way to tell a top-level navigation from a subresource:
/// the resource load client carries no resource type.
///
/// Guarded: resource loads are main-thread work for a document, but a worker or
/// a service worker starts its own from another thread, and NSMutableDictionary
/// would tear under that.
static os_unfair_lock AuraMainDocumentLock = OS_UNFAIR_LOCK_INIT;

static NSMutableDictionary<NSValue *, NSNumber *> *AuraMainDocumentIdentifiers(void)
{
    static NSMutableDictionary<NSValue *, NSNumber *> *identifiers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ identifiers = [NSMutableDictionary dictionary]; });
    return identifiers;
}

static void AuraSetMainDocumentIdentifier(WKBundlePageRef page, uint64_t resourceIdentifier)
{
    NSValue *key = [NSValue valueWithPointer:page];
    os_unfair_lock_lock(&AuraMainDocumentLock);
    AuraMainDocumentIdentifiers()[key] = @(resourceIdentifier);
    os_unfair_lock_unlock(&AuraMainDocumentLock);
}

static BOOL AuraIsMainDocumentIdentifier(WKBundlePageRef page, uint64_t resourceIdentifier)
{
    NSValue *key = [NSValue valueWithPointer:page];
    os_unfair_lock_lock(&AuraMainDocumentLock);
    NSNumber *known = AuraMainDocumentIdentifiers()[key];
    os_unfair_lock_unlock(&AuraMainDocumentLock);
    return known != nil && known.unsignedLongLongValue == resourceIdentifier;
}

static void AuraForgetMainDocumentIdentifier(WKBundlePageRef page)
{
    NSValue *key = [NSValue valueWithPointer:page];
    os_unfair_lock_lock(&AuraMainDocumentLock);
    [AuraMainDocumentIdentifiers() removeObjectForKey:key];
    os_unfair_lock_unlock(&AuraMainDocumentLock);
}

static NSURL *AuraURLFromWKURL(WKURLRef wkURL)
{
    if (!wkURL) { return nil; }
    return CFBridgingRelease(WKURLCopyCFURL(kCFAllocatorDefault, wkURL));
}

static NSURL *AuraURLFromRequest(WKURLRequestRef request)
{
    if (!request) { return nil; }
    WKURLRef wkURL = WKURLRequestCopyURL(request);
    if (!wkURL) { return nil; }
    NSURL *url = AuraURLFromWKURL(wkURL);
    WKRelease((WKTypeRef)wkURL);
    return url;
}

static NSURL *AuraMainFrameURL(WKBundlePageRef page)
{
    WKBundleFrameRef mainFrame = WKBundlePageGetMainFrame(page);
    if (!mainFrame) { return nil; }
    WKURLRef wkURL = WKBundleFrameCopyURL(mainFrame);
    if (!wkURL) { return nil; }
    NSURL *url = AuraURLFromWKURL(wkURL);
    WKRelease((WKTypeRef)wkURL);
    return url;
}

/// The verdict a blocking `webRequest` listener returned, or Allow when no
/// extension registered one. Costs a synchronous IPC hop plus the extension's
/// JS, so the caller checks `AuraWebRequestChannelIsActive` first.
static AuraBlockDecision AuraExtensionDecision(
    WKBundlePageRef page,
    WKBundleFrameRef frame,
    uint64_t resourceIdentifier,
    WKURLRequestRef request,
    NSURLRequest *bridged,
    NSURL *url,
    uint32_t typeMask,
    BOOL isMainFrame,
    BOOL isMainDocument,
    NSURL *__autoreleasing *outURL,
    NSDictionary *__autoreleasing *outVerdict)
{
    NSString *method = CFBridgingRelease(WKURLRequestCopyHTTPMethod(request)) ?: @"GET";
    // Frames have no id in the injected-bundle API. The frame pointer is stable
    // for the frame's lifetime, which is all a listener uses frameId for.
    const int32_t frameID = isMainFrame ? 0 : (int32_t)(((uintptr_t)frame >> 4) & 0x7fffffff);
    NSMutableDictionary *ask = [@{
        @"url": url.absoluteString ?: @"",
        @"type": AuraWebRequestTypeName(typeMask, isMainDocument, !isMainFrame),
        @"method": method,
        @"frameId": @(frameID),
        @"parentFrameId": @(isMainFrame ? -1 : 0),
        @"requestId": @(resourceIdentifier),
    } mutableCopy];

    // `pageUrl` is Aura's own: the shim maps it to the tab id WebKit gave the
    // extension. It stays the *current* main-frame URL even for a navigation,
    // which is what makes the mapping resolvable before the load commits.
    NSString *pageURL = AuraMainFrameURL(page).absoluteString;
    if (pageURL.length > 0) {
        ask[@"pageUrl"] = pageURL;
        // Chrome leaves documentUrl unset on a top-level navigation.
        if (!isMainDocument) { ask[@"documentUrl"] = pageURL; }
    }

    // Only when some listener is on onBeforeSendHeaders. Chrome's shape: an array of
    // {name, value}, in the order the request carries them.
    if (AuraWebRequestChannelWantsRequestHeaders() && bridged) {
        NSDictionary<NSString *, NSString *> *fields = bridged.allHTTPHeaderFields;
        if (fields.count > 0) {
            NSMutableArray *headers = [NSMutableArray arrayWithCapacity:fields.count];
            for (NSString *name in fields) {
                [headers addObject:@{ @"name": name, @"value": fields[name] ?: @"" }];
            }
            ask[@"requestHeaders"] = headers;
        }
    }

    NSDictionary *verdict = AuraWebRequestChannelDecide(ask);
    if (outVerdict) { *outVerdict = verdict; }
    if ([verdict[@"cancel"] boolValue]) { return AuraBlockDecisionBlock; }
    NSString *redirect = verdict[@"redirectUrl"];
    if ([redirect isKindOfClass:NSString.class] && redirect.length > 0) {
        NSURL *target = [NSURL URLWithString:redirect];
        if (target) {
            if (outURL) { *outURL = target; }
            return AuraBlockDecisionRedirect;
        }
    }
    return AuraBlockDecisionAllow;
}

/// The request as Foundation sees it. The C resource-load client offers no header
/// accessor, so this bridge is the only way to read (or, with the reverse call,
/// write) headers. Done once per request and passed around: it is a copy, and the
/// type sniffing and the header patch both need it.
static NSURLRequest *AuraBridgedRequest(WKURLRequestRef request)
{
    if (!request) { return nil; }
    id object = CFBridgingRelease(WKURLRequestCopyNSURLRequest(request));
    return [object isKindOfClass:NSURLRequest.class] ? object : nil;
}

/// Best available resource type for a request. The C resource-load client carries
/// none, so two headers off the bridged request answer it.
///
/// `Sec-Fetch-Dest` names the kind outright and is preferred. `Accept` is the
/// fallback: it separates documents, images and stylesheets cleanly and says
/// nothing about the rest, which is what the URL's extension is for.
static uint32_t AuraRequestTypeMask(NSURLRequest *bridged, NSURL *url, BOOL isMainFrame)
{
    const uint32_t fromDestination =
        AuraResourceTypeForFetchDestination([bridged valueForHTTPHeaderField:@"Sec-Fetch-Dest"]);
    if (fromDestination != 0) { return fromDestination; }
    return AuraResourceTypeMaskForURL(url, [bridged valueForHTTPHeaderField:@"Accept"], isMainFrame);
}

/// True for the methods that carry a body. A request whose body did not survive the
/// bridge must not be rebuilt from it, and this is how that is recognised.
static BOOL AuraMethodCarriesBody(NSString *method)
{
    NSString *upper = method.uppercaseString ?: @"GET";
    return [upper isEqualToString:@"POST"] || [upper isEqualToString:@"PUT"]
        || [upper isEqualToString:@"PATCH"];
}

/// A copy of `bridged` with the extension's header changes applied, or NULL when
/// there is nothing to change or the change cannot be made safely.
///
/// The C request has no header setter, so the only route is bridge out, mutate,
/// bridge back. What that cannot do is put back a body the bridge dropped, so a
/// body-carrying request that arrives here without one is left exactly as it was:
/// a POST sent with its body missing is worse than an unmodified header.
static WKURLRequestRef AuraCreateRequestWithHeaders(NSURLRequest *bridged, NSDictionary *verdict)
{
    NSDictionary *setHeaders = verdict[@"setHeaders"];
    NSArray *removeHeaders = verdict[@"removeHeaders"];
    const BOOL hasSet = [setHeaders isKindOfClass:NSDictionary.class] && setHeaders.count > 0;
    const BOOL hasRemove = [removeHeaders isKindOfClass:NSArray.class] && removeHeaders.count > 0;
    if (!bridged || (!hasSet && !hasRemove)) { return NULL; }
    if (!bridged.HTTPBody && !bridged.HTTPBodyStream && AuraMethodCarriesBody(bridged.HTTPMethod)) {
        os_log_debug(AuraBundleLog(), "header patch skipped: %{public}@ body did not survive the bridge",
                     bridged.HTTPMethod);
        return NULL;
    }

    NSMutableURLRequest *patched = [bridged mutableCopy];
    if (hasRemove) {
        for (NSString *name in removeHeaders) {
            if ([name isKindOfClass:NSString.class]) { [patched setValue:nil forHTTPHeaderField:name]; }
        }
    }
    if (hasSet) {
        for (NSString *name in setHeaders) {
            NSString *value = setHeaders[name];
            if ([name isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class]) {
                [patched setValue:value forHTTPHeaderField:name];
            }
        }
    }
    return WKURLRequestCreateWithNSURLRequest((__bridge CFTypeRef)patched);
}

/// True when `url` is the document `frame` is navigating to rather than a
/// subresource inside it.
///
/// The identifier `didInitiateLoadForResource` reports covers a main-frame
/// navigation the web process started, but a navigation handed down from the UI
/// process never gets that callback, and a subframe never gets it at all. The
/// provisional URL covers both, and it is set before this runs.
static BOOL AuraIsFrameDocumentRequest(WKBundleFrameRef frame, NSURL *url)
{
    if (!frame) { return NO; }
    WKURLRef wkURL = WKBundleFrameCopyProvisionalURL(frame);
    if (!wkURL) { return NO; }
    NSURL *provisional = AuraURLFromWKURL(wkURL);
    WKRelease((WKTypeRef)wkURL);
    return provisional != nil && [provisional.absoluteString isEqualToString:url.absoluteString];
}

/// A retained request pointing at `url`, or NULL if WebKit refuses the URL.
static WKURLRequestRef AuraCreateRequest(NSURL *url)
{
    WKURLRef wkURL = WKURLCreateWithCFURL((__bridge CFURLRef)url);
    if (!wkURL) { return NULL; }
    WKURLRequestRef request = WKURLRequestCreateWithWKURL(wkURL);
    WKRelease((WKTypeRef)wkURL);
    return request;
}

#pragma mark - Resource load client

static void AuraDidInitiateLoadForResource(
    WKBundlePageRef page,
    WKBundleFrameRef frame,
    uint64_t resourceIdentifier,
    WKURLRequestRef request,
    bool pageIsProvisionallyLoading,
    const void *clientInfo)
{
    if (!pageIsProvisionallyLoading || frame != WKBundlePageGetMainFrame(page)) { return; }
    AuraSetMainDocumentIdentifier(page, resourceIdentifier);
}

static WKURLRequestRef AuraWillSendRequestForFrame(
    WKBundlePageRef page,
    WKBundleFrameRef frame,
    uint64_t resourceIdentifier,
    WKURLRequestRef request,
    WKURLResponseRef redirectResponse,
    const void *clientInfo)
{
    @autoreleasepool {
        NSURL *url = AuraURLFromRequest(request);
        NSString *scheme = url.scheme.lowercaseString;
        const BOOL isNetworkURL = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]
            || [scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"wss"];
        if (!url || !isNetworkURL) {
            if (request) { WKRetain((WKTypeRef)request); }
            return request;
        }

        const BOOL isMainFrame = frame == WKBundlePageGetMainFrame(page);

        // Blocking is an extension's job now: uBlock Origin registers a blocking
        // webRequest listener and Aura keeps no rule set of its own. Nothing is
        // sent unless the host says some listener is actually registered.
        if (AuraWebRequestChannelIsActive()) {
            // Three ways to recognise a frame's own document, and any one is
            // enough. Getting this wrong on the main frame is what blanks a tab,
            // so it is deliberately generous.
            const BOOL isDocument = AuraIsFrameDocumentRequest(frame, url)
                || (isMainFrame && AuraIsMainDocumentIdentifier(page, resourceIdentifier));
            NSURLRequest *bridged = AuraBridgedRequest(request);
            uint32_t typeMask = AuraRequestTypeMask(bridged, url, isMainFrame);
            if (isDocument) {
                typeMask = isMainFrame ? AuraResourceTypeDocument : AuraResourceTypeSubdocument;
            }
            const BOOL isMainDocument = isMainFrame
                && (isDocument || typeMask == AuraResourceTypeDocument);
            NSURL *replacement = nil;
            NSDictionary *verdict = nil;
            AuraBlockDecision decision = AuraExtensionDecision(page, frame, resourceIdentifier, request, bridged,
                                                              url, typeMask, isMainFrame, isMainDocument,
                                                              &replacement, &verdict);
            // Extensions may cancel subresources and subframes, never the top
            // document: WebKit reports a blanked main resource as a failed
            // navigation and the tab goes blank. A navigation the UI process
            // started reaches the web process with no Sec-Fetch-Dest, no Accept
            // and no provisional URL yet, so a main-frame request nothing could
            // identify is protected as well.
            // ponytail: that costs main-frame "other" requests their blocking.
            // Drop the second clause if the bundle ever gets a real type.
            const BOOL protectDocument = isMainDocument
                || (isMainFrame && typeMask == AuraResourceTypeAny);
            if (decision == AuraBlockDecisionBlock) {
                os_log_debug(AuraBundleLog(), "block id=%llu url=%{private}@", resourceIdentifier, url);
                if (protectDocument) {
                    os_log_debug(AuraBundleLog(), "extension asked to cancel a main document; allowing");
                    if (request) { WKRetain((WKTypeRef)request); }
                    return request;
                }
                return NULL;
            }
            if (decision == AuraBlockDecisionRedirect && protectDocument && !isMainDocument) {
                // Same reasoning: a rewritten top-level URL is a navigation the
                // user did not ask for.
                if (request) { WKRetain((WKTypeRef)request); }
                return request;
            }
            if (decision == AuraBlockDecisionRedirect && replacement) {
                WKURLRequestRef rewritten = AuraCreateRequest(replacement);
                if (rewritten) {
                    os_log_debug(AuraBundleLog(), "redirect id=%llu url=%{private}@ -> %{private}@",
                                 resourceIdentifier, url, replacement);
                    return rewritten;
                }
            }
            // onBeforeSendHeaders. Only on an allow: a cancelled request sends nothing
            // and a redirect leaves with a request built from the new URL alone.
            if (decision == AuraBlockDecisionAllow) {
                WKURLRequestRef patched = AuraCreateRequestWithHeaders(bridged, verdict);
                if (patched) {
                    os_log_debug(AuraBundleLog(), "headers patched id=%llu url=%{private}@",
                                 resourceIdentifier, url);
                    return patched;
                }
            }
        }

        // The client contract is to hand back a retained request.
        if (request) { WKRetain((WKTypeRef)request); }
        return request;
    }
}

static void AuraDidCreatePage(WKBundleRef bundle, WKBundlePageRef page, const void *clientInfo)
{
    // One short round trip per page creation: a web process that came up after
    // the last push still learns whether a blocking listener exists.
    AuraWebRequestChannelRefreshActive();

    WKBundlePageResourceLoadClientV1 client;
    memset(&client, 0, sizeof(client));
    client.base.version = 1;
    client.didInitiateLoadForResource = AuraDidInitiateLoadForResource;
    client.willSendRequestForFrame = AuraWillSendRequestForFrame;
    // WebKit copies the struct (APIClient::initialize memcpy's it), so a stack
    // local is fine here.
    WKBundlePageSetResourceLoadClient(page, &client.base);
    os_log_debug(AuraBundleLog(), "didCreatePage: resource load client installed page=%p", page);
}

static void AuraWillDestroyPage(WKBundleRef bundle, WKBundlePageRef page, const void *clientInfo)
{
    AuraForgetMainDocumentIdentifier(page);
}

static void AuraDidReceiveMessage(WKBundleRef bundle, WKStringRef name, WKTypeRef body, const void *clientInfo)
{
    NSString *messageName = CFBridgingRelease(WKStringCopyCFString(kCFAllocatorDefault, name));
    NSString *payload = nil;
    if (body && WKGetTypeID(body) == WKStringGetTypeID()) {
        payload = CFBridgingRelease(WKStringCopyCFString(kCFAllocatorDefault, (WKStringRef)body));
    }
    if ([messageName isEqualToString:AuraWebRequestStateMessageName]) {
        AuraWebRequestChannelSetActive(payload);
    }
}

AURA_EXPORT void WKBundleInitialize(WKBundleRef bundle, WKTypeRef initializationUserData);

void WKBundleInitialize(WKBundleRef bundle, WKTypeRef initializationUserData)
{
    static WKBundleClientV1 client;
    memset(&client, 0, sizeof(client));
    client.base.version = 1;
    client.didCreatePage = AuraDidCreatePage;
    client.willDestroyPage = AuraWillDestroyPage;
    client.didReceiveMessage = AuraDidReceiveMessage;
    WKBundleSetClient(bundle, &client.base);
    AuraWebRequestChannelSetBundle(bundle);
    os_log(AuraBundleLog(), "WKBundleInitialize: injected bundle loaded in pid %d", getpid());
}
