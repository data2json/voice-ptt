#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <QuartzCore/QuartzCore.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/ev_keymap.h>
#include <sys/sysctl.h>
#include <stdlib.h>

typedef NS_ENUM(NSInteger, PTTMode) {
    PTTModeSmart = 0,     // Hold to talk, OR quick double-tap to lock hands-free
    PTTModeHoldOnly = 1,  // Strict hold-to-talk
    PTTModeToggleOnly = 2 // Tap once to start, tap again to stop
};

typedef NS_ENUM(NSInteger, OutputMode) {
    OutputModeSmartAuto = 0,     // Paste if text field focused, else copy to clipboard
    OutputModeAlwaysPaste = 1,   // Always paste preserving clipboard
    OutputModeClipboardOnly = 2  // Always copy to clipboard + show OSD toast
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
    float threshold; // <= 0 means adaptive ambient noise floor
    NSString *label;
} GatePreset;

static const GatePreset kGatePresets[] = {
    { -1.0f,  @"Auto (Adaptive Room Floor)" },
    { 0.012f, @"Low (Quiet Room)" },
    { 0.025f, @"Medium (Normal)" },
    { 0.045f, @"High (TV / Background Noise)" },
    { 0.080f, @"Very High (Close Mic Only)" }
};
static const NSInteger kGatePresetCount = 5;

static NSString * const kPrefModeKey = @"VoicePTTMode";
static NSString * const kPrefOutputModeKey = @"VoicePTTOutputMode";
static NSString * const kPrefHotkeyIndexKey = @"VoicePTTHotkeyIndex";
static NSString * const kPrefMicUIDKey = @"VoicePTTMicUID";
static NSString * const kPrefMicArmedKey = @"VoicePTTMicArmed";
static NSString * const kPrefModelPathKey = @"VoicePTTModelPath";
static NSString * const kPrefShowPillKey = @"VoicePTTShowPill";
static NSString * const kPrefTrailingSpaceKey = @"VoicePTTTrailingSpace";
static NSString * const kPrefCaptureMediaKey = @"VoicePTTCaptureMediaButton";
static NSString * const kPrefGatePresetKey = @"VoicePTTGatePresetV2";
static NSString * const kPrefLiveCaptionKey = @"VoicePTTLiveCaption";

static const NSInteger kServerPort = 8178;
static const NSInteger kPreviewServerPort = 8179;
static const uint32_t kSampleRate = 16000;
static const uint64_t kRingCapacitySamples = 16000ULL * 180ULL; // 3 minutes continuous PCM (~5.76 MB)
static const NSUInteger kIdleRMSRingSize = 120;                 // 6 seconds of 50ms chunks

static int CompareFloats(const void *a, const void *b) {
    float fa = *(const float *)a;
    float fb = *(const float *)b;
    return (fa > fb) - (fa < fb);
}

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

    // Live audio level meter on the top-right (green when clearing noise gate, gray below gate)
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

    // Live Caption Text
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
    const uint32_t trailingSilenceBytes = (uint32_t)(kSampleRate * 2 * 45 / 100); // 450ms silence pad
    uint32_t dataSize = (uint32_t)pcmData.length + trailingSilenceBytes;
    uint32_t chunkSize = 36 + dataSize;
    uint16_t audioFormat = 1;
    uint16_t numChannels = 1;
    uint32_t sampleRate = kSampleRate;
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
// Focus Detection via Accessibility API (Smart Auto Paste vs. Clipboard)
// -----------------------------------------------------------------------------
static BOOL IsFocusedElementEditableText(NSString **outAppName) {
    NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (outAppName) {
        *outAppName = frontApp.localizedName ?: @"";
    }
    NSString *bundleID = frontApp.bundleIdentifier ?: @"";

    // GPU/custom terminals often don't expose standard AXTextArea attributes
    static NSSet<NSString *> *terminalBundles = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        terminalBundles = [NSSet setWithArray:@[
            @"com.apple.Terminal",
            @"com.googlecode.iterm2",
            @"com.mitchellh.ghostty",
            @"net.kovidgoyal.kitty",
            @"org.alacritty",
            @"io.alacritty",
            @"dev.warp.Warp-Stable",
            @"com.github.wez.wezterm",
            @"org.gnu.Emacs"
        ]];
    });
    if ([terminalBundles containsObject:bundleID]) {
        return YES;
    }

    if (!AXIsProcessTrusted()) return NO;

    AXUIElementRef sysWide = AXUIElementCreateSystemWide();
    if (!sysWide) return NO;
    AXUIElementSetMessagingTimeout(sysWide, 0.15f);

    CFTypeRef focusedRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(sysWide, kAXFocusedUIElementAttribute, &focusedRef);
    CFRelease(sysWide);
    if (err != kAXErrorSuccess || !focusedRef) {
        return NO;
    }

    AXUIElementRef focused = (AXUIElementRef)focusedRef;
    AXUIElementSetMessagingTimeout(focused, 0.15f);

    BOOL editable = NO;

    CFTypeRef roleRef = NULL;
    if (AXUIElementCopyAttributeValue(focused, kAXRoleAttribute, &roleRef) == kAXErrorSuccess && roleRef) {
        if (CFGetTypeID(roleRef) == CFStringGetTypeID()) {
            NSString *role = (__bridge NSString *)roleRef;
            if ([role isEqualToString:(NSString *)kAXTextFieldRole] ||
                [role isEqualToString:(NSString *)kAXTextAreaRole] ||
                [role isEqualToString:(NSString *)kAXComboBoxRole] ||
                [role isEqualToString:@"AXSearchField"]) {
                editable = YES;
            }
        }
        CFRelease(roleRef);
    }

    if (!editable) {
        CFTypeRef subroleRef = NULL;
        if (AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute, &subroleRef) == kAXErrorSuccess && subroleRef) {
            if (CFGetTypeID(subroleRef) == CFStringGetTypeID()) {
                NSString *sub = (__bridge NSString *)subroleRef;
                if ([sub isEqualToString:@"AXSearchField"] || [sub isEqualToString:@"AXSecureTextField"]) {
                    editable = YES;
                }
            }
            CFRelease(subroleRef);
        }
    }

    if (!editable) {
        Boolean settable = false;
        if (AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute, &settable) == kAXErrorSuccess && settable) {
            editable = YES;
        }
    }

    if (!editable) {
        Boolean settable = false;
        if (AXUIElementIsAttributeSettable(focused, kAXValueAttribute, &settable) == kAXErrorSuccess && settable) {
            // Confirm it's not a slider/checkbox by checking for insertion point or text marker support
            CFTypeRef selRangeRef = NULL;
            if (AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute, &selRangeRef) == kAXErrorSuccess && selRangeRef) {
                editable = YES;
                CFRelease(selRangeRef);
            }
        }
    }

    if (!editable) {
        CFTypeRef axEditableRef = NULL;
        if (AXUIElementCopyAttributeValue(focused, CFSTR("AXEditable"), &axEditableRef) == kAXErrorSuccess && axEditableRef) {
            if (CFGetTypeID(axEditableRef) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)axEditableRef)) {
                editable = YES;
            }
            CFRelease(axEditableRef);
        }
    }

    if (!editable) {
        CFTypeRef lineRef = NULL;
        if (AXUIElementCopyAttributeValue(focused, kAXInsertionPointLineNumberAttribute, &lineRef) == kAXErrorSuccess && lineRef) {
            editable = YES;
            CFRelease(lineRef);
        }
    }

    CFRelease(focused);
    return editable;
}

