#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <QuartzCore/QuartzCore.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/ev_keymap.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <signal.h>

typedef NS_ENUM(NSInteger, PTTMode) {
    PTTModeSmart = 0,      // Hold to talk, OR quick double-tap to lock hands-free
    PTTModeHoldOnly = 1,   // Strict hold-to-talk
    PTTModeToggleOnly = 2, // Tap once to start, tap again to stop
    PTTModeDoubleTap = 3   // Double-tap to start, single-tap to send, double-tap while active to clear & start over
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
    CGEventFlags deviceMask;
    CGEventFlags devicePairMask;
    NSString *label;
} HotkeyOption;

// Keep indices 0..4 stable for backward-compatible NSUserDefaults; menu uses kHotkeyMenuOrder
static const HotkeyOption kHotkeyOptions[] = {
    { 61,  YES, kCGEventFlagMaskAlternate, NX_DEVICERALTKEYMASK,   (NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK),     @"Right Option (⌥)" },
    { 54,  YES, kCGEventFlagMaskCommand,   NX_DEVICERCMDKEYMASK,   (NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK),     @"Right Command (⌘)" },
    { 62,  YES, kCGEventFlagMaskControl,   NX_DEVICERCTLKEYMASK,   (NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK),     @"Right Control (⌃)" },
    { 96,  NO,  0,                         0,                      0,                                                 @"F5" },
    { 105, NO,  0,                         0,                      0,                                                 @"F13 (or Foot Pedal)" },
    { 58,  YES, kCGEventFlagMaskAlternate, NX_DEVICELALTKEYMASK,   (NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK),     @"Left Option (⌥)" },
    { 55,  YES, kCGEventFlagMaskCommand,   NX_DEVICELCMDKEYMASK,   (NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK),     @"Left Command (⌘)" },
    { 59,  YES, kCGEventFlagMaskControl,   NX_DEVICELCTLKEYMASK,   (NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK),     @"Left Control (⌃)" },
    { 60,  YES, kCGEventFlagMaskShift,     NX_DEVICERSHIFTKEYMASK, (NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK), @"Right Shift (⇧)" },
    { 56,  YES, kCGEventFlagMaskShift,     NX_DEVICELSHIFTKEYMASK, (NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK), @"Left Shift (⇧)" }
};
static const NSInteger kHotkeyOptionCount = 10;
static const NSInteger kHotkeyMenuOrder[] = { 0, 5, 1, 6, 2, 7, 8, 9, 3, 4 };

static inline BOOL IsHotkeyModifierDown(HotkeyOption hk, CGEventFlags flags) {
    if ((flags & hk.devicePairMask) != 0) {
        return (flags & hk.deviceMask) != 0;
    }
    return (flags & hk.modifierMask) != 0;
}

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

static NSString * const kPrefModeKey = @"VoicePTTModeV2";
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
static BOOL IsKnownTerminalBundleID(NSString *bundleID) {
    if (bundleID.length == 0) return NO;
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
    return [terminalBundles containsObject:bundleID];
}

// Thread-safe: runs AXUIElement IPC off the main thread so unresponsive apps never stall UI
static BOOL IsFocusedElementEditableTextForBundleID(NSString *bundleID) {
    if (IsKnownTerminalBundleID(bundleID)) {
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
@interface VoicePTTApp : NSObject <NSApplicationDelegate, NSMenuDelegate> {
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
    uint64_t _committedSample;
    uint64_t _captureLastSpeechSample;
    float _capturePeakRMS;

    CFMachPortRef _eventTap;
    CFRunLoopSourceRef _eventTapSource;
    CFRunLoopRef _eventTapRunLoop;

    // Lock-free atomic state mirrored for the dedicated high-priority CGEventTap thread
    _Atomic BOOL _tapCaptureMediaButton;
    _Atomic NSInteger _tapHotkeyIndex;
    _Atomic NSInteger _tapAppState;
    _Atomic BOOL _tapTriggerKeyIsDown;
    _Atomic BOOL _tapOtherKeyPressedDuringHold;
    _Atomic BOOL _tapInterveningKeyPressed;
    _Atomic BOOL _tapShuttingDown;
    _Atomic int _tapTimeoutBurstCount;
    _Atomic double _tapTimeoutWindowStart;

    // Atomic mirrors for non-blocking AudioControlQueue coordination
    _Atomic BOOL _micArmedAtomic;
    _Atomic BOOL _audioQueueRunningAtomic;
    _Atomic uint64_t _audioRestartGen;
}
- (void)handleTriggerDown;
- (void)handleTriggerUp;
- (void)handleMediaButtonToggle;
- (void)cancelRecording;
- (float)effectiveGateThresholdLocked;
- (void)scheduleAudioCaptureRestart:(NSTimeInterval)delay;
- (void)reenableEventTapIfAlive;

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSPanel *osdPanel;
@property (nonatomic, strong) LiveOSDView *osdView;
@property (nonatomic, strong) NSTask *serverTask;
@property (nonatomic, strong) NSLock *audioLock;
@property (nonatomic, strong) NSLock *tapLifecycleLock;
@property (nonatomic, strong) NSThread *eventTapThread;
@property (nonatomic, strong) dispatch_queue_t audioControlQueue;
@property (nonatomic, strong) NSLock *audioCacheLock;
@property (nonatomic, copy) NSArray<AudioInputDeviceInfo *> *cachedInputDevices;
@property (nonatomic, assign) float cachedInputGain;
@property (nonatomic, assign) BOOL needsAudioRestartWhenIdle;
@property (nonatomic, assign) NSInteger audioRestartRetryCount;
@property (nonatomic, assign) NSTimeInterval lastMediaButtonToggleTime;
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
@property (nonatomic, assign) NSTimeInterval holdStartTime;
@property (nonatomic, assign) NSTimeInterval lastShortTapReleaseTime;
@property (nonatomic, assign) NSTimeInterval tapDownTime;
@property (nonatomic, assign) NSTimeInterval lastIdleSoloTapUpTime;
@property (nonatomic, assign) BOOL awaitingSecondTapWhileIdle;
@property (nonatomic, strong) NSTimer *pendingStopTimer;
@property (nonatomic, assign) NSTimeInterval pendingStopReleaseTime;
@property (nonatomic, assign) BOOL awaitingResetSecondTapUp;
@property (nonatomic, assign) NSTimeInterval osdResetFlashUntil;
@property (nonatomic, copy) NSString *committedText;
@property (nonatomic, copy) NSString *liveTailText;
@property (nonatomic, copy) NSString *liveCaptionText;
@property (nonatomic, copy) NSString *lastTranscript;
@property (nonatomic, copy) NSString *lastOutputStatus;
@property (nonatomic, assign) double lastLatencySec;
@property (nonatomic, strong) NSTimer *permPollTimer;
@property (nonatomic, strong) NSTimer *healthTimer;
@property (nonatomic, strong) NSTimer *streamTimer;
@property (nonatomic, strong) NSTimer *postRollTimer;
@property (nonatomic, strong) NSTimer *toastTimer;
@property (nonatomic, assign) BOOL streamPassInFlight;
@property (nonatomic, assign) uint64_t lastStreamPassEndSample;
@property (nonatomic, assign) BOOL finalizePending;
@property (nonatomic, assign) uint64_t finalizeEndSample;
@property (nonatomic, assign) NSTimeInterval finalizePipelineStart;
@property (nonatomic, assign) NSTimeInterval finalizePostRollEnd;
@property (nonatomic, assign) NSUInteger sessionGen;
@property (nonatomic, assign) BOOL serverReady;
@property (nonatomic, copy) NSString *baseDir;
@property (nonatomic, copy) NSDictionary *pipelineConfig;
@property (nonatomic, copy) AudioObjectPropertyListenerBlock hwListenerBlock;
#ifdef VOICEPTT_TEST
@property (nonatomic, strong) NSURLSession *testURLSession;
@property (nonatomic, copy) NSString *testConfigDirOverride;
@property (nonatomic, copy) BOOL (^testRestartAudioHook)(void);
@property (nonatomic, copy) void (^testDeliverTextHook)(NSString *text, BOOL shouldPaste, NSString *statusTag);
@property (nonatomic, copy) OSStatus (^testEnqueueBufferHook)(AudioQueueRef inAQ, AudioQueueBufferRef inBuffer);
@property (nonatomic, copy) NSString *testFrontAppNameOverride;
@property (nonatomic, copy) NSString *testFrontAppBundleIDOverride;
@property (nonatomic, assign) NSTimeInterval testRetryDelayOverride;
@property (nonatomic, assign) NSTimeInterval testPendingStopDelayOverride;
#endif
@end

static void AudioQueueRunningListener(void *inUserData,
                                      AudioQueueRef inAQ,
                                      AudioQueuePropertyID inID) {
    if (inID != kAudioQueueProperty_IsRunning) return;
    VoicePTTApp *app = (__bridge VoicePTTApp *)inUserData;
    if (!app || atomic_load(&app->_tapShuttingDown)) return;

    UInt32 isRunning = 0;
    UInt32 size = sizeof(isRunning);
    OSStatus st = AudioQueueGetProperty(inAQ, kAudioQueueProperty_IsRunning, &isRunning, &size);
    if (st == noErr && isRunning == 0) {
        BOOL unexpectedStop = NO;
        [app.audioLock lock];
        if (app->_audioQueue == inAQ && app->_audioQueueRunning) {
            app->_audioQueueRunning = NO;
            atomic_store(&app->_audioQueueRunningAtomic, NO);
            unexpectedStop = YES;
        }
        [app.audioLock unlock];
        if (unexpectedStop && atomic_load(&app->_micArmedAtomic)) {
            NSLog(@"VoicePTT: AudioQueue stopped unexpectedly (audio device removed?), scheduling recovery");
            [app scheduleAudioCaptureRestart:0.8];
        }
    }
}

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
    if (app->_audioQueueRunning && app->_audioQueue == inAQ && app->_ringSamples && bytes >= sizeof(int16_t)) {
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

        gateThresh = [app effectiveGateThresholdLocked];

        if (app->_isCapturingSession) {
            isCapturing = YES;
            if (rms > app->_capturePeakRMS) {
                app->_capturePeakRMS = rms;
            }
            if (rms >= gateThresh) {
                app->_captureLastSpeechSample = app->_ringTotalSamples;
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

        shouldReenqueue = YES;
    }
    [app.audioLock unlock];

    if (shouldReenqueue) {
        OSStatus enqStatus = noErr;
#ifdef VOICEPTT_TEST
        if (app.testEnqueueBufferHook) {
            enqStatus = app.testEnqueueBufferHook(inAQ, inBuffer);
        } else {
            enqStatus = AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
        }
#else
        enqStatus = AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
#endif
        if (enqStatus != noErr) {
            BOOL shouldRecover = NO;
            [app.audioLock lock];
            if (app->_audioQueue == inAQ && app->_audioQueueRunning) {
                app->_audioQueueRunning = NO;
                atomic_store(&app->_audioQueueRunningAtomic, NO);
                shouldRecover = YES;
            }
            [app.audioLock unlock];
            if (shouldRecover && atomic_load(&app->_micArmedAtomic)) {
                NSLog(@"VoicePTT: AudioQueueEnqueueBuffer failed (%d), scheduling recovery", (int)enqStatus);
                [app scheduleAudioCaptureRestart:0.8];
            }
            return;
        }

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
    @autoreleasepool {
        VoicePTTApp *app = (__bridge VoicePTTApp *)userInfo;
        if (!app) return event;

        if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
            atomic_store(&app->_tapTriggerKeyIsDown, NO);
            atomic_store(&app->_tapOtherKeyPressedDuringHold, NO);
            atomic_store(&app->_tapInterveningKeyPressed, NO);
            if (atomic_load(&app->_tapShuttingDown)) {
                return event;
            }
            if (type == kCGEventTapDisabledByTimeout) {
                double now = CACurrentMediaTime();
                double winStart = atomic_load(&app->_tapTimeoutWindowStart);
                int burst = 1;
                if (now - winStart > 10.0) {
                    atomic_store(&app->_tapTimeoutWindowStart, now);
                    atomic_store(&app->_tapTimeoutBurstCount, 1);
                } else {
                    burst = atomic_fetch_add(&app->_tapTimeoutBurstCount, 1) + 1;
                }
                NSLog(@"VoicePTT: CGEventTap disabled by timeout (burst=%d)", burst);
                if (burst >= 4) {
                    // Circuit breaker: back off instead of looping and stalling WindowServer
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [app reenableEventTapIfAlive];
                    });
                    return event;
                }
            }
            if (app->_eventTap) {
                CGEventTapEnable(app->_eventTap, true);
            }
            return event;
        }

        // Handle NX_SYSDEFINED early and always return — never inspect keyboard fields on system events
        if (type == NX_SYSDEFINED) {
            if (!atomic_load(&app->_tapCaptureMediaButton)) {
                return event;
            }
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

        // Esc aborts active recording or pending finalization without pasting/copying
        if (type == kCGEventKeyDown && keyCode == 53) {
            AppState curState = (AppState)atomic_load(&app->_tapAppState);
            if (curState == AppStateHolding || curState == AppStateLocked || curState == AppStateTranscribing) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [app cancelRecording];
                });
                return NULL;
            }
            return event;
        }

        NSInteger hkIdx = atomic_load(&app->_tapHotkeyIndex);
        if (hkIdx < 0 || hkIdx >= kHotkeyOptionCount) hkIdx = 0;
        HotkeyOption hk = kHotkeyOptions[hkIdx];

        if (hk.isModifier) {
            if (type == kCGEventFlagsChanged && keyCode == hk.keyCode) {
                BOOL isNowDown = IsHotkeyModifierDown(hk, flags);
                BOOL wasDown = atomic_load(&app->_tapTriggerKeyIsDown);
                if (isNowDown && !wasDown) {
                    atomic_store(&app->_tapTriggerKeyIsDown, YES);
                    atomic_store(&app->_tapOtherKeyPressedDuringHold, NO);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [app handleTriggerDown];
                    });
                } else if (!isNowDown && wasDown) {
                    atomic_store(&app->_tapTriggerKeyIsDown, NO);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [app handleTriggerUp];
                    });
                }
            } else if (type == kCGEventKeyDown) {
                atomic_store(&app->_tapInterveningKeyPressed, YES);
                if (atomic_load(&app->_tapTriggerKeyIsDown)) {
                    atomic_store(&app->_tapOtherKeyPressedDuringHold, YES);
                }
            }
        } else {
            if (keyCode == hk.keyCode) {
                if (type == kCGEventKeyDown) {
                    int64_t isRepeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat);
                    if (isRepeat == 0 && !atomic_load(&app->_tapTriggerKeyIsDown)) {
                        atomic_store(&app->_tapTriggerKeyIsDown, YES);
                        atomic_store(&app->_tapOtherKeyPressedDuringHold, NO);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [app handleTriggerDown];
                        });
                    }
                    return NULL;
                } else if (type == kCGEventKeyUp) {
                    if (atomic_load(&app->_tapTriggerKeyIsDown)) {
                        atomic_store(&app->_tapTriggerKeyIsDown, NO);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [app handleTriggerUp];
                        });
                    }
                    return NULL;
                }
            } else if (type == kCGEventKeyDown) {
                atomic_store(&app->_tapInterveningKeyPressed, YES);
                if (atomic_load(&app->_tapTriggerKeyIsDown)) {
                    atomic_store(&app->_tapOtherKeyPressedDuringHold, YES);
                }
            }
        }

        return event;
    }
}

