#include "PlaybackPolicy.hpp"
#include "AnimeMapping.hpp"
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
    check(validOpeningInterval(30, 120, 1400));
    check(!validOpeningInterval(120, 30, 1400));
    check(!validOpeningInterval(-1, 120, 1400));
    check(!validOpeningInterval(30, 30, 1400));
    check(!validOpeningInterval(30, 30.5, 1400));
    check(!validOpeningInterval(30, 1400, 1400));
    check(confirmedOpeningTarget(30, 1400, 30, 120, 1400, true) == 120);
    check(confirmedOpeningTarget(119.9, 1400, 30, 120, 1400, true) == 120);
    check(confirmedOpeningTarget(120, 1400, 30, 120, 1400, true) == -1);
    check(confirmedOpeningTarget(29.9, 1400, 30, 120, 1400, true) == -1);
    check(confirmedOpeningTarget(30, 1400, 30, 120, 1400, false) == -1);
    check(confirmedOpeningTarget(30, 1400, 30, 120, 1450, true) == -1);
    check(confirmedOpeningTarget(30, 1400, 30, 120, 1398, true) == -1);
    check(confirmedOpeningTarget(30, 1400, 30, 120, 1399, true) == 120);
    check(confirmedOpeningTarget(0, 1400, 0, 90, 1400, true) == 90);
    check(confirmedOpeningTarget(90, 1400, 0, 90, 1400, true) == -1);
    check(confirmedOpeningTarget(30, 1400, 30, 120, std::numeric_limits<double>::quiet_NaN(), true) == -1);
    check(parseTimestamp("90") == 90);
    check(parseTimestamp("01:30") == 90);
    check(parseTimestamp("1:02:03") == 3723);
    check(parseTimestamp(" 01:30.5 ") == 90.5);
    check(parseTimestamp("01:30,5") == 90.5);
    check(parseTimestamp("0") == 0);
    check(parseTimestamp("00:00.0") == 0);
    check(parseTimestamp("") == -1);
    check(parseTimestamp(" ") == -1);
    check(parseTimestamp("1:90") == -1);
    check(parseTimestamp("-10") == -1);
    check(parseTimestamp("nan") == -1);
    check(parseTimestamp("infinity") == -1);
    check(parseTimestamp("1:2:3:4") == -1);
    check(parseTimestamp("1.5:00") == -1);
    check(parseTimestamp("1:") == -1);
    check(parseTimestamp(":30") == -1);
    check(parseTimestamp("1::30") == -1);
    check(parseTimestamp("10.") == -1);
    check(parseTimestamp(".5") == -1);
    check(parseTimestamp("1..5") == -1);
    check(parseTimestamp("1a30") == -1);
    check(parseTimestamp("99999999999999999999") == -1);
    check(parseTimestamp("24:00:00") == 86400);
    check(parseTimestamp("24:00:01") == -1);
    AnimeIdentity show{0, {"cowboybebop", "カウボーイビバップ"}, 1998, 26, 1};
    AnimeIdentity candidate{1, {"cowboybebop"}, 1998, 26, 1};
    check(matchingAnime(show, candidate));
    check(uniqueAnime(show, {candidate}, true) == 1);
    check(uniqueAnime(show, {}, true) == 0);
    check(uniqueAnime(show, {candidate}, false) == 0); // incomplete pagination
    check(uniqueAnime(show, {candidate, candidate}, true) == 1); // de-duplicate one ID
    auto other = candidate; other.mal = 2;
    check(uniqueAnime(show, {candidate, other}, true) == 0); // ambiguous, never first result
    other.year = 1999;
    check(uniqueAnime(show, {other, candidate}, true) == 1);
    check(!matchingAnime(show, other));
    other = candidate; other.episodes = 25; check(!matchingAnime(show, other));
    other = candidate; other.category = 2; check(!matchingAnime(show, other));
    other = candidate; other.titles = {"cowboybebop2"}; check(!matchingAnime(show, other));
    other = candidate; other.mal = 0; check(!matchingAnime(show, other));
    other = candidate; other.mal = 1000000001; check(!matchingAnime(show, other));
    other = candidate; other.year = 0; check(!matchingAnime(show, other));
    other = candidate; other.episodes = 0; check(!matchingAnime(show, other));
    auto unknown = show; unknown.year = 0; unknown.episodes = 0;
    check(!matchingAnime(unknown, candidate));
    unknown = show; unknown.category = 0; check(matchingAnime(unknown, candidate));
    unknown.year = 0; check(!matchingAnime(unknown, candidate));
    unknown = show; unknown.titles = {"カウボーイビバップ"};
    other = candidate; other.titles = {"カウボーイビバップ"}; check(matchingAnime(unknown, other));
    check(mappedEpisode({1,2,3}, {1,2,3}, 2, 12) == 2);
    check(mappedEpisode({0,1,2}, {1,2,3}, 1, 12) == 2); // explicit zero-based mapping
    check(mappedEpisode({13,14}, {1,2}, 14, 12) == 2); // explicit season labels
    check(mappedEpisode({0,1,2}, {0,0,0}, 1, 12) == 0); // don't guess zero-based
    check(mappedEpisode({1,2,3}, {0,0,0}, 3, 12) == 3);
    check(mappedEpisode({3,1,2}, {0,0,0}, 2, 12) == 2); // UI sort irrelevant
    check(mappedEpisode({1,3}, {0,0}, 3, 12) == 0); // incomplete ambiguous list
    check(mappedEpisode({1,2}, {0,-1}, 1, 12) == 0); // named special disables inference
    check(mappedEpisode({1,2}, {1,-1}, 1, 12) == 1); // named regular episode still valid
    check(mappedEpisode({1,2}, {1,-1}, 2, 12) == 0);
    check(mappedEpisode({1,2}, {1,1}, 1, 12) == 0); // duplicate episode names
    check(mappedEpisode({1,1}, {1,2}, 1, 12) == 0); // duplicate positions
    check(mappedEpisode({1}, {1}, 1, 0) == 0);
    check(mappedEpisode({1}, {13}, 1, 12) == 0);
    check(mappedEpisode({1}, {}, 1, 12) == 0);
    check(mappedEpisode({}, {}, 1, 12) == 0);
    check(mappedEpisode({1}, {1}, 2, 12) == 0);
    check(mappedEpisode({1,2,3}, {0,0,0}, 2, 2) == 0); // beyond MAL season size
    std::cout << "PASS: " << total << " playback policy checks (production C++ header).\n";
}
