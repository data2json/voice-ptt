#define VOICEPTT_TEST 1
#import "../src/VoicePTT.m"
#include <math.h>
#include <stdio.h>
#include <string.h>

// -----------------------------------------------------------------------------
// Lightweight Test Harness (Zero External Dependencies)
// -----------------------------------------------------------------------------
static int gTestsRun = 0;
static int gTestsPassed = 0;
static int gTestsFailed = 0;
static int gCurrentTestFailures = 0;

#define EXPECT_TRUE(cond) do { \
    if (!(cond)) { \
        fprintf(stderr, "  [FAIL] %s:%d: expected true: %s\n", __FILE__, __LINE__, #cond); \
        gCurrentTestFailures++; \
    } \
} while (0)

#define EXPECT_FALSE(cond) EXPECT_TRUE(!(cond))

#define EXPECT_EQ_INT(a, b) do { \
    long long _va = (long long)(a); \
    long long _vb = (long long)(b); \
    if (_va != _vb) { \
        fprintf(stderr, "  [FAIL] %s:%d: %s (%lld) != %s (%lld)\n", __FILE__, __LINE__, #a, _va, #b, _vb); \
        gCurrentTestFailures++; \
    } \
} while (0)

#define EXPECT_NEAR(a, b, tol) do { \
    double _va = (double)(a); \
    double _vb = (double)(b); \
    if (fabs(_va - _vb) > (double)(tol)) { \
        fprintf(stderr, "  [FAIL] %s:%d: %s (%.6f) != %s (%.6f) within %.6f\n", __FILE__, __LINE__, #a, _va, #b, _vb, (double)(tol)); \
        gCurrentTestFailures++; \
    } \
} while (0)

#define EXPECT_EQ_STR(a, b) do { \
    NSString *_sa = (a); \
    NSString *_sb = (b); \
    BOOL _eq = (_sa == _sb) || (_sa && _sb && [_sa isEqualToString:_sb]); \
    if (!_eq) { \
        fprintf(stderr, "  [FAIL] %s:%d: \"%s\" != \"%s\"\n", __FILE__, __LINE__, _sa ? _sa.UTF8String : "(nil)", _sb ? _sb.UTF8String : "(nil)"); \
        gCurrentTestFailures++; \
    } \
} while (0)

typedef void (*TestFn)(void);

static void RunTest(const char *name, TestFn fn) {
    gTestsRun++;
    gCurrentTestFailures = 0;
    @autoreleasepool {
        fn();
    }
    if (gCurrentTestFailures == 0) {
        gTestsPassed++;
        printf("[PASS] %s\n", name);
    } else {
        gTestsFailed++;
        printf("[FAIL] %s (%d assertion failure%s)\n", name, gCurrentTestFailures, gCurrentTestFailures == 1 ? "" : "s");
    }
}

// Pump the main run loop until predicate returns YES or timeout elapses
static BOOL PumpMainRunLoopUntil(NSTimeInterval timeoutSec, BOOL (^predicate)(void)) {
    NSTimeInterval deadline = CACurrentMediaTime() + timeoutSec;
    while (CACurrentMediaTime() < deadline) {
        if (predicate()) return YES;
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return predicate();
}

// -----------------------------------------------------------------------------
// Mock NSURLProtocol for Deterministic HTTP Testing (Whisper / DR / LLM)
// -----------------------------------------------------------------------------
typedef NSData * _Nullable (^MockHTTPHandler)(NSURLRequest *request, NSData *body, NSInteger *outStatusCode, NSError **outError);

@interface MockURLProtocol : NSURLProtocol
@end

static NSLock *gMockHTTPLock = nil;
static MockHTTPHandler gMockHTTPHandler = nil;
static NSMutableArray<NSURLRequest *> *gCapturedRequests = nil;
static NSMutableArray<NSData *> *gCapturedBodies = nil;

static void SetMockHTTPHandler(MockHTTPHandler handler) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gMockHTTPLock = [NSLock new];
        gCapturedRequests = [NSMutableArray array];
        gCapturedBodies = [NSMutableArray array];
    });
    [gMockHTTPLock lock];
    gMockHTTPHandler = [handler copy];
    [gCapturedRequests removeAllObjects];
    [gCapturedBodies removeAllObjects];
    [gMockHTTPLock unlock];
}

static NSData *ReadRequestBody(NSURLRequest *req) {
    if (req.HTTPBody) return req.HTTPBody;
    NSInputStream *stream = req.HTTPBodyStream;
    if (!stream) return [NSData data];
    [stream open];
    NSMutableData *buf = [NSMutableData data];
    uint8_t chunk[4096];
    while ([stream hasBytesAvailable]) {
        NSInteger n = [stream read:chunk maxLength:sizeof(chunk)];
        if (n <= 0) break;
        [buf appendBytes:chunk length:(NSUInteger)n];
    }
    [stream close];
    return buf;
}

@implementation MockURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return YES;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}
- (void)startLoading {
    NSData *body = ReadRequestBody(self.request);
    MockHTTPHandler handler = nil;
    [gMockHTTPLock lock];
    handler = gMockHTTPHandler;
    [gCapturedRequests addObject:self.request];
    [gCapturedBodies addObject:body ?: [NSData data]];
    [gMockHTTPLock unlock];

    NSInteger statusCode = 200;
    NSError *err = nil;
    NSData *respData = handler ? handler(self.request, body, &statusCode, &err) : [NSData data];

    if (err) {
        [self.client URLProtocol:self didFailWithError:err];
        return;
    }

    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                          statusCode:statusCode
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:@{ @"Content-Type": @"application/json" }];
    [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (respData) {
        [self.client URLProtocol:self didLoadData:respData];
    }
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

static NSURLSession *CreateMockURLSession(void) {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.protocolClasses = @[ [MockURLProtocol class] ];
    return [NSURLSession sessionWithConfiguration:cfg];
}

// -----------------------------------------------------------------------------
// Test Fixture Factory (Isolated Temp Config Dir, Zero Real Hardware/UI)
// -----------------------------------------------------------------------------
static VoicePTTApp *CreateTestApp(NSString **outTempDir) {
    VoicePTTApp *app = [VoicePTTApp new];
    app.audioLock = [NSLock new];
    app.tapLifecycleLock = [NSLock new];
    app.audioCacheLock = [NSLock new];
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    app.audioControlQueue = dispatch_queue_create("local.voiceptt.test.audio", attr);
    app.cachedInputDevices = @[];
    app.cachedInputGain = -1.0f;

    app->_ringSamples = (int16_t *)calloc((size_t)kRingCapacitySamples, sizeof(int16_t));
    app->_ambientNoiseFloor = 0.008f;
    app.pipelineConfig = [app defaultPipelineConfig];
    app.mode = PTTModeSmart;
    app.outputMode = OutputModeSmartAuto;
    app.hotkeyIndex = 0;
    app.gatePresetIndex = 0;
    app.micArmed = YES;
    app.showPill = NO;
    app.liveCaptionEnabled = YES;
    app.addTrailingSpace = NO;
    app.captureMediaButton = YES;
    app.serverReady = YES;
    app.state = AppStateIdle;
    app.testRetryDelayOverride = 0.03;

    NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"voiceptt-test-%@", [[NSUUID UUID] UUIDString]]];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
    app.testConfigDirOverride = tmpDir;
    if (outTempDir) *outTempDir = tmpDir;
    return app;
}

static void DestroyTestApp(VoicePTTApp *app, NSString *tempDir) {
    atomic_store(&app->_tapShuttingDown, YES);
    atomic_fetch_add(&app->_audioRestartGen, 1);
    [app stopStreamTimer];
    [app.postRollTimer invalidate];
    app.postRollTimer = nil;
    [app.toastTimer invalidate];
    app.toastTimer = nil;

    // Drain audioControlQueue so no async blocks touch freed ring buffer
    dispatch_sync(app.audioControlQueue, ^{});

    [app.audioLock lock];
    if (app->_ringSamples) {
        free(app->_ringSamples);
        app->_ringSamples = NULL;
    }
    [app.audioLock unlock];

    if (tempDir.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];
    }
}

