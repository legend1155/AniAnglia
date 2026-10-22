"""Portable logic tests only. Not an iOS build or an AVKit UI test."""
from pathlib import Path
import os, shutil, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
compiler = os.environ.get('CXX') or shutil.which('g++') or shutil.which('clang++')
if not compiler:
    raise SystemExit('A C++20 compiler (g++ or clang++) is required')
with tempfile.TemporaryDirectory() as temp:
    binary = str(Path(temp) / 'playback-test')
    subprocess.run([compiler, '-std=c++20', '-Wall', '-Wextra', '-Werror',
        '-I'+str(root/'AniAnglia/Releases'), str(root/'tests/playback_policy_test.cpp'), '-o', binary], check=True)
    subprocess.run([binary], check=True)
player = (root/'AniAnglia/Releases/PlayerViewController.mm').read_text()
assert '.pictureInPictureActive' not in player, 'Regression: property does not exist on AVPlayerViewController'
assert '@interface PlayerViewController : UIViewController' in player
assert 'playerViewControllerWillStartPictureInPicture:' in player
assert 'failedToStartPictureInPictureWithError:' in player
assert '[self.view addSubview:control]' in player
assert 'playback::confirmedOpeningTarget' in player and 'playback::nextPosition' in player
assert 'episode_openings_v3' in player
assert 'openingMediaIdentity' in player and 'record[@"media"]' in player
assert 'addBoundaryTimeObserverForTimes:' in player
assert 'removeTimeObserver:self.openingBoundaryObserver' in player
opening_method = player[player.index('-(double)openingTargetAt:'):player.index('-(void)skipOpening')]
assert 'opening_start' not in opening_method and 'getDefaultSkipTime' not in opening_method
assert 'playback::uniqueAnime(source, matches, true)' in player
assert 'playback::mappedEpisode(positions, numbers, self.source_position, total)' in player
assert 'https://api.jikan.moe/v4/anime' in player and 'has_next_page' in player
assert 'generation != owner.generation || version != owner.openingRequestVersion' in player
assert 'generation != owner.generation || requestVersion != owner.openingRequestVersion' in player
assert 'if (page >= 3)' in player
assert 'self.lastJikanRequest + 1.1' in player
assert 'origin:@"AniSkip-auto"' in player
assert 'owner.pendingOpeningStart < 0 && !owner.previewingOpening' in player
assert 'invalidateFetchedOpenings' in player
settings = (root/'AniAnglia/Misc/AppDataController.mm').read_text()
assert '@"auto_skip_opening": @YES' in settings
assert '@"aniskip_auto_lookup": @YES' in settings and 'aniskip_v4_migrated' in settings
release = (root/'AniAnglia/Releases/ReleaseViewController.mm').read_text()
episodes = (root/'AniAnglia/Releases/EpisodeSelectViewController.mm').read_text()
assert 'registerReleaseMetadata:_release' in release
assert 'setEpisodeNames:names' in episodes
assert '_episodeNames = [names copy]' in player and 'self.episodeNames = [names copy]' not in player
assert 'error:nil' not in player
# A header import alone does not link CoreMedia in this Objective-C++ target.
import re
project = (root/'AniAnglia.xcodeproj/project.pbxproj').read_text()
file_match = re.search(r'([A-F0-9]{24}) /\* CoreMedia.framework \*/ = \{isa = PBXFileReference;([^}]+)\};', project)
assert file_match and 'System/Library/Frameworks/CoreMedia.framework' in file_match[2] and 'sourceTree = SDKROOT' in file_match[2]
file_id = file_match[1]
build_match = re.search(r'([A-F0-9]{24}) /\* CoreMedia.framework in Frameworks \*/ = \{isa = PBXBuildFile; fileRef = ' + file_id, project)
assert build_match, 'CoreMedia needs a PBXBuildFile, not just a file reference'
phases = re.findall(r'([A-F0-9]{24}) /\* Frameworks \*/ = \{\s*isa = PBXFrameworksBuildPhase;([^}]+)\};', project)
assert any(build_match[1] in body for _, body in phases), 'CoreMedia must be in the target Frameworks build phase'
assert '#import <CoreMedia/CoreMedia.h>' in player
print('PASS: CoreMedia SDK reference and target link-phase regression checks.')
home = (root/'AniAnglia/Main/MainViewController.mm').read_text()
assert 'discovery::rank(candidates, taste, 24)' in home and 'officialGenres.find' in home
assert 'generation != owner.generation' in home and 'HomeProfileKey' in home
assert 'profile_voted_releases' in home and 'profile_favorites' in home
assert 'HomeProfileKey(@"hidden")' in home and 'Вернуть скрытые аниме' in home
provider = (root/'AniAnglia/Common/Pageable/ReleasesPageableDataProvider.mm').read_text()
assert 'const auto pages = _pages' in provider and 'Pageable<anixart::Release>::Ptr _pages' in provider
assert 'generation != self->_requestGeneration' in provider and 'std::lock_guard<std::mutex>' in provider
assert 'self->_pages->get()' not in provider and 'self->_pages->next()' not in provider
assert 'if (_is_needed_first_load) { [self loadCurrentPage]; return; }' in provider
assert 'playback::verifiedAnime(identity)' in player and 'showOpeningDiagnostics' in player
assert 'playback::shouldAutoAdvance' in player and 'record[@"metadata"]' in player
setter_start = player.index('-(void)setOpeningStatus:')
setter = player[setter_start:player.index('-(void)showOpeningDiagnostics', setter_start)]
assert '[self openingRecord]' not in setter, 'Status setter must not recursively resolve a binding'
filters = (root/'AniAnglia/Main/Search/FilterViewController.mm').read_text()
assert 'discovery::validYearRange' in filters and '_filter_request.start_year' in filters and 'resetFilters' in filters
# Snapshot is from the public AniSkip response, not an on-device timing test.
import json
fixture = json.loads((root/'tests/fixtures/aniskip_54595_4.json').read_text())
assert fixture['found'] and fixture['results'][0]['skipType'] == 'op'
assert fixture['results'][0]['interval'] == {'startTime':133.189, 'endTime':223.189}
assert fixture['results'][0]['episodeLength'] == 1422.467
import hashlib
progress_method = player[player.index('-(void)saveProgress {'):player.index('-(void)stopObserving {')]
assert hashlib.sha256(progress_method.encode()).hexdigest() == 'c397389220996ff02342ee911093c344a1678aefd1c0198d76fc1eee604d7eb0', 'Do not change the working progress persistence in v5'
assert 'candidate[@"requiresReview"]' in player and 'needsReview.count == 1' in player
# Read the production regex literal; this checks common labels under Python, not Apple's ICU runtime.
pattern_literal = re.search(r'pattern = \[NSRegularExpression regularExpressionWithPattern:@"((?:\\.|[^"\\])*)"', player)
assert pattern_literal
number_pattern = re.compile(json.loads('"' + pattern_literal[1] + '"'), re.IGNORECASE)
for label, expected in [('4',4), ('Серия №4',4), ('4-я серия',4), ('Episode 04',4), ('4 серия из 12',4), ('Ep. 4',4)]:
    match = number_pattern.fullmatch(label)
    assert match and int(match[1]) == expected, label
for label in ['4.5', 'OVA 4', '4 серия + спецвыпуск', 'Season 2 Episode 4']:
    assert not number_pattern.fullmatch(label), label
# Read the production regex literal; this checks common labels under Python, not Apple's ICU runtime.
pattern_literal = re.search(r'pattern = \[NSRegularExpression regularExpressionWithPattern:@"((?:\\.|[^"\\])*)"', player)
assert pattern_literal
number_pattern = re.compile(json.loads('"' + pattern_literal[1] + '"'), re.IGNORECASE)
for label, expected in [('4',4), ('Серия №4',4), ('4-я серия',4), ('Episode 04',4), ('4 серия из 12',4), ('Ep. 4',4)]:
    match = number_pattern.fullmatch(label)
    assert match and int(match[1]) == expected, label
for label in ['4.5', 'OVA 4', '4 серия + спецвыпуск', 'Season 2 Episode 4']:
    assert not number_pattern.fullmatch(label), label
print('PASS: v5 static source checks and recorded AniSkip response fixture (not iOS integration).')
print('PASS: source regression checks; iOS compilation and device UI still require Xcode/iPhone.')