// -----------------------------------------------------------------------------
// Main App Controller
// -----------------------------------------------------------------------------
@interface VoicePTTApp : NSObject <NSApplicationDelegate> {
@public
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _audioBuffers[4];
    BOOL _audioQueueRunning;

    // Continuous 16kHz 16-bit mono ring buffer
    int16_t *_ringSamples;
    uint64_t _ringTotalSamples;

    // Rolling ambient room-noise estimator (updated while idle)
    float _idleRMSRing[kIdleRMSRingSize];
    NSUInteger _idleRMSPos;
    NSUInteger _idleRMSCount;
    float _ambientNoiseFloor;

    // Active extraction markers
    BOOL _isCapturingSession;
    uint64_t _captureStartSample;
    float _capturePeakRMS;

    CFMachPortRef _eventTap;
    CFRunLoopSourceRef _eventTapSource;
}
- (void)handleTriggerDown;
- (void)handleTriggerUp;
- (void)handleMediaButtonToggle;
- (void)cancelRecording;
- (float)effectiveGateThresholdLocked;

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSPanel *osdPanel;
@property (nonatomic, strong) LiveOSDView *osdView;
@property (nonatomic, strong) NSTask *serverTask;
@property (nonatomic, strong) NSTask *previewServerTask;
@property (nonatomic, assign) BOOL previewServerReady;
@property (nonatomic, strong) NSLock *audioLock;
@property (nonatomic, assign) AppState state;
@property (nonatomic, assign) PTTMode mode;
@property (nonatomic, assign) OutputMode outputMode;
@property (nonatomic, assign) NSInteger hotkeyIndex;
@property (nonatomic, assign) NSInteger gatePresetIndex;
@property (nonatomic, copy) NSString *selectedMicUID;
@property (nonatomic, assign) BOOL micArmed;
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
@property (nonatomic, copy) NSString *lastOutputStatus;
@property (nonatomic, assign) double lastLatencySec;
@property (nonatomic, strong) NSTimer *permPollTimer;
@property (nonatomic, strong) NSTimer *healthTimer;
@property (nonatomic, strong) NSTimer *livePreviewTimer;
@property (nonatomic, strong) NSTimer *toastTimer;
@property (nonatomic, strong) NSTimer *audioRestartTimer;
@property (nonatomic, assign) BOOL previewInFlight;
@property (nonatomic, assign) uint64_t lastPreviewSampleCount;
@property (nonatomic, assign) NSUInteger sessionGen;
@property (nonatomic, assign) BOOL serverReady;
@property (nonatomic, copy) NSString *baseDir;
@property (nonatomic, copy) NSDictionary *pipelineConfig;
@property (nonatomic, copy) AudioObjectPropertyListenerBlock hwListenerBlock;
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
    BOOL isCapturing = NO;
    float rms = 0.0f;
    float gateThresh = 0.025f;

    [app.audioLock lock];
    if (app->_audioQueueRunning && app->_ringSamples && bytes >= sizeof(int16_t)) {
        const int16_t *samples = (const int16_t *)inBuffer->mAudioData;
        UInt32 count = bytes / sizeof(int16_t);

        // Compute chunk RMS
        double sumSq = 0.0;
        for (UInt32 i = 0; i < count; i++) {
            double s = (double)samples[i] / 32768.0;
            sumSq += s * s;
        }
        rms = (count > 0) ? (float)sqrt(sumSq / (double)count) : 0.0f;

        // Write into circular ring buffer
        uint64_t writeIdx = app->_ringTotalSamples % kRingCapacitySamples;
        uint64_t firstPart = MIN((uint64_t)count, kRingCapacitySamples - writeIdx);
        memcpy(app->_ringSamples + writeIdx, samples, (size_t)firstPart * sizeof(int16_t));
        if (firstPart < count) {
            memcpy(app->_ringSamples, samples + firstPart, (size_t)(count - firstPart) * sizeof(int16_t));
        }
        app->_ringTotalSamples += count;

        if (app->_isCapturingSession) {
            isCapturing = YES;
            if (rms > app->_capturePeakRMS) {
                app->_capturePeakRMS = rms;
            }
        } else {
            // Track rolling ambient noise floor during idle periods (30th percentile)
            app->_idleRMSRing[app->_idleRMSPos] = rms;
            app->_idleRMSPos = (app->_idleRMSPos + 1) % kIdleRMSRingSize;
            if (app->_idleRMSCount < kIdleRMSRingSize) {
                app->_idleRMSCount++;
            }
            if (app->_idleRMSCount >= 10 && (app->_idleRMSPos % 5 == 0)) {
                float sorted[kIdleRMSRingSize];
                memcpy(sorted, app->_idleRMSRing, app->_idleRMSCount * sizeof(float));
                qsort(sorted, app->_idleRMSCount, sizeof(float), CompareFloats);
                NSUInteger p30 = (NSUInteger)((double)app->_idleRMSCount * 0.30);
                if (p30 >= app->_idleRMSCount) p30 = app->_idleRMSCount - 1;
                float floorVal = sorted[p30];
                // Smooth update
                app->_ambientNoiseFloor = (app->_ambientNoiseFloor > 0.0f)
                    ? (app->_ambientNoiseFloor * 0.7f + floorVal * 0.3f)
                    : floorVal;
            }
        }

        gateThresh = [app effectiveGateThresholdLocked];
        shouldReenqueue = YES;
    }
    [app.audioLock unlock];

    if (shouldReenqueue) {
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);

        // Only wake main thread for live meter redraw while actively capturing
        if (isCapturing) {
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
    _ringSamples = (int16_t *)calloc((size_t)kRingCapacitySamples, sizeof(int16_t));
    _ambientNoiseFloor = 0.008f;
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
    [self loadPipelineConfig];
    [self setupStatusItem];
    [self setupFloatingOSD];
    [self setupAudioLifecycleObservers];
    [self requestMicrophonePermissionAndArm];
    [self startWhisperServer];
    [self setupEventTapWithPrompt:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self stopLivePreviewTimer];
    [self.toastTimer invalidate];
    [self.audioRestartTimer invalidate];
    [self teardownAudioLifecycleObservers];
    [self stopContinuousAudioCapture];
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
    [self.audioLock lock];
    if (_ringSamples) {
        free(_ringSamples);
        _ringSamples = NULL;
    }
    [self.audioLock unlock];
}

