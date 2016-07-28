//
//  OAXMPPOfflineMessageRetrieval.m
//  Oasis
//
//  Created by Liyu Wang on 13/01/2016.
//  Copyright © 2016 Oasis. All rights reserved.
//

#import "OAXMPPOfflineMessageRetrieval.h"
#import "XMPP.h"
#import "XMPPLogging.h"
#import "NSXMLElement+XEP_0203.h"
#import "XMPPDateTimeProfiles.h"
#import "XMPPMessageArchiving_Message_CoreDataObject.h"

#ifdef DEBUG
static const int xmppLogLevel = XMPP_LOG_LEVEL_VERBOSE; // | XMPP_LOG_FLAG_TRACE;
#else
static const int xmppLogLevel = XMPP_LOG_LEVEL_WARN;
#endif

#define QUERY_TIMEOUT 15.0 // NSTimeInterval (double) = seconds

NSString *const XMPPMessageRetrievalErrorDomain = @"XMPPMessageRetrievalErrorDomain";
NSString *const XMPPOfflineMessageRetrievalErrorDomain = @"XMPPOfflineMessageRetrievalErrorDomain";

typedef enum XMPPMessageRetrievalQueryInfoType {
    FetchOfflineMessageHeaders = 0,
    FetchMostRecentOfflineMessages, // retrieve will just send a view
    ViewOfflineMessages, // view will send a view then send a remove
    RemoveOfflineMessages
} XMPPMessageRetrievalQueryInfoType;

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - OAXMPPOfflineMessageHeader Implementation
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation OAXMPPOfflineMessageHeader

+ (OAXMPPOfflineMessageHeader *)headerWithJid:(NSString *)jid node:(NSString *)node {
    return [[OAXMPPOfflineMessageHeader alloc] initWithJid:jid node:node];
}

