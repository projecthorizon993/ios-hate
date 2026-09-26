#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LumaFrameSafety : NSObject

+ (nullable NSString *)perform:(NS_NOESCAPE void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
