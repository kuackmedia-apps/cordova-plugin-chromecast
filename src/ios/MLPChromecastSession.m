//
//  MLPChromecastSession.m
//  ChromeCast

#import "MLPChromecastSession.h"
#import "MLPCastUtilities.h"

@implementation MLPChromecastSession
GCKCastSession* currentSession;
CDVInvokedUrlCommand* joinSessionCommand;
NSDictionary* lastMedia = nil;
void (^loadMediaCallback)(NSString*) = nil;
BOOL isResumingSession = NO;
BOOL isQueueJumping = NO;
BOOL isDisconnecting = NO;
NSMutableArray<void (^)(void)>* endSessionCallbacks;
NSMutableArray<MLPCastRequestDelegate*>* requestDelegates;

- (instancetype)initWithListener:(id<CastSessionListener>)listener cordovaDelegate:(id<CDVCommandDelegate>)cordovaDelegate
{
    self = [super init];
    requestDelegates = [NSMutableArray new];
    endSessionCallbacks = [NSMutableArray new];
    self.sessionListener = listener;
    self.commandDelegate = cordovaDelegate;
    self.castContext = [GCKCastContext sharedInstance];
    self.sessionManager = self.castContext.sessionManager;
    
    // Ensure we are only listening once after init
    [self.sessionManager removeListener:self];
    [self.sessionManager addListener:self];
    
    return self;
}

- (void)setSession:(GCKCastSession*)session {
    currentSession = session;
}

- (void)tryRejoin {
    if (currentSession == nil) {
        // if the currentSession is null we should handle any potential resuming in didResumeCastSession
        return;
    }
    
    // Make sure we are looking at the actual current session, sometimes it doesn't get removed
    [self setSession:self.sessionManager.currentCastSession];
    
    // Reset resumingSession flag if it's been stuck for more than 30 seconds
    static NSDate *resumingStartTime = nil;
    if (isResumingSession) {
        if (resumingStartTime == nil) {
            resumingStartTime = [NSDate date];
        } else if ([[NSDate date] timeIntervalSinceDate:resumingStartTime] > 30) {
            NSLog(@"Resetting stuck isResumingSession flag after 30 seconds timeout");
            isResumingSession = NO;
            resumingStartTime = nil;
        }
    } else {
        resumingStartTime = nil;
    }
    
    // Enhanced connection verification:
    // 1. Check if session exists
    // 2. Verify connection state is actually connected
    // 3. Check we're not already in the resuming process
    // 4. Verify that device is still available in discovery manager
    if (currentSession != nil && 
        currentSession.connectionState == GCKConnectionStateConnected && 
        isResumingSession == NO) {
        
        // Additional verification that the device is still available
        BOOL deviceAvailable = NO;
        GCKDiscoveryManager* discoveryManager = GCKCastContext.sharedInstance.discoveryManager;
        NSString *deviceId = currentSession.device.deviceID;
        
        // Try to find the device in the current discovery list
        for (int i = 0; i < [discoveryManager deviceCount]; i++) {
            GCKDevice* device = [discoveryManager deviceAtIndex:i];
            if ([device.deviceID isEqualToString:deviceId]) {
                deviceAvailable = YES;
                break;
            }
        }
        
        if (deviceAvailable) {
            NSLog(@"Device still available, triggering session rejoin");
            // Trigger the SESSION_LISTENER
            [self.sessionListener onSessionRejoin:[MLPCastUtilities createSessionObject:currentSession]];
        } else {
            NSLog(@"Device no longer available despite having a connected session");
            // Force a disconnect since the device is no longer available
            [currentSession endWithAction:GCKSessionEndActionLeave];
        }
    }
}

- (void)joinDevice:(GCKDevice*)device cdvCommand:(CDVInvokedUrlCommand*)command {
    joinSessionCommand = command;
    BOOL startedSuccessfully = [self.sessionManager startSessionWithDevice:device];
    if (!startedSuccessfully) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Failed to join the selected route"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }
}

