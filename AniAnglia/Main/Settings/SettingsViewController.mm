//
//  ProfileEditViewController.m
//  AniAnglia
//
//  Created by Toilettrauma on 06.04.2025.
//

#import <Foundation/Foundation.h>
#import "SettingsViewController.h"
#import "LibanixartApi.h"
#import "AppColor.h"
#import "StringCvt.h"
#import "SettingsProfileViewController.h"
#import "CustomTableViewCells.h"
#import "AppDataController.h"
#import "SettingsAppearanceViewController.h"
#import "SettingsSecurityViewController.h"

// An actual searchable preference picker instead of requiring an exact typed voice name.
@interface PlaybackChoiceViewController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSString* preferenceKey;
@property(nonatomic, copy) NSArray<NSString*>* names;
@property(nonatomic, copy) NSArray<NSString*>* filtered;
@property(nonatomic, strong) UISearchController* search;
@property(nonatomic) BOOL loadingFailed;
@end
@implementation PlaybackChoiceViewController
-(void)viewDidLoad {
    [super viewDidLoad]; self.names = @[]; self.filtered = @[];
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self; self.search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.search; self.definesPresentationContext = YES;
    if ([self.preferenceKey isEqualToString:@"preferred_type_name"]) {
        [self loadVoices];
    } else {
        self.names = [[[AppDataController sharedInstance] getSettingsController] getSettingsObjectAtKey:@"known_source_names"] ?: @[];
        self.filtered = self.names; [self.tableView reloadData];
    }
}
-(void)loadVoices {
    self.loadingFailed = NO;
    UIActivityIndicatorView* spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.frame = CGRectMake(0, 0, 44, 44); [spinner startAnimating]; self.tableView.tableFooterView = spinner;
    __block NSMutableSet<NSString*>* names = [NSMutableSet new];
    [[LibanixartApi sharedInstance] asyncCall:^BOOL(anixart::Api* api) {
        for (const auto& voice : api->episodes().get_all_types()) {
            NSString* name = TO_NSSTRING(voice->name); if (name.length) [names addObject:name];
        }
        return NO;
    } completion:^(BOOL errored) {
        self.tableView.tableFooterView = nil; self.loadingFailed = errored;
        if (!errored) self.names = [[names allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        [self updateSearchResultsForSearchController:self.search];
    }];
}
-(void)updateSearchResultsForSearchController:(UISearchController*)search {
    NSString* query = search.searchBar.text ?: @"";
    self.filtered = query.length ? [self.names filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary* bindings) { NSString* name = object; return [name localizedCaseInsensitiveContainsString:query]; }]] : self.names;
    [self.tableView reloadData];
}
-(NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return 1 + self.filtered.count + (self.loadingFailed ? 1 : 0); }
-(NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    return [self.preferenceKey isEqualToString:@"preferred_source_name"] ? @"Источники появятся после открытия списка источников любого аниме. Если выбранного варианта нет у релиза, приложение предложит ручной выбор." : @"Если озвучка недоступна у релиза, приложение предложит ручной выбор.";
}
-(UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (self.loadingFailed && path.row == self.filtered.count + 1) { cell.textLabel.text = @"Ошибка загрузки — повторить"; return cell; }
    NSString* name = path.row == 0 ? @"" : self.filtered[path.row - 1];
    cell.textLabel.text = name.length ? name : @"Выбирать вручную";
    NSString* saved = [[[AppDataController sharedInstance] getSettingsController] getSettingsObjectAtKey:self.preferenceKey];
    cell.accessoryType = [name isEqualToString:saved] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
-(void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.loadingFailed && path.row == self.filtered.count + 1) { [self loadVoices]; return; }
    NSString* name = path.row == 0 ? @"" : self.filtered[path.row - 1];
    [[[AppDataController sharedInstance] getSettingsController] setSettingsObject:name atKey:self.preferenceKey];
    [self.navigationController popViewControllerAnimated:YES];
}
@end

