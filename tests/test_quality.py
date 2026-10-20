"""Compile the actual pure-C++ quality selector from PlayerViewController.mm."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
src = (root / 'AniAnglia/Releases/PlayerViewController.mm').read_text()
function = src[src.index('std::string choose_quality'):src.index('@interface PlayerViewController')]
cases = r'''
int main() {
 using Q = std::unordered_map<std::string, std::string>;
 assert(choose_quality(Q{}, "720").empty());
 assert(choose_quality(Q{{"720", "a"}, {"1080", "b"}}, "720") == "a");
 assert(choose_quality(Q{{"720p", "a"}, {"1080p", "b"}}, "480") == "b");
 assert(choose_quality(Q{{"auto", "a"}, {"hls", "b"}}, "720") == "a");
 assert(choose_quality(Q{{"720", ""}, {"480", "b"}}, "720") == "b");
 assert(choose_quality(Q{{"999999999999999999999999999999", "a"}}, "720") == "a");
 assert(choose_quality(Q{{"720", "a"}}, std::string_view("720xxxx", 3)) == "a");
}
'''
with tempfile.TemporaryDirectory() as temp:
 path = Path(temp) / 'test.cpp'
 path.write_text('#include <string>\n#include <string_view>\n#include <unordered_map>\n#include <cctype>\n#include <algorithm>\n#include <cassert>\n' + function + cases)
 subprocess.run(['g++', '-std=c++20', '-Wall', '-Wextra', '-Werror', str(path), '-o', temp+'/test'], check=True)
 subprocess.run([temp+'/test'], check=True)
print('PASS: 7 quality-selector cases (actual production function). iOS build not tested.')
