#import "XMPPMessageArchivingCoreDataStorage.h"
#import "XMPPCoreDataStorageProtected.h"
#import "XMPPLogging.h"
#import "NSXMLElement+XEP_0203.h"
#import "XMPPMessage+XEP_0085.h"

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

// Log levels: off, error, warn, info, verbose
// Log flags: trace
#if DEBUG
  static const int xmppLogLevel = XMPP_LOG_LEVEL_WARN; // VERBOSE; // | XMPP_LOG_FLAG_TRACE;
#else
  static const int xmppLogLevel = XMPP_LOG_LEVEL_WARN;
#endif

@interface XMPPMessageArchivingCoreDataStorage ()
{
	NSString *messageEntityName;
	NSString *contactEntityName;
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation XMPPMessageArchivingCoreDataStorage

static XMPPMessageArchivingCoreDataStorage *sharedInstance;

+ (instancetype)sharedInstance
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		
		sharedInstance = [[XMPPMessageArchivingCoreDataStorage alloc] initWithDatabaseFilename:nil storeOptions:nil];
	});
	
	return sharedInstance;
}

/**
 * Documentation from the superclass (XMPPCoreDataStorage):
 * 
 * If your subclass needs to do anything for init, it can do so easily by overriding this method.
 * All public init methods will invoke this method at the end of their implementation.
 * 
 * Important: If overriden you must invoke [super commonInit] at some point.
**/
- (void)commonInit
{
	[super commonInit];
	
	messageEntityName = @"XMPPMessageArchiving_Message_CoreDataObject";
	contactEntityName = @"XMPPMessageArchiving_Contact_CoreDataObject";
}

