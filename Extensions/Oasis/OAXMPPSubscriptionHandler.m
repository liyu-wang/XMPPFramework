//
//  OAXMPPSubscriptionHandler.m
//  Oasis
//
//  Created by Liyu Wang on 8/04/2016.
//  Copyright © 2016 Oasis. All rights reserved.
//

#import "OAXMPPSubscriptionHandler.h"

#import "XMPP.h"
#import "XMPPRoster.h"
#import "XMPPRosterCoreDataStorage.h"
#import "XMPPLogging.h"
#import "XMPPIDTracker.h"

// Log levels: off, error, warn, info, verbose
// Log flags: trace
#ifdef DEBUG
static const int xmppLogLevel = XMPP_LOG_LEVEL_VERBOSE; // | XMPP_LOG_FLAG_TRACE;
#else
static const int xmppLogLevel = XMPP_LOG_LEVEL_WARN;
#endif

#define LOADING_COMPLETE_TIME_OUT 5.0
#define PACKET_TIMEOUT 15.0 // NSTimeInterval (double) = seconds

NSString *const XMPPSubscriptionErrorDomain = @"XMPPSubscriptionErrorDomain";

@interface OAXMPPSubscriptionHandler () {
    XMPPRosterCoreDataStorage *_rosterStorage;
}
@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - OAXMPPSubscriptionHandler Implementation
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation OAXMPPSubscriptionHandler

- (instancetype)initWithRoster:(XMPPRoster *)roster {
    if (self = [super initWithDispatchQueue:NULL]) {
        
        _isAfterLoginSubPresenceFullyLoaded = false;
        
        _receivedSubscriptionJidSet = [NSMutableSet set];
        _receivedUnsubscriptionJidSet = [NSMutableSet set];
        
        _roster = roster;
        
        _rosterStorage = (XMPPRosterCoreDataStorage *)roster.xmppRosterStorage;
        
        _xmppIDTracker = [[XMPPIDTracker alloc] init];
    }
    
    return self;
}

- (BOOL)activate:(XMPPStream *)aXmppStream {
    
    XMPPLogTrace();
    
    if ([super activate:aXmppStream]) {
        XMPPLogVerbose(@"%@: Activated", THIS_FILE);
        
        [_roster addDelegate:self delegateQueue:self.moduleQueue];
        
        _xmppIDTracker = [[XMPPIDTracker alloc] initWithStream:xmppStream dispatchQueue:moduleQueue];
        
        return YES;
    }
    
    return NO;
}

- (void)deactivate {
    
    XMPPLogTrace();
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        [_roster removeDelegate:self];
        
        [_xmppIDTracker removeAllIDs];
        _xmppIDTracker = nil;
        
    }};
    
    if (dispatch_get_specific(moduleQueueTag))
        block();
    else
        dispatch_sync(moduleQueue, block);
    
    [super deactivate];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Properties
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)isAfterLoginSubPresenceFullyLoaded {
    if (dispatch_get_specific(moduleQueueTag)) {
        return _isAfterLoginSubPresenceFullyLoaded;
    } else {
        __block BOOL result;
        
        dispatch_sync(moduleQueue, ^{
            result = _isAfterLoginSubPresenceFullyLoaded;
        });
        
        return result;
    }
}