static NSData *MakeSinePCM(NSUInteger sampleCount, double freqHz, double amplitude) {
    NSMutableData *data = [NSMutableData dataWithLength:sampleCount * sizeof(int16_t)];
    int16_t *p = (int16_t *)data.mutableBytes;
    for (NSUInteger i = 0; i < sampleCount; i++) {
        double v = amplitude * sin(2.0 * M_PI * freqHz * (double)i / (double)kSampleRate);
        if (v > 32767.0) v = 32767.0;
        if (v < -32768.0) v = -32768.0;
        p[i] = (int16_t)llround(v);
    }
    return data;
}

static void AppendSamplesToRing(VoicePTTApp *app, const int16_t *samples, uint64_t count) {
    [app.audioLock lock];
    uint64_t remaining = count;
    const int16_t *src = samples;
    while (remaining > 0) {
        uint64_t writeIdx = app->_ringTotalSamples % kRingCapacitySamples;
        uint64_t part = MIN(remaining, kRingCapacitySamples - writeIdx);
        memcpy(app->_ringSamples + writeIdx, src, (size_t)part * sizeof(int16_t));
        app->_ringTotalSamples += part;
        src += part;
        remaining -= part;
    }
    [app.audioLock unlock];
}

// =============================================================================
// 1. DSP, WAV, Ring Buffer & Adaptive Gate Tests
// =============================================================================

static void TestBuildWAVDataHeaderAndSilencePad(void) {
    int16_t samples[4] = { 1000, -1000, 2000, -2000 };
    NSData *pcm = [NSData dataWithBytes:samples length:sizeof(samples)];
    NSData *wav = BuildWAVData(pcm);

    const uint32_t expectedSilenceBytes = (uint32_t)(kSampleRate * 2 * 45 / 100); // 14400 bytes
    const uint32_t expectedDataSize = (uint32_t)pcm.length + expectedSilenceBytes;
    EXPECT_EQ_INT(wav.length, 44 + expectedDataSize);

    const uint8_t *b = (const uint8_t *)wav.bytes;
    EXPECT_TRUE(memcmp(b, "RIFF", 4) == 0);
    EXPECT_TRUE(memcmp(b + 8, "WAVE", 4) == 0);
    EXPECT_TRUE(memcmp(b + 12, "fmt ", 4) == 0);
    EXPECT_TRUE(memcmp(b + 36, "data", 4) == 0);

    uint32_t chunkSize = 0, sampleRate = 0, dataSize = 0;
    uint16_t numChannels = 0, bitsPerSample = 0;
    memcpy(&chunkSize, b + 4, 4);
    memcpy(&numChannels, b + 22, 2);
    memcpy(&sampleRate, b + 24, 4);
    memcpy(&bitsPerSample, b + 34, 2);
    memcpy(&dataSize, b + 40, 4);

    EXPECT_EQ_INT(chunkSize, 36 + expectedDataSize);
    EXPECT_EQ_INT(numChannels, 1);
    EXPECT_EQ_INT(sampleRate, 16000);
    EXPECT_EQ_INT(bitsPerSample, 16);
    EXPECT_EQ_INT(dataSize, expectedDataSize);

    // Original PCM bytes preserved at offset 44
    EXPECT_TRUE(memcmp(b + 44, samples, sizeof(samples)) == 0);

    // Trailing silence pad is zero-filled
    BOOL allZero = YES;
    for (uint32_t i = 0; i < expectedSilenceBytes; i++) {
        if (b[44 + sizeof(samples) + i] != 0) {
            allZero = NO;
            break;
        }
    }
    EXPECT_TRUE(allZero);
}

static void TestHighPassFilterRemovesDCAndPreservesVoice(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    // Pure DC offset (+12000) should decay to near zero
    NSMutableData *dc = [NSMutableData dataWithLength:1600 * sizeof(int16_t)];
    int16_t *p = (int16_t *)dc.mutableBytes;
    for (int i = 0; i < 1600; i++) p[i] = 12000;

    NSData *dcFiltered = [app applyHighPassFilterPCM:dc];
    const int16_t *outDC = (const int16_t *)dcFiltered.bytes;
    EXPECT_EQ_INT(outDC[0], 0);
    EXPECT_TRUE(abs(outDC[1599]) < 50);

    // 1 kHz voice-band tone should retain > 90% amplitude
    NSData *tone = MakeSinePCM(1600, 1000.0, 10000.0);
    NSData *toneFiltered = [app applyHighPassFilterPCM:tone];
    const int16_t *outTone = (const int16_t *)toneFiltered.bytes;
    int maxAmp = 0;
    for (int i = 400; i < 1600; i++) {
        if (abs(outTone[i]) > maxAmp) maxAmp = abs(outTone[i]);
    }
    EXPECT_TRUE(maxAmp > 9000);

    // Tiny input (< 2 samples) returns cleanly without crashing
    int16_t one = 42;
    NSData *tiny = [NSData dataWithBytes:&one length:sizeof(one)];
    EXPECT_EQ_INT([app applyHighPassFilterPCM:tiny].length, sizeof(one));

    DestroyTestApp(app, tmp);
}

static void TestNoiseGateAndTrim(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    // Pure quiet room noise below threshold -> nil
    NSData *quiet = MakeSinePCM(3200, 500.0, 100.0); // RMS ~0.002
    EXPECT_TRUE([app applyNoiseGateAndTrimPCM:quiet threshold:0.025f outTrimStartSamples:NULL outLastSpeechSample:NULL] == nil);

    // 1.0s silence + 0.4s loud speech + 1.0s silence
    NSMutableData *utterance = [NSMutableData dataWithLength:16000 * sizeof(int16_t)]; // 1.0s zeros
    [utterance appendData:MakeSinePCM(6400, 800.0, 12000.0)]; // 0.4s speech (RMS ~0.26)
    [utterance appendData:[NSMutableData dataWithLength:16000 * sizeof(int16_t)]]; // 1.0s zeros

    NSUInteger trimStart = 0;
    NSUInteger lastSpeech = 0;
    NSData *gated = [app applyNoiseGateAndTrimPCM:utterance
                                        threshold:0.025f
                              outTrimStartSamples:&trimStart
                              outLastSpeechSample:&lastSpeech];
    EXPECT_TRUE(gated != nil);
    // Speech starts at sample 16000 (win 50); pre-roll is 10 wins (3200 samples) -> trimStart = 12800
    EXPECT_EQ_INT(trimStart, 12800);
    // Speech ends at sample 22400 (win 70) -> lastSpeech = 22400
    EXPECT_EQ_INT(lastSpeech, 22400);
    // Output should be trimmed significantly shorter than original 2.4s (38400 samples)
    EXPECT_TRUE(gated.length < utterance.length);
    EXPECT_TRUE(gated.length >= 6400 * sizeof(int16_t));

    DestroyTestApp(app, tmp);
}

static void TestRingBufferWraparoundAndClamping(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    // Position ring near wraparound boundary (kRingCapacitySamples - 5)
    [app.audioLock lock];
    app->_ringTotalSamples = kRingCapacitySamples - 5;
    [app.audioLock unlock];

    int16_t pattern[12] = { 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21 };
    AppendSamplesToRing(app, pattern, 12);

    // Slice across wrap boundary
    uint64_t start = kRingCapacitySamples - 5;
    uint64_t end = start + 12;
    NSData *sliced = [app sliceRingPCMFromSample:start toSample:end];
    EXPECT_TRUE(sliced != nil);
    EXPECT_EQ_INT(sliced.length, 12 * sizeof(int16_t));
    EXPECT_TRUE(memcmp(sliced.bytes, pattern, sizeof(pattern)) == 0);

    // Requesting older than earliest available sample clamps cleanly
    NSData *clamped = [app sliceRingPCMFromSample:0 toSample:end];
    EXPECT_EQ_INT(clamped.length, kRingCapacitySamples * sizeof(int16_t));

    // Invalid range (end <= start) returns nil
    EXPECT_TRUE([app sliceRingPCMFromSample:end toSample:start] == nil);

    DestroyTestApp(app, tmp);
}

static void TestAdaptiveGateThreshold(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    // Auto preset (index 0): _ambientNoiseFloor * 2.6 clamped to [0.012, 0.11]
    app.gatePresetIndex = 0;
    app->_ambientNoiseFloor = 0.002f; // 0.0052 -> clamps to min 0.012
    EXPECT_NEAR([app effectiveGateThresholdLocked], 0.012f, 0.0001f);

    app->_ambientNoiseFloor = 0.020f; // 0.052
    EXPECT_NEAR([app effectiveGateThresholdLocked], 0.052f, 0.0001f);

    app->_ambientNoiseFloor = 0.080f; // 0.208 -> clamps to max 0.11
    EXPECT_NEAR([app effectiveGateThresholdLocked], 0.11f, 0.0001f);

    // Fixed preset (index 3 = High = 0.045)
    app.gatePresetIndex = 3;
    EXPECT_NEAR([app effectiveGateThresholdLocked], 0.045f, 0.0001f);

    DestroyTestApp(app, tmp);
}

