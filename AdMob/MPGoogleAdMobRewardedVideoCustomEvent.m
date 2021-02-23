#import "MPGoogleAdMobRewardedVideoCustomEvent.h"
#import "GoogleAdMobAdapterConfiguration.h"
#import <GoogleMobileAds/GoogleMobileAds.h>
#if __has_include("MoPub.h")
#import "MPLogging.h"
#import "MPRewardedVideoError.h"
#import "MPReward.h"
#endif

@interface MPGoogleAdMobRewardedVideoCustomEvent () <GADFullScreenContentDelegate>
@property(nonatomic, copy) NSString *admobAdUnitId;
@property(nonatomic, strong) GADRewardedAd *rewardedAd;
@end

@implementation MPGoogleAdMobRewardedVideoCustomEvent
@dynamic delegate;
@dynamic localExtras;

- (void)initializeSdkWithParameters:(NSDictionary *)parameters {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      [[GADMobileAds sharedInstance] startWithCompletionHandler:^(GADInitializationStatus *status){
        MPLogInfo(@"Google Mobile Ads SDK initialized succesfully.");
      }];
    });
}

#pragma mark - MPFullscreenAdAdapter

- (BOOL)isRewardExpected {
    return YES;
}

- (BOOL)hasAdAvailable {
    return self.rewardedAd;
}

- (void)requestAdWithAdapterInfo:(NSDictionary *)info adMarkup:(NSString *)adMarkup {
    [self initializeSdkWithParameters:info];
    
    // Cache the network initialization parameters
    [GoogleAdMobAdapterConfiguration updateInitializationParameters:info];
    
    self.admobAdUnitId = [info objectForKey:@"adunit"];
    if (self.admobAdUnitId == nil) {
        NSError *error =
        [NSError errorWithDomain:MoPubRewardedAdsSDKDomain
                            code:MPRewardedVideoAdErrorInvalidAdUnitID
                        userInfo:@{NSLocalizedDescriptionKey : @"Ad Unit ID cannot be nil."}];
        
        MPLogAdEvent([MPLogEvent adLoadFailedForAdapter:NSStringFromClass(self.class) error:error], [self getAdNetworkId]);
        [self.delegate fullscreenAdAdapter:self didFailToLoadAdWithError:error];
        return;
    }
    
    GADRequest *request = [GADRequest request];
    if ([self.localExtras objectForKey:@"testDevices"]) {
      GADMobileAds.sharedInstance.requestConfiguration.testDeviceIdentifiers = self.localExtras[@"testDevices"];
    }

    if ([self.localExtras objectForKey:@"tagForChildDirectedTreatment"]) {
      [GADMobileAds.sharedInstance.requestConfiguration tagForChildDirectedTreatment:self.localExtras[@"tagForChildDirectedTreatment"]];
    }

    if ([self.localExtras objectForKey:@"tagForUnderAgeOfConsent"]) {
      [GADMobileAds.sharedInstance.requestConfiguration
          tagForUnderAgeOfConsent:self.localExtras[@"tagForUnderAgeOfConsent"]];
    }

    request.requestAgent = @"MoPub";

    if ([self.localExtras objectForKey:@"contentUrl"] != nil) {
        NSString *contentUrl = [self.localExtras objectForKey:@"contentUrl"];
        if ([contentUrl length] != 0) {
            request.contentURL = contentUrl;
        }
    }
    
    // Consent collected from the MoPub’s consent dialogue should not be used to set up Google's
    // personalization preference. Publishers should work with Google to be GDPR-compliant.
    
    NSString *npaValue = GoogleAdMobAdapterConfiguration.npaString;
    
    if (npaValue.length > 0) {
        GADExtras *extras = [[GADExtras alloc] init];
        extras.additionalParameters = @{@"npa": npaValue};
        [request registerAdNetworkExtras:extras];
    }

    MPLogAdEvent([MPLogEvent adLoadAttemptForAdapter:NSStringFromClass(self.class) dspCreativeId:nil dspName:nil], [self getAdNetworkId]);
    
    [GADRewardedAd loadWithAdUnitID:self.admobAdUnitId
                            request:request
                  completionHandler:^(GADRewardedAd *ad, NSError *error) {
      if (error) {
          MPLogAdEvent([MPLogEvent adLoadFailedForAdapter:NSStringFromClass(self.class) error:error], [self getAdNetworkId]);
          [self.delegate fullscreenAdAdapter:self didFailToLoadAdWithError:error];
        
          return;
      }
        
      self.rewardedAd = ad;
      self.rewardedAd.fullScreenContentDelegate = self;
        
      MPLogAdEvent([MPLogEvent adLoadSuccessForAdapter:NSStringFromClass(self.class)], [self getAdNetworkId]);
      [self.delegate fullscreenAdAdapterDidLoadAd:self];
    }];
}

