// Native playback lifecycle, resume, queue, compact controls and AVPlayerLayer PiP.
#import "PlayerViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreFoundation/CoreFoundation.h>
#import "AppDataController.h"
#import "StringCvt.h"

#include <cctype>
#include <exception>
#include <cmath>
#include <algorithm>
#include <set>

#include "PlaybackPolicy.hpp"
#include "AnimeMapping.hpp"
#include "PlayerChromeLayout.hpp"
#import "PlayerChrome.h"
#include "../Main/WatchPolicy.hpp"
#import "../Main/WatchHistory.h"

static void* PlaybackStatusContext = &PlaybackStatusContext;
static BOOL PlaybackRealNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}
static BOOL PlaybackPositiveInteger(id value, long maximum) {
    if (!PlaybackRealNumber(value)) return NO;
    double number = [value doubleValue];
    return std::isfinite(number) && number >= 1 && number <= maximum && std::floor(number) == number;
}
static NSString* PlaybackNormalizedTitle(NSString* title) {
    NSString* folded = [title stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    return [[[folded lowercaseString] componentsSeparatedByCharactersInSet:[NSCharacterSet.alphanumericCharacterSet invertedSet]] componentsJoinedByString:@""];
}
static NSString* PlaybackTime(double seconds) {
    long whole = (long)std::floor(seconds);
    return [NSString stringWithFormat:@"%02ld:%02ld", whole / 60, whole % 60];
}

// One public, app-owned control layer: AVKit does not expose native chrome visibility.
// This avoids private KVO/selectors and keeps every overlay on the same visibility state.
// The displayed layer is also the PiP source. No private AVKit view traversal.
@interface AniVideoSurface : UIView
@property(nonatomic, readonly) AVPlayerLayer* playerLayer;
@end
@implementation AniVideoSurface
+(Class)layerClass { return AVPlayerLayer.class; }
-(AVPlayerLayer*)playerLayer { return (AVPlayerLayer*)self.layer; }
@end

@interface PlayerViewController : UIViewController <UIGestureRecognizerDelegate, AVPictureInPictureControllerDelegate, UIPopoverPresentationControllerDelegate>
@property(nonatomic, strong) AVPlayerViewController* nativePlayer;
@property(nonatomic, strong) UIButton* skipButton;
@property(nonatomic, strong) UIButton* nextButton;
@property(nonatomic, strong) UIButton* moreButton;
@property(nonatomic, strong) AniVideoSurface* videoSurface;
@property(nonatomic, strong) AVPictureInPictureController* pipController;
@property(nonatomic) BOOL restoringPiP;
@property(nonatomic) BOOL menuOpen;
@property(nonatomic, strong) UIButton* closeButton;
@property(nonatomic, strong) UIButton* playButton;
@property(nonatomic, strong) UIButton* backButton;
@property(nonatomic, strong) UIButton* forwardButton;
@property(nonatomic, strong) UIButton* speedButton;

@property(nonatomic, strong) UIView* shade;
@property(nonatomic) CGRect lastChromeBounds;
@property(nonatomic) float preferredRate;
@property(nonatomic, strong) UIView* actionStack;
@property(nonatomic, strong) UIView* transportStack;
@property(nonatomic, strong) UILabel* playbackStatusLabel;
@property(nonatomic, strong) UILabel* timeLabel;
@property(nonatomic, strong) AniPlayerSlider* timeline;
@property(nonatomic) BOOL overlayHidden;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL scrubbing;
@property(nonatomic) NSUInteger seekSerial;
@property(nonatomic) BOOL wasPlaying;
@property(nonatomic) double hideDeadline;
@property(nonatomic, strong) UIActivityIndicatorView* spinner;
@property(nonatomic) BOOL pipActive;
@property(nonatomic) BOOL closing;
@property(nonatomic, copy) void (^onClose)(void);
@property(nonatomic, copy) void (^onSkip)(void);
@property(nonatomic, copy) void (^onNext)(void);
@property(nonatomic, copy) void (^onOpening)(void);
@property(nonatomic, copy) void (^onSeek)(void);
-(void)setLoading:(BOOL)loading;
-(void)setSkipAvailable:(BOOL)available nextAvailable:(BOOL)hasNext;
-(void)refreshTransport;
-(void)revealControls;
-(CGRect)chromeBounds;
-(void)sliderChanged;
-(void)attachPlayer:(AVPlayer*)player;
-(void)tearDownPlayback;
-(void)toggleControls;
-(void)seekToSeconds:(double)seconds;
@end
@implementation PlayerViewController
-(instancetype)init {
    if ((self = [super init])) {
        _nativePlayer = [AVPlayerViewController new]; _preferredRate=1;
        _nativePlayer.showsPlaybackControls = NO;
        _nativePlayer.allowsPictureInPicturePlayback = NO; // Compatibility handle only; the visible AVPlayerLayer owns PiP.
    }
    return self;
}
-(UIButton*)buttonWithTitle:(NSString*)title action:(SEL)action {
    AniPlayerButton* button=[[AniPlayerButton alloc] initWithFrame:CGRectZero];
    [button setTitle:title forState:UIControlStateNormal]; button.accessibilityLabel=title;
    if (action) [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
-(void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.blackColor;
    self.videoSurface=[AniVideoSurface new]; self.videoSurface.userInteractionEnabled=NO;
    self.videoSurface.playerLayer.videoGravity=AVLayerVideoGravityResizeAspect;
    self.videoSurface.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.videoSurface.frame=self.view.bounds; [self.view addSubview:self.videoSurface];
    self.shade=[AniPlayerShade new]; self.shade.userInteractionEnabled=NO; self.shade.backgroundColor=UIColor.clearColor;
    [self.view addSubview:self.shade];
    self.closeButton=[self buttonWithTitle:@"" action:@selector(closePressed)]; ((AniPlayerButton*)self.closeButton).chromeStyle=2;
    [self.closeButton setImage:AniPlayerIcon(@"xmark") forState:UIControlStateNormal]; self.closeButton.accessibilityLabel=@"Закрыть плеер";
    self.skipButton=[self buttonWithTitle:@"Пропустить опенинг" action:@selector(skipPressed)];
    [self.skipButton setImage:AniPlayerIcon(@"forward.end.fill") forState:UIControlStateNormal];
    self.nextButton=[self buttonWithTitle:@"Далее" action:@selector(nextPressed)];
    [self.nextButton setImage:AniPlayerIcon(@"forward.end.fill") forState:UIControlStateNormal];
    self.moreButton=[self buttonWithTitle:@"" action:@selector(morePressed)];
    [self.moreButton setImage:AniPlayerIcon(@"ellipsis") forState:UIControlStateNormal]; self.moreButton.accessibilityLabel=@"Меню плеера";
    self.actionStack=[AniPlayerOverlay new];
    for (UIButton* button in @[self.skipButton,self.nextButton]) [self.actionStack addSubview:button];
    self.transportStack=[AniPlayerOverlay new];
    self.playButton=[self buttonWithTitle:@"" action:@selector(playPressed)];
    self.backButton=[self buttonWithTitle:@"" action:@selector(backPressed)]; self.forwardButton=[self buttonWithTitle:@"" action:@selector(forwardPressed)];
    [self.backButton setImage:AniPlayerIcon(@"gobackward.10") forState:UIControlStateNormal]; self.backButton.accessibilityLabel=@"Назад на 10 секунд";
    [self.forwardButton setImage:AniPlayerIcon(@"goforward.10") forState:UIControlStateNormal]; self.forwardButton.accessibilityLabel=@"Вперёд на 10 секунд";
    for (UIButton* button in @[self.backButton,self.playButton,self.forwardButton]) ((AniPlayerButton*)button).chromeStyle=1;
    self.speedButton=[self buttonWithTitle:@"Скорость" action:@selector(speedPressed)];
    ((AniPlayerButton*)self.speedButton).chromeStyle=1; ((AniPlayerButton*)self.moreButton).chromeStyle=1; ((AniPlayerButton*)self.nextButton).chromeStyle=1;
    self.timeline=[AniPlayerSlider new]; self.timeline.minimumValue=0; self.timeline.maximumValue=1; self.timeline.minimumTrackTintColor=UIColor.whiteColor;
    self.timeline.maximumTrackTintColor=[UIColor colorWithWhite:1 alpha:0.22]; self.timeline.accessibilityLabel=@"Позиция в серии";
    [self.timeline addTarget:self action:@selector(scrubStarted) forControlEvents:UIControlEventTouchDown];
    [self.timeline addTarget:self action:@selector(scrubFinished) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside];
    [self.timeline addTarget:self action:@selector(scrubCancelled) forControlEvents:UIControlEventTouchCancel];
    [self.timeline addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
    self.timeLabel=[UILabel new]; self.timeLabel.textColor=UIColor.whiteColor; self.timeLabel.textAlignment=NSTextAlignmentCenter;
    self.timeLabel.font=[UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.playbackStatusLabel=[UILabel new]; self.playbackStatusLabel.textColor=[UIColor colorWithWhite:1 alpha:0.88];
    self.playbackStatusLabel.font=[UIFont systemFontOfSize:14]; self.playbackStatusLabel.alpha=0; self.playbackStatusLabel.accessibilityElementsHidden=YES; self.playbackStatusLabel.numberOfLines=1; self.playbackStatusLabel.textAlignment=NSTextAlignmentCenter;
    for (UIView* control in @[self.timeline,self.backButton,self.playButton,self.forwardButton,self.timeLabel,self.speedButton,self.moreButton]) [self.transportStack addSubview:control];
    for (UIView* control in @[self.closeButton,self.actionStack,self.transportStack,self.playbackStatusLabel]) [self.view addSubview:control];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge]; self.spinner.color=UIColor.whiteColor; self.spinner.hidesWhenStopped=YES;
    [self.view addSubview:self.spinner];
    UITapGestureRecognizer* tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleControls)]; tap.delegate=self; tap.cancelsTouchesInView=NO;
    [self.view addGestureRecognizer:tap]; [self setSkipAvailable:NO nextAvailable:NO]; [self revealControls];
}
-(CGRect)chromeBounds {
    CGRect safe=self.view.safeAreaLayoutGuide.layoutFrame;
    CGRect video=[self.videoSurface convertRect:self.videoSurface.playerLayer.videoRect toView:self.view];
    CGRect visible=CGRectIntersection(safe,video);
    return CGRectIsNull(visible) || CGRectIsEmpty(visible) || visible.size.width<240 || visible.size.height<120 ? safe : visible;
}
-(void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews]; self.actionStack.frame=self.view.bounds; self.transportStack.frame=self.view.bounds;
    CGRect bounds=[self chromeBounds]; self.lastChromeBounds=bounds;
    auto layout=playback::chromeLayout(bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height,!self.skipButton.hidden,!self.nextButton.hidden,UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory));
    auto rect=[](playback::ChromeRect r){return CGRectMake(r.x,r.y,r.w,r.h);};
    CGRect safe=self.view.safeAreaLayoutGuide.layoutFrame;
    self.closeButton.frame=CGRectMake(safe.origin.x+12,safe.origin.y+4,44,44); self.playbackStatusLabel.frame=CGRectZero;
    [self.skipButton setTitle:layout.shortVideo ? @"Пропустить" : @"Пропустить опенинг" forState:UIControlStateNormal]; self.skipButton.accessibilityLabel=@"Пропустить опенинг";
    self.skipButton.frame=rect(layout.skip); self.nextButton.frame=rect(layout.next);
    self.timeline.frame=rect(layout.slider); self.timeLabel.frame=rect(layout.time);
    self.backButton.frame=rect(layout.back); self.playButton.frame=rect(layout.play); self.forwardButton.frame=rect(layout.forward);
    self.speedButton.frame=rect(layout.speed); self.moreButton.frame=rect(layout.more);
    [self.speedButton setTitle:layout.speed.w<80 ? [NSString stringWithFormat:@"%.2g×",self.preferredRate] : @"Скорость" forState:UIControlStateNormal];
    self.shade.frame=CGRectMake(bounds.origin.x,CGRectGetMaxY(bounds)-160,bounds.size.width,160); [self.shade setNeedsDisplay];
    self.spinner.center=CGPointMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds));
}
-(BOOL)gestureRecognizer:(UIGestureRecognizer*)recognizer shouldReceiveTouch:(UITouch*)touch {
    for (UIView* view = touch.view; view && view != self.view; view = view.superview) {
        if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:AVRoutePickerView.class]) return NO;
    }
    return YES;
}
-(void)fitVideo { self.videoSurface.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect; [self.view setNeedsLayout]; }
-(void)setOverlayHidden:(BOOL)hidden {
    _overlayHidden = hidden;
    NSArray<UIView*>* controls=@[self.closeButton, self.actionStack, self.transportStack, self.playbackStatusLabel, self.shade];
    if (!self.isViewLoaded) return;
    for (UIView* view in controls) { [view.layer removeAllAnimations]; if (!hidden && view!=self.playbackStatusLabel) view.hidden=NO; }
    void (^changes)(void)=^{
        for (UIView* view in controls) view.alpha=(hidden || view==self.playbackStatusLabel) ? 0 : 1;
    };
    if (UIAccessibilityIsReduceMotionEnabled()) {
        changes(); for (UIView* view in controls) view.hidden = hidden;
    } else {
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:changes completion:^(BOOL finished) {
            if (finished && self.overlayHidden==hidden) for (UIView* view in controls) view.hidden = hidden;
        }];
    }
}
-(void)revealControls { self.overlayHidden = NO; self.hideDeadline = NSProcessInfo.processInfo.systemUptime + 4; }
-(void)toggleControls { if (self.overlayHidden) [self revealControls]; else self.overlayHidden = YES; }
-(void)refreshTransport {
    AVPlayer* player = self.nativePlayer.player;
    double seconds = CMTimeGetSeconds(player.currentTime), duration = CMTimeGetSeconds(player.currentItem.duration);
    BOOL valid = std::isfinite(seconds) && std::isfinite(duration) && duration > 0;
    self.timeline.enabled = valid && !self.loading;
    if (!self.scrubbing && valid) self.timeline.value = (float)(seconds / duration);
    if (!CGRectEqualToRect(self.lastChromeBounds,[self chromeBounds])) [self.view setNeedsLayout];
    if (self.scrubbing && valid) seconds=self.timeline.value*duration;
    self.timeline.accessibilityValue=valid ? [NSString stringWithFormat:@"%@ из %@",PlaybackTime(seconds),PlaybackTime(duration)] : @"Загрузка";
    self.timeLabel.text = valid ? [NSString stringWithFormat:@"%@ / %@", PlaybackTime(seconds), PlaybackTime(duration)] : @"— / —";
    BOOL playing = player.timeControlStatus == AVPlayerTimeControlStatusPlaying;
    [self.playButton setImage:AniPlayerIcon(playing ? @"pause.fill" : @"play.fill") forState:UIControlStateNormal];
    self.playButton.accessibilityLabel = playing ? @"Пауза" : @"Воспроизвести";
    if (!playing && self.wasPlaying) [self revealControls];
    if (playing && !self.wasPlaying) self.hideDeadline = NSProcessInfo.processInfo.systemUptime + 4;
    self.wasPlaying = playing;
    if (UIAccessibilityIsVoiceOverRunning() || UIAccessibilityIsSwitchControlRunning()) [self revealControls];
    if (discovery::controlsShouldHide(self.overlayHidden, playing, self.scrubbing || self.menuOpen || self.presentedViewController != nil || self.loading,
                                     UIAccessibilityIsVoiceOverRunning() || UIAccessibilityIsSwitchControlRunning(), NSProcessInfo.processInfo.systemUptime, self.hideDeadline)) self.overlayHidden = YES;
}
-(void)setLoading:(BOOL)loading {
    [self loadViewIfNeeded]; _loading = loading;
    if (loading) [self.spinner startAnimating]; else [self.spinner stopAnimating];
    self.skipButton.enabled = !loading; self.nextButton.enabled = !loading; self.moreButton.enabled = !loading; self.playButton.enabled = !loading; self.backButton.enabled=!loading; self.forwardButton.enabled=!loading; self.speedButton.enabled=!loading;
    self.nativePlayer.showsPlaybackControls = NO; self.scrubbing = NO; ++self.seekSerial; [self revealControls]; [self refreshTransport];
}
-(void)setSkipAvailable:(BOOL)available nextAvailable:(BOOL)hasNext {
    if (self.skipButton.hidden!=!available || self.nextButton.hidden!=!hasNext) [self.view setNeedsLayout];
    self.skipButton.hidden=!available; self.nextButton.hidden=!hasNext;
}
-(void)playPressed { if (self.loading) return; if (self.nativePlayer.player.rate > 0) [self.nativePlayer.player pause]; else self.nativePlayer.player.rate=self.preferredRate; [self revealControls]; [self refreshTransport]; }
-(void)seekToSeconds:(double)seconds {
    double duration = CMTimeGetSeconds(self.nativePlayer.player.currentItem.duration);
    if (self.loading || !std::isfinite(seconds) || !std::isfinite(duration) || duration <= 0) return;
    if (self.onSeek) self.onSeek();
    self.scrubbing=YES; NSUInteger serial=++self.seekSerial; AVPlayerItem* item=self.nativePlayer.player.currentItem;
    __weak PlayerViewController* weakSelf=self;
    CMTime tolerance=CMTimeMakeWithSeconds(0.2,600);
    [self.nativePlayer.player seekToTime:CMTimeMakeWithSeconds(MAX(0,MIN(seconds,duration)),600) toleranceBefore:tolerance toleranceAfter:tolerance completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(),^{
            PlayerViewController* owner=weakSelf;
            if (!owner || serial!=owner.seekSerial || item!=owner.nativePlayer.player.currentItem) return;
            owner.scrubbing=NO; [owner revealControls]; [owner refreshTransport];
        });
    }];
    [self revealControls];
}
-(void)backPressed { [self seekToSeconds:CMTimeGetSeconds(self.nativePlayer.player.currentTime) - 10]; }
-(void)forwardPressed { [self seekToSeconds:CMTimeGetSeconds(self.nativePlayer.player.currentTime) + 10]; }
-(void)scrubStarted { ++self.seekSerial; self.scrubbing = YES; if (self.onSeek) self.onSeek(); [self revealControls]; }
-(void)scrubFinished { self.scrubbing = NO; [self seekToSeconds:self.timeline.value * CMTimeGetSeconds(self.nativePlayer.player.currentItem.duration)]; }
-(void)sliderChanged {
    if (UIAccessibilityIsVoiceOverRunning() || UIAccessibilityIsSwitchControlRunning()) { self.scrubbing=NO; [self seekToSeconds:self.timeline.value*CMTimeGetSeconds(self.nativePlayer.player.currentItem.duration)]; }
    [self refreshTransport];
}
-(void)scrubCancelled { self.scrubbing = NO; [self revealControls]; }
-(void)skipPressed { [self revealControls]; if (self.onSkip) self.onSkip(); }
-(void)nextPressed { [self revealControls]; if (self.onNext) self.onNext(); }
-(void)attachPlayer:(AVPlayer*)player {
    [self loadViewIfNeeded];
    self.nativePlayer.player=player; // Retain the existing public getPlayer compatibility API.
    self.videoSurface.playerLayer.player=player;
    if (!self.pipController && [AVPictureInPictureController isPictureInPictureSupported]) {
        self.pipController=[[AVPictureInPictureController alloc] initWithPlayerLayer:self.videoSurface.playerLayer];
        self.pipController.delegate=self;
        if (@available(iOS 14.2, *)) self.pipController.canStartPictureInPictureAutomaticallyFromInline=YES;
    }
}
-(void)tearDownPlayback {
    self.closing=YES; self.pipController.delegate=nil;
    if (self.pipController.isPictureInPictureActive) [self.pipController stopPictureInPicture];
    self.pipController=nil; self.videoSurface.playerLayer.player=nil; self.nativePlayer.player=nil;
}
-(void)showPiPMessage:(NSString*)message {
    UIAlertController* alert=[UIAlertController alertControllerWithTitle:@"Картинка в картинке" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"ОК" style:UIAlertActionStyleCancel handler:nil]];
    if (!self.presentedViewController && self.presentingViewController) [self presentViewController:alert animated:YES completion:nil];
}
-(void)startPiP {
    [self revealControls];
    if (!self.pipController) { [self showPiPMessage:@"Устройство не поддерживает плавающее окно для этого видео."]; return; }
    if (self.pipController.isPictureInPictureActive) return;
    if (!self.pipController.isPictureInPicturePossible) { [self showPiPMessage:@"Плавающее окно пока недоступно. Дождись загрузки видео и попробуй снова. Доступность также зависит от формата потока и системных настроек."]; return; }
    [self.pipController startPictureInPicture];
}
-(void)showAirPlay {
    UIViewController* routes=[UIViewController new]; routes.view.backgroundColor=UIColor.secondarySystemBackgroundColor;
    routes.preferredContentSize=CGSizeMake(280,100); routes.modalPresentationStyle=UIModalPresentationPopover;
    UILabel* title=[UILabel new]; title.text=@"Выбрать устройство AirPlay"; title.font=[UIFont systemFontOfSize:15]; title.textColor=UIColor.labelColor; title.frame=CGRectMake(16,8,248,28);
    AVRoutePickerView* picker=[[AVRoutePickerView alloc] initWithFrame:CGRectMake(114,40,52,52)]; picker.tintColor=UIColor.labelColor; picker.activeTintColor=UIColor.systemBlueColor; picker.prioritizesVideoDevices=YES;
    [routes.view addSubview:title]; [routes.view addSubview:picker];
    routes.popoverPresentationController.sourceView=self.moreButton; routes.popoverPresentationController.sourceRect=self.moreButton.bounds;
    routes.popoverPresentationController.delegate=self;
    [self presentViewController:routes animated:YES completion:nil];
}
-(UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController*)controller { return UIModalPresentationNone; }
-(void)speedPressed {
    [self revealControls]; self.menuOpen=YES;
    UIAlertController* menu=[UIAlertController alertControllerWithTitle:@"Скорость воспроизведения" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak PlayerViewController* weakSelf=self;
    for (NSNumber* value in @[@0.5,@1.0,@1.25,@1.5,@2.0]) {
        [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@×",value] style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            PlayerViewController* owner=weakSelf; owner.menuOpen=NO; if (!owner || owner.loading) return;
            owner.preferredRate=value.floatValue;
            if (owner.onSeek) owner.onSeek();
            if (owner.nativePlayer.player.rate>0) owner.nativePlayer.player.rate=owner.preferredRate;
            [owner revealControls]; [owner.view setNeedsLayout];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action) { weakSelf.menuOpen=NO; [weakSelf revealControls]; }]];
    menu.popoverPresentationController.sourceView=self.speedButton; menu.popoverPresentationController.sourceRect=self.speedButton.bounds; menu.popoverPresentationController.delegate=self;
    [self presentViewController:menu animated:YES completion:nil];
}
-(void)finishMenu:(UIAlertController*)menu action:(void (^)(void))action {
    // Dismiss the sheet, never the full-screen player, before showing another UI.
    if (menu.presentingViewController) [menu dismissViewControllerAnimated:YES completion:action];
    else if (action) action();
}
-(void)morePressed {
    [self revealControls]; self.menuOpen=YES;
    UIAlertController* menu=[UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak PlayerViewController* weakSelf=self;
    __weak UIAlertController* weakMenu=menu;
    [menu addAction:[UIAlertAction actionWithTitle:@"Картинка в картинке" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        PlayerViewController* owner=weakSelf; owner.menuOpen=NO;
        [owner finishMenu:weakMenu action:^{ [weakSelf startPiP]; }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"AirPlay" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        PlayerViewController* owner=weakSelf; owner.menuOpen=NO;
        [owner finishMenu:weakMenu action:^{ [weakSelf showAirPlay]; }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Метки и диагностика автоскипа" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        PlayerViewController* owner=weakSelf; owner.menuOpen=NO;
        [owner finishMenu:weakMenu action:^{ if (weakSelf.onOpening) weakSelf.onOpening(); [weakSelf refreshTransport]; }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action) { weakSelf.menuOpen=NO; [weakSelf revealControls]; }]];
    menu.popoverPresentationController.sourceView=self.moreButton; menu.popoverPresentationController.sourceRect=self.moreButton.bounds;
    menu.popoverPresentationController.delegate=self;
    [self presentViewController:menu animated:YES completion:nil];
}
-(void)presentationControllerDidDismiss:(UIPresentationController*)controller { self.menuOpen=NO; [self revealControls]; }
-(void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController*)controller { if (controller==self.pipController) self.pipActive=YES; }
-(void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController*)controller {
    if (controller!=self.pipController) return;
    self.pipActive=YES; self.overlayHidden=YES;
    // Keep PlayerController and the visible source layer alive while browsing the app.
    if (UIApplication.sharedApplication.applicationState==UIApplicationStateActive && self.presentingViewController && !self.presentedViewController) [self dismissViewControllerAnimated:YES completion:nil];
}
-(void)pictureInPictureController:(AVPictureInPictureController*)controller failedToStartPictureInPictureWithError:(NSError*)error {
    if (controller!=self.pipController) return;
    self.pipActive=NO; [self revealControls]; [self showPiPMessage:error.localizedDescription ?: @"Не удалось запустить плавающее окно."];
}
-(void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController*)controller {
    if (controller!=self.pipController) return;
    self.pipActive=NO;
    if (!self.presentingViewController && !self.restoringPiP && !self.closing) { self.closing=YES; if (self.onClose) self.onClose(); }
    else [self revealControls];
}
-(void)pictureInPictureController:(AVPictureInPictureController*)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completion {
    if (controller!=self.pipController || self.closing) { completion(NO); return; }
    if (self.presentingViewController) { [self revealControls]; completion(YES); return; }
    self.restoringPiP=YES;
    UIViewController* top=nil;
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState!=UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow* window in ((UIWindowScene*)scene).windows) if (window.isKeyWindow) top=window.rootViewController;
    }
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top=top.presentedViewController;
    if (!top || top.isBeingDismissed) { self.restoringPiP=NO; completion(NO); return; }
    [top presentViewController:self animated:YES completion:^{ self.restoringPiP=NO; [self revealControls]; completion(YES); }];
}
-(void)closePressed { self.closing = YES; if (self.onClose) self.onClose(); [self dismissViewControllerAnimated:YES completion:nil]; }
-(void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; if (self.isBeingDismissed && !self.pipActive && !self.closing && self.onClose) self.onClose(); }
-(UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }
@end

@interface PlayerController () {
    discovery::WatchSampler _watchSampler;
}
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, NSString*>* releaseGenres;
@property(nonatomic, strong) NSMutableSet<NSNumber*>* watchSeconds;
@property(nonatomic, copy) NSString* watchStoreKey;
@property(nonatomic, copy) NSString* watchReleaseKey;
@property(nonatomic, copy) NSString* watchEpisodeKey;
@property(nonatomic) double watchDuration;
@property(nonatomic) double watchLastFlush;
@property(nonatomic) BOOL watchDirty;
@property(nonatomic) anixart::ReleaseID release_id;
@property(nonatomic) anixart::EpisodeSourceID source_id;
@property(nonatomic) long source_position;
@property(nonatomic, strong) PlayerViewController* player_view_controller;
@property(nonatomic, strong) AVPlayer* observedPlayer;
@property(nonatomic, strong) AVPlayerItem* observedItem;
@property(nonatomic, strong) id timeObserver;
@property(nonatomic, strong) id openingBoundaryObserver;
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
@property(nonatomic) double pendingOpeningStart;
@property(nonatomic) BOOL previewingOpening;
@property(nonatomic, strong) NSDictionary* openingCandidate;
@property(nonatomic, strong) NSURLSessionDataTask* openingRequest;
@property(nonatomic) NSUInteger openingRequestVersion;
@property(nonatomic, copy) NSString* openingStatus;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, NSDictionary*>* releaseMetadata;
@property(nonatomic, copy) NSDictionary<NSNumber*, NSString*>* episodeNames;
@property(nonatomic) BOOL mappingAttempted;
@property(nonatomic) NSTimeInterval lastJikanRequest;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*,NSArray<NSString*>*>* releaseSearchQueries;
@property(nonatomic, copy) NSArray<NSString*>* mappingQueries;
@property(nonatomic) NSUInteger mappingQueryIndex;
@property(nonatomic) double openingDeadline;
-(NSDictionary*)currentReleaseMetadata;
-(NSDictionary*)automaticOpeningBinding;
-(void)resolveAutomaticOpening;
-(void)requestAnimePage:(NSInteger)page metadata:(NSDictionary*)metadata candidates:(NSArray*)candidates generation:(NSUInteger)generation version:(NSUInteger)version;
-(NSDictionary*)openingRecord;
-(NSString*)openingMediaIdentity;
-(NSDictionary*)openingBinding;
-(void)showOpeningMenu;
-(void)fetchOpeningCandidate;
-(void)installOpeningBoundaries;
-(void)editOpeningBounds;
-(void)configureOpeningBinding;
-(void)reviewOpeningCandidate;
-(void)presentOpeningAlert:(UIAlertController*)alert;
-(void)showOpeningDiagnostics;
-(void)saveWatchHistory;
-(void)beginWatchTracking;
-(void)sampleWatchAt:(double)seconds;
-(void)applicationBackgrounded;
-(void)performOpeningRequest:(NSURLRequest*)request attempt:(NSUInteger)attempt generation:(NSUInteger)generation version:(NSUInteger)version completion:(void(^)(NSData*,NSURLResponse*,NSError*))completion;
-(BOOL)advanceOpeningQuery:(NSDictionary*)metadata generation:(NSUInteger)generation version:(NSUInteger)version;
-(void)watchHistoryReset:(NSNotification*)notification;
@end

@implementation PlayerController
-(instancetype)init {
    if ((self = [super init])) {
        _positions = @[];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationBackgrounded) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(watchHistoryReset:) name:@"AniWatchHistoryReset" object:nil];
    }
    return self;
}
-(void)setOpeningStatus:(NSString*)status {
    _openingStatus = [status copy];
    if (!self.player_view_controller.isViewLoaded) return;
    BOOL applied = [status containsString:@"Применено автоматически"] || [status containsString:@"Границы сохранены"];
    NSString* badge=applied ? @"Опенинг · готов" : ([status containsString:@"…"] ? @"AniSkip · загрузка" : @"Опенинг · нет данных");
    if ([status containsString:@"нет op-разметки"]) badge=@"Опенинг · нет разметки";
    if ([status containsString:@"Версия видео отличается"]) badge=@"Опенинг · проверить";
    self.player_view_controller.playbackStatusLabel.text = status.length ? badge : @"";
}
-(void)showOpeningDiagnostics {
    NSDictionary* binding = [self openingBinding];
    double duration = CMTimeGetSeconds(self.observedItem.duration);
    NSDictionary* metadata = [self currentReleaseMetadata];
    NSString* details = [NSString stringWithFormat:@"Релиз: %@\nПозиция источника: %ld\nMAL: %@\nСерия MAL: %@\nДлительность видео: %@\nИсточник привязки: %@\nСтатус: %@", metadata[@"query"] ?: @"нет данных", self.source_position, binding[@"mal"] ?: @"не найден", binding ? @((long)(self.source_position + [binding[@"offset"] longValue])) : @"не определена", std::isfinite(duration) ? [NSString stringWithFormat:@"%.3f с", duration] : @"ещё неизвестна", [binding[@"automatic"] boolValue] ? @"автоматически" : (binding ? @"ручная поправка" : @"нет"), self.openingStatus ?: @"нет данных"];
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Диагностика AniSkip" message:details preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Скопировать" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) { UIPasteboard.generalPasteboard.string = details; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Закрыть" style:UIAlertActionStyleCancel handler:nil]];
    [self presentOpeningAlert:alert];
}
-(AppSettingsDataController*)settings { return [[AppDataController sharedInstance] getSettingsController]; }
-(void)setEpisodePositions:(NSArray<NSNumber*>*)positions { self.positions = [positions sortedArrayUsingSelector:@selector(compare:)]; }
-(void)registerReleaseMetadata:(anixart::Release::Ptr)release {
    if (!release) return;
    if (!self.releaseGenres) self.releaseGenres = [NSMutableDictionary new];
    self.releaseGenres[@(static_cast<int64_t>(release->id))] = TO_NSSTRING(release->genres) ?: @"";
    if (self.watchSeconds.count && static_cast<int64_t>(release->id) == self.watchReleaseKey.longLongValue) self.watchDirty = YES;
    NSArray* raw = @[TO_NSSTRING(release->title_original) ?: @"", TO_NSSTRING(release->title_alt) ?: @"", TO_NSSTRING(release->title_ru) ?: @""];
    NSMutableOrderedSet<NSString*>* titles = [NSMutableOrderedSet new];
    NSMutableOrderedSet<NSString*>* searches=[NSMutableOrderedSet new];
    NSString* query = nil;
    for (NSString* title in raw) {
        // Split explicit alias separators, not slashes in titles such as Fate/stay night.
        NSString* separated = [[title stringByReplacingOccurrencesOfString:@" / " withString:@"\n"] stringByReplacingOccurrencesOfString:@" | " withString:@"\n"];
        for (NSString* alias in [separated componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\n;" ]]) {
            NSString* trimmed = [alias stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!query.length && trimmed.length) query = trimmed;
            if (trimmed.length>=3) [searches addObject:trimmed];
            NSString* normalized = PlaybackNormalizedTitle(trimmed);
            if (normalized.length >= 3) [titles addObject:normalized];
        }
    }
    if (!self.releaseSearchQueries) self.releaseSearchQueries=[NSMutableDictionary new];
    self.releaseSearchQueries[@(static_cast<int64_t>(release->id))]=[searches.array subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)3,searches.count))];
    NSString* yearText = TO_NSSTRING(release->year) ?: @"";
    NSRegularExpression* yearPattern = [NSRegularExpression regularExpressionWithPattern:@"^[12][0-9]{3}$" options:0 error:NULL];
    NSInteger year = [yearPattern firstMatchInString:yearText options:0 range:NSMakeRange(0, yearText.length)] ? yearText.integerValue : 0;
    NSDictionary* metadata = @{@"query": query ?: @"", @"titles": titles.array, @"year": @(year), @"episodes": @(release->episodes_total), @"category": @(static_cast<int>(release->category))};
    if (!self.releaseMetadata) self.releaseMetadata = [NSMutableDictionary new];
    if (self.releaseMetadata.count >= 200) [self.releaseMetadata removeAllObjects];
    self.releaseMetadata[@(static_cast<int64_t>(release->id))] = metadata;
}
-(void)setEpisodeNames:(NSDictionary<NSNumber*, NSString*>*)names { _episodeNames = [names copy]; }
-(NSDictionary*)currentReleaseMetadata { return self.releaseMetadata[@(static_cast<int64_t>(self.release_id))]; }
-(long)automaticEpisodeForTotal:(long)total {
    std::vector<long> positions, numbers;
    static NSRegularExpression* pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"^(?:(?:серия|эпизод|episode|ep\\.?)\\s*[№#]?\\s*)?([0-9]{1,6})(?:\\s*[-–]?\\s*(?:я|ая|th|st|nd|rd))?(?:\\s*(?:серия|эпизод|episode))?(?:\\s*(?:из|of)\\s*[0-9]{1,6})?$" options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    for (NSNumber* position in self.positions) {
        NSString* label = [self.episodeNames[position] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
        NSTextCheckingResult* match = [pattern firstMatchInString:label options:0 range:NSMakeRange(0, label.length)];
        long number = match ? [[label substringWithRange:[match rangeAtIndex:1]] longLongValue] : (label.length ? -1 : 0);
        // A literal "0" is a special, not a missing name.
        positions.push_back(position.longValue); numbers.push_back(match && !number ? -1 : number);
    }
    return playback::mappedEpisode(positions, numbers, self.source_position, total);
}
-(NSDictionary*)automaticOpeningBinding {
    if (![[[self settings] getSettingsObjectAtKey:@"aniskip_auto_lookup"] boolValue]) return nil;
    NSDictionary* metadata = [self currentReleaseMetadata];
    playback::AnimeIdentity identity;
    for (NSString* title in metadata[@"titles"]) identity.titles.push_back(TO_STDSTRING(title));
    identity.year = [metadata[@"year"] intValue]; identity.episodes = [metadata[@"episodes"] intValue]; identity.category = [metadata[@"category"] intValue];
    long verified = playback::verifiedAnime(identity);
    if (verified) {
        long episode = [self automaticEpisodeForTotal:12];
        if (episode) return @{@"mal": @(verified), @"offset": @(episode - self.source_position), @"automatic": @YES};
    }
    NSString* key = [NSString stringWithFormat:@"%lld", (long long)static_cast<int64_t>(self.release_id)];
    id cache = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"aniskip_mal_cache_v4"][key];
    if (![cache isKindOfClass:NSDictionary.class] || ![cache[@"metadata"] isEqual:metadata] ||
        !PlaybackPositiveInteger(cache[@"mal"], 1000000000) || !PlaybackPositiveInteger(cache[@"episodes"], 1000000) || !PlaybackRealNumber(cache[@"saved"])) return nil;
    double age = NSDate.date.timeIntervalSince1970 - [cache[@"saved"] doubleValue];
    long mal = [cache[@"mal"] longValue], total = [cache[@"episodes"] longValue];
    if (!std::isfinite(age) || age < 0 || age > 7 * 86400 || mal <= 0 || mal > 1000000000 || total <= 0) return nil;
    long episode = [self automaticEpisodeForTotal:total];
    if (!episode) { self.openingStatus = @"Не удалось однозначно определить номер серии. Можно указать привязку вручную."; return nil; }
    return @{@"mal": @(mal), @"offset": @(episode - self.source_position), @"automatic": @YES};
}
-(void)performOpeningRequest:(NSURLRequest*)request attempt:(NSUInteger)attempt generation:(NSUInteger)generation version:(NSUInteger)version completion:(void(^)(NSData*,NSURLResponse*,NSError*))completion {
    if (generation!=self.generation || version!=self.openingRequestVersion) return;
    if (![[[self settings] getSettingsObjectAtKey:@"aniskip_auto_lookup"] boolValue]) { self.openingStatus=@"Сетевые запросы AniSkip отключены в настройках."; return; }
    double remaining=self.openingDeadline-NSProcessInfo.processInfo.systemUptime;
    if (remaining<=0) {
        completion(nil,nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:@{NSLocalizedDescriptionKey:@"Лимит автопоиска 45 секунд исчерпан. Можно повторить в меню Опенинг."}]); return;
    }
    if ([request.URL.host isEqualToString:@"api.jikan.moe"]) self.lastJikanRequest=NSProcessInfo.processInfo.systemUptime;
    NSMutableURLRequest* limited=[request mutableCopy]; limited.timeoutInterval=MIN(request.timeoutInterval,remaining);
    __weak PlayerController* weakSelf=self;
    self.openingRequest=[NSURLSession.sharedSession dataTaskWithRequest:limited completionHandler:^(NSData* data,NSURLResponse* response,NSError* error) {
        dispatch_async(dispatch_get_main_queue(),^{
            PlayerController* owner=weakSelf;
            if (!owner || generation!=owner.generation || version!=owner.openingRequestVersion) return;
            owner.openingRequest=nil;
            NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)response).statusCode : 0;
            BOOL transient=playback::retryOpeningRequest((int)status, error.code, error && [error.domain isEqualToString:NSURLErrorDomain], attempt);
            if (transient) {
                NSTimeInterval delay=(attempt+1)*1.5;
                if ([response isKindOfClass:NSHTTPURLResponse.class]) {
                    NSString* header=[((NSHTTPURLResponse*)response) valueForHTTPHeaderField:@"Retry-After"];
                    if (header.doubleValue>0) delay=MIN(8,MAX(delay,header.doubleValue));
                }
                if (NSProcessInfo.processInfo.systemUptime+delay>=owner.openingDeadline) { completion(data,response,error); return; }
                owner.openingStatus=[NSString stringWithFormat:@"Сервис занят/соединение прервано. Повтор %lu/2…",(unsigned long)attempt+1];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                    [weakSelf performOpeningRequest:request attempt:attempt+1 generation:generation version:version completion:completion];
                });
                return;
            }
            completion(data,response,error);
        });
    }];
    [self.openingRequest resume];
}
-(BOOL)advanceOpeningQuery:(NSDictionary*)metadata generation:(NSUInteger)generation version:(NSUInteger)version {
    if (generation!=self.generation || version!=self.openingRequestVersion || self.mappingQueryIndex+1>=self.mappingQueries.count) return NO;
    self.mappingQueryIndex+=1;
    [self requestAnimePage:1 metadata:metadata candidates:@[] generation:generation version:version]; return YES;
}

