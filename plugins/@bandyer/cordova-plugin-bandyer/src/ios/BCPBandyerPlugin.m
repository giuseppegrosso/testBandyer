// Copyright © 2019 Bandyer S.r.l. All Rights Reserved.
// See LICENSE for licensing information

#import "BCPBandyerPlugin.h"
#import "BCPUsersDetailsCache.h"
#import "BCPUsersDetailsCommandsHandler.h"
#import "BCPUserInterfaceCoordinator.h"
#import "BCPConstants.h"
#import "BCPEventEmitter.h"
#import "BCPCallClientEventsReporter.h"
#import "BCPContactHandleProvider.h"
#import "BCPPushTokenEventsReporter.h"
#import "BCPChatClientEventsReporter.h"
#import "BCPUsersDetailsProvider.h"
#import "CDVPluginResult+BCPFactoryMethods.h"
#import "NSString+BandyerPlugin.h"

#import <Bandyer/Bandyer.h>

@interface BCPBandyerPlugin () <BCXCallClientObserver>

@property (nonatomic, strong, readwrite, nullable) BCPUsersDetailsCache *usersCache;
@property (nonatomic, strong, readwrite, nullable) BCPUserInterfaceCoordinator *coordinator;
@property (nonatomic, strong, nullable) BCPEventEmitter *eventEmitter;
@property (nonatomic, strong, nullable) BCPCallClientEventsReporter *callClientEventsReporter;
@property (nonatomic, strong, nullable) BCPChatClientEventsReporter *chatClientEventsReporter;
@property (nonatomic, strong, readwrite) BandyerSDK *sdk;

@end

@implementation BCPBandyerPlugin

- (instancetype)init
{
    self = [self initWithBandyerSDK:BandyerSDK.instance];
    return self;
}

- (instancetype)initWithBandyerSDK:(BandyerSDK *)sdk
{
    NSParameterAssert(sdk);

    self = [super init];
    if (self)
    {
        _sdk = sdk;
    }
    return self;
}

- (void)pluginInitialize
{
    [super pluginInitialize];

    [self setupSDKIfNeeded];
    self.usersCache = [BCPUsersDetailsCache new];
    self.coordinator = [self makeUserInterfaceCoordinator];
}

- (BCPUserInterfaceCoordinator *)makeUserInterfaceCoordinator
{
    return [[BCPUserInterfaceCoordinator alloc] initWithRootViewController:self.viewController];
}

- (void)setupSDKIfNeeded
{
    if (_sdk == nil)
        _sdk = BandyerSDK.instance;
}

- (void)initializeBandyer:(CDVInvokedUrlCommand *)command 
{
    self.eventEmitter = [[BCPEventEmitter alloc] initWithCallbackId:command.callbackId commandDelegate:self.commandDelegate];

    NSDictionary *args = command.arguments.firstObject;
    BDKConfig *config = [BDKConfig new];
    BDKEnvironment *environment = [args[kBCPEnvironmentKey] toBDKEnvironment];

    if (environment == nil)
    {
        [self reportCommandFailed:command];
        return;
    }

    config.environment = environment;
    if (@available(iOS 10.0, *))
    {
        NSNumber * callkitEnabled = args[kBCPCallKitConfigKey][kBCPCallKitConfigEnabledKey];
        config.callKitEnabled = [callkitEnabled boolValue];

        if (config.isCallKitEnabled)
        {
            config.handleProvider = [[BCPContactHandleProvider alloc] initWithCache:self.usersCache];
            config.nativeUIRingToneSound = args[kBCPCallKitConfigKey][kBCPCallKitConfigRingtoneKey];
            NSString *appIconResourceName = args[kBCPCallKitConfigKey][kBCPCallKitConfigIconKey];

            if (appIconResourceName)
            {
                NSString *path = [[NSBundle mainBundle] pathForResource:appIconResourceName ofType:@"png"];
                if (path)
                {
                    UIImage *appIcon = [UIImage imageWithContentsOfFile:path];
                    if (appIcon)
                    {
                        config.nativeUITemplateIconImageData = UIImagePNGRepresentation(appIcon);
                    }
                }
            }

            config.pushRegistryDelegate = [[BCPPushTokenEventsReporter alloc] initWithEventEmitter:self.eventEmitter];
            config.notificationPayloadKeyPath = args[kBCPVoipPushPayloadKey];
        }
    }

    self.coordinator.fakeCapturerFilename = args[kBCPFakeCapturerFilenameKey];

    NSString *appID = args[kBCPApplicationIDKey];

    if (appID.length == 0)
    {
        [self reportCommandFailed:command];
        return;
    }

    if ([args[kBCPLogEnabledKey] boolValue] == YES)
    {
        BandyerSDK.logLevel = BDFLogLevelAll;
    }

    [self.sdk initializeWithApplicationId:appID config:config];
    self.sdk.userInfoFetcher = [[BCPUsersDetailsProvider alloc] initWithCache:self.usersCache];
    self.coordinator.sdk = self.sdk;
    self.callClientEventsReporter = [[BCPCallClientEventsReporter alloc] initWithCallClient:self.sdk.callClient eventEmitter:self.eventEmitter];
    [self.callClientEventsReporter start];
    self.chatClientEventsReporter = [[BCPChatClientEventsReporter alloc] initWithChatClient:self.sdk.chatClient eventEmitter:self.eventEmitter];
    [self.chatClientEventsReporter start];
    [self reportCommandSucceeded:command];
}