#pragma mark - Preferences & Pipeline Config

- (void)loadPreferences {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    self.mode = [d objectForKey:kPrefModeKey] ? [d integerForKey:kPrefModeKey] : PTTModeSmart;
    self.outputMode = [d objectForKey:kPrefOutputModeKey] ? [d integerForKey:kPrefOutputModeKey] : OutputModeSmartAuto;
    self.hotkeyIndex = [d objectForKey:kPrefHotkeyIndexKey] ? [d integerForKey:kPrefHotkeyIndexKey] : 0;
    if (self.hotkeyIndex < 0 || self.hotkeyIndex >= kHotkeyOptionCount) self.hotkeyIndex = 0;

    // Default to Auto (Adaptive Room Floor)
    self.gatePresetIndex = [d objectForKey:kPrefGatePresetKey] ? [d integerForKey:kPrefGatePresetKey] : 0;
    if (self.gatePresetIndex < 0 || self.gatePresetIndex >= kGatePresetCount) self.gatePresetIndex = 0;

    self.selectedMicUID = [d stringForKey:kPrefMicUIDKey] ?: @"";
    self.micArmed = [d objectForKey:kPrefMicArmedKey] ? [d boolForKey:kPrefMicArmedKey] : YES;
    self.showPill = [d objectForKey:kPrefShowPillKey] ? [d boolForKey:kPrefShowPillKey] : YES;
    self.liveCaptionEnabled = [d objectForKey:kPrefLiveCaptionKey] ? [d boolForKey:kPrefLiveCaptionKey] : YES;
    self.addTrailingSpace = [d objectForKey:kPrefTrailingSpaceKey] ? [d boolForKey:kPrefTrailingSpaceKey] : NO;
    self.captureMediaButton = [d objectForKey:kPrefCaptureMediaKey] ? [d boolForKey:kPrefCaptureMediaKey] : YES;

    NSString *savedModel = [d stringForKey:kPrefModelPathKey];
    if (savedModel && [[NSFileManager defaultManager] fileExistsAtPath:savedModel] && ![savedModel.lastPathComponent containsString:@"silero"]) {
        self.selectedModelPath = savedModel;
    } else {
        NSString *mediumPath = [self.baseDir stringByAppendingPathComponent:@"models/ggml-medium.en-q5_0.bin"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:mediumPath]) {
            self.selectedModelPath = mediumPath;
        } else {
            NSArray<NSString *> *models = [self availableModels];
            self.selectedModelPath = models.firstObject ?: [self.baseDir stringByAppendingPathComponent:@"models/ggml-small.en-q5_1.bin"];
        }
    }
}

- (NSString *)configDirPath {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@".config/voice-ptt"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)configFilePath {
    NSString *path = [[self configDirPath] stringByAppendingPathComponent:@"config.json"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSDictionary *defaults = [self defaultPipelineConfig];
        NSData *json = [NSJSONSerialization dataWithJSONObject:defaults options:NSJSONWritingPrettyPrinted error:nil];
        if (json) {
            [json writeToFile:path atomically:YES];
        }
    }
    return path;
}

- (NSDictionary *)defaultPipelineConfig {
    return @{
        @"pre_roll_ms": @300,
        @"post_roll_ms": @200,
        @"adaptive_gate_multiplier": @2.6,
        @"adaptive_gate_min": @0.012,
        @"adaptive_gate_max": @0.11,
        @"llm": @{
            @"enabled": @NO,
            @"base_url": @"http://127.0.0.1:11434/v1",
            @"api_key": @"",
            @"model": @"qwen2.5:3b",
            @"timeout_sec": @12.0,
            @"temperature": @0.0,
            @"min_words_to_refine": @4,
            @"system_prompt": @"You clean up speech-to-text transcriptions. Fix obvious ASR mishearings, punctuation, capitalization, and spoken self-corrections (e.g., 'no wait, make that...'). Preserve the speaker's exact meaning and wording. Never answer questions or add commentary. Output ONLY the cleaned text."
        },
        @"decision_router": @{
            @"enabled": @NO,
            @"endpoint_url": @"http://127.0.0.1:8180/decide",
            @"model": @"Intern-Decision-2B",
            @"timeout_sec": @2.5,
            @"schema": @{
                @"needs_refine": @[ @"yes", @"no" ],
                @"output_action": @[ @"paste", @"clipboard", @"discard" ],
                @"style": @[ @"prose", @"code", @"command" ]
            }
        }
    };
}

- (NSDictionary *)loadPipelineConfig {
    NSString *path = [self configFilePath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            self.pipelineConfig = parsed;
            return parsed;
        }
    }
    NSDictionary *def = [self defaultPipelineConfig];
    self.pipelineConfig = def;
    return def;
}

- (BOOL)savePipelineConfig:(NSDictionary *)cfg {
    NSString *path = [self configFilePath];
    NSData *json = [NSJSONSerialization dataWithJSONObject:cfg options:NSJSONWritingPrettyPrinted error:nil];
    if (!json) return NO;
    BOOL ok = [json writeToFile:path atomically:YES];
    if (ok) {
        self.pipelineConfig = cfg;
    }
    return ok;
}

- (BOOL)isLLMRefinementEnabled {
    NSDictionary *llm = self.pipelineConfig[@"llm"];
    return [llm isKindOfClass:[NSDictionary class]] && [llm[@"enabled"] boolValue];
}

- (BOOL)isDecisionRouterEnabled {
    NSDictionary *dr = self.pipelineConfig[@"decision_router"];
    return [dr isKindOfClass:[NSDictionary class]] && [dr[@"enabled"] boolValue];
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
    NSString *path = [[self configDirPath] stringByAppendingPathComponent:@"prompt.txt"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    return path;
}

- (NSString *)loadCustomPrompt {
    NSString *text = [NSString stringWithContentsOfFile:[self promptFilePath] encoding:NSUTF8StringEncoding error:nil];
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

#pragma mark - Permissions & Audio Lifecycle Observers

- (void)requestMicrophonePermissionAndArm {
    if (@available(macOS 10.14, *)) {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (status == AVAuthorizationStatusAuthorized) {
            if (self.micArmed) {
                [self startContinuousAudioCapture];
            }
        } else if (status == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                if (granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (self.micArmed) {
                            [self startContinuousAudioCapture];
                            [self updateUI];
                        }
                    });
                }
            }];
        }
    } else {
        if (self.micArmed) {
            [self startContinuousAudioCapture];
        }
    }
}

