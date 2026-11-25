#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <string.h>

// 改成 zh-Hans / en-US 等即可切换识别语言；iOS 16+ 大多数语言支持端侧识别。
static NSString * const KDLocaleIdentifier = @"zh-CN";
static BOOL const KDOnDeviceOnly = YES;
static double const KDSampleRate = 16000.0;

#define KDLog(fmt, ...) NSLog(@"[KDDictation] " fmt, ##__VA_ARGS__)

static char KDAssociatedEngineKey;
static char KDAssociatedLabelKey;

#pragma mark - Tools

static NSArray<NSString *> *KDCharacters(NSString *string) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    if (!string) return result;
    [string enumerateSubstringsInRange:NSMakeRange(0, string.length)
                               options:NSStringEnumerationByComposedCharacterSequences
                            usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
        [result addObject:substring];
    }];
    return result;
}

static void KDSwizzle(Class cls, SEL originalSelector, SEL swizzledSelector) {
    Method original = class_getInstanceMethod(cls, originalSelector);
    Method swizzled = class_getInstanceMethod(cls, swizzledSelector);
    if (!original || !swizzled) return;
    if (class_addMethod(cls, originalSelector, method_getImplementation(swizzled), method_getTypeEncoding(swizzled))) {
        class_replaceMethod(cls, swizzledSelector, method_getImplementation(original), method_getTypeEncoding(original));
    } else {
        method_exchangeImplementations(original, swizzled);
    }
}

static BOOL KDIsKeyboardExtension(void) {
    NSDictionary *extension = NSBundle.mainBundle.infoDictionary[@"NSExtension"];
    NSString *point = extension[@"NSExtensionPointIdentifier"];
    if ([point isEqualToString:@"com.apple.keyboard-service"]) return YES;
    return [NSBundle.mainBundle.bundlePath containsString:@".appex"];
}

static UIResponder *KDFindFirstResponderInView(UIView *view) {
    if ([view isFirstResponder]) return view;
    for (UIView *subview in view.subviews) {
        UIResponder *found = KDFindFirstResponderInView(subview);
        if (found) return found;
    }
    return nil;
}

static id<UITextInput> KDCurrentTextInput(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window.isKeyWindow) continue;
        UIResponder *responder = KDFindFirstResponderInView(window);
        if ([responder conformsToProtocol:@protocol(UITextInput)]) {
            return (id<UITextInput>)responder;
        }
    }
    return nil;
}

#pragma mark - Weak script handler

@protocol KDMessageTarget <NSObject>
- (void)kd_handleMessageBody:(id)body;
@end

@interface KDWeakScriptHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<KDMessageTarget> target;
@end

@implementation KDWeakScriptHandler
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target kd_handleMessageBody:message.body];
}
@end

#pragma mark - WebAudioCapture (ported from stephancill/ios-keyboard-dictation)

