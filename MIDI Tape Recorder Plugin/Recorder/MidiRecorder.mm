//
//  MidiRecorder.mm
//  MIDI Tape Recorder Plugin
//
//  Created by Geert Bevin on 12/1/21.
//  MIDI Tape Recorder ©2021 by Geert Bevin is licensed under CC BY 4.0
//

#import "MidiRecorder.h"

#import <CoreAudioKit/CoreAudioKit.h>

#include "Constants.h"
#include "MidiHelper.h"
#include "MidiRecorderState.h"
#include "RecordedMidiMessage.h"

@implementation MidiRecorder {
    dispatch_queue_t _dispatchQueue;
    
    MidiRecorderState* _state;
    
    int16_t _lastRpnMsb[16];
    int16_t _lastRpnLsb[16];
    int16_t _lastDataMsb[16];
    int16_t _lastDataLsb[16];

    std::unique_ptr<std::vector<RecordedMidiMessage>> _recording;
    std::unique_ptr<std::vector<int>> _recordingBeatToIndex;
    
    NSMutableData* _recordingPreview;
    double _recordingDuration;
    
    // we store the recorded preview here because it's not accessed by the audio callback thread
    // and it's easier to keep it in Objective C with ARC
    NSData* _recordedPreview;
}

- (instancetype)initWithOrdinal:(int)ordinal {
    self = [super init];
    
    if (self) {
        _ordinal = ordinal;
        _dispatchQueue = dispatch_queue_create([NSString stringWithFormat:@"com.uwyn.midirecorder.Recording%d", ordinal].UTF8String, DISPATCH_QUEUE_CONCURRENT);
        
        _state = nil;
        
        for (int ch = 0; ch < 16; ++ch) {
            _lastRpnMsb[ch] = 0x7f;
            _lastRpnLsb[ch] = 0x7f;
            _lastDataMsb[ch] = 0;
            _lastDataLsb[ch] = 0;
        }
        
        _recording.reset(new std::vector<RecordedMidiMessage>());
        _recordingBeatToIndex.reset(new std::vector<int>());
        
        _recordingPreview = [NSMutableData new];
        _recordingDuration = 0.0;
        
        _recordedPreview = nil;
    }
    
    return self;
}

#pragma mark Transport

- (void)setRecord:(BOOL)record {
    dispatch_barrier_sync(_dispatchQueue, ^{
        if (_record == record) {
            return;
        }
        
        _record = record;
        
        if (record == NO) {
            // when recording is stopped, we move the recording data to the recorded data
            auto recorded = std::move(_recording);
            auto recorded_beat_index = std::move(_recordingBeatToIndex);
            double recorded_duration = _recordingDuration;
            if (_state->autoTrimRecordings && recorded && !recorded->empty()) {
                recorded_duration = ceil(recorded->back().offsetBeats);
            }
            _recordedPreview = _recordingPreview;

            _recording.reset(new std::vector<RecordedMidiMessage>());
            _recordingBeatToIndex.reset(new std::vector<int>());
            _recordingPreview = [NSMutableData new];
            _recordingDuration = 0.0;

            if (_delegate) {
                [_delegate finishRecording:_ordinal
                                      data:std::move(recorded)
                               beatToIndex:std::move(recorded_beat_index)
                                  duration:recorded_duration];
            }
        }
        else {
            if (_delegate) {
                [_delegate invalidateRecording:_ordinal];
            }
        }
    });
}

#pragma mark State

