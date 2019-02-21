//  Copyright (C) 2018, ownCloud GmbH.
//  This code is covered by the GNU Public License Version 3.
//  For distribution utilizing Apple mechanisms please see https://owncloud.org/contribute/iOS-license-exception/
//  You should have received a copy of this license along with this program.
//  If not, see <http://www.gnu.org/licenses/gpl-3.0.en.html>.
//
//  @Authors
//      Pablo Carrascal.

#import "OpenInAppHandler.h"
#import "AppDelegate.h"
#import "OCCommunication.h"
#import "UtilsUrls.h"
#import "ManageFilesDB.h"
#import "UtilsDtos.h"
#import "NSString+Encoding.h"
#import "FileListDBOperations.h"
#import "UtilsFramework.h"

@implementation OpenInAppHandler

-(id)initWithLink:(NSURL *)linkURL andUser:(UserDto *) user
{

    self = [super init];

    if (self)
    {
        _tappedLinkURL = linkURL;
        _user = user;
    }
    return self;
}

-(void)handleLink:(void (^)(NSArray *))success failure:(void (^)(NSError *))failure
{
    [self _getRedirection:_tappedLinkURL success:^(NSString *redirectedURL)
    {
        NSString *decodedURL = [[NSString alloc ] initWithString:redirectedURL];

        [self _isItemDirectory:decodedURL completionHandler:^(BOOL isDirectory, NSError *error)
        {
            if (error != nil)
            {
                failure(error);
            }
            else
            {
                __block NSArray<NSString *> *urls = [UtilsUrls getArrayOfWebdavUrlWithUrlInWebScheme:decodedURL forUser:_user isDirectory:isDirectory];

                __block NSMutableArray *files = [NSMutableArray new];

                __block BOOL isLeave = NO;
                
                dispatch_group_t group = dispatch_group_create();
                dispatch_group_enter(group);

                dispatch_group_async(group ,dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),^{
                    [urls enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {

                        [self _getFilesFrom:urls[idx] success:^(NSArray *items)
                        {
                            NSMutableArray *directoryList = [UtilsDtos passToFileDtoArrayThisOCFileDtoArray:items];
                            files[idx] = directoryList;

                            if (idx == urls.count - 1) {
                                if (!isLeave) {
                                    isLeave = YES;
                                    dispatch_group_leave(group);
                                }
                            }
                        }
                        failure:^(NSError *error)
                        {
                            NSLog(@"LOG ---> error in the request to the url -> %@", urls[idx]);
                            if (!isLeave) {
                                isLeave = YES;
                                dispatch_group_leave(group);
                            }
                            failure(error);
                        }];
                    }];
                });

                dispatch_group_notify(group ,dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),^{

                    if (files.count == urls.count) {
                        NSMutableArray *filesFromRootToFile = [self _syncFilesTreeWithFiles:files andUrls:urls];

                        if (filesFromRootToFile.count > 0) {
                            success([filesFromRootToFile copy]);
                        } else {
                            failure([UtilsFramework getErrorByCodeId:OCErrorPrivateLinkErrorCachingFile]);
                        }
                    } else {
                        failure([UtilsFramework getErrorByCodeId:OCErrorPrivateLinkErrorCachingFile]);
                    }
                });
            }
        }];
    } failure:^(NSError *error) {
        failure(error);
    }];
}

-(void)_getRedirection:(NSURL *)privateLink success:(void (^)(NSString *))success failure:(void (^)(NSError *))failure
{
    [[AppDelegate sharedOCCommunication] getWebdavLocationPathFromPrivateLinkURL:_tappedLinkURL.absoluteString success:^(NSString *path)
    {
        success(path);
    }
    failure:^(NSError *error)
    {
        failure(error);
    }];
}

-(void)_getFilesFrom:(NSString *)folderPath success:(void (^)(NSArray *))success failure:(void (^)(NSError *))failure
{
    DLog(@"_getFilesFrom: %@", folderPath);
    
    __block OCCommunication *ocComm;
    ocComm = [AppDelegate sharedOCCommunication];

    [ocComm readFolder:folderPath withUserSessionToken:APP_DELEGATE.userSessionCurrentToken onCommunication:ocComm successRequest:^(NSHTTPURLResponse *response, NSArray *items, NSString *redirectedServer, NSString *token)
    {
        success(items);
    }
    failureRequest:^(NSHTTPURLResponse *response, NSError *error, NSString *token, NSString *redirectedServer)
    {
        failure([UtilsFramework getErrorByCodeId:OCErrorPrivateLinkErrorCachingFile]);
    }];
}

