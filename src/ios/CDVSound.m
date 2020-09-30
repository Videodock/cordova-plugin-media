/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at
 http://www.apache.org/licenses/LICENSE-2.0
 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVSound.h"
#import "CDVFile.h"
#import <AVFoundation/AVFoundation.h>
#include <math.h>

#define DOCUMENTS_SCHEME_PREFIX @"documents://"
#define HTTP_SCHEME_PREFIX @"http://"
#define HTTPS_SCHEME_PREFIX @"https://"
#define CDVFILE_PREFIX @"cdvfile://"

@implementation CDVSound

BOOL keepAvAudioSessionAlwaysActive = NO;

@synthesize soundCache, avSession, currMediaId, statusCallbackId;

-(void) pluginInitialize
{
    NSDictionary* settings = self.commandDelegate.settings;
    keepAvAudioSessionAlwaysActive = [[settings objectForKey:[@"KeepAVAudioSessionAlwaysActive" lowercaseString]] boolValue];
    if (keepAvAudioSessionAlwaysActive) {
        if ([self hasAudioSession]) {
            NSError* error = nil;
            if(![self.avSession setActive:YES error:&error]) {
                NSLog(@"Unable to activate session: %@", [error localizedFailureReason]);
            }
        }
    }
}

// Maps a url for a resource path for playing
// "Naked" resource paths are assumed to be from the www folder as its base
- (NSURL*)urlForPlaying:(NSString*)resourcePath
{
    NSURL* resourceURL = nil;

    if ([resourcePath hasPrefix:HTTP_SCHEME_PREFIX] || [resourcePath hasPrefix:HTTPS_SCHEME_PREFIX]) {
        // if it is a http url, use it
        NSLog(@"Will use resource '%@' from the Internet.", resourcePath);
        resourceURL = [NSURL URLWithString:resourcePath];
    }

    return resourceURL;
}

// Creates or gets the cached audio file resource object
- (CDVAudioFile*)audioFileForResource:(NSString*)resourcePath withId:(NSString*)mediaId doValidation:(BOOL)bValidate forRecording:(BOOL)bRecord suppressValidationErrors:(BOOL)bSuppress
{
    BOOL bError = NO;
    CDVMediaError errcode = MEDIA_ERR_NONE_SUPPORTED;
    NSString* errMsg = @"";
    CDVAudioFile* audioFile = nil;
    NSURL* resourceURL = nil;

    if ([self soundCache] == nil) {
        [self setSoundCache:[NSMutableDictionary dictionaryWithCapacity:1]];
    } else {
        audioFile = [[self soundCache] objectForKey:mediaId];
    }
    if (audioFile == nil) {
        // validate resourcePath and create
        if ((resourcePath == nil) || ![resourcePath isKindOfClass:[NSString class]] || [resourcePath isEqualToString:@""]) {
            bError = YES;
            errcode = MEDIA_ERR_ABORTED;
            errMsg = @"invalid media src argument";
        } else {
            audioFile = [[CDVAudioFile alloc] init];
            audioFile.resourcePath = resourcePath;
            audioFile.resourceURL = nil;  // validate resourceURL when actually play or record
            [[self soundCache] setObject:audioFile forKey:mediaId];
        }
    }
    if (bValidate && (audioFile.resourceURL == nil)) {
        resourceURL = [self urlForPlaying:resourcePath];
        if ((resourceURL == nil) && !bSuppress) {
            bError = YES;
            errcode = MEDIA_ERR_ABORTED;
            errMsg = [NSString stringWithFormat:@"Cannot use audio file from resource '%@'", resourcePath];
        } else {
            audioFile.resourceURL = resourceURL;
        }
    }

    if (bError) {
        [self onStatus:MEDIA_ERROR mediaId:mediaId param:
            [self createMediaErrorWithCode:errcode message:errMsg]];
    }

    return audioFile;
}

// Creates or gets the cached audio file resource object
- (CDVAudioFile*)audioFileForResource:(NSString*)resourcePath withId:(NSString*)mediaId doValidation:(BOOL)bValidate forRecording:(BOOL)bRecord
{
    return [self audioFileForResource:resourcePath withId:mediaId doValidation:bValidate forRecording:bRecord suppressValidationErrors:NO];
}

