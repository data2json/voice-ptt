#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <QuartzCore/QuartzCore.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/ev_keymap.h>
#include <sys/sysctl.h>

typedef NS_ENUM(NSInteger, PTTMode) {
    PTTModeSmart = 0,     // Hold to talk, OR quick double-tap to lock hands-free
    PTTModeHoldOnly = 1,  // Strict hold-to-talk
    PTTModeToggleOnly = 2 // Tap once to start, tap again to stop
};

typedef NS_ENUM(NSInteger, AppState) {
    AppStateStarting = 0,
    AppStateIdle,
    AppStateHolding,
    AppStateLocked,
    AppStateTranscribing
};

typedef struct {
    CGKeyCode keyCode;
    BOOL isModifier;
    CGEventFlags modifierMask;
    NSString *label;
} HotkeyOption;

static const HotkeyOption kHotkeyOptions[] = {
    { 61,  YES, kCGEventFlagMaskAlternate, @"Right Option (⌥)" },
    { 54,  YES, kCGEventFlagMaskCommand,   @"Right Command (⌘)" },
    { 62,  YES, kCGEventFlagMaskControl,   @"Right Control (⌃)" },
    { 96,  NO,  0,                         @"F5" },
    { 105, NO,  0,                         @"F13 (or Foot Pedal)" }
};
static const NSInteger kHotkeyOptionCount = 5;

typedef struct {
    float threshold;
    NSString *label;
} GatePreset;

static const GatePreset kGatePresets[] = {
    { 0.012f, @"Low (Quiet Room)" },
    { 0.025f, @"Medium (Normal)" },
    { 0.045f, @"High (TV / Background Noise)" },
    { 0.080f, @"Very High (Close Mic Only)" }
};
static const NSInteger kGatePresetCount = 4;

static NSString * const kPrefModeKey = @"VoicePTTMode";
static NSString * const kPrefHotkeyIndexKey = @"VoicePTTHotkeyIndex";
static NSString * const kPrefMicUIDKey = @"VoicePTTMicUID";
static NSString * const kPrefModelPathKey = @"VoicePTTModelPath";
static NSString * const kPrefShowPillKey = @"VoicePTTShowPill";
static NSString * const kPrefTrailingSpaceKey = @"VoicePTTTrailingSpace";
static NSString * const kPrefCaptureMediaKey = @"VoicePTTCaptureMediaButton";
static NSString * const kPrefGatePresetKey = @"VoicePTTGatePreset";
static NSString * const kPrefLiveCaptionKey = @"VoicePTTLiveCaption";
static const NSInteger kServerPort = 8178;
static const NSInteger kPreviewServerPort = 8179;

// -----------------------------------------------------------------------------
// Live Caption Floating OSD (Non-Activating NSPanel - never steals text focus)
// -----------------------------------------------------------------------------
@interface LiveOSDView : NSView
@property (nonatomic, copy) NSString *headerText;
@property (nonatomic, copy) NSString *captionText;
@property (nonatomic, strong) NSColor *dotColor;
@property (nonatomic, assign) CGFloat audioLevel;
@property (nonatomic, assign) BOOL aboveGate;
@property (nonatomic, assign) BOOL showMeter;
@end

@implementation LiveOSDView
- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 1, 1) xRadius:16 yRadius:16];
    [[NSColor colorWithCalibratedWhite:0.06 alpha:0.92] setFill];
    [bg fill];
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.18] setStroke];
    [bg setLineWidth:1.0];
    [bg stroke];

    BOOL hasCaption = (self.captionText.length > 0);
    CGFloat headerY = hasCaption ? (bounds.size.height - 28.0) : ((bounds.size.height - 18.0) / 2.0);

    // Status dot
    NSRect dotRect = NSMakeRect(16, headerY + 4.0, 10, 10);
    [(self.dotColor ?: [NSColor systemRedColor]) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:dotRect] fill];

    // Header label
    NSDictionary *headerAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.88 alpha:1.0]
    };
    [(self.headerText ?: @"") drawAtPoint:NSMakePoint(34, headerY) withAttributes:headerAttrs];

    // Live audio level meter on the top-right (green/red when clearing noise gate, gray below gate)
    if (self.showMeter) {
        CGFloat meterWidth = 46.0;
        CGFloat startX = bounds.size.width - meterWidth - 16.0;
        NSInteger bars = 7;
        CGFloat barW = 3.5;
        CGFloat gap = 3.0;
        CGFloat maxH = 14.0;
        CGFloat clamped = MIN(1.0, MAX(0.06, self.audioLevel));
        NSColor *barColor = self.aboveGate
            ? [NSColor colorWithCalibratedRed:0.25 green:0.90 blue:0.45 alpha:0.95]
            : [NSColor colorWithCalibratedWhite:0.45 alpha:0.75];
        for (NSInteger i = 0; i < bars; i++) {
            CGFloat weight = 1.0 - fabs((CGFloat)i - (bars - 1) / 2.0) / ((bars + 1) / 2.0);
            CGFloat h = MAX(3.0, maxH * clamped * (0.45 + 0.55 * weight));
            NSRect r = NSMakeRect(startX + i * (barW + gap), headerY + 9.0 - (h / 2.0), barW, h);
            [barColor setFill];
            [[NSBezierPath bezierPathWithRoundedRect:r xRadius:1.5 yRadius:1.5] fill];
        }
    }

    // Live Caption Text (Apple Live Captions-style large clear text)
    if (hasCaption) {
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineBreakMode = NSLineBreakByWordWrapping;
        ps.lineSpacing = 3.0;
        NSDictionary *capAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:17.0 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor whiteColor],
            NSParagraphStyleAttributeName: ps
        };
        NSRect capRect = NSMakeRect(16, 12, bounds.size.width - 32, bounds.size.height - 46);
        [self.captionText drawWithRect:capRect options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine) attributes:capAttrs];
    }
}
@end

// -----------------------------------------------------------------------------
// Audio Device Helpers (Listing + Input Gain Control)
// -----------------------------------------------------------------------------
@interface AudioInputDeviceInfo : NSObject
@property (nonatomic, assign) AudioDeviceID deviceID;
@property (nonatomic, copy) NSString *uid;
@property (nonatomic, copy) NSString *name;
@end
@implementation AudioInputDeviceInfo
@end

static NSArray<AudioInputDeviceInfo *> *ListAudioInputDevices(void) {
    NSMutableArray *result = [NSMutableArray array];
    AudioObjectPropertyAddress prop = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &prop, 0, NULL, &dataSize) != noErr) {
        return result;
    }
    UInt32 count = dataSize / sizeof(AudioDeviceID);
    AudioDeviceID *devices = (AudioDeviceID *)malloc(dataSize);
    if (!devices) return result;

    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &prop, 0, NULL, &dataSize, devices) == noErr) {
        for (UInt32 i = 0; i < count; i++) {
            AudioObjectPropertyAddress streamProp = {
                kAudioDevicePropertyStreamConfiguration,
                kAudioDevicePropertyScopeInput,
                kAudioObjectPropertyElementMain
            };
            UInt32 streamSize = 0;
            if (AudioObjectGetPropertyDataSize(devices[i], &streamProp, 0, NULL, &streamSize) != noErr || streamSize == 0) {
                continue;
            }
            AudioBufferList *bufList = (AudioBufferList *)malloc(streamSize);
            if (!bufList) continue;
            UInt32 inputChannels = 0;
            if (AudioObjectGetPropertyData(devices[i], &streamProp, 0, NULL, &streamSize, bufList) == noErr) {
                for (UInt32 b = 0; b < bufList->mNumberBuffers; b++) {
                    inputChannels += bufList->mBuffers[b].mNumberChannels;
                }
            }
            free(bufList);
            if (inputChannels == 0) continue;

            CFStringRef uidRef = NULL;
            UInt32 uidSize = sizeof(CFStringRef);
            AudioObjectPropertyAddress uidProp = {
                kAudioDevicePropertyDeviceUID,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            AudioObjectGetPropertyData(devices[i], &uidProp, 0, NULL, &uidSize, &uidRef);

            CFStringRef nameRef = NULL;
            UInt32 nameSize = sizeof(CFStringRef);
            AudioObjectPropertyAddress nameProp = {
                kAudioObjectPropertyName,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            AudioObjectGetPropertyData(devices[i], &nameProp, 0, NULL, &nameSize, &nameRef);

            if (uidRef && nameRef) {
                AudioInputDeviceInfo *info = [AudioInputDeviceInfo new];
                info.deviceID = devices[i];
                info.uid = (__bridge_transfer NSString *)uidRef;
                info.name = (__bridge_transfer NSString *)nameRef;
                [result addObject:info];
            } else {
                if (uidRef) CFRelease(uidRef);
                if (nameRef) CFRelease(nameRef);
            }
        }
    }
    free(devices);
    return result;
}

static AudioDeviceID ResolveInputDeviceID(NSString *preferredUID) {
    if (preferredUID.length > 0) {
        for (AudioInputDeviceInfo *d in ListAudioInputDevices()) {
            if ([d.uid isEqualToString:preferredUID]) return d.deviceID;
        }
    }
    AudioDeviceID defID = kAudioObjectUnknown;
    UInt32 sz = sizeof(AudioDeviceID);
    AudioObjectPropertyAddress prop = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &prop, 0, NULL, &sz, &defID);
    return defID;
}