-(void)resolveAutomaticOpening {
    if (![[[self settings] getSettingsObjectAtKey:@"aniskip_auto_lookup"] boolValue] || self.mappingAttempted) return;
    self.mappingAttempted = YES;
    if (self.openingDeadline<=0) self.openingDeadline=NSProcessInfo.processInfo.systemUptime+45;
    NSDictionary* metadata = [self currentReleaseMetadata];
    if (!metadata) {
        NSUInteger generation = self.generation;
        anixart::ReleaseID releaseID = self.release_id;
        __block anixart::Release::Ptr release;
        __weak PlayerController* weakSelf = self;
        [[LibanixartApi sharedInstance] asyncCall:^BOOL(anixart::Api* api) {
            release = api->releases().get_release(releaseID); return !release;
        } completion:^(BOOL errored) {
            PlayerController* owner = weakSelf;
            if (!owner || generation != owner.generation) return;
            if (errored || !release) { owner.openingStatus = @"Не удалось загрузить данные сезона. Просмотр продолжается без автопропуска."; return; }
            [owner registerReleaseMetadata:release]; owner.mappingAttempted = NO;
            if (owner.ready) [owner fetchOpeningCandidate];
        }];
        return;
    }
    if (![metadata[@"query"] length] || ![metadata[@"titles"] count] ||
        (![metadata[@"year"] intValue] && ![metadata[@"episodes"] intValue]) ||
        (![metadata[@"category"] intValue] && (![metadata[@"year"] intValue] || ![metadata[@"episodes"] intValue]))) {
        self.openingStatus = @"Недостаточно данных каталога для безопасного поиска сезона; можно указать MAL ID вручную."; return;
    }
    self.mappingQueries=self.releaseSearchQueries[@(static_cast<int64_t>(self.release_id))] ?: @[metadata[@"query"]]; self.mappingQueryIndex=0;
    ++self.openingRequestVersion; [self.openingRequest cancel];
    [self requestAnimePage:1 metadata:metadata candidates:@[] generation:self.generation version:self.openingRequestVersion];
}
-(void)requestAnimePage:(NSInteger)page metadata:(NSDictionary*)metadata candidates:(NSArray*)candidates generation:(NSUInteger)generation version:(NSUInteger)version {
    if (generation != self.generation || version != self.openingRequestVersion || ![[[self settings] getSettingsObjectAtKey:@"aniskip_auto_lookup"] boolValue]) return;
    // One queue per player, at least 1.1 seconds apart, including repeated manual retries.
    NSTimeInterval wait = MAX(0, self.lastJikanRequest + 1.1 - NSProcessInfo.processInfo.systemUptime);
    if (wait > 0.001) {
        __weak PlayerController* weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf requestAnimePage:page metadata:metadata candidates:candidates generation:generation version:version];
        }); return;
    }
    self.lastJikanRequest = NSProcessInfo.processInfo.systemUptime;
    NSString* search=self.mappingQueryIndex<self.mappingQueries.count ? self.mappingQueries[self.mappingQueryIndex] : metadata[@"query"];
    self.openingStatus=[NSString stringWithFormat:@"Поиск сезона: %@ (%lu/%lu)…",search,(unsigned long)self.mappingQueryIndex+1,(unsigned long)MAX((NSUInteger)1,self.mappingQueries.count)];
    NSURLComponents* components = [NSURLComponents componentsWithString:@"https://api.jikan.moe/v4/anime"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:search], [NSURLQueryItem queryItemWithName:@"limit" value:@"25"], [NSURLQueryItem queryItemWithName:@"page" value:[@(page) stringValue]]];
    NSURLRequest* request = [NSURLRequest requestWithURL:components.URL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:20];
    __weak PlayerController* weakSelf = self;
    [self performOpeningRequest:request attempt:0 generation:generation version:version completion:^(NSData* data, NSURLResponse* response, NSError* error) {
        id json = nil;
        if (!error && [response isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse*)response).statusCode == 200 && data.length && data.length <= 2 * 1024 * 1024)
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            PlayerController* owner = weakSelf;
            if (!owner || generation != owner.generation || version != owner.openingRequestVersion) return;
            owner.openingRequest = nil;
            if (![[[owner settings] getSettingsObjectAtKey:@"aniskip_auto_lookup"] boolValue]) return;
            if (![json isKindOfClass:NSDictionary.class] || ![json[@"data"] isKindOfClass:NSArray.class] || ![json[@"pagination"] isKindOfClass:NSDictionary.class] ||
                ![json[@"pagination"][@"has_next_page"] isKindOfClass:NSNumber.class]) {
                owner.openingStatus=error ? [NSString stringWithFormat:@"Поиск MAL: %@",error.localizedDescription] : @"База MyAnimeList недоступна или ограничила запросы. Просмотр продолжается без автопропуска."; return;
            }
            NSMutableArray* all = [candidates mutableCopy]; [all addObjectsFromArray:json[@"data"]];
            if ([json[@"pagination"][@"has_next_page"] boolValue]) {
                if (page >= 3) {
                    if ([owner advanceOpeningQuery:metadata generation:generation version:version]) return;
                    owner.openingStatus=@"Слишком широкий поиск по доступным названиям. Нужна ручная привязка MAL."; return;
                }
                [owner requestAnimePage:page + 1 metadata:metadata candidates:all generation:generation version:version]; return;
            }
            playback::AnimeIdentity source;
            for (NSString* title in metadata[@"titles"]) source.titles.push_back(TO_STDSTRING(title));
            source.year = [metadata[@"year"] intValue]; source.episodes = [metadata[@"episodes"] intValue]; source.category = [metadata[@"category"] intValue];
            std::vector<playback::AnimeIdentity> matches;
            long total = 0;
            for (id value in all) {
                if (![value isKindOfClass:NSDictionary.class]) continue;
                NSDictionary* row = value;
                if (!PlaybackPositiveInteger(row[@"mal_id"], 1000000000) || ![row[@"type"] isKindOfClass:NSString.class] || ![row[@"titles"] isKindOfClass:NSArray.class]) continue;
                playback::AnimeIdentity candidate; candidate.ongoing=[row[@"status"] isEqual:@"Currently Airing"]; candidate.mal = [row[@"mal_id"] longValue]; candidate.episodes = PlaybackPositiveInteger(row[@"episodes"],1000000) ? [row[@"episodes"] intValue] : 0;
                candidate.year = PlaybackPositiveInteger(row[@"year"], 9999) ? [row[@"year"] intValue] : 0;
                // Jikan's year is null for many OVA/ONA entries. aired.from is the premiere year.
                if (!candidate.year && [row[@"aired"] isKindOfClass:NSDictionary.class] && [row[@"aired"][@"from"] isKindOfClass:NSString.class]) {
                    NSString* date = row[@"aired"][@"from"]; if (date.length >= 4) candidate.year = [[date substringToIndex:4] intValue];
                }
                NSString* type = row[@"type"];
                candidate.category = [@[@"TV", @"ONA"] containsObject:type] ? 1 : ([type isEqual:@"Movie"] ? 2 : ([@[@"OVA", @"Special", @"TV Special"] containsObject:type] ? 3 : 0));
                // Anixart may classify an ONA as OVA; only allow this where the source explicitly says OVA.
                if (source.category == 3 && [type isEqual:@"ONA"]) candidate.category = 3;
                for (id titleRow in row[@"titles"]) if ([titleRow isKindOfClass:NSDictionary.class] && [titleRow[@"title"] isKindOfClass:NSString.class]) {
                    NSString* title = PlaybackNormalizedTitle(titleRow[@"title"]); if (title.length) candidate.titles.push_back(TO_STDSTRING(title));
                }
                matches.push_back(candidate);
            }
            long mal = playback::uniqueAnime(source, matches, true);
            for (const auto& candidate : matches) if (candidate.mal == mal) total = candidate.episodes>0 ? candidate.episodes : 1000000;
            if (!mal || total<=0) {
                std::set<long> matchingIDs;
                for (const auto& candidate:matches) if (playback::matchingAnime(source,candidate)) matchingIDs.insert(candidate.mal);
                if (matchingIDs.empty() && [owner advanceOpeningQuery:metadata generation:generation version:version]) return;
                owner.openingStatus=matchingIDs.size()>1 ? @"Найдено несколько сезонов с совпадающими данными. Нужна ручная привязка MAL." : @"Сезон не найден по доступным названиям и данным каталога. Нужна ручная привязка MAL."; return;
            }
            NSMutableDictionary* cache = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"aniskip_mal_cache_v4"] mutableCopy] ?: [NSMutableDictionary new];
            NSString* key = [NSString stringWithFormat:@"%lld", (long long)static_cast<int64_t>(owner.release_id)];
            // Bounded positive cache; failures are not persisted.
            if (cache.count >= 200) [cache removeAllObjects];
            cache[key] = @{@"metadata": metadata, @"mal": @(mal), @"episodes": @(total), @"saved": @(NSDate.date.timeIntervalSince1970)};
            [[NSUserDefaults standardUserDefaults] setObject:cache forKey:@"aniskip_mal_cache_v4"];
            if ([owner automaticOpeningBinding]) [owner fetchOpeningCandidate];
        });
    }];
}