// =============================================================================
// 2. Transcript Sanitization, Repetition Loops & Streaming Prompt Tests
// =============================================================================

static void TestSanitizeTranscriptAndRepetitionLoops(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    EXPECT_EQ_STR([app sanitizeTranscript:nil], @"");
    EXPECT_EQ_STR([app sanitizeTranscript:@"   \n\t  "], @"");
    EXPECT_EQ_STR([app sanitizeTranscript:@"[BLANK_AUDIO]  (music) "], @"");
    EXPECT_EQ_STR([app sanitizeTranscript:@"  Thank you.  "], @"");
    EXPECT_EQ_STR([app sanitizeTranscript:@"thanks for watching!"], @"");
    EXPECT_EQ_STR([app sanitizeTranscript:@"  Hello\n   world  [cough]  today  "], @"Hello world today");

    // Short (< 6 words) skips loop collapser; 6+ words collapses 1-word & 2-word loops (>= 3x)
    EXPECT_EQ_STR([app collapseRepetitionLoops:@"hello hello hello hello world"], @"hello hello hello hello world");
    EXPECT_EQ_STR([app collapseRepetitionLoops:@"hello hello hello hello hello world"], @"hello world");
    EXPECT_EQ_STR([app collapseRepetitionLoops:@"thank you thank you thank you thank you"], @"thank you");
    // 2x repetition is preserved (natural speech like "no no")
    EXPECT_EQ_STR([app collapseRepetitionLoops:@"wait no no that is fine right now"], @"wait no no that is fine right now");

    DestroyTestApp(app, tmp);
}

static void TestJoinTranscriptPrefixAndStreamingPrompt(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    EXPECT_EQ_STR([app joinTranscriptPrefix:@"" withSuffix:@"hello world"], @"hello world");
    EXPECT_EQ_STR([app joinTranscriptPrefix:@"hello world" withSuffix:@""], @"hello world");
    EXPECT_EQ_STR([app joinTranscriptPrefix:@"Hello world" withSuffix:@"from macOS"], @"Hello world from macOS");
    // 1-word overlap dedupe across chunk commit boundary (case & punctuation insensitive)
    EXPECT_EQ_STR([app joinTranscriptPrefix:@"Testing boundary." withSuffix:@"boundary works great"], @"Testing boundary. works great");

    // Custom prompt + committed text trimming to <= 220 chars on word boundary
    [@"VoicePTT Whisper" writeToFile:[app promptFilePath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSMutableString *longCommit = [NSMutableString string];
    for (int i = 0; i < 40; i++) [longCommit appendFormat:@"word%02d ", i];
    app.committedText = longCommit;
    NSString *prompt = [app buildStreamingPrompt];
    EXPECT_TRUE([prompt hasPrefix:@"VoicePTT Whisper "]);
    EXPECT_TRUE(prompt.length < 260);
    EXPECT_TRUE([prompt hasSuffix:@"word39 "]);

    DestroyTestApp(app, tmp);
}

// =============================================================================
// 3. PTT State Machine, Hotkeys & Headphone-Bump Regression Tests
// =============================================================================

static void TestSmartModeHoldDoubleTapAndCancel(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);
    app.mode = PTTModeSmart;
    atomic_store(&app->_audioQueueRunningAtomic, YES);

    // 1. Short tap (< 0.25s) returns to Idle and arms double-tap window
    [app handleTriggerDown];
    EXPECT_EQ_INT(app.state, AppStateHolding);
    // Pin holdStartTime deterministically so cold CI VM latency inside beginSessionWithState: can't flake
    app.holdStartTime = CACurrentMediaTime() - 0.05;
    [app handleTriggerUp];
    EXPECT_EQ_INT(app.state, AppStateIdle);
    EXPECT_TRUE(app.lastShortTapReleaseTime > 0);

    // 2. Immediate second tap (< 0.38s) locks Hands-Free mode
    app.lastShortTapReleaseTime = CACurrentMediaTime() - 0.05;
    [app handleTriggerDown];
    EXPECT_EQ_INT(app.state, AppStateLocked);

    // 3. Esc key via EventTapCallback cancels Hands-Free mode and swallows Esc (returns NULL)
    CGEventRef escDown = CGEventCreateKeyboardEvent(NULL, 53, true);
    CGEventRef res = EventTapCallback(NULL, kCGEventKeyDown, escDown, (__bridge void *)app);
    EXPECT_TRUE(res == NULL);
    CFRelease(escDown);
    EXPECT_TRUE(PumpMainRunLoopUntil(0.5, ^BOOL { return app.state == AppStateIdle; }));

    // 4. Esc key when Idle passes through (returns non-NULL)
    CGEventRef escIdle = CGEventCreateKeyboardEvent(NULL, 53, true);
    CGEventRef resIdle = EventTapCallback(NULL, kCGEventKeyDown, escIdle, (__bridge void *)app);
    EXPECT_TRUE(resIdle == escIdle);
    CFRelease(escIdle);

    // 5. Modifier hold + another key pressed cancels instead of transcribing
    [app handleTriggerDown];
    EXPECT_EQ_INT(app.state, AppStateHolding);
    app.holdStartTime = CACurrentMediaTime() - 1.0; // simulate > 0.25s hold
    atomic_store(&app->_tapOtherKeyPressedDuringHold, YES);
    [app handleTriggerUp];
    EXPECT_EQ_INT(app.state, AppStateIdle);

    DestroyTestApp(app, tmp);
}

static void TestMediaButtonDebounceAgainstJackBounce(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);
    atomic_store(&app->_audioQueueRunningAtomic, YES);

    // First toggle starts Hands-Free recording
    [app handleMediaButtonToggle];
    EXPECT_EQ_INT(app.state, AppStateLocked);
    EXPECT_TRUE(app.lastMediaButtonToggleTime > 0);

    // Immediate bounce (< 350ms, e.g. bumped 3.5mm TRRS plug) MUST be ignored
    app.lastMediaButtonToggleTime = CACurrentMediaTime() - 0.05;
    [app handleMediaButtonToggle];
    EXPECT_EQ_INT(app.state, AppStateLocked);

    // Simulate > 350ms passing -> second intentional press finishes recording
    app.lastMediaButtonToggleTime = CACurrentMediaTime() - 0.5;
    [app handleMediaButtonToggle];
    EXPECT_EQ_INT(app.state, AppStateTranscribing);

    [app cancelRecording];
    DestroyTestApp(app, tmp);
}

static void TestHeadphoneUnplugCoalescingAndNonBlockingMainThread(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    __block _Atomic int restartCalls = 0;
    __block _Atomic BOOL ranOnMainThread = NO;
    dispatch_semaphore_t enteredHook = dispatch_semaphore_create(0);
    dispatch_semaphore_t allowFinish = dispatch_semaphore_create(0);

    app.testRestartAudioHook = ^BOOL {
        atomic_fetch_add(&restartCalls, 1);
        if ([NSThread isMainThread]) {
            atomic_store(&ranOnMainThread, YES);
        }
        dispatch_semaphore_signal(enteredHook);
        // Simulate a slow/stalled coreaudiod teardown during headphone unplug
        dispatch_semaphore_wait(allowFinish, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
        return YES;
    };

    // Fire 8 rapid hot-unplug hardware notifications (loose jack chatter)
    for (int i = 0; i < 8; i++) {
        [app scheduleAudioCaptureRestart:0.05];
    }

    // Wait for coalesced restart to enter hook on audioControlQueue
    EXPECT_EQ_INT(dispatch_semaphore_wait(enteredHook, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC))), 0);

    // While CoreAudio teardown is blocked inside audioControlQueue (up to 2000ms), verify
    // EventTapCallback stays completely responsive without waiting on audioControlQueue!
    CGEventRef keyEv = CGEventCreateKeyboardEvent(NULL, 0, true); // 'a' key
    NSTimeInterval t0 = CACurrentMediaTime();
    CGEventRef tapOut = EventTapCallback(NULL, kCGEventKeyDown, keyEv, (__bridge void *)app);
    double tapElapsedMs = (CACurrentMediaTime() - t0) * 1000.0;
    EXPECT_TRUE(tapOut == keyEv);
    EXPECT_TRUE(tapElapsedMs < 150.0);
    CFRelease(keyEv);

    // Release the stalled CoreAudio hook and drain
    dispatch_semaphore_signal(allowFinish);
    EXPECT_TRUE(PumpMainRunLoopUntil(1.0, ^BOOL {
        return atomic_load(&restartCalls) >= 1;
    }));
    // Give any stray timers a moment to prove only 1 coalesced restart fired
    usleep(80000);
    EXPECT_EQ_INT(atomic_load(&restartCalls), 1);
    EXPECT_FALSE(atomic_load(&ranOnMainThread));

    DestroyTestApp(app, tmp);
}