- (void)setupAudioLifecycleObservers {
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(handleSystemWake:)
                                                               name:NSWorkspaceDidWakeNotification
                                                             object:nil];

    __weak typeof(self) weakSelf = self;
    self.hwListenerBlock = ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf scheduleAudioCaptureRestart:0.6];
    };

    AudioObjectPropertyAddress devAddr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectPropertyAddress defAddr = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &devAddr, dispatch_get_main_queue(), self.hwListenerBlock);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &defAddr, dispatch_get_main_queue(), self.hwListenerBlock);
}

- (void)teardownAudioLifecycleObservers {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    if (self.hwListenerBlock) {
        AudioObjectPropertyAddress devAddr = {
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        AudioObjectPropertyAddress defAddr = {
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &devAddr, dispatch_get_main_queue(), self.hwListenerBlock);
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &defAddr, dispatch_get_main_queue(), self.hwListenerBlock);
        self.hwListenerBlock = nil;
    }
}

- (void)handleSystemWake:(NSNotification *)note {
    [self scheduleAudioCaptureRestart:1.0];
}

- (void)scheduleAudioCaptureRestart:(NSTimeInterval)delay {
    if (!self.micArmed) return;
    [self.audioRestartTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.audioRestartTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer * _Nonnull timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.micArmed) return;
        if (strongSelf.state == AppStateIdle || strongSelf.state == AppStateStarting) {
            [strongSelf startContinuousAudioCapture];
            [strongSelf updateUI];
        }
    }];
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

- (void)showToastWithHeader:(NSString *)header caption:(NSString *)caption dotColor:(NSColor *)color duration:(NSTimeInterval)seconds {
    [self.toastTimer invalidate];
    self.toastTimer = nil;
    if (!self.showPill) return;

    NSUInteger gen = self.sessionGen;
    [self showOSDWithHeader:header caption:caption dotColor:color showMeter:NO];
    self.toastTimer = [NSTimer scheduledTimerWithTimeInterval:seconds repeats:NO block:^(NSTimer * _Nonnull timer) {
        self.toastTimer = nil;
        if (gen == self.sessionGen && self.state == AppStateIdle) {
            [self hideOSD];
        }
    }];
}

- (void)hideOSD {
    [self.toastTimer invalidate];
    self.toastTimer = nil;
    [self.osdPanel orderOut:nil];
}

- (void)updateUI {
    if (!AXIsProcessTrusted()) {
        self.statusItem.button.title = @"⚠️";
    } else if (!self.serverReady || self.state == AppStateStarting) {
        self.statusItem.button.title = @"⏳";
    } else if (self.state == AppStateHolding) {
        self.statusItem.button.title = @"🔴";
        [self.toastTimer invalidate];
        self.toastTimer = nil;
        [self showOSDWithHeader:@"Listening…" caption:self.liveCaptionText dotColor:[NSColor systemRedColor] showMeter:YES];
    } else if (self.state == AppStateLocked) {
        self.statusItem.button.title = @"🔒";
        [self.toastTimer invalidate];
        self.toastTimer = nil;
        [self showOSDWithHeader:@"Hands-Free  (tap to send · Esc cancel)" caption:self.liveCaptionText dotColor:[NSColor systemOrangeColor] showMeter:YES];
    } else if (self.state == AppStateTranscribing) {
        self.statusItem.button.title = @"⏳";
        [self.toastTimer invalidate];
        self.toastTimer = nil;
        NSString *hdr = [self isLLMRefinementEnabled] ? @"Finalizing + Refining…" : @"Finalizing…";
        [self showOSDWithHeader:hdr caption:self.liveCaptionText dotColor:[NSColor systemBlueColor] showMeter:NO];
    } else {
        self.statusItem.button.title = self.micArmed ? @"🎙" : @"🔇";
        if (!self.toastTimer) {
            [self hideOSD];
        }
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
    } else if (!self.micArmed) {
        statusLine = @"Mic Paused (Click 'Continuous Mic Armed' to resume)";
    } else {
        HotkeyOption hk = kHotkeyOptions[self.hotkeyIndex];
        NSString *capState = _audioQueueRunning ? @"Ring Live" : @"Mic Idle";
        statusLine = [NSString stringWithFormat:@"Ready (%@) · %@ · %@", capState, hk.label, self.selectedModelPath.lastPathComponent];
    }
    NSMenuItem *statusItem = [[NSMenuItem alloc] initWithTitle:statusLine action:(!AXIsProcessTrusted() ? @selector(openAccessibilityPrefs:) : nil) keyEquivalent:@""];
    statusItem.target = self;
    [menu addItem:statusItem];

    if (self.lastTranscript.length > 0) {
        NSString *preview = self.lastTranscript.length > 40
            ? [[self.lastTranscript substringToIndex:40] stringByAppendingString:@"…"]
            : self.lastTranscript;
        NSString *tag = self.lastOutputStatus.length > 0 ? [NSString stringWithFormat:@" · %@", self.lastOutputStatus] : @"";
        NSString *lastLine = [NSString stringWithFormat:@"Last (%.2fs%@): \"%@\"", self.lastLatencySec, tag, preview];
        NSMenuItem *lastItem = [[NSMenuItem alloc] initWithTitle:lastLine action:@selector(copyLastTranscript:) keyEquivalent:@""];
        lastItem.target = self;
        [menu addItem:lastItem];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    // Continuous Mic Arm/Pause Toggle
    NSMenuItem *armToggle = [[NSMenuItem alloc] initWithTitle:@"Continuous Mic Armed (Pre-Roll Ring)" action:@selector(toggleMicArmed:) keyEquivalent:@""];
    armToggle.target = self;
    armToggle.state = self.micArmed ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:armToggle];

    // Output Mode submenu
    NSMenuItem *outParent = [[NSMenuItem alloc] initWithTitle:@"Output Mode" action:nil keyEquivalent:@""];
    NSMenu *outMenu = [NSMenu new];
    NSArray *outTitles = @[
        @"Smart Auto (Paste if text focused, else Copy)",
        @"Always Paste (Preserve Clipboard)",
        @"Clipboard Only (Copy + Toast)"
    ];
    for (NSInteger i = 0; i < (NSInteger)outTitles.count; i++) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:outTitles[i] action:@selector(selectOutputMode:) keyEquivalent:@""];
        it.target = self;
        it.tag = i;
        it.state = (self.outputMode == i) ? NSControlStateValueOn : NSControlStateValueOff;
        [outMenu addItem:it];
    }
    outParent.submenu = outMenu;
    [menu addItem:outParent];

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

    // Noise Gate / Adaptive Floor submenu
    float amb = 0.0f;
    float effGate = 0.0f;
    [self.audioLock lock];
    amb = _ambientNoiseFloor;
    effGate = [self effectiveGateThresholdLocked];
    [self.audioLock unlock];

    NSString *gateParentTitle = (self.gatePresetIndex == 0)
        ? [NSString stringWithFormat:@"Noise Gate (Auto · floor %.3f → %.3f)", amb, effGate]
        : [NSString stringWithFormat:@"Noise Gate (%@)", kGatePresets[self.gatePresetIndex].label];
    NSMenuItem *gateParent = [[NSMenuItem alloc] initWithTitle:gateParentTitle action:nil keyEquivalent:@""];
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

    // Refinement & Decision Router controls
    NSString *llmModel = self.pipelineConfig[@"llm"][@"model"] ?: @"LLM";
    NSString *llmTitle = [NSString stringWithFormat:@"LLM Refinement (%@)", llmModel];
    NSMenuItem *llmToggle = [[NSMenuItem alloc] initWithTitle:llmTitle action:@selector(toggleLLMRefinement:) keyEquivalent:@""];
    llmToggle.target = self;
    llmToggle.state = [self isLLMRefinementEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:llmToggle];

    NSString *drModel = self.pipelineConfig[@"decision_router"][@"model"] ?: @"DR";
    NSString *drTitle = [NSString stringWithFormat:@"Decision Router (%@)", drModel];
    NSMenuItem *drToggle = [[NSMenuItem alloc] initWithTitle:drTitle action:@selector(toggleDecisionRouter:) keyEquivalent:@""];
    drToggle.target = self;
    drToggle.state = [self isDecisionRouterEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:drToggle];

    NSMenuItem *configItem = [[NSMenuItem alloc] initWithTitle:@"Edit LLM & DR Config (config.json)…" action:@selector(openConfigFile:) keyEquivalent:@""];
    configItem.target = self;
    [menu addItem:configItem];

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
        [self copyTextToClipboard:self.lastTranscript];
        [self showToastWithHeader:@"Copied Last Transcript ✓" caption:self.lastTranscript dotColor:[NSColor systemGreenColor] duration:1.4];
    }
}

