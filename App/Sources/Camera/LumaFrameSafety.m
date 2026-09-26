#import "LumaFrameSafety.h"

@implementation LumaFrameSafety

+ (nullable NSString *)perform:(void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: @"unknown reason";
        return [NSString stringWithFormat:@"%@: %@", exception.name, reason];
    }
}

@end
