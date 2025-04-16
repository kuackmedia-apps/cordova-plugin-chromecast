//
//  MLPChromecast.m
//  ChromeCast

#import "MLPChromecast.h"
#import "MLPCastUtilities.h"

#define IDIOM    UI_USER_INTERFACE_IDIOM()
#define IPAD     UIUserInterfaceIdiomPad

@interface MLPChromecast()
@end

@implementation MLPChromecast
NSString* appId = nil;
CDVInvokedUrlCommand* scanCommand = nil;
int scansRunning = 0;

- (void)pluginInitialize {
    [super pluginInitialize];
    self.currentSession = [MLPChromecastSession alloc];

/*
    NSString* applicationId = [NSUserDefaults.standardUserDefaults stringForKey:@"appId"];
    if (applicationId == nil) {
        applicationId = kGCKDefaultMediaReceiverApplicationID;
    }
    [self setAppId:applicationId];
*/
}

- (void)setAppId:(NSString*)applicationId {
    // If the applicationId is invalid or has not changed, don't do anything
    if ([self isValidAppId:applicationId] && [applicationId isEqualToString:appId]) {
        return;
    }
    appId = applicationId;

  // 🚩 Guardar claramente appId en NSUserDefaults
    [NSUserDefaults.standardUserDefaults setObject:appId forKey:@"appId"];
    [NSUserDefaults.standardUserDefaults synchronize];

    GCKDiscoveryCriteria *criteria = [[GCKDiscoveryCriteria alloc]
                                      initWithApplicationID:appId];
    GCKCastOptions *options = [[GCKCastOptions alloc] initWithDiscoveryCriteria:criteria];
    options.physicalVolumeButtonsWillControlDeviceVolume = YES;
    options.disableDiscoveryAutostart = NO;
    options.suspendSessionsWhenBackgrounded = NO;
    [GCKCastContext setSharedInstanceWithOptions:options];

    // Enable chromecast logger.
//    [GCKLogger sharedInstance].delegate = self;

    // Ensure we have only 1 listener attached
    [GCKCastContext.sharedInstance.discoveryManager removeListener:self];
    [GCKCastContext.sharedInstance.discoveryManager addListener:self];

    [GCKCastContext.sharedInstance.sessionManager removeListener: self];
    [GCKCastContext.sharedInstance.sessionManager addListener: self];

    self.currentSession = [self.currentSession initWithListener:self cordovaDelegate:self.commandDelegate];
}

- (BOOL)isValidAppId:(NSString*)applicationId {
    if (applicationId == (id)[NSNull null] || applicationId.length == 0) {
        return NO;
    }
    return YES;
}

// Override CDVPlugin onReset
// Called when the webview navigates to a new page or refreshes
// Clean up any running process
- (void)onReset {
    [self stopRouteScanForSetup];
}

- (void)setup:(CDVInvokedUrlCommand*) command {
    self.eventCommand = command;
    [self stopRouteScanForSetup];
    [self sendEvent:@"SETUP" args:@[]];
}

-(void) initialize:(CDVInvokedUrlCommand*)command {
    NSString* applicationId = command.arguments[0];

    // If the app id is invalid just send success and return
    if (![self isValidAppId:applicationId]) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:@[]];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    [self setAppId:applicationId];

    // Initialize success
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:@[]];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];

    // Search for existing session with improved rejoin logic
    [self findAvailableReceiver:^{
        // Start device discovery to ensure device is available
        [[GCKCastContext sharedInstance].discoveryManager startDiscovery];

        // Add a brief delay before attempting to rejoin to allow discovery to find devices
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"Attempting to rejoin existing session");
            [self.currentSession tryRejoin];
        });
    }];
}