- (void)toggleMicArmed:(id)sender {
    self.micArmed = !self.micArmed;
    [[NSUserDefaults standardUserDefaults] setBool:self.micArmed forKey:kPrefMicArmedKey];
    if (self.micArmed) {
        [self startContinuousAudioCapture];
    } else {
        if (self.state == AppStateHolding || self.state == AppStateLocked) {
            [self cancelRecording];
        }
        [self stopContinuousAudioCapture];
    }
    [self updateUI];
}

- (void)selectOutputMode:(NSMenuItem *)sender {
    self.outputMode = (OutputMode)sender.tag;
    [[NSUserDefaults standardUserDefaults] setInteger:self.outputMode forKey:kPrefOutputModeKey];
    [self updateUI];
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
    if (self.micArmed) {
        [self startContinuousAudioCapture];
    }
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

- (void)toggleLLMRefinement:(id)sender {
    NSMutableDictionary *cfg = [[self loadPipelineConfig] mutableCopy];
    NSMutableDictionary *llm = [([cfg[@"llm"] isKindOfClass:[NSDictionary class]] ? cfg[@"llm"] : [self defaultPipelineConfig][@"llm"]) mutableCopy];
    BOOL nextVal = ![llm[@"enabled"] boolValue];
    llm[@"enabled"] = @(nextVal);
    cfg[@"llm"] = llm;
    [self savePipelineConfig:cfg];
    [self updateUI];
}

- (void)toggleDecisionRouter:(id)sender {
    NSMutableDictionary *cfg = [[self loadPipelineConfig] mutableCopy];
    NSMutableDictionary *dr = [([cfg[@"decision_router"] isKindOfClass:[NSDictionary class]] ? cfg[@"decision_router"] : [self defaultPipelineConfig][@"decision_router"]) mutableCopy];
    BOOL nextVal = ![dr[@"enabled"] boolValue];
    dr[@"enabled"] = @(nextVal);
    cfg[@"decision_router"] = dr;
    [self savePipelineConfig:cfg];
    [self updateUI];
}

- (void)openFileInEditor:(NSString *)path {
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    NSURL *textEditURL = [ws URLForApplicationWithBundleIdentifier:@"com.apple.TextEdit"];
    if (textEditURL) {
        NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
        [ws openURLs:@[ fileURL ] withApplicationAtURL:textEditURL configuration:cfg completionHandler:nil];
        return;
    }
    [ws openURL:fileURL];
}

- (void)openConfigFile:(id)sender {
    [self openFileInEditor:[self configFilePath]];
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
    [self openFileInEditor:[self promptFilePath]];
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

#pragma mark - Continuous CoreAudio Ring Buffer

- (float)effectiveGateThresholdLocked {
    if (self.gatePresetIndex <= 0 || kGatePresets[self.gatePresetIndex].threshold <= 0.0f) {
        NSDictionary *cfg = self.pipelineConfig;
        float mult = cfg[@"adaptive_gate_multiplier"] ? [cfg[@"adaptive_gate_multiplier"] floatValue] : 2.6f;
        float minG = cfg[@"adaptive_gate_min"] ? [cfg[@"adaptive_gate_min"] floatValue] : 0.012f;
        float maxG = cfg[@"adaptive_gate_max"] ? [cfg[@"adaptive_gate_max"] floatValue] : 0.11f;
        float adaptive = _ambientNoiseFloor * mult;
        return MIN(maxG, MAX(minG, adaptive));
    }
    return kGatePresets[self.gatePresetIndex].threshold;
}

- (BOOL)startContinuousAudioCapture {
    [self stopContinuousAudioCapture];

    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = (Float64)kSampleRate;
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
    if (_ringSamples) {
        memset(_ringSamples, 0, (size_t)kRingCapacitySamples * sizeof(int16_t));
    }
    _ringTotalSamples = 0;
    _idleRMSPos = 0;
    _idleRMSCount = 0;
    _isCapturingSession = NO;
    _captureStartSample = 0;
    _capturePeakRMS = 0.0f;
    _audioQueueRunning = YES;
    [self.audioLock unlock];

    UInt32 bufBytes = 1600; // 50ms chunks at 16kHz 16-bit mono
    for (int i = 0; i < 4; i++) {
        AudioQueueAllocateBuffer(_audioQueue, bufBytes, &_audioBuffers[i]);
        memset(_audioBuffers[i]->mAudioData, 0, bufBytes);
        AudioQueueEnqueueBuffer(_audioQueue, _audioBuffers[i], 0, NULL);
    }

    st = AudioQueueStart(_audioQueue, NULL);
    if (st != noErr) {
        NSLog(@"VoicePTT: AudioQueueStart failed: %d", (int)st);
        [self stopContinuousAudioCapture];
        return NO;
    }
    return YES;
}

- (void)stopContinuousAudioCapture {
    [self.audioLock lock];
    _audioQueueRunning = NO;
    _isCapturingSession = NO;
    [self.audioLock unlock];

    if (_audioQueue) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    }
}

- (NSData *)sliceRingPCMFromSample:(uint64_t)startSample toSample:(uint64_t)endSample {
    [self.audioLock lock];
    if (!_ringSamples || _ringTotalSamples == 0) {
        [self.audioLock unlock];
        return nil;
    }

    uint64_t latest = _ringTotalSamples;
    uint64_t earliest = (latest > kRingCapacitySamples) ? (latest - kRingCapacitySamples) : 0;

    uint64_t clampedEnd = MIN(endSample, latest);
    uint64_t clampedStart = MAX(startSample, earliest);
    if (clampedEnd <= clampedStart) {
        [self.audioLock unlock];
        return nil;
    }

    uint64_t numSamples = clampedEnd - clampedStart;
    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)(numSamples * sizeof(int16_t))];
    int16_t *dst = (int16_t *)out.mutableBytes;

    uint64_t readIdx = clampedStart % kRingCapacitySamples;
    uint64_t firstPart = MIN(numSamples, kRingCapacitySamples - readIdx);
    memcpy(dst, _ringSamples + readIdx, (size_t)firstPart * sizeof(int16_t));
    if (firstPart < numSamples) {
        memcpy(dst + firstPart, _ringSamples, (size_t)(numSamples - firstPart) * sizeof(int16_t));
    }
    [self.audioLock unlock];
    return out;
}