static float GetInputDeviceGain(AudioDeviceID devID) {
    if (devID == kAudioObjectUnknown) return -1.0f;
    UInt32 channels[3] = { 0, 1, 2 };
    for (int i = 0; i < 3; i++) {
        AudioObjectPropertyAddress prop = {
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyScopeInput,
            channels[i]
        };
        if (AudioObjectHasProperty(devID, &prop)) {
            Float32 val = 0.0f;
            UInt32 sz = sizeof(Float32);
            if (AudioObjectGetPropertyData(devID, &prop, 0, NULL, &sz, &val) == noErr) {
                return val;
            }
        }
    }
    return -1.0f;
}

static void SetInputDeviceGain(AudioDeviceID devID, float scalar) {
    if (devID == kAudioObjectUnknown) return;
    Float32 val = MIN(1.0f, MAX(0.0f, scalar));
    UInt32 channels[3] = { 0, 1, 2 };
    for (int i = 0; i < 3; i++) {
        AudioObjectPropertyAddress prop = {
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyScopeInput,
            channels[i]
        };
        Boolean settable = false;
        if (AudioObjectHasProperty(devID, &prop) &&
            AudioObjectIsPropertySettable(devID, &prop, &settable) == noErr && settable) {
            AudioObjectSetPropertyData(devID, &prop, 0, NULL, sizeof(Float32), &val);
        }
    }
}

// -----------------------------------------------------------------------------
// Build 44-byte WAV header + 16kHz Mono 16-bit PCM Data + 0.45s trailing silence
// (Trailing silence ensures Whisper emits <|endoftext|> cleanly without looping)
// -----------------------------------------------------------------------------
static NSData *BuildWAVData(NSData *pcmData) {
    const uint32_t trailingSilenceBytes = (uint32_t)(16000 * 2 * 45 / 100); // 450ms silence pad
    uint32_t dataSize = (uint32_t)pcmData.length + trailingSilenceBytes;
    uint32_t chunkSize = 36 + dataSize;
    uint16_t audioFormat = 1;
    uint16_t numChannels = 1;
    uint32_t sampleRate = 16000;
    uint16_t bitsPerSample = 16;
    uint32_t byteRate = sampleRate * numChannels * (bitsPerSample / 8);
    uint16_t blockAlign = numChannels * (bitsPerSample / 8);

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&chunkSize length:4];
    [wav appendBytes:"WAVE" length:4];
    [wav appendBytes:"fmt " length:4];
    uint32_t subchunk1Size = 16;
    [wav appendBytes:&subchunk1Size length:4];
    [wav appendBytes:&audioFormat length:2];
    [wav appendBytes:&numChannels length:2];
    [wav appendBytes:&sampleRate length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bitsPerSample length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataSize length:4];
    [wav appendData:pcmData];
    [wav increaseLengthBy:trailingSilenceBytes]; // zero-filled silence
    return wav;
}

// -----------------------------------------------------------------------------
// Main App Controller
// -----------------------------------------------------------------------------
@interface VoicePTTApp : NSObject <NSApplicationDelegate> {
@public
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _audioBuffers[3];
    BOOL _isRecordingAudio;
    float _peakRMS;
    CFMachPortRef _eventTap;
    CFRunLoopSourceRef _eventTapSource;
}
- (void)handleTriggerDown;
- (void)handleTriggerUp;
- (void)handleMediaButtonToggle;
- (void)cancelRecording;

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSPanel *osdPanel;
@property (nonatomic, strong) LiveOSDView *osdView;
@property (nonatomic, strong) NSTask *serverTask;
@property (nonatomic, strong) NSTask *previewServerTask;
@property (nonatomic, assign) BOOL previewServerReady;
@property (nonatomic, strong) NSMutableData *pcmBuffer;
@property (nonatomic, strong) NSLock *audioLock;
@property (nonatomic, assign) AppState state;
@property (nonatomic, assign) PTTMode mode;
@property (nonatomic, assign) NSInteger hotkeyIndex;
@property (nonatomic, assign) NSInteger gatePresetIndex;
@property (nonatomic, copy) NSString *selectedMicUID;
@property (nonatomic, copy) NSString *selectedModelPath;
@property (nonatomic, assign) BOOL showPill;
@property (nonatomic, assign) BOOL liveCaptionEnabled;
@property (nonatomic, assign) BOOL addTrailingSpace;
@property (nonatomic, assign) BOOL captureMediaButton;
@property (nonatomic, assign) BOOL triggerKeyIsDown;
@property (nonatomic, assign) BOOL otherKeyPressedDuringHold;
@property (nonatomic, assign) NSTimeInterval holdStartTime;
@property (nonatomic, assign) NSTimeInterval lastShortTapReleaseTime;
@property (nonatomic, copy) NSString *liveCaptionText;
@property (nonatomic, copy) NSString *lastTranscript;
@property (nonatomic, assign) double lastLatencySec;
@property (nonatomic, strong) NSTimer *permPollTimer;
@property (nonatomic, strong) NSTimer *healthTimer;
@property (nonatomic, strong) NSTimer *livePreviewTimer;
@property (nonatomic, assign) BOOL previewInFlight;
@property (nonatomic, assign) NSUInteger lastPreviewByteCount;
@property (nonatomic, assign) NSUInteger sessionGen;
@property (nonatomic, assign) BOOL serverReady;
@property (nonatomic, copy) NSString *baseDir;
@end

static void AudioInputCallback(void *inUserData,
                               AudioQueueRef inAQ,
                               AudioQueueBufferRef inBuffer,
                               const AudioTimeStamp *inStartTime,
                               UInt32 inNumPackets,
                               const AudioStreamPacketDescription *inPacketDesc) {
    VoicePTTApp *app = (__bridge VoicePTTApp *)inUserData;
    if (!app) return;

    UInt32 bytes = inBuffer->mAudioDataByteSize;
    BOOL shouldReenqueue = NO;
    float rms = 0.0f;
    float gateThresh = kGatePresets[app.gatePresetIndex].threshold;

    [app.audioLock lock];
    if (app->_isRecordingAudio && app.pcmBuffer && bytes > 0) {
        const int16_t *samples = (const int16_t *)inBuffer->mAudioData;
        UInt32 count = bytes / sizeof(int16_t);
        double sumSq = 0.0;
        for (UInt32 i = 0; i < count; i++) {
            double s = (double)samples[i] / 32768.0;
            sumSq += s * s;
        }
        rms = (count > 0) ? (float)sqrt(sumSq / (double)count) : 0.0f;

        [app.pcmBuffer appendBytes:inBuffer->mAudioData length:bytes];
        if (rms > app->_peakRMS) {
            app->_peakRMS = rms;
        }
        shouldReenqueue = YES;
    }
    [app.audioLock unlock];

    if (shouldReenqueue) {
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);

        CGFloat visualLevel = MIN(1.0, (CGFloat)(rms * 6.5f));
        BOOL clearedGate = (rms >= gateThresh);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (app.state == AppStateHolding || app.state == AppStateLocked) {
                app.osdView.audioLevel = visualLevel;
                app.osdView.aboveGate = clearedGate;
                [app.osdView setNeedsDisplay:YES];
            }
        });
    }
}

