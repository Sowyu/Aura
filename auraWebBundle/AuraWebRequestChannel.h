// The web process end of Aura's blocking `webRequest` bridge.
//
// `willSendRequestForFrame` has to answer before the load starts, so the only
// usable channel is a synchronous one: `WKBundlePostSynchronousMessage` blocks
// this thread on IPC to the UI process, where WebRequestBroker asks the
// extension and hands a verdict back.
//
// Every round trip stalls a page's main thread, so the fast path matters more
// than the slow one: nothing is sent unless the host has said some extension
// actually registered a blocking listener.

#ifndef AuraWebRequestChannel_h
#define AuraWebRequestChannel_h

#import <Foundation/Foundation.h>

#import "AuraResourceTypes.h"
#import "AuraWebBundleWK.h"

NS_ASSUME_NONNULL_BEGIN

/// Message name carried over `WKBundlePostSynchronousMessage`.
extern NSString *const AuraWebRequestMessageName;

/// Remembers the bundle handle so decisions can be posted later.
void AuraWebRequestChannelSetBundle(WKBundleRef bundle);

/// YES when the host currently has at least one blocking listener registered.
BOOL AuraWebRequestChannelIsActive(void);

/// YES when some listener is on `onBeforeSendHeaders`, so the ask has to carry the
/// request's headers. Off in the common case: reading and shipping them costs a
/// dictionary per request that nothing would look at.
BOOL AuraWebRequestChannelWantsRequestHeaders(void);

/// Records the host's answer to `AuraWebRequestStateMessageName`, a bit mask in a
/// string: bit 0 is "a listener is registered", bit 1 is "send request headers".
/// "0" and "1" carry the meaning they had before headers existed.
/// Every call drops the cached verdicts: the host only sends on a change, and a
/// new set of listeners may decide differently.
void AuraWebRequestChannelSetActive(NSString *_Nullable state);

/// Pulls the active flag from the host. Called once per page creation so a web
/// process that came up after the last push still learns the current state.
void AuraWebRequestChannelRefreshActive(void);

/// One synchronous round trip. Returns the host's string reply, or nil.
NSString *_Nullable AuraWebRequestChannelPostSync(NSString *name, NSString *body);

/// Blocks until the host answers or gives up. Returns the reply dictionary
/// (`cancel`, `redirectUrl`, `setHeaders`, `removeHeaders`), or nil for "allow,
/// unchanged".
NSDictionary *_Nullable AuraWebRequestChannelDecide(NSDictionary *request);

NS_ASSUME_NONNULL_END

#endif /* AuraWebRequestChannel_h */
