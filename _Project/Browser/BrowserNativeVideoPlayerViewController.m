#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserNativeVideoAssetLoader.h"

#import <AVFoundation/AVFoundation.h>

static NSString * const kBrowserNativeVideoPlayerLogPrefix = @"[NativeVideoPlayer]";
static NSString * const kBrowserNativePlayerInputLogPrefix = @"[InputTrace][NativePlayer]";

static NSString *BrowserNativePlayerPressTypeString(UIPressType type) {
    switch (type) {
        case UIPressTypeMenu: return @"Menu";
        case UIPressTypePlayPause: return @"PlayPause";
        case UIPressTypeSelect: return @"Select";
        case UIPressTypeUpArrow: return @"Up";
        case UIPressTypeDownArrow: return @"Down";
        case UIPressTypeLeftArrow: return @"Left";
        case UIPressTypeRightArrow: return @"Right";
        default: return [NSString stringWithFormat:@"Type-%ld", (long)type];
    }
}

static NSString *BrowserNativePlayerPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

@interface BrowserNativeVideoPlayerViewController ()

@property (nonatomic, strong) NSURL *videoURL;
@property (nonatomic, copy) NSString *videoTitle;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSHTTPCookie *> *requestCookies;
@property (nonatomic, strong) BrowserNativeVideoAssetLoader *assetLoader;

// Custom fast-forward scanning state (1.0 or 0.0 = normal playback, >1.0 = scanning).
// Scanning is emulated: the player is paused and the playhead advances with periodic
// seeks, so it works without having to buffer the stream at Nx speed.
@property (nonatomic, assign) float scanRate;
@property (nonatomic, strong) UILabel *scanRateLabel;
@property (nonatomic, strong) NSTimer *scanTimer;
@property (nonatomic, assign) NSTimeInterval scanTargetTime;
@property (nonatomic, assign) BOOL scanSeekInProgress;

// Seeks are async: while one is in flight, currentTime is stale. Accumulate
// successive skips on the pending target so rapid scrubbing actually advances.
@property (nonatomic, assign) NSTimeInterval pendingSeekTarget;
@property (nonatomic, assign) BOOL hasPendingSeek;

// Position HUD shown while scrubbing/scanning (AVKit's timeline stays hidden
// because we swallow the touches it would react to).
@property (nonatomic, strong) UIView *positionHUDView;
@property (nonatomic, strong) UILabel *positionHUDLabel;
@property (nonatomic, strong) UIProgressView *positionHUDProgress;
@property (nonatomic, strong) NSTimer *positionHUDHideTimer;

@end

@implementation BrowserNativeVideoPlayerViewController

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"%@ %@", kBrowserNativeVideoPlayerLogPrefix, message);
}

- (instancetype)initWithURL:(NSURL *)URL title:(NSString *)title {
    return [self initWithURL:URL title:title requestHeaders:nil cookies:nil];
}