@implementation VoicePTTApp

- (void)setState:(AppState)state {
    _state = state;
    atomic_store(&_tapAppState, (NSInteger)state);
    if (state == AppStateIdle && self.needsAudioRestartWhenIdle && self.micArmed) {
        self.needsAudioRestartWhenIdle = NO;
        [self scheduleAudioCaptureRestart:0.25];
    }
}

- (void)setHotkeyIndex:(NSInteger)hotkeyIndex {
    _hotkeyIndex = hotkeyIndex;
    atomic_store(&_tapHotkeyIndex, hotkeyIndex);
}

- (void)setCaptureMediaButton:(BOOL)captureMediaButton {
    _captureMediaButton = captureMediaButton;
    atomic_store(&_tapCaptureMediaButton, captureMediaButton);
}

- (void)setMicArmed:(BOOL)micArmed {
    _micArmed = micArmed;
    atomic_store(&_micArmedAtomic, micArmed);
}

- (void)setSelectedMicUID:(NSString *)selectedMicUID {
    NSString *copied = [selectedMicUID copy] ?: @"";
    [self.audioCacheLock lock];
    _selectedMicUID = copied;
    [self.audioCacheLock unlock];
}

- (NSString *)selectedMicUIDSnapshot {
    [self.audioCacheLock lock];
    NSString *uid = _selectedMicUID ?: @"";
    [self.audioCacheLock unlock];
    return uid;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.audioLock = [NSLock new];
    self.tapLifecycleLock = [NSLock new];
    self.audioCacheLock = [NSLock new];
    dispatch_queue_attr_t audioAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    self.audioControlQueue = dispatch_queue_create("local.voiceptt.audio.control", audioAttr);
    self.cachedInputDevices = @[];
    self.cachedInputGain = -1.0f;

    atomic_store(&_tapShuttingDown, NO);
    atomic_store(&_tapTriggerKeyIsDown, NO);
    atomic_store(&_tapOtherKeyPressedDuringHold, NO);
    atomic_store(&_tapInterveningKeyPressed, NO);
    atomic_store(&_tapTimeoutBurstCount, 0);
    atomic_store(&_tapTimeoutWindowStart, 0.0);
    atomic_store(&_audioQueueRunningAtomic, NO);
    atomic_store(&_audioRestartGen, 0);

    _ringSamples = (int16_t *)calloc((size_t)kRingCapacitySamples, sizeof(int16_t));
    _ambientNoiseFloor = 0.008f;
    self.state = AppStateStarting;
    self.serverReady = NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundleParent = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
    NSString *bundleResources = [[NSBundle mainBundle] resourcePath] ?: @"";
    NSString *appSupport = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/VoicePTT"];
    NSString *configDir = [NSHomeDirectory() stringByAppendingPathComponent:@".config/voice-ptt"];

    NSArray<NSString *> *searchBases = @[ bundleParent, bundleResources, appSupport, configDir ];
    self.baseDir = bundleParent;
    for (NSString *cand in searchBases) {
        if (cand.length > 0 && [fm fileExistsAtPath:[cand stringByAppendingPathComponent:@"models"]]) {
            self.baseDir = cand;
            break;
        }
    }

    [self loadPreferences];
    [self loadPipelineConfig];
    [self setupStatusItem];
    [self setupFloatingOSD];
    [self setupAudioLifecycleObservers];
    [self refreshAudioDeviceCacheAsync];
    [self requestMicrophonePermissionAndArm];
    [self startWhisperServer];
    [self setupEventTapWithPrompt:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    atomic_store(&_tapShuttingDown, YES);
    atomic_fetch_add(&_audioRestartGen, 1);

    [self stopStreamTimer];
    [self.pendingStopTimer invalidate];
    [self.postRollTimer invalidate];
    [self.toastTimer invalidate];
    [self.permPollTimer invalidate];
    [self.healthTimer invalidate];

    // Disable and stop the dedicated event tap thread immediately
    [self.tapLifecycleLock lock];
    if (_eventTap) {
        CGEventTapEnable(_eventTap, false);
        CFMachPortInvalidate(_eventTap);
    }
    if (_eventTapRunLoop) {
        CFRunLoopStop(_eventTapRunLoop);
    }
    [self.tapLifecycleLock unlock];

    [self teardownAudioLifecycleObservers];

    if (self.serverTask && self.serverTask.isRunning) {
        [self.serverTask terminate];
    }

    // Bounded teardown so quitting never hangs even if coreaudiod is stalled
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(self.audioControlQueue, ^{
        [self stopAudioCaptureOnAudioQueue];
        dispatch_semaphore_signal(done);
    });
    BOOL stoppedCleanly = (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC))) == 0);

    if (stoppedCleanly) {
        [self.audioLock lock];
        if (_ringSamples) {
            free(_ringSamples);
            _ringSamples = NULL;
        }
        [self.audioLock unlock];
    }
}