- (void)findAvailableReceiver:(void(^)(void))successCallback {
    // Ensure the scan is running
    [self startRouteScan];

    // Log the start of device discovery
    NSLog(@"Starting device discovery for available receivers");

    // Increased retry count to 8 (using new exponential backoff in retry method)
    // This gives more time for device discovery with gradually increasing intervals
    [MLPCastUtilities retry:^BOOL{
        // Did we find any devices?
        BOOL hasDevices = [GCKCastContext.sharedInstance.discoveryManager hasDiscoveredDevices];

        if (hasDevices) {
            // Get device count for logging
            NSUInteger deviceCount = [GCKCastContext.sharedInstance.discoveryManager deviceCount];
            NSLog(@"Found %lu Chromecast device(s)", (unsigned long)deviceCount);

            // See if any of these devices matches our saved session
            GCKSessionManager *sessionManager = [GCKCastContext sharedInstance].sessionManager;
            GCKSession *currentSession = sessionManager.currentSession;

            if (currentSession != nil) {
                NSString *deviceId = currentSession.device.deviceID;
                BOOL foundSessionDevice = NO;

                // Check if the device from our saved session is among the discovered devices
                for (NSUInteger i = 0; i < deviceCount; i++) {
                    GCKDevice *device = [[GCKCastContext sharedInstance].discoveryManager deviceAtIndex:i];
                    if ([device.deviceID isEqualToString:deviceId]) {
                        NSLog(@"Found device matching our current session: %@", device.friendlyName);
                        foundSessionDevice = YES;
                        break;
                    }
                }

                if (!foundSessionDevice) {
                    NSLog(@"Warning: Current session device not found in discovery results");
                }
            }

            [self sendReceiverAvailable:YES];
            return YES;
        }

        NSLog(@"No Chromecast devices found yet, continuing discovery...");
        return NO;
    } forTries:8 callback:^(BOOL passed){
        if (passed) {
            NSLog(@"Device discovery completed successfully, proceeding with session setup");
            successCallback();
        } else {
            NSLog(@"Failed to find any Chromecast devices after several attempts");
        }
    }];
}

- (void)stopRouteScanForSetup {
    if (scansRunning > 0) {
        // Terminate all scans
        scansRunning = 0;
        [self sendError:@"cancel" message:@"Scan stopped because setup triggered." command:scanCommand];
        scanCommand = nil;
        [self stopRouteScan];
    }
}

- (BOOL)stopRouteScan:(CDVInvokedUrlCommand*)command {
    if (scanCommand != nil) {
        [self stopRouteScan];
        [self sendError:@"cancel" message:@"Scan stopped." command:scanCommand];
        scanCommand = nil;
    }
    if (command != nil) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:@[]];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }
    return YES;
}

- (void)stopRouteScan {
    if (--scansRunning <= 0) {
        scansRunning = 0;
        [[GCKCastContext sharedInstance].discoveryManager stopDiscovery];
    }
}

-(BOOL) startRouteScan:(CDVInvokedUrlCommand*)command {
    if (scanCommand != nil) {
        [self sendError:@"cancel" message:@"Started a new route scan before stopping previous one." command:scanCommand];
    } else {
        // Only start the scan if the user has not already started one
        [self startRouteScan];
    }
    scanCommand = command;
    [self sendScanUpdate];
    return YES;
}

-(void) startRouteScan {
    scansRunning++;
    [[GCKCastContext sharedInstance].discoveryManager startDiscovery];
}

- (void)sendScanUpdate {
    if (scanCommand == nil) {
        return;
    }

    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:[MLPCastUtilities createDeviceArray]];
    [pluginResult setKeepCallback:@(true)];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:scanCommand.callbackId];
}

- (void)requestSession:(CDVInvokedUrlCommand*) command {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Cast to" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    GCKDiscoveryManager* discoveryManager = GCKCastContext.sharedInstance.discoveryManager;
    for (int i = 0; i < [discoveryManager deviceCount]; i++) {
        GCKDevice* device = [discoveryManager deviceAtIndex:i];
        [alert addAction:[UIAlertAction actionWithTitle:device.friendlyName style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self.currentSession joinDevice:device cdvCommand:command];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Stop Casting" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self.currentSession endSessionWithCallback:^{
            [self sendError:@"cancel" message:@"" command:command];
        } killSession:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [self.currentSession.remoteMediaClient stop];
        [self sendError:@"cancel" message:@"" command:command];
    }]];
    if (IDIOM == IPAD) {
        alert.popoverPresentationController.sourceView = self.webView;
        CGRect frame = CGRectMake(self.webView.frame.size.width/2, self.webView.frame.size.height, self.webView.bounds.size.width/2, self.webView.bounds.size.height);
        alert.popoverPresentationController.sourceRect = frame;
    }
    [self.viewController presentViewController:alert animated:YES completion:nil];
}