// returns whether or not audioSession is available - creates it if necessary
- (BOOL)hasAudioSession
{
    BOOL bSession = YES;

    if (!self.avSession) {
        NSError* error = nil;

        self.avSession = [AVAudioSession sharedInstance];
        if (error) {
            // is not fatal if can't get AVAudioSession , just log the error
            NSLog(@"error creating audio session: %@", [[error userInfo] description]);
            self.avSession = nil;
            bSession = NO;
        }
    }
    return bSession;
}

// helper function to create a error object string
- (NSDictionary*)createMediaErrorWithCode:(CDVMediaError)code message:(NSString*)message
{
    NSMutableDictionary* errorDict = [NSMutableDictionary dictionaryWithCapacity:2];

    [errorDict setObject:[NSNumber numberWithUnsignedInteger:code] forKey:@"code"];
    [errorDict setObject:message ? message:@"" forKey:@"message"];
    return errorDict;
}

//helper function to create specifically an abort error
-(NSDictionary*)createAbortError:(NSString*)message
{
  return [self createMediaErrorWithCode:MEDIA_ERR_ABORTED message:message];
}

- (void)create:(CDVInvokedUrlCommand*)command
{
    NSString* mediaId = [command argumentAtIndex:0];
    NSString* resourcePath = [command argumentAtIndex:1];

    CDVAudioFile* audioFile = [self audioFileForResource:resourcePath withId:mediaId doValidation:YES forRecording:NO suppressValidationErrors:YES];

    if (audioFile == nil) {
        NSString* errorMessage = [NSString stringWithFormat:@"Failed to initialize Media file with path %@", resourcePath];
        [self onStatus:MEDIA_ERROR mediaId:mediaId param:
          [self createAbortError:errorMessage]];
    } else {
        NSURL* resourceUrl = audioFile.resourceURL;

        if (![resourceUrl isFileURL] && ![resourcePath hasPrefix:CDVFILE_PREFIX]) {
            // First create an AVPlayerItem
            AVPlayerItem* playerItem = [AVPlayerItem playerItemWithURL:resourceUrl];

            // Subscribe to the AVPlayerItem's DidPlayToEndTime notification.
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemDidFinishPlaying:) name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];

            // Subscribe to the AVPlayerItem's PlaybackStalledNotification notification.
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemStalledPlaying:) name:AVPlayerItemPlaybackStalledNotification object:playerItem];

            // Pass the AVPlayerItem to a new player
            avPlayer = [[AVPlayer alloc] initWithPlayerItem:playerItem];

            // Avoid excessive buffering so streaming media can play instantly on iOS
            // Removes preplay delay on ios 10+, makes consistent with ios9 behaviour
            if ([NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){10,0,0}]) {
                avPlayer.automaticallyWaitsToMinimizeStalling = NO;
            }
        }

        self.currMediaId = mediaId;

        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }
}

- (void)setVolume:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;

#pragma unused(callbackId)
    NSString* mediaId = [command argumentAtIndex:0];
    NSNumber* volume = [command argumentAtIndex:1 withDefault:[NSNumber numberWithFloat:1.0]];

    if ([self soundCache] != nil) {
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
        if (audioFile != nil) {
            audioFile.volume = volume;
            if (audioFile.player) {
                audioFile.player.volume = [volume floatValue];
            }
            else {
                float customVolume = [volume floatValue];
                if (customVolume >= 0.0 && customVolume <= 1.0) {
                    [avPlayer setVolume: customVolume];
                }
                else {
                    NSLog(@"The value must be within the range of 0.0 to 1.0");
                }
            }
            [[self soundCache] setObject:audioFile forKey:mediaId];
        }
    }

    // don't care for any callbacks
}

- (void)setRate:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;

#pragma unused(callbackId)
    NSString* mediaId = [command argumentAtIndex:0];
    NSNumber* rate = [command argumentAtIndex:1 withDefault:[NSNumber numberWithFloat:1.0]];

    if ([self soundCache] != nil) {
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
        if (audioFile != nil) {
            audioFile.rate = rate;
            if (audioFile.player) {
                audioFile.player.enableRate = YES;
                audioFile.player.rate = [rate floatValue];
            }
            if (avPlayer.currentItem && avPlayer.currentItem.asset){
                float customRate = [rate floatValue];
                [avPlayer setRate:customRate];
            }

            [[self soundCache] setObject:audioFile forKey:mediaId];
        }
    }

    // don't care for any callbacks
}