- (NSDictionary*)recordedAsDict {
    __block NSDictionary* result;
    
    dispatch_barrier_sync(_dispatchQueue, ^{
        MidiTrackState& state = _state->track[_ordinal];
        auto recorded = state.recordedMessages.get();
        auto recorded_beatindex = state.recordedBeatToIndex.get();
        if (recorded == nullptr) {
            result = @{};
        }
        else {
            NSData* recorded_data = [NSData dataWithBytes:recorded->data()
                                                   length:recorded->size() * sizeof(RecordedMidiMessage)];
            NSData* recorded_beatindex_data = [NSData dataWithBytes:recorded_beatindex->data()
                                                             length:recorded_beatindex->size() * sizeof(int)];
            result = @{
                @"Recorded" : recorded_data,
                @"BeatToIndex" : recorded_beatindex_data,
                @"Duration" : @(state.recordedDuration.load()),
                @"MPE" : @{
                    @"zone1Members" : @(state.mpeState.zone1Members.load()),
                    @"zone1ManagerPitchSens" : @(state.mpeState.zone1ManagerPitchSens.load()),
                    @"zone1MemberPitchSens" : @(state.mpeState.zone1MemberPitchSens.load()),
                    @"zone2Members" : @(state.mpeState.zone2Members.load()),
                    @"zone2ManagerPitchSens" : @(state.mpeState.zone2ManagerPitchSens.load()),
                    @"zone2MemberPitchSens" : @(state.mpeState.zone2MemberPitchSens.load()),
                }
            };
        }
    });
    
    return result;
}

- (void)dictToRecorded:(NSDictionary*)dict {
    dispatch_barrier_sync(_dispatchQueue, ^{
        std::unique_ptr<std::vector<RecordedMidiMessage>> recorded(new std::vector<RecordedMidiMessage>());
        std::unique_ptr<std::vector<int>> recorded_beatindex(new std::vector<int>());
        double recorded_duration = 0.0;
        _recordedPreview = nil;

        NSData* recorded_data = [dict objectForKey:@"Recorded"];
        if (recorded_data) {
            RecordedMidiMessage* data = (RecordedMidiMessage*)recorded_data.bytes;
            unsigned long count = recorded_data.length / sizeof(RecordedMidiMessage);
            recorded->assign(data, data + count);
        }
        
        NSData* recorded_beatindex_data = [dict objectForKey:@"BeatToIndex"];
        if (recorded_beatindex_data) {
            recorded_beatindex.reset(new std::vector<int>());
            int* data = (int*)recorded_beatindex_data.bytes;
            unsigned long count = recorded_beatindex_data.length / sizeof(int);
            recorded_beatindex->assign(data, data + count);
        }

        id duration = [dict objectForKey:@"Duration"];
        if (duration) {
            recorded_duration = [duration doubleValue];
            if (_state->autoTrimRecordings) {
                recorded_duration = ceil(recorded_duration);
            }
        }
        
        NSDictionary* mpe = [dict objectForKey:@"MPE"];
        if (mpe) {
            MPEState& mpe_state = _state->track[_ordinal].mpeState;
            
            NSNumber* zone1_members = [mpe objectForKey:@"zone1Members"];
            if (zone1_members) {
                mpe_state.zone1Members = zone1_members.intValue;
                mpe_state.zone1Active = (mpe_state.zone1Members != 0);
            }

            NSNumber* zone1_manager_pitch = [mpe objectForKey:@"zone1ManagerPitchSens"];
            if (zone1_manager_pitch) {
                mpe_state.zone1ManagerPitchSens = zone1_manager_pitch.floatValue;
            }

            NSNumber* zone1_member_pitch = [mpe objectForKey:@"zone1MemberPitchSens"];
            if (zone1_member_pitch) {
                mpe_state.zone1MemberPitchSens = zone1_member_pitch.floatValue;
            }

            NSNumber* zone2_members = [mpe objectForKey:@"zone2Members"];
            if (zone2_members) {
                mpe_state.zone2Members = zone2_members.intValue;
                mpe_state.zone2Active = (mpe_state.zone2Members != 0);
            }

            NSNumber* zone2_manager_pitch = [mpe objectForKey:@"zone2ManagerPitchSens"];
            if (zone2_manager_pitch) {
                mpe_state.zone2ManagerPitchSens = zone2_manager_pitch.floatValue;
            }

            NSNumber* zone2_member_pitch = [mpe objectForKey:@"zone2MemberPitchSens"];
            if (zone2_member_pitch) {
                mpe_state.zone2MemberPitchSens = zone2_member_pitch.floatValue;
            }

            mpe_state.enabled = (mpe_state.zone1Active || mpe_state.zone2Active);
        }
        
        id preview = [NSMutableData new];
        if (recorded) {
            for (int m = 0; m < recorded->size(); ++m) {
                // update preview
                [self updatePreview:preview withMessage:recorded->at(m)];
            }
        }
        _recordedPreview = preview;

        if (_delegate) {
            [_delegate finishRecording:_ordinal
                                  data:std::move(recorded)
                           beatToIndex:std::move(recorded_beatindex)
                              duration:recorded_duration];
        }
    });
}

