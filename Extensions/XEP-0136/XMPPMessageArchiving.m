#import "XMPPMessageArchiving.h"
#import "XMPPFramework.h"
#import "XMPPLogging.h"
#import "NSNumber+XMPP.h"
#import "XMPPDateTimeProfiles.h"
// oasis <
#import "XMPPMessage+XEP_0085.h"
// oaiss >

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

// Log levels: off, error, warn, info, verbose
// Log flags: trace
#if DEBUG
  static const int xmppLogLevel = XMPP_LOG_LEVEL_WARN; // | XMPP_LOG_FLAG_TRACE;
#else
  static const int xmppLogLevel = XMPP_LOG_LEVEL_WARN;
#endif

#define XMLNS_XMPP_ARCHIVE @"urn:xmpp:archive"

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Oasis
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#define QUERY_TIMEOUT 30.0 // NSTimeInterval (double) = seconds

NSString *const OAXMPPMessageArchivingErrorDomain = @"OAXMPPMessageArchivingErrorDomain";

typedef enum OAXMPPMessageArchivingQueryInfoType {
    FetchConversationList,
    FetchArchivedMessages,
    RemoveArchivedMessages,
} OAXMPPMessageArchivingQueryInfoType;

@interface OAXMPPMessageArchivingQueryInfo : NSObject

@property (nonatomic, assign) OAXMPPMessageArchivingQueryInfoType type;
@property (nonatomic, readwrite) dispatch_source_t timer;
@property (nonatomic, copy) void(^completion)(NSError *error);

- (void)cancel;

+ (OAXMPPMessageArchivingQueryInfo *)queryInfoWithType:(OAXMPPMessageArchivingQueryInfoType)type;

@end


@implementation OAXMPPMessageArchivingQueryInfo

+ (OAXMPPMessageArchivingQueryInfo *)queryInfoWithType:(OAXMPPMessageArchivingQueryInfoType)type {
    return [[OAXMPPMessageArchivingQueryInfo alloc] initWithType:type];
}

- (instancetype)initWithType:(OAXMPPMessageArchivingQueryInfoType)aType {
    if (self = [super init]) {
        _type = aType;
    }
    return self;
}

- (void)cancel {
    if (_timer) {
        dispatch_source_cancel(_timer);
        #if !OS_OBJECT_USE_OBJC
        dispatch_release(timer);
        #endif
        _timer = NULL;
    }
}

