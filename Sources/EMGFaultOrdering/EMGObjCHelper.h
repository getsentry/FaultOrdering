//
//  EMGObjcHelper.h
//  EMGFaultOrdering
//
//  Created by Noah Martin on 5/17/25.
//

@interface EMGObjCHelper : NSObject

+ (NSObject*)startServerWithCallback:(NSData* (^)())callback;

@end
