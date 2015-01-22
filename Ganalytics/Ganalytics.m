//
//  Ganalytics.m
//  Ganalytics
//
//  Created by Emilio Pavia on 11/12/14.
//  Copyright (c) 2014 Emilio Pavia. All rights reserved.
//

#import "Ganalytics.h"

#ifdef DEBUG
    #define GANLog NSLog
#else
    #define GANLog(...)
#endif

//#define GAN_DEBUG		// Log call data
#define SUPPORT_IOS_6	// Use NSURLConnection in place of iOS 7-only NSURLSession

#define MAX_PAYLOAD_LENGTH 8192
#define RETRY_INTERVAL 20   // in seconds

@interface Ganalytics () <NSURLSessionDelegate>

@property (nonatomic, strong, readwrite) NSString *clientID;
@property (nonatomic, strong, readwrite) NSString *userAgent;

#ifdef SUPPORT_IOS_6
@property (nonatomic, strong) NSOperationQueue	*queue;
#else
@property (nonatomic, strong) NSURLSession *session;
#endif
@property (nonatomic, strong) NSDictionary *defaultParameters;
@property (nonatomic, strong) NSMutableDictionary *customDimensions;
@property (nonatomic, strong) NSMutableDictionary *customMetrics;
@property (nonatomic, strong) NSMutableDictionary *overrideParameters;
@property (nonatomic, strong) NSMutableDictionary *pendingRequests;

- (void)sendRequestWithParameters:(NSDictionary *)parameters date:(NSDate *)date;

@end

@interface NSDictionary (Ganalytics)

- (NSString *)gan_queryString;

@end

@implementation Ganalytics

+ (instancetype)sharedInstance {
    static Ganalytics *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[Ganalytics alloc] init];
    });
    return sharedInstance;
}

- (NSString *)pendingRequestsPath
{
	static NSString	*cachePath;
	
	if (!cachePath) {
		NSString	*cacheDir	= [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject];
		
		cachePath	= [cacheDir stringByAppendingPathComponent: @"Ganalytics.plist"];
	}
	
	return cachePath;
}

- (instancetype)initWithTrackingID:(NSString *)trackingID {
    self = [super init];
    if (self) {
        self.trackingID = trackingID;
        self.useSSL = YES;
        self.debugMode = NO;
        
        UIDevice *currentDevice = [UIDevice currentDevice];
        NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
        self.clientID = currentDevice.identifierForVendor.UUIDString;
        self.userAgent = [NSString stringWithFormat:@"%@/%@ (%@; CPU OS %@ like Mac OS X)",
                          infoDictionary[@"CFBundleName"],
                          infoDictionary[@"CFBundleShortVersionString"],
                          currentDevice.model,
                          currentDevice.systemVersion];
        
#ifdef SUPPORT_IOS_6
		self.queue		= [[NSOperationQueue alloc] init];
		self.queue.name	= @"GanalyticsQueue";
#else
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        self.session = [NSURLSession sessionWithConfiguration:configuration
                                                     delegate:nil
                                                delegateQueue:nil];
#endif
		
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        CGFloat screenScale = [UIScreen mainScreen].scale;
        self.defaultParameters = @{ @"v" : @1,
                                    @"cid" : self.clientID,
                                    @"aid" : infoDictionary[@"CFBundleIdentifier"],
                                    @"an" : infoDictionary[@"CFBundleName"],
                                    @"av" : infoDictionary[@"CFBundleShortVersionString"],
                                    @"ul" : [NSLocale preferredLanguages].firstObject,
                                    @"sr" : [NSString stringWithFormat:@"%.0fx%.0f@%.fx", CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds), screenScale]};
        
        self.customDimensions = [NSMutableDictionary dictionary];
        self.customMetrics = [NSMutableDictionary dictionary];
        self.overrideParameters = [NSMutableDictionary dictionary];
		self.pendingRequests	= [NSMutableDictionary dictionary];
		
		NSNotificationCenter	*nc	= [NSNotificationCenter defaultCenter];
		
		// Listen for app termination, save pending requests on disk in case we have some
		[nc addObserverForName: UIApplicationWillResignActiveNotification
						object: nil
						 queue: [NSOperationQueue currentQueue]
					usingBlock: ^(NSNotification *note) {
						// Save pending requests on disk for future sending
						if (self.pendingRequests.count) {
							GANLog(@"[%@] Save pending requests to disk", NSStringFromClass([self class]));
							[self.pendingRequests writeToFile: [self pendingRequestsPath] atomically: YES];
							self.pendingRequests	= nil;
						}
					}];
		[nc addObserverForName: UIApplicationDidBecomeActiveNotification
						object: nil
						 queue: [NSOperationQueue currentQueue]
					usingBlock: ^(NSNotification *note) {
						NSFileManager			*df	= [NSFileManager defaultManager];
						
						// Load pending requests on disk that could be there
						GANLog(@"[%@] Load pending requests from disk", NSStringFromClass([self class]));
						if ([df fileExistsAtPath: [self pendingRequestsPath]]) {
							// Read back pending requests and delete the file
							self.pendingRequests	= [NSMutableDictionary dictionaryWithContentsOfFile: [self pendingRequestsPath]];
							[df removeItemAtPath: [self pendingRequestsPath] error: nil];
						}
					}];
    }
    return self;
}