/**
 * Documentation from the superclass (XMPPCoreDataStorage):
 * 
 * Override me, if needed, to provide customized behavior.
 * For example, you may want to perform cleanup of any non-persistent data before you start using the database.
 * 
 * The default implementation does nothing.
**/
- (void)didCreateManagedObjectContext
{
	// If there are any "composing" messages in the database, delete them (as they are temporary).
	
	NSManagedObjectContext *moc = [self managedObjectContext];
	NSEntityDescription *messageEntity = [self messageEntity:moc];
	
	NSPredicate *predicate = [NSPredicate predicateWithFormat:@"composing == YES"];
	
	NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
	fetchRequest.entity = messageEntity;
	fetchRequest.predicate = predicate;
	fetchRequest.fetchBatchSize = saveThreshold;
	
	NSError *error = nil;
	NSArray *messages = [moc executeFetchRequest:fetchRequest error:&error];
	
	if (messages == nil)
	{
		XMPPLogError(@"%@: %@ - Error executing fetchRequest: %@", [self class], THIS_METHOD, error);
		return;
	}
	
	NSUInteger count = 0;
	
	for (XMPPMessageArchiving_Message_CoreDataObject *message in messages)
	{
		[moc deleteObject:message];
		
		if (++count > saveThreshold)
		{
			if (![moc save:&error])
			{
				XMPPLogWarn(@"%@: Error saving - %@ %@", [self class], error, [error userInfo]);
				[moc rollback];
			}
		}
	}
	
	if (count > 0)
	{
		if (![moc save:&error])
		{
			XMPPLogWarn(@"%@: Error saving - %@ %@", [self class], error, [error userInfo]);
			[moc rollback];
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Internal API
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)willInsertMessage:(XMPPMessageArchiving_Message_CoreDataObject *)message
{
	// Override hook
}

- (void)didUpdateMessage:(XMPPMessageArchiving_Message_CoreDataObject *)message
{
	// Override hook
}

- (void)willDeleteMessage:(XMPPMessageArchiving_Message_CoreDataObject *)message
{
	// Override hook
}

- (void)willInsertContact:(XMPPMessageArchiving_Contact_CoreDataObject *)contact
{
	// Override hook
}

- (void)didUpdateContact:(XMPPMessageArchiving_Contact_CoreDataObject *)contact
{
	// Override hook
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Private API
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (XMPPMessageArchiving_Message_CoreDataObject *)composingMessageWithJid:(XMPPJID *)messageJid
                                                               streamJid:(XMPPJID *)streamJid
                                                                outgoing:(BOOL)isOutgoing
                                                    managedObjectContext:(NSManagedObjectContext *)moc
{
	XMPPMessageArchiving_Message_CoreDataObject *result = nil;
	
	NSEntityDescription *messageEntity = [self messageEntity:moc];
	
	// Order matters:
	// 1. composing - most likely not many with it set to YES in database
	// 2. bareJidStr - splits database by number of conversations
	// 3. outgoing - splits database in half
	// 4. streamBareJidStr - might not limit database at all
	
	NSString *predicateFrmt = @"composing == YES AND bareJidStr == %@ AND outgoing == %@ AND streamBareJidStr == %@";
	NSPredicate *predicate = [NSPredicate predicateWithFormat:predicateFrmt,
                                                            [messageJid bare], @(isOutgoing),
                                                            [streamJid bare]];
	
	NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"timestamp" ascending:NO];
	
	NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
	fetchRequest.entity = messageEntity;
	fetchRequest.predicate = predicate;
	fetchRequest.sortDescriptors = @[sortDescriptor];
	fetchRequest.fetchLimit = 1;
	
	NSError *error = nil;
	NSArray *results = [moc executeFetchRequest:fetchRequest error:&error];
	
	if (results == nil || error)
	{
		XMPPLogError(@"%@: %@ - Error executing fetchRequest: %@", THIS_FILE, THIS_METHOD, fetchRequest);
	}
	else
	{
		result = (XMPPMessageArchiving_Message_CoreDataObject *)[results lastObject];
	}
	
	return result;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Public API
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (XMPPMessageArchiving_Contact_CoreDataObject *)contactForMessage:(XMPPMessageArchiving_Message_CoreDataObject *)msg
{
	// Potential override hook
	
	return [self contactWithBareJidStr:msg.bareJidStr
	                  streamBareJidStr:msg.streamBareJidStr
	              managedObjectContext:msg.managedObjectContext];
}

- (XMPPMessageArchiving_Contact_CoreDataObject *)contactWithJid:(XMPPJID *)contactJid
                                                      streamJid:(XMPPJID *)streamJid
                                           managedObjectContext:(NSManagedObjectContext *)moc
{
	return [self contactWithBareJidStr:[contactJid bare]
	                  streamBareJidStr:[streamJid bare]
	              managedObjectContext:moc];
}

- (XMPPMessageArchiving_Contact_CoreDataObject *)contactWithBareJidStr:(NSString *)contactBareJidStr
                                                      streamBareJidStr:(NSString *)streamBareJidStr
                                                  managedObjectContext:(NSManagedObjectContext *)moc
{
	NSEntityDescription *entity = [self contactEntity:moc];
	
	NSPredicate *predicate;
	if (streamBareJidStr)
	{
		predicate = [NSPredicate predicateWithFormat:@"bareJidStr == %@ AND streamBareJidStr == %@",
	                                                              contactBareJidStr, streamBareJidStr];
	}
	else
	{
		predicate = [NSPredicate predicateWithFormat:@"bareJidStr == %@", contactBareJidStr];
	}
	
	NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
	[fetchRequest setEntity:entity];
	[fetchRequest setFetchLimit:1];
	[fetchRequest setPredicate:predicate];
	
	NSError *error = nil;
	NSArray *results = [moc executeFetchRequest:fetchRequest error:&error];
	
	if (results == nil)
	{
		XMPPLogError(@"%@: %@ - Fetch request error: %@", THIS_FILE, THIS_METHOD, error);
		return nil;
	}
	else
	{
		return (XMPPMessageArchiving_Contact_CoreDataObject *)[results lastObject];
	}
}

- (NSString *)messageEntityName
{
	__block NSString *result = nil;
	
	dispatch_block_t block = ^{
		result = messageEntityName;
	};
	
	if (dispatch_get_specific(storageQueueTag))
		block();
	else
		dispatch_sync(storageQueue, block);
	
	return result;
}

- (void)setMessageEntityName:(NSString *)entityName
{
	dispatch_block_t block = ^{
		messageEntityName = entityName;
	};
	
	if (dispatch_get_specific(storageQueueTag))
		block();
	else
		dispatch_async(storageQueue, block);
}

- (NSString *)contactEntityName
{
	__block NSString *result = nil;
	
	dispatch_block_t block = ^{
		result = contactEntityName;
	};
	
	if (dispatch_get_specific(storageQueueTag))
		block();
	else
		dispatch_sync(storageQueue, block);
	
	return result;
}

- (void)setContactEntityName:(NSString *)entityName
{
	dispatch_block_t block = ^{
		contactEntityName = entityName;
	};
	
	if (dispatch_get_specific(storageQueueTag))
		block();
	else
		dispatch_async(storageQueue, block);
}

- (NSEntityDescription *)messageEntity:(NSManagedObjectContext *)moc
{
	// This is a public method, and may be invoked on any queue.
	// So be sure to go through the public accessor for the entity name.
	
	return [NSEntityDescription entityForName:[self messageEntityName] inManagedObjectContext:moc];
}

- (NSEntityDescription *)contactEntity:(NSManagedObjectContext *)moc
{
	// This is a public method, and may be invoked on any queue.
	// So be sure to go through the public accessor for the entity name.
	
	return [NSEntityDescription entityForName:[self contactEntityName] inManagedObjectContext:moc];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Storage Protocol
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)configureWithParent:(XMPPMessageArchiving *)aParent queue:(dispatch_queue_t)queue
{
	return [super configureWithParent:aParent queue:queue];
}

- (void)archiveMessage:(XMPPMessage *)message outgoing:(BOOL)isOutgoing xmppStream:(XMPPStream *)xmppStream
{
	// Message should either have a body, or be a composing notification
	
	NSString *messageBody = [[message elementForName:@"body"] stringValue];
	BOOL isComposing = NO;
	BOOL shouldDeleteComposingMessage = NO;
	
	if ([messageBody length] == 0)
	{
		// Message doesn't have a body.
		// Check to see if it has a chat state (composing, paused, etc).
		
		isComposing = [message hasComposingChatState];
		if (!isComposing)
		{
			if ([message hasChatState])
			{
				// Message has non-composing chat state.
				// So if there is a current composing message in the database,
				// then we need to delete it.
				shouldDeleteComposingMessage = YES;
			}
			else
			{
				// Message has no body and no chat state.
				// Nothing to do with it.
				return;
			}
		}
	}
	
	[self scheduleBlock:^{
		
		NSManagedObjectContext *moc = [self managedObjectContext];
		XMPPJID *myJid = [self myJIDForXMPPStream:xmppStream];
		
		XMPPJID *messageJid = isOutgoing ? [message to] : [message from];
		
		// Fetch-n-Update OR Insert new message
		
		XMPPMessageArchiving_Message_CoreDataObject *archivedMessage =
		    [self composingMessageWithJid:messageJid
		                        streamJid:myJid
		                         outgoing:isOutgoing
		             managedObjectContext:moc];
		
		if (shouldDeleteComposingMessage)
		{
			if (archivedMessage)
			{
				[self willDeleteMessage:archivedMessage]; // Override hook
				[moc deleteObject:archivedMessage];
			}
			else
			{
				// Composing message has already been deleted (or never existed)
			}
		}
		else
		{
			XMPPLogVerbose(@"Previous archivedMessage: %@", archivedMessage);
			
			BOOL didCreateNewArchivedMessage = NO;
			if (archivedMessage == nil)
			{
				archivedMessage = (XMPPMessageArchiving_Message_CoreDataObject *)
					[[NSManagedObject alloc] initWithEntity:[self messageEntity:moc]
				             insertIntoManagedObjectContext:nil];
				
				didCreateNewArchivedMessage = YES;
			}
			
			archivedMessage.message = message;
			archivedMessage.body = messageBody;
			
			archivedMessage.bareJid = [messageJid bareJID];
			archivedMessage.streamBareJidStr = [myJid bare];
			
			NSDate *timestamp = [message delayedDeliveryDate];
			if (timestamp)
				archivedMessage.timestamp = timestamp;
			else
				archivedMessage.timestamp = [[NSDate alloc] init];
			
			archivedMessage.thread = [[message elementForName:@"thread"] stringValue];
			archivedMessage.isOutgoing = isOutgoing;
			archivedMessage.isComposing = isComposing;
			
			XMPPLogVerbose(@"New archivedMessage: %@", archivedMessage);
														 
			if (didCreateNewArchivedMessage) // [archivedMessage isInserted] doesn't seem to work
			{
				XMPPLogVerbose(@"Inserting message...");
				
				[archivedMessage willInsertObject];       // Override hook
				[self willInsertMessage:archivedMessage]; // Override hook
				[moc insertObject:archivedMessage];
			}
			else
			{
				XMPPLogVerbose(@"Updating message...");
				
				[archivedMessage didUpdateObject];       // Override hook
				[self didUpdateMessage:archivedMessage]; // Override hook
			}
			
			// Create or update contact (if message with actual content)
			
			if ([messageBody length] > 0)
			{
				BOOL didCreateNewContact = NO;
				
				XMPPMessageArchiving_Contact_CoreDataObject *contact = [self contactForMessage:archivedMessage];
				XMPPLogVerbose(@"Previous contact: %@", contact);
				
				if (contact == nil)
				{
					contact = (XMPPMessageArchiving_Contact_CoreDataObject *)
					    [[NSManagedObject alloc] initWithEntity:[self contactEntity:moc]
					             insertIntoManagedObjectContext:nil];
					
					didCreateNewContact = YES;
				}
				
				contact.streamBareJidStr = archivedMessage.streamBareJidStr;
				contact.bareJid = archivedMessage.bareJid;
					
				contact.mostRecentMessageTimestamp = archivedMessage.timestamp;
				contact.mostRecentMessageBody = archivedMessage.body;
				contact.mostRecentMessageOutgoing = @(isOutgoing);
				
				XMPPLogVerbose(@"New contact: %@", contact);
				
				if (didCreateNewContact) // [contact isInserted] doesn't seem to work
				{
					XMPPLogVerbose(@"Inserting contact...");
					
					[contact willInsertObject];       // Override hook
					[self willInsertContact:contact]; // Override hook
					[moc insertObject:contact];
				}
				else
				{
					XMPPLogVerbose(@"Updating contact...");
					
					[contact didUpdateObject];       // Override hook
					[self didUpdateContact:contact]; // Override hook
				}
			}
		}
	}];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Oasis
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (XMPPMessageArchiving_Contact_CoreDataObject *)oa_recentContactWithUsername:(NSString *)username
                                                             streamBareJidStr:(NSString *)streamBareJidStr
                                                         managedObjectContext:(NSManagedObjectContext *)moc {
    NSEntityDescription *entity = [self contactEntity:moc];
    
    NSPredicate *predicate;
    
    if (streamBareJidStr) {
        predicate = [NSPredicate predicateWithFormat:@"username == %@ AND streamBareJidStr == %@", username, streamBareJidStr];
    } else {
        predicate = [NSPredicate predicateWithFormat:@"username == %@", username];
    }
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    [fetchRequest setEntity:entity];
    [fetchRequest setFetchLimit:1];
    [fetchRequest setPredicate:predicate];
    
    NSError *error = nil;
    NSArray *results = [moc executeFetchRequest:fetchRequest error:&error];
    
    if (results == nil)
    {
        XMPPLogError(@"%@: %@ - Fetch request error: %@", THIS_FILE, THIS_METHOD, error);
        return nil;
    }
    else
    {
        return (XMPPMessageArchiving_Contact_CoreDataObject *)[results lastObject];
    }
}

- (void)oa_markRecentContactMessageWithId:(id)managedObjId asRead:(BOOL)read {
    [self executeBlock:^{
        NSManagedObject *mObj = [[self managedObjectContext] objectWithID:managedObjId];
        [mObj setValue:[NSNumber numberWithBool:read] forKey:@"isRead"];
    }];
}

- (void)oa_deleteRecentContactMessageWithUsername:(NSString *)username
                                 streamBareJidStr:(NSString *)streamBareJidStr {
    [self executeBlock:^{
        XMPPMessageArchiving_Contact_CoreDataObject *recentContact = [self oa_recentContactWithUsername:username
                                                                                       streamBareJidStr:streamBareJidStr
                                                                                   managedObjectContext:[self managedObjectContext]];
        [[self managedObjectContext] deleteObject:recentContact];
    }];
}

- (void)oa_archiveMessage:(XMPPMessage *)message
                timestamp:(NSDate *)timestamp
                 outgoing:(BOOL)isOutgoing
                   isRead:(BOOL)read
             updateRecent:(BOOL)updateRecentFlag
              saveMessage:(BOOL)saveMessageFlag
               xmppStream:(XMPPStream *)xmppStream {
    
    // Message should either have a body, or be a composing notification
    
    NSString *messageBody = [[message elementForName:@"body"] stringValue];
    BOOL isComposing = NO;
    BOOL shouldDeleteComposingMessage = NO;
    OAXMPPMessageType msgType = OAXMPPMessageTypeText;
    
    if ([messageBody length] == 0)
    {
        // Message doesn't have a body.
        // Check to see if it has a chat state (composing, paused, etc).
        
        isComposing = [message hasComposingChatState];
        if (!isComposing)
        {
            if ([message hasChatState])
            {
                // Message has non-composing chat state.
                // So if there is a current composing message in the database,
                // then we need to delete it.
                shouldDeleteComposingMessage = YES;
            }
            else
            {
                if ([message oa_isPhotoMessage])
                {
                    msgType = OAXMPPMessageTypePhoto;
                }
                else if ([message oa_isSystemMessage])
                {
                    msgType = OAXMPPMessageTypeSystem;
                }
                else
                {
                    // Message has no body and no chat state.
                    // Nothing to do with it.
                    return;
                }
            }
        }
    }
    
    [self scheduleBlock:^{
        
        NSManagedObjectContext *moc = [self managedObjectContext];
        XMPPJID *myJid = [self myJIDForXMPPStream:xmppStream];
        
        XMPPJID *messageJid = nil;
        NSString *username = nil;
        NSString *jidOrUsername = isOutgoing ? [message toStr] : [message fromStr];
        
        if ([jidOrUsername rangeOfString:@"@"].location != NSNotFound)
        {
            messageJid = [XMPPJID jidWithString: jidOrUsername];
            username = messageJid.user;
        } else {
            username = jidOrUsername;
        }
        
        // check if the message has proper jid, fetch conversation list will skip this
        if (messageJid) {
            
            // Fetch-n-Update OR Insert new message
            
            XMPPMessageArchiving_Message_CoreDataObject *archivedMessage =
            [self composingMessageWithJid:messageJid
                                streamJid:myJid
                                 outgoing:isOutgoing
                     managedObjectContext:moc];
            
            if (shouldDeleteComposingMessage)
            {
                if (archivedMessage)
                {
                    [self willDeleteMessage:archivedMessage]; // Override hook
                    [moc deleteObject:archivedMessage];
                }
                else
                {
                    // Composing message has already been deleted (or never existed)
                }
                return;
            }
            else
            {
                if (saveMessageFlag) {
                    XMPPLogVerbose(@"Previous archivedMessage: %@", archivedMessage);
                    
                    BOOL didCreateNewArchivedMessage = NO;
                    if (archivedMessage == nil)
                    {
                        archivedMessage = (XMPPMessageArchiving_Message_CoreDataObject *)
                        [[NSManagedObject alloc] initWithEntity:[self messageEntity:moc]
                                 insertIntoManagedObjectContext:nil];
                        
                        didCreateNewArchivedMessage = YES;
                    }
                    
                    archivedMessage.message = message;
                    if (msgType == OAXMPPMessageTypePhoto) {
                        archivedMessage.body = [message oa_photoMessageContent];
                    } else if (msgType == OAXMPPMessageTypeSystem) {
                        archivedMessage.body = [message oa_systemMessageContent];
                    } else {
                        archivedMessage.body = messageBody;
                    }
                    
                    archivedMessage.messageType = msgType;
                    
                    archivedMessage.bareJid = [messageJid bareJID];
                    archivedMessage.streamBareJidStr = [myJid bare];
                    
                    if (timestamp) {
                        archivedMessage.timestamp = timestamp;
                    } else {
                        NSDate *timestamp = [message delayedDeliveryDate];
                        if (timestamp)
                            archivedMessage.timestamp = timestamp;
                        else
                            archivedMessage.timestamp = [[NSDate alloc] init];
                    }
                    
                    archivedMessage.thread = [[message elementForName:@"thread"] stringValue];
                    archivedMessage.isOutgoing = isOutgoing;
                    archivedMessage.isComposing = isComposing;
                    
                    XMPPLogVerbose(@"New archivedMessage: %@", archivedMessage);
                    
                    if (didCreateNewArchivedMessage) // [archivedMessage isInserted] doesn't seem to work
                    {
                        XMPPLogVerbose(@"Inserting message...");
                        
                        [archivedMessage willInsertObject];       // Override hook
                        [self willInsertMessage:archivedMessage]; // Override hook
                        [moc insertObject:archivedMessage];
                    }
                    else
                    {
                        XMPPLogVerbose(@"Updating message...");
                        
                        [archivedMessage didUpdateObject];       // Override hook
                        [self didUpdateMessage:archivedMessage]; // Override hook
                    }
                }
            }

        }
        
        // Create or update contact (if message with actual content)
//        if (([messageBody length] > 0 || msgType == OAXMPPMessageTypePhoto || msgType == OAXMPPMessageTypeSystem)
//            && updateRecentFlag)
        if (updateRecentFlag && (message.isChatMessage && msgType != OAXMPPMessageTypeOthers))
        {
            BOOL didCreateNewContact = NO;
            
            // use username rather than jid to find the recent contact
            // because the conversation list doesn't return jid
            XMPPMessageArchiving_Contact_CoreDataObject *contact = [self oa_recentContactWithUsername:username
                                                                                     streamBareJidStr:myJid.bare
                                                                                 managedObjectContext:moc];
            
            if ([message wasDelayed]) {
                // earlier delayed message shouldn't override later delayed message in conversation list
                NSComparisonResult *result = [contact.mostRecentMessageTimestamp compare:[message delayedDeliveryDate]];
                if (result == NSOrderedDescending || result == NSOrderedSame) {
                    return;
                }
            }
            
            XMPPLogVerbose(@"Previous contact: %@", contact);
            
            if (contact == nil)
            {
                contact = (XMPPMessageArchiving_Contact_CoreDataObject *)
                [[NSManagedObject alloc] initWithEntity:[self contactEntity:moc]
                         insertIntoManagedObjectContext:nil];
                
                didCreateNewContact = YES;
            }
            
            contact.streamBareJidStr = myJid.bare;
            if (messageJid)
            {
                contact.bareJid = messageJid;
                contact.username = messageJid.user;
            } else {
                contact.username = username;
            }
            
            if (timestamp)
            {
                contact.mostRecentMessageTimestamp = timestamp;
            }
            else
            {
                if ([message wasDelayed]) {
                    contact.mostRecentMessageTimestamp = [message delayedDeliveryDate];
                }
                else
                {
                    contact.mostRecentMessageTimestamp = [[NSDate alloc] init];
                }
            }
            
            if (msgType == OAXMPPMessageTypePhoto) {
                contact.mostRecentMessageBody = @"[image]";
            } else if (msgType == OAXMPPMessageTypeSystem) {
                contact.mostRecentMessageBody = [message oa_systemMessageContent];
            } else {
                contact.mostRecentMessageBody = messageBody;
            }
            
            contact.mostRecentMessageOutgoing = [NSNumber numberWithBool:isOutgoing];
            contact.isRead = [NSNumber numberWithBool:read];
            
            XMPPLogVerbose(@"New contact: %@", contact);
            
            if (didCreateNewContact) // [contact isInserted] doesn't seem to work
            {
                XMPPLogVerbose(@"Inserting contact...");
                
                [contact willInsertObject];       // Override hook
                [self willInsertContact:contact]; // Override hook
                [moc insertObject:contact];
            }
            else
            {
                XMPPLogVerbose(@"Updating contact...");
                
                [contact didUpdateObject];       // Override hook
                [self didUpdateContact:contact]; // Override hook
            }
        }
    }];

}

- (void)oa_removeOldArchivedMessagesWithJid:(NSString *)bareJid streamJidStr:(NSString *)streamJid {
    [self scheduleBlock:^{
        NSManagedObjectContext *moc = [self managedObjectContext];
        
        NSFetchRequest *fetchArchivedMessagesRequest = [[NSFetchRequest alloc] init];
        fetchArchivedMessagesRequest.entity = [NSEntityDescription entityForName:@"XMPPMessageArchiving_Message_CoreDataObject" inManagedObjectContext:moc];
        fetchArchivedMessagesRequest.predicate = [NSPredicate predicateWithFormat:@"bareJidStr == %@ && streamBareJidStr == %@", bareJid, streamJid];
        fetchArchivedMessagesRequest.includesPropertyValues = NO;
        
        NSError *error = nil;
        NSArray *allMessages = [moc executeFetchRequest:fetchArchivedMessagesRequest error:&error];
        
//        NSUInteger unsavedCount = [self numberOfUnsavedChanges];
        
        for (NSManagedObject *msg in allMessages) {
            [moc deleteObject: msg];
            
//            if (++unsavedCount >= saveThreshold) {
//                [self save];
//                unsavedCount = 0;
//            }
        }
    }];
}

- (void)oa_removeOldRecentContactListWithStreamJidStr:(NSString *)streamJid {
    [self scheduleBlock:^{
        NSManagedObjectContext *moc = [self managedObjectContext];
        
        NSFetchRequest *fetchRecentChatsRequest = [[NSFetchRequest alloc] init];
        fetchRecentChatsRequest.entity = [NSEntityDescription entityForName:@"XMPPMessageArchiving_Contact_CoreDataObject" inManagedObjectContext:moc];
        fetchRecentChatsRequest.predicate = [NSPredicate predicateWithFormat:@"streamBareJidStr == %@", streamJid];
        fetchRecentChatsRequest.includesPropertyValues = NO;
        
        NSError *error = nil;
        NSArray *allRecentChats = [moc executeFetchRequest:fetchRecentChatsRequest error:&error];
        
//        NSUInteger unsavedCount = [self numberOfUnsavedChanges];
        
        for (NSManagedObject *chat in allRecentChats) {
            [moc deleteObject: chat];
            
//            if (++unsavedCount >= saveThreshold) {
//                [self save];
//                unsavedCount = 0;
//            }
        }
    }];
}

@end
