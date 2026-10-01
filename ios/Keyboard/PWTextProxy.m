// PWTextProxy.m — see PWTextProxy.h.
#import "PWTextProxy.h"
@implementation PWTextProxy
+ (nullable NSUUID *)documentIdentifierOf:(id<UITextDocumentProxy>)proxy {
    if (proxy == nil) return nil;
    if (![(id)proxy respondsToSelector:@selector(documentIdentifier)]) return nil;
    return proxy.documentIdentifier;
}
@end