static CGEventRef EventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    VoicePTTApp *app = (__bridge VoicePTTApp *)userInfo;
    if (!app) return event;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (app->_eventTap) {
            CGEventTapEnable(app->_eventTap, true);
        }
        return event;
    }

    // Intercept Apple headset inline button / media Play-Pause key (NX_KEYTYPE_PLAY = 16)
    if (type == NX_SYSDEFINED && app.captureMediaButton) {
        NSEvent *nsEvent = [NSEvent eventWithCGEvent:event];
        if (nsEvent && nsEvent.subtype == 8) { // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            NSInteger data1 = nsEvent.data1;
            int mediaKeyCode = (int)((data1 & 0xFFFF0000) >> 16);
            int keyFlags = (int)(data1 & 0x0000FFFF);
            int keyState = (keyFlags & 0xFF00) >> 8; // 0x0A = keyDown, 0x0B = keyUp
            BOOL isRepeat = (keyFlags & 0x1) != 0;
            if (mediaKeyCode == NX_KEYTYPE_PLAY) {
                if (keyState == 0x0A && !isRepeat) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [app handleMediaButtonToggle];
                    });
                }
                return NULL;
            }
        }
        return event;
    }

    CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    CGEventFlags flags = CGEventGetFlags(event);

    // Esc cancels active recording without pasting
    if (type == kCGEventKeyDown && keyCode == 53) {
        if (app.state == AppStateHolding || app.state == AppStateLocked) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [app cancelRecording];
            });
            return NULL;
        }
        return event;
    }

    HotkeyOption hk = kHotkeyOptions[app.hotkeyIndex];

    if (hk.isModifier) {
        if (type == kCGEventFlagsChanged && keyCode == hk.keyCode) {
            BOOL isNowDown = (flags & hk.modifierMask) != 0;
            if (isNowDown && !app.triggerKeyIsDown) {
                app.triggerKeyIsDown = YES;
                app.otherKeyPressedDuringHold = NO;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [app handleTriggerDown];
                });
            } else if (!isNowDown && app.triggerKeyIsDown) {
                app.triggerKeyIsDown = NO;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [app handleTriggerUp];
                });
            }
        } else if (type == kCGEventKeyDown && app.triggerKeyIsDown) {
            app.otherKeyPressedDuringHold = YES;
        }
    } else {
        if (keyCode == hk.keyCode) {
            if (type == kCGEventKeyDown) {
                int64_t isRepeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat);
                if (isRepeat == 0 && !app.triggerKeyIsDown) {
                    app.triggerKeyIsDown = YES;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [app handleTriggerDown];
                    });
                }
                return NULL;
            } else if (type == kCGEventKeyUp) {
                if (app.triggerKeyIsDown) {
                    app.triggerKeyIsDown = NO;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [app handleTriggerUp];
                    });
                }
                return NULL;
            }
        }
    }

    return event;
}

@implementation VoicePTTApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.audioLock = [NSLock new];
    self.state = AppStateStarting;
    self.serverReady = NO;

    NSString *bundleParent = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
    NSString *fallbackDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads/voice-ptt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:[bundleParent stringByAppendingPathComponent:@"models"]]) {
        self.baseDir = bundleParent;
    } else {
        self.baseDir = fallbackDir;
    }

    [self loadPreferences];
    [self setupStatusItem];
    [self setupFloatingOSD];
    [self requestMicrophonePermission];
    [self startWhisperServer];
    [self setupEventTapWithPrompt:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self stopLivePreviewTimer];
    [self stopAudioRecording];
    if (_eventTap) {
        CGEventTapEnable(_eventTap, false);
        CFRelease(_eventTap);
        _eventTap = NULL;
    }
    if (self.serverTask && self.serverTask.isRunning) {
        [self.serverTask terminate];
    }
    if (self.previewServerTask && self.previewServerTask.isRunning) {
        [self.previewServerTask terminate];
    }
}

#pragma mark - Preferences

- (void)loadPreferences {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    self.mode = [d objectForKey:kPrefModeKey] ? [d integerForKey:kPrefModeKey] : PTTModeSmart;
    self.hotkeyIndex = [d objectForKey:kPrefHotkeyIndexKey] ? [d integerForKey:kPrefHotkeyIndexKey] : 0;
    if (self.hotkeyIndex < 0 || self.hotkeyIndex >= kHotkeyOptionCount) self.hotkeyIndex = 0;

    // Default to High (TV / Background Noise) gate preset
    self.gatePresetIndex = [d objectForKey:kPrefGatePresetKey] ? [d integerForKey:kPrefGatePresetKey] : 2;
    if (self.gatePresetIndex < 0 || self.gatePresetIndex >= kGatePresetCount) self.gatePresetIndex = 2;

    self.selectedMicUID = [d stringForKey:kPrefMicUIDKey] ?: @"";
    self.showPill = [d objectForKey:kPrefShowPillKey] ? [d boolForKey:kPrefShowPillKey] : YES;
    self.liveCaptionEnabled = [d objectForKey:kPrefLiveCaptionKey] ? [d boolForKey:kPrefLiveCaptionKey] : YES;
    self.addTrailingSpace = [d objectForKey:kPrefTrailingSpaceKey] ? [d boolForKey:kPrefTrailingSpaceKey] : NO;
    self.captureMediaButton = [d objectForKey:kPrefCaptureMediaKey] ? [d boolForKey:kPrefCaptureMediaKey] : YES;

    NSString *savedModel = [d stringForKey:kPrefModelPathKey];
    if (savedModel && [[NSFileManager defaultManager] fileExistsAtPath:savedModel] && ![savedModel.lastPathComponent containsString:@"silero"]) {
        self.selectedModelPath = savedModel;
    } else {
        // Prefer medium.en-q5_0 if installed for stronger noise immunity, else first available
        NSString *mediumPath = [self.baseDir stringByAppendingPathComponent:@"models/ggml-medium.en-q5_0.bin"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:mediumPath]) {
            self.selectedModelPath = mediumPath;
        } else {
            NSArray<NSString *> *models = [self availableModels];
            self.selectedModelPath = models.firstObject ?: [self.baseDir stringByAppendingPathComponent:@"models/ggml-small.en-q5_1.bin"];
        }
    }
}

- (NSArray<NSString *> *)availableModels {
    NSString *modelsDir = [self.baseDir stringByAppendingPathComponent:@"models"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:modelsDir error:nil];
    NSMutableArray *bins = [NSMutableArray array];
    for (NSString *f in files) {
        if ([f hasSuffix:@".bin"] && ![f.lowercaseString containsString:@"silero"]) {
            [bins addObject:[modelsDir stringByAppendingPathComponent:f]];
        }
    }
    [bins sortUsingSelector:@selector(localizedStandardCompare:)];
    return bins;
}

