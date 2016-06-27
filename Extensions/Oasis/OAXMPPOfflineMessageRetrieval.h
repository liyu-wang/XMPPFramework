//
//  OAXMPPOfflineMessageRetrieval.h
//  Oasis
//
//  Created by Liyu Wang on 13/01/2016.
//  Copyright © 2016 Oasis. All rights reserved.
//

#import "XMPPModule.h"

typedef enum OAXMPPMessageRetrievalErrorCode {
    OAXMPPMessageRetrievalTimeout = 0,
    OAXMPPMessageRetrievalDisconnect
} OAXMPPMessageRetrievalErrorCode;

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - OAXMPPOfflineMessageHeader Interface
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface OAXMPPOfflineMessageHeader : NSObject
@property (nonatomic, strong) NSString *jidStr;
@property (nonatomic, strong) NSString *node;

+ (OAXMPPOfflineMessageHeader *)headerWithJid:(NSString *)jid node:(NSString *)node;

- (id)initWithJid:(NSString *)jid node:(NSString *)node;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - OAXMPPOfflineMessageRetrieval Interface
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface OAXMPPOfflineMessageRetrieval : XMPPModule {
    BOOL _autoRetrieveOfflineMessageHeaders;
    BOOL _autoRetrieveTheMostRecentOfflineMessage;
    BOOL _autoClearOfflieMessageHeaders;
    
    // most recent offline message header for each jid
    NSMutableArray *_mostRecentOfflineMessageHeaders;
    NSMutableDictionary *_offlineMessageHeaderDic;
    NSMutableDictionary *_pendingQueries;
}

@property (nonatomic, assign) BOOL autoRetrieveOfflineMessageHeaders;
@property (nonatomic, assign) BOOL autoRetrieveTheMostRecentOfflineMessage;
@property (nonatomic, assign) BOOL autoClearOfflieMessageHeaders;

- (NSArray *)mostRecentOfflineMessageHeaders;
- (NSArray *)offlineMessageHeadersForJid:(NSString *)jid;

- (void)retrieveOfflineMessagesHeaders;
- (void)retrieveOfflineMessagesWithHeaders:(NSArray *)headers;

- (void)clearOfflineMessageHeadersWithJid:(NSString *)jid completion:(void(^)(NSError *error))block;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Delegate Protocol
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@protocol OAXMPPOfflineMessageRetrievalDelegate <NSObject>
@optional

- (void)offlineMessageRetrieval:(OAXMPPOfflineMessageRetrieval *)sender didReceiveMostRecentOfflineMessageHeaders:(NSArray *)items;
- (void)offlineMessageRetrieval:(OAXMPPOfflineMessageRetrieval *)sender failedToReceiveMostRecentOfflineMessageHeaders:(NSError *)error;

- (void)offlineMessageRetrieval:(OAXMPPOfflineMessageRetrieval *)sender didSendRetrievalForOfflineMessagesWithHeaders:(NSArray *)headers;
- (void)offlineMessageRetrieval:(OAXMPPOfflineMessageRetrieval *)sender failedToSendRetrievalForOfflineMessagesWithHeaders:(NSArray *)headers error:(NSError *)error;

@end
