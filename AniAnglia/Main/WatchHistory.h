#pragma once
#import <Foundation/Foundation.h>
static inline NSString* AniWatchKey(long long profile) {
    return [NSString stringWithFormat:@"watch_interest_v1_%lld", profile];
}
static inline NSString* AniWatchRevisionKey(NSString* key) { return [key stringByAppendingString:@"_revision"]; }
// Store contiguous coverage as ranges rather than thousands of NSNumber entries per episode.
static inline NSArray* AniWatchRanges(NSSet<NSNumber*>* seconds) {
    NSMutableArray* ranges = [NSMutableArray new]; NSInteger begin = -1, end = -1;
    for (NSNumber* value in [seconds.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        NSInteger second = value.integerValue;
        if (begin < 0) { begin = second; end = second + 1; }
        else if (second == end) ++end;
        else { [ranges addObject:@[@(begin), @(end)]]; begin = second; end = second + 1; }
    }
    if (begin >= 0) [ranges addObject:@[@(begin), @(end)]];
    return ranges;
}
static inline NSMutableSet<NSNumber*>* AniWatchSeconds(NSDictionary* record, double duration) {
    NSMutableSet<NSNumber*>* seconds = [NSMutableSet new];
    if (!(duration > 0 && duration <= 18000) || ![record isKindOfClass:NSDictionary.class] || ![record[@"ranges"] isKindOfClass:NSArray.class]) return seconds;
    for (id range in record[@"ranges"]) {
        if (![range isKindOfClass:NSArray.class] || [range count] != 2 || ![range[0] isKindOfClass:NSNumber.class] || ![range[1] isKindOfClass:NSNumber.class]) continue;
        double beginValue = [range[0] doubleValue], endValue = [range[1] doubleValue];
        NSInteger begin = [range[0] integerValue], end = [range[1] integerValue];
        if (!(beginValue >= 0 && endValue > beginValue && endValue <= duration && beginValue == begin && endValue == end)) continue;
        for (NSInteger second = begin; second < end; ++second) [seconds addObject:@(second)];
    }
    return seconds;
}
// A single main-queue writer. No stream URLs, account tokens or server telemetry.
static inline void AniStoreWatch(NSString* key, NSString* releaseID, NSString* episodeKey,
                                NSString* genres, NSSet<NSNumber*>* seconds, double duration) {
    if (!key.length || !releaseID.length || !episodeKey.length || !seconds.count) return;
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary* library = [[defaults dictionaryForKey:key] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary* title = [library[releaseID] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary* episodes = [title[@"episodes"] mutableCopy] ?: [NSMutableDictionary new];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    episodes[episodeKey] = @{@"ranges": AniWatchRanges(seconds), @"duration": @(duration), @"updated": @(now)};
    while (episodes.count > 50) {
        NSString* oldest = [[episodes.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString* a, NSString* b) { return [episodes[a][@"updated"] compare:episodes[b][@"updated"]]; }] firstObject];
        [episodes removeObjectForKey:oldest];
    }
    title[@"episodes"] = episodes; title[@"updated"] = @(now);
    if (genres.length) title[@"genres"] = genres;
    library[releaseID] = title;
    while (library.count > 100) {
        NSString* oldest = [[library.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString* a, NSString* b) { return [library[a][@"updated"] compare:library[b][@"updated"]]; }] firstObject];
        [library removeObjectForKey:oldest];
    }
    NSMutableArray<NSDictionary*>* entries = [NSMutableArray new];
    for (NSString* titleID in library) for (NSString* episode in library[titleID][@"episodes"]) {
        [entries addObject:@{@"title":titleID, @"episode":episode, @"updated":library[titleID][@"episodes"][episode][@"updated"] ?: @0}];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) { return [a[@"updated"] compare:b[@"updated"]]; }];
    for (NSUInteger i = 0; entries.count > 300 && i < entries.count - 300; ++i) {
        NSDictionary* entry = entries[i]; NSString* titleID = entry[@"title"];
        NSMutableDictionary* oldTitle = [library[titleID] mutableCopy];
        NSMutableDictionary* oldEpisodes = [oldTitle[@"episodes"] mutableCopy];
        [oldEpisodes removeObjectForKey:entry[@"episode"]]; oldTitle[@"episodes"] = oldEpisodes;
        if (oldEpisodes.count) library[titleID] = oldTitle; else [library removeObjectForKey:titleID];
    }
    [defaults setObject:library forKey:key];
    [defaults setInteger:[defaults integerForKey:AniWatchRevisionKey(key)] + 1 forKey:AniWatchRevisionKey(key)];
}