- (void)setIsAfterLoginSubPresenceFullyLoaded:(BOOL)isAfterLoginSubPresenceFullyLoaded {
    dispatch_block_t block = ^{
        _isAfterLoginSubPresenceFullyLoaded = isAfterLoginSubPresenceFullyLoaded;
    };
    
    if (dispatch_get_specific(moduleQueueTag)) {
        block();
    } else {
        dispatch_async(moduleQueue, block);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - XMPPStream Delegate
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)xmppStream:(XMPPStream *)sender didReceivePresence:(XMPPPresence *)presence {
    NSString *type = [presence type];
    
    if ([type isEqualToString:@"subscribe"]) {
        // see - (void)xmppRoster:(XMPPRoster *)sender didReceivePresenceSubscriptionRequest:(XMPPPresence *)presence
//        [self processPotentialReversedSubscribePresnce:presence];
    } else if ([type isEqualToString:@"subscribed"]) {
        [self processSubscribedPresence:presence];
    } else if ([type isEqualToString:@"unsubscribe"]) {
        if ([self isAfterLoginSubPresenceFullyLoaded]) {
            [self processLiveUnsubscribePresence:presence];
        } else {
            [self processAfterLoginUnsubscribePresence:presence];
        }
    } else if ([type isEqualToString:@"unsubscribed"]) {
        [self processUnsubscribedPresence:presence];
    }
}

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq {
    
    NSString *type = [iq type];
    
    if ([type isEqualToString:@"result"] || [type isEqualToString:@"error"]) {
        return [_xmppIDTracker invokeForID:[iq elementID] withObject:iq];
    } else if ([type isEqualToString:@"set"]) {
        NSXMLElement *query = [iq elementForName:@"query" xmlns:@"jabber:iq:roster"];
        
        if (query) {
            NSArray *items = [query elementsForName:@"item"];
            
            for (NSXMLElement *item in items) {@autoreleasepool {
                NSString *bareJid = [[item attributeForName:@"jid"] stringValue];
                NSString *subscriptionStr = [[item attributeForName:@"subscription"] stringValue];
                DDXMLNode *ask =[item attributeForName:@"ask"];
                NSString *askStr = (ask == nil ? @"null" : [ask stringValue]);
                
                [_xmppIDTracker invokeForID:[NSString stringWithFormat:@"%@-%@-%@", bareJid, subscriptionStr, askStr] withObject:iq];
            }}
        }
    }
    
    return NO;
}

- (void)xmppStreamDidDisconnect:(XMPPStream *)sender withError:(NSError *)error {
    [self setIsAfterLoginSubPresenceFullyLoaded: NO];
    
    [_receivedSubscriptionJidSet removeAllObjects];
    [_receivedUnsubscriptionJidSet removeAllObjects];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - XMPPRoster Delegate
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)xmppRosterDidEndPopulating:(XMPPRoster *)sender {
    
    [self rescheduleLoadingCompleteTimer];
}

/* handle the initial subscribe presence only (not the reversed subscirbe sent by the receivers) */
- (void)xmppRoster:(XMPPRoster *)sender didReceivePresenceSubscriptionRequest:(XMPPPresence *)presence {
    
    if ([self isAfterLoginSubPresenceFullyLoaded]) {
        [self processLiveSubscribePresence:presence];
    } else {
        [self processAfterLoginSubscribePresence:presence];
    }
}

- (void)xmppRoster:(XMPPRoster *)sender didReceiveReversedSubscribePresence:(XMPPPresence *)presence {
    NSXMLElement *oasisElement = [presence elementForName:@"oasis" xmlns:@"http://oasis.com/xmpp"];
    NSString *token = [[oasisElement attributeForName:@"token"] stringValue];
    
    if (!token || [token isEqualToString:@""]) {
        XMPPPresence *subscribed = [XMPPPresence presenceWithType:@"subscribed" to:presence.from];
        [self.xmppStream sendElement:subscribed];
        
        // sent like been accepted event
        [multicastDelegate xmppSubscriptionHandler:self sentSubscriptionBeenAcceptedByJid:presence.from];
    }
}

- (void)xmppRoster:(XMPPRoster *)sender didReceiveRosterPush:(XMPPIQ *)iq {
    NSXMLElement *query = [iq elementForName:@"query" xmlns:@"jabber:iq:roster"];
    
    for (NSXMLElement *item in [query elementsForName:@"item"]) {
        NSString *subscription = [[item attributeForName:@"subscription"] stringValue];
        
        if ([subscription isEqualToString:@"remove"]) {
            XMPPJID *jid = [XMPPJID jidWithString:[[item attributeForName:@"jid"] stringValue]];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                OALinkStatus linkStatus = [self linkStatusForJid:jid];
                if (linkStatus == OALinkStatusReceived) {
                    dispatch_async(moduleQueue, ^{
                        [_receivedSubscriptionJidSet removeObject:jid];
                        
                        // received like been cancelled by sender event
                        [multicastDelegate xmppSubscriptionHandler:self receivedSubscriptionBeenCancelledByJid:jid];
                    });
                }
            });
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Private API
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)processAfterLoginSubscribePresence:(XMPPPresence *)presence {
    XMPPJID *jid = [presence from];
    [_receivedSubscriptionJidSet addObject:jid];
    
    [self rescheduleLoadingCompleteTimer];
}

- (void)processAfterLoginUnsubscribePresence:(XMPPPresence *)presence {
    XMPPJID *jid = [presence from];
    [_receivedUnsubscriptionJidSet addObject:jid];
    
    [self rescheduleLoadingCompleteTimer];
}

- (void)processLiveSubscribePresence:(XMPPPresence *)presence {
    NSXMLElement *oasisElement = [presence elementForName:@"oasis" xmlns:@"http://oasis.com/xmpp"];
    NSString *token = [[oasisElement attributeForName:@"token"] stringValue];
    
    if (token && ![token isEqualToString:@""]) {
        XMPPJID *jid = [presence from];
        [_receivedSubscriptionJidSet addObject:jid];
        
        // receive like event
        [multicastDelegate xmppSubscriptionHandler:self didReceiveLiveSubscriptionFromJid:jid];
    } else {
        // this shouldn't happen
    }
}

- (void)processLiveUnsubscribePresence:(XMPPPresence *)presence {
    XMPPJID *jid = [presence from];
    [_receivedUnsubscriptionJidSet addObject:jid];
}

- (void)processSubscribedPresence:(XMPPPresence *)presence {
    
}

- (void)processUnsubscribedPresence:(XMPPPresence *)presence {
    dispatch_async(dispatch_get_main_queue(), ^{
        OALinkStatus linkStatus = [self linkStatusForJid:presence.from];
        if (linkStatus == OALinkStatusNone || OALinkStatusSent) {
            dispatch_async(moduleQueue, ^{
                // sent like been rejected event
                [multicastDelegate xmppSubscriptionHandler:self sentSubscriptionBeenRejectedByJid:presence.from];
            });
        }
    });
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Timer
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)rescheduleLoadingCompleteTimer {
    [self cancelLoadingCompleteTimer];
    
    _loadingCompleteTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, moduleQueue);
    
    OAXMPPSubscriptionHandler* __weak weakSelf = self;
    
    dispatch_source_set_event_handler(_loadingCompleteTimer, ^{ @autoreleasepool {
        OAXMPPSubscriptionHandler* strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf didFinishLoadingAfterLoginSubscriptionsAndUnsubscriptions];
        }
    }});
    
    dispatch_time_t fireTime = dispatch_time(DISPATCH_TIME_NOW, (LOADING_COMPLETE_TIME_OUT * NSEC_PER_SEC));
    dispatch_source_set_timer(_loadingCompleteTimer, fireTime, DISPATCH_TIME_FOREVER, 1.0);
    dispatch_resume(_loadingCompleteTimer);
}