#pragma mark - Preferences & Pipeline Config

- (void)loadPreferences {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    self.mode = [d objectForKey:kPrefModeKey] ? [d integerForKey:kPrefModeKey] : PTTModeDoubleTap;
    if (self.mode < PTTModeSmart || self.mode > PTTModeDoubleTap) self.mode = PTTModeDoubleTap;
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
        NSArray<NSString *> *preferred = @[
            @"models/ggml-large-v3-turbo-q5_0.bin",
            @"models/ggml-medium.en-q5_0.bin",
            @"models/ggml-small.en-q5_1.bin"
        ];
        NSString *picked = nil;
        for (NSString *rel in preferred) {
            NSString *full = [self.baseDir stringByAppendingPathComponent:rel];
            if ([[NSFileManager defaultManager] fileExistsAtPath:full]) {
                picked = full;
                break;
            }
        }
        if (picked) {
            self.selectedModelPath = picked;
        } else {
            NSArray<NSString *> *models = [self availableModels];
            self.selectedModelPath = models.firstObject ?: [self.baseDir stringByAppendingPathComponent:@"models/ggml-small.en-q5_1.bin"];
        }
    }
}

- (NSURLSession *)activeURLSession {
#ifdef VOICEPTT_TEST
    if (self.testURLSession) return self.testURLSession;
#endif
    return [NSURLSession sharedSession];
}

- (NSString *)configDirPath {
#ifdef VOICEPTT_TEST
    if (self.testConfigDirOverride.length > 0) {
        [[NSFileManager defaultManager] createDirectoryAtPath:self.testConfigDirOverride withIntermediateDirectories:YES attributes:nil error:nil];
        return self.testConfigDirOverride;
    }
#endif
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
        @"post_roll_min_ms": @350,
        @"post_roll_silence_ms": @450,
        @"post_roll_max_ms": @1800,
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

- (NSString *)promptFilePath {
    NSString *path = [[self configDirPath] stringByAppendingPathComponent:@"prompt.txt"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    return path;
}

- (NSString *)latencyLogPath {
    return [[self configDirPath] stringByAppendingPathComponent:@"latency.log"];
}

- (void)appendLatencyLog:(NSString *)line {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"HH:mm:ss";
    });
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];
    fprintf(stderr, "%s", entry.UTF8String);
    fflush(stderr);

    NSString *path = [self latencyLogPath];
    NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        }
    }
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
                [self scheduleAudioCaptureRestart:0.0];
            }
        } else if (status == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                if (granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (self.micArmed) {
                            [self scheduleAudioCaptureRestart:0.0];
                            [self updateUI];
                        }
                    });
                }
            }];
        }
    } else {
        if (self.micArmed) {
            [self scheduleAudioCaptureRestart:0.0];
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
        if (!strongSelf || atomic_load(&strongSelf->_tapShuttingDown)) return;
        // Runs on audioControlQueue — never blocks the main thread or CGEventTap!
        [strongSelf refreshCachedAudioDevicesOnAudioQueue];
        if (atomic_load(&strongSelf->_micArmedAtomic)) {
            [strongSelf scheduleAudioCaptureRestart:0.8];
        }
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
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &devAddr, self.audioControlQueue, self.hwListenerBlock);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &defAddr, self.audioControlQueue, self.hwListenerBlock);
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
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &devAddr, self.audioControlQueue, self.hwListenerBlock);
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &defAddr, self.audioControlQueue, self.hwListenerBlock);
        self.hwListenerBlock = nil;
    }
}

- (void)handleSystemWake:(NSNotification *)note {
    [self scheduleAudioCaptureRestart:1.0];
}

// Thread-safe, debounced, coalesced restart completely off the main thread
- (void)scheduleAudioCaptureRestart:(NSTimeInterval)delay {
    if (!atomic_load(&_micArmedAtomic) || atomic_load(&_tapShuttingDown)) return;
    uint64_t gen = atomic_fetch_add(&_audioRestartGen, 1) + 1;
    int64_t delayNs = (int64_t)(MAX(0.0, delay) * (double)NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayNs), self.audioControlQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || atomic_load(&strongSelf->_tapShuttingDown)) return;
        if (atomic_load(&strongSelf->_audioRestartGen) != gen) return;
        if (!atomic_load(&strongSelf->_micArmedAtomic)) return;

        AppState st = (AppState)atomic_load(&strongSelf->_tapAppState);
        if (st == AppStateIdle || st == AppStateStarting) {
            BOOL ok = [strongSelf restartAudioCaptureOnAudioQueue];
            if (ok) {
                strongSelf.audioRestartRetryCount = 0;
            } else if (strongSelf.audioRestartRetryCount < 3) {
                strongSelf.audioRestartRetryCount++;
                NSTimeInterval retryDelay = 1.5;
#ifdef VOICEPTT_TEST
                if (strongSelf.testRetryDelayOverride > 0.0) {
                    retryDelay = strongSelf.testRetryDelayOverride;
                }
#endif
                [strongSelf scheduleAudioCaptureRestart:retryDelay];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.needsAudioRestartWhenIdle = NO;
                [strongSelf updateUI];
            });
        } else {
            // Defer restart until active recording/transcription finishes
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.needsAudioRestartWhenIdle = YES;
            });
        }
    });
}

- (void)reenableEventTapIfAlive {
    if (atomic_load(&_tapShuttingDown)) return;
    [self.tapLifecycleLock lock];
    if (_eventTap && CFMachPortIsValid(_eventTap)) {
        atomic_store(&_tapTimeoutBurstCount, 0);
        CGEventTapEnable(_eventTap, true);
    }
    [self.tapLifecycleLock unlock];
}

- (void)eventTapThreadMain {
    @autoreleasepool {
        CFRunLoopRef rl = CFRunLoopGetCurrent();
        CFRetain(rl);

        [self.tapLifecycleLock lock];
        _eventTapRunLoop = rl;
        CFMachPortRef tap = _eventTap;
        CFRunLoopSourceRef src = _eventTapSource;
        [self.tapLifecycleLock unlock];

        if (tap && src && !atomic_load(&_tapShuttingDown)) {
            CFRunLoopAddSource(rl, src, kCFRunLoopCommonModes);
            CGEventTapEnable(tap, true);
            CFRunLoopRun();
            CFRunLoopRemoveSource(rl, src, kCFRunLoopCommonModes);
        }

        [self.tapLifecycleLock lock];
        if (_eventTapRunLoop == rl) {
            _eventTapRunLoop = NULL;
        }
        if (_eventTapSource) {
            CFRelease(_eventTapSource);
            _eventTapSource = NULL;
        }
        if (_eventTap) {
            CGEventTapEnable(_eventTap, false);
            CFMachPortInvalidate(_eventTap);
            CFRelease(_eventTap);
            _eventTap = NULL;
        }
        [self.tapLifecycleLock unlock];
        CFRelease(rl);
    }
}

- (void)setupEventTapWithPrompt:(BOOL)prompt {
    if (self.eventTapThread || _eventTap) return;

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

    // Attach active CGEventTap ONLY to a dedicated UserInteractive background CFRunLoop
    // so main-thread UI, CoreAudio, or AX work can NEVER freeze macOS keyboard/mouse input.
    CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(NX_SYSDEFINED);
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap,
                                         kCGHeadInsertEventTap,
                                         kCGEventTapOptionDefault,
                                         mask,
                                         EventTapCallback,
                                         (__bridge void *)self);
    if (tap) {
        CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
        [self.tapLifecycleLock lock];
        _eventTap = tap;
        _eventTapSource = src;
        [self.tapLifecycleLock unlock];

        NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(eventTapThreadMain) object:nil];
        thread.name = @"VoicePTT.EventTap";
        thread.qualityOfService = NSQualityOfServiceUserInteractive;
        self.eventTapThread = thread;
        [thread start];
    }
    [self updateUI];
}

#pragma mark - Menu Bar & Live Caption Floating OSD

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"⏳";
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    self.statusItem.menu = menu;
    [self populateMenu:menu];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self populateMenu:menu];
    [self refreshAudioDeviceCacheAsync];
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
        BOOL justReset = (CACurrentMediaTime() < self.osdResetFlashUntil);
        NSString *hdr = justReset
            ? @"Cleared — Recording Fresh…  (1× send · Esc abort)"
            : (self.mode == PTTModeDoubleTap
                ? @"Recording  (1× send · 2× clear · Esc abort)"
                : @"Hands-Free  (tap to send · Esc cancel)");
        NSColor *dot = justReset ? [NSColor systemGreenColor] : [NSColor systemOrangeColor];
        [self showOSDWithHeader:hdr caption:self.liveCaptionText dotColor:dot showMeter:YES];
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
}

- (void)rebuildMenu {
    if (self.statusItem.menu) {
        [self populateMenu:self.statusItem.menu];
    }
}

