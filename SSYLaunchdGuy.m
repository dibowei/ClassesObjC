#import "SSYLaunchdGuy.h"
#import "SSYShellTasker.h"
#import "NSError+SSYAdds.h"
#import "SSYOtherApper.h"
#import "SSYShellTasker.h"
#import "NSString+Data.h"
#import "NSFileManager+SomeMore.h"
#import "NSFileManager+TempFile.h"
#import "SSYPathWaiter.h"
#import "SSYLaunchdBasics.h"

NSString* const SSYLaunchdGuyErrorDomain = @"SSYLaunchdGuyErrorDomain" ;

@interface SSYLaunchdGuy ()
@end

@implementation SSYLaunchdGuy

+ (BOOL)isScheduledLaunchdAgentWithPrefix:(NSString*)prefix {
	NSDictionary* dicOfDics = [SSYLaunchdBasics installedLaunchdAgentsWithPrefix:prefix] ;
	for (NSString* label in dicOfDics) {
		NSDictionary* agentDic = [dicOfDics valueForKey:label] ;
		// Use defensive programming when reading from files!
		if ([agentDic respondsToSelector:@selector(valueForKey:)]) {
			NSDictionary* timeValues = [agentDic valueForKey:@"StartCalendarInterval"] ;
			if (timeValues) {
				return YES ;
			}
		}
	}
	
	return NO ;
}

+ (NSError*)warnUserIfLaunchdHangInTaskResult:(NSInteger)result
										error:(NSError*)error {
	if ((result != 0) && ([error code] == SSYShellTaskerErrorTimedOut)) {
		NSTimeInterval timeout = [[[error userInfo] objectForKey:constKeySSYShellTaskerTimeout] doubleValue] ;
		NSLog(@"Warning 516-7625 launchctl timed out at %0.1f secs.  Time to restart?", timeout) ;
		NSString* reason = @"The launchd process of Mac OS X is not responding." ;
		NSString* suggestion = @"You should restart your Mac at the next opportunity.  "
		@"This bug has reportedly been fixed by Apple in Mac OS 10.8 (Mountain Lion)." ;
		error = [error errorByAddingLocalizedFailureReason:reason] ;
		error = [error errorByAddingLocalizedRecoverySuggestion:suggestion] ;
		NSString* message = [NSString stringWithFormat:@"%@\n\n%@",
							 reason,
							 suggestion] ;
		
		NSString* windowTitle = [NSString stringWithFormat:
								 @"%@ : Problem with Mac OS X",
								 [[NSProcessInfo processInfo] processName]] ;
		CFUserNotificationDisplayNotice (
										 60,  // timeout
										 kCFUserNotificationStopAlertLevel,
										 NULL,
										 NULL,
										 NULL,
										 (CFStringRef)windowTitle,
										 (CFStringRef)message,
										 NULL) ;
		// The above function returns immediately. It does not wait
		// for a user response after displaying the dialog.
	}
	
	return error ;
}

// launchctl itself has a built-in timeout of 25 seconds (Mac OS 10.6.6).
// So, anything over 25 seconds will act like 25 seconds.  However, on
// 20120428 launchctl got into some weird state in Mac OS X 10.7.3.
// Whenever I gave it a command to load or unload a job, it would hang
// indefinitely.  So I reduced this in BookMacster 1.11 from 180.0 to
// 35.0 seconds.
#define LAUNCHCTL_TIMEOUT 35.0

