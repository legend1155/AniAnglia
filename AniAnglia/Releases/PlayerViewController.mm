// Native playback lifecycle, resume, queue and source web fallback.
#import "PlayerViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import "AppDataController.h"
#import "StringCvt.h"
#import <SafariServices/SafariServices.h>
#include <cctype>
#include <cmath>
#include <algorithm>

#include "PlaybackPolicy.hpp"

static void* PlaybackStatusContext = &PlaybackStatusContext;

// A container keeps interactive buttons ABOVE AVKit (not in its noninteractive contentOverlayView).
@interface PlayerViewController : UIViewController
@property(nonatomic, strong) AVPlayerViewController* nativePlayer;
@property(nonatomic, strong) UIButton* skipButton;
@property(nonatomic, strong) UIButton* nextButton;
@property(nonatomic, strong) UIButton* controlsButton;
@property(nonatomic, strong) UIButton* closeButton;
@property(nonatomic, strong) UIStackView* actionStack;
@property(nonatomic) BOOL overlayHidden;
@property(nonatomic, strong) UIActivityIndicatorView* spinner;
@property(nonatomic) BOOL pipActive;
@property(nonatomic) BOOL closing;
@property(nonatomic, copy) void (^onClose)(void);
@property(nonatomic, copy) void (^onSkip)(void);
@property(nonatomic, copy) void (^onNext)(void);
-(void)setLoading:(BOOL)loading;
-(void)setSkipAvailable:(BOOL)available nextAvailable:(BOOL)hasNext;
@end
@implementation PlayerViewController
-(instancetype)init {
    if ((self = [super init])) _nativePlayer = [AVPlayerViewController new];
    return self;
}
-(UIButton*)buttonWithTitle:(NSString*)title action:(SEL)action {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    button.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.85];
    button.layer.cornerRadius = 10;
    button.contentEdgeInsets = UIEdgeInsetsMake(10, 14, 10, 14);
    button.accessibilityLabel = title;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
-(void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    [self addChildViewController:self.nativePlayer];
    [self.view addSubview:self.nativePlayer.view];
    [self.nativePlayer didMoveToParentViewController:self];
    self.nativePlayer.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.nativePlayer.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.nativePlayer.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.nativePlayer.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.nativePlayer.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    UIButton* close = [self buttonWithTitle:@"Закрыть" action:@selector(closePressed)];
    self.closeButton = close;
    self.controlsButton = [self buttonWithTitle:@"Скрыть панель" action:@selector(toggleControls)];
    self.skipButton = [self buttonWithTitle:@"Skip · Опенинг" action:@selector(skipPressed)];
    self.nextButton = [self buttonWithTitle:@"Следующая серия →" action:@selector(nextPressed)];
    UIButton* fit = [self buttonWithTitle:@"Вписать видео" action:@selector(fitVideo)];
    UIStackView* skips = [[UIStackView alloc] initWithArrangedSubviews:@[fit, self.skipButton, self.nextButton]];
    self.actionStack = skips;
    skips.axis = UILayoutConstraintAxisVertical; skips.spacing = 8; skips.alignment = UIStackViewAlignmentTrailing;
    for (UIView* control in @[close, self.controlsButton, skips]) {
        [self.view addSubview:control]; control.translatesAutoresizingMaskIntoConstraints = NO;
    }
    UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [close.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [close.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.controlsButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.controlsButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [skips.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [skips.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-100]
    ]];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.color = UIColor.whiteColor;
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner]; self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
    [self setSkipAvailable:NO nextAvailable:NO];
}
-(void)fitVideo {
    self.nativePlayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
}
-(void)toggleControls {
    self.overlayHidden = !self.overlayHidden;
    self.nativePlayer.showsPlaybackControls = !self.overlayHidden;
    self.actionStack.hidden = self.overlayHidden;
    self.closeButton.hidden = self.overlayHidden;
    [self.controlsButton setTitle:self.overlayHidden ? @"Показать панель" : @"Скрыть панель" forState:UIControlStateNormal];
}
-(void)setLoading:(BOOL)loading {
    [self loadViewIfNeeded];
    if (loading) [self.spinner startAnimating]; else [self.spinner stopAnimating];
    self.skipButton.enabled = !loading; self.nextButton.enabled = !loading;
    self.controlsButton.enabled = !loading;
    self.nativePlayer.showsPlaybackControls = !loading && !self.overlayHidden;
}
-(void)setSkipAvailable:(BOOL)available nextAvailable:(BOOL)hasNext {
    self.skipButton.hidden = !available; self.nextButton.hidden = !hasNext;
}
-(void)skipPressed { if (self.onSkip) self.onSkip(); }
-(void)nextPressed { if (self.onNext) self.onNext(); }
-(void)closePressed {
    self.closing = YES;
    if (self.onClose) self.onClose();
    [self dismissViewControllerAnimated:YES completion:nil];
}
-(void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed && !self.pipActive && !self.closing && self.onClose) self.onClose();
}
-(UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }
@end