- (id)initWithJid:(NSString *)jid node:(NSString *)node {
    self = [super init];
    if (self) {
        _jidStr = jid;
        _node = node;
    }
    return self;
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - XMPPMessageRetrievalQueryInfo Interface
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface XMPPMessageRetrievalQueryInfo : NSObject {
    XMPPMessageRetrievalQueryInfoType _type;
    dispatch_source_t _timer;
}

+ (XMPPMessageRetrievalQueryInfo *)queryInfoWithType:(XMPPMessageRetrievalQueryInfoType)type;

@property (nonatomic, readonly) XMPPMessageRetrievalQueryInfoType type;
@property (nonatomic, readwrite) dispatch_source_t timer;

@property (nonatomic, copy) void(^completion)(NSError *error);

- (id)initWithType:(XMPPMessageRetrievalQueryInfoType)type;
- (void)cancel;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - XMPPMessageRetrievalQueryInfo Implementation
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation XMPPMessageRetrievalQueryInfo

+ (XMPPMessageRetrievalQueryInfo *)queryInfoWithType:(XMPPMessageRetrievalQueryInfoType)type {
    return [[XMPPMessageRetrievalQueryInfo alloc] initWithType:type];
}

- (id)initWithType:(XMPPMessageRetrievalQueryInfoType)type {
    self = [super init];
    if (self) {
        _type = type;
    }
    return self;
}

- (void)cancel {
    if (_timer) {
        dispatch_source_cancel(_timer);
#if !OS_OBJECT_USE_OBJC
        dispatch_release(_timer);
#endif
        _timer = NULL;
    }
}

- (void)dealloc {
    [self cancel];
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - XMPPOfflineMessageRetrievalQueryInfo Interface
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface XMPPOfflineMessageRetrievalQueryInfo : XMPPMessageRetrievalQueryInfo {
    NSArray *_items;
}

+ (XMPPOfflineMessageRetrievalQueryInfo *)queryInfoWithType:(XMPPMessageRetrievalQueryInfoType)type items:(NSArray *)items;
+ (XMPPOfflineMessageRetrievalQueryInfo *)queryInfoWithType:(XMPPMessageRetrievalQueryInfoType)type bareJid:(NSString *)bareJid items:(NSArray *)items;

@property (nonatomic, strong) NSString *bareJid;
@property (nonatomic, strong) NSArray *items;

- (id)initWithType:(XMPPMessageRetrievalQueryInfoType)type bareJid:(NSString *)bareJid items:(NSArray *)items;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - XMPPOfflineMessageRetrievalQueryInfo Implementation
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation XMPPOfflineMessageRetrievalQueryInfo

+ (XMPPOfflineMessageRetrievalQueryInfo *)queryInfoWithType:(XMPPMessageRetrievalQueryInfoType)type items:(NSArray *)items {
    return [[XMPPOfflineMessageRetrievalQueryInfo alloc] initWithType:type bareJid:nil items:items];
}

+ (XMPPOfflineMessageRetrievalQueryInfo *)queryInfoWithType:(XMPPMessageRetrievalQueryInfoType)type bareJid:(NSString *)bareJid items:(NSArray *)items {
    return [[XMPPOfflineMessageRetrievalQueryInfo alloc] initWithType:type bareJid:bareJid items:items];
}

- (id)initWithType:(XMPPMessageRetrievalQueryInfoType)type bareJid:(NSString *)bareJid items:(NSArray *)items {
    self = [super initWithType:type];
    if (self) {
        _bareJid = bareJid;
        _items = items;
    }
    return self;
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - OAXMPPOfflineMessageRetrieval Implementation
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface OAXMPPOfflineMessageRetrieval()

- (void)viewOfflineMessagesWithJid:(NSString *)bareJid completion:(void(^)(NSError *error))block;
- (void)removeOfflineMessagesWithJid:(NSString *)bareJid completion:(void(^)(NSError *error))block;

@end

@implementation OAXMPPOfflineMessageRetrieval

- (id)init {
    if (self = [super initWithDispatchQueue:NULL]) {
        
        _autoRetrieveOfflineMessageHeaders = YES;
        _autoRetrieveTheMostRecentOfflineMessage = YES;
        _autoClearOfflieMessageHeaders = YES;
		
		_mostRecentOfflineMessageHeaders = [NSMutableArray array];
        _offlineMessageHeaderDic = [NSMutableDictionary dictionary];
		_pendingQueries = [NSMutableDictionary dictionary];
        
    }
    return self;
}

- (BOOL)activate:(XMPPStream *)aXmppStream {
	if ([super activate:aXmppStream]) {
		// Reserved for possible future use.
		
		return YES;
	}
	
	return NO;
}

- (void)deactivate {
	// Reserved for possible future use.
	
	[super deactivate];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Properties
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)autoRetrieveOfflineMessageHeaders {
    if (dispatch_get_specific(moduleQueueTag)) {
		return _autoRetrieveOfflineMessageHeaders;
	} else {
		__block BOOL result;
		
		dispatch_sync(moduleQueue, ^{
			result = _autoRetrieveOfflineMessageHeaders;
		});
		
		return result;
	}
}

- (void)setAutoRetrieveOfflineMessageHeaders:(BOOL)flag {
    dispatch_block_t block = ^{
		
		_autoRetrieveOfflineMessageHeaders = flag;
	};
	
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_async(moduleQueue, block);
}

- (BOOL)autoRetrieveTheMostRecentOfflineMessage {
    if (dispatch_get_specific(moduleQueueTag)) {
		return _autoRetrieveTheMostRecentOfflineMessage;
	} else {
		__block BOOL result;
		
		dispatch_sync(moduleQueue, ^{
			result = _autoRetrieveTheMostRecentOfflineMessage;
		});
		
		return result;
	}
}

- (void)setAutoRetrieveTheMostRecentOfflineMessage:(BOOL)flag {
    dispatch_block_t block = ^{
		
		_autoRetrieveTheMostRecentOfflineMessage = flag;
	};
	
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_async(moduleQueue, block);
}

- (BOOL)autoClearOfflieMessageHeaders {
    if (dispatch_get_specific(moduleQueueTag)) {
		return _autoClearOfflieMessageHeaders;
	} else {
		__block BOOL result;
		
		dispatch_sync(moduleQueue, ^{
			result = _autoClearOfflieMessageHeaders;
		});
		
		return result;
	}
}

- (void)setAutoClearOfflieMessageHeaders:(BOOL)flag {
    dispatch_block_t block = ^{
		
		_autoClearOfflieMessageHeaders = flag;
	};
	
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_async(moduleQueue, block);
}

- (NSArray *)mostRecentOfflineMessageHeaders {
    if (dispatch_get_specific(moduleQueueTag)) {
        return _mostRecentOfflineMessageHeaders;
    } else {
        __block NSArray *result;
        dispatch_async(moduleQueue, ^{
            result = _mostRecentOfflineMessageHeaders;
        });
        return result;
    }
}

- (NSArray *)offlineMessageHeadersForJid:(NSString *)jid {
    if (dispatch_get_specific(moduleQueueTag)) {
		return [_offlineMessageHeaderDic objectForKey:jid];
	} else {
		__block NSArray *result;
		dispatch_sync(moduleQueue, ^{
            result = [_offlineMessageHeaderDic objectForKey:jid];
        });
		return result;
	}
}

- (NSArray *)offlineMessageToPrefetch {
    NSMutableArray *headersToFetch = [@[] mutableCopy];
    for (NSString *bareJid in [_offlineMessageHeaderDic allKeys]) {
        NSArray *array = _offlineMessageHeaderDic[bareJid];
        [headersToFetch addObject:[array lastObject]];
    }
    return headersToFetch;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Retrieving Deleting
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)retrieveOfflineMessagesHeaders {
    XMPPLogTrace();
    
//    <iq type='get' xmlns='jabber:client' id='210:sendIQ'>
//        <query xmlns='http://jabber.org/protocol/disco#items' node='http://jabber.org/protocol/offline'/>
//    </iq>
    
    NSXMLElement *query = [NSXMLElement elementWithName:@"query" xmlns:@"http://jabber.org/protocol/disco#items"];
    [query addAttributeWithName:@"node" stringValue:@"http://jabber.org/protocol/offline"];
    
    NSString *uuid = [xmppStream generateUUID];
    XMPPIQ *iq = [XMPPIQ iqWithType:@"get" elementID:uuid child:query];
    
    [xmppStream sendElement:iq];
    
    XMPPOfflineMessageRetrievalQueryInfo *queryInfo = (XMPPOfflineMessageRetrievalQueryInfo *)[XMPPOfflineMessageRetrievalQueryInfo queryInfoWithType:FetchOfflineMessageHeaders];
    [self addQueryInfo:queryInfo withKey:uuid];
}

/* retrieve will just send a view */
- (void)retrieveOfflineMessagesWithHeaders:(NSArray *)headers {
    XMPPLogTrace();
    
    if (headers.count == 0)
        return;
    
//    <iq type='get' id='5826' xmlns='jabber:client'>
//        <offline xmlns='http://jabber.org/protocol/offline'>
//            <item action='view' node='2013-11-27T03:19:51.766Z'/>
//        </offline>
//    </iq>
    
    NSXMLElement *offline = [self offlineElementWithAction:@"view" headers:headers];
    
    NSString *uuid = [xmppStream generateUUID];
    XMPPIQ *iq = [XMPPIQ iqWithType:@"get" elementID:uuid child:offline];
    
    [xmppStream sendElement:iq];
    
    XMPPMessageRetrievalQueryInfo *queryInfo = [XMPPOfflineMessageRetrievalQueryInfo queryInfoWithType:FetchMostRecentOfflineMessages
                                                                                                 items:headers];
    [self addQueryInfo:queryInfo withKey:uuid];
}

- (void)clearOfflineMessageHeadersWithJid:(NSString *)jid completion:(void(^)(NSError *error))block {
    XMPPLogTrace();
    
    NSArray *headers = _offlineMessageHeaderDic[jid];
    if (headers.count == 1) {
        // since we viewed the most recent offline messages for the conversation view
        // we just need to remove it straight away
        [self removeOfflineMessagesWithJid:jid completion:block];
    } else if (headers.count > 0) {
        [self viewOfflineMessagesWithJid:jid completion:block];
    } else {
        if (block) {
            block(nil);
        }
    }
}

/* view will send a view then send a remove */
- (void)viewOfflineMessagesWithJid:(NSString *)bareJid completion:(void(^)(NSError *error))block {
    XMPPLogTrace();
    
    //    <iq type='get' id='5826' xmlns='jabber:client'>
    //        <offline xmlns='http://jabber.org/protocol/offline'>
    //            <item action='view' node='2013-11-27T03:19:51.766Z'/>
    //        </offline>
    //    </iq>
    
    NSArray *headers = _offlineMessageHeaderDic[bareJid];
    if (headers.count > 0) {
        // since we fetched the most recent offline messages for the conversation view we don't
        // need to view it again, otherwise same most recent offline message will be sent from server.
        NSMutableArray *mutableHeaders = [headers mutableCopy];
        [mutableHeaders removeLastObject];
        
        NSXMLElement *offline = [self offlineElementWithAction:@"view" headers:mutableHeaders];
        NSString *uuid = [xmppStream generateUUID];
        XMPPIQ *iq = [XMPPIQ iqWithType:@"get" elementID:uuid child:offline];
        
        [xmppStream sendElement:iq];
        
        XMPPMessageRetrievalQueryInfo *queryInfo = [XMPPOfflineMessageRetrievalQueryInfo queryInfoWithType:ViewOfflineMessages
                                                                                                   bareJid:bareJid
                                                                                                     items:headers];
        queryInfo.completion = block;
        
        [self addQueryInfo:queryInfo withKey:uuid];
    }
}

- (void)removeOfflineMessagesWithJid:(NSString *)bareJid completion:(void(^)(NSError *error))block {
    XMPPLogTrace();

//    <iq type='get' id='5826' xmlns='jabber:client'>
//        <offline xmlns='http://jabber.org/protocol/offline'>
//            <item action='remove' node='2013-11-27T03:19:51.766Z'/>
//        </offline>
//    </iq>
    
    NSArray *headers = _offlineMessageHeaderDic[bareJid];
    if (headers.count > 0) {
        NSXMLElement *offline = [self offlineElementWithAction:@"remove" headers:headers];
        NSString *uuid = [xmppStream generateUUID];
        XMPPIQ *iq = [XMPPIQ iqWithType:@"get" elementID:uuid child:offline];
        
        [xmppStream sendElement:iq];
        
        XMPPMessageRetrievalQueryInfo *queryInfo = [XMPPOfflineMessageRetrievalQueryInfo queryInfoWithType:RemoveOfflineMessages
                                                                                                   bareJid:bareJid
                                                                                                     items:headers];
        queryInfo.completion = block;
        
        [self addQueryInfo:queryInfo withKey:uuid];
    }
}


////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSXMLElement Helper
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSXMLElement *)offlineElementWithAction:(NSString *)action headers:(NSArray *)headers {
    NSXMLElement *offline = [NSXMLElement elementWithName:@"offline" xmlns:@"http://jabber.org/protocol/offline"];
    NSXMLElement *item = nil;
    for (OAXMPPOfflineMessageHeader *header in headers) {
        item = [NSXMLElement elementWithName:@"item"];
        [item addAttributeWithName:@"action" stringValue:action];
        [item addAttributeWithName:@"node" stringValue:header.node];
        [offline addChild:item];
    }
    return offline;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - IQ Response Processing
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)addQueryInfo:(XMPPMessageRetrievalQueryInfo *)queryInfo withKey:(NSString *)uuid {
    // setup timer
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, moduleQueue);
    
    OAXMPPOfflineMessageRetrieval* __weak weakSelf = self;
    
    dispatch_source_set_event_handler(timer, ^{
        OAXMPPOfflineMessageRetrieval* strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf queryTimeout:uuid];
        }
    });
    
    dispatch_time_t fireTime = dispatch_time(DISPATCH_TIME_NOW, (QUERY_TIMEOUT * NSEC_PER_SEC));
	
	dispatch_source_set_timer(timer, fireTime, DISPATCH_TIME_FOREVER, 1.0);
	dispatch_resume(timer);
	
	queryInfo.timer = timer;
    
    [_pendingQueries setObject:queryInfo forKey:uuid];
}