- (NSString *)vadModelPath {
    NSString *modelsDir = [self.baseDir stringByAppendingPathComponent:@"models"];
    NSArray *candidates = @[ @"ggml-silero-v6.2.0.bin", @"ggml-silero-v5.1.2.bin" ];
    for (NSString *name in candidates) {
        NSString *p = [modelsDir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return nil;
}

- (NSString *)fastPreviewModelPath {
    NSString *modelsDir = [self.baseDir stringByAppendingPathComponent:@"models"];
    NSArray *candidates = @[ @"ggml-base.en-q5_1.bin", @"ggml-tiny.en-q5_1.bin", @"ggml-base.en.bin", @"ggml-small.en-q5_1.bin" ];
    for (NSString *name in candidates) {
        NSString *p = [modelsDir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return nil;
}

- (NSString *)promptFilePath {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@".config/voice-ptt"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"prompt.txt"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    return path;
}

- (NSString *)loadCustomPrompt {
    NSString *text = [NSString stringWithContentsOfFile:[self promptFilePath] encoding:NSUTF8StringEncoding error:nil];
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

#pragma mark - Permissions

- (void)requestMicrophonePermission {
    if (@available(macOS 10.14, *)) {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (status == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {}];
        }
    }
}

- (void)setupEventTapWithPrompt:(BOOL)prompt {
    if (_eventTap) return;

    NSDictionary *opts = @{ (__bridge id)kAXTrustedCheckOptionPrompt: @(prompt) };
    BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    if (!trusted) {
        [self updateUI];
        if (!self.permPollTimer) {
            self.permPollTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
                if (AXIsProcessTrusted()) {
                    [timer invalidate];
                    self.permPollTimer = nil;
                    [self setupEventTapWithPrompt:NO];
                }
            }];
        }
        return;
    }

    CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(NX_SYSDEFINED);
    _eventTap = CGEventTapCreate(kCGSessionEventTap,
                                 kCGHeadInsertEventTap,
                                 kCGEventTapOptionDefault,
                                 mask,
                                 EventTapCallback,
                                 (__bridge void *)self);
    if (_eventTap) {
        _eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), _eventTapSource, kCFRunLoopCommonModes);
        CGEventTapEnable(_eventTap, true);
    }
    [self updateUI];
}

#pragma mark - Menu Bar & Live Caption Floating OSD

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"⏳";
    [self rebuildMenu];
}

- (void)setupFloatingOSD {
    NSRect frame = NSMakeRect(0, 0, 320, 42);
    self.osdPanel = [[NSPanel alloc] initWithContentRect:frame
                                               styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    self.osdPanel.level = NSStatusWindowLevel + 1;
    self.osdPanel.opaque = NO;
    self.osdPanel.backgroundColor = [NSColor clearColor];
    self.osdPanel.hasShadow = YES;
    self.osdPanel.ignoresMouseEvents = YES;
    self.osdPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

    self.osdView = [[LiveOSDView alloc] initWithFrame:frame];
    self.osdPanel.contentView = self.osdView;
}

- (void)showOSDWithHeader:(NSString *)header caption:(NSString *)caption dotColor:(NSColor *)color showMeter:(BOOL)showMeter {
    if (!self.showPill) {
        [self.osdPanel orderOut:nil];
        return;
    }

    BOOL hasCaption = (caption.length > 0);
    CGFloat width = 320.0;
    CGFloat height = 42.0;

    if (hasCaption) {
        width = 560.0;
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineBreakMode = NSLineBreakByWordWrapping;
        ps.lineSpacing = 3.0;
        NSDictionary *capAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:17.0 weight:NSFontWeightMedium],
            NSParagraphStyleAttributeName: ps
        };
        NSRect textBounds = [caption boundingRectWithSize:NSMakeSize(width - 32.0, 140.0)
                                                  options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine)
                                               attributes:capAttrs];
        height = MIN(180.0, MAX(76.0, ceil(textBounds.size.height) + 52.0));
    } else {
        NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold] };
        CGFloat headerW = [header sizeWithAttributes:attrs].width;
        width = MAX(220.0, headerW + 52.0 + (showMeter ? 62.0 : 0.0));
        height = 40.0;
    }

    NSPoint mouse = [NSEvent mouseLocation];
    NSScreen *targetScreen = [NSScreen mainScreen];
    for (NSScreen *s in [NSScreen screens]) {
        if (NSPointInRect(mouse, s.frame)) {
            targetScreen = s;
            break;
        }
    }
    NSRect vf = targetScreen.visibleFrame;
    NSRect newFrame = NSMakeRect(vf.origin.x + (vf.size.width - width) / 2.0,
                                 vf.origin.y + 44.0,
                                 width,
                                 height);
    [self.osdPanel setFrame:newFrame display:YES];
    self.osdView.frame = NSMakeRect(0, 0, width, height);
    self.osdView.headerText = header;
    self.osdView.captionText = caption;
    self.osdView.dotColor = color;
    self.osdView.showMeter = showMeter;
    [self.osdView setNeedsDisplay:YES];
    [self.osdPanel orderFrontRegardless];
}

- (void)hideOSD {
    [self.osdPanel orderOut:nil];
}

- (void)updateUI {
    if (!AXIsProcessTrusted()) {
        self.statusItem.button.title = @"⚠️";
    } else if (!self.serverReady || self.state == AppStateStarting) {
        self.statusItem.button.title = @"⏳";
    } else if (self.state == AppStateHolding) {
        self.statusItem.button.title = @"🔴";
        [self showOSDWithHeader:@"Listening…" caption:self.liveCaptionText dotColor:[NSColor systemRedColor] showMeter:YES];
    } else if (self.state == AppStateLocked) {
        self.statusItem.button.title = @"🔒";
        [self showOSDWithHeader:@"Hands-Free  (tap to send · Esc cancel)" caption:self.liveCaptionText dotColor:[NSColor systemOrangeColor] showMeter:YES];
    } else if (self.state == AppStateTranscribing) {
        self.statusItem.button.title = @"⏳";
        [self showOSDWithHeader:@"Finalizing…" caption:self.liveCaptionText dotColor:[NSColor systemBlueColor] showMeter:NO];
    } else {
        self.statusItem.button.title = @"🎙";
        [self hideOSD];
    }
    [self rebuildMenu];
}

