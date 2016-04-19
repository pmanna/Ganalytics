//
//  Ganalytics.m
//  Ganalytics
//
//  Created by Emilio Pavia on 11/12/14.
//  Copyright (c) 2014 Emilio Pavia. All rights reserved.
//

#import "Ganalytics.h"
#import <pthread.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#ifdef SUPPORT_IDFA
#import <AdSupport/AdSupport.h>
#endif

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

@interface Ganalytics () {
	pthread_mutex_t	mutex;
}

@property (nonatomic, strong, readwrite) NSString *clientID;
@property (nonatomic, strong, readwrite) NSString *userAgent;
@property (nonatomic, strong, readwrite) NSString *idfa;

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSDictionary *defaultParameters;
@property (nonatomic, strong) NSMutableDictionary *customDimensions;
@property (nonatomic, strong) NSMutableDictionary *customMetrics;
@property (nonatomic, strong) NSMutableDictionary *overrideParameters;
@property (nonatomic, strong) NSMutableArray *pendingRequests;
@property (nonatomic, strong) dispatch_source_t queueTimer;
@property (nonatomic, assign) NSUInteger progBase;
@property (nonatomic, assign) NSUInteger progIndex;
@property (assign, getter=isSending) BOOL sending;

- (NSString *)hardwareString;
- (void)processResponse: (NSURLResponse *)aResponse withData: (NSData *)someData error: (NSError *)error;
- (void)sendRequestWithParameters:(NSDictionary *)parameters date:(NSDate *)date;
- (void)pickRequestFromQueue;
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
		// Always good to have random engine setup...
		srandom((unsigned)time(NULL));
		
        sharedInstance = [[Ganalytics alloc] init];
    });
    return sharedInstance;
}

- (instancetype)initWithTrackingID:(NSString *)trackingID {
    self = [super init];
    if (self) {
        self.trackingID				= trackingID;
        self.useSSL					= YES;
        self.debugMode				= NO;
		self.allowIDFACollection	= NO;
		self.progBase				= (NSUInteger)random();
		self.progIndex				= 1;
		
		pthread_mutex_init(&mutex, NULL);
		
        UIDevice *currentDevice = [UIDevice currentDevice];
        NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
		
		// WARN: This may return NULL on iOS 7, so ensure to request it later!
		// http://stackoverflow.com/questions/22849932/identifierforvendor-for-uuidstring-returns-null
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
        self.defaultParameters = @{ @"v"  : @1,
									@"_v" : @"mi3.1.5",	// Simulate GAI SDK 3.1.5
									@"_crc" : @0,		// See above, seems to always be 0
									@"ds" : @"app",
									@"dm" : [self hardwareString],
                                    @"aid" : infoDictionary[@"CFBundleIdentifier"],
                                    @"an" : infoDictionary[@"CFBundleName"],
                                    @"av" : infoDictionary[@"CFBundleShortVersionString"],
                                    @"ul" : [NSLocale preferredLanguages].firstObject,
                                    @"sr" : [NSString stringWithFormat:@"%.0fx%.0f", CGRectGetWidth(screenBounds) * screenScale, CGRectGetHeight(screenBounds) * screenScale]};
        
        self.customDimensions	= [NSMutableDictionary dictionary];
        self.customMetrics		= [NSMutableDictionary dictionary];
        self.overrideParameters = [NSMutableDictionary dictionary];
		
		// Loads pending requests, if any, and starts queue timer
		[self loadPendingRequests];
		
		NSNotificationCenter		*nc	= [NSNotificationCenter defaultCenter];
		
		weakify(self);
		
		// Listen for app suspend, save pending requests on disk in case we have some
		[nc addObserverForName: UIApplicationWillResignActiveNotification
						object: nil
						 queue: [NSOperationQueue currentQueue]
					usingBlock: ^(NSNotification *note) {
						strongify(self);
						
						if (self.session)
							[self.session flushWithCompletionHandler:^{
								[self savePendingRequests];
							}];
						else
							[self savePendingRequests];
					}];
		
		// Listen for app resume, load pending requests from disk in case we have some
		[nc addObserverForName: UIApplicationDidBecomeActiveNotification
						object: nil
						 queue: [NSOperationQueue currentQueue]
					usingBlock: ^(NSNotification *note) {
						strongify(self);
						
						[self loadPendingRequests];
					}];
    }
    return self;
}

- (instancetype)init {
    return [self initWithTrackingID:nil];
}