#pragma mark MIDI files

- (NSData*)recordedAsMidiTrackChunk {
    MidiTrackState& state = _state->track[_ordinal];
    auto recorded = state.recordedMessages.get();
    if (!recorded || recorded->empty()) {
        return nil;
    }

    // accumulate the track data in a seperate object so that
    // we can provide the length before adding its data
    NSMutableData* track = [NSMutableData new];

    // add tempo to track
    writeMidiVarLen(track, 0);
    // we can't have more than 0xffffff microseconds per beat
    int32_t beat_micros = MIN(1000000.0 * 60.0 / _state->tempo, 0xffffff);
    uint8_t meta_tempo[] = { 0xff, 0x51, 0x03 };
    [track appendBytes:&meta_tempo[0] length:3];
    uint8_t bm1 = (beat_micros >> 16) & 0xff;
    [track appendBytes:&bm1 length:1];
    uint8_t bm2 = (beat_micros >> 8) & 0xff;
    [track appendBytes:&bm2 length:1];
    uint8_t bm3 = beat_micros & 0xff;
    [track appendBytes:&bm3 length:1];

    // add midi events to track
    int64_t last_offset_ticks = 0;
    for (uint32_t i = 0; i < recorded->size(); ++i) {
        const RecordedMidiMessage& message = recorded->at(i);
        int64_t offset_ticks = int64_t(message.offsetBeats * MIDI_BEAT_TICKS);
        uint32_t delta_ticks = uint32_t(offset_ticks - last_offset_ticks);
        writeMidiVarLen(track, delta_ticks);
        for (int d = 0; d < message.length; ++d) {
            [track appendBytes:&message.data[d] length:1];
        }
        
        last_offset_ticks = offset_ticks;
    }
    
    // add end of track meta event
    int64_t offset_ticks = int64_t(state.recordedDuration * MIDI_BEAT_TICKS);
    uint32_t delta_ticks = uint32_t(offset_ticks - last_offset_ticks);
    writeMidiVarLen(track, delta_ticks);
    uint8_t meta_end_of_track[] = { 0xff, 0x2f, 0x00 };
    [track appendBytes:&meta_end_of_track[0] length:3];
    
    // create the full track chunk, including the header
    NSMutableData* data = [NSMutableData new];

    // we know we're using ASCII character, so UTF-8 will only use those characters
    [data appendBytes:[@"MTrk" UTF8String] length:4];

    // track chunk length
    uint32_t track_header_length = needsMidiByteSwap() ? CFSwapInt32((uint32_t)track.length) : (uint32_t)track.length;
    [data appendBytes:&track_header_length length:4];
    
    // add the previously accumulated track events
    [data appendData:track];

    return data;
}