-(MLPCastRequestDelegate*)createLoadMediaRequestDelegate:(CDVInvokedUrlCommand*)command {
    loadMediaCallback = ^(NSString* error) {
        if (error) {
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        } else {
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:[MLPCastUtilities createMediaObject:currentSession]];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        }
    };
    return [self createRequestDelegate:command success:^{
    } failure:^(GCKError * error) {
        loadMediaCallback(error.description);
        loadMediaCallback = nil;
    } abortion:^(GCKRequestAbortReason abortReason) {
        if (abortReason == GCKRequestAbortReasonReplaced) {
            loadMediaCallback(@"aborted loadMedia/queueLoad request reason: GCKRequestAbortReasonReplaced");
        } else if (abortReason == GCKRequestAbortReasonCancelled) {
            loadMediaCallback(@"aborted loadMedia/queueLoad request reason: GCKRequestAbortReasonCancelled");
        }
        loadMediaCallback = nil;
    }];
}

-(MLPCastRequestDelegate*)createSessionUpdateRequestDelegate:(CDVInvokedUrlCommand*)command {
    return [self createRequestDelegate:command success:^{
        [self.sessionListener onSessionUpdated:[MLPCastUtilities createSessionObject:currentSession]];
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    } failure:nil abortion:nil];
}

-(MLPCastRequestDelegate*)createMediaUpdateRequestDelegate:(CDVInvokedUrlCommand*)command {
    return [self createRequestDelegate:command success:^{
        [self.sessionListener onMediaUpdated:[MLPCastUtilities createMediaObject:currentSession]];
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    } failure:nil abortion:nil];
}

-(MLPCastRequestDelegate*)createRequestDelegate:(CDVInvokedUrlCommand*)command success:(void(^)(void))success failure:(void(^)(GCKError*))failure abortion:(void(^)(GCKRequestAbortReason))abortion {
    // set up any required defaults
    if (success == nil) {
        success = ^{
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        };
    }
    if (failure == nil) {
        failure = ^(GCKError * error) {
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.description];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        };
    }
    if (abortion == nil) {
        abortion = ^(GCKRequestAbortReason abortReason) {
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsNSInteger:abortReason];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        };
    }
    MLPCastRequestDelegate* delegate = [[MLPCastRequestDelegate alloc] initWithSuccess:^{
        [self checkFinishDelegates];
        success();
    } failure:^(GCKError * error) {
        [self checkFinishDelegates];
        failure(error);
    } abortion:^(GCKRequestAbortReason abortReason) {
        [self checkFinishDelegates];
        abortion(abortReason);
    }];
    
    [requestDelegates addObject:delegate];
    return delegate;
}

- (void)endSession:(CDVInvokedUrlCommand*)command killSession:(BOOL)killSession {
    [self endSessionWithCallback:^{
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    } killSession:killSession];
}

- (void)endSessionWithCallback:(void(^)(void))callback killSession:(BOOL)killSession {
    [endSessionCallbacks addObject:callback];
    if (killSession) {
        [currentSession endWithAction:GCKSessionEndActionStopCasting];
    } else {
        isDisconnecting = YES;
        [currentSession endWithAction:GCKSessionEndActionLeave];
    }
}

- (void)setMediaMutedAndVolumeWithCommand:(CDVInvokedUrlCommand*)command {
    GCKMediaStatus* mediaStatus = currentSession.remoteMediaClient.mediaStatus;
    // set muted to the current state
    BOOL muted = mediaStatus.isMuted;
    // If we have the muted argument
    if (command.arguments[1] != [NSNull null]) {
        // Update muted
        muted = [command.arguments[1] boolValue];
    }
    
    __weak MLPChromecastSession* weakSelf = self;
    
    void (^setMuted)(void) = ^{
        // Now set the volume
        GCKRequest* request = [weakSelf.remoteMediaClient setStreamMuted:muted customData:nil];
        request.delegate = [weakSelf createMediaUpdateRequestDelegate:command];
    };
    
    // Set an invalid newLevel for default
    double newLevel = -1;
    // Get the newLevel argument if possible
    if (command.arguments[0] != [NSNull null]) {
        newLevel = [command.arguments[0] doubleValue];
    }
    
    if (newLevel == -1) {
        // We have no newLevel, so only set muted state
        setMuted();
    } else {
        // We have both muted and newLevel, so set volume, then muted
        GCKRequest* request = [self.remoteMediaClient setStreamVolume:newLevel customData:nil];
        request.delegate = [self createRequestDelegate:command success:setMuted failure:nil abortion:nil];
    }
}