+ (BOOL)agentLoadPath:(NSString*)plistPath
			  error_p:(NSError**)error_p {	
	NSString* subcmd = @"load" ;
	NSArray* arguments = [NSArray arrayWithObjects:
						  subcmd,
						  // The following two lines were added in BookMacster 1.3.2 for Alex Harsha-Strong <aharshas@gmail.com>
						  // because he was getting "nothing found to load" errors.  Solution -w was suggested here:
						  // http://www.cuddletech.com/blog/pivot/entry.php?id=403
						  // Then I read the documentation and decided to add -F too.
						  @"-w",  
						  @"-F",
						  plistPath,
						  nil] ;
	NSData* stderrData = nil ;
	NSError* error_ ;
	NSString* command = @"/bin/launchctl" ;
	NSInteger result = [SSYShellTasker doShellTaskCommand:command
												arguments:arguments
											  inDirectory:nil
												stdinData:nil
											 stdoutData_p:NULL
											 stderrData_p:&stderrData
												  timeout:LAUNCHCTL_TIMEOUT
												  error_p:&error_] ;
	error_ = [self warnUserIfLaunchdHangInTaskResult:result
											  error:error_] ;
	if ((result != 0) && error_p) {
		NSString* msg = [NSString stringWithFormat:@"%@ failed", command] ;
		*error_p = SSYMakeError(26530, msg) ;
		*error_p = [*error_p errorByAddingUnderlyingError:error_] ;
		*error_p = [*error_p errorByAddingUserInfoObject:[NSNumber numberWithInteger:result]
												  forKey:@"Command Result"] ;
		
		if (stderrData) {
			id stderr = [NSString stringWithDataUTF8:stderrData] ;
			if(!stderr) {
				stderr = stderrData ;
			}
			
			*error_p = [*error_p errorByAddingUserInfoObject:stderr
													  forKey:@"stderr"] ;
		}
	}

	return (result == 0) ;

}

+ (BOOL)removeAgentsWithPrefix:(NSString*)prefix
					afterDelay:(NSInteger)delay
					   timeout:(NSTimeInterval)timeout
					 successes:(NSMutableSet*)successes
					  failures:(NSMutableSet*)failures {
	BOOL ok = YES ;
	NSString* myAgentDirectory = [SSYLaunchdBasics homeLaunchAgentsPath] ;
	
#if (MAC_OS_X_VERSION_MAX_ALLOWED < 1060) 
	NSArray* existingFilenames = [[NSFileManager defaultManager] directoryContentsAtPath:myAgentDirectory] ;
#else
	NSError* error = nil ;
	NSArray* existingFilenames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:myAgentDirectory
																					 error:&error] ;
	if ([error isNotFileNotFoundError]) {
		NSLog(@"Internal Error 923-5347 %@" , error) ;
		return NO ;
	}
#endif

	// Unload and remove file for all agents with given identifier
	if (prefix) {
		for (NSString* filename in existingFilenames) {
			if ([filename hasPrefix:prefix]) {
				// The 'label' is the filename without the ".plist" extension…
				NSString* label = [filename stringByDeletingPathExtension] ;
				ok = [self removeAgentWithLabel:label
									 afterDelay:delay
									 justReload:NO
										timeout:timeout] ;
				if (timeout > 0.0) {
					NSString* path = [myAgentDirectory stringByAppendingPathComponent:filename] ;
					if (ok) {
						[successes addObject:path] ;
					}
					else {
						ok = NO ;
						[failures addObject:path] ;
					}
				}
			}
		}
	}

	return ok ;
}

+ (BOOL)addAgentInfo:(NSDictionary*)dic
		   directory:(NSString*)dirPath
				load:(BOOL)load
			 error_p:(NSError**)error_p {
	NSError* error = nil ;
    BOOL ok = YES ;
	
	// Create data
	NSString* errorDescription = nil ;
	NSData* data = [NSPropertyListSerialization dataFromPropertyList:dic
															  format:NSPropertyListXMLFormat_v1_0
													errorDescription:&errorDescription] ;
	if (!data) {
		NSString* msg = [NSString stringWithFormat:
						 @"Could not load agent because %@",
						 errorDescription] ;
		error = SSYMakeError(48376, msg) ;
		error = [error errorByAddingUserInfoObject:dic
												  forKey:@"Dictionary"] ;
		ok = NO ;
		goto end ;
	}
	
	// Generate file URL
	NSString* filename = [dic objectForKey:@"Label"] ;
	if (!filename) {
		error = SSYMakeError(483276, @"No label") ;
		error = [error errorByAddingUserInfoObject:dic
												  forKey:@"Dic"] ;
		error = [error errorByAddingBacktrace] ;
		ok = NO ;
		goto end ;
	}
	filename = [filename stringByAppendingPathExtension:@"plist"] ;
	NSString* path = [dirPath stringByAppendingPathComponent:filename] ;
	NSURL* url = [NSURL fileURLWithPath:path] ;
	
	// Write data to file URL
	ok = [data writeToURL:url
				  options:NSAtomicWrite
					error:&error] ;
	if (!ok) {
		goto end ;
	}
	
	// Set file permissions.  Probably for security, launchctl will refuse
	// to load a plist file if it has permissions octal '666'.  It wants '644'.
	NSNumber* octal644 = [NSNumber numberWithUnsignedLong:0644] ;
	// Note that, in 0644, the 0 is a prefix which says to interpret the
	// remainder of the digits as octal, just as 0x is a prefix which says to
	// interpret the remainder of the digits as hexidecimal.  It's C !
	NSDictionary* attributes = [NSDictionary dictionaryWithObject:octal644
														   forKey:NSFilePosixPermissions] ;
#if (MAC_OS_X_VERSION_MAX_ALLOWED < 1060) 
	ok =[[NSFileManager defaultManager] changeFileAttributes:attributes
													  atPath:path] ;
#else
	ok =[[NSFileManager defaultManager] setAttributes:attributes
										 ofItemAtPath:path
												error:&error] ;
#endif
	if (!ok) {
		NSString* msg = [NSString stringWithFormat:
						 @"Could not set permissions for agent %@",
						 path] ;
		error = [SSYMakeError(32457, msg) errorByAddingUnderlyingError:error] ;
		goto end ;
	}
	
	
	if (load) {
		ok = [self agentLoadPath:path
						 error_p:&error] ;
		if (!ok) {
			NSString* msg = [NSString stringWithFormat:
							 @"Could not load agent %@",
							 path] ;
			error = [SSYMakeError(32452, msg) errorByAddingUnderlyingError:error] ;
			
			goto end ;
		}
	}
	
end:;
    if (error_p) {
        *error_p = error ;
    }
    
	return ok ;
}

