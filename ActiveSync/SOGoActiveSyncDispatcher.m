/*

Copyright (c) 2014, Inverse inc.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the Inverse inc. nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

*/
#include "SOGoActiveSyncDispatcher.h"

#import <Foundation/NSArray.h>
#import <Foundation/NSCalendarDate.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/NSTimeZone.h>
#import <Foundation/NSURL.h>

#import <NGObjWeb/NSException+HTTP.h>
#import <NGObjWeb/SoApplication.h>
#import <NGObjWeb/SoObject.h>
#import <NGObjWeb/WOContext.h>
#import <NGObjWeb/WOContext+SoObjects.h>
#import <NGObjWeb/WOCookie.h>
#import <NGObjWeb/WODirectAction.h>
#import <NGObjWeb/WORequest.h>
#import <NGObjWeb/WOResponse.h>


#import <NGCards/iCalEntityObject.h>
#import <NGCards/iCalEvent.h>
#import <NGCards/iCalToDo.h>
#import <NGCards/NGVCard.h>

#import <NGExtensions/NGBase64Coding.h>
#import <NGExtensions/NSCalendarDate+misc.h>
#import <NGExtensions/NGCalendarDateRange.h>
#import <NGExtensions/NGHashMap.h>
#import <NGExtensions/NSString+misc.h>

#import <NGImap4/NGImap4Client.h>
#import <NGImap4/NGImap4Connection.h>
#import <NGImap4/NSString+Imap4.h>

#import <NGMime/NGMimeBodyPart.h>
#import <NGMime/NGMimeMultipartBody.h>
#import <NGMail/NGMimeMessageParser.h>
#import <NGMail/NGMimeMessage.h>
#import <NGMail/NGMimeMessageGenerator.h>

#import <DOM/DOMElement.h>
#import <DOM/DOMProtocols.h>
#import <DOM/DOMSaxBuilder.h>

#import <EOControl/EOQualifier.h>

#import <SOGo/NSArray+DAV.h>
#import <SOGo/NSDictionary+DAV.h>
#import <SOGo/SOGoDAVAuthenticator.h>
#import <SOGo/SOGoDomainDefaults.h>
#import <SOGo/SOGoMailer.h>
#import <SOGo/SOGoUser.h>
#import <SOGo/SOGoUserFolder.h>
#import <SOGo/SOGoUserManager.h>
#import <SOGo/SOGoUserSettings.h>

#import <Appointments/SOGoAppointmentFolder.h>
#import <Appointments/SOGoAppointmentFolders.h>

#import <Contacts/SOGoContactGCSFolder.h>
#import <Contacts/SOGoContactFolders.h>
#import <Contacts/SOGoContactObject.h>
#import <Contacts/SOGoContactSourceFolder.h>

#import <Mailer/SOGoMailAccount.h>
#import <Mailer/SOGoMailAccounts.h>
#import <Mailer/SOGoMailBodyPart.h>
#import <Mailer/SOGoMailFolder.h>
#import <Mailer/SOGoMailObject.h>

#import <Foundation/NSObject.h>
#import <Foundation/NSString.h>

#include "iCalEvent+ActiveSync.h"
#include "iCalToDo+ActiveSync.h"
#include "NGMimeMessage+ActiveSync.h"
#include "NGVCard+ActiveSync.h"
#include "NSCalendarDate+ActiveSync.h"
#include "NSData+ActiveSync.h"
#include "NSDate+ActiveSync.h"
#include "NSString+ActiveSync.h"
#include "SOGoActiveSyncConstants.h"
#include "SOGoMailObject+ActiveSync.h"

@implementation SOGoActiveSyncDispatcher

- (void) _setFolderSyncKey: (NSString *) theSyncKey
{
  NSMutableDictionary *metadata;
  
  metadata = [[[context activeUser] userSettings] microsoftActiveSyncMetadataForDevice: [context objectForKey: @"DeviceId"]];
  
  [metadata setObject: [NSDictionary dictionaryWithObject: theSyncKey  forKey: @"SyncKey"]  forKey: @"FolderSync"];

  [[[context activeUser] userSettings] setMicrosoftActiveSyncMetadata: metadata
                                                               forDevice: [context objectForKey: @"DeviceId"]];

  [[[context activeUser] userSettings] synchronize];
}