- (void)rebuildMenu {
    NSMenu *menu = [NSMenu new];

    NSString *statusLine = nil;
    if (!AXIsProcessTrusted()) {
        statusLine = @"⚠️ Needs Accessibility Permission (Click to open)";
    } else if (!self.serverReady) {
        statusLine = @"Loading Whisper + Silero VAD…";
    } else {
        HotkeyOption hk = kHotkeyOptions[self.hotkeyIndex];
        statusLine = [NSString stringWithFormat:@"Ready · %@ · %@", hk.label, self.selectedModelPath.lastPathComponent];
    }
    NSMenuItem *statusItem = [[NSMenuItem alloc] initWithTitle:statusLine action:(!AXIsProcessTrusted() ? @selector(openAccessibilityPrefs:) : nil) keyEquivalent:@""];
    statusItem.target = self;
    [menu addItem:statusItem];

    if (self.lastTranscript.length > 0) {
        NSString *preview = self.lastTranscript.length > 42
            ? [[self.lastTranscript substringToIndex:42] stringByAppendingString:@"…"]
            : self.lastTranscript;
        NSString *lastLine = [NSString stringWithFormat:@"Last (%.2fs): \"%@\"", self.lastLatencySec, preview];
        NSMenuItem *lastItem = [[NSMenuItem alloc] initWithTitle:lastLine action:@selector(copyLastTranscript:) keyEquivalent:@""];
        lastItem.target = self;
        [menu addItem:lastItem];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    // Trigger Mode submenu
    NSMenuItem *modeParent = [[NSMenuItem alloc] initWithTitle:@"Trigger Mode" action:nil keyEquivalent:@""];
    NSMenu *modeMenu = [NSMenu new];
    NSArray *modeTitles = @[
        @"Smart (Hold to talk · Double-tap lock)",
        @"Hold Only (Push-to-Talk)",
        @"Tap-to-Toggle (No holding)"
    ];
    for (NSInteger i = 0; i < (NSInteger)modeTitles.count; i++) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:modeTitles[i] action:@selector(selectMode:) keyEquivalent:@""];
        it.target = self;
        it.tag = i;
        it.state = (self.mode == i) ? NSControlStateValueOn : NSControlStateValueOff;
        [modeMenu addItem:it];
    }
    modeParent.submenu = modeMenu;
    [menu addItem:modeParent];

    // Hotkey submenu
    NSMenuItem *hkParent = [[NSMenuItem alloc] initWithTitle:@"Hotkey" action:nil keyEquivalent:@""];
    NSMenu *hkMenu = [NSMenu new];
    for (NSInteger i = 0; i < kHotkeyOptionCount; i++) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:kHotkeyOptions[i].label action:@selector(selectHotkey:) keyEquivalent:@""];
        it.target = self;
        it.tag = i;
        it.state = (self.hotkeyIndex == i) ? NSControlStateValueOn : NSControlStateValueOff;
        [hkMenu addItem:it];
    }
    hkParent.submenu = hkMenu;
    [menu addItem:hkParent];

    // Noise Gate / Background Noise Rejection submenu
    NSMenuItem *gateParent = [[NSMenuItem alloc] initWithTitle:@"Noise Gate (Ignore TV / Room)" action:nil keyEquivalent:@""];
    NSMenu *gateMenu = [NSMenu new];
    for (NSInteger i = 0; i < kGatePresetCount; i++) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:kGatePresets[i].label action:@selector(selectGatePreset:) keyEquivalent:@""];
        it.target = self;
        it.tag = i;
        it.state = (self.gatePresetIndex == i) ? NSControlStateValueOn : NSControlStateValueOff;
        [gateMenu addItem:it];
    }
    gateParent.submenu = gateMenu;
    [menu addItem:gateParent];

    // Mic Input Gain quick-control submenu
    AudioDeviceID activeDev = ResolveInputDeviceID(self.selectedMicUID);
    float curGain = GetInputDeviceGain(activeDev);
    NSString *gainTitle = (curGain >= 0.0f)
        ? [NSString stringWithFormat:@"Mic Input Gain (%d%%)", (int)roundf(curGain * 100.0f)]
        : @"Mic Input Gain";
    NSMenuItem *gainParent = [[NSMenuItem alloc] initWithTitle:gainTitle action:nil keyEquivalent:@""];
    NSMenu *gainMenu = [NSMenu new];
    NSArray *gainLevels = @[ @35, @50, @65, @80, @100 ];
    for (NSNumber *pct in gainLevels) {
        NSString *lbl = [NSString stringWithFormat:@"%@%%%@", pct, (pct.integerValue == 50 ? @" (Best vs TV)" : @"")];
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:lbl action:@selector(selectMicGain:) keyEquivalent:@""];
        it.target = self;
        it.tag = pct.integerValue;
        it.state = (curGain >= 0.0f && fabs(curGain * 100.0f - pct.floatValue) < 7.0f) ? NSControlStateValueOn : NSControlStateValueOff;
        [gainMenu addItem:it];
    }
    gainParent.submenu = gainMenu;
    [menu addItem:gainParent];

    // Microphone submenu
    NSMenuItem *micParent = [[NSMenuItem alloc] initWithTitle:@"Microphone" action:nil keyEquivalent:@""];
    NSMenu *micMenu = [NSMenu new];
    NSMenuItem *defMic = [[NSMenuItem alloc] initWithTitle:@"System Default" action:@selector(selectMic:) keyEquivalent:@""];
    defMic.target = self;
    defMic.representedObject = @"";
    defMic.state = (self.selectedMicUID.length == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    [micMenu addItem:defMic];
    for (AudioInputDeviceInfo *dev in ListAudioInputDevices()) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:dev.name action:@selector(selectMic:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = dev.uid;
        it.state = [self.selectedMicUID isEqualToString:dev.uid] ? NSControlStateValueOn : NSControlStateValueOff;
        [micMenu addItem:it];
    }
    micParent.submenu = micMenu;
    [menu addItem:micParent];

    // Model submenu
    NSMenuItem *modelParent = [[NSMenuItem alloc] initWithTitle:@"Whisper Model" action:nil keyEquivalent:@""];
    NSMenu *modelMenu = [NSMenu new];
    for (NSString *path in [self availableModels]) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:path.lastPathComponent action:@selector(selectModel:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = path;
        it.state = [self.selectedModelPath isEqualToString:path] ? NSControlStateValueOn : NSControlStateValueOff;
        [modelMenu addItem:it];
    }
    modelParent.submenu = modelMenu;
    [menu addItem:modelParent];

    [menu addItem:[NSMenuItem separatorItem]];

    // Options
    NSMenuItem *mediaToggle = [[NSMenuItem alloc] initWithTitle:@"Headset / Play Button (Tap-to-Toggle)" action:@selector(toggleCaptureMediaButton:) keyEquivalent:@""];
    mediaToggle.target = self;
    mediaToggle.state = self.captureMediaButton ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:mediaToggle];

    NSMenuItem *liveToggle = [[NSMenuItem alloc] initWithTitle:@"Live Caption OSD While Speaking" action:@selector(toggleLiveCaption:) keyEquivalent:@""];
    liveToggle.target = self;
    liveToggle.state = self.liveCaptionEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:liveToggle];

    NSMenuItem *pillToggle = [[NSMenuItem alloc] initWithTitle:@"Show Floating OSD" action:@selector(toggleShowPill:) keyEquivalent:@""];
    pillToggle.target = self;
    pillToggle.state = self.showPill ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:pillToggle];

    NSMenuItem *spaceToggle = [[NSMenuItem alloc] initWithTitle:@"Add Trailing Space" action:@selector(toggleTrailingSpace:) keyEquivalent:@""];
    spaceToggle.target = self;
    spaceToggle.state = self.addTrailingSpace ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:spaceToggle];

    NSMenuItem *promptItem = [[NSMenuItem alloc] initWithTitle:@"Edit Custom Vocabulary (prompt.txt)…" action:@selector(openPromptFile:) keyEquivalent:@""];
    promptItem.target = self;
    [menu addItem:promptItem];

    NSMenuItem *restartItem = [[NSMenuItem alloc] initWithTitle:@"Restart Whisper Engine" action:@selector(restartServer:) keyEquivalent:@""];
    restartItem.target = self;
    [menu addItem:restartItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit VoicePTT" action:@selector(quitApp:) keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
}

#pragma mark - Menu Actions

- (void)openAccessibilityPrefs:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)copyLastTranscript:(id)sender {
    if (self.lastTranscript.length > 0) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:self.lastTranscript forType:NSPasteboardTypeString];
    }
}

- (void)selectMode:(NSMenuItem *)sender {
    self.mode = (PTTMode)sender.tag;
    [[NSUserDefaults standardUserDefaults] setInteger:self.mode forKey:kPrefModeKey];
    [self updateUI];
}

- (void)selectHotkey:(NSMenuItem *)sender {
    self.hotkeyIndex = sender.tag;
    self.triggerKeyIsDown = NO;
    [[NSUserDefaults standardUserDefaults] setInteger:self.hotkeyIndex forKey:kPrefHotkeyIndexKey];
    [self updateUI];
}

- (void)selectGatePreset:(NSMenuItem *)sender {
    self.gatePresetIndex = sender.tag;
    [[NSUserDefaults standardUserDefaults] setInteger:self.gatePresetIndex forKey:kPrefGatePresetKey];
    [self updateUI];
}

- (void)selectMicGain:(NSMenuItem *)sender {
    AudioDeviceID devID = ResolveInputDeviceID(self.selectedMicUID);
    SetInputDeviceGain(devID, (float)sender.tag / 100.0f);
    [self rebuildMenu];
}

- (void)selectMic:(NSMenuItem *)sender {
    self.selectedMicUID = sender.representedObject ?: @"";
    [[NSUserDefaults standardUserDefaults] setObject:self.selectedMicUID forKey:kPrefMicUIDKey];
    [self updateUI];
}