- (void)dealloc {
    [self cancel];
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation XMPPMessageArchiving

- (id)init
{
	// This will cause a crash - it's designed to.
	// Only the init methods listed in XMPPMessageArchiving.h are supported.
	
	return [self initWithMessageArchivingStorage:nil dispatchQueue:NULL];
}

- (id)initWithDispatchQueue:(dispatch_queue_t)queue
{
	// This will cause a crash - it's designed to.
	// Only the init methods listed in XMPPMessageArchiving.h are supported.
	
	return [self initWithMessageArchivingStorage:nil dispatchQueue:queue];
}

- (id)initWithMessageArchivingStorage:(id <XMPPMessageArchivingStorage>)storage
{
	return [self initWithMessageArchivingStorage:storage dispatchQueue:NULL];
}

- (id)initWithMessageArchivingStorage:(id <XMPPMessageArchivingStorage>)storage dispatchQueue:(dispatch_queue_t)queue
{
	NSParameterAssert(storage != nil);
	
	if ((self = [super initWithDispatchQueue:queue]))
	{
		if ([storage configureWithParent:self queue:moduleQueue])
		{
			xmppMessageArchivingStorage = storage;
		}
		else
		{
			XMPPLogError(@"%@: %@ - Unable to configure storage!", THIS_FILE, THIS_METHOD);
		}
		
		NSXMLElement *_default = [NSXMLElement elementWithName:@"default"];
		[_default addAttributeWithName:@"expire" stringValue:@"604800"];
		[_default addAttributeWithName:@"save" stringValue:@"body"];
		
		NSXMLElement *pref = [NSXMLElement elementWithName:@"pref" xmlns:XMLNS_XMPP_ARCHIVE];
		[pref addChild:_default];
		
		preferences = pref;
// oasis <
        _pendingQueries = [[NSMutableDictionary alloc] init];
// oasis >
	}
	return self;
}

- (BOOL)activate:(XMPPStream *)aXmppStream
{
	XMPPLogTrace();
	
	if ([super activate:aXmppStream])
	{
		XMPPLogVerbose(@"%@: Activated", THIS_FILE);
		
		// Reserved for future potential use
		
		return YES;
	}
	
	return NO;
}

- (void)deactivate
{
	XMPPLogTrace();
	
	// Reserved for future potential use
	
	[super deactivate];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Properties
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (id <XMPPMessageArchivingStorage>)xmppMessageArchivingStorage
{
    // Note: The xmppMessageArchivingStorage variable is read-only (set in the init method)
    
    return xmppMessageArchivingStorage;
}

- (BOOL)clientSideMessageArchivingOnly
{
	__block BOOL result = NO;
	
	dispatch_block_t block = ^{
		result = clientSideMessageArchivingOnly;
	};
	
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_sync(moduleQueue, block);
	
	return result;
}

- (void)setClientSideMessageArchivingOnly:(BOOL)flag
{
	dispatch_block_t block = ^{
		clientSideMessageArchivingOnly = flag;
	};
	
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_async(moduleQueue, block);
}

- (NSXMLElement *)preferences
{
	__block NSXMLElement *result = nil;
	
	dispatch_block_t block = ^{
		
		result = [preferences copy];
	};
	
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_sync(moduleQueue, block);
	
	return result;
}

- (void)setPreferences:(NSXMLElement *)newPreferences
{
	dispatch_block_t block = ^{ @autoreleasepool {
		
		// Update cached value
		
		preferences = [newPreferences copy];
		
		// Update storage
		
		if ([xmppMessageArchivingStorage respondsToSelector:@selector(setPreferences:forUser:)])
		{
			XMPPJID *myBareJid = [[xmppStream myJID] bareJID];
			
			[xmppMessageArchivingStorage setPreferences:preferences forUser:myBareJid];
		}
		
		// Todo:
		// 
		//  - Send new pref to server (if changed)
	}};
	
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_async(moduleQueue, block);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)shouldArchiveMessage:(XMPPMessage *)message outgoing:(BOOL)isOutgoing xmppStream:(XMPPStream *)xmppStream
{
	// XEP-0136 Section 2.9: Preferences precedence rules:
	// 
	// When determining archiving preferences for a given message, the following rules shall apply:
	// 
	// 1. 'save' value is taken from the <session> element that matches the conversation, if present,
	//    else from the <item> element that matches the contact (see JID Matching), if present,
	//    else from the default element.
	// 
	// 2. 'otr' and 'expire' value are taken from the <item> element that matches the contact, if present,
	//    else from the default element.
	
	NSXMLElement *match = nil;
	
	NSString *messageThread = [[message elementForName:@"thread"] stringValue];
	if (messageThread)
	{
		// First priority - matching session element
		
		for (NSXMLElement *session in [preferences elementsForName:@"session"])
		{
			NSString *sessionThread = [session attributeStringValueForName:@"thread"];
			if ([messageThread isEqualToString:sessionThread])
			{
				match = session;
				break;
			}
		}
	}
	
	if (match == nil)
	{
		// Second priority - matching item element
		//
		// 
		// XEP-0136 Section 10.1: JID Matching
		// 
		// The following rules apply:
		// 
		// 1. If the JID is of the form <localpart@domain.tld/resource>, only this particular JID matches.
		// 2. If the JID is of the form <localpart@domain.tld>, any resource matches.
		// 3. If the JID is of the form <domain.tld>, any node matches.
		// 
		// However, having these rules only would make impossible a match like "all collections having JID
		// exactly equal to bare JID/domain JID". Therefore, when the 'exactmatch' attribute is set to "true" or
		// "1" on the <list/>, <remove/> or <item/> element, a JID value such as "example.com" matches
		// that exact JID only rather than <*@example.com>, <*@example.com/*>, or <example.com/*>, and
		// a JID value such as "localpart@example.com" matches that exact JID only rather than
		// <localpart@example.com/*>.
		
		XMPPJID *messageJid;
		if (isOutgoing)
			messageJid = [message to];
		else
			messageJid = [message from];
		
		NSXMLElement *match_full = nil;
		NSXMLElement *match_bare = nil;
		NSXMLElement *match_domain = nil;
		
		for (NSXMLElement *item in [preferences elementsForName:@"item"])
		{
			XMPPJID *itemJid = [XMPPJID jidWithString:[item attributeStringValueForName:@"jid"]];
			
			if (itemJid.resource)
			{
				BOOL match = [messageJid isEqualToJID:itemJid options:XMPPJIDCompareFull];
				
				if (match && (match_full == nil))
				{
					match_full = item;
				}
			}
			else if (itemJid.user)
			{
				BOOL exactmatch = [item attributeBoolValueForName:@"exactmatch" withDefaultValue:NO];
				BOOL match;
				
				if (exactmatch)
					match = [messageJid isEqualToJID:itemJid options:XMPPJIDCompareFull];
				else
					match = [messageJid isEqualToJID:itemJid options:XMPPJIDCompareBare];
				
				if (match && (match_bare == nil))
				{
					match_bare = item;
				}
			}
			else
			{
				BOOL exactmatch = [item attributeBoolValueForName:@"exactmatch" withDefaultValue:NO];
				BOOL match;
				
				if (exactmatch)
					match = [messageJid isEqualToJID:itemJid options:XMPPJIDCompareFull];
				else
					match = [messageJid isEqualToJID:itemJid options:XMPPJIDCompareDomain];
				
				if (match && (match_domain == nil))
				{
					match_domain = item;
				}
			}
		}
		
		if (match_full)
			match = match_full;
		else if (match_bare)
			match = match_bare;
		else if (match_domain)
			match = match_domain;
	}
	
	if (match == nil)
	{
		// Third priority - default element
		
		match = [preferences elementForName:@"default"];
	}
	
	if (match == nil)
	{
		XMPPLogWarn(@"%@: No message archive rule found for message! Discarding...", THIS_FILE);
		return NO;
	}
	
	// The 'save' attribute specifies the user's default setting for Save Mode.
	// The allowable values are:
	// 
	// - body    : the saving entity SHOULD save only <body/> elements.
	// - false   : the saving entity MUST save nothing.
	// - message : the saving entity SHOULD save the full XML content of each <message/> element.
	// - stream  : the saving entity SHOULD save every byte that passes over the stream in either direction.
	// 
	// Note: We currently only support body, and treat values of 'message' or 'stream' the same as 'body'.
	
	NSString *save = [[match attributeStringValueForName:@"save"] lowercaseString];
	
	if ([save isEqualToString:@"false"])
		return NO;
	else
		return YES;
}


////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark XMPPStream Delegate
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)xmppStreamDidAuthenticate:(XMPPStream *)sender
{
	XMPPLogTrace();
	
// oasis <
    [self oa_sendGetRecentConversationListIQ];
// oasis >
    
	if (clientSideMessageArchivingOnly) return;
	
	// Fetch most recent preferences
	
	if ([xmppMessageArchivingStorage respondsToSelector:@selector(preferencesForUser:)])
	{
		XMPPJID *myBareJid = [[xmppStream myJID] bareJID];
		
		preferences = [xmppMessageArchivingStorage preferencesForUser:myBareJid];
	}
	
	// Request archiving preferences from server
	// 
	// <iq type='get'>
	//   <pref xmlns='urn:xmpp:archive'/>
	// </iq>
	
	NSXMLElement *pref = [NSXMLElement elementWithName:@"pref" xmlns:XMLNS_XMPP_ARCHIVE];
	XMPPIQ *iq = [XMPPIQ iqWithType:@"get" to:nil elementID:nil child:pref];
	
	[sender sendElement:iq];
}

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
	NSString *type = [iq type];
	
	if ([type isEqualToString:@"result"])
	{
		NSXMLElement *pref = [iq elementForName:@"pref" xmlns:XMLNS_XMPP_ARCHIVE];
		if (pref)
		{
			[self setPreferences:pref];
// Oasis <
            return NO;
// Oasis >
		}
        
// oasis <
        OAXMPPMessageArchivingQueryInfo *queryInfo = _pendingQueries[[iq elementID]];
        if (queryInfo) {
            switch (queryInfo.type) {
                case FetchConversationList:
                    [self oa_processRecentConversationsIQ:iq withInfo:queryInfo];
                    break;
                case FetchArchivedMessages:
                    [self oa_processArchivedMessagesIQ:iq witnInfo:queryInfo];
                    break;
                case RemoveArchivedMessages:
                    [self oa_processRemoveArchivedMessagesResultIQ:iq witnInfo:queryInfo];
                    break;
            }
            
            [self removeQueryInfo:queryInfo withKey:[iq elementID]];
            return YES;
        }
// oasis >
	}
	else if ([type isEqualToString:@"set"])
	{
		// We receive the following type of IQ when we send a chat message within facebook from another device:
		// 
		// <iq from="chat.facebook.com" to="-121201407@chat.facebook.com/e49b026a_4BA226A73192D type="set">
		//   <own-message xmlns="http://www.facebook.com/xmpp/messages" to="-123@chat.facebook.com" self="false">
		//     <body>Hi Jilr</body>
		//   </own-message>
		// </iq>
		
		NSXMLElement *ownMessage = [iq elementForName:@"own-message" xmlns:@"http://www.facebook.com/xmpp/messages"];
		if (ownMessage)
		{
			BOOL isSelf = [ownMessage attributeBoolValueForName:@"self" withDefaultValue:NO];
			if (!isSelf)
			{
				NSString *bodyStr = [[ownMessage elementForName:@"body"] stringValue];
				if ([bodyStr length] > 0)
				{
					NSXMLElement *body = [NSXMLElement elementWithName:@"body" stringValue:bodyStr];
					
					XMPPJID *to = [XMPPJID jidWithString:[ownMessage attributeStringValueForName:@"to"]];
					XMPPMessage *message = [XMPPMessage messageWithType:@"chat" to:to];
					[message addChild:body];
					
					if ([self shouldArchiveMessage:message outgoing:YES xmppStream:sender])
					{
						[xmppMessageArchivingStorage archiveMessage:message outgoing:YES xmppStream:sender];
					}
				}
			}
			
			return YES;
		}
	}
	
	return NO;
}