- (void)removeQueryInfo:(XMPPMessageRetrievalQueryInfo *)queryInfo withKey:(NSString *)uuid {
    [queryInfo cancel];
    
    [_pendingQueries removeObjectForKey:uuid];
}

- (void)queryTimeout:(NSString *)uuid {
	XMPPMessageRetrievalQueryInfo *queryInfo = [_pendingQueries objectForKey:uuid];
	if (queryInfo) {
		[self processQuery:queryInfo withFailureCode:OAXMPPMessageRetrievalTimeout];
		[self removeQueryInfo:queryInfo withKey:uuid];
	}
}

- (void)processQuery:(XMPPMessageRetrievalQueryInfo *)queryInfo withFailureCode:(OAXMPPMessageRetrievalErrorCode)errorCode {
    NSError *error = nil;
    switch (queryInfo.type) {
        case FetchOfflineMessageHeaders:
            error = [NSError errorWithDomain:XMPPOfflineMessageRetrievalErrorDomain code:errorCode userInfo:nil];
            [multicastDelegate offlineMessageRetrieval:self failedToReceiveMostRecentOfflineMessageHeaders:error];
            break;
        case FetchMostRecentOfflineMessages:
            error = [NSError errorWithDomain:XMPPOfflineMessageRetrievalErrorDomain code:errorCode userInfo:nil];
            [multicastDelegate offlineMessageRetrieval:self failedToSendRetrievalForOfflineMessagesWithHeaders:_mostRecentOfflineMessageHeaders error:error];
            break;
        case ViewOfflineMessages:
        case RemoveOfflineMessages:
            error = [NSError errorWithDomain:XMPPOfflineMessageRetrievalErrorDomain code:errorCode userInfo:nil];
            if (queryInfo.completion) {
                queryInfo.completion(error);
            }
            break;
        default:
            break;
    }
}

