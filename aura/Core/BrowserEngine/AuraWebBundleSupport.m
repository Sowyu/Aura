#import "AuraWebBundleSupport.h"

#import <WebKit/WebKit.h>

// Private API, transcribed from WebKit trunk
// Source/WebKit/UIProcess/API/Cocoa/_WKProcessPoolConfiguration.h and
// Source/WebKit/UIProcess/API/Cocoa/WKProcessPoolPrivate.h.
@interface _WKProcessPoolConfiguration: NSObject <NSCopying>
@property (nonatomic, copy) NSURL *injectedBundleURL;
@end

@interface WKProcessPool (AuraPrivate)
- (instancetype)_initWithConfiguration:(_WKProcessPoolConfiguration *)configuration;
@end

WKProcessPool *AuraMakeInjectedBundleProcessPool(NSURL *bundleURL)
{
    Class configurationClass = NSClassFromString(@"_WKProcessPoolConfiguration");
    if (!configurationClass) { return nil; }
    if (![WKProcessPool instancesRespondToSelector:@selector(_initWithConfiguration:)]) { return nil; }

    _WKProcessPoolConfiguration *configuration = [[configurationClass alloc] init];
    if (![configuration respondsToSelector:@selector(setInjectedBundleURL:)]) { return nil; }
    configuration.injectedBundleURL = bundleURL;

    return [[WKProcessPool alloc] _initWithConfiguration:configuration];
}
