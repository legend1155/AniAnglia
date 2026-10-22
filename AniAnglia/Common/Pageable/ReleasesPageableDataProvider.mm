//
//  ReleasesPageableDataProvider.m
//  AniAnglia
//
//  Created by Toilettrauma on 20.04.2025.
//

#import <Foundation/Foundation.h>
#import "ReleasesPageableDataProvider.h"
#import "ProfileListsView.h"
#import "StringCvt.h"
#include <mutex>

@interface ReleasesPageableDataProvider () {
    anixart::Pageable<anixart::Release>::Ptr _pages;
    std::mutex _pageMutex;
    NSUInteger _requestGeneration;
    BOOL _loading, _endReached, _pendingRefresh;
    NSInteger _lastPageIndex;
    std::vector<anixart::Release::Ptr> _releases;
}
@property(nonatomic, readonly) BOOL is_needed_first_load;

@end

@implementation ReleasesPageableDataProvider

+(NSString*)getSeasonNameFor:(anixart::Release::Season)season {
    switch (season) {
        case anixart::Release::Season::Winter:
            return NSLocalizedString(@"app.release.season.winter", "");
        case anixart::Release::Season::Spring:
            return NSLocalizedString(@"app.release.season.spring", "");
        case anixart::Release::Season::Summer:
            return NSLocalizedString(@"app.release.season.summer", "");
        case anixart::Release::Season::Fall:
            return NSLocalizedString(@"app.release.season.fall", "");
        default:
            return NSLocalizedString(@"app.release.season.unknown", "");
    }
}

+(NSString*)getCategoryNameFor:(anixart::Release::Category)category {
    switch (category) {
        case anixart::Release::Category::Series:
            return NSLocalizedString(@"app.release.category.series", "");
        case anixart::Release::Category::Movies:
            return NSLocalizedString(@"app.release.category.movies", "");
        case anixart::Release::Category::Ova:
            return NSLocalizedString(@"app.release.category.ova", "");
        default:
            return NSLocalizedString(@"app.release.category.unknown", "");
    }
}

+(NSString*)getStatusNameFor:(anixart::Release::Status)status {
    switch (status) {
        case anixart::Release::Status::Finished:
            return NSLocalizedString(@"app.release.status.finished", "");
        case anixart::Release::Status::Ongoing:
            return NSLocalizedString(@"app.release.status.ongoing", "");
        case anixart::Release::Status::Upcoming:
            return NSLocalizedString(@"app.release.status.upcoming", "");
        default:
            return NSLocalizedString(@"app.release.status.unknown", "");
    }
}

+(NSString*)getAgeRatingNameFor:(anixart::Release::AgeRating)age_rating {
    switch (age_rating) {
        case anixart::Release::AgeRating::G:
            return NSLocalizedString(@"app.release.age_rating.g", "");
        case anixart::Release::AgeRating::PG6:
            return NSLocalizedString(@"app.release.age_rating.pg6", "");
        case anixart::Release::AgeRating::PG12:
            return NSLocalizedString(@"app.release.age_rating.pg12", "");
        case anixart::Release::AgeRating::R16:
            return NSLocalizedString(@"app.release.age_rating.r16", "");
        case anixart::Release::AgeRating::R18:
            return NSLocalizedString(@"app.release.age_rating.r18", "");
        default:
            return NSLocalizedString(@"app.release.age_rating.unknown", "");
    }
}