static NSString * const KDWebPage =
    @"<!doctype html><html><body><script>"
    @"const targetRate = 16000;"
    @"const post = m => window.webkit.messageHandlers.capture.postMessage(m);"
    @"const encode = samples => {"
    @"  const bytes = new Uint8Array(samples.buffer, 0, samples.length * 2);"
    @"  let binary = '';"
    @"  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));"
    @"  return btoa(binary);"
    @"};"
    @"let lastHeartbeat = performance.now();"
    @"window.captureHeartbeat = () => { lastHeartbeat = performance.now(); };"
    @"let stopCapture = () => {};"
    @"window.stopCapture = () => stopCapture();"
    @"window.startCapture = async () => {"
    @"  let stopping = false, stream, context, source, processor, sink, watchdog;"
    @"  const audioSession = navigator.audioSession;"
    @"  const previousType = audioSession?.type ?? 'auto';"
    @"  const cleanup = () => {"
    @"    if (stopping) return;"
    @"    stopping = true;"
    @"    clearInterval(watchdog);"
    @"    if (processor) { processor.onaudioprocess = null; processor.disconnect(); }"
    @"    if (source) source.disconnect();"
    @"    if (sink) sink.disconnect();"
    @"    if (stream) stream.getTracks().forEach(t => t.stop());"
    @"    if (context) context.close().catch(() => {});"
    @"    try { if (audioSession) audioSession.type = previousType; } catch (e) {}"
    @"  };"
    @"  const interrupted = reason => { if (!stopping) { cleanup(); post({ type: 'interrupted', reason }); } };"
    @"  stopCapture = cleanup;"
    @"  try {"
    @"    try { if (audioSession) audioSession.type = 'play-and-record'; } catch (e) {}"
    @"    stream = await navigator.mediaDevices.getUserMedia({"
    @"      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }"
    @"    });"
    @"    if (stopping) { stream.getTracks().forEach(t => t.stop()); return; }"
    @"    const track = stream.getAudioTracks()[0];"
    @"    track.onended = () => interrupted('track-ended');"
    @"    context = new AudioContext({ latencyHint: 'interactive' });"
    @"    await context.resume();"
    @"    processor = context.createScriptProcessor(1024, 1, 1);"
    @"    sink = context.createGain();"
    @"    sink.gain.value = 0;"
    @"    processor.connect(sink);"
    @"    sink.connect(context.destination);"
    @"    source = context.createMediaStreamSource(stream);"
    @"    source.connect(processor);"
    @"    context.onstatechange = () => { if (context.state !== 'running') interrupted('context-' + context.state); };"
    @"    if (audioSession) audioSession.onstatechange = () => { if (audioSession.state === 'interrupted') interrupted('audio-session-interrupted'); };"
    @"    lastHeartbeat = performance.now();"
    @"    watchdog = setInterval(() => { if (performance.now() - lastHeartbeat > 3000) interrupted('native-heartbeat-expired'); }, 500);"
    @"    const step = context.sampleRate / targetRate;"
    @"    let position = 0, sum = 0, count = 0;"
    @"    processor.onaudioprocess = event => {"
    @"      const input = event.inputBuffer.getChannelData(0);"
    @"      const output = new Int16Array(Math.ceil(input.length / step) + 1);"
    @"      let written = 0, energy = 0;"
    @"      for (const sample of input) {"
    @"        energy += sample * sample; sum += sample; count += 1; position += 1;"
    @"        if (position >= step) {"
    @"          position -= step;"
    @"          output[written++] = Math.max(-1, Math.min(1, sum / count)) * 32767;"
    @"          sum = 0; count = 0;"
    @"        }"
    @"      }"
    @"      if (written > 0) post({ type: 'audio', data: encode(output.subarray(0, written)), rms: Math.sqrt(energy / input.length) });"
    @"    };"
    @"    post({ type: 'started', sampleRate: context.sampleRate });"
    @"  } catch (error) {"
    @"    if (stopping) return;"
    @"    cleanup();"
    @"    post({ type: 'failed', reason: error.name + ': ' + error.message });"
    @"  }"
    @"};"
    @"post({ type: 'ready' });"
    @"</script></body></html>";

@interface KDWebAudioCapture : NSObject <KDMessageTarget, WKUIDelegate, WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, assign) BOOL isReady;
@property (nonatomic, assign) BOOL isCapturing;
@property (nonatomic, copy) void (^onAudio)(NSData *pcm, float rms);
@property (nonatomic, copy) void (^onEnded)(NSString *reason);
- (void)attachToView:(UIView *)view;
- (void)start;
- (void)stop;
- (void)tearDown;
@end