- (void)selectModel:(NSMenuItem *)sender {
    NSString *path = sender.representedObject;
    if (path && ![path isEqualToString:self.selectedModelPath]) {
        self.selectedModelPath = path;
        [[NSUserDefaults standardUserDefaults] setObject:path forKey:kPrefModelPathKey];
        [self restartServer:nil];
    }
}

- (void)toggleCaptureMediaButton:(id)sender {
    self.captureMediaButton = !self.captureMediaButton;
    [[NSUserDefaults standardUserDefaults] setBool:self.captureMediaButton forKey:kPrefCaptureMediaKey];
    [self updateUI];
}

- (void)toggleLiveCaption:(id)sender {
    self.liveCaptionEnabled = !self.liveCaptionEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:self.liveCaptionEnabled forKey:kPrefLiveCaptionKey];
    [self updateUI];
}

- (void)toggleShowPill:(id)sender {
    self.showPill = !self.showPill;
    [[NSUserDefaults standardUserDefaults] setBool:self.showPill forKey:kPrefShowPillKey];
    [self updateUI];
}

- (void)toggleTrailingSpace:(id)sender {
    self.addTrailingSpace = !self.addTrailingSpace;
    [[NSUserDefaults standardUserDefaults] setBool:self.addTrailingSpace forKey:kPrefTrailingSpaceKey];
    [self updateUI];
}

- (void)openPromptFile:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[self promptFilePath]]];
}

- (void)restartServer:(id)sender {
    if (self.serverTask && self.serverTask.isRunning) {
        [self.serverTask terminate];
        [self.serverTask waitUntilExit];
    }
    if (self.previewServerTask && self.previewServerTask.isRunning) {
        [self.previewServerTask terminate];
        [self.previewServerTask waitUntilExit];
    }
    self.serverReady = NO;
    self.previewServerReady = NO;
    self.state = AppStateStarting;
    [self updateUI];
    [self startWhisperServer];
}

- (void)quitApp:(id)sender {
    [NSApp terminate:nil];
}

#pragma mark - Whisper Server Lifecycle

- (void)startWhisperServer {
    NSString *bundledBin = [[NSBundle mainBundle] pathForResource:@"whisper-server" ofType:nil];
    NSString *fallbackBin = [self.baseDir stringByAppendingPathComponent:@"whisper.cpp/build/bin/whisper-server"];
    NSString *serverBin = (bundledBin && [[NSFileManager defaultManager] isExecutableFileAtPath:bundledBin]) ? bundledBin : fallbackBin;

    if (![[NSFileManager defaultManager] isExecutableFileAtPath:serverBin]) {
        NSLog(@"VoicePTT: whisper-server binary not found at %@", serverBin);
        return;
    }

    int cores32 = 6;
    size_t sz32 = sizeof(cores32);
    if (sysctlbyname("hw.physicalcpu", &cores32, &sz32, NULL, 0) != 0 || cores32 <= 0) {
        cores32 = 6;
    }

    // Note: NO -nf (allow temperature fallback to break repetition loops!) + -mc 0 (no looping context)
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[
        @"-m", self.selectedModelPath,
        @"--host", @"127.0.0.1",
        @"--port", [NSString stringWithFormat:@"%ld", (long)kServerPort],
        @"-t", [NSString stringWithFormat:@"%d", cores32],
        @"-bo", @"1",
        @"-bs", @"1",
        @"-mc", @"0",
        @"-l", @"en",
        @"-nt",
        @"-sns",
        @"-nth", @"0.65"
    ]];

    NSString *vadPath = [self vadModelPath];
    if (vadPath) {
        [args addObjectsFromArray:@[
            @"--vad",
            @"-vm", vadPath,
            @"-vt", @"0.60",
            @"-vspd", @"200",
            @"-vp", @"80"
        ]];
    }

    NSTask *task = [NSTask new];
    task.launchPath = serverBin;
    task.arguments = args;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *err = nil;
    [task launchAndReturnError:&err];
    if (err) {
        NSLog(@"VoicePTT: Failed to launch whisper-server: %@", err);
        return;
    }
    self.serverTask = task;

    // Launch dedicated fast preview server (base.en ~220ms) on separate port so live OSD never blocks final pass
    NSString *previewModel = [self fastPreviewModelPath];
    if (previewModel) {
        NSMutableArray *pArgs = [NSMutableArray arrayWithArray:@[
            @"-m", previewModel,
            @"--host", @"127.0.0.1",
            @"--port", [NSString stringWithFormat:@"%ld", (long)kPreviewServerPort],
            @"-t", @"4",
            @"-bo", @"1",
            @"-bs", @"1",
            @"-mc", @"0",
            @"-l", @"en",
            @"-nt",
            @"-sns",
            @"-nth", @"0.65"
        ]];
        if (vadPath) {
            [pArgs addObjectsFromArray:@[
                @"--vad",
                @"-vm", vadPath,
                @"-vt", @"0.58",
                @"-vspd", @"180",
                @"-vp", @"60"
            ]];
        }
        NSTask *pTask = [NSTask new];
        pTask.launchPath = serverBin;
        pTask.arguments = pArgs;
        pTask.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        pTask.standardError = [NSFileHandle fileHandleWithNullDevice];
        NSError *pErr = nil;
        [pTask launchAndReturnError:&pErr];
        if (!pErr) {
            self.previewServerTask = pTask;
            __block int retries = 0;
            [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:YES block:^(NSTimer * _Nonnull pTimer) {
                retries++;
                if (retries > 30 || self.previewServerReady) {
                    [pTimer invalidate];
                    return;
                }
                NSURL *pUrl = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/", (long)kPreviewServerPort]];
                [[[NSURLSession sharedSession] dataTaskWithURL:pUrl completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                    if (!e && r) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.previewServerReady = YES;
                            [pTimer invalidate];
                        });
                    }
                }] resume];
            }];
        }
    }

    [self.healthTimer invalidate];
    self.healthTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:YES block:^(NSTimer * _Nonnull timer) {
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/", (long)kServerPort]];
        NSURLSessionDataTask *check = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            if (!error && resp) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [timer invalidate];
                    self.healthTimer = nil;
                    self.serverReady = YES;
                    if (self.state == AppStateStarting) {
                        self.state = AppStateIdle;
                    }
                    [self updateUI];
                });
            }
        }];
        [check resume];
    }];
}

#pragma mark - Hotkey State Machine

- (void)beginSessionWithState:(AppState)newState {
    self.sessionGen++;
    self.liveCaptionText = @"";
    self.lastPreviewByteCount = 0;
    if ([self startAudioRecording]) {
        self.state = newState;
        [self startLivePreviewTimer];
        [self updateUI];
    }
}

- (void)handleTriggerDown {
    if (!self.serverReady || self.state == AppStateTranscribing) return;

    NSTimeInterval now = CACurrentMediaTime();

    if (self.mode == PTTModeToggleOnly) {
        if (self.state == AppStateIdle) {
            [self beginSessionWithState:AppStateLocked];
        } else if (self.state == AppStateLocked) {
            [self finishRecordingAndTranscribe];
        }
        return;
    }

    if (self.mode == PTTModeHoldOnly) {
        if (self.state == AppStateIdle) {
            self.holdStartTime = now;
            [self beginSessionWithState:AppStateHolding];
        }
        return;
    }

    // Smart Mode: Hold to talk, OR quick double-tap to lock hands-free
    if (self.state == AppStateLocked) {
        [self finishRecordingAndTranscribe];
        return;
    }

    if (self.state == AppStateIdle) {
        if (now - self.lastShortTapReleaseTime < 0.38) {
            self.lastShortTapReleaseTime = 0;
            [self beginSessionWithState:AppStateLocked];
        } else {
            self.holdStartTime = now;
            [self beginSessionWithState:AppStateHolding];
        }
    }
}