- (void)startPlayingAudio:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{

    NSString* callbackId = command.callbackId;

#pragma unused(callbackId)
    NSString* mediaId = [command argumentAtIndex:0];
    NSString* resourcePath = [command argumentAtIndex:1];
    NSDictionary* options = [command argumentAtIndex:2 withDefault:nil];

    BOOL bError = NO;

    CDVAudioFile* audioFile = [self audioFileForResource:resourcePath withId:mediaId doValidation:YES forRecording:NO];
    if ((audioFile != nil) && (audioFile.resourceURL != nil)) {
        if (audioFile.player == nil) {
            bError = [self prepareToPlay:audioFile withId:mediaId];
        }
        if (!bError) {
            //self.currMediaId = audioFile.player.mediaId;
            self.currMediaId = mediaId;

            // audioFile.player != nil  or player was successfully created
            // get the audioSession and set the category to allow Playing when device is locked or ring/silent switch engaged
            if ([self hasAudioSession]) {
                NSError* __autoreleasing err = nil;
                NSNumber* playAudioWhenScreenIsLocked = [options objectForKey:@"playAudioWhenScreenIsLocked"];
                BOOL bPlayAudioWhenScreenIsLocked = YES;
                if (playAudioWhenScreenIsLocked != nil) {
                    bPlayAudioWhenScreenIsLocked = [playAudioWhenScreenIsLocked boolValue];
                }

                NSString* sessionCategory = bPlayAudioWhenScreenIsLocked ? AVAudioSessionCategoryPlayback : AVAudioSessionCategorySoloAmbient;
                [self.avSession setCategory:sessionCategory error:&err];
                if (![self.avSession setActive:YES error:&err]) {
                    // other audio with higher priority that does not allow mixing could cause this to fail
                    NSLog(@"Unable to play audio: %@", [err localizedFailureReason]);
                    bError = YES;
                }
            }
            if (!bError) {
                NSLog(@"Playing audio sample '%@'", audioFile.resourcePath);
                double duration = 0;
                if (avPlayer.currentItem && avPlayer.currentItem.asset) {
                    CMTime time = avPlayer.currentItem.asset.duration;
                    duration = CMTimeGetSeconds(time);
                    if (isnan(duration)) {
                        NSLog(@"Duration is infifnite, setting it to -1");
                        duration = -1;
                    }

                    if (audioFile.rate != nil){
                        float customRate = [audioFile.rate floatValue];
                        NSLog(@"Playing stream with AVPlayer & custom rate");
                        [avPlayer setRate:customRate];
                    } else {
                        NSLog(@"Playing stream with AVPlayer & default rate");
                        [avPlayer play];
                    }

                } else {

                    NSNumber* loopOption = [options objectForKey:@"numberOfLoops"];
                    NSInteger numberOfLoops = 0;
                    if (loopOption != nil) {
                        numberOfLoops = [loopOption intValue] - 1;
                    }
                    audioFile.player.numberOfLoops = numberOfLoops;
                    if (audioFile.player.isPlaying) {
                        [audioFile.player stop];
                        audioFile.player.currentTime = 0;
                    }
                    if (audioFile.volume != nil) {
                        audioFile.player.volume = [audioFile.volume floatValue];
                    }

                    audioFile.player.enableRate = YES;
                    if (audioFile.rate != nil) {
                        audioFile.player.rate = [audioFile.rate floatValue];
                    }

                    [audioFile.player play];
                    duration = round(audioFile.player.duration * 1000) / 1000;
                }

                [self onStatus:MEDIA_DURATION mediaId:mediaId param:@(duration)];
                [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_RUNNING)];
            }
        }
        if (bError) {
            /*  I don't see a problem playing previously recorded audio so removing this section - BG
            NSError* error;
            // try loading it one more time, in case the file was recorded previously
            audioFile.player = [[ AVAudioPlayer alloc ] initWithContentsOfURL:audioFile.resourceURL error:&error];
            if (error != nil) {
                NSLog(@"Failed to initialize AVAudioPlayer: %@\n", error);
                audioFile.player = nil;
            } else {
                NSLog(@"Playing audio sample '%@'", audioFile.resourcePath);
                audioFile.player.numberOfLoops = numberOfLoops;
                [audioFile.player play];
            } */
            // error creating the session or player
            [self onStatus:MEDIA_ERROR mediaId:mediaId
              param:[self createMediaErrorWithCode:MEDIA_ERR_NONE_SUPPORTED message:nil]];
        }
    }
    // else audioFile was nil - error already returned from audioFile for resource
    return;

    }];
}