#pragma mark - Hotkey State Machine (Timestamp Marking on Continuous Ring)

- (BOOL)ensureContinuousMicReady {
    if (!self.micArmed) {
        [self showToastWithHeader:@"Mic is Paused" caption:@"Enable 'Continuous Mic Armed' in menu bar" dotColor:[NSColor systemYellowColor] duration:1.8];
        return NO;
    }
    if (!_audioQueueRunning) {
        return [self startContinuousAudioCapture];
    }
    return YES;
}

- (void)beginSessionWithState:(AppState)newState {
    if (![self ensureContinuousMicReady]) return;

    NSDictionary *cfg = [self loadPipelineConfig];
    NSInteger preRollMs = cfg[@"pre_roll_ms"] ? [cfg[@"pre_roll_ms"] integerValue] : 300;
    preRollMs = MAX(0, MIN(2000, preRollMs));
    uint64_t preRollSamples = (uint64_t)((preRollMs * kSampleRate) / 1000);

    self.sessionGen++;
    self.liveCaptionText = @"";
    self.lastPreviewSampleCount = 0;

    [self.audioLock lock];
    uint64_t nowSample = _ringTotalSamples;
    uint64_t earliest = (nowSample > kRingCapacitySamples) ? (nowSample - kRingCapacitySamples) : 0;
    _captureStartSample = (nowSample > earliest + preRollSamples) ? (nowSample - preRollSamples) : earliest;
    _capturePeakRMS = 0.0f;
    _isCapturingSession = YES;
    [self.audioLock unlock];

    self.state = newState;
    [self startLivePreviewTimer];
    [self updateUI];
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
        [self.audioLock lock];
        _isCapturingSession = NO;
        [self.audioLock unlock];
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
    [self.audioLock lock];
    _isCapturingSession = NO;
    [self.audioLock unlock];
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

    uint64_t startSample = 0;
    uint64_t endSample = 0;
    float peak = 0.0f;
    float gateThresh = 0.025f;

    [self.audioLock lock];
    if (_isCapturingSession && _ringTotalSamples > _captureStartSample) {
        uint64_t totalCaptured = _ringTotalSamples - _captureStartSample;
        // Require >= 0.5s total and >= 0.25s new samples since last preview
        if (totalCaptured >= (kSampleRate / 2) && (totalCaptured - self.lastPreviewSampleCount >= (kSampleRate / 4))) {
            uint64_t maxPreviewSamples = (uint64_t)kSampleRate * 10ULL;
            endSample = _ringTotalSamples;
            startSample = (totalCaptured > maxPreviewSamples) ? (endSample - maxPreviewSamples) : _captureStartSample;
            self.lastPreviewSampleCount = totalCaptured;
            peak = _capturePeakRMS;
            gateThresh = [self effectiveGateThresholdLocked];
        }
    }
    [self.audioLock unlock];

    if (endSample <= startSample || peak < gateThresh) return;

    NSData *snapshot = [self sliceRingPCMFromSample:startSample toSample:endSample];
    if (!snapshot) return;

    NSData *filtered = [self applyHighPassFilterPCM:snapshot];
    NSData *gated = [self applyNoiseGateAndTrimPCM:filtered threshold:gateThresh];
    if (!gated || gated.length < (kSampleRate * 2 / 3)) return;

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

#pragma mark - Signal Conditioning (High-Pass Filter + Adaptive Noise Gate)

// 1st-order ~80Hz high-pass filter @ 16kHz to strip desk rumble, AC hum, and DC offset
- (NSData *)applyHighPassFilterPCM:(NSData *)pcm {
    const int16_t *src = (const int16_t *)pcm.bytes;
    NSUInteger count = pcm.length / sizeof(int16_t);
    if (count < 2) return pcm;

    NSMutableData *out = [NSMutableData dataWithLength:count * sizeof(int16_t)];
    int16_t *dst = (int16_t *)out.mutableBytes;

    const double alpha = 0.9695;
    double prevX = (double)src[0];
    double prevY = 0.0;
    dst[0] = 0;

    for (NSUInteger i = 1; i < count; i++) {
        double x = (double)src[i];
        double y = alpha * (prevY + x - prevX);
        prevX = x;
        prevY = y;
        if (y > 32767.0) y = 32767.0;
        if (y < -32768.0) y = -32768.0;
        dst[i] = (int16_t)llround(y);
    }
    return out;
}

- (NSData *)applyNoiseGateAndTrimPCM:(NSData *)pcm threshold:(float)thresh {
    const int16_t *src = (const int16_t *)pcm.bytes;
    NSUInteger totalSamples = pcm.length / sizeof(int16_t);
    if (totalSamples < 320) return nil;

    // 20ms windows (320 samples @ 16kHz), with ~240ms hold/pre-roll around speech so syllables never chop
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
            memset(d, 0, win * sizeof(int16_t));
        }
    }

    free(active);
    return out;
}