- (void)midiTrackChunkToRecorded:(NSData*)track division:(uint16_t)division{
    if (track == nil || track.length == 0) {
        return;
    }

    // prepare local data to accumulate into
    
    std::unique_ptr<std::vector<RecordedMidiMessage>> recorded(new std::vector<RecordedMidiMessage>());
    std::unique_ptr<std::vector<int>> recorded_beatindex(new std::vector<int>());
    NSMutableData* recorded_preview = [NSMutableData new];
    double recorded_duration = 0.0;

    // process the track events

    int64_t last_offset_ticks = 0;
    uint8_t running_status = 0;
    uint32_t i = 0;
    uint8_t* track_bytes = (uint8_t*)track.bytes;
    while (i < track.length) {
        // read variable length delta time
        uint32_t delta_ticks;
        i += readMidiVarLen(&track_bytes[i], delta_ticks);
        
        int64_t offset_ticks = last_offset_ticks + delta_ticks;
        double duration_beats = double(offset_ticks) / division;
        last_offset_ticks = offset_ticks;
        
        // update the beat to index mapping
        while ((int)duration_beats >= recorded_beatindex->size()) {
            recorded_beatindex->push_back((int)recorded->size());
        }

        // handle event
        uint8_t event_identifier = track_bytes[i];
        i += 1;
        switch (event_identifier) {
            // sysex event
            case 0xf0:
            case 0xf7: {
                // capture the event length
                uint32_t length;
                i += readMidiVarLen(&track_bytes[i], length);
                // skip over the event data
                i += length;
                break;
            }
            // meta event
            case 0xff: {
                // skip over the event type
                i += 1;
                // capture the event length
                uint32_t length;
                i += readMidiVarLen(&track_bytes[i], length);
                // skip over the event data
                i += length;
                break;
            }
            // midi event
            default: {
                uint8_t d0 = event_identifier;
                // check for status byte
                if ((d0 & 0x80) != 0) {
                    running_status = d0;
                }
                // not a status byte, we'll reuse the previous one as running status
                else {
                    d0 = running_status;
                }
                
                RecordedMidiMessage msg;
                msg.offsetBeats = duration_beats;

                // get the data bytes based on the active state
                // one data byte
                if ((d0 & 0xf0) == 0xc0 || (d0 & 0xf0) == 0xd0) {
                    uint8_t d1 = track_bytes[i];
                    i += 1;
                    
                    msg.length = 2;
                    msg.data[0] = d0;
                    msg.data[1] = d1;
                    msg.data[2] = 0;
                }
                // two data bytes
                else {
                    uint8_t d1 = track_bytes[i];
                    i += 1;
                    uint8_t d2 = track_bytes[i];
                    i += 1;
                    
                    msg.length = 3;
                    msg.data[0] = d0;
                    msg.data[1] = d1;
                    msg.data[2] = d2;
                }

                // add the recorded message
                recorded->push_back(msg);
                
                // update the preview
                [self updatePreview:recorded_preview withMessage:msg];

                break;
            }
        }
    }
    
    recorded_duration = double(last_offset_ticks) / division;
    if (_state->autoTrimRecordings) {
        recorded_duration = ceil(recorded_duration);
    }
    // transfer all the accumulated data to the active recorded data
    
    _recordedPreview = recorded_preview;
    
    if (_delegate) {
        [_delegate finishRecording:_ordinal
                              data:std::move(recorded)
                       beatToIndex:std::move(recorded_beatindex)
                          duration:recorded_duration];
    }
}

#pragma mark Recording

- (void)ping:(double)timeSampleSeconds {
    dispatch_barrier_sync(_dispatchQueue, ^{
        if (_record && _recording) {
            // update the recording duration even when there's no incoming messages
            if (_state->transportStartSampleSeconds == 0.0) {
                _recordingDuration = 0.0;
            }
            else {
                _recordingDuration = (timeSampleSeconds - _state->transportStartSampleSeconds) * _state->secondsToBeats;
            }
            
            // while recording, we keep track of the position in the recording that the beginning of a beat
            // corresponds to, this allow for fast scanning later during playback
            if (_recordingBeatToIndex.get()) {
                int current_beat = (int)_recordingDuration;
                // fill in any beats that might have been miseed (very unlikely, but best to be safe)
                // and add the current beat in case this is the first time creating the link to the index
                while (current_beat >= _recordingBeatToIndex->size()) {
                    _recordingBeatToIndex->push_back((int)_recording->size());
                }
            }
            
            // update the preview in case of gaps
            if (_recordingPreview && !_recording->empty()) {
                [self updatePreview:_recordingPreview withOffsetBeats:_recordingDuration];
            }
        }
    });
}

