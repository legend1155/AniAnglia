//
//  SourceSelectViewController.m
//  iOSAnixart
//
//  Created by Toilettrauma on 30.09.2024.
//

#import "SourceSelectViewController.h"
#import "LibanixartApi.h"
#import "AppColor.h"
#import "StringCvt.h"
#import "EpisodeSelectViewController.h"
#import "LoadableView.h"
#import "AppDataController.h"
#include <algorithm>

@interface SourceViewCell : UITableViewCell
@property(nonatomic, retain) UILabel* name_label;

+(NSString*)getIndentifier;

-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuse_identifier;

-(void)setName:(NSString*)name;
@end

@interface SourceSelectViewController () {
    anixart::ReleaseID _release_id;
    anixart::EpisodeTypeID _type_id;
    std::vector<anixart::EpisodeSource::Ptr> _sources;
}
@property(nonatomic, retain) NSString* type_name;
@property(nonatomic) BOOL triedPreference;
@property(nonatomic, retain) LibanixartApi* api_proxy;
@property(nonatomic, retain) UIView* header_view;
@property(nonatomic, retain) UILabel* type_name_label;
@property(nonatomic, retain) UITableView* table_view;
@property(nonatomic, retain) LoadableView* loadable_view;
@end

@implementation SourceViewCell

+(NSString*)getIndentifier {
    return @"SourceViewCell";
}
-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuse_identifier {
    self = [super initWithStyle:style reuseIdentifier:reuse_identifier];
    
    [self setup];
    [self setupLayout];
    
    return self;
}
-(void)setup {
    _name_label = [UILabel new];
    
    [self.contentView addSubview:_name_label];
    
    _name_label.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [_name_label.topAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.topAnchor],
        [_name_label.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
        [_name_label.widthAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.widthAnchor],
        [_name_label.heightAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.heightAnchor]
    ]];
}
-(void)setupLayout {
    self.backgroundColor = [AppColorProvider backgroundColor];
    _name_label.textColor = [AppColorProvider textColor];
}

-(void)setName:(NSString*)name {
    _name_label.text = name;
}

@end

@implementation SourceSelectViewController

-(instancetype)initWithReleaseID:(anixart::ReleaseID)release_id typeID:(anixart::EpisodeTypeID)type_id typeName:(NSString*)type_name {
    self = [super init];
    
    _release_id = release_id;
    _type_id = type_id;
    _type_name = type_name;
    _api_proxy = [LibanixartApi sharedInstance];
    
    return self;
}

-(void)viewDidLoad {
    [super viewDidLoad];
    
    [self preSetup];
    [self preSetupLayout];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"А–Я" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSort)];
    [self loadSources];
}

-(void)preSetup {
    self.navigationItem.title = NSLocalizedString(@"app.source_select.nav_item.title", "");
    
    _loadable_view = [LoadableView new];
    
    [self.view addSubview:_loadable_view];
    
    _loadable_view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [_loadable_view.centerYAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.centerYAnchor],
        [_loadable_view.centerXAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.centerXAnchor]
    ]];
}

