//
//  Ganalytics.h
//  Ganalytics
//
//  Created by Emilio Pavia on 11/12/14.
//  Copyright (c) 2014 Emilio Pavia. All rights reserved.
//

#import <UIKit/UIKit.h>

#define SUPPORT_IDFA	// Leaving this not commented means you've to declare you're using IDFA when submitting

// From http://holko.pl/2015/05/31/weakify-strongify/
#define weakify(var) __weak typeof(var) AHKWeak_##var = var;

#define strongify(var) \
	_Pragma("clang diagnostic push") \
	_Pragma("clang diagnostic ignored \"-Wshadow\"") \
	__strong typeof(var) var = AHKWeak_##var; \
	_Pragma("clang diagnostic pop")


typedef NS_ENUM(NSInteger, GANDefaultParameter) {
    GANApplicationID,
    GANApplicationName,
    GANApplicationVersion
};

@interface Ganalytics : NSObject

@property (nonatomic, strong) NSString *trackingID;

@property (nonatomic, assign) BOOL useSSL;				// YES by default
@property (nonatomic, assign) BOOL debugMode;   		// NO by default
@property (nonatomic, assign) BOOL allowIDFACollection;	// NO by default


+ (instancetype)sharedInstance;

- (instancetype)initWithTrackingID:(NSString *)trackingID NS_DESIGNATED_INITIALIZER;

- (void)sendEventWithCategory:(NSString *)category  // required
                       action:(NSString *)action    // required
                        label:(NSString *)label     // optional
                        value:(NSNumber *)value;    // optional

- (void)sendSocialWithNetwork:(NSString *)network   // required
                       action:(NSString *)action    // required
                       target:(NSString *)target;   // optional

- (void)sendTimingWithCategory:(NSString *)category // required
                      interval:(NSNumber *)interval // required (milliseconds)
                          name:(NSString *)name     // optional
                         label:(NSString *)label;   // optional

- (void)sendView:(NSString *)screenName;

- (void)setCustomDimensionAtIndex:(NSInteger)index  // between 1 and 200 (inclusive)
                            value:(NSString *)value;

- (void)setCustomMetricAtIndex:(NSInteger)index     // between 1 and 200 (inclusive)
                         value:(NSInteger)value;

- (void)setValue:(id)value forDefaultParameter:(GANDefaultParameter)parameter;  // use this method to override default parameters

- (void)sendRequestWithParameters:(NSDictionary *)parameters;

@end