- (instancetype)initWithURL:(NSURL *)URL
                      title:(NSString *)title
             requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders
                    cookies:(NSArray<NSHTTPCookie *> *)cookies {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _videoURL = URL;
        _videoTitle = [title copy] ?: @"";
        _requestHeaders = [requestHeaders copy] ?: @{};
        _requestCookies = [cookies copy] ?: @[];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.blackColor;
    self.showsPlaybackControls = YES;
    AVPlayerItem *playerItem = nil;
    if (self.requestHeaders.count > 0 || self.requestCookies.count > 0) {
        NSMutableDictionary *assetOptions = [NSMutableDictionary dictionary];
        if (self.requestHeaders.count > 0) {
            assetOptions[@"AVURLAssetHTTPHeaderFieldsKey"] = self.requestHeaders;
            NSString *userAgent = self.requestHeaders[@"User-Agent"];
            if (userAgent.length > 0) {
                assetOptions[@"AVURLAssetHTTPUserAgentKey"] = userAgent;
            }
        }
        if (self.requestCookies.count > 0) {
            assetOptions[@"AVURLAssetHTTPCookiesKey"] = self.requestCookies;
        }
        self.assetLoader = [[BrowserNativeVideoAssetLoader alloc] initWithRequestHeaders:self.requestHeaders cookies:self.requestCookies];
        NSURL *assetURL = [self.assetLoader assetURLForPlaybackURL:self.videoURL];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:assetOptions];
        [self.assetLoader attachToAsset:asset];
        playerItem = [AVPlayerItem playerItemWithAsset:asset];
        [self log:@"using request headers %@ cookies=%lu", self.requestHeaders, (unsigned long)self.requestCookies.count];
    } else {
        playerItem = [AVPlayerItem playerItemWithURL:self.videoURL];
    }
    self.player = [AVPlayer playerWithPlayerItem:playerItem];
    [self log:@"created player url=%@", self.videoURL.absoluteString ?: @""];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemFailedToPlayToEndTime:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:self.player.currentItem];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemNewErrorLogEntry:)
                                                 name:AVPlayerItemNewErrorLogEntryNotification
                                               object:self.player.currentItem];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleFocusUpdate:)
                                                 name:UIFocusDidUpdateNotification
                                               object:nil];

    [self.player.currentItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
    if (@available(tvOS 10.0, *)) {
        [self.player addObserver:self
                      forKeyPath:@"timeControlStatus"
                         options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                         context:NULL];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSLog(@"%@ viewDidAppear", kBrowserNativePlayerInputLogPrefix);
    [self log:@"viewDidAppear play"];
    [self.player play];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    NSLog(@"%@ viewWillDisappear", kBrowserNativePlayerInputLogPrefix);
    [self log:@"viewWillDisappear pause"];
    [self stopScanTimer];
    self.scanRate = 1.0f;
    [self.player pause];
}

- (void)dealloc {
    @try {
        [self.player.currentItem removeObserver:self forKeyPath:@"status"];
    } @catch (__unused NSException *exception) {}
    @try {
        [self.player removeObserver:self forKeyPath:@"timeControlStatus"];
    } @catch (__unused NSException *exception) {}
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)togglePlayback {
    if ([self isScanning]) {
        // Cancel fast-forward and resume normal playback from the current position.
        [self log:@"toggle stop scanning, resume 1x"];
        [self applyScanRate:1.0f];
        return;
    }
    if (self.player.rate > 0.0) {
        [self log:@"toggle pause"];
        [self.player pause];
    } else {
        [self log:@"toggle play"];
        [self.player play];
    }
}

- (BOOL)isScanning {
    return self.scanRate > 1.0f;
}

- (BOOL)isEffectivelyPaused {
    // Paused for real (not our emulated scanning, which also pauses the player).
    return ![self isScanning] && self.player.rate == 0.0f;
}

- (void)applyScanRate:(float)rate {
    BOOL wasScanning = [self isScanning];
    self.scanRate = rate;
    [self log:@"scan rate=%0.1f", rate];
    [self updateScanRateLabel];

    if (rate > 1.0f) {
        if (!wasScanning) {
            NSTimeInterval currentTime = CMTimeGetSeconds(self.player.currentTime);
            self.scanTargetTime = isfinite(currentTime) ? currentTime : 0.0;
            [self.player pause];
        }
        if (self.scanTimer == nil) {
            __weak typeof(self) weakSelf = self;
            self.scanTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
                [weakSelf scanTimerStep];
            }];
        }
        return;
    }

    // Scanning finished: resume normal playback from the virtual playhead.
    [self stopScanTimer];
    if (wasScanning) {
        CMTime seekTime = CMTimeMakeWithSeconds(self.scanTargetTime, NSEC_PER_SEC);
        __weak typeof(self) weakSelf = self;
        [self.player seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(__unused BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.player play];
            });
        }];
    }
}

- (void)stopScanTimer {
    [self.scanTimer invalidate];
    self.scanTimer = nil;
    self.scanSeekInProgress = NO;
}