- (void)setReceiverVolumeLevelWithCommand:(CDVInvokedUrlCommand*)command newLevel:(float)newLevel {
    GCKRequest* request = [currentSession setDeviceVolume:newLevel];
    request.delegate = [self createSessionUpdateRequestDelegate:command];
}

- (void)setReceiverMutedWithCommand:(CDVInvokedUrlCommand*)command muted:(BOOL)muted {
    GCKRequest* request = [currentSession setDeviceMuted:muted];
    request.delegate = [self createSessionUpdateRequestDelegate:command];
}

- (void)loadMediaWithCommand:(CDVInvokedUrlCommand*)command mediaInfo:(GCKMediaInformation*)mediaInfo autoPlay:(BOOL)autoPlay currentTime : (double)currentTime {
    GCKMediaLoadOptions* options = [[GCKMediaLoadOptions alloc] init];
    options.autoplay = autoPlay;
    options.playPosition = currentTime;
    GCKRequest* request = [self.remoteMediaClient loadMedia:mediaInfo withOptions:options];
    request.delegate = [self createLoadMediaRequestDelegate:command];
}

- (void)createMessageChannelWithCommand:(CDVInvokedUrlCommand*)command namespace:(NSString*)namespace{
    GCKGenericChannel* newChannel = [[GCKGenericChannel alloc] initWithNamespace:namespace];
    newChannel.delegate = self;
    self.genericChannels[namespace] = newChannel;
    [currentSession addChannel:newChannel];
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendMessageWithCommand:(CDVInvokedUrlCommand*)command namespace:(NSString*)namespace message:(NSString*)message{
    // Verificar si el canal ya existe antes de crear uno nuevo
    GCKGenericChannel* channel = self.genericChannels[namespace];
    
    // Si el canal no existe, crearlo
    if (channel == nil) {
        NSLog(@"Channel for namespace %@ not found, creating new channel", namespace);
        channel = [[GCKGenericChannel alloc] initWithNamespace:namespace];
        channel.delegate = self;
        self.genericChannels[namespace] = channel;
        
        // Verificar si la sesión existe
        if (currentSession == nil) {
            NSLog(@"Cannot send message: No active Cast session");
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR 
                                             messageAsString:@"No active Cast session"];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            return;
        }
        
        // Añadir el canal a la sesión
        [currentSession addChannel:channel];
        NSLog(@"Added channel for namespace: %@", namespace);
    }
    
    // Ahora enviar el mensaje usando el canal
    NSLog(@"Sending message to namespace %@: %@", namespace, message);
    GCKError* error = nil;
    [channel sendTextMessage:message error:&error];
    
    // Enviar resultado al callback
    CDVPluginResult* pluginResult;
    if (error != nil) {
        NSLog(@"Error sending message: %@", error.description);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR 
                                       messageAsString:error.description];
    } else {
        NSLog(@"Message sent successfully to namespace: %@", namespace);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    }
    
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)mediaSeekWithCommand:(CDVInvokedUrlCommand*)command position:(NSTimeInterval)position resumeState:(GCKMediaResumeState)resumeState {
    GCKMediaSeekOptions* options = [[GCKMediaSeekOptions alloc] init];
    options.interval = position;
    options.resumeState = resumeState;
    GCKRequest* request = [self.remoteMediaClient seekWithOptions:options];
    request.delegate = [self createMediaUpdateRequestDelegate:command];
}

- (void)queueJumpToItemWithCommand:(CDVInvokedUrlCommand *)command itemId:(NSUInteger)itemId {
    isQueueJumping = YES;
    GCKRequest* request = [self.remoteMediaClient queueJumpToItemWithID:itemId];
    request.delegate = [self createRequestDelegate:command success:nil failure:^(GCKError * error) {
        isQueueJumping = NO;
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.description];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    } abortion:^(GCKRequestAbortReason abortReason) {
        isQueueJumping = NO;
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsNSInteger:abortReason];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];
}

