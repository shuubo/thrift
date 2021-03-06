/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements. See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership. The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License. You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

#import <Foundation/Foundation.h>
#import "TSocketServer.h"
#import "TNSFileHandleTransport.h"
#import "TProtocol.h"
#import "TTransportException.h"
#import "TObjective-C.h"
#import <sys/socket.h>
#include <netinet/in.h>
#include <stdio.h>
#include <arpa/inet.h>


NSString * const kTSocketServer_ClientConnectionFinishedForProcessorNotification = @"TSocketServer_ClientConnectionFinishedForProcessorNotification";
NSString * const kTSocketServer_ProcessorKey = @"TSocketServer_Processor";
NSString * const kTSockerServer_TransportKey = @"TSockerServer_Transport";


@implementation TSocketServer

- (id) initWithPort: (int) port
    protocolFactory: (id <TProtocolFactory>) protocolFactory
   processorFactory: (id <TProcessorFactory>) processorFactory;
{
  return [self initWithPort:port protocolFactory:protocolFactory processorFactory:processorFactory singleThreaded:NO];
}

- (id) initWithPort: (int) port
protocolFactory: (id <TProtocolFactory>) protocolFactory
processorFactory: (id <TProcessorFactory>) processorFactory
singleThreaded: (BOOL)aBool;
{
  self = [super init];
    
  isObserving = NO;
  singleThreaded = aBool;
  mInputProtocolFactory = [protocolFactory retain_stub];
  mOutputProtocolFactory = [protocolFactory retain_stub];
  mProcessorFactory = [processorFactory retain_stub];


  int err = 0;
  int fd = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (!fd) {
    perror("socket");
    return nil;
  }
  int yes = 1;
  err = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (void *)&yes, sizeof(yes));
  if (err) {
    perror("setsockopt");
    return nil;
  }
    
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_len = sizeof(addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  //addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    
  err = bind(fd, (struct sockaddr*) &addr, sizeof(addr));
  if (err) {
    perror("bind");
    return nil;
  }
    
  err = listen(fd, 1);
  if (err) {
    perror("listen");
    return nil;
  }

  // wrap it in a file handle so we can get messages from it
  mSocketFileHandle = [[NSFileHandle alloc] initWithFileDescriptor: fd
                                                    closeOnDealloc: YES];

  // register for notifications of accepted incoming connections
  [[NSNotificationCenter defaultCenter] addObserver: self
                                           selector: @selector(connectionAccepted:)
                                               name: NSFileHandleConnectionAcceptedNotification
                                             object: mSocketFileHandle];
  isObserving = YES;
  
  // tell socket to listen
  [mSocketFileHandle acceptConnectionInBackgroundAndNotify];
  
  NSLog(@"Listening on TCP port %d", port);
  
  return self;
}


- (void) dealloc
{
  if (isObserving) [[NSNotificationCenter defaultCenter] removeObject: self];
  [mInputProtocolFactory release_stub];
  [mOutputProtocolFactory release_stub];
  [mProcessorFactory release_stub];
  [mSocketFileHandle release_stub];
  [super dealloc_stub];
}


- (void) connectionAccepted: (NSNotification *) aNotification
{
  NSFileHandle * socket = [[aNotification userInfo] objectForKey: NSFileHandleNotificationFileHandleItem];

  // now that we have a client connected, spin off a thread to handle activity
  if (!singleThreaded) {
    [NSThread detachNewThreadSelector: @selector(handleClientConnection:)
			     toTarget: self
			   withObject: socket];
  }
  else {
    [self handleClientConnection:socket];
  }

  [[aNotification object] acceptConnectionInBackgroundAndNotify];
}


- (void) handleClientConnection: (NSFileHandle *) clientSocket
{
#if __has_feature(objc_arc)
    @autoreleasepool {
        TNSFileHandleTransport * transport = [[TNSFileHandleTransport alloc] initWithFileHandle: clientSocket];
        id<TProcessor> processor = [mProcessorFactory processorForTransport: transport];
        
        id <TProtocol> inProtocol = [mInputProtocolFactory newProtocolOnTransport: transport];
        id <TProtocol> outProtocol = [mOutputProtocolFactory newProtocolOnTransport: transport];
        
        @try {
            BOOL result = NO;
            do {
                @autoreleasepool {
                    result = [processor processOnInputProtocol: inProtocol outputProtocol: outProtocol];
                }
            } while (result);
        }
        @catch (TTransportException * te) {
	  //NSLog(@"Caught transport exception, abandoning client connection: %@", te);
	  [clientSocket closeFile];
        }
    }
#else
  NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
  
  TNSFileHandleTransport * transport = [[TNSFileHandleTransport alloc] initWithFileHandle: clientSocket];
  id<TProcessor> processor = [mProcessorFactory processorForTransport: transport];
  
  id <TProtocol> inProtocol = [[mInputProtocolFactory newProtocolOnTransport: transport] autorelease];
  id <TProtocol> outProtocol = [[mOutputProtocolFactory newProtocolOnTransport: transport] autorelease];

  @try {
    BOOL result = NO;
    do {
      NSAutoreleasePool * myPool = [[NSAutoreleasePool alloc] init];
      result = [processor processOnInputProtocol: inProtocol outputProtocol: outProtocol];
      [myPool release];
    } while (result);
  }
  @catch (TTransportException * te) {
    //NSLog(@"Caught transport exception, abandoning client connection: %@", te);
    [clientSocket closeFile];
  }
  [pool release];
#endif
}



@end