// Playback preferences and image cache controls share the existing settings target.
@interface PlaybackSettingsViewController : UITableViewController
@property(nonatomic) BOOL cacheMode;
@property(nonatomic, strong) AppSettingsDataController* settings;
@end
@implementation PlaybackSettingsViewController
-(void)viewDidLoad {
    [super viewDidLoad];
    self.settings = [[AppDataController sharedInstance] getSettingsController];
    self.title = self.cacheMode ? @"Кеш изображений" : @"Воспроизведение";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
}
-(void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
-(NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    return self.cacheMode ? @"Кеш только изображений, с учётом HTTP-политики сервера. Видео для офлайн-просмотра не сохраняются." : @"Skip, прогресс и автоматические переходы работают во встроенном iOS-плеере. В веб-плеере ими управляет сайт. AniSkip автоматически ищет сезон через Jikan и применяет таймкоды подходящей серии и длительности видео. Без меток ничего не вырезается. Пропуск конца серии — отдельная настройка перехода до титров.";
}
-(NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return self.cacheMode ? 2 : 12; }
-(UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (self.cacheMode) {
        cell.textLabel.text = path.row == 0 ? @"Лимит кеша" : @"Очистить кеш изображений";
        if (!path.row) cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld МБ", (long)[self.settings getMaxCacheSizeBytes]/1024/1024];
        return cell;
    }
    NSArray* titles = @[@"Плеер", @"Качество", @"Озвучка по умолчанию", @"Источник по умолчанию", @"Запоминать выбор", @"Следующая серия автоматически", @"Автопропуск опенинга", @"Границы опенинга", @"AniSkip: автопоиск таймкодов", @"Пропускать конец серии", @"Последние секунды до перехода", @"Сбросить прогресс просмотра"];
    cell.textLabel.text = titles[path.row];
    NSArray* keys = @[@"default_player", @"preffered_quality", @"preferred_type_name", @"preferred_source_name", @"remember_source", @"auto_next_video", @"auto_skip_opening", @"", @"aniskip_auto_lookup", @"auto_skip_ending", @"ending_skip_time"];
    if ((path.row >= 4 && path.row <= 6) || path.row == 8 || path.row == 9) {
        UISwitch* toggle = [UISwitch new]; toggle.tag = path.row;
        toggle.on = [[self.settings getSettingsObjectAtKey:keys[path.row]] boolValue];
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (path.row == 7) {
        cell.detailTextLabel.text = @"В плеере → Опенинг";
    } else if (path.row < keys.count) {
        id value = [self.settings getSettingsObjectAtKey:keys[path.row]];
        cell.detailTextLabel.text = path.row == 0 ? ([value integerValue] == 2 ? @"Веб" : @"iOS") : [value description];
    }
    return cell;
}
-(void)toggleChanged:(UISwitch*)sender {
    NSArray* keys = @[@"remember_source", @"auto_next_video", @"auto_skip_opening"];
    NSString* key = sender.tag == 9 ? @"auto_skip_ending" : (sender.tag == 8 ? @"aniskip_auto_lookup" : keys[sender.tag - 4]);
    [self.settings setSettingsObject:@(sender.on) atKey:key];
}
-(void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.cacheMode && path.row == 1) {
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
        [tableView reloadData]; return;
    }
    if (!self.cacheMode && ((path.row >= 4 && path.row <= 6) || path.row == 8 || path.row == 9)) return;
    if (!self.cacheMode && (path.row == 2 || path.row == 3)) {
        PlaybackChoiceViewController* choices = [[PlaybackChoiceViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        choices.preferenceKey = path.row == 2 ? @"preferred_type_name" : @"preferred_source_name";
        choices.title = path.row == 2 ? @"Озвучка по умолчанию" : @"Источник по умолчанию";
        [self.navigationController pushViewController:choices animated:YES]; return;
    }
    if (!self.cacheMode && path.row == 7) {
        UIAlertController* info = [UIAlertController alertControllerWithTitle:@"Точный пропуск опенинга" message:@"AniSkip и автопропуск включены по умолчанию. Во встроенном iOS-плеере приложение ищет сезон в MyAnimeList через Jikan по названию и данным релиза, затем запрашивает op-таймкоды AniSkip для номера и длительности серии. Ввод ID и подтверждение каждой серии не нужны. При неоднозначности, отсутствии разметки или несовпадении длительности пропуска нет. Ручная разметка/привязка остаётся в меню Опенинг. Распознавания звука/видео нет. Отключение сетевого автопоиска не удаляет уже сохранённые метки; чтобы не перематывать, выключи Автопропуск опенинга." preferredStyle:UIAlertControllerStyleAlert];
        [info addAction:[UIAlertAction actionWithTitle:@"ОК" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:info animated:YES completion:nil]; return;
    }
    if (!self.cacheMode && path.row == 11) {
        UIAlertController* confirm = [UIAlertController alertControllerWithTitle:@"Удалить сохранённый прогресс?" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Удалить" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) { [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"playback_progress"]; }]];
        [self presentViewController:confirm animated:YES completion:nil]; return;
    }
    NSString* key = self.cacheMode ? @"max_cache_size" : (@[@"default_player", @"preffered_quality", @"preferred_type_name", @"preferred_source_name", @"", @"", @"", @"opening_start", @"default_skip_time", @"", @"ending_skip_time"])[path.row];
    NSArray* values = self.cacheMode ? @[@0, @10, @50, @100, @250] : (path.row == 0 ? @[@1, @2] : (path.row == 1 ? @[@"360", @"480", @"720", @"1080"] : nil));
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:[tableView cellForRowAtIndexPath:path].textLabel.text message:nil preferredStyle:UIAlertControllerStyleAlert];
    if (values) {
        for (id value in values) {
            NSString* title = (!self.cacheMode && path.row == 0) ? ([value integerValue] == 2 ? @"Веб-плеер источника" : @"Встроенный iOS") : [value description];
            [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
                [self.settings setSettingsObject:self.cacheMode ? @([value integerValue]*1024*1024) : value atKey:key];
                [tableView reloadData];
            }]];
        }
    } else {
        alert.message = path.row == 10 ? @"За столько секунд до конца перейти к следующей серии, если включён пропуск конца. Последняя серия не обрывается." : @"Опенинг пропускается по заданному интервалу, без распознавания.";
        [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
            field.text = [[self.settings getSettingsObjectAtKey:key] description]; field.keyboardType = UIKeyboardTypeNumberPad;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Сохранить" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            NSString* text = alert.textFields.firstObject.text ?: @"";
            id value = text;
            if (path.row >= 7) value = @(MIN(3600, MAX(0, text.integerValue)));
            [self.settings setSettingsObject:value atKey:key]; [tableView reloadData];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

@interface SettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) LibanixartApi* api_proxy;
@property(nonatomic, strong) AppSettingsDataController* app_settings_controller;
@property(nonatomic, retain) UITableView* content_table_view;

@end

@implementation SettingsViewController

-(instancetype)init {
    self = [super init];
    
    _api_proxy = [LibanixartApi sharedInstance];
    _app_settings_controller = [[AppDataController sharedInstance] getSettingsController];
    
    return self;
}

-(void)viewDidLoad {
    [super viewDidLoad];
    
    [self setup];
    [self setupLayout];
}
-(void)setup {
    self.navigationItem.title = NSLocalizedString(@"app.settings.title", "");
    
    _content_table_view = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    [_content_table_view registerClass:TransitionTableViewCell.class forCellReuseIdentifier:[TransitionTableViewCell getIdentifier]];
    [_content_table_view registerClass:SwitchTableViewCell.class forCellReuseIdentifier:[SwitchTableViewCell getIdentifier]];
    _content_table_view.dataSource = self;
    _content_table_view.delegate = self;
    
    [self.view addSubview:_content_table_view];
    
    _content_table_view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [_content_table_view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_content_table_view.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [_content_table_view.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [_content_table_view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}
-(void)setupLayout {
    self.view.backgroundColor = [AppColorProvider backgroundColor];
    _content_table_view.backgroundColor = [AppColorProvider backgroundColor];
}

-(NSInteger)numberOfSectionsInTableView:(UITableView *)table_view {
    return 4;
}
-(NSInteger)tableView:(UITableView *)table_view numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return 2;
        case 1:
            return 4;
        case 2:
            return 1;
        case 3:
            return 2;
    }
    return 0;
}
-(CGFloat)tableView:(UITableView *)table_view heightForRowAtIndexPath:(NSIndexPath *)index_path {
    return 50;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case 2:
            return NSLocalizedString(@"app.settings.alternative_connection.footer", "");
    }
    return nil;
}
-(UITableViewCell *)tableView:(UITableView *)table_view cellForRowAtIndexPath:(NSIndexPath *)index_path {
    NSInteger section = index_path.section;
    NSInteger row = index_path.row;
    if (section == 0) {
        if (row == 0) {
            TransitionTableViewCell* cell = [table_view dequeueReusableCellWithIdentifier:[TransitionTableViewCell getIdentifier]];
            
            [cell setName:NSLocalizedString(@"app.settings.profile.name", "")];
            [cell setContent:nil];
            [cell setImage:[UIImage systemImageNamed:@"person.fill"] tintColor:[UIColor whiteColor] color:[UIColor systemRedColor]];
            return cell;
        }
        if (row == 1) {
            TransitionTableViewCell* cell = [table_view dequeueReusableCellWithIdentifier:[TransitionTableViewCell getIdentifier]];
            
            [cell setName:NSLocalizedString(@"app.settings.privacy_and_security.name", "")];
            [cell setContent:nil];
            [cell setImage:[UIImage systemImageNamed:@"lock.fill"] tintColor:[UIColor whiteColor] color:[UIColor systemGrayColor]];
            return cell;
        }
    }
    if (section == 1) {
        if (row == 0) {
            TransitionTableViewCell* cell = [table_view dequeueReusableCellWithIdentifier:[TransitionTableViewCell getIdentifier]];
            
            [cell setName:NSLocalizedString(@"app.settings.appearance.name", "")];
            [cell setContent:nil];
            [cell setImage:[UIImage systemImageNamed:@"eye.fill"] tintColor:[UIColor whiteColor] color:[UIColor systemIndigoColor]];
            return cell;
        }
        if (row == 1) {
            TransitionTableViewCell* cell = [table_view dequeueReusableCellWithIdentifier:[TransitionTableViewCell getIdentifier]];
            
            [cell setName:NSLocalizedString(@"app.settings.notifications.name", "")];
            [cell setContent:nil];
            [cell setImage:[UIImage systemImageNamed:@"bell.fill"] tintColor:[UIColor whiteColor] color:[UIColor systemPurpleColor]];
            return cell;
        }
        if (row == 2) {
            TransitionTableViewCell* cell = [table_view dequeueReusableCellWithIdentifier:[TransitionTableViewCell getIdentifier]];
            
            [cell setName:NSLocalizedString(@"app.settings.data_control.name", "")];
            [cell setContent:nil];
            [cell setImage:[UIImage systemImageNamed:@"externaldrive.fill"] tintColor:[UIColor whiteColor] color:[UIColor systemGreenColor]];
            return cell;
        }
        if (row == 3) {
            TransitionTableViewCell* cell = [table_view dequeueReusableCellWithIdentifier:[TransitionTableViewCell getIdentifier]];
            
            [cell setName:NSLocalizedString(@"app.settings.playback.name", "")];
            [cell setContent:nil];
            [cell setImage:[UIImage systemImageNamed:@"arrowtriangle.right.fill"] tintColor:[UIColor whiteColor] color:[UIColor systemBlueColor]];
            return cell;
        }
    }
    if (section == 2) {
        if (row == 0) {
            SwitchTableViewCell* cell = [table_view dequeueReusableCellWithIdentifier:[SwitchTableViewCell getIdentifier]];
            
            [cell setContent:NSLocalizedString(@"app.settings.alternative_connection.name", "")];
            [cell setOn:[_app_settings_controller getAlternativeConnection]];
            [cell setHandler:^(BOOL is_on) {
                [self onAlternativeConnectionSwitched:is_on];
            }];
            return cell;
        }
    }
    if (section == 3) {
        if (row == 0) {
            TransitionTableViewCell* cell = [table_view dequeueReusableCellWithIdentifier:[TransitionTableViewCell getIdentifier]];
            
            [cell setName:NSLocalizedString(@"app.settings.help.name", "")];
            [cell setContent:nil];
            [cell setImage:[UIImage systemImageNamed:@"questionmark"] tintColor:[UIColor whiteColor] color:[UIColor systemGrayColor]];
            return cell;
        }
        if (row == 1) {
            TransitionTableViewCell* cell = [table_view dequeueReusableCellWithIdentifier:[TransitionTableViewCell getIdentifier]];
            
            [cell setName:NSLocalizedString(@"app.settings.rules.name", "")];
            [cell setContent:nil];
            [cell setImage:[UIImage systemImageNamed:@"shield.fill"] tintColor:[UIColor whiteColor] color:[UIColor systemPinkColor]];
            return cell;
        }
    }
    
    // should never reach here
    return nil;
}

-(void)tableView:(UITableView *)table_view didSelectRowAtIndexPath:(NSIndexPath *)index_path {
    NSInteger section = index_path.section;
    NSInteger row = index_path.row;
    [table_view deselectRowAtIndexPath:index_path animated:YES];
    
    if (section == 3) [self showUnavailableSetting];
    if (section == 0) {
        if (row == 0) {
            [self onProfileSelected];
        }
        if (row == 1) {
            [self onPrivacyAndSectitySelected];
        }
    }
    if (section == 1) {
        if (row == 0) [self onAppearanceSelected];
        if (row == 2 || row == 3) {
            PlaybackSettingsViewController* settings = [[PlaybackSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            settings.cacheMode = row == 2;
            [self.navigationController pushViewController:settings animated:YES];
        }
        if (row == 1) [self showUnavailableSetting];
    }
}

-(void)showUnavailableSetting {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Пока недоступно" message:@"Этот раздел ещё не реализован." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"ОК" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
-(void)onLogoutItemSelected {
    
}
-(void)onChangeCustomStatusItemSelected {
    
}
-(void)onProfileSelected {
    [self.navigationController pushViewController:[SettingsProfileViewController new] animated:YES];
}
-(void)onPrivacyAndSectitySelected {
    [self.navigationController pushViewController:[SettingsSecurityViewController new] animated:YES];
}
-(void)onAppearanceSelected {
    [self.navigationController pushViewController:[SettingsAppearanceViewController new] animated:YES];
}

-(void)onAlternativeConnectionSwitched:(BOOL)is_on {
    [_app_settings_controller setAlternativeConnection:is_on];
}

@end
