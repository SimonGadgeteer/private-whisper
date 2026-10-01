// PWTextProxy.h — new code; technique from Dictus TextProxyIdentity.m (https://github.com/getdictus/dictus-ios, PR #282).
// MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
// Swift imports documentIdentifier as a non-optional UUID and traps on nil; ObjC can return nil safely.
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface PWTextProxy : NSObject
+ (nullable NSUUID *)documentIdentifierOf:(id<UITextDocumentProxy>)proxy NS_SWIFT_NAME(documentIdentifier(of:));
@end
NS_ASSUME_NONNULL_END