- (void)mediaPlayWithCommand:(CDVInvokedUrlCommand*)command {
    GCKRequest* request = [self.remoteMediaClient play];
    request.delegate = [self createMediaUpdateRequestDelegate:command];
}

- (void)mediaPauseWithCommand:(CDVInvokedUrlCommand*)command {
    GCKRequest* request = [self.remoteMediaClient pause];
    request.delegate = [self createMediaUpdateRequestDelegate:command];
}

- (void)mediaStopWithCommand:(CDVInvokedUrlCommand*)command {
    GCKRequest* request = [self.remoteMediaClient stop];
    request.delegate = [self createMediaUpdateRequestDelegate:command];
}

- (void)setActiveTracksWithCommand:(CDVInvokedUrlCommand*)command activeTrackIds:(NSArray<NSNumber*>*)activeTrackIds textTrackStyle:(GCKMediaTextTrackStyle*)textTrackStyle {
    GCKRequest* request = [self.remoteMediaClient setActiveTrackIDs:activeTrackIds];
    request.delegate = [self createMediaUpdateRequestDelegate:command];
    request = [self.remoteMediaClient setTextTrackStyle:textTrackStyle];
}

- (void)queueLoadItemsWithCommand:(CDVInvokedUrlCommand *)command queueItems:(NSArray *)queueItems startIndex:(NSInteger)startIndex repeatMode:(GCKMediaRepeatMode)repeatMode {
    GCKMediaQueueItem *item = queueItems[startIndex];
    GCKMediaQueueLoadOptions *options = [[GCKMediaQueueLoadOptions alloc] init];
    options.repeatMode = repeatMode;
    options.startIndex = startIndex;
    options.playPosition = item.startTime;
    GCKRequest* request = [self.remoteMediaClient queueLoadItems:queueItems withOptions:options];
    request.delegate = [self createLoadMediaRequestDelegate:command];
}

