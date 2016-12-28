#import <Foundation/Foundation.h>

#import "XMPPCoreDataStorage.h"
#import "XMPPMessageArchiving.h"
#import "XMPPMessageArchiving_Message_CoreDataObject.h"
#import "XMPPMessageArchiving_Contact_CoreDataObject.h"


@interface XMPPMessageArchivingCoreDataStorage : XMPPCoreDataStorage <XMPPMessageArchivingStorage>
{
	/* Inherited protected variables from XMPPCoreDataStorage
	
	NSString *databaseFileName;
	NSUInteger saveThreshold;
	
	dispatch_queue_t storageQueue;
	 
	*/
}

/**
 * Convenience method to get an instance with the default database name.
 * 
 * IMPORTANT:
 * You are NOT required to use the sharedInstance.
 * 
 * If your application uses multiple xmppStreams, and you use a sharedInstance of this class,
 * then all of your streams share the same database store. You might get better performance if you create
 * multiple instances of this class instead (using different database filenames), as this way you can have
 * concurrent writes to multiple databases.
**/
+ (instancetype)sharedInstance;


@property (strong) NSString *messageEntityName;
@property (strong) NSString *contactEntityName;

- (NSEntityDescription *)messageEntity:(NSManagedObjectContext *)moc;
- (NSEntityDescription *)contactEntity:(NSManagedObjectContext *)moc;

- (XMPPMessageArchiving_Contact_CoreDataObject *)contactForMessage:(XMPPMessageArchiving_Message_CoreDataObject *)msg;

- (XMPPMessageArchiving_Contact_CoreDataObject *)contactWithJid:(XMPPJID *)contactJid
                                                      streamJid:(XMPPJID *)streamJid
                                           managedObjectContext:(NSManagedObjectContext *)moc;

- (XMPPMessageArchiving_Contact_CoreDataObject *)contactWithBareJidStr:(NSString *)contactBareJidStr
                                                      streamBareJidStr:(NSString *)streamBareJidStr
                                                  managedObjectContext:(NSManagedObjectContext *)moc;

// oasis <

- (XMPPMessageArchiving_Contact_CoreDataObject *)oa_recentContactWithUsername:(NSString *)username
                                                             streamBareJidStr:(NSString *)streamBareJidStr
                                                         managedObjectContext:(NSManagedObjectContext *)moc;

- (XMPPMessageArchiving_Message_CoreDataObject *)oa_messageWithMessageId:(NSString *)messageId
                                                        streamBareJidStr:(NSString *)streamBareJidStr
                                                    managedObjectContext:(NSManagedObjectContext *)moc;

- (void)oa_updateUnreadCount:(NSInteger)unreadCount forRecentContactWithId:(id)managedObjId;

- (void)oa_deleteRecentContactMessageWithUsername:(NSString *)username
                                 streamBareJidStr:(NSString *)streamBareJidStr;

- (void)oa_markAsReadForMessageWithMessageId:(NSString *)messageId
                            streamBareJidStr:(NSString *)streamBareJidStr;

// oasis >

/* Inherited from XMPPCoreDataStorage
 * Please see the XMPPCoreDataStorage header file for extensive documentation.
 
- (id)initWithDatabaseFilename:(NSString *)databaseFileName storeOptions:(NSDictionary *)storeOptions;
- (id)initWithInMemoryStore;

@property (readonly) NSString *databaseFileName;
 
@property (readwrite) NSUInteger saveThreshold;

@property (readonly) NSManagedObjectModel *managedObjectModel;
@property (readonly) NSPersistentStoreCoordinator *persistentStoreCoordinator;

@property (readonly) NSManagedObjectContext *mainThreadManagedObjectContext;
 
*/

@end