#pragma mark - Extraction, Transcription, Decision Router & LLM Refinement

- (void)finishRecordingAndTranscribe {
    self.sessionGen++;
    NSUInteger gen = self.sessionGen;
    [self stopLivePreviewTimer];

    NSDictionary *cfg = [self loadPipelineConfig];
    NSInteger postRollMs = cfg[@"post_roll_ms"] ? [cfg[@"post_roll_ms"] integerValue] : 200;
    postRollMs = MAX(0, MIN(1000, postRollMs));

    self.state = AppStateTranscribing;
    [self updateUI];

    NSTimeInterval pipelineStart = CACurrentMediaTime();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(postRollMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (gen != self.sessionGen) return;

        uint64_t startSample = 0;
        uint64_t endSample = 0;
        float peak = 0.0f;
        float gateThresh = 0.025f;

        [self.audioLock lock];
        startSample = _captureStartSample;
        endSample = _ringTotalSamples;
        peak = _capturePeakRMS;
        gateThresh = [self effectiveGateThresholdLocked];
        _isCapturingSession = NO;
        [self.audioLock unlock];

        NSData *pcm = [self sliceRingPCMFromSample:startSample toSample:endSample];
        if (!pcm || pcm.length < (kSampleRate * 2 / 4) || peak < gateThresh) {
            self.liveCaptionText = @"";
            self.state = AppStateIdle;
            [self updateUI];
            return;
        }

        NSData *filteredPCM = [self applyHighPassFilterPCM:pcm];
        NSData *gatedPCM = [self applyNoiseGateAndTrimPCM:filteredPCM threshold:gateThresh];
        if (!gatedPCM || gatedPCM.length < (kSampleRate * 2 / 5)) {
            self.liveCaptionText = @"";
            self.state = AppStateIdle;
            [self updateUI];
            return;
        }

        double audioDurationSec = (double)gatedPCM.length / ((double)kSampleRate * 2.0);

        [self sendPCMToWhisper:gatedPCM isPreview:NO completion:^(NSString *cleaned, double asrElapsed) {
            if (gen != self.sessionGen) return;
            if (cleaned.length == 0) {
                self.state = AppStateIdle;
                self.liveCaptionText = @"";
                [self updateUI];
                return;
            }

            // Snapshot focus context now (right before DR / LLM / Output)
            NSString *activeApp = @"";
            BOOL focusedEditable = IsFocusedElementEditableText(&activeApp);

            [self runDecisionRouterAndRefinement:cleaned
                                       activeApp:activeApp
                                 focusedEditable:focusedEditable
                                   audioDuration:audioDurationSec
                                      completion:^(NSString *finalText, NSString *routeOverride) {
                if (gen != self.sessionGen) return;

                double totalElapsed = CACurrentMediaTime() - pipelineStart;
                self.state = AppStateIdle;
                self.liveCaptionText = @"";

                if (finalText.length > 0 && ![routeOverride isEqualToString:@"discard"]) {
                    self.lastTranscript = finalText;
                    self.lastLatencySec = totalElapsed;
                    [self deliverFinalText:finalText focusedEditable:focusedEditable routeOverride:routeOverride];
                } else if ([routeOverride isEqualToString:@"discard"]) {
                    self.lastOutputStatus = @"Discarded (DR)";
                    [self showToastWithHeader:@"Discarded by Decision Router" caption:nil dotColor:[NSColor systemGrayColor] duration:1.2];
                }
                [self updateUI];
            }];
        }];
    });
}

// Stage 3A: Decision Router (Intern-Decision HTTP interface) -> Stage 3B: OpenAI-Compat LLM Refiner
- (void)runDecisionRouterAndRefinement:(NSString *)rawText
                             activeApp:(NSString *)activeApp
                       focusedEditable:(BOOL)focusedEditable
                         audioDuration:(double)audioDuration
                            completion:(void (^)(NSString *finalText, NSString *routeOverride))completion {
    NSDictionary *cfg = self.pipelineConfig ?: [self defaultPipelineConfig];
    NSDictionary *drCfg = [cfg[@"decision_router"] isKindOfClass:[NSDictionary class]] ? cfg[@"decision_router"] : nil;
    NSDictionary *llmCfg = [cfg[@"llm"] isKindOfClass:[NSDictionary class]] ? cfg[@"llm"] : nil;

    void (^proceedToLLM)(BOOL, NSString *, NSString *) = ^(BOOL shouldRefine, NSString *styleHint, NSString *routeOverride) {
        if ([routeOverride isEqualToString:@"discard"]) {
            completion(rawText, @"discard");
            return;
        }
        if (!shouldRefine || ![llmCfg[@"enabled"] boolValue]) {
            completion(rawText, routeOverride);
            return;
        }
        [self refineTextWithOpenAICompatLLM:rawText
                                  activeApp:activeApp
                                  styleHint:styleHint
                                     config:llmCfg
                                 completion:^(NSString *refined) {
            completion(refined.length > 0 ? refined : rawText, routeOverride);
        }];
    };

    // Count words for fast local skip gate
    NSArray<NSString *> *words = [rawText componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSInteger wordCount = 0;
    for (NSString *w in words) {
        if (w.length > 0) wordCount++;
    }
    NSInteger minWords = llmCfg[@"min_words_to_refine"] ? [llmCfg[@"min_words_to_refine"] integerValue] : 4;
    BOOL defaultShouldRefine = [llmCfg[@"enabled"] boolValue] && (wordCount >= minWords);

    if (!drCfg || ![drCfg[@"enabled"] boolValue]) {
        proceedToLLM(defaultShouldRefine, @"prose", nil);
        return;
    }

    NSString *endpoint = drCfg[@"endpoint_url"];
    NSURL *url = endpoint.length > 0 ? [NSURL URLWithString:endpoint] : nil;
    if (!url) {
        proceedToLLM(defaultShouldRefine, @"prose", nil);
        return;
    }

    NSDictionary *payload = @{
        @"model": drCfg[@"model"] ?: @"Intern-Decision-2B",
        @"state": @{
            @"transcript": rawText,
            @"active_app": activeApp ?: @"",
            @"focused_editable": @(focusedEditable),
            @"audio_duration_sec": @(audioDuration),
            @"word_count": @(wordCount)
        },
        @"schema": drCfg[@"schema"] ?: @{
            @"needs_refine": @[ @"yes", @"no" ],
            @"output_action": @[ @"paste", @"clipboard", @"discard" ],
            @"style": @[ @"prose", @"code", @"command" ]
        }
    };

    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body) {
        proceedToLLM(defaultShouldRefine, @"prose", nil);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = drCfg[@"timeout_sec"] ? [drCfg[@"timeout_sec"] doubleValue] : 2.5;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = body;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        BOOL shouldRefine = defaultShouldRefine;
        NSString *styleHint = @"prose";
        NSString *routeOverride = nil;

        if (!err && data) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *decisions = [obj[@"decisions"] isKindOfClass:[NSDictionary class]] ? obj[@"decisions"] : obj;
                id refineChoice = decisions[@"needs_refine"];
                if ([refineChoice isKindOfClass:[NSString class]]) {
                    shouldRefine = [[(NSString *)refineChoice lowercaseString] isEqualToString:@"yes"];
                } else if ([refineChoice isKindOfClass:[NSNumber class]]) {
                    shouldRefine = [refineChoice boolValue];
                }
                if ([decisions[@"style"] isKindOfClass:[NSString class]]) {
                    styleHint = decisions[@"style"];
                }
                if ([decisions[@"output_action"] isKindOfClass:[NSString class]]) {
                    NSString *act = [(NSString *)decisions[@"output_action"] lowercaseString];
                    if ([act isEqualToString:@"paste"] || [act isEqualToString:@"clipboard"] || [act isEqualToString:@"discard"]) {
                        routeOverride = act;
                    }
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            proceedToLLM(shouldRefine, styleHint, routeOverride);
        });
    }];
    [task resume];
}