- (void)populateMenu:(NSMenu *)menu {
    [menu removeAllItems];

    NSString *statusLine = nil;
    if (!AXIsProcessTrusted()) {
        statusLine = @"⚠️ Needs Accessibility Permission (Click to open)";
    } else if (!self.serverReady) {
        statusLine = @"Loading Whisper + Silero VAD…";
    } else if (!self.micArmed) {
        statusLine = @"Mic Paused (Click 'Continuous Mic Armed' to resume)";
    } else {
        HotkeyOption hk = kHotkeyOptions[self.hotkeyIndex];
        NSString *capState = atomic_load(&_audioQueueRunningAtomic) ? @"Ring Live" : @"Mic Reconnecting…";
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
    NSArray<NSDictionary *> *modeEntries = @[
        @{ @"tag": @(PTTModeDoubleTap),  @"title": @"Double-Tap (2× Start · 1× Send · 2× Clear)" },
        @{ @"tag": @(PTTModeSmart),      @"title": @"Smart (Hold to talk · Double-tap lock)" },
        @{ @"tag": @(PTTModeHoldOnly),   @"title": @"Hold Only (Push-to-Talk)" },
        @{ @"tag": @(PTTModeToggleOnly), @"title": @"Tap-to-Toggle (No holding)" }
    ];
    for (NSDictionary *entry in modeEntries) {
        NSInteger tag = [entry[@"tag"] integerValue];
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:entry[@"title"] action:@selector(selectMode:) keyEquivalent:@""];
        it.target = self;
        it.tag = tag;
        it.state = (self.mode == tag) ? NSControlStateValueOn : NSControlStateValueOff;
        [modeMenu addItem:it];
    }
    modeParent.submenu = modeMenu;
    [menu addItem:modeParent];

    // Hotkey submenu (Left & Right modifiers grouped cleanly, followed by Function keys)
    NSMenuItem *hkParent = [[NSMenuItem alloc] initWithTitle:@"Hotkey" action:nil keyEquivalent:@""];
    NSMenu *hkMenu = [NSMenu new];
    for (NSInteger pos = 0; pos < kHotkeyOptionCount; pos++) {
        NSInteger idx = kHotkeyMenuOrder[pos];
        if (!kHotkeyOptions[idx].isModifier && pos > 0 && kHotkeyOptions[kHotkeyMenuOrder[pos - 1]].isModifier) {
            [hkMenu addItem:[NSMenuItem separatorItem]];
        }
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:kHotkeyOptions[idx].label action:@selector(selectHotkey:) keyEquivalent:@""];
        it.target = self;
        it.tag = idx;
        it.state = (self.hotkeyIndex == idx) ? NSControlStateValueOn : NSControlStateValueOff;
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

    // Mic Input Gain & Microphone submenus (read from async CoreAudio cache — zero main-thread HAL IPC)
    NSArray<AudioInputDeviceInfo *> *cachedDevices = nil;
    float curGain = -1.0f;
    NSString *curMicUID = @"";
    [self.audioCacheLock lock];
    cachedDevices = self.cachedInputDevices ?: @[];
    curGain = self.cachedInputGain;
    curMicUID = _selectedMicUID ?: @"";
    [self.audioCacheLock unlock];

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
    defMic.state = (curMicUID.length == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    [micMenu addItem:defMic];
    for (AudioInputDeviceInfo *dev in cachedDevices) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:dev.name action:@selector(selectMic:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = dev.uid;
        it.state = [curMicUID isEqualToString:dev.uid] ? NSControlStateValueOn : NSControlStateValueOff;
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

    NSMenuItem *liveToggle = [[NSMenuItem alloc] initWithTitle:@"Live Incremental Streaming (Single Model)" action:@selector(toggleLiveCaption:) keyEquivalent:@""];
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
        [self scheduleAudioCaptureRestart:0.0];
    } else {
        if (self.state == AppStateHolding || self.state == AppStateLocked) {
            [self cancelRecording];
        }
        [self stopContinuousAudioCaptureAsync];
    }
    [self updateUI];
}

- (void)selectOutputMode:(NSMenuItem *)sender {
    self.outputMode = (OutputMode)sender.tag;
    [[NSUserDefaults standardUserDefaults] setInteger:self.outputMode forKey:kPrefOutputModeKey];
    [self updateUI];
}

- (void)selectMode:(NSMenuItem *)sender {
    [self.pendingStopTimer invalidate];
    self.pendingStopTimer = nil;
    self.awaitingSecondTapWhileIdle = NO;
    self.awaitingResetSecondTapUp = NO;
    self.lastIdleSoloTapUpTime = 0;
    self.mode = (PTTMode)sender.tag;
    [[NSUserDefaults standardUserDefaults] setInteger:self.mode forKey:kPrefModeKey];
    [self updateUI];
}

- (void)selectHotkey:(NSMenuItem *)sender {
    [self.pendingStopTimer invalidate];
    self.pendingStopTimer = nil;
    self.awaitingSecondTapWhileIdle = NO;
    self.awaitingResetSecondTapUp = NO;
    self.lastIdleSoloTapUpTime = 0;
    self.hotkeyIndex = sender.tag;
    atomic_store(&_tapTriggerKeyIsDown, NO);
    atomic_store(&_tapOtherKeyPressedDuringHold, NO);
    atomic_store(&_tapInterveningKeyPressed, NO);
    [[NSUserDefaults standardUserDefaults] setInteger:self.hotkeyIndex forKey:kPrefHotkeyIndexKey];
    [self updateUI];
}

- (void)selectGatePreset:(NSMenuItem *)sender {
    self.gatePresetIndex = sender.tag;
    [[NSUserDefaults standardUserDefaults] setInteger:self.gatePresetIndex forKey:kPrefGatePresetKey];
    [self updateUI];
}

- (void)selectMicGain:(NSMenuItem *)sender {
    float scalar = (float)sender.tag / 100.0f;
    NSString *uid = [self selectedMicUIDSnapshot];
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.audioControlQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        AudioDeviceID devID = ResolveInputDeviceID(uid);
        SetInputDeviceGain(devID, scalar);
        [strongSelf refreshCachedAudioDevicesOnAudioQueue];
    });
}

- (void)selectMic:(NSMenuItem *)sender {
    self.selectedMicUID = sender.representedObject ?: @"";
    [[NSUserDefaults standardUserDefaults] setObject:self.selectedMicUID forKey:kPrefMicUIDKey];
    [self refreshAudioDeviceCacheAsync];
    if (self.micArmed) {
        [self scheduleAudioCaptureRestart:0.0];
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
    NSTask *oldTask = self.serverTask;
    self.serverTask = nil;
    [self.healthTimer invalidate];
    self.healthTimer = nil;

    self.serverReady = NO;
    self.streamPassInFlight = NO;
    self.finalizePending = NO;
    self.state = AppStateStarting;
    [self updateUI];

    if (oldTask && oldTask.isRunning) {
        [oldTask terminate];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSTimeInterval deadline = CACurrentMediaTime() + 2.0;
            while (oldTask.isRunning && CACurrentMediaTime() < deadline) {
                usleep(25000);
            }
            if (oldTask.isRunning) {
                pid_t pid = oldTask.processIdentifier;
                if (pid > 0) kill(pid, SIGKILL);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!atomic_load(&self->_tapShuttingDown)) {
                    [self startWhisperServer];
                }
            });
        });
    } else {
        [self startWhisperServer];
    }
}

- (void)quitApp:(id)sender {
    [NSApp terminate:nil];
}

#pragma mark - Whisper Server Lifecycle (Single Model Incremental Engine)

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

    // Single dedicated model server:
    // - No -nt so verbose_json includes segment timestamps for sliding commits
    // - -nlp skips slow language auto-detection in verbose_json
    // - -mc 64 enables custom prompt.txt + incremental prefix context without looping
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[
        @"-m", self.selectedModelPath,
        @"--host", @"127.0.0.1",
        @"--port", [NSString stringWithFormat:@"%ld", (long)kServerPort],
        @"-t", [NSString stringWithFormat:@"%d", cores32],
        @"-bo", @"1",
        @"-bs", @"1",
        @"-mc", @"64",
        @"-l", @"en",
        @"-nlp",
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

- (void)refreshCachedAudioDevicesOnAudioQueue {
    NSArray<AudioInputDeviceInfo *> *devices = ListAudioInputDevices();
    NSString *preferredUID = [self selectedMicUIDSnapshot];
    AudioDeviceID activeDev = ResolveInputDeviceID(preferredUID);
    float gain = GetInputDeviceGain(activeDev);

    [self.audioCacheLock lock];
    self.cachedInputDevices = devices;
    self.cachedInputGain = gain;
    [self.audioCacheLock unlock];
}

- (void)refreshAudioDeviceCacheAsync {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.audioControlQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || atomic_load(&strongSelf->_tapShuttingDown)) return;
        [strongSelf refreshCachedAudioDevicesOnAudioQueue];
    });
}

// Always runs on self.audioControlQueue — NEVER on the main thread!
- (void)stopAudioCaptureOnAudioQueue {
    AudioQueueRef aqToDispose = NULL;
    [self.audioLock lock];
    _audioQueueRunning = NO;
    atomic_store(&_audioQueueRunningAtomic, NO);
    _isCapturingSession = NO;
    aqToDispose = _audioQueue;
    _audioQueue = NULL;
    for (int i = 0; i < 4; i++) {
        _audioBuffers[i] = NULL;
    }
    [self.audioLock unlock];

    if (aqToDispose) {
        AudioQueueRemovePropertyListener(aqToDispose, kAudioQueueProperty_IsRunning, AudioQueueRunningListener, (__bridge void *)self);
        // AudioQueueDispose(..., true) stops the queue immediately and disposes it in one call
        AudioQueueDispose(aqToDispose, true);
    }
}

- (void)stopContinuousAudioCaptureAsync {
    atomic_fetch_add(&_audioRestartGen, 1); // cancel any pending restart
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.audioControlQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf stopAudioCaptureOnAudioQueue];
    });
}