+ (NSString*)myAgentDirectoryError_p:(NSError**)error_p {
	NSString* myAgentDirectory = [SSYLaunchdBasics homeLaunchAgentsPath] ;
	BOOL ok = [[NSFileManager defaultManager] createDirectoryIfNoneExistsAtPath:myAgentDirectory
																		error_p:error_p] ;
	if (!ok) {
		myAgentDirectory = nil ;
	}
	
	return myAgentDirectory ;
}

+ (BOOL)addAgent:(NSDictionary*)agentDic
			load:(BOOL)load
		 error_p:(NSError**)error_p {
	BOOL ok = YES ;
	NSError* error = nil ;
	
	NSString* myAgentDirectory = [self myAgentDirectoryError_p:&error] ;
	
	if (myAgentDirectory) {
		// Create new file for new agent, write to disk and load 
		ok = [self addAgentInfo:agentDic
					  directory:myAgentDirectory
						   load:load
						error_p:&error] ;
	}
	
	if (!ok && error_p) {
		*error_p = error ;
	}
	
	return ok ;
}

+ (BOOL)addAgents:(NSArray*)agents
			 load:(BOOL)load
		  error_p:(NSError**)error_p {
	BOOL ok = YES ;
	NSError* error = nil ;
	
	NSString* myAgentDirectory = [self myAgentDirectoryError_p:&error] ;
	
	if (myAgentDirectory) {
		// Create new files for new agents, write to disk and load 
		for (NSDictionary* dic in agents) {
			ok = [self addAgentInfo:dic
						  directory:myAgentDirectory
							   load:load
							error_p:&error] ;
			if (!ok) {
				break ;
			}
		}
	}
	
	if (!ok && error_p) {
		*error_p = error ;
	}
	
	return ok ;
}

+ (NSString*)bashEscapementOfLabel:(NSString*)label {
	NSSet* reservedChars = [NSSet setWithObjects:
							@"?", @"+", @"{", @"|", @"(", @")", @"[", @"]", nil] ;
	NSMutableString* mutantLabel = [label mutableCopy] ;
	for (NSString* reservedChar in reservedChars) {
		[mutantLabel replaceOccurrencesOfString:reservedChar
									 withString:[NSString stringWithFormat:@"\\%@", reservedChar]
										options:0
										  range:NSMakeRange(0, [mutantLabel length])] ;
	}
	NSString* escapedLabel = [[mutantLabel copy] autorelease] ;
	[mutantLabel release] ;
	return escapedLabel ;
}