- (void)cancelLoadingCompleteTimer {
    if (_loadingCompleteTimer) {
        dispatch_source_cancel(_loadingCompleteTimer);
        #if !OS_OBJECT_USE_OBJC
        dispatch_release(_loadingFinishedTimer);
        #endif
        _loadingCompleteTimer = NULL;
    }
}

- (void)didFinishLoadingAfterLoginSubscriptionsAndUnsubscriptions {
    [self setIsAfterLoginSubPresenceFullyLoaded:YES];
    [multicastDelegate xmppSubscriptionHandler:self didFinishLoadingAfterLoginSubscriptions:_receivedSubscriptionJidSet];
    [multicastDelegate xmppSubscriptionHandler:self didFinishLoadingAfterLoginUnsubscriptions:_receivedUnsubscriptionJidSet];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Methods borrow from XMPPRoster
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)sendAddUserIQ:(XMPPJID *)jid group:(NSString *)group completion:(void(^)(XMPPIQ *, id <XMPPTrackingInfo>))block {
    
    if (jid == nil) return;
    
    XMPPJID *myJID = xmppStream.myJID;
    
    if ([myJID isEqualToJID:jid options:XMPPJIDCompareBare]) {
        XMPPLogInfo(@"%@: %@ - Ignoring request to add myself to my own roster", [self class], THIS_METHOD);
        return;
    }
    
    NSXMLElement *item = [NSXMLElement elementWithName:@"item"];
    [item addAttributeWithName:@"jid" stringValue:[jid bare]];
    [item addAttributeWithName:@"name" stringValue:[jid user]];
    
    NSXMLElement *groupElement = [NSXMLElement elementWithName:@"group"];
    [groupElement setStringValue:group];
    [item addChild:groupElement];
    
    NSXMLElement *query = [NSXMLElement elementWithName:@"query" xmlns:@"jabber:iq:roster"];
    [query addChild:item];
    
    XMPPIQ *iq = [XMPPIQ iqWithType:@"set" elementID:[xmppStream generateUUID]];
    [iq addChild:query];
    
    [_xmppIDTracker addID:[iq elementID] block:block timeout:PACKET_TIMEOUT];
    
    [xmppStream sendElement:iq];
}

