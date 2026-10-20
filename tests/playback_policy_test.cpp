#include "PlaybackPolicy.hpp"
#include <cassert>
#include <iostream>
#include <limits>
int main() {
    using Q = std::unordered_map<std::string, std::string>;
    using namespace playback;
    int total = 0;
    auto check = [&](bool condition) { assert(condition); ++total; };
    check(chooseQuality(Q{}, "720").empty());
    check(chooseQuality(Q{{"720", "a"}, {"1080", "b"}}, "720") == "a");
    check(chooseQuality(Q{{"720p", "a"}, {"1080p", "b"}}, "720") == "a");
    check(chooseQuality(Q{{"480p", "a"}, {"1080p", "b"}}, "720") == "a");
    check(chooseQuality(Q{{"720p", "a"}, {"1080p", "b"}}, "480") == "a");
    check(chooseQuality(Q{{"auto", "a"}, {"hls", "b"}}, "720") == "a");
    check(chooseQuality(Q{{"720", ""}, {"480", "b"}}, "720") == "b");
    check(chooseQuality(Q{{"999999999999999999999999999999", "a"}}, "720") == "a");
    check(chooseQuality(Q{{"720", "a"}}, std::string_view("720xxxx", 3)) == "a");
    check(chooseQuality(Q{{"360", "a"}, {"1080", "b"}}, "auto") == "b");
    check(qualityNumber("720p") == 720);
    check(qualityNumber("auto") == 0);
    check(nextPosition({}, 1) == -1);
    check(nextPosition({1, 2, 3}, 1) == 2);
    check(nextPosition({1, 3, 7}, 1) == 3);
    check(nextPosition({7, 1, 3, 3}, 1) == 3);
    check(nextPosition({1, 3, 7}, 7) == -1);
    check(nextPosition({1}, 1) == -1);
    check(openingTarget(0, 1400, 0, 90) == 90);
    check(openingTarget(89.5, 1400, 0, 90) == 90);
    check(openingTarget(90, 1400, 0, 90) == -1);
    check(openingTarget(10, 1400, 30, 90) == -1);
    check(openingTarget(30, 1400, 30, 90) == 120);
    check(openingTarget(119, 1400, 30, 90) == 120);
    check(openingTarget(120, 1400, 30, 90) == -1);
    check(openingTarget(0, 1400, 0, 0) == -1);
    check(openingTarget(0, 90, 0, 90) == -1);
    check(openingTarget(0, 30, 0, 90) == -1);
    check(openingTarget(0, 1400, -10, 90) == -1);
    check(openingTarget(std::numeric_limits<double>::quiet_NaN(), 1400, 0, 90) == -1);
    check(openingTarget(0, std::numeric_limits<double>::infinity(), 0, 90) == -1);
    check(shouldSkipEnding(1310, 1400, 90, true));
    check(!shouldSkipEnding(1309, 1400, 90, true));
    check(!shouldSkipEnding(1310, 1400, 90, false));
    check(!shouldSkipEnding(1400, 1400, 90, true));
    check(!shouldSkipEnding(10, 80, 90, true));
    check(!shouldSkipEnding(10, 1400, 0, true));
    check(!shouldSkipEnding(10, std::numeric_limits<double>::infinity(), 90, true));
    std::cout << "PASS: " << total << " playback policy checks (production C++ header).\n";
}