- (void)handleTriggerUp {
    if (self.state != AppStateHolding) return;

    NSTimeInterval heldDuration = CACurrentMediaTime() - self.holdStartTime;

    if (self.otherKeyPressedDuringHold) {
        [self cancelRecording];
        return;
    }

    if (self.mode == PTTModeSmart && heldDuration < 0.25) {
        [self stopLivePreviewTimer];
        [self stopAudioRecording];
        self.liveCaptionText = @"";
        self.lastShortTapReleaseTime = CACurrentMediaTime();
        self.state = AppStateIdle;
        [self updateUI];
        return;
    }

    [self finishRecordingAndTranscribe];
}

- (void)handleMediaButtonToggle {
    if (!self.serverReady || self.state == AppStateTranscribing) return;
    if (self.state == AppStateIdle) {
        [self beginSessionWithState:AppStateLocked];
    } else if (self.state == AppStateHolding || self.state == AppStateLocked) {
        [self finishRecordingAndTranscribe];
    }
}

- (void)cancelRecording {
    self.sessionGen++;
    [self stopLivePreviewTimer];
    [self stopAudioRecording];
    self.liveCaptionText = @"";
    self.lastShortTapReleaseTime = 0;
    self.state = AppStateIdle;
    [self updateUI];
}

#pragma mark - Live Caption Preview Timer

- (void)startLivePreviewTimer {
    [self stopLivePreviewTimer];
    if (!self.liveCaptionEnabled || !self.showPill) return;

    self.livePreviewTimer = [NSTimer scheduledTimerWithTimeInterval:0.40 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [self runLiveCaptionPreview];
    }];
}

- (void)stopLivePreviewTimer {
    [self.livePreviewTimer invalidate];
    self.livePreviewTimer = nil;
}

- (void)runLiveCaptionPreview {
    if (self.previewInFlight || (self.state != AppStateHolding && self.state != AppStateLocked)) return;

    NSData *snapshot = nil;
    float peak = 0.0f;
    [self.audioLock lock];
    if (self.pcmBuffer && self.pcmBuffer.length >= (16000 * 2 / 2)) {
        // Trigger fast preview whenever >= 0.25s of new audio arrived
        if (self.pcmBuffer.length - self.lastPreviewByteCount >= (16000 * 2 / 4)) {
            // Cap live preview to latest 10 seconds so OSD stays ~200ms snappy
            NSUInteger maxPreviewBytes = 16000 * 2 * 10;
            if (self.pcmBuffer.length > maxPreviewBytes) {
                NSRange tail = NSMakeRange(self.pcmBuffer.length - maxPreviewBytes, maxPreviewBytes);
                snapshot = [self.pcmBuffer subdataWithRange:tail];
            } else {
                snapshot = [self.pcmBuffer copy];
            }
            self.lastPreviewByteCount = self.pcmBuffer.length;
            peak = _peakRMS;
        }
    }
    [self.audioLock unlock];

    float gateThresh = kGatePresets[self.gatePresetIndex].threshold;
    if (!snapshot || peak < gateThresh) return;

    NSData *gated = [self applyNoiseGateAndTrimPCM:snapshot threshold:gateThresh];
    if (!gated || gated.length < (16000 * 2 / 3)) return;

    self.previewInFlight = YES;
    NSUInteger gen = self.sessionGen;

    [self sendPCMToWhisper:gated isPreview:YES completion:^(NSString *cleaned, double elapsed) {
        self.previewInFlight = NO;
        if (gen == self.sessionGen && (self.state == AppStateHolding || self.state == AppStateLocked)) {
            if (cleaned.length > 0) {
                self.liveCaptionText = cleaned;
                [self updateUI];
            }
        }
    }];
}

#pragma mark - CoreAudio Recording

- (BOOL)startAudioRecording {
    [self stopAudioRecording];

    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = 16000.0;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    fmt.mChannelsPerFrame = 1;
    fmt.mBitsPerChannel = 16;
    fmt.mBytesPerFrame = 2;
    fmt.mBytesPerPacket = 2;
    fmt.mFramesPerPacket = 1;

    OSStatus st = AudioQueueNewInput(&fmt, AudioInputCallback, (__bridge void *)self, NULL, kCFRunLoopCommonModes, 0, &_audioQueue);
    if (st != noErr || !_audioQueue) {
        NSLog(@"VoicePTT: AudioQueueNewInput failed: %d", (int)st);
        return NO;
    }

    if (self.selectedMicUID.length > 0) {
        CFStringRef uid = (__bridge CFStringRef)self.selectedMicUID;
        AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_CurrentDevice, &uid, sizeof(CFStringRef));
    }

    [self.audioLock lock];
    self.pcmBuffer = [NSMutableData dataWithCapacity:16000 * 2 * 15];
    _peakRMS = 0.0f;
    _isRecordingAudio = YES;
    [self.audioLock unlock];

    UInt32 bufBytes = 1600; // 50ms chunks at 16kHz 16-bit mono
    for (int i = 0; i < 3; i++) {
        AudioQueueAllocateBuffer(_audioQueue, bufBytes, &_audioBuffers[i]);
        memset(_audioBuffers[i]->mAudioData, 0, bufBytes);
        AudioQueueEnqueueBuffer(_audioQueue, _audioBuffers[i], 0, NULL);
    }

    st = AudioQueueStart(_audioQueue, NULL);
    if (st != noErr) {
        NSLog(@"VoicePTT: AudioQueueStart failed: %d", (int)st);
        [self stopAudioRecording];
        return NO;
    }
    return YES;
}

- (NSData *)stopAudioRecording {
    [self.audioLock lock];
    _isRecordingAudio = NO;
    [self.audioLock unlock];

    if (_audioQueue) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    }

    [self.audioLock lock];
    NSData *captured = [self.pcmBuffer copy];
    self.pcmBuffer = nil;
    [self.audioLock unlock];
    return captured;
}

#pragma mark - Noise Gate, Transcription & Repetition Guard

- (NSData *)applyNoiseGateAndTrimPCM:(NSData *)pcm threshold:(float)thresh {
    const int16_t *src = (const int16_t *)pcm.bytes;
    NSUInteger totalSamples = pcm.length / sizeof(int16_t);
    if (totalSamples < 320) return nil;

    // 20ms windows (320 samples @ 16kHz), with 240ms hold/pre-roll around speech so syllables never chop
    const NSUInteger win = 320;
    const NSUInteger numWins = totalSamples / win;
    if (numWins == 0) return nil;

    uint8_t *active = (uint8_t *)calloc(numWins, 1);
    if (!active) return pcm;

    NSInteger firstSpeechWin = -1;
    NSInteger lastSpeechWin = -1;
    for (NSUInteger w = 0; w < numWins; w++) {
        double sumSq = 0.0;
        const int16_t *p = src + (w * win);
        for (NSUInteger j = 0; j < win; j++) {
            double s = (double)p[j] / 32768.0;
            sumSq += s * s;
        }
        float rms = (float)sqrt(sumSq / (double)win);
        if (rms >= thresh) {
            if (firstSpeechWin < 0) firstSpeechWin = (NSInteger)w;
            lastSpeechWin = (NSInteger)w;
            // Open gate for 12 windows (~240ms) before and after speech energy
            NSInteger lo = MAX(0, (NSInteger)w - 10);
            NSInteger hi = MIN((NSInteger)numWins - 1, (NSInteger)w + 14);
            for (NSInteger k = lo; k <= hi; k++) active[k] = 1;
        }
    }

    if (firstSpeechWin < 0 || lastSpeechWin < firstSpeechWin) {
        free(active);
        return nil;
    }

    NSUInteger startWin = (NSUInteger)MAX(0, firstSpeechWin - 10);
    NSUInteger endWin = (NSUInteger)MIN((NSInteger)numWins, lastSpeechWin + 15);
    NSUInteger outSamples = (endWin - startWin) * win;

    NSMutableData *out = [NSMutableData dataWithLength:outSamples * sizeof(int16_t)];
    int16_t *dst = (int16_t *)out.mutableBytes;

    for (NSUInteger w = startWin; w < endWin; w++) {
        int16_t *d = dst + ((w - startWin) * win);
        if (active[w]) {
            memcpy(d, src + (w * win), win * sizeof(int16_t));
        } else {
            // Hard-zero quiet TV/background windows between phrases
            memset(d, 0, win * sizeof(int16_t));
        }
    }

    free(active);
    return out;
}