- (void)dealloc
{
	pthread_mutex_destroy(&mutex);
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

- (void)sendRequestWithParameters:(NSDictionary *)parameters
{
	pthread_mutex_lock(&mutex);
	[self.pendingRequests addObject: parameters];
	pthread_mutex_unlock(&mutex);
}

#pragma mark - Private methods

- (NSString*)hardwareString
{
	int			name[]	= {CTL_HW,HW_MACHINE};
	size_t		size	= 100;
	
	sysctl(name, 2, NULL, &size, NULL, 0); // getting size of answer
	
	char		*hw_machine = malloc(size);
	
	sysctl(name, 2, hw_machine, &size, NULL, 0);
	
	NSString	*hardware	= [NSString stringWithUTF8String:hw_machine];
	free(hw_machine);
	
	return hardware;
}

- (void)processResponse: (NSURLResponse *)aResponse withData: (NSData *)someData error: (NSError *)error
{
	pthread_mutex_lock(&mutex);
	
#ifdef DEBUG
	// See https://developers.google.com/analytics/devguides/collection/protocol/v1/validating-hits
	if (someData) {
		NSError __autoreleasing	*jsonError		= nil;
		NSDictionary			*requestResult	= [NSJSONSerialization JSONObjectWithData: someData
																				  options: 0
																					error: &jsonError];
		
		if (!jsonError && [requestResult isKindOfClass: [NSDictionary class]]) {
			NSArray		*hitArray	= (NSArray *)requestResult[@"hitParsingResult"];
			
			if ([hitArray isKindOfClass: [NSArray class]] && (hitArray.count > 0)) {
				NSDictionary	*hitResult	= hitArray[0];
				
				if (![hitResult[@"valid"] boolValue])
					NSLog(@"Wrong Ganalytics hit request: %@\n%@", hitResult[@"hit"], hitResult[@"parserMessage"]);
			}
		} else {
			NSLog(@"Bad Ganalytics debug response: %@", [jsonError localizedDescription]);
		}
	}
#endif
	
	if (error) {
		NSLog(@"Ganalytics error: %@", [error localizedDescription]);
	} else if (self.pendingRequests.count) {
		[self.pendingRequests removeObjectAtIndex: 0];
	}
	
	self.sending	= NO;
	pthread_mutex_unlock(&mutex);
}

- (void)sendRequestWithParameters:(NSDictionary *)parameters date:(NSDate *)date {
    NSParameterAssert(date);
    NSAssert(self.trackingID, @"trackingID cannot be nil");
	
	NSDate	*now	= [NSDate date];
	
	// Request this again, iOS 7 bug, see above
	if (!self.clientID)
		self.clientID = [UIDevice currentDevice].identifierForVendor.UUIDString;
	
    NSMutableDictionary *params = self.defaultParameters.mutableCopy;
    [params addEntriesFromDictionary:self.overrideParameters];
    [params setObject:self.trackingID forKey:@"tid"];
	if (self.clientID)
		[params setObject: [self.clientID lowercaseString] forKey:@"cid"];
    [params addEntriesFromDictionary:self.customDimensions];
    [params addEntriesFromDictionary:self.customMetrics];
    [params addEntriesFromDictionary:parameters];
    [params addEntriesFromDictionary:@{ @"qt" : [NSString stringWithFormat:@"%.0f", [now timeIntervalSinceDate:date] * 1000.0],
										@"a": [NSString stringWithFormat:@"%lu", (unsigned long)(self.progBase + self.progIndex)],
										@"_s": [NSString stringWithFormat:@"%lu", (unsigned long)(self.progIndex)],
										@"ht": [NSString stringWithFormat:@"%.0f", [now timeIntervalSince1970] * 1000.0]}];
	self.progIndex++;
#ifdef SUPPORT_IDFA
	if (self.allowIDFACollection) {
		// No need to check [[ASIdentifierManager sharedManager] isAdvertisingTrackingEnabled],
		// attribution & conversion are permitted uses
		if (!self.idfa)
			self.idfa	= [[[ASIdentifierManager sharedManager] advertisingIdentifier].UUIDString copy];
		
		if (self.idfa)	// As above, iOS 7 bug, can still be nil
			[params addEntriesFromDictionary: @{@"ate":@"1", @"idfa": self.idfa}];
	}
#endif
	
    NSURLRequest *request = [self requestWithParameters:params];
    if (request.HTTPBody.length > MAX_PAYLOAD_LENGTH) {
        GANLog(@"[%@] The body must be no longer than %d bytes.", NSStringFromClass([self class]), MAX_PAYLOAD_LENGTH);
    }
    
#ifdef GAN_DEBUG
	GANLog(@"[%@] %@ %@ %@ DEBUG = %@", NSStringFromClass([self class]), request.HTTPMethod, request.URL, params, (self.debugMode ? @"YES" : @"NO"));
#endif
	
    if (!self.debugMode) {
		weakify(self);
		
		if (self.session)
			[[self.session dataTaskWithRequest: [self requestWithParameters:params]
							 completionHandler: ^(NSData *data, NSURLResponse *response, NSError *error) {
								 strongify(self);
								 
								 [self processResponse: response withData: data error: error];
							 }] resume];
		else
			[NSURLConnection sendAsynchronousRequest: [self requestWithParameters:params]
											   queue: [NSOperationQueue currentQueue]
								   completionHandler: ^(NSURLResponse *response, NSData *data, NSError *connectionError) {
									   strongify(self);
									   
									   [self processResponse: response withData: data error: connectionError];
								   }];
	} else {
		pthread_mutex_lock(&mutex);
		self.sending	= NO;
		pthread_mutex_unlock(&mutex);
	}
}

- (void)pickRequestFromQueue
{
	pthread_mutex_lock(&mutex);
	// Do nothing if there are no pending requests or one is being sent already
	if (!self.pendingRequests.count || self.isSending) {
		pthread_mutex_unlock(&mutex);
		return;
	}
	
	self.sending	= YES;
	
	NSDictionary	*parameters	= [self.pendingRequests objectAtIndex: 0];
	
	[self sendRequestWithParameters: parameters date: [NSDate date]];
	pthread_mutex_unlock(&mutex);
}

- (NSURL *)endpointURL {
#ifdef DEBUG
	// See https://developers.google.com/analytics/devguides/collection/protocol/v1/validating-hits
	if (self.useSSL) {
		return [NSURL URLWithString:@"https://ssl.google-analytics.com/debug/collect"];
	}
	return [NSURL URLWithString:@"https://www.google-analytics.com/debug/collect"];
#else
    if (self.useSSL) {
        return [NSURL URLWithString:@"https://ssl.google-analytics.com/collect"];
    }
    return [NSURL URLWithString:@"http://www.google-analytics.com/collect"];
#endif
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
	pthread_mutex_lock(&mutex);
	
	// Queue will be removed, stop timer
	if (self.queueTimer != nil) {
		dispatch_cancel(self.queueTimer);
		self.queueTimer	= nil;
	}
	
	// Save pending requests on disk for future sending, empty queue
	if (self.pendingRequests.count) {
		GANLog(@"[%@] Save pending requests to disk", NSStringFromClass([self class]));
		
		[self.pendingRequests writeToFile: [self pendingRequestsPath] atomically: YES];
		self.pendingRequests	= nil;
	}
	
	pthread_mutex_unlock(&mutex);
}

- (void)loadPendingRequests
{
	NSFileManager			*df	= [NSFileManager defaultManager];
	
	pthread_mutex_lock(&mutex);
	// Load pending requests on disk that could be there
	if ([df fileExistsAtPath: [self pendingRequestsPath]]) {
		GANLog(@"[%@] Load pending requests from disk", NSStringFromClass([self class]));
		
		// Read back pending requests and delete the file
		self.pendingRequests	= [NSMutableArray arrayWithContentsOfFile: [self pendingRequestsPath]];
		[df removeItemAtPath: [self pendingRequestsPath] error: nil];
	} else if (!self.pendingRequests) {
		self.pendingRequests	= [NSMutableArray array];
	}
	
	// Now that we have a queue to work on, start timer on a specific GCD queue
	if (!self.queueTimer) {
		NSString			*queueId	= [NSString stringWithFormat: @"%@.ganalytics", [[NSBundle mainBundle] bundleIdentifier]];
		dispatch_queue_t	t_queue		= dispatch_queue_create([queueId UTF8String], 0);
		
		self.queueTimer	= dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, t_queue);
		
		dispatch_source_set_timer(self.queueTimer, dispatch_walltime(NULL, 0),
								  (int64_t)(QUEUE_INTERVAL * (double)NSEC_PER_SEC),
								  (int64_t)(0.1 * (double)NSEC_PER_SEC));

		dispatch_source_set_event_handler(self.queueTimer, ^{
			[self pickRequestFromQueue];
		});
		
		dispatch_resume(self.queueTimer);
	}
	pthread_mutex_unlock(&mutex);
}

@end

@implementation NSDictionary (Ganalytics)

- (NSString *)gan_queryString {
    NSMutableArray *parameters = [NSMutableArray array];
    for (id key in self) {
		id	value	= (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
																							(CFStringRef)[[self objectForKey:key] description],
																							NULL,
																							CFSTR("!*'();:@&=+$,/?%#[]"),
																							kCFStringEncodingUTF8);
		
        NSString *parameter = [NSString stringWithFormat: @"%@=%@", key, value];
        [parameters addObject:parameter];
    }
	
	// Add cache buster as last parameter
	[parameters addObject: [NSString stringWithFormat: @"z=%ld", labs(random())]];
	
    return [parameters componentsJoinedByString:@"&"];
}

@end