- (void)xmppStream:(XMPPStream *)sender didSendMessage:(XMPPMessage *)message
{
	XMPPLogTrace();
	
	if ([self shouldArchiveMessage:message outgoing:YES xmppStream:sender])
	{
// oasis <
//		[xmppMessageArchivingStorage archiveMessage:message outgoing:YES xmppStream:sender];
        if (![message hasComposingChatState]) {
            [xmppMessageArchivingStorage oa_archiveMessage:message timestamp:nil outgoing:YES isRead:YES updateRecent:YES saveMessage:YES xmppStream:sender];
        }
// oasis >
	}
}

- (void)xmppStream:(XMPPStream *)sender didReceiveMessage:(XMPPMessage *)message
{
	XMPPLogTrace();
	
	if ([self shouldArchiveMessage:message outgoing:NO xmppStream:sender])
	{
// oasis <
//		[xmppMessageArchivingStorage archiveMessage:message outgoing:NO xmppStream:sender];
        if (![message hasComposingChatState]) {
            // don't store composing message in db
            [xmppMessageArchivingStorage oa_archiveMessage:message timestamp:nil outgoing:NO isRead:NO updateRecent:YES saveMessage:YES xmppStream:sender];
        }
// oasis >
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - OASIS IQ process
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

-(void)xmppStreamDidDisconnect:(XMPPStream *)sender withError:(NSError *)error {
    for (NSString *uuid in _pendingQueries) {
        OAXMPPMessageArchivingQueryInfo *queryInfo = _pendingQueries[uuid];
        
        [self processQuery:queryInfo withFailureCode:OAXMPPMessageArchivingErrorCodeDisconnect];
    }
    
    // Clear the list of pending queries
    [_pendingQueries removeAllObjects];
}

- (void)addQueryInfo:(OAXMPPMessageArchivingQueryInfo *)queryInfo withKey:(NSString *)uuid {

    // setup timer
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, moduleQueue);
    
    dispatch_source_set_event_handler(timer, ^{ @autoreleasepool {
        
        [self queryTimeout:uuid];
    }});
    
    dispatch_time_t fireTime = dispatch_time(DISPATCH_TIME_NOW, (QUERY_TIMEOUT * NSEC_PER_SEC));
    
    dispatch_source_set_timer(timer, fireTime, DISPATCH_TIME_FOREVER, 1.0);
    dispatch_resume(timer);
    
    queryInfo.timer = timer;
    
    // Add to dictionary
    _pendingQueries[uuid] = queryInfo;
}

- (void)removeQueryInfo:(OAXMPPMessageArchivingQueryInfo *)queryInfo withKey:(NSString *)uuid {
    [queryInfo cancel];
    
    [_pendingQueries removeObjectForKey:uuid];
}

- (void)processQuery:(OAXMPPMessageArchivingQueryInfo *)queryInfo withFailureCode:(OAXMPPMessageArchivingErrorCode)errorCode {
    NSError *error = [NSError errorWithDomain:OAXMPPMessageArchivingErrorDomain code:errorCode userInfo:nil];
    
    switch (queryInfo.type) {
        case FetchConversationList:
            [multicastDelegate messageArchiving:self failedToFetchConversationList:error];
            break;
        case FetchArchivedMessages:
        case RemoveArchivedMessages:
            if (queryInfo.completion) {
                queryInfo.completion(error);
            }
            break;
        default:
            break;
    }
}

- (void)queryTimeout:(NSString *)uuid {
    OAXMPPMessageArchivingQueryInfo *queryInfo = [_pendingQueries objectForKey:uuid];
    if (queryInfo) {
        [self processQuery:queryInfo withFailureCode:OAXMPPMessageArchivingErrorCodeTimeout];
        [self removeQueryInfo:queryInfo withKey:uuid];
    }
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - OASIS Fetch archived messages
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)oa_fetchArchivedMessagesFromServerWithJid:(NSString *)bareJid max:(NSInteger)maxNumber completion:(void (^)(NSError *error))block {
    XMPPLogTrace();
    
    //    <iq type='get' id='2345:retrieve' xmlns='jabber:client'>
    //        <retrieve xmlns='urn:xmpp:archive' with='101@talk1.qa.oasisactive.net'>
    //            <set xmlns='http://jabber.org/protocol/rsm'>
    //                <max>10</max>
    //            </set>
    //        </retrieve>
    //    </iq>
    
    if (!bareJid)
        return;
    
    NSXMLElement *retrieve = [NSXMLElement elementWithName:@"retrieve" xmlns:@"urn:xmpp:archive"];
    [retrieve addAttributeWithName:@"with" stringValue:bareJid];
    
    NSXMLElement *set = [NSXMLElement elementWithName:@"set" xmlns:@"http://jabber.org/protocol/rsm"];
    NSXMLElement *max = [NSXMLElement elementWithName:@"max"
                                          stringValue:[NSString stringWithFormat:@"%ld", (long)maxNumber]];
    [set addChild:max];
    
    [retrieve addChild:set];
    
    NSString *uuid = [xmppStream generateUUID];
    NSXMLElement *iq = [XMPPIQ iqWithType:@"get" elementID:uuid child:retrieve];
    
    [xmppStream sendElement:iq];
    
    OAXMPPMessageArchivingQueryInfo *queryInfo = [OAXMPPMessageArchivingQueryInfo queryInfoWithType:FetchArchivedMessages];
    [queryInfo setCompletion:block];
    [self addQueryInfo:queryInfo withKey:uuid];
}

- (void)oa_processArchivedMessagesIQ:(XMPPIQ *)iq witnInfo:(OAXMPPMessageArchivingQueryInfo *)queryInfo {
    XMPPLogTrace();
    
    //    <iq to="liyuw@talk1.qa.oasisactive.net/OASIS_FSC" type="result" id="2345:retrieve">
    //        <chat start="2013-11-14T12:53:08.999Z" with="101@talk1.qa.oasisactive.net" xmlns="urn:xmpp:archive">
    //            <from secs="0"><body type="2"></body></from>
    //            <from secs="1182765"><body>2</body></from>
    //            <from secs="1182769"><body type="0">3</body></from>
    //            <from secs="1197337"><body type="1">_103_get2_/images/14520011032016_get2_[width]x[height].jpg</body></from>
    //            <set xmlns="http://jabber.org/protocol/rsm">
    //                <first index="0">0</first>
    //                <last>0</last>
    //                <count>10</count>
    //            </set>
    //        </chat>
    //    </iq>
    
    if ([iq.type isEqualToString:@"result"]) {
        NSXMLElement *chatElement = [iq elementForName:@"chat" xmlns:XMLNS_XMPP_ARCHIVE];
        NSString *withBareJid = [chatElement attributeStringValueForName:@"with"];
        
        [xmppMessageArchivingStorage oa_removeOldArchivedMessagesWithJid:withBareJid streamJidStr:self.xmppStream.myJID.bare];
        
        NSString *referenceTimeStr = [chatElement attributeStringValueForName:@"start"];
        NSTimeInterval ref = [[XMPPDateTimeProfiles parseDateTime:referenceTimeStr] timeIntervalSince1970];
        
        NSInteger i = 0;
        NSInteger prevSecOffset = -1;
        NSArray *children = [chatElement children];
        
        for (NSXMLElement *fromOrTo in children) {
            BOOL isOutgoing = NO;
            if ([fromOrTo.name isEqualToString:@"to"]) {
                isOutgoing = YES;
            } else if ([fromOrTo.name isEqualToString:@"from"]) {
                isOutgoing = NO;
            } else {
                // skip the last child
                //<set xmlns="http://jabber.org/protocol/rsm"><first index="0">0</first><last>0</last><count>3</count></set>
                continue;
            }
            
            NSInteger secOffset = [[fromOrTo attributeStringValueForName:@"secs"] integerValue];
            // work around for the chat server returns many messages with same secs offset
            // always make subsequent message 1 sec greater than the previous message
            if (secOffset <= prevSecOffset) {
                secOffset = prevSecOffset + 1;
            }
            NSXMLElement *body = [fromOrTo elementForName:@"body"];
            
            NSTimeInterval time = ref + secOffset;
            NSDate *timestamp = [NSDate dateWithTimeIntervalSince1970:time];
            
            XMPPMessage *message = [XMPPMessage messageWithType:@"chat"];
            
            if (isOutgoing) {
                [message addAttributeWithName:@"to" stringValue:withBareJid];
            } else {
                [message addAttributeWithName:@"from" stringValue:withBareJid];
            }
            
            // add payload based on oasis message type
            OAXMPPMessageType oaMsgType = [body attributeIntegerValueForName:@"type" withDefaultValue:OAXMPPMessageTypeText];
            [message oa_addPayload:body.stringValue forMsgType:oaMsgType];
            
            // only update recent for the most recent message
            [xmppMessageArchivingStorage oa_archiveMessage:message
                                                 timestamp:timestamp
                                                  outgoing:isOutgoing
                                                    isRead:YES
                                              updateRecent:(i == children.count - 2)
                                               saveMessage:YES
                                                xmppStream:xmppStream];
            
            prevSecOffset = secOffset;
            i++;
        }
        
        if (queryInfo.completion) {
            queryInfo.completion(nil);
        }
    } else {
        if (queryInfo.completion) {
            queryInfo.completion([NSError errorWithDomain:OAXMPPMessageArchivingErrorDomain code:OAXMPPMessageArchivingErrorCodeServerError userInfo:nil]);
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - OASIS Remove archived messages
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)oa_removeArchivedMessagesWithJid:(NSString *)bareJid completion:(void(^)(NSError *error))block {
    XMPPLogTrace();
    
    // <iq type='set' id='1950:remove' xmlns='jabber:client'>
    // <remove xmlns='urn:xmpp:archive' with='114@talk1.qa.oasisactive.net'/>
    // </iq>
    NSXMLElement *removeElement = [NSXMLElement elementWithName:@"remove" xmlns:@"urn:xmpp:archive"];
    [removeElement addAttributeWithName:@"with" stringValue:bareJid];
    
    NSString *uuid = [xmppStream generateUUID];
    
    XMPPIQ *iq = [XMPPIQ iqWithType:@"set" elementID:uuid child:removeElement];
    [iq addAttributeWithName:@"xmlns" stringValue:@"jabber:client"];
    
    [self.xmppStream sendElement:iq];
    
    OAXMPPMessageArchivingQueryInfo *queryInfo = [OAXMPPMessageArchivingQueryInfo queryInfoWithType:RemoveArchivedMessages];
    [queryInfo setCompletion:block];
    [self addQueryInfo:queryInfo withKey:uuid];
}

- (void)oa_processRemoveArchivedMessagesResultIQ:(XMPPIQ *)iq witnInfo:(OAXMPPMessageArchivingQueryInfo *)queryInfo {
    
    // <iq to="103@talk1.qa.oasisactive.net/OASIS_FSC" type="result" id="1950:remove" />
    
    if ([iq.type isEqualToString:@"result"]) {
        if (queryInfo.completion) {
            queryInfo.completion(nil);
        }
    } else {
        if (queryInfo.completion) {
            queryInfo.completion([NSError errorWithDomain:OAXMPPMessageArchivingErrorDomain code:OAXMPPMessageArchivingErrorCodeServerError userInfo:nil]);
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - OASIS Recent Conversation List
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)oa_sendGetRecentConversationListIQ {
    
    // <iq type='get' id='55:list' xmlns='jabber:client'>
    // <list xmlns='urn:xmpp:archive'>
    // <set xmlns='http://jabber.org/protocol/rsm'>
    // <max>1</max>
    // </set>
    // </list>
    // </iq>
    
    NSXMLElement *listElement = [NSXMLElement elementWithName:@"list" xmlns:XMLNS_XMPP_ARCHIVE];
    NSXMLElement *setElement = [NSXMLElement elementWithName:@"set" xmlns:@"http://jabber.org/protocol/rsm"];
    NSXMLElement *maxElement = [NSXMLElement elementWithName:@"max" stringValue:@"1"];
    
    [setElement addChild:maxElement];
    [listElement addChild:setElement];
    
    NSString *uuid = [xmppStream generateUUID];
    XMPPIQ *iq = [XMPPIQ iqWithType:@"get" elementID:uuid child:listElement];
    [self.xmppStream sendElement:iq];
    
    OAXMPPMessageArchivingQueryInfo *queryInfo = [OAXMPPMessageArchivingQueryInfo queryInfoWithType:FetchConversationList];
    [self addQueryInfo:queryInfo withKey:uuid];
}

- (void)oa_processRecentConversationsIQ:(XMPPIQ *)iq withInfo:(OAXMPPMessageArchivingQueryInfo *)queryInfo {
    
    // <iq xmlns="jabber:client" type="result" id="E94134FE-59C3-4237-BB1F-07892B92D2D5" to="103@talk1.qa.oasisactive.net/oasis_iphone">
    // <list xmlns="urn:xmpp:archive">
    // <chat with="114" start="2015-12-30T23:55:48.234Z">
    // <from secs="0">
    // <body type="0">ddddd</body>
    // </from>
    // </chat>
    // <chat with="a113" start="2015-12-29T23:05:22.293Z">
    // <to secs="0">
    // <body type="0">vvv</body>
    // </to>
    // </chat>
    // </list>
    // </iq>
    
    if ([iq.type isEqualToString:@"result"]) {
        
        NSMutableArray *usernameArray = [@[] mutableCopy];
        
        // clear old conversations
        [self.xmppMessageArchivingStorage oa_removeOldRecentContactListWithStreamJidStr:self.xmppStream.myJID.bare];
        
        NSXMLElement *listElement = [iq elementForName:@"list" xmlns:XMLNS_XMPP_ARCHIVE];
        NSArray *chats = [listElement elementsForName:@"chat"];
        for (NSXMLElement *chat in chats) {
            // should send jid rather than username
            NSString *username = [chat attributeStringValueForName:@"with"];
            NSString *timeStampStr = [chat attributeStringValueForName:@"start"];
            NSDate *timeStamp = [XMPPDateTimeProfiles parseDateTime:timeStampStr];
            
            XMPPMessage *message = [XMPPMessage messageWithType:@"chat"];
            
            OAXMPPMessageType oaMsgType;
            NSXMLElement *body;
            BOOL outgoing = NO;
            NSXMLElement *from = [chat elementForName:@"from"];
            if (from) {
                body = [from elementForName:@"body"];
                oaMsgType = [body attributeIntegerValueForName:@"type" withDefaultValue:OAXMPPMessageTypeText];
                
                [message addAttributeWithName:@"from" stringValue:username];
            } else {
                NSXMLElement *to = [chat elementForName:@"to"];
                body = [to elementForName:@"body"];
                oaMsgType = [body attributeIntegerValueForName:@"type" withDefaultValue:OAXMPPMessageTypeText];
                outgoing = YES;
                
                [message addAttributeWithName:@"to" stringValue:username];
            }
            
            // add payload based on oasis message type
            [message oa_addPayload:[body stringValue] forMsgType:oaMsgType];
            
            // update only the recent contact table
            [xmppMessageArchivingStorage oa_archiveMessage:message timestamp:timeStamp outgoing:outgoing isRead: YES updateRecent:YES saveMessage:NO xmppStream:self.xmppStream];
            
            [usernameArray addObject:username];
        }
        
        [multicastDelegate messageArchiving:self didFetchConversationsWithUsers:usernameArray];
    } else {
        NSError *error = [NSError errorWithDomain:OAXMPPMessageArchivingErrorDomain code:OAXMPPMessageArchivingErrorCodeServerError userInfo:nil];
        [multicastDelegate messageArchiving:self failedToFetchConversationList: error];
    }
}

@end
