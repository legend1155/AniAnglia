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
print('PASS: source regression checks; iOS compilation and device UI still require Xcode/iPhone.')