- (void)processOfflineMessageHeadersRetrievalIQ:(XMPPIQ *)iq withInfo:(XMPPOfflineMessageRetrievalQueryInfo *)queryInfo {
    XMPPLogTrace();
    
//    <iq to="101@talk1.qa.oasisactive.net/OASIS_FSC" type="result" id="2338:sendIQ">
//        <query node="http://jabber.org/protocol/offline" xmlns="http://jabber.org/protocol/disco#items">
//            <item node="2013-11-28T05:25:53.335Z" jid="101@talk1.qa.oasisactive.net" name="liyuw@talk1.qa.oasisactive.net/oasis_iphone" />
//            <item node="2013-11-28T05:25:54.567Z" jid="101@talk1.qa.oasisactive.net" name="liyuw@talk1.qa.oasisactive.net/oasis_iphone" />
//            <item node="2013-11-28T05:25:58.088Z" jid="101@talk1.qa.oasisactive.net" name="liyuw@talk1.qa.oasisactive.net/oasis_iphone" />
//            <item node="2013-11-28T06:35:36.188Z" jid="101@talk1.qa.oasisactive.net" name="103@talk1.qa.oasisactive.net/oasis_iphone" />
//        </query>
//    </iq>
    if ([iq.type isEqualToString:@"result"]) {
        [_mostRecentOfflineMessageHeaders removeAllObjects];
        [_offlineMessageHeaderDic removeAllObjects];
        
        NSXMLElement *query = [iq elementForName:@"query" xmlns:@"http://jabber.org/protocol/disco#items"];
        if (query == nil)
            return;
        NSArray *items = [query elementsForName:@"item"];
        
        NSString *toJidStr = nil;
        NSString *node = nil;
        NSString *fromjidStr = nil;
        XMPPJID *jid = nil;
        OAXMPPOfflineMessageHeader *header = nil;
        for (NSXMLElement *item in items) {
            toJidStr = [item attributeStringValueForName:@"jid"];
            if ([toJidStr isEqualToString:self.xmppStream.myJID.bare]) {
                node = [item attributeStringValueForName:@"node"];
                
                fromjidStr = [item attributeStringValueForName:@"name"];
                jid = [XMPPJID jidWithString:fromjidStr];
                fromjidStr = jid.bare;
                
                header = [OAXMPPOfflineMessageHeader headerWithJid:fromjidStr node:node];
                
                NSMutableArray *array = (NSMutableArray *)_offlineMessageHeaderDic[fromjidStr];
                if (!array) {
                    array = [@[] mutableCopy];
                    _offlineMessageHeaderDic[fromjidStr] = array;
                }
                
                [array addObject:header];
            }
        }
        
        NSString *aKey;
        NSEnumerator *keyEnumerator = [_offlineMessageHeaderDic keyEnumerator];
        
        while ((aKey = [keyEnumerator nextObject]) != nil) {
            NSArray *array = _offlineMessageHeaderDic[aKey];
            if (array.count > 0) {
                [_mostRecentOfflineMessageHeaders addObject:[array lastObject]];
            }
        }
        
        [multicastDelegate offlineMessageRetrieval:self didReceiveOfflineMessageHeadersDict:_offlineMessageHeaderDic mostRecentOfflineMessageHeaders:_mostRecentOfflineMessageHeaders];
    } else {
        [multicastDelegate offlineMessageRetrieval:self failedToReceiveMostRecentOfflineMessageHeaders:nil];
    }
}

