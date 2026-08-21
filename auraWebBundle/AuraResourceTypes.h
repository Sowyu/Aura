// Request classification for the blocking `webRequest` bridge, shared verbatim
// by two targets:
//
//   * AuraWebBundle.wkbundle, where it runs inside the WebContent process on
//     the thread that is about to start a resource load.
//   * Aura.app, which needs the message names to answer the bundle.
//
// Foundation only. No WebKit, no app code.

#ifndef AuraResourceTypes_h
#define AuraResourceTypes_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Resource types a request can be classified as. `AuraResourceTypeAny` is what
/// a request gets when its type could not be inferred.
typedef NS_OPTIONS(uint32_t, AuraResourceType) {
    AuraResourceTypeDocument = 1u << 0,
    AuraResourceTypeSubdocument = 1u << 1,
    AuraResourceTypeScript = 1u << 2,
    AuraResourceTypeImage = 1u << 3,
    AuraResourceTypeStylesheet = 1u << 4,
    AuraResourceTypeXHR = 1u << 5,
    AuraResourceTypeMedia = 1u << 6,
    AuraResourceTypeFont = 1u << 7,
    AuraResourceTypeWebSocket = 1u << 8,
    AuraResourceTypePing = 1u << 9,
    AuraResourceTypeOther = 1u << 10,
    AuraResourceTypeAny = 0x7ffu
};

/// What an extension's blocking listener asked for.
typedef NS_ENUM(uint32_t, AuraBlockDecision) {
    /// Let the request through untouched.
    AuraBlockDecisionAllow = 0,
    /// Cancel the request before it reaches the network.
    AuraBlockDecisionBlock = 1,
    /// Serve a different URL instead.
    AuraBlockDecisionRedirect = 2
};

/// Whether some extension has a blocking `webRequest` listener registered.
/// The bundle pulls it synchronously on page creation; the host pushes it to
/// live web processes whenever it changes. Body either way: "1" or "0". Every
/// change is the bundle's cue to drop cached verdicts.
extern NSString *const AuraWebRequestStateMessageName;

/// Best guess at a request's resource type. WebKit's injected-bundle resource
/// load client does not carry one, so this reads the `Accept` header first and
/// falls back to the URL's path extension.
///
/// The `Accept` header is the reliable half. WebCore sets a distinct one per
/// resource kind before `willSendRequest` runs: `text/html,...` for a document
/// or an iframe, `image/png,image/svg+xml,...` for an image, `text/css,...` for
/// a stylesheet. Scripts and fetches both get `*/*`, and fonts and media get
/// none at all, which is what the extension table is for.
uint32_t AuraResourceTypeMaskForURL(NSURL *url, NSString *_Nullable acceptHeader, BOOL isMainFrame);

/// `Sec-Fetch-Dest` names the resource kind outright, so when it is there
/// nothing has to be inferred. Returns 0 for a missing or unrecognised value,
/// which is the caller's cue to fall back to `AuraResourceTypeMaskForURL`.
uint32_t AuraResourceTypeForFetchDestination(NSString *_Nullable destination);

/// webRequest's `type` string for one of `AuraResourceType`'s mask bits.
///
/// Foundation only, so it lives here rather than with the channel: the app
/// links it too, which is the only way it can be tested without a web process.
NSString *AuraWebRequestTypeName(uint32_t typeMask, BOOL isMainDocument, BOOL isSubframe);

NS_ASSUME_NONNULL_END

#endif /* AuraResourceTypes_h */