@implementation KDWebAudioCapture {
    WKWebView *_webView;
    NSTimer *_heartbeat;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
        configuration.allowsInlineMediaPlayback = YES;
        configuration.mediaTypesRequiringUserActionForPlayback = 0;
        configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
        KDWeakScriptHandler *handler = [[KDWeakScriptHandler alloc] init];
        handler.target = self;
        [configuration.userContentController addScriptMessageHandler:handler name:@"capture"];

        _webView = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 1, 1) configuration:configuration];
        _webView.alpha = 0.01;
        _webView.userInteractionEnabled = NO;
        _webView.accessibilityElementsHidden = YES;
        _webView.uiDelegate = self;
        _webView.navigationDelegate = self;
        objc_setAssociatedObject(_webView, @selector(kd_handleMessageBody:), handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

- (void)attachToView:(UIView *)view {
    [view addSubview:_webView];
    [view sendSubviewToBack:_webView];
    [_webView loadHTMLString:KDWebPage baseURL:[NSURL URLWithString:@"https://keyboard-dictation.invalid/"]];
}

- (void)start {
    if (!self.isReady || self.isCapturing) return;
    self.isCapturing = YES;
    __weak typeof(self) weakSelf = self;
    _heartbeat = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf.webView evaluateJavaScript:@"captureHeartbeat(); 0" completionHandler:nil];
    }];
    [_webView evaluateJavaScript:@"startCapture(); 0" completionHandler:^(id result, NSError *error) {
        if (error) [weakSelf finishWithReason:[NSString stringWithFormat:@"start failed: %@", error.localizedDescription]];
    }];
}

- (void)stop {
    if (!self.isCapturing) return;
    [_webView evaluateJavaScript:@"stopCapture(); 0" completionHandler:nil];
    [self finishWithReason:@"stopped"];
}

- (void)tearDown {
    [self stop];
    [_webView stopLoading];
    [_webView.configuration.userContentController removeScriptMessageHandlerForName:@"capture"];
    [_webView removeFromSuperview];
}

- (void)finishWithReason:(NSString *)reason {
    [_heartbeat invalidate];
    _heartbeat = nil;
    if (!self.isCapturing) return;
    self.isCapturing = NO;
    if (self.onEnded) self.onEnded(reason);
}

- (void)kd_handleMessageBody:(id)body {
    if (![body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *message = body;
    NSString *type = message[@"type"];
    if ([type isEqualToString:@"ready"]) {
        self.isReady = YES;
    } else if ([type isEqualToString:@"audio"]) {
        if (!self.isCapturing) return;
        NSData *pcm = [[NSData alloc] initWithBase64EncodedString:message[@"data"] ?: @"" options:0];
        if (pcm.length && self.onAudio) self.onAudio(pcm, [message[@"rms"] floatValue]);
    } else if ([type isEqualToString:@"interrupted"] || [type isEqualToString:@"failed"]) {
        [self finishWithReason:[NSString stringWithFormat:@"%@: %@", type, message[@"reason"] ?: @"unknown"]];
    }
}

- (void)webView:(WKWebView *)webView
requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
initiatedByFrame:(WKFrameInfo *)frame
           type:(WKMediaCaptureType)type
decisionHandler:(void (^)(WKPermissionDecision decision))decisionHandler {
    decisionHandler(type == WKMediaCaptureTypeMicrophone ? WKPermissionDecisionGrant : WKPermissionDecisionDeny);
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    self.isReady = NO;
    [self finishWithReason:@"web content process terminated"];
    [webView loadHTMLString:KDWebPage baseURL:[NSURL URLWithString:@"https://keyboard-dictation.invalid/"]];
}

@end

#pragma mark - Dictation engine

@interface KDDictationEngine : NSObject
- (instancetype)initWithTextSink:(void (^)(NSString *text, NSInteger deleteCount))textSink
                      statusSink:(void (^)(NSString *status))statusSink;
- (void)attachCaptureToView:(UIView *)view;
- (void)toggle;
- (void)start;
- (void)stop;
- (void)tearDown;
@end

@interface KDDictationEngine ()
@property (nonatomic, strong) KDWebAudioCapture *capture;
@property (nonatomic, strong) SFSpeechRecognizer *recognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *request;
@property (nonatomic, strong) SFSpeechRecognitionTask *task;
@property (nonatomic, strong) AVAudioFormat *audioFormat;
@property (nonatomic, copy) NSString *insertedPartial;
@property (nonatomic, assign) NSUInteger capturedSamples;
@property (nonatomic, copy) NSString *speechError;
@property (nonatomic, copy) void (^textSink)(NSString *, NSInteger);
@property (nonatomic, copy) void (^statusSink)(NSString *);
@end

@implementation KDDictationEngine

- (instancetype)initWithTextSink:(void (^)(NSString *, NSInteger))textSink
                      statusSink:(void (^)(NSString *))statusSink {
    self = [super init];
    if (self) {
        _textSink = textSink;
        _statusSink = statusSink;
        _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:KDLocaleIdentifier]];
        _audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                       sampleRate:KDSampleRate
                                                         channels:1
                                                      interleaved:YES];
        _capture = [[KDWebAudioCapture alloc] init];
        __weak typeof(self) weakSelf = self;
        _capture.onAudio = ^(NSData *pcm, float rms) { [weakSelf appendPCM:pcm rms:rms]; };
        _capture.onEnded = ^(NSString *reason) { [weakSelf captureEnded:reason]; };
    }
    return self;
}