- (void)scanTimerStep {
    if (self.player.currentItem == nil || ![self isScanning]) {
        return;
    }
    if (self.scanSeekInProgress) {
        return; // Previous seek still loading; don't queue more.
    }

    NSTimeInterval delta = self.scanRate * 0.5; // seconds advanced per 0.5s tick = Nx speed
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    NSTimeInterval target = self.scanTargetTime + delta;
    if (isfinite(duration) && duration > 0.0 && target >= duration - 1.0) {
        // Reached the end of the video: stop scanning just before it.
        self.scanTargetTime = MAX(duration - 1.0, 0.0);
        [self applyScanRate:1.0f];
        return;
    }
    self.scanTargetTime = MAX(target, 0.0);
    [self showPositionHUDForTarget:self.scanTargetTime];

    // Loose tolerance: keyframe-aligned seeks load fast; scanTargetTime keeps the
    // real position so progress never stalls on long keyframe intervals.
    self.scanSeekInProgress = YES;
    CMTime seekTime = CMTimeMakeWithSeconds(self.scanTargetTime, NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    [self.player seekToTime:seekTime
            toleranceBefore:kCMTimePositiveInfinity
             toleranceAfter:kCMTimePositiveInfinity
          completionHandler:^(__unused BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.scanSeekInProgress = NO;
        });
    }];
}

- (void)updateScanRateLabel {
    if (![self isScanning]) {
        self.scanRateLabel.hidden = YES;
        return;
    }
    if (self.scanRateLabel == nil) {
        UILabel *label = [[UILabel alloc] init];
        label.font = [UIFont monospacedDigitSystemFontOfSize:31.0 weight:UIFontWeightSemibold];
        label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        label.layer.cornerRadius = 8.0;
        label.layer.masksToBounds = YES;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentOverlayView addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:self.contentOverlayView.topAnchor constant:60.0],
            [label.trailingAnchor constraintEqualToAnchor:self.contentOverlayView.trailingAnchor constant:-90.0],
        ]];
        self.scanRateLabel = label;
    }
    self.scanRateLabel.text = [NSString stringWithFormat:@"  » %gx  ", self.scanRate];
    self.scanRateLabel.hidden = NO;
}

- (void)handleRightArrowPress {
    if (self.player.currentItem == nil) {
        return;
    }
    // While paused, step forward instead of scanning.
    if (![self isScanning] && self.player.rate == 0.0f) {
        [self skipByInterval:10.0];
        return;
    }
    float nextRate = self.scanRate >= 16.0f ? 32.0f
                   : (self.scanRate >= 8.0f ? 16.0f
                   : (self.scanRate >= 4.0f ? 8.0f
                   : (self.scanRate >= 2.0f ? 4.0f : 2.0f)));
    [self applyScanRate:nextRate];
}

- (void)handleLeftArrowPress {
    if (self.player.currentItem == nil) {
        return;
    }
    if ([self isScanning]) {
        // Step the fast-forward speed back down; below 2x resume normal playback.
        float nextRate = self.scanRate > 16.0f ? 16.0f
                       : (self.scanRate > 8.0f ? 8.0f
                       : (self.scanRate > 4.0f ? 4.0f
                       : (self.scanRate > 2.0f ? 2.0f : 1.0f)));
        [self applyScanRate:nextRate];
        return;
    }
    [self skipByInterval:-10.0];
}