static void TestHeadphoneUnplugDuringRecordingDefersUntilIdle(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);
    atomic_store(&app->_audioQueueRunningAtomic, YES);

    __block _Atomic int restartCalls = 0;
    __weak typeof(app) weakApp = app;
    app.testRestartAudioHook = ^BOOL {
        atomic_fetch_add(&restartCalls, 1);
        __strong typeof(weakApp) strongApp = weakApp;
        if (strongApp) {
            atomic_store(&strongApp->_audioQueueRunningAtomic, YES);
        }
        return YES;
    };

    // User is actively holding PTT when headphones get bumped out
    app.state = AppStateHolding;
    [app scheduleAudioCaptureRestart:0.02];

    // Wait until scheduleAudioCaptureRestart defers and flags needsAudioRestartWhenIdle
    EXPECT_TRUE(PumpMainRunLoopUntil(1.0, ^BOOL {
        return app.needsAudioRestartWhenIdle;
    }));
    EXPECT_EQ_INT(atomic_load(&restartCalls), 0);

    // Returning to Idle automatically triggers the deferred mic recovery!
    app.state = AppStateIdle;
    EXPECT_TRUE(PumpMainRunLoopUntil(1.5, ^BOOL {
        return atomic_load(&restartCalls) == 1 && !app.needsAudioRestartWhenIdle;
    }));

    DestroyTestApp(app, tmp);
}

static void TestAudioRestartRetryCapOnTransientFailure(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    // Fails twice while device is settling, succeeds on 3rd attempt
    __block _Atomic int attempts = 0;
    app.testRestartAudioHook = ^BOOL {
        int n = atomic_fetch_add(&attempts, 1) + 1;
        return (n >= 3);
    };

    [app scheduleAudioCaptureRestart:0.01];
    EXPECT_TRUE(PumpMainRunLoopUntil(1.5, ^BOOL {
        return atomic_load(&attempts) == 3;
    }));
    usleep(80000);
    EXPECT_EQ_INT(atomic_load(&attempts), 3);

    // Permanent failure caps cleanly at 1 initial + 3 retries = 4 attempts
    atomic_store(&attempts, 0);
    app.audioRestartRetryCount = 0;
    app.testRestartAudioHook = ^BOOL {
        atomic_fetch_add(&attempts, 1);
        return NO;
    };

    [app scheduleAudioCaptureRestart:0.01];
    EXPECT_TRUE(PumpMainRunLoopUntil(1.5, ^BOOL {
        return atomic_load(&attempts) == 4;
    }));
    usleep(100000);
    EXPECT_EQ_INT(atomic_load(&attempts), 4);

    DestroyTestApp(app, tmp);
}

static void TestEventTapTimeoutCircuitBreakerAndNXSysdefinedPassThrough(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    // 1. Timeout resets stuck trigger key state and increments burst counter
    atomic_store(&app->_tapTriggerKeyIsDown, YES);
    atomic_store(&app->_tapOtherKeyPressedDuringHold, YES);
    EventTapCallback(NULL, kCGEventTapDisabledByTimeout, NULL, (__bridge void *)app);
    EXPECT_FALSE(atomic_load(&app->_tapTriggerKeyIsDown));
    EXPECT_FALSE(atomic_load(&app->_tapOtherKeyPressedDuringHold));
    EXPECT_EQ_INT(atomic_load(&app->_tapTimeoutBurstCount), 1);

    // 2. Burst of 4 timeouts within 10s trips circuit breaker (count reaches 4)
    EventTapCallback(NULL, kCGEventTapDisabledByTimeout, NULL, (__bridge void *)app);
    EventTapCallback(NULL, kCGEventTapDisabledByTimeout, NULL, (__bridge void *)app);
    EventTapCallback(NULL, kCGEventTapDisabledByTimeout, NULL, (__bridge void *)app);
    EXPECT_EQ_INT(atomic_load(&app->_tapTimeoutBurstCount), 4);

    // 3. NX_SYSDEFINED when captureMediaButton == NO passes through immediately without crashing
    app.captureMediaButton = NO;
    CGEventRef dummy = CGEventCreate(NULL);
    CGEventRef out = EventTapCallback(NULL, (CGEventType)NX_SYSDEFINED, dummy, (__bridge void *)app);
    EXPECT_TRUE(out == dummy);
    CFRelease(dummy);

    DestroyTestApp(app, tmp);
}

// =============================================================================
// 4. Config, Mocked HTTP (Whisper / Decision Router / LLM) & Routing Tests
// =============================================================================

static void TestPipelineConfigPersistenceAndToggles(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    NSDictionary *cfg = [app loadPipelineConfig];
    EXPECT_TRUE([cfg isKindOfClass:[NSDictionary class]]);
    EXPECT_FALSE([app isLLMRefinementEnabled]);
    EXPECT_FALSE([app isDecisionRouterEnabled]);

    [app toggleLLMRefinement:nil];
    EXPECT_TRUE([app isLLMRefinementEnabled]);

    [app toggleDecisionRouter:nil];
    EXPECT_TRUE([app isDecisionRouterEnabled]);

    // Reload from temp config.json on disk and confirm persisted
    NSDictionary *reloaded = [app loadPipelineConfig];
    EXPECT_TRUE([reloaded[@"llm"][@"enabled"] boolValue]);
    EXPECT_TRUE([reloaded[@"decision_router"][@"enabled"] boolValue]);

    DestroyTestApp(app, tmp);
}

static void TestWhisperHTTPMultipartAndSegmentParsing(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);
    app.testURLSession = CreateMockURLSession();

    __block BOOL sawMultipart = NO;
    __block BOOL sawVerboseFormat = NO;
    SetMockHTTPHandler(^NSData *(NSURLRequest *req, NSData *body, NSInteger *status, NSError **err) {
        NSString *ct = [req valueForHTTPHeaderField:@"Content-Type"] ?: @"";
        sawMultipart = [ct hasPrefix:@"multipart/form-data; boundary="];
        NSString *bodyStr = [[NSString alloc] initWithData:body encoding:NSISOLatin1StringEncoding] ?: @"";
        sawVerboseFormat = [bodyStr containsString:@"verbose_json"];
        NSString *resp = @"{\"text\":\"  Hello [cough] world! \",\"segments\":[{\"start\":0.0,\"end\":1.2,\"text\":\"Hello\"},{\"start\":1.2,\"end\":2.4,\"text\":\"world!\"}]}";
        return [resp dataUsingEncoding:NSUTF8StringEncoding];
    });

    __block BOOL done = NO;
    __block NSString *gotCleaned = nil;
    __block NSArray *gotSegs = nil;
    NSData *pcm = MakeSinePCM(8000, 440.0, 5000.0);
    [app sendPCMToWhisper:pcm prompt:@"custom vocab" needSegments:YES completion:^(NSString *cleaned, NSArray<NSDictionary *> *segments, double elapsed) {
        gotCleaned = cleaned;
        gotSegs = segments;
        done = YES;
    }];

    EXPECT_TRUE(PumpMainRunLoopUntil(2.0, ^BOOL { return done; }));
    EXPECT_TRUE(sawMultipart);
    EXPECT_TRUE(sawVerboseFormat);
    EXPECT_EQ_STR(gotCleaned, @"Hello world!");
    EXPECT_EQ_INT(gotSegs.count, 2);

    SetMockHTTPHandler(nil);
    DestroyTestApp(app, tmp);
}

