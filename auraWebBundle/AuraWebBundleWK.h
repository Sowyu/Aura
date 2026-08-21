// Hand-declared subset of WebKit's injected-bundle C API.
//
// These symbols are exported from WebKit.framework (they are listed in the
// SDK's WebKit.tbd) but their headers live in PrivateHeaders/, which Apple
// does not ship in the macOS SDK. The declarations below are transcribed from
// WebKit trunk:
//   Source/WebKit/WebProcess/InjectedBundle/API/c/WKBundle.h
//   Source/WebKit/WebProcess/InjectedBundle/API/c/WKBundlePage.h
//   Source/WebKit/WebProcess/InjectedBundle/API/c/WKBundleFrame.h
//   Source/WebKit/WebProcess/InjectedBundle/API/c/WKBundlePageResourceLoadClient.h
//   Source/WebKit/Shared/API/c/WKURLRequest.h
//   Source/WebKit/Shared/API/c/cf/WKURLCF.h
//   Source/WebKit/Shared/API/c/WKType.h

#ifndef AuraWebBundleWK_h
#define AuraWebBundleWK_h

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef const void *WKTypeRef;
typedef const struct OpaqueWKBundle *WKBundleRef;
typedef const struct OpaqueWKBundlePage *WKBundlePageRef;
typedef const struct OpaqueWKBundlePageGroup *WKBundlePageGroupRef;
typedef const struct OpaqueWKBundleFrame *WKBundleFrameRef;
typedef const struct OpaqueWKString *WKStringRef;
typedef const struct OpaqueWKURL *WKURLRef;
typedef const struct OpaqueWKURLRequest *WKURLRequestRef;
typedef const struct OpaqueWKURLResponse *WKURLResponseRef;
typedef const struct OpaqueWKError *WKErrorRef;
typedef uint32_t WKTypeID;

#pragma mark - WKBundle client

typedef void (*WKBundleDidCreatePageCallback)(WKBundleRef, WKBundlePageRef, const void *clientInfo);
typedef void (*WKBundleWillDestroyPageCallback)(WKBundleRef, WKBundlePageRef, const void *clientInfo);
typedef void (*WKBundleDidInitializePageGroupCallback)(WKBundleRef, WKBundlePageGroupRef, const void *clientInfo);
typedef void (*WKBundleDidReceiveMessageCallback)(WKBundleRef, WKStringRef, WKTypeRef, const void *clientInfo);
typedef void (*WKBundleDidReceiveMessageToPageCallback)(WKBundleRef, WKBundlePageRef, WKStringRef, WKTypeRef, const void *clientInfo);

typedef struct WKBundleClientBase {
    int version;
    const void *clientInfo;
} WKBundleClientBase;

typedef struct WKBundleClientV1 {
    WKBundleClientBase base;
    // Version 0.
    WKBundleDidCreatePageCallback didCreatePage;
    WKBundleWillDestroyPageCallback willDestroyPage;
    WKBundleDidInitializePageGroupCallback didInitializePageGroup;
    WKBundleDidReceiveMessageCallback didReceiveMessage;
    // Version 1.
    WKBundleDidReceiveMessageToPageCallback didReceiveMessageToPage;
} WKBundleClientV1;

extern void WKBundleSetClient(WKBundleRef bundle, WKBundleClientBase *client);

#pragma mark - WKBundlePage resource load client

