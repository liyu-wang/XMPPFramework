//
//  OAXMPPSubscriptionHandler.h
//  Oasis
//
//  Created by Liyu Wang on 8/04/2016.
//  Copyright © 2016 Oasis. All rights reserved.
//

#import "XMPPModule.h"

typedef NS_ENUM(NSInteger, OALinkStatus) {
    OALinkStatusNone = 0,
    OALinkStatusSent,
    OALinkStatusReceived,
    OALinkStatusContact,
    // intermediate status when you accepted the subscribe from the sender, but the sender haven't logged in since
    OALinkStatusContactPending,
    // intermediate status when sender received the subscribed presence from the receiver but waiting for the reverse subscribe
    // after respond subscribed to the reverse subscribe the subscription become 'both'
    OALinkStatusAwaitingReverseSubscribe,
    OALinkStatusDeletedByYou,
    OALinkStatusDeletedYou
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - OAXMPPSubscriptionHandler Interface
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@class XMPPRoster;
@class XMPPJID;
@class XMPPIDTracker;

@interface OAXMPPSubscriptionHandler : XMPPModule {
    BOOL _isAfterLoginSubPresenceFullyLoaded;
    
    NSMutableSet *_receivedSubscriptionJidSet;
    NSMutableSet *_receivedUnsubscriptionJidSet;
    
    dispatch_source_t _loadingCompleteTimer;
    
    XMPPRoster *_roster;
    
    XMPPIDTracker *_xmppIDTracker;
}

@property (nonatomic, assign) BOOL isAfterLoginSubPresenceFullyLoaded;
@property (nonatomic, readonly) NSMutableSet *receivedSubscriptionJidSet;

- (instancetype)initWithRoster:(XMPPRoster *)roster;

- (OALinkStatus)linkStatusForJid:(XMPPJID *)JID;

- (void)subscribeToJid:(NSString *)bareJid withToken:(NSString *)token defaultGroupName:(NSString *)groupName completion:(void(^)(BOOL))block;
- (void)cancelSubscriptionToJid:(NSString *)bareJid completion:(void(^)(BOOL))completionBlock;
- (void)acceptSubscriptionFromJid:(NSString *)bareJid defaultGroupName:(NSString *)groupName completion:(void(^)(BOOL))completionBlock;
- (void)rejectSubscriptionFromJid:(NSString *)bareJid completion:(void(^)(BOOL))completionBlock;
- (void)unsubscribeToJid:(NSString *)bareJid completion:(void(^)(BOOL))completionBlock;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - OAXMPPSubscriptionHandlerDelegate Protocol
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@class XMPPJID;

@protocol OAXMPPSubscriptionHandlerDelegate <NSObject>
@optional

- (void)xmppSubscriptionHandler:(OAXMPPSubscriptionHandler *)sender didFinishLoadingAfterLoginSubscriptions:(NSSet<XMPPJID *> *) jidSet;
- (void)xmppSubscriptionHandler:(OAXMPPSubscriptionHandler *)sender didFinishLoadingAfterLoginUnsubscriptions:(NSSet<XMPPJID *> *) jidSet;

- (void)xmppSubscriptionHandler:(OAXMPPSubscriptionHandler *)sender didReceiveLiveSubscriptionFromJid:(XMPPJID *)jid;
- (void)xmppSubscriptionHandler:(OAXMPPSubscriptionHandler *)sender receivedSubscriptionBeenCancelledByJid:(XMPPJID *)jid;
- (void)xmppSubscriptionHandler:(OAXMPPSubscriptionHandler *)sender didAcceptReceivedSubscriptionFromJid:(XMPPJID *)jid;
- (void)xmppSubscriptionHandler:(OAXMPPSubscriptionHandler *)sender didRejectReceivedSubscriptionFromJid:(XMPPJID *)jid;

- (void)xmppSubscriptionHandler:(OAXMPPSubscriptionHandler *)sender didSendSubscriptionToJid:(XMPPJID *)jid;
- (void)xmppSubscriptionHandler:(OAXMPPSubscriptionHandler *)sender didCancelSentSubscriptionToJid:(XMPPJID *)jid;
- (void)xmppSubscriptionHandler:(OAXMPPSubscriptionHandler *)sender sentSubscriptionBeenAcceptedByJid:(XMPPJID *)jid;
- (void)xmppSubscriptionHandler:(OAXMPPSubscriptionHandler *)sender sentSubscriptionBeenRejectedByJid:(XMPPJID *)jid;

- (void)xmppSubscriptionHandler:(OAXMPPSubscriptionHandler *)sender didUnsubscribeToJid:(XMPPJID *)jid;

@end