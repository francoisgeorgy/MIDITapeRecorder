//
//  DSPKernelAdapter.h
//  MIDI Tape Recorder Plugin
//
//  Created by Geert Bevin on 11/27/21.
//  MIDI Tape Recorder ©2021 by Geert Bevin is licensed under CC BY 4.0
//

#import <AudioToolbox/AudioToolbox.h>

#import "MidiRecorderState.h"
#import "AudioUnitIOState.h"

@interface DSPKernelAdapter : NSObject

@property(nonatomic) AUAudioFrameCount maximumFramesToRender;
@property(nonatomic, readonly) AUAudioUnitBus* outputBus;

- (MidiRecorderState*)state;
- (AudioUnitIOState*)ioState;

- (void)setParameter:(AUParameter*)parameter value:(AUValue)value;
- (AUValue)valueForParameter:(AUParameter*)parameter;

- (void)allocateRenderResources;
- (void)deallocateRenderResources;
- (AUInternalRenderBlock)internalRenderBlock;

@end
