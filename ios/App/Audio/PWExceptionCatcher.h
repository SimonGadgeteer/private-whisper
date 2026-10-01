// PWExceptionCatcher.h — new code for Private Whisper; technique from Dictus ObjCExceptionCatcher
// (https://github.com/getdictus/dictus-ios, #71/#102/#417). MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PWExceptionCatcher : NSObject
/// Runs `block`; an Objective-C exception becomes an NSError (Swift: `throws`).
+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(run(_:));
@end
NS_ASSUME_NONNULL_END
