// The native request filter, shared verbatim by two targets:
//
//   * AuraWebBundle.wkbundle, where it runs inside the WebContent process on
//     the thread that is about to start a resource load.
//   * Aura.app, so the host can build a rule file and the tests can drive the
//     matcher directly.
//
// Foundation only. No WebKit, no app code: whatever links this gets a matcher
// and nothing else.

#ifndef AuraBlockRules_h
#define AuraBlockRules_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Resource types a rule can be restricted to. `AuraResourceTypeAny` is what a
/// request gets when its type could not be inferred, so type-restricted rules
/// still have a chance to match it.
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

typedef NS_ENUM(uint32_t, AuraBlockDecision) {
    /// Let the request through untouched.
    AuraBlockDecisionAllow = 0,
    /// Cancel the request before it reaches the network.
    AuraBlockDecisionBlock = 1,
    /// Same request, different URL (a `$removeparam` rewrite).
    AuraBlockDecisionRewrite = 2,
    /// Serve a neutered stand-in instead (a `$redirect` rule).
    AuraBlockDecisionRedirect = 3
};

/// Name of the rule file the host writes and the injected bundle reads.
extern NSString *const AuraBlockRulesFileName;

/// Name of the marker file the host writes while an extension has a blocking
/// `webRequest` listener registered. Its absence is what keeps the bundle out
/// of IPC when no extension cares, and its modification date is the bundle's
/// cue to drop cached verdicts.
extern NSString *const AuraWebRequestStateFileName;

@interface AuraBlockRules: NSObject

/// The rule set the injected bundle consults. Thread-safe for evaluation.
@property (class, readonly) AuraBlockRules *sharedRules;

@property (readonly) NSUInteger ruleCount;
@property (readonly) NSUInteger allowlistedHostCount;
@property (readonly, copy, nullable) NSString *revision;

/// Reloads only when the file's modification date or size moved since the last
/// read. Returns YES when a new rule set was installed.
- (BOOL)reloadIfChangedAtPath:(NSString *)path;

/// Unconditional load, for tests. Returns NO when the file is missing or malformed.
- (BOOL)loadFromPath:(NSString *)path;

/// Drops every rule. Used by tests between cases.
- (void)unload;

/// The verdict for one request.
///
/// `documentHost` is the top frame's host, used for `$domain=`, third-party
/// tests and the per-site kill switch. Pass nil when it is unknown.
/// `outURL` receives the replacement URL for `Rewrite` and `Redirect`.
- (AuraBlockDecision)decisionForURL:(NSURL *)url
                       documentHost:(nullable NSString *)documentHost
                           typeMask:(uint32_t)typeMask
                        isMainFrame:(BOOL)isMainFrame
                         resultURL:(NSURL *_Nullable *_Nullable)outURL;

/// Best guess at a request's resource type. WebKit's injected-bundle resource
/// load client does not carry one, so this reads the `Accept` header first and
/// falls back to the URL's path extension.
+ (uint32_t)typeMaskForURL:(NSURL *)url
              acceptHeader:(nullable NSString *)acceptHeader
               isMainFrame:(BOOL)isMainFrame;

@end

NS_ASSUME_NONNULL_END

#endif /* AuraBlockRules_h */