- (void)queueInsertItemsWithCommand:(CDVInvokedUrlCommand *)command queueItems:(NSArray *)queueItems insertBeforeItemId:(NSInteger)insertBeforeItemId {
    // Check if remoteMediaClient is available
    if (self.remoteMediaClient == nil) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"No active media session"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }
    
    // Check if we have queue items
    if (queueItems == nil || queueItems.count == 0) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"No queue items to insert"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }
    
    // Check if there's a current queue
    if (self.remoteMediaClient.mediaStatus == nil) {
        NSLog(@"Warning: No media status available, queue may not exist yet");
    } else {
        NSLog(@"Current media status: playerState=%d, queueItemCount=%lu", 
              (int)self.remoteMediaClient.mediaStatus.playerState,
              (unsigned long)self.remoteMediaClient.mediaStatus.queueItemCount);
    }
    
    // Log for debugging
    NSLog(@"Attempting to insert %lu queue items before item ID: %ld", (unsigned long)queueItems.count, (long)insertBeforeItemId);
    
    // Create a custom data dictionary
    NSMutableDictionary *customData = [NSMutableDictionary dictionary];
    customData[@"insertItemsCommand"] = @YES;
    
    // Define success and failure blocks to be used with the delegate
    void(^successBlock)(void) = ^{
        NSLog(@"Queue insert items succeeded");
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    };
    
    void(^failureBlock)(GCKError *) = ^(GCKError *error) {
        NSLog(@"Queue insert items failed with error: %@", error.description);
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR 
                                             messageAsString:[NSString stringWithFormat:@"queueInsertItems error: %@", error.description]];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    };
    
    void(^abortionBlock)(GCKRequestAbortReason) = ^(GCKRequestAbortReason abortReason) {
        NSLog(@"Queue insert items aborted with reason: %ld", (long)abortReason);
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR 
                                             messageAsString:[NSString stringWithFormat:@"queueInsertItems aborted: %ld", (long)abortReason]];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    };
    
    // Create a delegate for the request
    MLPCastRequestDelegate *delegate = [self createRequestDelegate:command 
                                                          success:successBlock
                                                          failure:failureBlock
                                                         abortion:abortionBlock];
    
    // Try using a different method if provided, otherwise use the standard one
    GCKRequest *request = nil;
    
    // Try different API methods depending on the version
    @try {
        // First try with custom data, which is available in newer API versions
        request = [self.remoteMediaClient queueInsertItems:queueItems beforeItemWithID:insertBeforeItemId customData:customData];
        
        if (request == nil) {
            // Fallback to method without custom data
            NSLog(@"Falling back to method without customData");
            request = [self.remoteMediaClient queueInsertItems:queueItems beforeItemWithID:insertBeforeItemId];
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception trying to call queueInsertItems: %@", exception);
        // Try alternative method if the previous one failed due to API changes
        @try {
            NSLog(@"Trying alternative method for queue insert");
            // Alternative for item ID 0 (beginning of queue)
            if (insertBeforeItemId == 0 || insertBeforeItemId == kGCKMediaQueueInvalidItemID) {
                request = [self.remoteMediaClient queueInsertAndPlayItem:queueItems[0] beforeItemWithID:kGCKMediaQueueInvalidItemID playPosition:0 customData:nil];
            } else {
                // For other positions, try one item at a time
                for (GCKMediaQueueItem *item in queueItems) {
                    GCKRequest *itemRequest = [self.remoteMediaClient queueInsertAndPlayItem:item 
                                                                           beforeItemWithID:insertBeforeItemId 
                                                                               playPosition:0 
                                                                                customData:nil];
                    if (itemRequest != nil) {
                        request = itemRequest; // Keep track of the last request
                    }
                }
            }
        } @catch (NSException *innerException) {
            NSLog(@"Exception trying alternative queueInsert methods: %@", innerException);
        }
    }
    
    // Check if any of the methods succeeded
    if (request == nil) {
        NSLog(@"Error: Failed to create queue insert request with any method");
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Failed to create queue insert request"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }
    
    // Assign delegate to the request
    request.delegate = delegate;
    
    // Manually keep a reference to the delegate until the request completes
    [requestDelegates addObject:delegate];
    
    NSLog(@"Queue insert request created with ID: %ld", (long)request.requestID);
}

- (void) checkFinishDelegates {
    NSMutableArray<MLPCastRequestDelegate*>* tempArray = [NSMutableArray new];
    for (MLPCastRequestDelegate* delegate in requestDelegates) {
        if (!delegate.finished ) {
            [tempArray addObject:delegate];
        }
    }
    requestDelegates = tempArray;
}

#pragma -- GCKSessionManagerListener
- (void)sessionManager:(GCKSessionManager *)sessionManager didStartCastSession:(GCKCastSession *)session {
    [self setSession:session];
    self.remoteMediaClient = session.remoteMediaClient;
    [self.remoteMediaClient addListener:self];
    if (joinSessionCommand != nil) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary: [MLPCastUtilities createSessionObject:session] ];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:joinSessionCommand.callbackId];
        joinSessionCommand = nil;
    }
}

- (void)sessionManager:(GCKSessionManager *)sessionManager didEndCastSession:(GCKCastSession *)session withError:(NSError *)error {
    // Clear the session
    currentSession = nil;
    
    // Did we fail on a join session command?
    if (error != nil && joinSessionCommand != nil) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.debugDescription];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:joinSessionCommand.callbackId];
        joinSessionCommand = nil;
        return;
    }
    
    // Call all callbacks that are waiting for session end
    for (void (^endSessionCallback)(void) in endSessionCallbacks) {
        endSessionCallback();
    }
    // And remove the callbacks
    endSessionCallbacks = [NSMutableArray new];
    
    // Are we just leaving the session? (leaving results in disconnected status)
    if (isDisconnecting) {
        // Clear isDisconnecting
        isDisconnecting = NO;
        [self.sessionListener onSessionUpdated:[MLPCastUtilities createSessionObject:session status:@"disconnected"]];
    } else {
        [self.sessionListener onSessionUpdated:[MLPCastUtilities createSessionObject:session]];
    }
}