- (instancetype)init {
    return [self initWithTrackingID:nil];
}

- (void)sendEventWithCategory:(NSString *)category
                       action:(NSString *)action
                        label:(NSString *)label
                        value:(NSNumber *)value {
    NSParameterAssert(category);
    NSParameterAssert(action);
    
    NSMutableDictionary *parameters = @{ @"t" : @"event",
                                         @"ec" : category,
                                         @"ea" : action }.mutableCopy;
    if (label) {
        parameters[@"el"] = label;
    }
    if (value) {
        parameters[@"ev"] = value;
    }
    
    [self sendRequestWithParameters:parameters];
}

- (void)sendSocialWithNetwork:(NSString *)network
                       action:(NSString *)action
                       target:(NSString *)target {
    NSParameterAssert(network);
    NSParameterAssert(action);
    
    NSMutableDictionary *parameters = @{ @"t" : @"social",
                                         @"sn" : network,
                                         @"sa" : action }.mutableCopy;
    if (target) {
        parameters[@"st"] = target;
    }
    
    [self sendRequestWithParameters:parameters];
}

- (void)sendTimingWithCategory:(NSString *)category
                      interval:(NSNumber *)interval
                          name:(NSString *)name
                         label:(NSString *)label {
    NSParameterAssert(category);
    NSParameterAssert(interval);
    
    NSMutableDictionary *parameters = @{ @"t" : @"timing",
                                         @"utc" : category,
                                         @"utt" : interval }.mutableCopy;
    if (name) {
        parameters[@"utv"] = name;
    }
    if (label) {
        parameters[@"utl"] = label;
    }
    
    [self sendRequestWithParameters:parameters];
}

- (void)sendRequestWithParameters:(NSDictionary *)parameters date:(NSDate *)date {
    NSParameterAssert(date);
    NSAssert(self.trackingID, @"trackingID cannot be nil");
    
    NSMutableDictionary *params = self.defaultParameters.mutableCopy;
    [params addEntriesFromDictionary:self.overrideParameters];
    [params setObject:self.trackingID forKey:@"tid"];
    [params addEntriesFromDictionary:self.customDimensions];
    [params addEntriesFromDictionary:self.customMetrics];
    [params addEntriesFromDictionary:parameters];
    [params addEntriesFromDictionary:@{ @"qt" : [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSinceDate:date] * 1000.0] }];
    
    NSURLRequest *request = [self requestWithParameters:params];
    if (request.HTTPBody.length > MAX_PAYLOAD_LENGTH) {
        GANLog(@"[%@] The body must be no longer than %d bytes.", NSStringFromClass([self class]), MAX_PAYLOAD_LENGTH);
    }
    
#ifdef GAN_DEBUG
	GANLog(@"[%@] %@ %@ %@ DEBUG = %@", NSStringFromClass([self class]), request.HTTPMethod, request.URL, params, (self.debugMode ? @"YES" : @"NO"));
#endif
	
    if (!self.debugMode) {
#ifdef SUPPORT_IOS_6
		dispatch_queue_t current_queue	= dispatch_get_current_queue();
		
		[NSURLConnection sendAsynchronousRequest: [self requestWithParameters:params]
										   queue: self.queue
							   completionHandler: ^(NSURLResponse *response, NSData *data, NSError *connectionError) {
								   if (connectionError) {
									   NSInteger	errorCode	= connectionError.code;
									   
									   if (errorCode == NSURLErrorNotConnectedToInternet) {
										   // No connection, doesn't make sense retrying, store the request for later use
										   GANLog(@"[%@] No connection, storing request %@.", NSStringFromClass([self class]), parameters);
										   [self.pendingRequests setObject: parameters
																	forKey: [@([date timeIntervalSinceReferenceDate]) stringValue]];
									   } else {
										   // Internet is on, may have timed out, retry in a bit
										   dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RETRY_INTERVAL * NSEC_PER_SEC)), current_queue, ^{
											   [self sendRequestWithParameters:parameters date:date];
										   });
									   }
								   } else {
									   // If we had a successful connection, and have previous calls pending, re-queue them
									   if (self.pendingRequests.count) {
										   for (NSString *aKey in self.pendingRequests.allKeys) {
											   NSDate				*aDate		= [NSDate dateWithTimeIntervalSinceReferenceDate: [aKey doubleValue]];
											   NSMutableDictionary	*paramDict	= [NSMutableDictionary dictionaryWithDictionary: self.pendingRequests[aKey]];
											   
											   GANLog(@"[%@] Re-queueing stored request %@.", NSStringFromClass([self class]), paramDict);
											   dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RETRY_INTERVAL * NSEC_PER_SEC)), current_queue, ^{
												   [self sendRequestWithParameters: paramDict date: aDate];
											   });
										   }
										   
										   // Removing pending requests, as they've been re-queued already
										   [self.pendingRequests removeAllObjects];
									   }
								   }
							   }];
