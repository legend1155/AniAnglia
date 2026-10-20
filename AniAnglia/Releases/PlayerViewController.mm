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

// Labels may be "720p", "auto", etc. Never throw from std::stol.
std::string choose_quality(const std::unordered_map<std::string, std::string>& qualities, const std::string_view preferred) {
    auto exact = qualities.find(std::string(preferred));
    if (exact != qualities.end() && !exact->second.empty()) return exact->second;
    long best = -1;
    std::string result;
    for (const auto& [label, url] : qualities) {
        if (url.empty()) continue;
        long value = 0;
        for (unsigned char c : label) {
            if (!std::isdigit(c)) break;
            value = std::min(100000L, value * 10 + c - '0');
        }
        if (value > best || (value == best && url < result)) { best = value; result = url; }
    }
    return result;
}

@interface PlayerViewController : AVPlayerViewController
@property(nonatomic, copy) void (^onClose)(void);
@end
@implementation PlayerViewController
-(void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed && !self.pictureInPictureActive && self.onClose) self.onClose();
}
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
-(void)saveProgress {
    if (!self.ready || self.resumePending || !self.progressKey || !self.observedPlayer) return;
    double seconds = CMTimeGetSeconds(self.observedPlayer.currentTime);
    double duration = CMTimeGetSeconds(self.observedItem.duration);
    if (!std::isfinite(seconds) || seconds < 0) return;
    NSMutableDictionary* progress = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"playback_progress"] mutableCopy] ?: [NSMutableDictionary new];
    if (std::isfinite(duration) && duration > 0 && seconds >= duration - 3) [progress removeObjectForKey:self.progressKey];
    else progress[self.progressKey] = @(seconds);
    [[NSUserDefaults standardUserDefaults] setObject:progress forKey:@"playback_progress"];
}
-(void)stopObserving {
    [self saveProgress];
    if (self.timeObserver) [self.observedPlayer removeTimeObserver:self.timeObserver];
    self.timeObserver = nil;
    if (self.observedItem) {
        [self.observedItem removeObserver:self forKeyPath:@"status" context:NULL];
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
    if (self.player_view_controller.presentingViewController) return;
    self.player_view_controller = [PlayerViewController new];
    self.player_view_controller.delegate = self;
    self.player_view_controller.modalPresentationStyle = UIModalPresentationFullScreen;
    self.player_view_controller.videoGravity = AVLayerVideoGravityResizeAspect;
    self.player_view_controller.showsPlaybackControls = YES;
    self.player_view_controller.view.backgroundColor = UIColor.blackColor;
    __weak PlayerController* weakSelf = self;
    __weak PlayerViewController* weakController = self.player_view_controller;
    self.player_view_controller.onClose = ^{
        PlayerController* owner = weakSelf;
        if (!owner || owner.player_view_controller != weakController) return;
        owner.generation += 1;
        [owner stopObserving];
        owner.player_view_controller.player = nil;
        owner.player_view_controller = nil;
    };
}
-(void)playWithReleaseID:(anixart::ReleaseID)release_id sourceID:(anixart::EpisodeSourceID)source_id position:(long)position autoShow:(BOOL)auto_show completion:(void(^)(BOOL))completion {
    [self stopObserving];
    self.release_id = release_id; self.source_id = source_id; self.source_position = position;
    self.targetURL = nil;
    self.progressKey = [NSString stringWithFormat:@"%lld:%lld:%lld:%ld", (long long)static_cast<int64_t>([[AppDataController sharedInstance] getMyProfileID]), (long long)static_cast<int64_t>(release_id), (long long)static_cast<int64_t>(source_id), position];
    self.advancing = NO; self.openingHandled = NO;
    NSUInteger generation = ++self.generation;
    [self prepareController];
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
            stream = [NSURL URLWithString:TO_NSSTRING(choose_quality(streams, preferred))];
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
    [self prepareController]; [self showViewController:self.player_view_controller]; [self runPlayer];
}
-(void)runPlayer {
    [self stopObserving];
    NSError* error = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
    [[AVAudioSession sharedInstance] setActive:YES error:&error];
    AVPlayerItem* item = [AVPlayerItem playerItemWithURL:self.selected_stream_url];
    self.observedPlayer = [AVPlayer playerWithPlayerItem:item];
    self.observedItem = item;
    self.player_view_controller.player = self.observedPlayer;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(episodeEnded:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
}
-(void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context {
    if (object != self.observedItem || ![keyPath isEqualToString:@"status"]) { [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return; }
    // AVFoundation may deliver KVO off-main. Queue all UI and lifecycle work.
    NSUInteger generation = self.generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.generation || object != self.observedItem) return;
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
                if (!owner || generation != owner.generation || !finished) return;
                owner.resumePending = NO;
                [owner.observedPlayer play];
                owner.timeObserver = [owner.observedPlayer addPeriodicTimeObserverForInterval:CMTimeMake(1, 1) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
                    PlayerController* current = weakSelf;
                    if (!current || generation != current.generation) return;
                    [current handleOpeningAt:CMTimeGetSeconds(time)];
                    [current saveProgress];
                }];
            });
        }];
    });
}
-(void)handleOpeningAt:(double)seconds {
    if (self.openingHandled || !std::isfinite(seconds)) return;
    AppSettingsDataController* settings = [self settings];
    double begin = MAX(0, [[settings getSettingsObjectAtKey:@"opening_start"] doubleValue]);
    double length = std::chrono::duration_cast<std::chrono::seconds>([settings getDefaultSkipTime]).count();
    if (seconds >= begin + length) { self.openingHandled = YES; return; }
    if ([[settings getSettingsObjectAtKey:@"auto_skip_opening"] boolValue] && seconds >= begin && length > 0) {
        self.openingHandled = YES;
        double duration = CMTimeGetSeconds(self.observedItem.duration);
        if (std::isfinite(duration) && begin + length < duration)
            [self.observedPlayer seekToTime:CMTimeMakeWithSeconds(begin + length, 600)];
    }
}
-(void)episodeEnded:(NSNotification*)notification {
    if (notification.object != self.observedItem || self.advancing) return;
    [self saveProgress];
    if (!self.progressKey) return;
    auto release = self.release_id; auto source = self.source_id; long position = self.source_position;
    [[LibanixartApi sharedInstance] asyncCall:^BOOL(anixart::Api* api) {
        api->episodes().add_watched_episode(release, source, (int32_t)position); return NO;
    } completion:^(BOOL errored) {}];
    if (![[self settings] getAutoNextVideo]) return;
    for (NSNumber* next in self.positions) if (next.longValue > position) {
        self.advancing = YES;
        [self playWithReleaseID:release sourceID:source position:next.longValue autoShow:NO completion:nil];
        break;
    }
}
-(void)playbackFailed:(NSNotification*)notification { [self showPlaybackError]; }
-(void)showPlaybackError {
    [self.observedPlayer pause];
    if (self.player_view_controller.presentedViewController) return;
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Не удалось воспроизвести видео" message:@"Источник не вернул совместимый поток. Можно попробовать веб-плеер источника или другую озвучку." preferredStyle:UIAlertControllerStyleAlert];
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
-(AVPlayerViewController*)getPlayer { return self.player_view_controller; }
+(instancetype)sharedInstance {
    static PlayerController* shared; static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [PlayerController new]; }); return shared;
}
-(void)playerViewController:(AVPlayerViewController*)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completion {
    if (controller.presentingViewController) { completion(YES); return; }
    [self showViewController:controller];
    completion(controller.presentingViewController != nil);
}
@end
