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

#define kSystemVersion [[[UIDevice currentDevice] systemVersion] floatValue]

//#define GAN_DEBUG		// Log call data

#define MAX_PAYLOAD_LENGTH 8192
// interval between the request posting, in seconds
// Official Google SDK has event throttling, then a limit to throughput is desirable,
// even though we try to avoid dropping any event
// (see https://developers.google.com/analytics/devguides/collection/other/limits-quotas#client_libs_sdks )
#define QUEUE_INTERVAL 0.3

@interface Ganalytics ()

@property (nonatomic, strong, readwrite) NSString *clientID;
@property (nonatomic, strong, readwrite) NSString *userAgent;

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSDictionary *defaultParameters;
@property (nonatomic, strong) NSMutableDictionary *customDimensions;
@property (nonatomic, strong) NSMutableDictionary *customMetrics;
@property (nonatomic, strong) NSMutableDictionary *overrideParameters;
@property (nonatomic, strong) NSMutableArray *pendingRequests;
@property (nonatomic, strong) NSTimer *queueTimer;
@property (assign, getter=isSending) BOOL sending;

- (void)sendRequestWithParameters:(NSDictionary *)parameters date:(NSDate *)date;
- (void)pickRequestFromQueue: (NSTimer *)aTimer;
- (NSURL *)endpointURL;
- (NSURLRequest *)requestWithParameters:(NSDictionary *)parameters;

// Persistence methods
- (NSString *)pendingRequestsPath;
- (void)savePendingRequests;
- (void)loadPendingRequests;

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
		
		if (kSystemVersion >= 7.0) {
			NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
			self.session = [NSURLSession sessionWithConfiguration: configuration
														 delegate: nil
													delegateQueue: [NSOperationQueue currentQueue]];
		}
		
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        CGFloat screenScale = [UIScreen mainScreen].scale;
        self.defaultParameters = @{ @"v" : @1,
                                    @"cid" : self.clientID,
                                    @"aid" : infoDictionary[@"CFBundleIdentifier"],
                                    @"an" : infoDictionary[@"CFBundleName"],
                                    @"av" : infoDictionary[@"CFBundleShortVersionString"],
                                    @"ul" : [NSLocale preferredLanguages].firstObject,
                                    @"sr" : [NSString stringWithFormat:@"%.0fx%.0f@%.fx", CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds), screenScale]};
        
        self.customDimensions	= [NSMutableDictionary dictionary];
        self.customMetrics		= [NSMutableDictionary dictionary];
        self.overrideParameters = [NSMutableDictionary dictionary];
		
		// Loads pending requests, if any, and starts queue timer
		[self loadPendingRequests];
		
		NSNotificationCenter		*nc	= [NSNotificationCenter defaultCenter];
		 __weak __typeof__(self)	wself	= self;
		
		// Listen for app suspend, save pending requests on disk in case we have some
		[nc addObserverForName: UIApplicationWillResignActiveNotification
						object: nil
						 queue: [NSOperationQueue currentQueue]
					usingBlock: ^(NSNotification *note) {
						if (wself.session)
							[wself.session flushWithCompletionHandler:^{
								[wself savePendingRequests];
							}];
						else
							[wself savePendingRequests];
					}];
		// Listen for app resume, load pending requests from disk in case we have some
		[nc addObserverForName: UIApplicationDidBecomeActiveNotification
						object: nil
						 queue: [NSOperationQueue currentQueue]
					usingBlock: ^(NSNotification *note) {
						[wself loadPendingRequests];
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

- (void)sendRequestWithParameters:(NSDictionary *)parameters {
	[self.pendingRequests addObject: parameters];
}

#pragma mark - Private methods

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
		if (self.session)
			[[self.session dataTaskWithRequest: [self requestWithParameters:params]
							 completionHandler: ^(NSData *data, NSURLResponse *response, NSError *error) {
								 if (!error)
									 [self.pendingRequests removeObjectAtIndex: 0];
								 
								 self.sending	= NO;
							 }] resume];
		else
			[NSURLConnection sendAsynchronousRequest: [self requestWithParameters:params]
											   queue: [NSOperationQueue currentQueue]
								   completionHandler: ^(NSURLResponse *response, NSData *data, NSError *connectionError) {
									   if (!connectionError)
										   [self.pendingRequests removeObjectAtIndex: 0];
									   
									   self.sending	= NO;
								   }];
	} else {
		self.sending	= NO;
	}
}

- (void)pickRequestFromQueue: (NSTimer *)aTimer
{
	// Do nothing if there are no pending requests or one is being sent already
	if (!self.pendingRequests.count || self.isSending)
		return;
	
	self.sending	= YES;
	
	NSDictionary	*parameters	= [self.pendingRequests objectAtIndex: 0];
	
	[self sendRequestWithParameters: parameters date: [NSDate date]];
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

#pragma mark - Requests Persistence

- (NSString *)pendingRequestsPath
{
	static NSString	*cachePath;
	
	if (!cachePath) {
		NSString	*cacheDir	= [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject];
		
		cachePath	= [cacheDir stringByAppendingPathComponent: @"Ganalytics.plist"];
	}
	
	return cachePath;
}

- (void)savePendingRequests
{
	// Save pending requests on disk for future sending, empty queue
	if (self.pendingRequests.count) {
		GANLog(@"[%@] Save pending requests to disk", NSStringFromClass([self class]));
		
		[self.pendingRequests writeToFile: [self pendingRequestsPath] atomically: YES];
		self.pendingRequests	= nil;
	}
	
	// Queue has been removed, stop timer
	[self.queueTimer invalidate];	self.queueTimer	= nil;
}

- (void)loadPendingRequests
{
	NSFileManager			*df	= [NSFileManager defaultManager];
	
	// Load pending requests on disk that could be there
	if ([df fileExistsAtPath: [self pendingRequestsPath]]) {
		GANLog(@"[%@] Load pending requests from disk", NSStringFromClass([self class]));
		
		// Read back pending requests and delete the file
		self.pendingRequests	= [NSMutableArray arrayWithContentsOfFile: [self pendingRequestsPath]];
		[df removeItemAtPath: [self pendingRequestsPath] error: nil];
	} else if (!self.pendingRequests) {
		self.pendingRequests	= [NSMutableArray array];
	}
	
	// Now that we have a queue to work on, start timer
	if (!self.queueTimer)
		self.queueTimer	= [NSTimer scheduledTimerWithTimeInterval: QUEUE_INTERVAL
														   target: self
														 selector: @selector(pickRequestFromQueue:)
														 userInfo: nil
														  repeats: YES];
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