+ (pid_t)pidIfRunningLabel:(NSString*)label {
	NSInteger result ;
	pid_t pid = 0 ;	
	
	NSData* stdoutData = nil ;
	NSError* error = nil ;
	NSString* command = [NSString stringWithFormat:
						 @"/bin/launchctl list | /usr/bin/grep %@",
						 [self bashEscapementOfLabel:label]] ;
	NSArray* arguments = [NSArray arrayWithObjects:
						  @"-c",
						  command,
						  nil] ;
	result = [SSYShellTasker doShellTaskCommand:@"/bin/sh"
									  arguments:arguments
									inDirectory:nil
									  stdinData:nil
								   stdoutData_p:&stdoutData
								   stderrData_p:NULL
										timeout:3.0
										error_p:&error] ;
	error = [self warnUserIfLaunchdHangInTaskResult:result
											  error:error] ;
	if ((result != 0) && error) {
		NSLog(@"SSYLaunchdGuy Error 879-1417 label=%@  %@", label, error) ;
	}
	
	if (stdoutData) {
		NSString* response = [[NSString alloc] initWithData:stdoutData
												   encoding:NSUTF8StringEncoding] ;
		// Next line is defensive programming
		NSString* trimmedResponse = [response stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ;
        [response release] ;
		NSArray* words = [trimmedResponse componentsSeparatedByString:@" "] ;
		if ([words count] > 0) {
			NSString* pidString = [words objectAtIndex:0] ;
			pid = [pidString integerValue] ;
		}
	}
	
	return pid ;
}

/*!
 @brief    
 
 @details   This section was added in BookMacster 1.7.2/1.6.8,
 and upgraded to a separate method in BookMacster 1.9.9.  Problem:
 launchctl will log a stupid message to stderr if we tell it to 
 unload a job which is not loaded.  I presume it might, or might
 someday, do a similar thing if we tell it to load a job which
 is already loaded.  Use this method first.  It will ask launchctl
 for its list of loaded jobs, then grep it to see if our job is already loaded.
 
 If any error occurs, this method logs it to the console and returns YES,
 that is, assuming worst-case, that the job *is* loaded and therefore
 should be unloaded.  If you were using this method to see if a job
 needs to be loaded, you'd want to reverse that behavior!
 @result    YES if the job is loaded or an error occurs,
 NO if the job is definitely not loaded
 */
+ (BOOL)isLoadedLabel:(NSString*)label {
	NSArray *arguments;
	NSInteger result;
	BOOL isLoaded = YES ;
	
	/*
	 I do this with two separate tasks: First, launchctl, then pipe
	 pipe to grep.  Note that the pipe requires the bash shell.
	 Another, probably easier way to do this is to concatenate
	 both launchctl and grep commands into a string, and execute
	 one task, targeting /bin/sh.  For an example of that, see
	 +pidIfRunningLabel.
	 */
	
	arguments = [NSArray arrayWithObjects:
				 @"list",
				 nil] ;
	
	NSData* listData = nil ;
	NSError* error = nil ;
	result = [SSYShellTasker doShellTaskCommand:@"/bin/launchctl"
									  arguments:arguments
									inDirectory:nil
									  stdinData:nil
								   stdoutData_p:&listData
								   stderrData_p:NULL
										timeout:3.0
										error_p:&error] ;
	error = [self warnUserIfLaunchdHangInTaskResult:result
											  error:error] ;
	if ((result != 0) && error) {
		NSLog(@"SSYLaunchdGuy Error 845-6422 label=%@  %@", label, error) ;
	}
	
	if (listData) {
		NSString *escapedLabel = [self bashEscapementOfLabel:label] ;

		NSString* pattern = [NSString stringWithFormat:
							 @"[[:space:]]%@$",
							 escapedLabel] ;
		arguments = [NSArray arrayWithObjects:
					 @"-q",	// Return 0 if pattern is found, 1 if not, 1 if error	 
					 pattern,
					 nil] ;
		NSData* countData = nil ;
		error = nil ;
		result = [SSYShellTasker doShellTaskCommand:@"/usr/bin/grep"
										  arguments:arguments
										inDirectory:nil
										  stdinData:listData
									   stdoutData_p:&countData
									   stderrData_p:NULL
											timeout:3.0
											error_p:&error] ;
#if 0
#warning Faking Brent Robinson error #2
		result = SSYShellTaskerErrorTimedOut ;
		error = SSYMakeError(987654, @"Fake Error #2") ;
#endif
		error = [self warnUserIfLaunchdHangInTaskResult:result
												  error:error] ;
		if (error) {
			NSLog(@"SSYLaunchdGuy Error 845-6423 label=%@  %@", label, error) ;
		}
		else {
			isLoaded = (result == 0) ;
		}
	}
	else {
		NSLog(@"SSYLaunchdGuy Error 589-9393 label=%@  %@", label, error) ;
		// Until BookMacster 1.9.9, we'd return NO here.  Now we'll return YES ;
	}
	
	return isLoaded ;
}

+ (BOOL)removeAgentWithLabel:(NSString*)label
				  afterDelay:(NSInteger)delaySeconds
				  justReload:(BOOL)justReload
					 timeout:(NSTimeInterval)timeout {
	if (!label) {
		return YES ;
	}

	
	NSString* filename = [label stringByAppendingPathExtension:@"plist"] ;
	NSString* directory = [SSYLaunchdBasics homeLaunchAgentsPath] ;
	NSString* plistPath = [directory stringByAppendingPathComponent:filename] ;
	
	// Added in BookMacster 1.5.7:
	if (![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
		return YES ;
	}
	
	// Stupid launchctl will log an error to console if we ask it
	// to unload a job that is not loaded.  To avoid that,
	BOOL isLoaded = [self isLoadedLabel:label] ;
	
	
	NSString* cmdPath = [[NSFileManager defaultManager] temporaryFilePath] ;
	// I presumed we need execute permissions, which we don't get from
	// -[NSString writeToFile::], so I do it this way:
	NSNumber* octal755 = [NSNumber numberWithUnsignedLong:0755] ;
	// Note that, in 0755, the 0 is a prefix which says to interpret the
	// remainder of the digits as octal, just as 0x is a prefix which says to
	// interpret the remainder of the digits as hexidecimal.  It's in the C
	// language standard!
	NSDictionary* attributes = [NSDictionary dictionaryWithObjectsAndKeys:
								octal755, NSFilePosixPermissions,
								nil] ;
	
	// Generate the command (cmd) as a multi-line string
	NSMutableString* formatString = [[NSMutableString alloc] init] ;
	[formatString appendString:
	 @"#!/bin/sh\n"                                       // shebang
	 @"PLIST_PATH=\"%@\"\n"                               // define environment variable
	 @"sleep %d\n" ] ;                                    // for optional delaySeconds
	if (isLoaded) {
		[formatString appendString:
		 @"/bin/launchctl unload -wF \"$PLIST_PATH\"\n"] ;    // Unload the agent
	}
	if (justReload) {
		[formatString appendString:
		 @"sleep 1\n"                                     // Seems like a good idea to wait here for launchd/launchctl to regain its bearings
		 @"/bin/launchctl load -wF \"$PLIST_PATH\"\n"] ;  // reload the agent
	}
	else {
		[formatString appendString:
		 @"rm \"$PLIST_PATH\"\n" ] ;                      // Remove the plist file
	}	
	[formatString appendString:
	 @"rm \"%@\"\n"] ;                                    // Remove this script's file (self-destruct)
	NSString* cmd = [NSString stringWithFormat:
					 formatString,
					 plistPath,
					 delaySeconds,
					 cmdPath] ;
	[formatString release] ;
	
	// Write the command to a file
	NSData* data = [cmd dataUsingEncoding:NSUTF8StringEncoding] ;
	[[NSFileManager defaultManager] createFileAtPath:cmdPath
											contents:data
										  attributes:attributes] ;
    NSTask* task = [[NSTask alloc] init] ;	
    [task setLaunchPath:cmdPath] ;
	[task launch] ;
	[task release] ;
		
	BOOL ok = YES ;
	
	if (timeout > 0.0) {
		SSYPathWaiter* waiter = [[SSYPathWaiter alloc] init] ;
		ok = [waiter blockUntilWatchFlags:SSYPathObserverChangeFlagsDelete
									 path:cmdPath
								  timeout:timeout] ;
		[waiter release] ;
	}
	
	return ok ;
}

+ (BOOL)removeAgentsWithGlob:(NSString*)glob
					 error_p:(NSError**)error_p {
	NSArray* arguments ;
	NSData* stderrData = nil ;
	NSError* error = nil ;
	NSInteger result ;
	
	// A little trick is used in this method.  NSTask bypasses the shell, which
	// provides globbing.  So we need to wrap both of our commands in a
	// /bin/sh/ -c command in order to support globbing.

	// Unload
	NSString* command = [NSString stringWithFormat:
						 @"/bin/launchctl unload %@",
						 glob] ;
	arguments = [NSArray arrayWithObjects:
				 @"-c",
				 command,
				 nil] ;
	result = [SSYShellTasker doShellTaskCommand:@"/bin/sh"
									  arguments:arguments
									inDirectory:[SSYLaunchdBasics homeLaunchAgentsPath]
									  stdinData:nil
								   stdoutData_p:NULL
								   stderrData_p:&stderrData
										timeout:3.0
										error_p:&error] ;
	// We allowed 3.0 seconds because it is important to unload jobs before removing their
	// plist files.  Otherwise you can't unload it due to "no such file or directory".

	// If there were no loaded jobs matching the given glob, then at this
	// point we will have result=0, error=nil, and
	// stderr=launchctl: Couldn't stat("/path/to/*whatever*.plist"): No such file or directory

	error = [self warnUserIfLaunchdHangInTaskResult:result
											  error:error] ;

	// Uninstall (Remove .plist file)
	if (result == 0) {
		NSString* command = [NSString stringWithFormat:
							 @"/bin/rm -f %@",
							 glob] ;
		arguments = [NSArray arrayWithObjects:
					 @"-c",
					 command,
					 nil] ;
		stderrData = nil ;
		error = nil ;
		
		result = [SSYShellTasker doShellTaskCommand:@"/bin/sh"
										  arguments:arguments
										inDirectory:[SSYLaunchdBasics homeLaunchAgentsPath]
										  stdinData:nil
									   stdoutData_p:NULL
									   stderrData_p:&stderrData
											timeout:0.0
											error_p:&error] ;
		// If there are no such files to remove, rm will return 0 because we used '-f'.
		if (result != 0) {
			// This is a real error
			if (error_p) {
				*error_p = SSYMakeError(773484, @"Failed to remove launchd jobs") ;
			}
		}
	}
	else {
		// ok=NO means that there may have been jobs to unload, but they were not unloaded.
		// In that case, we don't want to uninstall them because then we could never
		// unload them other than by logging out and back in.
		if (error_p) {
			*error_p = SSYMakeError(7378934, @"Failed to unload launchd jobs") ;
		}
	}
		
	if ((result != 0) && error_p) {
		*error_p = [*error_p errorByAddingUserInfoObject:error
												  forKey:@"NSTask Error"] ;
		*error_p = [*error_p errorByAddingUserInfoObject:[NSString stringWithDataUTF8:stderrData]
												  forKey:@"Command Stderr"] ;
	}
	
	return (result == 0) ;
}

+ (BOOL)tryAgentLoad:(BOOL)load
			   label:(NSString*)label
			 error_p:(NSError**)error_p {
	if (!label) {
		return YES ;
	}
	
	// For performance reasons, we check for the file first since
	// that should be much faster than "launchctl list".
	
	// This section was added in BookMacster 1.7.2/1.6.8
	// launchctl will log a message to stderr if we tell it to 
	// load a job for which there is no plist file
	NSString* filename = [label stringByAppendingPathExtension:@"plist"] ;
	NSString* directory = [SSYLaunchdBasics homeLaunchAgentsPath] ;
	NSString* plistPath = [directory stringByAppendingPathComponent:filename] ;
	if (load) {
		if (![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
			NSLog(@"Warning 147-7580 Cannot load nonexistent %@", plistPath) ;
			return YES ;
		}
	}
	
	NSArray* arguments ;
	NSInteger result ;
	
	// launchctl will log a stupid message to stderr if we tell it to 
	// unload a job which is not loaded.
	BOOL isLoaded = [self isLoadedLabel:label] ;

	if (load == isLoaded) {
		return YES ;
	}
	
	// If we haven't returned yet, proceed with the actual work of loading or unloading
	NSString* subcmd = load ? @"load" : @"unload" ;
	arguments = [NSArray arrayWithObjects:
				 subcmd,
				 @"-wF",
				 plistPath,
				 nil] ;
	
	NSError* error = nil ;
	result = [SSYShellTasker doShellTaskCommand:@"/bin/launchctl"
									  arguments:arguments
									inDirectory:nil
									  stdinData:nil
								   stdoutData_p:NULL
								   stderrData_p:NULL
										timeout:2.0  // Was 0.0 until BookMacster 1.7.2/1.6.8
										error_p:&error] ;

	error = [self warnUserIfLaunchdHangInTaskResult:result
											  error:error] ;

	if ((result != 0) && error_p) {
		*error_p = error ;
	}
	
	return (result == 0) ;
}


@end