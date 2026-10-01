// PWExceptionCatcher.m — see PWExceptionCatcher.h.
#import "PWExceptionCatcher.h"
@implementation PWExceptionCatcher
+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try { block(); return YES; }
    @catch (NSException *e) {
        if (error) *error = [NSError errorWithDomain:@"PrivateWhisper.ObjCException" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: e.reason ?: e.name, @"name": e.name}];
        return NO;
    }
}
@end
