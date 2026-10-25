#import <React/RCTBridgeModule.h>
#import <UIKit/UIKit.h>

@interface RCT_EXTERN_MODULE(PushifyPurchases, NSObject)
RCT_EXTERN_METHOD(readDeferredToken:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
@end