- (void)sessionManager:(GCKSessionManager *)sessionManager didResumeCastSession:(GCKCastSession *)session {
    // Log for debugging purposes
    NSLog(@"didResumeCastSession called for session ID: %@", session.sessionID);
    
    if (currentSession && currentSession.sessionID == session.sessionID) {
        NSLog(@"Session IDs match, this appears to be an internal iOS resume event, not handling");
        // ios randomly resumes current session, don't trigger SESSION_LISTENER in this case
        return;
    }
    
    // Set resuming flag with timestamp for timeout safety
    isResumingSession = YES;
    
    // Do all the setup/configuration required when we get a session
    [self sessionManager:sessionManager didStartCastSession:session];
    
    // Start active device scan to ensure device is still available
    [[GCKCastContext sharedInstance].discoveryManager startDiscovery];
    
    // Delay returning the resumed session, so that iOS has a chance to get any media first
    // If we return immediately, the session may be sent out without media even though there should be
    // The case where a session is resumed that has no media will have to wait the full timeout before being sent
    
    // Increased number of retries and changed retry strategy
    __block int mediaStatusRetryCount = 0;
    [MLPCastUtilities retry:^BOOL{
        // Did we find any media?
        if (session.remoteMediaClient.mediaStatus != nil) {
            NSLog(@"Media status found on retry %d", mediaStatusRetryCount);
            // No need to wait any longer
            return YES;
        }
        
        // Log the retry attempt
        mediaStatusRetryCount++;
        NSLog(@"Waiting for media status, retry %d of 5", mediaStatusRetryCount);
        
        // Additional checks to validate if session is still valid
        if (session.connectionState == GCKConnectionStateDisconnected) {
            NSLog(@"Session disconnected during resumption, aborting further retries");
            return YES;  // Return yes to stop retrying, we'll handle the failure in the callback
        }
        
        return NO;
    } forTries:5 callback:^(BOOL passed){
        // Check if we have a valid media status
        BOOL hasValidMedia = (session.remoteMediaClient.mediaStatus != nil);
        
        if (passed && hasValidMedia) {
            NSLog(@"Successfully resumed session with media status");
            // trigger the SESSION_LISTENER event with complete session info
            [self.sessionListener onSessionRejoin:[MLPCastUtilities createSessionObject:session]];
        } else {
            NSLog(@"Failed to get media status after retries or session disconnected");
            // Still trigger session with whatever we have, but log the issue
            [self.sessionListener onSessionRejoin:[MLPCastUtilities createSessionObject:session]];
        }
        
        // Check for media queue items too
        if (session.remoteMediaClient.mediaStatus != nil && 
            session.remoteMediaClient.mediaStatus.queueItemCount > 0) {
            NSLog(@"Found queue with %lu items", 
                  (unsigned long)session.remoteMediaClient.mediaStatus.queueItemCount);
            // Request queue items to ensure they're loaded
            // Use queueFetchItemIDs instead of queueFetchItems which doesn't exist
            NSMutableArray<NSNumber *> *itemIds = [NSMutableArray array];
            
            // Get all item IDs from the queue
            for (NSUInteger i = 0; i < session.remoteMediaClient.mediaStatus.queueItemCount; i++) {
                GCKMediaQueueItem *item = [session.remoteMediaClient.mediaStatus queueItemAtIndex:i];
                if (item) {
                    [itemIds addObject:@(item.itemID)];
                }
            }
            
            if (itemIds.count > 0) {
                NSLog(@"Fetching %lu queue items during resume", (unsigned long)itemIds.count);
                GCKRequest* request = [session.remoteMediaClient queueFetchItemsForIDs:itemIds];
                request.delegate = [self createRequestDelegate:nil success:^{
                    NSLog(@"Queue items fetched successfully during resume");
                } failure:^(GCKError * error) {
                    NSLog(@"Failed to fetch queue items during resume: %@", error);
                } abortion:nil];
            } else {
                NSLog(@"No queue item IDs available to fetch");
            }
        }
        
        // We are done resuming, regardless of outcome
        isResumingSession = NO;
    }];
}

#pragma -- GCKRemoteMediaClientListener