// Always runs on self.audioControlQueue — NEVER on the main thread!
- (BOOL)restartAudioCaptureOnAudioQueue {
#ifdef VOICEPTT_TEST
    if (self.testRestartAudioHook) {
        return self.testRestartAudioHook();
    }
#endif
    [self stopAudioCaptureOnAudioQueue];

    NSArray<AudioInputDeviceInfo *> *devices = ListAudioInputDevices();
    NSString *preferredUID = [self selectedMicUIDSnapshot];

    // Update menu cache while we already have the device list
    AudioDeviceID activeDev = ResolveInputDeviceID(preferredUID);
    float gain = GetInputDeviceGain(activeDev);
    [self.audioCacheLock lock];
    self.cachedInputDevices = devices;
    self.cachedInputGain = gain;
    [self.audioCacheLock unlock];

    if (devices.count == 0) {
        NSLog(@"VoicePTT: No audio input devices available yet, will retry");
        return NO;
    }

    // Only bind to preferredUID if that device is currently present; otherwise fall back to System Default
    BOOL preferredPresent = NO;
    if (preferredUID.length > 0) {
        for (AudioInputDeviceInfo *d in devices) {
            if ([d.uid isEqualToString:preferredUID]) {
                preferredPresent = YES;
                break;
            }
        }
    }

    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = (Float64)kSampleRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    fmt.mChannelsPerFrame = 1;
    fmt.mBitsPerChannel = 16;
    fmt.mBytesPerFrame = 2;
    fmt.mBytesPerPacket = 2;
    fmt.mFramesPerPacket = 1;

    AudioQueueRef newAQ = NULL;
    OSStatus st = AudioQueueNewInput(&fmt, AudioInputCallback, (__bridge void *)self, NULL, NULL, 0, &newAQ);
    if (st != noErr || !newAQ) {
        NSLog(@"VoicePTT: AudioQueueNewInput failed: %d", (int)st);
        return NO;
    }

    if (preferredPresent) {
        CFStringRef uid = (__bridge CFStringRef)preferredUID;
        OSStatus devSt = AudioQueueSetProperty(newAQ, kAudioQueueProperty_CurrentDevice, &uid, sizeof(CFStringRef));
        if (devSt != noErr) {
            NSLog(@"VoicePTT: Failed to bind preferred mic %@ (%d), falling back to System Default", preferredUID, (int)devSt);
        }
    }

    AudioQueueAddPropertyListener(newAQ, kAudioQueueProperty_IsRunning, AudioQueueRunningListener, (__bridge void *)self);

    UInt32 bufBytes = 1600; // 50ms chunks at 16kHz 16-bit mono
    AudioQueueBufferRef newBuffers[4] = { NULL, NULL, NULL, NULL };
    for (int i = 0; i < 4; i++) {
        OSStatus allocSt = AudioQueueAllocateBuffer(newAQ, bufBytes, &newBuffers[i]);
        if (allocSt != noErr || !newBuffers[i]) {
            NSLog(@"VoicePTT: AudioQueueAllocateBuffer failed: %d", (int)allocSt);
            AudioQueueRemovePropertyListener(newAQ, kAudioQueueProperty_IsRunning, AudioQueueRunningListener, (__bridge void *)self);
            AudioQueueDispose(newAQ, true);
            return NO;
        }
        memset(newBuffers[i]->mAudioData, 0, bufBytes);
        OSStatus enqSt = AudioQueueEnqueueBuffer(newAQ, newBuffers[i], 0, NULL);
        if (enqSt != noErr) {
            NSLog(@"VoicePTT: Initial AudioQueueEnqueueBuffer failed: %d", (int)enqSt);
            AudioQueueRemovePropertyListener(newAQ, kAudioQueueProperty_IsRunning, AudioQueueRunningListener, (__bridge void *)self);
            AudioQueueDispose(newAQ, true);
            return NO;
        }
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
    _committedSample = 0;
    _captureLastSpeechSample = 0;
    _capturePeakRMS = 0.0f;
    _audioQueue = newAQ;
    for (int i = 0; i < 4; i++) {
        _audioBuffers[i] = newBuffers[i];
    }
    _audioQueueRunning = YES;
    atomic_store(&_audioQueueRunningAtomic, YES);
    [self.audioLock unlock];

    st = AudioQueueStart(newAQ, NULL);
    if (st != noErr) {
        NSLog(@"VoicePTT: AudioQueueStart failed: %d", (int)st);
        [self stopAudioCaptureOnAudioQueue];
        return NO;
    }
    return YES;
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
    if (!atomic_load(&_audioQueueRunningAtomic)) {
        [self scheduleAudioCaptureRestart:0.0];
        [self showToastWithHeader:@"Reconnecting Microphone…" caption:@"Try again in a moment" dotColor:[NSColor systemYellowColor] duration:1.4];
        return NO;
    }
    return YES;
}

- (void)beginSessionWithState:(AppState)newState {
    [self beginSessionWithState:newState includePreRoll:YES];
}

- (void)beginSessionWithState:(AppState)newState includePreRoll:(BOOL)includePreRoll {
    if (![self ensureContinuousMicReady]) return;

    NSDictionary *cfg = [self loadPipelineConfig];
    NSInteger preRollMs = includePreRoll ? (cfg[@"pre_roll_ms"] ? [cfg[@"pre_roll_ms"] integerValue] : 300) : 0;
    preRollMs = MAX(0, MIN(2000, preRollMs));
    uint64_t preRollSamples = (uint64_t)((preRollMs * kSampleRate) / 1000);

    self.sessionGen++;
    [self.pendingStopTimer invalidate];
    self.pendingStopTimer = nil;
    self.awaitingResetSecondTapUp = NO;
    [self.postRollTimer invalidate];
    self.postRollTimer = nil;
    self.committedText = @"";
    self.liveTailText = @"";
    self.liveCaptionText = @"";
    self.lastStreamPassEndSample = 0;
    self.finalizePending = NO;
    self.finalizeEndSample = 0;

    [self.audioLock lock];
    uint64_t nowSample = _ringTotalSamples;
    uint64_t earliest = (nowSample > kRingCapacitySamples) ? (nowSample - kRingCapacitySamples) : 0;
    _captureStartSample = (nowSample > earliest + preRollSamples) ? (nowSample - preRollSamples) : earliest;
    _committedSample = _captureStartSample;
    _captureLastSpeechSample = 0;
    _capturePeakRMS = 0.0f;
    _isCapturingSession = YES;
    [self.audioLock unlock];

    self.state = newState;
    [self startStreamTimer];
    [self updateUI];
}

- (void)clearBufferAndRestartLockedSession {
    self.osdResetFlashUntil = CACurrentMediaTime() + 0.90;
    [self beginSessionWithState:AppStateLocked includePreRoll:NO];
    NSUInteger gen = self.sessionGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(920 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (gen == self.sessionGen && self.state == AppStateLocked) {
            [self updateUI];
        }
    });
}

- (void)commitPendingStopNow {
    NSTimeInterval rel = self.pendingStopReleaseTime;
    [self.pendingStopTimer invalidate];
    self.pendingStopTimer = nil;
    self.awaitingResetSecondTapUp = NO;
    if (self.state == AppStateLocked) {
        [self finishRecordingAndTranscribeFromReleaseTime:rel];
    }
}

- (void)handleTriggerDown {
    if (!self.serverReady || self.state == AppStateTranscribing) return;

    NSTimeInterval now = CACurrentMediaTime();

    if (self.mode == PTTModeDoubleTap) {
        self.tapDownTime = now;
        if (self.state == AppStateIdle) {
            if (self.lastIdleSoloTapUpTime > 0 &&
                (now - self.lastIdleSoloTapUpTime) < 0.40 &&
                !atomic_load(&_tapInterveningKeyPressed)) {
                self.awaitingSecondTapWhileIdle = YES;
            } else {
                self.awaitingSecondTapWhileIdle = NO;
                self.lastIdleSoloTapUpTime = 0;
            }
        } else if (self.state == AppStateLocked && self.pendingStopTimer != nil) {
            if (!atomic_load(&_tapInterveningKeyPressed)) {
                // Second tap started inside the double-tap window — pause pending stop until keyUp confirms solo tap
                [self.pendingStopTimer invalidate];
                self.pendingStopTimer = nil;
                self.awaitingResetSecondTapUp = YES;
            } else {
                [self commitPendingStopNow];
            }
        }
        return;
    }

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
    if (self.mode == PTTModeDoubleTap) {
        if (!self.serverReady || self.state == AppStateTranscribing) return;
        NSTimeInterval now = CACurrentMediaTime();
        NSTimeInterval pressDuration = (self.tapDownTime > 0) ? (now - self.tapDownTime) : 0.0;
        BOOL wasCleanSoloTap = !atomic_load(&_tapOtherKeyPressedDuringHold) && (pressDuration < 0.45);

        if (self.state == AppStateIdle) {
            if (!wasCleanSoloTap) {
                self.awaitingSecondTapWhileIdle = NO;
                self.lastIdleSoloTapUpTime = 0;
                return;
            }
            if (self.awaitingSecondTapWhileIdle) {
                self.awaitingSecondTapWhileIdle = NO;
                self.lastIdleSoloTapUpTime = 0;
                self.osdResetFlashUntil = 0;
                [self beginSessionWithState:AppStateLocked includePreRoll:YES];
            } else {
                self.lastIdleSoloTapUpTime = now;
                atomic_store(&_tapInterveningKeyPressed, NO);
            }
            return;
        }

        if (self.state == AppStateLocked) {
            if (self.awaitingResetSecondTapUp) {
                self.awaitingResetSecondTapUp = NO;
                if (wasCleanSoloTap) {
                    // Double-tap while active: clear buffer and start over!
                    [self clearBufferAndRestartLockedSession];
                } else {
                    // Second press was a shortcut chord (e.g. Cmd+Tab right after stopping) -> commit the stop
                    [self finishRecordingAndTranscribeFromReleaseTime:self.pendingStopReleaseTime];
                }
                return;
            }

            if (!wasCleanSoloTap) {
                // Ignore modifier chords (e.g. Cmd+C, Shift+letter) while recording hands-free
                return;
            }

            // First clean solo tap while active: schedule stop & send (overlaps with post-roll window so zero extra lag)
            self.pendingStopReleaseTime = now;
            atomic_store(&_tapInterveningKeyPressed, NO);
            [self.pendingStopTimer invalidate];
            NSTimeInterval stopDelay = 0.30;
#ifdef VOICEPTT_TEST
            if (self.testPendingStopDelayOverride > 0.0) {
                stopDelay = self.testPendingStopDelayOverride;
            }
#endif
            __weak typeof(self) weakSelf = self;
            self.pendingStopTimer = [NSTimer scheduledTimerWithTimeInterval:stopDelay repeats:NO block:^(NSTimer * _Nonnull timer) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf commitPendingStopNow];
            }];
        }
        return;
    }

    if (self.state != AppStateHolding) return;

    NSTimeInterval heldDuration = CACurrentMediaTime() - self.holdStartTime;

    if (atomic_load(&_tapOtherKeyPressedDuringHold)) {
        [self cancelRecording];
        return;
    }

    if (self.mode == PTTModeSmart && heldDuration < 0.25) {
        self.sessionGen++;
        [self stopStreamTimer];
        [self.audioLock lock];
        _isCapturingSession = NO;
        [self.audioLock unlock];
        self.committedText = @"";
        self.liveTailText = @"";
        self.liveCaptionText = @"";
        self.finalizePending = NO;
        self.lastShortTapReleaseTime = CACurrentMediaTime();
        self.state = AppStateIdle;
        [self updateUI];
        return;
    }

    [self finishRecordingAndTranscribe];
}

