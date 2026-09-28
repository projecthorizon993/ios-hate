#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block that may raise an Objective-C exception and converts the failure
/// into a string instead of terminating the process.
///
/// AVFoundation raises `NSInvalidArgumentException` for a number of out-of-range or
/// unsupported configuration values (for example writing `isVideoHDREnabled` on a
/// format where it is not supported). Swift cannot catch those, so every place that
/// mutates AVFoundation state must be wrapped.
@interface LumaFrameSafety : NSObject

/// Executes `block`. Returns `nil` on success, or a `"Name: reason"` description of
/// the exception that was raised.
+ (nullable NSString *)perform:(void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