- (void)remoteMediaClient:(GCKRemoteMediaClient *)client didUpdateMediaStatus:(GCKMediaStatus *)mediaStatus {
    // The following code block is dedicated to catching when the next video in a queue loads so that we can let the user know the video ended.
    
    // If lastMedia and current media are part of the same mediaSession
    // AND if the currentItemID has changed
    // AND if there is no idle reason, that means that video just moved onto to the next video naturally (eg. next video in a queue).  We have to handle this case manually. Other ways resulting in currentItemID changing are handled without additional assistance
    if (lastMedia != nil
        && mediaStatus.mediaSessionID == [lastMedia gck_integerForKey:@"mediaSessionId" withDefaultValue:0]
        && mediaStatus.currentItemID != [lastMedia gck_integerForKey:@"currentItemId" withDefaultValue:-1]
        && mediaStatus.idleReason == GCKMediaPlayerIdleReasonNone) {
        
        // send out a media update to indicate that the previous media has finished
        NSMutableDictionary* lastMediaMutable = [lastMedia mutableCopy];
        lastMediaMutable[@"playerState"] = @"IDLE";
        if (isQueueJumping) {
            lastMediaMutable[@"idleReason"] = @"INTERRUPTED";
            // reset isQueueJumping
            isQueueJumping = NO;
        } else {
            lastMediaMutable[@"idleReason"] = @"FINISHED";
        }
        [self.sessionListener onMediaUpdated:lastMediaMutable];
    }
    
    // update the last media now
    lastMedia = [MLPCastUtilities createMediaObject:currentSession];
    
    // Enhanced media state synchronization
    // Only send updates if we aren't loading media or resuming session
    if (!loadMediaCallback && !isResumingSession) {
        // Check if we have complete media information before sending update
        if (lastMedia && [lastMedia count] > 0) {
            // Log what we're sending
            NSLog(@"Sending media update with playerState: %@", lastMedia[@"playerState"]);
            [self.sessionListener onMediaUpdated:lastMedia];
        } else {
            NSLog(@"Media information is incomplete, not sending media update");
        }
    }
}

- (void)remoteMediaClient:(GCKRemoteMediaClient *)client didReceiveQueueItemIDs:(NSArray<NSNumber *> *)queueItemIDs {
    // New media has been loaded, wipe any lastMedia reference
    lastMedia = nil;
    // Save the queueItemIDs in cast utilities so it can be used when building queue items
    [MLPCastUtilities setQueueItemIDs:queueItemIDs];
    
    // If we do not have a loadMediaCallback that means this was an external media load
    if (!loadMediaCallback) {
        // So set the callback to trigger the MEDIA_LOAD event
        loadMediaCallback = ^(NSString* error) {
            if (error) {
                NSLog(@"%@%@", @"Chromecast Error: ", error);
            } else {
                [self.sessionListener onMediaLoaded:[MLPCastUtilities createMediaObject:currentSession]];
            }
        };
    }
    
    // When internally loading a queue the media itmes are not always available at this point, so request the items
    GCKRequest* request = [self.remoteMediaClient queueFetchItemsForIDs:queueItemIDs];
    request.delegate = [self createRequestDelegate:nil success:^{
        loadMediaCallback(nil);
        loadMediaCallback = nil;
    } failure:^(GCKError * error) {
        loadMediaCallback([GCKError enumDescriptionForCode:error.code]);
        loadMediaCallback = nil;
    } abortion:^(GCKRequestAbortReason abortReason) {
        if (abortReason == GCKRequestAbortReasonReplaced) {
            loadMediaCallback(@"aborted loadMedia/queueLoad fetch request reason: GCKRequestAbortReasonReplaced");
        } else if (abortReason == GCKRequestAbortReasonCancelled) {
            loadMediaCallback(@"aborted loadMedia/queueLoad fetch request reason: GCKRequestAbortReasonCancelled");
        }
        loadMediaCallback = nil;
    }];
}


#pragma -- GCKGenericChannelDelegate
- (void)castChannel:(GCKGenericChannel *)channel didReceiveTextMessage:(NSString *)message withNamespace:(NSString *)protocolNamespace {
    NSDictionary* session = [MLPCastUtilities createSessionObject:currentSession];
    [self.sessionListener onMessageReceived:session namespace:protocolNamespace message:message];
}
@end