- (void)attachCaptureToView:(UIView *)view {
    [self.capture attachToView:view];
}

- (void)toggle {
    self.capture.isCapturing ? [self stop] : [self start];
}

- (void)start {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    if (!info[@"NSMicrophoneUsageDescription"] || !info[@"NSSpeechRecognitionUsageDescription"]) {
        if (self.statusSink) self.statusSink(@"目标 App 缺少麦克风/语音识别权限声明");
        return;
    }
    if (AVAudioSession.sharedInstance.recordPermission != AVAudioSessionRecordPermissionGranted) {
        [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.statusSink) self.statusSink(granted ? @"再次点击开始听写" : @"需要麦克风权限");
            });
        }];
        return;
    }
    if ([SFSpeechRecognizer authorizationStatus] != SFSpeechRecognizerAuthorizationStatusAuthorized) {
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *text = status == SFSpeechRecognizerAuthorizationStatusAuthorized
                    ? @"再次点击开始听写" : @"需要语音识别权限";
                if (self.statusSink) self.statusSink(text);
            });
        }];
        return;
    }
    if (!self.recognizer.isAvailable) {
        if (self.statusSink) self.statusSink(@"语音识别暂不可用");
        return;
    }

    SFSpeechAudioBufferRecognitionRequest *request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    request.shouldReportPartialResults = YES;
    request.addsPunctuation = YES;
    request.requiresOnDeviceRecognition = KDOnDeviceOnly;
    self.request = request;
    self.insertedPartial = @"";
    self.capturedSamples = 0;
    self.speechError = nil;

    __weak typeof(self) weakSelf = self;
    self.task = [self.recognizer recognitionTaskWithRequest:request resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleResult:result error:error];
        });
    }];

    [self.capture start];
    if (self.statusSink) self.statusSink(@"正在连接麦克风…");
}

- (void)stop {
    [self.capture stop];
}

- (void)appendPCM:(NSData *)pcm rms:(float)rms {
    NSUInteger frames = pcm.length / 2;
    if (!frames || !self.request) return;
    self.capturedSamples += frames;
    NSString *level = [@"" stringByPaddingToLength:MIN((NSUInteger)(rms * 20), 10) withString:@"▮" startingAtIndex:0];
    NSString *status = [NSString stringWithFormat:@"%.1fs %@", self.capturedSamples / KDSampleRate, level];
    if (self.speechError) status = [status stringByAppendingFormat:@" · %@", self.speechError];
    if (self.statusSink) self.statusSink(status);

    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.audioFormat frameCapacity:(AVAudioFrameCount)frames];
    buffer.frameLength = (AVAudioFrameCount)frames;
    memcpy(buffer.int16ChannelData[0], pcm.bytes, frames * 2);
    [self.request appendBuffer:buffer];
}

