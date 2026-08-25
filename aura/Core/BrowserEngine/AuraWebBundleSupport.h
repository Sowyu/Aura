// Bridging header for the `aura` target.
//
// Declares the one private-API call Swift cannot express safely (building a
// WKProcessPool whose web content processes load an injected bundle) and
// re-exports the message names the host answers on.

#ifndef AuraWebBundleSupport_h
#define AuraWebBundleSupport_h

#import <Foundation/Foundation.h>

#import "AuraResourceTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class WKProcessPool;
@class WKWebViewConfiguration;

/// Builds a process pool whose WebContent processes dlopen the injected bundle
/// at `bundleURL`. Returns nil when the private API is missing.
WKProcessPool *_Nullable AuraMakeInjectedBundleProcessPool(NSURL *bundleURL);

/// Asks WebKit to run this configuration's pages at foreground priority
/// (`_clientNavigationsRunAtForegroundPriority`; the iOS-only
/// `_alwaysRunsAtForegroundPriority` is the fallback spelling). Aimed at the
/// Development WebContent service's failed foreground assertion, which is what
/// purges its layers. Returns NO when neither private property exists.
BOOL AuraSetAlwaysForegroundPriority(WKWebViewConfiguration *configuration);

/// Answers the synchronous messages the injected bundle posts to this process.
///
/// `handler` runs on the main thread with the sending WebContent process parked
/// inside its resource-load callback, so it must return in single-digit
/// milliseconds. Its result is the reply; nil means "no answer". Returns NO when
/// the private API is missing, in which case the bundle gets NULL replies and
/// falls back to allowing everything.
BOOL AuraSetInjectedBundleMessageHandler(
    WKProcessPool *pool,
    NSString *_Nullable (^handler)(NSString *name, NSString *body));

/// Posts a one-way message to every live WebContent process in `pool`. Processes
/// that start later do not see it; the bundle pulls current state on page creation.
void AuraPostMessageToInjectedBundle(WKProcessPool *pool, NSString *name, NSString *body);

NS_ASSUME_NONNULL_END

#endif /* AuraWebBundleSupport_h */

#import "AuraExceptionCatcher.h"