- (void)skipByInterval:(NSTimeInterval)delta {
    if (self.player.currentItem == nil) {
        return;
    }

    NSTimeInterval currentTime;
    if ([self isScanning]) {
        currentTime = self.scanTargetTime;
    } else if (self.hasPendingSeek) {
        currentTime = self.pendingSeekTarget;
    } else {
        currentTime = CMTimeGetSeconds(self.player.currentTime);
    }
    if (!isfinite(currentTime)) {
        currentTime = 0.0;
    }

    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    NSTimeInterval targetTime = currentTime + delta;
    if (isfinite(duration) && duration > 0.0) {
        targetTime = MIN(MAX(targetTime, 0.0), MAX(duration - 0.05, 0.0));
    } else {
        targetTime = MAX(targetTime, 0.0);
    }

    [self log:@"seek delta=%0.3f from=%0.3f to=%0.3f", delta, currentTime, targetTime];
    if ([self isScanning]) {
        // Keep the virtual scan playhead in sync with manual seeks (trackpad scrub).
        self.scanTargetTime = targetTime;
    }
    self.pendingSeekTarget = targetTime;
    self.hasPendingSeek = YES;
    [self showPositionHUDForTarget:targetTime];
    CMTime seekTime = CMTimeMakeWithSeconds(targetTime, NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    [self.player seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            // Only the latest seek clears the pending state; superseded seeks
            // report finished=NO and must not reset the accumulated target.
            if (finished && strongSelf != nil && fabs(strongSelf.pendingSeekTarget - targetTime) < 0.001) {
                strongSelf.hasPendingSeek = NO;
            }
        });
    }];
}

- (void)scrubByHorizontalDelta:(CGFloat)delta {
    // Approximate touch-surface horizontal movement to timeline seek.
    NSTimeInterval secondsDelta = (NSTimeInterval)delta / 8.0;
    if (fabs(secondsDelta) < 0.01) {
        return;
    }
    [self skipByInterval:secondsDelta];
}

static NSString *BrowserNativePlayerFormatTime(NSTimeInterval time) {
    if (!isfinite(time) || time < 0.0) {
        time = 0.0;
    }
    NSInteger total = (NSInteger)llround(time);
    NSInteger hours = total / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger seconds = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)seconds];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)seconds];
}

- (void)showPositionHUDForTarget:(NSTimeInterval)target {
    if (self.positionHUDView == nil) {
        UIView *hud = [[UIView alloc] init];
        hud.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
        hud.layer.cornerRadius = 10.0;
        hud.layer.masksToBounds = YES;
        hud.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentOverlayView addSubview:hud];

        UILabel *label = [[UILabel alloc] init];
        label.font = [UIFont monospacedDigitSystemFontOfSize:29.0 weight:UIFontWeightSemibold];
        label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [hud addSubview:label];

        UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        progress.progressTintColor = UIColor.whiteColor;
        progress.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.3];
        progress.translatesAutoresizingMaskIntoConstraints = NO;
        [hud addSubview:progress];

        [NSLayoutConstraint activateConstraints:@[
            [hud.centerXAnchor constraintEqualToAnchor:self.contentOverlayView.centerXAnchor],
            [hud.bottomAnchor constraintEqualToAnchor:self.contentOverlayView.bottomAnchor constant:-80.0],
            [label.topAnchor constraintEqualToAnchor:hud.topAnchor constant:16.0],
            [label.centerXAnchor constraintEqualToAnchor:hud.centerXAnchor],
            [progress.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:14.0],
            [progress.leadingAnchor constraintEqualToAnchor:hud.leadingAnchor constant:28.0],
            [progress.trailingAnchor constraintEqualToAnchor:hud.trailingAnchor constant:-28.0],
            [progress.bottomAnchor constraintEqualToAnchor:hud.bottomAnchor constant:-20.0],
            [progress.widthAnchor constraintEqualToConstant:760.0],
        ]];

        self.positionHUDView = hud;
        self.positionHUDLabel = label;
        self.positionHUDProgress = progress;
    }

    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    BOOL hasDuration = isfinite(duration) && duration > 0.0;
    self.positionHUDLabel.text = [NSString stringWithFormat:@"%@ / %@",
                                  BrowserNativePlayerFormatTime(target),
                                  hasDuration ? BrowserNativePlayerFormatTime(duration) : @"--:--"];
    self.positionHUDProgress.hidden = !hasDuration;
    if (hasDuration) {
        self.positionHUDProgress.progress = (float)(target / duration);
    }
    self.positionHUDView.hidden = NO;

    [self.positionHUDHideTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.positionHUDHideTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:NO block:^(__unused NSTimer *timer) {
        weakSelf.positionHUDView.hidden = YES;
    }];
}