#else
        [[self.session dataTaskWithRequest:[self requestWithParameters:params]
                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                             if (error) {
								 NSInteger	errorCode	= error.code;
								 
								 if (errorCode == NSURLErrorNotConnectedToInternet) {
									 // No connection, doesn't make sense retrying, store the request for later use
									 GANLog(@"[%@] No connection, storing request %@.", NSStringFromClass([self class]), parameters);
									 [self.pendingRequests setObject: parameters
															  forKey: [@([date timeIntervalSinceReferenceDate]) stringValue]];
								 } else {
									 dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RETRY_INTERVAL * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
										 [self sendRequestWithParameters:parameters date:date];
									 });
								 }
							 } else {
								 // If we had a successful connection, and have previous calls pending, re-queue them
								 if (self.pendingRequests.count) {
									 for (NSString *aKey in self.pendingRequests.allKeys) {
										 NSDate				*aDate		= [NSDate dateWithTimeIntervalSinceReferenceDate: [aKey doubleValue]];
										 NSMutableDictionary	*paramDict	= [NSMutableDictionary dictionaryWithDictionary: self.pendingRequests[aKey]];
										 
										 GANLog(@"[%@] Re-queueing stored request %@.", NSStringFromClass([self class]), paramDict);
										 dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RETRY_INTERVAL * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
											 [self sendRequestWithParameters: paramDict date: aDate];
										 });
									 }
									 
									 // Removing pending requests, as they've been re-queued already
									 [self.pendingRequests removeAllObjects];
								 }
                            }
                         }] resume];
#endif
    }
}

- (void)sendRequestWithParameters:(NSDictionary *)parameters {
    [self sendRequestWithParameters:parameters date:[NSDate date]];
}

- (void)sendView:(NSString *)screenName {
    NSParameterAssert(screenName);
    
    NSMutableDictionary *parameters = @{ @"t" : @"screenview",
                                         @"cd" : screenName }.mutableCopy;
    
    [self sendRequestWithParameters:parameters];

}

- (void)setCustomDimensionAtIndex:(NSInteger)index
                            value:(NSString *)value {
    NSParameterAssert(value);
    
    if (index < 1 || index > 200) {
        GANLog(@"[%@] The index for custom dimensions must be between 1 and 200 (inclusive).", NSStringFromClass([self class]));
    } else {
        NSString *key = [NSString stringWithFormat:@"cd%ld", (long)index];
        self.customDimensions[key] = value;
    }
}

- (void)setCustomMetricAtIndex:(NSInteger)index
                         value:(NSInteger)value {
    if (index < 1 || index > 200) {
        GANLog(@"[%@] The index for custom metrics must be between 1 and 200 (inclusive).", NSStringFromClass([self class]));
    } else {
        NSString *key = [NSString stringWithFormat:@"cm%ld", (long)index];
        self.customMetrics[key] = [NSString stringWithFormat:@"%ld", (long)value];
    }
}

- (void)setValue:(id)value forDefaultParameter:(GANDefaultParameter)parameter {
    NSString *key = nil;
    switch (parameter) {
        case GANApplicationID:
            key = @"aid";
            break;
        case GANApplicationName:
            key = @"an";
            break;
        case GANApplicationVersion:
            key = @"av";
            break;
        default:
            break;
    }
    
    if (key) {
        if (value) {
            self.overrideParameters[key] = value;
        } else {
            [self.overrideParameters removeObjectForKey:key];
        }
    }
}

- (NSURL *)endpointURL {
    if (self.useSSL) {
        return [NSURL URLWithString:@"https://ssl.google-analytics.com/collect"];
    }
    return [NSURL URLWithString:@"http://www.google-analytics.com/collect"];
}

- (NSURLRequest *)requestWithParameters:(NSDictionary *)parameters {
    NSString *queryString = [parameters gan_queryString];
    NSData *payload = [NSData dataWithBytes:[queryString UTF8String] length:strlen([queryString UTF8String])];
    
    NSMutableURLRequest *postRequest = [NSMutableURLRequest requestWithURL:self.endpointURL];
    [postRequest setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
    [postRequest setHTTPMethod:@"POST"];
    [postRequest setHTTPBody:payload];

    return postRequest;
}

@end

@implementation NSDictionary (Ganalytics)

- (NSString *)gan_queryString {
    NSMutableArray *parameters = [NSMutableArray array];
    for (id key in self) {
        id value = [self objectForKey:key];
        NSString *parameter = [[NSString stringWithFormat: @"%@=%@", key, value] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        [parameters addObject:parameter];
    }
    return [parameters componentsJoinedByString:@"&"];
}

@end