static void TestDecisionRouterAndLLMRefinementAndFallback(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);
    app.testURLSession = CreateMockURLSession();

    // Enable both DR and LLM in pipelineConfig
    NSMutableDictionary *cfg = [[app defaultPipelineConfig] mutableCopy];
    NSMutableDictionary *llm = [cfg[@"llm"] mutableCopy];
    llm[@"enabled"] = @YES;
    llm[@"api_key"] = @"test-secret";
    cfg[@"llm"] = llm;
    NSMutableDictionary *dr = [cfg[@"decision_router"] mutableCopy];
    dr[@"enabled"] = @YES;
    cfg[@"decision_router"] = dr;
    app.pipelineConfig = cfg;

    // Case A: DR says needs_refine=yes, output_action=clipboard, style=code; LLM returns quoted text -> quotes stripped!
    SetMockHTTPHandler(^NSData *(NSURLRequest *req, NSData *body, NSInteger *status, NSError **err) {
        if ([req.URL.path containsString:@"/decide"]) {
            return [@"{\"decisions\":{\"needs_refine\":\"yes\",\"output_action\":\"clipboard\",\"style\":\"code\"}}" dataUsingEncoding:NSUTF8StringEncoding];
        }
        if ([req.URL.path containsString:@"/chat/completions"]) {
            NSString *auth = [req valueForHTTPHeaderField:@"Authorization"] ?: @"";
            if (![auth isEqualToString:@"Bearer test-secret"]) {
                *status = 401;
                return [NSData data];
            }
            return [@"{\"choices\":[{\"message\":{\"content\":\"\\\"git status --short\\\"\"}}]}" dataUsingEncoding:NSUTF8StringEncoding];
        }
        return [NSData data];
    });

    __block BOOL done = NO;
    __block NSString *finalText = nil;
    __block NSString *routeOverride = nil;
    [app runDecisionRouterAndRefinement:@"uh git status dash dash short"
                              activeApp:@"Terminal"
                        focusedEditable:YES
                          audioDuration:2.0
                             completion:^(NSString *ft, NSString *ro, double drMs, double llmMs) {
        finalText = ft;
        routeOverride = ro;
        done = YES;
    }];
    EXPECT_TRUE(PumpMainRunLoopUntil(2.0, ^BOOL { return done; }));
    EXPECT_EQ_STR(finalText, @"git status --short");
    EXPECT_EQ_STR(routeOverride, @"clipboard");

    // Case B: DR endpoint errors + LLM endpoint errors -> falls back cleanly to raw ASR text
    SetMockHTTPHandler(^NSData *(NSURLRequest *req, NSData *body, NSInteger *status, NSError **err) {
        *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
        return nil;
    });
    done = NO;
    finalText = nil;
    routeOverride = nil;
    [app runDecisionRouterAndRefinement:@"this should fall back cleanly"
                              activeApp:@"Notes"
                        focusedEditable:YES
                          audioDuration:2.0
                             completion:^(NSString *ft, NSString *ro, double drMs, double llmMs) {
        finalText = ft;
        routeOverride = ro;
        done = YES;
    }];
    EXPECT_TRUE(PumpMainRunLoopUntil(2.0, ^BOOL { return done; }));
    EXPECT_EQ_STR(finalText, @"this should fall back cleanly");
    EXPECT_TRUE(routeOverride == nil);

    SetMockHTTPHandler(nil);
    DestroyTestApp(app, tmp);
}

static void TestOutputDeliveryRoutingAndTerminalDetection(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    EXPECT_TRUE(IsKnownTerminalBundleID(@"com.apple.Terminal"));
    EXPECT_TRUE(IsKnownTerminalBundleID(@"com.mitchellh.ghostty"));
    EXPECT_TRUE(IsKnownTerminalBundleID(@"com.googlecode.iterm2"));
    EXPECT_FALSE(IsKnownTerminalBundleID(@"com.apple.Safari"));
    EXPECT_FALSE(IsKnownTerminalBundleID(@""));

    __block NSString *lastEmitted = nil;
    __block BOOL lastPasted = NO;
    __block NSString *lastStatus = nil;
    app.testDeliverTextHook = ^(NSString *text, BOOL shouldPaste, NSString *statusTag) {
        lastEmitted = text;
        lastPasted = shouldPaste;
        lastStatus = statusTag;
    };

    // Smart Auto + focused editable + trailing space -> Paste with trailing space
    app.outputMode = OutputModeSmartAuto;
    app.addTrailingSpace = YES;
    [app deliverFinalText:@"hello" focusedEditable:YES routeOverride:nil onEmitted:nil];
    EXPECT_TRUE(lastPasted);
    EXPECT_EQ_STR(lastEmitted, @"hello ");
    EXPECT_EQ_STR(lastStatus, @"Pasted");

    // Smart Auto + unfocused -> Clipboard without trailing space
    [app deliverFinalText:@"hello" focusedEditable:NO routeOverride:nil onEmitted:nil];
    EXPECT_FALSE(lastPasted);
    EXPECT_EQ_STR(lastEmitted, @"hello");
    EXPECT_EQ_STR(lastStatus, @"Copied (No Text Focus)");

    // Decision Router override -> clipboard even when Always Paste is set
    app.outputMode = OutputModeAlwaysPaste;
    [app deliverFinalText:@"hello" focusedEditable:YES routeOverride:@"clipboard" onEmitted:nil];
    EXPECT_FALSE(lastPasted);
    EXPECT_EQ_STR(lastStatus, @"Copied (DR)");

    // Decision Router override -> paste even when Clipboard Only is set
    app.outputMode = OutputModeClipboardOnly;
    [app deliverFinalText:@"hello" focusedEditable:NO routeOverride:@"paste" onEmitted:nil];
    EXPECT_TRUE(lastPasted);
    EXPECT_EQ_STR(lastStatus, @"Pasted (DR)");

    DestroyTestApp(app, tmp);
}

// =============================================================================
// 5. AudioInputCallback, Streaming Commits, Finalization & UI/Menu Tests
// =============================================================================

static void TestAudioInputCallbackAmbientFloorCaptureAndErrorRecovery(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    // Fake non-NULL AudioQueueRef sentinel (never passed to real CoreAudio thanks to hook)
    AudioQueueRef fakeAQ = (AudioQueueRef)(uintptr_t)0x1234;
    [app.audioLock lock];
    app->_audioQueue = fakeAQ;
    app->_audioQueueRunning = YES;
    atomic_store(&app->_audioQueueRunningAtomic, YES);
    app->_ambientNoiseFloor = 0.0f;
    [app.audioLock unlock];

    __block _Atomic int enqueueCount = 0;
    __block OSStatus nextEnqueueStatus = noErr;
    app.testEnqueueBufferHook = ^OSStatus(AudioQueueRef inAQ, AudioQueueBufferRef inBuf) {
        atomic_fetch_add(&enqueueCount, 1);
        return nextEnqueueStatus;
    };

    // Feed 15 idle 50ms chunks (800 samples each) so qsort(CompareFloats) computes 30th-percentile floor
    NSData *quietChunk = MakeSinePCM(800, 300.0, 600.0); // RMS ~0.013
    AudioQueueBuffer quietBuf = {
        .mAudioDataBytesCapacity = (UInt32)quietChunk.length,
        .mAudioData = (void *)quietChunk.bytes,
        .mAudioDataByteSize = (UInt32)quietChunk.length
    };

    for (int i = 0; i < 15; i++) {
        AudioInputCallback((__bridge void *)app, fakeAQ, &quietBuf, NULL, 800, NULL);
    }
    EXPECT_EQ_INT(atomic_load(&enqueueCount), 15);
    EXPECT_EQ_INT(app->_ringTotalSamples, 15ULL * 800ULL);
    EXPECT_TRUE(app->_ambientNoiseFloor > 0.005f && app->_ambientNoiseFloor < 0.03f);

    // Now simulate active capture session with loud speech + LiveOSDView meter update
    app.osdView = [[LiveOSDView alloc] initWithFrame:NSMakeRect(0, 0, 320, 42)];
    app.state = AppStateHolding;
    [app.audioLock lock];
    app->_isCapturingSession = YES;
    app->_capturePeakRMS = 0.0f;
    app->_captureLastSpeechSample = 0;
    [app.audioLock unlock];

    NSData *loudChunk = MakeSinePCM(800, 900.0, 14000.0); // RMS ~0.30
    AudioQueueBuffer loudBuf = {
        .mAudioDataBytesCapacity = (UInt32)loudChunk.length,
        .mAudioData = (void *)loudChunk.bytes,
        .mAudioDataByteSize = (UInt32)loudChunk.length
    };
    AudioInputCallback((__bridge void *)app, fakeAQ, &loudBuf, NULL, 800, NULL);

    EXPECT_TRUE(app->_capturePeakRMS > 0.20f);
    EXPECT_EQ_INT(app->_captureLastSpeechSample, 16ULL * 800ULL);
    EXPECT_TRUE(PumpMainRunLoopUntil(0.5, ^BOOL {
        return app.osdView.aboveGate && app.osdView.audioLevel > 0.5;
    }));

    // Simulate AudioQueueEnqueueBuffer failure (e.g., headphones unplugged mid-stream)
    __block _Atomic int recoveryTriggered = 0;
    app.state = AppStateIdle;
    app.testRestartAudioHook = ^BOOL {
        atomic_fetch_add(&recoveryTriggered, 1);
        return YES;
    };
    nextEnqueueStatus = kAudioQueueErr_InvalidRunState;
    AudioInputCallback((__bridge void *)app, fakeAQ, &loudBuf, NULL, 800, NULL);

    EXPECT_FALSE(atomic_load(&app->_audioQueueRunningAtomic));
    EXPECT_TRUE(PumpMainRunLoopUntil(1.5, ^BOOL {
        return atomic_load(&recoveryTriggered) == 1;
    }));

    [app.audioLock lock];
    app->_audioQueue = NULL;
    [app.audioLock unlock];
    DestroyTestApp(app, tmp);
}