- (void)handleResult:(SFSpeechRecognitionResult *)result error:(NSError *)error {
    if (result) {
        [self replacePartialWith:result.bestTranscription.formattedString ?: @""];
        if (result.isFinal) {
            if (self.insertedPartial.length && self.textSink) self.textSink(@" ", 0);
            [self finishRecognition:@"已插入"];
        }
        return;
    }
    if (error) {
        KDLog(@"recognition error: %@", error.localizedDescription);
        self.speechError = error.localizedDescription;
        if (!self.capture.isCapturing) [self finishRecognition:[NSString stringWithFormat:@"语音识别: %@", self.speechError]];
    }
}

- (void)replacePartialWith:(NSString *)text {
    NSArray<NSString *> *oldCharacters = KDCharacters(self.insertedPartial);
    NSArray<NSString *> *newCharacters = KDCharacters(text);
    NSUInteger common = 0;
    while (common < MIN(oldCharacters.count, newCharacters.count) &&
           [oldCharacters[common] isEqualToString:newCharacters[common]]) common++;
    NSInteger deleteCount = (NSInteger)(oldCharacters.count - common);
    NSArray *insertion = [newCharacters subarrayWithRange:NSMakeRange(common, newCharacters.count - common)];
    NSString *inserted = [insertion componentsJoinedByString:@""];
    if ((deleteCount > 0 || inserted.length) && self.textSink) self.textSink(inserted, deleteCount);
    self.insertedPartial = text;
}

- (void)captureEnded:(NSString *)reason {
    [self.request endAudio];
    if (!self.request) {
        [self finishRecognition:self.speechError ?: @"完成"];
    } else if (![reason isEqualToString:@"stopped"]) {
        if (self.statusSink) self.statusSink(reason);
    }
}

- (void)finishRecognition:(NSString *)status {
    [self.task cancel];
    self.task = nil;
    self.request = nil;
    self.insertedPartial = @"";
    if (self.statusSink) self.statusSink(status);
}

- (void)tearDown {
    [self.capture tearDown];
    [self.task cancel];
    self.task = nil;
    self.request = nil;
}

@end

#pragma mark - Host app mode

@interface KDWindow : UIWindow
@property (nonatomic, weak) UIButton *micButton;
@end

@implementation KDWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UIButton *button = self.micButton;
    return button && !button.hidden && CGRectContainsPoint(button.frame, point);
}
@end

@interface KDHostTweak : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIButton *micButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) KDDictationEngine *engine;
+ (instancetype)shared;
- (void)install;
@end

@implementation KDHostTweak

+ (instancetype)shared {
    static KDHostTweak *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[KDHostTweak alloc] init]; });
    return instance;
}

- (void)install {
    KDWindow *window = [[KDWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.windowLevel = UIWindowLevelAlert + 2;
    window.backgroundColor = UIColor.clearColor;
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = root;
    self.window = window;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(CGRectGetWidth(window.bounds) - 60, 0, 44, 44);
    [button setTitle:@"语" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [[UIColor alloc] initWithWhite:0.0 alpha:0.35];
    button.layer.cornerRadius = 10;
    button.hidden = YES;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 180, 20)];
    label.font = [UIFont systemFontOfSize:11];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [[UIColor alloc] initWithWhite:0.0 alpha:0.35];
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 6;
    label.clipsToBounds = YES;
    label.hidden = YES;

    [root.view addSubview:button];
    [root.view addSubview:label];
    self.micButton = button;
    self.statusLabel = label;
    window.micButton = button;

    __weak typeof(self) weakSelf = self;
    self.engine = [[KDDictationEngine alloc] initWithTextSink:^(NSString *text, NSInteger deleteCount) {
        id<UITextInput> input = KDCurrentTextInput();
        for (NSInteger i = 0; i < deleteCount; i++) [input deleteBackward];
        if (text.length) [input insertText:text];
    } statusSink:^(NSString *status) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.statusLabel.text = status;
        strongSelf.statusLabel.hidden = status.length == 0;
    }];
    [self.engine attachCaptureToView:root.view];
    [button addTarget:self.engine action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(keyboardFrameChanged:)
                                               name:UIKeyboardWillChangeFrameNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(keyboardFrameChanged:)
                                               name:UIKeyboardDidChangeFrameNotification
                                             object:nil];
    window.hidden = NO;
    KDLog(@"host mode installed");
}