- (void)handleMediaButtonToggle {
    if (!self.serverReady || self.state == AppStateTranscribing) return;
    // Debounce electrical contact chatter when a 3.5mm TRRS headphone jack is bumped/unplugged
    NSTimeInterval now = CACurrentMediaTime();
    if (now - self.lastMediaButtonToggleTime < 0.35) {
        return;
    }
    self.lastMediaButtonToggleTime = now;

    if (self.state == AppStateIdle) {
        [self beginSessionWithState:AppStateLocked];
    } else if (self.state == AppStateHolding || self.state == AppStateLocked) {
        [self finishRecordingAndTranscribe];
    }
}

- (void)cancelRecording {
    self.sessionGen++;
    [self stopStreamTimer];
    [self.pendingStopTimer invalidate];
    self.pendingStopTimer = nil;
    self.awaitingSecondTapWhileIdle = NO;
    self.awaitingResetSecondTapUp = NO;
    self.lastIdleSoloTapUpTime = 0;
    self.osdResetFlashUntil = 0;
    [self.postRollTimer invalidate];
    self.postRollTimer = nil;
    [self.audioLock lock];
    _isCapturingSession = NO;
    [self.audioLock unlock];
    self.committedText = @"";
    self.liveTailText = @"";
    self.liveCaptionText = @"";
    self.finalizePending = NO;
    self.lastShortTapReleaseTime = 0;
    self.state = AppStateIdle;
    [self updateUI];
}

#pragma mark - Single-Model Incremental Streaming