- (void)handleMidiRPNValue:(int)channel {
    int rpn_param = (_lastRpnMsb[channel] << 7) + _lastRpnLsb[channel];
    
    switch (rpn_param) {
        // pitchbend sensitivity
        case 0: {
            float sensitivity = float(_lastDataMsb[channel]) + float(_lastDataLsb[channel]) / 100.f;
            MPEState& mpe_state = _state->track[_ordinal].mpeState;
            if (mpe_state.zone1Active) {
                if (channel == 0) {
                    mpe_state.zone1ManagerPitchSens = sensitivity;
                }
                else if (channel <= mpe_state.zone1Members) {
                    mpe_state.zone1MemberPitchSens = sensitivity;
                }
            }
            if (mpe_state.zone2Active) {
                if (channel == 15) {
                    mpe_state.zone2ManagerPitchSens = sensitivity;
                }
                else if (channel <= 15 - mpe_state.zone2Members) {
                    mpe_state.zone2MemberPitchSens = sensitivity;
                }
            }
            break;
        }
        // MPE configuration message
        case 6: {
            MPEState& mpe_state = _state->track[_ordinal].mpeState;

            // only accept MCM on channels 1 and 16
            if (channel == 0) {
                mpe_state.zone1Members = _lastDataMsb[channel];
                if (mpe_state.zone1Members == 0) {
                    mpe_state.zone1Active = false;
                    mpe_state.zone1ManagerPitchSens = 0.f;
                    mpe_state.zone1MemberPitchSens = 0.f;
                }
                else {
                    mpe_state.zone1Active = true;
                    mpe_state.zone1ManagerPitchSens = 2.f;
                    mpe_state.zone1MemberPitchSens = 48.f;
                }
                
                // disable zone 2 when zone 1 uses all member channels
                if (mpe_state.zone1Members >= 14) {
                    mpe_state.zone2Members = 0;
                    mpe_state.zone2Active = false;
                    mpe_state.zone2ManagerPitchSens = 0.f;
                    mpe_state.zone2MemberPitchSens = 0.f;
                }
                // reduce the zone 2 member channels if they overlap zone 1 member channels
                else if (mpe_state.zone2Active) {
                    mpe_state.zone2Members = MIN(14 - mpe_state.zone1Members.load(), mpe_state.zone2Members.load());
                }
            }
            else if (channel == 15) {
                mpe_state.zone2Members = _lastDataMsb[channel];
                if (mpe_state.zone2Members == 0) {
                    mpe_state.zone2Active = false;
                    mpe_state.zone2ManagerPitchSens = 0.f;
                    mpe_state.zone2MemberPitchSens = 0.f;
                }
                else {
                    mpe_state.zone2Active = true;
                    mpe_state.zone2ManagerPitchSens = 2.f;
                    mpe_state.zone2MemberPitchSens = 48.f;
                }
                
                // disable zone 1 when zone 2 uses all member channels
                if (mpe_state.zone2Members >= 14) {
                    mpe_state.zone1Members = 0;
                    mpe_state.zone1Active = false;
                    mpe_state.zone1ManagerPitchSens = 0.f;
                    mpe_state.zone1MemberPitchSens = 0.f;
                }
                // reduce the zone 1 member channels if they overlap zone 2 member channels
                else if (mpe_state.zone1Active) {
                    mpe_state.zone1Members = MIN(14 - mpe_state.zone2Members.load(), mpe_state.zone1Members.load());
                }
            }
            
            mpe_state.enabled = (mpe_state.zone1Active || mpe_state.zone2Active);
            
            break;
        }
    }
}

- (void)recordMidiMessage:(QueuedMidiMessage&)message {
    dispatch_barrier_sync(_dispatchQueue, ^{
        // track the MPE Configuration Message and RPN 0 PitchBend sensitivity
        // when recording is enabled for this track
        // we only look at CC messages for this
        if (_state->track[_ordinal].recordEnabled &&
            message.length == 3 &&
            (message.data[0] & 0xf0) == 0xb0) {
            uint8_t channel = (message.data[0] & 0x0f);
            uint8_t cc_num = message.data[1];
            uint8_t cc_val = message.data[2];
            
            switch (cc_num) {
                // RPN parameter number
                case 100:
                    _lastRpnLsb[channel] = cc_val;
                    break;
                case 101:
                    _lastRpnMsb[channel] = cc_val;
                    break;
                // RPN parameter value
                case 6:
                    if (_lastRpnMsb[channel] != 0x7f || _lastRpnLsb[channel] != 0x7f) {
                        _lastDataMsb[channel] = cc_val;
                        _lastDataLsb[channel] = 0;
                        
                        [self handleMidiRPNValue:channel];
                    }
                    break;
                case 38:
                    if (_lastRpnMsb[channel] != 0x7f || _lastRpnLsb[channel] != 0x7f) {
                        _lastDataLsb[channel] = cc_val;
                        
                        [self handleMidiRPNValue:channel];
                    }
                    break;
            }
        }
        
        // don't record if record enable isn't active
        if (!_record || !_recording) {
            return;
        }

        // auto start the recording on the first received message
        // if the recording hasn't started yet
        if (_recording->empty() && _state->transportStartSampleSeconds == 0.0) {
            if (_delegate) {
                _state->transportStartSampleSeconds = message.timeSampleSeconds;
                _state->playDurationBeats = 0.0;
                [_delegate startRecord];
            }
        }

        // add message to the recording
        RecordedMidiMessage recorded_message;
        double offset_seconds = message.timeSampleSeconds - _state->transportStartSampleSeconds;
        recorded_message.offsetBeats = offset_seconds * _state->secondsToBeats;
        recorded_message.length = message.length;
        recorded_message.data[0] = message.data[0];
        recorded_message.data[1] = message.data[1];
        recorded_message.data[2] = message.data[2];
        _recording->push_back(recorded_message);
        _recordingDuration = offset_seconds * _state->secondsToBeats;
        
        // update the preview
        [self updatePreview:_recordingPreview withMessage:recorded_message];
    });
}

