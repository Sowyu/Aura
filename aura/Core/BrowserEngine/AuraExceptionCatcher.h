#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C @try so an NSException raised by a library
/// (legacy NSFileHandle APIs raise instead of throwing) comes back as an NSError
/// rather than taking the process down. Swift cannot catch these itself.
@interface AuraExceptionCatcher : NSObject
+ (nullable NSError *)tryBlock:(void (NS_NOESCAPE ^)(void))block;
@end

NS_ASSUME_NONNULL_END