static void TestStreamingPassPauseCommitAndSegmentCommit(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);
    app.testURLSession = CreateMockURLSession();
    atomic_store(&app->_audioQueueRunningAtomic, YES);
    app.gatePresetIndex = 2; // Fixed 0.025 threshold

    // Trigger A: >= 1.2s tail with >= 400ms trailing silence -> commits to committedText
    NSData *speech = MakeSinePCM(16000, 700.0, 12000.0); // 1.0s loud speech
    NSData *silence = [NSMutableData dataWithLength:12800 * sizeof(int16_t)]; // 0.8s silence
    AppendSamplesToRing(app, (const int16_t *)speech.bytes, 16000);
    AppendSamplesToRing(app, (const int16_t *)silence.bytes, 12800);

    app.state = AppStateLocked;
    app.sessionGen = 1;
    [app.audioLock lock];
    app->_isCapturingSession = YES;
    app->_captureStartSample = 0;
    app->_committedSample = 0;
    app->_captureLastSpeechSample = 16000;
    app->_capturePeakRMS = 0.25f;
    [app.audioLock unlock];

    SetMockHTTPHandler(^NSData *(NSURLRequest *req, NSData *body, NSInteger *status, NSError **err) {
        return [@"{\"text\":\"First sentence done.\"}" dataUsingEncoding:NSUTF8StringEncoding];
    });

    [app runStreamingPass];
    EXPECT_TRUE(PumpMainRunLoopUntil(2.0, ^BOOL { return !app.streamPassInFlight && app.committedText.length > 0; }));
    EXPECT_EQ_STR(app.committedText, @"First sentence done.");
    EXPECT_EQ_STR(app.liveTailText, @"");
    EXPECT_TRUE(app->_committedSample > 0);

    // Trigger B: Long continuous speech (>= 8.0s) with verbose_json multi-segment commit
    uint64_t newStart = app->_ringTotalSamples;
    NSData *longSpeech = MakeSinePCM(16000 * 9, 650.0, 11000.0); // 9.0s continuous speech
    AppendSamplesToRing(app, (const int16_t *)longSpeech.bytes, 16000 * 9);
    [app.audioLock lock];
    app->_committedSample = newStart;
    app->_captureLastSpeechSample = app->_ringTotalSamples; // no trailing silence -> Trigger B
    app->_capturePeakRMS = 0.25f;
    [app.audioLock unlock];
    app.lastStreamPassEndSample = 0;

    SetMockHTTPHandler(^NSData *(NSURLRequest *req, NSData *body, NSInteger *status, NSError **err) {
        NSString *json = @"{\"text\":\"Part one part two still talking\",\"segments\":["
                          "{\"start\":0.0,\"end\":3.5,\"text\":\"Part one\"},"
                          "{\"start\":3.5,\"end\":6.0,\"text\":\"part two\"},"
                          "{\"start\":6.0,\"end\":9.0,\"text\":\"still talking\"}]}";
        return [json dataUsingEncoding:NSUTF8StringEncoding];
    });

    [app runStreamingPass];
    EXPECT_TRUE(PumpMainRunLoopUntil(2.0, ^BOOL { return !app.streamPassInFlight && app.liveTailText.length > 0; }));
    EXPECT_EQ_STR(app.committedText, @"First sentence done. Part one part two");
    EXPECT_EQ_STR(app.liveTailText, @"still talking");
    EXPECT_EQ_STR([app assembledTranscript], @"First sentence done. Part one part two still talking");
    EXPECT_TRUE(app->_committedSample > newStart);

    SetMockHTTPHandler(nil);
    DestroyTestApp(app, tmp);
}

static void TestEndToEndPostRollFinalizeFastPathDiscardAndMicDrop(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);
    app.testURLSession = CreateMockURLSession();
    app.testFrontAppNameOverride = @"Terminal";
    app.testFrontAppBundleIDOverride = @"com.apple.Terminal";
    app.gatePresetIndex = 2; // 0.025

    // Keep post-roll short in temp config so test runs fast
    NSMutableDictionary *cfg = [[app defaultPipelineConfig] mutableCopy];
    cfg[@"post_roll_min_ms"] = @100;
    cfg[@"post_roll_silence_ms"] = @150;
    cfg[@"post_roll_max_ms"] = @400;
    [app savePipelineConfig:cfg];

    __block NSString *deliveredText = nil;
    __block BOOL deliveredPaste = NO;
    app.testDeliverTextHook = ^(NSString *text, BOOL shouldPaste, NSString *statusTag) {
        deliveredText = text;
        deliveredPaste = shouldPaste;
    };

    // Case 1: Full tail transcription + latency.log written
    NSData *speech = MakeSinePCM(12000, 750.0, 12000.0); // 0.75s speech
    NSData *sil = [NSMutableData dataWithLength:4800 * sizeof(int16_t)]; // 0.3s silence
    AppendSamplesToRing(app, (const int16_t *)speech.bytes, 12000);
    AppendSamplesToRing(app, (const int16_t *)sil.bytes, 4800);

    atomic_store(&app->_audioQueueRunningAtomic, YES);
    app.state = AppStateHolding;
    app.sessionGen = 10;
    [app.audioLock lock];
    app->_isCapturingSession = YES;
    app->_captureStartSample = 0;
    app->_committedSample = 0;
    app->_captureLastSpeechSample = 12000;
    app->_capturePeakRMS = 0.25f;
    [app.audioLock unlock];

    __block _Atomic int whisperHits = 0;
    SetMockHTTPHandler(^NSData *(NSURLRequest *req, NSData *body, NSInteger *status, NSError **err) {
        atomic_fetch_add(&whisperHits, 1);
        return [@"{\"text\":\"Ship it to production.\"}" dataUsingEncoding:NSUTF8StringEncoding];
    });

    [app finishRecordingAndTranscribe];
    EXPECT_TRUE(PumpMainRunLoopUntil(2.0, ^BOOL { return app.state == AppStateIdle && deliveredText != nil; }));
    EXPECT_EQ_INT(atomic_load(&whisperHits), 1);
    EXPECT_EQ_STR(deliveredText, @"Ship it to production.");
    EXPECT_TRUE(deliveredPaste);

    NSString *logContents = [NSString stringWithContentsOfFile:[app latencyLogPath] encoding:NSUTF8StringEncoding error:nil];
    EXPECT_TRUE([logContents containsString:@"Ship it to production."]);
    EXPECT_TRUE([logContents containsString:@"out=Pasted (Terminal)"]);

    // Case 2: Fast path (speechAlreadyCovered) + headphone mic drops during post-roll (exits immediately)
    deliveredText = nil;
    atomic_store(&whisperHits, 0);
    atomic_store(&app->_audioQueueRunningAtomic, NO); // simulates mic drop mid-utterance!
    app.state = AppStateHolding;
    app.sessionGen = 11;
    app.committedText = @"Already streamed cleanly";
    app.liveTailText = @"";
    app.lastStreamPassEndSample = 16000;
    [app.audioLock lock];
    app->_isCapturingSession = YES;
    app->_captureLastSpeechSample = 12000;
    app->_capturePeakRMS = 0.25f;
    [app.audioLock unlock];

    [app finishRecordingAndTranscribe];
    EXPECT_TRUE(PumpMainRunLoopUntil(1.5, ^BOOL { return app.state == AppStateIdle && deliveredText != nil; }));
    EXPECT_EQ_INT(atomic_load(&whisperHits), 0); // zero extra Whisper call on fast path!
    EXPECT_EQ_STR(deliveredText, @"Already streamed cleanly");

    // Case 3: Decision Router returns "discard" -> nothing delivered, status = Discarded (DR)
    NSMutableDictionary *drCfg = [cfg[@"decision_router"] mutableCopy];
    drCfg[@"enabled"] = @YES;
    cfg[@"decision_router"] = drCfg;
    [app savePipelineConfig:cfg];

    SetMockHTTPHandler(^NSData *(NSURLRequest *req, NSData *body, NSInteger *status, NSError **err) {
        return [@"{\"decisions\":{\"needs_refine\":\"no\",\"output_action\":\"discard\",\"style\":\"prose\"}}" dataUsingEncoding:NSUTF8StringEncoding];
    });

    deliveredText = nil;
    app.state = AppStateHolding;
    app.sessionGen = 12;
    app.committedText = @"accidental cough";
    app.liveTailText = @"";
    app.lastStreamPassEndSample = 16000;
    [app finishRecordingAndTranscribe];
    EXPECT_TRUE(PumpMainRunLoopUntil(1.5, ^BOOL { return app.state == AppStateIdle && [app.lastOutputStatus isEqualToString:@"Discarded (DR)"]; }));
    EXPECT_TRUE(deliveredText == nil);

    // Case 4: Empty / sub-gate audio -> returns cleanly to Idle without emitting
    app.state = AppStateHolding;
    app.sessionGen = 13;
    app.committedText = @"";
    app.liveTailText = @"";
    app.lastStreamPassEndSample = 0;
    [app.audioLock lock];
    app->_capturePeakRMS = 0.001f; // below gate
    [app.audioLock unlock];
    [app finishRecordingAndTranscribe];
    EXPECT_TRUE(PumpMainRunLoopUntil(1.5, ^BOOL { return app.state == AppStateIdle; }));
    EXPECT_TRUE(deliveredText == nil);

    SetMockHTTPHandler(nil);
    DestroyTestApp(app, tmp);
}

