// Bridging header for the `aura` target.
//
// Declares the one private-API call Swift cannot express safely (building a
// WKProcessPool whose web content processes load an injected bundle) and
// re-exports the matcher so the host and its tests share the bundle's code.

#ifndef AuraWebBundleSupport_h
#define AuraWebBundleSupport_h

#import <Foundation/Foundation.h>

#import "AuraBlockRules.h"

NS_ASSUME_NONNULL_BEGIN

@class WKProcessPool;

/// Builds a process pool whose WebContent processes dlopen the injected bundle
/// at `bundleURL`. Returns nil when the private API is missing.
WKProcessPool *_Nullable AuraMakeInjectedBundleProcessPool(NSURL *bundleURL);

NS_ASSUME_NONNULL_END

#endif /* AuraWebBundleSupport_h */