- (BOOL)prepareToPlay:(CDVAudioFile*)audioFile withId:(NSString*)mediaId
{
    BOOL bError = NO;
    NSError* __autoreleasing playerError = nil;

    // create the player
    NSURL* resourceURL = audioFile.resourceURL;

    if ([resourceURL isFileURL]) {
        audioFile.player = [[CDVAudioPlayer alloc] initWithContentsOfURL:resourceURL error:&playerError];
    } else {
        /*
        NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:resourceURL];
        NSString* userAgent = [self.commandDelegate userAgent];
        if (userAgent) {
            [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
        }
        NSURLResponse* __autoreleasing response = nil;
        NSData* data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&playerError];
        if (playerError) {
            NSLog(@"Unable to download audio from: %@", [resourceURL absoluteString]);
        } else {
            // bug in AVAudioPlayer when playing downloaded data in NSData - we have to download the file and play from disk
            CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
            CFStringRef uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuidRef);
            NSString* filePath = [NSString stringWithFormat:@"%@/%@", [NSTemporaryDirectory()stringByStandardizingPath], uuidString];
            CFRelease(uuidString);
            CFRelease(uuidRef);
            [data writeToFile:filePath atomically:YES];
            NSURL* fileURL = [NSURL fileURLWithPath:filePath];
            audioFile.player = [[CDVAudioPlayer alloc] initWithContentsOfURL:fileURL error:&playerError];
        }
        */
    }

    if (playerError != nil) {
        NSLog(@"Failed to initialize AVAudioPlayer: %@\n", [playerError localizedDescription]);
        audioFile.player = nil;
        if (! keepAvAudioSessionAlwaysActive && self.avSession && ! [self isPlayingOrRecording]) {
            [self.avSession setActive:NO error:nil];
        }
        bError = YES;
    } else {
        audioFile.player.mediaId = mediaId;
        audioFile.player.delegate = self;
        if (avPlayer == nil)
            bError = ![audioFile.player prepareToPlay];
    }
    return bError;
}

- (void)stopPlayingAudio:(CDVInvokedUrlCommand*)command
{
    NSString* mediaId = [command argumentAtIndex:0];
    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];

    if ((audioFile != nil) && (audioFile.player != nil)) {
        NSLog(@"Stopped playing audio sample '%@'", audioFile.resourcePath);
        [audioFile.player stop];
        audioFile.player.currentTime = 0;
        [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_STOPPED)];
    }
    // seek to start and pause
    if (avPlayer.currentItem && avPlayer.currentItem.asset) {
        BOOL isReadyToSeek = (avPlayer.status == AVPlayerStatusReadyToPlay) && (avPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay);
        if (isReadyToSeek) {
            [avPlayer seekToTime: kCMTimeZero
                 toleranceBefore: kCMTimeZero
                  toleranceAfter: kCMTimeZero
               completionHandler: ^(BOOL finished){
                   if (finished) [avPlayer pause];
               }];
            [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_STOPPED)];
        } else {
            // cannot seek, wrong state
            CDVMediaError errcode = MEDIA_ERR_NONE_ACTIVE;
            NSString* errMsg = @"Cannot service stop request until the avPlayer is in 'AVPlayerStatusReadyToPlay' state.";
            [self onStatus:MEDIA_ERROR mediaId:mediaId param:
              [self createMediaErrorWithCode:errcode message:errMsg]];
        }
    }
}

- (void)pausePlayingAudio:(CDVInvokedUrlCommand*)command
{
    NSString* mediaId = [command argumentAtIndex:0];
    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];

    if ((audioFile != nil) && ((audioFile.player != nil) || (avPlayer != nil))) {
        NSLog(@"Paused playing audio sample '%@'", audioFile.resourcePath);
        if (audioFile.player != nil) {
            [audioFile.player pause];
        } else if (avPlayer != nil) {
            [avPlayer pause];
        }

        [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_PAUSED)];
    }
}