-(instancetype)initWithPages:(anixart::Pageable<anixart::Release>::UPtr)pages {
    if ((self = [super init])) {
        _pages = std::move(pages); _is_needed_first_load = static_cast<bool>(_pages); _endReached = !_pages;
    }
    return self;
}
-(instancetype)initWithPages:(anixart::Pageable<anixart::Release>::UPtr)pages initialReleases:(std::vector<anixart::Release::Ptr>)releases {
    if ((self = [self initWithPages:std::move(pages)])) _releases = std::move(releases);
    return self;
}
-(void)clear {
    ++_requestGeneration; _loading = NO; _pendingRefresh = NO;
    _releases.clear(); [self callDelegateDidUpdate];
}
-(void)reload {
    if (_loading) { _pendingRefresh = YES; return; }
    _releases.clear(); [self callDelegateDidUpdate]; [self loadPageAtIndex:0];
}
-(void)refresh {
    if (_loading) { _pendingRefresh = YES; return; }
    [self loadPageAtIndex:0];
}
-(void)setPages:(anixart::Pageable<anixart::Release>::UPtr)pages {
    ++_requestGeneration; _loading = NO; _pendingRefresh = NO;
    _releases.clear(); _pages = std::move(pages); _endReached = !_pages; _lastPageIndex = 0;
    [self callDelegateDidUpdate]; [self loadCurrentPage];
}
-(BOOL)isEnd { return _endReached; }
-(size_t)getItemsCount { return _releases.size(); }
-(anixart::Release::Ptr)getReleaseAtIndex:(NSInteger)index {
    return index >= 0 && static_cast<std::size_t>(index) < _releases.size() ? _releases[static_cast<std::size_t>(index)] : nullptr;
}
-(void)loadPageAtIndex:(NSInteger)index mode:(NSInteger)mode append:(BOOL)append {
    if (!_pages || _loading) return;
    _loading = YES; _is_needed_first_load = NO;
    const auto pages = _pages; // Shared ownership: changing a query cannot destroy an in-flight pager.
    const NSUInteger generation = _requestGeneration;
    __block std::vector<anixart::Release::Ptr> items;
    __block NSInteger loadedIndex = index;
    __block BOOL endReached = NO;
    if ([self.delegate respondsToSelector:@selector(pageableDataProvider:didBeginLoadingPageAtIndex:)])
        [self.delegate pageableDataProvider:self didBeginLoadingPageAtIndex:index];
    [self.api_proxy asyncCall:^BOOL(anixart::Api* api) {
        (void)api;
        // Also serialize refreshes of the same mutable pager after clear/replacement.
        std::lock_guard<std::mutex> guard(self->_pageMutex);
        items = mode == 1 ? pages->next() : (mode == 2 ? pages->go((int32_t)index) : pages->get());
        loadedIndex = pages->get_current_page(); endReached = pages->is_end();
        return NO;
    } completion:^(BOOL errored) {
        if (generation != self->_requestGeneration) return; // Old query never changes new results or spinner.
        self->_loading = NO;
        if (errored) [self callDelegateDidFailPageAtIndex:index];
        else {
            if (append) self->_releases.insert(self->_releases.end(), items.begin(), items.end());
            else self->_releases = std::move(items);
            self->_lastPageIndex = loadedIndex; self->_endReached = endReached;
            [self callDelegateDidLoadPageAtIndex:loadedIndex];
        }
        if (self->_pendingRefresh) { self->_pendingRefresh = NO; [self refresh]; }
    }];
}
-(void)loadCurrentPage { [self loadPageAtIndex:_lastPageIndex mode:0 append:NO]; }
-(void)loadCurrentPageIfNeeded {
    if (_is_needed_first_load) [self loadCurrentPage];
    else if (!_loading) [self callDelegateDidLoadPageAtIndex:_lastPageIndex];
}
-(void)loadNextPage {
    if (!_pages || _endReached || _loading) return;
    if (_is_needed_first_load) { [self loadCurrentPage]; return; }
    [self loadPageAtIndex:_lastPageIndex + 1 mode:1 append:YES];
}
-(void)loadPageAtIndex:(NSInteger)index { [self loadPageAtIndex:index mode:2 append:NO]; }

-(UIAction*)makeContextMenuAction:(anixart::Profile::ListStatus)list_status toRelease:(anixart::Release::Ptr)release {
    UIImage* image = list_status == release->profile_list_status ? [UIImage systemImageNamed:@"checkmark"] : nil;
    return [UIAction actionWithTitle:[ProfileListsView getListStatusName:list_status] image:image identifier:nil handler:^(UIAction* action) {
        [self onAddListContextMenu:list_status withRelease:release];
    }];
}