//
//
//
- (void) processFolderCreate: (id <DOMElement>) theDocumentElement
                  inResponse: (WOResponse *) theResponse
{
  NSString *parentId, *displayName, *nameInContainer, *syncKey;
  SOGoUserFolder *userFolder;
  NSMutableString *s;
  NSData *d;

  int type;

  parentId = [[(id)[theDocumentElement getElementsByTagName: @"ParentId"] lastObject] textValue];
  displayName = [[(id)[theDocumentElement getElementsByTagName: @"DisplayName"] lastObject] textValue];
  type = [[[(id)[theDocumentElement getElementsByTagName: @"Type"] lastObject] textValue] intValue];
  userFolder = [[context activeUser] homeFolderInContext: context];

  // See 2.2.3.170.2 Type (FolderCreate) - http://msdn.microsoft.com/en-us/library/gg675445(v=exchg.80).aspx
  // We support the following types:
  //
  // 12 User-created mail folder
  // 13 User-created Calendar folder
  // 14 User-created Contacts folder
  // 15 User-created Tasks folder
  //
  switch (type)
    {
    case 12:
      {
        SOGoMailAccounts *accountsFolder;
        SOGoMailFolder *newFolder;
        id currentFolder;
        
        accountsFolder = [userFolder lookupName: @"Mail"  inContext: context  acquire: NO];
        currentFolder = [accountsFolder lookupName: @"0"  inContext: context  acquire: NO];
        
        newFolder = [currentFolder lookupName: [NSString stringWithFormat: @"folder%@", [displayName stringByEncodingImap4FolderName]]
                                    inContext: context
                                      acquire: NO];
        
        // FIXME
        // handle exists (status == 2)
        // handle right synckey
        if ([newFolder create])
          {
            nameInContainer = [newFolder nameInContainer];
            
            // We strip the "folder" prefix
            nameInContainer = [nameInContainer substringFromIndex: 6];
            nameInContainer = [[NSString stringWithFormat: @"mail/%@", nameInContainer] stringByEscapingURL];
          }
        else
          {
            [theResponse setStatus: 500];
            [theResponse appendContentString: @"Unable to create folder."];
            return;
          }
      }
      break;
    case 13:
    case 15:
      {
        SOGoAppointmentFolders *appointmentFolders;

        appointmentFolders = [userFolder privateCalendars: @"Calendar" inContext: context];
        [appointmentFolders newFolderWithName: displayName
                              nameInContainer: &nameInContainer];
        if (type == 13)
          nameInContainer = [NSString stringWithFormat: @"vevent/%@", nameInContainer];
        else
          nameInContainer = [NSString stringWithFormat: @"vtodo/%@", nameInContainer];
      }
      break;
    case 14:
      {
        SOGoContactFolders *contactFolders;
        
        contactFolders = [userFolder privateContacts: @"Contacts" inContext: context];
        [contactFolders newFolderWithName: displayName
                          nameInContainer: &nameInContainer];
        nameInContainer = [NSString stringWithFormat: @"vcard/%@", nameInContainer];
      }
      break;
    default:
      {
        [theResponse setStatus: 500];
        [theResponse appendContentString: @"Unsupported folder type during creation."];
        return;
      }
    } // switch (type) ...

  //
  // We update the FolderSync's synckey
  // 
  syncKey = [[NSProcessInfo processInfo] globallyUniqueString];

  [self _setFolderSyncKey: syncKey];

  // All good, we send our response. The format is documented here:
  // 6.7 FolderCreate Response Schema - http://msdn.microsoft.com/en-us/library/dn338950(v=exchg.80).aspx  
  //
  s = [NSMutableString string];
  [s appendString: @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
  [s appendString: @"<!DOCTYPE ActiveSync PUBLIC \"-//MICROSOFT//DTD ActiveSync//EN\" \"http://www.microsoft.com/\">"];
  [s appendString: @"<FolderCreate xmlns=\"FolderHierarchy:\">"];
  [s appendFormat: @"<Status>%d</Status>", 1];
  [s appendFormat: @"<SyncKey>%@</SyncKey>", syncKey];
  [s appendFormat: @"<ServerId>%@</ServerId>", nameInContainer];
  [s appendString: @"</FolderCreate>"];
  
  d = [[s dataUsingEncoding: NSUTF8StringEncoding] xml2wbxml];
  
  [theResponse setContent: d];
}

//
//
//
- (void) processFolderDelete: (id <DOMElement>) theDocumentElement
                  inResponse: (WOResponse *) theResponse
{
  SOGoMailAccounts *accountsFolder;
  SOGoMailFolder *folderToDelete;
  SOGoUserFolder *userFolder;
  id currentFolder;
  NSException *error;
  NSString *serverId;
      
  SOGoMicrosoftActiveSyncFolderType folderType;

  
  serverId = [[[(id)[theDocumentElement getElementsByTagName: @"ServerId"] lastObject] textValue] realCollectionIdWithFolderType: &folderType];

  userFolder = [[context activeUser] homeFolderInContext: context];
  accountsFolder = [userFolder lookupName: @"Mail"  inContext: context  acquire: NO];
  currentFolder = [accountsFolder lookupName: @"0"  inContext: context  acquire: NO];
  
  folderToDelete = [currentFolder lookupName: [NSString stringWithFormat: @"folder%@", serverId]
                                   inContext: context
                                     acquire: NO];

  error = [folderToDelete delete];

  if (!error)
    {
      NSMutableString *s;
      NSString *syncKey;
      NSData *d;
      
      //
      // We update the FolderSync's synckey
      // 
      syncKey = [[NSProcessInfo processInfo] globallyUniqueString];
      
      [self _setFolderSyncKey: syncKey];

      s = [NSMutableString string];
      [s appendString: @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
      [s appendString: @"<!DOCTYPE ActiveSync PUBLIC \"-//MICROSOFT//DTD ActiveSync//EN\" \"http://www.microsoft.com/\">"];
      [s appendString: @"<FolderDelete xmlns=\"FolderHierarchy:\">"];
      [s appendFormat: @"<Status>%d</Status>", 1];
      [s appendFormat: @"<SyncKey>%@</SyncKey>", syncKey];
      [s appendString: @"</FolderDelete>"];
      
      d = [[s dataUsingEncoding: NSUTF8StringEncoding] xml2wbxml];
      
      [theResponse setContent: d];
    }
  else
    {
      [theResponse setStatus: 500];
      [theResponse appendContentString: @"Unable to delete folder."];
    }
}

//
//
//
- (void) processFolderUpdate: (id <DOMElement>) theDocumentElement
                  inResponse: (WOResponse *) theResponse
{
  NSString *serverId, *parentId, *displayName;
  SOGoMailAccounts *accountsFolder;
  SOGoUserFolder *userFolder;
  SOGoMailFolder *folderToUpdate;
  id currentFolder;
  NSException *error;
      
  SOGoMicrosoftActiveSyncFolderType folderType;
  int status;
  
  serverId = [[[(id)[theDocumentElement getElementsByTagName: @"ServerId"] lastObject] textValue] realCollectionIdWithFolderType: &folderType];
  parentId = [[(id)[theDocumentElement getElementsByTagName: @"ParentId"] lastObject] textValue];
  displayName = [[(id)[theDocumentElement getElementsByTagName: @"DisplayName"] lastObject] textValue];

  userFolder = [[context activeUser] homeFolderInContext: context];
  accountsFolder = [userFolder lookupName: @"Mail"  inContext: context  acquire: NO];
  currentFolder = [accountsFolder lookupName: @"0"  inContext: context  acquire: NO];
  
  folderToUpdate = [currentFolder lookupName: [NSString stringWithFormat: @"folder%@", serverId]
                                   inContext: context
                                     acquire: NO];

  error = [folderToUpdate renameTo: displayName];

  // Handle new name exist
  if (!error)
    {
      NSMutableString *s;
      NSString *syncKey;
      NSData *d;
      
      //
      // We update the FolderSync's synckey
      // 
      syncKey = [[NSProcessInfo processInfo] globallyUniqueString];

      // See http://msdn.microsoft.com/en-us/library/gg675615(v=exchg.80).aspx
      // we return '9' - we force a FolderSync
      status = 9;

      [self _setFolderSyncKey: syncKey];

      s = [NSMutableString string];
      [s appendString: @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
      [s appendString: @"<!DOCTYPE ActiveSync PUBLIC \"-//MICROSOFT//DTD ActiveSync//EN\" \"http://www.microsoft.com/\">"];
      [s appendString: @"<FolderUpdate xmlns=\"FolderHierarchy:\">"];
      [s appendFormat: @"<Status>%d</Status>", status];
      [s appendFormat: @"<SyncKey>%@</SyncKey>", syncKey];
      [s appendString: @"</FolderUpdate>"];
      
      d = [[s dataUsingEncoding: NSUTF8StringEncoding] xml2wbxml];
      
      [theResponse setContent: d];
    }
  else
    {
      [theResponse setStatus: 500];
      [theResponse appendContentString: @"Unable to update folder."];
    }
}


//
// <?xml version="1.0"?>
// <!DOCTYPE ActiveSync PUBLIC "-//MICROSOFT//DTD ActiveSync//EN" "http://www.microsoft.com/">
// <FolderSync xmlns="FolderHierarchy:">
//  <SyncKey>0</SyncKey>
// </FolderSync>
//
- (void) processFolderSync: (id <DOMElement>) theDocumentElement
                inResponse: (WOResponse *) theResponse
{
  NSMutableDictionary *metadata;
  NSMutableString *s;
  NSString *syncKey;
  NSData *d;
  
  BOOL first_sync;
  int status;

  metadata = [[[context activeUser] userSettings] microsoftActiveSyncMetadataForDevice: [context objectForKey: @"DeviceId"]];
  syncKey = [[(id)[theDocumentElement getElementsByTagName: @"SyncKey"] lastObject] textValue];
  s = [NSMutableString string];

  first_sync = NO;
  status = 1;

  if ([syncKey isEqualToString: @"0"])
    {
      first_sync = YES;
      syncKey = @"1";
    }
  else if (![syncKey isEqualToString: [[metadata objectForKey: @"FolderSync"] objectForKey: @"SyncKey"]])
    {
      // Synchronization key mismatch or invalid synchronization key
      status = 9;
    }

  [self _setFolderSyncKey: syncKey];

  [s appendString: @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
  [s appendString: @"<!DOCTYPE ActiveSync PUBLIC \"-//MICROSOFT//DTD ActiveSync//EN\" \"http://www.microsoft.com/\">"];
  [s appendFormat: @"<FolderSync xmlns=\"FolderHierarchy:\"><Status>%d</Status><SyncKey>%@</SyncKey><Changes>", status, syncKey];
  
  // Initial sync, let's return the complete folder list
  if (first_sync)
    {
      SOGoMailAccounts *accountsFolder;
      SOGoMailAccount *accountFolder;
      SOGoUserFolder *userFolder;
      id currentFolder;

      NSDictionary *folderMetadata;
      NSArray *allFoldersMetadata;
      NSString *name, *serverId, *parentId;

      int i, type;
      
      userFolder = [[context activeUser] homeFolderInContext: context];
      accountsFolder = [userFolder lookupName: @"Mail"  inContext: context  acquire: NO];
      accountFolder = [accountsFolder lookupName: @"0"  inContext: context  acquire: NO];

      allFoldersMetadata = [accountFolder allFoldersMetadata];

      // See 2.2.3.170.3 Type (FolderSync) - http://msdn.microsoft.com/en-us/library/gg650877(v=exchg.80).aspx
      [s appendFormat: @"<Count>%d</Count>", [allFoldersMetadata count]+3];

      for (i = 0; i < [allFoldersMetadata count]; i++)
        {
          folderMetadata = [allFoldersMetadata objectAtIndex: i];
          serverId = [NSString stringWithFormat: @"mail%@", [folderMetadata objectForKey: @"path"]];
          name = [folderMetadata objectForKey: @"displayName"];
          
          if ([name hasPrefix: @"/"])
            name = [name substringFromIndex: 1];
          
          if ([name hasSuffix: @"/"])
            name = [name substringToIndex: [name length]-2];

          type = [[folderMetadata objectForKey: @"type"] activeSyncFolderType];

          parentId = @"0";

          if ([folderMetadata objectForKey: @"parent"])
            {
              parentId = [NSString stringWithFormat: @"mail%@", [folderMetadata objectForKey: @"parent"]];
              name = [[name pathComponents] lastObject];
            }

          [s appendFormat: @"<Add><ServerId>%@</ServerId><ParentId>%@</ParentId><Type>%d</Type><DisplayName>%@</DisplayName></Add>",
             [serverId stringByEscapingURL],
             [parentId stringByEscapingURL],
             type,
             name];
        }

      // We add the personal calendar - events
      // FIXME: add all calendars
      currentFolder = [[context activeUser] personalCalendarFolderInContext: context];
      name = [NSString stringWithFormat: @"vevent/%@", [currentFolder nameInContainer]];
      [s appendFormat: @"<Add><ServerId>%@</ServerId><ParentId>%@</ParentId><Type>%d</Type><DisplayName>%@</DisplayName></Add>", name, @"0", 8, [currentFolder displayName]];

      // We add the personal calendar - tasks
      // FIXME: add all calendars
      currentFolder = [[context activeUser] personalCalendarFolderInContext: context];
      name = [NSString stringWithFormat: @"vtodo/%@", [currentFolder nameInContainer]];
      [s appendFormat: @"<Add><ServerId>%@</ServerId><ParentId>%@</ParentId><Type>%d</Type><DisplayName>%@</DisplayName></Add>", name, @"0", 7, [currentFolder displayName]];
      
      // We add the personal address book
      // FIXME: add all address books
      currentFolder = [[context activeUser] personalContactsFolderInContext: context];
      name = [NSString stringWithFormat: @"vcard/%@", [currentFolder nameInContainer]];
      [s appendFormat: @"<Add><ServerId>%@</ServerId><ParentId>%@</ParentId><Type>%d</Type><DisplayName>%@</DisplayName></Add>", name, @"0", 9, [currentFolder displayName]];
    }

  [s appendString: @"</Changes></FolderSync>"];

  d = [[s dataUsingEncoding: NSUTF8StringEncoding] xml2wbxml];

  [theResponse setContent: d];
}

//
// From: http://msdn.microsoft.com/en-us/library/ee157980(v=exchg.80).aspx :
//
// <2> Section 2.2.2.6: The GetAttachment command is not supported when the MS-ASProtocolVersion header is set to 14.0 or 14.1
// in the GetAttachment command request. Use the Fetch element of the ItemOperations command instead. For more information about
// the MS-ASProtocolVersion header, see [MS-ASHTTP] section 2.2.1.1.2.4.
//
- (void) processGetAttachment: (id <DOMElement>) theDocumentElement
                   inResponse: (WOResponse *) theResponse
{

}

//
// <?xml version="1.0"?>
// <!DOCTYPE ActiveSync PUBLIC "-//MICROSOFT//DTD ActiveSync//EN" "http://www.microsoft.com/">
// <GetItemEstimate xmlns="GetItemEstimate:">
//  <Collections>
//   <Collection>
//    <SyncKey xmlns="AirSync:">1</SyncKey>
//    <CollectionId>folderINBOX</CollectionId>
//    <Options xmlns="AirSync:">
//     <FilterType>3</FilterType>
//    </Options>
//   </Collection>
//  </Collections>
// </GetItemEstimate>
//
- (void) processGetItemEstimate: (id <DOMElement>) theDocumentElement
                     inResponse: (WOResponse *) theResponse
{
  EOQualifier *notDeletedQualifier, *sinceDateQualifier;
  NSString *collectionId, *realCollectionId;
  id currentFolder, currentCollection;
  SOGoMailAccounts *accountsFolder;
  SOGoUserFolder *userFolder;
  EOAndQualifier *qualifier;
  NSCalendarDate *filter;
  NSMutableString *s;
  NSArray *uids;
  NSData *d;

  SOGoMicrosoftActiveSyncFolderType folderType;
  int status;

  s = [NSMutableString string];
  status = 1;

  collectionId = [[(id)[theDocumentElement getElementsByTagName: @"CollectionId"] lastObject] textValue];
  realCollectionId = [collectionId realCollectionIdWithFolderType: &folderType];


  userFolder = [[context activeUser] homeFolderInContext: context];
  accountsFolder = [userFolder lookupName: @"Mail"  inContext: context  acquire: NO];
  currentFolder = [accountsFolder lookupName: @"0"  inContext: context  acquire: NO];
  
  currentCollection = [currentFolder lookupName: [NSString stringWithFormat: @"folder%@", realCollectionId]
                                      inContext: context
                                        acquire: NO];
  //
  // For IMAP, we simply build a request like this:
  //
  // . UID SORT (SUBJECT) UTF-8 SINCE 1-Jan-2014 NOT DELETED
  // * SORT 124576 124577 124579 124578
  // . OK Completed (4 msgs in 0.000 secs)
  //
  filter = [NSCalendarDate dateFromFilterType: [[(id)[theDocumentElement getElementsByTagName: @"FilterType"] lastObject] textValue]];
  
  notDeletedQualifier =  [EOQualifier qualifierWithQualifierFormat:
                                        @"(not (flags = %@))",
                                      @"deleted"];
  sinceDateQualifier = [EOQualifier qualifierWithQualifierFormat:
                                      @"(DATE >= %@)", filter];
                                                  
  
  qualifier = [[EOAndQualifier alloc] initWithQualifiers: notDeletedQualifier, sinceDateQualifier,
                                                      nil];
  AUTORELEASE(qualifier);
  
  uids = [currentCollection fetchUIDsMatchingQualifier: qualifier
                                          sortOrdering: @"REVERSE ARRIVAL"
                                              threaded: NO];
  
  
  [s appendString: @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
  [s appendString: @"<!DOCTYPE ActiveSync PUBLIC \"-//MICROSOFT//DTD ActiveSync//EN\" \"http://www.microsoft.com/\">"];
  [s appendFormat: @"<GetItemEstimate xmlns=\"GetItemEstimate:\"><Response><Status>%d</Status><Collection>", status];
  
  [s appendString: @"<Class>Email</Class>"];
  [s appendFormat: @"<CollectionId>%@</CollectionId>", collectionId];
  [s appendFormat: @"<Estimate>%d</Estimate>", [uids count]];
  
  [s appendString: @"</Collection></Response></GetItemEstimate>"];

  d = [[s dataUsingEncoding: NSUTF8StringEncoding] xml2wbxml];
  
  [theResponse setContent: d];

}

//
// <?xml version="1.0"?>
// <!DOCTYPE ActiveSync PUBLIC "-//MICROSOFT//DTD ActiveSync//EN" "http://www.microsoft.com/">
// <ItemOperations xmlns="ItemOperations:">
//  <Fetch>
//   <Store>Mailbox</Store>                                      -- http://msdn.microsoft.com/en-us/library/gg663522(v=exchg.80).aspx
//   <FileReference xmlns="AirSyncBase:">2</FileReference>       -- 
//   <Options/>
//  </Fetch>
// </ItemOperations>
//
- (void) processItemOperations: (id <DOMElement>) theDocumentElement
                    inResponse: (WOResponse *) theResponse
{
  NSString *fileReference, *realCollectionId; 
  NSMutableString *s;

  SOGoMicrosoftActiveSyncFolderType folderType;

  fileReference = [[[(id)[theDocumentElement getElementsByTagName: @"FileReference"] lastObject] textValue] stringByUnescapingURL];

  realCollectionId = [fileReference realCollectionIdWithFolderType: &folderType];
  
  if (folderType == ActiveSyncMailFolder)
    {
      id currentFolder, currentCollection, currentBodyPart;
      NSString *folderName, *messageName, *pathToPart;
      SOGoMailAccounts *accountsFolder;
      SOGoUserFolder *userFolder;
      SOGoMailObject *mailObject;
      NSData *d;

      NSRange r1, r2;

      r1 = [realCollectionId rangeOfString: @"/"];
      r2 = [realCollectionId rangeOfString: @"/"  options: 0  range: NSMakeRange(NSMaxRange(r1)+1, [realCollectionId length]-NSMaxRange(r1)-1)];
      
      folderName = [realCollectionId substringToIndex: r1.location];
      messageName = [realCollectionId substringWithRange: NSMakeRange(NSMaxRange(r1), r2.location-r1.location-1)];
      pathToPart = [realCollectionId substringFromIndex: r2.location+1];
      
      userFolder = [[context activeUser] homeFolderInContext: context];
      accountsFolder = [userFolder lookupName: @"Mail"  inContext: context  acquire: NO];
      currentFolder = [accountsFolder lookupName: @"0"  inContext: context  acquire: NO];

      currentCollection = [currentFolder lookupName: [NSString stringWithFormat: @"folder%@", folderName]
                                          inContext: context
                                            acquire: NO];
      
      mailObject = [currentCollection lookupName: messageName  inContext: context  acquire: NO];
      currentBodyPart = [mailObject lookupImap4BodyPartKey: pathToPart  inContext: context];


      s = [NSMutableString string];
      [s appendString: @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
      [s appendString: @"<!DOCTYPE ActiveSync PUBLIC \"-//MICROSOFT//DTD ActiveSync//EN\" \"http://www.microsoft.com/\">"];
      [s appendString: @"<ItemOperations xmlns=\"ItemOperations:\">"];
      [s appendString: @"<Status>1</Status>"];
      [s appendString: @"<Response>"];

      [s appendString: @"<Fetch>"];
      [s appendString: @"<Status>1</Status>"];
      [s appendFormat: @"<FileReference xmlns=\"AirSyncBase:\">%@</FileReference>", [fileReference stringByEscapingURL]];
      [s appendString: @"<Properties>"];

      [s appendFormat: @"<ContentType xmlns=\"AirSyncBase:\">%@/%@</ContentType>", [[currentBodyPart partInfo] objectForKey: @"type"], [[currentBodyPart partInfo] objectForKey: @"subtype"]];
      [s appendFormat: @"<Data>%@</Data>", [[[currentBodyPart fetchBLOB] stringByEncodingBase64] stringByReplacingString: @"\n"  withString: @""]];

      [s appendString: @"</Properties>"];
      [s appendString: @"</Fetch>"];


      [s appendString: @"</Response>"];
      [s appendString: @"</ItemOperations>"];
  
      d = [[s dataUsingEncoding: NSUTF8StringEncoding] xml2wbxml];
      [theResponse setContent: d];
    }
  else
    {
      [theResponse setStatus: 500];
    }
}


//
//
//
- (void) processMeetingResponse: (id <DOMElement>) theDocumentElement
                     inResponse: (WOResponse *) theResponse
{

}


//
// <?xml version="1.0"?>
// <!DOCTYPE ActiveSync PUBLIC "-//MICROSOFT//DTD ActiveSync//EN" "http://www.microsoft.com/">
// <MoveItems xmlns="Move:">
//  <Move>
//   <SrcMsgId>85</SrcMsgId>
//   <SrcFldId>mail/INBOX</SrcFldId>
//   <DstFldId>mail/toto</DstFldId>
//  </Move>
// </MoveItems>
//
- (void) processMoveItems: (id <DOMElement>) theDocumentElement
               inResponse: (WOResponse *) theResponse
{
  NSString *srcMessageId, *srcFolderId, *dstFolderId, *dstMessageId;
  SOGoMicrosoftActiveSyncFolderType srcFolderType, dstFolderType;
  
  srcMessageId = [[(id)[theDocumentElement getElementsByTagName: @"SrcMsgId"] lastObject] textValue];
  srcFolderId = [[[(id)[theDocumentElement getElementsByTagName: @"SrcFldId"] lastObject] textValue] realCollectionIdWithFolderType: &srcFolderType];
  dstFolderId = [[[(id)[theDocumentElement getElementsByTagName: @"DstFldId"] lastObject] textValue] realCollectionIdWithFolderType: &dstFolderType];

  // FIXME
  if (srcFolderType == ActiveSyncMailFolder && dstFolderType == ActiveSyncMailFolder)
    {
      SOGoMailAccounts *accountsFolder;
      SOGoMailFolder *currentFolder;
      SOGoUserFolder *userFolder;
      NGImap4Client *client;
      id currentCollection;

      NSDictionary *response;
      NSString *v;

      userFolder = [[context activeUser] homeFolderInContext: context];
      accountsFolder = [userFolder lookupName: @"Mail"  inContext: context  acquire: NO];
      currentFolder = [accountsFolder lookupName: @"0"  inContext: context  acquire: NO];
      
      currentCollection = [currentFolder lookupName: [NSString stringWithFormat: @"folder%@", srcFolderId]
                                          inContext: context
                                            acquire: NO];

      client = [[currentCollection imap4Connection] client];
      [client select: srcFolderId];
      response = [client copyUid: [srcMessageId intValue]
                        toFolder: [NSString stringWithFormat: @"/%@", dstFolderId]];

      // We extract the destionation message id
      dstMessageId = nil;

      if ([[response objectForKey: @"result"] boolValue]
          && (v = [[[response objectForKey: @"RawResponse"] objectForKey: @"ResponseResult"] objectForKey: @"flag"])
          && [v hasPrefix: @"COPYUID "])
        {
          dstMessageId = [[v componentsSeparatedByString: @" "] lastObject];

          // We mark the original message as deleted
          response = [client storeFlags: [NSArray arrayWithObject: @"Deleted"]
                                forUIDs: [NSArray arrayWithObject: srcMessageId]
                            addOrRemove: YES];

          if ([[response valueForKey: @"result"] boolValue])
            [currentCollection markForExpunge];

        }

      if (!dstMessageId)
        {
          [theResponse setStatus: 500];
          [theResponse appendContentString: @"Unable to move message"];
        }
      else
        {
          NSMutableString *s;
          NSData *d;
          
          // Everything is alright, lets return the proper response
          s = [NSMutableString string];
          
          [s appendString: @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
          [s appendString: @"<!DOCTYPE ActiveSync PUBLIC \"-//MICROSOFT//DTD ActiveSync//EN\" \"http://www.microsoft.com/\">"];
          [s appendString: @"<MoveItems xmlns=\"Move:\">"];
          [s appendFormat: @"<SrcMsgId>%@</SrcMsgId>", srcMessageId];
          [s appendFormat: @"<DstMsgId>%@</DstMsgId>", dstMessageId];
          [s appendFormat: @"<Status>%d</Status>", 1];
          [s appendString: @"</MoveItems>"];
          
          d = [[s dataUsingEncoding: NSUTF8StringEncoding] xml2wbxml];
          
          [theResponse setContent: d];
        }
    }
  else
    {
      [theResponse setStatus: 500];
      [theResponse appendContentString: @"Unsupported move operation"];
    }
}

//
// We ignore everything for now
//
- (void) processPing: (id <DOMElement>) theDocumentElement
          inResponse: (WOResponse *) theResponse
{
  NSMutableString *s;
  NSData *d;
  
  s = [NSMutableString string];
  [s appendString: @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
  [s appendString: @"<!DOCTYPE ActiveSync PUBLIC \"-//MICROSOFT//DTD ActiveSync//EN\" \"http://www.microsoft.com/\">"];
  [s appendString: @"<Ping xmlns=\"Ping:\">"];
  [s appendFormat: @"<Status>1</Status>"];
  [s appendString: @"</Ping>"];
  
  d = [[s dataUsingEncoding: NSUTF8StringEncoding] xml2wbxml];
  
  [theResponse setContent: d];
}

//
// <?xml version="1.0"?>
// <!DOCTYPE ActiveSync PUBLIC "-//MICROSOFT//DTD ActiveSync//EN" "http://www.microsoft.com/">
// <ResolveRecipients xmlns="ResolveRecipients:">
//  <To>sogo1@example.com</To>
//  <To>sogo10@sogoludo.inverse</To>
//  <Options>
//   <MaxAmbiguousRecipients>19</MaxAmbiguousRecipients>
//   <Availability>
//    <StartTime>2014-01-16T05:00:00.000Z</StartTime>
//    <EndTime>2014-01-17T04:59:00.000Z</EndTime>
//   </Availability>
//  </Options>
// </ResolveRecipients>
//
- (void) processResolveRecipients: (id <DOMElement>) theDocumentElement
                       inResponse: (WOResponse *) theResponse
{
  NSArray *allRecipients;
  int i, j, k;

  allRecipients = (id)[theDocumentElement getElementsByTagName: @"To"];

  if ([allRecipients count] && [(id)[theDocumentElement getElementsByTagName: @"Availability"] count])
    {
      NSCalendarDate *startDate, *endDate;
      SOGoAppointmentFolder *folder;
      NSString *aRecipient, *login;
      NSMutableString *s;
      NSArray *freebusy;
      SOGoUser *user;
      NSData *d;

      unsigned int startdate, enddate, increments;
      char c;

      startDate = [[[(id)[theDocumentElement getElementsByTagName: @"StartTime"] lastObject] textValue] calendarDate];
      startdate = [startDate timeIntervalSince1970];

      endDate = [[[(id)[theDocumentElement getElementsByTagName: @"EndTime"] lastObject] textValue] calendarDate];
      enddate = [endDate timeIntervalSince1970];
      
      // Number of 30 mins increments between our two dates
      increments = ceil((float)((enddate - startdate)/60/30)) + 1;
        
      s = [NSMutableString string];
  
      [s appendString: @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
      [s appendString: @"<!DOCTYPE ActiveSync PUBLIC \"-//MICROSOFT//DTD ActiveSync//EN\" \"http://www.microsoft.com/\">"];
      [s appendString: @"<ResolveRecipients xmlns=\"ResolveRecipients:\">"];
      [s appendFormat: @"<Status>%d</Status>", 1];

      for (i = 0; i < [allRecipients count]; i++)
        {
          aRecipient = [[allRecipients objectAtIndex: i] textValue];
          
          login = [[SOGoUserManager sharedUserManager] getUIDForEmail: aRecipient];

          if (login)
            {
              user = [SOGoUser userWithLogin: login];
              
              [s appendString: @"<Response>"];
              [s appendFormat: @"<To>%@</To>", aRecipient];
              [s appendFormat: @"<Status>%d</Status>", 1];
              [s appendFormat: @"<RecipientCount>%d</RecipientCount>", 1];

              [s appendString: @"<Recipient>"];              
              [s appendFormat: @"<Type>%d</Type>", 1];
              [s appendFormat: @"<DisplayName>%@</DisplayName>", [user cn]];
              [s appendFormat: @"<EmailAddress>%@</EmailAddress>", [user systemEmail]];

              // Freebusy structure: http://msdn.microsoft.com/en-us/library/gg663493(v=exchg.80).aspx
              [s appendString: @"<Availability>"];
              [s appendFormat: @"<Status>%d</Status>", 1];
              [s appendString: @"<MergedFreeBusy>"];

              folder = [user personalCalendarFolderInContext: context];
              freebusy = [folder fetchFreeBusyInfosFrom: startDate  to: endDate];
              

              NGCalendarDateRange *r1, *r2;
              
              for (j = 1; j <= increments; j++)
                {
                  c = '0';
                  
                  r1  =  [NGCalendarDateRange calendarDateRangeWithStartDate: [NSDate dateWithTimeIntervalSince1970: (startdate+j*30*60)]
                                                                     endDate: [NSDate dateWithTimeIntervalSince1970: (startdate+j*30*60 + 30)]];
                  
                  
                  for (k = 0; k < [freebusy count]; k++)
                    {
                      
                      r2 = [NGCalendarDateRange calendarDateRangeWithStartDate: [[freebusy objectAtIndex: k] objectForKey: @"startDate"]
                                                                       endDate: [[freebusy objectAtIndex: k] objectForKey: @"endDate"]];
                      
                      if ([r2 doesIntersectWithDateRange: r1])
                        {
                          c = '2';
                          break;
                        }
                    }
                  
                  
                  [s appendFormat: @"%c", c];
                }

             
              [s appendString: @"</MergedFreeBusy>"];
              [s appendString: @"</Availability>"];


              [s appendString: @"</Recipient>"];
              [s appendString: @"</Response>"];
            }
        }

      [s appendString: @"</ResolveRecipients>"];
      
      d = [[s dataUsingEncoding: NSUTF8StringEncoding] xml2wbxml];
      
      [theResponse setContent: d];
    }
}

//
// <?xml version="1.0"?>
// <!DOCTYPE ActiveSync PUBLIC "-//MICROSOFT//DTD ActiveSync//EN" "http://www.microsoft.com/">
// <Search xmlns="Search:">
//  <Store>
//   <Name>GAL</Name>
//   <Query>so</Query>
//   <Options>
//    <Range>0-19</Range>
//   </Options>
//  </Store>
// </Search>
//
- (void) processSearch: (id <DOMElement>) theDocumentElement
            inResponse: (WOResponse *) theResponse
{
  SOGoContactSourceFolder *currentFolder;
  NSDictionary *systemSources, *contact;
  SOGoContactFolders *contactFolders;
  NSArray *allKeys, *allContacts;
  SOGoUserFolder *userFolder;
  NSString *name, *query;
  NSMutableString *s;
  NSData *d;

  int i, j, total;
            
  name = [[(id)[theDocumentElement getElementsByTagName: @"Name"] lastObject] textValue];
  query = [[(id)[theDocumentElement getElementsByTagName: @"Query"] lastObject] textValue];
  
  // FIXME: for now, we only search in the GAL
  if (![name isEqualToString: @"GAL"])
    {
      [theResponse setStatus: 500];
      return;
    }
    

  userFolder = [[context activeUser] homeFolderInContext: context];
  contactFolders = [userFolder privateContacts: @"Contacts"  inContext: context];
  systemSources = [contactFolders systemSources];
  allKeys = [systemSources allKeys];

  s = [NSMutableString string];

  [s appendString: @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
  [s appendString: @"<!DOCTYPE ActiveSync PUBLIC \"-//MICROSOFT//DTD ActiveSync//EN\" \"http://www.microsoft.com/\">"];
  [s appendString: @"<Search xmlns=\"Search:\">"];
  [s appendFormat: @"<Status>1</Status>"];
  [s appendFormat: @"<Response>"];
  [s appendFormat: @"<Store>"];
  [s appendFormat: @"<Status>1</Status>"];

  total = 0;

  for (i = 0; i < [allKeys count]; i++)
    {
      currentFolder = [systemSources objectForKey: [allKeys objectAtIndex: i]];
      allContacts = [currentFolder lookupContactsWithFilter: query
                                                 onCriteria: @"name_or_address"
                                                     sortBy: @"c_cn"
                                                   ordering: NSOrderedAscending
                                                   inDomain: [[context activeUser] domain]];

      for (j = 0; j < [allContacts count]; j++)
        {          
          contact = [allContacts objectAtIndex: j];
          
          // We skip lists for now
          if ([[contact objectForKey: @"c_component"] isEqualToString: @"vlist"])
            continue;
          
          // We get the LDIF entry of our record, for easier processing
          contact = [[currentFolder lookupName: [contact objectForKey: @"c_name"] inContext: context  acquire: NO] ldifRecord];
          
          [s appendString: @"<Result xmlns=\"Search:\">"];
          [s appendString: @"<Properties>"];
          [s appendFormat: @"<DisplayName xmlns=\"Gal:\">%@</DisplayName>", [contact objectForKey: @"displayname"]];
          [s appendFormat: @"<FirstName xmlns=\"Gal:\">%@</FirstName>", [contact objectForKey: @"givenname"]];
          [s appendFormat: @"<LastName xmlns=\"Gal:\">%@</LastName>", [contact objectForKey: @"sn"]];
          [s appendFormat: @"<EmailAddress xmlns=\"Gal:\">%@</EmailAddress>", [contact objectForKey: @"mail"]];
          [s appendFormat: @"<Phone xmlns=\"Gal:\">%@</Phone>", [contact objectForKey: @"telephonenumber"]];
          [s appendFormat: @"<Company xmlns=\"Gal:\">%@</Company>", [contact objectForKey: @"o"]];
          [s appendString: @"</Properties>"];
          [s appendString: @"</Result>"];
          total++;
        }        
    }
  
  [s appendFormat: @"<Range>0-%d</Range>", total-1];
  [s appendFormat: @"<Total>%d</Total>", total];
  [s appendString: @"</Store>"];
  [s appendString: @"</Response>"];
  [s appendString: @"</Search>"];

  d = [[s dataUsingEncoding: NSUTF8StringEncoding] xml2wbxml];
  
  [theResponse setContent: d];
}

//
//
//
- (NSException *) _sendMail: (NSData *) theMail
                 recipients: (NSArray *) theRecipients
            saveInSentItems: (BOOL) saveInSentItems
{
  id <SOGoAuthenticator> authenticator;
  SOGoDomainDefaults *dd;
  NSException *error;
  NSString *from;

  authenticator = [SOGoDAVAuthenticator sharedSOGoDAVAuthenticator];
  dd = [[context activeUser] domainDefaults];
  
  // We generate the Sender
  from = [[[context activeUser] allEmails] objectAtIndex: 0];
  
  error = [[SOGoMailer mailerWithDomainDefaults: dd]
                       sendMailData: theMail
                       toRecipients: theRecipients
                             sender: from
                  withAuthenticator: authenticator
                          inContext: context];

  if (error)
    {
      return error;
    }
  
  if (saveInSentItems)
    {
      SOGoMailAccounts *accountsFolder;
      SOGoMailAccount *accountFolder;
      SOGoUserFolder *userFolder;
      SOGoSentFolder *sentFolder;

      userFolder = [[context activeUser] homeFolderInContext: context];
      accountsFolder = [userFolder lookupName: @"Mail"  inContext: context  acquire: NO];
      accountFolder = [accountsFolder lookupName: @"0"  inContext: context  acquire: NO];
      sentFolder = [accountFolder sentFolderInContext: context];

      [sentFolder postData: theMail  flags: @"seen"];
    }

  return nil;
}

//
//
//
- (void) processSendMail: (id <DOMElement>) theDocumentElement
              inResponse: (WOResponse *) theResponse
{
  NGMimeMessageParser *parser;
  NGMimeMessage *message;
  NSException *error;
  NSData *data;
  
  // We get the mail's data
  data = [[[[(id)[theDocumentElement getElementsByTagName: @"MIME"] lastObject] textValue] stringByDecodingBase64] dataUsingEncoding: NSUTF8StringEncoding];
  
  // We extract the recipients
  parser = [[NGMimeMessageParser alloc] init];
  message = [parser parsePartFromData: data];
  RELEASE(parser);
  
  error = [self _sendMail: data
               recipients: [message allRecipients]
                saveInSentItems:  ([(id)[theDocumentElement getElementsByTagName: @"SaveInSentItems"] count] ? YES : NO)];

  if (error)
    {
      [theResponse setStatus: 500];
      [theResponse appendContentString: @"FATAL ERROR occured during SendMail"];
    }
}



//
//
// Examples:
//
// <?xml version="1.0"?>
// <!DOCTYPE ActiveSync PUBLIC "-//MICROSOFT//DTD ActiveSync//EN" "http://www.microsoft.com/">
// <Settings xmlns="Settings:">
//  <Oof>
//   <Get>
//    <BodyType>text</BodyType>
//   </Get>
//  </Oof>
// </Settings>
//
//
//
// "POST /SOGo/Microsoft-Server-ActiveSync?Cmd=Settings&User=sogo10&DeviceId=SEC17CD1A3E9E3F2&DeviceType=SAMSUNGSGHI317M HTTP/1.1"
//
// <?xml version="1.0"?>
// <!DOCTYPE ActiveSync PUBLIC "-//MICROSOFT//DTD ActiveSync//EN" "http://www.microsoft.com/">
// <Settings xmlns="Settings:">
//  <DeviceInformation>
//   <Set>
//    <Model>SGH-I317M</Model>
//    <IMEI>354422050248226</IMEI>
//    <FriendlyName>t0ltevl</FriendlyName>
//    <OS>Android</OS>
//    <OSLanguage>English</OSLanguage>
//    <PhoneNumber>15147553630</PhoneNumber>
//    <UserAgent>SAMSUNG-SGH-I317M/100.40102</UserAgent>
//    <EnableOutboundSMS>0</EnableOutboundSMS>
//    <MobileOperator>Koodo</MobileOperator>
//   </Set>
//  </DeviceInformation>
// </Settings>
//
// We ignore everything for now
// 
- (void) processSettings: (id <DOMElement>) theDocumentElement
              inResponse: (WOResponse *) theResponse
{
  
  NSMutableString *s;
  NSData *d;
  
  s = [NSMutableString string];
  [s appendString: @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
  [s appendString: @"<!DOCTYPE ActiveSync PUBLIC \"-//MICROSOFT//DTD ActiveSync//EN\" \"http://www.microsoft.com/\">"];
  [s appendString: @"<Settings xmlns=\"Settings:\">"];
  [s appendFormat: @"    <Status>1</Status>"];
  [s appendString: @"</Settings>"];
  
  d = [[s dataUsingEncoding: NSUTF8StringEncoding] xml2wbxml];
  
  [theResponse setContent: d];
}


//
// <?xml version="1.0"?>
// <!DOCTYPE ActiveSync PUBLIC "-//MICROSOFT//DTD ActiveSync//EN" "http://www.microsoft.com/">
// <SmartForward xmlns="ComposeMail:">
//  <ClientId>C9FF94FE-EA40-473A-B3E2-AAEE94F753A4</ClientId>
//  <SaveInSentItems/>
//  <ReplaceMime/>
//  <Source>
//   <FolderId>mail/INBOX</FolderId>
//   <ItemId>82</ItemId>
//  </Source>
//  <MIME>... the data ...</MIME>
// </SmartForward>
//
- (void) processSmartForward: (id <DOMElement>) theDocumentElement
                  inResponse: (WOResponse *) theResponse
{
  NSString *folderId, *itemId, *realCollectionId;
  SOGoMicrosoftActiveSyncFolderType folderType;

  folderId = [[(id)[theDocumentElement getElementsByTagName: @"FolderId"] lastObject] textValue];
  itemId = [[(id)[theDocumentElement getElementsByTagName: @"ItemId"] lastObject] textValue];
  realCollectionId = [folderId realCollectionIdWithFolderType: &folderType];

  if (folderType == ActiveSyncMailFolder)
    {
      SOGoMailAccounts *accountsFolder;
      SOGoMailFolder *currentFolder;
      SOGoUserFolder *userFolder;
      SOGoMailObject *mailObject;
      id currentCollection;

      NGMimeMessage *messageFromSmartForward, *messageToSend;
      NGMimeMessageParser *parser;
      NSData *data;

      userFolder = [[context activeUser] homeFolderInContext: context];
      accountsFolder = [userFolder lookupName: @"Mail"  inContext: context  acquire: NO];
      currentFolder = [accountsFolder lookupName: @"0"  inContext: context  acquire: NO];
      
      currentCollection = [currentFolder lookupName: [NSString stringWithFormat: @"folder%@", realCollectionId]
                                          inContext: context
                                            acquire: NO];

      mailObject = [currentCollection lookupName: itemId  inContext: context  acquire: NO];


      parser = [[NGMimeMessageParser alloc] init];
      data = [[[[(id)[theDocumentElement getElementsByTagName: @"MIME"] lastObject] textValue] stringByDecodingBase64] dataUsingEncoding: NSUTF8StringEncoding];
      messageFromSmartForward = [parser parsePartFromData: data];

      RELEASE(parser);
      

      // We create a new MIME multipart/mixed message. The first part will be the text part
      // of our "smart forward" and the second part will be the message/rfc822 part of the
      // "smart forwarded" message.
      NGMimeBodyPart   *bodyPart;
      NGMutableHashMap *map;
      id body;

      map = [NGHashMap hashMapWithDictionary: [messageFromSmartForward headers]];
      [map setObject: @"multipart/mixed"  forKey: @"content-type"];

      messageToSend = [[[NGMimeMessage alloc] initWithHeader: map] autorelease];
      body = [[[NGMimeMultipartBody alloc] initWithPart: messageToSend] autorelease];
      
      // First part
      map = [[[NGMutableHashMap alloc] initWithCapacity: 1] autorelease];
      [map setObject: @"text/plain" forKey: @"content-type"];
      bodyPart = [[[NGMimeBodyPart alloc] initWithHeader:map] autorelease];
      [bodyPart setBody: [messageFromSmartForward body]];
      [body addBodyPart: bodyPart];

      // Second part
      // FIXME - SOPE (read "POS") generates garbage if we only have the content-type header
      map = [[[NGMutableHashMap alloc] initWithCapacity: 1] autorelease];
      [map setObject: @"message/rfc822" forKey: @"content-type"];
      bodyPart = [[[NGMimeBodyPart alloc] initWithHeader:map] autorelease];
      [bodyPart setBody: [mailObject content]];
      [body addBodyPart: bodyPart];
      [messageToSend setBody: body];
      
      NGMimeMessageGenerator *generator;
      generator = [[[NGMimeMessageGenerator alloc] init] autorelease];
      data = [generator generateMimeFromPart: messageToSend];
            
      NSException *error = [self _sendMail: data
                                recipients: [messageFromSmartForward allRecipients]
                                 saveInSentItems:  ([(id)[theDocumentElement getElementsByTagName: @"SaveInSentItems"] count] ? YES : NO)];
      
      if (error)
        {
          [theResponse setStatus: 500];
          [theResponse appendContentString: @"FATAL ERROR occured during SmartForward"];
        }
    }
  else
    {
      // FIXME
      [theResponse setStatus: 500];
      [theResponse appendContentString: @"SmartForward not-implemented on non-mail folders."];
    }
}

//
// <?xml version="1.0"?>
// <!DOCTYPE ActiveSync PUBLIC "-//MICROSOFT//DTD ActiveSync//EN" "http://www.microsoft.com/">
// <SmartReply xmlns="ComposeMail:">
//  <ClientId>DD40B5DC-4BDF-4A6A-9D8B-4B02BE5342CD</ClientId>
//  <SaveInSentItems/>
//  <ReplaceMime/>                       -- http://msdn.microsoft.com/en-us/library/gg663506(v=exchg.80).aspx
//  <Source>
//   <FolderId>mail/INBOX</FolderId>
//   <ItemId>82</ItemId>
//  </Source>
//  <MIME>... the data ...</MIME>
// </SmartReply>
//
- (void) processSmartReply: (id <DOMElement>) theDocumentElement
                inResponse: (WOResponse *) theResponse
{
  [self processSmartForward: theDocumentElement  inResponse: theResponse];
}



//
//
//
- (NSException *) dispatchRequest: (id) theRequest
                       inResponse: (id) theResponse
                          context: (id) theContext
{
  id <DOMElement> documentElement;
  id builder, dom;
  SEL aSelector;

  NSString *cmdName, *deviceId;
  NSData *d;

  ASSIGN(context, theContext);
 
  // Get the device ID and "stash" it
  deviceId = [[theRequest uri] deviceId];
  [context setObject: deviceId  forKey: @"DeviceId"];

  d = [[theRequest content] wbxml2xml];

  if (!d)
    {
      // We check if it's a Ping command with no body.
      // See http://msdn.microsoft.com/en-us/library/ee200913(v=exchg.80).aspx for details
      cmdName = [[theRequest uri] command];
      
      if ([cmdName caseInsensitiveCompare: @"Ping"] != NSOrderedSame)
        return [NSException exceptionWithHTTPStatus: 500];
    }

  if (d)
    {
      builder = [[[NSClassFromString(@"DOMSaxBuilder") alloc] init] autorelease];
      dom = [builder buildFromData: d];
      documentElement = [dom documentElement];
      
      // See 2.2.2 Commands - http://msdn.microsoft.com/en-us/library/ee202197(v=exchg.80).aspx
      // for all potential commands
      cmdName = [NSString stringWithFormat: @"process%@:inResponse:", [documentElement tagName]];
    }
  else
    {
      // Ping command with empty body
      cmdName = [NSString stringWithFormat: @"process%@:inResponse:", cmdName];
    }
  
  aSelector = NSSelectorFromString(cmdName);

  [self performSelector: aSelector  withObject: documentElement  withObject: theResponse];

  [theResponse setHeader: @"application/vnd.ms-sync.wbxml"  forKey: @"Content-Type"];
  [theResponse setHeader: @"14.0"  forKey: @"MS-Server-ActiveSync"];
  [theResponse setHeader: @"Sync,SendMail,SmartForward,SmartReply,GetAttachment,GetHierarchy,CreateCollection,DeleteCollection,MoveCollection,FolderSync,FolderCreate,FolderDelete,FolderUpdate,MoveItems,GetItemEstimate,MeetingResponse,Search,Settings,Ping,ItemOperations,Provision,ResolveRecipients,ValidateCert"  forKey: @"MS-ASProtocolCommands"];
  [theResponse setHeader: @"2.0,2.1,2.5,12.0,12.1,14.0"  forKey: @"MS-ASProtocolVersions"];

   RELEASE(context);

  return nil;
}

@end