- (void)seekToAudio:(CDVInvokedUrlCommand*)command
{
    // args:
    // 0 = Media id
    // 1 = seek to location in milliseconds

    NSString* mediaId = [command argumentAtIndex:0];

    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    double position = [[command argumentAtIndex:1] doubleValue];
    double posInSeconds = position / 1000;

    if ((audioFile != nil) && (audioFile.player != nil)) {

        if (posInSeconds >= audioFile.player.duration) {
            // The seek is past the end of file.  Stop media and reset to beginning instead of seeking past the end.
            [audioFile.player stop];
            audioFile.player.currentTime = 0;
            [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_STOPPED)];
        } else {
            audioFile.player.currentTime = posInSeconds;
            [self onStatus:MEDIA_POSITION mediaId:mediaId param:@(posInSeconds)];
        }

    } else if (avPlayer != nil) {
        int32_t timeScale = avPlayer.currentItem.asset.duration.timescale;
        CMTime timeToSeek = CMTimeMakeWithSeconds(posInSeconds, MAX(1, timeScale));

        BOOL isPlaying = (avPlayer.rate > 0 && !avPlayer.error);
        BOOL isReadyToSeek = (avPlayer.status == AVPlayerStatusReadyToPlay) && (avPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay);

        // CB-10535:
        // When dealing with remote files, we can get into a situation where we start playing before AVPlayer has had the time to buffer the file to be played.
        // To avoid the app crashing in such a situation, we only seek if both the player and the player item are ready to play. If not ready, we send an error back to JS land.
        if(isReadyToSeek) {
            if (avPlayer.currentItem.seekableTimeRanges.count == 0) {
                return;
            }

            CMTimeRange range = [[avPlayer.currentItem.seekableTimeRanges lastObject] CMTimeRangeValue];
            CMTime maxTime = range.duration;

            if (CMTimeGetSeconds(timeToSeek) > CMTimeGetSeconds(maxTime)) {
                timeToSeek = maxTime;
            }

            [avPlayer seekToTime: timeToSeek
                 toleranceBefore: kCMTimeZero
                  toleranceAfter: kCMTimeZero
               completionHandler: ^(BOOL finished) {
                   if (isPlaying) [avPlayer play];
               }];
        } else {
            NSString* errMsg = @"AVPlayerItem cannot service a seek request with a completion handler until its status is AVPlayerItemStatusReadyToPlay.";
            [self onStatus:MEDIA_ERROR mediaId:mediaId param:
              [self createAbortError:errMsg]];
        }
    }
}


- (void)release:(CDVInvokedUrlCommand*)command
{
    NSString* mediaId = [command argumentAtIndex:0];
    //NSString* mediaId = self.currMediaId;

    if (mediaId != nil) {
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];

        if (audioFile != nil) {
            if (audioFile.player && [audioFile.player isPlaying]) {
                [audioFile.player stop];
            }
            if (avPlayer != nil) {
                [avPlayer pause];
                avPlayer = nil;
            }
            if (! keepAvAudioSessionAlwaysActive && self.avSession && ! [self isPlayingOrRecording]) {
                [self.avSession setActive:NO error:nil];
                self.avSession = nil;
            }
            [[self soundCache] removeObjectForKey:mediaId];
            NSLog(@"Media with id %@ released", mediaId);
        }
    }
}

- (void)getCurrentPositionAudio:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    NSString* mediaId = [command argumentAtIndex:0];

#pragma unused(mediaId)
    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    double position = -1;

    if ((audioFile != nil) && (audioFile.player != nil) && [audioFile.player isPlaying]) {
        position = round(audioFile.player.currentTime * 1000) / 1000;
    }
    if (avPlayer) {
       CMTime time = [avPlayer currentTime];
       position = CMTimeGetSeconds(time);
    }

    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:position];

    [self onStatus:MEDIA_POSITION mediaId:mediaId param:@(position)];
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer*)player successfully:(BOOL)flag
{
    //commented as unused
    CDVAudioPlayer* aPlayer = (CDVAudioPlayer*)player;
    NSString* mediaId = aPlayer.mediaId;
    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];

    if (audioFile != nil) {
        NSLog(@"Finished playing audio sample '%@'", audioFile.resourcePath);
    }
    if (flag) {
        audioFile.player.currentTime = 0;
        [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_STOPPED)];
    } else {
        [self onStatus:MEDIA_ERROR mediaId:mediaId param:
            [self createMediaErrorWithCode:MEDIA_ERR_DECODE message:nil]];
    }
     if (! keepAvAudioSessionAlwaysActive && self.avSession && ! [self isPlayingOrRecording]) {
         [self.avSession setActive:NO error:nil];
     }
}