- (void)queueLoad:(CDVInvokedUrlCommand *)command {
    NSDictionary *request = command.arguments[0];
    NSArray *items = request[@"items"];
    NSInteger startIndex = [request[@"startIndex"] integerValue];
    NSString *repeadModeString = request[@"repeatMode"];
    GCKMediaRepeatMode repeatMode = GCKMediaRepeatModeAll;
    if ([repeadModeString isEqualToString:@"REPEAT_OFF"]) {
        repeatMode = GCKMediaRepeatModeOff;
    }
    else if ([repeadModeString isEqualToString:@"REPEAT_ALL"]) {
        repeatMode = GCKMediaRepeatModeAll;
    }
    else if ([repeadModeString isEqualToString:@"REPEAT_SINGLE"]) {
        repeatMode = GCKMediaRepeatModeSingle;
    }
    else if ([repeadModeString isEqualToString:@"REPEAT_ALL_AND_SHUFFLE"]) {
        repeatMode = GCKMediaRepeatModeAllAndShuffle;
    }

    NSMutableArray *queueItems = [[NSMutableArray alloc] init];
    for (NSDictionary *item in items) {
        [queueItems addObject: [MLPCastUtilities buildMediaQueueItem:item]];
    }
    [self.currentSession queueLoadItemsWithCommand:command queueItems:queueItems startIndex:startIndex repeatMode:repeatMode];
}

- (void)queueInsertItems:(CDVInvokedUrlCommand *)command {
    // Check if we have a valid session
    if (self.currentSession == nil || self.currentSession.remoteMediaClient == nil) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                             messageAsString:@"No active session or media client"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    // Validate input arguments
    if (command.arguments.count == 0 || ![command.arguments[0] isKindOfClass:[NSDictionary class]]) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                             messageAsString:@"Invalid arguments - expected object with items and insertBeforeItemId"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    // Extract data from arguments
    NSDictionary *request = command.arguments[0];

    // Validate required properties
    if (![request objectForKey:@"items"] || ![request[@"items"] isKindOfClass:[NSArray class]]) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                             messageAsString:@"Missing required property: items"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    if (![request objectForKey:@"insertBeforeItemId"]) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                             messageAsString:@"Missing required property: insertBeforeItemId"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    NSArray *items = request[@"items"];
    NSInteger insertBeforeItemId = [request[@"insertBeforeItemId"] integerValue];

    // Additional validation
    if (items.count == 0) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                             messageAsString:@"Empty items array"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    // Log for debugging
    NSLog(@"queueInsertItems: Received %lu items to insert before itemId %ld",
           (unsigned long)items.count, (long)insertBeforeItemId);

    // Create queue items array from JSON data
    NSMutableArray *queueItems = [[NSMutableArray alloc] init];
    for (NSDictionary *item in items) {
        GCKMediaQueueItem *queueItem = [MLPCastUtilities buildMediaQueueItem:item];
        if (queueItem != nil) {
            [queueItems addObject:queueItem];
            NSLog(@"Created queue item with contentID: %@", queueItem.mediaInformation.contentID);
        } else {
            NSLog(@"Failed to create queue item from: %@", item);
        }
    }

    // Final validation before calling the session method
    if (queueItems.count == 0) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                             messageAsString:@"Failed to create any valid queue items"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    // Call the session method to insert the items
    [self.currentSession queueInsertItemsWithCommand:command queueItems:queueItems insertBeforeItemId:insertBeforeItemId];
}

