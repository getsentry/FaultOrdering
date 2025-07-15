//
//  EMGObjcHelper.h
//  EMGFaultOrdering
//
//  Created by Noah Martin on 5/17/25.
//

#if TARGET_OS_IOS
@import UIKit;
#elif TARGET_OS_OSX
@import AppKit;
#endif
@import FaultOrderingSwift;

#import "EMGObjCHelper.h"

@implementation EMGObjCHelper

+ (NSObject*)startServerWithCallback:(NSData* (^)())callback {
    return [[EMGServer alloc] initWithCallback:callback];
}

@end