- (void)processOfflineMessagesRetrievalIQ:(XMPPIQ *)iq withInfo:(XMPPOfflineMessageRetrievalQueryInfo *)queryInfo {
    XMPPLogTrace();
    
    [multicastDelegate offlineMessageRetrieval:self didSendRetrievalForOfflineMessagesWithHeaders:_mostRecentOfflineMessageHeaders];
}

- (void)processOfflineMessagesViewIQ:(XMPPIQ *)iq withInfo:(XMPPOfflineMessageRetrievalQueryInfo *)queryInfo {
    XMPPLogTrace();
    
//    <iq to="101@talk1.qa.oasisactive.net/OASIS_FSC" type="result" id="2343" />
    
    if ([iq.type isEqualToString:@"result"]) {
        [self removeOfflineMessagesWithJid:queryInfo.bareJid completion:queryInfo.completion];
    } else {
        XMPPLogError(@"failed to view offline messages");
    }
}

- (void)processOfflineMessagesRemovalIQ:(XMPPIQ *)iq withInfo:(XMPPOfflineMessageRetrievalQueryInfo *)queryInfo {
    XMPPLogTrace();
    
//    <iq to="101@talk1.qa.oasisactive.net/OASIS_FSC" type="result" id="2343" />
    
    if ([iq.type isEqualToString:@"result"]) {
        NSString *key = queryInfo.bareJid;
        if (key) {
            NSArray *headers = [_offlineMessageHeaderDic objectForKey:key];
            [_mostRecentOfflineMessageHeaders removeObject:[headers lastObject]];
            [_offlineMessageHeaderDic removeObjectForKey:key];
        }
        
        if (queryInfo.completion) {
            queryInfo.completion(nil);
        }
    } else {
        XMPPLogError(@"failed to remove offline messages");
    }
}