-(NSString *)_getFileNameFromURLWithURL: (NSString *)url
{
    NSMutableArray *components = [NSMutableArray arrayWithArray:[url componentsSeparatedByString:@"/"]];
    NSString *name = components.lastObject;
    if (components.count > 1)
    {
        if ([components.lastObject isEqualToString:@""])
        {
            [components removeLastObject];
            name = [components.lastObject stringByAppendingString:@"/"];
        }
        else
        {
            name = components.lastObject;
        }
    }

    return name;
}

-(NSString *)_getFilePathFromURLWithURL: (NSString *)url andFileName: (NSString *)name
{
    NSString *path = [url stringByReplacingOccurrencesOfString:name withString:@""];
    return path;
}

-(void)_isItemDirectory: (NSString *)itemPath completionHandler:(void (^)(BOOL isDirectory, NSError * error))completionHandler
{
    NSError *error = NULL;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(.*)\/remote.php\/dav\/files\/[^\/]*\/" options:NSRegularExpressionCaseInsensitive error:&error];
    NSString *result = [regex stringByReplacingMatchesInString:itemPath options:0 range:NSMakeRange(0, [itemPath length]) withTemplate:@""];

    NSString *path = [[UtilsUrls getFullRemoteServerPathWithWebDav:_user] stringByAppendingString:result];

    [[AppDelegate sharedOCCommunication] readFile:path  onCommunication: [AppDelegate sharedOCCommunication] successRequest:^(NSHTTPURLResponse *response, NSArray *items, NSString *redirectedServer)
    {
        NSMutableArray<FileDto *> *item = [UtilsDtos passToFileDtoArrayThisOCFileDtoArray:items];

        if (item[0].isDirectory)
        {
            completionHandler(YES, nil);
        }
        else
        {
            completionHandler(NO, nil);
        }

    }
    failureRequest:^(NSHTTPURLResponse *response, NSError *error, NSString *redirectedServer)
    {
        completionHandler(NO, error);
    }];
}

-(NSMutableArray *)_syncFilesTreeWithFiles: (NSMutableArray *)filesToSync andUrls: (NSArray<NSString *> *)urls
{
    NSMutableArray *filesToReturn = [[NSMutableArray alloc] initWithCapacity:urls.count];
    FileDto *parent = nil;
    NSString *rootFileSystem = [NSString stringWithFormat:@"%@%ld/", [UtilsUrls getOwnCloudFilePath],(long)_user.userId];

    NSString *subfolders = [UtilsUrls getServerSubfolders:_user];
    NSString *stringToTrim = [[NSString alloc] init];
    if (subfolders == nil) {
        stringToTrim = k_url_webdav_server_with_first_slash;
    } else {
        stringToTrim = [subfolders stringByAppendingString:k_url_webdav_server];
    }
    
    for (int i = 0; i < filesToSync.count; i ++)
    {

        NSString *urlToGetAsParent = urls[i];
        NSString *shortedFileURL = [UtilsUrls getFilePathOnDBByFullPath:urlToGetAsParent andUser:_user];
        NSString *name = [self _getFileNameFromURLWithURL:shortedFileURL];
        NSString *path = [self _getFilePathFromURLWithURL:shortedFileURL andFileName:name];

        if ([path isEqualToString:stringToTrim])
        {
            path = @"";
        }

        name = [name encodeString:NSUTF8StringEncoding];
        path = [path encodeString:NSUTF8StringEncoding];
        parent = [ManageFilesDB getFileDtoByFileName:name andFilePath:path andUser:_user];

        if (parent != nil)
        {
            [filesToReturn addObject:parent];
        }
        else
        {
            parent = [ManageFilesDB getFileDtoByFileName:name andFilePath:path andUser:_user];
            if (parent != nil)
            {
                [filesToReturn addObject:parent];
            }
        }

        //Now we create the all folders of the current directory
        [FileListDBOperations deleteOldDataFromDBBeforeRefresh:filesToSync[i] parent:parent];
        rootFileSystem = [[rootFileSystem stringByAppendingString:
                           [name stringByRemovingPercentEncoding]] stringByReplacingOccurrencesOfString:stringToTrim withString:@""];
        [FileListDBOperations createAllFoldersByArrayOfFilesDto:filesToSync[i] andLocalFolder: rootFileSystem];
    }
    return filesToReturn;

}

@end