-(NSNumber*)nextPosition {
    std::vector<long> positions;
    for (NSNumber* item in self.positions) positions.push_back(item.longValue);
    long next = playback::nextPosition(positions, self.source_position);
    return next < 0 ? nil : @(next);
}
-(void)watchHistoryReset:(NSNotification*)notification {
    if ([notification.object isEqual:self.watchStoreKey]) {
        [self.watchSeconds removeAllObjects]; self.watchDirty = NO; _watchSampler.reset();
    }
}
-(void)applicationBackgrounded {
    [self saveProgress]; [self saveWatchHistory]; _watchSampler.reset();
}
-(void)beginWatchTracking {
    _watchSampler.reset(); self.watchSeconds = [NSMutableSet new]; self.watchDirty = NO;
    self.watchStoreKey = nil; self.watchEpisodeKey = nil; self.watchReleaseKey = nil; self.watchDuration = 0;
    if (!self.progressKey) return;
    NSArray<NSString*>* parts = [self.progressKey componentsSeparatedByString:@":"];
    if (parts.count != 4) return;
    self.watchStoreKey = AniWatchKey(parts[0].longLongValue); self.watchReleaseKey = parts[1];
    long episode = [self automaticEpisodeForTotal:[[self currentReleaseMetadata][@"episodes"] longValue]];
    self.watchEpisodeKey = episode > 0 ? [NSString stringWithFormat:@"episode:%ld", episode] : [NSString stringWithFormat:@"source:%@:%@", parts[2], parts[3]];
    self.watchDuration = CMTimeGetSeconds(self.observedItem.duration);
    NSDictionary* title = [[NSUserDefaults.standardUserDefaults dictionaryForKey:self.watchStoreKey] objectForKey:self.watchReleaseKey];
    NSDictionary* record = title[@"episodes"][self.watchEpisodeKey];
    // Do not transfer coverage to another montage with a different duration.
    if (std::isfinite(self.watchDuration) && std::abs([record[@"duration"] doubleValue] - self.watchDuration) <= 1) {
        self.watchSeconds = AniWatchSeconds(record, self.watchDuration);
    }
    self.watchLastFlush = NSProcessInfo.processInfo.systemUptime;
}
-(void)sampleWatchAt:(double)seconds {
    if (!self.watchStoreKey) return;
    BOOL sameProfile = [self.watchStoreKey isEqualToString:AniWatchKey((long long)static_cast<int64_t>([[AppDataController sharedInstance] getMyProfileID]))];
    BOOL visible = UIApplication.sharedApplication.applicationState == UIApplicationStateActive || self.player_view_controller.pipActive;
    BOOL active = sameProfile && visible && self.ready && !self.resumePending && !self.player_view_controller.scrubbing && self.observedPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying;
    double now = NSProcessInfo.processInfo.systemUptime;
    for (int second : _watchSampler.sample(seconds, now, self.observedPlayer.rate, self.watchDuration, active)) {
        NSNumber* value = @(second);
        if (![self.watchSeconds containsObject:value]) { [self.watchSeconds addObject:value]; self.watchDirty = YES; }
    }
    if (now - self.watchLastFlush >= 15) { [self saveWatchHistory]; self.watchLastFlush = now; }
}
-(void)saveWatchHistory {
    if (!self.watchDirty || !self.watchStoreKey || !self.watchReleaseKey || !self.watchEpisodeKey || !std::isfinite(self.watchDuration) || self.watchDuration <= 0) return;
    NSString* genres = self.releaseGenres[@(self.watchReleaseKey.longLongValue)] ?: @"";
    AniStoreWatch(self.watchStoreKey, self.watchReleaseKey, self.watchEpisodeKey, genres, self.watchSeconds, self.watchDuration);
    self.watchDirty = NO;
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
    [self saveWatchHistory]; _watchSampler.reset(); self.watchStoreKey = nil;
    [self saveProgress];
    ++self.openingRequestVersion; [self.openingRequest cancel]; self.openingRequest = nil;
    if (self.timeObserver) [self.observedPlayer removeTimeObserver:self.timeObserver];
    if (self.openingBoundaryObserver) [self.observedPlayer removeTimeObserver:self.openingBoundaryObserver];
    self.timeObserver = nil; self.openingBoundaryObserver = nil;
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

    self.player_view_controller.modalPresentationStyle = UIModalPresentationFullScreen;
    self.player_view_controller.nativePlayer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.player_view_controller.nativePlayer.showsPlaybackControls = NO;
    self.player_view_controller.view.backgroundColor = UIColor.blackColor;
    __weak PlayerController* weakSelf = self;
    __weak PlayerViewController* weakController = self.player_view_controller;
    self.player_view_controller.onClose = ^{
        PlayerController* owner = weakSelf;
        if (!owner || owner.player_view_controller != weakController) return;
        owner.generation += 1;
        [owner stopObserving];
        [owner.player_view_controller tearDownPlayback];
        owner.player_view_controller = nil;
    };
    self.player_view_controller.onSeek = ^{ PlayerController* owner = weakSelf; if (owner) owner->_watchSampler.reset(); };
    self.player_view_controller.onSkip = ^{ [weakSelf skipOpening]; };
    self.player_view_controller.onNext = ^{ [weakSelf playNextEpisode]; };
    self.player_view_controller.onOpening = ^{ [weakSelf showOpeningMenu]; };
}
-(void)playWithReleaseID:(anixart::ReleaseID)release_id sourceID:(anixart::EpisodeSourceID)source_id position:(long)position autoShow:(BOOL)auto_show completion:(void(^)(BOOL))completion {
    [self stopObserving];
    self.release_id = release_id; self.source_id = source_id; self.source_position = position;
    self.targetURL = nil; self.mappingAttempted = NO; self.openingDeadline=0;
    self.progressKey = [NSString stringWithFormat:@"%lld:%lld:%lld:%ld", (long long)static_cast<int64_t>([[AppDataController sharedInstance] getMyProfileID]), (long long)static_cast<int64_t>(release_id), (long long)static_cast<int64_t>(source_id), position];
    self.advancing = NO; self.openingHandled = NO; self.episodeCompleted = NO; self.errorShown = NO;
    self.pendingOpeningStart = -1; self.previewingOpening = NO; self.openingCandidate = nil; self.openingStatus = @"";
    NSUInteger generation = ++self.generation;
    [self prepareController];
    [self.player_view_controller setLoading:YES];
    [self.player_view_controller setSkipAvailable:NO nextAvailable:NO];
    if (auto_show) [self showViewController:self.player_view_controller];
    NSString* quality = [[self settings] getPrefferedQuality] ?: @"720";
    // Web playback was removed. Legacy saved preferences cannot bypass the native player.
    __block NSURL* target = nil;
    __block NSURL* stream = nil;
    [[LibanixartApi sharedInstance] asyncCall:^BOOL(anixart::Api* api) {
        auto episode = api->episodes().get_episode_target(release_id, source_id, (int32_t)position);
        target = [NSURL URLWithString:TO_NSSTRING(episode->url)];
        if (!target || ![@[@"https", @"http"] containsObject:target.scheme.lowercaseString]) return YES;
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
    self.pendingOpeningStart = -1; self.previewingOpening = NO; self.openingCandidate = nil; self.openingStatus = @"";
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
    [self.player_view_controller attachPlayer:self.observedPlayer];
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
        _watchSampler.reset();
        [self.observedPlayer seekToTime:CMTimeMakeWithSeconds(resume, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PlayerController* owner = weakSelf;
                if (!owner || generation != owner.generation) return;
                if (owner.observedItem.status != AVPlayerItemStatusReadyToPlay) { [owner showPlaybackError]; return; }
                owner.resumePending = NO;
                [owner beginWatchTracking];
                [owner.player_view_controller setLoading:NO];
                [owner updatePlaybackAt:CMTimeGetSeconds(owner.observedPlayer.currentTime)];
                if (generation != owner.generation) return;
                [owner installOpeningBoundaries];
                owner.observedPlayer.rate=owner.player_view_controller.preferredRate;
                NSDictionary* savedOpening = [owner openingRecord];
                if (!savedOpening) [owner fetchOpeningCandidate];
                else owner.openingStatus = [NSString stringWithFormat:@"Границы сохранены: %@–%@ (%@).", PlaybackTime([savedOpening[@"start"] doubleValue]), PlaybackTime([savedOpening[@"end"] doubleValue]), savedOpening[@"origin"] ?: @"локально"];
                owner.timeObserver = [owner.observedPlayer addPeriodicTimeObserverForInterval:CMTimeMake(1, 4) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
                    PlayerController* current = weakSelf;
                    if (!current || generation != current.generation) return;
                    double seconds = CMTimeGetSeconds(time);
                    [current sampleWatchAt:seconds];
                    [current.player_view_controller refreshTransport];
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
-(NSString*)openingMediaIdentity {
    if (!self.selected_stream_url) return nil;
    NSURLComponents* parts = [NSURLComponents componentsWithURL:self.selected_stream_url resolvingAgainstBaseURL:NO];
    parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil;
    return parts.URL.absoluteString;
}
-(NSDictionary*)openingRecord {
    if (!self.progressKey) return nil;
    id value = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"episode_openings_v3"][self.progressKey];
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary* record = value;
    if ([record[@"origin"] isKindOfClass:NSString.class] && [record[@"origin"] hasPrefix:@"AniSkip-"]) {
        // v4 fetched records had no mapping provenance. Refetch once; manual marks are untouched.
        if (!PlaybackPositiveInteger(record[@"mal"], 1000000000) || !PlaybackPositiveInteger(record[@"episode"], 1000000) ||
            ![record[@"metadata"] isEqual:[self currentReleaseMetadata]]) return nil;
        if ([[[self settings] getSettingsObjectAtKey:@"aniskip_auto_lookup"] boolValue]) {
            NSDictionary* binding = [self openingBinding];
            if (binding && ([binding[@"mal"] longLongValue] != [record[@"mal"] longLongValue] ||
                self.source_position + [binding[@"offset"] longValue] != [record[@"episode"] longValue])) return nil;
        }
    }
    if (![record[@"media"] isKindOfClass:NSString.class] || ![record[@"media"] isEqualToString:[self openingMediaIdentity]]) return nil;
    if (!PlaybackRealNumber(record[@"start"]) || !PlaybackRealNumber(record[@"end"]) || !PlaybackRealNumber(record[@"duration"]) ||
        ![record[@"confirmed"] isEqual:@YES]) return nil;
    double duration = CMTimeGetSeconds(self.observedItem.duration);
    double reference = [record[@"duration"] doubleValue];
    if (!std::isfinite(reference) || !playback::validOpeningInterval([record[@"start"] doubleValue], [record[@"end"] doubleValue], duration) ||
        std::abs(reference - duration) > 1.0) return nil;
    return record;
}
-(NSString*)openingBindingKey {
    if (!self.progressKey) return nil;
    NSArray<NSString*>* parts = [self.progressKey componentsSeparatedByString:@":"];
    return parts.count == 4 ? [[parts subarrayWithRange:NSMakeRange(0, 3)] componentsJoinedByString:@":"] : nil;
}
-(NSDictionary*)openingBinding {
    NSString* key = [self openingBindingKey];
    if (!key) return nil;
    id value = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"opening_mal_bindings"][key];
    if (![value isKindOfClass:NSDictionary.class]) return [self automaticOpeningBinding];
    NSDictionary* binding = value;
    if (!PlaybackRealNumber(binding[@"mal"]) || !PlaybackRealNumber(binding[@"offset"])) return [self automaticOpeningBinding];
    double mal = [binding[@"mal"] doubleValue], offset = [binding[@"offset"] doubleValue];
    if (!std::isfinite(mal) || mal < 1 || mal > 1000000000 || std::floor(mal) != mal || !std::isfinite(offset) || std::abs(offset) > 1000000 || std::floor(offset) != offset) return [self automaticOpeningBinding];
    return binding;
}
-(void)presentOpeningAlert:(UIAlertController*)alert {
    PlayerViewController* screen = self.player_view_controller;
    if (!screen) return;
    NSUInteger generation = self.generation;
    void (^present)(void) = ^{
        if (screen == self.player_view_controller && generation == self.generation && !screen.closing)
            [screen presentViewController:alert animated:YES completion:nil];
    };
    if (screen.presentedViewController) [screen dismissViewControllerAnimated:NO completion:present];
    else present();
}
-(void)openingMessage:(NSString*)message {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Опенинг" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"ОК" style:UIAlertActionStyleDefault handler:nil]];
    [self presentOpeningAlert:alert];
}
-(void)storeOpeningFrom:(double)begin to:(double)end origin:(NSString*)origin {
    double duration = CMTimeGetSeconds(self.observedItem.duration);
    if (!self.progressKey || ![self openingMediaIdentity].length || !playback::validOpeningInterval(begin, end, duration)) {
        [self openingMessage:@"Нужны границы этой серии: начало ≥ 0, конец позже начала хотя бы на секунду и раньше конца видео. Дождись загрузки длительности."]; return;
    }
    NSMutableDictionary* records = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"episode_openings_v3"] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary* record = [@{@"start": @(begin), @"end": @(end), @"duration": @(duration), @"confirmed": @YES, @"origin": origin, @"media": [self openingMediaIdentity]} mutableCopy];
    if ([origin hasPrefix:@"AniSkip-"]) {
        NSDictionary* binding = [self openingBinding]; NSDictionary* metadata = [self currentReleaseMetadata];
        if (binding && metadata) {
            record[@"mal"] = binding[@"mal"]; record[@"episode"] = @(self.source_position + [binding[@"offset"] longValue]); record[@"metadata"] = metadata;
        }
    }
    records[self.progressKey] = record;
    [[NSUserDefaults standardUserDefaults] setObject:records forKey:@"episode_openings_v3"];
    self.pendingOpeningStart = -1; self.previewingOpening = NO; self.openingHandled = NO; self.openingCandidate = nil;
    self.openingStatus = @"Границы сохранены только для этой серии, источника и длительности видео.";
    [self installOpeningBoundaries];
    [self updatePlaybackAt:CMTimeGetSeconds(self.observedPlayer.currentTime)];
}
-(void)showOpeningMenu {
    NSUInteger generation = self.generation;
    if (!self.ready || self.resumePending) return;
    if (!self.progressKey) { [self openingMessage:@"Разметка доступна для серии, открытой из списка эпизодов, а не для отдельной ссылки."]; return; }
    [self.observedPlayer pause];
    NSDictionary* record = [self openingRecord];
    NSString* description = record ? [NSString stringWithFormat:@"Сохранено %@–%@. %@", PlaybackTime([record[@"start"] doubleValue]), PlaybackTime([record[@"end"] doubleValue]), self.openingStatus ?: @""] : [NSString stringWithFormat:@"Точных границ для этого видео пока нет — ничего автоматически не вырезается. %@", self.openingStatus ?: @""];
    UIAlertController* menu = [UIAlertController alertControllerWithTitle:@"Опенинг текущей серии" message:description preferredStyle:UIAlertControllerStyleAlert];
    [menu addAction:[UIAlertAction actionWithTitle:@"Ввести начало и конец" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return; [self editOpeningBounds]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Начало опенинга сейчас" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
        double seconds = CMTimeGetSeconds(self.observedPlayer.currentTime);
        if (!std::isfinite(seconds) || seconds < 0) return;
        self.pendingOpeningStart = seconds; self.previewingOpening = YES;
        self.openingStatus = [NSString stringWithFormat:@"Начало %@. Дойди до конца опенинга и отметь конец.", PlaybackTime(seconds)];
        [self updatePlaybackAt:seconds];
        self.observedPlayer.rate=self.player_view_controller.preferredRate;
    }]];
    if (self.pendingOpeningStart >= 0) {
        [menu addAction:[UIAlertAction actionWithTitle:@"Конец опенинга сейчас — сохранить" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
            [self storeOpeningFrom:self.pendingOpeningStart to:CMTimeGetSeconds(self.observedPlayer.currentTime) origin:@"manual"];
        }]];
    }
    if (self.pendingOpeningStart >= 0 || self.previewingOpening) [menu addAction:[UIAlertAction actionWithTitle:@"Отменить разметку / просмотр" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
        self.pendingOpeningStart = -1; self.previewingOpening = NO;
    }]];
    if (self.openingCandidate) [menu addAction:[UIAlertAction actionWithTitle:@"Проверить таймкоды AniSkip" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return; [self reviewOpeningCandidate]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Диагностика AniSkip" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation == self.generation) [self showOpeningDiagnostics];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Повторить автопоиск / запрос AniSkip" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
        self.mappingAttempted = NO; self.openingDeadline=0; [self fetchOpeningCandidate];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"MAL ID вручную (необязательно)" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return; [self configureOpeningBinding]; }]];
    if (record) [menu addAction:[UIAlertAction actionWithTitle:@"Удалить границы этой серии" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
        NSMutableDictionary* records = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"episode_openings_v3"] mutableCopy];
        [records removeObjectForKey:self.progressKey]; [[NSUserDefaults standardUserDefaults] setObject:records forKey:@"episode_openings_v3"];
        self.pendingOpeningStart = -1; self.previewingOpening = NO; self.openingHandled = NO;
        [self installOpeningBoundaries];
        [self updatePlaybackAt:CMTimeGetSeconds(self.observedPlayer.currentTime)];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Вписать видео" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return; [self.player_view_controller fitVideo]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Продолжить просмотр" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action) {
        if (generation == self.generation) self.observedPlayer.rate=self.player_view_controller.preferredRate;
    }]];
    [self presentOpeningAlert:menu];
}
-(void)editOpeningBounds {
    NSUInteger generation = self.generation;
    NSDictionary* record = [self openingRecord];
    UIAlertController* editor = [UIAlertController alertControllerWithTitle:@"Границы только этой серии" message:@"Укажи начало и конец опенинга, не его длительность. Форматы: 90.5, 01:30.5 или 00:01:30.5. При смене серии или длительности эти метки не переносятся." preferredStyle:UIAlertControllerStyleAlert];
    [editor addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = @"Начало, например 00:30";
        if (record) field.text = [record[@"start"] stringValue];
        else if (self.pendingOpeningStart >= 0) field.text = [NSString stringWithFormat:@"%.3f", self.pendingOpeningStart];
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [editor addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = @"Конец, например 02:00"; if (record) field.text = [record[@"end"] stringValue];
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [editor addAction:[UIAlertAction actionWithTitle:@"Сохранить для этой серии" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
        double begin = playback::parseTimestamp(TO_STDSTRING(editor.textFields[0].text ?: @""));
        double end = playback::parseTimestamp(TO_STDSTRING(editor.textFields[1].text ?: @""));
        [self storeOpeningFrom:begin to:end origin:@"manual"];
    }]];
    [editor addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    [self presentOpeningAlert:editor];
}
-(void)invalidateFetchedOpenings {
    self.openingDeadline=0;
    NSString* prefix = [[self openingBindingKey] stringByAppendingString:@":"];
    if (!prefix.length) return;
    NSMutableDictionary* records = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"episode_openings_v3"] mutableCopy];
    for (NSString* key in records.allKeys) {
        id record = records[key];
        if ([key hasPrefix:prefix] && [record isKindOfClass:NSDictionary.class] &&
            [record[@"origin"] isKindOfClass:NSString.class] && [record[@"origin"] hasPrefix:@"AniSkip-"]) [records removeObjectForKey:key];
    }
    if (records) [[NSUserDefaults standardUserDefaults] setObject:records forKey:@"episode_openings_v3"];
    [self installOpeningBoundaries];
    [self updatePlaybackAt:CMTimeGetSeconds(self.observedPlayer.currentTime)];
}
-(void)configureOpeningBinding {
    NSUInteger generation = self.generation;
    NSDictionary* binding = [self openingBinding];
    UIAlertController* editor = [UIAlertController alertControllerWithTitle:@"Привязка AniSkip" message:@"Необязательная ручная поправка к автоматическому поиску: MyAnimeList ID этого сезона и номер текущей серии в нём. ID Anixart не подходит. Пустое поле удаляет ручную поправку и возвращает автопоиск; сеть можно отключить в настройках AniSkip. Подходящие таймкоды применяются автоматически." preferredStyle:UIAlertControllerStyleAlert];
    [editor addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = @"MyAnimeList ID сезона"; field.text = binding ? [binding[@"mal"] stringValue] : @""; field.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [editor addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = @"Номер текущей серии в MAL";
        if (binding) field.text = [NSString stringWithFormat:@"%ld", self.source_position + [binding[@"offset"] longValue]];
        field.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [editor addAction:[UIAlertAction actionWithTitle:@"Сохранить привязку" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
        NSString* key = [self openingBindingKey]; if (!key) return;
        NSString* mal = [editor.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString* episode = [editor.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableDictionary* bindings = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"opening_mal_bindings"] mutableCopy] ?: [NSMutableDictionary new];
        ++self.openingRequestVersion; [self.openingRequest cancel]; self.openingCandidate = nil;
        if (!mal.length) {
            [bindings removeObjectForKey:key]; [[NSUserDefaults standardUserDefaults] setObject:bindings forKey:@"opening_mal_bindings"];
            [self invalidateFetchedOpenings];
            self.mappingAttempted = NO; self.openingStatus = @"Ручная привязка удалена. Восстановлен автоматический поиск."; [self fetchOpeningCandidate]; return;
        }
        NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
        if (mal.length > 9 || !episode.length || episode.length > 6 || [mal rangeOfCharacterFromSet:invalid].location != NSNotFound ||
            [episode rangeOfCharacterFromSet:invalid].location != NSNotFound || mal.longLongValue < 1 || episode.longLongValue < 1 || std::abs((double)episode.longLongValue - self.source_position) > 1000000) {
            [self openingMessage:@"Нужны положительный числовой MAL ID и номер текущей серии. Не вставляй ID Anixart или полный URL."]; return;
        }
        bindings[key] = @{@"mal": @(mal.longLongValue), @"offset": @(episode.longLongValue - self.source_position)};
        [[NSUserDefaults standardUserDefaults] setObject:bindings forKey:@"opening_mal_bindings"];
        [self invalidateFetchedOpenings];
        [self fetchOpeningCandidate];
    }]];
    [editor addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    [self presentOpeningAlert:editor];
}
-(void)fetchOpeningCandidate {
    NSDictionary* binding = [self openingBinding];
    double duration = CMTimeGetSeconds(self.observedItem.duration);
    if (!self.ready || !self.progressKey || !std::isfinite(duration) || duration <= 0) return;
    if (self.openingDeadline<=0) self.openingDeadline=NSProcessInfo.processInfo.systemUptime+45;
    if (!binding) { [self resolveAutomaticOpening]; return; }
    if (![[[self settings] getSettingsObjectAtKey:@"aniskip_auto_lookup"] boolValue]) { self.openingStatus = @"Сетевые запросы AniSkip отключены в настройках."; return; }
    long episode = self.source_position + [binding[@"offset"] longValue];
    if (episode < 1 || episode > 1000000) { self.openingStatus = @"Номер серии вне привязки MAL. Проверь настройки."; return; }
    ++self.openingRequestVersion; [self.openingRequest cancel]; self.openingCandidate = nil;
    NSUInteger requestVersion = self.openingRequestVersion, generation = self.generation;
    NSURLComponents* components = [NSURLComponents componentsWithString:@"https://api.aniskip.com"];
    components.path = [NSString stringWithFormat:@"/v2/skip-times/%lld/%ld", [binding[@"mal"] longLongValue], episode];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"types" value:@"op"], [NSURLQueryItem queryItemWithName:@"episodeLength" value:@"0"]];
    NSURLRequest* request = [NSURLRequest requestWithURL:components.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    self.openingStatus = @"Запрашиваются таймкоды AniSkip…";
    __weak PlayerController* weakSelf = self;
    [self performOpeningRequest:request attempt:0 generation:generation version:requestVersion completion:^(NSData* data, NSURLResponse* response, NSError* error) {
        NSDictionary* candidate = nil;
        NSMutableArray<NSDictionary*>* needsReview = [NSMutableArray new];
        NSString* reason = error ? [NSString stringWithFormat:@"AniSkip: %@",error.localizedDescription] : @"Сервис недоступен или вернул некорректный ответ.";
        if (!error && [response isKindOfClass:NSHTTPURLResponse.class]) reason = [NSString stringWithFormat:@"AniSkip: HTTP %ld.", (long)((NSHTTPURLResponse*)response).statusCode];
        if (!error && [response isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse*)response).statusCode == 200 && data.length && data.length <= 1024 * 1024) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([json isKindOfClass:NSDictionary.class] && [json[@"results"] isKindOfClass:NSArray.class]) {
                NSMutableArray<NSDictionary*>* compatible = [NSMutableArray new];
                NSMutableSet<NSString*>* reported=[NSMutableSet new];
                reason = [NSString stringWithFormat:@"AniSkip: для MAL %@, серии %ld нет op-разметки.", binding[@"mal"], episode];
                for (id value in json[@"results"]) {
                    if (![value isKindOfClass:NSDictionary.class]) continue;
                    NSDictionary* row = value; id interval = row[@"interval"];
                    if (![row[@"skipType"] isEqual:@"op"] || ![interval isKindOfClass:NSDictionary.class] || !PlaybackRealNumber(interval[@"startTime"]) ||
                        !PlaybackRealNumber(interval[@"endTime"]) || !PlaybackRealNumber(row[@"episodeLength"])) continue;
                    double begin = [interval[@"startTime"] doubleValue], end = [interval[@"endTime"] doubleValue], reference = [row[@"episodeLength"] doubleValue];
                    if (!std::isfinite(reference) || !playback::validOpeningInterval(begin, end, duration)) { reason = @"AniSkip вернул некорректные границы опенинга."; continue; }
                    NSString* identity=[NSString stringWithFormat:@"%.6f:%.6f:%.6f",begin,end,reference];
                    if ([reported containsObject:identity]) continue; [reported addObject:identity];
                    if (std::abs(reference - duration) > 1.0) {
                        reason = [NSString stringWithFormat:@"Версия видео отличается: плеер %.3f с, AniSkip %.3f с (разница %.3f с). Автопропуск не применён.", duration, reference, std::abs(reference - duration)];
                        [needsReview addObject:@{@"start": @(begin), @"end": @(end), @"duration": @(duration), @"reference": @(reference), @"requiresReview": @YES}]; continue;
                    }
                    NSDictionary* intervalRecord=@{@"start":@(begin),@"end":@(end),@"duration":@(duration)};
                    if (![compatible containsObject:intervalRecord]) [compatible addObject:intervalRecord];
                }
                if (compatible.count == 1) candidate = compatible.firstObject;
                else if (!compatible.count && needsReview.count == 1) candidate = needsReview.firstObject;
                else if (compatible.count > 1) reason = @"AniSkip вернул несколько подходящих интервалов; требуется проверка.";
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            PlayerController* owner = weakSelf;
            if (!owner || generation != owner.generation || requestVersion != owner.openingRequestVersion) return;
            owner.openingRequest = nil;
            if (![[[owner settings] getSettingsObjectAtKey:@"aniskip_auto_lookup"] boolValue]) return;
            // Never overwrite the user's local correction or interrupt marking/preview.
            if (candidate && [candidate[@"requiresReview"] boolValue] && ![owner openingRecord]) {
                owner.openingCandidate = candidate;
                owner.openingStatus = [reason stringByAppendingString:@" Предложение доступно для ручной проверки в меню Опенинг."];
            } else if (candidate && ![owner openingRecord] && owner.pendingOpeningStart < 0 && !owner.previewingOpening) {
                [owner storeOpeningFrom:[candidate[@"start"] doubleValue] to:[candidate[@"end"] doubleValue] origin:@"AniSkip-auto"];
                owner.openingStatus = [NSString stringWithFormat:@"AniSkip: MAL %@, серия %ld, %@–%@. Длительность видео %.3f с. Применено автоматически.", binding[@"mal"], episode, PlaybackTime([candidate[@"start"] doubleValue]), PlaybackTime([candidate[@"end"] doubleValue]), duration];
            } else if (candidate && ![owner openingRecord]) {
                owner.openingCandidate = candidate; owner.openingStatus = @"Таймкоды доступны; ручная разметка имеет приоритет.";
            } else if (!candidate) {
                owner.openingStatus = reason;
            }
            [owner updatePlaybackAt:CMTimeGetSeconds(owner.observedPlayer.currentTime)];
        });
    }];
}
-(void)reviewOpeningCandidate {
    NSUInteger generation = self.generation;
    NSDictionary* candidate = self.openingCandidate; if (!candidate) return;
    double begin = [candidate[@"start"] doubleValue], end = [candidate[@"end"] doubleValue];
    NSString* message = [NSString stringWithFormat:@"%@–%@. Таймкоды сообщества могут отличаться для другой версии видео. Проверь начало и конец по самому видео. Эта разметка не переносится на другие серии.", PlaybackTime(begin), PlaybackTime(end)];
    if ([candidate[@"requiresReview"] boolValue]) message = [message stringByAppendingFormat:@"\nВНИМАНИЕ: длительности различаются — видео %.3f с, разметка %.3f с. Автоматически применять нельзя. Подтверждай только после проверки ОБЕИХ границ.", [candidate[@"duration"] doubleValue], [candidate[@"reference"] doubleValue]];
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Проверить опенинг AniSkip" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Посмотреть начало" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
        self.previewingOpening = YES;
        _watchSampler.reset();
        [self.observedPlayer seekToTime:CMTimeMakeWithSeconds(MAX(0, begin - 2), 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Посмотреть конец" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
        self.previewingOpening = YES;
        _watchSampler.reset();
        [self.observedPlayer seekToTime:CMTimeMakeWithSeconds(MAX(begin, end - 2), 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Границы верны — сохранить" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return; [self storeOpeningFrom:begin to:end origin:@"AniSkip-confirmed"]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Не подходит — удалить предложение" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
        self.openingCandidate = nil; self.previewingOpening = NO;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Закрыть" style:UIAlertActionStyleCancel handler:nil]];
    [self presentOpeningAlert:alert];
}
-(void)installOpeningBoundaries {
    if (self.openingBoundaryObserver) [self.observedPlayer removeTimeObserver:self.openingBoundaryObserver];
    self.openingBoundaryObserver = nil;
    NSDictionary* record = [self openingRecord];
    if (!record || !self.ready || !self.observedPlayer) return;
    NSArray<NSValue*>* times = @[
        [NSValue valueWithCMTime:CMTimeMakeWithSeconds([record[@"start"] doubleValue], 600)],
        [NSValue valueWithCMTime:CMTimeMakeWithSeconds([record[@"end"] doubleValue], 600)]
    ];
    NSUInteger generation = self.generation;
    __weak PlayerController* weakSelf = self;
    self.openingBoundaryObserver = [self.observedPlayer addBoundaryTimeObserverForTimes:times queue:dispatch_get_main_queue() usingBlock:^{
        PlayerController* owner = weakSelf;
        if (!owner || generation != owner.generation) return;
        [owner updatePlaybackAt:CMTimeGetSeconds(owner.observedPlayer.currentTime)];
    }];
}
-(double)openingTargetAt:(double)seconds {
    if (self.previewingOpening || self.pendingOpeningStart >= 0 || !self.progressKey) return -1;
    NSDictionary* record = [self openingRecord];
    if (!record) return -1;
    return playback::confirmedOpeningTarget(seconds, CMTimeGetSeconds(self.observedItem.duration),
        [record[@"start"] doubleValue], [record[@"end"] doubleValue], [record[@"duration"] doubleValue], [record[@"confirmed"] boolValue]);
}
-(void)skipOpening {
    if (!self.ready || self.resumePending) return;
    double target = [self openingTargetAt:CMTimeGetSeconds(self.observedPlayer.currentTime)];
    if (target < 0) return;
    self.openingHandled = YES;
    [self.player_view_controller setSkipAvailable:NO nextAvailable:[self nextPosition] != nil];
    NSUInteger generation = self.generation;
    _watchSampler.reset();
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
    NSUInteger generation = self.generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL matching = generation == self.generation && item == self.observedItem;
        if (!matching || self.advancing || !self.ready) return;
        [self markEpisodeCompleted];
        BOOL hasNext = [self nextPosition] != nil;
        if (playback::shouldAutoAdvance([[self settings] getAutoNextVideo], matching, self.ready, self.advancing, hasNext)) [self playNextEpisode];
        else self.player_view_controller.playbackStatusLabel.text = hasNext ? @"Серия завершена · можно перейти далее" : @"Просмотр завершён · следующей серии в источнике нет";
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
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Не удалось воспроизвести видео" message:@"Источник не вернул совместимый поток. Повтори попытку или выбери другой источник/озвучку." preferredStyle:UIAlertControllerStyleAlert];
    if (self.progressKey) [alert addAction:[UIAlertAction actionWithTitle:@"Повторить" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self playWithReleaseID:self.release_id sourceID:self.source_id position:self.source_position autoShow:NO completion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Закрыть" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action) { [self.player_view_controller dismissViewControllerAnimated:YES completion:nil]; }]];
    [self.player_view_controller presentViewController:alert animated:YES completion:nil];
}
-(AVPlayerViewController*)getPlayer { return self.player_view_controller.nativePlayer; }
+(instancetype)sharedInstance {
    static PlayerController* shared; static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [PlayerController new]; }); return shared;
}
@end
