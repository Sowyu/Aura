// The web process end of Aura's blocking `webRequest` bridge.
//
// `willSendRequestForFrame` has to answer before the load starts, so the only
// usable channel is a synchronous one: `WKBundlePostSynchronousMessage` blocks
// this thread on IPC to the UI process, where WebRequestBroker asks the
// extension and hands a verdict back.
//
// Every round trip stalls a page's main thread, so the fast path matters more
// than the slow one: nothing is sent unless the host has written an "active"
// marker saying some extension actually registered a blocking listener.

#ifndef AuraWebRequestChannel_h
#define AuraWebRequestChannel_h

#import <Foundation/Foundation.h>

#import "AuraBlockRules.h"
#import "AuraWebBundleWK.h"

NS_ASSUME_NONNULL_BEGIN

/// Message name carried over `WKBundlePostSynchronousMessage`.
extern NSString *const AuraWebRequestMessageName;

/// Remembers the bundle handle so decisions can be posted later.
void AuraWebRequestChannelSetBundle(WKBundleRef bundle);

/// YES when the host currently has at least one blocking listener registered.
/// Re-reads `statePath` at most once a second; every other call is a load of a
/// cached flag.
BOOL AuraWebRequestChannelIsActive(NSString *statePath);

/// Blocks until the host answers or gives up. Returns the reply dictionary
/// (`cancel`, `redirectUrl`), or nil for "allow, unchanged".
NSDictionary *_Nullable AuraWebRequestChannelDecide(NSDictionary *request);

/// webRequest's `type` string for one of AuraBlockRules' type mask bits.
NSString *AuraWebRequestTypeName(uint32_t typeMask, BOOL isMainDocument, BOOL isSubframe);

NS_ASSUME_NONNULL_END

#endif /* AuraWebRequestChannel_h */