////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - XMPPStream Delegate
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)xmppStreamDidAuthenticate:(XMPPStream *)sender {
	if (self.autoRetrieveOfflineMessageHeaders) {
		[self retrieveOfflineMessagesHeaders];
	}
}

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
    XMPPMessageRetrievalQueryInfo *queryInfo = [_pendingQueries objectForKey:[iq elementID]];
    if (queryInfo) {
        switch (queryInfo.type) {
            case FetchOfflineMessageHeaders:
                [self processOfflineMessageHeadersRetrievalIQ:iq withInfo:(XMPPOfflineMessageRetrievalQueryInfo *)queryInfo];
                if (self.autoRetrieveTheMostRecentOfflineMessage &&
                    _mostRecentOfflineMessageHeaders.count > 0) {
                    // fetch the most recent offline messages for the conversation view
                    [self retrieveOfflineMessagesWithHeaders:_mostRecentOfflineMessageHeaders];
                }
                break;
            case FetchMostRecentOfflineMessages:
                [self processOfflineMessagesRetrievalIQ:iq withInfo:(XMPPOfflineMessageRetrievalQueryInfo *)queryInfo];
                break;
            case ViewOfflineMessages:
                [self processOfflineMessagesViewIQ:iq withInfo:(XMPPOfflineMessageRetrievalQueryInfo *)queryInfo];
                break;
            case RemoveOfflineMessages:
                [self processOfflineMessagesRemovalIQ:iq withInfo:(XMPPOfflineMessageRetrievalQueryInfo *)queryInfo];
                break;
            default:
                break;
        }
        [self removeQueryInfo:queryInfo withKey:[iq elementID]];
        return YES;
    }
    
    return NO;
}


- (void)xmppStreamDidDisconnect:(XMPPStream *)sender withError:(NSError *)error {
    if (_autoClearOfflieMessageHeaders) {
        [_mostRecentOfflineMessageHeaders removeAllObjects];
        [_offlineMessageHeaderDic removeAllObjects];
    }
    
    NSString *aKey;
    NSEnumerator *keyEnumerator = [_pendingQueries keyEnumerator];
    
    while ((aKey = [keyEnumerator nextObject]) != nil) {
        XMPPMessageRetrievalQueryInfo *queryInfo = _pendingQueries[aKey];
        if (queryInfo) {
            [self processQuery:queryInfo withFailureCode:OAXMPPMessageRetrievalDisconnect];
            [self removeQueryInfo:queryInfo withKey:aKey];
        }
    }
}

@end