-(UIContextMenuConfiguration *)getContextMenuConfigurationForItemAtIndex:(NSInteger)index {
    if (index >= _releases.size()) {
        return nil;
    }
    anixart::Release::Ptr release = _releases[index];
    
    UIMenu* list_menu = [UIMenu menuWithTitle:NSLocalizedString(@"app.release.list_status.add", "") image:[UIImage systemImageNamed:@"line.3.horizontal"] identifier:nil options:0 children:@[
        [self makeContextMenuAction:anixart::Profile::ListStatus::NotWatching toRelease:release],
        [self makeContextMenuAction:anixart::Profile::ListStatus::Watching toRelease:release],
        [self makeContextMenuAction:anixart::Profile::ListStatus::Plan toRelease:release],
        [self makeContextMenuAction:anixart::Profile::ListStatus::Watched toRelease:release],
        [self makeContextMenuAction:anixart::Profile::ListStatus::HoldOn toRelease:release],
        [self makeContextMenuAction:anixart::Profile::ListStatus::Dropped toRelease:release]
    ]];
    UIAction* bookmark_action;
    if (release->is_favorite) {
        bookmark_action = [UIAction actionWithTitle:NSLocalizedString(@"app.release.bookmark.remove", "") image:[UIImage systemImageNamed:@"bookmark.slash"] identifier:nil handler:^(UIAction* action){
            [self onBookmarkContextMenu:NO withRelease:release];
        }];
    } else {
        bookmark_action = [UIAction actionWithTitle:NSLocalizedString(@"app.release.bookmark.add", "") image:[UIImage systemImageNamed:@"bookmark"] identifier:nil handler:^(UIAction* action){
            [self onBookmarkContextMenu:YES withRelease:release];
        }];
    }
    
    UIMenu* copy_menu = [UIMenu menuWithTitle:NSLocalizedString(@"app.release.copy", "") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil options:0 children:@[
        [UIAction actionWithTitle:NSLocalizedString(@"app.release.copy_title", "") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction* action) {
            [self onCopyTitleContextMenuWithRelease:release];
        }],
        [UIAction actionWithTitle:NSLocalizedString(@"app.release.copy_orig_title", "") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction* action) {
            [self onCopyOrigTitleContextMenuWithRelease:release];
        }],
        [UIAction actionWithTitle:NSLocalizedString(@"app.release.copy_alt_title", "") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction* action) {
            [self onCopyAltTitleContextMenuWithRelease:release];
        }],
    ]];
    
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^(NSArray* suggested_actions) {
        return [UIMenu menuWithChildren:@[
            bookmark_action,
            list_menu,
            copy_menu
        ]];
    }];
}

-(void)onAddListContextMenu:(anixart::Profile::ListStatus)list_status withRelease:(anixart::Release::Ptr)release {
    [self.api_proxy performAsyncBlock:^BOOL(anixart::Api* api) {
        api->releases().add_release_to_profile_list(release->id, list_status);
        return YES;
    } withUICompletion:^{
        // possible violation
        release->profile_list_status = list_status;
        [self callDelegateDidUpdate];
    }];
}

-(void)onBookmarkContextMenu:(BOOL)bookmarked withRelease:(anixart::Release::Ptr)release {
    [self.api_proxy performAsyncBlock:^BOOL(anixart::Api* api) {
        if (bookmarked) {
            api->releases().add_release_to_favorites(release->id);
        } else {
            api->releases().remove_release_from_favorites(release->id);
        }
        return YES;
    } withUICompletion:^{
        // possible violation
        release->is_favorite = bookmarked;
        [self callDelegateDidUpdate];
    }];
}

-(void)onCopyTitleContextMenuWithRelease:(anixart::Release::Ptr)release {
    UIPasteboard* pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = TO_NSSTRING(release->title_ru);
}

-(void)onCopyOrigTitleContextMenuWithRelease:(anixart::Release::Ptr)release {
    UIPasteboard* pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = TO_NSSTRING(release->title_original);
}

-(void)onCopyAltTitleContextMenuWithRelease:(anixart::Release::Ptr)release {
    UIPasteboard* pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = TO_NSSTRING(release->title_alt);
}


@end