- (void)queueJumpToItem:(CDVInvokedUrlCommand *)command {
    NSUInteger itemId = [command.arguments[0] unsignedIntegerValue];
    [self.currentSession queueJumpToItemWithCommand:command itemId:itemId];
}

- (void)setMediaVolume:(CDVInvokedUrlCommand*) command {
    [self.currentSession setMediaMutedAndVolumeWithCommand:command];
}

- (void)setReceiverVolumeLevel:(CDVInvokedUrlCommand*) command {
    double newLevel = 1.0;
    if (command.arguments[0]) {
        newLevel = [command.arguments[0] doubleValue];
    } else {
        newLevel = 1.0;
    }
    [self.currentSession setReceiverVolumeLevelWithCommand:command newLevel:newLevel];
}

- (void)setReceiverMuted:(CDVInvokedUrlCommand*) command {
    BOOL muted = NO;
    if (command.arguments[0]) {
        muted = [command.arguments[0] boolValue];
    }
    [self.currentSession setReceiverMutedWithCommand:command muted:muted];
}

- (void)sessionStop:(CDVInvokedUrlCommand*)command {
    [self.currentSession endSession:command killSession:YES];
}

- (void)sessionLeave:(CDVInvokedUrlCommand*) command {
    [self.currentSession endSession:command killSession:NO];
}

- (void)loadMedia:(CDVInvokedUrlCommand*) command {
    NSString* contentId = command.arguments[0];
    NSObject* customData = command.arguments[1];
    NSString* contentType = command.arguments[2];
    double duration = [command.arguments[3] doubleValue];
    NSString* streamType = command.arguments[4];
    BOOL autoplay = [command.arguments[5] boolValue];
    double currentTime = [command.arguments[6] doubleValue];
    NSDictionary* metadata = command.arguments[7];
    NSDictionary* textTrackStyle = command.arguments[8];
    GCKMediaInformation* mediaInfo = [MLPCastUtilities buildMediaInformation:contentId customData:customData contentType:contentType duration:duration streamType:streamType startTime:currentTime metaData:metadata textTrackStyle:textTrackStyle];

    [self.currentSession loadMediaWithCommand:command mediaInfo:mediaInfo autoPlay:autoplay currentTime:currentTime];
}

- (void)addMessageListener:(CDVInvokedUrlCommand*)command {
    NSString* namespace = command.arguments[0];
    [self.currentSession createMessageChannelWithCommand:command namespace:namespace];
}

- (void)sendMessage:(CDVInvokedUrlCommand*) command {
    NSString* namespace = command.arguments[0];
    NSString* message = command.arguments[1];

    [self.currentSession sendMessageWithCommand:command namespace:namespace message:message];
}

- (void)mediaPlay:(CDVInvokedUrlCommand*)command {
    [self.currentSession mediaPlayWithCommand:command];
}

- (void)mediaPause:(CDVInvokedUrlCommand*)command {
    [self.currentSession mediaPauseWithCommand:command];
}

- (void)mediaSeek:(CDVInvokedUrlCommand*)command {
    int currentTime = [command.arguments[0] doubleValue];
    NSString* resumeState = command.arguments[1];
    GCKMediaResumeState resumeStateObj = [MLPCastUtilities parseResumeState:resumeState];
    [self.currentSession mediaSeekWithCommand:command position:currentTime resumeState:resumeStateObj];
}

- (void)mediaStop:(CDVInvokedUrlCommand*)command {
    [self.currentSession mediaStopWithCommand:command];
}

- (void)mediaEditTracksInfo:(CDVInvokedUrlCommand*)command {
    NSArray<NSNumber*>* activeTrackIds = command.arguments[0];
    NSData* textTrackStyle = command.arguments[1];

    GCKMediaTextTrackStyle* textTrackStyleObject = [MLPCastUtilities buildTextTrackStyle:textTrackStyle];
    [self.currentSession setActiveTracksWithCommand:command activeTrackIds:activeTrackIds textTrackStyle:textTrackStyleObject];
}