- (void)updatePreview:(NSMutableData*)preview withOffsetBeats:(double)offsetBeats {
    int32_t pixel = int32_t(offsetBeats * PIXELS_PER_BEAT + 0.5);
    pixel *= 2;
    
    int8_t active_notes = 0;
    if (pixel > 0) {
        active_notes = ((int8_t*)preview.bytes)[preview.length-1];
    }
    if (pixel + 1 >= preview.length) {
        uint8_t zero = 0;
        while (preview.length < pixel + 2) {
            [preview appendBytes:&zero length:1];
            [preview appendBytes:&active_notes length:1];
        }
    }
}

- (void)updatePreview:(NSMutableData*)preview withMessage:(RecordedMidiMessage&)message {
    int32_t pixel = int32_t(message.offsetBeats * PIXELS_PER_BEAT + 0.5);
    pixel *= 2;
    
    [self updatePreview:preview withOffsetBeats:message.offsetBeats];
    
    uint8_t* preview_bytes = (uint8_t*)preview.mutableBytes;
    int8_t active_notes = preview_bytes[pixel + 1];

    // track the note and the events indepdently
    if (message.length == 3 &&
        ((message.data[0] & 0xf0) == 0x90 ||
         (message.data[0] & 0xf0) == 0x80)) {
        // note on
        if ((message.data[0] & 0xf0) == 0x90) {
            // note on with zero velocity == note off
            if (message.data[2] == 0) {
                active_notes -= 1;
            }
            else {
                active_notes += 1;
            }
        }
        // note off
        else if ((message.data[0] & 0xf0) == 0x80) {
            active_notes -= 1;
        }
    }
    else if (preview_bytes[pixel] < 0xff) {
        preview_bytes[pixel] += 1;
    }
    
    preview_bytes[pixel + 1] = active_notes;
}

- (void)clear {
    dispatch_barrier_sync(_dispatchQueue, ^{
        _record = NO;

        if (_delegate) {
            [_delegate invalidateRecording:_ordinal];
        }

        _recording.reset(new std::vector<RecordedMidiMessage>);
        _recordingBeatToIndex.reset(new std::vector<int>());
        _recordingPreview = [NSMutableData new];
        _recordingDuration = 0.0;

        _recordedPreview = nil;
    });
}

#pragma mark Getters and Setter

- (void)setState:(MidiRecorderState*)state {
    _state = state;
}

- (double)duration {
    __block double duration = 0.0;
    
    dispatch_sync(_dispatchQueue, ^{
        if (_record == YES) {
            duration = _recordingDuration;
        }
        else {
            duration = _state->track[_ordinal].recordedDuration;
        }
    });
    
    return duration;
}

- (NSData*)preview {
    __block NSData* preview = nil;
    
    dispatch_sync(_dispatchQueue, ^{
        if (_record == YES) {
            preview = _recordingPreview;
        }
        else {
            preview = _recordedPreview;
        }
    });
    
    return preview;
}

@end