-(void)itemDidFinishPlaying:(NSNotification *) notification {
    // Will be called when AVPlayer finishes playing playerItem
    NSString* mediaId = self.currMediaId;

     if (! keepAvAudioSessionAlwaysActive && self.avSession && ! [self isPlayingOrRecording]) {
         [self.avSession setActive:NO error:nil];
     }
    [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_STOPPED)];
}

-(void)itemStalledPlaying:(NSNotification *) notification {
    // Will be called when playback stalls due to buffer empty
    NSLog(@"Stalled playback");
}

- (void)onMemoryWarning
{
    /* https://issues.apache.org/jira/browse/CB-11513 */
    NSMutableArray* keysToRemove = [[NSMutableArray alloc] init];

    for(id key in [self soundCache]) {
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:key];
        if (audioFile != nil) {
            if (audioFile.player != nil && ![audioFile.player isPlaying]) {
                [keysToRemove addObject:key];
            }
        }
    }

    [[self soundCache] removeObjectsForKeys:keysToRemove];

    // [[self soundCache] removeAllObjects];
    // [self setSoundCache:nil];
    [self setAvSession:nil];

    [super onMemoryWarning];
}


- (void)dealloc
{
    [[self soundCache] removeAllObjects];
}

- (void)onReset
{
    for (CDVAudioFile* audioFile in [[self soundCache] allValues]) {
        if (audioFile != nil) {
            if (audioFile.player != nil) {
                [audioFile.player stop];
                audioFile.player.currentTime = 0;
            }
        }
    }

    [[self soundCache] removeAllObjects];
}

- (void)getCurrentAmplitudeAudio:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    NSString* mediaId = [command argumentAtIndex:0];

#pragma unused(mediaId)
    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    float amplitude = 0; // The linear 0.0 .. 1.0 value

    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:amplitude];
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
 }

- (void)messageChannel:(CDVInvokedUrlCommand*)command
{
    self.statusCallbackId = command.callbackId;
}

- (void)onStatus:(CDVMediaMsg)what mediaId:(NSString*)mediaId param:(NSObject*)param
{
    if (self.statusCallbackId!=nil) { //new way, android,windows compatible
        NSMutableDictionary* status=[NSMutableDictionary dictionary];
        status[@"msgType"] = @(what);
        //in the error case contains a dict with "code" and "message"
        //otherwise a NSNumber
        status[@"value"] = param;
        status[@"id"] = mediaId;
        NSMutableDictionary* dict=[NSMutableDictionary dictionary];
        dict[@"action"] = @"status";
        dict[@"status"] = status;
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:dict];
        [result setKeepCallbackAsBool:YES]; //we keep this forever
        [self.commandDelegate sendPluginResult:result callbackId:self.statusCallbackId];
    } else { //old school evalJs way
        if (what==MEDIA_ERROR) {
            NSData* jsonData = [NSJSONSerialization dataWithJSONObject:param options:0 error:nil];
            param=[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }
        NSString* jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);",
              @"cordova.require('cordova-plugin-media.Media').onStatus",
              mediaId, (int)what, param];
        [self.commandDelegate evalJs:jsString];
    }
}

-(BOOL) isPlayingOrRecording
{
    for(NSString* mediaId in soundCache) {
        CDVAudioFile* audioFile = [soundCache objectForKey:mediaId];
        if (audioFile.player && [audioFile.player isPlaying]) {
            return true;
        }
    }
    return false;
}

@end

@implementation CDVAudioFile

@synthesize resourcePath;
@synthesize resourceURL;
@synthesize player, volume, rate;

@end
@implementation CDVAudioPlayer
@synthesize mediaId;

@end