static void TestEventTapModifierNonModifierAndMediaKeyPaths(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);
    atomic_store(&app->_audioQueueRunningAtomic, YES);
    app.mode = PTTModeHoldOnly;

    // 1. Modifier hotkey (Right Option = keyCode 61, mask Alternate)
    app.hotkeyIndex = 0;
    CGEventRef modDown = CGEventCreate(NULL);
    CGEventSetType(modDown, kCGEventFlagsChanged);
    CGEventSetIntegerValueField(modDown, kCGKeyboardEventKeycode, 61);
    CGEventSetFlags(modDown, kCGEventFlagMaskAlternate);
    EXPECT_TRUE(EventTapCallback(NULL, kCGEventFlagsChanged, modDown, (__bridge void *)app) == modDown);
    EXPECT_TRUE(atomic_load(&app->_tapTriggerKeyIsDown));
    EXPECT_TRUE(PumpMainRunLoopUntil(0.5, ^BOOL { return app.state == AppStateHolding; }));

    // Pressing another key while holding modifier marks chord flag
    CGEventRef otherKey = CGEventCreateKeyboardEvent(NULL, 12, true); // 'q'
    EventTapCallback(NULL, kCGEventKeyDown, otherKey, (__bridge void *)app);
    EXPECT_TRUE(atomic_load(&app->_tapOtherKeyPressedDuringHold));
    CFRelease(otherKey);

    // Releasing modifier dispatches handleTriggerUp (cancels because chord flag was set)
    CGEventRef modUp = CGEventCreate(NULL);
    CGEventSetType(modUp, kCGEventFlagsChanged);
    CGEventSetIntegerValueField(modUp, kCGKeyboardEventKeycode, 61);
    CGEventSetFlags(modUp, 0);
    EXPECT_TRUE(EventTapCallback(NULL, kCGEventFlagsChanged, modUp, (__bridge void *)app) == modUp);
    EXPECT_FALSE(atomic_load(&app->_tapTriggerKeyIsDown));
    EXPECT_TRUE(PumpMainRunLoopUntil(0.5, ^BOOL { return app.state == AppStateIdle; }));
    CFRelease(modDown);
    CFRelease(modUp);

    // 2. Non-modifier hotkey (F5 = keyCode 96, index 3) in ToggleOnly mode -> swallowed (returns NULL)
    app.hotkeyIndex = 3;
    app.mode = PTTModeToggleOnly;
    CGEventRef f5Down = CGEventCreateKeyboardEvent(NULL, 96, true);
    EXPECT_TRUE(EventTapCallback(NULL, kCGEventKeyDown, f5Down, (__bridge void *)app) == NULL);
    EXPECT_TRUE(atomic_load(&app->_tapTriggerKeyIsDown));
    EXPECT_TRUE(PumpMainRunLoopUntil(0.5, ^BOOL { return app.state == AppStateLocked; }));

    // Autorepeat F5 keyDown is also swallowed without re-triggering
    CGEventSetIntegerValueField(f5Down, kCGKeyboardEventAutorepeat, 1);
    EXPECT_TRUE(EventTapCallback(NULL, kCGEventKeyDown, f5Down, (__bridge void *)app) == NULL);

    CGEventRef f5Up = CGEventCreateKeyboardEvent(NULL, 96, false);
    EXPECT_TRUE(EventTapCallback(NULL, kCGEventKeyUp, f5Up, (__bridge void *)app) == NULL);
    EXPECT_FALSE(atomic_load(&app->_tapTriggerKeyIsDown));
    CFRelease(f5Down);
    CFRelease(f5Up);
    [app cancelRecording];

    // 3. NX_SYSDEFINED with captureMediaButton == YES: Play key swallowed, Volume key passes through
    app.captureMediaButton = YES;
    NSInteger playDownData1 = ((NSInteger)NX_KEYTYPE_PLAY << 16) | (0x0A << 8);
    NSEvent *playEv = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                         location:NSZeroPoint
                                    modifierFlags:0
                                        timestamp:0
                                     windowNumber:0
                                          context:nil
                                          subtype:8
                                            data1:playDownData1
                                            data2:-1];
    CGEventRef playCG = playEv.CGEvent;
    if (playCG) {
        EXPECT_TRUE(EventTapCallback(NULL, (CGEventType)NX_SYSDEFINED, playCG, (__bridge void *)app) == NULL);
        EXPECT_TRUE(PumpMainRunLoopUntil(0.5, ^BOOL { return app.state == AppStateLocked; }));
        [app cancelRecording];
    }

    NSInteger volUpData1 = ((NSInteger)NX_KEYTYPE_SOUND_UP << 16) | (0x0A << 8);
    NSEvent *volEv = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                        location:NSZeroPoint
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:0
                                         context:nil
                                         subtype:8
                                           data1:volUpData1
                                           data2:-1];
    CGEventRef volCG = volEv.CGEvent;
    if (volCG) {
        EXPECT_TRUE(EventTapCallback(NULL, (CGEventType)NX_SYSDEFINED, volCG, (__bridge void *)app) == volCG);
    }

    DestroyTestApp(app, tmp);
}

