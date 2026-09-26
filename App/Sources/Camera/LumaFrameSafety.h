#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LumaFrameSafety : NSObject

+ (nullable NSString *)perform:(void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