- (void)keyboardFrameChanged:(NSNotification *)notification {
    CGRect frame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat top = CGRectGetMinY(frame);
    CGFloat screenHeight = UIScreen.mainScreen.bounds.size.height;
    BOOL visible = top < screenHeight - 1;
    self.micButton.hidden = !visible;
    self.statusLabel.hidden = !visible || self.statusLabel.text.length == 0;
    if (!visible) return;
    CGFloat y = top - 52;
    self.micButton.frame = CGRectMake(CGRectGetWidth(self.window.bounds) - 60, y, 44, 44);
    self.statusLabel.frame = CGRectMake(8, y + 12, 180, 20);
}

@end

#pragma mark - Keyboard extension mode

@interface UIInputViewController (KD)
- (void)kd_viewDidLoad;
- (void)kd_viewWillDisappear:(BOOL)animated;
@end

@implementation UIInputViewController (KD)

- (void)kd_viewDidLoad {
    [self kd_viewDidLoad];
    if (objc_getAssociatedObject(self, &KDAssociatedEngineKey)) return;

    __weak typeof(self) weakSelf = self;
    KDDictationEngine *engine = [[KDDictationEngine alloc] initWithTextSink:^(NSString *text, NSInteger deleteCount) {
        typeof(weakSelf) strongVC = weakSelf;
        if (!strongVC) return;
        for (NSInteger i = 0; i < deleteCount; i++) [strongVC.textDocumentProxy deleteBackward];
        if (text.length) [strongVC.textDocumentProxy insertText:text];
    } statusSink:^(NSString *status) {
        typeof(weakSelf) strongVC = weakSelf;
        UILabel *label = objc_getAssociatedObject(strongVC, &KDAssociatedLabelKey);
        label.text = status;
        label.hidden = status.length == 0;
    }];

    [engine attachCaptureToView:self.view];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(CGRectGetWidth(self.view.bounds) - 52, 6, 44, 36);
    [button setTitle:@"语" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [[UIColor alloc] initWithWhite:0.0 alpha:0.3];
    button.layer.cornerRadius = 8;
    [button addTarget:engine action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, CGRectGetWidth(self.view.bounds) - 68, 20)];
    label.font = [UIFont systemFontOfSize:11];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [[UIColor alloc] initWithWhite:0.0 alpha:0.3];
    label.textAlignment = NSTextAlignmentCenter;
    label.hidden = YES;
    [self.view addSubview:label];

    objc_setAssociatedObject(self, &KDAssociatedEngineKey, engine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &KDAssociatedLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    KDLog(@"keyboard extension mode installed");
}

- (void)kd_viewWillDisappear:(BOOL)animated {
    [self kd_viewWillDisappear:animated];
    KDDictationEngine *engine = objc_getAssociatedObject(self, &KDAssociatedEngineKey);
    [engine stop];
}

@end

@interface KDKeyboardTweak : NSObject
+ (void)install;
@end

@implementation KDKeyboardTweak
+ (void)install {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        KDSwizzle([UIInputViewController class], @selector(viewDidLoad), @selector(kd_viewDidLoad));
        KDSwizzle([UIInputViewController class], @selector(viewWillDisappear:), @selector(kd_viewWillDisappear:));
    });
}
@end

#pragma mark - Entry point (no Substrate / ElleKit dependency)

__attribute__((constructor)) static void KDInitialize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (KDIsKeyboardExtension()) {
            [KDKeyboardTweak install];
        } else {
            [KDHostTweak.shared install];
        }
    });
}