- (NSString *)joinTranscriptPrefix:(NSString *)prefix withSuffix:(NSString *)suffix {
    NSString *a = [prefix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSString *b = [suffix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    if (a.length == 0) return b;
    if (b.length == 0) return a;

    // Guard against 1-word overlap at chunk commit boundaries
    NSArray<NSString *> *aWords = [a componentsSeparatedByString:@" "];
    NSArray<NSString *> *bWords = [b componentsSeparatedByString:@" "];
    if (aWords.count >= 1 && bWords.count >= 2) {
        NSString *lastA = [aWords.lastObject.lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
        NSString *firstB = [bWords.firstObject.lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
        if (lastA.length > 0 && [lastA isEqualToString:firstB]) {
            b = [[bWords subarrayWithRange:NSMakeRange(1, bWords.count - 1)] componentsJoinedByString:@" "];
            if (b.length == 0) return a;
        }
    }
    return [NSString stringWithFormat:@"%@ %@", a, b];
}

- (NSString *)assembledTranscript {
    return [self joinTranscriptPrefix:self.committedText withSuffix:self.liveTailText];
}

- (NSString *)buildStreamingPrompt {
    NSString *custom = [self loadCustomPrompt];
    NSString *committed = self.committedText ?: @"";
    if (committed.length > 220) {
        committed = [committed substringFromIndex:committed.length - 220];
        NSRange sp = [committed rangeOfString:@" "];
        if (sp.location != NSNotFound && sp.location + 1 < committed.length) {
            committed = [committed substringFromIndex:sp.location + 1];
        }
    }
    if (custom.length > 0 && committed.length > 0) {
        return [NSString stringWithFormat:@"%@ %@", custom, committed];
    }
    return committed.length > 0 ? committed : custom;
}

- (void)startStreamTimer {
    [self stopStreamTimer];
    if (!self.liveCaptionEnabled) return;

    self.streamTimer = [NSTimer scheduledTimerWithTimeInterval:0.55 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [self runStreamingPass];
    }];
}

- (void)stopStreamTimer {
    [self.streamTimer invalidate];
    self.streamTimer = nil;
}

- (void)runStreamingPass {
    if (self.streamPassInFlight || self.finalizePending || self.pendingStopTimer != nil || (self.state != AppStateHolding && self.state != AppStateLocked)) return;

    uint64_t tailStart = 0;
    uint64_t nowSample = 0;
    uint64_t lastSpeech = 0;
    float peak = 0.0f;
    float gateThresh = 0.025f;

    [self.audioLock lock];
    if (_isCapturingSession && _ringTotalSamples > _committedSample) {
        tailStart = _committedSample;
        nowSample = _ringTotalSamples;
        lastSpeech = _captureLastSpeechSample;
        peak = _capturePeakRMS;
        gateThresh = [self effectiveGateThresholdLocked];
    }
    [self.audioLock unlock];

    if (nowSample <= tailStart || peak < gateThresh || lastSpeech <= tailStart) return;

    uint64_t tailSamples = nowSample - tailStart;
    double tailDurationSec = (double)tailSamples / (double)kSampleRate;

    // Avoid mid-flight contention on short 1-4.5s bursts:
    // Only stream incrementally once the speaker either pauses cleanly (>= 400ms silence after >= 1.2s tail)
    // OR speaks continuously past 4.5s (long hands-free dictation).
    BOOL pauseReady = (tailDurationSec >= 1.2) &&
                      (nowSample >= lastSpeech + (uint64_t)(kSampleRate * 40 / 100));
    BOOL longSpeechReady = (tailDurationSec >= 4.5);
    if (!pauseReady && !longSpeechReady) return;

    // Avoid redundant passes during silence: require >= 0.45s new audio AND speech not already covered
    if (self.lastStreamPassEndSample > tailStart) {
        uint64_t newSinceLast = (nowSample > self.lastStreamPassEndSample) ? (nowSample - self.lastStreamPassEndSample) : 0;
        if (newSinceLast < (uint64_t)(kSampleRate * 45 / 100)) return;
        if (lastSpeech + (uint64_t)(kSampleRate * 45 / 100) <= self.lastStreamPassEndSample) return;
    }

    NSData *snapshot = [self sliceRingPCMFromSample:tailStart toSample:nowSample];
    if (!snapshot) return;

    NSData *filtered = [self applyHighPassFilterPCM:snapshot];
    NSUInteger trimStartSamples = 0;
    NSUInteger lastSpeechOffsetInSlice = 0;
    NSData *gated = [self applyNoiseGateAndTrimPCM:filtered
                                         threshold:gateThresh
                               outTrimStartSamples:&trimStartSamples
                               outLastSpeechSample:&lastSpeechOffsetInSlice];
    if (!gated || gated.length < (kSampleRate * 2 / 3)) return;

    double gatedDurationSec = (double)gated.length / ((double)kSampleRate * 2.0);
    BOOL needSegments = (!pauseReady && tailDurationSec >= 8.0);

    self.streamPassInFlight = YES;
    NSUInteger gen = self.sessionGen;
    NSString *prompt = [self buildStreamingPrompt];

    [self sendPCMToWhisper:gated prompt:prompt needSegments:needSegments completion:^(NSString *cleaned, NSArray<NSDictionary *> *segments, double elapsed) {
        self.streamPassInFlight = NO;
        if (gen != self.sessionGen) return;

        self.lastStreamPassEndSample = nowSample;

        if (cleaned.length > 0) {
            // Trigger A: Clean pause commit (>= 1.2s tail with >= 400ms trailing below-gate silence)
            BOOL hasCleanTrailingPause = (tailDurationSec >= 1.2) &&
                                         (lastSpeechOffsetInSlice > 0) &&
                                         (tailSamples >= (uint64_t)lastSpeechOffsetInSlice + (uint64_t)(kSampleRate * 40 / 100));

            if (hasCleanTrailingPause) {
                self.committedText = [self joinTranscriptPrefix:self.committedText withSuffix:cleaned];
                self.liveTailText = @"";
                uint64_t nextCommit = tailStart + (uint64_t)lastSpeechOffsetInSlice + (uint64_t)(kSampleRate * 15 / 100);
                if (nextCommit > nowSample) nextCommit = nowSample;
                [self.audioLock lock];
                if (nextCommit > _committedSample) {
                    _committedSample = nextCommit;
                }
                [self.audioLock unlock];
            } else if (tailDurationSec >= 8.0 && segments.count >= 2) {
                // Trigger B: Long continuous speech commit via verbose_json segment timestamps
                NSInteger commitIdx = -1;
                double commitEndSec = 0.0;
                for (NSInteger i = 0; i < (NSInteger)segments.count - 1; i++) {
                    NSDictionary *seg = segments[i];
                    if ([seg isKindOfClass:[NSDictionary class]] && [seg[@"end"] respondsToSelector:@selector(doubleValue)]) {
                        double segEnd = [seg[@"end"] doubleValue];
                        if (segEnd > 0.5 && segEnd <= (gatedDurationSec - 1.5)) {
                            commitIdx = i;
                            commitEndSec = segEnd;
                        }
                    }
                }
                if (commitIdx >= 0) {
                    NSMutableArray<NSString *> *headParts = [NSMutableArray array];
                    NSMutableArray<NSString *> *tailParts = [NSMutableArray array];
                    for (NSInteger i = 0; i < (NSInteger)segments.count; i++) {
                        NSString *t = [segments[i][@"text"] isKindOfClass:[NSString class]] ? segments[i][@"text"] : @"";
                        if (i <= commitIdx) [headParts addObject:t];
                        else [tailParts addObject:t];
                    }
                    NSString *headClean = [self sanitizeTranscript:[headParts componentsJoinedByString:@" "]];
                    NSString *tailClean = [self sanitizeTranscript:[tailParts componentsJoinedByString:@" "]];
                    if (headClean.length > 0) {
                        self.committedText = [self joinTranscriptPrefix:self.committedText withSuffix:headClean];
                        self.liveTailText = tailClean;
                        uint64_t nextCommit = tailStart + (uint64_t)trimStartSamples + (uint64_t)llround(commitEndSec * (double)kSampleRate);
                        if (nextCommit > nowSample) nextCommit = nowSample;
                        [self.audioLock lock];
                        if (nextCommit > _committedSample) {
                            _committedSample = nextCommit;
                        }
                        [self.audioLock unlock];
                    } else {
                        self.liveTailText = cleaned;
                    }
                } else {
                    self.liveTailText = cleaned;
                }
            } else {
                self.liveTailText = cleaned;
            }
        }

        self.liveCaptionText = [self assembledTranscript];
        if (self.state == AppStateHolding || self.state == AppStateLocked) {
            [self updateUI];
        }

        if (self.finalizePending) {
            [self runFinalizeStepForGen:gen];
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

- (NSData *)applyNoiseGateAndTrimPCM:(NSData *)pcm
                           threshold:(float)thresh
                 outTrimStartSamples:(NSUInteger *)outTrimStartSamples
                 outLastSpeechSample:(NSUInteger *)outLastSpeechSample {
    if (outTrimStartSamples) *outTrimStartSamples = 0;
    if (outLastSpeechSample) *outLastSpeechSample = 0;

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

    if (outTrimStartSamples) *outTrimStartSamples = startWin * win;
    if (outLastSpeechSample) *outLastSpeechSample = (NSUInteger)(lastSpeechWin + 1) * win;

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

#pragma mark - Extraction, Finalization, Decision Router & LLM Refinement

- (void)finishRecordingAndTranscribe {
    [self finishRecordingAndTranscribeFromReleaseTime:CACurrentMediaTime()];
}

- (void)finishRecordingAndTranscribeFromReleaseTime:(NSTimeInterval)initialReleaseTime {
    // Keep sessionGen intact so an in-flight streaming pass hands off cleanly instead of being discarded
    NSUInteger gen = self.sessionGen;
    [self stopStreamTimer];
    [self.pendingStopTimer invalidate];
    self.pendingStopTimer = nil;
    self.awaitingResetSecondTapUp = NO;
    [self.postRollTimer invalidate];
    self.postRollTimer = nil;

    NSDictionary *cfg = [self loadPipelineConfig];
    NSInteger postRollMinMs = cfg[@"post_roll_min_ms"] ? [cfg[@"post_roll_min_ms"] integerValue] : 350;
    NSInteger postRollSilenceMs = cfg[@"post_roll_silence_ms"] ? [cfg[@"post_roll_silence_ms"] integerValue] : 450;
    NSInteger postRollMaxMs = cfg[@"post_roll_max_ms"] ? [cfg[@"post_roll_max_ms"] integerValue] : 1800;
    postRollMinMs = MAX(100, MIN(2000, postRollMinMs));
    postRollSilenceMs = MAX(150, MIN(2000, postRollSilenceMs));
    postRollMaxMs = MAX(postRollMinMs, MIN(4000, postRollMaxMs));

    NSTimeInterval releaseTime = (initialReleaseTime > 0.0) ? initialReleaseTime : CACurrentMediaTime();
    self.finalizePipelineStart = releaseTime;
    self.state = AppStateTranscribing;
    [self updateUI];

    // Speech-tail-aware post-roll: keep listening briefly until silence settles (or max cap)
    // so releasing the key slightly early never chops the final word.
    self.postRollTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer * _Nonnull timer) {
        if (gen != self.sessionGen) {
            [timer invalidate];
            return;
        }

        double elapsedMs = (CACurrentMediaTime() - releaseTime) * 1000.0;
        if (elapsedMs < (double)postRollMinMs) {
            return;
        }

        uint64_t nowSample = 0;
        uint64_t lastSpeech = 0;
        [self.audioLock lock];
        nowSample = _ringTotalSamples;
        lastSpeech = _captureLastSpeechSample;
        [self.audioLock unlock];

        double silenceSinceSpeechMs = (lastSpeech > 0 && nowSample >= lastSpeech)
            ? ((double)(nowSample - lastSpeech) * 1000.0 / (double)kSampleRate)
            : 9999.0;

        BOOL micAlive = atomic_load(&_audioQueueRunningAtomic);
        if (!micAlive || silenceSinceSpeechMs >= (double)postRollSilenceMs || elapsedMs >= (double)postRollMaxMs) {
            [timer invalidate];
            self.postRollTimer = nil;
            self.finalizePostRollEnd = CACurrentMediaTime();

            [self.audioLock lock];
            self.finalizeEndSample = _ringTotalSamples;
            _isCapturingSession = NO;
            [self.audioLock unlock];

            self.finalizePending = YES;
            if (!self.streamPassInFlight) {
                [self runFinalizeStepForGen:gen];
            }
        }
    }];
}

- (void)runFinalizeStepForGen:(NSUInteger)gen {
    if (gen != self.sessionGen || !self.finalizePending) return;
    self.finalizePending = NO;

    NSTimeInterval streamWaitEnd = CACurrentMediaTime();
    double postRollMs = (self.finalizePostRollEnd - self.finalizePipelineStart) * 1000.0;
    double waitStreamMs = MAX(0.0, (streamWaitEnd - self.finalizePostRollEnd) * 1000.0);

    uint64_t startSample = 0;
    uint64_t commitSample = 0;
    uint64_t endSample = self.finalizeEndSample;
    uint64_t lastSpeech = 0;
    float peak = 0.0f;
    float gateThresh = 0.025f;

    [self.audioLock lock];
    startSample = _captureStartSample;
    commitSample = _committedSample;
    lastSpeech = _captureLastSpeechSample;
    peak = _capturePeakRMS;
    gateThresh = [self effectiveGateThresholdLocked];
    [self.audioLock unlock];

    double totalAudioSec = (endSample > startSample) ? ((double)(endSample - startSample) / (double)kSampleRate) : 0.0;
    double tailAudioSec = (endSample > commitSample) ? ((double)(endSample - commitSample) / (double)kSampleRate) : 0.0;

    void (^finishWithRawTranscript)(NSString *, double, BOOL) = ^(NSString *rawAssembled, double whisperFinalMs, BOOL usedFastPath) {
        if (gen != self.sessionGen) return;
        NSString *trimmed = [rawAssembled stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        if (trimmed.length == 0) {
            self.state = AppStateIdle;
            self.committedText = @"";
            self.liveTailText = @"";
            self.liveCaptionText = @"";
            [self updateUI];
            return;
        }

        NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
        NSString *activeApp = frontApp.localizedName ?: @"";
        NSString *frontBundleID = frontApp.bundleIdentifier ?: @"";
#ifdef VOICEPTT_TEST
        if (self.testFrontAppNameOverride) activeApp = self.testFrontAppNameOverride;
        if (self.testFrontAppBundleIDOverride) frontBundleID = self.testFrontAppBundleIDOverride;
#endif

        void (^continueAfterFocusCheck)(BOOL) = ^(BOOL focusedEditable) {
            if (gen != self.sessionGen) return;

            [self runDecisionRouterAndRefinement:trimmed
                                       activeApp:activeApp
                                 focusedEditable:focusedEditable
                                   audioDuration:totalAudioSec
                                      completion:^(NSString *finalText, NSString *routeOverride, double drMs, double llmMs) {
                if (gen != self.sessionGen) return;

                self.state = AppStateIdle;
                self.committedText = @"";
                self.liveTailText = @"";
                self.liveCaptionText = @"";

                NSString *preview = finalText.length > 60
                    ? [[finalText substringToIndex:60] stringByAppendingString:@"…"]
                    : finalText;

                if (finalText.length > 0 && ![routeOverride isEqualToString:@"discard"]) {
                    self.lastTranscript = finalText;
                    [self deliverFinalText:finalText
                           focusedEditable:focusedEditable
                             routeOverride:routeOverride
                                 onEmitted:^{
                        double totalMs = (CACurrentMediaTime() - self.finalizePipelineStart) * 1000.0;
                        self.lastLatencySec = totalMs / 1000.0;
                        NSString *logLine = [NSString stringWithFormat:
                            @"total=%.0fms | post_roll=%.0fms | wait_stream=%.0fms | whisper=%.0fms (tail=%.1fs, fastpath=%@) | dr=%.0fms | llm=%.0fms | out=%@ (%@) | \"%@\"",
                            totalMs, postRollMs, waitStreamMs, whisperFinalMs, tailAudioSec,
                            usedFastPath ? @"yes" : @"no", drMs, llmMs,
                            self.lastOutputStatus ?: @"", activeApp.length > 0 ? activeApp : @"unknown", preview];
                        [self appendLatencyLog:logLine];
                    }];
                } else if ([routeOverride isEqualToString:@"discard"]) {
                    double totalMs = (CACurrentMediaTime() - self.finalizePipelineStart) * 1000.0;
                    self.lastOutputStatus = @"Discarded (DR)";
                    NSString *logLine = [NSString stringWithFormat:
                        @"total=%.0fms | post_roll=%.0fms | wait_stream=%.0fms | whisper=%.0fms | dr=%.0fms | out=Discarded (DR)",
                        totalMs, postRollMs, waitStreamMs, whisperFinalMs, drMs];
                    [self appendLatencyLog:logLine];
                    [self showToastWithHeader:@"Discarded by Decision Router" caption:nil dotColor:[NSColor systemGrayColor] duration:1.2];
                }
                [self updateUI];
            }];
        };

        // Fast paths avoid AX IPC completely; otherwise run AX queries off the main thread
        if (IsKnownTerminalBundleID(frontBundleID)) {
            continueAfterFocusCheck(YES);
        } else if (self.outputMode != OutputModeSmartAuto && ![self isDecisionRouterEnabled]) {
            continueAfterFocusCheck(NO);
        } else {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                BOOL editable = IsFocusedElementEditableTextForBundleID(frontBundleID);
                dispatch_async(dispatch_get_main_queue(), ^{
                    continueAfterFocusCheck(editable);
                });
            });
        }
    };

    // Fast path: if streaming already covered all speech up to (lastSpeech + 150ms), zero extra Whisper work!
    NSString *alreadyAssembled = [self assembledTranscript];
    BOOL speechAlreadyCovered = (self.lastStreamPassEndSample > 0) &&
                                (lastSpeech > 0) &&
                                (self.lastStreamPassEndSample >= lastSpeech + (uint64_t)(kSampleRate * 15 / 100));
    if (speechAlreadyCovered && alreadyAssembled.length > 0) {
        finishWithRawTranscript(alreadyAssembled, 0.0, YES);
        return;
    }

    // Otherwise run ONE final pass on ONLY the uncommitted tail [commitSample, endSample)
    if (endSample <= commitSample || peak < gateThresh) {
        finishWithRawTranscript(alreadyAssembled, 0.0, YES);
        return;
    }

    NSData *tailPCM = [self sliceRingPCMFromSample:commitSample toSample:endSample];
    if (!tailPCM || tailPCM.length < (kSampleRate * 2 / 4)) {
        finishWithRawTranscript(alreadyAssembled, 0.0, YES);
        return;
    }

    NSData *filteredPCM = [self applyHighPassFilterPCM:tailPCM];
    NSData *gatedPCM = [self applyNoiseGateAndTrimPCM:filteredPCM
                                            threshold:gateThresh
                                  outTrimStartSamples:NULL
                                  outLastSpeechSample:NULL];
    if (!gatedPCM || gatedPCM.length < (kSampleRate * 2 / 5)) {
        finishWithRawTranscript(alreadyAssembled, 0.0, YES);
        return;
    }

    NSString *prompt = [self buildStreamingPrompt];
    [self sendPCMToWhisper:gatedPCM prompt:prompt needSegments:NO completion:^(NSString *tailCleaned, NSArray<NSDictionary *> *segments, double asrElapsed) {
        if (gen != self.sessionGen) return;
        NSString *combined = [self joinTranscriptPrefix:self.committedText withSuffix:tailCleaned];
        if (combined.length == 0) {
            combined = alreadyAssembled;
        }
        finishWithRawTranscript(combined, asrElapsed * 1000.0, NO);
    }];
}

// Stage 3A: Decision Router (Intern-Decision HTTP interface) -> Stage 3B: OpenAI-Compat LLM Refiner
- (void)runDecisionRouterAndRefinement:(NSString *)rawText
                             activeApp:(NSString *)activeApp
                       focusedEditable:(BOOL)focusedEditable
                         audioDuration:(double)audioDuration
                            completion:(void (^)(NSString *finalText, NSString *routeOverride, double drMs, double llmMs))completion {
    NSDictionary *cfg = self.pipelineConfig ?: [self defaultPipelineConfig];
    NSDictionary *drCfg = [cfg[@"decision_router"] isKindOfClass:[NSDictionary class]] ? cfg[@"decision_router"] : nil;
    NSDictionary *llmCfg = [cfg[@"llm"] isKindOfClass:[NSDictionary class]] ? cfg[@"llm"] : nil;

    void (^proceedToLLM)(BOOL, NSString *, NSString *, double) = ^(BOOL shouldRefine, NSString *styleHint, NSString *routeOverride, double drMs) {
        if ([routeOverride isEqualToString:@"discard"]) {
            completion(rawText, @"discard", drMs, 0.0);
            return;
        }
        if (!shouldRefine || ![llmCfg[@"enabled"] boolValue]) {
            completion(rawText, routeOverride, drMs, 0.0);
            return;
        }
        NSTimeInterval llmT0 = CACurrentMediaTime();
        [self refineTextWithOpenAICompatLLM:rawText
                                  activeApp:activeApp
                                  styleHint:styleHint
                                     config:llmCfg
                                 completion:^(NSString *refined) {
            double llmMs = (CACurrentMediaTime() - llmT0) * 1000.0;
            completion(refined.length > 0 ? refined : rawText, routeOverride, drMs, llmMs);
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
        proceedToLLM(defaultShouldRefine, @"prose", nil, 0.0);
        return;
    }

    NSString *endpoint = drCfg[@"endpoint_url"];
    NSURL *url = endpoint.length > 0 ? [NSURL URLWithString:endpoint] : nil;
    if (!url) {
        proceedToLLM(defaultShouldRefine, @"prose", nil, 0.0);
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
        proceedToLLM(defaultShouldRefine, @"prose", nil, 0.0);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = drCfg[@"timeout_sec"] ? [drCfg[@"timeout_sec"] doubleValue] : 2.5;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = body;

    NSTimeInterval drT0 = CACurrentMediaTime();
    NSURLSessionDataTask *task = [[self activeURLSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        BOOL shouldRefine = defaultShouldRefine;
        NSString *styleHint = @"prose";
        NSString *routeOverride = nil;
        double drMs = (CACurrentMediaTime() - drT0) * 1000.0;

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
            proceedToLLM(shouldRefine, styleHint, routeOverride, drMs);
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

    NSURLSessionDataTask *task = [[self activeURLSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
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

- (void)deliverFinalText:(NSString *)text
         focusedEditable:(BOOL)focusedEditable
           routeOverride:(NSString *)routeOverride
               onEmitted:(void (^)(void))onEmitted {
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

#ifdef VOICEPTT_TEST
    if (self.testDeliverTextHook) {
        NSString *emitted = (shouldPaste && self.addTrailingSpace) ? [text stringByAppendingString:@" "] : text;
        self.testDeliverTextHook(emitted, shouldPaste, statusTag);
        if (onEmitted) onEmitted();
        return;
    }
#endif

    if (shouldPaste) {
        NSString *toPaste = self.addTrailingSpace ? [text stringByAppendingString:@" "] : text;
        [self pasteTextPreservingClipboard:toPaste onPosted:onEmitted];
    } else {
        [self copyTextToClipboard:text];
        if (onEmitted) onEmitted();
        [self showToastWithHeader:@"Copied to Clipboard ✓" caption:text dotColor:[NSColor systemGreenColor] duration:1.8];
    }
}

- (void)sendPCMToWhisper:(NSData *)pcm
                  prompt:(NSString *)prompt
            needSegments:(BOOL)needSegments
              completion:(void (^)(NSString *cleaned, NSArray<NSDictionary *> *segments, double elapsed))completion {
    double durationSec = (double)pcm.length / ((double)kSampleRate * 2.0);
    // Dynamic audio_ctx: keep generous minimum (384) so large-v3-turbo doesn't echo/loop short phrases
    NSInteger audioCtx = 0;
    if (durationSec < 22.0) {
        NSInteger frames = (NSInteger)ceil((durationSec + 2.0) * 50.0);
        audioCtx = ((frames + 63) / 64) * 64;
        if (audioCtx < 384) audioCtx = 384;
        if (audioCtx >= 1500) audioCtx = 0;
    }

    NSData *wavData = BuildWAVData(pcm);
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
    // Keep segment timestamps enabled (large-v3-turbo needs them to emit EOT cleanly without repeating),
    // but disable expensive per-token cross-attention timestamps.
    appendField(@"no_timestamps", @"false");
    appendField(@"token_timestamps", @"false");
    appendField(@"response_format", needSegments ? @"verbose_json" : @"json");
    if (audioCtx > 0) {
        appendField(@"audio_ctx", [NSString stringWithFormat:@"%ld", (long)audioCtx]);
    }
    if (prompt.length > 0) {
        appendField(@"prompt", prompt);
    }
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/inference", (long)kServerPort]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30.0;
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = body;

    NSURLSessionDataTask *task = [[self activeURLSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *cleaned = nil;
        NSArray<NSDictionary *> *segments = nil;
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                if ([json[@"text"] isKindOfClass:[NSString class]]) {
                    cleaned = [self sanitizeTranscript:json[@"text"]];
                }
                if ([json[@"segments"] isKindOfClass:[NSArray class]]) {
                    segments = json[@"segments"];
                }
            }
        }
        double elapsed = CACurrentMediaTime() - t0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(cleaned ?: @"", segments ?: @[], elapsed);
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

- (void)pasteTextPreservingClipboard:(NSString *)text onPosted:(void (^)(void))onPosted {
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
        if (onPosted) onPosted();

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

#ifndef VOICEPTT_TEST
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
#endif