@interface PlayerController ()
@property(nonatomic) anixart::ReleaseID release_id;
@property(nonatomic) anixart::EpisodeSourceID source_id;
@property(nonatomic) long source_position;
@property(nonatomic, strong) PlayerViewController* player_view_controller;
@property(nonatomic, strong) AVPlayer* observedPlayer;
@property(nonatomic, strong) AVPlayerItem* observedItem;
@property(nonatomic, strong) id timeObserver;
@property(nonatomic, strong) NSURL* targetURL;
@property(nonatomic, strong) NSURL* selected_stream_url;
@property(nonatomic, copy) NSArray<NSNumber*>* positions;
@property(nonatomic, copy) NSString* progressKey;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL resumePending;
@property(nonatomic) BOOL openingHandled;
@property(nonatomic) BOOL advancing;
@property(nonatomic) BOOL episodeCompleted;
@property(nonatomic) BOOL errorShown;
@property(nonatomic) double lastSaveTime;
@end

@implementation PlayerController
-(instancetype)init {
    if ((self = [super init])) {
        _positions = @[];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveProgress) name:UIApplicationDidEnterBackgroundNotification object:nil];
    }
    return self;
}
-(AppSettingsDataController*)settings { return [[AppDataController sharedInstance] getSettingsController]; }
-(void)setEpisodePositions:(NSArray<NSNumber*>*)positions { self.positions = [positions sortedArrayUsingSelector:@selector(compare:)]; }
-(NSNumber*)nextPosition {
    std::vector<long> positions;
    for (NSNumber* item in self.positions) positions.push_back(item.longValue);
    long next = playback::nextPosition(positions, self.source_position);
    return next < 0 ? nil : @(next);
}
-(void)saveProgress {
    if (!self.ready || self.resumePending || !self.progressKey || !self.observedPlayer) return;
    double seconds = CMTimeGetSeconds(self.observedPlayer.currentTime);
    double duration = CMTimeGetSeconds(self.observedItem.duration);
    if (!std::isfinite(seconds) || seconds < 0) return;
    NSMutableDictionary* progress = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"playback_progress"] mutableCopy] ?: [NSMutableDictionary new];
    if (self.episodeCompleted || (std::isfinite(duration) && duration > 0 && seconds >= duration - 3)) [progress removeObjectForKey:self.progressKey];
    else progress[self.progressKey] = @(seconds);
    [[NSUserDefaults standardUserDefaults] setObject:progress forKey:@"playback_progress"];
}
-(void)stopObserving {
    [self saveProgress];
    if (self.timeObserver) [self.observedPlayer removeTimeObserver:self.timeObserver];
    self.timeObserver = nil;
    if (self.observedItem) {
        [self.observedItem removeObserver:self forKeyPath:@"status" context:PlaybackStatusContext];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.observedItem];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.observedItem];
    }
    [self.observedPlayer pause];
    self.observedItem = nil; self.observedPlayer = nil; self.ready = NO; self.resumePending = NO;
}
-(void)showViewController:(UIViewController*)controller {
    UIViewController* top = nil;
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow* window in ((UIWindowScene*)scene).windows) if (window.isKeyWindow) top = window.rootViewController;
    }
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    if (top != controller && !controller.presentingViewController) [top presentViewController:controller animated:YES completion:nil];
}
-(void)prepareController {
    if (self.player_view_controller) return;
    self.player_view_controller = [PlayerViewController new];
    self.player_view_controller.nativePlayer.delegate = self;
    self.player_view_controller.modalPresentationStyle = UIModalPresentationFullScreen;
    self.player_view_controller.nativePlayer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.player_view_controller.nativePlayer.showsPlaybackControls = YES;
    self.player_view_controller.view.backgroundColor = UIColor.blackColor;
    __weak PlayerController* weakSelf = self;
    __weak PlayerViewController* weakController = self.player_view_controller;
    self.player_view_controller.onClose = ^{
        PlayerController* owner = weakSelf;
        if (!owner || owner.player_view_controller != weakController) return;
        owner.generation += 1;
        [owner stopObserving];
        owner.player_view_controller.nativePlayer.player = nil;
        owner.player_view_controller = nil;
    };
    self.player_view_controller.onSkip = ^{ [weakSelf skipOpening]; };
    self.player_view_controller.onNext = ^{ [weakSelf playNextEpisode]; };
}
-(void)playWithReleaseID:(anixart::ReleaseID)release_id sourceID:(anixart::EpisodeSourceID)source_id position:(long)position autoShow:(BOOL)auto_show completion:(void(^)(BOOL))completion {
    [self stopObserving];
    self.release_id = release_id; self.source_id = source_id; self.source_position = position;
    self.targetURL = nil;
    self.progressKey = [NSString stringWithFormat:@"%lld:%lld:%lld:%ld", (long long)static_cast<int64_t>([[AppDataController sharedInstance] getMyProfileID]), (long long)static_cast<int64_t>(release_id), (long long)static_cast<int64_t>(source_id), position];
    self.advancing = NO; self.openingHandled = NO; self.episodeCompleted = NO; self.errorShown = NO;
    NSUInteger generation = ++self.generation;
    [self prepareController];
    [self.player_view_controller setLoading:YES];
    [self.player_view_controller setSkipAvailable:NO nextAvailable:NO];
    if (auto_show) [self showViewController:self.player_view_controller];
    NSString* quality = [[self settings] getPrefferedQuality] ?: @"720";
    BOOL web = [[self settings] getDefaultPlayer] == app_settings::Playback::DefaultPlayer::Web;
    __block NSURL* target = nil;
    __block NSURL* stream = nil;
    [[LibanixartApi sharedInstance] asyncCall:^BOOL(anixart::Api* api) {
        auto episode = api->episodes().get_episode_target(release_id, source_id, (int32_t)position);
        target = [NSURL URLWithString:TO_NSSTRING(episode->url)];
        if (!target || ![@[@"https", @"http"] containsObject:target.scheme.lowercaseString]) return YES;
        if (web) return NO;
        NSString* extension = target.pathExtension.lowercaseString;
        if ([@[@"m3u8", @"mp4", @"m4v"] containsObject:extension]) stream = target;
        else {
            auto streams = [LibanixartApi sharedInstance].parsers->extract_info(episode->url);
            std::string preferred = TO_STDSTRING(quality);
            stream = [NSURL URLWithString:TO_NSSTRING(playback::chooseQuality(streams, preferred))];
        }
        return !stream || ![@[@"https", @"http"] containsObject:stream.scheme.lowercaseString];
    } completion:^(BOOL errored) {
        if (generation != self.generation) { if (completion) completion(YES); return; }
        self.targetURL = target;
        if (web && !errored) {
            [self openWebPlayer]; if (completion) completion(NO); return;
        }
        if (errored) { if (completion) completion(YES); [self showPlaybackError]; return; }
        self.selected_stream_url = stream;
        [self runPlayer];
        if (completion) completion(NO);
    }];
}
-(void)playWithURL:(NSURL*)url {
    ++self.generation; [self stopObserving]; self.progressKey = nil; self.positions = @[];
    self.targetURL = url; self.selected_stream_url = url;
    self.episodeCompleted = NO; self.openingHandled = NO; self.errorShown = NO;
    [self prepareController]; [self showViewController:self.player_view_controller]; [self runPlayer];
}
-(void)runPlayer {
    [self stopObserving];
    [self.player_view_controller setLoading:YES];
    self.lastSaveTime = -1;
    NSError* error = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
    [[AVAudioSession sharedInstance] setActive:YES error:&error];
    AVPlayerItem* item = [AVPlayerItem playerItemWithURL:self.selected_stream_url];
    // Keep the native AVPlayer identity across episodes (important for AVKit/PiP).
    AVPlayer* player = self.player_view_controller.nativePlayer.player ?: [AVPlayer new];
    [player replaceCurrentItemWithPlayerItem:item];
    self.observedPlayer = player;
    self.observedItem = item;
    self.player_view_controller.nativePlayer.player = self.observedPlayer;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(episodeEnded:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:PlaybackStatusContext];
}
-(void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context {
    if (context != PlaybackStatusContext) { [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return; }
    // Ignore stale items on the main queue, without passing our old KVO to NSObject.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (object != self.observedItem) return;
        NSUInteger generation = self.generation;
        if (self.observedItem.status == AVPlayerItemStatusFailed) { [self showPlaybackError]; return; }
        if (self.observedItem.status != AVPlayerItemStatusReadyToPlay || self.ready) return;
        self.ready = YES; self.resumePending = YES;
        NSDictionary* progress = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"playback_progress"];
        double resume = self.progressKey ? [progress[self.progressKey] doubleValue] : 0;
        double duration = CMTimeGetSeconds(self.observedItem.duration);
        if (!std::isfinite(resume) || resume < 0 || (std::isfinite(duration) && resume >= duration - 3)) resume = 0;
        __weak PlayerController* weakSelf = self;
        [self.observedPlayer seekToTime:CMTimeMakeWithSeconds(resume, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PlayerController* owner = weakSelf;
                if (!owner || generation != owner.generation) return;
                if (owner.observedItem.status != AVPlayerItemStatusReadyToPlay) { [owner showPlaybackError]; return; }
                owner.resumePending = NO;
                [owner.player_view_controller setLoading:NO];
                [owner updatePlaybackAt:CMTimeGetSeconds(owner.observedPlayer.currentTime)];
                if (generation != owner.generation) return;
                [owner.observedPlayer play];
                owner.timeObserver = [owner.observedPlayer addPeriodicTimeObserverForInterval:CMTimeMake(1, 1) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
                    PlayerController* current = weakSelf;
                    if (!current || generation != current.generation) return;
                    double seconds = CMTimeGetSeconds(time);
                    [current updatePlaybackAt:seconds];
                    if (generation != current.generation) return;
                    if (current.lastSaveTime < 0 || std::abs(seconds - current.lastSaveTime) >= 5) {
                        [current saveProgress]; current.lastSaveTime = seconds;
                    }
                }];
            });
        }];
    });
}
-(double)openingTargetAt:(double)seconds {
    AppSettingsDataController* settings = [self settings];
    double begin = [[settings getSettingsObjectAtKey:@"opening_start"] doubleValue];
    double length = std::chrono::duration_cast<std::chrono::seconds>([settings getDefaultSkipTime]).count();
    return playback::openingTarget(seconds, CMTimeGetSeconds(self.observedItem.duration), begin, length);
}
-(void)skipOpening {
    if (!self.ready || self.resumePending) return;
    double target = [self openingTargetAt:CMTimeGetSeconds(self.observedPlayer.currentTime)];
    if (target < 0) return;
    self.openingHandled = YES;
    [self.player_view_controller setSkipAvailable:NO nextAvailable:[self nextPosition] != nil];
    NSUInteger generation = self.generation;
    [self.observedPlayer seekToTime:CMTimeMakeWithSeconds(target, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (finished && generation == self.generation) [self saveProgress]; });
    }];
}
-(void)updatePlaybackAt:(double)seconds {
    if (!self.ready || self.resumePending || !std::isfinite(seconds)) return;
    BOOL hasNext = [self nextPosition] != nil;
    double target = [self openingTargetAt:seconds];
    [self.player_view_controller setSkipAvailable:target >= 0 nextAvailable:hasNext];
    BOOL playing = self.observedPlayer.rate > 0;
    if (playing && !self.openingHandled && target >= 0 && [[[self settings] getSettingsObjectAtKey:@"auto_skip_opening"] boolValue]) [self skipOpening];
    double ending = [[[self settings] getSettingsObjectAtKey:@"ending_skip_time"] doubleValue];
    BOOL skipEnding = [[[self settings] getSettingsObjectAtKey:@"auto_skip_ending"] boolValue];
    if (playing && skipEnding && playback::shouldSkipEnding(seconds, CMTimeGetSeconds(self.observedItem.duration), ending, hasNext)) {
        [self markEpisodeCompleted];
        [self playNextEpisode];
    }
}
-(void)markEpisodeCompleted {
    if (self.episodeCompleted || !self.progressKey) return;
    self.episodeCompleted = YES; [self saveProgress];
    auto release = self.release_id; auto source = self.source_id; long position = self.source_position;
    [[LibanixartApi sharedInstance] asyncCall:^BOOL(anixart::Api* api) {
        api->episodes().add_watched_episode(release, source, (int32_t)position); return NO;
    } completion:^(BOOL errored) { if (errored) NSLog(@"Could not sync completed episode"); }];
}
-(void)playNextEpisode {
    NSNumber* next = [self nextPosition];
    if (!next || self.advancing || !self.ready || self.resumePending) return;
    self.advancing = YES;
    // Manual early transition saves progress, without falsely marking a series watched.
    [self playWithReleaseID:self.release_id sourceID:self.source_id position:next.longValue autoShow:NO completion:nil];
}
-(void)episodeEnded:(NSNotification*)notification {
    AVPlayerItem* item = notification.object;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (item != self.observedItem || self.advancing) return;
        [self markEpisodeCompleted];
        if ([[self settings] getAutoNextVideo]) [self playNextEpisode];
    });
}
-(void)playbackFailed:(NSNotification*)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ if (notification.object == self.observedItem) [self showPlaybackError]; });
}
-(void)showPlaybackError {
    [self.observedPlayer pause];
    [self.player_view_controller setLoading:NO];
    if (self.errorShown || !self.player_view_controller || self.player_view_controller.presentedViewController) return;
    self.errorShown = YES;
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Не удалось воспроизвести видео" message:@"Источник не вернул совместимый поток. Можно попробовать веб-плеер источника или другую озвучку." preferredStyle:UIAlertControllerStyleAlert];
    if (self.progressKey) [alert addAction:[UIAlertAction actionWithTitle:@"Повторить" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self playWithReleaseID:self.release_id sourceID:self.source_id position:self.source_position autoShow:NO completion:nil];
    }]];
    if (self.targetURL) [alert addAction:[UIAlertAction actionWithTitle:@"Открыть веб-плеер" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) { [self openWebPlayer]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Закрыть" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action) { [self.player_view_controller dismissViewControllerAnimated:YES completion:nil]; }]];
    [self.player_view_controller presentViewController:alert animated:YES completion:nil];
}
-(void)openWebPlayer {
    if (!self.targetURL) return;
    NSURL* url = self.targetURL;
    ++self.generation; [self stopObserving];
    SFSafariViewController* web = [[SFSafariViewController alloc] initWithURL:url];
    UIViewController* native = self.player_view_controller;
    self.player_view_controller = nil;
    if (native.presentingViewController) [native dismissViewControllerAnimated:YES completion:^{ [self showViewController:web]; }];
    else [self showViewController:web];
}
-(AVPlayerViewController*)getPlayer { return self.player_view_controller.nativePlayer; }
+(instancetype)sharedInstance {
    static PlayerController* shared; static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [PlayerController new]; }); return shared;
}
// PiP state belongs to the delegate lifecycle, not to a nonexistent AVKit property.
-(void)playerViewControllerWillStartPictureInPicture:(AVPlayerViewController*)controller { if (controller == self.player_view_controller.nativePlayer) self.player_view_controller.pipActive = YES; }
-(void)playerViewControllerDidStopPictureInPicture:(AVPlayerViewController*)controller {
    if (controller != self.player_view_controller.nativePlayer) return;
    self.player_view_controller.pipActive = NO;
    if (!self.player_view_controller.presentingViewController) {
        ++self.generation; [self stopObserving]; self.player_view_controller = nil;
    }
}
-(void)playerViewController:(AVPlayerViewController*)controller failedToStartPictureInPictureWithError:(NSError*)error { if (controller == self.player_view_controller.nativePlayer) self.player_view_controller.pipActive = NO; }
-(void)playerViewController:(AVPlayerViewController*)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completion {
    PlayerViewController* container = self.player_view_controller;
    if (!container || container.nativePlayer != controller) { completion(NO); return; }
    if (container.presentingViewController) { completion(YES); return; }
    [self showViewController:container];
    completion(container.presentingViewController != nil);
}
@end