- (void)removeUser:(XMPPJID *)jid completion:(void(^)(XMPPIQ *, id <XMPPTrackingInfo>))block {
    
    if (jid == nil) return;
    
    XMPPJID *myJID = xmppStream.myJID;
    
    if ([myJID isEqualToJID:jid options:XMPPJIDCompareBare]) {
        XMPPLogInfo(@"%@: %@ - Ignoring request to remove myself from my own roster", [self class], THIS_METHOD);
        return;
    }
    
    NSXMLElement *item = [NSXMLElement elementWithName:@"item"];
    [item addAttributeWithName:@"jid" stringValue:[jid bare]];
    [item addAttributeWithName:@"subscription" stringValue:@"remove"];
    
    NSXMLElement *query = [NSXMLElement elementWithName:@"query" xmlns:@"jabber:iq:roster"];
    [query addChild:item];
    
    XMPPIQ *iq = [XMPPIQ iqWithType:@"set" elementID:[xmppStream generateUUID]];
    [iq addChild:query];
    
    [_xmppIDTracker addID:[iq elementID] block:block timeout:PACKET_TIMEOUT];
    
    [xmppStream sendElement:iq];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public API
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (OALinkStatus)linkStatusForJid:(XMPPJID *)JID {
    if (JID == nil || _roster == nil) {
        return OALinkStatusNone;
    }
    
    XMPPUserCoreDataStorageObject *user = [_rosterStorage userForJID:JID xmppStream:self.xmppStream managedObjectContext:_rosterStorage.mainThreadManagedObjectContext];
    if (user) {
        NSString *subscription = user.subscription;
        NSString *ask = user.ask;
        
        // TODO, presence unsubscribe
        if ([subscription isEqualToString:@"to"] && ask == nil) {
            if ([_receivedUnsubscriptionJidSet containsObject:JID]) {
                return OALinkStatusDeletedYou;
            } else {
                return OALinkStatusAwaitingReverseSubscribe;
            }
        }
        
        if ([subscription isEqualToString:@"both"]) {
            return OALinkStatusContact;
        }
        
        if ([subscription isEqualToString:@"from"]) {
            // you accepted the request from the sender, but the sender hasn't logged in since
            if ([ask isEqualToString:@"subscribe"]) {
                return OALinkStatusContactPending;
            }
            
            // you deleted the user, treat this user as if you have no interaction before
            if ([ask isEqualToString:@"unsubscribe"]) {
                return OALinkStatusDeletedByYou;
            }
        }
        
        if ([subscription isEqualToString:@"none"] && [ask isEqualToString:@"subscribe"]) {
            return OALinkStatusSent;
        }
        
        return OALinkStatusNone;
    } else {
        if ([_receivedSubscriptionJidSet containsObject:JID]) {
            return OALinkStatusReceived;
        } else {
            return OALinkStatusNone;
        }
    }
}

- (void)subscribeToJid:(NSString *)bareJid withToken:(NSString *)token defaultGroupName:(NSString *)groupName completion:(void(^)(BOOL))completionBlock {
    
    XMPPJID *jid = [XMPPJID jidWithString:bareJid];
    
    dispatch_block_t block = ^{ @autoreleasepool {
        
        void (^iqHandler)(XMPPIQ *, id <XMPPTrackingInfo>) = ^(XMPPIQ *iq, id <XMPPTrackingInfo> info) {
            if (!iq) {
                completionBlock(NO);
                return;
            }
            
            XMPPPresence *presence = [XMPPPresence presenceWithType:@"subscribe" to:jid];
            NSXMLElement *oasisElement = [NSXMLElement elementWithName:@"oasis" xmlns:@"http://oasis.com/xmpp"];
            [oasisElement addAttributeWithName:@"token" stringValue:token];
            [presence addChild:oasisElement];
            
            void (^pHandler)(XMPPIQ *, id <XMPPTrackingInfo>) = ^(XMPPIQ *iq, id <XMPPTrackingInfo> info) {
                if (iq) {
                    [multicastDelegate xmppSubscriptionHandler:self didSendSubscriptionToJid:jid];
                    completionBlock(YES);
                } else {
                    completionBlock(NO);
                }
            };
            
            [_xmppIDTracker addID:[NSString stringWithFormat:@"%@-%@-%@", jid.bare, @"none", @"subscribe"] block:pHandler timeout:PACKET_TIMEOUT];
            
            [self.xmppStream sendElement:presence];
        };
        
        [self sendAddUserIQ:jid group:groupName completion:iqHandler];
    }};
    
    OALinkStatus linkStatus = [self linkStatusForJid:jid];
    
    if (linkStatus == OALinkStatusDeletedYou || linkStatus == OALinkStatusDeletedByYou) {
        // wrap the block inside remove block
        dispatch_block_t removeBlock = ^{ @autoreleasepool {
            [self removeUser:jid completion:^(XMPPIQ *iq, id<XMPPTrackingInfo> info) {
                if (iq) {
                    // execute the nested block
                    if (dispatch_get_specific(moduleQueueTag))
                        block();
                    else
                        dispatch_async(moduleQueue, block);
                } else {
                    completionBlock(NO);
                }
            }];
        }};
        
        if (dispatch_get_specific(moduleQueueTag))
            removeBlock();
        else
            dispatch_async(moduleQueue, removeBlock);
        
    } else {
        // execute the block directly
        if (dispatch_get_specific(moduleQueueTag))
            block();
        else
            dispatch_async(moduleQueue, block);
    }
}

- (void)cancelSubscriptionToJid:(NSString *)bareJid completion:(void(^)(BOOL))completionBlock {
    XMPPJID *jid = [XMPPJID jidWithString:bareJid];
    
    dispatch_block_t block = ^{ @autoreleasepool {
        [self removeUser:jid completion:^(XMPPIQ *iq, id<XMPPTrackingInfo> info) {
            if (iq) {
                [multicastDelegate xmppSubscriptionHandler:self didCancelSentSubscriptionToJid:jid];
                completionBlock(YES);
            } else {
                completionBlock(NO);
            }
        }];
    }};
        
    if (dispatch_get_specific(moduleQueueTag))
        block();
    else
        dispatch_async(moduleQueue, block);
}

- (void)acceptSubscriptionFromJid:(NSString *)bareJid defaultGroupName:(NSString *)groupName completion:(void(^)(BOOL))completionBlock {
    XMPPJID *jid = [XMPPJID jidWithString:bareJid];
    
    dispatch_block_t block = ^{ @autoreleasepool {
        XMPPPresence *subscribedPresence = [XMPPPresence presenceWithType:@"subscribed" to:jid];
        [self.xmppStream sendElement:subscribedPresence];
        
        void (^iqHandler)(XMPPIQ *, id <XMPPTrackingInfo>) = ^(XMPPIQ *iq, id <XMPPTrackingInfo> info) {
            if (!iq) {
                completionBlock(NO);
                return;
            }
            
            // reverse subscribe
            XMPPPresence *presence = [XMPPPresence presenceWithType:@"subscribe" to:jid];
            
            void (^pHandler)(XMPPIQ *, id <XMPPTrackingInfo>) = ^(XMPPIQ *iq, id <XMPPTrackingInfo> info) {
                if (iq) {
                    [_receivedSubscriptionJidSet removeObject:jid];
                    [multicastDelegate xmppSubscriptionHandler:self didAcceptReceivedSubscriptionFromJid:jid];
                    completionBlock(YES);
                } else {
                    completionBlock(NO);
                }
            };
            
            [_xmppIDTracker addID:[NSString stringWithFormat:@"%@-%@-%@", jid.bare, @"from", @"subscribe"] block:pHandler timeout:PACKET_TIMEOUT];
            
            [self.xmppStream sendElement:presence];
        };
        
        [self sendAddUserIQ:jid group:groupName completion:iqHandler];
    }};
    
    if (dispatch_get_specific(moduleQueueTag))
        block();
    else
        dispatch_async(moduleQueue, block);
}

- (void)rejectSubscriptionFromJid:(NSString *)bareJid completion:(void(^)(BOOL))completionBlock {
    XMPPJID *jid = [XMPPJID jidWithString:bareJid];
    
    dispatch_block_t block = ^{ @autoreleasepool {
        XMPPPresence *presence = [XMPPPresence presenceWithType:@"unsubscribed" to:jid];
        
        void (^pHandler)(XMPPIQ *, id <XMPPTrackingInfo>) = ^(XMPPIQ *iq, id <XMPPTrackingInfo> info) {
            if (iq) {
                [_receivedSubscriptionJidSet removeObject:jid];
                [multicastDelegate xmppSubscriptionHandler:self didRejectReceivedSubscriptionFromJid:jid];
                completionBlock(YES);
            } else {
                completionBlock(NO);
            }
        };
        
        [_xmppIDTracker addID:[NSString stringWithFormat:@"%@-%@-%@", jid.bare, @"remove", @"null"] block:pHandler timeout:PACKET_TIMEOUT];
        
        [self.xmppStream sendElement:presence];
    }};
    
    if (dispatch_get_specific(moduleQueueTag))
        block();
    else
        dispatch_async(moduleQueue, block);
}

- (void)unsubscribeToJid:(NSString *)bareJid completion:(void(^)(BOOL))completionBlock {
    XMPPJID *jid = [XMPPJID jidWithString:bareJid];
    OALinkStatus linkStatus = [self linkStatusForJid:jid];
    
    if (linkStatus == OALinkStatusContact) {
        
        dispatch_block_t block = ^{ @autoreleasepool {
            XMPPPresence *unsubscribePresence = [XMPPPresence presenceWithType:@"unsubscribe" to:jid];
            void (^pHandler)(XMPPIQ *, id <XMPPTrackingInfo>) = ^(XMPPIQ *iq, id <XMPPTrackingInfo> info) {
                if (iq) {
                    [multicastDelegate xmppSubscriptionHandler:self didUnsubscribeToJid:jid];
                    completionBlock(YES);
                } else {
                    completionBlock(NO);
                }
            };
            
            [_xmppIDTracker addID:[NSString stringWithFormat:@"%@-%@-%@", jid.bare, @"from", @"unsubscribe"] block:pHandler timeout:PACKET_TIMEOUT];
            [self.xmppStream sendElement:unsubscribePresence];
        }};
        
        if (dispatch_get_specific(moduleQueueTag))
            block();
        else
            dispatch_async(moduleQueue, block);
        
    } else if (linkStatus == OALinkStatusContactPending || linkStatus == OALinkStatusDeletedYou) {
        
        dispatch_block_t removeBlock = ^{ @autoreleasepool {
            [self removeUser:jid completion:^(XMPPIQ *iq, id<XMPPTrackingInfo> info) {
                if (iq) {
                    if (linkStatus == OALinkStatusContactPending) {
                        [multicastDelegate xmppSubscriptionHandler:self didUnsubscribeToJid:jid];
                    }
                    completionBlock(YES);
                } else {
                    completionBlock(NO);
                }
            }];
        }};
        
        if (dispatch_get_specific(moduleQueueTag))
            removeBlock();
        else
            dispatch_async(moduleQueue, removeBlock);
        
    } else if (linkStatus == OALinkStatusReceived) {
        
        [self rejectSubscriptionFromJid:bareJid completion:completionBlock];
        
    } else if (linkStatus == OALinkStatusSent) {
        
        [self cancelSubscriptionToJid:bareJid completion:completionBlock];
        
    }
}

@end