typedef void (*WKBundlePageDidInitiateLoadForResourceCallback)(WKBundlePageRef, WKBundleFrameRef, uint64_t resourceIdentifier, WKURLRequestRef, bool pageIsProvisionallyLoading, const void *clientInfo);
typedef WKURLRequestRef (*WKBundlePageWillSendRequestForFrameCallback)(WKBundlePageRef, WKBundleFrameRef, uint64_t resourceIdentifier, WKURLRequestRef, WKURLResponseRef redirectResponse, const void *clientInfo);
typedef void (*WKBundlePageDidReceiveResponseForResourceCallback)(WKBundlePageRef, WKBundleFrameRef, uint64_t resourceIdentifier, WKURLResponseRef, const void *clientInfo);
typedef void (*WKBundlePageDidReceiveContentLengthForResourceCallback)(WKBundlePageRef, WKBundleFrameRef, uint64_t resourceIdentifier, uint64_t contentLength, const void *clientInfo);
typedef void (*WKBundlePageDidFinishLoadForResourceCallback)(WKBundlePageRef, WKBundleFrameRef, uint64_t resourceIdentifier, const void *clientInfo);
typedef void (*WKBundlePageDidFailLoadForResourceCallback)(WKBundlePageRef, WKBundleFrameRef, uint64_t resourceIdentifier, WKErrorRef, const void *clientInfo);
typedef bool (*WKBundlePageShouldCacheResponseCallback)(WKBundlePageRef, WKBundleFrameRef, uint64_t resourceIdentifier, const void *clientInfo);
typedef bool (*WKBundlePageShouldUseCredentialStorageCallback)(WKBundlePageRef, WKBundleFrameRef, uint64_t resourceIdentifier, const void *clientInfo);

typedef struct WKBundlePageResourceLoadClientBase {
    int version;
    const void *clientInfo;
} WKBundlePageResourceLoadClientBase;

typedef struct WKBundlePageResourceLoadClientV1 {
    WKBundlePageResourceLoadClientBase base;
    // Version 0.
    WKBundlePageDidInitiateLoadForResourceCallback didInitiateLoadForResource;
    // Returns a *retained* request. Returning NULL blanks the request, cancelling the load.
    WKBundlePageWillSendRequestForFrameCallback willSendRequestForFrame;
    WKBundlePageDidReceiveResponseForResourceCallback didReceiveResponseForResource;
    WKBundlePageDidReceiveContentLengthForResourceCallback didReceiveContentLengthForResource;
    WKBundlePageDidFinishLoadForResourceCallback didFinishLoadForResource;
    WKBundlePageDidFailLoadForResourceCallback didFailLoadForResource;
    // Version 1.
    WKBundlePageShouldCacheResponseCallback shouldCacheResponse;
    WKBundlePageShouldUseCredentialStorageCallback shouldUseCredentialStorage;
} WKBundlePageResourceLoadClientV1;

extern void WKBundlePageSetResourceLoadClient(WKBundlePageRef page, WKBundlePageResourceLoadClientBase *client);

#pragma mark - Frames

extern WKBundleFrameRef WKBundlePageGetMainFrame(WKBundlePageRef page);
extern WKURLRef WKBundleFrameCopyURL(WKBundleFrameRef frame);

#pragma mark - Injected-bundle messaging

/// Blocks the calling (web) thread until the UI process answers. `returnData`
/// receives a retained reply, or NULL when no host handler is installed.
extern void WKBundlePostSynchronousMessage(WKBundleRef bundle, WKStringRef messageName, WKTypeRef messageBody, WKTypeRef *returnData);
extern void WKBundlePostMessage(WKBundleRef bundle, WKStringRef messageName, WKTypeRef messageBody);

#pragma mark - Strings

extern WKStringRef WKStringCreateWithCFString(CFStringRef string);
extern CFStringRef WKStringCopyCFString(CFAllocatorRef allocator, WKStringRef string) CF_RETURNS_RETAINED;
extern WKTypeID WKStringGetTypeID(void);
extern WKTypeID WKGetTypeID(WKTypeRef object);

#pragma mark - Value types

extern WKURLRef WKURLRequestCopyURL(WKURLRequestRef request);
extern CFStringRef WKURLRequestCopyHTTPMethod(WKURLRequestRef request) CF_RETURNS_RETAINED;
extern WKURLRequestRef WKURLRequestCreateWithWKURL(WKURLRef url);
extern CFURLRef WKURLCopyCFURL(CFAllocatorRef allocator, WKURLRef url) CF_RETURNS_RETAINED;
extern WKURLRef WKURLCreateWithCFURL(CFURLRef url);
extern WKTypeRef WKRetain(WKTypeRef object);
extern void WKRelease(WKTypeRef object);

#ifdef __cplusplus
}
#endif

#endif /* AuraWebBundleWK_h */