static void TestMenuPopulationPreferencesModelsAndOSDRendering(void) {
    NSString *tmp = nil;
    VoicePTTApp *app = CreateTestApp(&tmp);

    // 1. Model & VAD discovery in temp baseDir
    NSString *modelsDir = [tmp stringByAppendingPathComponent:@"models"];
    [[NSFileManager defaultManager] createDirectoryAtPath:modelsDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSData data] writeToFile:[modelsDir stringByAppendingPathComponent:@"ggml-small.en-q5_1.bin"] atomically:YES];
    [[NSData data] writeToFile:[modelsDir stringByAppendingPathComponent:@"ggml-base.en-q5_1.bin"] atomically:YES];
    [[NSData data] writeToFile:[modelsDir stringByAppendingPathComponent:@"ggml-silero-v6.2.0.bin"] atomically:YES];
    app.baseDir = tmp;

    NSArray<NSString *> *models = [app availableModels];
    EXPECT_EQ_INT(models.count, 2); // silero excluded
    EXPECT_EQ_STR(models[0].lastPathComponent, @"ggml-base.en-q5_1.bin");
    EXPECT_EQ_STR(models[1].lastPathComponent, @"ggml-small.en-q5_1.bin");
    EXPECT_EQ_STR([app vadModelPath].lastPathComponent, @"ggml-silero-v6.2.0.bin");
    app.selectedModelPath = models[1];

    // 2. selectedMicUID thread-safe setter/snapshot & ensureContinuousMicReady branches
    app.selectedMicUID = @"USB-Headset-UID";
    EXPECT_EQ_STR([app selectedMicUIDSnapshot], @"USB-Headset-UID");

    app.micArmed = NO;
    EXPECT_FALSE([app ensureContinuousMicReady]);
    app.micArmed = YES;
    atomic_store(&app->_audioQueueRunningAtomic, NO);
    app.testRestartAudioHook = ^BOOL { return YES; };
    EXPECT_FALSE([app ensureContinuousMicReady]); // schedules async reconnect instead of blocking

    // 3. Menu population with cached devices, gain, lastTranscript, and menu actions
    AudioInputDeviceInfo *dev = [AudioInputDeviceInfo new];
    dev.deviceID = 99;
    dev.uid = @"USB-Headset-UID";
    dev.name = @"Test USB Headset";
    [app.audioCacheLock lock];
    app.cachedInputDevices = @[ dev ];
    app.cachedInputGain = 0.50f;
    [app.audioCacheLock unlock];
    app.lastTranscript = @"This is a sufficiently long test transcript to trigger menu preview truncation cleanly.";
    app.lastOutputStatus = @"Pasted";
    app.lastLatencySec = 0.85;
    atomic_store(&app->_audioQueueRunningAtomic, YES);

    NSMenu *menu = [NSMenu new];
    [app populateMenu:menu];
    EXPECT_TRUE(menu.itemArray.count >= 15);
    // Find Mic Input Gain title reflecting cached 50%
    BOOL foundGain50 = NO;
    BOOL foundHeadset = NO;
    for (NSMenuItem *it in menu.itemArray) {
        if ([it.title containsString:@"Mic Input Gain (50%)"]) foundGain50 = YES;
        if ([it.title isEqualToString:@"Microphone"]) {
            for (NSMenuItem *sub in it.submenu.itemArray) {
                if ([sub.title isEqualToString:@"Test USB Headset"] && sub.state == NSControlStateValueOn) {
                    foundHeadset = YES;
                }
            }
        }
    }
    EXPECT_TRUE(foundGain50);
    EXPECT_TRUE(foundHeadset);

    // Exercise menu action setters safely
    NSMenuItem *tagItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    tagItem.tag = OutputModeClipboardOnly;
    [app selectOutputMode:tagItem];
    EXPECT_EQ_INT(app.outputMode, OutputModeClipboardOnly);

    tagItem.tag = PTTModeToggleOnly;
    [app selectMode:tagItem];
    EXPECT_EQ_INT(app.mode, PTTModeToggleOnly);

    tagItem.tag = 2;
    [app selectHotkey:tagItem];
    EXPECT_EQ_INT(app.hotkeyIndex, 2);

    tagItem.tag = 3;
    [app selectGatePreset:tagItem];
    EXPECT_EQ_INT(app.gatePresetIndex, 3);

    BOOL origMedia = app.captureMediaButton;
    [app toggleCaptureMediaButton:nil];
    EXPECT_EQ_INT(app.captureMediaButton, !origMedia);

    BOOL origLive = app.liveCaptionEnabled;
    [app toggleLiveCaption:nil];
    EXPECT_EQ_INT(app.liveCaptionEnabled, !origLive);

    BOOL origPill = app.showPill;
    [app toggleShowPill:nil];
    EXPECT_EQ_INT(app.showPill, !origPill);

    BOOL origSpace = app.addTrailingSpace;
    [app toggleTrailingSpace:nil];
    EXPECT_EQ_INT(app.addTrailingSpace, !origSpace);

    [app toggleMicArmed:nil];
    EXPECT_FALSE(app.micArmed);
    [app toggleMicArmed:nil];
    EXPECT_TRUE(app.micArmed);

    // 4. LiveOSDView offscreen drawRect: rendering (header+meter and caption modes)
    LiveOSDView *osd = [[LiveOSDView alloc] initWithFrame:NSMakeRect(0, 0, 560, 100)];
    osd.headerText = @"Listening…";
    osd.captionText = @"Testing live caption rendering";
    osd.dotColor = [NSColor systemRedColor];
    osd.showMeter = YES;
    osd.audioLevel = 0.75;
    osd.aboveGate = YES;
    NSBitmapImageRep *rep = [osd bitmapImageRepForCachingDisplayInRect:osd.bounds];
    EXPECT_TRUE(rep != nil);
    [osd cacheDisplayInRect:osd.bounds toBitmapImageRep:rep];

    osd.captionText = @"";
    osd.aboveGate = NO;
    [osd cacheDisplayInRect:osd.bounds toBitmapImageRep:rep];

    DestroyTestApp(app, tmp);
}

// =============================================================================
// Entry Point
// =============================================================================
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        printf("Running VoicePTT test suite...\n\n");

        RunTest("BuildWAVData header & 450ms silence pad", TestBuildWAVDataHeaderAndSilencePad);
        RunTest("High-pass filter removes DC & preserves voice", TestHighPassFilterRemovesDCAndPreservesVoice);
        RunTest("Noise gate & silence trim", TestNoiseGateAndTrim);
        RunTest("Ring buffer wraparound & horizon clamping", TestRingBufferWraparoundAndClamping);
        RunTest("Adaptive & fixed noise gate thresholds", TestAdaptiveGateThreshold);
        RunTest("Transcript sanitization & repetition loop collapse", TestSanitizeTranscriptAndRepetitionLoops);
        RunTest("Chunk prefix/suffix dedupe & streaming prompt", TestJoinTranscriptPrefixAndStreamingPrompt);
        RunTest("Smart PTT mode hold, double-tap lock, Esc & chord cancel", TestSmartModeHoldDoubleTapAndCancel);
        RunTest("Media button 350ms debounce against jack bounce", TestMediaButtonDebounceAgainstJackBounce);
        RunTest("Headphone unplug burst coalescing & non-blocking main/event tap", TestHeadphoneUnplugCoalescingAndNonBlockingMainThread);
        RunTest("Headphone unplug mid-recording defers restart until Idle", TestHeadphoneUnplugDuringRecordingDefersUntilIdle);
        RunTest("Audio restart retry cap on transient & permanent failures", TestAudioRestartRetryCapOnTransientFailure);
        RunTest("EventTap timeout circuit breaker & NX_SYSDEFINED pass-through", TestEventTapTimeoutCircuitBreakerAndNXSysdefinedPassThrough);
        RunTest("Pipeline config persistence & toggles", TestPipelineConfigPersistenceAndToggles);
        RunTest("Whisper multipart HTTP upload & verbose_json parsing", TestWhisperHTTPMultipartAndSegmentParsing);
        RunTest("Decision Router + OpenAI LLM refinement & error fallback", TestDecisionRouterAndLLMRefinementAndFallback);
        RunTest("Output delivery routing & terminal bundle detection", TestOutputDeliveryRoutingAndTerminalDetection);
        RunTest("AudioInputCallback ambient floor, capture meter & error recovery", TestAudioInputCallbackAmbientFloorCaptureAndErrorRecovery);
        RunTest("Incremental streaming pause commit & multi-segment commit", TestStreamingPassPauseCommitAndSegmentCommit);
        RunTest("End-to-end post-roll finalize, fast path, DR discard & mic drop", TestEndToEndPostRollFinalizeFastPathDiscardAndMicDrop);
        RunTest("EventTap modifier, non-modifier F5 & NX_SYSDEFINED media key paths", TestEventTapModifierNonModifierAndMediaKeyPaths);
        RunTest("Menu population, model/VAD discovery, prefs & OSD rendering", TestMenuPopulationPreferencesModelsAndOSDRendering);

        printf("\nSummary: %d/%d passed", gTestsPassed, gTestsRun);
        if (gTestsFailed > 0) {
            printf(" (%d FAILED)\n", gTestsFailed);
            return 1;
        }
        printf("\n");
        return 0;
    }
}