- (void)closePlayer {
    [self log:@"close player"];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleFocusUpdate:(NSNotification *)notification {
    // Debug instrumentation: trace where focus moves inside AVKit's transport bar
    // while the native player is presented (paused-scrub snap-back investigation).
    if (self.viewIfLoaded.window == nil) {
        return;
    }
    id<UIFocusItem> previousItem = notification.userInfo[UIFocusUpdateContextKey] ?
        ((UIFocusUpdateContext *)notification.userInfo[UIFocusUpdateContextKey]).previouslyFocusedItem : nil;
    id<UIFocusItem> nextItem = notification.userInfo[UIFocusUpdateContextKey] ?
        ((UIFocusUpdateContext *)notification.userInfo[UIFocusUpdateContextKey]).nextFocusedItem : nil;
    [self log:@"focus %@ -> %@",
     previousItem ? NSStringFromClass([(id)previousItem class]) : @"(nil)",
     nextItem ? NSStringFromClass([(id)nextItem class]) : @"(nil)"];
}

- (void)handlePlayerItemFailedToPlayToEndTime:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self log:@"failedToPlayToEnd error=%@", error];
}

- (void)handlePlayerItemNewErrorLogEntry:(NSNotification *)notification {
    AVPlayerItemErrorLog *errorLog = self.player.currentItem.errorLog;
    AVPlayerItemErrorLogEvent *lastEvent = errorLog.events.lastObject;
    [self log:@"errorLog domain=%@ status=%ld comment=%@ serverAddress=%@ playbackSessionID=%@",
     lastEvent.errorDomain ?: @"",
     (long)lastEvent.errorStatusCode,
     lastEvent.errorComment ?: @"",
     lastEvent.serverAddress ?: @"",
     lastEvent.playbackSessionID ?: @""];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (object == self.player.currentItem && [keyPath isEqualToString:@"status"]) {
        switch (self.player.currentItem.status) {
            case AVPlayerItemStatusUnknown:
                [self log:@"item status=unknown error=%@", self.player.currentItem.error];
                break;
            case AVPlayerItemStatusReadyToPlay:
                [self log:@"item status=ready duration=%f likelyToKeepUp=%d bufferEmpty=%d",
                 CMTimeGetSeconds(self.player.currentItem.duration),
                 self.player.currentItem.isPlaybackLikelyToKeepUp,
                 self.player.currentItem.isPlaybackBufferEmpty];
                break;
            case AVPlayerItemStatusFailed:
                [self log:@"item status=failed error=%@", self.player.currentItem.error];
                break;
        }
        return;
    }

    if (object == self.player && [keyPath isEqualToString:@"timeControlStatus"]) {
        if (@available(tvOS 10.0, *)) {
            NSString *status = @"unknown";
            switch (self.player.timeControlStatus) {
                case AVPlayerTimeControlStatusPaused:
                    status = @"paused";
                    break;
                case AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate:
                    status = @"waiting";
                    break;
                case AVPlayerTimeControlStatusPlaying:
                    status = @"playing";
                    break;
            }
            [self log:@"timeControlStatus=%@ reason=%@", status, self.player.reasonForWaitingToPlay ?: @""];
            return;
        }
    }

    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"%@ pressesBegan type=%@ phase=%@",
              kBrowserNativePlayerInputLogPrefix,
              BrowserNativePlayerPressTypeString(press.type),
              BrowserNativePlayerPressPhaseString(press.phase));
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"%@ pressesEnded type=%@ phase=%@",
              kBrowserNativePlayerInputLogPrefix,
              BrowserNativePlayerPressTypeString(press.type),
              BrowserNativePlayerPressPhaseString(press.phase));
    }
    [super pressesEnded:presses withEvent:event];
}

@end