- (void)presentAdFromViewController:(UIViewController *)viewController {
    MPLogAdEvent([MPLogEvent adShowAttemptForAdapter:NSStringFromClass(self.class)], [self getAdNetworkId]);
    
    if (self.rewardedAd) {
        [self.rewardedAd presentFromRootViewController:viewController
                              userDidEarnRewardHandler:^ {
            GADAdReward *reward = self.rewardedAd.adReward;
            
            MPReward *moPubReward = [[MPReward alloc] initWithCurrencyType:reward.type amount:reward.amount];
            [self.delegate fullscreenAdAdapter:self willRewardUser:moPubReward];
        }];
    } else {
        NSError *error = [NSError
                          errorWithDomain:MoPubRewardedAdsSDKDomain
                          code:MPRewardedVideoAdErrorNoAdReady
                          userInfo:@{NSLocalizedDescriptionKey : @"Rewarded ad is not ready to be presented."}];
        MPLogAdEvent([MPLogEvent adShowFailedForAdapter:NSStringFromClass(self.class) error:error], [self getAdNetworkId]);
        [self.delegate fullscreenAdAdapter:self didFailToShowAdWithError:error];
    }
}

- (BOOL)enableAutomaticImpressionAndClickTracking {
    return NO;
}

// MoPub's API includes this method because it's technically possible for two MoPub adapters or
// adapters to wrap the same SDK and therefore both claim ownership of the same cached ad. The
// method will be called if 1) this adapter has already invoked
// fullscreenAdAdapter:self handleAdEvent:MPFullscreenAdEventDidLoad on the delegate, and 2) some other adapter plays a
// rewarded video ad. It's a way of forcing this adapter to double-check that its ad is
// definitely still available and is not the one that just played. If the ad is still available, no
// action is necessary. If it's not, this adapter should call
// fullscreenAdAdapter:self handleAdEvent:MPFullscreenAdEventDidExpire to let the MoPub SDK know that it's no longer ready to play
// and needs to load another ad. That event will be passed on to the publisher app, which can then
// trigger another load.
- (void)handleDidPlayAd {
    if (!self.rewardedAd) {
        [self.delegate fullscreenAdAdapterDidExpire:self];
    }
}

#pragma mark - GADRewardedAdDelegate methods

- (void)adDidPresentFullScreenContent:(id)ad {
    MPLogAdEvent([MPLogEvent adWillAppearForAdapter:NSStringFromClass(self.class)], [self getAdNetworkId]);
    MPLogAdEvent([MPLogEvent adShowSuccessForAdapter:NSStringFromClass(self.class)], [self getAdNetworkId]);
    MPLogAdEvent([MPLogEvent adDidAppearForAdapter:NSStringFromClass(self.class)], [self getAdNetworkId]);

    [self.delegate fullscreenAdAdapterAdWillAppear:self];
    [self.delegate fullscreenAdAdapterAdDidAppear:self];
    [self.delegate fullscreenAdAdapterDidTrackImpression:self];
}

- (void)ad:(id)ad didFailToPresentFullScreenContentWithError:(NSError *)error {
    MPLogAdEvent([MPLogEvent adShowFailedForAdapter:NSStringFromClass(self.class) error:error], [self getAdNetworkId]);
    [self.delegate fullscreenAdAdapter:self didFailToShowAdWithError:error];
}

- (void)adDidDismissFullScreenContent:(id)ad {
    MPLogAdEvent([MPLogEvent adWillDisappearForAdapter:NSStringFromClass(self.class)], [self getAdNetworkId]);
    [self.delegate fullscreenAdAdapterAdWillDisappear:self];
    
    MPLogAdEvent([MPLogEvent adDidDisappearForAdapter:NSStringFromClass(self.class)], [self getAdNetworkId]);
    [self.delegate fullscreenAdAdapterAdDidDisappear:self];
    
    [self.delegate fullscreenAdAdapterAdWillDismiss:self];
    [self.delegate fullscreenAdAdapterAdDidDismiss:self];
}

- (NSString *) getAdNetworkId {
    return self.admobAdUnitId;
}

@dynamic hasAdAvailable;

@end
