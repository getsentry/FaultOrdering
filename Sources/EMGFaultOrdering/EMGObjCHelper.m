//
//  EMGObjcHelper.h
//  EMGFaultOrdering
//
//  Created by Noah Martin on 5/17/25.
//

@import UIKit;
@import FaultOrderingSwift;

#import "EMGObjCHelper.h"

@implementation EMGObjCHelper

+ (NSObject*)startServerWithCallback:(NSData* (^)())callback {
  return [[EMGServer alloc] initWithCallback:callback];
}

@end