- (void)selectRoute:(CDVInvokedUrlCommand*)command {
    GCKCastSession* currentSession = [GCKCastContext sharedInstance].sessionManager.currentCastSession;
    if (currentSession != nil &&
        (currentSession.connectionState == GCKConnectionStateConnected || currentSession.connectionState == GCKConnectionStateConnecting)) {
        [self sendError:@"session_error" message:@"Leave or stop current session before attempting to join new session." command:command];
        return;
    }

    NSString* routeID = command.arguments[0];
    // Ensure the scan is running
    [self startRouteScan];

    [MLPCastUtilities retry:^BOOL{
        GCKDevice* device = [[GCKCastContext sharedInstance].discoveryManager deviceWithUniqueID:routeID];
        if (device != nil) {
            [self.currentSession joinDevice:device cdvCommand:command];
            return YES;
        }
        return NO;
    } forTries:5 callback:^(BOOL passed) {
        if (!passed) {
            [self sendError:@"timeout" message:[NSString stringWithFormat:@"Failed to join route (%@) after 15s and %d tries.", routeID, 15] command:command];
        }
        [self stopRouteScan];
    }];
}

#pragma GCKLoggerDelegate
- (void)logMessage:(NSString *)message atLevel:(GCKLoggerLevel)level fromFunction:(NSString *)function location:(NSString *)location {
    NSLog(@"%@", [NSString stringWithFormat:@"GCKLogger = %@, %ld, %@, %@", message,(long)level,function,location]);
}

#pragma GCKDiscoveryManagerListener

- (void) didUpdateDeviceList {
    BOOL receiverAvailable = [GCKCastContext.sharedInstance.discoveryManager deviceCount] > 0 ? YES : NO;
    [self sendReceiverAvailable:receiverAvailable];
    [self sendScanUpdate];
}

#pragma GCKSessionManagerListener

- (void)sessionManager:(GCKSessionManager *)sessionManager didStartSession:(GCKSession *)session {
    // Only save the app Id after a session for that appId has been successfully created/joined
    [NSUserDefaults.standardUserDefaults setObject:appId forKey:@"appId"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma CastSessionListener

- (void)onMediaLoaded:(NSDictionary *)media {
    [self sendEvent:@"MEDIA_LOAD" args:@[media]];
}

- (void)onMediaUpdated:(NSDictionary *)media {
    [self sendEvent:@"MEDIA_UPDATE" args:@[media]];
}

- (void)onSessionRejoin:(NSDictionary*)session {
    [self sendEvent:@"SESSION_LISTENER" args:@[session]];
}

- (void)onSessionUpdated:(NSDictionary *)session {
    [self sendEvent:@"SESSION_UPDATE" args:@[session]];
}

- (void)onMessageReceived:(NSDictionary *)session namespace:(NSString *)namespace message:(NSString *)message {
    [self sendEvent:@"RECEIVER_MESSAGE" args:@[namespace,message]];
}

- (void)onSessionEnd:(NSDictionary *)session {
    [self sendEvent:@"SESSION_UPDATE" args:@[session]];
}

- (void)onCastStateChanged:(NSNotification*)notification {
    GCKCastState castState = [notification.userInfo[kGCKNotificationKeyCastState] intValue];
    [self sendReceiverAvailable:(castState == GCKCastStateNoDevicesAvailable)];
}

- (void)sendReceiverAvailable:(BOOL)available {
    [self sendEvent:@"RECEIVER_LISTENER" args:@[@(available)]];
}

- (void)sendEvent:(NSString *)eventName args:(NSArray *)args{
    if (self.eventCommand == nil) {
        return;
    }
    NSMutableArray* argArray = [[NSMutableArray alloc] initWithArray:@[eventName]];
    [argArray addObject:args];
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:argArray];
    [pluginResult setKeepCallback:@(true)];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:self.eventCommand.callbackId];
}

- (void)sendError:(NSString *)code message:(NSString *)message command:(CDVInvokedUrlCommand*)command{

    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[MLPCastUtilities createError:code message:message]];

    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

@end
