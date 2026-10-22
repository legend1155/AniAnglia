//
//  MainViewController.m
//  iOSAnixart
//
//  Created by Toilettrauma on 28.08.2024.
//

#import <Foundation/Foundation.h>
#import "MainViewController.h"
#import "AppColor.h"
#import "LibanixartApi.h"
#import "ReleaseViewController.h"
#import "StringCvt.h"
#import "ReleasesTableViewController.h"
#import "ReleasesViewController.h"

#import "FilterViewController.h"
#import "ReleaseTableViewCell.h"
#import "AppDataController.h"
#import "ModernStyle.h"
#include "DiscoveryPolicy.hpp"
#include "WatchPolicy.hpp"
#import "WatchHistory.h"
#include <set>
#include <exception>

static NSString* HomeProfileKey(NSString* suffix) {
    return [NSString stringWithFormat:@"discovery_v5_%lld_%@", (long long)static_cast<int64_t>([[AppDataController sharedInstance] getMyProfileID]), suffix];
}
static std::vector<std::string> HomeGenres(const std::string& value) {
    std::vector<std::string> result;
    NSString* text = TO_NSSTRING(value) ?: @"";
    for (NSString* part in [text componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",;|"]]) {
        NSString* clean = [[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
        if (clean.length) result.push_back(TO_STDSTRING(clean));
    }
    return result;
}

@interface HomeTasteController : UITableViewController
@property(nonatomic, copy) NSArray<NSString*>* genres;
@property(nonatomic, strong) NSMutableArray<NSString*>* selected;
@property(nonatomic, copy) NSString* storageKey;
@property(nonatomic, copy) NSString* hiddenKey;
@property(nonatomic, copy) NSString* watchKey;
@property(nonatomic, copy) NSString* negativeKey;
@property(nonatomic, copy) void (^onChange)(void);
@end
@implementation HomeTasteController
-(void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Мои жанры";
    self.storageKey = HomeProfileKey(@"genres"); self.hiddenKey = HomeProfileKey(@"hidden");
    self.watchKey = AniWatchKey((long long)static_cast<int64_t>([[AppDataController sharedInstance] getMyProfileID])); self.negativeKey = HomeProfileKey(@"negative_genres");
    self.genres = [[LibanixartApi sharedInstance] getGenresArray] ?: @[];
    self.selected = [[[NSUserDefaults standardUserDefaults] stringArrayForKey:self.storageKey] mutableCopy] ?: [NSMutableArray new];
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Сбросить" style:UIBarButtonItemStylePlain target:self action:@selector(resetGenres)];
}
-(void)resetGenres {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Настройки подбора" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Сбросить выбранные жанры" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        [self.selected removeAllObjects]; [self saveGenres]; [self.tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Вернуть скрытые аниме" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:self.hiddenKey];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:self.negativeKey]; if (self.onChange) self.onChange();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Сбросить обучение по просмотру" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
        [defaults removeObjectForKey:self.watchKey];
        [NSNotificationCenter.defaultCenter postNotificationName:@"AniWatchHistoryReset" object:self.watchKey];
        [defaults setInteger:[defaults integerForKey:AniWatchRevisionKey(self.watchKey)] + 1 forKey:AniWatchRevisionKey(self.watchKey)];
        if (self.onChange) self.onChange();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
-(void)saveGenres {
    [[NSUserDefaults standardUserDefaults] setObject:self.selected forKey:self.storageKey];
    if (self.onChange) self.onChange();
}
-(NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return self.genres.count; }
-(NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section { return self.genres.count ? @"Необязательные предпочтения. Учитываются реально просмотренные минуты и доля серии, избранное и оценки. Короткий выход нейтрален; «Неинтересно» — явный отрицательный сигнал. Подбор выполняется локально, без отдельного сервера." : @"Список жанров пока недоступен. Вернись после загрузки каталога."; }
-(UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = self.genres[path.row]; cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.accessoryType = [self.selected containsObject:self.genres[path.row]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
-(void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
    NSString* genre = self.genres[path.row];
    if ([self.selected containsObject:genre]) [self.selected removeObject:genre]; else [self.selected addObject:genre];
    [self saveGenres]; [tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
}
@end

@interface HomeRecommendationsController : UITableViewController {
    std::vector<anixart::Release::Ptr> _items;
    discovery::Taste _taste;
}
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL dirty;
@property(nonatomic, copy) NSString* loadedProfile;
@property(nonatomic, copy) NSString* summary;
@property(nonatomic, strong) UILabel* statusLabel;
@property(nonatomic, strong) NSDate* lastRefresh;
@property(nonatomic) NSInteger watchRevision;
-(void)refreshRecommendations;
-(void)editTaste;
@end
@implementation HomeRecommendationsController
-(void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Тебе понравится";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = 175; self.tableView.estimatedRowHeight = 175;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:ReleaseTableViewCell.class forCellReuseIdentifier:[ReleaseTableViewCell getIdentifier]];
    self.statusLabel = [UILabel new]; self.statusLabel.numberOfLines = 0; self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.statusLabel.textColor = UIColor.secondaryLabelColor; self.tableView.backgroundView = self.statusLabel;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refreshRecommendations) forControlEvents:UIControlEventValueChanged];
    [self refreshRecommendations];
}
-(void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    BOOL changedProfile = self.loadedProfile && ![self.loadedProfile isEqualToString:HomeProfileKey(@"profile")];
    if (changedProfile) { ++self.generation; self.loading = NO; _items.clear(); _taste.clear(); [self.tableView reloadData]; }
    NSString* watchKey = AniWatchKey((long long)static_cast<int64_t>([[AppDataController sharedInstance] getMyProfileID]));
    BOOL changedWatch = self.watchRevision != [NSUserDefaults.standardUserDefaults integerForKey:AniWatchRevisionKey(watchKey)];
    if (changedProfile || changedWatch || self.dirty || (!self.loading && self.lastRefresh && -self.lastRefresh.timeIntervalSinceNow > 300)) [self refreshRecommendations];
}
-(void)editTaste {
    HomeTasteController* choices = [[HomeTasteController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    __weak HomeRecommendationsController* weakSelf = self;
    choices.onChange = ^{ weakSelf.dirty = YES; };
    [self.navigationController pushViewController:choices animated:YES];
}
-(void)refreshRecommendations {
    if (self.loading) return;
    self.loading = YES; self.dirty = NO; self.statusLabel.text = _items.empty() ? @"Подбираем аниме…" : @"";
    NSUInteger generation = ++self.generation;
    NSString* profileKey = HomeProfileKey(@"profile"); self.loadedProfile = profileKey;
    auto profileID = [[AppDataController sharedInstance] getMyProfileID];
    NSString* watchKey = AniWatchKey((long long)static_cast<int64_t>(profileID));
    NSDictionary* watchHistory = [NSUserDefaults.standardUserDefaults dictionaryForKey:watchKey] ?: @{};
    NSDictionary* negativeGenres = [NSUserDefaults.standardUserDefaults dictionaryForKey:HomeProfileKey(@"negative_genres")] ?: @{};
    self.watchRevision = [NSUserDefaults.standardUserDefaults integerForKey:AniWatchRevisionKey(watchKey)];
    __block double watchedMinutes = 0;

    NSArray<NSString*>* preferred = [[NSUserDefaults standardUserDefaults] stringArrayForKey:HomeProfileKey(@"genres")] ?: @[];
    NSArray<NSString*>* catalogueGenres = [[LibanixartApi sharedInstance] getGenresArray] ?: @[];
    NSArray<NSString*>* hidden = [[NSUserDefaults standardUserDefaults] stringArrayForKey:HomeProfileKey(@"hidden")] ?: @[];
    __block std::vector<anixart::Release::Ptr> result;
    __block discovery::Taste taste;
    __block BOOL partial = NO;
    __block BOOL personalized = NO;
    __weak HomeRecommendationsController* weakSelf = self;
    [[LibanixartApi sharedInstance] asyncCall:^BOOL(anixart::Api* api) {
        std::set<long long> excluded;
        std::map<std::string, std::string> officialGenres;
        for (NSString* genre in catalogueGenres) {
            auto normalized = HomeGenres(TO_STDSTRING(genre));
            if (normalized.size() == 1) officialGenres[normalized.front()] = TO_STDSTRING(genre);
        }
        for (NSString* idText in hidden) excluded.insert(idText.longLongValue);
        for (NSString* genre in preferred) discovery::learn(taste, HomeGenres(TO_STDSTRING(genre)), 12);
        for (NSString* releaseID in watchHistory) {
            NSDictionary* title = watchHistory[releaseID];
            if (![title isKindOfClass:NSDictionary.class]) continue;
            NSDictionary* episodes = title[@"episodes"]; int interest = 0; double titleWatched = 0;
            if (![episodes isKindOfClass:NSDictionary.class]) continue;
            for (NSString* episode in episodes) {
                NSDictionary* record = episodes[episode];
                if (![record isKindOfClass:NSDictionary.class]) continue;
                double duration = [record[@"duration"] doubleValue];
                if (!std::isfinite(duration) || duration <= 0 || duration > 18000) continue;
                NSSet* unique = AniWatchSeconds(record, duration);
                double watched = unique.count;
                interest = std::min(8, interest + discovery::watchInterest(watched, duration));
                titleWatched += watched;
            }
            watchedMinutes += titleWatched / 60;
            if (titleWatched >= 60) excluded.insert(releaseID.longLongValue);
            if ([title[@"genres"] isKindOfClass:NSString.class]) discovery::learn(taste, HomeGenres(TO_STDSTRING(title[@"genres"])), interest);
        }
        // Bounded requests. Candidate membership flags additionally exclude watched/dropped titles.
        try {
            auto pages = api->releases().profile_favorites(profileID, anixart::Profile::ListSort::Descending, 0, 0);
            for (const auto& seed : pages->get()) {
                if (!seed) continue;
                excluded.insert(static_cast<int64_t>(seed->id)); discovery::learn(taste, HomeGenres(seed->genres), 3);
            }
        } catch (const std::exception&) { partial = YES; }
        try {
            auto pages = api->releases().profile_voted_releases(profileID, anixart::Release::ByVoteSort::Descending, 0);
            for (const auto& seed : pages->get()) {
                if (!seed) continue;
                excluded.insert(static_cast<int64_t>(seed->id));
                int vote = seed->my_vote > 0 ? seed->my_vote : seed->your_vote;
                if (vote >= 4 && vote <= 5) discovery::learn(taste, HomeGenres(seed->genres), 6);
                else if (vote >= 1 && vote <= 2) discovery::learn(taste, HomeGenres(seed->genres), -8);
            }
        } catch (const std::exception&) { partial = YES; }
        try {
            auto pages = api->releases().get_history(0);
            for (const auto& seed : pages->get()) if (seed) excluded.insert(static_cast<int64_t>(seed->id));
        } catch (const std::exception&) { partial = YES; }
        for (NSString* releaseID in negativeGenres) {
            id genres = negativeGenres[releaseID];
            if ([genres isKindOfClass:NSString.class]) discovery::learn(taste, HomeGenres(TO_STDSTRING(genres)), -8);
        }
        personalized = std::any_of(taste.begin(), taste.end(), [](const auto& value) { return value.second != 0; });
        std::vector<anixart::Release::Ptr> pool;
        anixart::requests::FilterRequest request;
        request.sort = anixart::requests::FilterRequest::Popular;
        request.profile_list_exclusions = {anixart::Profile::List::Watched, anixart::Profile::List::Dropped};
        try {
            auto pages = api->search().filter_search(request, false, 0);
            auto first = pages->get(); pool.insert(pool.end(), first.begin(), first.end());
        } catch (const std::exception&) { partial = YES; }
        // Expand around the two strongest genres rather than re-rank only the global top page.
        std::vector<std::pair<std::string, int>> top(taste.begin(), taste.end());
        std::sort(top.begin(), top.end(), [](const auto& a, const auto& b) { return a.second != b.second ? a.second > b.second : a.first < b.first; });
        for (std::size_t i = 0; i < std::min<std::size_t>(2, top.size()); ++i) {
            if (top[i].second <= 0) continue;
            auto official = officialGenres.find(top[i].first);
            if (official == officialGenres.end()) continue;
            request.genres = {official->second};
            try {
                auto pages = api->search().filter_search(request, false, 0);
                auto content = pages->get(); pool.insert(pool.end(), content.begin(), content.end());
            } catch (const std::exception&) { partial = YES; }
        }
        std::vector<discovery::Candidate> candidates;
        for (const auto& release : pool) {
            if (!release) continue;
            long long id = static_cast<int64_t>(release->id);
            candidates.push_back({id, HomeGenres(release->genres), release->grade,
                release->is_viewed || excluded.contains(id) || release->profile_list_status == anixart::Profile::ListStatus::Watched,
                release->profile_list_status == anixart::Profile::ListStatus::Dropped || release->is_deleted,
                release->is_favorite, release->profile_list_status == anixart::Profile::ListStatus::Watching});
        }
        for (long long id : discovery::rank(candidates, taste, 24)) {
            auto found = std::find_if(pool.begin(), pool.end(), [id](const auto& release) { return release && static_cast<int64_t>(release->id) == id; });
            if (found != pool.end()) result.push_back(*found);
        }
        return pool.empty();
    } completion:^(BOOL errored) {
        HomeRecommendationsController* owner = weakSelf;
        if (!owner || generation != owner.generation || ![profileKey isEqualToString:HomeProfileKey(@"profile")]) return;
        owner.loading = NO; owner.lastRefresh = NSDate.date; [owner.refreshControl endRefreshing];
        if (!errored) { owner->_items = std::move(result); owner->_taste = std::move(taste); }
        owner.summary = errored ? @"Не удалось обновить подборку. Потяни вниз, чтобы повторить." : (personalized ? @"По фактическому просмотру, жанрам, избранному, оценкам и «Неинтересно»." : @"Популярное для начала. Добавь избранное, оценки или выбери свои жанры.");
        if (watchedMinutes > 0 && !errored) owner.summary = [owner.summary stringByAppendingFormat:@" Учтено %.0f мин просмотра на этом устройстве; это сигнал интереса, а не точная оценка вкуса.", watchedMinutes];
        if (partial && !errored) owner.summary = [owner.summary stringByAppendingString:@" Часть данных недоступна; подборка может быть неполной."];
        owner.statusLabel.text = owner->_items.empty() ? (errored ? owner.summary : @"Подходящих новых аниме пока нет. Измени жанры или обнови подборку.") : @"";
        [owner.tableView reloadData];
        if (owner.watchRevision != [NSUserDefaults.standardUserDefaults integerForKey:AniWatchRevisionKey(watchKey)]) owner.dirty = YES;
        if (owner.dirty) [owner refreshRecommendations];
    }];
}
-(NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_items.size(); }
-(NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section { return self.summary; }
-(CGFloat)tableView:(UITableView*)tableView heightForRowAtIndexPath:(NSIndexPath*)path {
    return [[UIFontMetrics defaultMetrics] scaledValueForValue:175];
}
-(UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
    ReleaseTableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:[ReleaseTableViewCell getIdentifier] forIndexPath:path];
    auto release = _items[(std::size_t)path.row];
    [cell setTitle:TO_NSSTRING(release->title_ru) ?: TO_NSSTRING(release->title_original)];
    [cell setImageUrl:[NSURL URLWithString:TO_NSSTRING(release->image_url)]];
    [cell setRating:release->grade]; [cell setEpCount:std::max(0, release->episodes_released) totalEpCount:std::max(0, release->episodes_total)];
    NSMutableArray<NSString*>* reasons = [NSMutableArray new];
    for (const auto& genre : HomeGenres(release->genres)) if (_taste.contains(genre) && _taste.at(genre) > 0) [reasons addObject:TO_NSSTRING(genre)];
    NSString* reason = reasons.count ? [NSString stringWithFormat:@"Твои жанры: %@", [reasons componentsJoinedByString:@", "]] : @"Популярное в каталоге";
    [cell setDescription:[NSString stringWithFormat:@"%@ · %@", TO_NSSTRING(release->year) ?: @"", reason]];
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor; cell.layer.cornerRadius = 18; cell.clipsToBounds = YES;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
-(void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    [self.navigationController pushViewController:[[ReleaseViewController alloc] initWithReleaseID:_items[(std::size_t)path.row]->id] animated:YES];
}
-(UISwipeActionsConfiguration*)tableView:(UITableView*)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)path {
    auto releaseID = static_cast<int64_t>(_items[(std::size_t)path.row]->id);
    NSString* rejectedGenres = TO_NSSTRING(_items[(std::size_t)path.row]->genres) ?: @"";
    __weak HomeRecommendationsController* weakSelf = self;
    UIContextualAction* hide = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Неинтересно" handler:^(UIContextualAction* action, UIView* view, void (^completion)(BOOL)) {
        HomeRecommendationsController* owner = weakSelf;
        if (!owner || ![owner.loadedProfile isEqualToString:HomeProfileKey(@"profile")]) { completion(NO); return; }
        NSString* key = HomeProfileKey(@"hidden");
        NSMutableArray* hidden = [[[NSUserDefaults standardUserDefaults] stringArrayForKey:key] mutableCopy] ?: [NSMutableArray new];
        NSString* value = [NSString stringWithFormat:@"%lld", (long long)releaseID];
        if (![hidden containsObject:value]) [hidden addObject:value];
        if (hidden.count > 500) [hidden removeObjectAtIndex:0];
        [[NSUserDefaults standardUserDefaults] setObject:hidden forKey:key];
        NSString* negativeKey = HomeProfileKey(@"negative_genres");
        NSMutableDictionary* negatives = [[NSUserDefaults.standardUserDefaults dictionaryForKey:negativeKey] mutableCopy] ?: [NSMutableDictionary new];
        negatives[value] = rejectedGenres;
        for (NSString* titleID in [negatives.allKeys copy]) if (![hidden containsObject:titleID]) [negatives removeObjectForKey:titleID];
        [NSUserDefaults.standardUserDefaults setObject:negatives forKey:negativeKey];
        owner.dirty = YES;
        std::erase_if(owner->_items, [releaseID](const auto& release) { return static_cast<int64_t>(release->id) == releaseID; });
        if (owner->_items.empty()) owner.statusLabel.text = @"Все предложения скрыты. Можно изменить жанры или вернуть скрытые аниме в настройках подбора.";
        [owner.tableView reloadData]; completion(YES);
    }];
    hide.backgroundColor = UIColor.systemIndigoColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[hide]];
}
@end

anixart::FilterPages::UPtr construct_filter_request_pages(anixart::Api* api, const std::optional<anixart::Release::Status> status, const std::optional<anixart::Release::Category> category) {
    anixart::requests::FilterRequest filter_request;
    filter_request.status = status;
    filter_request.category = category;
    return api->search().filter_search(filter_request, false, 0);
}

@interface MainViewController () <UISearchBarDelegate>
@property(nonatomic) LibanixartApi* api_proxy;
@property(nonatomic, retain) SegmentedPageViewController* page_view_controler;
@property(nonatomic, strong) HomeRecommendationsController* recommendations;
@property(nonatomic, strong) UIStackView* homeActions;

@end

@implementation MainViewController

-(void)viewDidLoad {
    [super viewDidLoad];
    
    _api_proxy = [LibanixartApi sharedInstance];
    
    [self setup];
    [self setupLayout];
}

-(void)setup {
    self.recommendations = [HomeRecommendationsController new];
    UIButton* advanced = [UIButton buttonWithType:UIButtonTypeSystem];
    [advanced setTitle:@"Расширенный поиск" forState:UIControlStateNormal];
    [advanced setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
    AniStyleButton(advanced, YES); [advanced addTarget:self action:@selector(openAdvancedSearch) forControlEvents:UIControlEventTouchUpInside];
    UIButton* taste = [UIButton buttonWithType:UIButtonTypeSystem];
    [taste setTitle:@"Мои жанры" forState:UIControlStateNormal]; AniStyleButton(taste, NO);
    [taste addTarget:self.recommendations action:@selector(editTaste) forControlEvents:UIControlEventTouchUpInside];
    self.homeActions = [[UIStackView alloc] initWithArrangedSubviews:@[advanced, taste]];
    self.homeActions.spacing = 10; self.homeActions.distribution = UIStackViewDistributionFillEqually;
    [self.view addSubview:self.homeActions]; self.homeActions.translatesAutoresizingMaskIntoConstraints = NO;
    _page_view_controler = [SegmentedPageViewController new];
    [_page_view_controler setPageViewControllers:@[
       self.recommendations,
       [[ReleasesViewController alloc] initWithPages:construct_filter_request_pages(_api_proxy.api, std::nullopt, std::nullopt)],
       [[ReleasesViewController alloc] initWithPages:construct_filter_request_pages(_api_proxy.api, anixart::Release::Status::Ongoing, std::nullopt)],
       [[ReleasesViewController alloc] initWithPages:construct_filter_request_pages(_api_proxy.api, anixart::Release::Status::Upcoming, std::nullopt)],
       [[ReleasesViewController alloc] initWithPages:construct_filter_request_pages(_api_proxy.api, anixart::Release::Status::Finished, std::nullopt)],
       [[ReleasesViewController alloc] initWithPages:construct_filter_request_pages(_api_proxy.api, std::nullopt, anixart::Release::Category::Movies)],
       [[ReleasesViewController alloc] initWithPages:construct_filter_request_pages(_api_proxy.api, std::nullopt, anixart::Release::Category::Ova)]
   ]];
    [_page_view_controler setSegmentTitles:@[
        @"Тебе понравится",
        NSLocalizedString(@"app.pages.releases.actual", ""),
        NSLocalizedString(@"app.pages.releases.ongoing", ""),
        NSLocalizedString(@"app.pages.releases.upcoming", ""),
        NSLocalizedString(@"app.pages.releases.finished", ""),
        NSLocalizedString(@"app.pages.releases.movies", ""),
        NSLocalizedString(@"app.pages.releases.ova", "")
    ]];
    
    [self addChildViewController:_page_view_controler];
    
    [self.view addSubview:_page_view_controler.view];
    
    _page_view_controler.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.homeActions.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.homeActions.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [self.homeActions.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [self.homeActions.heightAnchor constraintGreaterThanOrEqualToConstant:52],
        [_page_view_controler.view.topAnchor constraintEqualToAnchor:self.homeActions.bottomAnchor constant:12],
        [_page_view_controler.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_page_view_controler.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_page_view_controler.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [_page_view_controler didMoveToParentViewController:self];
}

-(void)openAdvancedSearch { [self.navigationController pushViewController:[FilterViewController new] animated:YES]; }
-(void)setupLayout {
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
}

@end