-(void)setup {
    _table_view = [UITableView new];
    [_table_view registerClass:SourceViewCell.class forCellReuseIdentifier:[SourceViewCell getIndentifier]];
    _table_view.dataSource = self;
    _table_view.delegate = self;
    
    _type_name_label = [UILabel new];
    _type_name_label.text = _type_name;
    _type_name_label.font = [UIFont boldSystemFontOfSize:25];
    
    _header_view = [UIView new];
    
    [self.view addSubview:_table_view];
    [_header_view addSubview:_type_name_label];
    _table_view.tableHeaderView = _header_view;
    
    _table_view.translatesAutoresizingMaskIntoConstraints = NO;
    _header_view.translatesAutoresizingMaskIntoConstraints = NO;
    _type_name_label.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [_header_view.topAnchor constraintEqualToAnchor:_table_view.topAnchor],
        [_header_view.leadingAnchor constraintEqualToAnchor:_table_view.layoutMarginsGuide.leadingAnchor],
        [_header_view.trailingAnchor constraintEqualToAnchor:_table_view.layoutMarginsGuide.trailingAnchor],
        [_header_view.heightAnchor constraintEqualToAnchor:_type_name_label.heightAnchor constant:5],
        
        [_type_name_label.leadingAnchor constraintEqualToAnchor:_header_view.leadingAnchor],
        [_type_name_label.trailingAnchor constraintEqualToAnchor:_header_view.trailingAnchor],

        [_table_view.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_table_view.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [_table_view.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [_table_view.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    
    [_header_view setNeedsLayout];
    [_header_view layoutIfNeeded];
    _table_view.tableHeaderView = _header_view;
}

-(void)preSetupLayout {
    self.view.backgroundColor = [AppColorProvider backgroundColor];
}

-(void)setupLayout {
    _table_view.backgroundColor = [AppColorProvider backgroundColor];
    _type_name_label.textColor = [AppColorProvider textColor];
}

-(void)sortItems {
    BOOL descending = [[NSUserDefaults standardUserDefaults] boolForKey:@"sources_descending"];
    std::sort(_sources.begin(), _sources.end(), [descending](const auto& a, const auto& b) {
        NSComparisonResult result = [TO_NSSTRING(a->name) localizedCaseInsensitiveCompare:TO_NSSTRING(b->name)];
        return descending ? result == NSOrderedDescending : result == NSOrderedAscending;
    });
}
-(void)toggleSort {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:![defaults boolForKey:@"sources_descending"] forKey:@"sources_descending"];
    [self sortItems]; [_table_view reloadData];
}
-(void)loadSources {
    [_loadable_view startLoading];
    
    [_api_proxy asyncCall:^BOOL(anixart::Api* api) {
        self->_sources = api->episodes().get_release_sources(self->_release_id, self->_type_id);
        return NO;
    } completion:^(BOOL errored) {
        [self->_loadable_view endLoadingWithErrored:errored];
        if (!errored) {
            AppSettingsDataController* settings = [[AppDataController sharedInstance] getSettingsController];
            NSMutableSet<NSString*>* known = [NSMutableSet setWithArray:[settings getSettingsObjectAtKey:@"known_source_names"] ?: @[]];
            for (const auto& source : self->_sources) {
                NSString* name = TO_NSSTRING(source->name);
                if (name.length) [known addObject:name];
            }
            [settings setSettingsObject:[[known allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)] atKey:@"known_source_names"];
            [self sortItems];
            [self setup];
            [self setupLayout];
            if (!self.triedPreference) {
                self.triedPreference = YES;
                NSString* preferred = [[[AppDataController sharedInstance] getSettingsController] getSettingsObjectAtKey:@"preferred_source_name"];
                for (const auto& item : self->_sources) {
                    if (preferred.length && [TO_NSSTRING(item->name) caseInsensitiveCompare:preferred] == NSOrderedSame) {
                        [self.navigationController pushViewController:[[EpisodeSelectViewController alloc] initWithReleaseID:_release_id typeID:_type_id typeName:_type_name sourceID:item->id sourceName:TO_NSSTRING(item->name)] animated:NO];
                        break;
                    }
                }
            }
        }
    }];
}


-(NSInteger)tableView:(UITableView *)table_view numberOfRowsInSection:(NSInteger)section {
    return _sources.size();
}
-(CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 50;
}
-(UITableViewCell *)tableView:(UITableView *)table_view cellForRowAtIndexPath:(NSIndexPath *)index_path {
    SourceViewCell* cell = [table_view dequeueReusableCellWithIdentifier:[SourceViewCell getIndentifier] forIndexPath:index_path];
    NSInteger index = [index_path item];
    anixart::EpisodeSource::Ptr& source = _sources[index];
    
    [cell setName:TO_NSSTRING(source->name)];

    return cell;
}

-(void)tableView:(UITableView *)table_view didSelectRowAtIndexPath:(NSIndexPath *)index_path {
    [table_view deselectRowAtIndexPath:index_path animated:YES];
    NSInteger index = [index_path item];
    anixart::EpisodeSource::Ptr& source = _sources[index];
    AppSettingsDataController* settings = [[AppDataController sharedInstance] getSettingsController];
    if ([settings getRememberSource]) [settings setSettingsObject:TO_NSSTRING(source->name) atKey:@"preferred_source_name"];

    
    [self.navigationController pushViewController:[[EpisodeSelectViewController alloc] initWithReleaseID:_release_id typeID:_type_id typeName:_type_name sourceID:source->id sourceName:TO_NSSTRING(source->name)] animated:NO];
}

@end
