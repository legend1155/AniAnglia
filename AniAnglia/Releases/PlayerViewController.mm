// Native playback lifecycle, resume, queue and source web fallback.
#import "PlayerViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreFoundation/CoreFoundation.h>
#import "AppDataController.h"
#import "StringCvt.h"
#import <SafariServices/SafariServices.h>
#include <cctype>
#include <exception>
#include <cmath>
#include <algorithm>

#include "PlaybackPolicy.hpp"
#include "AnimeMapping.hpp"

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

// A container keeps interactive buttons ABOVE AVKit (not in its noninteractive contentOverlayView).
@interface PlayerViewController : UIViewController
@property(nonatomic, strong) AVPlayerViewController* nativePlayer;
@property(nonatomic, strong) UIButton* skipButton;
@property(nonatomic, strong) UIButton* nextButton;
@property(nonatomic, strong) UIButton* openingButton;
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
@property(nonatomic, copy) void (^onOpening)(void);
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
    self.openingButton = [self buttonWithTitle:@"Опенинг · настроить" action:@selector(openingPressed)];
    UIStackView* skips = [[UIStackView alloc] initWithArrangedSubviews:@[self.openingButton, self.skipButton, self.nextButton]];
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
    self.controlsButton.enabled = !loading; self.openingButton.enabled = !loading;
    self.nativePlayer.showsPlaybackControls = !loading && !self.overlayHidden;
}
-(void)setSkipAvailable:(BOOL)available nextAvailable:(BOOL)hasNext {
    self.skipButton.hidden = !available; self.nextButton.hidden = !hasNext;
}
-(void)skipPressed { if (self.onSkip) self.onSkip(); }
-(void)nextPressed { if (self.onNext) self.onNext(); }
-(void)openingPressed { if (self.onOpening) self.onOpening(); }
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
-(void)registerReleaseMetadata:(anixart::Release::Ptr)release {
    if (!release) return;
    NSArray* raw = @[TO_NSSTRING(release->title_original) ?: @"", TO_NSSTRING(release->title_alt) ?: @"", TO_NSSTRING(release->title_ru) ?: @""];
    NSMutableOrderedSet<NSString*>* titles = [NSMutableOrderedSet new];
    NSString* query = nil;
    for (NSString* title in raw) {
        // Split explicit alias separators, not slashes in titles such as Fate/stay night.
        NSString* separated = [[title stringByReplacingOccurrencesOfString:@" / " withString:@"\n"] stringByReplacingOccurrencesOfString:@" | " withString:@"\n"];
        for (NSString* alias in [separated componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\n;" ]]) {
            NSString* trimmed = [alias stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!query.length && trimmed.length) query = trimmed;
            NSString* normalized = PlaybackNormalizedTitle(trimmed);
            if (normalized.length >= 3) [titles addObject:normalized];
        }
    }
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
    NSRegularExpression* pattern = [NSRegularExpression regularExpressionWithPattern:@"^(?:(?:серия|эпизод|episode|ep\\.?)\\s*)?([0-9]{1,6})(?:\\s*(?:серия|эпизод|episode))?$" options:NSRegularExpressionCaseInsensitive error:NULL];
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
-(void)resolveAutomaticOpening {
    if (![[[self settings] getSettingsObjectAtKey:@"aniskip_auto_lookup"] boolValue] || self.mappingAttempted) return;
    self.mappingAttempted = YES;
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
    ++self.openingRequestVersion; [self.openingRequest cancel];
    [self requestAnimePage:1 metadata:metadata candidates:@[] generation:self.generation version:self.openingRequestVersion];
}
-(void)requestAnimePage:(NSInteger)page metadata:(NSDictionary*)metadata candidates:(NSArray*)candidates generation:(NSUInteger)generation version:(NSUInteger)version {
    if (generation != self.generation || version != self.openingRequestVersion || ![[[self settings] getSettingsObjectAtKey:@"aniskip_auto_lookup"] boolValue]) return;
    // One queue per player, at least 1.1 seconds apart, including repeated manual retries.
    NSTimeInterval wait = MAX(0, self.lastJikanRequest + 1.1 - NSDate.date.timeIntervalSince1970);
    if (wait > 0.001) {
        __weak PlayerController* weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf requestAnimePage:page metadata:metadata candidates:candidates generation:generation version:version];
        }); return;
    }
    self.lastJikanRequest = NSDate.date.timeIntervalSince1970;
    self.openingStatus = @"Автоматический поиск сезона в MyAnimeList через Jikan…";
    NSURLComponents* components = [NSURLComponents componentsWithString:@"https://api.jikan.moe/v4/anime"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:metadata[@"query"]], [NSURLQueryItem queryItemWithName:@"limit" value:@"25"], [NSURLQueryItem queryItemWithName:@"page" value:[@(page) stringValue]]];
    NSURLRequest* request = [NSURLRequest requestWithURL:components.URL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:20];
    __weak PlayerController* weakSelf = self;
    self.openingRequest = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
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
                owner.openingStatus = @"База MyAnimeList недоступна или ограничила запросы. Просмотр продолжается без автопропуска."; return;
            }
            NSMutableArray* all = [candidates mutableCopy]; [all addObjectsFromArray:json[@"data"]];
            if ([json[@"pagination"][@"has_next_page"] boolValue]) {
                if (page >= 3) { owner.openingStatus = @"Слишком широкий поиск сезона; автоматическая привязка не выбрана."; return; }
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
                if (!PlaybackPositiveInteger(row[@"mal_id"], 1000000000) || !PlaybackPositiveInteger(row[@"episodes"], 1000000) || ![row[@"type"] isKindOfClass:NSString.class] || ![row[@"titles"] isKindOfClass:NSArray.class]) continue;
                playback::AnimeIdentity candidate; candidate.mal = [row[@"mal_id"] longValue]; candidate.episodes = [row[@"episodes"] intValue];
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
            for (const auto& candidate : matches) if (candidate.mal == mal) total = candidate.episodes;
            if (!mal || total <= 0) { owner.openingStatus = @"Сезон не найден однозначно по названию, году, формату и числу серий. Случайный результат не используется."; return; }
            NSMutableDictionary* cache = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"aniskip_mal_cache_v4"] mutableCopy] ?: [NSMutableDictionary new];
            NSString* key = [NSString stringWithFormat:@"%lld", (long long)static_cast<int64_t>(owner.release_id)];
            // Bounded positive cache; failures are not persisted.
            if (cache.count >= 200) [cache removeAllObjects];
            cache[key] = @{@"metadata": metadata, @"mal": @(mal), @"episodes": @(total), @"saved": @(NSDate.date.timeIntervalSince1970)};
            [[NSUserDefaults standardUserDefaults] setObject:cache forKey:@"aniskip_mal_cache_v4"];
            if ([owner automaticOpeningBinding]) [owner fetchOpeningCandidate];
        });
    }];
    [self.openingRequest resume];
}

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
    self.player_view_controller.onOpening = ^{ [weakSelf showOpeningMenu]; };
}
-(void)playWithReleaseID:(anixart::ReleaseID)release_id sourceID:(anixart::EpisodeSourceID)source_id position:(long)position autoShow:(BOOL)auto_show completion:(void(^)(BOOL))completion {
    [self stopObserving];
    self.release_id = release_id; self.source_id = source_id; self.source_position = position;
    self.targetURL = nil; self.mappingAttempted = NO;
    self.progressKey = [NSString stringWithFormat:@"%lld:%lld:%lld:%ld", (long long)static_cast<int64_t>([[AppDataController sharedInstance] getMyProfileID]), (long long)static_cast<int64_t>(release_id), (long long)static_cast<int64_t>(source_id), position];
    self.advancing = NO; self.openingHandled = NO; self.episodeCompleted = NO; self.errorShown = NO;
    self.pendingOpeningStart = -1; self.previewingOpening = NO; self.openingCandidate = nil; self.openingStatus = @"";
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
                [owner installOpeningBoundaries];
                [owner.observedPlayer play];
                if (![owner openingRecord]) [owner fetchOpeningCandidate];
                owner.timeObserver = [owner.observedPlayer addPeriodicTimeObserverForInterval:CMTimeMake(1, 4) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
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
    records[self.progressKey] = @{@"start": @(begin), @"end": @(end), @"duration": @(duration), @"confirmed": @YES, @"origin": origin, @"media": [self openingMediaIdentity]};
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
        [self.observedPlayer play];
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
    [menu addAction:[UIAlertAction actionWithTitle:@"Повторить автопоиск / запрос AniSkip" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
        self.mappingAttempted = NO; [self fetchOpeningCandidate];
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
        if (generation == self.generation) [self.observedPlayer play];
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
    if (!binding) { [self resolveAutomaticOpening]; return; }
    if (![[[self settings] getSettingsObjectAtKey:@"aniskip_auto_lookup"] boolValue]) { self.openingStatus = @"Сетевые запросы AniSkip отключены в настройках."; return; }
    long episode = self.source_position + [binding[@"offset"] longValue];
    if (episode < 1 || episode > 1000000) { self.openingStatus = @"Номер серии вне привязки MAL. Проверь настройки."; return; }
    ++self.openingRequestVersion; [self.openingRequest cancel]; self.openingCandidate = nil;
    NSUInteger requestVersion = self.openingRequestVersion, generation = self.generation;
    NSURLComponents* components = [NSURLComponents componentsWithString:@"https://api.aniskip.com"];
    components.path = [NSString stringWithFormat:@"/v2/skip-times/%lld/%ld", [binding[@"mal"] longLongValue], episode];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"types" value:@"op"], [NSURLQueryItem queryItemWithName:@"episodeLength" value:[NSString stringWithFormat:@"%lld", (long long)std::llround(duration)]]];
    NSURLRequest* request = [NSURLRequest requestWithURL:components.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    self.openingStatus = @"Запрашиваются таймкоды AniSkip…";
    __weak PlayerController* weakSelf = self;
    self.openingRequest = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        NSDictionary* candidate = nil;
        if (!error && [response isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse*)response).statusCode == 200 && data.length && data.length <= 1024 * 1024) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([json isKindOfClass:NSDictionary.class] && [json[@"results"] isKindOfClass:NSArray.class]) {
                NSMutableArray<NSDictionary*>* compatible = [NSMutableArray new];
                for (id value in json[@"results"]) {
                    if (![value isKindOfClass:NSDictionary.class]) continue;
                    NSDictionary* row = value; id interval = row[@"interval"];
                    if (![row[@"skipType"] isEqual:@"op"] || ![interval isKindOfClass:NSDictionary.class] || !PlaybackRealNumber(interval[@"startTime"]) ||
                        !PlaybackRealNumber(interval[@"endTime"]) || !PlaybackRealNumber(row[@"episodeLength"])) continue;
                    double begin = [interval[@"startTime"] doubleValue], end = [interval[@"endTime"] doubleValue], reference = [row[@"episodeLength"] doubleValue];
                    if (!std::isfinite(reference) || std::abs(reference - duration) > 1.0 || !playback::validOpeningInterval(begin, end, duration)) continue;
                    [compatible addObject:@{@"start": @(begin), @"end": @(end), @"duration": @(duration)}];
                }
                if (compatible.count == 1) candidate = compatible.firstObject;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            PlayerController* owner = weakSelf;
            if (!owner || generation != owner.generation || requestVersion != owner.openingRequestVersion) return;
            owner.openingRequest = nil;
            if (![[[owner settings] getSettingsObjectAtKey:@"aniskip_auto_lookup"] boolValue]) return;
            // Never overwrite the user's local correction or interrupt marking/preview.
            if (candidate && ![owner openingRecord] && owner.pendingOpeningStart < 0 && !owner.previewingOpening) {
                [owner storeOpeningFrom:[candidate[@"start"] doubleValue] to:[candidate[@"end"] doubleValue] origin:@"AniSkip-auto"];
                owner.openingStatus = @"AniSkip: границы найдены и применены автоматически.";
            } else if (candidate && ![owner openingRecord]) {
                owner.openingCandidate = candidate; owner.openingStatus = @"Таймкоды доступны; ручная разметка имеет приоритет.";
            } else if (!candidate) {
                owner.openingStatus = @"Нет подходящих таймкодов AniSkip или сервис недоступен. Без меток пропуск не выполняется.";
            }
            [owner updatePlaybackAt:CMTimeGetSeconds(owner.observedPlayer.currentTime)];
        });
    }];
    [self.openingRequest resume];
}
-(void)reviewOpeningCandidate {
    NSUInteger generation = self.generation;
    NSDictionary* candidate = self.openingCandidate; if (!candidate) return;
    double begin = [candidate[@"start"] doubleValue], end = [candidate[@"end"] doubleValue];
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Проверить опенинг AniSkip" message:[NSString stringWithFormat:@"%@–%@. Таймкоды сообщества могут отличаться для другой версии видео. Проверь начало и конец по самому видео. Эта разметка не переносится на другие серии.", PlaybackTime(begin), PlaybackTime(end)] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Посмотреть начало" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
        self.previewingOpening = YES;
        [self.observedPlayer seekToTime:CMTimeMakeWithSeconds(MAX(0, begin - 2), 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Посмотреть конец" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (generation != self.generation) return;
        self.previewingOpening = YES;
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
    [self.observedPlayer seekToTime:CMTimeMakeWithSeconds(target, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (finished && generation == self.generation) [self saveProgress]; });
    }];
}
-(void)updatePlaybackAt:(double)seconds {
    if (!self.ready || self.resumePending || !std::isfinite(seconds)) return;
    BOOL hasNext = [self nextPosition] != nil;
    NSString* openingTitle = self.pendingOpeningStart >= 0 ? @"Опенинг · отметить конец" : (self.openingCandidate ? @"Опенинг · проверить" : ([self openingRecord] ? @"Опенинг · изменить" : @"Опенинг · настроить"));
    [self.player_view_controller.openingButton setTitle:openingTitle forState:UIControlStateNormal];
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