- (void)finishRecordingAndTranscribe {
    self.sessionGen++;
    [self stopLivePreviewTimer];
    NSData *pcm = [self stopAudioRecording];
    float peak = _peakRMS;
    float gateThresh = kGatePresets[self.gatePresetIndex].threshold;

    if (!pcm || pcm.length < (16000 * 2 / 4) || peak < gateThresh) {
        self.liveCaptionText = @"";
        self.state = AppStateIdle;
        [self updateUI];
        return;
    }

    NSData *gatedPCM = [self applyNoiseGateAndTrimPCM:pcm threshold:gateThresh];
    if (!gatedPCM || gatedPCM.length < (16000 * 2 / 5)) {
        self.liveCaptionText = @"";
        self.state = AppStateIdle;
        [self updateUI];
        return;
    }

    self.state = AppStateTranscribing;
    [self updateUI];

    [self sendPCMToWhisper:gatedPCM isPreview:NO completion:^(NSString *cleaned, double elapsed) {
        self.state = AppStateIdle;
        self.liveCaptionText = @"";
        if (cleaned.length > 0) {
            self.lastTranscript = cleaned;
            self.lastLatencySec = elapsed;
            NSString *toPaste = self.addTrailingSpace ? [cleaned stringByAppendingString:@" "] : cleaned;
            [self pasteTextPreservingClipboard:toPaste];
        }
        [self updateUI];
    }];
}

- (void)sendPCMToWhisper:(NSData *)pcm isPreview:(BOOL)isPreview completion:(void (^)(NSString *cleaned, double elapsed))completion {
    double durationSec = (double)pcm.length / (16000.0 * 2.0);
    // Safe dynamic audio_ctx: tighter for fast base.en preview, generous for final medium.en pass
    NSInteger audioCtx = 0;
    if (durationSec < 22.0) {
        double pad = isPreview ? 1.5 : 2.5;
        NSInteger minCtx = isPreview ? 256 : 384;
        NSInteger frames = (NSInteger)ceil((durationSec + pad) * 50.0);
        audioCtx = ((frames + 63) / 64) * 64;
        if (audioCtx < minCtx) audioCtx = minCtx;
        if (audioCtx >= 1500) audioCtx = 0;
    }

    NSData *wavData = BuildWAVData(pcm);
    NSString *prompt = isPreview ? @"" : [self loadCustomPrompt];
    NSTimeInterval t0 = CACurrentMediaTime();

    NSString *boundary = [NSString stringWithFormat:@"----VoicePTT%@", [[NSUUID UUID] UUIDString]];
    NSMutableData *body = [NSMutableData data];

    void (^appendField)(NSString *, NSString *) = ^(NSString *name, NSString *val) {
        [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", boundary, name, val] dataUsingEncoding:NSUTF8StringEncoding]];
    };

    [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:wavData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    appendField(@"temperature", @"0.0");
    appendField(@"temperature_inc", @"0.2"); // allows Whisper to break repetition loops!
    appendField(@"entropy_thold", @"2.2");
    appendField(@"no_speech_thold", @"0.65");
    appendField(@"response_format", @"json");
    if (audioCtx > 0) {
        appendField(@"audio_ctx", [NSString stringWithFormat:@"%ld", (long)audioCtx]);
    }
    if (prompt.length > 0) {
        appendField(@"prompt", prompt);
    }
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

    NSInteger targetPort = (isPreview && self.previewServerReady) ? kPreviewServerPort : kServerPort;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/inference", (long)targetPort]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30.0;
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = body;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *cleaned = nil;
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]] && [json[@"text"] isKindOfClass:[NSString class]]) {
                cleaned = [self sanitizeTranscript:json[@"text"]];
            }
        }
        double elapsed = CACurrentMediaTime() - t0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(cleaned ?: @"", elapsed);
        });
    }];
    [task resume];
}

// Collapse Whisper n-gram repetition loops (e.g. "thank you thank you thank you...")
- (NSString *)collapseRepetitionLoops:(NSString *)text {
    NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];
    if (words.count < 6) return text;

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSUInteger i = 0;
    while (i < words.count) {
        BOOL collapsed = NO;
        // Check phrase lengths 1..8 words repeating 3+ consecutive times
        for (NSUInteger n = 1; n <= 8 && i + n * 3 <= words.count; n++) {
            NSUInteger reps = 1;
            while (i + (reps + 1) * n <= words.count) {
                BOOL match = YES;
                for (NSUInteger k = 0; k < n; k++) {
                    NSString *a = [words[i + k].lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
                    NSString *b = [words[i + reps * n + k].lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
                    if (![a isEqualToString:b]) {
                        match = NO;
                        break;
                    }
                }
                if (!match) break;
                reps++;
            }
            if (reps >= 3) {
                for (NSUInteger k = 0; k < n; k++) [out addObject:words[i + k]];
                i += reps * n;
                collapsed = YES;
                break;
            }
        }
        if (!collapsed) {
            [out addObject:words[i]];
            i++;
        }
    }
    return [out componentsJoinedByString:@" "];
}

- (NSString *)sanitizeTranscript:(NSString *)raw {
    if (!raw) return @"";
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    s = [[s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    while ([s containsString:@"  "]) {
        s = [s stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (s.length == 0) return @"";

    // Remove common bracketed non-speech markers even mid-string
    NSError *reErr = nil;
    NSRegularExpression *brackRe = [NSRegularExpression regularExpressionWithPattern:@"\\[[^\\]]*\\]|\\([^\\)]*\\)" options:0 error:&reErr];
    if (brackRe) {
        s = [brackRe stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
        while ([s containsString:@"  "]) s = [s stringByReplacingOccurrencesOfString:@"  " withString:@" "];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    if (s.length == 0) return @"";

    s = [self collapseRepetitionLoops:s];

    NSString *lower = [s.lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
    NSArray *ignore = @[ @"you", @"thank you", @"thanks for watching", @"bye", @"hmm", @"uh" ];
    for (NSString *tok in ignore) {
        if ([lower isEqualToString:tok]) return @"";
    }
    return s;
}

- (void)pasteTextPreservingClipboard:(NSString *)text {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];

    NSMutableArray<NSDictionary<NSPasteboardType, NSData *> *> *savedItems = [NSMutableArray array];
    for (NSPasteboardItem *item in pb.pasteboardItems) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (NSPasteboardType type in item.types) {
            NSData *d = [item dataForType:type];
            if (d) dict[type] = d;
        }
        if (dict.count > 0) [savedItems addObject:dict];
    }

    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
    NSInteger ourChangeCount = pb.changeCount;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        CGEventRef vDown = CGEventCreateKeyboardEvent(src, 9, true);
        CGEventRef vUp   = CGEventCreateKeyboardEvent(src, 9, false);
        CGEventSetFlags(vDown, kCGEventFlagMaskCommand);
        CGEventSetFlags(vUp,   kCGEventFlagMaskCommand);
        CGEventPost(kCGHIDEventTap, vDown);
        CGEventPost(kCGHIDEventTap, vUp);
        CFRelease(vDown);
        CFRelease(vUp);
        if (src) CFRelease(src);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (pb.changeCount == ourChangeCount && savedItems.count > 0) {
                [pb clearContents];
                NSMutableArray *restored = [NSMutableArray arrayWithCapacity:savedItems.count];
                for (NSDictionary *dict in savedItems) {
                    NSPasteboardItem *newItem = [NSPasteboardItem new];
                    for (NSPasteboardType t in dict) {
                        [newItem setData:dict[t] forType:t];
                    }
                    [restored addObject:newItem];
                }
                [pb writeObjects:restored];
            }
        });
    });
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        VoicePTTApp *delegate = [VoicePTTApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
