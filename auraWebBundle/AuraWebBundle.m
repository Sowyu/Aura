// Aura's WebKit injected bundle. Loaded by the WebContent process, so every
// line here runs inside the web process, on the thread that is about to start
// the resource load. That is what makes the block decision synchronous:
// willSendRequestForFrame returns before the network request exists.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <os/log.h>

#import "AuraBlockRules.h"
#import "AuraWebBundleWK.h"

#define AURA_EXPORT __attribute__((visibility("default")))

static os_log_t AuraBundleLog(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.aurabrowser.app", "bundle"); });
    return log;
}

/// `…/NativeBlocking/AuraWebBundle.wkbundle/Contents/Resources/rules-v1.json`.
///
/// Found relative to this dylib rather than passed in: the WebContent process
/// gets a read-only sandbox extension for the injected bundle's directory and
/// for nothing else, so the rule file has to live inside it.
static NSString *AuraRulesPath(void)
{
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((const void *)&AuraRulesPath, &info) == 0 || !info.dli_fname) { return; }
        NSString *executable = @(info.dli_fname);
        NSString *contents = executable.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        path = [[contents stringByAppendingPathComponent:@"Resources"]
            stringByAppendingPathComponent:AuraBlockRulesFileName];
    });
    return path;
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

static NSString *AuraMainFrameHost(WKBundlePageRef page)
{
    WKBundleFrameRef mainFrame = WKBundlePageGetMainFrame(page);
    if (!mainFrame) { return nil; }
    WKURLRef wkURL = WKBundleFrameCopyURL(mainFrame);
    if (!wkURL) { return nil; }
    NSURL *url = AuraURLFromWKURL(wkURL);
    WKRelease((WKTypeRef)wkURL);
    return url.host;
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
        NSString *documentHost = isMainDocument ? url.host : AuraMainFrameHost(page);

        NSURL *replacement = nil;
        const AuraBlockDecision decision = [AuraBlockRules.sharedRules decisionForURL:url
                                                                        documentHost:documentHost
                                                                            typeMask:typeMask
                                                                         isMainFrame:isMainDocument
                                                                          resultURL:&replacement];

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
    NSString *rulesPath = AuraRulesPath();
    if (rulesPath) {
        // Cheap: one stat per page creation, a full parse only when the host
        // rewrote the file.
        if ([AuraBlockRules.sharedRules reloadIfChangedAtPath:rulesPath]) {
            os_log(AuraBundleLog(), "loaded %lu rules (revision %{public}@)",
                   (unsigned long)AuraBlockRules.sharedRules.ruleCount,
                   AuraBlockRules.sharedRules.revision ?: @"none");
        }
    }

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

AURA_EXPORT void WKBundleInitialize(WKBundleRef bundle, WKTypeRef initializationUserData);

void WKBundleInitialize(WKBundleRef bundle, WKTypeRef initializationUserData)
{
    static WKBundleClientV1 client;
    memset(&client, 0, sizeof(client));
    client.base.version = 1;
    client.didCreatePage = AuraDidCreatePage;
    client.willDestroyPage = AuraWillDestroyPage;
    WKBundleSetClient(bundle, &client.base);
    os_log(AuraBundleLog(), "WKBundleInitialize: injected bundle loaded in pid %d rules=%{public}@",
           getpid(), AuraRulesPath() ?: @"(unknown path)");
}
