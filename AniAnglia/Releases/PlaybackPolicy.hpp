#pragma once
#include <algorithm>
#include <cctype>
#include <cmath>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace playback {
inline int qualityNumber(std::string_view label) {
    int value = 0;
    for (unsigned char c : label) {
        if (!std::isdigit(c)) break;
        value = std::min(100000, value * 10 + c - '0');
    }
    return value;
}
inline std::string chooseQuality(const std::unordered_map<std::string, std::string>& qualities, std::string_view preferred) {
    auto exact = qualities.find(std::string(preferred));
    if (exact != qualities.end() && !exact->second.empty()) return exact->second;
    const int requested = qualityNumber(preferred);
    std::string result;
    int bestRank = -1, bestValue = -1;
    for (const auto& [label, url] : qualities) {
        if (url.empty()) continue;
        int value = qualityNumber(label);
        // Same resolution (720p), then highest below preference, then lowest above.
        int rank = requested > 0 ? (value == requested ? 4 : (value > 0 && value < requested ? 3 : (value > 0 ? 2 : 1))) : 1;
        int score = rank == 2 ? -value : value;
        if (rank > bestRank || (rank == bestRank && (score > bestValue || (score == bestValue && url < result)))) {
            bestRank = rank; bestValue = score; result = url;
        }
    }
    return result;
}
inline long nextPosition(const std::vector<long>& positions, long current) {
    long result = -1;
    for (long position : positions) if (position > current && (result < 0 || position < result)) result = position;
    return result;
}
inline double openingTarget(double seconds, double duration, double begin, double length) {
    if (!std::isfinite(seconds) || !std::isfinite(duration) || !std::isfinite(begin) || !std::isfinite(length)) return -1;
    if (seconds < 0 || begin < 0 || length <= 0 || duration <= 0) return -1;
    double target = begin + length;
    return seconds >= begin && seconds < target && target < duration ? target : -1;
}
inline bool shouldSkipEnding(double seconds, double duration, double length, bool hasNext) {
    return hasNext && std::isfinite(seconds) && std::isfinite(duration) && std::isfinite(length) && length > 0 &&
        duration > length + 30 && seconds >= duration - length && seconds < duration;
}
}