- (void)start:(CDVInvokedUrlCommand *)command 
{
    NSDictionary *args = command.arguments.firstObject;
    NSString *user = args[kBCPUserAliasKey];

    if (user.length == 0)
    {
        [self reportCommandFailed:command];
        return;
    }

    [self.sdk.callClient addObserver:self queue:dispatch_get_main_queue()];
    [self.sdk.callClient start:user];
    [self.sdk.chatClient start:user];

    [self reportCommandSucceeded:command];
}

- (void)stop:(CDVInvokedUrlCommand *)command 
{
    [self.sdk.callClient removeObserver:self];
    [self.sdk.callClient stop];
    [self.sdk.chatClient stop];

    [self reportCommandSucceeded:command];
}

- (void)pause:(CDVInvokedUrlCommand *)command 
{
    [self.sdk.callClient pause];
    [self.sdk.chatClient pause];

    [self reportCommandSucceeded:command];
}

- (void)resume:(CDVInvokedUrlCommand *)command 
{
    [self.sdk.callClient resume];
    [self.sdk.chatClient resume];

    [self reportCommandSucceeded:command];
}

- (void)state:(CDVInvokedUrlCommand *)command 
{
    BCXCallClientState state = [self.sdk.callClient state];
    NSString *stateAsString = [NSStringFromBCXCallClientState(state) lowercaseString];

    [self reportCommandSucceeded:command withMessageAsString:stateAsString];
}

- (void)handlePushNotificationPayload:(CDVInvokedUrlCommand *)command 
{
    [self reportCommandFailed:command];
}

- (void)startCall:(CDVInvokedUrlCommand *)command
{
    NSDictionary *args = command.arguments.firstObject;
    NSArray *callee = args[kBCPCalleeKey];
    NSString *joinUrl = args[kBCPJoinUrlKey];
    BDKCallType typeCall = [args[kBCPCallTypeKey] toBDKCallType];
    BOOL recording = [args[kBCPRecordingKey] boolValue];

    if (callee.count == 0 && joinUrl.length == 0)
    {
        [self reportCommandFailed:command];
        return;
    }

    id <BDKIntent> intent;

    if (joinUrl.length > 0)
    {
        intent = [BDKJoinURLIntent intentWithURL:[NSURL URLWithString:joinUrl]];
    } else
    {
        intent = [BDKMakeCallIntent intentWithCallee:callee type:typeCall record:recording maximumDuration:0];
    }

    [self.coordinator handleIntent:intent];

    [self reportCommandSucceeded:command];
}

- (void)startChat:(CDVInvokedUrlCommand *)command
{
    NSDictionary *args = command.arguments.firstObject;
    NSString *user = args[kBCPUserAliasKey];
    NSNumber *audioOnly = args[kBCPAudioOnlyTypeKey];
    NSNumber *audioUpgradable = args[kBCPAudioUpgradableTypeKey];
    NSNumber *audioVideo = args[kBCPAudioVideoTypeKey];

    if (user.length == 0)
    {
        [self reportCommandFailed:command];
        return;
    }

    //TODO: HANDLE CALL OPTIONS
    BCHOpenChatIntent *intent = [BCHOpenChatIntent openChatWith:user];
    [self.coordinator handleIntent:intent];

    [self reportCommandSucceeded:command];
}

- (void)addUsersDetails:(CDVInvokedUrlCommand *)command 
{
    BCPUsersDetailsCommandsHandler *handler = [[BCPUsersDetailsCommandsHandler alloc] initWithCommandDelegate:self.commandDelegate cache:self.usersCache];
    [handler addUsersDetails:command];
}

- (void)removeUsersDetails:(CDVInvokedUrlCommand *)command 
{
    BCPUsersDetailsCommandsHandler *handler = [[BCPUsersDetailsCommandsHandler alloc] initWithCommandDelegate:self.commandDelegate cache:self.usersCache];
    [handler purge:command];
}

- (void)setUserDetailsFormat:(CDVInvokedUrlCommand *)command
{
    NSDictionary *args = command.arguments.firstObject;

    NSString *format = args[@"default"];
    if (format != nil && [format isKindOfClass:NSString.class])
    {
        self.coordinator.userDetailsFormat = format;
        [self.commandDelegate sendPluginResult:[CDVPluginResult bcp_success] callbackId:command.callbackId];
    } else
    {
        [self.commandDelegate sendPluginResult:[CDVPluginResult bcp_error] callbackId:command.callbackId];
    }
}

// MARK: Command result reporting

- (void)reportCommandSucceeded:(CDVInvokedUrlCommand *)command
{
    [self.commandDelegate sendPluginResult:[CDVPluginResult bcp_success] callbackId:command.callbackId];
}

- (void)reportCommandSucceeded:(CDVInvokedUrlCommand *)command withMessageAsString:(NSString *)message
{
    [self.commandDelegate sendPluginResult:[CDVPluginResult bcp_successWithMessageAsString:message] callbackId:command.callbackId];
}

- (void)reportCommandFailed:(CDVInvokedUrlCommand *)command
{
    [self.commandDelegate sendPluginResult:[CDVPluginResult bcp_error] callbackId:command.callbackId];
}

// MARK: BCXCallClientObserver

- (void)callClient:(id <BCXCallClient>)client didReceiveIncomingCall:(id <BCXCall>)call
{
    [self.coordinator handleIntent:[BDKIncomingCallHandlingIntent new]];
}

@end
