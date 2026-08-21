#import "AuraExceptionCatcher.h"

@implementation AuraExceptionCatcher

+ (NSError *)tryBlock:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name;
        return [NSError errorWithDomain:@"AuraExceptionCatcher"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: reason ?: @"Objective-C exception"}];
    }
}

@end