- (void)refineTextWithOpenAICompatLLM:(NSString *)rawText
                            activeApp:(NSString *)activeApp
                            styleHint:(NSString *)styleHint
                               config:(NSDictionary *)llmCfg
                           completion:(void (^)(NSString *refined))completion {
    NSString *baseURL = llmCfg[@"base_url"] ?: @"http://127.0.0.1:11434/v1";
    while ([baseURL hasSuffix:@"/"]) {
        baseURL = [baseURL substringToIndex:baseURL.length - 1];
    }
    NSString *endpoint = [baseURL hasSuffix:@"/chat/completions"]
        ? baseURL
        : [baseURL stringByAppendingString:@"/chat/completions"];

    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) {
        completion(rawText);
        return;
    }

    NSString *sysPrompt = llmCfg[@"system_prompt"];
    if (![sysPrompt isKindOfClass:[NSString class]] || sysPrompt.length == 0) {
        sysPrompt = [self defaultPipelineConfig][@"llm"][@"system_prompt"];
    }

    NSMutableString *userMsg = [NSMutableString string];
    if (activeApp.length > 0 || styleHint.length > 0) {
        [userMsg appendFormat:@"[Context: active_app=%@, style=%@]\n", activeApp.length > 0 ? activeApp : @"unknown", styleHint.length > 0 ? styleHint : @"prose"];
    }
    [userMsg appendString:rawText];

    double temp = llmCfg[@"temperature"] ? [llmCfg[@"temperature"] doubleValue] : 0.0;
    NSString *model = [llmCfg[@"model"] isKindOfClass:[NSString class]] ? llmCfg[@"model"] : @"qwen2.5:3b";

    NSDictionary *payload = @{
        @"model": model,
        @"temperature": @(temp),
        @"messages": @[
            @{ @"role": @"system", @"content": sysPrompt },
            @{ @"role": @"user",   @"content": userMsg }
        ]
    };

    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body) {
        completion(rawText);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = llmCfg[@"timeout_sec"] ? [llmCfg[@"timeout_sec"] doubleValue] : 12.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSString *apiKey = [llmCfg[@"api_key"] isKindOfClass:[NSString class]] ? llmCfg[@"api_key"] : @"";
    if (apiKey.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    }
    req.HTTPBody = body;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *result = nil;
        if (!err && data) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                NSArray *choices = obj[@"choices"];
                if ([choices isKindOfClass:[NSArray class]] && choices.count > 0) {
                    NSDictionary *first = choices.firstObject;
                    NSDictionary *msg = [first isKindOfClass:[NSDictionary class]] ? first[@"message"] : nil;
                    NSString *content = [msg isKindOfClass:[NSDictionary class]] ? msg[@"content"] : nil;
                    if ([content isKindOfClass:[NSString class]]) {
                        result = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        // Strip accidental outer quotes if the raw transcript wasn't quoted
                        if (result.length >= 2 &&
                            (([result hasPrefix:@"\""] && [result hasSuffix:@"\""] && ![rawText hasPrefix:@"\""]) ||
                             ([result hasPrefix:@"'"] && [result hasSuffix:@"'"] && ![rawText hasPrefix:@"'"]))) {
                            result = [[result substringWithRange:NSMakeRange(1, result.length - 2)]
                                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        }
                    }
                }
            }
        } else if (err) {
            NSLog(@"VoicePTT: LLM refinement failed (falling back to raw ASR): %@", err.localizedDescription);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result.length > 0 ? result : rawText);
        });
    }];
    [task resume];
}

- (void)deliverFinalText:(NSString *)text focusedEditable:(BOOL)focusedEditable routeOverride:(NSString *)routeOverride {
    BOOL shouldPaste = NO;
    NSString *statusTag = @"Pasted";

    if ([routeOverride isEqualToString:@"clipboard"]) {
        shouldPaste = NO;
        statusTag = @"Copied (DR)";
    } else if ([routeOverride isEqualToString:@"paste"]) {
        shouldPaste = YES;
        statusTag = @"Pasted (DR)";
    } else if (self.outputMode == OutputModeClipboardOnly) {
        shouldPaste = NO;
        statusTag = @"Copied";
    } else if (self.outputMode == OutputModeAlwaysPaste) {
        shouldPaste = YES;
        statusTag = @"Pasted";
    } else {
        // Smart Auto: paste if editable text focus exists, else copy + OSD toast
        shouldPaste = focusedEditable;
        statusTag = focusedEditable ? @"Pasted" : @"Copied (No Text Focus)";
    }

    self.lastOutputStatus = statusTag;

    if (shouldPaste) {
        NSString *toPaste = self.addTrailingSpace ? [text stringByAppendingString:@" "] : text;
        [self pasteTextPreservingClipboard:toPaste];
    } else {
        [self copyTextToClipboard:text];
        [self showToastWithHeader:@"Copied to Clipboard ✓" caption:text dotColor:[NSColor systemGreenColor] duration:1.8];
    }
}

- (void)sendPCMToWhisper:(NSData *)pcm isPreview:(BOOL)isPreview completion:(void (^)(NSString *cleaned, double elapsed))completion {
    double durationSec = (double)pcm.length / ((double)kSampleRate * 2.0);
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

- (void)copyTextToClipboard:(NSString *)text {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
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
