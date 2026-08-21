// Aura's WebKit injected bundle. Loaded by the WebContent process, so every
// line here runs inside the web process, on the thread that is about to start
// the resource load. That is what makes the block decision synchronous:
// willSendRequestForFrame returns before the network request exists.

#import <Foundation/Foundation.h>
#import <os/log.h>

#import "AuraBlockRules.h"
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

/// Asks the host for the rule document when the host's revision differs from
/// the one loaded here. The web process cannot read Aura's files, and the bundle
/// itself sits inside the signed app, so everything arrives over IPC.
static void AuraLoadRulesDocument(NSString *document)
{
    if (!document) { return; }
    if ([AuraBlockRules.sharedRules loadFromData:[document dataUsingEncoding:NSUTF8StringEncoding]]) {
        os_log(AuraBundleLog(), "loaded %lu rules (revision %{public}@)",
               (unsigned long)AuraBlockRules.sharedRules.ruleCount,
               AuraBlockRules.sharedRules.revision ?: @"none");
    }
}

static void AuraSyncRules(void)
{
    AuraLoadRulesDocument(AuraWebRequestChannelPostSync(AuraBlockRulesMessageName,
                                                        AuraBlockRules.sharedRules.revision ?: @""));
}

#pragma mark - Main-document tracking

/// Resource identifier of the request that is loading each page's main document.
/// `didInitiateLoadForResource` reports it (with `pageIsProvisionallyLoading`)
/// just before `willSendRequestForFrame` runs for the same identifier, which is
/// the only reliable way to tell a top-level navigation from a subresource:
/// the resource load client carries no resource type.
static NSMutableDictionary<NSValue *, NSNumber *> *AuraMainDocumentIdentifiers(void)
{
    static NSMutableDictionary<NSValue *, NSNumber *> *identifiers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ identifiers = [NSMutableDictionary dictionary]; });
    return identifiers;
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
    NSURL *url,
    uint32_t typeMask,
    BOOL isMainFrame,
    BOOL isMainDocument,
    NSURL *__autoreleasing *outURL)
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

    NSDictionary *verdict = AuraWebRequestChannelDecide(ask);
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
    AuraMainDocumentIdentifiers()[[NSValue valueWithPointer:page]] = @(resourceIdentifier);
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

        NSNumber *mainDocumentIdentifier = AuraMainDocumentIdentifiers()[[NSValue valueWithPointer:page]];
        const BOOL isMainFrame = frame == WKBundlePageGetMainFrame(page);
        const BOOL isMainDocument = isMainFrame
            && mainDocumentIdentifier != nil
            && mainDocumentIdentifier.unsignedLongLongValue == resourceIdentifier;

        const uint32_t typeMask = [AuraBlockRules typeMaskForURL:url acceptHeader:nil isMainFrame:isMainFrame];
        NSString *documentHost = isMainDocument ? url.host : AuraMainFrameURL(page).host;

        NSURL *replacement = nil;
        AuraBlockDecision decision = [AuraBlockRules.sharedRules decisionForURL:url
                                                                        documentHost:documentHost
                                                                            typeMask:typeMask
                                                                         isMainFrame:isMainDocument
                                                                          resultURL:&replacement];

        // Aura's own rules win outright; an extension only gets asked about
        // requests that would otherwise go through untouched.
        if (decision == AuraBlockDecisionAllow && AuraWebRequestChannelIsActive()) {
            decision = AuraExtensionDecision(page, frame, resourceIdentifier, request, url,
                                             typeMask, isMainFrame, isMainDocument, &replacement);
        }

        switch (decision) {
        case AuraBlockDecisionBlock:
            os_log_debug(AuraBundleLog(), "block id=%llu url=%{private}@", resourceIdentifier, url);
            return NULL;
        case AuraBlockDecisionRedirect:
        case AuraBlockDecisionRewrite: {
            WKURLRequestRef rewritten = replacement ? AuraCreateRequest(replacement) : NULL;
            if (rewritten) {
                os_log_debug(AuraBundleLog(), "rewrite id=%llu url=%{private}@ -> %{private}@",
                             resourceIdentifier, url, replacement);
                return rewritten;
            }
            break;
        }
        case AuraBlockDecisionAllow:
            break;
        }

        // The client contract is to hand back a retained request.
        if (request) { WKRetain((WKTypeRef)request); }
        return request;
    }
}

static void AuraDidCreatePage(WKBundleRef bundle, WKBundlePageRef page, const void *clientInfo)
{
    // Two short round trips per page creation; the rule document only travels
    // when the host rebuilt it.
    AuraSyncRules();
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
    [AuraMainDocumentIdentifiers() removeObjectForKey:[NSValue valueWithPointer:page]];
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
    } else if ([messageName isEqualToString:AuraBlockRulesMessageName]) {
        AuraLoadRulesDocument(payload);
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
